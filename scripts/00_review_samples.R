# 00_review_samples.R — sample and inspect thumbnails across years
#
# Downloads 1-2 random thumbnails per year (if not already on disk),
# reports band count, datatype, dimensions, and pixel stats.
# Reusable for any AOI — just swap the parquet cache and AOI.

library(sf)
library(dplyr)
library(arrow)
library(fly)
library(terra)

n_per_year <- 2
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

# --- Sample n per year ---------------------------------------------------

set.seed(seed)
samples <- centroids |>
  dplyr::group_by(year) |>
  dplyr::slice_sample(n = n_per_year) |>
  dplyr::ungroup()

message("Sampled ", nrow(samples), " photos across ", n_distinct(samples$year), " years")

# --- Fetch samples -------------------------------------------------------

dest_dir <- "data/raw/thumbs/samples"

fetch_result <- fly::fly_fetch(
  samples,
  type = "thumbnail",
  dest_dir = dest_dir,
  workers = 6
)

# --- Inspect each thumbnail ----------------------------------------------

inspect <- purrr::map_dfr(seq_len(nrow(fetch_result)), function(i) {
  fr <- fetch_result[i, ]
  if (!fr$success || !file.exists(fr$dest)) {
    return(tibble::tibble(
      airp_id = fr$airp_id, year = NA_integer_, file = fr$dest,
      bands = NA, datatype = NA, width = NA, height = NA,
      min_val = NA, max_val = NA, mean_val = NA, note = "fetch failed"
    ))
  }

  r <- terra::rast(fr$dest)
  g <- terra::global(r[[1]], c("min", "max", "mean"), na.rm = TRUE)
  yr <- samples$year[samples$airp_id == fr$airp_id][1]

  tibble::tibble(
    airp_id = fr$airp_id,
    year = yr,
    file = basename(fr$dest),
    bands = terra::nlyr(r),
    datatype = terra::datatype(r),
    width = terra::ncol(r),
    height = terra::nrow(r),
    min_val = round(g$min, 1),
    max_val = round(g$max, 1),
    mean_val = round(g$mean, 1),
    note = dplyr::case_when(
      terra::nlyr(r) == 1 ~ "grayscale",
      terra::nlyr(r) == 3 ~ "RGB",
      terra::nlyr(r) == 4 ~ "RGBA",
      TRUE ~ paste0(terra::nlyr(r), " bands")
    )
  )
})

# --- Report ---------------------------------------------------------------

message("\n--- Thumbnail inspection ---")
inspect |>
  dplyr::arrange(year) |>
  print(n = 50)

message("\n--- Summary by type ---")
inspect |>
  dplyr::count(note, bands, datatype, width, height) |>
  print()
