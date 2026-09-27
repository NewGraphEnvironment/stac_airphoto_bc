# Review — p1 round 2 (data-raw/tables_import-georef_validate.R + two CSVs)

Reviewed 2026-09-26 against the staged diff, the source tables at stac_orthophoto_bc@d5887d7,
the consumers in the working tree (`scripts/aoi.R` `aoi_rotation_table()` /
`aoi_rotation_for()` / report, `tests/test_aoi.R`, `scripts/03_cog.py`) and the #23 body.
Probes were run in `scratchpad/r2/`, with `GIT_OPTIONAL_LOCKS=0` against the real source so
`git status` could not rewrite its index.

## Round 1 fixes: verified

- Re-running the staged script against the real source gives both staged CSVs
  **byte-for-byte**. It also passes with `STAC_ORTHOPHOTO_BC` given as the mis-cased
  `/Users/airvine/PRojects/...` path and with a trailing slash, so the top-level check does
  not refuse a legitimate checkout.
- The provenance guard now fails loud: a plain copy with no git stops with
  `fatal: not a git repository`, and a copy nested inside another repo stops with "is not the
  top of a git checkout". Captured stderr on a *successful* git call can only add lines, and
  every added line leads to a refusal (a non-empty `dirty`, a length-2 `top`, or
  `length(src_sha) != 1`), never to a pass.
- `bc81050` and `bcc668` ship as `90,"disputed"`. The consumers handle the new value:
  `aoi_rotation_for()` passes it through, the report lists `disputed` rolls, the test pins
  `%in% c("measured","reviewed","disputed")`, and the #23 body defines it.

## Findings

- **[low / fragile]** data-raw/tables_import-georef_validate.R:79,100 — The `DISPUTED`
  override replaces whatever label the source gives, **including a later human
  resolution**, and no guard notices. Probe D: set `bc81050` upstream to
  `decided_by_eye, rotation 0` (a reviewer settling the dispute), leave placement unchanged,
  and the import exits 0 and writes `"bc81050",0,"disputed"`. That output breaks the script's
  own definition of `disputed` ("the correlator decided it ... the value is kept"), because
  the value is now the reviewer's. This is the round 1 defect one axis over: the label again
  disagrees with the source, this time because a hardcoded list outlives the fact it
  records. The error is conservative, since the frames stay flagged for checking, so this is
  not a blocker. Fix, one guard: require every `DISPUTED` roll's source `verdict` to still be
  a correlator verdict (`decided` / `majority`), and otherwise stop with "the dispute may be
  resolved upstream — revisit DISPUTED".

- **[low]** data-raw/tables_import-georef_validate.R:140-143 — `"both disputed rolls present"`
  checks `rotation_roll` only. `"held rolls carry no shift"` is `all()` over the disputed
  rolls' rows in `placement_frame`, so it passes **vacuously** when those rows are missing,
  for example when the placement table spells the roll differently. Probe E: relabel
  `bcc668` as `BCC668` in the placement table only and give 5 of its frames a correlator
  shift, trading 5 other correlator frames to `none` so the pinned counts hold. The import
  exits 0 and the shifted frames ship. The output drops `film_roll` and consumers join
  placement by `airp_id`, so nothing downstream catches it. The trigger is contrived, but
  the guard's premise is not checked. Fix: add
  `all(DISPUTED %in% placement_frame$film_roll)`.

- **[low / fragile]** data-raw/tables_import-georef_validate.R:42 — `git status --porcelain`
  does not show gitignored files. If a table being read were ignored, the dirty check would
  pass and the stamped commit would not contain the bytes read. The source's `.gitignore`
  has a include/exclude scheme on exactly this directory (`data/georef_validate/*`, then
  `!data/georef_validate/*.csv`, lines 59-60). Both tables are **tracked today** (verified
  with `git ls-files`), so the committed outputs are correct. Probe C (tables present but
  ignored) exits 0 and stamps the commit. Fix: run
  `git ls-files --error-unmatch -- data/georef_validate/rotation_table.csv data/georef_validate/placement_frame.csv`
  through `git()` before reading.

Checked and not flagged:
- `order(film_roll)` gives the same result under `C` and `en_US` for the current data (all
  `[a-z0-9]`).
- `airp_id` parses to integer throughout (26234–1605904).
- `unname(table["x"])` is a plain integer, so `identical(..., 252L)` is sound.
- `write.csv` sets `na = ""`, and the output contains no NA.
- `on.exit` is inside a function, so it fires.
- The guards run before either write.
- `as.integer("NaN")` is 0 and would pass the rotation guard, but the source writes missing
  values as `NA` and unresolved rows are excluded, so this is latent only.
