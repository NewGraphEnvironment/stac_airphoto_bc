# Review round 3 — #32 (staged diff)

## Mechanism

Round 2's two defects share one assumption: **the locator the assertion uses is
present, and it is the thing the property is about.**

- *Present:* `min(..., Inf)` returns a legal operand when nothing is found, so
  "not found" compared as "comes last" and every placement passed. (It is the same
  shape as the earlier `sub()` that returned its input unchanged.)
- *Is the property:* "before the work" was anchored on `fly_georef`, one member of
  the set of calls that touch files, so the check could sit after `unlink()`.

Anywhere a test asserts "X is guarded" by checking that a name is present, rather
than that a call comes before the effect it guards, the same gap is open.

## Enumeration (assertion | absent/empty input -> red or pass)

| # | assertion (tests/test_aoi.R) | absent / empty / wrong input | result |
|---|---|---|---|
| 1 | L297 transmute assigns `aoi_id = !!id` / `.env$id` | block locator misses: "transmute block was actually located" (L265) goes red. `outputs` empty: grepl FALSE, red | red |
| 2 | L299 never a bare `aoi_id = id` | `outputs` empty: `!grepl` is TRUE, a vacuous pass, but #1 is red on the same input | red (pair) |
| 3 | L423 accepts matching ledger | positive control | n/a |
| 4 | L426 accepts zero-row ledger | asserts acceptance of the vacuous case, which is intended | n/a |
| 5 | L433-439 refuses WFS ids, names AOI, value and remedy | `msg` NA: the `!is.na(msg) &&` guard makes each red | red |
| 6 | L441 mixing | refusal NA: red | red |
| 7 | L444 NA aoi_id | refusal NA: red | red |
| 8 | L448 no aoi_id column | refusal NA: red | red |
| 9 | L454 `aoi_ledger_write()` calls `aoi_ledger_check_id()` | writer undefined: error, so `ok()` is red. Call moved **after `readr::write_csv()`**: **PASS** (mutated in a copy). Symbol referenced but never called (`chk <- aoi_ledger_check_id`): **PASS** (mutated) | **pass: gap** |
| 10 | L466 02_georef.R check on the read | any anchor absent: Inf, `is.finite` fails, red. Parse fails or `getParseData` returns NULL: FALSE or Inf, red. Check inside the closure after `unlink`: red (mutated). Check moved after `aoi_dem()` but still before `map_dfr`: green, which is correct. Wrapped in `try(..., silent = TRUE)`: PASS (generic; no presence test can see it) | red on absence |

The runtime guard `aoi_ledger_check_id()` (scripts/aoi.R:795), probed in a copy:

| input | result |
|---|---|
| no `aoi_id` column, zero-column df, NULL ledger | refuse |
| zero rows (character or logical column) | accept (vacuous; the writer's count check covers it) |
| factor column, good / bad | accept / refuse |
| numeric WFS-like ids | refuse |
| all-NA logical column (readr's guess for an empty column) | refuse |
| list-column good / bad | accept / refuse |
| `id = NA` | refuse |
| `id = character(0)` or `NULL` | **accept any ledger**: `vals != character(0)` is `logical(0)`, so `bad` is empty. Unreachable, because every caller passes the scalar `id` from `for (id in aoi_ids())`, and `aoi_ids()` aborts on an unknown id |
| `id` longer than 1 | recycles and can accept. Unreachable, as above |
| read path: CSV lacking `aoi_id` with `cols(aoi_id = "c")` | readr warns ("named parsers don't match") and continues; `aoi_ledger_check_cols()` then refuses. Red |

## Findings

- **[severity: fragile]** tests/test_aoi.R:454. The round 2 fix to one caller did
  not reach the other. The read-path assertion now pins *order* (the check comes
  before the first effect). The writer assertion pins only *presence*:
  `"aoi_ledger_check_id" %in% all.names(body(aoi_ledger_write))`. Two mutations of
  `aoi_ledger_write()` were each run in a copy, and each left the whole suite green:
  1. Moving the call below `readr::write_csv(ledger, aoi_path("ledger", id))`
     (scripts/aoi.R:855).
  2. Replacing the call with a bare symbol reference.

  Under mutation 1, a mis-keyed ledger overwrites the good one on disk and is
  refused only afterwards. 02_georef.R's read check would still stop the next stage,
  so the pipeline aborts rather than publishes. The cost is that the previous good
  ledger has been destroyed.

  The code is correct today: the call sits at aoi.R:848, before the write. What is
  missing is a test that holds it there. The fix is the same ordering the read-path
  test uses, applied to `body(aoi_ledger_write)`: parse the function body, and
  require the `aoi_ledger_check_id` call before `write_csv`, with both anchors
  finite.

No other findings. The transmute pair, the unit refusals and the read-path ordering
test all go red when their input is absent. The runtime guard refuses every
reachable absent, empty-valued, NA and wrong-typed case. The zero-length-`id` pass
is unreachable from its only two callers. The working tree was `cmp`-checked
unchanged after the mutation runs.
