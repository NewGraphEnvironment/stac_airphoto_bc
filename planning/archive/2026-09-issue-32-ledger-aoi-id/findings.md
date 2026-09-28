# Findings — The ledger's aoi_id holds WFS feature ids, not the AOI id (#32)

## Issue context

**If we fix it:** the ledger's `aoi_id` names the AOI, so ledgers can be concatenated and grouped by area. **If we never do:** every `data/select/<id>.csv` carries WFS feature ids in `aoi_id`, and anything that ever groups on it groups on nonsense. Nothing reads it today; no published item is affected.

## Problem

`scripts/01_fetch.R` builds the ledger with `dplyr::transmute(aoi_id = id, ...)`. The centroid cache carries the catalogue's own `id` column (`WHSE_IMAGERY_AND_BASE_MAPS.AIMG_PHOTO_CENTROIDS_SP.<n>`), and dplyr's data masking resolves `id` to that column before the loop variable. Measured 2026-09-27: `unique(read_csv("data/select/se_c.csv")$aoi_id)` returns feature ids, not `"se_c"`. Present at 9818d6f, so it predates #23.

## Fix

`aoi_id = !!id` (or `.env$id`), and a test in `tests/test_aoi.R` that the transmute block uses an injected value — the existing parse-based check of that block is where it fits.

## Measured before the fix (2026-09-27)

Distinct `aoi_id` values per on-disk ledger, all `WHSE_IMAGERY_AND_BASE_MAPS.AIMG_PHOTO_CENTROIDS_SP.<n>`:
`neexdzii_kwa` 14,858, `se_a` 818, `se_b` 840, `se_c` 1,013.

- Nothing reads `aoi_id`: not `aoi_report_write()`, not `02_georef.R`, not the Python stages.
- `data/select/` is gitignored (`.gitignore:7 data/*`); the tracked `data/reports/*.md` do not render `aoi_id`.
- `scripts/aoi.R:487` `data.frame(aoi_id = id)` is base R — no data masking, correct.
- Repair chosen over re-running `01_fetch.R`: a re-run needs fwapg for `neexdzii_kwa`
  and resets `02_georef.R`'s `georef_failed` outcomes, forcing a 02 re-run, to change one column.

## Errors Encountered

| Error | Resolution |
|-------|------------|
| Stray `git checkout -- .` reverted uncommitted Phase 2 edits | Recovered from the mutation copy; commit before any mutation run |
| Mutation baseline exited 1 | Copy lacked `data-raw/` (`aoi_rotation_table()` reads it); symlink it too |
