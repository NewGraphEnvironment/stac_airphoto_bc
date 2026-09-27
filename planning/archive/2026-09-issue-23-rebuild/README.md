## Outcome

Rebuilt the whole collection (#23, folding in #28, #29, #30) on fly 0.15.0. Every published frame is regenerated with:
- per-roll scanning rotation from the private orthophoto validation, or a series default, labelled `rotation_source`
- per-frame measured placement shifts, applied as a translation of the georeferenced raster, labelled `placement_source`
- DEM-corrected footprints

Each thumbnail carries a sha256 `file:checksum` and the fly and pipeline commits that built it. `03_cog.R` + `03_cog_tag.py` became a single deterministic rasterio write (`03_cog.py`), because the old path had silently broken every published COG in three ways: COG layout, NoData=255, and lost colour interpretation.

The review loop's lasting lesson is one mechanism, found five times: a raster's inputs were assumed single-valued and recorded when some were computed per AOI window, or never recorded. Instances:
- stale GeoTIFFs relabelled with the current run's provenance
- footprints not vouched for
- a shared frame sized differently by two AOIs, through a reprojected DEM grid and window-edge bearings
- 02's commit and the source JPG unrecorded

It ended with the ±1 roll-neighbour padding, a native-grid DEM, a manifest recording every raster-shaping input, and an enumeration of those inputs (progress.md). The DB tunnel proved unnecessary: the only DB use is the watershed polygon, which the local `fresh-db` serves. Publishing is the step after merge.

## Measurement

- **Before → after on se_c:** before this branch, 11 of 88 selected frames georeferenced; fly 0.9 refused film without a per-roll rotation. After, 102 of 102.
- **Full rebuild:**
  - 10,100 COGs: neexdzii_kwa 9,824, se_a 167, se_b 161, se_c 102.
  - Dry-run register `--require-all-published`: 9,976 → 10,100 links, 0 not rebuilt, and every item passes the checksum, layout, tag/property and vocabulary checks.
  - Neexdzii Kwa: all 9,741 published frames selected, 83 new, 0 `no_bearing`, 0 published ids outside every window.
- **Rotation sources:** measured 2,470, reviewed 1,951, disputed 252, assumed_by_series 4,124, digital 1,027.
- **Placement:** correlator 252, roll_model 113.
- **Placement equals fly's warp of a shifted footprint:** bounds within 1e-6 m; pixels identical (RGBA) or at most 1 DN (grey).
- **Known-answer frames:**
  - bc5282 165: 0 m from the validated rebuild.
  - bc83062 123: 332 m from it, which is exactly the applied correlator shift √(120² + 310²).
- **Window-edge bearings:** before the neighbour padding, 74 of 669 frames shared by se_a and se_b had bearings up to ~2° apart. After, 0 of 669 bearings and footprint digests differ.
- **DEM margin:** raised 6,000 → 10,000 m after the shortfall guard caught 7 selected frames 2,008 m past the DEM on se_a. The union keeps published frames anywhere in the window.
- **DEM evidence (from stac_orthophoto_bc):** width within 0–2% of the photogrammetric solutions; fitted film scale 0.909 → 1.000, closer on 45 of 50 frames.
- **Wrong turns kept:**
  - `pipeline_sha` first used HEAD and a bare `-dirty`, then moved to the last code commit plus a digest of the uncommitted diff.
  - The first NK run died on a transient WFS error.
  - The second died on WFS batches typing a column differently (`aoi_match_types()`).

## Evidence

Run logs are local and gitignored: `data/logs/rebuild/all_20260927T043156.log` (the full rebuild) and `data/logs/rebuild/se_2026092*`. Reviews: `review-plan.md`, `review-p1-round*.md`, `review-p26-round*.md` in this directory.

Closed by: PR #31
