# test_pipeline.R — end-to-end test of fetch → georef → COG → S3 → STAC
#
# Runs a sample of n photos through the full pipeline.
# Use to validate after changes to fly, directory layout, or STAC schema.

library(sf)
library(dplyr)
library(arrow)
library(fly)

n_test <- 100
seed <- 42

# --- Load centroids from cache -------------------------------------------

centroids_raw <- arrow::read_parquet("data/centroids_raw.parquet") |>
  sf::st_as_sf(coords = c("longitude", "latitude"), crs = 4326) |>
  sf::st_transform(3005)

aoi <- fresh::frs_watershed_at_measure(
  blue_line_key = 360873822,
  downstream_route_measure = 166030.4
) |> sf::st_transform(3005)

centroids <- fly::fly_filter(centroids_raw, aoi, method = "footprint") |>
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
  fly::fly_thumb_georef(
    fr, ph,
    dest_dir = file.path("data", "raw", "georef", "thumbs", yr)
  )
})
message("Georeffed: ", sum(georef_results$success), "/", nrow(georef_results))

# --- 03: COG -------------------------------------------------------------

message("\n=== COG ===")
source("scripts/03_cog.R")

# --- 04: S3 upload --------------------------------------------------------

message("\n=== S3 UPLOAD ===")
source("scripts/04_s3_upload.R")

# --- 05: STAC register ----------------------------------------------------

message("\n=== STAC REGISTER ===")
exit_code <- system("conda run -n stac-airphoto-bc python scripts/05_stac_register.py")
if (exit_code != 0) warning("STAC registration failed")

# --- Summary --------------------------------------------------------------

message("\n=== SUMMARY ===")
message("Fetched:    ", sum(fetch_results$success), "/", nrow(fetch_results))
message("Georeffed:  ", sum(georef_results$success), "/", nrow(georef_results))

cog_count <- length(list.files("data/stac/thumbs", pattern = "\\.tif$", recursive = TRUE))
json_count <- length(list.files("data/stac", pattern = "\\.json$"))
message("COGs:       ", cog_count)
message("STAC items: ", json_count - 1, " + collection")
