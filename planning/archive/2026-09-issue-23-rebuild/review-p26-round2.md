# Code-check round 2: staged diff p26 (#23)

Reviewer: subagent, 2026-09-26. Diff: `scratchpad/diff-p26r2.patch`. This round focuses on the round 1 fixes.
Tests at review time: `Rscript tests/test_aoi.R` all pass; `pytest tests/` 49 passed.
Probes ran in a scratch clone (`scratchpad/cc-r2/w`). On the real se_c tree, 03 reports
`0 COGs written, 102 unchanged`, so none of the 102 is falsely refused.

## Findings

- **[severity: bug]** scripts/03_cog.py:220-232 (`vouched`). This is round 1's defect again, one axis over. 03 vouches a GeoTIFF on `airp_id`, `rotation` and `fly_sha` only. It never compares the footprint the raster was warped to against the footprint the window now describes, although the manifest records `footprint_bearing` and `footprint_digest` for exactly that purpose. Two ways to reach it:
  - Re-run 01 without 02. Examples are 01's own remedy for `dem_shortfall_m` ("delete the DEM … before re-running") or a `FORCE_REFRESH` catalogue re-query.
  - Any other path that changes the window's size, position or bearing but not its rotation.

  Either way, the old raster passes 03 and is re-tagged with the new window's `HEIGHT_SOURCE` / `FOOTPRINT_BASIS`. 05 stamps the same values, and `stac_validate.py` passes the result, because tag and property still share one source.

  **Probe:** I edited the scratch window for airp_id 1259564. I moved `footprint_bearing` from 144.9 to 164.9 and set `height_source` to `corrected_unit_slip`. I did not run 02. 03 then printed `1 COGs written, 101 unchanged`, and the COG now carries `HEIGHT_SOURCE=corrected_unit_slip` over a raster warped at bearing 144.9.

  The fix has two parts:
  - The bearing half is one comparison: manifest `footprint_bearing` against window `footprint_bearing`, to 1e-6.
  - The size/position half needs the digest in the window, because 01 writes the window with `st_drop_geometry()`. Have 01 write `footprint_digest` into the window, using the same function 02 uses, and have 03 compare it to the manifest's.

- **[severity: fragile]** scripts/aoi.R:344-352 (`aoi_georef_manifest_read`) with scripts/02_georef.R:152-160. The manifest is read with the positional `col_types = "ccidcc"` and no check on the column names. On a manifest written before `footprint_digest` existed (the round 1 version, 5 columns), readr only warns. `had$footprint_digest` is then `NULL`, so `eq()` returns `logical(0)`, `same` is `logical(0)`, and `stale` is `logical(0)`. As a result nothing is regenerated, even a frame whose rotation changed. `bind_rows(..., ok_rows)` then rewrites the manifest with the **new** rotation for the **old** raster, and 03 vouches for it. The guard fails toward pass, and does so silently.

  **Probe** (R, readr 2.2.0): a 5-column manifest with rotation 0, a want of 90, and `any(stale)` came out `FALSE`.

  This is latent for any machine holding a round-1-era manifest. The local manifest already has 6 columns. The same collapse recurs the next time a manifest column is added. Fix: `stop()` unless `identical(names(m), names(empty))`, or assert `length(same) == length(dest)`.

- **[severity: fragile]** scripts/aoi.R:309-315 (`aoi_provenance`), consumed by 03 `run_constants`. `-dirty` is computed over every tracked file, and the pipeline dirties its own tree: `data/reports/<id>.md` is tracked, and 01 and 02 rewrite it on every run with a `Generated <date>` line. That has two consequences:
  - Every 01 invocation after the first one following a commit stamps `-dirty`, even when no code changed. So the published `nge:pipeline_sha` almost always reads `-dirty`, and the flag cannot tell a code change from a report rewrite.
  - Re-running 01 for a single AOI gives that window `X-dirty` while the others hold `X`. 03's `run_constants` then refuses the mix, which forces a re-fetch of every AOI. This is a false refusal, and 01's DEM-shortfall remedy leads straight to it.

  Separately, the SHA is taken at 01 time and carried through the window. So a COG that 03 writes after 02 or 03 changed names the commit that ran 01, not the code that wrote it. This PR itself changes 03.

  Fix: scope the dirty check to code (`git status --porcelain --untracked-files=no -- scripts data-raw`). Optionally, have 03 refuse when the window's SHA prefix is not the current HEAD.

## Checked and found sound

- **Path identity.** R `file.path("data","raw","georef","thumbs", yr, name)`, with `yr` an integer from `map_dfr` over `as.integer(photo_year)`, and Python `str(Path("data/raw/georef/thumbs").glob(...))` give identical strings from the repo root. All 102 local GeoTIFFs match their manifest rows, and `res$dest` from fly matches `want$dest` (102 rows recorded). The orphan check compares `Path` objects of the same relative form. `.tif.tmp` is not matched by `**/*.tif`.
- **Id types.** `airp_id` is int32 in the window, selected, centroid and published parquets, so `as.character()` never goes scientific. readr 2.2.0 writes integral doubles such as 100000, 700000 and 1260000 in fixed notation, so the ledger ids that `selected_ids()` reads compare as strings cleanly. There are no duplicate thumbnail stems across airp_ids in the se_c window or the 9,976 published rows, so `by_stem` and the manifest's `airp_id` cannot disagree for that reason.
- **Rotation text.** Manifest rotation (`""` for NA) against `fmt(window rotation)` compares equal for film and digital.
- **Frames shared by AOIs.** `selected_ids` is a union, which is right, because any ledger selecting the frame warrants its build. `load_windows` refuses windows that disagree on rotation or placement. Bearing and the footprint digest are not compared across windows. For a selected frame, the adjacent roll neighbours lie well inside both windows' 8 km-plus buffers, so the bearings should agree. I could not measure this: only se_c is local.
- **Crash between unlink and fly_georef.** The manifest is written only at the end of the AOI. After a crash the old rows remain, so 02 regenerates on the next run, and 03 either refuses (old rotation or no row) or reports an orphan COG. Nothing passes silently.
- **05.** 05 refuses non-selected and window-less COGs. Items are written only after `check_item`, and a stale item JSON whose COG was removed fails `stac_validate.py` before 04 syncs.
- **04.** The `-[0-9]+$` composite test is safe: standard base64 has no `-`. The zero-compared case is printed, and realistic runs upload every rebuilt COG with SHA-256.
- **Docs.** The CLAUDE.md / README / scripts/README.md prose added in this diff is true of the code. The only gap: the manifest reuse lines ("rotation, bearing and fly SHA") omit `footprint_digest`. That is incomplete, not false.
