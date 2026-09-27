# Code-check round 4: staged diff p26 (#23)

Reviewer: subagent, 2026-09-26. Diff: `scratchpad/diff-p26r4.patch`. Scope: round 3's fixes first
(roll-neighbour padding, native-grid DEM, manifest `pipeline_sha` / `source` / `source_md5`,
`footprint_digest` in 03's cross-window check, `aoi_dem_corner()` 10,000), then the remaining
enumeration. Tests were run in the scratch copy `scratchpad/cc-r4/w`, which holds the staged tree plus
`data/` without `raw`, `stac` or `_pre23`. **pytest: 49 passed. `Rscript tests/test_aoi.R`: exit 1,
with one assertion failing** (finding 1).

## Findings

- **[severity: bug]** tests/test_aoi.R:263-264 against scripts/01_fetch.R:199. **Round 3's fix turns
  the R suite red, and it disarms the guard that sits behind the failure.**
  - The test finds the ledger `transmute()` by anchoring on `ledger <- window \|>`.
  - 01_fetch.R now reads `ledger <- window[window$in_window, ] |>`, so the anchor no longer matches.
    `sub()` then returns the whole file, the test reports
    `the transmute block was actually located  FAIL`, and the script exits 1.
  - That also leaves the two assertions after it, "01_fetch.R's transmute() names every declared
    column" and "... declares rejected_reason", checking the whole file rather than the block. The
    test's own comment (lines 255-258) describes exactly this defeat.
  - The prompt's context says the tests pass; on this staged tree they do not. Fix: anchor on the new
    line, for example `.*ledger <- window\\[window\\$in_window, \\] \\|>`.

- **[severity: bug, edge]** scripts/01_fetch.R:118-125. **A window with no roll neighbours crashes 01.**
  - When every window frame's ±1 neighbours are already in the window or missing from the catalogue,
    `nbr` has 0 rows.
  - Then `nbr$in_window <- FALSE` raises `replacement has 1 row, data has 0`. Probed on a 0-row slice
    of `data/neighbours/se_c.parquet` put through `aoi_centroids_as_sf()`: `$<-` on the sf object
    goes to `[[<-.data.frame`. `nbr[, names(window)]` would fail next, with "undefined columns".
  - This is loud rather than silent, and unlikely on today's AOIs (they gain 184-206 neighbours
    each). But nothing rules it out for an AOI whose window holds whole rolls. Fix: `nbr$in_window <-
    rep(FALSE, nrow(nbr))`, and skip the `rbind` when `nrow(nbr) == 0`.

- **[severity: fragile]** scripts/aoi.R:301-326 with scripts/02_georef.R:157,168 and
  scripts/03_cog.py:208-213,249. **`-dirty` names no code state, so round 3's `pipeline_sha` vouching
  cannot tell one uncommitted edit from another.**
  - The suffix is a constant, so every dirty tree at HEAD X is `X-dirty`.
  - The scenario: edit 02's `fly_georef()` call without committing, re-run 01 and 02. 02's `same`
    matches on `pipeline_sha`, so it reuses every GeoTIFF written before the edit. 03's
    `run_constants` equality passes, and the COG is tagged `PIPELINE_SHA=X-dirty`.
  - Round 3's finding 2 was this exact scenario. The fix closes it only for committed code.
  - The cold run that produced the round 3 measurements ran dirty: every window here carries
    `94104f555686-dirty`. So "second 02 pass regenerates 0" was measured under a key that cannot see
    an edit between the two passes.
  - Fix: either suffix a short hash of `git diff HEAD -- scripts data-raw`, computed the same way in
    `aoi.R` and `current_pipeline_sha()`, or have 03 refuse `-dirty` without an explicit flag.

- **[severity: fragile]** scripts/01_fetch.R:87-114. **A neighbour cache is refreshed only when a
  window roll is missing from it, or on `FORCE_REFRESH`.** So there are two ways the neighbour rows and
  the window rows come from different catalogue snapshots.
  - **Deleting the centroid cache to re-query.** That refreshes the window but not `data/neighbours/`.
  - **Two AOIs fetched at different times.** se_a's X+1 comes from se_a's centroid cache, while
    se_b's X+1 comes from se_b's neighbour cache.
  - What goes wrong:
    - Within one AOI it is silent, but harmless: 02 re-reads the same window, so the ledger, 02 and
      the raster agree.
    - Across AOIs, a moved neighbour centroid changes a shared frame's bearing and digest. 03 then
      refuses with "two AOI windows disagree on footprint_digest — re-run 01_fetch.R", and a plain
      re-run does not fix it, because neither cache is refetched without `FORCE_REFRESH = TRUE`.
  - It fails toward refusal. It needs the historical catalogue to change a coordinate, so it is
    low-probability. The message should name `FORCE_REFRESH`, or the neighbour cache should be
    refreshed whenever the centroid cache is (for example, by comparing their mtimes).

