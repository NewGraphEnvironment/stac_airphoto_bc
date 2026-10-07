# Review — #42 Phase 1, round 1

Scope: staged diff (environment.yml, scripts/05_stac_register.py, stacs.toml,
tests/test_stacs_config.py, planning files), against stacs v0.1.1 source
(`src/stacs/cli.py`, `validate.py`, `register.py`, `pyproject.toml`) and the
stac_dem_bc reference adoption (origin/main `stacs.toml`, `tests/test_stacs_config.py`).

## Clean

No issues found.

## What was checked (and why each is not a finding)

- **Suite runs.** `conda run -n stac-airphoto-bc pytest tests/ -q`: 87 passed. The new file alone:
  10 passed. Installed stacs: 0.1.1, `direct_url.json` has `requested_revision: v0.1.1`,
  `commit_id 7e66b2a` (= the v0.1.1 tag commit). Env Python 3.12.14, above the >=3.11 floor
  (`tomllib`, `str | None` in stacs need it).
- **Guards fail toward fail, not pass.**
  - `test_environment_yml_pins_the_same_tag`: any re-spelling the regex does not match
    (`stacs.git@v…`, a SHA, `refs/tags/…`) yields `[]`, which is not `["0.1.1"]`, so it goes red;
    a greedy capture ends at the closing `"`, and the comment lines carry no `stacs@v`.
  - `test_the_password_is_named_never_given`: if `"[transport]\n"` ever stopped matching, the
    replace is a no-op, `read_config` succeeds, and `pytest.raises` fails. That is a red test,
    not a silent pass. The `$`-anchored match avoids the tmp_path-contains-"password" trap.
  - `_audit` runs `stacs.cli.main`, which returns 2 on a ConfigError (missing/unreadable toml),
    so every `rc == 1` / `rc == 0` assertion fails on a broken config rather than passing.
  - `import stacs` is a hard import, so an env without stacs errors at collection.
- **The fixture can reach the failure mode.** The bad item sits mid-sort; `require` is applied
  per item in `audit_items` (`_is_asset` checks for a non-empty href, which the fixture
  supplies on good items), and the author's mutation (drop `require`) turns it red. The
  loosen-flag test exercises `merge_asset_rules`, which ignores `--collection-id`, as claimed.
- **Proxy vs property / verification that reads its own output.** The audit fixtures are
  built from `ASSET_THUMBNAIL`, `COLLECTION_ID` and `S3_BASE`, so they test that the toml and
  stacs wiring agree with the module, not 05's `build_items()` output. That is the stated
  purpose. `build_items()` keys the asset by the same constant (line 205), so the shapes agree
  by construction.
- **One fact derived twice.** The toml's three catalogue values are each pinned to the module
  value that produces them (`COLLECTION_ID`, `S3_BASE`, `ASSET_THUMBNAIL`). `S3_BASE` has no
  trailing slash, and stacs does `bucket_url.rstrip("/") + "/collection.json"`, matching 05's
  own `f"{S3_BASE}/collection.json"` (line 353). The key literal `"thumbnail"` survives in
  `scripts/stac_validate.py:76` and `scripts/cog_render-compare.py:198`. A rename of
  `ASSET_THUMBNAIL` + toml without them would make `check_item` refuse every item ("no
  thumbnail asset"), which fails loudly toward abort, not silently. So it is not reported.
- **Pins across repos.** stac_dem_bc pins v0.1.0 and this repo pins v0.1.1. They are separate
  conda/uv environments with no shared resolution, so the "two repos, one remote, two tags"
  trap does not apply. This repo has no CI workflow installing stacs, so environment.yml is
  the only install path to pin.
- **Secrets.** No secret appears in stacs.toml. The host/IP in the comment are public DNS
  (same text as stac_dem_bc), and `password_env` names the variable only.
- **Module load side effects.** Loading 05 via `importlib` inserts `scripts/` on `sys.path`
  (pre-existing behaviour, as for `test_cog.py`'s pattern). There is no top-level work beyond
  imports and constants, and `main` is guarded by `if __name__ == "__main__"`.
