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
# (03_cog.R, 04_s3_upload.R, 05_stac_register.py) stay AOI-agnostic.

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
#' The other capability — that `fly_footprint()` returns its four reporting
#' columns on tibble-backed input (fly#35) — is checked in `01_fetch.R` at the
#' call itself. A formal is not evidence a column comes back.
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
      "Install fly >= 0.5.1 — 0.5.0 added `dem` and 0.5.1 fixed fly#35, which ",
      "drops the reporting columns on the tibble `bcdata` returns. The latest ",
      "release is the one to take:\n",
      "  remotes::install_github(\"NewGraphEnvironment/fly\")",
      call. = FALSE
    )
  }

  invisible(TRUE)
}

#' Columns `fly_footprint()` must return
#'
#' fly#35 dropped all four whenever the input carried the `tbl_df` class, which
#' is exactly what `bcdata::collect()` returns. Geometry and every number stayed
#' correct, so nothing failed — only the audit trail went missing, which is the
#' expensive kind of silence. Fixed in fly 0.5.1; asserted here because a formal
#' is not evidence a column comes back, and because this is the one property
#' whose loss has already happened once.
aoi_footprint_cols <- function() {
  c("footprint_basis", "footprint_terrain", "width_source",
    "footprint_bearing", "height_agl", "dem_coverage")
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
#' A positive control on fly's vocabulary. `aoi_rotation_ok()` and the report
#' both read `footprint_terrain`, and a guard keyed on a value fly might rename
#' fails toward *pass* — silently, on the arm that matters. Refusing an
#' unrecognised value turns that into an abort naming the value, so a new fly
#' sizing route is a loud stop rather than a quiet mis-classification.
#'
#' Like the threshold above this is fly's fact, not ours, and it is pinned in
#' `tests/test_aoi.R` against `fly_footprint()`'s own source. `dem_agl` and
#' `no_dem_coverage` are emitted only under a DEM, so no run and no fixture can
#' corroborate them while `aoi_dem_enabled()` is FALSE — reading them out of fly
#' is the only check that reaches them before #23 flips it.
aoi_terrain_values <- function() {
  c("nominal_scale", "gsd_scaled", "dem_agl", "no_dem_coverage")
}

aoi_check_footprint_cols <- function(fp) {
  missing <- setdiff(aoi_footprint_cols(), names(fp))
  if (length(missing)) {
    stop(
      "fly_footprint() returned no ", paste(missing, collapse = ", "), ".\n",
      "That is fly#35: the columns are dropped when the input carries the ",
      "`tbl_df` class, which is what bcdata::collect() returns. Fixed in fly ",
      "0.5.1 — install a newer fly:\n",
      "  remotes::install_github(\"NewGraphEnvironment/fly\")",
      call. = FALSE
    )
  }
  invisible(fp)
}

#' Which frames may carry a `rotation` column into `fly_georef()`
#'
#' Almost none, now, and that is the correct answer rather than a limitation.
#'
#' A user-supplied `rotation` is the **highest-precedence** input in
#' `fly_georef()` — read at `fly/R/fly_georef.R:316` (`user_val`), the refusal at
#' `:322`, the `rot` chain at `:341`, against fly 0.10.0 on 2026-09-07. It does
#' two things at once, and both are wrong for the frames this pipeline used to
#' hand it:
#'
#' 1. **Digital.** It beats `fly_digital_rotation()`, the corner mapping fly
#'    measured three independent ways. Harmless before fly 0.6.0, when no digital
#'    frame had a footprint at all; live from 0.6.0 on.
#' 2. **Film with a rotated ring.** fly 0.9.0 rotates every film footprint onto
#'    its flight line, and then *refuses* such a frame unless the caller supplies
#'    that roll's rotation — because the corner mapping is a per-roll camera-mount
#'    property fly cannot derive (measured 0 for bc5282/1968, 90 for
#'    bc83062/1983). Supplying a value **disarms that refusal.** Measured on 11
#'    real 1995 frames: 11/11 written with the column, 0/11 and 11 refusal
#'    warnings without it.
#'
#' And the value would be wrong anyway. `aoi_rotation()` derives it per frame
#' from bearing, so it varies *within* a roll where the property is a per-roll
#' constant — measured on `se_c`, **34 of 48 rolls** get two to four different
#' values, so at most one per roll can be right. The failure is the expensive
#' kind: a valid GeoTIFF, right CRS, right ground, picture turned a quarter or a
#' half turn, `success = TRUE`, and nothing downstream reporting it.
#'
#' So a rotation is supplied only where fly has **not** already rotated the ring
#' — `is.na(footprint_bearing)`, which is fly's own routing condition — and only
#' for film. Everything else is left `NA`, which sends digital frames to fly's
#' measured mapping and rotated film frames to fly's refusal, landing them in the
#' ledger as `georef_failed`. Issue #23 carries the measured per-roll table for
#' 54 rolls; until it lands, a refused film frame is the honest outcome.
aoi_rotation_ok <- function(media, footprint_terrain, footprint_bearing) {
  # NULL and character(0) are different states and only one of them is legal. A
  # frame set with no rows gives an empty mask, which is right. A frame set with
  # no `media` COLUMN gives NULL — and `x[!logical(0)] <- NA` is a silent no-op,
  # so every frame would keep a rotation and both failures above would be back,
  # reported by nothing. Measured: a 5-row frame with no `media` came out 180 on
  # all 5.
  if (is.null(media) || is.null(footprint_bearing)) {
    stop("`media` or `footprint_bearing` is absent, so the frames that may ",
         "safely carry a `rotation` cannot be identified. Supplying one to the ",
         "wrong frame overrides the corner mapping fly measured, or suppresses ",
         "fly's refusal to guess a per-roll one — either way the picture is ",
         "written a quarter turn out and nothing reports it. Re-run 01_fetch.R, ",
         "or re-query the centroid cache with FORCE_REFRESH = TRUE.",
         call. = FALSE)
  }

  film <- !is.na(media) & grepl("^Film", media)

  # An unrecognised terrain route means fly has changed under us, and every
  # decision below is keyed on values from that vocabulary. Abort rather than
  # classify on a string this code has never seen.
  seen <- stats::na.omit(unique(footprint_terrain))
  unknown <- setdiff(seen, aoi_terrain_values())
  if (length(unknown)) {
    stop("fly returned unrecognised `footprint_terrain` value(s): ",
         paste(unknown, collapse = ", "), ".\n",
         "Known: ", paste(aoi_terrain_values(), collapse = ", "), ". ",
         "The rotation mask and the report both key on this vocabulary, so a ",
         "new sizing route has to be read before it is classified.",
         call. = FALSE)
  }

  # One fact, two sources: the catalogue says what the medium was and fly says
  # which route sized it. A frame that is film by the catalogue and GSD-sized by
  # fly means one of the two is wrong, and guessing which is how a quarter-turn
  # error ships anyway.
  clash <- film & !is.na(footprint_terrain) & footprint_terrain == "gsd_scaled"
  if (any(clash)) {
    stop(
      sum(clash), " frame(s) are film by the catalogue's `media` but were ",
      "sized by fly's digital GSD route. The rotation mask cannot be trusted ",
      "for them, and a wrong rotation georeferences the picture a quarter ",
      "turn out with nothing downstream reporting it.",
      call. = FALSE
    )
  }

  film & is.na(footprint_bearing)
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
  c("centroids", "selected", "ledger", "aoi", "dem", "report", aoi_logs())
}

aoi_path <- function(what, id) {
  spec <- switch(
    what,
    centroids = list(dir = "data/centroids", ext = ".parquet"),
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
#' 6,000 leaves about 5% over that, which is thin. The check is not this
#' arithmetic — it is `dem_coverage`, which fly computes per frame and warns
#' below 0.95. 7,242 m is also measured over frames published so far rather than
#' over the window being sized, so treat the margin as provisional and read the
#' coverage.
aoi_dem_corner <- function() 6000

#' Is terrain correction on?
#'
#' **Off**, deliberately. `fly_footprint()` sized from a reported scale
#' understates footprint area by a median 14% and up to 26%, always in the same
#' direction, and footprints decide which frames are candidates at all — so
#' turning this on moves the published selection.
#'
#' `CLAUDE.md` records the decision not to correct one region and not the other:
#' the collection would be half-corrected, and no consumer could tell which half
#' they had. Only 235 southeast frames exist on this machine; the 9,741 Neexdzii
#' Kwa frames have no cache, no thumbnails and no ledger here. Re-deriving both
#' in one pass is issue #23, which flips this function and owns the rebuild.
#'
#' Everything below it is wired and exercised, so #23 is a one-line change here
#' rather than a plumbing job.
aoi_dem_enabled <- function() FALSE

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

    dem <- flooded::fl_dem_aoi(
      aoi_resolve(id),
      buffer = aoi_fetch_buffer() + aoi_dem_corner(),
      target_crs = 3005
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

  terra::rast(path)
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

# --- Rotation -------------------------------------------------------------

#' Derive per-photo rotation from flight-line bearing
#'
#' **Reaches almost nothing since #20, and deliberately.** `aoi_rotation_ok()`
#' withholds the column from every frame whose ring fly has rotated onto its
#' flight line — which is every digital frame and, at fly 0.9.0 and later, all
#' but a handful of film ones (3 of 810 on `se_c`). What survives is the case
#' this function was written for and is still correct for: an axis-aligned film
#' square, where the value shifts corners on the square itself. Issue #23 owns
#' the rotated case and carries a measured per-roll table.
#'
#' Mirrors fly's internal `bearing_to_rotation()` (`fly/R/fly_georef.R:482`),
#' which is not exported.
#'
#' **What it does now.** Because `aoi_rotation_ok()` admits only frames with no
#' `footprint_bearing`, every value this function can contribute is the
#' `rot[is.na(rot)] <- 180L` fallback — measured across all three AOIs, 11 / 6 /
#' 3 frames, all 180. And 180 is also fly's own fallback for an axis-aligned
#' frame, so the column is behaviourally a no-op today. It is kept because #23
#' replaces it with a measured per-roll table and the plumbing is where that
#' table will attach.
#'
#' **What it used to do, and why that stopped being true.** Bearing was computed
#' once over the whole fetch window, where the rolls are intact, and carried
#' forward — `fly_bearing()` derives a frame's bearing from its neighbour *in the
#' set it is handed*, so filtering to one AOI thins the rolls and a frame whose
#' neighbour was filtered out falls back to a fixed 180. That carry-forward is
#' gone: from fly 0.9.0 a supplied rotation reaches only unrotated frames, and on
#' every rotated one it would suppress fly's refusal instead. See
#' `aoi_rotation_ok()`.
aoi_rotation <- function(bearing) {
  rot <- (floor((bearing + 91) / 90) * 90L) %% 360L
  rot[is.na(rot)] <- 180L
  as.integer(rot)
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
  c("selected", "no_footprint", "footprint_misses_aoi",
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
    "height_agl", "dem_coverage",
    "rotation", "thumbnail_image_url", "rejected_reason")
}

#' Refuse a ledger missing any declared column
#'
#' Extra columns pass. The ledger is allowed to grow ahead of its readers, and
#' refusing an unexpected column would make every future addition a breaking
#' change to a file three stages write.
#'
#' The case that actually arrives is a ledger written before #20:
#' `02_georef.R` reads `data/select/<id>.csv` back off disk, and one from an
#' earlier run has none of the three. That must abort naming the re-run, not
#' silently write a short row over a complete one.
aoi_ledger_check_cols <- function(ledger, id) {
  missing <- setdiff(aoi_ledger_cols(), names(ledger))
  if (length(missing)) {
    stop(
      "Ledger for '", id, "' is missing ", length(missing), " column(s): ",
      paste(missing, collapse = ", "), ".\n",
      "A ledger written before issue #20 carries no terrain columns. ",
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
             "26%, always in the same direction. Turning terrain correction on ",
             "is issue #23 — see `aoi_dem_enabled()`.")
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
    paste0("- Frames selected: **", nrow(sel), "**"),
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
    "- `no_thumbnail_url` — the catalogue has no thumbnail for this frame.",
    "- `fetch_failed` / `georef_failed` — the frame was selected and the",
    "  pipeline could not produce an asset for it."
  )

  writeLines(lines, aoi_path("report", id))
  invisible(lines)
}
