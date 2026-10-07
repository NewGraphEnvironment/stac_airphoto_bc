# Progress — Adopt stacs for registration and verification (#42)

## Session 2026-10-07

- Plan-mode exploration — phases approved by user
- Created branch `42-adopt-stacs-for-registration-and-verification` off main
- Scaffolded PWF baseline from issue #42 with approved phases
- Next: start Phase 1
- Phase 1: stacs v0.1.1 pinned in `environment.yml` (python>=3.11) and installed into the
  conda env (`direct_url.json` requested_revision v0.1.1); `stacs.toml`; `ASSET_THUMBNAIL`
  in `05_stac_register.py`; `tests/test_stacs_config.py` (10 tests). Suite 87 passed.
  Mutations in a scratch copy, each red: drop `require` (4 fail), wrong collection id (4),
  trailing-slash bucket (1), env pin v0.1.10 (1), a second env pin (1).
- Code-check round 1 on Phase 1: Clean (`review-p1-round1.md`). Rounds 2+ review the
  cumulative branch diff with Phase 2, so Phase 1 is committed after one round.
- Plan review landed; findings folded into Phase 2 (`review-plan.md`).
- Phase 3 live checks run early (read-only), all green; see findings.md.
- Phase 2: stacs commands in `run_pipeline.sh` and `06_catalogue_promote.sh` heredocs
  (`bash -n` clean); `CLAUDE.md` registration block moved into Pipeline and rewritten,
  "Registration runs before the sync" now names item generation; `scripts/README.md`
  Prerequisites, After the Pipeline, the backfill note, tests row, conda recipe (+ pytest,
  + stacs pin). Pin test covers both install paths; README pin bumped alone goes red.
  Widened grep: no hits outside `planning/`. The printed `verify` line, run verbatim:
  IN SYNC, exit 0 (15:55:34Z). Suite 87 passed.
- Code-check rounds 2 and 3 over the cumulative branch diff (`review-round2.md`,
  `review-round3.md`): 3 + 3 doc defects, none inside a previous fix, all fixed. Round 3
  enumerated all 83 claims about stacs/the test/the toml across 8 places against v0.1.1
  source: 79 true, the other 4 are its 3 findings. Mechanism: one body of facts restated
  in eight places from memory; plus "registration" changing meaning in this branch (now
  item generation vs pgstac registration), fixed in `04_s3_upload.R` comments too.
- Phase 3: #42 body edited (v0.1.1 pin, stac_dem_bc#49 deletion, live check, load path not exercised).
