# 02_georef.R — georeference selected thumbnails to estimated ground footprints
#
# Usage:
#   Rscript scripts/02_georef.R              # every registered AOI
#   Rscript scripts/02_georef.R se_a se_b    # named AOIs only
#
# Reads the selected set 01_fetch.R wrote rather than re-deriving the filter,
# so the two stages cannot drift apart.

suppressPackageStartupMessages({
  library(sf)
  library(dplyr)
  library(arrow)
  library(fly)
})

source("scripts/aoi.R")

aoi_require_fly()

ids <- aoi_ids()

for (id in ids) {
  message("\n=== ", id, " — ", aoi_label(id), " ===")

  sel_path <- aoi_path("selected", id)
  if (!file.exists(sel_path)) {
    stop("No selected set for '", id, "' at ", sel_path,
         " — run 01_fetch.R first.", call. = FALSE)
  }

  selected <- aoi_centroids_as_sf(arrow::read_parquet(sel_path))
  selected$year <- as.integer(selected$photo_year)

  # The whole fetch window, as 01_fetch.R sized it. fly_georef() builds its own
  # footprints from whatever `photos_sf` it is handed, and fly_bearing() needs a
  # neighbour ADJACENT by frame_number — so handing it the thinned selected set
  # lost bearings the ledger had recorded, and wrote those frames axis-aligned
  # (#28: 1 of 88 on se_c). Handed the window, it footprints the intact rolls and
  # georeferences only the frames in `fetch_result`.
  win_path <- aoi_path("window", id)
  if (!file.exists(win_path)) {
    stop("No window for '", id, "' at ", win_path, " — re-run 01_fetch.R.",
         call. = FALSE)
  }
  window <- aoi_centroids_as_sf(arrow::read_parquet(win_path))
  window$year <- as.integer(window$photo_year)

  if (!all(c("rotation", "rotation_source") %in% names(window))) {
    stop("Window for '", id, "' has no per-roll `rotation` — re-run 01_fetch.R.",
         call. = FALSE)
  }

  # Selection and georeferencing must be one fly. A window sized by another build
  # would be georeferenced on footprints that differ from the ones that selected
  # it, and the items would name a fly that did only half the work.
  prov <- aoi_provenance()
  if (!identical(unique(window$fly_sha), prov$fly_sha)) {
    stop("Window for '", id, "' was sized with fly ", paste(unique(window$fly_sha), collapse = ", "),
         " but fly ", prov$fly_sha, " is installed. Re-run 01_fetch.R ", id, ".",
         call. = FALSE)
  }

  # --- The ledger, read and checked before any work -----------------------
  # Up here rather than beside the write at the end of the loop: the schema
  # refusal tells the operator to re-run 01_fetch.R, and it used to arrive after
  # fly_georef() had already written every GeoTIFF for the AOI.

  # aoi_id as character: an AOI id that looks numeric would otherwise be guessed
  # as a double, fail aoi_ledger_check_id(), and be written back reformatted.
  ledger <- readr::read_csv(aoi_path("ledger", id), show_col_types = FALSE,
                            col_types = readr::cols(aoi_id = "c"))
  aoi_ledger_check_cols(ledger, id)
  aoi_ledger_check_id(ledger, id)

  # Built at fetch time, read here. Resolving the AOI polygon to build one would
  # open a `fresh` database connection for a watershed AOI, which this stage has
  # no other reason to need.
  dem <- aoi_dem(id)

  # --- What actually made it to disk --------------------------------------

  thumb_files <- list.files(file.path("data", "raw", "thumbs"),
                            pattern = "\\.jpg$", recursive = TRUE,
                            full.names = TRUE)

  fetch_result <- tibble::tibble(
    airp_id = selected$airp_id[match(
      basename(thumb_files),
      basename(selected$thumbnail_image_url)
    )],
    dest = thumb_files,
    success = TRUE
  ) |> tidyr::drop_na(airp_id)

  message(nrow(fetch_result), " of this AOI's thumbnails on disk")

  manifest <- aoi_georef_manifest_read()

  # --- Georeference per year ----------------------------------------------
  # Output: data/raw/georef/thumbs/{year}/*.tif (BC Albers 3005), global and
  # year-partitioned so an overlapping AOI reuses rather than duplicates.

  years <- sort(unique(
    selected$year[selected$airp_id %in% fetch_result$airp_id]
  ))

  georef_results <- purrr::map_dfr(years, function(yr) {
    ids_yr <- selected$airp_id[selected$year == yr]
    fr <- dplyr::filter(fetch_result, airp_id %in% ids_yr)
    # Every window frame on the rolls being written, whatever its year, rather
    # than the selected set. fly_bearing() groups by roll, so this is the set the
    # ledger's bearings came from, and it needs no assumption that a roll was
    # flown within one year.
    rolls <- unique(selected$film_roll[selected$airp_id %in% fr$airp_id])
    ph <- window[window$film_roll %in% rolls, ]

    if (nrow(fr) == 0) return(tibble::tibble())

    # Prove it rather than argue it: the bearing fly will derive here must be the
    # one the ledger records for every frame about to be written. fly_georef()
    # calls fly_footprint() on exactly these inputs internally.
    fp <- fly::fly_footprint(ph, dem = dem)
    led <- ledger[match(fr$airp_id, ledger$airp_id), ]
    now <- fp$footprint_bearing[match(fr$airp_id, fp$airp_id)]
    was <- suppressWarnings(as.numeric(led$footprint_bearing))
    drift <- !((is.na(now) & is.na(was)) |
                 (!is.na(now) & !is.na(was) & abs(now - was) < 1e-6))
    if (any(drift)) {
      stop(sum(drift), " frame(s) in ", yr, " would be georeferenced on a bearing ",
           "other than the one the ledger records (e.g. airp_id ",
           paste(utils::head(fr$airp_id[drift], 5), collapse = ", "), "). ",
           "Re-run 01_fetch.R ", id, " so both come from the same window.",
           call. = FALSE)
    }

    # A GeoTIFF already on disk is reused by fly_georef(overwrite = FALSE). That
    # is only safe if it was written from the same inputs, so each one is
    # recorded in a manifest and removed when its rotation, bearing or fly build
    # has changed since — a changed rotation table then reaches the raster.
    dest <- file.path("data", "raw", "georef", "thumbs", yr,
                      sub("\\.[^.]+$", ".tif", basename(fr$dest)))
    # The footprint ring itself, digested, so a change of size or position that
    # leaves the bearing alone — a rebuilt DEM, a refreshed catalogue row — still
    # regenerates the GeoTIFF. Rounded to the centimetre so float noise does not.
    # ...and must be the footprint 01_fetch.R selected on, to the centimetre.
    fp_digest <- aoi_footprint_digest(fp[match(fr$airp_id, fp$airp_id), ])
    was_digest <- window$footprint_digest[match(fr$airp_id, window$airp_id)]
    moved <- !((is.na(fp_digest) & is.na(was_digest)) |
                 (!is.na(fp_digest) & !is.na(was_digest) & fp_digest == was_digest))
    if (any(moved)) {
      stop(sum(moved), " frame(s) in ", yr, " would be georeferenced on a footprint ",
           "other than the one 01_fetch.R selected on (e.g. airp_id ",
           paste(utils::head(fr$airp_id[moved], 5), collapse = ", "), "). ",
           "Re-run 01_fetch.R ", id, ".", call. = FALSE)
    }
    want <- tibble::tibble(dest = dest, airp_id = as.character(fr$airp_id),
                           rotation = as.integer(led$rotation), footprint_bearing = now,
                           footprint_digest = fp_digest,
                           fly_sha = prov$fly_sha,
                           pipeline_sha = prov$pipeline_sha,
                           source = fr$dest,
                           source_md5 = unname(tools::md5sum(fr$dest)))
    had <- manifest[match(dest, manifest$dest), ]
    # Element-wise, NA equal to NA and to nothing else.
    eq <- function(a, b) (is.na(a) & is.na(b)) | (!is.na(a) & !is.na(b) & a == b)
    same <- !is.na(had$dest) &
      eq(had$rotation, want$rotation) &
      eq(round(had$footprint_bearing, 6), round(want$footprint_bearing, 6)) &
      eq(had$footprint_digest, want$footprint_digest) &
      eq(had$fly_sha, want$fly_sha) &
      eq(had$pipeline_sha, want$pipeline_sha) &
      eq(had$source_md5, want$source_md5)
    stale <- file.exists(dest) & !same
    if (any(stale)) {
      message("  regenerating ", sum(stale), " GeoTIFF(s) whose inputs changed")
      unlink(dest[stale])
    }

    message("  georeferencing ", nrow(fr), " thumbnails for ", yr,
            " (", nrow(ph), " window frames footprinted)")
    res <- fly::fly_georef(
      fr, ph,
      dest_dir = file.path("data", "raw", "georef", "thumbs", yr),
      rotation = "auto",
      dem = dem
    )
    ok_rows <- want[want$dest %in% res$dest[res$success], ]
    manifest <<- dplyr::bind_rows(manifest[!manifest$dest %in% ok_rows$dest, ], ok_rows)
    res
  })

  aoi_georef_manifest_write(manifest)

  readr::write_csv(georef_results, aoi_path("georef_log", id))

  # --- Fold failures back into the ledger ---------------------------------

  # Recompute the outcome for every frame this run covered, rather than only
  # marking failures. fly_georef() reports success for an output that already
  # exists, so a frame that failed once and succeeds on a re-run would otherwise
  # keep georef_failed in the ledger and the report for ever — the ledger only
  # ever moved toward failure and never back.
  ok <- georef_results$airp_id[georef_results$success]
  failed <- georef_results$airp_id[!georef_results$success]
  ledger$rejected_reason[ledger$airp_id %in% ok] <- "selected"
  ledger$rejected_reason[ledger$airp_id %in% failed] <- "georef_failed"

  aoi_ledger_write(ledger, id)
  aoi_report_write(ledger, id)

  message(sum(georef_results$success), "/", nrow(georef_results),
          " thumbnails georeferenced")
}
