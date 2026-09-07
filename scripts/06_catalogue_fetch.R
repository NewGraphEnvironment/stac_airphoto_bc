# 06_catalogue_fetch.R — catalogue rows for every item already published
#
# Usage:
#   Rscript scripts/06_catalogue_fetch.R
#   Rscript scripts/06_catalogue_fetch.R --limit 500   # smoke test
#
# Writes data/catalogue/published.parquet, which 06_catalogue_backfill.py reads.
#
# Why this exists at all
# ----------------------
# 01_fetch.R caches a catalogue row per AOI, keyed by an AOI polygon. That is the
# right shape for a run, and the wrong one for a backfill: `data/` is gitignored,
# so the 9,741 Neexdzii Kwa rows are gone from this machine along with their
# COGs, and only the published item JSONs on S3 remain.
#
# Rows are therefore fetched by `airp_id` rather than by re-resolving the AOI.
# Two reasons, and the second is the one that matters:
#
#   * `neexdzii_kwa` is `type = "watershed"`, so aoi_resolve() needs
#     fresh::frs_db_conn() and a live Postgres host. Querying by id drops that
#     dependency entirely.
#   * a published item's id IS its `airp_id`, so the set of ids is an exact
#     denominator. Re-resolving a polygon answers "what is in this area now",
#     which is a different question and cannot be reconciled against what was
#     published — a footprint estimate that has since moved would silently
#     change the membership.

suppressPackageStartupMessages({
  library(dplyr)
  library(arrow)
  library(bcdata)
  library(jsonlite)
})

# --- Config ---------------------------------------------------------------

BCDC_CENTROIDS <- "0af7544c-f2ad-4553-bb37-889c94d4c571"  # AIMG_PHOTO_CENTROIDS_SP
COLLECTION_URL <- "https://stac-airphoto-bc.s3.us-west-2.amazonaws.com/collection.json"
OUT_DIR        <- file.path("data", "catalogue")
OUT_PATH       <- file.path(OUT_DIR, "published.parquet")

# 500 ids per request. Measured against the live service: 200, 500 and 1000 all
# return exactly what was asked for, in 1.2-1.6 s. 500 keeps the CQL filter well
# inside any URL length limit while costing only 20 requests for the whole
# collection, and it makes a truncated batch small enough to see.
BATCH_SIZE <- 500
MAX_TRIES  <- 3

args <- commandArgs(trailingOnly = TRUE)
limit <- NA_integer_
if ("--limit" %in% args) {
  limit <- suppressWarnings(as.integer(args[which(args == "--limit") + 1L]))
  if (is.na(limit) || limit < 1L) {
    stop("--limit needs a positive integer.", call. = FALSE)
  }
}

# --- Item ids from the published collection --------------------------------

message("Reading ", COLLECTION_URL)
collection <- jsonlite::fromJSON(COLLECTION_URL, simplifyVector = FALSE)

hrefs <- vapply(
  Filter(function(l) identical(l$rel, "item"), collection$links),
  function(l) l$href, character(1)
)

# An item id is the href's basename without its extension, URL-decoded — the
# same derivation 05_stac_register.py::link_id() uses, so the two agree about
# what an id is even if the href format moves again.
ids_chr <- sub("\\.[^.]*$", "", basename(utils::URLdecode(hrefs)))
ids <- suppressWarnings(as.integer(ids_chr))

if (anyNA(ids)) {
  stop("Item id(s) that are not integers: ",
       paste(utils::head(ids_chr[is.na(ids)], 10), collapse = ", "),
       call. = FALSE)
}
if (anyDuplicated(ids)) {
  stop("Duplicate item ids in the published collection — the merge in ",
       "05_stac_register.py keys by id and should make that impossible.",
       call. = FALSE)
}

message(length(ids), " published item id(s)")

if (!is.na(limit)) {
  ids <- utils::head(ids, limit)
  message("--limit ", limit, ": querying ", length(ids), " of them")
}

# --- Query the catalogue in batches ----------------------------------------

