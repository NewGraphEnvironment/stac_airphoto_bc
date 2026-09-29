# Task: Grayscale georef outputs become Gray + Alpha: COG writer drops the alpha colorinterp (#36)

## Problem

fly's next release (NewGraphEnvironment/fly#56) changes the shape of every **grayscale** GeoTIFF `fly_georef()` writes: **1 band with `NoData=0` → 2 bands, Gray + Alpha, no NoData.** RGB is unchanged (4 bands, RGBA). The reason: under `-dstnodata 0` GDAL rewrote genuine black inside the frame as 1 so it would not read as fill. Measured on the output of the 182 calibration grayscale thumbnails: 161 frames warped axis-aligned, up to 3.6% of a frame on roll bcb94081, and 41 frames at a 30-degree bearing, up to 0.26%. It happens silently on sf's GDAL 3.8.5 and is printed as a warning by other builds, including the Windows CI runner's, which also gave masked grayscale 2 bands (fly#68). *(Body corrected 2026-09-28: an earlier version said the black was "written as nodata", quoted the source-side 3.5%, and called the shift Windows-specific. fly's own review measured all three as wrong.)*

## Phase 1: Tests first (`tests/test_cog.py`)
- [ ] `fly_like()` grey fixture becomes fly 0.19's shape: 2 bands Gray + Alpha, no nodata, collar alpha 0. Update the module docstring, which still says "grey frame with nodata 0".
- [ ] The parametrised round-trip test covers gray+alpha. Confirm it goes **red** on the current `write_cog()`.
- [ ] New test: overviews respect alpha. A fixture ≥1024 px so the COG driver builds overviews. At every level, alpha is only 0/255 and the dataset mask equals the alpha band.
- [ ] New test: a 1-band `NoData=0` GeoTIFF (fly < 0.19's shape) is refused, with a message naming the cause.
- [ ] Parametrise the determinism test over gray and RGBA.

## Phase 2: Writer (`scripts/03_cog.py`)
- [ ] In `write_cog()`, set `profile["alpha"] = "YES"` when `colorinterp[-1] == ColorInterp.alpha`, with a comment saying why: rasterio ignores an alpha colorinterp on a 2-band GTiff unless it was created with ALPHA=YES.
- [ ] Refuse a source with no alpha band. This asserts the capability at the point it matters: a GeoTIFF from fly < 0.19 carries black→1 rewrites, and a rebuild with an old fly would republish that shape. No version number goes into the code.
- [ ] Update the `check_same_raster()` docstring to cover the new shape.
- [ ] `pytest tests/ -q` green. Then restore each defect and watch its test fail: without `alpha=YES` → the gray round-trip test is red; without the refusal → the refusal test is red.

## Phase 3: Docs
- [ ] `CLAUDE.md`:
  - COG shape per source: gray → Gray+Alpha, RGB → RGBA, never a NoData.
  - The new refusal in 03.
  - Known issue: until the sync, the published grayscale COGs are 1-band `NoData=0` with black→1. Local and S3 differ between the rebuild and the sync.
- [ ] `scripts/README.md`, if it describes the COG shape.

## Phase 4: Local cold rebuild on fly 0.19.0 (no publish)
- [ ] Commit phases 1–3 first. `pipeline_sha` stamps uncommitted code as `-dirty`, and Rscript must not be edited mid-run.
- [ ] Snapshot for the diff into `data/_pre36/`: `data/select/*.csv`, `data/window/*.parquet`, the item JSONs.
- [ ] Install fly 0.19.0 from GitHub (unpinned, per the Architecture section). `tests/test_aoi.R` must be green, including the footprint-column check.
- [ ] Run each stage on its own, logging to `data/logs/rebuild36/` (not `run_pipeline.sh`, which ends in the upload):
  - `01_fetch.R` for all AOIs, with the fresh-db env
  - `02_georef.R`
  - `03_cog.py --check-determinism`, then `03_cog.py`
  - `05_stac_register.py --require-all-published`
  - `stac_validate.py`
- [ ] Measure:
  - band shape over every COG: gray is 2 bands `(gray, alpha)`, RGB is 4, none has a NoData
  - item count, and published ids not rebuilt (expect 0)
  - selection diff against the snapshot ledgers (new, dropped)
  - `height_source` counts before and after
  - footprint width change distribution on the corrected frames
- [ ] Write the numbers into `findings.md`, and later the archive README's Measurement and Evidence sections.

## Phase 5: Close out
- [ ] Edit the #36 body: tick the writer, tests and overview items, and state what remains (sync plus `catalogue_register.sh --all` on geopro).
- [ ] `/planning-archive`, then `/gh-pr-push`. The PR says "Part of #36", not "Closes", so the issue stays open until the publish.

## Validation
- [ ] Tests pass
- [ ] `/code-check` clean on each commit
- [ ] PWF checkboxes match landed work
- [ ] `/planning-archive` on completion
