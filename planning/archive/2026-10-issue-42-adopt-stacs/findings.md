# Findings — Adopt stacs for registration and verification (#42)

## Issue context

## Problem

`scripts/run_pipeline.sh` tells the operator to register by `cd ~/Projects/repo/stac_dem_bc`
and running that repo's `catalogue_register.sh`. This repo's registration therefore depends
on another repo's working tree being on `main` with a working `.venv`. That layer is now the
`stacs` package (NewGraphEnvironment/stacs#1).

Parity for this collection was measured 2026-10-06: `stacs verify` reports the same sets as
the shell (10,100 items, in sync).

## Work

- [ ] Pin `stacs` at `v0.1.0` once that tag exists
- [ ] Commit a `stacs.toml`: `collection_id = "stac-airphoto-bc"`, the bucket URL, the API,
      `[assets] require = "thumbnail"` (what the pipeline passes as `STAC_REQUIRE_ASSET`
      today), and the `[transport]` the STAC host needs
- [ ] `run_pipeline.sh`: replace the `cd` block with
      `stacs register --config stacs.toml --mode all` then `stacs verify --config stacs.toml`
- [ ] Correct the note beside it: "`--drift` registers only ids the API lacks and never
      refreshes an item this run rebuilt" has been false since
      NewGraphEnvironment/stac_dem_bc#45 -- drift compares bodies, so `--mode drift` does
      register rebuilt items
- [ ] Keep build-side: `05_stac_register.py` (item creation and the collection merge),
      `stac_validate.py` and `06_catalogue_validate.py` (COG checks)

## Plan-mode exploration (2026-10-07)

- stac_dem_bc `origin/main` (354bfa2) no longer has `scripts/catalogue_register.sh`; stac_dem_bc#49
  deleted it with `item_register.sh` and `collection_register.sh` when it adopted stacs v0.1.0.
  The registration this repo documents is therefore already broken against a current checkout.
- stacs tags: `v0.1.0`, `v0.1.1`. `git diff v0.1.0 v0.1.1 -- src/` is docstring examples only
  (doctests), plus pyproject metadata; no behaviour change. Pin v0.1.1.
- stacs `requires-python = ">=3.11"`; the local `stac-airphoto-bc` env is Python 3.12.14;
  `environment.yml` says `python>=3.9`.
- Values the toml restates: `05_stac_register.py` `COLLECTION_ID = "stac-airphoto-bc"`,
  `S3_BASE = "https://stac-airphoto-bc.s3.us-west-2.amazonaws.com"`; the asset key `thumbnail`
  is a literal at the asset build (also literal in `stac_validate.py`, `cog_render-compare.py`).
- Reference adoption: stac_dem_bc `stacs.toml` + `tests/test_stacs_config.py`,
  `planning/archive/2026-10-issue-49-adopt-stacs/`.
- `data/stac/` holds 10,101 JSONs locally (10,100 items + `collection.json`).

## Plan review (2026-10-07)

Plan agent, findings in `review-plan.md`. Folded in: G1 (`06_catalogue_promote.sh` carries a
second copy of the broken heredoc), G2 (widened grep; the source writes `` `stac_dem_bc`'s ``
with backticks, so the planned alternative never matched), G3 (README recipe pin), G4
("registration" naming two steps), S1, V1 (the `--mode all --dryrun` returns before any
probe, so it proves less than `verify`). G5 and S2 declined with reasons in `task_plan.md`.

## Live check (2026-10-07, stacs 0.1.1, committed `stacs.toml`)

- `stacs audit --config stacs.toml --dir data/stac --expect 10100`: OK, `require=thumbnail`,
  2.5 s. **This proves this machine's tree only** (A2): `data/` is gitignored and no machine
  is guaranteed to hold it all. The audit that protects pgstac is the one `register` runs on
  the published bodies it fetches.
- `stacs verify --config stacs.toml --out-dir <scratch>` (15:50:28Z): IN SYNC, 10,100
  published / 10,100 registered, 0 missing, 0 orphaned, 0 changed, collection `same`,
  exit 0, 1m11s.
- `stacs register --mode all --dryrun` (15:51:50Z): fetched collection.json, 10,100 to
  register, returned before the API and ssh probes (`register.py:461-467`).
- `stacs register --mode drift`, no dryrun (15:51:53Z): API probe and ssh probe to
  `root@geopro` passed, every body fetched and compared, "nothing to register -- already in
  sync", exit 0, 1m07s. No write.
- **Not exercised** (A3): the remote load path (`env_file`, `workdir`, `path_prepend`, the PG
  exports, `uv run pypgstac`, `STACS_LOADED`). stac_dem_bc#49 did not exercise it either
  (its archived findings, "Live check"). The first real `--mode all` here, or anywhere, is
  its first live test. `stacs load collection --config stacs.toml data/stac/collection.json`
  would test it on demand by upserting the byte-identical published body; that is a write
  and the user's call.

## Errors Encountered

| Error | Resolution |
|-------|------------|
