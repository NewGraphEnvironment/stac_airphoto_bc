# Findings — Move the Python environment from conda to uv (#44)

## Issue context

**If done:** this repo's Python environment matches `stacs` and `stac_floodplains_bc` (uv, `pyproject.toml` + `uv.lock`), with a lock file instead of an unpinned `environment.yml`. **If never:** it stays on conda, which works but is inconsistent across the stac_* repos and is unlocked.

## Context

Raised 2026-10-07 while adopting stacs (#42). The pipeline's Python runs in the conda env `stac-airphoto-bc` (`environment.yml`, plus the hand recipe in `scripts/README.md` for the conda ToS problem). No `pyproject.toml`, no lock file, nothing in history about uv. `stacs` and `stac_floodplains_bc` are on uv; `stac_dem_bc` is still conda too.

## Work

- `pyproject.toml` + `uv.lock`; stacs from its git tag via `[tool.uv.sources]` (stacs README, "Install")
- Every `conda run -n stac-airphoto-bc …` in `scripts/`, `CLAUDE.md`, `scripts/README.md` → `uv run …`
- `tests/test_stacs_config.py`'s pin test reads the install paths; repoint it at `pyproject.toml`
- **Risk to measure first:** rasterio/GDAL come from conda-forge today; uv's wheels bundle their own GDAL. `03_cog.py` and the COG tests depend on GDAL behaviour (CLAUDE.md "COG bands", alpha overviews measured on 3.12.4). Run `pytest tests/` and `cog_render-compare.py --expect-same` on a few frames under both before switching.


## Errors Encountered

| Error | Resolution |
|-------|------------|
