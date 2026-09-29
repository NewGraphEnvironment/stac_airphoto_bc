# Plan review (#36): Plan agent, 2026-09-28

The Plan agent is read-only, so this is transcribed from its reply. Each finding carries its disposition.

## Blocker (conditional)
- **B1. The published-id snapshot is stale.** `data/catalogue/published.parquet` was dated 2026-09-07 and held 9,976 ids. The collection has 10,100. The 124 missing ids are protected by the union (`aoi_published_ids()`, `01_fetch.R:219-223`) only while their footprint stays on the AOI, and the fly 0.16–0.18 corrections could move one off. `05 --require-all-published` would then fail after hours of 02 and 03.
  **Confirmed (9,976 vs 10,100, 124 missing). Fixed:** the old file is copied to `data/_pre36/`, `06_catalogue_fetch.R` re-run, and the result is 10,100 rows with 10,100 unique ids. A freshness guard is filed as its own issue (S3).

## Gaps
- **G1.** No plan for a `dem_shortfall_m` abort after the height corrections widen footprints.
  **Accepted as a risk.** 01 is itself the pre-flight: it aborts before 02 starts. A margin fix is a `scripts/` change, which means a new commit and re-running 01 for every AOI. That costs minutes.
- **G2.** The refusal's remedy text says "re-run 02". 02 refuses a window sized by another fly, so the remedy is 01 and 02 for every AOI.
  **Fix.**
- **G3.** The snapshot is missing the manifest, `published.parquet` and `collection.json`, and the old grayscale COGs are overwritten locally.
  **Fixed:** all three are now in `data/_pre36/`. The old COGs stay on S3 until the sync.
- **G4.** "Footprint width change" had no method.
  **Use the `height_agl` ratio** from the ledgers, restricted to frames whose `footprint_digest` changed.
- **G5.** "Never a NoData" is documented but not enforced.
  **Fix:** refuse `nodata is not None` beside the alpha check.
- **G6.** `CLAUDE.md` "wrong in three ways until the #23 rebuild is published" is stale, and `data/reports/*.md` are tracked and rewritten by 01 and 02.
  **Reports** are committed with the rebuild. **The stale bullet** is outside this diff; it is mentioned in the PR, not edited.

## Ordering
- **O1.** Check the union right after 01: every id in the collection must still be selected.
  **Adopted.**
- **O2.** Run `stac_validate.py` only if 05 exits 0.
  **Adopted.**
- **O3.** Any `scripts/` change after the Phase 4 commit voids the rebuild (`pipeline_sha`).
  **Adopted:** code review finishes first, and PR comments that touch `scripts/` mean a re-run.
- **O4.** The alpha refusal sits in the write loop, not the pre-flight.
  **Not changed.** With an old fly, `vouched()` refuses every frame on the fly SHA before any write, so the per-frame guard is a backstop.
- **O5.** The rotated-geotransform test depends on the order of the checks.
  **Noted.**

## Assumptions
- **A1.** fly warps masked frames with `-r bilinear -srcalpha`, so real alpha may be fractional.
  **Measure** the count of COGs with alpha outside {0, 255}.
- **A2.** The refusal cannot reject legitimate input.
  **Agreed.**
- **A3.** Keep `FORCE_REFRESH` at FALSE, so selection changes come from fly alone.
  **Adopted.**
- **A4.** "Unpinned" installs fly main, `0eeb977`, two commits past v0.19.0.
  **Record it, and confirm no R/ or inst/ diff.**
- **A5.** `tests/test_aoi.R` passes on 0.19.
  **Confirmed:** all pass.
- **A6.** `alpha=YES` is set unconditionally, not "when the last band is alpha".
  **Plan wording updated.**

## Scope
- **S1.** The rebuild also carries the geometry changes from fly 0.16–0.18.
  **Report them separately** (frames whose digest changed vs did not), and say so in the PR and in #36.
- **S2.** The sync re-uploads every COG (the FLY_SHA and PIPELINE_SHA tags change), not only grayscale.
  **Adopted in the remaining-work text.**
- **S3.** Nothing checks that `published.parquet` is fresh.
  **Filed as its own issue.**
- **S4.** After the sync, check on `images.a11s.one` that a Gray + Alpha item renders with transparency.
  **Added to what remains in #36.**

## Acceptance
- **AC1.** Check band shape per id, not as a histogram, including the mask flags.
  **Adopted.**
- **AC2.** Show the defect is gone: genuine 0 under alpha 255 on grayscale.
  **Adopted.**
- **AC3.** `--check-determinism` covers one frame only.
  **Recorded.**
- **AC4.** The fixture test checks the fixture against itself.
  **Accepted:** `check_same_raster()` on every rebuilt frame is the integration check. Round 1 of code-check also warped a real thumbnail through `sf::gdal_utils` and got exactly the fixture's shape.
- **AC5.** Explicit pass criteria for Phase 4.
  **Adopted** in `task_plan.md`.
