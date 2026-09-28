# Review round 1 — #32 staged diff

## Clean

No issues found.

### What was checked

- `01_fetch.R:210` `aoi_id = !!id`: probed. `transmute()` over a frame carrying an
  `id` column, inside a top-level `for (id in ...)`, yields the loop value on every row.
  There are no other bare `id` references in a data-masked verb in 01_fetch.R,
  02_georef.R or aoi.R. `aoi.R:487` `data.frame(aoi_id = id)` is base R, so nothing is
  masked there.
- `02_georef.R:71`: probed. `col_types = readr::cols(aoi_id = "c")` forces only that
  column and leaves the others guessed as before, so the read-back shape feeds
  `aoi_ledger_write()` unchanged. A numeric-looking id stays `chr`.
- `aoi_ledger_check_id()`: zero-row, NA, mixed and missing-column cases all refuse or
  accept correctly. The refusal is a `stop()` with a message and `call. = FALSE`, so it
  fails toward abort.
- Other ledger consumers: `centroids.py` `selected_ids()` (used by 03_cog.py and
  05_stac_register.py) reads `airp_id` and `rejected_reason` and never `aoi_id`, so the
  on-disk repair and the guard do not affect them. `test_pipeline.R` and
  `00_review_samples.R` build no ledger.
- Test parse assertions: the regex spellings match the accepted `!!id` / `.env$id`
  forms, and the `tryCatch(..., FALSE)` around `parse()` fails red, not green.

### Considered and not raised (below the bar)

- `tests/test_aoi.R:456`: "02_georef.R calls aoi_ledger_check_id() on the read" is
  satisfied by the name appearing anywhere in 02_georef.R. If the call moved below
  `fly_georef()`, the test would stay green even though the label promises placement on
  the read. Nothing is broken today, since the call sits on the read at line 74. This is
  noted only as a limit of what the assertion can see.
