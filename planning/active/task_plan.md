# Task: Rebuild the collection on current fly: per-roll rotation, measured placement, DEM-corrected footprints (#23)

Folds in #28 (bearing re-derived on a thinned set), #29 (fly 0.12 `height_source`) and
#30 (checksums, run provenance, item JSON kept before overwrite).

The collection was last rebuilt in March under #13 (fly 0.3.0, `rotation = "auto"`).
Rotation was guessed per frame from bearing (it is a per-roll constant, now measured for
67 of 69 rolls); film has no terrain correction (fitted scale 0.909 published, 1.000 with
fly + DEM); 2012 digital ships 2.2-2.8x oversized and 2019 29% undersized. The private
accuracy work (`stac_orthophoto_bc`) supplies per-roll rotations and per-frame placement
shifts. **The PR stops at a validated local cold rebuild and dry-run register; the S3
publish and geopro reload are a separate step after merge.**

## Phase 0: Issue body and baseline
- [x] Edit #30's body: the COG-layout finding, and "tag before the COG write" as a requirement
- [x] Branch `23-rebuild-the-collection-on-current-fly`, PWF baseline, plan review (Plan agent, concurrent)

## Phase 1: The tables, committed and reproducible
- [x] `data-raw/tables_import-georef_validate.R` (renamed noun-first): reads `stac_orthophoto_bc/data/georef_validate/{rotation_table,placement_frame}.csv` and writes reduced copies. Refuses a dirty source tree, and records the source commit
- [x] `data-raw/rotation_roll.csv`: `film_roll, rotation, rotation_source` (`measured` = correlator `decided`/`majority`; `reviewed` = `decided_confirmed`/`decided_by_eye`; the 2 unresolved rolls are left out so they fall to the series rule)
- [x] `data-raw/placement_frame.csv`: `airp_id, placement_source, shift_x_m_3005, shift_y_m_3005`. Every row, with `none` kept, so absent means outside the table
- [x] Guards in the import: 67 rolls, 10,239 frames, counts by source 252/211/9,776, rotations limited to {0, 90, 180, 270}, `bc81050`/`bcc668` carry no shift

## Phase 2: fly and the DEM
- [x] Install fly 0.14.1. `aoi_footprint_cols()` gains `height_source` (0.12), `dem_shortfall_m`, `dem_elev_sd` (0.14); `aoi_terrain_values()` re-pinned against fly's source; the tests re-pinned
- [x] `aoi_dem_enabled()` → `TRUE`. Docstrings and CLAUDE.md prose that say "off, waits for #23" are updated
- [x] Ledger columns gain `height_source`, `rotation_source`, `placement_source`, `shift_x_m_3005`, `shift_y_m_3005`. The ledger check and report are updated to match (also `dem_shortfall_m`, `dem_elev_sd`, `selection_basis`)

## Phase 3: Rotation from the table (replaces the bearing guess)
- [x] `aoi_rotation_default(film_roll, year)`: `bc5xxx` through 1974 → 0; `bc5xxx` 1975-76 → 90 and flagged for review; every other film series → 90. Aborts on a `bc5xxx` year outside those bins, or on an unrecognised series, rather than guessing — returns NA rather than aborting; `01_fetch.R` stops only when a SELECTED film frame is NA (bc4xxx in the window must not abort a run)
- [x] `aoi_rotation_for(window)`: film → the table value, else the series default, with `rotation_source`. Digital → `NA` (fly's measured mapping). Replaces `aoi_rotation()` + `aoi_rotation_ok()` in `01_fetch.R`, and both are removed along with their tests
- [ ] Bearingless film frames: counted per AOI. A per-roll value on an axis-aligned ring assumes the flight ran north, so they go to the ledger as `no_bearing` rather than being written possibly turned. If Neexdzii Kwa has more than a handful, I stop and bring you the count
- [x] The report lists every roll at `assumed_by_series`, and the 1975-76 `bc5xxx` rolls as "review each"
- [x] Tests: the series boundaries, the table taking precedence over the default, digital left `NA`, and an unknown series aborting (the bug restored, and each guard shown to fire)

## Phase 4: Georef from the intact window (#28)
- [x] `01_fetch.R` writes the window's per-roll inputs. `02_georef.R` passes `photos_sf` = the **window** frames of that year (rolls intact) and `fetch_result` = the selected frames only. fly footprints all of `photos_sf` and georeferences only `fetch_result` (`fly_georef.R`, loop over `results`) — per ROLL rather than per year (plan review 2a), plus a GeoTIFF manifest so a changed input regenerates (2c)
- [x] Assert that the bearing fly uses equals the ledger's `footprint_bearing` for every written frame (#28's 1 of 88 on `se_c` goes to 0)

