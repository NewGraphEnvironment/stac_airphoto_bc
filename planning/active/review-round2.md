# Code-check round 2 (#47)

## Clean

No issues found.

### What was checked (so "Clean" is a measurement, not a quiet round)

- **The rename preserves every value, across the whole collection.** Each of the
  10,100 items in `data/stac` was compared with its regenerated twin in the scratch
  `stac47/` (05 run with `--out`). The four `nge:` keys were mapped to
  `processing:software {"fly": "<v>+<sha>"}`, `processing:version` and
  `processing:datetime`, and the processing URL was appended to `stac_extensions`.
  After that mapping, **10,100 of 10,100 are equal and 0 differ**, and
  `collection.json` is identical. NEWS's "changes no value … only item JSON changes"
  holds for the documented publish order.
- **The scratch 05 run passed pystac `validate()`** against the live processing
  v1.2.0 schema on all 10,100 items. It also passed `check_item()`, including
  `tags_disagree()` against the real COG tags. The `processing:datetime` ISO strings
  carry microseconds and `+00:00`, and they validate.
- **`check_item()` refuses the current `data/stac` items** (4 undeclared-prefix
  problems, 2 tag disagreements and 3 missing keys per item) and passes the renamed
  ones. So CLAUDE.md is right that `04_s3_upload.R` cannot sync until 05 has
  rewritten every item.
- **Fixes from round 1 and the plan review:**
  - `_blank()`: `""`, `None` and `NaN` are covered for both fly parts by the
    parametrised test. The `""` case cannot be reached in practice:
    `aoi_provenance()` refuses an empty RemoteSha or pipeline SHA. 03's `fmt("")`
    would still tag `""`, but 05 then refuses the item as missing
    `processing:software`. That fails toward refusal and is not new.
  - The core-key skip and the projection pairing: removing the `":" not in key`
    skip, or mapping `proj` to `None`, would turn the matching new test red, as
    the tests' own assertions show.
  - The publish order (`05 --require-all-published` → 04 → `stacs --mode all` →
    confirm no live `nge:` → re-render Pages) is consistent with the code:
    - `--require-all-published` writes `not_rebuilt.txt` and fails; the JSON sync
      excludes `.txt`.
    - The JSON sync compares size and timestamp, so rewritten items upload.
    - The pgstac upsert replaces each body, so no `nge:` key survives there.
    - The scratch run reported 0 published items not rebuilt.
- **Other readers of the renamed fields:**
  - `06_catalogue_backfill.py`, `06_catalogue_validate.py`,
    `cog_render-compare.py`, `cog_rewrite-check.py`, `04_s3_upload.R` and
    `test_stacs_config.py` read none of the renamed properties.
  - 03's tag names (`FLY_VERSION`, `FLY_SHA`, `PIPELINE_SHA`) are unchanged, and the
    new `tags_disagree()` block compares against them.
  - The `06_catalogue_promote.sh` path refuses post-#23 items already, so it cannot
    re-introduce `nge:` items.
- **Cited issues resolve and match the work:** stac_floodplains_bc#74 (open, the
  same rename) and stac_pointcloud_bc#12 (the family rule).
- `uv run pytest tests/ -q`: 108 passed.

### Noted, not a defect

- **`processing:version` names the window's commit (`e16dd5307f57`), not the
  commit whose 05 wrote the renamed JSON.** That is the existing `pipeline_sha`
  contract: it names the code that produced the raster. It also fits the extension's
  "software that produced the data". It does mean a checkout of `e16dd5307f57`
  reproduces the COG, not the item body.
- **`index.html` still names the `nge:` fields.** This is the tradeoff accepted in
  round 1. README.md was re-rendered with wording that is accurate before and after
  publishing ("Items published before the rebuild … hold the same values as `nge:`
  fields"). So `index.html` could be re-rendered now from the same text without
  becoming wrong. Deferring it is a choice, not a necessity.
