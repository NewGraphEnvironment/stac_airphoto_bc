# 01_fetch.R — select and fetch thumbnails for one or more AOIs
#
# Usage:
#   Rscript scripts/01_fetch.R              # every registered AOI
#   Rscript scripts/01_fetch.R se_a se_b    # named AOIs only
#
# The AOI used to be two constants at the top of this file (issue #16). It is
# now an id looked up in scripts/aoi.R, and an unknown id aborts before any
# work starts.

suppressPackageStartupMessages({
  library(sf)
  library(dplyr)
  library(arrow)
  library(fly)
  library(bcdata)
})

source("scripts/aoi.R")

aoi_require_fly()

# --- Config ---------------------------------------------------------------

BCDC_CENTROIDS <- "0af7544c-f2ad-4553-bb37-889c94d4c571"  # AIMG_PHOTO_CENTROIDS_SP
FETCH_WORKERS  <- 6
FORCE_REFRESH  <- FALSE   # TRUE re-queries the catalogue for the named AOIs

ids <- aoi_ids()

# Output trees are global and year-partitioned, not per-AOI: S3 is laid out by
# year, items are keyed by airp_id, and two AOIs 2 km apart share frames.
dir.create(file.path("data", "raw", "thumbs"), recursive = TRUE,
           showWarnings = FALSE)

message("AOIs to process: ", paste(ids, collapse = ", "))

