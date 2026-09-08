# Review round 2 — #20 (staged diff)

Reviewer: code-check subagent. Date: 2026-09-07.
Scope: `git diff --cached` — `scripts/{aoi.R, 01_fetch.R, 02_georef.R, 00_review_samples.R,
test_pipeline.R, run_pipeline.sh, README.md}`, `tests/test_aoi.R`, `CLAUDE.md`, PWF files.

**The captured diff was stale.** `/tmp/.../final.diff` predates the index by two fixes:
`aoi_film_mask()`'s `is.null(media)` refusal and the removal of the `terrain <- ledger$…`
local in `aoi_terrain_lines()`. Everything below was measured against the **current index**
(`git diff` empty, so index == worktree), not against the captured diff.

Everything is measured. Commands and outputs inline.

---

## Findings

### 1. [fragile] tests/test_aoi.R:189-196 — the "transmute() names every declared column" guard is defeatable two ways, both measured green

```r
block <- sub(".*ledger <- window \\|>", "", fetch_src)
block <- sub("sel_ids <-.*", "", block)
absent <- cols[!vapply(cols, function(c) grepl(c, block, fixed = TRUE), logical(1))]
```

**(a) The extracted block contains the transmute's own comments**, and those comments name
two of the columns being checked (`01_fetch.R:132-137`). Deleting `footprint_basis` and
`footprint_terrain` from the `transmute()` leaves the assertion green:

```
$ Rscript /tmp/probe1.R
extracted nchar: 956  of  7130
mutation took: TRUE
still 'found' in block after deletion: footprint_basis, footprint_terrain
```

Those are exactly the two columns whose loss #20 exists to prevent — the pre-#20 bug was
`window$footprint_basis <- fly_footprint(window)$footprint_basis` discarding the rest — so
the guard is blind on its own subject.

**(b) `sub()` returns the string unchanged when the anchor does not match.** Reformat the
pipe, switch to `%>%`, or rename `ledger`, and `block` silently becomes the whole file,
where all 13 names appear:

```
non-matching anchor leaves whole file: TRUE
whole-file vacuous pass: TRUE
```

That is `code-check.md`'s "A guard that fails toward pass": the failure path (regex missed)
and the pass path (everything found) are indistinguishable.

Fix, both halves, three lines:

```r
block <- sub(".*ledger <- window \\|>", "", fetch_src)
stopifnot(nchar(block) < nchar(fetch_src))          # the anchor matched
block <- sub("sel_ids <-.*", "", block)
block <- paste(grep("^\\s*#", strsplit(block, "\n")[[1]], value = TRUE, invert = TRUE),
               collapse = "\n")                      # code only, not comments
```

With the comment strip in place, mutation (a) reddens.

---

### 2. [fragile] tests/test_aoi.R:213-222 — the "no unguarded fly caller" complement passes on an empty set, and keys on a style one of its own subjects does not use

```r
fly_callers <- Filter(function(f) grepl("library(fly)", ...), list.files("scripts", ...))
ok("no unguarded fly caller in scripts/", all(vapply(fly_callers, ..., logical(1))))
```

`all(vapply(character(0), f, logical(1)))` is `TRUE`. Nothing asserts `fly_callers` is
non-empty, so a wrong working directory, a `scripts/` rename, or every script moving to
`fly::` calls turns this into a green no-op. Four files match today, so it is not vacuous
*now* — but nothing would say so when it stops being.

Second half: the filter is `library(fly)`, while `01_fetch.R`, `02_georef.R` and
`00_review_samples.R` all call fly as `fly::fly_*`. A new stage written in that style with
no `library(fly)` line is invisible to the complement — which is the exact case the
complement exists for (`00_review_samples.R` was the caller round 1 caught being missed).

```r
ok("found the fly callers at all", length(fly_callers) >= 4)
# and widen the filter: grepl("library\\(fly\\)|fly::", src)
```

---

### 3. [fragile] scripts/aoi.R:391-393 — `file.rename()`'s return value is discarded on the one destructive step

```r
tmp <- paste0(path, ".tmp.tif")
terra::writeRaster(dem, tmp, overwrite = TRUE)
file.rename(tmp, path)
```

`file.rename()` signals failure by returning `FALSE` with a warning, not by erroring —
`code-check.md`, "The one destructive step is the one that must not go unchecked". Here the
next line (`terra::rast(path)`) happens to error on the missing file, so today it fails
loudly *by accident*: the loudness is a property of the caller, not of this function. Move
either line and it goes quiet. One line:

