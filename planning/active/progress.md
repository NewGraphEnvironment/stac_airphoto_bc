# Progress — Grayscale georef outputs become Gray + Alpha (#36)

## Session 2026-09-28

- Plan-mode exploration, reproduced the refusal and the fix in scratch; phases approved by user
- Scope decision: code + tests + local cold rebuild on fly 0.19.0; stop before S3 sync and geopro registration
- Created branch `36-grayscale-georef-outputs-become-gray-alp` off main
- Scaffolded PWF baseline from issue #36 with approved phases
- Next: start Phase 1
- Phase 1–3: tests went red on the old writer (5 failures). Writer fix plus mask-property guard; 63 pass. Code-check ran 3 rounds plus an enumeration (findings.md). Plan review folded in (review-plan.md)
- Phase 4 prep: snapshot in `data/_pre36/`; `published.parquet` refreshed to 10,100; fly 0.19.0 (`0eeb977`) installed; `tests/test_aoi.R` passes; filed #37
