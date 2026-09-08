# Code check — round 5 (issue #20)

Narrow scope: defects **inside** the five closures round 4's residue was closed with.
Nothing else in the diff was re-reviewed.

Everything below was measured. Mutations were applied to the working tree and
reverted; `git status --porcelain` is empty and `Rscript tests/test_aoi.R` is green.

R 4.5.2, fly 0.10.0 (`/Users/airvine/Projects/repo/fly` at `5d95a1c`, clean tree,
`DESCRIPTION` version matches the installed build). Cache present on this machine:
`data/centroids/{se_a,se_b,se_c}.parquet`.

---

## Findings

- **[bug]** `scripts/aoi.R:103-124` — `aoi_dem_coverage_min()` (closure 4) was
  inserted **inside** `aoi_terrain_values()`'s docstring. The two blocks are now one,
  with no separator at `:110`:

  ```
  103  #' Terrain routes fly is known to emit
  ...
  109  #' sizing route is a loud stop rather than a quiet mis-classification.
  110  #' fly's DEM coverage warning threshold        <- second title, mid-block
  ...
  120  aoi_dem_coverage_min <- function() 0.95
  121
  122  aoi_terrain_values <- function() {
  ```

  So the paragraph explaining *why the vocabulary is enumerated* — the subject of
  round 4's finding and of closure 3 — now documents the coverage threshold, and
  `aoi_terrain_values()` is left with no docstring at all. Every other function in
  this file carries its rationale directly above it, so a reader arriving at the
  vocabulary literal gets nothing, and a reader arriving at `0.95` gets an argument
  about terrain routes first. Nothing changes at runtime; it is a straight
  mis-insertion with one right answer (split the block, move it above line 122).

  Worth folding in while it is open: the stamp says *"reaching through `fly:::` to a
  private function is a worse dependency than a stamped literal. So: stamped."* —
  written before closure 2 added `fly:::fly_dem_coverage_min()` to the test. The
  reader is told the literal is unpinned when a (cache-gated) pin now exists.

- **[fragile]** `tests/test_aoi.R:149-195` — closures 2 and 4 were placed behind the
  gitignored cache gate, so on every machine but this one they do not run, and the
  SKIP names **one of the five** assertions inside.

  This is round 4's own prescription (*"four literals close here, not in four
  separate designs"*) meeting round 4's own warning at its `:80-83` (*"gated on the
  gitignored `data/centroids/se_c.parquet`, so on a fresh clone it reports
  SKIPPED"*). The prescription was followed and the exposure went 1 → 5.

  Measured — `.gitignore:7` is `data/*` and `git ls-files data/centroids` is empty,
  so this is the state of a fresh clone. There is no `.github/workflows`, so no
  machine other than this one has ever run the five:

  | | assertions run |
  |---|---|
  | with cache | 82 |
  | cache moved aside | 77 |

  The five lost are `the real bcdata-shaped input is tibble-backed`,
  `fly_footprint() returns every declared column on it`, `aoi_footprint_cols() is
  fly's reporting set exactly`, `every footprint_terrain fly emits is in
  aoi_terrain_values()`, and `aoi_dem_coverage_min() matches fly's`. The one SKIP
  line printed reads `fly_footprint() on real bcdata input — SKIPPED - no centroid
  cache; run 01_fetch.R se_c`, which names only the first. The suite then prints
  **`All assertions passed.`**

  Mutations, run with the cache moved aside:

  | mutation | with cache | fresh clone |
  |---|---|---|
  | `aoi_dem_coverage_min()` `0.95` → `0.42` | RED | **GREEN** |
  | drop `dem_coverage` from `aoi_footprint_cols()` | RED | **GREEN** |
  | widen `aoi_terrain_values()` with `"bogus"` | RED | RED |

  Only closure 3 survives the gate, because its assertion (`expected_terrain`) is
  outside it. The `aoi_footprint_cols()` case is the sharper one: with the cache
  gone, the only remaining exercise of that literal is
  `aoi_check_footprint_cols(fp_full)` at `:117-121`, whose fixture is **built from
  `aoi_footprint_cols()`** — `setdiff(x, x)`, round 1's tautology — so the literal is
  unpinned in both directions on a fresh clone rather than only the one round 4
  named.

  Cheapest close is the one `code-check.md` already prescribes for this shape: make
  vacuity visible. Print one `SKIPPED` line **per** assertion the gate withholds (or
  a single line naming all five), and count the skips in the summary so
  `All assertions passed.` is not what a fresh clone reads. The literals themselves
  can be pinned without the cache — see the two findings below.

