# Code check — round 3 (issue #20)

Scope: staged diff. Files read in full: `scripts/aoi.R`, `scripts/01_fetch.R`,
`scripts/02_georef.R`, `tests/test_aoi.R`, plus `scripts/00_review_samples.R`,
`scripts/test_pipeline.R`, `scripts/run_pipeline.sh`.

Everything below was **measured**, not read. Mutations were applied to the working
tree and reverted; the tree is restored and `Rscript tests/test_aoi.R` is green.

---

## The mechanism

Rounds 1 and 2 each found their best defect in `tests/test_aoi.R`. The shared
assumption is not "tests are hard" — it is this:

> **Every guard this diff adds asserts a property of *this repo's own text or
> schema*, and derives its expectation from a literal this repo wrote. Not one
> of them asserts the other half of the contract — what `fly` actually does.
> That half is carried in comments, and a comment cannot go red.**

Each contract is `P and Q`. `P` is repo-side, hardcoded, and can fail (rounds 1
and 2 made sure of that — and those fixes are correct). `Q` is fly-side and is
documented in a docstring citing a file and line number in another repo. So a
green suite means *"the repo still says what it said"*, never *"the thing it
describes is still true"*.

Two consequences, and both are live in this diff:

1. **Where the guard reads repo text, its "not found" path and its "nothing to
   find" path are the same path.** Round 2 fixed this for the transmute block's
   first anchor. It is still open on two other text scans, proven below.
2. **Where the guard reads a repo literal describing fly, the literal is stale
   and nothing can see it.** `aoi_footprint_cols()` is now a strict subset of
   what fly returns, and `aoi_rotation()` is a copy of a fly internal whose
   meaning fly changed. `aoi_require_fly()` — the diff's headline guard — passes
   on the fly that broke both.

`aoi_require_fly()` is the mechanism in one function. It replaces a version floor
with a **capability proxy**: `"dem" %in% formals` for three functions. The
pipeline depends on at least three more fly behaviours a version floor implicitly
covered — the four reporting columns (acknowledged, checked separately at the
call site, correctly), the invariant `footprint_terrain is NA exactly where the
geometry is empty` (checked: fly asserts it at `R/fly_footprint.R:921`, so the
`no_footprint` re-key is on the property — this one is right), and **the meaning
of the `rotation` column**, which fly 0.10.0 changed and which nothing here
asserts. The guard has no ceiling and no way to fail on it.

---

## Findings

- **[bug]** `scripts/01_fetch.R:120-121` + `scripts/aoi.R:435-439` (`aoi_rotation()`)
  — the `rotation` column disarms fly 0.10.0's film-frame refusal and supplies a
  value fly explicitly refuses to guess.

  fly 0.10.0 rotates every film footprint onto its flight line, and
  `fly_georef()` then **skips a rotated square (film) frame with a warning**
  unless the caller supplies that roll's rotation — because the corner mapping is
  a per-roll camera-mount property fly cannot derive (measured 0 for bc5282/1968,
  90 for bc83062/1983). fly's own code says why the bearing must not be reused:

  > `fly/R/fly_georef.R:313-315` — *"a non-square ring already carries its
  > bearing (see `fly_rectangles()`), so applying `bearing_to_rotation()` on top
  > would count it twice."*

  A user `rotation` column is the highest-precedence input (`fly_georef.R:316`,
  `:345`) and short-circuits the refusal at `:321`. `aoi_rotation()` is a
  behavioural copy of `fly:::bearing_to_rotation()` — I verified they agree on
  every bearing 0..359 with 0 disagreements — so the pipeline hands fly exactly
  the input fly's guard exists to reject.

  Measured on `se_c`, fly 0.10.0:

  | measurement | value |
  |---|---|
  | frames in the window | 1013 |
  | film by `media` | 810 |
  | of those, ring rotated onto a bearing (`footprint_bearing` non-NA) | **807** |
  | 1995 film frames on disk, georeffed **with** the repo's `rotation` column | **11/11 written, 0 warnings** |
  | same frames with `rotation` set to NA (fly decides) | **0/11 written, 11 film-refusal warnings** |

  And the value is wrong by construction: it is bearing-derived, so it varies
  *within a roll*, where the property is a per-roll constant. Distinct rotations
  supplied per roll on `se_c` — `bc5255` **4 values** over 24 frames, `bcb94081`
  **4** over 43, `bc80116` **4** over 11, `bc80140` 3 over 60, `bcc95037` 3 over
  80. At most one value per roll can be right.

  Failure direction is the expensive one: a valid GeoTIFF, correct CRS, correct
  ground, picture turned a quarter or half turn, `success = TRUE`, `selected` in
  the ledger, and nothing downstream reporting it. This is fly's stated reason
  for adding the refusal.

  It is in scope for this diff on three counts: the diff removes the version
  floor and its replacement passes on 0.10.0; `CLAUDE.md` now states "Developed
  against fly 0.10.0"; and `aoi_film_mask()` — whose entire stated purpose is to
  make the `rotation` column safe under a fly that sizes digital frames — fixes
  the digital half and leaves the film half handing fly the disarming value. The
  test file's note that "Rotation is #23's to settle" covers *which* value is
  right; it does not cover the fact that supplying any value suppresses fly's own
  refusal.

  Cheapest correct action if #23 owns the value: set `rotation` to `NA` for film
  frames whose ring is rotated (i.e. mask on `is.na(fp$footprint_bearing)` rather
  than on film-vs-digital), and let fly refuse them loudly into `georef_failed`.
  0 frames written beats 807 written a quarter turn out.

