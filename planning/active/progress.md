# Progress — The ledger's aoi_id holds WFS feature ids, not the AOI id (#32)

## Session 2026-09-27

- Plan-mode exploration — phases approved by user
- Created branch `32-the-ledger-s-aoi-id-holds-wfs-feature-i` off main
- Scaffolded PWF baseline from issue #32 with approved phases
- Next: start Phase 1
- Phase 1: tests written. `Rscript tests/test_aoi.R` → 7 new assertions fail (the
  parse pair on the bare `aoi_id = id`; `aoi_ledger_check_id()` absent). The mix / NA /
  missing-column refusals pass vacuously until the function exists — the Phase 2
  mutation run is what proves them.