- **[fragile]** `tests/test_aoi.R:283-288, 313` — closure 1 closes the trailing-comment
  spelling and leaves a fourth: a mention inside a **string literal** still passes the
  scan.

  `parse()` drops comments by construction, which is the fix; it preserves string
  literals by construction, which is the hole. Measured, replacing
  `01_fetch.R:21`'s call with `message("fly capability guarded by aoi_require_fly() in aoi.R")`:

  ```
  baseline                                    GREEN
  A2  trailing comment mention                RED  (2 fails)   <- closure 1 works
  A3  mention inside a STRING literal         GREEN            <- defect
  ```

  Round 2 closed total removal, round 3 the whole-line comment, round 4 the trailing
  comment, and this is the fourth spelling of one defect. It is not hypothetical in
  this repo: `scripts/aoi.R:59` is `stop("aoi_require_fly() needs the formals of ...")`,
  a working example of the shape one file away — and it is precisely why `aoi.R` has
  to be excluded by name at `:311` rather than being allowed to fail the scan. The
  test comment already says so; the scan does not act on it.

  A wider regex is not the fix and neither is a wider parser call — ask for a *call*
  rather than for text. Measured, catches A3 and is TRUE on all four unmutated files:

  ```r
  guarded <- function(f) any(unlist(lapply(parse(f), all.names)) == "aoi_require_fly")
  ```

  `all.names()` walks the parse tree and returns symbols; a string constant is not a
  symbol, so the string spelling cannot survive it, and the "proves the file parses"
  property closure 1 wanted is kept.

- **[fragile]** `tests/test_aoi.R:183-190` — the `tryCatch` downgrades a fly **rename**
  to a benign SKIP, on the one event that makes the stamped copy stale.

  `:::` is fine here; the masking is not. Measured, both mutations applied together —
  the test asks for a renamed internal *and* `aoi_dem_coverage_min()` set to `0.42`:

  ```
  fly's coverage threshold          SKIPPED - fly:::fly_dem_coverage_min() not found
  All assertions passed.
  ```

  A fly that renames or relocates `fly_dem_coverage_min()` is exactly the fly whose
  threshold may have moved, so the pin disarms itself at the moment it is needed and
  reports the disarm as a pass. Same fail-toward-pass direction as the cache gate
  above, arriving through an error handler instead of an `if`. `error =` should count
  a failure (or a named skip that the summary reports) rather than returning `NULL`
  into a silent branch — the function is `<bytecode>`-visible and present today, so a
  hard read fails loudly and correctly.

- **[fragile]** `tests/test_aoi.R:416-424` and `scripts/aoi.R:122-124` — closure 3's
  `expected_terrain` is independent of `aoi_terrain_values()`, and that is the wrong
  axis of independence: it is a second copy of a **fly** fact, and the premise that it
  cannot be read from fly is false.

  It does work in the direction it was written for — measured, both round 4 mutations
  now go red, and unlike closures 2 and 4 it survives a fresh clone:

  | mutation | result |
  |---|---|
  | E widen `aoi_terrain_values()` with `"bogus"` | RED |
  | F narrow it (drop `no_dem_coverage`) | RED |

  But `code-check.md`'s partition puts a contract this repo chose on the hardcode
  side and a fact about a third party on the read-from-the-artifact side, and round 4
  classified this literal explicitly as *"a new repo literal describing a fly fact"*.
  Re-typing it applies the `expected_cols` remedy — correct for the ledger schema,
  which this repo owns — to a literal this repo does not own. There are now two copies
  of the guess and a pin between them that cannot move when fly does.

  The comment at `:419-421` states the risk this is supposed to cover — *"`dem_agl`
  and `no_dem_coverage` appear in no run and no other test, and the day #23 flips it a
  wrong set aborts `01_fetch.R` on every AOI"* — and the closure does not reach it. A
  duplicate of a guess cannot validate the guess, and closure 2's fly-side assertion
  (`every footprint_terrain fly emits is in aoi_terrain_values()`) can only ever see
  the two values fly emits with the DEM off. Measured on `se_c`: `nominal_scale` 810,
  `gsd_scaled` 188, NA 15 — so both DEM values remain unvalidated in both places, and
  a fly that renames either stays green everywhere until #23 flips the switch.

  The premise is checkable and false. All four values are readable from the
  **installed** fly, no source checkout required:

  ```
  deparse(fly::fly_footprint) contains  nominal_scale    TRUE
                                        gsd_scaled       TRUE
                                        dem_agl          TRUE
                                        no_dem_coverage  TRUE
  ```

  So the vocabulary can be pinned against fly the way `0.95` now is — and unlike the
  cache-gated assertions, that pin needs no parquet file, so it runs on a fresh clone.

