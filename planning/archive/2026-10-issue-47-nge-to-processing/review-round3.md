# Code-check round 3 (#47)

## Clean
No issues found.

## Mechanism and its reach

The mechanism behind rounds 1-2 and the plan review is **one fact held in two places
that happen to agree**, plus the question of which way each pairing fails when they
part. I listed every pairing the diff creates or touches and checked each against its
source of truth. Every one either derives from a single constant or fails toward
refusal.

| pairing | source of truth | if they part | verdict |
|---|---|---|---|
| `FIELD_PREFIXES` vs 05's `stac_extensions` list | the three constants in `airphoto_props` (05 imports them, it does not restate the URLs) | a prefix added to only one side: `fields_undeclared()` refuses the item | refuses |
| `FIELD_PREFIXES` vs the fields 05 actually writes | 05 `build_items()`: `proj:` x4, `airphoto:*`, `processing:` x3, `file:` x2 on thumbnail; pystac adds no prefixed keys | an unlisted prefix is refused | complete. 10,100-item dry run (`scratchpad/stac47`) shows no other prefix |
| 03 `PROVENANCE_TAGS` (10) vs `tags_disagree()` coverage | 03 | coverage was `BUILD_PROPERTY_FIELDS` (7 airphoto + 3 nge). It is now the same 7 plus the 3 run tags compared by hand. Same 10 | equal |
| tag text vs property value for the run | 03 `fmt()` vs `build_properties()` | `""` run constant: 03 tags `""`, 05 omits (`_blank`). Gives a mismatch plus "missing", so it refuses. NaN/None: both omit, so it refuses as missing | refuses |
| `REQUIRED_BUILD_PROPERTIES` vs the writers | `build_properties()` + 05's `processing:datetime` | pinned by `test_every_required_build_property_is_produced_somewhere` | pinned |
| `processing:software` shape vs the check | `check_item` fly-entry check; `{}`, a non-fly dict and a str are all tested | refuses | pinned |
| `PROJECTION_EXTENSION` vs the live items | the live items list projection v1.1.0 | unchanged URL, now a constant | equal |
| tests' `_props()` vs real items | the dry-run output | the fixture matches the real keys | fine |

### Guards checked for failing toward pass
- `fields_undeclared()`: the only pass paths are a key with no colon (core) and `airphoto:`. A wrong or missing schema URL refuses. A different extension version refuses (exact string).
- `tags_disagree()` run check: a missing tag gives `"None+..."`, which no item can carry. A missing `PIPELINE_SHA` plus a missing `processing:version` compares `None == None`, but the REQUIRED loop then reports "missing processing:version". No pass path.

### Measured
- `uv run pytest tests/ -q`: 108 passed.
- Compared `data/stac` (old, `nge:`) with `scratchpad/stac47` (05 `--out` dry run at d044fa7..4d96c16, 10,100 items) using `scratchpad/r3_cmp.py`. Mapping `nge:` to `processing:` makes every item's properties identical, and so are the assets, geometry, bbox, links and ids. `stac_extensions` gains only processing v1.2.0. 0 items carry `nge:`. The pystac schema validation passed on all of them, so the processing v1.2.0 schema resolves. The dry run predates 0b04670, whose code change (`_blank`) affects only `""` inputs, and there are none in the local windows.
- The cross-repo citations resolve to on-topic issues: stac_floodplains_bc#74 (open, "Move the nge: item fields…") and stac_pointcloud_bc#12 (closed, the rename rule).

### Considered, not reported
- A partial 05 on a machine without every COG would let `stac_validate.py` pass (it checks only local items), so a sync could leave mixed `nge:`/`processing:` items live. This is documented as publish step 1 (`--require-all-published`), from the plan review. It is a process guard, not a code one, and it was already accepted.
- `06_catalogue_backfill.py` / `06_catalogue_validate.py` touch only catalogue properties on live items and never call `check_item`, so the rename does not reach them.
- No tracked script, test or `stacs.toml` reads an `nge:` field. `index.html` was accepted in round 1.
