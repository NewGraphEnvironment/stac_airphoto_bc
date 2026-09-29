## Outcome

fly 0.19.0 (fly#56) writes grayscale georef output as Gray + Alpha with no NoData. `03_cog.py` lost the alpha colorinterp on the 2-band in-memory copy, so `check_same_raster()` refused every grey frame. Creating that copy with `ALPHA=YES` keeps it, and on RGBA it changes no bytes.

The guard grew in review. Round 2 found that "the last band is alpha" passes Gray + Alpha + NoData 0, where GDAL lets the NoData win and masks interior black again. Round 3 found the mechanism: a colorinterp, or a resampling setting, was being credited with a property it does not guarantee. So 03 now checks the mask a reader sees: every image band must be masked `[per_dataset, alpha]`. The test table enumerates band counts 1–5 × trailing alpha × NoData, and a mutation table shows every part of the guard is load-bearing; that enumeration ended the review loop.

A cold local rebuild on fly 0.19.0 then replaced all 10,100 COGs. The plan review also caught a stale published-id snapshot (9,976 of 10,100 ids), which was refreshed before 01 ran; the freshness guard is #37. The S3 sync and the geopro registration were deliberately left undone and are open in #36.

## Measurement

- **Band shape, per path:**
  - 3,746 grey COGs went from 1-band NoData 0 to Gray + Alpha
  - 6,354 RGBA stayed RGBA
  - 0 carry a NoData; 0 have alpha values outside {0, 255}
- **The defect removed:** 2,216 of 3,746 grey frames (59%) get back 71,100 genuine-black pixels that the published shape wrote as 1.
  - Against the S3 copies (three worst frames, all roll bcb94081, plus the median frame), every differing interior pixel is old 1 → new 0, with the same grid and the same fill.
- **No geometry change:**
  - `footprint_digest` changed on 0 of 10,100 items.
  - None of fly's 53 roll-table rolls has a selected frame here, so fly 0.16–0.18's height corrections do not reach these AOIs. That turned "the rebuild may move footprints" from a risk into a measured zero.
- **Run:**
  - 01 took 35 min, 02 88 min (10,100 regenerated, 0 reused, cold path confirmed by mtime), 03 55 min (10,100 written).
  - 05: 0 published items missed. `stac_validate`: 10,100 of 10,100 items pass.
- **Wrong turns kept:**
  - The plan credited nearest resampling with keeping overview alpha binary. GDAL 3.12.4 keeps it binary under `average` and `cubic` too.
  - The first guard checked colorinterp; the second added a NoData check, which made the no-alpha test vacuous. The property-based check replaced both.

## Evidence

- Run logs (local, gitignored): `data/logs/rebuild36/*`
- Snapshot of the pre-rebuild state: `data/_pre36/`
- Reviews: `review-plan.md`, `review-round*.md` in this directory

Closed by: PR (Part of #36; the issue stays open for the sync and registration)
