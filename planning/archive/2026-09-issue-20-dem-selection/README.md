# #20 — DEM to selection, fly's reporting columns, capability assert

**Closed by** PR against `20-dem-to-selection-fly-columns-version-window`
(`711e1b3`, `2efa268`). **Issue:** #20. **Successor:** #23 owns the rebuild.

Three defects in the selection path, all of which made the reporting surface say
less than it appeared to: `fly_footprint()`'s result was discarded except one
column; selection ran through `fly_filter()`, which builds its *own* footprints,
so a DEM would have corrected a set nothing selected on; and a prose "fly >=
0.5.0" floor that nothing enforced. All three are closed. A DEM is threaded to
every stage that sizes a footprint and left **off** — `aoi_dem_enabled()` returns
`FALSE`, and #23 flips it and re-derives both regions so the collection is never
half-corrected.

Two bugs the issue did not name were found and fixed: the `rotation` column was
disarming fly's refusal to georeference a rotated film frame, and the
`digital_unknown_format` rejection reason was keyed on a `footprint_basis` string
fly had stopped writing.

## Measurement

Measured on `se_c` (1,013 frames) at fly 0.10.0 unless stated.

**The upgrade moves selection on its own** — 215 of 1,013 rows changed outcome
across fly 0.5.0 → 0.10.0, and every one reconciles: 203 digital (188 gain a
footprint, 15 remain unsized) and **12 film**, 6 each way, all on diagonal
bearings. The issue's premise that "0.6.0 leaves film output unchanged" holds
only through 0.8.x — fly 0.9.0 rotates film footprints onto the flight line.

**`fly_filter()` was replaceable exactly** — one `st_intersects()` on the single
footprint result is set-identical, 91 = 91, symmetric difference 0. This is what
makes the ledger's terrain columns describe the footprints selection actually
used, rather than a second set built alongside them.

**The DEM reaches selection** — with it on, `footprint_terrain` gains `dem_agl`
on 825 frames, selection moves 88 → 104, the 15 otherwise-unsizeable frames all
gain footprints, and `dem_coverage` runs min 0.975 / median 1.0 with **none**
below fly's 0.95 threshold. So the 6 km corner allowance on top of the 8 km fetch
buffer is measured adequate rather than reasoned adequate.

**The `rotation` column was disarming a safety refusal.** Reported mid-session as
"88/88 georeferenced" and both halves of that were wrong: the run was the *warm*
path over a populated tree (cold it is 11/88), and the frames only wrote because
a supplied `rotation` short-circuits fly's refusal to guess a per-roll corner
mapping. On 11 real 1995 frames: 11/11 written with the column, **0/11 and 11
refusals** without. The value was wrong anyway — derived per frame from bearing,
where the property is a per-roll constant, so **34 of 48 rolls** got two to four
different values. Changed what the pipeline does: film now lands in
`georef_failed` until #23 supplies the table, which is the honest outcome.

**fly reports six columns, not four.** `width_source` (0.6.0) and
`footprint_bearing` (0.9.0) were still being dropped by the very transmute this
issue exists to fix.

## Evidence

`planning/archive/2026-09-issue-20-dem-selection/` — `findings.md` carries every
measurement with its command; `review-round[1-5].md` are the code-check rounds,
each with its own mutation table.

Five rounds, and rounds 2, 3, 4 and 5 *each* found their best defect inside the
previous round's fix. Worth reading in order, because the sequence is the point:

- **Round 1** — a test fixture built from the function under test, so the
  assertion was `setdiff(x, x)` and a bogus column left the suite green.
- **Round 3** — the two bugs above, plus the mechanism: every guard asserted a
  property of *this repo's own text or schema* and none asserted what fly does,
  because that half lived in comments, and a comment cannot go red.
- **Round 5** — round 4's closing move put four literals behind a **gitignored
  cache gate**, so a fresh clone ran none of them and still printed "All
  assertions passed". Closed by reading fly's facts from the installed package.

The "is this stage guarded" scan was defeated in four successive spellings —
total removal, a whole-line comment, a trailing comment, a mention inside a
string literal — each round closing one. The form with no next spelling is asking
the parse tree for a *call* rather than the file for text.

## Wrong turns worth keeping

- **A fly version *window* `[0.6.0, 0.9.0)` was designed, dropped, and then
  half-vindicated.** It was dropped on the argument that a ceiling merely
  duplicates a refusal fly already makes loudly. Round 3 measured that fly's
  refusal was being *suppressed* by this pipeline's own `rotation` column, so the
  ceiling had been protecting something real. Put back to the user with the
  measurement; they chose to stay on fly 0.10.0 and let fly refuse.
- **`bcmaps::cded_terra()` was proposed as the DEM source** before searching the
  org for the verb. `flooded::fl_dem_aoi()` already existed.
- **`git checkout -- <path>` was used to undo a test mutation** and restored from
  the *index*, silently discarding two unrelated fixes.
- **A mutation was reported as "STILL GREEN"** when the replacement had not
  applied. A probe reporting no effect must first prove it took effect.

## What this leaves for #23

The per-roll rotation table is now the thing standing between this pipeline and
film output — `georef_failed` on 77 of 88 selected `se_c` frames is the visible,
intended state. Flipping `aoi_dem_enabled()` is a one-line change here. One
residue is recorded in `review-round4.md`: `02_georef.R` rebuilds bearings on the
per-year subset, so 1 of 88 frames loses a refusal it would get from the intact
window.
