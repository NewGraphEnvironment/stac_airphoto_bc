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

## Verification (2026-09-28 UTC)

- `audit-items --collection-id stac-airphoto-bc --require-asset thumbnail --expect 10100`
  over the 10,100 local items (stdin, `collection.json` excluded): `OK: every item agrees
  with its collection (require=thumbnail forbid=-)`. Negative control
  `--require-asset dem`: `FAIL: 10100 item(s) lack asset 'dem'` — the check fires.
- Live `catalogue_register.sh --verify` with the documented env, 06:12:04–06:12:18Z (14 s):
  `asset audit: require=thumbnail forbid=-`, published 10100, registered 10100, missing 0,
  orphaned 0, `IN SYNC`. `STAC_REQUIRE_ASSET` is honoured for a foreign collection.
- The API returns `numberMatched: null` (probed with `/search`, `limit: 1`), so
  `06_catalogue_promote.sh`'s old confirmation `jq '.numberMatched'` printed `null`
  against its "Expect 1775". A replacement (`.features | length`) could not fail either
  (1,810 items already carry the property), and a one-item API-vs-S3 property check
  that followed was removed in code-check round 3: fixed sample unrelated to the run,
  and `null == null` passes when nothing can be fetched. No content check remains;
  the gap is upstream as stac_dem_bc#45.
- `stac_dem_bc/scripts/item_register.sh:19`: "There is deliberately no delete path" —
  the basis for "nothing is deleted" in the docs.

## Errors Encountered

| Error | Resolution |
|-------|------------|
| `diff` in this shell is a `git diff --no-index` wrapper; `diff -q` → `unknown switch 'q'` | Compared with `jq -n --slurpfile … '=='` instead (code-check-shell "verification command can be shadowed") |
| Unquoted heredoc building the issue body ran `` `--all` `` as a command; sentence lost a word | Patched the file and re-edited the issue; quote heredocs that carry markdown |