- **[fragile]** `tests/test_aoi.R:313-314` — a syntax error in any fly-calling script
  aborts the suite uncaught, because the complement's `code_of(f)` is not inside
  `ok()`.

  Measured, with `if (TRUE {` appended to `02_georef.R`: the named loop reports it
  well (`02_georef.R calls aoi_require_fly()  FAIL — scripts/02_georef.R:119:10:
  unexpected '{'`), then line 313 raises `Error in parse(f)` and R halts. Exit code is
  1, so this is loud rather than silent — but ~30 later assertions never run and the
  `N assertion(s) failed` summary never prints, so the output reads as a crash rather
  than as a suite result. One `tryCatch` around the Filter's `code_of()`, treating an
  unparseable file as unguarded, keeps it a finding instead of a crash.

---

## Checked and clean

Stated because the prompt asked for each of them by name.

- **The five fly citations are all exact** against fly 0.10.0 / `5d95a1c` (clean tree,
  installed version matches the checkout), verified by `grep -n` rather than by
  counting:

  | citation in `scripts/aoi.R` | fly | line |
  |---|---|---|
  | `fly_georef.R:316` (`user_val`) | `user_val <- if (user_rotation_col) user_rot[j] else NA_integer_` | 316 |
  | `fly_georef.R:322` (the refusal) | `if (is.na(user_val) && rotated[j] && !non_square[j]) {` | 322 |
  | `fly_georef.R:341` (the `rot` chain) | `rot <- if (!is.na(user_val)) {` | 341 |
  | `fly_georef.R:482` (`bearing_to_rotation()`) | `bearing_to_rotation <- function(bearing) {` | 482 |
  | `fly_footprint.R:176` (`0.95`) | `fly_dem_coverage_min <- function() 0.95` | 176 |

- **`deparse(parse(f))` preserves the call and alters nothing that matters.**
  `has_call = TRUE` on all four scripts, and also under `options(keep.source = TRUE)`
  — the srcref attributes add ~144 characters each and carry no comment text
  (`grepl("#", .)` is FALSE), so running the suite from an interactive session does
  not resurrect the round-3 spelling. `parse(f)` is `parse(file = f)`; no positional
  hazard.

- **`setequal` vs `identical` for the footprint columns.** A reorder of
  `aoi_footprint_cols()` leaves the suite GREEN, and that is correct: every consumer
  is order-insensitive — `setdiff()` at `aoi.R:127`, `%in%` at `test_aoi.R:219`,
  `setNames()` fixture construction at `:117`, and the per-column loops at `:129`,
  `:133`. `identical` would pin an order nothing reads. No finding.

- **`:::` on the internal is safe here.** It is a test, `fly_dem_coverage_min` is
  absent from `getNamespaceExports("fly")` so there is no exported alternative, and
  it returns `0.95` as a plain double, so `identical()` against
  `aoi_dem_coverage_min()` is a real comparison. The defect is the handler around it,
  not the `:::`.

