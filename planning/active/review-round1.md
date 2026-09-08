# Review round 1 — #20 phase 1 (staged diff)

Reviewer: code-check subagent. Date: 2026-09-07.
Scope: `git diff --cached` — CLAUDE.md, scripts/{01_fetch.R, 02_georef.R, aoi.R,
README.md, run_pipeline.sh, test_pipeline.R}, tests/test_aoi.R.

Everything below was **measured**, not read. Commands and outputs are inline.

---

## Findings

### 1. [bug] scripts/aoi.R:349 — the schema guard is wired in ahead of its producer; both stages abort on every run

`aoi_ledger_write()` now calls `aoi_ledger_check_cols()`, which requires
`footprint_terrain`, `height_agl` and `dem_coverage`. Nothing in this diff produces
them. `01_fetch.R:91-105`'s `transmute()` emits exactly ten columns:

```
aoi_id airp_id film_roll frame_number photo_year era footprint_basis rotation
thumbnail_image_url rejected_reason
```

Measured against both real producers:

```
$ Rscript -e 'source("scripts/aoi.R"); ...'
01_fetch ledger -> ABORT: Ledger for 'se_a' is missing 3 column(s):
    footprint_terrain, height_agl, dem_coverage.
02_georef ledger -> ABORT: Ledger for 'se_a' is missing 3 column(s):
    footprint_terrain, height_agl, dem_coverage.
```

The second was run against the real `data/select/se_a.csv` on disk, read back with
`readr::read_csv()` exactly as `02_georef.R:88` does. All three committed ledgers
(`se_a.csv`, `se_b.csv`, `se_c.csv`) have the same ten columns.

**Where the abort lands is what makes it expensive.** `01_fetch.R` calls
`aoi_ledger_write()` at line 143 — *after* `fly_fetch()` has downloaded every
thumbnail for every year (lines 127-136) and after `fetch_results` has been written
to the fetch log. So the run does all the network work, then throws away the ledger
and the report. This is `code-check.md`'s "`cmd dir/*` dies on ARG_MAX at scale — and
only after the expensive work already succeeded", one repo over: the costly stage
succeeds and the cheap one discards it.

The task plan puts `aoi_ledger_cols()` + the schema check in **Phase 2**
(`planning/active/task_plan.md`, "Phase 2: Stop discarding the result"), together
with the `transmute()` change that feeds it. This diff has landed Phase 2's *guard*
without Phase 2's *producer*.

Given the phases land in one PR the merged state is fine, but as committed the branch
is not bisectable and any `Rscript scripts/01_fetch.R` run between this commit and
the Phase 2 commit burns a full fetch. Two acceptable fixes:

- move `aoi_ledger_cols()` / `aoi_ledger_check_cols()` / the `aoi_ledger_write()` call
  into the Phase 2 commit, where their producer is, or
- keep them here and land Phase 2 in the same commit.

Do not "fix" it by softening the guard — the guard is right; only its arrival time is
wrong.

---

### 2. [bug] tests/test_aoi.R:110-114 — "accepts a complete ledger" derives its fixture from the guard's own list, so it can never fail

```r
cols <- aoi_ledger_cols()
full <- as.data.frame(stats::setNames(rep(list(logical(0)), length(cols)), cols))
ok("accepts a complete ledger", is.na(refusal(aoi_ledger_check_cols(full, "se_a"))))
```

Both sides of that assertion come from `aoi_ledger_cols()`, so it reduces to
`setdiff(x, x)` and is green for **any** definition of the column list — including one
that names a column no producer will ever write. `code-check.md`, "Verification that
reads its own output": *a round-trip through your own reader validates only
self-consistency*.

Proved by mutation. A copy of the tree with one bogus name appended to
`aoi_ledger_cols()`:

```r
"rotation", "thumbnail_image_url", "rejected_reason", "zzz_bogus_column")
```

`Rscript tests/test_aoi.R` on that tree:

```
accepts a complete ledger                                  PASS
refuses a ledger missing a terrain column                  PASS
  ... names the missing column                             PASS
refuses a pre-#20 ledger                                   PASS
tolerates an extra column                                  PASS
All assertions passed.        (exit 0)
```

Every assertion green, while `aoi_ledger_write()` would abort on every real run —
which is *exactly* the live state of finding 1. **The suite is structurally incapable
of seeing the defect this diff actually contains.**

