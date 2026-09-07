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
- Next: Phase 1 — pytest into the env, failing tests, then `scripts/airphoto_props.py`.
