# Code-check round 2 — #32 (parse-order test in tests/test_aoi.R)

Scope: the one change since round 1, `call_line()` + "02_georef.R calls
aoi_ledger_check_id() on the read" (tests/test_aoi.R:459-466). The rest of the
diff was re-read; nothing new there. Suite run from repo root: all assertions
pass; tree unchanged (`git status` identical before and after).

## What holds (probed on scratch copies, repo untouched)

- Both absent: `min(numeric(0), Inf)` is `Inf`, `Inf < Inf` is FALSE, red.
- check_id absent, fly_georef present: `Inf < 182`, red.
- check_id moved after fly_georef (inside the year closure): 187 vs 181, red.
- `getParseData()` returning NULL: `min(NULL, Inf)` is `Inf`, red. A parse error
  goes to `tryCatch` -> FALSE, red. Both fail safe.
- `fly::fly_georef(` tokenises the name as `SYMBOL_FUNCTION_CALL` (line 182), so the
  namespaced call is found. Comments and strings are not counted.
- Same line: strict `<` gives FALSE, so it can false-red but cannot false-green.

## Findings

- **[fragile]** tests/test_aoi.R:460 — the test can still pass vacuously. Nothing
  asserts that the anchor was found. If `fly_georef` stops appearing as a call token
  in 02_georef.R, `call_line(pd, "fly_georef")` is `Inf`, and any placement of
  `aoi_ledger_check_id()` passes, including one after the georeferencing. Two ways
  this happens: the call moves into a helper in aoi.R, or the function is passed as a
  value (`do.call(fly::fly_georef, ...)`, `purrr::map(..., fly::fly_georef)`).
  Probed: with `fly::fly_georef(` renamed to a helper, or wrapped in `do.call`, the
  anchor reads `Inf`. The test passes today only because check_id also happens to sit
  at line 74. This is the "guard that fails toward pass" shape. Fix: require the
  anchor to be finite, e.g.
  `g <- call_line(pd, "fly_georef"); is.finite(g) && call_line(pd, "aoi_ledger_check_id") < g`.

- **[fragile]** tests/test_aoi.R:465 vs scripts/02_georef.R:108-187 — "precedes the
  first fly_georef() call" is weaker than the claim the comment makes ("abort before
  any GeoTIFF is written" / "on the read"). Probed: with check_id moved to line 179,
  inside the per-year `map_dfr` closure just before `fly_georef`, the test still
  passes (179 < 182). In that position:
  - (a) `unlink(dest[stale])` at line 177 has already deleted the stale GeoTIFFs for
    that year.
  - (b) The check sits after the `if (nrow(fr) == 0) return(...)` at line 118, so for
    an AOI with no thumbnails on disk it never runs on the read. The only refusal
    left is in `aoi_ledger_write()` at the end.

  The current code (line 74, straight after the `read_csv`) is correct. The test just
  does not pin it there. Fix: anchor on the earliest consequential call rather than
  `fly_georef` alone, e.g. the minimum over `c("map_dfr", "unlink", "fly_footprint",
  "fly_georef")`, still asserted finite. Alternatively, assert check_id's call falls
  between the ledger `read_csv` and `aoi_dem`.

Neither finding is a runtime bug. Both concern whether the wiring test would catch
a future regression, which is the test's only purpose.
