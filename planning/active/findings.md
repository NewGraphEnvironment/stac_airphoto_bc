# Findings — Register with catalogue_register.sh --drift once stac_dem_bc#42 merges (#33)

## Issue context

## Problem

`CLAUDE.md`'s registration block hand-assembles `collection_register.sh` + `item_register.sh` + `--verify` from stac_dem_bc, because `catalogue_register.sh --all/--drift` refused every airphoto item for lacking a `dem` asset (NewGraphEnvironment/stac_dem_bc#42). Hand assembly gets none of the fetch-by-published-href, drift, count and homogeneity logic.

## Fix

Once stac_dem_bc#42 merges, the orchestrator registers any collection. Replace the block with:

```bash
cd ~/Projects/repo/stac_dem_bc
STAC_COLLECTION=stac-airphoto-bc \
STAC_BUCKET_URL=https://stac-airphoto-bc.s3.us-west-2.amazonaws.com \
  bash scripts/catalogue_register.sh --drift     # --verify to check only
```

and drop the sentence citing #42 as the reason it cannot. Optional: `STAC_REQUIRE_ASSET=thumbnail` gives the audit an asset check. Without it the run prints `asset audit: none`, and the collection-id and count checks still run.

Measured before the merge (read-only, `audit-items` over `data/stac/`): 10,100 items pass under the new rules and all 10,100 fail under the old ones.

## Plan-mode exploration (2026-09-27)

- stac_dem_bc#42 closed by stac_dem_bc PR #43, merged 2026-09-28T00:48Z. Local
  `stac_dem_bc` checkout level with origin/main (`0e7934a`).
- `catalogue_register.sh` modes: `--drift`/`--verify` run `register_manifest.py diff`,
  a set difference of published vs registered **ids**. Content of an already-registered
  id is never compared, so `--drift` cannot refresh a rebuilt item and `--verify` cannot
  see one stale. `--all` = `sort -u published.txt`, every published item upserted.
- Order in the script: fetch every body → audit (`audit-items`, collection id + count +
  optional asset rules) → collection upsert → item upsert. Nothing reaches pgstac if the
  audit refuses.
- `--dryrun` exits before the fetch, so it does not exercise the audit.
- Local `data/stac/`: 10,100 items; asset keys `thumbnail` 10,100, `flight_log` 8,224,
  `patb_georef` 1,810, `camera_calibration` 1,337. `STAC_REQUIRE_ASSET=thumbnail` is a
  real check.
- The delete-and-reload `stac_register-pypgstac.sh` was still prescribed by
  `scripts/README.md` ("After the Pipeline"), `scripts/run_pipeline.sh`'s closing echo
  and `scripts/06_catalogue_promote.sh`'s closing heredoc — only CLAUDE.md had moved off it.

## Errors Encountered

| Error | Resolution |
|-------|------------|
