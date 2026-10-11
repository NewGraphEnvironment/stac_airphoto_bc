# Task: Move the nge: item fields to standard or descriptive names (#47)

**If we do it:** each field an item carries says what it is. Clients that know the standard extension read the standard fields, and a reader does not have to know that `nge` means New Graph Environment. **If we never do:** the fields stay readable only to people who know the initials.

## Context

stac_pointcloud_bc#12 settled the rule for the whole catalogue family. A field with a standard home uses it, otherwise its prefix names what it describes, and `nge:` survives only where NGE itself is the subject. All four of this repo's `nge:` fields are run provenance, and the processing extension (v1.2.0) is their standard home. Every published item carries the same values today: fly `0.19.0`, fly sha `0eeb977c3893`, pipeline sha `e16dd5307f57` (10,100 of 10,100 local items).

Decided at the plan gate (2026-10-10):
- **fly sha:** goes into the version as semver build metadata: `processing:software: {"fly": "0.19.0+0eeb977c3893"}`. No new prefix, and nothing new is needed in crate#23.
- **Publishing:** this PR lands the code, tests and docs. Publishing waits for the next full rebuild, as the issue says. The PR proves the result locally with `05 --out <scratch>`.

| was | now |
|---|---|
| `nge:produced_datetime` | `processing:datetime` |
| `nge:fly_version` + `nge:fly_sha` | `processing:software` `{"fly": "<version>+<sha>"}` |
| `nge:pipeline_sha` | `processing:version`, which the spec defines as the version of "the processing chain that produced the data" |

**COG bytes do not change.** The COG tags are `FLY_VERSION`, `FLY_SHA` and `PIPELINE_SHA`, and none of them contains `nge`. They stay as they are, so only item JSON changes, and every `file:checksum` holds. Note that editing `scripts/` moves `pipeline_sha`, but 05 does not check it against the windows (only 03 does). Items regenerated later still record `e16dd5307f57`, the run that built the rasters, which is correct.

**Consequence of the validator guard:** once this merges, `stac_validate.py` refuses the `nge:`-named items currently in `data/stac`. So any sync, including `04_s3_upload.R`, has to re-run 05 first, and that publishes the rename. That is the intended coupling: the rename rides with the next publish of any kind.

## Phase 1: Tests first (failing)
- [x] `tests/test_cog.py`: `build_properties()` gives `processing:software == {"fly": "0.14.1+abc"}` and `processing:version == "def"`, and no `nge:` key
- [x] `tests/test_cog.py`: `build_properties()` leaves out `processing:software` when either fly part is missing (it never writes `"0.14.1+None"`); the validator then refuses the item as missing it
- [x] `tests/test_cog.py`: update `test_every_required_build_property_is_produced_somewhere` so its leftover set is `{"processing:datetime"}`
- [x] `tests/test_cog.py`: `check_item()` refuses an item that carries any `nge:` key, or any property or asset field whose prefix is not declared (`proj`, `file`, `processing`, `airphoto`), and one that uses `processing:*` without declaring the processing extension
- [x] `tests/test_cog.py`: `tags_disagree()` on a tmp GeoTIFF whose `FLY_SHA` tag differs from the sha part of `processing:software["fly"]` reports the mismatch, and one whose `PIPELINE_SHA` differs from `processing:version` does too

## Phase 2: Writer (`scripts/airphoto_props.py`, `scripts/05_stac_register.py`)
- [x] `airphoto_props.py`: remove the `nge:` rows from `BUILD_PROPERTY_FIELDS`, leaving the `airphoto:` mapping only. `build_properties()` adds `processing:software` and `processing:version`. Rewrite the prefix comment block: `processing:` is now the ground shared with floodplains#74
- [x] `airphoto_props.py`: add a `PROCESSING_EXTENSION` constant (`https://stac-extensions.github.io/processing/v1.2.0/schema.json`) and a declared-prefix set. `REQUIRED_BUILD_PROPERTIES` swaps the four `nge:` keys for `processing:software`, `processing:version` and `processing:datetime`
- [x] `05_stac_register.py`: stamp `processing:datetime` (the COG mtime, as before) and list `PROCESSING_EXTENSION` in `stac_extensions`

## Phase 3: Validator (`scripts/stac_validate.py`)
- [x] `tags_disagree()`: compare `FLY_VERSION`+`FLY_SHA` with `processing:software["fly"]`, and `PIPELINE_SHA` with `processing:version`. Keep the existing loop for the `airphoto:` tags
- [x] `check_item()`: refuse undeclared prefixes on properties and on asset fields (this catches `nge:` and any future stray), refuse `processing:*` without the extension, and refuse `processing:software` without a `fly` entry
- [x] Restore the bug: put an `nge:` key back in a fixture, and drop `PROCESSING_EXTENSION` from 05, and confirm each guard fails

## Phase 4: Local proof (nothing published)
- [ ] `uv run pytest tests/ -q` green
- [ ] `uv run python scripts/05_stac_register.py --out <scratch>`, then a scratch script diffs every item against `data/stac`. Expected: only the 4 → 3 key swap with equal values, plus `stac_extensions` gaining processing. Count the items and report the total
- [ ] `check_item(doc, Path("data/stac"))` on every scratch item: 0 problems, with tags checked against the real COGs

## Phase 5: Docs, NEWS, issue
- [ ] `CLAUDE.md` (Architecture paragraph, the Build properties table) and `README.Rmd`, then re-render `README.md`. Check that the diff touches only that paragraph
- [ ] New `NEWS.md` with an entry for the unpublished change that names each old → new pair (saved filters stop matching), plus the `like '0.19.0+%'` note for filtering by fly version
- [ ] Edit the #47 body so its Fields table records the decisions. Comment on crate#23 that this repo needs no new prefix, though `airphoto:` itself still has no schema

## Validation

- [ ] Tests pass
- [ ] `/code-check` clean (each commit, or once over the branch with `/code-check branch`)
- [ ] PWF checkboxes match landed work
- [ ] `/planning-archive` on completion

## Out of scope
- The `06_catalogue_*` backfill scripts (historical; their additive check would flag the dropped keys, and they are not in the run path)
- A crate schema for `airphoto:` (crate#23's remit)
- Publishing: 05 → `04_s3_upload.R` → `stacs register --mode all` at the next rebuild
