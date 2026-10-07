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


## The GDAL premise does not hold here (2026-10-07)

The issue says "rasterio/GDAL come from conda-forge today". They do not: `environment.yml`
takes only `python` and `pip` from conda-forge and installs every package with pip, so
rasterio is the PyPI wheel with its own GDAL — the same artefact uv installs.
`stac_dem_bc#16` measured this for both repos on 2026-09-04.

| env | Python | rasterio | GDAL | PROJ |
|---|---|---|---|---|
| conda `stac-airphoto-bc` | 3.12.14 (conda-forge) | 1.5.1 | 3.12.4 | 9.8.1 |
| uv `.venv` | 3.12.13 (uv-managed) | 1.5.1 | 3.12.4 | 9.8.1 |

## The real risk was the lock drifting

A fresh `uv lock` resolved rasterio **1.5.2**, shapely 2.2.0, numpy 2.5.3 and four minor
bumps. Under `requires-python = ">=3.11"` it also **forked** rasterio to 1.4.4 for 3.11,
because rasterio 1.5 requires 3.12, which would give a 3.11 machine a different bundled
GDAL. Fixes:

- `requires-python = ">=3.12"`, the Python the env actually ran; stacs' floor is 3.11, so
  that pin is still met
- every drifted package was held back with `uv lock --upgrade-package <pkg>==<ver>` until
  `uv export` matched the conda `pip freeze`. Only colorama (`sys_platform == 'win32'`) is
  left in the diff

`direct_url.json` under uv carries `requested_revision: "v0.1.1"` and the same
`commit_id` (`7e66b2a`) as under conda, so the stacs install test keeps its check. It now
also compares `commit_id` against the commit `uv.lock` resolved.

## Tests

- conda: `87 passed`; uv: `87 passed`. The same 40 warnings (Affine `*` deprecation,
  NotGeoreferenced on the render PNG).
- Pin test mutations, each run in a copy of the tree: pyproject tag `v0.1.10`, uv.lock tag
  `v0.1.10`, and uv.lock commit changed each fail exactly one test; the unmutated control
  passes 10/10.

## Render check under uv

`uv run python scripts/cog_render-compare.py --expect-same 695106` → 5 frames (gray+alpha
and RGBA), published vs local: bytes_same, 0 pixels differing at full resolution and
every overview. Exit 0. Log `data/logs/render/20261007T163419Z` (gitignored).

## pipeline_sha moves with this branch

