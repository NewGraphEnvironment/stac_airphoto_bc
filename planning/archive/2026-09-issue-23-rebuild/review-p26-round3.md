# Code-check round 3: staged diff p26 (#23)

Reviewer: subagent, 2026-09-26. Diff: `scratchpad/diff-p26r3.patch`. This round tests the session's
statement of the mechanism and its enumeration (progress.md, last bullet). Tests at review time, run in
the scratch copy `scratchpad/cc-r3/w`: `Rscript tests/test_aoi.R` all pass, `pytest tests/` 49 passed.

## The mechanism, restated

The session wrote: "03 labels a raster from the window, but the raster's identity is only in the manifest."
The assumption underneath is narrower than that: **each frame has exactly one window and one set of
inputs.** The manifest is global and keyed by GeoTIFF path. The window is per AOI, and 03 and 05 collapse
it to the first AOI in sort order (`load_windows`, `load_build_meta` `setdefault`). The comparison between
the two is sound only while every AOI that holds a frame would record the same inputs for it. That fails
for shared frames, which is finding 1. The enumeration also has a second gap: it lists what fly was *given*
(rotation, ring, fly build) and leaves out what 02 itself passes and reads, which is finding 2.

## Findings

- **[severity: bug]** scripts/03_cog.py:173-199 (`load_windows`), 241-258 (`vouched`); scripts/02_georef.R:142-168; scripts/aoi.R:591-624 (`aoi_dem`). **For frames two AOIs share, the footprint digest depends on which AOI computed it.** Two consequences follow. A full run leaves 02 regenerating those GeoTIFFs back and forth, and 03 then refuses them on every run.

  **Why the digest differs.** The DEM is per AOI. `flooded::fl_dem_aoi()` crops MRDEM in its own CRS with `snap = "out"`, then calls `terra::project(r_clip, target_crs$wkt)` with no template. So each AOI's DEM lands on its own EPSG:3005 grid, with its own bilinear-resampled values. The digest is centimetre-rounded, so it sees that difference.

  **Probe (scratch, `cc-r3/w/probe_dem.R`).** I projected the se_c DEM to EPSG:3979 at 30 m to stand in for the source. I cropped it twice, the second crop smaller by only ~3 cells at one corner, so both crops cover the same ground. I projected each crop to 3005 as `fl_dem_aoi` does and ran `fly_footprint()` on se_c's selected rolls with each DEM:
  - **78 of 102** selected frames got a different `aoi_footprint_digest`;
  - median area difference 77 m², maximum 1,692 m²;
  - median `height_agl` difference 1 cm.

  **Shared frames exist.** se_a and se_b are about 1.5 km apart. Their centroid caches share **669** frames, and the pre-#23 ledgers (`data/_pre23/data_select/`) have **60** frames selected in both.

  **What happens on a run.** Take `run_pipeline.sh` with no ids, which runs AOIs in registry order:
  1. `02 se_a` writes frame X at A's digest.
  2. `02 se_b` finds that the manifest (A) is not `want` (B). It unlinks the GeoTIFF, regenerates it, and records B.
  3. 03 builds `by_stem` from the first window in sort order, which is se_a, so the meta digest is A while the manifest holds B. It refuses with "written on a different footprint than the window records".
  4. The remedy the message gives ("Re-run 02_georef.R for their AOI") repeats step 2. Only running `02 se_a` last happens to clear it.

  `load_windows` compares rotation and placement across windows but not `footprint_digest`, `height_source` or `footprint_basis`, so nothing names the real cause. A simulation confirms it (a copy of se_c's window saved as `se_b.parquet` with altered digests): `load_windows` raised nothing, and `vouched` refused **102 of 102**.

  This fails toward refusal, not pass. When the manifest matches the first window, the labels and the raster agree. But no full rebuild with overlapping AOIs can get through 03, and each run rewrites every shared GeoTIFF twice. Round 2 recorded the missing cross-window comparison as "could not measure". Now that 03 vouches on the digest, it is a hard failure.

  Fix direction:
  - (a) Build every AOI's DEM on one fixed 3005 grid, e.g. `terra::project(x, template)` onto a global 30 m origin. Where two crops overlap they then give identical cells.
  - Or (b) make the shared frame's inputs one fact. For example, 03 and 05 could pick the window row whose digest matches the manifest and refuse only when none does, and 02 could skip regenerating a GeoTIFF whose recorded digest matches another AOI's current window.

  Either way, add `footprint_digest` to `load_windows`' agreement check, or have it report the disagreement, so the refusal names its cause.

- **[severity: fragile]** scripts/02_georef.R:152-155 with scripts/03_cog.py:210-216 and 241-258. **The enumeration files `pipeline_sha` under "refused on mismatch", but the refusal compares the commit that ran 01 (the window) with the commit running 03 (HEAD).** The commit that ran **02** is recorded nowhere. 02 is the one pipeline stage whose code shapes the pixels: it chooses `fly_georef()`'s arguments (`rotation = "auto"`, and `mask` / `mask_threshold` / `srcnodata` left at fly's defaults) and the `ph` set. The manifest keys reuse on rotation, bearing, digest and fly SHA only.

  How it is reached:
  1. Commit Y changes 02's `fly_georef()` call, for example `mask = "none"` or a `mask_threshold`.
  2. The operator re-runs 01 at Y, as 03's refusal tells them to, then 02 at Y. Every manifest key is unchanged, so every GeoTIFF written by the old call is reused.
  3. 03 at Y passes its HEAD check and tags `PIPELINE_SHA=Y`. 05 publishes `nge:pipeline_sha` Y over rasters that Y's code did not produce.

  The same gap covers the other raw input to `fly_georef()`, the **source JPG**. It is not in the manifest either. `fly_fetch()` writes straight to the destination with `download.file()` and guards only on size > 0, so a killed download leaves a truncated JPG that is blessed on every later run. The natural repair is to delete the JPG and re-run 01. That does not regenerate the GeoTIFF, because every manifest key still matches.

  Both are silent and both need a trigger: a pixel-affecting edit to 02, or a bad thumbnail. Fix direction: record 02's `aoi_provenance()$pipeline_sha` in the manifest and have 03 tag *that* value (or refuse when it differs from the window). Record `tools::md5sum(fr$dest)` of the source JPG and regenerate when it changes.