`ok("keeps the columns the report and 02_georef.R read", ...)` at line 98 is the one
assertion in the section that is hardcoded rather than derived, and it names six
columns — none of them the three that matter, so it does not close the gap.

The fix is one absolute assertion driven from the **producer**, not from the guard.
Cheapest form that would have failed on this diff:

```r
# the columns 01_fetch.R's transmute() actually emits — restated deliberately,
# so this and aoi_ledger_cols() are two independently-maintained copies of one
# contract and a divergence between them is what turns the suite red
fetch_cols <- c("aoi_id", "airp_id", "film_roll", "frame_number", "photo_year",
                "era", "footprint_basis", "footprint_terrain", "height_agl",
                "dem_coverage", "rotation", "thumbnail_image_url",
                "rejected_reason")
ok("01_fetch.R's ledger satisfies the schema",
   is.na(refusal(aoi_ledger_check_cols(
     as.data.frame(stats::setNames(rep(list(logical(0)), length(fetch_cols)),
                                   fetch_cols)), "se_a"))))
```

Better still, parse the literal out of `scripts/01_fetch.R` so it cannot be
hand-synced. Either way, keep the derived assertion too — it is harmless; it is just
not evidence.

---

### 3. [fragile] scripts/aoi.R:307-308 — the refusal names a remedy that walks back through the guard

```
"Re-run 01_fetch.R ", id, " to rebuild it."
```

As committed, that command aborts with the identical message (finding 1, measured
above), so a reader following the remedy is refused twice and learns nothing. This is
`code-check.md`'s fly#37 row — *a guard's error message must not recommend a remedy
that walks back through it* — and the check it prescribes is "run the remedy for every
input a clause can receive".

The remedy becomes correct once Phase 2 lands, so this resolves with finding 1 rather
than needing its own change. Flagged because it is what makes finding 1 costly rather
than merely untidy: the message actively directs the operator into a second full
fetch that also fails.

One thing to keep in view for Phase 2: re-running `01_fetch.R` rebuilds
`rejected_reason` from scratch, discarding the `georef_failed` marks `02_georef.R`
folded in. That is pre-existing behaviour and out of scope here, but the remedy
sentence is the place a reader learns about it.

---

### 4. [fragile] scripts/aoi.R:56 — `aoi_require_fly()` passes on an empty or unnamed `fns`

```r
missing <- names(fns)[!vapply(fns, function(f) "dem" %in% f, logical(1))]
```

`names(fns)` is `NULL` for an unnamed list, and `NULL[logical(0)]` and
`NULL[TRUE]` are both `NULL`, so `length(missing)` is 0 and the guard returns
`invisible(TRUE)`. Measured:

```
empty list:          PASSED (no refusal)
unnamed broken list: PASSED (no refusal)     # list(c("a","b")) — no `dem` anywhere
NULL element:        refused                  # list(fly_filter = NULL) — correct
partially named:     refused: "... : () takes no `dem` argument."
```

The default path (`fns = NULL`) always builds a fully-named three-element list, so
production cannot reach this; only the test injection can. It is still a guard failing
toward pass on the degenerate input, and the partially-named case renders a message
naming `()` with no function in it. Two lines close both:

```r
stopifnot(length(fns) > 0, !is.null(names(fns)), all(nzchar(names(fns))))
```

Low severity — reachable only from tests today.

---

### 5. [fragile] tests/test_aoi.R:28-33 — `refusal()` cannot distinguish an abort from an abort with an empty message

`stop("")` yields `conditionMessage(e) == ""`, and `!is.na("")` is `TRUE`, so an
empty-message abort counts as a valid refusal. Measured:

```
empty-message abort -> refusal() returns: [] ; !is.na -> TRUE
```

Most refusal assertions pair the `!is.na(msg)` check with a `grepl()` on the text, so
they are safe. Two do not:

- line 129, `ok("refuses a pre-#20 ledger", !is.na(refusal(...)))`
- line 64, `ok(paste0("refuses a fly whose ", fn, "() has no `dem`"), !is.na(msg))`
  — mitigated by the two text assertions immediately after it.

Line 129 is the exposed one: any error from `aoi_ledger_check_cols()`, for any reason,
counts as evidence. `code-check.md`, "A restored bug can fire a DIFFERENT guard" —
*grep the output for the message you expect, never just the status*. Add
`grepl("footprint_terrain", msg, fixed = TRUE)` beside it.

