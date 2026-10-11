## Outcome

Moved the four `nge:` run fields on every item to the STAC processing extension
v1.2.0, as stac_pointcloud_bc#12 decided for the catalogue family:
`nge:produced_datetime` → `processing:datetime`, `nge:fly_version` + `nge:fly_sha` →
`processing:software` `{"fly": "<version>+<sha>"}` (semver build metadata, so no
custom prefix and nothing for crate#23), `nge:pipeline_sha` → `processing:version`.
`stac_validate.py` now refuses any property or asset field whose prefix is not in
`airphoto_props.FIELD_PREFIXES` or whose schema the item does not list. The COG tags
keep their names, so no checksum moves. Nothing was published: CLAUDE.md
(Build properties) carries the publish order, which starts with
`05 --require-all-published` because 05 merges links, not bodies. A late edit to the
issue asked for checked-in schema copies "as stac_pointcloud_bc#2 does"; that branch
copies only crate schemas, and this mapping uses none.

## Measurement

05 run into scratch with this code, over all 10,100 items (2026-10-11): 0 not rebuilt;
diff against `data/stac` shows the rename and nothing else, every value equal;
`check_item()` 0 problems on the new items and 9 per old item (4 undeclared prefixes,
2 tag mismatches, 3 missing keys), which is the guard refusing the current tree.
Mutation table: each of 8 guard removals turned 1 to 5 tests red (progress.md).
Code-check: plan review + 3 rounds; round 1 one accepted finding, rounds 2 and 3 Clean.

Closed by: PR (see branch 47-move-the-nge-item-fields-to-standard-or)
