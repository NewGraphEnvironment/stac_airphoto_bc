# aoi.R — AOI registry, resolver, and per-AOI output paths
#
# Sourced by every pipeline stage. The AOI used to be three edited constants
# (issue #16); it is now an entry in `aoi_registry()` selected by id.
#
# Usage from a stage script:
#   source("scripts/aoi.R")
#   ids <- aoi_ids()                  # command-line args, or all registered
#   aoi <- aoi_resolve("se_a")        # sf POLYGON in EPSG:3005
#
# What is per-AOI and what is shared:
#   per-AOI   centroid cache, AOI polygon, selected set, logs, reports
#   shared    data/raw/thumbs/{year}/, data/raw/georef/, data/stac/
#
# The shared half is deliberate. S3 is laid out by year, not by AOI, and items
# are keyed by `airp_id` across the whole collection — so two AOIs that overlap
# share a photo rather than fetching it twice, and the COG-scanning stages
# (03_cog.py, 04_s3_upload.R, 05_stac_register.py) stay AOI-agnostic.

# --- What fly must be able to do ------------------------------------------

#' Refuse a fly that cannot carry a DEM through to selection
#'
#' A capability check rather than a version comparison, and deliberately so.
#' Issue #20 as filed prescribed a floor of fly 0.6.0; it was written on the day
#' 0.6.0 shipped and four releases landed in the week that followed, so the
#' number was stale before the work started. A version literal here has to be
#' re-derived every time fly moves, and the run where nobody re-derives it is the
#' one that matters.
#'
#' What this pipeline actually needs is that `dem` reaches all three functions
#' that size a footprint. `fly_footprint()` is not enough on its own: selection
#' is `fly_filter()`, which builds its own footprints, and `fly_georef()` builds
#' a third set — so a DEM that reached only one of them would correct footprints
#' nothing selects on, or publish a GeoTIFF whose footprint disagrees with the
#' one that selected it.
#'
#' The other capability — that `fly_footprint()` returns its reporting columns,
#' `height_source` among them (fly 0.12.0, fly#54) — is checked in `01_fetch.R` at
#' the call itself by `aoi_check_footprint_cols()`. A formal is not evidence a
#' column comes back.
#'
#' `fns` is injectable so the refusing branch is reachable in tests without a
#' second fly installed.
aoi_require_fly <- function(fns = NULL) {
  if (is.null(fns)) {
    fns <- list(
      fly_filter    = names(formals(fly::fly_filter)),
      fly_footprint = names(formals(fly::fly_footprint)),
      fly_georef    = names(formals(fly::fly_georef))
    )
  }

  # An empty or unnamed list must not pass. `names(NULL)` is NULL and
  # `vapply()` over an empty list is `logical(0)`, so without this the guard
  # falls straight through to `invisible(TRUE)` — reporting a fly it never
  # looked at as capable, which is the one direction that costs something.
  wanted <- c("fly_filter", "fly_footprint", "fly_georef")
  if (!is.list(fns) || !all(wanted %in% names(fns))) {
    stop("aoi_require_fly() needs the formals of ",
         paste(wanted, collapse = ", "), "; got ",
         if (is.list(fns) && length(fns)) {
           paste(names(fns), collapse = ", ")
         } else {
           "nothing"
         }, ".", call. = FALSE)
  }

  # Every function reported, not just the first missing one: a caller who fixes
  # the one name in the message and re-runs, only to be refused again for the
  # next, learns the guard's shape one round-trip at a time.
  missing <- wanted[!vapply(fns[wanted], function(f) "dem" %in% f, logical(1))]

  if (length(missing)) {
    stop(
      "This fly cannot carry a DEM through to selection: ",
      paste0(missing, "()", collapse = ", "),
      if (length(missing) > 1) " take" else " takes",
      " no `dem` argument.\n",
      "Install the latest fly. 0.5.0 added `dem`, and the rebuild (#23) also ",
      "needs 0.12.0's `flying_height` check (fly#54), which ",
      "aoi_check_footprint_cols() asserts through `height_source`:\n",
      "  remotes::install_github(\"NewGraphEnvironment/fly\")",
      call. = FALSE
    )
  }

  invisible(TRUE)
}

#' Columns `fly_footprint()` must return
#'
#' fly#35 dropped the reporting columns whenever the input carried the `tbl_df`
#' class, which is exactly what `bcdata::collect()` returns. Geometry and every
#' number stayed correct, so nothing failed — only the audit trail went missing,
#' which is the expensive kind of silence. Fixed in fly 0.5.1; asserted here
#' because a formal is not evidence a column comes back.
#'
#' The set is fly's, and it grows: `width_source` arrived in 0.6.0,
#' `footprint_bearing` in 0.9.0, `height_source` in 0.12.0 (whether a reported
#' `flying_height` was believed, repaired for the fly#54 unit slip, or refused), and
#' `dem_shortfall_m` / `dem_elev_sd` in 0.14.0. `tests/test_aoi.R` compares this
#' set with what the installed fly actually adds, in both directions, so a new
#' column is a failing test rather than one nobody declared.
#'
#' `height_source` is also the capability the rebuild needs: a fly without it sizes
#' the 13 slipped rolls at ~110 km under a DEM, so its absence aborts here.
aoi_footprint_cols <- function() {
  c("footprint_basis", "footprint_terrain", "width_source",
    "footprint_bearing", "height_agl", "dem_coverage",
    "height_source", "dem_shortfall_m", "dem_elev_sd")
}