for (id in ids) {
  message("\n=== ", id, " — ", aoi_label(id), " ===")

  aoi <- aoi_resolve(id)
  sf::st_write(aoi, aoi_path("aoi", id), delete_dsn = TRUE, quiet = TRUE)

  # --- Query the catalogue (cached per AOI) -------------------------------
  # Cached without geometry; every stage rebuilds points from longitude and
  # latitude, so a cache hit and a cache miss give identical geometry.

  cache <- aoi_path("centroids", id)

  if (FORCE_REFRESH || !file.exists(cache)) {
    aoi_buf <- sf::st_buffer(aoi, aoi_fetch_buffer())

    raw <- bcdata::bcdc_query_geodata(BCDC_CENTROIDS) |>
      bcdata::filter(INTERSECTS(aoi_buf)) |>
      bcdata::collect()

    names(raw) <- tolower(names(raw))  # WFS returns uppercase

    # Write via a temp file: a redirect truncates its target before the command
    # runs, so an interrupted query would otherwise leave a zero-byte parquet
    # that the file.exists() guard blesses on every future run.
    tmp <- paste0(cache, ".tmp")
    raw |> sf::st_drop_geometry() |> arrow::write_parquet(tmp)
    file.rename(tmp, cache)

    message("Cached ", nrow(raw), " centroids to ", cache)
  }

  window <- aoi_centroids_as_sf(arrow::read_parquet(cache))
  window$year <- as.integer(window$photo_year)
  window$era <- aoi_era(window$year)

  message(nrow(window), " frames in the ", aoi_fetch_buffer() / 1000, " km window")

  # --- Footprints, built once ---------------------------------------------
  # One call, and its whole result is kept. This line used to read
  #
  #   window$footprint_basis <- fly::fly_footprint(window)$footprint_basis
  #
  # which threw away `footprint_terrain`, `height_agl` and `dem_coverage` — the
  # three columns that make terrain handling auditable — so they could not reach
  # the ledger even on a fly that returned them correctly (#20).
  #
  # `fly_filter()` is deliberately not used below. It builds its OWN footprints
  # internally (fly/R/fly_filter.R:50), so selecting with it would leave two
  # derivations of one fact free to disagree — the ledger describing one set of
  # footprints while selection ran on another — and would make the DEM's
  # two-pass sampling run twice over /vsicurl/. The intersection it performs is
  # the one line below it.

  dem <- aoi_dem(id, build = TRUE)

  fp <- fly::fly_footprint(window, dem = dem)
  aoi_check_footprint_cols(fp)

  # The four assignments below are BY POSITION, and `cand_ids` maps rows of `fp`
  # onto ids of `window`. A reorder or a dropped row would misalign every column
  # and name the wrong frames, and a same-length reorder is invisible to R and to
  # the column check above. True today by fly's construction — it assigns
  # attributes onto the input object and returns it — which is exactly why it is
  # worth one line here rather than a note somewhere.
  stopifnot(nrow(fp) == nrow(window), identical(fp$airp_id, window$airp_id))

  for (col in aoi_footprint_cols()) window[[col]] <- fp[[col]]

  # --- Rotation, film only, where the rolls are still intact --------------
  # Must happen on the whole window, before any filtering. See aoi_rotation().
  #
  # Supplied only where fly has NOT already rotated the ring, and only for film
  # — see aoi_rotation_ok(). A `rotation` is the highest-precedence input in
  # fly_georef(): on a digital frame it overrides the corner mapping fly
  # measured, and on a rotated film frame it DISARMS fly's refusal to guess a
  # per-roll constant. Measured on se_c, 807 of 810 film frames now fall to
  # fly's refusal and land as `georef_failed`, which is the honest outcome until
  # #23 supplies the measured table.

  rot_ok <- aoi_rotation_ok(window$media, window$footprint_terrain,
                            window$footprint_bearing)

  window$rotation <- aoi_rotation(fly::fly_bearing(window)$bearing)
  window$rotation[!rot_ok] <- NA_integer_

  # --- Candidates: footprint overlaps the AOI -----------------------------
  # An empty footprint answers FALSE to every predicate, so an unsized frame
  # cannot become a candidate here — it is classified as `no_footprint` below
  # rather than silently as a miss.

  cand_ids <- window$airp_id[
    lengths(sf::st_intersects(fp, sf::st_transform(aoi, sf::st_crs(fp)))) > 0
  ]

  ledger <- window |>
    sf::st_drop_geometry() |>
    dplyr::transmute(
      aoi_id = id,
      airp_id, film_roll, frame_number,
      photo_year = year, era, footprint_basis,
      footprint_terrain, width_source, footprint_bearing,
      height_agl, dem_coverage, rotation,
      thumbnail_image_url,
      # Keyed on `footprint_terrain` being absent, which fly sets exactly where
      # the geometry is empty. It used to key on `footprint_basis ==
      # "unknown_format"`, a string fly stopped writing for these frames once it
      # could size digital ones — after which an unsized frame fell through to
      # `footprint_misses_aoi` and was reported as "sized, but missing the AOI"
      # for a frame that was never sized.
      rejected_reason = dplyr::case_when(
        is.na(footprint_terrain)   ~ "no_footprint",
        !airp_id %in% cand_ids     ~ "footprint_misses_aoi",
        is.na(thumbnail_image_url) ~ "no_thumbnail_url",
        TRUE                       ~ "selected"
      )
    )

  sel_ids <- ledger$airp_id[ledger$rejected_reason == "selected"]

  if (!length(sel_ids)) {
    stop("No frames selected for AOI '", id,
         "' — nothing to fetch. Check the AOI and the fetch buffer.",
         call. = FALSE)
  }

  selected <- window[window$airp_id %in% sel_ids, ]
  arrow::write_parquet(sf::st_drop_geometry(selected), aoi_path("selected", id))

  message(nrow(selected), " frames selected across ",
          dplyr::n_distinct(selected$year), " years")

  # --- Fetch thumbnails, partitioned by year ------------------------------
  # fly_fetch(overwrite = FALSE) skips files already on disk, so a frame shared
  # by two AOIs is downloaded once.

  years <- sort(unique(selected$year))

  fetch_results <- purrr::map_dfr(years, function(yr) {
    photos <- dplyr::filter(selected, year == yr)
    message("  fetching ", nrow(photos), " thumbnails for ", yr)
    fly::fly_fetch(
      photos,
      type = "thumbnail",
      dest_dir = file.path("data", "raw", "thumbs", yr),
      workers = FETCH_WORKERS
    )
  })

  readr::write_csv(fetch_results, aoi_path("fetch_log", id))

  failed <- fetch_results$airp_id[!fetch_results$success]
  ledger$rejected_reason[ledger$airp_id %in% failed] <- "fetch_failed"

  aoi_ledger_write(ledger, id)
  aoi_report_write(ledger, id)

  message(sum(fetch_results$success), "/", nrow(fetch_results),
          " thumbnails downloaded — report at ", aoi_path("report", id))
}
