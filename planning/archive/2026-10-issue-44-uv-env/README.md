# #44 — Move the Python environment from conda to uv

## Outcome

The pipeline's Python moved from an unpinned conda `environment.yml` to `pyproject.toml` +
`uv.lock`, matching `stacs` and `stac_floodplains_bc`. Every call site is now `uv run`,
with `--locked` where the pipeline writes published bytes. The issue's stated risk,
that rasterio/GDAL came from conda-forge, was false: rasterio was already the PyPI wheel
with its own GDAL, the same artefact uv installs. The real risk was the lock drifting. A
fresh lock picked rasterio 1.5.2, and under a 3.11 floor it forked to 1.4.4. Either could
change the bundled GDAL and so every COG's `file:checksum`. The lock therefore holds the
conda env's exact versions, and `requires-python` is `>=3.12`. The census became
`scripts/cog_rewrite-check.py`, the writer check a future lock bump needs. Three
code-check rounds shaped it: tags must come from the window row, not off the COG, and
the check must run before any stage runs under the new lock, because its reference is
the local COGs. Follow-up: #45 (`pipeline_sha` does not cover the lock).

## Measurement

- rasterio 1.5.1 / GDAL 3.12.4 / PROJ 9.8.1 in both envs, with a byte-identical bundled
  `libgdal` (plan review). Python 3.12.14 (conda) vs 3.12.13 (uv).
- Write census, tags read back off each COG: **10,100 / 10,100** byte-identical under
  conda (9 min 18 s) and under uv (11 min 15 s), 8 workers. The per-frame CSVs are
  identical. Positive controls (an edited tag, a 0.5 m shift) → differs.
- `cog_rewrite-check.py`, tags from the window row as 03 makes them: **10,100 same** under
  uv (11 min 21 s). Controls: scale text changed → differs; no window row → error.
- `05_stac_register.py --out`: conda and uv trees identical, and all 10,101 files equal
  to `data/stac`.
- `stacs verify`: IN SYNC, 10,100, under both; identical id lists.
- `pytest tests/`: 87 passed under both. The pin-test mutations (pyproject tag, lock
  tag, lock commit) each turn one test red.
- `stac_validate.py` through `Rscript` → `uv run --locked`: 10,100 pass; exit codes
  propagate (control 3 → 3).
- Wrong turn: the plan offered `cog_render-compare.py --expect-same` as the env check.
  It compares bytes already written, so its verdict is the same under any env (plan
  review). Two later doc claims also had to be retracted (rounds 2-3), and a `git grep -E '\bconda'`
  acceptance check matched nothing and so could not fail.

## Evidence

`data/logs/rewrite/20261007T1*` and `data/logs/render/20261007T163419Z` (gitignored, on
the machine that ran them); the code-check rounds are `review-round*.md` here.

Closed by: PR for branch `44-move-the-python-environment-from-conda-to`