#' fly's DEM coverage warning threshold
#'
#' A fact about fly, not a contract this repo chose. `fly_dem_coverage_min()` is
#' internal and not exported, so it is copied here rather than called — and
#' **pinned** against fly in `tests/test_aoi.R`, which may reach through `fly:::`
#' where production code should not. A copy with a pin is a stamped literal; a
#' copy without one goes stale invisibly.
#'
#' **Source:** `fly/R/fly_footprint.R:176`, `fly_dem_coverage_min() <- 0.95`,
#' read 2026-09-07 against fly 0.10.0. Used only in report prose; nothing
#' branches on it.
aoi_dem_coverage_min <- function() 0.95

#' Terrain routes fly is known to emit
#'
#' A positive control on fly's vocabulary. `aoi_rotation_for()` and the report
#' both read `footprint_terrain`, and a guard keyed on a value fly might rename
#' fails toward *pass* — silently, on the arm that matters. Refusing an
#' unrecognised value turns that into an abort naming the value, so a new fly
#' sizing route is a loud stop rather than a quiet mis-classification.
#'
#' Like the threshold above this is fly's fact, not ours, and it is pinned in
#' `tests/test_aoi.R` against `fly_footprint()`'s own source. `dem_agl` and
#' `no_dem_coverage` are emitted only under a DEM, so no run and no fixture can
#' corroborate them when `aoi_dem_enabled()` is FALSE — reading them out of fly
#' is the check that reaches them on every machine, cache or not.
aoi_terrain_values <- function() {
  c("nominal_scale", "gsd_scaled", "dem_agl", "no_dem_coverage")
}

aoi_check_footprint_cols <- function(fp) {
  missing <- setdiff(aoi_footprint_cols(), names(fp))
  if (length(missing)) {
    stop(
      "fly_footprint() returned no ", paste(missing, collapse = ", "), ".\n",
      "Either this fly predates the column (height_source arrived in 0.12.0, ",
      "dem_shortfall_m and dem_elev_sd in 0.14.0), or it is fly#35, which drops ",
      "the columns on the `tbl_df` input bcdata::collect() returns (fixed in ",
      "0.5.1). Install the latest fly:\n",
      "  remotes::install_github(\"NewGraphEnvironment/fly\")",
      call. = FALSE
    )
  }
  invisible(fp)
}

#' The measured tables the rebuild reads (#23)
#'
#' Imported from the private `stac_orthophoto_bc` repo by
#' `data-raw/tables_import-georef_validate.R`, which stamps the source commit on
#' line 1 of each file. Read here, not in each stage, so the path and the comment
#' convention live in one place.
aoi_rotation_table <- function(path = "data-raw/rotation_roll.csv") {
  x <- utils::read.csv(path, comment.char = "#", colClasses = "character")
  x$rotation <- as.integer(x$rotation)
  x
}

aoi_placement_table <- function(path = "data-raw/placement_frame.csv") {
  x <- utils::read.csv(path, comment.char = "#", colClasses = "character")
  x$shift_x_m_3005 <- as.numeric(x$shift_x_m_3005)
  x$shift_y_m_3005 <- as.numeric(x$shift_y_m_3005)
  x
}

#' Film rolls of the old `bc5xxx` series, flown 1975-76
#'
#' The three measured rolls in this bin disagree — two at 90, one at 180 — so no
#' default fits them. They take 90 and every one is listed for review by eye.
aoi_rotation_needs_review <- function(film_roll, year) {
  !is.na(film_roll) & grepl("^bc5[0-9]{3}$", film_roll) &
    !is.na(year) & year %in% c(1975L, 1976L)
}

#' The scanning rotation for a film roll nobody measured
#'
#' Follows the roll **series**, not the decade (stac_orthophoto_bc research §14).
#' A first rule set it by decade and the placement review proved it wrong for
#' `bc5420`, `bc5440` and `bc5688`, 1970s rolls of the older series. Over the 67
#' known rolls:
#'
#'   | series                             | 0  | 90 | 180 | default          |
#'   |------------------------------------|----|----|-----|------------------|
#'   | `bc5xxx`, through 1974             | 11 | 0  | 0   | 0                |
#'   | `bc5xxx`, 1975-76                  | 0  | 2  | 1   | 90, review each  |
#'   | every other (`bc7xxx` on, bcb, bcc)| 0  | 53 | 0   | 90               |
#'
#' Anything else — a `bc5xxx` roll outside those years, a series this table has
#' never seen — is `NA`, not a guess. `01_fetch.R` refuses to select a film frame
#' left `NA`, so an unknown series stops the run on the frames that matter rather
#' than shipping a quarter turn. A wrong default is at least visible: 90 degrees
#' off, not subtly wrong.
aoi_rotation_default <- function(film_roll, year) {
  year <- as.integer(year)
  old  <- !is.na(film_roll) & grepl("^bc5[0-9]{3}$", film_roll)
  new  <- !is.na(film_roll) & grepl("^(bc[6-9][0-9]{3,}|bcb[0-9]+|bcc[0-9]+)$", film_roll)
  out  <- rep(NA_integer_, length(film_roll))
  out[old & !is.na(year) & year <= 1974L] <- 0L
  out[aoi_rotation_needs_review(film_roll, year)] <- 90L
  out[new] <- 90L
  out
}

