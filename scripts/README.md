# Pipeline Scripts

This pipeline turns historical aerial photographs of British Columbia into a searchable, viewable online image collection. It downloads thumbnail images from the provincial catalogue, places them in their correct geographic positions, converts them to a web-friendly format, uploads them to cloud storage, and registers them in a searchable catalog so anyone can find and view them by location or date.

## Key Concepts

**COG (Cloud Optimized GeoTIFF)** — A specially organized image file that can be viewed over the internet without downloading the whole thing. A regular image file requires a complete download before you can see it. A COG is internally organized so that a viewer can request just the piece it needs (e.g. a zoomed-in corner), making it practical to browse thousands of large images from a web browser or GIS application.

**STAC (SpatioTemporal Asset Catalog)** — A standard way to describe images with where and when metadata. Think of it as a library catalog for geographic imagery: each image gets a record describing its location, date, and where to find the file. STAC makes the collection searchable — "show me all photos from 1968 that overlap this watershed."

**Georeferencing (warping)** — The original thumbnails are flat images with no geographic information. Georeferencing stretches and positions each image so it lines up with its real-world location on a map, using the known camera position, altitude, and scale recorded in the provincial catalogue.

**S3** — Amazon's cloud file storage. COGs are uploaded here so they are accessible via URL from anywhere, without running a dedicated file server.

**pgstac** — A PostgreSQL database that stores STAC records and exposes them through a search API. Hosted on a cloud server at `images.a11s.one`, this is what allows users to search the collection by location, date, or other properties from QGIS, a web browser, or any STAC-compatible tool.

## Quick Start

```bash
# Full pipeline, every registered AOI
bash scripts/run_pipeline.sh

# Or a named subset
bash scripts/run_pipeline.sh se_a se_b

# Or run individual steps from the project root
Rscript scripts/01_fetch.R se_a
Rscript scripts/02_georef.R se_a
Rscript scripts/03_cog.R                    # global; also calls 03_cog_tag.py
conda run -n stac-airphoto-bc python scripts/05_stac_register.py
Rscript scripts/04_s3_upload.R              # AFTER registration, not before
```

## Areas of interest

The AOI is a parameter, not a constant. `scripts/aoi.R` holds the registry —
one entry per area, given either as a watershed (`blue_line_key` +
`downstream_route_measure`, resolved through `fresh`) or as a WGS84 bbox:

| id | area |
|----|------|
| `neexdzii_kwa` | Neexdzii Kwa (Upper Bulkley) watershed |
| `se_a`, `se_b`, `se_c` | three small southeast BC bboxes |

Every stage takes AOI ids as command-line arguments and processes all
registered AOIs when given none. An unknown id aborts before any work starts.

To add an area, add an entry to `aoi_registry()`. Nothing else changes.

## Pipeline Steps

| Step | Script | What it does |
|------|--------|--------------|
| 0 | `00_review_samples.R` | Grab a few thumbnails per year and inspect their properties (band count, dimensions, pixel values) — useful for understanding what the source data looks like before processing |
| 1 | `01_fetch.R` | Query the BC Data Catalogue for air photo locations in the study area, then download the thumbnail images (6 downloads in parallel) |
| 2 | `02_georef.R` | Position each thumbnail on the map by stretching it to match its estimated ground footprint (BC Albers projection, EPSG 3005) |
| 3a | `03_cog.R` | Convert the georeferenced images into COGs — adding internal tiling and compression so they work efficiently over the web |
| 3b | `03_cog_tag.py` | Stamp each COG with descriptive metadata (photo ID, date, scale, roll/frame) that shows up when you inspect the file in QGIS or any GDAL tool — called automatically by step 3a |
| 4 | `04_s3_upload.R` | Sync COGs to the S3 bucket, uploading only new or changed files |
| 5 | `05_stac_register.py` | Create a STAC catalog record for each image (location, date, properties, download link) and validate the whole collection |
| — | `test_pipeline.R` | Run a 100-photo sample through the full pipeline to verify everything works after code changes |

## Data Flow

```
BC Data Catalogue (provincial web service)
  ↓ 01_fetch — download thumbnails
data/raw/thumbs/{year}/*.jpg
  ↓ 02_georef — position on map
data/raw/georef/thumbs/{year}/*.tif
  ↓ 03_cog + 03_cog_tag — convert to web-friendly format, embed metadata
data/stac/thumbs/{year}/*.tif
  ↓ 04_s3_upload — push to cloud storage
s3://stac-airphoto-bc/thumbs/{year}/*
  ↓ 05_stac_register — build searchable catalog
data/stac/{airp_id}.json              (one record per photo)
data/stac/collection.json             (collection-level summary)
```

## Re-running is Safe

Every step checks for existing outputs and skips work that's already done. You can re-run the pipeline after adding new photos or fixing a single step without reprocessing everything:

