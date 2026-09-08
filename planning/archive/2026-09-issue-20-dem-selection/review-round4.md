# Code check — round 4 (issue #20)

Narrow scope: verify the four reductions round 3 asked for, re-check its three
wrong-side literals, and look for new instances of its mechanism.

Everything below was **measured**. Mutations were applied to the working tree and
reverted; `git diff --stat` is 0 lines and `Rscript tests/test_aoi.R` is green.

fly 0.10.0, `5d95a1c`. Windows measured: `se_a` (818), `se_b` (840), `se_c` (1013).

---

## Verification of the four reductions

### 1. `aoi_rotation_ok()` vs fly's own routing — **equivalent, confirmed**

fly's refusal (`fly/R/fly_georef.R:322`) is
`is.na(user_val) && rotated[j] && !non_square[j]`, where `rotated <-
is.finite(footprints$footprint_bearing)` (`:227`) and empty footprints are
`next`ed at `:314`. The mask supplies a rotation only where
`is.na(footprint_bearing)`, i.e. only where `rotated` is FALSE.

Measured on the `se_c` window (1013 frames):

| measurement | value |
|---|---|
| mask TRUE (repo supplies a rotation) | 3 |
| fly would REFUSE | 807 |
| **repo supplies where fly would have refused (disarm)** | **0** |
| film & rotated & non-square (would get `fly_digital_rotation()`) | 0 |
| digital & rotated & square (refused with the film message) | 0 |
| `is.na(b) != !is.finite(b)` disagreements | 0 (no NaN, no Inf) |

End-to-end, the reversal of round 3's mutation G — real `fly_georef()` on the 11
1995 film frames on disk, with the new mask:

```
Georeferenced 0 of 11 images    (11 film-refusal warnings)
```

Round 3 measured 11/11 written. The finding is closed.

**The `is.na` / `is.finite` split is safe by construction**, not by luck:
`fly_footprint()` sets `bearing[no_geom] <- NA_real_` (`fly_footprint.R:951`) for
exactly the reason fly's comment there gives, so the two predicates can only
disagree on `NaN`/`Inf`, which `atan2()` cannot produce. Measured 0.

**The two-derivation gap cannot disarm the refusal.** The mask is computed on the
window's `footprint_bearing`; fly decides on the per-year subset it rebuilds
internally. `fly_bearing()` requires a neighbour **adjacent by `frame_number`**
(`fly/R/fly_bearing.R:88-92`), so a subset can only *lose* bearings — a frame
cannot gain one. Measured over the 88 selected `se_c` frames, per year, as
`fly_georef()` sees them: **0 disarms**.

- **[fragile]** the same gap loses a *refusal*: 1 of 88 has a finite bearing in
  the window and NA in its per-year subset, so it is written at `180L` on an
  axis-aligned footprint instead of landing in `georef_failed` as
  `aoi_rotation_ok()`'s docstring (`scripts/aoi.R:158-160`) promises. Not silently
  wrong — the ring is axis-aligned in the same call, `180L` is fly's own fallback
  for that case, and fly warns *"drawn axis-aligned … as though the flight line
  ran due north"*. But it is one more instance of the two-derivations shape that
  `01_fetch.R:84-89` is proud of avoiding for footprints.

### 2. `aoi_footprint_cols()` — **6 is exactly complete**

```
setdiff(names(fly_footprint(w)), names(w))
  footprint_basis, footprint_terrain, width_source,
  footprint_bearing, height_agl, dem_coverage
aoi_footprint_cols()          identical
missing: (none)   extra: (none)   dropped by fly: (none)
```

Round 3's finding 2 is closed for today's value.

- **[fragile]** the mechanism is not. `aoi_check_footprint_cols()` is
  `setdiff(aoi_footprint_cols(), names(fp))` — one-directional, so a **seventh**
  column fly adds is invisible, which is precisely how the literal went two
  columns stale between fly 0.8.0 and 0.10.0. And the only assertion that drives
  real fly (`tests/test_aoi.R:153-155`) is gated on the gitignored
  `data/centroids/se_c.parquet`, so on a fresh clone it reports SKIPPED. What
  keeps mutation G red there is `test_aoi.R:183`, a repo-vs-repo check against
  `aoi_ledger_cols()` — which also cannot see an addition.

### 3. `aoi_terrain_values()` — **complete, and cannot abort on a legitimate value**

Every write to `terrain` in `fly/R/fly_footprint.R`, enumerated rather than
sampled — `:771` (`nominal_scale`, else NA), `:772` (`gsd_scaled`), `:914`
(`nominal_scale`), `:915` (`dem_agl`), `:916` (`no_dem_coverage`), `:917`
(`nominal_scale`), `:943` (NA) — and `:988` is the column's only assignment. The
four values plus NA are the whole vocabulary. Observed on `se_c`: `nominal_scale`
810, `gsd_scaled` 188, NA 15; `setdiff` against the literal is empty.

So the guard is correct today and the "aborts on a legitimate value" risk is nil.
See the finding below for why it is nonetheless on the wrong side.

### 4. The three hardened assertions — **two of three now have teeth; one gap remains**

