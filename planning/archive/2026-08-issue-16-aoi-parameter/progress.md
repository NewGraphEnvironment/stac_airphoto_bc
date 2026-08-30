# Progress — Point the pipeline at a second area (#16)

## Session 2026-08-29

- Plan-mode exploration — read all 10 scripts directly, measured S3 + live collection state
- Three scope decisions put to the user and answered (digital frames, DEM, selection)
- Phases approved by user
- Created branch `16-point-the-pipeline-at-a-second-area-lift` off main
- Scaffolded PWF baseline from issue #16 with approved phases
- Plan-agent design review running concurrently (not a gate)
- Next: Phase 1 — fly 0.5.0 upgrade + AOI registry

### Phase 1 complete
- Installed fly 0.5.0; pinned `>= 0.5.0` in scripts/README.md and CLAUDE.md
- Added `scripts/aoi.R` — registry (watershed + bbox), resolver, per-AOI paths
- Verified the registry reproduces the original watershed AOI
- Measured AOI A: 818 candidates in window, 18 digital (2.2%, not the issue's 20%)
- Plan-agent review returned; 10 findings reproduced and folded into task_plan
- Measured that minimal set-cover selects 1 frame/era -> user changed the
  selection decision to all footprint-overlapping frames, era for reporting
- Filed fly#35 (footprint_basis dropped on tibble input)
- Next: Phase 2 — parameterise every stage

### Phases 2–4 implemented, Phase 5 run locally
- `01_fetch.R`, `02_georef.R`, `00_review_samples.R`, `test_pipeline.R` parameterised
  by AOI id; unknown id aborts before any work
- `scripts/centroids.py` — shared loader so `03_cog_tag.py` and `05_stac_register.py`
  read the union of per-AOI caches instead of one file
- `05_stac_register.py` rewritten to MERGE with the published collection
- `04_s3_upload.R` backs up collection.json, then syncs in two passes (no `--delete`)
- `run_pipeline.sh`: `set -euo pipefail`, AOI args, register BEFORE sync, geopro IP from env
- `README.Rmd` uses the registry rather than the fifth hardcoded AOI

Measured:
- se_a 818 window / 109 selected; se_b 840 / 108; se_c 1013 / 78
- every ledger reconciles to its window
- 295 selections but **235 unique frames** — 60 shared between A and B, fetched,
  converted and published once, which is why the output trees are global
- digital share varies far more than the issue assumed: 2.2% (A), 4% (B), **20% (C)**
- merge dry-run: 9,741 published + 235 new = 9,976 links, 0 dropped, byte-identical
  across two runs, extent grows to cover both regions

Environment: the conda env did not exist on this machine and `conda env create`
failed on an Anaconda ToS prompt for the `defaults` channel — while reporting exit 0
through the task wrapper. Dropped `defaults` from environment.yml and built from
conda-forge explicitly.

- Next: code-check rounds, then S3 upload + registration

### Phase 5 complete — published and registered
- Baseline recorded before any write: 9,741 over the watershed, 0 over each new AOI
- Registered and synced: S3 9,742 -> 9,977 objects (+235 exactly), collection backed up
- pypgstac reload: 9,976 items
- Verified live: watershed **9,741** (unchanged), AOI A **116**, B **121**, C **78**,
  extent covers both regions, temporal 1967-07-11..2019-09-18

Note on the pypgstac script: it DELETEs the collection and reloads from
collection.json's item links, so the merge is load-bearing — an unmerged
collection would have deleted 9,741 items from the catalog. It also leaves the
collection empty between the delete and the load (~10 min).

### Review rounds
- Round 1: 12 findings, all fixed
- Round 2 (reviewing the fixes): 3 real bugs **inside** the round 1 fixes, plus one
  still-tautological assertion and two partial fixes — all fixed

### Round 3 — convergence
- One new finding, and it predates round 2 rather than sitting inside a round 2 fix:
  `if published:` gated the merge and every assertion on truthiness, so a 200 whose
  body was `null`/`{}`/`[]`/`false` took the replace-everything path with rc=0 and no
  assertion able to fire. Fixed by validating the shape; all four bodies now abort.
- Round 3 confirmed round 2's fixes hold: 24-cell temporal matrix clean, sub-extent
  removal has no remaining consumer, `link_id()` gives 9,976 distinct ids over 9,976
  live hrefs, and the assertions go red when the defect is restored.
- Pass 1: 12 findings. Pass 2: 10, three of them inside pass 1's fixes. Pass 3: 1, none
  inside pass 2's fixes. That is the convergence signal to stop.