- **[bug]** `scripts/01_fetch.R:104-107, 132-152` and `scripts/aoi.R:98-100`
  (`aoi_footprint_cols()`) — the transmute still drops two of fly's reporting
  columns, including the one 02_georef then re-derives and gets wrong.

  #20 exists because `01_fetch.R` kept one of `fly_footprint()`'s reporting
  columns and discarded the rest. On fly 0.10.0 that function returns **six**,
  and this diff lands **four**:

  ```
  fly_footprint() adds : footprint_basis, footprint_terrain, width_source,
                         footprint_bearing, height_agl, dem_coverage
  aoi_footprint_cols() : footprint_basis, footprint_terrain, height_agl, dem_coverage
  dropped              : width_source, footprint_bearing
  ```

  `aoi_check_footprint_cols()` cannot see this: its expected set is a repo
  literal, correctly hardcoded so it *can* fail (that part is right), but written
  against fly 0.5.1 and never re-derived. It asserts "these four arrived", never
  "these are all fly emits". `footprint_bearing` was added by fly 0.10.0 — the
  release this was developed against — and `width_source` by 0.8.0, where it is
  documented as the audit trail for every digital footprint, which is the exact
  subject of the repo's own "Digital frames are excluded" known issue.

  `footprint_bearing` is load-bearing, not decorative: it is non-NA on 995/1013,
  and because it is not carried forward, `02_georef.R:90` makes `fly_georef()`
  re-derive the bearing from the **thinned** per-year subset. Measured on `se_c`:
  87 of 88 keep a bearing there against 88 of 88 from the intact window, and fly
  warns that the odd one is *"drawn axis-aligned and georeferenced as though the
  flight line ran due north."* So the ledger describes a ring rotated onto a
  bearing while the GeoTIFF is written on an axis-aligned one — two derivations
  of one fact disagreeing, which is precisely what `01_fetch.R:83-89` says it
  avoided by not using `fly_filter()`. Small here (1/88); it is the same shape as
  the bug the comment is proud of closing.

- **[fragile]** `tests/test_aoi.R:221-226` and `:245-253` — the "every fly caller
  is guarded" assertions pass on a comment.

  Both scan raw source for the literal `aoi_require_fly()`. Round 2 fixed exactly
  this class for the transmute block (stripping comment lines) and did not apply
  it to the two assertions written in the same round.

  Mutation A (applied and reverted): delete the real `aoi_require_fly()` call
  from `01_fetch.R:21` and leave `# guarded by aoi_require_fly() in aoi.R`.

  ```
  01_fetch.R calls aoi_require_fly()                         PASS
  no unguarded fly caller in scripts/                        PASS
  All assertions passed.
  ```

  The guard is gone from the stage and the suite is green. Mutation B (delete
  with no mention) does go red, so the assertions have teeth only against total
  removal — and the realistic way a call is lost is a refactor that leaves a
  reference behind, or the call moving into a helper.

  Related, same scan: `scripts/aoi.R` is itself counted as a fly caller (it
  matches `fly::` at lines 47-49) and passes the unguarded filter only because
  the string `aoi_require_fly()` appears inside its own `stop()` message at line
  59. Five callers are found, so `length(fly_callers) >= 4` has slack.

