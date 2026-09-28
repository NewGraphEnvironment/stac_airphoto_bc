# Task: Register with catalogue_register.sh --drift once stac_dem_bc#42 merges (#33)

## Problem

`CLAUDE.md`'s registration block hand-assembles `collection_register.sh` + `item_register.sh` + `--verify` from stac_dem_bc, because `catalogue_register.sh --all/--drift` refused every airphoto item for lacking a `dem` asset (NewGraphEnvironment/stac_dem_bc#42). Hand assembly gets none of the fetch-by-published-href, drift, count and homogeneity logic.

**Correction at the plan gate (2026-09-27):** `--drift` diffs id sets only, so it never
re-upserts an existing id whose content changed — and every rebuild here changes existing
ids. The routine is `--all` (user's choice); `--drift` is a gap-filler.

## Phase 1: One registration command everywhere
- [x] `CLAUDE.md` Pipeline section: replace the three-script block with one `catalogue_register.sh` call (`STAC_COLLECTION`, `STAC_BUCKET_URL`, `STAC_REQUIRE_ASSET=thumbnail`), `--all` as the routine and `--verify` after, one line on why `--drift` is not enough here; drop the #42 sentence, keep the pypgstac warning
- [x] `CLAUDE.md` Known issues: point the pypgstac bullet at the one command
- [x] `scripts/README.md`: rewrite "After the Pipeline" around the same command, drop the delete-and-reload framing (the merged collection stays load-bearing — as the set `--verify` compares against; a dropped link surfaces as an orphan, not a deletion); Prerequisites row: tailnet SSH to `root@geopro` + a `stac_dem_bc` checkout instead of `GEOPRO_IP`
- [x] `scripts/run_pipeline.sh`: closing echo prints the same command
- [x] `scripts/06_catalogue_promote.sh`: closing heredoc prints the same command (keep the `curl /search` confirmation)
- [x] Grep `pypgstac|GEOPRO_IP|item_register|collection_register|stac_dem_bc#42` — only the CLAUDE.md warning and `planning/archive/` remain

## Phase 2: Verify
- [x] `bash -n` on both edited shell scripts
- [x] From `stac_dem_bc`: `register_manifest.py audit-items` over the 10,100 local items with `--require-asset thumbnail --expect 10100` passes
- [x] From `stac_dem_bc`: live `catalogue_register.sh --verify` with the documented env (read-only); record output in `findings.md`
- [x] Edit the #33 issue body to prescribe `--all`, with the reason

## Validation

- [x] Tests pass (Python 49/49; no R touched, `tests/test_aoi.R` not run)
- [x] `/code-check` clean on each commit
- [x] PWF checkboxes match landed work
- [ ] `/planning-archive` on completion