## Checked and found sound

- **The DEM beyond the ring.** In `fly_georef()` (fly 988d1b1, `R/fly_georef.R:209`) the DEM reaches the raster only through `fly_footprint(photos_sf, dem = dem)`, the same call 02 digests. So the digest does cover the DEM for a single AOI, and a rebuilt DEM or raised `aoi_dem_corner()` regenerates.
- **Mask and srcnodata.** These are fly defaults inside `fly_georef()`, so `fly_sha` covers them unless 02 starts passing them (finding 2).
- **GDAL, terra and rasterio versions.** No tag or property claims them, so an upgrade that leaves an older raster in place does not falsify any label. 03 rewrites the COG from the GeoTIFF every run, so 03-side library and code changes always apply.
- **`footprint_basis` and `height_source`.** Both come out of the same `fly_footprint()` call as the ring. At a fixed fly SHA, an unchanged digest implies unchanged inputs to that call, so the session's claim that the digest covers them holds for one window. It does not hold across windows (finding 1).
- **`rotation_source`, `placement_source` and the shift.** A source-only relabel at the same rotation value is a true relabel of an identical raster. 03 applies the shift and placement at write.
- **Second writers.** `scripts/test_pipeline.R:80` calls `fly_georef()` into the shared `data/raw/georef/thumbs/` tree without writing manifest rows or checking bearing or digest. Its new GeoTIFFs therefore have no manifest row, and 03 refuses them loudly (the test stops before 05 and 04). The next 02 unlinks and regenerates them as rowless, so the production path recovers. `06_catalogue_backfill.py` writes only to its `--out-dir`. No other script writes GeoTIFFs, COGs or item JSONs under `data/stac`. `05` attaches any `data/stac/scans/**` COG as `visual` without vouching, but nothing writes scans today.
- **03/05 window choice.** Both take the first window in sorted path order (`load_centroids` sorts; `load_build_meta` sorts and uses `setdefault`), so tags and properties come from the same row.
- **Tests.** R assertions all pass; pytest 49 passed (scratch copy, identical scripts).