| Step | What gets skipped |
|------|-------------------|
| 01 | Catalogue query cached per AOI as `data/centroids/<id>.parquet` (set `FORCE_REFRESH = TRUE` to re-query); already-downloaded thumbnails are kept |
| 02 | GeoTIFFs that already exist in the output directory |
| 03a | COGs that already exist on disk |
| 03b | COGs that already have metadata tags embedded |
| 04 | Files already on S3 with matching size |
| 05 | Rebuilds item records from local COGs, then merges them into the published collection — idempotent, and it never drops a published item link |

## What is per-AOI and what is shared

```
data/aoi/<id>.gpkg               per-AOI   the resolved AOI polygon
data/centroids/<id>.parquet      per-AOI   cached catalogue query (8 km buffer)
data/selected/<id>.parquet       per-AOI   frames chosen for this AOI
data/select/<id>.csv             per-AOI   ledger: one row per candidate + reason
data/reports/<id>.md             per-AOI   the report (committed)
data/logs/<stage>/<id>.csv       per-AOI   stage logs
data/raw/thumbs/{year}/          GLOBAL
data/raw/georef/thumbs/{year}/   GLOBAL
data/stac/thumbs/{year}/         GLOBAL
data/stac/<airp_id>.json         GLOBAL
```

The output half is global on purpose. S3 is laid out by year and items are keyed
by `airp_id` across the whole collection, so two AOIs that overlap share a frame
rather than fetching, converting and publishing it twice — 60 of the 295
selections across the three southeast AOIs are the same 60 frames, shared by A
and B.

## The rejection ledger

`data/select/<id>.csv` carries one row per frame in the buffered fetch window,
each with exactly one outcome, and the counts must reconcile to the window —
that is what makes "what selection rejected and why" answerable rather than
asserted. Reasons: `selected`, `digital_unknown_format`, `footprint_misses_aoi`,
`no_thumbnail_url`, `fetch_failed`, `georef_failed`.

`digital_unknown_format` is the interesting one. `fly` (>= 0.4.0) will not size
a footprint for a digital frame, because a sensor's width is not in the centroid
metadata (fly#32). The share varies far more than expected: 2.2% of the AOI A
window, 4% of B, **20% of C**. Those are the frames the published Neexdzii Kwa
collection sized as 9-inch negatives — one of them ships an 11,435 m footprint
against 2,286–7,242 m for every film frame. Excluding them stops shipping that.

## Prerequisites

| Component | What's needed |
|-----------|---------------|
| R packages | `fly` (≥ 0.5.0), `fresh`, `terra`, `sf`, `dplyr`, `arrow`, `purrr` |
| Python (conda) | Environment `stac-airphoto-bc` with `pystac`, `rasterio`, `shapely`, `pyarrow` |
| geopro | `GEOPRO_IP` set in the environment for the registration step |
| AWS CLI | Configured with write access to `s3://stac-airphoto-bc` |

## After the Pipeline

The pipeline produces COGs on S3 and STAC catalog files on disk. To make the collection searchable at `images.a11s.one`, register it on the pgstac server:

```bash
ssh root@$GEOPRO_IP "bash /tmp/stac_register-pypgstac.sh stac-airphoto-bc https://stac-airphoto-bc.s3.us-west-2.amazonaws.com"
```

That script **deletes the collection and its items and reloads them from
`collection.json`'s item links**. So the merged collection is load-bearing: a
`collection.json` listing only the newest AOI would delete every other item from
the catalog. `05_stac_register.py` asserts against the written file that no
published link was dropped, and refuses to promote a collection that fails.

### Building the conda environment

`conda env create -f environment.yml` can fail with
`CondaToSNonInteractiveError` if conda's global config still resolves the
`defaults` channel, whose Terms of Service must be accepted interactively.
Nothing here needs it — build from conda-forge explicitly instead:

```bash
conda create -n stac-airphoto-bc -c conda-forge --override-channels python=3.12 pip -y
conda run -n stac-airphoto-bc pip install pystac rio-stac rasterio shapely pyarrow tqdm jsonschema
```

This loads the STAC records into a PostgreSQL database that powers the search API. Once registered, the collection is available in QGIS (via the STAC Data Source Manager), through the API at `images.a11s.one`, or any STAC-compatible client.

## Embedded Image Metadata

Each COG carries descriptive tags readable by any GDAL-based tool (visible in QGIS under Layer Properties → Information):

| Tag | Example |
|-----|---------|
| `AIRP_ID` | `695106` |
| `PHOTO_DATE` | `1968-07-15` |
| `SCALE` | `31680` |
| `FILM_ROLL` | `bc5281` |
| `FRAME_NUMBER` | `084` |
| `FOCAL_LENGTH` | `152.4` |
| `FLYING_HEIGHT` | `4572` |
| `FILENAME` | `bc5281_084_thumb.tif` |
