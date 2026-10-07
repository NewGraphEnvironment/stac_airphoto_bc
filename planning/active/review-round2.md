# Code-check round 2 — #44 (conda → uv), staged diff + HEAD

## Findings

- **[fragile]** pyproject.toml:11-14 (committed in HEAD b1bafd9, not in the staged diff)
  The comment beside the rasterio pin says a bump "is its own change, checked with
  `cog_render-compare.py --expect-same` before any sync". This branch now documents the
  opposite in three places. CLAUDE.md:83-84, scripts/README.md "Building the Python
  environment" and cog_rewrite-check.py:20-21 all say `--expect-same` compares files
  already written, so it cannot see an environment change. The comment is the doc a
  person reads at the moment they edit the pin. It sends them to the check that passes
  under any environment, and the one that can fail, `cog_rewrite-check.py`, goes unrun.
  That is a guard failing toward pass, through the docs. Repoint the comment at
  `uv run python scripts/cog_rewrite-check.py`.

- **[fragile]** scripts/cog_rewrite-check.py:23-24 (docstring). The claim "All 10,100
  matched under uv.lock's environment on 2026-10-07 (#44), as they had under the conda
  env it replaced" was measured with the round-1 method, which read the tags back off the
  COG (findings.md "Write census", and Phase 2's `20261007T170827Z.csv`). The fixed
  method, `frame_tags()`/`shift_of()` from the window row, has not completed a full run.
  The background run started 17:15:29Z, and `data/logs/rewrite/` still holds only the
  old CSV. My small-sample probes agree with the claim (below), and round 1 had
  300/300 tag dicts equal, so it will probably hold. Still, it is a number this code has
  not yet produced. Before committing, confirm the running census ends
  "10,100 same, 0 not", and cite its CSV. The "as they had under the conda env" half
  compares across the two methods. The new method was never run under conda.
  That is acceptable if worded so, because the pyarrow version is the same in both locks.

- **[fragile, doc accuracy]** scripts/README.md:64, the new tool row. "it skips only 03's
  pipeline-SHA refusal" is not true. The tool also skips the rest of
  `run_constants()` (fly_version/fly_sha agreement), the ledger selection check
  (`selected_ids`), the manifest vouching (`vouched()`) and the orphan-COG refusal.
  Because it iterates COGs, not GeoTIFFs, it also never visits a GeoTIFF that has no
  COG. I checked whether any of these skips can produce a false "same", and none can.
  None of them changes the bytes `write_cog()` produces. A GeoTIFF rebuilt since 03 last
  ran shows as `differs`, the fail direction. An orphan COG or a missing GeoTIFF becomes
  an `error:` row. So the verdict about the environment is sound and only the sentence is
  wrong. It should say the tool skips 03's selection and vouching guards, the SHA refusal
  among them, and checks only existing COGs. Relatedly, both the README row and
  docstring:15-16 name two causes of a `differs`, the environment or windows rebuilt by
  01. There are two more: a GeoTIFF rewritten by 02 since 03 last ran, and a change to
  `03_cog.py` itself. Both fail toward fail.

## The fix itself (round-1 finding): verified

I compared `rewrite()` against 03_cog.py `main()`, lines 298-347:
- Stem: 03 keys `by_stem.get(src.stem)` and the tool keys `dst.stem`. `dst` is
  `STAC/rel` and `src` is `GEOREF/rel`, the same filename, so the stem is the same,
  including dotted stems like `bcc98021_179.tif.thmb`. `FILENAME` is the same stem.
- The rows kept are the same. Both call `load_windows()`, so the `in_window is False`
  drop is shared. `to_pydict()` yields Python `bool`: 18,994/18,994 rows measured. Of
  the 652 stems in two windows, the first row in sorted-parquet order wins, with the
  same agreement guard, in both.
- `meta` goes through unchanged. 03 does nothing to it between `load_windows()` and
  the `shift_of(meta)` / `write_cog(src, dst, frame_tags(meta, src.stem), dx, dy)`
  call, and the tool makes that same call. The temp `dst` matters only through
  `dst.name`, which is the same.
- No frame is skipped silently. All 10,100 COG stems have a window row, and none
  exists only as a roll neighbour. `meta is None`, any guard `SystemExit` and a
  missing GeoTIFF all become `error:` rows and exit 1.
- Probes in scratchpad/r2/, read-only against the repo. 9 frames, 1 of them in two
  windows: all `same`. On `1967/bc5255_203_thumb.tif`, I mutated the window row to
  reproduce a pyarrow type change: `photo_date` date → datetime gave `differs`, and
  `scale` text gave `differs`. So the tool now sees an upstream tag-text change that
  the round-1 version could not. An int → float `rotation` stays `same`, as it does in
  03, because `fmt()` normalises it.

Also checked, no issue: `tests/test_stacs_config.py` passes (10/10) against `.venv`, and
`direct_url.json`'s `commit_id` 7e66b2a matches uv.lock. `uv run --locked` is used at
every call site whose output is published, and `--locked` refuses to re-resolve.
