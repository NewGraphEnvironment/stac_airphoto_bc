# Task: Adopt stacs for registration and verification (#42)

## Problem

`scripts/run_pipeline.sh` tells the operator to register by `cd ~/Projects/repo/stac_dem_bc`
and running that repo's `catalogue_register.sh`. This repo's registration therefore depends
on another repo's working tree being on `main` with a working `.venv`. That layer is now the
`stacs` package (NewGraphEnvironment/stacs#1).

Parity for this collection was measured 2026-10-06: `stacs verify` reports the same sets as
the shell (10,100 items, in sync).

## Context (from plan-mode exploration)

Today this repo registers on pgstac by `cd ~/Projects/repo/stac_dem_bc` and running that
repo's `catalogue_register.sh` (the `run_pipeline.sh` heredoc, `CLAUDE.md` Pipeline section,
`scripts/README.md` "After the Pipeline"). **That script no longer exists on
stac_dem_bc's `origin/main`**: stac_dem_bc#49 adopted `stacs` and deleted
`catalogue_register.sh`, `item_register.sh` and `collection_register.sh`. So the documented
registration is already broken. A checkout that is still on an older commit is the only
reason it would run.

`stacs` (NewGraphEnvironment/stacs) is that layer, packaged. Tags `v0.1.0` and `v0.1.1`
exist. stac_dem_bc's adoption (`stacs.toml` plus `tests/test_stacs_config.py`, archived at
`planning/archive/2026-10-issue-49-adopt-stacs/`) is the reference implementation. Parity
for this collection was measured 2026-10-06: 10,100 items, in sync.

**Decisions taken by default (say if you want them otherwise):**
- **Pin `v0.1.1`, not `v0.1.0`.** The issue was written before 0.1.1 existed. I checked
  `git diff v0.1.0 v0.1.1 -- src/`: it adds docstring examples only, so behaviour is
  identical. stac_dem_bc pins 0.1.0, but the two repos install into separate environments
  (a conda env here, a `.venv` there), so they do not conflict.
- **`--mode all`, as the issue says.** The corrected note will say `drift` is also valid
  now that it compares bodies.
- **`run_pipeline.sh` keeps printing the registration commands rather than running them.**
  Registration needs tailnet ssh to geopro and stays a separate step after the sync, as now.

## Phase 1: Pin stacs and declare the catalogue
- [x] `environment.yml`: `python>=3.11` (stacs' floor), and under `pip:` add
      `"stacs @ git+https://github.com/NewGraphEnvironment/stacs@v0.1.1"`
- [x] Install into the local `stac-airphoto-bc` env (Python 3.12.14) with the same pip line.
      Expect `stacs --version` to report 0.1.1
- [x] `05_stac_register.py`: add `ASSET_THUMBNAIL = "thumbnail"` beside `COLLECTION_ID`
      and use it where the `thumbnail` asset is built (line ~203). This gives the toml a
      module value to be pinned to
- [x] `stacs.toml` at the repo root:
      - `[catalogue]`: `api = "https://images.a11s.one"`,
        `collection_id = "stac-airphoto-bc"`,
        `bucket_url = "https://stac-airphoto-bc.s3.us-west-2.amazonaws.com"`
      - `[assets] require = "thumbnail"`
      - `[transport]`: the same geopro values as stac_dem_bc's `stacs.toml` (`root@geopro`,
        db `stac`, `/opt/geoserv/.env`, `/opt/geoserv/scripts`, `/root/.local/bin`,
        `pg_user stac`, `password_env = "POSTGRES_PASSWORD"`, `uv run pypgstac`)
      - a header comment naming which module holds each value
- [x] `tests/test_stacs_config.py`, a slimmed version of stac_dem_bc's. It loads
      `05_stac_register.py` with `importlib`, the way `test_cog.py` loads `03_cog.py`. The
      tests:
      - the toml parses through `stacs.cli.read_config`
      - `collection_id == COLLECTION_ID`, `bucket_url == S3_BASE`,
        `require == ASSET_THUMBNAIL`
      - the installed stacs is `0.1.1` and came from the tag (`direct_url.json`'s
        `requested_revision`)
      - `environment.yml` pins exactly that tag
      - a `password` key is refused
      - `stacs audit --config stacs.toml`, run in process, passes a good item and fails one
        item without `thumbnail`. It also fails one that names another collection. The bad
        item sits in the middle of the sort order, so this proves the config is wired, not
        just present
