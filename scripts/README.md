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
uv run python scripts/03_cog.py            # global
uv run python scripts/05_stac_register.py
Rscript scripts/04_s3_upload.R              # AFTER 05_stac_register.py, not before

# A full rebuild (#23): fail if any published item was not rebuilt locally
uv run python scripts/05_stac_register.py --require-all-published --out /tmp/dry
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
| 1 | `01_fetch.R` | Query the BC Data Catalogue for air photo locations in the study area, size each footprint with a DEM, give each frame its roll's scanning rotation and its measured placement shift, select every frame that reaches the AOI plus every frame already published, then download the thumbnails (6 in parallel) |
| 2 | `02_georef.R` | Position each thumbnail on the map by stretching it to match its ground footprint (BC Albers, EPSG 3005). Hands `fly` the whole rolls, so each frame's flight bearing is the one the ledger records |
| 3 | `03_cog.py` | Move each image by its placement shift, stamp it with descriptive and provenance metadata, and write it once as a COG. A file is replaced only when its bytes change |
| 4 | `04_s3_upload.R` | Re-check every item against its COG (`stac_validate.py`), back up the published collection and item JSONs, then sync to S3 with SHA-256 checksums and spot-check what arrived |
| 5 | `05_stac_register.py` | Create a STAC record for each image — location, date, properties, `file:checksum`, provenance — merge into the published collection, and validate |
| — | `stac_validate.py` | The pre-sync checks: checksum and size against the file, COG layout, COG tags against item properties, the named provenance set, the closed vocabularies |
| — | `cog_rewrite-check.py` | The writer check for a change to the Python environment (#44). For every local COG it makes `03_cog.py`'s own call, `write_cog()` with `frame_tags()` and `shift_of()` of the frame's window row, in a temp dir, and compares the bytes. It skips 03's guards, the pipeline-SHA refusal among them (run constants, ledger selection, manifest vouching, orphans), none of which changes the bytes written, and it visits existing COGs only. A `differs` is the environment, or an input changed since 03 last wrote the COG: windows rebuilt by 01, a GeoTIFF rewritten by 02, or `03_cog.py` itself; a COG with no window row or no GeoTIFF is an `error:`. Run it right after a `uv lock` upgrade, before any stage runs under the new lock: the local COGs are its reference. Exits 1 unless every COG is the same; per-frame verdicts go to `data/logs/rewrite/<stamp>.csv` |
| — | `cog_render-compare.py` | The render check, a spot check run before and after a sync. It draws a seeded sample of frames (two per band shape, plus any `airp_id`s named) the way a GDAL client does: alpha over a checkerboard, so fill shows as checkerboard and black stays black. Each frame's PNG shows published, local and a diff, with differing pixels in magenta. Per frame it compares the bytes and counts differing pixels at full resolution and at every overview level. `--expect-same` exits 1 on any difference. The PNGs and `summary.csv` go to `data/logs/render/<stamp>/` |
| — | `../data-raw/tables_import-georef_validate.R` | Imports the measured per-roll rotation and per-frame placement tables from the private validation repo into `data-raw/rotation_roll.csv` and `data-raw/placement_frame.csv`, stamped with the source commit |
| — | `airphoto_props.py` | Turns a catalogue row into `airphoto:` item properties and `metadata`-role assets. Imported by both step 5 and the backfill so the two cannot disagree; not run directly |
| — | `../tests/` | Unit tests. `test_airphoto_props.py` covers the two coercions that fail silently (`Y`/`N` to boolean, and the `0` sentinel); `test_cog.py` the single-write COG stage (shift, alpha and nodata kept, overviews carry the alpha, only a GeoTIFF whose image bands are all masked by a trailing alpha written, layout, determinism) — `uv run pytest tests/ -q`. `test_render.py` checks that the render check's fill, black and diff panels show what they claim. `test_stacs_config.py` pins `stacs.toml` to `05_stac_register.py` and the installed stacs to its tag, and runs `stacs audit` over items shaped like ours. `test_aoi.R` covers the guards in `aoi.R` that must fail toward abort, and the rotation rule — `Rscript tests/test_aoi.R`. Both from the repo root |
| — | `test_pipeline.R` | Run a 100-photo sample through the full pipeline to verify everything works after code changes |

## Backfilling items published before a metadata change

Steps 1-5 only ever rewrite items whose COG is on the machine running them. When
a change adds a property, every item published from a machine that no longer has
its COGs keeps the old shape — the collection then answers a question for part of
its coverage and silently not for the rest. These four scripts close that gap
(built for #21; reusable for the next one).

| Order | Script | What it does |
|------|--------|--------------|
| 1 | `06_catalogue_fetch.R` | Take the item ids from the **published** `collection.json` and fetch a catalogue row for each, by `airp_id`, in batches of 500. Refuses unless every requested id comes back |
| 2 | `06_catalogue_backfill.py` | Fetch each published item over HTTPS, add the new properties and assets, write to `--out-dir` (default `data/stac_patched/`). Touches nothing live. `--limit N` for a smoke run |
| 3 | `06_catalogue_validate.py` | Seven guards — COUNT, BOOLEAN, DIAGONAL, VALUES, SENTINEL, ADDITIVE, SCHEMA. ADDITIVE re-fetches the live items, so it can actually disagree with the writer |
| 4 | `06_catalogue_promote.sh` | Runs all of the above in the one order that is safe, validates again on the promoted tree, then syncs |

```bash
Rscript scripts/06_catalogue_fetch.R
uv run python scripts/06_catalogue_backfill.py
bash scripts/06_catalogue_promote.sh          # or --no-sync to stop before S3
```

Two things worth knowing before you use `--limit`:

- Item links are sorted by href, and the first item with a photogrammetric
  solution is at index **1915** — so a smoke run smaller than that contains no
  `patb_georef` asset at all and the DIAGONAL guard compares two constants. The
  validator prints `VACUOUS:` when this happens rather than letting a green
  partial run read as evidence.
- The sync is not the end. pgstac still holds the old items until the collection
  is re-registered with `stacs register --config stacs.toml --mode all` (After the
  Pipeline, below).

### Property casing, because pgstac `=` is case-sensitive

`bcgs_tile` is **lowercase** (`093l01044`) and mixes 1:20,000, 1:10,000 and
1:5,000 mapsheets in one column; `nts_tile` is **uppercase** (`093L01`). Both are
the catalogue's own convention, confirmed against
`bcdata::bcdc_describe_feature()`. `ground_sample_distance` is in **centimetres**
and is omitted where the catalogue holds `0`, which is a missing-value sentinel.

## Data Flow

```
BC Data Catalogue (provincial web service)
  ↓ 01_fetch — download thumbnails
data/raw/thumbs/{year}/*.jpg
  ↓ 02_georef — position on map
data/raw/georef/thumbs/{year}/*.tif
  ↓ 03_cog — shift by the measured placement, embed metadata, write once as COG
data/stac/thumbs/{year}/*.tif
  ↓ 04_s3_upload — push to cloud storage
s3://stac-airphoto-bc/thumbs/{year}/*
  ↓ 05_stac_register — build searchable catalog
data/stac/{airp_id}.json              (one record per photo)
data/stac/collection.json             (collection-level summary)
```

Note the numbering does not match the run order: `04_s3_upload.R` runs **after**
`05_stac_register.py`, so a run publishes its own STAC output. The `06_*` scripts
are a separate, occasional path rather than a sixth step.

## Re-running is Safe

Every step checks for existing outputs and skips work that's already done. You can re-run the pipeline after adding new photos or fixing a single step without reprocessing everything:

| Step | What gets skipped |
|------|-------------------|
| 01 | Catalogue query cached per AOI as `data/centroids/<id>.parquet` (set `FORCE_REFRESH = TRUE` to re-query); already-downloaded thumbnails are kept |
| 02 | GeoTIFFs already on disk whose recorded inputs (rotation, bearing, footprint digest, fly build, pipeline commit, source JPG) are unchanged — `data/raw/georef/manifest.csv`; a changed input regenerates the file |
| 03 | Nothing is skipped, but a COG is only replaced when its bytes change, so an unchanged one keeps its mtime |
| 04 | Files already on S3 with the same size and a timestamp no older than the local file |
| 05 | Rebuilds item records from local COGs, then merges them into the published collection — idempotent, and it never drops a published item link |

## What is per-AOI and what is shared

```
data/aoi/<id>.gpkg               per-AOI   the resolved AOI polygon
data/centroids/<id>.parquet      per-AOI   cached catalogue query (8 km buffer)
data/neighbours/<id>.parquet     per-AOI   every catalogue frame on the window's rolls (for +/-1 neighbours)
data/window/<id>.parquet         per-AOI   the fetch window + roll neighbours, sized, with rotation, placement, provenance
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
asserted. Reasons: `selected`, `no_footprint`, `footprint_misses_aoi`,
`no_bearing`, `no_thumbnail_url`, `fetch_failed`, `georef_failed`. A selected
frame's `selection_basis` says why: `footprint` (it reaches the AOI) or
`published` (it is already in the collection, and is rebuilt so no item keeps
the old geometry). The declared column set is
`aoi_ledger_cols()`, and `aoi_ledger_write()` refuses a ledger missing any of
them — including one written before #20, which carries no terrain columns. It
also refuses one whose `aoi_id` is not the AOI (`aoi_ledger_check_id()`): before
#32 every ledger held the catalogue's WFS feature ids there.

`no_footprint` replaced `digital_unknown_format` in #20, and the rename is not
cosmetic. The old reason keyed on `footprint_basis == "unknown_format"`, a
string fly stopped writing for these frames once fly 0.6.0 could size digital
ones — after which an unsized frame fell through to `footprint_misses_aoi` and
was reported as *sized, but missing the AOI* for a frame that was never sized at
all. It now keys on `footprint_terrain` being absent, which is the property
itself.

Digital frames are no longer excluded. fly 0.6.0 sizes them from `pixel count x
ground_sample_distance`, and on `se_c` at fly 0.10.0 that is **188 of 1,013**
frames which fly 0.5.0 refused, leaving 15 genuinely unsizeable. Those 15 all
gain footprints when terrain correction is switched on — see
`aoi_dem_enabled()`.

`footprint_terrain`, `width_source`, `footprint_bearing`, `height_agl` and
`dem_coverage` are `fly`'s own reporting columns and land in the ledger
unchanged — all six of them, which is what `aoi_footprint_cols()` declares. With
the DEM off the last two are empty on every row, which the report says rather
than showing a blank table.

`georef_failed` is currently the outcome for most film frames, and that is
deliberate rather than a fault. fly 0.9.0 refuses a rotated film frame without
its roll's measured rotation, `aoi_rotation_ok()` no longer supplies one that
would suppress that refusal, and issue #23 carries the table. Measured cold on
`se_c`: 11 of 88 georeference — the digital frames plus one unrotated film
frame. Note `fly_georef(overwrite = FALSE)` skips GeoTIFFs already on disk, so
re-running over a populated tree reports success for frames it did not write.

**The committed reports under `data/reports/` still use the old vocabulary, and
that is deliberate.** They are the only tracked artifact under `data/`, and they
describe the collection as *published* — a fly 0.5.0 selection. Regenerating them
here would have them describe a selection nobody published, so they are
regenerated when #23 rebuilds and republishes. Until then, expect
`digital_unknown_format` in the committed reports and `no_footprint` from the
code.

## Prerequisites

| Component | What's needed |
|-----------|---------------|
| R packages | `fly`, `fresh`, `flooded`, `terra`, `sf`, `dplyr`, `arrow`, `purrr`. No fly version is pinned — `aoi_require_fly()` asserts that `dem` reaches `fly_filter()`, `fly_footprint()` and `fly_georef()`, which is the capability the pipeline depends on. Take the latest fly. |
| Python (uv) | [uv](https://docs.astral.sh/uv/). `pyproject.toml` + `uv.lock` declare `pystac`, `rasterio`, `shapely`, `pyarrow`, and [`stacs`](https://github.com/NewGraphEnvironment/stacs) at the tag `pyproject.toml` pins; `uv run` builds `.venv/` on first use |
| geopro | For pgstac registration: tailnet SSH to `root@geopro` with a key that logs in non-interactively. stacs runs on this machine and loads through `pypgstac` on the host; the database password stays there |
| AWS CLI | Configured with write access to `s3://stac-airphoto-bc` |

## After the Pipeline

The pipeline produces COGs on S3 and STAC catalog files on disk. To make the collection searchable at `images.a11s.one`, register it into pgstac with [`stacs`](https://github.com/NewGraphEnvironment/stacs), after the S3 sync, from the repo root:

```bash
uv run stacs register --config stacs.toml --mode all
uv run stacs verify   --config stacs.toml
```

`stacs.toml` declares the catalogue: the API, the collection id, the bucket, the
`thumbnail` asset every item must carry, and the STAC host it writes through.
`register` reads the **published** `collection.json`, fetches every item it links,
and audits every item it will send (collection id, the `thumbnail` asset, no id
twice; under `--mode all`, every item) before
anything reaches the database; then it upserts the collection, then the items, and
checks the API serves the bodies it sent. Nothing is deleted.

`--mode all` re-sends every item. `--mode drift` compares each published body with
the one the API serves, by digest, and sends the collection and only the missing and
the different items, so it does refresh items a rebuild rewrote; use it when a run
touched few. `verify`
makes the same comparison in both directions, changes nothing, and is the one that
fails on orphans (ids registered but no longer published); `--out-dir` writes the
id lists. `--dryrun` on `--mode all` reads `collection.json` only and probes neither
the API nor the host.

The merged collection is still load-bearing, as the set everything is compared
against: a `collection.json` listing only the newest AOI would register just that
AOI and `stacs verify` would report every other item as orphaned.
`05_stac_register.py` asserts against the written file that no published link was
dropped, and refuses to promote a collection that fails.

Do not use `stac_register-pypgstac.sh`: it deletes the collection before
reloading, and a failure between the two leaves the API empty.

Registering loads the STAC records into the PostgreSQL database that powers the search API. Once registered, the collection is available in QGIS (via the STAC Data Source Manager), through the API at `images.a11s.one`, or any STAC-compatible client.

### Building the Python environment

```bash
uv sync    # or let the first `uv run` do it
```

`uv.lock` pins every package, rasterio included, and rasterio's PyPI wheel bundles
the GDAL that writes the COGs. It holds the versions the conda environment had when
the published collection was built (rasterio 1.5.1, GDAL 3.12.4), and under it
`03_cog.py`'s writer reproduced all 10,100 local COGs byte for byte (#44). That was
measured with the macOS arm64 / CPython 3.12 wheel (`.python-version`); the lock names
other platforms' wheels too, and those are different binaries, never compared.

Upgrade a package as its own change (`uv lock --upgrade-package <pkg>`), then run
`uv run python scripts/cog_rewrite-check.py` **before any stage runs under the new
lock**: it rewrites every local COG from its GeoTIFF and its window row, as 03 does, in
a temp dir, and reports any whose bytes would change. A new GDAL can rewrite every COG,
and the sync would re-upload them. The local COGs are its reference, so once 03 has run
under the new lock they are the new env's output and the check passes against itself;
a lock-only bump does not move `pipeline_sha` (#45), so 03 does not refuse to run.
`cog_render-compare.py` cannot see this either: it compares files already written.
The rewrite check covers COGs only. For the item JSON (a pystac bump, say), run
`uv run python scripts/05_stac_register.py --out <scratch dir>` and compare it with
`data/stac`, likewise before 05 runs under the new lock.

The stacs tag in `pyproject.toml` and the one `uv.lock` resolved must agree;
`tests/test_stacs_config.py` fails when they do not.

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
