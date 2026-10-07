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

## Errors Encountered

| Error | Resolution |
|-------|------------|
