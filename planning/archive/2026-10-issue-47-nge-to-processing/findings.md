# Findings — Move the nge: item fields to standard or descriptive names (#47)

## Issue context

**If we do it:** each field an item carries says what it is. Clients that know the standard extension read the standard fields, and a reader does not have to know that `nge` means New Graph Environment. **If we never do:** the fields stay readable only to people who know the initials.

Decided for the catalogue family in NewGraphEnvironment/stac_pointcloud_bc#12 (2026-10-10):
- A field with a standard home uses it.
- Otherwise its prefix names what it describes.
- `nge:` stays only where New Graph Environment itself is the subject.

Each custom prefix gets a JSON Schema in crate, which items list in `stac_extensions` (NewGraphEnvironment/crate#23 is the umbrella; `lidarbc` and `las` are done there). **Prefer a standard field.** A custom prefix earns a crate schema only when more than one catalogue writes it, or something outside NGE reads it (`crate/pkgdown/assets/stac/README.md`), because every schema is permanent and every field change is a new version. Provenance that only this catalogue writes goes in `processing:*` or a `derived_from` link.

Once the mapping below is settled, file one crate issue for the custom prefixes that remain and link it from crate#23. This catalogue's rebuild waits on that crate deploy. Validate against copies of the schemas checked into this repo, as stac_pointcloud_bc#2 does, not against the live URLs. The [processing extension](https://github.com/stac-extensions/processing) (v1.2.0) defines `processing:datetime`, `processing:version`, `processing:software` (a name → version map) and `processing:lineage`.

## Fields (main, 2026-10-10)

The mapping below is a proposal. Check each row against what the field holds before renaming it.

| field | proposed | note |
|---|---|---|
| `nge:produced_datetime` | `processing:datetime` | the same meaning |
| `nge:fly_version` | `processing:software` `{"fly": "<version>"}` | |
| `nge:fly_sha` | the `fly` entry's value, or a custom field | `processing:software` holds one string per name: decide whether a sha belongs beside the version |
| `nge:pipeline_sha` | `processing:version` (this pipeline's commit), or `processing:software` | |

## When

Renaming changes every published item, so it rides with this catalogue's next full rebuild, not a release of its own. NEWS names each old → new pair, because a saved filter on an old name stops matching.



## Exploration (2026-10-10)

- `nge:` fields are written in `scripts/airphoto_props.py` (`BUILD_PROPERTY_FIELDS`, `REQUIRED_BUILD_PROPERTIES`) and `scripts/05_stac_register.py` (`nge:produced_datetime`); checked by `scripts/stac_validate.py` (`tags_disagree`, `check_item`) and `tests/test_cog.py`.
- All 10,100 local items: fly `0.19.0`, fly sha `0eeb977c3893` (12 chars, `aoi_provenance()` in `scripts/aoi.R`), pipeline `e16dd5307f57`.
- COG tags (`FLY_VERSION`, `FLY_SHA`, `PIPELINE_SHA`) carry no prefix, so the rename is item-JSON only; checksums hold.
- 05 does not check `pipeline_sha` against the code (03 does), so 05 can regenerate items from the existing windows.
- processing v1.2.0: item properties must hold at least one `processing:*` field; `processing:software` is a name → version string map; `processing:version` is "the version of the primary processing software or processing chain".
- Sibling decisions: stac_pointcloud_bc#12 (closed) chose `lidarbc:`/`las:`; floodplains#74 proposes `processing:software` for versions and `link:` for shas; crate#23 holds the schemas.

## Plan review and round 1 (2026-10-10)

Saved: `review-plan.md` (written here from the Plan agent's reply), `review-round1.md`.
Folded in: the publish order (`05 --require-all-published` first; 05 merges links,
not bodies), empty-string run constants treated as missing, tests for the core-key
skip and the projection pairing, the validator docstring and `scripts/README.md`,
NEWS's heading (the next sync of any kind, not only a rebuild) and filter wording
(the dotted-path filter on `processing:software` is unproven against pgstac, so NEWS
makes no syntax claim), and `index.html` left as is until publish, since it
describes the live items.

**The #47 body was edited before this branch's copy was saved.** It added: one crate
issue for any custom prefix that remains, and "validate against copies of the
schemas checked into this repo, as stac_pointcloud_bc#2 does". Read on pointcloud's
#2 branch (`scripts/laz_item.py`, `schemas_preload()`), that copies only the
crate schemas (`lidarbc`, `las`), never the standard extensions. This mapping
leaves no crate prefix, so there is nothing to vendor, no crate issue to file, and
no crate deploy to wait on. `airphoto:` is written by this catalogue alone and, under
crate's rule (a schema only when two catalogues write it or something outside NGE
reads it), earns none.

## Local proof (Phase 4, 2026-10-11)

`05_stac_register.py --out <scratch>/stac47 --require-all-published`: 10,100 items,
10,100 published links, 0 not rebuilt, valid. Diff against `data/stac` over all
10,100: no difference beyond the rename, every value equal
(`processing:software.fly == nge:fly_version + "+" + nge:fly_sha`), `stac_extensions`
gains processing only. `check_item()` on every new item: 0 problems, tags against the
real COGs. On every old item it reports 4 undeclared prefixes, 2 tag mismatches and
3 missing keys: the guard refuses the current `data/stac`, as intended. Script:
scratchpad `diff47.py` (not kept). 05 listing `PROCESSING_EXTENSION` is proven by this
run, since 05 runs `check_item()` on every item and the extension pairing is
mutation-tested.

## Errors Encountered

| Error | Resolution |
|-------|------------|
