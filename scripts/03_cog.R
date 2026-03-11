# 03_cog.R — convert georeferenced TIFFs to Cloud-Optimized GeoTIFFs

library(terra)

# --- Find georeferenced TIFFs -------------------------------------------

georef_dir <- file.path("data", "raw", "georef", "thumbs")
stac_dir <- file.path("data", "stac", "bc-airphoto", "thumbs")

georef_files <- list.files(georef_dir, pattern = "\\.tif$",
                           recursive = TRUE, full.names = TRUE)

message(length(georef_files), " georeferenced TIFFs found")

# --- Convert to COG ------------------------------------------------------
# Nodata already handled by fly_thumb_georef():
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

readr::write_csv(results, "data/cog_log.csv")

message(
  sum(results$success & !results$skipped), " converted, ",
  sum(results$skipped), " skipped, ",
  sum(!results$success), " failed"
)
