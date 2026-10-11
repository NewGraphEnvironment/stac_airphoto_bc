# Progress — Move the nge: item fields to standard or descriptive names (#47)

## Session 2026-10-10

- Plan-mode exploration — phases approved by user (fly sha as semver build metadata; code now, publish with next rebuild)
- Created branch `47-move-the-nge-item-fields-to-standard-or` off main
- Scaffolded PWF baseline from issue #47 with approved phases
- Next: start Phase 1
- Phases 1-3: tests, writer, validator. 105 tests pass.
- Mutation table (copy under scratchpad, 6 mutations): removing the prefix guard fails 5 tests; removing the fly-entry check, 3; dropping the PIPELINE_SHA tag compare, 1; writing a half fly build, 4; putting `nge:fly_sha` back in the writer, 2; un-declaring the processing schema, 1. Dropping PROCESSING_EXTENSION from 05 is proved in Phase 4 (05 runs check_item on every item before it writes).
- Phase 4: 05 into scratch over all 10,100 items; rename-only diff, 0 problems (findings.md).
- Plan review + code-check rounds 1-3 (review-*.md): round 1 one accepted finding (index.html re-rendered at publish), rounds 2 and 3 Clean; no defect inside a fix. Fixes in 0b04670.
- Next: archive, PR. Publishing is a separate step (CLAUDE.md, Build properties).
