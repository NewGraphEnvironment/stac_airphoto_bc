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
