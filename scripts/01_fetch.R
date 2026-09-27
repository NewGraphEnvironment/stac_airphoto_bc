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
prov <- aoi_provenance()

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

  # --- Roll neighbours: a bearing is a fact about the roll, not the window --
  # fly_bearing() takes a frame's heading from the NEXT frame on its roll, or the
  # previous one when the next is absent from the set it is handed. A frame near
  # the edge of the spatial window therefore got a heading that depended on which
  # AOI's window it was in: measured on se_a and se_b, 74 of 669 shared frames had
  # bearings up to ~2 degrees apart, so the same photograph would be georeferenced
  # two ways (fly 0.15.0, 2026-09-26). Padding every window frame with its +/-1
  # neighbours from the catalogue makes the heading depend on the catalogue alone.
  # The neighbours are sized and handed to fly_georef() but never selected, and the
  # ledger does not count them (`in_window`).

  nbr_cache <- aoi_path("neighbours", id)
  rolls <- sort(unique(stats::na.omit(window$film_roll)))
  cached_rolls <- if (file.exists(nbr_cache)) {
    unique(arrow::read_parquet(nbr_cache, col_select = "film_roll")$film_roll)
  } else character()

  # Refetched with the window: a neighbour cache older than the centroid cache is
  # from an earlier catalogue snapshot, and would pair new centroids with old ones.
  stale_nbr <- file.exists(nbr_cache) && file.mtime(nbr_cache) < file.mtime(cache)
  if (FORCE_REFRESH || stale_nbr || !all(rolls %in% cached_rolls)) {
    batches <- split(rolls, ceiling(seq_along(rolls) / 40))
    ref <- arrow::read_parquet(cache)
    roll_rows <- purrr::map_dfr(batches, function(b) {
      x <- bcdata::bcdc_query_geodata(BCDC_CENTROIDS) |>
        bcdata::filter(FILM_ROLL %in% !!b) |>
        bcdata::collect()
      names(x) <- tolower(names(x))
      aoi_match_types(as.data.frame(sf::st_drop_geometry(x)), ref)
    })
    missing_rolls <- setdiff(rolls, roll_rows$film_roll)
    if (length(missing_rolls)) {
      stop("The catalogue returned no frames for roll(s) ",
           paste(missing_rolls, collapse = ", "), " that the window holds.",
           call. = FALSE)
    }
    tmp <- paste0(nbr_cache, ".tmp")
    arrow::write_parquet(roll_rows, tmp)
    if (!file.rename(tmp, nbr_cache)) stop("Could not write ", nbr_cache, call. = FALSE)
    message("Cached ", nrow(roll_rows), " frames of ", length(rolls), " rolls to ", nbr_cache)
  }

  roll_rows <- arrow::read_parquet(nbr_cache)
  frame_key <- function(r, f) paste(r, suppressWarnings(as.numeric(f)))
  wanted <- c(frame_key(window$film_roll, as.numeric(window$frame_number) + 1),
              frame_key(window$film_roll, as.numeric(window$frame_number) - 1))
  nbr <- roll_rows[frame_key(roll_rows$film_roll, roll_rows$frame_number) %in% wanted &
                     !roll_rows$airp_id %in% window$airp_id, ]
  window$in_window <- TRUE
  if (nrow(nbr)) {
    nbr <- aoi_centroids_as_sf(nbr)
    nbr$year <- as.integer(nbr$photo_year)
    nbr$era <- aoi_era(nbr$year)
    nbr$in_window <- rep(FALSE, nrow(nbr))
    window <- rbind(window, nbr[, names(window)])
  }

  message(nrow(nbr), " roll neighbours added outside the window")

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
  window$footprint_digest <- aoi_footprint_digest(fp)

  # --- Rotation and placement, per frame, from the measured tables (#23) ---
  # Rotation is a per-roll scanning constant: the measured value where the roll
  # was measured, the series default otherwise, NA for digital (fly measured
  # that corner mapping itself). See aoi_rotation_for().
  #
  # Placement is a per-frame translation in EPSG:3005 metres, applied to the
  # georeferenced raster in 03_cog.py — never to the centroids here, because fly
  # takes each film frame's bearing from its neighbours' centroids and uneven
  # shifts would turn frames, including uncorrected ones. A frame absent from the
  # table is outside the measured rolls and stays where the catalogue puts it.

  rot <- aoi_rotation_for(window$media, window$footprint_terrain,
                          window$film_roll, window$year)
  window$rotation        <- rot$rotation
  window$rotation_source <- rot$rotation_source
  film <- !is.na(window$media) & grepl("^Film", window$media)

  placement <- aoi_placement_table()
  hit <- match(as.character(window$airp_id), placement$airp_id)
  window$placement_source <- ifelse(is.na(hit), "none", placement$placement_source[hit])
  window$shift_x_m_3005   <- ifelse(is.na(hit), 0, placement$shift_x_m_3005[hit])
  window$shift_y_m_3005   <- ifelse(is.na(hit), 0, placement$shift_y_m_3005[hit])

  # --- Candidates: footprint overlaps the AOI -----------------------------
  # An empty footprint answers FALSE to every predicate, so an unsized frame
  # cannot become a candidate here — it is classified as `no_footprint` below
  # rather than silently as a miss.

  cand_ids <- window$airp_id[window$in_window &
    lengths(sf::st_intersects(fp, sf::st_transform(aoi, sf::st_crs(fp)))) > 0
  ]

  # The union (#23): every frame already published is rebuilt, whether or not the
  # DEM-corrected footprint still reaches the AOI, so no published item keeps the
  # old geometry. Recorded as `selection_basis`, a column of its own, because
  # 02_georef.R rewrites `rejected_reason` and would erase a reason-coded basis.
  published_ids <- aoi_published_ids()

  ledger <- window[window$in_window, ] |>
    sf::st_drop_geometry() |>
    dplyr::transmute(
      aoi_id = id,
      airp_id, film_roll, frame_number,
      photo_year = year, era, footprint_basis,
      footprint_terrain, width_source, footprint_bearing,
      height_agl, dem_coverage, height_source,
      dem_shortfall_m, dem_elev_sd,
      rotation, rotation_source,
      placement_source, shift_x_m_3005, shift_y_m_3005,
      thumbnail_image_url,
      selection_basis = dplyr::case_when(
        airp_id %in% cand_ids                        ~ "footprint",
        as.character(airp_id) %in% published_ids     ~ "published",
        TRUE                                         ~ NA_character_
      ),
      # Keyed on `footprint_terrain` being absent, which fly sets exactly where
      # the geometry is empty. It used to key on `footprint_basis ==
      # "unknown_format"`, a string fly stopped writing for these frames once it
      # could size digital ones — after which an unsized frame fell through to
      # `footprint_misses_aoi` and was reported as "sized, but missing the AOI"
      # for a frame that was never sized.
      #
      # `no_bearing`: a frame with no adjacent roll neighbour in the window gets
      # an axis-aligned ring. A per-roll rotation on that ring places a film
      # picture as though the aircraft flew due north, and fly's own fallback
      # draws a digital one north-up at 180. Withheld rather than written
      # possibly turned.
      rejected_reason = dplyr::case_when(
        is.na(footprint_terrain)                ~ "no_footprint",
        is.na(selection_basis)                  ~ "footprint_misses_aoi",
        is.na(footprint_bearing)                ~ "no_bearing",
        is.na(thumbnail_image_url)              ~ "no_thumbnail_url",
        TRUE                                    ~ "selected"
      )
    )

  sel_ids <- ledger$airp_id[ledger$rejected_reason == "selected"]

  # A selected film frame with no rotation is a roll of a series the default
  # does not cover (aoi_rotation_default()). Handing fly NA sends it to fly's
  # refusal, and guessing ships a quarter turn — so stop and name the rolls.
  norot <- window$airp_id %in% sel_ids & film & is.na(window$rotation)
  if (any(norot)) {
    stop(sum(norot), " selected film frame(s) have no rotation, on roll(s) ",
         paste(sort(unique(window$film_roll[norot])), collapse = ", "),
         ". Measure the roll, or extend aoi_rotation_default() deliberately.",
         call. = FALSE)
  }

  # A footprint hanging off the DEM is sized from the part that is covered. fly
  # reports how far the DEM would have to reach (`dem_shortfall_m`, fly 0.14.0);
  # any shortfall on a selected frame means the cached DEM is too small for this
  # window, and the cache would otherwise be reused on every run.
  short <- window$dem_shortfall_m[window$airp_id %in% sel_ids]
  if (any(short > 0, na.rm = TRUE)) {
    stop(sum(short > 0, na.rm = TRUE), " selected frame(s) reach up to ",
         round(max(short, na.rm = TRUE)), " m past the DEM for '", id, "'. ",
         "Delete ", aoi_path("dem", id), " and raise aoi_dem_corner() before re-running.",
         call. = FALSE)
  }

  if (!length(sel_ids)) {
    stop("No frames selected for AOI '", id,
         "' — nothing to fetch. Check the AOI and the fetch buffer.",
         call. = FALSE)
  }

  selected <- window[window$airp_id %in% sel_ids, ]
  arrow::write_parquet(sf::st_drop_geometry(selected), aoi_path("selected", id))

  # The whole window too, rotation and placement included. 02_georef.R hands
  # fly_georef() these frames rather than the selected set, so the rolls are
  # intact and the bearing fly derives is the one this ledger records (#28).
  for (k in names(prov)) window[[k]] <- prov[[k]]
  arrow::write_parquet(sf::st_drop_geometry(window), aoi_path("window", id))

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