#' Rotation, and where it came from, for every frame in a window
#'
#' Replaces the per-frame bearing guess (`aoi_rotation()`, fixed-180 fallback)
#' and the mask that withheld it (`aoi_rotation_ok()`). The scanning rotation is a
#' per-roll constant: `fly_georef()` refuses a bearing-rotated film frame without
#' one, because the corner mapping records how the negative was scanned and no
#' frame reveals it. A user `rotation` column is fly's highest-precedence input, so
#' supplying one disarms that refusal — which is now correct, because the value is
#' a measured or series-assumed per-roll constant rather than a per-frame guess.
#'
#' - **film** — the roll's measured value (`measured` or `reviewed`), else the
#'   series default (`assumed_by_series`), else `NA`.
#' - **digital** — `NA` with no source. fly measured the digital corner mapping three
#'   independent ways, and a supplied value would override it.
#'
#' Returns a data frame with `rotation` and `rotation_source`, one row per input.
aoi_rotation_for <- function(media, footprint_terrain, film_roll, photo_year,
                             table = aoi_rotation_table()) {
  # NULL and character(0) are different states and only one of them is legal. A
  # frame set with no rows gives an empty result, which is right. A frame set with
  # no `media` COLUMN gives NULL, and every frame would then be classified digital
  # and handed no rotation, which sends every film frame to fly's refusal with
  # nothing saying why.
  if (is.null(media) || is.null(film_roll)) {
    stop("`media` or `film_roll` is absent, so film frames cannot be told from ",
         "digital ones and no per-roll rotation can be looked up. Re-run ",
         "01_fetch.R, or re-query the centroid cache with FORCE_REFRESH = TRUE.",
         call. = FALSE)
  }

  film <- !is.na(media) & grepl("^Film", media)

  # An unrecognised terrain route means fly has changed under us. Abort rather
  # than classify on a string this code has never seen.
  seen <- stats::na.omit(unique(footprint_terrain))
  unknown <- setdiff(seen, aoi_terrain_values())
  if (length(unknown)) {
    stop("fly returned unrecognised `footprint_terrain` value(s): ",
         paste(unknown, collapse = ", "), ".\n",
         "Known: ", paste(aoi_terrain_values(), collapse = ", "), ". ",
         "The rotation assignment and the report both key on this vocabulary, so ",
         "a new sizing route has to be read before it is classified.",
         call. = FALSE)
  }

  # One fact, two sources: the catalogue says what the medium was and fly says
  # which route sized it. Film by the catalogue and GSD-sized by fly means one of
  # the two is wrong, and guessing which is how a quarter-turn error ships.
  clash <- film & !is.na(footprint_terrain) & footprint_terrain == "gsd_scaled"
  if (any(clash)) {
    stop(
      sum(clash), " frame(s) are film by the catalogue's `media` but were ",
      "sized by fly's digital GSD route. Which rotation applies cannot be ",
      "decided for them, and a wrong one georeferences the picture a quarter ",
      "turn out with nothing downstream reporting it.",
      call. = FALSE
    )
  }

  hit <- match(film_roll, table$film_roll)
  measured <- film & !is.na(hit)
  default  <- aoi_rotation_default(film_roll, photo_year)
  assumed  <- film & is.na(hit) & !is.na(default)

  rotation <- rep(NA_integer_, length(media))
  source   <- rep(NA_character_, length(media))
  rotation[measured] <- table$rotation[hit[measured]]
  source[measured]   <- table$rotation_source[hit[measured]]
  rotation[assumed]  <- default[assumed]
  source[assumed]    <- "assumed_by_series"

  data.frame(rotation = rotation, rotation_source = source)
}

#' Which fly and which commit of this pipeline produced a run (#30)
#'
#' Stamped on every window row by `01_fetch.R`, carried into the COG tags by
#' `03_cog.py` and onto the items by `05_stac_register.py`, so a published frame
#' names the code that sized and placed it. A dirty tree is recorded as
#' `<commit>-dirty-<digest of the uncommitted change>` (scripts/pipeline_sha.sh),
#' so two different uncommitted states never share a label.
#'
#' The fly SHA is the one pak or remotes recorded at install; a fly installed
#' from a local checkout has none, and that is refused rather than published
#' as a version string alone.
aoi_provenance <- function() {
  d <- utils::packageDescription("fly")
  fly_remote <- d$RemoteSha
  if (is.null(fly_remote) || !nzchar(fly_remote)) {
    stop("The installed fly records no RemoteSha, so the items could not name the ",
         "fly that built them. Install it from GitHub:\n",
         "  pak::pak(\"NewGraphEnvironment/fly\")", call. = FALSE)
  }
  # One definition, shared with 03_cog.py: scripts/pipeline_sha.sh.
  sha <- system2("bash", "scripts/pipeline_sha.sh", stdout = TRUE)
  if (!is.null(attr(sha, "status")) || length(sha) != 1L || !nzchar(sha)) {
    stop("scripts/pipeline_sha.sh did not report a commit.", call. = FALSE)
  }
  list(
    fly_version  = as.character(d$Version),
    fly_sha      = substr(fly_remote, 1, 12),
    pipeline_sha = sha
  )
}

#' Every item id the published collection carries
#'
#' From `data/catalogue/published.parquet`, the catalogue rows `06_catalogue_fetch.R`
#' keyed to the live `collection.json`. One snapshot, read by every AOI, so the
#' union 01_fetch.R selects on is the same set in every AOI. Refused when absent:
#' without it the union silently becomes "new selection only".
aoi_published_ids <- function(path = "data/catalogue/published.parquet") {
  if (!file.exists(path)) {
    stop("No published-id snapshot at ", path, ". Run 06_catalogue_fetch.R, which ",
         "keys it to the live collection.json.", call. = FALSE)
  }
  as.character(arrow::read_parquet(path, col_select = "airp_id")$airp_id)
}

#' A digest of each footprint ring, the raster's shape on the ground
#'
#' Size, position and bearing in one value: a rebuilt DEM, a refreshed catalogue
#' row or a new fly build that moves a footprint changes it, and float noise does
#' not (EPSG:3005 coordinates rounded to the centimetre, all positive in BC, so no
#' negative zero). `01_fetch.R` stamps it on the window, `02_georef.R` asserts the
#' footprints it hands fly_georef() reproduce it and records it in the manifest,
#' and `03_cog.py` refuses a GeoTIFF whose recorded digest is not the window's.
#' `NA` for an empty footprint.
aoi_footprint_digest <- function(fp) {
  fp <- sf::st_transform(fp, 3005)
  vapply(seq_len(nrow(fp)), function(i) {
    xy <- sf::st_coordinates(sf::st_geometry(fp)[i])
    if (!nrow(xy)) return(NA_character_)
    digest::digest(paste(sprintf("%.2f", xy[, c("X", "Y"), drop = FALSE]), collapse = ","),
                   algo = "sha256", serialize = FALSE)
  }, character(1))
}

