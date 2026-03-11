# 02_georef.R — georeference thumbnails to estimated ground footprints

library(sf)
library(dplyr)
library(arrow)
library(fly)

# --- Load filtered centroids (same filter logic as 01_fetch.R) -----------

centroids_raw <- arrow::read_parquet("data/centroids_raw.parquet") |>
  sf::st_as_sf(coords = c("longitude", "latitude"), crs = 4326) |>
  sf::st_transform(3005)

aoi <- fresh::frs_watershed_at_measure(
  blue_line_key = 360873822,
  downstream_route_measure = 166030.4
) |> sf::st_transform(3005)

centroids <- fly::fly_filter(centroids_raw, aoi, method = "footprint") |>
  dplyr::mutate(year = as.integer(photo_year))

# --- Build fetch result from files on disk -------------------------------
# Reconstruct what fly_fetch() would have returned by scanning data/raw/thumbs/

thumb_files <- list.files("data/raw/thumbs", pattern = "\\.jpg$",
                          recursive = TRUE, full.names = TRUE)

fetch_result <- tibble::tibble(
  airp_id = centroids$airp_id[match(
    basename(thumb_files),
    basename(centroids$thumbnail_image_url)
  )],
  dest = thumb_files,
  success = TRUE
) |> tidyr::drop_na(airp_id)

message(nrow(fetch_result), " thumbnails on disk")

# --- Georeference per year ----------------------------------------------
# Output: data/raw/georef/thumbs/{year}/*.tif (BC Albers 3005)
# fly_thumb_georef(overwrite = FALSE) skips existing files.

years <- sort(unique(centroids$year[centroids$airp_id %in% fetch_result$airp_id]))

georef_results <- purrr::map_dfr(years, function(yr) {
  ids <- centroids$airp_id[centroids$year == yr]
  fr <- dplyr::filter(fetch_result, airp_id %in% ids)
  ph <- dplyr::filter(centroids, airp_id %in% fr$airp_id)

  if (nrow(fr) == 0) return(tibble::tibble())

  message("Georeferencing ", nrow(fr), " thumbnails for ", yr)
  fly::fly_thumb_georef(
    fr, ph,
    dest_dir = file.path("data", "raw", "georef", "thumbs", yr)
  )
})

readr::write_csv(georef_results, "data/georef_log.csv")

message(
  sum(georef_results$success), "/", nrow(georef_results),
  " thumbnails georeferenced"
)
