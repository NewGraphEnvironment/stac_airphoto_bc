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

aoi_path <- function(what, id) {
  spec <- switch(
    what,
    centroids = list(dir = "data/centroids", ext = ".parquet"),
    selected  = list(dir = "data/selected",  ext = ".parquet"),
    ledger    = list(dir = "data/select",    ext = ".csv"),
    aoi       = list(dir = "data/aoi",       ext = ".gpkg"),
    report    = list(dir = "data/reports",   ext = ".md"),
    # Named logs only. Without this, a typo — aoi_path("centroid", id) — fell
    # through to a plausible-looking data/logs/centroid/<id>.csv and created the
    # directory, so the artifact went somewhere nothing reads and every later
    # file.exists() guard reported "run 01_fetch.R first".
    if (what %in% aoi_logs()) {
      list(dir = file.path("data", "logs", what), ext = ".csv")
    } else {
      stop("Unknown artifact kind '", what, "'. Known: ",
           paste(c("centroids", "selected", "ledger", "aoi", "report",
                   aoi_logs()), collapse = ", "),
           call. = FALSE)
    }
  )
  dir.create(spec$dir, recursive = TRUE, showWarnings = FALSE)
  file.path(spec$dir, paste0(id, spec$ext))
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
#' Mirrors fly's internal `bearing_to_rotation()` (fly/R/fly_georef.R:300),
#' which is not exported. Kept here because we must compute rotation ourselves:
#' `fly_georef(rotation = "auto")` calls `fly_bearing()` on whatever set it is
#' handed, and `fly_bearing()` derives each frame's bearing from the *next frame
#' on the same roll in that set*. Filtering to one AOI thins the rolls, so a
#' frame whose successor was filtered out gets `NA` and silently falls back to
#' the fixed 180 degrees that fly#25/#26 exist to correct.
#'
#' So bearing is computed once over the whole fetch window, where the rolls are
#' intact, and carried forward as a `rotation` column — which `fly_georef()`
#' honours in preference to recomputing (fly/R/fly_georef.R:127).
aoi_rotation <- function(bearing) {
  rot <- (floor((bearing + 91) / 90) * 90L) %% 360L
  rot[is.na(rot)] <- 180L
  as.integer(rot)
}

# --- Provenance -----------------------------------------------------------

#' Coerce centroids to a plain data.frame-backed sf in EPSG:3005
#'
#' Two reasons, both load-bearing:
#'
#' 1. `fly_footprint()` silently drops `footprint_basis`, `footprint_terrain`,
#'    `height_agl` and `dem_coverage` when its input carries the `tbl_df` class,
#'    which is exactly what `bcdata::collect()` returns (fly#35). Those columns
#'    are the whole rejection ledger, and nothing errors when they go missing.
#' 2. Points are always rebuilt from `longitude`/`latitude`, so a cache hit and
#'    a cache miss produce identical geometry rather than the WFS `SHAPE` in one
#'    case and rebuilt points in the other.
aoi_centroids_as_sf <- function(x) {
  df <- as.data.frame(sf::st_drop_geometry(x))
  sf::st_transform(
    # remove = FALSE keeps longitude/latitude as columns, so the frame survives
    # a parquet round-trip and every stage rebuilds the same geometry from them.
    sf::st_as_sf(df, coords = c("longitude", "latitude"), crs = 4326,
                 remove = FALSE),
    3005
  )
}

# --- Rejection ledger and report ------------------------------------------

# One row per frame in the buffered fetch window, each with exactly one
# outcome. The counts must reconcile to the window, which is what makes
# "what selection rejected and why" answerable rather than asserted.
aoi_reasons <- function() {
  c("selected", "digital_unknown_format", "footprint_misses_aoi",
    "no_thumbnail_url", "fetch_failed", "georef_failed")
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
  unknown <- setdiff(unique(ledger$rejected_reason), aoi_reasons())
  if (length(unknown)) {
    stop("Unregistered rejection reason(s): ",
         paste(unknown, collapse = ", "), call. = FALSE)
  }
  readr::write_csv(ledger, aoi_path("ledger", id))
  invisible(ledger)
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
    paste0("- Frames in the 8 km fetch window: **", nrow(ledger), "**"),
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
    "## Why frames were rejected",
    "",
    knitr::kable(
      dplyr::count(ledger, rejected_reason, name = "frames"),
      format = "markdown"
    ),
    "",
    "Rejection reasons:",
    "",
    "- `digital_unknown_format` — a digital frame. `fly` (>= 0.4.0) will not",
    "  size a footprint it cannot derive, because a sensor's width is not in",
    "  the centroid metadata (fly#32). These are the frames the published",
    "  Neexdzii Kwa collection sized as 9-inch negatives, which is why one of",
    "  them ships an 11,435 m footprint. Excluding them stops shipping that.",
    "- `footprint_misses_aoi` — sized, but the ground footprint does not reach",
    "  the AOI. Expected: the window is buffered by 8 km precisely so no",
    "  overlapping frame is missed, and most of that buffer does not overlap.",
    "- `no_thumbnail_url` — the catalogue has no thumbnail for this frame.",
    "- `fetch_failed` / `georef_failed` — the frame was selected and the",
    "  pipeline could not produce an asset for it."
  )

  writeLines(lines, aoi_path("report", id))
  invisible(lines)
}
