# 04_s3_upload.R — back up the published collection, then sync to S3
#
# Runs AFTER 05_stac_register.py, so the item JSONs and collection.json that
# registration just wrote are included. It used to run before, which meant a
# run's own STAC output was never uploaded by that run.

BUCKET <- "stac-airphoto-bc"
LOCAL_DIR <- file.path("data", "stac")

if (!dir.exists(LOCAL_DIR)) {
  stop("No COGs found at ", LOCAL_DIR, " — run 03_cog.R first.", call. = FALSE)
}

run <- function(cmd) {
  message("Running: ", cmd)
  code <- system(cmd)
  if (code != 0) stop("Command failed with exit code ", code, ": ", cmd,
                      call. = FALSE)
  invisible(code)
}

# --- Back up collection.json before anything overwrites it -----------------
# Every other object in the bucket is reproducible from the pipeline or already
# duplicated locally. collection.json is not: it is the only record of which
# items are published, and the sync overwrites it wholesale.

# Timestamped, not date-only. With a date key the second run of a day backs up
# the collection the FIRST run published — so if run 1 published a damaged
# collection, run 2 overwrites the last good copy with the damaged one, in both
# S3 and data/backup/, and the thing this block exists to protect is gone.
stamp <- format(Sys.time(), "%Y%m%dT%H%M%S")
backup_key <- sprintf("backup/collection-%s.json", stamp)

run(sprintf("aws s3 cp s3://%s/collection.json s3://%s/%s",
            BUCKET, BUCKET, backup_key))

dir.create(file.path("data", "backup"), recursive = TRUE, showWarnings = FALSE)
run(sprintf("aws s3 cp s3://%s/collection.json data/backup/collection-%s.json",
            BUCKET, stamp))

message("Published collection backed up to s3://", BUCKET, "/", backup_key)

# --- Sync ------------------------------------------------------------------
# Two passes, because the comparison that is right for one is wrong for the
# other. No --delete in either: this pipeline extends the collection and must
# never be able to remove a published object.

# COGs: content is immutable for a given filename, and they are large, so
# comparing size alone avoids re-uploading gigabytes on every run.
run(sprintf(
  "aws s3 sync %s s3://%s --exclude '.*' --exclude '*' --include '*.tif' --size-only",
  LOCAL_DIR, BUCKET
))

# JSON: --size-only would skip a regenerated item whose content changed but
# whose byte count did not — a title, a property, a corrected href. Let the
# default size-and-timestamp comparison run.
run(sprintf(
  "aws s3 sync %s s3://%s --exclude '.*' --exclude '*' --include '*.json'",
  LOCAL_DIR, BUCKET
))

message("Sync complete")