- **[fragile]** `tests/test_aoi.R:199-213` — "the transmute names every declared
  column" cannot see `footprint_terrain` being dropped.

  The predicate is `grepl(col, block, fixed = TRUE)` — a proxy for "the transmute
  declares this as an **output**". `footprint_terrain` is also *referenced as an
  input* inside the `case_when` at `01_fetch.R:147`, which is code and survives
  the comment strip.

  Mutation D (applied and reverted): delete only `footprint_terrain` from the
  transmute's output list, leaving the `case_when` untouched.

  ```
  the transmute block was actually located                   PASS
  01_fetch.R's transmute() names every declared column       PASS
  All assertions passed.
  ```

  The ledger loses the single most load-bearing column of #20 and the suite is
  green. Bounded in practice — `aoi_ledger_check_cols()` inside
  `aoi_ledger_write()` catches it at run time, loudly — so this is a blind spot
  in the assertion, not shipped data loss. Worth recording that the runtime guard
  is the one doing the work here, and the test advertises a job it cannot do.

  Also note the second anchor is unguarded: `sub("sel_ids <-.*", "", block)`
  returns `block` unchanged on a miss (the round-2 defect, one line down from its
  fix). Mutation C (rename `sel_ids` **and** drop three columns) still went red,
  because those three names do not reappear later in the file — so it is latent
  rather than live.

- **[fragile]** `scripts/aoi.R:159` — the film/terrain clash guard is keyed on a
  third-party string with no assertion that fly still emits it.

  `footprint_terrain == "gsd_scaled"` is fly's name for its digital sizing route
  (fly 0.8.0). The docstring at `:132-136` argues correctly that the *mask* must
  key on `media` rather than on fly's routing — and then keys the cross-check
  that corroborates the mask on exactly that routing string.

  ```
  aoi_film_mask(c("Film - BW"), c("gsd_scaled_v2"))  ->  PASSED (no refusal)
  aoi_film_mask(c("Film - BW"), c("gsd_scaled"))     ->  refused
  ```

  Fails toward pass the day fly renames the route or adds a second digital path —
  which is the scenario the docstring itself raises. Consequence is limited (the
  mask stays media-keyed and correct; only the corroboration goes silent), so:
  fragile. The same literal is hardcoded again in the test fixture at
  `tests/test_aoi.R:325`.

---

## Enumeration 1 — every assertion added by the diff

19 in `scripts/*.R`, 6 text-derived in `tests/test_aoi.R`. "Can fail" was checked
by mutation for every row marked NO and for the rows marked with a proof.

