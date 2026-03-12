# 04_s3_upload.R — sync COGs to S3

bucket <- "stac-airphoto-bc"
local_dir <- file.path("data", "stac")

if (!dir.exists(local_dir)) {
  stop("No COGs found at ", local_dir, " — run 03_cog.R first")
}

# --- Sync to S3 -----------------------------------------------------------
# aws s3 sync uploads only new/changed files.
# Local data/stac/ mirrors bucket root: thumbs/{year}/*.tif

cmd <- sprintf(
  "aws s3 sync %s s3://%s --exclude '.*' --size-only",
  local_dir, bucket
)

message("Running: ", cmd)
exit_code <- system(cmd)

if (exit_code != 0) {
  stop("S3 sync failed with exit code ", exit_code)
}

message("Sync complete")