## Phase 5: Placement shift (translate the raster)
- [x] `03_cog.R` applies `terra::shift(r, dx, dy)` before the COG write, looked up by `airp_id`. The raw GeoTIFF stays fly's own output, so a re-run shifts exactly once (idempotent by construction, never by skip) — became `03_cog.py`: rasterio single write (translation of the geotransform); terra's COG writer also broke nodata/alpha (plan review 1)
- [x] Equivalence check on 3-5 frames with non-zero shifts: our shifted output against `stac_orthophoto_bc`'s `shift_footprint()` + `fly:::georef_one()`. Same bounds to < 1 cm, same pixels — 2 se_c frames (grey rot 0, RGBA rot 90) with an artificial shift: bounds equal to 1e-6 m, pixels identical / max 1 DN; se_c has no measured shifts (findings)
- [x] The shift and its source are carried to the COG tags and item properties

## Phase 6: #30, provenance and checksums
- [x] Tagging moves **before** the COG write: tag the georef GeoTIFF (or the in-memory raster), then write the COG. A validator confirms `IFDS_BEFORE_DATA` holds — in-memory copy; validator checks ghost header flag + IFD offset
- [x] Provenance tags and properties: fly version + SHA, pipeline SHA, run datetime, rotation/placement/height source. Names follow `stac_floodplains_bc` where they fit — no run datetime in tags (determinism); `nge:produced_datetime` on items from COG mtime
- [x] `05_stac_register.py`: `file:checksum` (sha256 multihash, `1220…`) + `file:size` on `thumbnail`, file extension v2.1.0, and the new `airphoto:` properties via `airphoto_props.py`
- [x] Validator before the sync: recompute checksums from disk; provenance keys as an absolute named set; COG layout
- [x] Determinism: COG + tag one unchanged input twice, and the bytes must be identical
- [x] `04_s3_upload.R`: copy every published item JSON to a dated prefix before the sync. Drop `--size-only` for COGs: a rebuilt COG of the same byte size would otherwise be skipped silently — plus validator first, `--checksum-algorithm SHA256`, head-object spot check

## Phase 7: The union, then the cold rebuild
- [ ] Selection = new DEM-corrected selection ∪ published `airp_id`s in the window, with a ledger reason for "kept because published". Measure how many published ids fall **outside** every window, and stop and ask if any do
- [ ] Move the local derived trees aside (`data/raw/georef`, `data/stac`) so the run is **cold**. `fly_georef(overwrite = FALSE)` and `03_cog.R` otherwise skip what exists (CLAUDE.md warns about this)
- [ ] Run all four AOIs (Neexdzii Kwa needs `fresh` for the watershed, and about 9.7k thumbnail fetches). Logs go to `data/logs/`, and the counts to findings
- [ ] Dry-run register (`--out`) against the live collection: item count = the union, merge assertions pass, every item carries the checksum and provenance, COG validity on all of them
- [ ] Known-answer frames: `bc5282` frame 165 and `bc83062` frame 123 against the review page's regenerated rasters (same place to a few metres); counts by `rotation_source`/`placement_source` against the tables

## Phase 8: Docs and wrap-up
- [ ] CLAUDE.md and README: Current State, and the Known-issues entries that #23 resolves (film refused, DEM off, digital mis-sized) rewritten or removed, with the publish step documented
- [ ] `research/` is not needed: the verdicts live in `stac_orthophoto_bc`, and the archive README carries this run's measurements
- [ ] `/planning-archive`, `/gh-pr-push` (closes #23, #28, #29, #30)

## After merge, on your word (not in this PR)
Back up the item JSONs → `04_s3_upload.R` → geopro reload → stac_orthophoto_bc#45 re-baselined.

## Validation

- [ ] Tests pass
- [ ] `/code-check` clean on each commit
- [ ] PWF checkboxes match landed work
- [ ] `/planning-archive` on completion
