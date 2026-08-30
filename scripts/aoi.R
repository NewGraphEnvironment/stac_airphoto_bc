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
#' `what` is one of "centroids", "selected", "aoi", "report", or a log name
#' ("fetch_log", "georef_log", "cog_log").
aoi_path <- function(what, id) {
  spec <- switch(
    what,
    centroids = list(dir = "data/centroids", ext = ".parquet"),
    selected  = list(dir = "data/selected",  ext = ".parquet"),
    aoi       = list(dir = "data/aoi",       ext = ".gpkg"),
    report    = list(dir = "data/reports",   ext = ".md"),
    list(dir = file.path("data", "logs", what), ext = ".csv")
  )
  dir.create(spec$dir, recursive = TRUE, showWarnings = FALSE)
  file.path(spec$dir, paste0(id, spec$ext))
}
