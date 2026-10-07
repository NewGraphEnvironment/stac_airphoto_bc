# Progress — Move the Python environment from conda to uv (#44)

## Session 2026-10-07

- Plan-mode exploration — phases approved by user
- Created branch `44-move-the-python-environment-from-conda-to` off main
- Scaffolded PWF baseline from issue #44 with approved phases
- Next: start Phase 1
- Phase 1: conda baseline 87 passed; pyproject.toml + uv.lock held to the conda freeze
  (requires-python 3.12 to stop a rasterio 1.4.4 fork); uv 87 passed; write census
  10,100/10,100 identical under both envs, positive control differs. Commit b1bafd9
- Plan review returned (no blockers); adopted --locked, item-body and stacs-verify A/B,
  stac_validate as the read check, census committed as a tool. Follow-up #45 filed
- Phase 2: call sites switched, environment.yml removed, pin tests repointed and
  mutation-tested, cog_rewrite-check.py committed and run (10,100 same); items, stacs
  verify, R→uv path all identical/passing
- /code-check: 3 rounds. R1: rewrite check read tags off the COG (blind to pyarrow) → now
  frame_tags/shift_of of the window row, re-run 10,100 same. R2: 3 doc claims inside that
  fix. R3: mechanism, the docs generalised this branch's 03 refusal; precondition (run
  before any stage under the new lock) stated everywhere. Ended by enumeration (7 places)
