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
| Digital frames (`unknown_format` under fly ≥ 0.4.0) | **Exclude, report the count per AOI.** fly#32 is the follow-up. |
| DEM-corrected footprints (fly 0.5.0 `dem` arg) | **Not this run.** One variable at a time; follow-up rebuilds both regions together. |
| Selection | **All frames whose footprint overlaps the AOI**, reported by era (pre-1980, 1980–1999, 2000+). Minimal set-cover was measured and rejected — see below. |

### Why minimal set-cover was dropped

Measured on AOI A: 818 centroids in the 8 km fetch window → 116 frames whose
footprint overlaps the AOI → `fly_select(mode = "minimal", target_coverage = 0.95)`
selects **exactly 1 frame per era**, because film footprints here are 2.3–7.2 km
wide and the AOI is ~1 km². That is 3 photos for AOI A and ~9 across all three.
The user chose to keep every footprint-overlapping frame instead (~350 total).
Era is now a **reporting** dimension, not a pruning one. `fly_select` is not
used; `fly_coverage` and `fly_overlap` are used for the report.

## Verified findings from the concurrent Plan-agent review

Each was reproduced before being accepted. Findings not listed here were either
already covered by the plan or not reproduced.

| # | Finding | Verified how |
|---|---|---|
| B1 | `run_pipeline.sh` syncs to S3 (line 23) **before** registration writes the item JSONs (line 27) — so the JSONs a run produces never reach S3 | read the script; ordering is unambiguous |
| B2 | A fresh run dies at `01_fetch.R:21` — `data/` is gitignored and absent, and nothing creates it | `[ -d data ]` is false on this machine |
| B3 | Selection strands `fly_georef(rotation = "auto")`: a thinned roll gives `fly_bearing()` no successor, so every frame silently falls back to the fixed 180° | measured — bearing NA **3/3** on a selected set, **0/3** when joined from the full candidate set (172.7°, 84.8°, 262.3°) |
| B4 | `05_stac_register.py` and `03_cog_tag.py` each read a single `CACHE_PATH`, so with per-AOI parquets they would drop every other AOI's COGs | read both; `03_cog_tag.py:15` confirmed |
| G1 | `04_s3_upload.R` uses `--size-only`, so a regenerated JSON of identical byte count never uploads | read the script |
| G2 | `00_review_samples.R` writes into `data/raw/thumbs/samples/`, which `02_georef.R` then picks up in its recursive scan — the same photo twice | read both paths |
| G3 | Cache-miss keeps the WFS geometry; cache-hit rebuilds points from lon/lat — same photo, two provenances | read `01_fetch.R:48-50` |
| S1 | A **fifth** hardcoded AOI, in the published `README.Rmd:84-85` | grep |
| S2 | `run_pipeline.sh:32` hardcodes the geopro IP in a public repo | grep |
| Q4 | The published collection already contains digital frames sized as 9-inch negatives | sampled live items: `bcd12008` (100 mm, 1:50000) ships an **11,435 m**-wide footprint against 2,286–7,242 m for every film frame |

### Found while verifying: an upstream fly bug

`fly_footprint()` **silently drops `footprint_basis`, `footprint_terrain`,
`height_agl` and `dem_coverage` when its input carries the `tbl_df` class** —
which is exactly what `bcdata::collect()` returns. Measured:

```
bcdc_sf,sf,tbl_df,tbl,data.frame  -> footprint_basis absent
sf,tbl_df,tbl,data.frame          -> footprint_basis absent
sf,data.frame                     -> footprint_basis present
```

