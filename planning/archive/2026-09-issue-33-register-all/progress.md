# Progress — Register with catalogue_register.sh --drift once stac_dem_bc#42 merges (#33)

## Session 2026-09-27

- Plan-mode exploration — phases approved by user; routine mode `--all` chosen at the gate
- Created branch `33-register-with-catalogue-register-sh-drif` off main
- Scaffolded PWF baseline from issue #33 with approved phases
- Phase 1: one `catalogue_register.sh --all && --verify` block, subshelled, in CLAUDE.md,
  scripts/README.md, run_pipeline.sh and 06_catalogue_promote.sh; pypgstac only named as
  "do not use"
- /code-check: 3 rounds + enumeration (review-round1..3.md). R1 stale README sentence,
  missing Python prereq; R2 PYTHON= read as a directory (inside R1's fix), vacuous /search
  check, exported vars leaking into the DEM shell; R3 the replacement spot-check passed on
  null==null and sampled a fixed item, trailing comments broke a zsh paste. Spot-check
  removed; content gap filed upstream as stac_dem_bc#45; misleading error as stac_dem_bc#44
- Phase 2: audit-items OK on 10,100 (dem negative control fails all); live --verify IN SYNC
  10100/10100; documented block run verbatim under bash and zsh (nointeractivecomments) in
  pass (dryrun) and fail (nonexistent bucket, rc 22, verify skipped) states; PYTHON= path vs
  directory confirmed; #33 body retitled/rewritten for `--all`