#' What each GeoTIFF on disk was written from
#'
#' `fly_georef(overwrite = FALSE)` reuses any GeoTIFF already at its path, which
#' is right for an unchanged frame and wrong for one whose rotation, bearing or
#' fly build has moved, or whose footprint ring has (a digest of it, so a rebuilt
#' DEM or refreshed catalogue row that leaves the bearing alone still counts), or
#' whose source JPG or the pipeline commit that ran 02 has — 02 chooses
#' fly_georef()'s arguments and the frames it is handed, so its commit shapes
#' the pixels too.
#' `02_georef.R` records the inputs here on every write and
#' regenerates a GeoTIFF whose recorded inputs differ; `03_cog.py` refuses a
#' GeoTIFF the manifest does not vouch for. Global, like the tree it describes.
aoi_georef_manifest_path <- function() file.path("data", "raw", "georef", "manifest.csv")

aoi_georef_manifest_read <- function() {
  empty <- tibble::tibble(dest = character(), airp_id = character(),
                          rotation = integer(), footprint_bearing = double(),
                          footprint_digest = character(), fly_sha = character(),
                          pipeline_sha = character(), source = character(),
                          source_md5 = character())
  path <- aoi_georef_manifest_path()
  if (!file.exists(path)) return(empty)
  m <- readr::read_csv(path, col_types = readr::cols(.default = "c"),
                       show_col_types = FALSE)
  # By name, never by position. A manifest from before a column was added reads
  # with that column NULL, every comparison in 02 goes zero-length, nothing is
  # regenerated, and the manifest is then rewritten vouching for the old raster.
  if (!identical(names(m), names(empty))) {
    stop("Georef manifest at ", path, " has columns ", paste(names(m), collapse = ", "),
         "; expected ", paste(names(empty), collapse = ", "), ". Delete it: every ",
         "GeoTIFF is then regenerated on the next 02_georef.R.", call. = FALSE)
  }
  m$rotation <- as.integer(m$rotation)
  m$footprint_bearing <- as.numeric(m$footprint_bearing)
  m
}

aoi_georef_manifest_write <- function(manifest) {
  path <- aoi_georef_manifest_path()
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  manifest$airp_id <- as.character(manifest$airp_id)
  tmp <- paste0(path, ".tmp")
  readr::write_csv(manifest[order(manifest$dest), ], tmp, na = "")
  if (!file.rename(tmp, path)) stop("Could not write ", path, call. = FALSE)
  invisible(manifest)
}

#' Cast a catalogue query's columns to a reference frame's types, losing nothing
#'
#' The WFS types each response on its own contents, so a page or batch whose
#' `ground_sample_distance` is all null arrives as character beside another where
#' it is integer, and `bind_rows()` refuses (measured on the Neexdzii Kwa roll
#' query, 2026-09-27). The centroid cache is the reference. A value that turns NA
#' in the cast was not NA before is data being dropped, so that aborts rather than
#' passing quietly.
aoi_match_types <- function(x, ref) {
  for (col in intersect(names(x), names(ref))) {
    cls <- class(ref[[col]])[1]
    if (identical(class(x[[col]])[1], cls)) next
    before <- x[[col]]
    after <- switch(cls,
      integer   = suppressWarnings(as.integer(as.character(before))),
      numeric   = suppressWarnings(as.numeric(as.character(before))),
      character = as.character(before),
      logical   = as.logical(before),
      Date      = as.Date(before),
      stop("aoi_match_types(): no rule for class ", cls, " (", col, ")", call. = FALSE))
    lost <- is.na(after) & !is.na(before)
    if (any(lost)) {
      stop("Casting `", col, "` to ", cls, " would drop ", sum(lost), " value(s), e.g. ",
           paste(utils::head(unique(before[lost]), 3), collapse = ", "), ".", call. = FALSE)
    }
    x[[col]] <- after
  }
  x
}

# --- Registry -------------------------------------------------------------
# Each entry is `type = "watershed"` (resolved through fresh) or
# `type = "bbox"` (WGS84 xmin, ymin, xmax, ymax).

aoi_registry <- function() {
  list(
    neexdzii_kwa = list(
      type = "watershed",
      label = "Neexdzii Kwa (Upper Bulkley)",
      blue_line_key = 360873822,
      downstream_route_measure = 166030.4
    ),
    se_a = list(
      type = "bbox",
      label = "Southeast BC A",
      bbox = c(-116.0758, 49.0953, -116.0635, 49.1060)
    ),
    se_b = list(
      type = "bbox",
      label = "Southeast BC B",
      bbox = c(-116.0549, 49.1127, -116.0427, 49.1221)
    ),
    se_c = list(
      type = "bbox",
      label = "Southeast BC C",
      bbox = c(-117.9819, 49.2420, -117.9729, 49.2502)
    )
  )
}

# --- Resolver -------------------------------------------------------------

