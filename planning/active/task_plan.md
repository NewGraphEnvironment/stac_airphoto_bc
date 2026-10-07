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
- [x] Record the conda env's `pip freeze` and `rasterio.__gdal_version__` in `findings.md`
- [x] `conda run -n stac-airphoto-bc pytest tests/ -q`: baseline pass count (87)
- [x] Write `pyproject.toml`: `[tool.uv] package = false`, `requires-python = ">=3.12"`
      (not 3.11: a 3.11 floor forks rasterio to 1.4.4, see findings), the same dependency
      floors as `environment.yml`, `pytest` in a `dev` group, stacs via
      `[tool.uv.sources] stacs = { git = …, tag = "v0.1.1" }`
- [x] `uv lock`, then hold each drifted package to the conda version with
      `uv lock --upgrade-package <pkg>==<ver>` until `uv export` matches the freeze. Python 3.12
      (`.python-version`)
- [x] `uv run pytest tests/ -q`: 87, same as conda
- [x] A/B writer census: 10,100 / 10,100 identical under both envs, identical CSVs; positive
      control (tag edited, shift +0.5 m) reports "differs"
- [x] Render spot check under uv (`--expect-same`, 5 frames) exits 0. Plan review: this compares
      bytes already written, so it is no env check; `stac_validate.py` replaces it (Phase 2)
- [x] Commit the env files and findings (`pyproject.toml`, `uv.lock`, `.python-version`,
      `.gitignore` gets `.venv/`)

## Phase 2: Switch — every call site, the pin test, delete `environment.yml`
- [x] `tests/test_stacs_config.py`: the pin test reads the tag from `pyproject.toml`
      `[tool.uv.sources]` and `uv.lock` (whole-string), the install test also checks
      `commit_id` against the lock's; each mutation (pyproject tag, lock tag, lock commit) turns
      one test red, in a copy of the tree
- [x] `conda run … -n stac-airphoto-bc` → `uv run` everywhere; `uv run --locked` at the pipeline
      call sites (`run_pipeline.sh`, `04_s3_upload.R`, `test_pipeline.R`, `06_catalogue_promote.sh`
      `UV_RUN`) so a hand edit to `pyproject.toml` cannot re-resolve mid-run. Usage docstrings in
      `scripts/*.py`, `tests/*.py`
- [x] Commit the census as `scripts/cog_rewrite-check.py`: the writer check an upgrade needs,
      which the README's upgrade paragraph points at
- [x] Delete `environment.yml`; `scripts/README.md` Prerequisites + "Building the Python
      environment" (claim scoped to macOS arm64 / cp312); `CLAUDE.md`
- [x] `git grep -nIi conda -- ':!planning'` shows only the allowed hits (`\b` in `git grep -E` matched nothing here, so that form could not fail)
- [x] Item bodies: `05_stac_register.py --out <scratch>` under conda and uv, outputs identical
- [x] Read side: `uv run python scripts/stac_validate.py` passes, once through R
      (`Rscript -e 'q(status = system("uv run --locked python scripts/stac_validate.py"))'`)
      to exercise R → uv; `uv run --offline` works once synced
- [x] `stacs verify --out-dir` under conda and under uv: same exit code, same id lists
- [x] `uv run pytest tests/ -q` and `Rscript tests/test_aoi.R` pass

## Phase 3: Close out
- [ ] Edit #44's body: correct the GDAL premise, record the census
- [x] Follow-up issue #45: `pipeline_sha` does not cover `pyproject.toml`/`uv.lock`, so a lock bump
      that changes COG bytes leaves provenance unchanged
- [ ] `/code-check`, `/planning-archive` (README with Measurement and Evidence), `/gh-pr-push`
- [ ] After merge, not in this PR: set `stac_dem_bc#16`'s `stac_airphoto_bc` row to migrated

## Not in scope
- Upgrading rasterio/pystac (a separate issue: bump the lock, then `cog_rewrite-check.py`)
- Removing the conda env from this machine (`conda env remove -n stac-airphoto-bc` stays
  the user's call, after merge)

## Validation

- [ ] Tests pass
- [ ] `/code-check` clean on each commit
- [ ] PWF checkboxes match landed work
- [ ] `/planning-archive` on completion
