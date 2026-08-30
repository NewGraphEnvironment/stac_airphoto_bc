# 00_review_samples.R — sample and inspect thumbnails across years
#
# Usage:
#   Rscript scripts/00_review_samples.R              # every registered AOI
#   Rscript scripts/00_review_samples.R se_a         # named AOIs only
#
# Downloads a couple of thumbnails per year and reports band count, datatype,
# dimensions and pixel stats. Samples land in data/raw/samples/, deliberately
# OUTSIDE data/raw/thumbs/ — 02_georef.R scans that tree recursively and matches
# on basename, so a sample sharing a filename with a real fetch would be
# georeferenced twice and duplicate its row in the log.

suppressPackageStartupMessages({
  library(sf)
  library(dplyr)
  library(arrow)
  library(fly)
  library(terra)
})

source("scripts/aoi.R")

N_PER_YEAR <- 2
SEED <- 42

ids <- aoi_ids()

for (id in ids) {
  message("\n=== ", id, " — ", aoi_label(id), " ===")

  cache <- aoi_path("centroids", id)
  if (!file.exists(cache)) {
    stop("No centroid cache for '", id, "' at ", cache,
         " — run 01_fetch.R first.", call. = FALSE)
  }

  aoi <- aoi_resolve(id)

  centroids <- aoi_centroids_as_sf(arrow::read_parquet(cache)) |>
    (\(x) fly::fly_filter(x, aoi, method = "footprint"))() |>
    dplyr::mutate(year = as.integer(photo_year)) |>
    dplyr::filter(!is.na(thumbnail_image_url))

  set.seed(SEED)
  samples <- centroids |>
    dplyr::group_by(year) |>
    dplyr::slice_sample(n = N_PER_YEAR) |>
    dplyr::ungroup()

  message("Sampled ", nrow(samples), " photos across ",
          dplyr::n_distinct(samples$year), " years")

  fetch_result <- fly::fly_fetch(
    samples,
    type = "thumbnail",
    dest_dir = file.path("data", "raw", "samples", id),
    workers = 6
  )

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

    tibble::tibble(
      airp_id = fr$airp_id,
      year = samples$year[samples$airp_id == fr$airp_id][1],
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

  message("\n--- Thumbnail inspection: ", id, " ---")
  inspect |> dplyr::arrange(year) |> print(n = 50)

  message("\n--- Summary by type ---")
  inspect |> dplyr::count(note, bands, datatype, width, height) |> print()
}
