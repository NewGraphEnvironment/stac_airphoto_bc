# Review round 1 — branch 47-move-the-nge-item-fields-to-standard-or

## Findings

- **[severity: fragile]** index.html (not in diff) — README.md was re-knit, but `index.html` was not. The README.Rmd `build` chunk renders both, and `index.html` is the Pages site (newgraphenvironment.com/stac_airphoto_bc/). It still names `nge:fly_version` and `nge:produced_datetime` (2 hits), so the site and README.md now describe different field names. Today the site matches the live items. Once the rebuild publishes, it will be wrong unless someone re-renders it. If it was left stale on purpose until the rebuild, the "publish" step should say so, for example in CLAUDE.md's #47 paragraph. Otherwise the drift will go unnoticed. The `[NEWS](NEWS.md)` link will work there once it is rendered: Pages serves `.md` raw (README.md returns 200 text/markdown).

Nothing else found. What was checked:

- `uv run pytest tests/ -q` gives 105 passed.
- Simulation over all 10,100 local items in `data/stac`: none uses a property or asset prefix outside proj/file/nge/airphoto, and every item lists only projection v1.1.0 and file v2.1.0. Then 40 random items were renamed exactly as `build_properties()` + 05 now write them, with PROCESSING_EXTENSION appended. On all 40, `check_item()` (checksum, layout and `tags_disagree` against the real COG tags) returned no problems, and `pystac.Item.validate()` passed against the live processing v1.2.0 schema.
- `processing:datetime` from `datetime.fromtimestamp(..., tz=timezone.utc).isoformat()` ends in `+00:00`, which satisfies the schema's `(\+00:00|Z)$` pattern. `processing:software` values are strings, as `patternProperties` requires.
- The schema's `require_any_field` is satisfied by any one of the three fields.
- `tags_disagree`: when the tags are absent it builds `"None+None"`, which never equals a real value or `None`, so the check fails toward reporting a disagreement, not toward passing. The `PIPELINE_SHA` None==None case is still caught by REQUIRED_BUILD_PROPERTIES.
- Other readers: 03_cog.py (tags still FLY_VERSION/FLY_SHA/PIPELINE_SHA from window columns, unchanged), 02_georef.R, aoi.R, 06_catalogue_*, cog_render-compare.py, cog_rewrite-check.py, stacs.toml and the installed stacs. None reads the renamed item properties. No `nge:` remains in tracked files outside NEWS/CLAUDE/README/tests and index.html.
- Cross-repo citations resolve to on-topic issues: stac_pointcloud_bc#12, stac_floodplains_bc#74, crate#23 (its body lists stac_airphoto_bc#47 among the pending prefixes), stac_airphoto_bc#47.