#' Resolve a registered AOI id to an sf polygon in BC Albers (EPSG:3005)
#'
#' `conn` is only used by watershed AOIs. Left NULL, one is opened for the call
#' and closed again; pass an open connection when resolving several watershed
#' AOIs so they share it.
aoi_resolve <- function(id, conn = NULL) {
  entry <- aoi_entry(id)

  if (identical(entry$type, "watershed") && is.null(conn)) {
    conn <- fresh::frs_db_conn()
    on.exit(DBI::dbDisconnect(conn), add = TRUE)
  }

  geom <- switch(
    entry$type,
    watershed = fresh::frs_watershed_at_measure(
      conn = conn,
      blue_line_key = entry$blue_line_key,
      downstream_route_measure = entry$downstream_route_measure
    ),
    bbox = {
      b <- entry$bbox
      sf::st_as_sf(
        data.frame(aoi_id = id),
        geometry = sf::st_as_sfc(sf::st_bbox(
          c(xmin = b[1], ymin = b[2], xmax = b[3], ymax = b[4]),
          crs = sf::st_crs(4326)
        ))
      )
    },
    stop("Unknown AOI type '", entry$type, "' for id '", id, "'.", call. = FALSE)
  )

  sf::st_transform(geom, 3005)
}

#' Look up one registry entry, failing with the valid ids rather than NULL
aoi_entry <- function(id) {
  reg <- aoi_registry()
  if (!id %in% names(reg)) {
    stop(
      "Unknown AOI id '", id, "'. Registered: ",
      paste(names(reg), collapse = ", "),
      call. = FALSE
    )
  }
  reg[[id]]
}

#' Human label for reports
aoi_label <- function(id) aoi_entry(id)$label

# --- Which AOIs to run ----------------------------------------------------

#' AOI ids for this run: command-line args if given, otherwise every
#' registered id.
#'
#' Every id is validated against the registry before any work starts, so a typo
#' fails immediately rather than after the first AOI has been fetched.
aoi_ids <- function(args = commandArgs(trailingOnly = TRUE)) {
  ids <- if (length(args)) args else names(aoi_registry())
  invisible(lapply(ids, aoi_entry))
  ids
}

# --- Per-AOI output paths -------------------------------------------------

#' Path to a per-AOI artifact, creating its directory
#'
#' `what` is one of "centroids", "selected", "ledger", "aoi", "report", or a
#' log name
#' ("fetch_log", "georef_log", "cog_log").
aoi_logs <- function() c("fetch_log", "georef_log", "cog_log")

aoi_kinds <- function() {
  c("centroids", "neighbours", "window", "selected", "ledger", "aoi", "dem", "report", aoi_logs())
}

aoi_path <- function(what, id) {
  spec <- switch(
    what,
    centroids = list(dir = "data/centroids", ext = ".parquet"),
    neighbours = list(dir = "data/neighbours", ext = ".parquet"),
    window    = list(dir = "data/window",    ext = ".parquet"),
    selected  = list(dir = "data/selected",  ext = ".parquet"),
    ledger    = list(dir = "data/select",    ext = ".csv"),
    aoi       = list(dir = "data/aoi",       ext = ".gpkg"),
    dem       = list(dir = "data/dem",       ext = ".tif"),
    report    = list(dir = "data/reports",   ext = ".md"),
    # Named logs only. Without this, a typo — aoi_path("centroid", id) — fell
    # through to a plausible-looking data/logs/centroid/<id>.csv and created the
    # directory, so the artifact went somewhere nothing reads and every later
    # file.exists() guard reported "run 01_fetch.R first".
    if (what %in% aoi_logs()) {
      list(dir = file.path("data", "logs", what), ext = ".csv")
    } else {
      stop("Unknown artifact kind '", what, "'. Known: ",
           paste(aoi_kinds(), collapse = ", "),
           call. = FALSE)
    }
  )
  dir.create(spec$dir, recursive = TRUE, showWarnings = FALSE)
  file.path(spec$dir, paste0(id, spec$ext))
}

# --- The fetch window, and the DEM under it -------------------------------

#' Metres the catalogue query is buffered by before selection
#'
#' Film footprints are kilometres wide, so a frame whose centroid sits well
#' outside the AOI can still cover it. Lived in `01_fetch.R` as a constant and is
#' here because three things now need the same number: the query, the report's
#' prose, and the DEM extent.
aoi_fetch_buffer <- function() 8000

#' Metres of DEM beyond the fetch window
#'
#' fly buffers past the **corner** of the widest footprint, not its edge
#' (`fly/R/fly_footprint.R:539-553`), and the correction enlarges footprints
#' before the second sampling pass — so the reach is `half_side * growth *
#' sqrt(2)`, not `half_side`. The widest film footprint published from this
#' collection is 7,242 m and #23 measures median width growth of 1.067x:
#'
#'   3621 * 1.12 * sqrt(2) = 5,736 m
#'
#' That was 6,000, and it assumed every selected frame sits near the AOI. Since
#' #23 selects the union — every published frame in the window is rebuilt — a
#' selected frame can sit anywhere in the 8 km window, and on `se_a` seven of
#' them reached 2,008 m past a 6,000 m margin (measured 2026-09-26, fly 0.15.0).
#' 10,000 covers 5,736 + 2,008 with about 25% to spare. The check is not this
#' arithmetic: `01_fetch.R` refuses any selected frame with `dem_shortfall_m > 0`.
aoi_dem_corner <- function() 10000

#' Is terrain correction on?
#'
#' **On**, since the #23 rebuild. `fly_footprint()` sized from a reported scale
#' understates footprint area by a median 14% and up to 26%, always in the same
#' direction (fly `inst/notes/terrain-correction.md`). Measured independently of
#' fly, twice: against the catalogue's published photogrammetric solutions, fly
#' with a DEM agrees on width to 0-2% for every sensor it can size, and 2012
#' digital has no footprint at all without one; against orthophotos, film fitted at
#' a scale of 0.909 as published and 1.000 with the DEM, closer on 45 of 50 paired
#' frames (stac_orthophoto_bc, research sections 3 and 6a).
#'
#' It moves selection, because footprints decide which frames are candidates. So
#' it is on for every AOI at once, never for one region alone: a half-corrected
#' collection is one no consumer can read.
aoi_dem_enabled <- function() TRUE

