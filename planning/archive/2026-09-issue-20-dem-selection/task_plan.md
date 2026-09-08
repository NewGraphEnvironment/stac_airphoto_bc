# Task: Selection does not use a DEM, discards fly's reporting columns, and pins no fly version (#20)

Three defects in the selection path, all of which make the reporting surface say less
than it appears to.

1. **`fly_footprint()`'s result is discarded except one column.** `01_fetch.R:83` keeps
   only `footprint_basis`, so `footprint_terrain`, `height_agl` and `dem_coverage` —
   the three columns fly 0.5.0 added to make terrain handling auditable — can never
   reach the ledger even on a fly build that returns them correctly.
2. **A DEM passed to `fly_footprint()` would not change selection.** Selection is
   `fly_filter()` at `01_fetch.R:87`, which builds its own footprints
   (`fly/R/fly_filter.R:50`). Reported scale understates footprint **area by a median
   14%, to 26%**, always in the same direction.
3. **No fly version pin.** Three places say `>= 0.5.0` in prose and nothing enforces
   it. Installed here is fly 0.5.0, which still carries the fly#35 tibble bug that
   drops exactly those four columns.

**#23 owns the rebuild** and says #20 "should land first or together". So the DEM is
wired and left **off**; #23 flips one constant and re-derives both regions together,
which is what `CLAUDE.md:169` requires.

## Decisions taken (user, 2026-09-07)

| | |
|---|---|
| DEM | Wired through, `aoi_dem_enabled()` returns `FALSE`. Selection unchanged today; #23 flips it. |
| DEM source | `flooded::fl_dem_aoi()` — MRDEM-30 via `/vsicurl/`, crop before reproject, returns a `SpatRaster`, which is what fly's `dem` takes. New dependency. |
| Reporting columns | Ledger + `data/selected/<aoi>.parquet` only. Not promoted to STAC — #23 promotes them when every item gets them at once. |
| fly guard | **Capability asserts, no version comparison.** fly 0.10.0 installed. |
| Film rotation | **Not supplied where fly has rotated the ring**, so fly refuses those frames into `georef_failed` rather than being handed a value that disarms its own guard. Decided by the user after round 3 measured it. #23 supplies the table. |

### Why no version number — the issue's 0.6.0 is stale

#20 was filed **2026-08-30** and never edited. fly 0.6.0 and 0.7.0 shipped that same
day, so "pin at 0.6.0" meant "pin at current" when it was written. Four releases have
landed since — 0.7.1, 0.8.0 (09-01), 0.9.0 (09-02), 0.10.0 (09-07) — and #23, filed
09-06, wants fly 0.9 at a pinned SHA.

A version *window* was considered and rejected this session. It would have pinned this
repo to 0.8.0, superseded on 09-02, which #23 lifts within its own scope. And the
breakage it guarded against is one fly already refuses loudly by itself:
`fly_georef()` returns `success = FALSE` for a rotated film frame with no per-roll
rotation (`fly/R/fly_georef.R:284`), which `02_georef.R:94-96` folds into the ledger as
`georef_failed`. A ceiling here is a second copy of that refusal, and it is the copy
that goes stale. `CLAUDE.md` — "Assert capabilities, not versions".

What #20 actually depends on, both true from fly 0.5.1 through 0.10.0:

