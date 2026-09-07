# Progress — Carry the catalogue metadata on items (#21)

## Session 2026-09-07

- Plan-mode exploration: read `05_stac_register.py`, `01_fetch.R`, `aoi.R`,
  `centroids.py`, `03_cog_tag.py`, `04_s3_upload.R`, `test_pipeline.R`; profiled the
  three centroid caches; fetched the published collection and a published item.
- Found the real precedent in `stac_orthophoto_bc/scripts/item_cog_backfill.py`.
- Four decisions taken at the gate: link-only for PAT-B, issue's field set plus
  `flight_log_url`, backfill in this issue, carry `media` alongside `footprint_basis`.
- Created branch `21-carry-catalogue-metadata-on-items` off main.
- Scaffolded PWF baseline with the approved phases.
- Phase 1: `scripts/airphoto_props.py` + 35 tests, each proved able to fail.
- Phase 2: wired into `05_stac_register.py`; all 235 regenerated items compared
  against the ones on disk, 0 regressions.
- Phase 3: `06_catalogue_fetch.R`; 9,976/9,976 rows, diagonal confirmed over the
  population.
- Plan review returned 2 blockers, both verified and both real — the zero-GSD
  sentinel and the `.OR` spelling. Fixed, with a new SENTINEL guard.
- Phase 4: backfill + 7-guard validator; 9/9 restore-the-bug proofs fire their
  own tag; full run over 9,976 clean.
- Phase 5: promoted, re-validated the promoted tree, synced to S3, verified three
  published items over HTTPS. Docs and issue body updated.
- Commits: bbcbd0b, 5384aef, 4141096, ff5642c, + phase 4 and 5.
- Next: `/planning-archive`, then open the PR. The geopro pypgstac reload is
  deliberately left for a human — it deletes before it reloads.