#' The DEM for an AOI, or NULL when terrain correction is off
#'
#' MRDEM-30 through `flooded::fl_dem_aoi()` — NRCan's 30 m bare-earth model, one
#' public 84 GB COG read over `/vsicurl/`, cropped before it is reprojected. It
#' is also the raster fly documents as its own default and ships a clip of as
#' test data, so the pipeline and the package it calls agree on the source.
#'
#' `build = TRUE` fetches and caches; `build = FALSE` reads the cache and refuses
#' if it is absent. The asymmetry is deliberate: building needs the AOI polygon,
#' and resolving a watershed AOI opens a `fresh` database connection
#' (`aoi_resolve()`), which `02_georef.R` has no other reason to require. So the
#' DEM is built once at fetch time and read thereafter, mirroring how that stage
#' already refuses a missing selected set.
aoi_dem_source <- function() {
  paste0("/vsicurl/https://canelevation-dem.s3.ca-central-1.amazonaws.com/",
         "mrdem-30/mrdem-30-dtm.tif")
}

aoi_dem <- function(id, build = FALSE) {
  if (!aoi_dem_enabled()) {
    return(NULL)
  }

  path <- aoi_path("dem", id)

  if (!file.exists(path)) {
    if (!build) {
      stop("No cached DEM for '", id, "' at ", path,
           " — run 01_fetch.R ", id, " first, which builds it.", call. = FALSE)
    }
    message("  fetching MRDEM-30 for ", id, " (",
            (aoi_fetch_buffer() + aoi_dem_corner()) / 1000, " km buffer)")

    # Kept on MRDEM's own grid and CRS, not reprojected. terra::project() with no
    # template gives every AOI its own EPSG:3005 grid and its own resampled values,
    # so a frame two AOIs share (se_a and se_b share 60) would be sized differently
    # by each and its footprint digest would depend on which AOI ran last. A crop
    # with snap = "out" keeps the source cells, so shared ground reads the same
    # values from every AOI's DEM. fly transforms footprints to the DEM's CRS.
    src <- aoi_dem_source()
    dem <- flooded::fl_dem_aoi(
      aoi_resolve(id),
      source = src,
      buffer = aoi_fetch_buffer() + aoi_dem_corner(),
      target_crs = sf::st_crs(terra::crs(terra::rast(src)))
    )

    # Through a temp file: terra truncates its target before the write, so an
    # interrupted fetch would otherwise leave a partial raster that the
    # file.exists() guard above blesses on every future run. Same reason the
    # centroid cache is written this way.
    tmp <- paste0(path, ".tmp.tif")
    terra::writeRaster(dem, tmp, overwrite = TRUE)

    # Checked, because `file.rename()` reports failure by returning FALSE with a
    # warning rather than by erroring. Today the `terra::rast(path)` below would
    # error on the missing file, but that loudness belongs to the caller and
    # moving either line takes it away. This is the one destructive step here.
    if (!file.rename(tmp, path)) {
      stop("Could not move the DEM into place: ", tmp, " -> ", path, ".\n",
           "The fetched raster is still at the temp path.", call. = FALSE)
    }
  }

  dem <- terra::rast(path)
  # A DEM cached before #23 moved to MRDEM's native grid is on an EPSG:3005 grid of
  # its own, and would size this AOI's shared frames differently from every other
  # AOI's. Refused rather than reused.
  if (!identical(terra::crs(dem, describe = TRUE)$code, "3979")) {
    stop("Cached DEM ", path, " is not on MRDEM's native grid (EPSG:3979). Delete it ",
         "and re-run 01_fetch.R ", id, ".", call. = FALSE)
  }
  dem
}

# --- Era bins -------------------------------------------------------------
# Reporting dimension only. Selection keeps every frame whose footprint
# overlaps the AOI (issue #16) — era is how the report is grouped, not a filter.
# The breaks are the ones the issue measured: pre-1980, 1980–1999, 2000+.

aoi_era <- function(year) {
  cut(
    as.integer(year),
    breaks = c(-Inf, 1979, 1999, Inf),
    labels = c("pre1980", "1980_1999", "2000plus")
  )
}

# --- Provenance -----------------------------------------------------------

#' Rebuild centroids as an sf POINT layer in EPSG:3005
#'
#' Two reasons, both load-bearing:
#'
#' 1. Geometry is always rebuilt from `longitude`/`latitude`, so a cache hit and
#'    a cache miss produce identical geometry rather than the WFS `SHAPE` in one
#'    case and rebuilt points in the other.
#' 2. It rebuilds them as **POINT**. Every fly function that takes centroids
#'    refuses anything else (fly#37, `fly/R/fly_filter.R:35`): `st_coordinates()`
#'    returns one row per feature for a POINT and one row per *vertex* for
#'    anything else, which turned 20 frames into 100 rows with 80 of them
#'    carrying another photo's attributes. So this is now the step that satisfies
#'    that guard, not merely a convenience.
#'
#' What used to be reason 1 is gone: an `as.data.frame()` coercion that stripped
#' the `tbl_df` class, because `fly_footprint()` silently dropped its four
#' reporting columns on tibble input (fly#35) — which is exactly what
#' `bcdata::collect()` returns. Fixed in fly 0.5.1, and measured against a real
#' `sf,bcdc_sf,tbl_df,tbl,data.frame` window before removing the workaround.
#' `aoi_check_footprint_cols()` is what would catch a regression now.
aoi_centroids_as_sf <- function(x) {
  sf::st_transform(
    # remove = FALSE keeps longitude/latitude as columns, so the frame survives
    # a parquet round-trip and every stage rebuilds the same geometry from them.
    sf::st_as_sf(sf::st_drop_geometry(x), coords = c("longitude", "latitude"),
                 crs = 4326, remove = FALSE),
    3005
  )
}