- [x] Restore-the-bug check: drop `require` from the toml and confirm the missing-thumbnail
      test goes red; change `collection_id` and confirm the pin test goes red
- [x] `conda run -n stac-airphoto-bc pytest tests/ -q` is green

## Phase 2: Registration commands and docs
- [x] `scripts/run_pipeline.sh` heredoc: replace the `cd` block with
      `conda run --no-capture-output -n stac-airphoto-bc stacs register --config stacs.toml --mode all`
      followed by the same with `stacs verify --config stacs.toml`, run from the repo
      root. Correct the note: `--mode drift` compares bodies (stac_dem_bc#45, now stacs), so
      it does refresh rebuilt items. `all` is the routine and drift is a valid alternative
- [x] `CLAUDE.md`:
      - Pipeline section: replace the stac_dem_bc block (subshell and env vars, the
        `--all`-vs-`--drift` paragraph, the worktree/`PYTHON=` advice) with the stacs
        commands and a pointer to `stacs.toml`
      - Known issues: retarget the pypgstac warning's "Register with … instead"
      - Architecture: one line that registration is `stacs`, pinned in `environment.yml`
- [x] `scripts/README.md`:
      - Prerequisites: the geopro row becomes tailnet ssh to `root@geopro` plus stacs in
        the conda env. The stac_dem_bc checkout and `.venv` requirement is dropped
      - "After the Pipeline": the stacs commands. The merged collection stays
        load-bearing. Drop the id-set-only claims
      - Line ~99: `catalogue_register.sh --all` becomes `stacs register --mode all`
      - The conda build recipe gains the stacs pip line
- [x] `scripts/06_catalogue_promote.sh` (plan review G1): its closing heredoc is a second copy
      of the broken stac_dem_bc block. Replace it with the same stacs commands; rewrite the
      note (verify now compares bodies); line 37's `catalogue_register.sh` becomes `stacs register`
- [x] Wording (G4): `CLAUDE.md` "Registration runs **before** the sync" means item generation
      (`05_stac_register.py`); call the stacs step "pgstac registration". The heredoc's
      "Register on geopro" runs on this machine and reaches geopro over ssh
- [x] Say why `stacs verify` follows `register --mode all` (S1): register ignores orphans,
      verify fails on them and writes id lists with `--out-dir`
- [x] Pin test covers the README conda recipe too (G3), so a bump in one install path alone
      fails; the recipe also gains `pytest` (missing today). Mutation: README pin bumped alone
- [x] Widened grep (G2), expect no hits outside `planning/`:
      `catalogue_register|STAC_(COLLECTION|BUCKET_URL|REQUIRE_ASSET)|orchestrator|stac_dem_bc#45|--drift|--verify|PYTHON=|compares? (ids|id sets)|nothing (checks|compares) content`
- [x] `bash -n` on `run_pipeline.sh` and `06_catalogue_promote.sh`
- [x] Leave the build side alone: `05_stac_register.py` (except the constant),
      `stac_validate.py`, `06_catalogue_validate.py`. The `"thumbnail"` literals in
      `stac_validate.py` and `cog_render-compare.py` stay (G5): a rename that missed them
      fails loudly, every item refused. `test_pipeline.R` stays as is (S2): it ends at the
      sync and prints no registration hint today

## Phase 3: Live check
- [x] `stacs audit --config stacs.toml --dir data/stac --expect 10100` over the local items
      (offline)
- [x] `stacs verify --config stacs.toml --out-dir <scratchpad>` against images.a11s.one
      (read-only). Expect IN SYNC 10,100/10,100
- [x] Only if in sync: `stacs register --config stacs.toml --mode all --dryrun` (reads
      collection.json only; returns before any probe), then `--mode drift` without
      `--dryrun` (plan review V1), which probes the API and ssh to geopro and, in sync,
      writes nothing
- [x] Record timings and results in `findings.md`
- [x] Edit the #42 body: tick the items, note the v0.1.1 pin and why, and state that
      stac_dem_bc#49 had already deleted the script this repo pointed at

## Validation

- [x] Tests pass
- [x] `/code-check` clean on each commit
- [x] PWF checkboxes match landed work
- [x] `/planning-archive` on completion
