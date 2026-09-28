# Task: The ledger's aoi_id holds WFS feature ids, not the AOI id (#32)

## Problem

`scripts/01_fetch.R` builds the ledger with `dplyr::transmute(aoi_id = id, ...)`. The centroid cache carries the catalogue's own `id` column (`WHSE_IMAGERY_AND_BASE_MAPS.AIMG_PHOTO_CENTROIDS_SP.<n>`), and dplyr's data masking resolves `id` to that column before the loop variable. Measured 2026-09-27: `unique(read_csv("data/select/se_c.csv")$aoi_id)` returns feature ids, not `"se_c"`. Present at 9818d6f, so it predates #23.

## Phase 1: Tests first (red)
- [x] `tests/test_aoi.R`, in the existing transmute-block section: assert `outputs`
      assigns `aoi_id` from an injected value (`aoi_id = !!id` or `.env$id`), and that a
      bare `aoi_id = id` is absent
- [x] New `aoi_ledger_check_id()` section, both answers on fixtures with rows: accepts a
      ledger whose `aoi_id` is all `id`; refuses feature ids, a mix, and `NA`; refusal
      names the AOI, an offending value, and the remedy (`01_fetch.R`); zero-row ledger passes
- [x] Run `Rscript tests/test_aoi.R` — the new assertions fail (function absent, bare `id`)

## Phase 2: Fix
- [x] `scripts/01_fetch.R:208` → `aoi_id = !!id`, with a one-line comment on why
- [x] `scripts/aoi.R`: add `aoi_ledger_check_id(ledger, id)` beside
      `aoi_ledger_check_cols()`; call it from `aoi_ledger_write()` (covers 01 and 02's write)
- [x] `scripts/02_georef.R:70`: call it on the read path next to `aoi_ledger_check_cols()`,
      so a stale ledger aborts before any GeoTIFF is written (same reason as that comment)
- [x] `Rscript tests/test_aoi.R` green; mutation: revert to `aoi_id = id` and drop the
      writer call, confirm each goes red, restore (work on a copy, `cmp` after)

## Phase 3: Repair the written ledgers and docs
- [ ] Rewrite `aoi_id` in `data/select/{neexdzii_kwa,se_a,se_b,se_c}.csv` in place: read
      all-character, set `aoi_id <- id`, write; verify every other column is byte-identical
      (`cut -d, -f2-` diff before/after) and `unique(aoi_id) == id`. Local data only,
      gitignored — record the command and result in progress.md
- [ ] Re-render nothing: reports do not carry `aoi_id` (confirm `git status` shows no
      `data/reports/` change)
- [ ] CLAUDE.md: drop the Known issues line "The ledger's `aoi_id` holds WFS feature ids…"

## Validation
- [ ] Tests pass
- [ ] `/code-check` clean on each commit
- [ ] PWF checkboxes match landed work
- [ ] `/planning-archive` on completion, then `/gh-pr-push`

