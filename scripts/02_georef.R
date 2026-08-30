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

  # `rotation` was computed in 01_fetch.R over the whole fetch window, where
  # the film rolls are still intact. Passing it here stops fly_georef() from
  # recomputing bearings on this thinned set, where a frame whose roll
  # neighbour was filtered out would silently fall back to a fixed 180.
  if (!"rotation" %in% names(selected)) {
    stop("Selected set for '", id, "' has no `rotation` column — ",
         "re-run 01_fetch.R.", call. = FALSE)
  }

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

  # --- Georeference per year ----------------------------------------------
  # Output: data/raw/georef/thumbs/{year}/*.tif (BC Albers 3005), global and
  # year-partitioned so an overlapping AOI reuses rather than duplicates.

  years <- sort(unique(
    selected$year[selected$airp_id %in% fetch_result$airp_id]
  ))

  georef_results <- purrr::map_dfr(years, function(yr) {
    ids_yr <- selected$airp_id[selected$year == yr]
    fr <- dplyr::filter(fetch_result, airp_id %in% ids_yr)
    ph <- dplyr::filter(selected, airp_id %in% fr$airp_id)

    if (nrow(fr) == 0) return(tibble::tibble())

    message("  georeferencing ", nrow(fr), " thumbnails for ", yr)
    fly::fly_georef(
      fr, ph,
      dest_dir = file.path("data", "raw", "georef", "thumbs", yr),
      rotation = "auto"
    )
  })

  readr::write_csv(georef_results, aoi_path("georef_log", id))

  # --- Fold failures back into the ledger ---------------------------------

  ledger <- readr::read_csv(aoi_path("ledger", id), show_col_types = FALSE)

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
