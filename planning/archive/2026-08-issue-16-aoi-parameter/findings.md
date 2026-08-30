# Findings — Point the pipeline at a second area (#16)

## Measured during plan-mode exploration (2026-08-29)

| # | Finding | Evidence |
|---|---|---|
| 1 | Local `data/` does not exist — no parquet cache, no COGs, no item JSONs | `[ -d data ]` false; existing 9,741 items live only on S3 |
| 2 | `05_stac_register.py` would REPLACE the collection, not extend it | reads all metadata from one `data/centroids_raw.parquet`; computes `collection.json` links + extent only from items it just built |
| 3 | Centroid cache has no AOI in its key | `if (force_refresh || !file.exists(cache_path))` — 2nd AOI silently reuses 1st AOI's centroids |
| 4 | `test_pipeline.R:68` calls `fly::fly_thumb_georef()`, removed in fly 0.3.0 | not in `getNamespaceExports("fly")` |
| 5 | A 5th hardcoded AOI the issue did not list | `test_pipeline.R:21 blue_line_key = 360873822` |
| 6 | Installed `fly` is 0.3.0; local source tree is 0.5.0 | issue requires >= 0.4.0 |
| 7 | fly >= 0.4.0 gives digital frames EMPTY geometry (`footprint_basis = "unknown_format"`) | `fly_film_media()` ships only `"Film - BW"`, `"Film - Colour"`; fly#32 open |
| 8 | `media` column IS present in the centroid layer | confirmed in `fly/inst/testdata/photo_centroids.gpkg` |
| 9 | Anonymous `ListBucket` DENIED on `s3://stac-airphoto-bc`; authenticated listing works (9,742 objects at root) | `aws s3 ls --no-sign-request` -> AccessDenied; authed -> 9,742 `.json` |
| 10 | `collection.json` IS anonymously readable (GetObject public) | `curl` returns it with 9,741 item links |
| 11 | Published extent | `[-126.9605625124543, 53.98428549959949, -125.73744986575, 54.73610913846966]`, temporal `1968-05-09` .. `2019-09-18` |
| 12 | Single-pathed outputs that clobber across AOIs | `data/aoi.gpkg` (`delete_dsn = TRUE`), `data/fetch_log.csv`, `data/georef_log.csv`, `data/cog_log.csv` |

## Decisions locked with the user (pre-baseline)

| Decision | Choice | Rationale |
|---|---|---|
| Digital frames (~20%) | Exclude, report count per AOI | Satisfies "what selection rejected and why"; fly#32 is the follow-up that closes it |
| DEM footprints (fly 0.5.0 `dem`) | Not this run | Keeps new AOIs derived like the published 9,741; avoids a half-corrected collection |
| Selection | `fly_select(mode = "minimal", target_coverage = 0.95)` within 3 eras (pre-1980, 1980–1999, 2000+) | The breaks the issue itself measured |

## Errors Encountered

| Error | Resolution |
|-------|------------|

## Issue context (full body, as of 2026-08-29)

## Problem

The collection serves 9,741 photos spanning 1963–2019 over a single watershed,
extent `-126.96, 53.98, -125.74, 54.74`. Queried anywhere else it returns zero,
which reads as a broken query rather than an extent limit.

The archive is not regional. The pipeline is built on
[`fly`](https://github.com/NewGraphEnvironment/fly), whose exported surface is
area-agnostic. The limit is that it has only ever been pointed at one area —
**and the AOI is hardcoded, in three places**:

```r
scripts/01_fetch.R:12          blk <- 360873822
scripts/01_fetch.R:13          drm <- 166030.4
scripts/00_review_samples.R:23 blue_line_key = 360873822
scripts/02_georef.R:15         blue_line_key = 360873822
```

Everything downstream of the AOI is already area-agnostic. **The deliverable is
lifting that constant into a parameter and proving the run on a second area.**

## Scope: three small AOIs in southeast BC

| AOI | bbox | area |
|---|---|---|
| A | `-116.0758, 49.0953, -116.0635, 49.1060` | 1.03 km² |
| B | `-116.0549, 49.1127, -116.0427, 49.1221` | 0.91 km² |
| C | `-117.9819, 49.2420, -117.9729, 49.2502` | 0.58 km² |

Small deliberately. The targets are ~1 km², but film footprints are kilometres
wide, so `01_fetch.R` buffers the AOI by 8 km before querying. Measured centroid
counts in the buffered fetch window:

| | photos |
|---|---|
| A + B (buffers overlap; 2 km apart) | **1,624** |
| C | **1,429** |
| **total fetch window** | **~3,050** |

`fly_filter(method = "footprint")` then narrows to frames whose **footprint**
overlaps the target — a centroid outside a 1 km² AOI can easily have a footprint
covering it, which is the reason to use footprints rather than a point-in-polygon
test.

### Why not the whole region

An earlier version of this issue proposed three whole watershed groups,
`-118.31, 49.00, -115.60, 50.33`. Measured: **110,395 centroids** — about 11x the
entire existing collection, and roughly 40 GB of thumbnails. That is not a first
run of a pipeline that has executed once. A second run's job is to surface every
hardcoded assumption; 110k photos does not test that better, it fails slower.
The region stays as a follow-up once the parameterisation is proven.

## The four steps, each a deliverable

1. **Select** — footprints over the AOI, chosen by overlap and era rather than
   taking everything (`fly_footprint`, `fly_overlap`, `fly_select`)
2. **Fetch** — thumbnails for the selected frames (`fly_fetch`)
3. **Georeference** — to COG (`fly_georef`)
4. **Register** — S3 upload and items into `stac-airphoto-bc`

Thumbnails are what gets catalogued. The provincial georeferencing behind
`PATB_GEOREF_URL` requires purchasing the photo, so it is not a shortcut here —
the thumbnail is the product, and there is often enough in it to read the story
before deciding whether a purchase is warranted.

## Measured before starting, so these are not open questions

- **Archive density in the south is high, not sparse.** 680 centroids in one
  0.15 x 0.10 degree box, spanning **1964–2018**: 76 pre-1980, 393 in 1980–1999,
  165 from 2000 on.
- **Thumbnails are free and live.** 1978 film and 2011 digital both return
  HTTP 200, ~270–420 KB JPEG.
- **20% of frames are digital**, focal length 92/100 mm against 153/305 mm on
  film, with `GROUND_SAMPLE_DISTANCE` populated where film mostly has none.
  **Requires `fly` >= 0.4.0** — 0.3.0 sizes every frame from a 9-inch negative
  that a digital sensor does not have (fly#30).
- The centroid layer is
  `WHSE_IMAGERY_AND_BASE_MAPS.AIMG_PHOTO_CENTROIDS_SP`. The scale field is
  `SCALE`, a string like `"1:15000"` — querying `PHOTO_SCALE` returns all
  `NULL`, which reads as missing data rather than a wrong field name.

## Acceptance

- The AOI is a **parameter**, not three edited constants
- `/search` returns items over the new AOIs
- Collection extent covers both regions; existing items intact — this extends
  coverage, it does not replace
- Report per AOI: frames selected, year range obtained, and what selection
  rejected and why