So the entire reporting surface fly 0.4.0/0.5.0 added is invisible to any
caller feeding it bcdata output, and the digital exclusion stays silent. The
pipeline coerces to a plain `data.frame`-backed sf after the query; filed
upstream as [fly#35](https://github.com/NewGraphEnvironment/fly/issues/35).

## Phase 1: Prerequisites and the AOI registry

- [x] Upgrade installed `fly` 0.3.0 → 0.5.0
- [x] Add `scripts/aoi.R`: registry, resolver (watershed **and** bbox), per-AOI
      path helper
- [x] Register four AOIs: `neexdzii_kwa` (existing constants, unchanged), `se_a`,
      `se_b`, `se_c`
- [x] Verify the registry reproduces the original watershed — resolves to
      `-126.7470, 54.1018, -125.9112, 54.6744`, 2,319 km², a subset of the
      published item extent as it should be (items are footprints, which
      overhang the AOI)
- [x] Measure `media` / footprint basis on real southern centroids — 818 in the
      AOI A window, 18 `Digital - Colour` (2.2%, not the 20% the issue assumed),
      800 film
- [x] Pin `fly (>= 0.5.0)` in `scripts/README.md` and CLAUDE.md
- [x] File the `tbl_df` column-drop bug upstream on fly — [fly#35](https://github.com/NewGraphEnvironment/fly/issues/35)

## Phase 2: Parameterise every stage

- [x] `01_fetch.R` — AOI ids from the command line (default all, **abort** on an
      unknown id); per-AOI centroid cache and AOI gpkg; create `data/` and every
      subdirectory up front (B2); coerce the bcdata result to a plain
      `data.frame`-backed sf, which also settles the cache-hit/miss geometry
      asymmetry (G3, fly bug)
- [x] `02_georef.R` — read the per-AOI selected set rather than re-deriving the
      filter; join `bearing` computed on the **full candidate set** onto the
      frames being georeferenced (B3)
- [x] `00_review_samples.R` — parameterised, and its output moved out of the
      `02_georef.R` scan path (G2)
- [x] `test_pipeline.R` — parameterised; fix the removed `fly_thumb_georef()`
      call (B5)
- [x] `03_cog.R` — per-AOI log path only; the disk scan stays global
- [x] `03_cog_tag.py` — read the **union** of `data/centroids/*.parquet` (B4)
- [x] `run_pipeline.sh` — `set -euo pipefail`, AOI ids passed through, geopro IP
      out of the source (S2), and **sync after registration** (B1)
- [x] `README.Rmd` — demonstrate the registry rather than the constant (S1);
      rebuild `README.md` / `README.html` / `index.html`

## Phase 3: Candidate selection and the rejection ledger

- [x] Narrow the fetch window with `fly_filter(method = "footprint")`; keep every
      frame that overlaps
- [x] One row per candidate in `data/select/<id>.csv` with a `rejected_reason`:
      `selected`, `digital_unknown_format`, `footprint_misses_aoi`,
      `no_thumbnail_url`, `fetch_failed`, `georef_failed`
- [x] Assert the ledger reconciles — rows equal candidates in the buffered window
- [x] Per-AOI markdown report: frames available and selected by era, year range,
      and every rejection with its reason and count
- [x] Abort loudly if an AOI selects zero frames

## Phase 4: Additive registration

- [x] Back up the published `collection.json` to S3 and locally **before any
      write** — it is the one irreplaceable object in the bucket
- [x] Record the baseline: item-JSON count on S3 and `/search` count over the
      original watershed
- [x] `05_stac_register.py` — read the union of `data/centroids/*.parquet` (B4);
      merge new item links with the published ones (authenticated bucket listing
      as ground truth, `collection.json` as the credential-free fallback);
      recompute extent over the union
- [x] Stamp `airphoto:footprint_basis` on new items so a future DEM rebuild is a
      delta rather than archaeology
- [x] `--out <dir>` dry-run mode; assert as code that the old item hrefs are a
      subset of the new, the new bbox contains the published bbox, and running
      twice is idempotent
- [x] Sync JSONs in a pass without `--size-only` (G1); never `--delete`

## Phase 5: Run the three AOIs end to end

- [x] Run `se_a` through fetch → georef → COG → tag as a single-AOI smoke test
- [x] Dry-run the collection merge and check the assertions before the first sync
- [x] Run `se_b` and `se_c`; confirm frames shared between A and B were fetched
      once, not twice
- [x] Upload, register, then sync again (B1)
- [x] Register on geopro; confirm `/search` returns over each new AOI **and**
      still returns the baseline count over the original watershed
- [x] Confirm the live collection extent covers both regions
- [x] Update `scripts/README.md` and CLAUDE.md

## Validation

- [x] Existing AOI resolves to the same polygon as the published collection implies
- [x] `/search` returns items over all three new AOIs
- [x] Live collection extent covers both regions; existing 9,741 items intact
- [x] Per-AOI report produced for each of A, B, C, with a reconciling ledger
- [x] `/code-check` clean on each commit
- [x] PWF checkboxes match landed work; `/planning-archive` on completion

## Verification commands

```bash
# published extent, before and after — must grow, never shrink
curl -s https://images.a11s.one/collections/stac-airphoto-bc | jq .extent

# item count on S3 — must not fall below 9741
aws s3 ls s3://stac-airphoto-bc/ | grep -c '\.json$'

# search over a new AOI (bbox A), and over the original watershed
curl -s "https://images.a11s.one/search?collections=stac-airphoto-bc&bbox=-116.0758,49.0953,-116.0635,49.1060" | jq '.numberMatched'
curl -s "https://images.a11s.one/search?collections=stac-airphoto-bc&bbox=-126.96,53.98,-125.74,54.74" | jq '.numberMatched'
```