- **Closure 5's numbers and its no-op claim hold.** Re-measured over all three AOIs
  through `fly_footprint()` + `aoi_rotation_ok()`:

  | AOI | frames | film | `nominal_scale` | mask TRUE | rotations supplied |
  |---|---|---|---|---|---|
  | se_a | 818 | 800 | 800 | 11 | 180 |
  | se_b | 840 | 806 | 806 | 6 | 180 |
  | se_c | 1013 | 810 | 810 | 3 | 180 |

  So the docstring's *"3 of 810 on `se_c`"* is exact, and *"11 / 6 / 3 frames, all
  180"* is exact. The *"behaviourally a no-op"* claim also holds, and by construction
  rather than coincidence: `02_georef.R:93` passes `rotation = "auto"`, so
  `auto_rotation` is TRUE and an NA in the supplied column reaches
  `fly_georef.R:348`'s `if (auto_rotation) 180L`. Supplying the column does suppress
  fly's own auto path (`fly_georef.R:268`, `auto_rotation && !has_rotation_col`), but
  that path would run `fly_bearing()` on the per-year **selected subset** of the
  window, and a subset can only lose bearings — so it can never produce a non-180
  where the window's `footprint_bearing` was NA, which is the only case the mask
  admits. Verified, not assumed.

---

## Where this leaves round 4's residue

| closure | works as claimed | defect found |
|---|---|---|
| 1 `code_of()` via `parse()` | A2 now RED | string-literal spelling still GREEN; parse error aborts the suite at `:313` |
| 2 cache-block assertions | all RED **with** the cache | invisible on a fresh clone; `0.42` and a dropped column both GREEN there |
| 3 `expected_terrain` re-typed | E and F now RED, survives a fresh clone | a second copy of a fly fact; the readable-from-fly premise is false |
| 4 `aoi_dem_coverage_min()` | RED with the cache | docstring merged into `aoi_terrain_values()`'s; pin masked by `tryCatch` |
| 5 `aoi_rotation()` docs + citations | — | none; all five citations and all three measurements verify |

The mechanism this round found is one, and it is the same one rounds 2-4 kept
finding one spelling over: **round 4's closing move put the guards where they could
not run.** Two of the five closures are real on this machine and absent everywhere
else, a third is a duplicate of the guess it was meant to check, and the
fourth's pin turns itself off on the event it exists for. Closure 5 is complete.

The terminating check is not another round: it is that **every assertion added by
these five closures runs on a fresh clone, or announces by name that it did not.**
Three of the four literals can be read from the *installed* fly with no cache at all
(`fly:::fly_dem_coverage_min()`, and `deparse(fly::fly_footprint)` for the terrain
vocabulary), which closes the gate question and the wrong-side question in the same
edit. Only `aoi_footprint_cols()` genuinely needs a real window, and that one wants
the skip counted rather than printed.

## Mutations run

All applied to the working tree and reverted; `git status --porcelain` is empty and
the suite is green.

| id | mutation | with cache | fresh clone |
|---|---|---|---|
| A2 | trailing `# aoi_require_fly()` comment | RED (2) | — |
| A3 | mention inside a string literal | **GREEN** | — |
| E | widen `aoi_terrain_values()` | RED (1) | RED (1) |
| F | narrow `aoi_terrain_values()` | RED (2) | — |
| G2 | drop `dem_coverage` from `aoi_footprint_cols()` | RED (1) | **GREEN** |
| R | `aoi_dem_coverage_min()` 0.95 → 0.42 / 0.90 | RED (1) | **GREEN** |
| R2 | reorder `aoi_footprint_cols()` | GREEN (correct) | — |
| S | rename `fly:::fly_dem_coverage_min` **and** set the literal to 0.42 | **GREEN** (SKIP) | — |
| T | syntax error in `02_georef.R` | abort at `:313`, exit 1 | — |
| U | `deparse(parse(f))` under `keep.source = TRUE` | call preserved, no comment text | — |
| V | assertion count with / without the cache | 82 | 77 |
| W | `all.names(parse(f))` scan against A3 | FALSE (catches it); TRUE on all four clean | — |
| X | film / mask / rotation over all three AOIs | 800·806·810, 11·6·3, all 180 | — |
