# Review — p1 round 1 (data-raw/tables_import-georef_validate.R + two CSVs)

Reviewed 2026-09-26 against the staged diff, the full script, both outputs, both source
tables at stac_orthophoto_bc@d5887d7 (main, clean, on origin/main), research sections 14-15,
`scripts/georef_validate-placement.R` header and `PLACEMENT_HOLD` in
`scripts/georef_validate-functions.R:421-428`.

Verified: re-running the script (in a scratch copy) against the real source reproduces both
committed CSVs byte-for-byte. No reviewer notes, `decided_by`, `manual_note`, `threshold`,
`fly_sha_measured` or `film_roll` reach the placement output; the rotation output carries only
`film_roll, rotation, rotation_source`. No leak found. The source tables are git-tracked, so the
dirty check does look at the bytes read. Non-`none` shifts occur only on rolls present in
`rotation_roll.csv` (the 33 placement rolls absent from the rotation table and the two
unresolved rolls are all `none`). `unname(src_counts["x"])` compares correctly to an integer
(probed).

## Findings

- **[severity: bug]** data-raw/tables_import-georef_validate.R:44-58 (output
  data-raw/rotation_roll.csv rows `bc81050`, `bcc668`) — The two rolls whose rotation a person
  has **disputed** ship as `rotation_source = "measured"`, which this script (line 45) and the
  #23 body define as "the correlator decided it, and no person has looked". The mapping keys
  only on `rotation_table.csv$verdict` (`decided` / `majority`, `decided_by = correlator`,
  `manual_vs_auto = NA`), but the dispute is recorded elsewhere — upstream `PLACEMENT_HOLD`
  (functions.R:423: "the reviewer twice marked the published orientation right" for bc81050;
  bcc668 "may be flipped") and research section 14 ("`bc81050` is disputed"). The script knows
  this: its own guard at line 112-115 hardcodes the same two rolls *because* "a person disputes
  these two rolls' rotation". So 404 frames (bc81050 180, bcc668 224 in placement_frame) will be
  published with a provenance claim that is false in the direction that hides them from exactly
  the filter the property exists for (issue body: "so assumed frames can be filtered, checked by
  eye"). Whether to apply the correlator's 90 is upstream's decision ("it stays at the
  correlator's value"); the label is this import's. Needs a decision on how to represent it
  (a fourth value such as `disputed`, or leave them out so they fall to the series rule like
  the unresolved pair) — a stored-data vocabulary choice, so likely the user's.

- **[severity: fragile]** data-raw/tables_import-georef_validate.R:25,32-37 — The provenance
  guard fails toward pass when `SRC_REPO` is not a git checkout (e.g. `STAC_ORTHOPHOTO_BC`
  pointed at an exported/copied tree). `system2(stdout = TRUE)` does not capture stderr, so
  `git status` failing with status 128 returns `character(0)` plus a warning; `length(dirty)` is
  0 and the dirty check passes. `src_sha` is then `character(0)`, `sprintf()` returns
  `character(0)`, and `writeLines()` writes **no header line at all**. Reproduced in scratch:
  exit 0, message "Imported from stac_orthophoto_bc@: ...", both CSVs written with no
  provenance comment. The committed files would then differ from the documented format (line 1
  comment) and carry no source commit, silently. Fix: check `attr(x, "status")` on both git
  calls (or `length(src_sha) == 1 && nzchar(src_sha)`) and stop. (Related edge: a copy nested
  inside some *other* git repo would stamp that repo's sha, since `git -C` walks up.)

No other issues.