| id | mutation | expected | observed |
|---|---|---|---|
| A | full-line `# guarded by aoi_require_fly() in aoi.R` replaces the call | RED | **RED** — round 3's defect closed |
| **A2** | **trailing** `ids_placeholder <- NULL  # aoi_require_fly()` | RED | ***GREEN — defect*** |
| B | delete the call outright (positive control) | RED | RED |
| C | rename `sel_ids` + drop 2 columns | RED | RED |
| D | drop only `footprint_terrain` from the transmute output | RED | **RED** — round 3's defect closed |
| D2 | drop `width_source` from the transmute output | RED | RED |
| G | add a bogus column to `aoi_footprint_cols()` | RED | RED |
| H | invert the mask (`film & !is.na(bearing)`) | RED | RED |
| I | drop the bearing arm (regress to `aoi_film_mask`) | RED | RED |
| E | **widen** `aoi_terrain_values()` with `"bogus_route"` | RED | ***GREEN — defect*** |
| F | **narrow** it (drop `no_dem_coverage`) | RED | ***GREEN — defect*** |

The `^\s*#` regex does not *mis-handle* a trailing comment — it keeps the whole
line, comment included — which is enough to preserve round 3's defect in a
narrower form. See the finding below.

---

## Findings

- **[fragile]** `tests/test_aoi.R:241-244` (`code_of()`) — the comment strip is
  line-anchored, so a **trailing** mention still passes the "every fly caller is
  guarded" scan.

  `grep("^\\s*#", lines, invert = TRUE)` drops comment *lines*. A code line with a
  trailing comment survives whole. Mutation A2, applied and reverted — replace
  `aoi_require_fly()` at `01_fetch.R:21` with
  `ids_placeholder <- NULL  # aoi_require_fly()`:

  ```
  01_fetch.R calls aoi_require_fly()                         PASS
  no unguarded fly caller in scripts/                        PASS
  All assertions passed.
  ```

  Round 2 fixed the total-removal case, round 3 fixed the whole-line-comment case,
  and this is the third spelling of one defect. It is realistic in this repo
  specifically: the four scanned files are densely commented and already carry
  cross-references of exactly this shape.

  The remedy is not a wider regex — `sub("#.*", "", line)` truncates a `#` inside a
  string literal, and `01_fetch.R:25` has one. Ask the parser, which drops comments
  by construction and additionally proves the file parses. Measured, with A2
  applied:

  ```
  current  ^\s*# strip ->  TRUE   (want FALSE)
  parse()-based strip   ->  FALSE  (want FALSE)
  ```

  ```r
  code_of <- function(f) paste(deparse(parse(f)), collapse = "\n")
  ```

  Verified TRUE for all four files unmutated, so the positive control still holds.

- **[fragile]** `scripts/aoi.R:110-112` (`aoi_terrain_values()`) — a new repo
  literal describing a fly fact, with nothing asserting it against fly. This is
  round 3's mechanism, one function over from where it flagged it.

  The set is correct today (verified above). Nothing in the suite can see it move
  in either direction — both mutations left the whole suite green:

  - **E, widening.** Adding a value to `aoi_terrain_values()` costs nothing
    visible, but the clash guard three lines down keys on the *literal*
    `"gsd_scaled"` (`aoi.R:198`), not on the vocabulary. So a fly that adds a
    second digital sizing route, added to the vocabulary and not to the clash
    check, silently stops cross-checking film-by-catalogue against
    digital-by-fly — the exact fail-toward-pass round 3 flagged for
    `"gsd_scaled"`, moved one indirection back.
  - **F, narrowing.** No arm is exercised against a value fly emits under a DEM.
    `dem_agl` and `no_dem_coverage` have never appeared in any run or any test,
    because `aoi_dem_enabled()` is FALSE — so the day #23 flips it, this guard
    aborts `01_fetch.R` before the ledger is built if the set is wrong, on every
    AOI, and the suite that was green says nothing.

  The assertion that claims to cover this — `test_aoi.R:377-379`, *"every known
  value is accepted"* — builds its input from `aoi_terrain_values()`, so it
  evaluates `setdiff(x, x)` and can never fail. That is the defect round 1 fixed
  for `expected_cols`, and the reason is written out in this same file at
  `:168-173`.

  Direction is safer than what it replaced (a fly *rename* now aborts loudly
  instead of mis-classifying), so this is a reduction, not a regression. It is not
  closed.

  Cheapest close, and it is the shape already used for `aoi_footprint_cols()`:
  drive the vocabulary against real fly output in the arm that reads the cache
  (`test_aoi.R:149-160`) — `setdiff(unique(fp$footprint_terrain), aoi_terrain_values())`
  is empty — and re-type the four values independently, as `expected_cols` does, so
  a widening goes red.