# --- Rejection ledger and report ------------------------------------------

# One row per frame in the buffered fetch window, each with exactly one
# outcome. The counts must reconcile to the window, which is what makes
# "what selection rejected and why" answerable rather than asserted.
aoi_reasons <- function() {
  c("selected", "no_footprint", "footprint_misses_aoi", "no_bearing",
    "no_thumbnail_url", "fetch_failed", "georef_failed")
}

#' Columns every ledger must carry
#'
#' The three terrain columns are the point of issue #20. Before it,
#' `01_fetch.R` kept one column of `fly_footprint()`'s result and discarded the
#' rest, so `footprint_terrain`, `height_agl` and `dem_coverage` could not reach
#' the ledger even on a fly that returned them correctly — and nothing said so,
#' because an absent column reads as "this pipeline does not report terrain"
#' rather than as "this line drops it".
#'
#' Naming them here is what makes their arrival a measurement.
aoi_ledger_cols <- function() {
  c("aoi_id", "airp_id", "film_roll", "frame_number",
    "photo_year", "era", "footprint_basis",
    "footprint_terrain", "width_source", "footprint_bearing",
    "height_agl", "dem_coverage", "height_source",
    "dem_shortfall_m", "dem_elev_sd",
    "rotation", "rotation_source",
    "placement_source", "shift_x_m_3005", "shift_y_m_3005",
    "thumbnail_image_url", "selection_basis", "rejected_reason")
}

#' Refuse a ledger missing any declared column
#'
#' Extra columns pass. The ledger is allowed to grow ahead of its readers, and
#' refusing an unexpected column would make every future addition a breaking
#' change to a file three stages write.
#'
#' The case that actually arrives is a ledger written by an earlier run:
#' `02_georef.R` reads `data/select/<id>.csv` back off disk, and one from before
#' #20 has no terrain columns, one from before #23 no rotation or placement
#' source. That must abort naming the re-run, not silently write a short row over
#' a complete one.
aoi_ledger_check_cols <- function(ledger, id) {
  missing <- setdiff(aoi_ledger_cols(), names(ledger))
  if (length(missing)) {
    stop(
      "Ledger for '", id, "' is missing ", length(missing), " column(s): ",
      paste(missing, collapse = ", "), ".\n",
      "A ledger written by an earlier version of the pipeline lacks them. ",
      "Re-run 01_fetch.R ", id, " to rebuild it.",
      call. = FALSE
    )
  }
  invisible(ledger)
}

#' Write the ledger, asserting it accounts for every candidate
#'
#' The count is read back from the centroid cache on disk rather than passed in.
#' A caller-supplied total is whatever the caller already computed from the
#' ledger itself — `nrow(ledger)` compared against `nrow(ledger)` — so the guard
#' held for any input and could not go red. The cache is an independent record
#' of how many frames the query returned.
aoi_ledger_write <- function(ledger, id) {
  cache <- aoi_path("centroids", id)
  if (!file.exists(cache)) {
    stop("No centroid cache for '", id, "' — cannot reconcile the ledger.",
         call. = FALSE)
  }
  window_n <- nrow(arrow::read_parquet(cache))

  if (nrow(ledger) != window_n) {
    stop(
      "Ledger does not reconcile for '", id, "': ", nrow(ledger),
      " rows against ", window_n, " frames in the cached fetch window.",
      call. = FALSE
    )
  }
  # Row count alone is weak in 01_fetch.R, where the ledger is a transmute() of
  # the frame read from this same cache and the counts agree by construction.
  # Unique ids is the part that can actually differ.
  if (dplyr::n_distinct(ledger$airp_id) != nrow(ledger)) {
    stop(
      "Ledger for '", id, "' has ", nrow(ledger), " rows but only ",
      dplyr::n_distinct(ledger$airp_id), " distinct airp_id — a frame is ",
      "counted more than once, so the rejection totals do not partition.",
      call. = FALSE
    )
  }

  aoi_ledger_check_cols(ledger, id)

  unknown <- setdiff(unique(ledger$rejected_reason), aoi_reasons())
  if (length(unknown)) {
    stop("Unregistered rejection reason(s): ",
         paste(unknown, collapse = ", "), call. = FALSE)
  }
  readr::write_csv(ledger, aoi_path("ledger", id))
  invisible(ledger)
}

#' Report lines describing how footprints were sized
#'
#' Two states, and the empty one is the delivered one. With terrain correction
#' off (`aoi_dem_enabled()`), `height_agl` and `dem_coverage` are `NA` on every
#' row — so this says so rather than rendering a table of nothing, which reads
#' as a pipeline that lost the numbers rather than one that never took them.
#'
#' The columns are re-coerced because a ledger arriving from
#' `readr::read_csv()` is not the ledger `01_fetch.R` built: an all-`NA` numeric
#' column round-trips through CSV as **logical**, and with the DEM off that is
#' both of these columns on every run. `mean()` of a logical is a proportion, so
#' without this the same section reports a coverage figure in `01_fetch.R` and a
#' different kind of number in `02_georef.R` from identical data.
aoi_terrain_lines <- function(ledger) {
  agl <- suppressWarnings(as.numeric(ledger$height_agl))
  cov <- suppressWarnings(as.numeric(ledger$dem_coverage))

  counts <- knitr::kable(
    dplyr::count(
      dplyr::mutate(ledger,
                    footprint_terrain = ifelse(is.na(footprint_terrain),
                                               "(no footprint)",
                                               footprint_terrain)),
      footprint_terrain,
      name = "frames"
    ),
    format = "markdown"
  )

  if (!any(!is.na(cov))) {
    return(c(
      counts,
      "",
      paste0("No DEM was applied, so `height_agl` and `dem_coverage` are empty ",
             "on every row. Footprints are sized from the catalogue's reported ",
             "scale, which understates their area by a median 14% and up to ",
             "26%, always in the same direction. See `aoi_dem_enabled()`.")
    ))
  }

  c(
    counts,
    "",
    paste0("- Frames with a terrain-corrected footprint: **",
           sum(!is.na(agl)), "**"),
    paste0("- `dem_coverage` range: **",
           paste(round(range(cov, na.rm = TRUE), 3), collapse = "–"), "**"),
    paste0("- Frames below fly's ", aoi_dem_coverage_min(),
           " coverage threshold: **",
           sum(cov < aoi_dem_coverage_min(), na.rm = TRUE), "**")
  )
}