```r
if (!file.rename(tmp, path)) {
  stop("Could not move the DEM into place: ", tmp, " -> ", path, call. = FALSE)
}
```

Minor, same block: `terra::writeRaster()` can drop a PAM sidecar beside its target. Only
`.tmp.tif` is renamed, so a `<id>.tif.tmp.tif.aux.xml` would be orphaned next to a
`<id>.tif` with no sidecar. Rename or delete it with the same call if one appears.

---

### 4. [fragile] scripts/01_fetch.R:96-99, 120-122 — the change's own "riskiest assumption" is measured but not guarded

```r
window$footprint_basis   <- fp$footprint_basis      # by position
window$footprint_terrain <- fp$footprint_terrain
window$height_agl        <- fp$height_agl
window$dem_coverage      <- fp$dem_coverage
...
cand_ids <- window$airp_id[lengths(sf::st_intersects(fp, ...)) > 0]   # fp rows -> window ids
```

`findings.md` calls this "the riskiest assumption in the change" and measured it once
(`airp_id IDENTICAL and in order: TRUE`). Nothing in the code asserts it.
`aoi_check_footprint_cols()` checks column *presence*, not row alignment — a reorder is
invisible to it, and a same-length reorder is invisible to R too: four columns and the
candidate set all silently name the wrong frames.

Verified this is currently safe by construction rather than by luck — `fly_footprint()`
assigns its attributes by vector position onto the input object and returns it
(`fly/R/fly_footprint.R:773-774, 988-996`), and `fly_bearing()` likewise builds
`bearing[ord[i]]` back into input order and returns `photos_sf` (`fly/R/fly_bearing.R:70,
99-110`). So this is low risk today. It is still a one-line assertion on the property the
whole diff rests on, and it is what makes a future fly change loud instead of silent:

```r
stopifnot(nrow(fp) == nrow(window), identical(fp$airp_id, window$airp_id))
```

---

## Checked and clean — with the evidence

The specific items asked about. Each measured; none is a finding.

