# 01_fetch.R — fetch airphoto centroids and thumbnails for Neexdzii Kwa watershed

library(sf)
library(dplyr)
library(arrow)
library(fresh)
library(fly)
library(bcdata)

# --- AOI: Neexdzii Kwa watershed ----------------------------------------

blk <- 360873822
drm <- 166030.4

aoi <- frs_watershed_at_measure(
  blue_line_key = blk,
  downstream_route_measure = drm
)

aoi_3005 <- sf::st_transform(aoi, 3005)
sf::st_write(aoi, "data/aoi.gpkg", delete_dsn = TRUE)

# --- Query BC Data Catalogue (cached) ------------------------------------
# The WFS query is expensive (paginated). Cache raw results as parquet.
# Re-run with force_refresh = TRUE to pick up newly catalogued photos.

cache_path <- "data/centroids_raw.parquet"
force_refresh <- FALSE

if (force_refresh || !file.exists(cache_path)) {
  aoi_buf <- sf::st_buffer(aoi_3005, 8000)

  centroids_raw <- bcdata::bcdc_query_geodata("0af7544c-f2ad-4553-bb37-889c94d4c571") |>
    bcdata::filter(INTERSECTS(aoi_buf)) |>
    bcdata::collect()

  # WFS returns uppercase column names — lowercase for fly compatibility
  names(centroids_raw) <- tolower(names(centroids_raw))

  # Cache without geometry (lat/lon columns preserved for re-deriving points)
  centroids_raw |>
    sf::st_drop_geometry() |>
    arrow::write_parquet(cache_path)

  message("Cached ", nrow(centroids_raw), " centroids to ", cache_path)
} else {
  # Rebuild sf from cached parquet
  centroids_raw <- arrow::read_parquet(cache_path) |>
    sf::st_as_sf(coords = c("longitude", "latitude"), crs = 4326) |>
    sf::st_transform(3005)

  message("Loaded ", nrow(centroids_raw), " centroids from cache")
}

# --- Precise filter (re-runs every time with current footprint estimates) -

centroids <- fly::fly_filter(centroids_raw, aoi_3005, method = "footprint")

# --- Add year column for directory partitioning --------------------------

centroids <- centroids |>
  dplyr::mutate(year = as.integer(photo_year))

message(
  nrow(centroids), " photos across ",
  dplyr::n_distinct(centroids$year), " years"
)

# --- Fetch thumbnails partitioned by year --------------------------------
# Raw JPGs go to data/raw/thumbs/{year}/.
# Final COGs go to data/stac/bc-airphoto/thumbs/{year}/ at the COG step.
# fly_fetch(overwrite = FALSE) skips existing files on disk.

years <- sort(unique(centroids$year))

fetch_results <- purrr::map_dfr(years, function(yr) {
  photos <- dplyr::filter(centroids, year == yr)
  message("Fetching ", nrow(photos), " thumbnails for ", yr)
  fly::fly_fetch(
    photos,
    type = "thumbnail",
    dest_dir = file.path("data", "raw", "thumbs", yr),
    workers = 6
  )
})

readr::write_csv(fetch_results, "data/fetch_log.csv")

message(
  sum(fetch_results$success), "/", nrow(fetch_results),
  " thumbnails downloaded"
)