`pipeline_sha.sh` excludes only markdown, so changing the usage lines in `scripts/*.py`
and the `.sh`/`.R` call sites gives the code a new SHA. The windows are already stamped
`e16dd5307f57` while the code was at `35dcf87e4def` (#42), so 03 refuses them either way;
the next real run re-stamps. Nothing published changes until then.

## Write census (2026-10-07)

`scratchpad/cog_census.py` (committed as `scripts/cog_rewrite-check.py` in Phase 2): for every
COG under `data/stac/thumbs`, `write_cog(georef_tif, tags read off the COG, shift from its
tags)` in a temp dir, sha256 against the local COG. 8 workers, 10 cores.

| env | started | done | same | differs | error |
|---|---|---|---|---|---|
| conda | 16:34:10 | 16:43:28 | 10,100 | 0 | 0 |
| uv | 16:43:28 | 16:54:43 | 10,100 | 0 | 0 |

The two per-frame CSVs are byte-identical (`cmp`). Positive control on
`1967/bc5255_203_thumb.tif`: one tag edited → differs; shift +0.5 m → differs. So the
census can fail, and it did not.

`03_cog.py` is unchanged since `e16dd53`, the commit that wrote these COGs, so the conda
pass reproducing them is the expected result, and it is the control for the uv pass.

## Plan review (Plan agent, 2026-10-07)

No blockers. The reviewer independently found that the bundled `libgdal.38.3.12.4.dylib` is
byte-identical (sha256 `6500a5d8…`) in both envs and that neither env sets `GDAL_DATA` or
`PROJ_*`. Adopted:

- `--expect-same` compares bytes already on disk, so its verdict does not depend on the env.
  The read side is now `stac_validate.py`, which recomputes checksum, tags and layout
  for every COG
- item bodies are compared too (`05_stac_register.py --out` under both)
- `uv run --locked` at pipeline call sites: plain `uv run` re-locks after a `pyproject.toml`
  edit and would install a new GDAL between byte-writing steps. A departure from
  floodplains, which uses plain `uv run`
- the R → uv path is exercised through `stac_validate.py`, which uploads nothing
- `stacs verify` is compared under both envs rather than read as pass/fail
- the census is committed as a tool, because the upgrade path otherwise has no writer
  check that keeps its reference: `03_cog.py` overwrites the COGs it would be compared
  against. (Its refusal of these windows is this branch's situation, not a property of
  a lock bump: a lock-only change does not move `pipeline_sha`, #45; code-check round 3.)
- the README's "the lock fixes the bytes" is scoped to macOS arm64 / cp312
- `stac_dem_bc#16` is updated after merge, not before
- follow-up issue: `pipeline_sha` ignores the lock

`06_catalogue_promote.sh` cannot reach its `$UV_RUN` lines today: it exits early because
every item already carries `file:checksum`. The rename is untested and is reported as such.

## Phase 2 checks (2026-10-07)

| check | conda | uv |
|---|---|---|
| `scripts/cog_rewrite-check.py` (committed census) | — | 10,100 same, 0 not (16:56:09 to 17:08:27; `data/logs/rewrite/20261007T170827Z.csv`) |
| `05_stac_register.py --out <scratch>` | exit 0 | exit 0 |
| … the two output trees | identical (`diff -rq`) | |
| … uv's 10,100 items + `collection.json` vs `data/stac` | | 0 differ |
| `stacs verify --out-dir` | exit 0, IN SYNC 10,100 | exit 0, IN SYNC 10,100; id lists identical |
| `stac_validate.py` via `Rscript -e 'q(status = system("uv run --locked …"))'` | | 10,100 of 10,100 pass, R exit 0; control `SystemExit(3)` → R exit 3 |
| `uv run --offline --locked` | | imports rasterio and stacs |
| `pytest tests/` | 87 passed | 87 passed |
| `Rscript tests/test_aoi.R` | | all assertions passed |

`05`'s items carry `nge:pipeline_sha` from the windows (`e16dd5307f57`), not from the
current code, which is why they compare equal to `data/stac` despite this branch moving
the code SHA.

`06_catalogue_promote.sh` still was not run: it exits before any `$UV_RUN` line, because
every item already carries `file:checksum`.

## Code-check rounds 1-2: the rewrite check's tags (2026-10-07)

Round 1 found that `cog_rewrite-check.py` read the tags and shift back off each COG, which
holds the tag text fixed. A pyarrow bump that changed how 03 formats a window value would
therefore pass, a guard failing toward pass. The tool now makes 03's call:
`frame_tags(window_row)` and `shift_of(window_row)`. Controls on one frame: scale text
changed → differs; shift +0.5 m → differs; no window row → error. Full run under uv:
**10,100 same, 0 not**, 17:15:29 to 17:26:50 (`data/logs/rewrite/20261007T172650Z.csv`).
The new method was not run under conda; pyarrow is 25.0.1 in both, and the read-back
census had matched under both.

Round 2 found three documentation defects inside round 1's fix: the `pyproject.toml`
comment still sent a bump to `--expect-same`, the docstring cited a result the new
method had not yet produced, and the README understated what the tool skips.
Enumerated every statement of the tool's coverage or results (pyproject comment,
CLAUDE.md paragraph, README row, README env section, docstring, findings, #44 body) and
made each match the code. Each now also says the tool covers COGs only, and that item
JSON is checked with `05 --out`.

## Code-check round 3: the check's precondition (2026-10-07)

Round 3 named the mechanism behind rounds 1-2: the docs turned this branch's situation
into a rule for every environment change. Two assumptions carried it:
(a) "after an env change, 03 refuses", which is false because a lock-only bump leaves
`pipeline_sha` unmoved (#45); and (b) "the local COGs are the published bytes", which
stops being true once 03 runs under the new lock. Together, "bump, then run 01/02/03
individually (the documented non-publishing route), then the check" reports same, and the
reviewer proved it in a one-frame scratch tree (LZW standing in for a new GDAL). Fixed by
stating the precondition wherever the check is named (run it right after the bump, before
any stage runs under the new lock), and by correcting why 03 is no substitute: it
overwrites the reference. The same precondition applies to the item-JSON `05 --out` advice.

## Errors Encountered

| Error | Resolution |
|-------|------------|
| `diff a b` printed git-diff usage (`unknown switch i`) | `diff` is a shell function wrapping `git diff`; use `/usr/bin/diff` |
| `git grep -nIiE '\bconda'` found nothing, not even CLAUDE.md's soul lines | `\b` is not word-boundary in git grep's ERE here; plain `-i conda`, allowed hits listed |
