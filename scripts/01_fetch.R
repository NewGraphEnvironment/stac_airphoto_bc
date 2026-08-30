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

# --- Config ---------------------------------------------------------------

BCDC_CENTROIDS <- "0af7544c-f2ad-4553-bb37-889c94d4c571"  # AIMG_PHOTO_CENTROIDS_SP
FETCH_BUFFER_M <- 8000    # film footprints are km wide; buffer before querying
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
    aoi_buf <- sf::st_buffer(aoi, FETCH_BUFFER_M)

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

  message(nrow(window), " frames in the ", FETCH_BUFFER_M / 1000, " km window")

  # --- Rotation, computed where the rolls are still intact ----------------
  # Must happen on the whole window, before any filtering. See aoi_rotation().

  window$rotation <- aoi_rotation(fly::fly_bearing(window)$bearing)

  # --- Footprint basis, for the ledger ------------------------------------
  # Digital frames come back "unknown_format" with an empty geometry, which
  # every sf predicate then quietly answers FALSE for.

  window$footprint_basis <- fly::fly_footprint(window)$footprint_basis

  # --- Candidates: footprint overlaps the AOI -----------------------------

  cand_ids <- fly::fly_filter(window, aoi, method = "footprint")$airp_id

  ledger <- window |>
    sf::st_drop_geometry() |>
    dplyr::transmute(
      aoi_id = id,
      airp_id, film_roll, frame_number,
      photo_year = year, era, footprint_basis, rotation,
      thumbnail_image_url,
      rejected_reason = dplyr::case_when(
        !is.na(footprint_basis) &
          footprint_basis == "unknown_format" ~ "digital_unknown_format",
        !airp_id %in% cand_ids                ~ "footprint_misses_aoi",
        is.na(thumbnail_image_url)            ~ "no_thumbnail_url",
        TRUE                                  ~ "selected"
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