---

## Checked and clean — with the evidence

These were the specific items asked about. Each was measured; none is a finding.

| item | verdict |
|---|---|
| **`setdiff()` direction** (`aoi.R:302`) | Correct. `setdiff(required, present)` = missing. Verified against a real `readr::read_csv()` of `data/select/se_a.csv` — it reports the three absent columns and nothing spurious. Extra columns pass, as documented. |
| **`ok()` counts an erroring expression as a failure** | Yes. `expr` is a lazy promise forced inside `tryCatch`, so `ok("x", stop("boom"))` prints `FAIL - boom` and increments the counter. Measured: `failures counted: 1`. Nothing is swallowed. |
| **`<<-` on `failures`** | Correct. Both `failures` and `ok` live in the global env, so `<<-` resolves through the enclosure to the global binding. The suite exits non-zero via `stop()` at line 156. |
| **Singular/plural in `stop()`** | Correct both ways. One missing → `"fly_filter() takes no \`dem\` argument."`; three → `"fly_filter(), fly_footprint(), fly_georef() take no ..."`. Both branches of the `if` return a string, so no `NULL` reaches `stop()`. |
| **`names(formals())` on all three fly functions** | Safe. Measured on the installed fly **0.10.0**: `fly_filter(photos_sf, aoi_sf, method, buffer, dem)`, `fly_footprint(centroids_sf, negative_size, format_size, dem)`, `fly_georef(fetch_result, photos_sf, dest_dir, overwrite, srcnodata, rotation, dem)`. All plain closures, no generic/`...` indirection, `dem` present on all three. The positive control in the suite genuinely passes. |
| **fly not installed at all** | Comprehensible. All three call sites (`01_fetch.R:15`, `02_georef.R:14`, `test_pipeline.R:13`) run `library(fly)` *before* `source("scripts/aoi.R")`, so a missing fly fails first with R's own `there is no package called 'fly'`. `aoi_require_fly()` is never reached, so its install remedy is not shown — acceptable, since `library()`'s message is unambiguous. A *renamed* function would surface as `object 'fly_filter' not found`, which is less good but still names the thing. |
| **`aoi_require_fly()` placement vs `library(fly)`** | Fine in all three scripts — `library(fly)` precedes it everywhere. It also now runs before `aoi_ids()` in `01_fetch.R`, so an unknown AOI id is reported after the fly check instead of before; both are pre-work and cheap, so ordering is immaterial. |
| **`run_pipeline.sh` backticks in the new comment block** | No risk. `#` comments are discarded by the parser before any expansion, so the backticks around `dem` and the `()` are inert. Verified two ways: `bash -n scripts/run_pipeline.sh` clean, and a live `bash -c` with `$(echo SIDE_EFFECT)` inside an identical comment produced no side effect. No heredoc is in scope. |
| **BSD/GNU portability, `set -u` array guards** | Unchanged by this diff, and the pre-existing `[ ${#AOI_IDS[@]} -gt 0 ]` guards are the correct bash 3.2 form. |
| **`aoi_require_fly()` refusal tests reach the failure mode** | Yes — the injectable `fns` is the right call. The per-function loop, the all-three case, and the "names no other function" assertions each fail if the guard reports only the first miss or always reports all three. Restore-the-bug on the *fly* half is genuinely covered; it is the *ledger* half (finding 2) that is not. |
| **"One fact derived twice" — is the column list duplicated?** | Only once, deliberately, between `aoi_ledger_cols()` and `01_fetch.R`'s `transmute()` — which is the correct shape (a builder's copy and a validator's copy, so the guard is not `x == x`). The problem is not the duplication; it is that **no test compares the two copies**. See finding 2. |
| **CLAUDE.md / README.md / run_pipeline.sh prose** | Consistent with the code. All three now describe the capability rather than a version floor, and none restates a version number that will go stale. `flooded` is listed as a requirement before Phase 3 uses it — harmless, and true at merge. |

---

## Summary

Two things must change before merge:

1. **Finding 1** — the schema guard must land in the same commit as the `transmute()`
   that satisfies it, or the branch has a commit where every pipeline run aborts after
   downloading everything.
2. **Finding 2** — add one absolute assertion driven from `01_fetch.R`'s column set.
   The suite is currently green on a tree where the guard rejects every real ledger,
   which is the one thing it exists to prevent.

Findings 3-5 are cheap and can ride along.