| item | verdict |
|---|---|
| **`aoi_terrain_lines()` `ifelse` scope** | Clean, and already repaired in the index: the `terrain <- ledger$footprint_terrain` local is gone and `mutate()` now references the column directly (`aoi.R:580-583`). Had the local stayed it would still have been *correct* — dplyr data-masking resolves a non-column name to the enclosing environment — but the column reference removes the question. |
| **`aoi_terrain_lines()` on 0 rows** | Safe. `ifelse(logical(0), …)` gives `logical(0)`, `mutate()` accepts it on a 0-row frame, `count()` returns 0 rows, `kable()` emits header-only. Measured: returns the 2-line table plus the DEM-off paragraph, no error. Unreachable in practice anyway — `01_fetch.R:148` aborts on an empty selection first. |
| **`knitr::kable()` inside `c()`** | Safe. `kable` returns a `knitr_kable` character vector; `c()` drops the class and splices every element, which is what `writeLines()` wants. Same shape as the pre-existing `by_era` table at `aoi.R:646`. Measured output is well-formed markdown. |
| **CSV round-trip of the terrain columns** | Handled. Measured on a DEM-off ledger: `footprint_terrain` returns `character`, `height_agl`/`dem_coverage` return `logical` (all-NA). The `as.numeric()` re-coercion at `aoi.R:575-576` is what makes `01_fetch.R`'s report and `02_georef.R`'s identical, and `!any(!is.na(cov))` correctly selects the DEM-off branch on a logical column. |
| **`aoi_film_mask()` with an absent `media` column** | Already fixed in the index (`aoi.R:144-150`), and the fix is right. Without it `aoi_film_mask(NULL)` returned `logical(0)`, and `window$rotation[!logical(0)] <- NA_integer_` is a **silent no-op** — every digital frame would have kept a film rotation and shipped a quarter turn out. The test at `test_aoi.R:279-281` reaches it. Length mismatch is not otherwise reachable: `film` is derived from `window$media`, a column, so it is always `nrow(window)`. |
| **`aoi_film_mask()` with all-NA media** | Correct direction. Unknown media reads as not-film, so the frame gets `rotation = NA` and falls to fly's own `fly_digital_rotation()` rather than an invented 180. Fails toward "let fly measure it", which is the safe arm. |
| **`aoi_film_mask()` clash check under a DEM** | Checked and **not** a defect — I expected `gsd_scaled` to be overwritten once a DEM is supplied and it is not: `dem_eligible <- !by_gsd & …` (`fly_footprint.R:811`), so GSD-sized frames keep `gsd_scaled` through the DEM block at 913-917. The cross-check still discriminates when `aoi_dem_enabled()` flips. |
| **`02_georef.R:109` overwriting a prior rejection reason** | Cannot happen. `ok` ⊆ `georef_results$airp_id` ⊆ `fetch_result` ⊆ `selected` (the parquet), and `01_fetch.R:146,154` writes that parquet from `rejected_reason == "selected"` only. So `no_footprint`, `footprint_misses_aoi` and `no_thumbnail_url` rows are structurally absent from `ok`. The one reason it *can* overwrite is `fetch_failed` → `selected`, which is the documented intent (a frame that failed once and succeeds on a re-run must be able to move back) and is correct. |
| **`airp_id` type across the CSV/parquet boundary** | Safe. Measured on the real artifacts: ledger `airp_id` reads back as `numeric`, parquet as `integer`; `%in%` coerces to a common numeric type and matches **88 of 88**. No leading zeros, no scientific-notation width. |
| **`aoi_ledger_write()` reconciliation on the new path** | Still satisfied. In `01_fetch.R` the ledger is a `transmute()` of `window`, itself the whole cache; in `02_georef.R` it is the CSV read back. Measured on `se_c`: 1,013 ledger rows, and the reasons partition as `footprint_misses_aoi` 907 / `no_footprint` 15 / `no_thumbnail_url` 3 / `selected` 88 = 1,013. The `n_distinct(airp_id)` arm is what carries the real weight and it holds. |
| **`no_footprint` re-key vs the rotation mask** | Consistent, and cross-checks: `sum(is.na(rotation))` = 203 (every digital frame) and `no_footprint` = 15 (the unsizeable subset), which is the 188 + 15 split findings.md reports. |
| **`cand_ids` when nothing intersects** | Loud. `window$airp_id[all-FALSE]` is `character(0)`, every row becomes `footprint_misses_aoi`, `sel_ids` is empty and `01_fetch.R:148` aborts with a named message. And `case_when` orders `is.na(footprint_terrain)` **first**, so an unsized frame whose bare centroid happened to intersect could not be mislabelled. |
| **`sum(cov < 0.95, na.rm = TRUE)`** | Safe, and unreachable with the DEM off — the early return at `aoi.R:590` fires first. On the DEM-on branch `cov` is numeric with NAs and `na.rm` covers them. |
| **`test_pipeline.R:79` `dem = aoi_dem(id)`** | `id` is defined at `test_pipeline.R:22`. Lazy evaluation means it is forced inside `fly_georef()`; with the DEM off it is `NULL`, with it on the cache exists because the stage requires 01_fetch to have run. |
| **`00_review_samples.R` fly guard + DEM** | Correct. It carries `library(fly)` so the complement in finding 2 does cover it today, and `aoi_dem(id)` with `build = FALSE` matches the read-only asymmetry `aoi.R:360-365` documents. |
| **`data/dem/` tracking** | Ignored. `.gitignore`'s `data/*` covers it; only `data/reports/*.md` is un-ignored. |
| **`aoi_require_fly()` degenerate inputs** | The round-1 fix holds. Measured through the suite: `list()`, `setNames(list(), character(0))`, an unnamed list and a one-element list are all refused. |
| **Suite state** | `Rscript tests/test_aoi.R` — all assertions pass, including the two real-fly arms (the `se_c` centroid cache is present, so neither is SKIPPED). |

Note on the one round-1 item not carried through: `test_aoi.R:250` (`refuses a pre-#20
ledger`) still asserts only `!is.na(refusal(...))` with no `grepl()` on the text. The
hardened `refusal()` closes the empty-message half, and `aoi_ledger_check_cols()` has
exactly one abort path, so it is currently unambiguous — but it is the one refusal
assertion in the file not matched on its message.

---

## Summary

No bugs. Four fragility findings, all cheap:

1. Two mutations of `01_fetch.R`'s `transmute()` leave `tests/test_aoi.R` green (measured);
   and the block extraction fails toward a whole-file vacuous pass.
2. The "no unguarded fly caller" complement passes on an empty set and keys on
   `library(fly)`, a style its own subjects do not use.
3. `file.rename()` unchecked on the DEM's one destructive step.
4. `fp` → `window` positional alignment measured once, asserted nowhere. Safe today by
   fly's construction, verified in fly's source.
