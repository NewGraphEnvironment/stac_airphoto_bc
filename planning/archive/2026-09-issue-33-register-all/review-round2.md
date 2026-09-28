# Review round 2 — #33 staged diff

Reviewed: `git diff --cached` (CLAUDE.md above the soul marker, scripts/README.md,
scripts/run_pipeline.sh, scripts/06_catalogue_promote.sh) against
stac_dem_bc@0e7934a `scripts/catalogue_register.sh`, `collection_register.sh`,
`item_register.sh`, `register_manifest.py`.

Confirmed true (probed, not just read):
- `PYTHON` is honoured by every python call in all three shell scripts
  (catalogue_register.sh:50, collection_register.sh:68, item_register.sh:58);
  register_manifest.py is only ever invoked through `$PY`.
- STAC_REQUIRE_ASSET=thumbnail is honoured, not refused: collection id
  `stac-airphoto-bc` != `stac-elevation-bc`, bucket `stac-airphoto-bc` != `stac-dem-bc`,
  and no item link points into stac-dem-bc (all 10,100 local links are
  `https://stac-airphoto-bc.s3.us-west-2.amazonaws.com/<id>.json`).
- `_href_to_id` (basename minus `.json`) equals each item's `id` for all 10,100 local
  items; all carry `thumbnail` and `collection: stac-airphoto-bc`, so the audit passes.
- "fetch, audit everything, then upsert collection, then items, nothing deleted" matches
  catalogue_register.sh:475-489 and both `--method upsert` loads.
- `--verify`'s "orphaned" claim for a truncated collection.json matches `ids_diff`.
- Round-1 fix 1 (README ~97-98) reads correctly. No remaining `GEOPRO_IP` or
  delete-and-reload prescription outside planning/archive and data (grep by meaning:
  geopro, reload, delete, register, searchable, a11s.one).
- Both edited shell scripts pass `bash -n`; heredocs are quoted (`<<'EOF'`).

## Findings

- **[fragile]** scripts/README.md:221 — "`PYTHON=` pointing at its `stac-catalog` conda
  env" is wrong if taken literally, and reproduces exactly the failure the row warns
  about. The scripts test `[ -x "$PY" ]`, and a **directory passes `-x`** (probed), so
  `PYTHON=…/envs/stac-catalog` is accepted, then `"$PY" -c …` fails with "is a
  directory", catalogue_register.sh:66 discards stderr (`2>/dev/null`), and the run exits
  1 with "Run from the repo root". A bare `PYTHON=python` fails `-x` and silently falls
  back to `python3`. The working value is the interpreter's absolute path, e.g.
  `PYTHON=$(conda info --base)/envs/stac-catalog/bin/python` — or simply
  `conda activate stac-catalog`, since the `python3` fallback then resolves to the env.
  (Also: no `stac-catalog` env exists on this machine; the name comes from
  stac_dem_bc's `environment.yml`, so it too must be built first, like `.venv`.)

- **[fragile]** scripts/06_catalogue_promote.sh:118-128 — the post-registration check
  can no longer fail. Measured 2026-09-27 against the live API (read-only POST /search,
  `limit: 5000`, `fields: id`): **1,810** `stac-airphoto-bc` items already serve
  `airphoto:georef_metadata = true`, no `next` link. So `.features | length` with
  `limit: 1` prints 1 whether or not the re-registration ran, and "confirm the point of
  the exercise" confirms nothing. (The old `numberMatched`/1775 check was broken for a
  different reason; replacing it with a presence test traded a null for a constant.) A
  discriminating check needs something the re-registration changes: e.g. fetch one
  promoted item from `/collections/stac-airphoto-bc/items/<id>` and compare a newly
  backfilled property or `file:checksum` to the S3 copy, or count with a large `limit`
  and compare to the count in the promoted tree.

- **[fragile]** CLAUDE.md:77-79, scripts/README.md:229-232, scripts/run_pipeline.sh:68-70,
  scripts/06_catalogue_promote.sh:112-114 — the handed-over block `export`s
  STAC_COLLECTION / STAC_BUCKET_URL / STAC_REQUIRE_ASSET into the operator's shell and
  leaves it `cd`'d in stac_dem_bc. A later `bash scripts/catalogue_register.sh --drift`
  or `--verify` for stac_dem_bc's own collection, in that same shell, silently runs
  against stac-airphoto-bc instead: the id is not the DEM one and the bucket is not the
  DEM bucket, so STAC_REQUIRE_ASSET is honoured rather than refused, and the run
  reports success/IN SYNC for the wrong catalogue while the DEM drift goes unchecked
  (it does print `collection : stac-airphoto-bc`, but nothing fails). The previous
  CLAUDE.md block exported two of these too; the diff copies the pattern into three
  more places and adds a third variable. A subshell `( export …; bash … --all && bash …
  --verify )` or per-command env prefixes would keep it from leaking.

## Notes (not findings)

- Pre-existing, not in this diff: scripts/README.md:268 ("This loads the STAC records
  into a PostgreSQL database…") sits after the "Building the conda environment" code
  block, so "This" now reads as referring to the pip install. It was stranded there
  before #33.
