# Progress — Selection does not use a DEM, discards fly's reporting columns, and pins no fly version (#20)

## Session 2026-09-07

- Plan-mode exploration — read `01_fetch.R`, `aoi.R`, `02_georef.R`, `05_stac_register.py`,
  the #16 and #21 archives, and issue #23. Explore agent read the fly working tree.
- Four scope forks put to the user and answered: DEM wired-but-off, ledger-only
  reporting columns, the fly guard, and `flooded::fl_dem_aoi()` as the DEM source.
  (The guard was first designed as a version *window*; superseded below.)
- One finding the issue does not name: `fly_georef()` sizes its own footprints, so the
  DEM has to reach 02_georef.R too.
- Created branch `20-dem-to-selection-fly-columns-version-window` off main
- Scaffolded PWF baseline with approved phases
- Next: Phase 1

## Session 2026-09-07 (continued)

- **The issue's fly 0.6.0 floor was stale** — #20 filed 2026-08-30, the day 0.6.0
  shipped; five releases since. The user asked; the version window I had planned was
  dropped for a capability assert carrying no version at all.
- Installed **fly 0.10.0** from the `v0.10.0` tag (`RemoteSha 1337d024`), replacing a
  0.5.0 that carried no provenance fields at all.
- Preserved the fly 0.5.0 ledgers/reports to the scratchpad before upgrading — the only
  baseline that exists, since `data/` is gitignored bar the reports.
- Plan review returned 21 findings. Acted on: `00_review_samples.R` missed entirely
  (a fourth fly caller), the `rotation`-overrides-digital-mapping bug, the rejection
  reason keyed on a string fly no longer writes, the ledger check firing after the
  expensive work, the doubled DEM read through `fly_filter()`, and the DEM-on
  assertion that could pass for the wrong reason.
- Code-check round 1 found a **circular test fixture** — built from the function under
  test, so appending a bogus column left the suite green. Fixed and proven by mutation.
- Measured, not assumed: row alignment through `fly_footprint()`; `st_intersects()`
  set-identical to `fly_filter()`; `dem_coverage` min 0.975 with none below 0.95.
- Both suites green. `data/reports/` restored to the published state.
- Next: code-check round 3, archive, PR.

## Session 2026-09-07 (round 3)

- Code-check round 3 found **two bugs**, both inside earlier work, and named the
  mechanism: every guard added asserted a property of this repo's own text or
  schema, never what fly does — and a comment cannot go red.
- **The `rotation` column was disarming fly's film refusal.** Reported earlier in
  this session as "88/88 georeferenced"; that was the warm path over a populated
  tree, and cold it is 11/88. Corrected to the user, who chose to stay on fly
  0.10.0 and let fly refuse rather than pin below 0.9.
- `aoi_film_mask()` → `aoi_rotation_ok()`, keyed on fly's own routing condition
  (`is.na(footprint_bearing)`) rather than on medium alone.
- `aoi_footprint_cols()` was a stale subset: fly returns six columns and the
  transmute #20 exists to fix was still dropping two. Ledger now 15 columns.
- Three test assertions proven defeatable by mutation and all three now fail on
  the mutation that defeated them.
- Added `aoi_terrain_values()` — an unrecognised fly terrain route now aborts
  instead of being silently classified.
- Next: archive, PR.

## Session 2026-09-07 (rounds 4-5, close)

- Round 4: no bugs; verified all four of round 3's reductions were real, and named
  the closing axis. Round 5: one bug (a docstring inserted inside another's) and
  five fragility findings, every one **inside round 4's closures**.
- The sharpest: closing four literals in the block that loads a real fly object put
  them behind a **gitignored cache gate**, so a fresh clone ran none of them and
  still printed "All assertions passed." Closed by reading fly's facts from the
  installed package instead — no data file needed.
- The "is this stage guarded" scan was defeated in four successive spellings
  (removal, whole-line comment, trailing comment, string literal). Closed by asking
  the parse tree for a *call* rather than the file for text.
- Termination is measured, not asserted: a fresh clone now runs 82 assertions
  against 77, and names and counts the 4 it cannot.
- Five code-check rounds. Next: archive, PR.
