# Task: Point the pipeline at a second area: lift the hardcoded AOI, then run three small AOIs end to end (#16)

## Problem

The collection serves 9,741 photos spanning 1963–2019 over a single watershed,
extent `-126.96, 53.98, -125.74, 54.74`. Queried anywhere else it returns zero,
which reads as a broken query rather than an extent limit.

The archive is not regional. The pipeline is built on
[`fly`](https://github.com/NewGraphEnvironment/fly), whose exported surface is
area-agnostic. The limit is that it has only ever been pointed at one area —
**and the AOI is hardcoded, in three places** (exploration found a fourth).
Everything downstream of the AOI is already area-agnostic. **The deliverable is
lifting that constant into a parameter and proving the run on a second area.**

### Scope: three small AOIs in southeast BC

| AOI | bbox | area |
|---|---|---|
| A | `-116.0758, 49.0953, -116.0635, 49.1060` | 1.03 km² |
| B | `-116.0549, 49.1127, -116.0427, 49.1221` | 0.91 km² |
| C | `-117.9819, 49.2420, -117.9729, 49.2502` | 0.58 km² |

Small deliberately. Film footprints are kilometres wide, so `01_fetch.R` buffers
the AOI by 8 km before querying — ~3,050 centroids in the fetch window.

### Acceptance (from the issue)

- The AOI is a **parameter**, not three edited constants
- `/search` returns items over the new AOIs
- Collection extent covers both regions; existing items intact — this extends
  coverage, it does not replace
- Report per AOI: frames selected, year range obtained, and what selection
  rejected and why

## What exploration changed about the plan

Four things the issue body does not cover, each found by reading rather than
assuming:

1. **Local `data/` does not exist.** No parquet cache, no COGs, no item JSONs.
   The existing 9,741 items live only on S3.
2. **`05_stac_register.py` would replace, not extend, the collection.** It reads
   every item's metadata from the single file `data/centroids_raw.parquet`,
   globs local COGs, and computes `collection.json`'s item links and extent
   **only from the items it just built**. Run as-is after a new-AOI run it emits
   a collection describing the three small AOIs and nothing else — directly
   violating the issue's "existing items intact" acceptance criterion. This is
   the load-bearing risk in the issue and Phase 4 exists for it.
3. **The centroid cache has no AOI in its key.** `data/centroids_raw.parquet`
   is guarded by `if (force_refresh || !file.exists(cache_path))`, so a second
   AOI silently reuses the first AOI's centroids, and `force_refresh = TRUE`
   overwrites the only copy of the existing collection's metadata.
4. **`test_pipeline.R:68` calls `fly::fly_thumb_georef()`**, removed in fly
   0.3.0. The test harness is already broken and cannot validate this work.

Also single-pathed and would clobber across AOIs: `data/aoi.gpkg` (written with
`delete_dsn = TRUE`), `data/fetch_log.csv`, `data/georef_log.csv`,
`data/cog_log.csv`.

`03_cog.R`, `04_s3_upload.R` and the COG-scanning half of `05_stac_register.py`
are already AOI-agnostic — they walk directories. They need per-AOI log paths
and nothing else.

## Decisions locked with the user

| Decision | Choice |
|---|---|
| Digital frames (~20%, `unknown_format` under fly ≥ 0.4.0) | **Exclude, report the count per AOI.** fly#32 is the follow-up. |
| DEM-corrected footprints (fly 0.5.0 `dem` arg) | **Not this run.** Keeps new AOIs derived like the published 9,741; follow-up rebuilds both regions together. |
| Selection | **`fly_select(mode = "minimal", target_coverage = 0.95)` within three eras** — pre-1980, 1980–1999, 2000+, the breaks the issue itself measured. |

## Phase 1: Prerequisites and the AOI registry

- [ ] Upgrade installed `fly` 0.3.0 → 0.5.0 (local source tree is already at
      0.5.0); record the version in `scripts/README.md` prerequisites
- [ ] Confirm `fly_footprint()` on a sample of southern centroids returns
      `footprint_basis` values as expected, and count how many are
      `unknown_format` — this is the number the per-AOI report will carry
- [ ] Add `scripts/aoi.R`: a declarative registry, one entry per AOI, carrying
      an `id` and either a watershed spec (`blue_line_key` +
      `downstream_route_measure`) or a `bbox`; plus a resolver returning an
      `sf` polygon in EPSG:3005 for either shape
- [ ] Register four AOIs: `neexdzii_kwa` (the existing watershed, unchanged),
      `se_a`, `se_b`, `se_c` (the three bboxes from the issue)
- [ ] Add a single helper for per-AOI output paths so no two AOIs share a cache,
      gpkg or log file

## Phase 2: Parameterise the AOI-hardcoding scripts

- [ ] `01_fetch.R` — take AOI ids from a command-line arg (default: all);
      resolve via the registry; move the centroid cache to
      `data/centroids/<aoi_id>.parquet` and the AOI to
      `data/aoi/<aoi_id>.gpkg`; per-AOI `fetch_log`
- [ ] `02_georef.R` — same parameterisation; read the per-AOI cache; per-AOI
      `georef_log`
- [ ] `00_review_samples.R` — same parameterisation
- [ ] `test_pipeline.R` — same parameterisation, **and** fix the removed
      `fly_thumb_georef()` call to `fly_georef()` so the harness runs again
- [ ] `03_cog.R` — per-AOI `cog_log` path only; the disk scan stays as-is
- [ ] `run_pipeline.sh` — accept and pass through AOI ids; keep the no-arg
      default working
- [ ] Verify the existing AOI still resolves to the same polygon it did before
      (compare against the published collection's bbox), so parameterisation is
      provably behaviour-preserving for the area already published

## Phase 3: Selection by overlap and era

- [ ] Add a selection step between filter and fetch: `fly_footprint()` →
      `fly_overlap()` → `fly_select(mode = "minimal", target_coverage = 0.95)`,
      run within each of the three eras
- [ ] Frames with no footprint (`unknown_format`) are counted and named as
      rejected, not silently dropped — fly warns, and the report must carry it
- [ ] Emit a per-AOI report: frames available, frames selected per era, year
      range obtained, and every rejection with its reason
- [ ] Confirm the existing AOI's behaviour is opt-in — selection must not
      silently change what would be fetched for `neexdzii_kwa`

## Phase 4: Make registration additive (the risky one)

- [ ] `05_stac_register.py` — read metadata from **every** per-AOI parquet under
      `data/centroids/`, not one fixed file
- [ ] Merge newly generated items with the existing published items rather than
      replacing them: enumerate the existing item set, and recompute the
      collection's spatial and temporal extent over the **union**
- [ ] Enumerate via the authenticated bucket listing (verified working: 9,742
      objects at root). Anonymous `ListBucket` is denied on this bucket, so do
      not build the merge on unauthenticated listing; `collection.json`'s own
      item links are the credential-free fallback
- [ ] **Dry-run gate before any S3 write:** generate `collection.json` locally
      and assert it carries ≥ 9,741 existing item links plus the new ones, and
      that its bbox contains the published extent
      `[-126.96, 53.98, -125.74, 54.74]`. Do not proceed on a shrunken extent
- [ ] Keep `aws s3 sync` free of `--delete` so no existing object can be removed

## Phase 5: Run the three AOIs end to end

- [ ] Run `se_a`, `se_b`, `se_c` through fetch → georef → COG → tag
- [ ] Upload to S3 and regenerate the merged collection
- [ ] Register on geopro via `stac_register-pypgstac.sh`
- [ ] Confirm `/search` returns items over each new AOI, and that a query over
      the original watershed still returns its items
- [ ] Confirm the live collection extent covers both regions
- [ ] Update `scripts/README.md` and `CLAUDE.md` for the AOI parameter, the new
      selection step, and the per-AOI paths

## Validation

- [ ] Existing AOI resolves to the same polygon and same item set as published
- [ ] `/search` returns items over all three new AOIs
- [ ] Live collection extent covers both regions; existing 9,741 items intact
- [ ] Per-AOI report produced for each of A, B, C
- [ ] `/code-check` clean on each commit
- [ ] PWF checkboxes match landed work; `/planning-archive` on completion

## Verification commands

```bash
# published extent, before and after — must grow, never shrink
curl -s https://images.a11s.one/collections/stac-airphoto-bc | jq .extent

# item count before and after — must not fall below 9741
aws s3 ls s3://stac-airphoto-bc/ | grep -c '\.json$'

# search over a new AOI (bbox A)
curl -s "https://images.a11s.one/search?collections=stac-airphoto-bc&bbox=-116.0758,49.0953,-116.0635,49.1060" | jq '.numberMatched'

# search over the original watershed — must still return items
curl -s "https://images.a11s.one/search?collections=stac-airphoto-bc&bbox=-126.96,53.98,-125.74,54.74" | jq '.numberMatched'
```

