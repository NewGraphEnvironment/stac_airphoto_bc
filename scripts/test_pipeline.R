# test_pipeline.R — end-to-end test of fetch → georef → COG → S3 → STAC
#
# Usage:
#   Rscript scripts/test_pipeline.R              # first registered AOI
#   Rscript scripts/test_pipeline.R se_a         # a named AOI
#
# Runs a sample of n photos from one AOI through the full pipeline.
# Use to validate after changes to fly, directory layout, or STAC schema.

library(sf)
library(dplyr)
library(arrow)
library(fly)

source("scripts/aoi.R")

n_test <- 100
seed <- 42

id <- aoi_ids()[1]
message("Test AOI: ", id, " — ", aoi_label(id))

# --- Load the selected set 01_fetch.R wrote ------------------------------

sel_path <- aoi_path("selected", id)
if (!file.exists(sel_path)) {
  stop("No selected set for '", id, "' — run 01_fetch.R first.", call. = FALSE)
}

centroids <- aoi_centroids_as_sf(arrow::read_parquet(sel_path)) |>
  dplyr::mutate(year = as.integer(photo_year)) |>
  dplyr::filter(!is.na(thumbnail_image_url))

# --- Sample across years -------------------------------------------------

set.seed(seed)
test_set <- centroids |>
  dplyr::group_by(year) |>
  dplyr::slice_sample(n = 3) |>
  dplyr::ungroup() |>
  dplyr::slice_head(n = n_test)

message(
  "Test set: ", nrow(test_set), " photos across ",
  dplyr::n_distinct(test_set$year), " years"
)

years <- sort(unique(test_set$year))

# --- 01: Fetch ------------------------------------------------------------

message("\n=== FETCH ===")
fetch_results <- purrr::map_dfr(years, function(yr) {
  photos <- dplyr::filter(test_set, year == yr)
  message("  ", yr, ": ", nrow(photos), " photos")
  fly::fly_fetch(
    photos, type = "thumbnail",
    dest_dir = file.path("data", "raw", "thumbs", yr),
    workers = 6
  )
})
message("Fetched: ", sum(fetch_results$success), "/", nrow(fetch_results))

# --- 02: Georef ----------------------------------------------------------

message("\n=== GEOREF ===")
georef_results <- purrr::map_dfr(years, function(yr) {
  ids <- test_set$airp_id[test_set$year == yr]
  fr <- dplyr::filter(fetch_results, airp_id %in% ids, success)
  ph <- dplyr::filter(test_set, airp_id %in% fr$airp_id)
  if (nrow(fr) == 0) return(tibble::tibble())
  message("  ", yr, ": ", nrow(fr), " photos")
  fly::fly_georef(
    fr, ph,
    dest_dir = file.path("data", "raw", "georef", "thumbs", yr),
    rotation = "auto"
  )
})
message("Georeffed: ", sum(georef_results$success), "/", nrow(georef_results))

# --- 03: COG -------------------------------------------------------------

message("\n=== COG ===")
source("scripts/03_cog.R")

# --- 04: STAC register ----------------------------------------------------
# Before the upload, not after — the sync must carry the item JSONs and
# collection.json this run just wrote. stop() rather than warning(), so a failed
# registration cannot fall through to publishing whatever is on disk.

message("\n=== STAC REGISTER ===")
exit_code <- system(
  "conda run --no-capture-output -n stac-airphoto-bc python scripts/05_stac_register.py"
)
if (exit_code != 0) {
  stop("STAC registration failed with exit code ", exit_code, call. = FALSE)
}

# --- 05: S3 upload --------------------------------------------------------

message("\n=== S3 UPLOAD ===")
source("scripts/04_s3_upload.R")

# --- Summary --------------------------------------------------------------

message("\n=== SUMMARY ===")
message("Fetched:    ", sum(fetch_results$success), "/", nrow(fetch_results))
message("Georeffed:  ", sum(georef_results$success), "/", nrow(georef_results))

cog_count <- length(list.files("data/stac/thumbs", pattern = "\\.tif$", recursive = TRUE))
json_count <- length(list.files("data/stac", pattern = "\\.json$"))
message("COGs:       ", cog_count)
message("STAC items: ", json_count - 1, " + collection")
