# Plan review (Plan agent, 2026-09-26)

Returned as reply text (Plan agents cannot write); recorded here by the session.

Findings, as triaged:

| # | finding | class | disposition |
|---|---|---|---|
| 1 | terra COG writer sets NoData=255 and drops colour interp/alpha on published COGs | Blocker | Confirmed on `bcc98035_140` (published: 4x undefined, nodata 255; raw: RGBA, per-dataset alpha). Fixed: 03_cog.py writes via rasterio COG copy; pixels, mask, colorinterp identical to raw. Post-write assertion added |
| 1b | equivalence test must use srcnodata NULL, fresh temp paths, grey + colour | Acceptance | Adopted for Phase 5 check |
| 1c | 03 cannot map filename -> airp_id; unmatched would silently shift 0 | Gap | Fixed: window lookup, unmatched aborts |
| 2a | year slice exact only if no roll spans years | Gap | Fixed: subset window by the selected frames' rolls |
| 2b | bearing assertion has nothing to read | Gap | Fixed: 02 computes fly_footprint on the same `ph` and compares |
| 2c | frames shared between AOIs; reuse of stale GeoTIFFs | Assumption | Fixed: georef manifest; a GeoTIFF whose recorded rotation/bearing/fly differs is regenerated |
| 2d | Phase 3 must not land without Phase 4 | Ordering | Adopted: one commit |
| 3a | withholding works only if frame never reaches fly_georef | Gap | Holds: `no_bearing` is decided in 01 before `selected` is written |
| 3b | bearingless DIGITAL frames written axis-aligned at 180 | Gap | Fixed: `no_bearing` applies to any bearingless frame with a footprint |
| 3c | disputed rolls labelled measured | Scope | Fixed in Phase 1 (`disputed`, user decision) |
| 4a | 02 resets rejected_reason, erasing "kept because published" | Blocker | Fixed: separate `selection_basis` column |
| 4b | published frames that fail silently keep old items | Blocker | Fixed: 05 `--require-all-published` lists and fails; decision on unbuildable frames goes to the user with numbers |
| 4c | measure published-outside-window before fetch; pin snapshot | Gap | Adopted in Phase 7 |
| 4d | bc4xxx series in window | Assumption | Holds: `norot` stop scoped to selected frames |
| 5a | 03 skip existing COGs | Ordering | Fixed: content-compare replace |
| 5b | run_pipeline.sh publishes | Blocker | Adopted: Phase 7 runs stages individually |
| 5c | test_pipeline.R publishes and samples thinned | Blocker | Fixed georef to roll-subset window; not run in Phase 7 |
| 5d | 06_catalogue_promote.sh can revert the rebuild | Gap | Fixed: refuses once local items carry file:checksum |
| 5e | DEM cache reused unchecked | Gap | Fixed: 01 aborts if any selected frame has dem_shortfall_m > 0 |
| 6 | tag-before-COG mechanism open; terra drops tags | Blocker | Fixed: in-memory rasterio copy, tags verified in output |
| 7a | run time in tags breaks determinism | Blocker | Fixed: no run time in tags; `nge:produced_datetime` from COG mtime on items |
| 7b | pipeline SHA changes bytes by design; dirty tree; fly RemoteSha | Assumption | `-dirty` suffix; RemoteSha required |
| 7c | checksum check at upload time | Ordering | Fixed: 04 runs stac_validate.py first |
| 8a | verify what arrived on S3 | Gap | 04 syncs with `--checksum-algorithm SHA256` and spot-checks head-object against file:checksum |
| 8b | item JSON backup filter order and count | Gap | Adopted |
| 9a | extent only grows | Gap | Noted, left |
| 9b | new properties' readers, file ext, CSV comment, id types | Gap | Handled (windows as source; file ext declared; R reads CSVs with comment.char) |
| 9c | required set fails on legit NA | Acceptance | Required set excludes height_source; rotation keys required on film only |
| 10 | pinned counts; stale prose | Assumption/Scope | Counts deliberate; prose in Phase 8 |