| # | site | expectation derived from | side | can it fail? |
|---|---|---|---|---|
| 1 | `aoi.R:58` shape of `fns` | `wanted` literal — repo contract | repo | YES (test, empty/unnamed list) |
| 2 | `aoi.R:73` `dem` missing | literal `"dem"` — fly API; this *is* the property, so hardcoding is required | fly, correct | YES (test, all 3 arms) |
| 3 | `aoi.R:105` `aoi_check_footprint_cols` | `aoi_footprint_cols()` — repo literal | repo | YES — but the literal is a **stale subset** (finding 2) |
| 4 | `aoi.R:144` `media` NULL | structural | repo | YES (test) |
| 5 | `aoi.R:160` film/terrain clash | literal `"gsd_scaled"` — fly fact | **fly, wrong side** | YES today; **NO** once fly moves the string (proven) |
| 6 | `aoi.R:236` unknown AOI type | registry | repo | YES |
| 7 | `aoi.R:246` unknown AOI id | registry | repo | YES |
| 8 | `aoi.R:300` unknown artifact kind | `aoi_kinds()` | repo | YES |
| 9 | `aoi.R:375` no cached DEM | filesystem | — | YES (unreachable while `aoi_dem_enabled()` is FALSE) |
| 10 | `aoi.R:398` `file.rename` failed | OS return value | — | YES (round-2 fix, correct) |
| 11 | `aoi.R:513` ledger schema | `aoi_ledger_cols()` — repo contract | repo | YES (test, 3 arms) |
| 12 | `aoi.R:534` no centroid cache | filesystem | — | YES |
| 13 | `aoi.R:539` row reconcile | **the parquet cache — independent of the ledger** | independent | YES (round-1 fix, correct) |
| 14 | `aoi.R:549` distinct `airp_id` | the ledger itself | weak | YES only if the cache holds duplicate ids |
| 15 | `aoi.R:561` unregistered reason | `aoi_reasons()` — repo contract | repo | YES |
| 16 | `01_fetch.R:102` `fp`/`window` alignment | `window`, the *input* to `fp` | independent | YES (round-2 fix, correct) |
| 17 | `01_fetch.R:157` nothing selected | data | — | YES |
| 18 | `02_georef.R:28` no selected set | filesystem | — | YES |
| 19 | `02_georef.R:40` no `rotation` column | schema | repo | YES |
| 20 | `test:181` `identical(cols, expected_cols)` | independently written literal | repo | YES (round-1 fix, correct) |
| 21 | `test:201` block was located | `nchar` compare | — | YES (round-2 fix, correct) |
| 22 | `test:211` transmute names every column | `grepl` over source text | proxy | **NO for `footprint_terrain`** (proven) |
| 23 | `test:224` `<file>` calls the guard | `grepl` over source text | proxy | **NO when a comment mentions it** (proven) |
| 24 | `test:243` found the callers at all | literal `4`; actual 5 | repo | YES if `scripts/` moves |
| 25 | `test:250` no unguarded fly caller | `grepl` over source text | proxy | **NO**, same as #23 |

Nothing else in the diff calls `stop`, `stopifnot` or `ok`.

## Enumeration 2 — every literal, and which side it belongs on

Contract this repo chose ⇒ **must** be hardcoded, or the guard can never fail.
Fact about fly or the BC catalogue ⇒ **must** be read from the artifact, or it
goes stale invisibly.

| literal | site | what it is | verdict |
|---|---|---|---|
| `8000` | `aoi.R:317` | fetch buffer | contract — correct |
| `6000` | `aoi.R:334` | DEM corner margin | reasoned from fly + collection measurements; documented provisional and backstopped by `dem_coverage` — acceptable |
| `FALSE` | `aoi.R:351` | terrain correction off | contract — correct |
| `"footprint_basis"`, `"footprint_terrain"`, `"height_agl"`, `"dem_coverage"` | `aoi.R:99` | fly's reporting surface | hardcoding is right; **the set is stale** — fly returns 6 (finding 2) |
| `"gsd_scaled"` | `aoi.R:159` | fly's digital route name | **wrong side** — fly fact inside a guard, fails toward pass (proven) |
| `"^Film"` | `aoi.R:152` | BC catalogue `media` vocabulary | hardcoded; fails toward *skip* under fly 0.10.0, so the direction is safe. Nothing asserts the vocabulary is unchanged |
| `"0.5.0"`, `"0.5.1"`, `fly#35` | `aoi.R:79-82`, `:108` | which release added `dem` / fixed #35 | **verified against `fly/NEWS.md`** — 0.5.0 line 13, 0.5.1 line 3. Correct, and message prose is the right home |
| `0.95` | `aoi.R:617` | "fly's 0.95 coverage threshold" | **wrong side** — fly fact with no cross-check. Minor: report prose only, and the branch is unreachable while the DEM is off |
| `(bearing + 91)/90`, `180L` | `aoi.R:436-437` | copy of `fly:::bearing_to_rotation()` | **wrong side, and the sharpest instance** — verified identical to fly's internal on all 360 bearings, while fly 0.10.0 changed what the output *means* (finding 1) |
| `aoi_ledger_cols()`, `aoi_reasons()`, `aoi_kinds()`, `aoi_logs()` | `aoi.R` | ledger/report schema | contract — correct |
| registry bboxes, `blue_line_key` | `aoi.R:178-202` | AOI definitions | contract — correct |
| `expected_cols` | `test:174-179` | ledger schema, re-typed | contract, independently written — **correct, this is the round-1 fix** |
| `complete` formal-name lists | `test:62-67` | fly signatures | fly fact, hardcoded — **not load-bearing** (only `"dem"` membership is read), harmless |
| `"0.5.1"` | `test:108` | remedy text | pins the message, not the fact — correct |
| `4` | `test:243` | caller count floor | repo fact (5 actual) — correct, with slack |
| `"data/centroids/se_c.parquet"` | `test:148` | repo path | contract — correct |
| `"Film - BW"`, `"Digital - Colour"`, ... | `test:302, 319, 328` | catalogue vocabulary | fixture; stale-able but low cost |
| `c("nominal_scale","dem_agl","gsd_scaled")` | `test:325` | fly's terrain vocabulary | fly fact in a fixture; goes stale with the guard it exercises |
| `"^1 frame"`, `"quarter"`, `"FORCE_REFRESH"`, `"fly#35"`, `"01_fetch.R"`, `"dem_coverage"` | `test` | message-text pins | correct — these pin claims, which is the right use |
| `seq(0,270,90)`, `180L` | `test:349-351` | `aoi_rotation()` contract | correct |

