# Task: Grayscale georef outputs become Gray + Alpha: COG writer drops the alpha colorinterp (#36)

## Problem

fly's next release (NewGraphEnvironment/fly#56) changes the shape of every **grayscale** GeoTIFF `fly_georef()` writes: **1 band with `NoData=0` → 2 bands, Gray + Alpha, no NoData.** RGB is unchanged (4 bands, RGBA). The reason: under `-dstnodata 0` GDAL rewrote genuine black inside the frame as 1 so it would not read as fill. Measured on the output of the 182 calibration grayscale thumbnails: 161 frames warped axis-aligned, up to 3.6% of a frame on roll bcb94081, and 41 frames at a 30-degree bearing, up to 0.26%. It happens silently on sf's GDAL 3.8.5 and is printed as a warning by other builds, including the Windows CI runner's, which also gave masked grayscale 2 bands (fly#68). *(Body corrected 2026-09-28: an earlier version said the black was "written as nodata", quoted the source-side 3.5%, and called the shift Windows-specific. fly's own review measured all three as wrong.)*

## Phase 1: Tests first (`tests/test_cog.py`)
- [x] `fly_like()` grey fixture becomes fly 0.19's shape: 2 bands Gray + Alpha, no nodata, collar alpha 0. Update the module docstring, which still says "grey frame with nodata 0".
- [x] The parametrised round-trip test covers gray+alpha. Confirm it goes **red** on the current `write_cog()`.
- [x] New test: overviews respect alpha. A fixture ≥1024 px so the COG driver builds overviews. At every level, alpha is only 0/255 and the dataset mask equals the alpha band.
- [x] New test: the shape table (`SHAPES`). Only an alpha-masked GeoTIFF is written; fly < 0.19's 1-band `NoData=0` and six other shapes are refused.
- [x] Parametrise the determinism test over gray and RGBA.

## Phase 2: Writer (`scripts/03_cog.py`)
- [x] In `write_cog()`, set `profile["alpha"] = "YES"`. It is unconditional because the refusal guarantees the last band is alpha. Comment why: rasterio ignores an alpha colorinterp on a 2-band GTiff unless it was created with ALPHA=YES.
- [x] Refuse a source unless every image band is masked by its last band, an alpha (`mask_flag_enums == [per_dataset, alpha]`; review-plan G5, code-check rounds 2–3). The remedy is to re-run 01 and 02 for every AOI (G2). This asserts the capability at the point it matters: a GeoTIFF from fly < 0.19 carries black→1 rewrites, and a rebuild with an old fly would republish that shape. No version number goes into the code.
- [x] Update the `check_same_raster()` docstring to cover the new shape.
- [x] `pytest tests/ -q` green. Then restore each defect and watch its test fail: without `alpha=YES` → the gray round-trip test is red; without the refusal → the refusal test is red.

## Phase 3: Docs
- [x] `CLAUDE.md`:
  - COG shape per source: gray → Gray+Alpha, RGB → RGBA, never a NoData.
  - The new refusal in 03.
  - Known issue: until the sync, the published grayscale COGs are 1-band `NoData=0` with black→1. Local and S3 differ between the rebuild and the sync.
- [x] `scripts/README.md`, if it describes the COG shape.

## Phase 4: Local cold rebuild on fly 0.19.0 (no publish)
- [ ] Commit phases 1–3 first. `pipeline_sha` stamps uncommitted code as `-dirty`, and Rscript must not be edited mid-run.
- [x] Snapshot for the diff into `data/_pre36/`: `data/select/*.csv`, `data/window/*.parquet`, the item JSONs, `collection.json`, the georef manifest, `published.parquet`.
- [x] Refresh `data/catalogue/published.parquet` (`06_catalogue_fetch.R`): it held 9,976 ids against 10,100 published (review-plan B1).
- [x] Install fly 0.19.0 from GitHub (unpinned, per the Architecture section). `tests/test_aoi.R` must be green, including the footprint-column check.
- [ ] Run each stage on its own, logging to `data/logs/rebuild36/` (not `run_pipeline.sh`, which ends in the upload):
  - `01_fetch.R` for all AOIs, with the fresh-db env and `FORCE_REFRESH` left FALSE. Then, before 02, every published id must still be selected (O1)
  - `02_georef.R`
  - `03_cog.py --check-determinism`, then `03_cog.py`
  - `05_stac_register.py --require-all-published`
  - `stac_validate.py`, only if 05 exits 0 (O2)
- [ ] Pass criteria (AC5):
  - 03 prints `N written, 0 unchanged`, with N the number of GeoTIFFs
  - 05 exits 0 with 0 published items not rebuilt
  - `stac_validate.py` reports N of N
  - 0 selected ids dropped
- [ ] Measure:
  - band shape per id against the snapshot (AC1): every old 1-band grey COG is now `(gray, alpha)` with mask flags `[per_dataset, alpha]`, every RGBA is still RGBA, and none has a NoData
  - alpha values outside {0, 255}, as a count (A1)
  - grayscale frames with a genuine 0 under alpha 255, which the old shape could not hold (AC2)
  - item count, and published ids not rebuilt (expect 0)
  - selection diff against the snapshot ledgers (new, dropped)
  - `height_source` counts before and after
  - footprint change: frames whose `footprint_digest` changed vs did not (S1), and the `height_agl` ratio on the changed ones (G4)
- [ ] Write the numbers into `findings.md`, and later the archive README's Measurement and Evidence sections.

## Phase 5: Close out
- [ ] Edit the #36 body: tick the writer, tests and overview items. State what remains: the sync, which re-uploads every COG, not only grayscale (S2); `catalogue_register.sh --all` on geopro; and a render check of a Gray + Alpha item on images.a11s.one (S4).
- [ ] File the `published.parquet` freshness guard as its own issue (S3).
- [ ] `/planning-archive`, then `/gh-pr-push`. The PR says "Part of #36", not "Closes", so the issue stays open until the publish.

## Validation
- [ ] Tests pass
- [ ] `/code-check` clean on each commit
- [ ] PWF checkboxes match landed work
- [ ] `/planning-archive` on completion