fetch_batch <- function(batch) {
  for (try_n in seq_len(MAX_TRIES)) {
    out <- try(
      bcdata::bcdc_query_geodata(BCDC_CENTROIDS) |>
        bcdata::filter(AIRP_ID %in% batch) |>
        bcdata::collect(),
      silent = TRUE
    )
    if (!inherits(out, "try-error")) return(out)
    message("    attempt ", try_n, " failed: ",
            trimws(substr(as.character(out), 1, 120)))
    if (try_n < MAX_TRIES) Sys.sleep(2 * try_n)
  }
  stop("Batch failed after ", MAX_TRIES, " attempts.", call. = FALSE)
}

batches <- split(ids, ceiling(seq_along(ids) / BATCH_SIZE))
message("Querying in ", length(batches), " batch(es) of up to ", BATCH_SIZE)

rows <- vector("list", length(batches))

for (i in seq_along(batches)) {
  batch <- batches[[i]]
  raw <- fetch_batch(batch)
  names(raw) <- tolower(names(raw))
  raw <- sf::st_drop_geometry(raw)

  # Reconcile per batch, not only at the end. A service that silently truncates
  # a response returns a well-formed 200 whose missing rows read as "absent from
  # the catalogue" rather than "not sent" — the same shape as a paged API's
  # default limit. Catching it here names the batch; catching it at the end
  # names 9,976 ids and says nothing about which request went wrong.
  got <- unique(raw$airp_id)
  short <- setdiff(batch, got)
  if (length(short)) {
    message("  batch ", i, ": asked ", length(batch), ", got ", length(got),
            " — ", length(short), " missing")
  } else {
    message("  batch ", i, "/", length(batches), ": ", nrow(raw), " rows")
  }
  rows[[i]] <- raw
}

catalogue <- dplyr::bind_rows(rows) |> dplyr::distinct(airp_id, .keep_all = TRUE)

# --- Reconcile against the denominator -------------------------------------

missing <- setdiff(ids, catalogue$airp_id)
extra   <- setdiff(catalogue$airp_id, ids)

message("\nRequested ", length(ids), " id(s); catalogue returned ",
        nrow(catalogue))

if (length(extra)) {
  stop("Catalogue returned ", length(extra), " id(s) that were not asked for — ",
       "the filter is not doing what it appears to. First few: ",
       paste(utils::head(extra, 10), collapse = ", "), call. = FALSE)
}

if (length(missing)) {
  stop(
    length(missing), " published item id(s) have no catalogue row: ",
    paste(utils::head(missing, 20), collapse = ", "),
    if (length(missing) > 20) ", ..." else "",
    "\nEvery published id came FROM this catalogue, so this is upstream drift, ",
    "not an expected state. Refusing rather than writing a parquet the backfill ",
    "would silently skip those items with.",
    call. = FALSE
  )
}

# --- The cross-tab the issue rests on --------------------------------------
# #21 states georef_metadata_ind and patb_georef_url are exactly equivalent,
# measured on a cross-tab that came out perfectly diagonal. That was 2,671 rows
# from three small AOIs. Measure it over the whole published collection and print
# it — a claim carried forward from a subset is not a measurement of the
# population.

xtab <- table(
  georef_metadata_ind = catalogue$georef_metadata_ind,
  has_patb_url = !is.na(catalogue$patb_georef_url),
  useNA = "ifany"
)
message("\ngeoref_metadata_ind x patb_georef_url present, all ", nrow(catalogue),
        " rows:")
print(xtab)

off_diagonal <- sum(catalogue$georef_metadata_ind == "Y" &
                      is.na(catalogue$patb_georef_url), na.rm = TRUE) +
  sum(catalogue$georef_metadata_ind == "N" &
        !is.na(catalogue$patb_georef_url), na.rm = TRUE)
message("off-diagonal rows: ", off_diagonal)

unrecognised <- sum(!catalogue$georef_metadata_ind %in% c("Y", "N") |
                      is.na(catalogue$georef_metadata_ind))
message("georef_metadata_ind neither Y nor N: ", unrecognised)

# --- Write ------------------------------------------------------------------
# Via a temp file: a redirect or an interrupted write leaves a zero-byte parquet
# that a later file.exists() guard would bless.

dir.create(OUT_DIR, recursive = TRUE, showWarnings = FALSE)
tmp <- paste0(OUT_PATH, ".tmp")
arrow::write_parquet(catalogue, tmp)
invisible(file.rename(tmp, OUT_PATH))

message("\nWrote ", nrow(catalogue), " rows x ", ncol(catalogue),
        " cols to ", OUT_PATH)