- **[fragile]** `scripts/aoi.R:460-477` (`aoi_rotation()`) — round 3's sharpest
  wrong-side literal is now **unreachable**, and its docstring still describes the
  design it was written for.

  The mask selects exactly the frames whose `footprint_bearing` is NA, and
  `footprint_bearing` is NA exactly where `fly_bearing()` returned NA (or the
  geometry is empty, in which case `fly_georef()` skips the frame at `:314`). So
  every value the `rotation` column can carry is the `rot[is.na(rot)] <- 180L`
  fallback. Measured on all three AOIs:

  | AOI | frames | mask TRUE | rotation values supplied |
  |---|---|---|---|
  | se_a | 818 | 11 | 180 |
  | se_b | 840 | 6 | 180 |
  | se_c | 1013 | 3 | 180 |

  The copied `bearing_to_rotation()` formula therefore cannot go stale in a way
  that reaches output — that half of round 3's finding is closed by the mask. What
  remains is that `180L` is also fly's own fallback (`fly_georef.R:346`,
  `if (auto_rotation) 180L`), so the column is now behaviourally a no-op for those
  20 frames, while the docstring above it still says the load-bearing opposite:

  > *"bearing is computed once over the whole fetch window … and carried forward as
  > a `rotation` column — which `fly_georef()` honours in preference to recomputing"*

  Nothing is carried forward any more. A reader deciding whether `aoi_rotation()`
  can be deleted, or what #23 has to replace, gets a false premise. Two of its
  citations are stale with it: `bearing_to_rotation()` is at
  `fly/R/fly_georef.R:482`, not `:300`, and `:127` is now roxygen about nodata
  handling rather than the honouring rule. (`aoi_rotation_ok()`'s citations at
  `aoi.R:134` are off by a little in the same way — `:316` is right, the refusal is
  at `:322` not `:321`, the `rot` chain at `:341` not `:345`.)

  Keeping the plumbing for #23 is right. Restating what it does now is one
  paragraph.

- **[fragile]** `scripts/aoi.R:656-657` — `0.95` is **still open, unchanged from
  round 3**.

  Correct today: `fly_dem_coverage_min()` is `0.95` at `fly/R/fly_footprint.R:176`.
  Still a repo copy of a fly constant with nothing pinning it, and still report
  prose only. Round 3 called it minor because the branch is unreachable while
  `aoi_dem_enabled()` is FALSE — worth noting that #23 is the issue that flips it,
  so the day this becomes reachable is the day it is most likely to be wrong. Cost
  is one sentence in `data/reports/<id>.md` naming a threshold fly no longer uses,
  beside a count computed from that same wrong number. `fly:::fly_dem_coverage_min()`
  is not exported; either read it through `:::` with the fallback, or pin the
  literal with an assertion against it in the cache-gated arm.

---

## Round 3's counted set, after this round

| round 3 item | state |
|---|---|
| assertion #22 — transmute names every column (`footprint_terrain` blind) | **closed** (D, D2 red) |
| assertion #23 — `<file>` calls the guard | **narrowed**, not closed (A red, A2 green) |
| assertion #25 — no unguarded fly caller | **narrowed**, not closed (same scan) |
| literal — `"gsd_scaled"` on the wrong side | **improved**; residual is mutation E |
| literal — `aoi_footprint_cols()` stale subset | **closed** for the value; the one-directional `setdiff` remains |
| literal — `aoi_rotation()` copy of a fly internal | **unreachable**; docstring now false |
| literal — `0.95` | **open, unchanged** |
| *(new)* `aoi_terrain_values()` | wrong side, both directions green |

Three of round 3's seven are closed, three narrowed or made unreachable, one
untouched, and one new instance added. Nothing found this round changes what the
pipeline writes: **no `bug`-severity finding.** The measured behaviour of the diff
is correct on all three AOIs — the residue is guards that cannot see themselves
break.

The remaining instances all sit on one axis, which is worth naming for whoever
closes them: **every one is a guard reading repo text or a repo literal where a
real `fly` object is already in hand.** The cache-gated arm at `test_aoi.R:149-160`
already loads that object; the terrain vocabulary, the seventh-column direction of
`aoi_footprint_cols()`, and `0.95` can all be asserted against it in the same
block, and the caller scan can be handed to `parse()`. That is four literals and
one regex, not five separate designs.

## Mutations run

All applied to the working tree and reverted. `git diff --stat` is 0 lines and the
suite is green.

A, A2, B, C, D, D2, E, F, G, H, I (table above), plus:

| id | measurement | result |
|---|---|---|
| J | `setdiff(names(fly_footprint(w)), names(w))` vs `aoi_footprint_cols()` | identical, 6 |
| K | mask vs fly's refusal condition over the `se_c` window | 0 disarms |
| L | window vs per-year-subset `footprint_bearing`, 88 selected frames | 1 lost refusal, 0 disarms |
| M | real `fly_georef()` on 11 1995 film frames, new mask | 0/11 written, 11 refusals |
| N | terrain vocabulary observed vs `aoi_terrain_values()` | `setdiff` empty |
| O | `aoi_rotation()` output over all three AOIs, post-mask | 180 only, 20 frames |
| P | distinct rotations per film roll, `se_c` | 34 of 48 rolls carry 2–4 — the diff's claim at `aoi.R:150` verified exactly |
| Q | `parse()`-based `code_of()` against mutation A2 | FALSE (catches it); TRUE on all four files unmutated |
