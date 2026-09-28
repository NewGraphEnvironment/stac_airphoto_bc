# Review round 1 — #33 staged diff (registration via catalogue_register.sh)

Reviewed: staged CLAUDE.md (above marker), scripts/README.md, scripts/run_pipeline.sh,
scripts/06_catalogue_promote.sh, against stac_dem_bc main @ 0e7934a
(catalogue_register.sh, collection_register.sh, item_register.sh, register_manifest.py).

## Findings

- **[fragile]** scripts/README.md:97-98 — stale claim the diff missed. The `--limit`
  notes under the backfill section still say "pgstac still holds the old items until
  the collection is re-registered on geopro, and **that script deletes before it
  reloads**." After this diff the documented registration is the upsert orchestrator,
  which deletes nothing, so this sentence now contradicts the "After the Pipeline"
  section 130 lines below it. The grep in task_plan Phase (`pypgstac|GEOPRO_IP|...`)
  cannot catch it because the line names no script. Fix: drop the "deletes before it
  reloads" clause (or say "re-registered with `catalogue_register.sh --all`").

- **[fragile]** scripts/README.md:221 (Prerequisites row) — "a `stac_dem_bc` checkout"
  is not sufficient. `catalogue_register.sh` runs `${PYTHON:-.venv/bin/python}`
  (falling back to `python3`) and its first act is importing `collection_patch` and
  `stac_utils`, which import `pystac`, `rasterio`, `rio_cogeo`, `shapely`, `requests`.
  `.venv/` is gitignored in stac_dem_bc and is only built by its CI workflow
  (`uv venv --python 3.12 .venv` + `uv pip install ...`, `.github/workflows/update.yml:82`),
  so a fresh checkout has none. Probed: with `PYTHON=/usr/bin/python3` (no pystac)
  the script exits 1 with "could not read COLLECTION_ID from scripts/collection_patch.py.
  Run from the repo root." — stderr is swallowed (`2>/dev/null`, line 66), so the
  message points at the wrong cause even when the operator IS in the repo root. Fails
  loud, not toward pass, but the documented prerequisites will not produce a working
  run on a new machine. Fix: name the requirement — stac_dem_bc's `.venv` (or
  `PYTHON=` a python with its `environment.yml` deps). The misleading error itself is
  stac_dem_bc's to fix, if at all.

## Claims verified TRUE (no action)

- Fetches the published `collection.json` (`curl $STAC_BUCKET_URL/collection.json`) and
  every linked item by its published href; all 10,100 local item links are absolute
  `https://stac-airphoto-bc.s3.us-west-2.amazonaws.com/<id>.json`.
- Audits before any write: `audit-items` (collection id, `--expect` count,
  `--require-asset thumbnail`) runs before `collection_register.sh`, then items.
  `STAC_REQUIRE_ASSET` is honoured because the collection id and bucket are not
  stac_dem_bc's and no item link points into `stac-dem-bc` (dryrun prints
  `asset audit: require=thumbnail forbid=-`). All 10,100 local items carry `thumbnail`
  and `collection: stac-airphoto-bc`.
- Upsert only: `pypgstac load ... --method upsert` in both register scripts; no delete
  path. (pgstac's item upsert is delete+insert of changed rows inside one load
  transaction — "nothing is deleted" is accurate at the level a reader means.)
- `--drift` = `register_manifest.py diff` over id sets -> missing ids only; cannot
  refresh an existing id. `--verify` compares id sets both directions and exits 1 on
  either. `--all`'s trailing `verify-serving` is ids-only too. All as documented.
- Must run after the sync: it reads S3, not `data/stac`. A one-AOI collection.json would
  give `--all` only that AOI and `--verify` would report the rest as orphaned (exit 1).
- Live probes (read-only), from stac_dem_bc with the documented env:
  `--all --dryrun` -> published 10100, would fetch 10100, rc 0;
  `--verify` -> `IN SYNC: 10100 published, all registered, no orphans`, rc 0.
- Printed commands: all heredocs are `<<'EOF'` (quoted), so `\` continuations and URLs
  print literally; the `export A=.. \ B=.. \ C=..` continuation is valid when pasted;
  terminators at column 0; run_pipeline.sh ends with a newline after `EOF`.
- 06_catalogue_promote.sh check: the API honours the `query` extension (conformance
  lists item-search#query). Probed: `georef_metadata eq true` -> 1 feature (value true);
  a nonexistent property -> 0; `eq "bogus"` -> 0; unknown collection -> 0;
  `numberMatched` is null. So `.features | length` with `limit:1` does discriminate
  presence of the property and cannot pass vacuously on an ignored filter.
