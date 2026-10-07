# Plan review — #42 (Plan agent, 2026-10-07)

Read-only agent; findings returned as reply text and written here by the parent session.

**Bottom line:** no blocker. Two real problems: G1 (a second copy of the broken heredoc in
`06_catalogue_promote.sh`) and V1 (the `--mode all --dryrun` proves less than `verify`).

## Answers to the six questions
1. Importing `05_stac_register.py` is safe: module level is `sys.path.insert`, imports and
   constants; 0.24 s cold.
2. `S3_BASE` is exactly the `bucket_url` stacs expects: stacs builds
   `bucket_url.rstrip("/") + "/collection.json"` (`register.py:414`); 05 fetches the same URL.
3. `register --mode all --dryrun` makes no ssh and no API call: it returns at
   `register.py:461-467`, before `_api_probe` and the ssh `probe` (472-474), before any item
   fetch and the audit. `audit --dir` is a non-recursive listdir of `*.json` minus
   `collection.json` (`validate.py:94-109`); `data/stac` has 10,100 item JSONs, the
   collection and `thumbs/`.
4. See G1/G2. `README.Rmd`/`README.md`/`index.html` only link stac_dem_bc as a sibling.
5. Published `collection.json` at `bucket_url/collection.json`: id `stac-airphoto-bc`,
   10,100 absolute item links, no self/child links, byte-identical to the local copy.
6. V1, V2.

## Gap
- **G1** `scripts/06_catalogue_promote.sh:108-120` heredoc runs `cd ~/Projects/repo/stac_dem_bc`
  + `catalogue_register.sh --all && --verify`; its note says verify "cannot confirm the new
  properties landed; nothing checks content yet (stac_dem_bc#45)", false with stacs; line 37
  names `catalogue_register.sh`. **Folded in.**
- **G2** The planned grep's `stac_dem_bc's orchestrator` never matches the backticked source;
  stale claims without any token (`scripts/README.md:251`, `:266`, `:242-249`,
  `CLAUDE.md:100-104`). Widen the grep, exclude `planning/`. **Folded in.**
- **G3** The README conda recipe will restate the tag with nothing pinning it; the test
  scans only `environment.yml`. stac_dem_bc loops over both install paths. Recipe also lacks
  `pytest`. **Folded in.**
- **G4** `CLAUDE.md:58` "Registration runs before the sync" means item generation; the
  stacs step runs after. "Register on geopro" now runs here over ssh. **Folded in.**
- **G5** `ASSET_THUMBNAIL` single-source is half true: `stac_validate.py:76`,
  `cog_render-compare.py:198` keep the literal. A rename fails loudly. Suggest moving to
  `airphoto_props.py`. **Declined:** build side is out of scope (#42); noted in task_plan.

## Ordering
- **O1** Prove the documented command before rewriting docs around it. **Done:** live
  checks ran before Phase 2.
- **O2** The CLAUDE.md block sits under `### The AOI is a parameter`, not `### Pipeline`.

## Assumption
- **A1** Separate envs, 0.1.0 vs 0.1.1: correct; same host and DB, docstring-only diff.
- **A2** The `--expect 10100` audit over `data/stac` proves this machine's tree only; the
  register-time audit over fetched published bodies is what protects pgstac. **Recorded.**
- **A3** `[transport]` copied from stac_dem_bc has never been proven against a write; its
  #49 findings say the remote load path was not exercised. **Recorded; user's call.**

## Scope
- **S1** Say why `verify` follows `register --mode all`: verify fails on orphans, register
  ignores them (`register.py:514-522`, `:590`). **Folded in.**
- **S2** `test_pipeline.R` ends at the sync with no registration hint. **Declined**, noted.
- **S3** `scripts/README.md:272` orphaned after the conda recipe. **Fold in while rewriting.**

## Acceptance
- **V1** Replace the dryrun with `register --mode drift` (no dryrun) after verify is in
  sync: probes API + ssh, writes nothing when in sync. **Done.**
- **V2** Concrete pass criteria: pytest count, `bash -n`, widened grep, verify IN SYNC,
  probe result, the printed heredoc runs as printed.
- **V3** Add a README-pin mutation once G3 is done.
