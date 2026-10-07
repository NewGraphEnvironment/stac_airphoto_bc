# Task: Move the Python environment from conda to uv (#44)

**If done:** this repo's Python environment matches `stacs` and `stac_floodplains_bc` (uv, `pyproject.toml` + `uv.lock`), with a lock file instead of an unpinned `environment.yml`. **If never:** it stays on conda, which works but is inconsistent across the stac_* repos and is unlocked.

## Context

The pipeline's Python runs in conda env `stac-airphoto-bc` from an unpinned `environment.yml`.
`stacs` and `stac_floodplains_bc` are on uv (`pyproject.toml` + `uv.lock`). The goal is a
locked env that matches the siblings, with no change to any COG byte or item body.

### What exploration changed

- **The issue's main risk doesn't apply here.** It says "rasterio/GDAL come from conda-forge
  today". They don't. `environment.yml` gets only `python` and `pip` from conda-forge, and
  everything else comes from pip. The installed rasterio is the PyPI wheel (1.5.1, with
  GDAL 3.12.4 bundled), the same kind of wheel uv installs. `stac_dem_bc#16` measured this
  for both repos on 2026-09-04, and floodplains already runs rasterio under uv with no system GDAL.
- **The real risk is version drift.** A fresh `uv lock` would pick up rasterio **1.5.2**
  (current on PyPI) and a newer pystac. A different bundled GDAL could change COG bytes, and
  then every `file:checksum` changes and the next sync re-uploads 33 GiB with no change to the
  content. So the lock must reproduce the conda env's versions exactly (`pip list` captured:
  rasterio 1.5.1, pystac 1.15.2, shapely 2.1.2, pyarrow 25.0.1, numpy 2.5.2, rio-stac 0.12.0,
  stacs 0.1.1). Upgrading is a separate, deliberate step, checked with `--expect-same`.
- **03_cog.py can't serve as the writer check on this tree.** The windows are stamped with
  `pipeline_sha` `e16dd5307f57`, but the code is now at `35dcf87e4def` (#42 touched
  `scripts/`), so 03 refuses them. Even without that, a re-run tags a new `PIPELINE_SHA`. So the
  A/B check calls `write_cog()` directly. For each frame it takes the tags and shift from the
  existing local COG, rewrites from that frame's GeoTIFF, and compares the bytes to the local
  COG. All 10,100 GeoTIFFs and COGs are on disk, so this can cover every frame.
- **Editing usage lines in `scripts/` moves `pipeline_sha`.** It excludes only markdown. This
  is expected and does nothing to published data until the next run. I'll record it so nobody
  later reads it as a code change.

## Phase 1: Measure — the conda baseline, then the uv env, before switching anything
- [ ] Record the conda env's `pip freeze` and `rasterio.__gdal_version__` in `findings.md`
- [ ] `conda run -n stac-airphoto-bc pytest tests/ -q`: baseline pass count
- [ ] Write `pyproject.toml`: `[tool.uv] package = false`, `requires-python = ">=3.11"`, the
      same dependency floors as `environment.yml`, `pytest` in a `dev` dependency group, and
      stacs via `[tool.uv.sources] stacs = { git = …, tag = "v0.1.1" }` (stacs README, "Install")
- [ ] `uv lock`, then hold each drifted package to the conda version with
      `uv lock --upgrade-package <pkg>==<ver>` until `uv export` matches the freeze (diff
      recorded). Python 3.12, matching the conda env (`.python-version`)
- [ ] `uv run pytest tests/ -q`: same pass count as under conda. If the stacs pin test
      fails on `direct_url.json` under uv, that's expected and Phase 2 handles it
- [ ] A/B writer census (scratch script, results in `findings.md`). Under both envs, for every
      frame: `write_cog(georef_tif, tags read off the local COG, shift from its tags)` → sha256,
      compared with the local COG's sha256. Pass means 10,100 / 10,100 identical under uv
- [ ] Reader side: `uv run python scripts/cog_render-compare.py --expect-same` on the default
      spot-check sample plus a few named ids, gray and RGB (exit 0)
- [ ] Commit the env files and findings (`pyproject.toml`, `uv.lock`, `.python-version`,
      `.gitignore` gets `.venv/`)

## Phase 2: Switch — every call site, the pin test, delete `environment.yml`
- [ ] `tests/test_stacs_config.py`: `test_every_install_path_pins_the_same_tag` reads the stacs
      tag from `pyproject.toml` `[tool.uv.sources]` (via `tomllib`) and from `uv.lock`'s source
      URL. Each must be whole: `v0.1.10` must not pass for `v0.1.1`.
      `test_the_pinned_stacs_is_the_one_installed`: keep its `requested_revision` check if uv
      records it, otherwise check `commit_id` against the commit `uv.lock` resolved. Restore the
      bug (bump one pin only) and watch the test go red
- [ ] `conda run [--no-capture-output] -n stac-airphoto-bc` → `uv run` in `scripts/run_pipeline.sh`,
      `scripts/06_catalogue_promote.sh` (`CONDA_RUN`→`UV_RUN`), `scripts/04_s3_upload.R`,
      `scripts/test_pipeline.R`, and the usage docstrings of every `scripts/*.py` and `tests/*.py`.
      Fix `run_pipeline.sh`'s pipefail comment, which names conda run
- [ ] Delete `environment.yml`. `scripts/README.md`: Prerequisites row → uv. Replace "Building
      the conda environment" (the ToS recipe) with `uv sync`. Update the stacs command blocks
- [ ] `CLAUDE.md`: Primary Language line, render-check and stacs command blocks, the pin note
      ("pinned to a tag in `environment.yml`" → `pyproject.toml`)
- [ ] `grep -rn conda` over the repo shows only the soul-generated code-check index lines and
      `planning/archive/`
- [ ] Re-run `uv run pytest tests/ -q` and `Rscript tests/test_aoi.R`. Smoke test: run
      `uv run stacs verify --config stacs.toml` live, read-only. It fails on orphans, so it
      shows registration still works from the uv env

## Phase 3: Close out
- [ ] Edit #44's body: correct the GDAL premise and link the census. Update the
      `stac_airphoto_bc` row in `stac_dem_bc#16`'s rollout table to "migrated"
- [ ] `/code-check` on each commit, `/planning-archive` (README with the Measurement and
      Evidence sections), `/gh-pr-push`

## Not in scope
- Upgrading rasterio/pystac (a separate issue: bump the lock, then render-check before syncing)
- Removing the conda env from this machine (`conda env remove -n stac-airphoto-bc` stays
  the user's call, after merge)


## Validation

- [ ] Tests pass
- [ ] `/code-check` clean on each commit
- [ ] PWF checkboxes match landed work
- [ ] `/planning-archive` on completion
