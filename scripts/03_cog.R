# 03_cog.R — convert georeferenced TIFFs to Cloud-Optimized GeoTIFFs

library(terra)

# --- Find georeferenced TIFFs -------------------------------------------

georef_dir <- file.path("data", "raw", "georef", "thumbs")
stac_dir <- file.path("data", "stac", "thumbs")

georef_files <- list.files(georef_dir, pattern = "\\.tif$",
                           recursive = TRUE, full.names = TRUE)

message(length(georef_files), " georeferenced TIFFs found")

# --- Convert to COG ------------------------------------------------------
# Nodata already handled by fly_georef():
#   - Grayscale: nodata=0
#   - RGB: alpha band (band 4) masks black border
# COGs use DEFLATE compression and internal tiling.

results <- purrr::map_dfr(georef_files, function(src) {
  # Preserve year/ subdirectory structure
  rel <- sub(paste0(georef_dir, "/"), "", src)
  dst <- file.path(stac_dir, rel)

  if (file.exists(dst)) {
    return(tibble::tibble(source = src, dest = dst, success = TRUE, skipped = TRUE))
  }

  dir.create(dirname(dst), recursive = TRUE, showWarnings = FALSE)

  tryCatch({
    r <- terra::rast(src)
    terra::writeRaster(r, dst, filetype = "COG",
                       gdal = c("COMPRESS=DEFLATE", "OVERVIEW_RESAMPLING=NEAREST"),
                       overwrite = TRUE)
    tibble::tibble(source = src, dest = dst, success = TRUE, skipped = FALSE)
  }, error = function(e) {
    warning("Failed: ", src, " — ", conditionMessage(e))
    tibble::tibble(source = src, dest = dst, success = FALSE, skipped = FALSE)
  })
})

# The COG stage is global — it converts every georeferenced TIFF on disk
# regardless of which AOI produced it — so its log is global too.
dir.create(file.path("data", "logs"), recursive = TRUE, showWarnings = FALSE)
readr::write_csv(results, file.path("data", "logs", "cog_log.csv"))

message(
  sum(results$success & !results$skipped), " converted, ",
  sum(results$skipped), " skipped, ",
  sum(!results$success), " failed"
)

# --- Embed metadata tags via Python/rasterio ------------------------------
# terra can't persist custom GDAL metadata tags; rasterio can.
# Tags: airp_id, photo_date, scale, film_roll, frame_number, focal_length, flying_height.

message("\nEmbedding metadata tags...")
# stop(), not warning(): Rscript exits 0 on a warning, so `set -euo pipefail`
# in run_pipeline.sh would not catch it and the pipeline would go on to register
# and publish untagged COGs. --no-capture-output so the Python error is visible
# rather than buffered away.
exit_code <- system(
  "conda run --no-capture-output -n stac-airphoto-bc python scripts/03_cog_tag.py"
)
if (exit_code != 0) {
  stop("Metadata tagging failed with exit code ", exit_code, call. = FALSE)
}
