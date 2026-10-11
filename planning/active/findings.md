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

## Errors Encountered

| Error | Resolution |
|-------|------------|