#' Report lines on where each selected frame's rotation and placement came from
#'
#' The point of `rotation_source` is that assumed frames can be found and checked
#' by eye, so the report names the rolls rather than counting them: every roll at
#' `assumed_by_series` or `disputed`, and the 1975-76 `bc5xxx` rolls, whose three
#' measured neighbours disagree, as "review each".
aoi_provenance_lines <- function(ledger) {
  sel <- ledger[ledger$rejected_reason == "selected", ]
  if (!nrow(sel)) return("No frames selected.")

  src <- function(x) ifelse(is.na(x), "(none: digital)", x)
  rolls <- function(which) {
    r <- sort(unique(sel$film_roll[which]))
    if (length(r)) paste0("`", r, "`", collapse = ", ") else "none"
  }
  review <- aoi_rotation_needs_review(sel$film_roll, as.integer(sel$photo_year))

  c(
    knitr::kable(dplyr::count(dplyr::mutate(sel, rotation_source = src(rotation_source)),
                              rotation_source, name = "frames"),
                 format = "markdown"),
    "",
    knitr::kable(dplyr::count(sel, placement_source, name = "frames"),
                 format = "markdown"),
    "",
    knitr::kable(dplyr::count(dplyr::mutate(sel, height_source = ifelse(
                   is.na(height_source), "(not judged)", height_source)),
                              height_source, name = "frames"),
                 format = "markdown"),
    "",
    paste0("- Rolls at `assumed_by_series`: ",
           rolls(sel$rotation_source %in% "assumed_by_series")),
    paste0("- Rolls at `disputed`: ", rolls(sel$rotation_source %in% "disputed")),
    paste0("- `bc5xxx` rolls flown 1975-76, **review each by eye**: ", rolls(review))
  )
}

#' Render the per-AOI markdown report from the ledger
aoi_report_write <- function(ledger, id) {
  sel <- ledger[ledger$rejected_reason == "selected", ]

  by_era <- ledger |>
    dplyr::count(era, rejected_reason) |>
    tidyr::pivot_wider(names_from = rejected_reason, values_from = n,
                       values_fill = 0)

  yr <- if (nrow(sel)) range(sel$photo_year, na.rm = TRUE) else c(NA, NA)

  lines <- c(
    paste0("# ", id, " — ", aoi_label(id)),
    "",
    paste0("Generated ", format(Sys.Date())),
    "",
    "## Summary",
    "",
    paste0("- Frames in the ", aoi_fetch_buffer() / 1000,
           " km fetch window: **", nrow(ledger), "**"),
    paste0("- Frames selected: **", nrow(sel), "**",
           if ("selection_basis" %in% names(sel) && nrow(sel)) paste0(
             " (", sum(sel$selection_basis %in% "footprint"), " by footprint, ",
             sum(sel$selection_basis %in% "published"),
             " because already published)") else ""),
    paste0("- Year range obtained: **",
           if (is.na(yr[1])) "none" else paste(yr, collapse ="–"), "**"),
    "",
    "## Selected by era",
    "",
    knitr::kable(
      dplyr::count(sel, era, name = "selected"),
      format = "markdown"
    ),
    "",
    "## Every frame accounted for, by era",
    "",
    knitr::kable(by_era, format = "markdown"),
    "",
    "## How each footprint was sized",
    "",
    aoi_terrain_lines(ledger),
    "",
    "## Where rotation, placement and height came from (selected frames)",
    "",
    aoi_provenance_lines(ledger),
    "",
    "## Why frames were rejected",
    "",
    knitr::kable(
      dplyr::count(ledger, rejected_reason, name = "frames"),
      format = "markdown"
    ),
    "",
    "Rejection reasons:",
    "",
    "- `no_footprint` — `fly` could not size this frame, so it has no ground",
    "  footprint to select on. Keyed on `footprint_terrain` being absent, which",
    "  is the property itself; it used to be keyed on a `footprint_basis` string",
    "  fly stopped writing once it could size digital frames, and those frames",
    "  then fell through to `footprint_misses_aoi` — reported as *sized, but",
    "  missing the AOI* for a frame that was never sized at all.",
    "- `footprint_misses_aoi` — sized, but the ground footprint does not reach",
    paste0("  the AOI. Expected: the window is buffered by ",
           aoi_fetch_buffer() / 1000, " km precisely so no"),
    "  overlapping frame is missed, and most of that buffer does not overlap.",
    "- `no_bearing` — a film frame with no adjacent roll neighbour in the window,",
    "  so fly draws its footprint axis-aligned. Its per-roll rotation would place",
    "  the picture as though the aircraft flew due north, so it is withheld.",
    "- `no_thumbnail_url` — the catalogue has no thumbnail for this frame.",
    "- `fetch_failed` / `georef_failed` — the frame was selected and the",
    "  pipeline could not produce an asset for it."
  )

  writeLines(lines, aoi_path("report", id))
  invisible(lines)
}