- **[severity: fragile]** scripts/aoi.R:603-654. **Nothing checks that a cached DEM is the kind
  round 3 now builds.**
  - `aoi_dem()` reuses any `data/dem/<id>.tif` without checking its CRS or grid.
  - A DEM cached before this change is on the old per-AOI EPSG:3005 grid with 6,000 m. Such a DEM is
    used as is.
  - The only checks that could notice:
    - 03's cross-window digest check, but only for frames that two AOIs share;
    - the `dem_shortfall_m` guard, but only when a selected frame overhangs.
  - neexdzii_kwa shares no frames with the se AOIs, so a stale DEM there would size the whole
    rebuild with nothing reporting it.
  - No instance exists today: the three local DEMs are EPSG:3979 on one 30 m origin (se_a and se_b
    are offset by a whole 69 x 40 cells), and there is no neexdzii_kwa DEM here. Fix: one line in
    `aoi_dem()`, refusing a cached raster whose CRS is not the source's.

## Answers to the round's questions

- **Can padding change selection or reconciliation?**
  - **Selection:** yes, by design and only through bearings. An edge frame now takes its heading from
    its catalogue neighbour, so its rotated ring, and whether it is `no_bearing` or a candidate, can
    move. `cand_ids`, the ledger and `selected` are all restricted to `in_window`.
  - **Reconciliation:** unaffected. The ledger is `window[in_window, ]`, which is exactly the
    centroid cache rows, and the airp_ids are unique because `nbr` excludes window airp_ids.
  - In `fly_footprint()` at e56d2ec, no per-set aggregate other than `fly_bearing()` reaches a frame's
    ring. The roll-height table is a shipped table keyed on `film_roll`, and DEM sampling is per
    frame. So the ±1 neighbours are sufficient, and adjacency needs `|Δframe| == 1`.
  - Measured on these windows:
    - 0 duplicate roll-frame keys in any neighbour or centroid cache;
    - 0 non-numeric frame numbers;
    - every centroid-cache row present, identical, in its neighbour cache;
    - 669 shared se_a/se_b in-window frames, 0 differing in digest, coverage or height.
- **Can a neighbour row leak?** No.
  - The ledger, `sel_ids`, the fetch, 02's `fr` and the report are all built from in-window rows.
  - 03's `load_windows` and 05's `load_build_meta` skip `in_window is False`. pyarrow returns a
    Python bool, so `is False` is correct.
  - `selected_ids` reads the ledgers only.
  - 02 hands neighbours to fly only as `ph`, which is intended.
- **Does rbind coerce types?** Not on this data. Column classes are identical between the centroid
  and neighbour caches for all three AOIs, and the post-`rbind` classes equal the window's. Two
  theoretical cases remain:
  - An incompatible batch type (character vs double) makes `map_dfr` abort, which is loud.
  - A column that is all-`NA` (logical) in the window with Date in `nbr` would lose its Date class.
    It would touch only NA window cells and unpublished neighbour rows.
- **Does the native-CRS DEM change what fly reports?** No change in meaning.
  - `fly_dem_sample()` transforms the rectangles to the DEM's CRS and aligns to its grid.
  - `dem_coverage` is a cell-count ratio.
  - `dem_shortfall_m` is in EPSG:3979 metres. Its only consumer is the `> 0` guard.
  - `aoi_terrain_lines` reads only the ledger (in-window rows).
  - `fl_dem_aoi` skips `project()` when `target_crs` equals the source CRS, which it does here.
- **Other per-AOI or unrecorded inputs.**
  - Between a vouched GeoTIFF and its label, none found beyond the dirty-sha and cached-DEM gaps
    above.
  - The DEM crop extent is per AOI, but every in-window frame has `dem_shortfall_m == 0` in all three
    windows. Shared ground therefore reads identical source cells.
  - Out-of-window neighbours do overhang (7 / 7 / 11), but their rings reach no raster or label.
  - `aoi_rotation_for()`'s clash and unknown-terrain stops now also evaluate neighbour rows. An
    unselectable out-of-window frame could therefore abort an AOI. That is loud and consistent with
    the stops' intent, and did not fire on the cold run.
