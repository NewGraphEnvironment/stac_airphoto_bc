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
| fly guard | A **window**, `>= 0.6.0 && < 0.9.0`, not the floor the issue names. |

### Why a window and not a floor

Measured 2026-09-07. At **≥ 0.9** two things degrade, one of them silently:

- `fly_bearing()` returns `NA_real_` for any frame whose roll neighbour is outside the
  8 km window (`fly/R/fly_bearing.R:105`; NEWS 0.9.0 "breaking for sampled input"). The
  window is a spatial subset of every roll, so `aoi_rotation()` falls back to the fixed
  180° that fly#25/#26 exist to correct — no error, no warning.
- `fly_georef()` refuses a rotated film frame without the roll's measured `rotation`,
  and that table is #23's deliverable.

fly's own working tree is at **0.10.0**, one `devtools::install()` away, so a bare floor
is a guard that fails toward pass on the version most likely to arrive.

## Phase 1: The fly version window

`aoi_require_fly(ver = utils::packageVersion("fly"))` in `scripts/aoi.R`, taking the
version as an argument so it is testable at 0.5.0 / 0.6.0 / 0.8.0 / 0.9.0 / 0.10.0
without touching the installed library.

- [ ] `aoi_require_fly()` with two distinct messages — below 0.6.0 names fly#35 and the
      absent digital sizing; at or above 0.9.0 names both degradations and **#23** as
      what lifts the ceiling
- [ ] `tests/test_aoi.R` — abort at 0.5.0, 0.9.0, 0.10.0; pass at 0.6.0 and 0.8.0
- [ ] Call it from `01_fetch.R`, `02_georef.R`, `test_pipeline.R` (`03_cog.R` has no fly)
- [ ] Prose floors → the window: `run_pipeline.sh:8`, `scripts/README.md:178`, `CLAUDE.md:24`
- [ ] Upgrade fly to 0.8.0 — the installed 0.5.0 fails the new guard

## Phase 2: Stop discarding the result; carry it to the ledger

- [ ] Keep `footprint_basis`, `footprint_terrain`, `height_agl`, `dem_coverage`;
      `stop()` naming fly#35 if any is absent — the guard that would have caught the
      original bug
- [ ] Add the three to the ledger `transmute()` (`01_fetch.R:91-103`).
      `data/selected/<aoi>.parquet` gets them free.
- [ ] `aoi_ledger_cols()` + schema check in `aoi_ledger_write()`. An old ledger lacks
      the columns, so `02_georef.R` alone against one must fail with "re-run 01_fetch.R"
- [ ] Report section in `aoi_report_write()`: counts by `footprint_terrain`, plus a
      `dem_coverage` summary. Handle the DEM-off case explicitly rather than rendering
      an empty table.

## Phase 3: Thread `dem` to every stage that sizes a footprint

- [ ] `aoi_dem_enabled()`, `aoi_dem()`, `aoi_path("dem", …)`. Buffer is
      `FETCH_BUFFER_M` + 6000 — fly buffers past the *corner* of the widest footprint
      (`half_side * sqrt(2)`; widest film here is 7,242 m, giving 5,121 m)
- [ ] `01_fetch.R` — `dem` to `fly_footprint()` **and** `fly_filter()`
- [ ] `02_georef.R` — `dem` to `fly_georef()`, which sizes its own footprints
      (`fly/R/fly_georef.R:183`)
- [ ] `test_pipeline.R` — the same two threads, or it drifts from the stages it tests

## Phase 4: Drop the tbl_df workaround

- [ ] Remove the `as.data.frame()` coercion and reason 1 of the `aoi_centroids_as_sf()`
      docstring. Only the class-stripping half goes; rebuilding points from
      `longitude`/`latitude` stays.
- [ ] Confirm the tibble-backed result by running, not by reading

## Phase 5: Docs and verification

- [ ] `CLAUDE.md` — fly#35 known issue goes; DEM known issue rewritten as wired-and-off
      with #23 naming the flip; ledger schema gains the three columns
- [ ] `scripts/README.md` — `flooded` prerequisite, ledger columns, `Rscript tests/test_aoi.R`
- [ ] DEM-off run of `01_fetch.R se_c`, reconciled against the committed ledger
- [ ] DEM-on smoke — **the selected set must differ**, or `dem` did not reach `fly_filter()`
- [ ] Restore `data/reports/` and confirm it is clean before each commit

## Validation

- [ ] `Rscript tests/test_aoi.R` green, both guards proven against both answers
- [ ] `conda run -n stac-airphoto-bc pytest tests/ -q` still green
- [ ] `/code-check` clean on each commit
- [ ] PWF checkboxes match landed work
- [ ] `/planning-archive` on completion

## Out of scope, deliberately

- Running the rebuild. #23 owns it, including the per-roll rotation table, digital
  sizing from the photogrammetric solution, and re-deriving **both** regions in one pass.
- Promoting the terrain columns to STAC properties.
- fly ≥ 0.9. The ceiling is the mechanism that keeps it out until #23 is ready.
