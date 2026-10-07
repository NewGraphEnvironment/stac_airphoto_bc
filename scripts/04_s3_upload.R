# 04_s3_upload.R — back up the published collection, then sync to S3
#
# Runs AFTER 05_stac_register.py, so the item JSONs and collection.json that
# 05_stac_register.py just wrote are included. It used to run before, which meant a
# run's own STAC output was never uploaded by that run.

BUCKET <- "stac-airphoto-bc"
LOCAL_DIR <- file.path("data", "stac")

if (!dir.exists(LOCAL_DIR)) {
  stop("No COGs found at ", LOCAL_DIR, " — run 03_cog.py first.", call. = FALSE)
}

run <- function(cmd) {
  message("Running: ", cmd)
  code <- system(cmd)
  if (code != 0) stop("Command failed with exit code ", code, ": ", cmd,
                      call. = FALSE)
  invisible(code)
}

# --- Refuse to upload anything that does not check out ---------------------
# The checksums, the named provenance set, the tags against the properties and
# the COG layout, recomputed from the bytes on disk immediately before they are
# uploaded (#30). 05_stac_register.py runs the same checks, but a publish can come
# days after it, and a file touched in between would otherwise ship with a
# checksum that describes something else.

run("uv run --locked python scripts/stac_validate.py")

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

# --- ... and every item JSON, because the sync replaces them in place --------
# Versioning on this bucket is Suspended, so a replaced object is gone. The COGs
# are deliberately not backed up (#30: known-wrong before #23, and rebuildable
# from fly v0.3.0 and the openmaps JPGs); the item JSONs are the record of what
# was published, and they are small. `backup/` is excluded so it never copies
# into itself, and the count is checked against the collection's item links.
items_key <- sprintf("backup/items-%s/", stamp)
run(sprintf(paste0("aws s3 cp s3://%s/ s3://%s/%s --recursive --only-show-errors ",
                   "--exclude '*' --include '*.json' --exclude 'backup/*' ",
                   "--exclude 'collection.json'"),
            BUCKET, BUCKET, items_key))

published <- jsonlite::fromJSON(sprintf("data/backup/collection-%s.json", stamp))
n_links <- sum(published$links$rel == "item")
n_copied <- length(system(sprintf("aws s3 ls s3://%s/%s", BUCKET, items_key),
                          intern = TRUE))
if (n_copied < n_links) {
  stop("Item backup holds ", n_copied, " JSONs for ", n_links, " published item ",
       "links; refusing to overwrite them. Backup at s3://", BUCKET, "/", items_key,
       call. = FALSE)
}
message(n_copied, " item JSONs backed up to s3://", BUCKET, "/", items_key)

# --- Sync ------------------------------------------------------------------
# Two passes, because the comparison that is right for one is wrong for the
# other. No --delete in either: this pipeline extends the collection and must
# never be able to remove a published object.

# COGs: size and mtime, not --size-only. A COG's content is NOT immutable for a
# filename — the #23 rebuild replaces every published one under the same name —
# and a rebuilt COG of the same byte count would be skipped with no error.
# 03_cog.py replaces a file only when its bytes change, so an unchanged COG keeps
# its mtime and is not re-uploaded. SHA-256 is recorded on each object so what
# arrived can be checked against the item's file:checksum.
run(sprintf(
  "aws s3 sync %s s3://%s --exclude '.*' --exclude '*' --include '*.tif' --checksum-algorithm SHA256",
  LOCAL_DIR, BUCKET
))

# JSON: --size-only would skip a regenerated item whose content changed but
# whose byte count did not — a title, a property, a corrected href. Let the
# default size-and-timestamp comparison run.
run(sprintf(
  "aws s3 sync %s s3://%s --exclude '.*' --exclude '*' --include '*.json'",
  LOCAL_DIR, BUCKET
))

# --- What arrived is what was checked ---------------------------------------
# A sample, not all 10k: head-object per COG is one request each. S3 reports the
# object's SHA-256 base64-encoded; the item carries it as a hex multihash.
items <- list.files(LOCAL_DIR, pattern = "^[0-9]+\\.json$", full.names = TRUE)
set.seed(as.integer(format(Sys.time(), "%H%M%S")))
compared <- 0L
for (f in sample(items, min(20L, length(items)))) {
  a <- jsonlite::fromJSON(f)$assets$thumbnail
  key <- sub(sprintf("^https://%s\\.s3\\.[^/]+/", BUCKET), "", a$href)
  key <- utils::URLdecode(key)
  h <- jsonlite::fromJSON(paste(system(sprintf(
    "aws s3api head-object --bucket %s --key %s --checksum-mode ENABLED",
    BUCKET, shQuote(key)), intern = TRUE), collapse = "\n"))
  # An object above the CLI's multipart threshold (8 MB) carries a checksum of
  # its parts' checksums, written "<base64>-<N>", which no whole-file hash can
  # match. Thumbnails are under 6 MB, so this is reported rather than guessed at.
  if (is.null(h$ChecksumSHA256) || grepl("-[0-9]+$", h$ChecksumSHA256)) {
    message("  ", key, ": no whole-object SHA-256 on S3 (multipart or none); not compared")
    next
  }
  got <- paste0("1220", paste(as.character(jsonlite::base64_dec(h$ChecksumSHA256)),
                              collapse = ""))
  if (!identical(got, a[["file:checksum"]])) {
    stop("S3 object ", key, " has SHA-256 ", got, " but its item says ",
         a[["file:checksum"]], call. = FALSE)
  }
  compared <- compared + 1L
}
message("Checked ", compared, " uploaded COGs against their items")

message("Sync complete")