## Enumeration 3 — mutations run

All applied to the working tree and reverted; `git diff` against the index is
empty and the suite is green.

| id | mutation | expected | observed |
|---|---|---|---|
| A | replace `aoi_require_fly()` call in `01_fetch.R` with a comment naming it | RED | **GREEN** — defect |
| B | delete the call with no mention | RED | RED — positive control, the scan has teeth |
| C | rename `sel_ids` (breaks the 2nd `sub()` anchor) + drop 3 columns | RED | RED — latent, not live |
| D | drop only `footprint_terrain` from the transmute output | RED | **GREEN** — defect |
| E | `aoi_film_mask("Film - BW", "gsd_scaled_v2")` | refusal | **no refusal** — defect |
| F | `aoi_film_mask("Film - BW", "gsd_scaled")` | refusal | refusal — positive control |
| G | `fly_georef()` on 11 real 1995 film frames, with vs without the `rotation` column | — | 11/11 vs **0/11 + 11 refusals** — finding 1 |
| H | `aoi_rotation()` vs `fly:::bearing_to_rotation()` over bearings 0..359 | — | 0 disagreements — finding 1 |
| I | `setdiff(names(fly_footprint(w)), names(w))` vs `aoi_footprint_cols()` | — | 2 columns dropped — finding 2 |
| J | `fly_bearing()` on the intact window vs the per-year subsets `02_georef.R` builds | — | 88/88 vs 87/88 — finding 2 |

## Is the class closed?

Enumerated, not eyeballed: **25 assertions**, **20 literal groups**, **10
mutations**. Three of the 25 assertions cannot fail on the property they name
(#22, #23, #25 — all three are text scans, all three proven). Three of the 20
literal groups are on the wrong side (`"gsd_scaled"`, `0.95`, `aoi_rotation()`'s
copy of a fly internal) and one is on the right side but stale
(`aoi_footprint_cols()`).

The three text scans and the four fly-side literals are the same mechanism at two
altitudes: a guard that reads what the repo says instead of what the thing does.
I do not claim the class is closed — I claim it is now counted, and the count
above is what a fourth round should try to reduce rather than re-derive.

Two checks I ran that came back clean, recorded so they are not re-run:

- The `no_footprint` re-key is on the **property**, not a proxy. fly asserts the
  invariant in its own source: `fly/R/fly_footprint.R:921-922` — *"Keeping the
  invariant `footprint_terrain is NA exactly where the geometry is empty` is what
  lets a caller read the column at all."*
- The `rotation = "auto"` argument at `02_georef.R:93` is inert, not
  contradictory: with a `rotation` column present, `has_rotation_col` is TRUE at
  `fly_georef.R:237` and the auto branch at `:268` never runs.
