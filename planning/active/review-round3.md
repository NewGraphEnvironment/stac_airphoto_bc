# Code-check round 3 — #44 (conda → uv), staged diff + HEAD

## The mechanism

Rounds 1 and 2 found instances. This round looked for what produced them. The rules for
any env change were written from this branch's situation and stated as if they held for
every future env change. Two facts about this branch made that look safe:

- **(a) "An env change makes 03 refuse."** On this branch 03 refuses the windows. The
  reason is that the branch edits `scripts/`, which moves `pipeline_sha`. It is not
  because the env changed. `pipeline_sha.sh` hashes only `scripts/` and `data-raw/`, so
  a change to `uv.lock` or `pyproject.toml` alone leaves it where it was (#45). On a
  steady-state tree, `03_cog.py` runs normally after `uv lock --upgrade-package`.
- **(b) "The local COGs are the published bytes."** That is true today, because nothing
  has run since the last sync. It stops being true as soon as 03 runs under the new lock.
  03 replaces every COG whose bytes differ.

The rewrite check uses the local COG as its reference (`new == dst.read_bytes()`). Under
(a) the docs say 03 cannot run. Under (b) they assume it has not run. Both are wrong for
the case the tool exists for. In that case the check compares the new env's output with
the new env's output, so it verifies its own output.

## Findings

- **[fragile]** scripts/cog_rewrite-check.py:68 (`new == dst.read_bytes()`), together with the ordering every doc gives it: pyproject.toml:14 "before any run that publishes", scripts/README.md:64 "after a `uv lock` upgrade and before any run that publishes", scripts/README.md:277-279 (same), CLAUDE.md:74 "after any change to the Python environment".
  The check is valid only if no 03 run under the new lock has happened yet. No doc says
  so, and "before any run that *publishes*" allows the order that breaks it. CLAUDE.md:52
  tells people to "run the stages individually when the result must not be published".
  The order then goes: bump the lock, run 01/02/03 individually (none of them publishes),
  run `cog_rewrite-check.py`, then sync. 03 has already overwritten the reference, so the
  check reports "same" and exits 0. The sync then re-uploads every COG whose bytes the new
  GDAL changed, and their `nge:pipeline_sha`/`PIPELINE_SHA` labels do not change (#45).
  That is the outcome the tool exists to prevent, and the check fails toward pass.

  **Proven in a scratch tree** (`scratchpad/r3/tree`: one frame, `bc5255_203_thumb`; the
  repo's `data/window` symlinked read-only; the repo's `.venv` python). As a stand-in for
  a new GDAL, I changed `COG_OPTIONS` compress to LZW in the copy of `03_cog.py`. Results:
  - control: `1 same`, exit 0
  - changed writer: `differs`, exit 1
  - after 03's own `write_cog()` call wrote that frame into `data/stac` under the changed
    writer: `1 same, 0 not`, exit 0

  The same reasoning reaches the item-JSON advice (CLAUDE.md:85, README.md:282-283,
  docstring:18-19). "Compare `05_stac_register.py --out <dir>` with `data/stac`" passes
  trivially once a plain `05` has run under the new lock, because 05 rewrites `data/stac`.

  Fix, either one:
  - State the precondition everywhere this ordering appears: run it before 03 or 05 runs
    under the new lock, against a tree whose COGs and items are the published ones.
  - Or take the reference from outside the env: each item's published `file:checksum`
    (`thumbnail` asset) from the S3 `collection.json` items, instead of the local bytes.
    03 can then no longer overwrite it.

- **[fragile]** CLAUDE.md:83, scripts/cog_rewrite-check.py:21-23 (docstring), scripts/cog_rewrite-check.py:78-79 (comment in `main()`), planning/active/findings.md (plan-review bullet: "the upgrade path otherwise has no writer check: `03_cog.py` refuses to run until 01/02 restamp the windows").
  These say 03 refuses after an env change. The docstring adds "it cannot run until 01
  and 02 have been re-run, and that run then tags a new PIPELINE_SHA, which changes every
  byte anyway". That is false for a lock-only change.

  **Probed** in a scratch clone of HEAD: `pipeline_sha.sh` printed `35dcf87e4def` in all
  three states, i.e.
  - before the change,
  - with `uv.lock` and `pyproject.toml` edited but uncommitted,
  - with that edit committed.

  The claim contradicts follow-up #45 on this same branch, which records that
  `pipeline_sha` does not cover `uv.lock`. It presents a refusal that does not exist, and
  it is the premise the first finding's unsafe ordering rests on. After a lock bump, 03
  can and will run. It overwrites local COGs and prints "N COGs written". On a tree with
  no other change, N > 0 is itself the signal that the env changed the bytes, but only
  after the reference is gone. The comment at :78-79 ("03's refusal of it is what this
  check works around") is only true while the code SHA has moved, as it has on this
  branch. Reword all four to say that a lock-only change does not move `pipeline_sha`
  (#45), so 03 runs and overwrites the reference. That is why the check must come first.

## Checked, no issue

- `--locked` is used at every call site whose output is published: `run_pipeline.sh` 03/05,
  `test_pipeline.R` 03/05, `04_s3_upload.R` `stac_validate.py`, and
  `06_catalogue_promote.sh` `$UV_RUN`. No R or shell file invokes Python in any other
  way (`git grep python -- '*.R' '*.sh'`).
- "~11 min for 10,100 frames on 8 workers": 10 cores, default workers = 8. The run took
  17:15:29 to 17:26:50. Both CSVs in `data/logs/rewrite/` are 10,100 `same`.
- The docstring's 10,100 citation now names the new-method CSV (`20261007T172650Z.csv`),
  and that CSV shows 10,100 same.
- `test_stacs_config.py`: `_locked_stacs()` parses the lock's
  `https://github.com/NewGraphEnvironment/stacs?tag=v0.1.1#<commit>` form. The tag and
  commit tests are whole-string, and the mutations are recorded in findings.
- `cog_render-compare.py --expect-same` is no longer offered anywhere as an env check
  (`git grep expect-same`).
- No live `conda`/`environment.yml` reference remains outside planning/ and the soul
  convention lines.
- Repo untouched by these probes (`git status` unchanged; `data/logs/rewrite/` still
  holds only the two committed-run CSVs).