1. `fly_filter()`, `fly_footprint()` and `fly_georef()` each take a `dem` argument.
2. `fly_footprint()` returns the four columns on **tibble-backed** sf input, which is
   what `bcdata::collect()` gives (fly#35, fixed in 0.5.1).

### Measured on fly 0.10.0, 2026-09-07, over `data/centroids/se_c.parquet` (1,013 frames)

All four columns returned on `sf,bcdc_sf,tbl_df,tbl,data.frame` input — fly#35 confirmed
fixed against the real shape, not a constructed one.

| `footprint_basis` | n | | `footprint_terrain` | n |
|---|---|---|---|---|
| Film - BW | 522 | | `nominal_scale` | 810 |
| Film - Colour | 288 | | `gsd_scaled` | 188 |
| Digital - Colour | 188 | | `NA` (no footprint) | 15 |
| `inferred_format` | 15 | | | |

The 188 digital frames are ones fly 0.5.0 rejected as `unknown_format` — 18.6%, matching
`scripts/README.md:170`. The remaining 15 have no footprint at all, and fly's own
warning names `dem` + `flying_height` + `focal_length` as what would size them, so the
DEM is load-bearing for those too.

### Consequence to state in the PR — corrected by measurement

The prediction here was that `02_georef.R` would report `georef_failed` for rotated
film until #23 lands the per-roll rotation table. **That is wrong**, and the run says
so: `02_georef.R se_c` georeferenced **88/88**, including the 10 digital 2018 frames.
fly only skips a rotated film frame when `rotation` is `NA`, and this pipeline supplies
one for every film frame.

The real consequence is narrower and quieter: fly 0.9.0 changed what a `rotation`
*value* means — it used to shift corners on an axis-aligned square and now shifts them
on a ring already rotated onto the bearing — so `aoi_rotation()`'s film values are
calibrated against the old meaning. Film georeferencing is therefore unsettled rather
than blocked, and #23 owns it with the table measured for 54 rolls. Recorded in
`CLAUDE.md`; nothing in this issue rebuilds or republishes.

## Phase 1: Assert the capabilities, not the version

`aoi_require_fly()` in `scripts/aoi.R`, taking the formal names as an argument so the
refusing case is reachable without a second fly installed. Cheap enough to run at the
top of every stage; the column capability is checked where the real call happens
(Phase 2), because a formal is not evidence a column comes back.

- [x] Upgrade fly — **0.10.0 installed** from the `v0.10.0` tag, `RemoteSha 1337d024`,
      so this install carries provenance where the 0.5.0 it replaced carried none
- [x] `aoi_require_fly()` — asserts `dem` is a formal of `fly_filter`, `fly_footprint`
      and `fly_georef`; message names fly >= 0.5.1 as the remedy and why
- [x] `tests/test_aoi.R` — accepts the real fly, refuses a formal set with `dem` missing
      from each of the three in turn, and names the offending function. Also refuses an
      empty or under-named set, which the first version passed
- [x] Call it from `00_review_samples.R`, `01_fetch.R`, `02_georef.R` and
      `test_pipeline.R` — four fly callers, not the three the plan first named; the
      plan review caught `00_review_samples.R`. `03_cog.R` genuinely has no fly.
      A test asserts every script loading fly calls the guard
- [x] Prose floors → what is actually required: `run_pipeline.sh:8`,
      `scripts/README.md:178`, `CLAUDE.md:24`

## Phase 2: Stop discarding the result; carry it to the ledger

- [x] Keep `footprint_basis`, `footprint_terrain`, `height_agl`, `dem_coverage`;
      `stop()` naming fly#35 if any is absent — the guard that would have caught the
      original bug
- [x] Add the three to the ledger `transmute()` (`01_fetch.R:91-103`).
      `data/selected/<aoi>.parquet` gets them free.
- [x] `aoi_ledger_cols()` + schema check in `aoi_ledger_write()`. An old ledger lacks
      the columns, so `02_georef.R` alone against one must fail with "re-run 01_fetch.R"
- [x] Report section in `aoi_report_write()`: counts by `footprint_terrain`, plus a
      `dem_coverage` summary. Handle the DEM-off case explicitly rather than rendering
      an empty table.

## Phase 3: Thread `dem` to every stage that sizes a footprint

- [x] `aoi_dem_enabled()`, `aoi_dem()`, `aoi_path("dem", …)`. Buffer is
      `aoi_fetch_buffer()` + 6000 — fly buffers past the *corner* of the widest footprint
      (`half_side * sqrt(2)`; widest film here is 7,242 m, giving 5,121 m)
- [x] `01_fetch.R` — `dem` to the single `fly_footprint()` call. **Not** to
      `fly_filter()`: it is no longer used, because it builds a second set of
      footprints. Selection is `st_intersects()` on the one result, proven set-identical
- [x] `02_georef.R` — `dem` to `fly_georef()`, which sizes its own footprints
      (`fly/R/fly_georef.R:183`)
- [x] `test_pipeline.R` — the same two threads, or it drifts from the stages it tests

## Phase 4: Drop the tbl_df workaround

- [x] Remove the `as.data.frame()` coercion and reason 1 of the `aoi_centroids_as_sf()`
      docstring. Only the class-stripping half goes; rebuilding points from
      `longitude`/`latitude` stays.
- [x] Confirm the tibble-backed result by running, not by reading

## Phase 5: Docs and verification

- [x] `CLAUDE.md` — fly#35 known issue goes; DEM known issue rewritten as wired-and-off
      with #23 naming the flip; ledger schema gains the three columns; digital-frames
      known issue updated (fly 0.6.0+ sizes them, so the exclusion no longer holds)
- [x] `scripts/README.md` — `flooded` prerequisite, ledger columns, `Rscript tests/test_aoi.R`,
      and the `digital_unknown_format` paragraph, which fly 0.10.0 makes stale
- [x] DEM-off run of `01_fetch.R se_c`, reconciled against the fly 0.5.0 ledger
      preserved before the upgrade — there is no *committed* ledger, since `.gitignore`
      excludes everything under `data/` but the reports. 215 of 1,013 rows moved and
      every one is accounted for: 203 digital (188 gained a footprint, 15 still
      unsized) **and 12 film**, 6 each way. "No film row moves" was wrong — fly 0.9.0
      rotates film footprints onto the flight line and all 12 movers sit on diagonal
      bearings.
- [x] DEM-on smoke — **the selected set must differ**, or `dem` did not reach `fly_filter()`
- [ ] Edit #20's body to record that the 0.6.0 prescription was overtaken, and add the
      ≥0.9 georef finding to #23
- [x] Restore `data/reports/` and confirm it is clean before each commit

## Validation

- [x] `Rscript tests/test_aoi.R` green, both guards proven against both answers
- [x] `conda run -n stac-airphoto-bc pytest tests/ -q` still green
- [x] `/code-check` clean on each commit
- [x] PWF checkboxes match landed work
- [x] `/planning-archive` on completion

## Out of scope, deliberately

- Running the rebuild. #23 owns it, including the per-roll rotation table, digital
  sizing from the photogrammetric solution, and re-deriving **both** regions in one pass.
- Promoting the terrain columns to STAC properties.
- fly ≥ 0.9. The ceiling is the mechanism that keeps it out until #23 is ready.

## Landed beyond the original plan

Found by the plan review and the code-check rounds, each measured before acting:

- **`aoi_film_mask()`** — a `rotation` column is the highest-precedence input in
  `fly_georef()` (`fly/R/fly_georef.R:341-344`) and `aoi_rotation()` never returns
  `NA`, so every digital frame would have been georeferenced a quarter turn out with
  nothing downstream reporting it. Harmless before fly 0.6.0, live now. Verified:
  `rotation` non-`NA` on all 810 film frames, `NA` on all 203 digital.
- **`digital_unknown_format` → `no_footprint`**, re-keyed on `is.na(footprint_terrain)`.
  The old reason keyed on a `footprint_basis` string fly stopped writing, after which
  unsized frames fell through to `footprint_misses_aoi` and were reported as *sized,
  but missing the AOI* for frames never sized at all.
- **Selection no longer goes through `fly_filter()`.** It built a second set of
  footprints, which is defect 2 of #20 with a DEM on both sides. Replaced with one
  `st_intersects()` on the single result, proven set-identical (91 = 91, symmetric
  difference 0).
- **`00_review_samples.R`** gained the guard and the DEM thread — it filters with fly
  and would otherwise sample a different set than the pipeline selects.
- **`aoi_fetch_buffer()`** — the 8 km figure was typed into `01_fetch.R` and again into
  the report prose. One source now.
- **The ledger check moved to the top of `02_georef.R`'s loop.** Its message says
  "re-run 01_fetch.R", and it used to arrive after every GeoTIFF had been written.

## Changed after round 3 (user decision, 2026-09-07)

Round 3 measured that the `rotation` column **disarms** fly 0.10.0's refusal to
georeference a rotated film frame without its roll's measured rotation — and that
`aoi_rotation()`'s per-frame value varies within a roll where the property is a
per-roll constant (34 of 48 rolls get 2-4 values). It also showed that the
"88/88 georeferenced" reported earlier in the session was the **warm path**: cold,
the same command gives 11/88.

That invalidated the argument used to drop the fly version ceiling — that a
ceiling merely duplicates a refusal fly already makes. fly does make it; this
pipeline was suppressing it. Put back to the user, who chose:

**Stay on fly 0.10.0 and let fly refuse film.** `aoi_rotation_ok()` supplies a
rotation only where fly has not rotated the ring and only for film. On `se_c`
that is 3 frames; 807 rotated film frames and 203 digital frames get `NA`, and 77
selected film frames land as `georef_failed`. The pipeline produces almost no
film output until #23 lands the per-roll table, and that is the intended state:
loud and visible beats 807 frames written possibly a quarter turn out.

- [x] `aoi_rotation_ok()` replaces `aoi_film_mask()`, keyed on fly's own routing
      condition `is.na(footprint_bearing)`
- [x] `aoi_footprint_cols()` widened from four to **six** — fly returns
      `width_source` (0.6.0) and `footprint_bearing` (0.9.0) and the transmute
      #20 exists to fix was still dropping both. Ledger is now 15 columns.
- [x] `aoi_terrain_values()` — an unrecognised fly terrain route aborts rather
      than being classified on a string this code has never seen
- [x] Three test assertions proven defeatable by mutation, all three now red on
      the mutation that defeated them
