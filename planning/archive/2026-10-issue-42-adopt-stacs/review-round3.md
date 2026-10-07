# Review round 3 — #42 cumulative branch diff (staged), every stacs claim enumerated

Scope: environment.yml, scripts/05_stac_register.py, stacs.toml, tests/test_stacs_config.py,
scripts/run_pipeline.sh, scripts/06_catalogue_promote.sh, scripts/README.md, CLAUDE.md
(above the soul marker). Ground truth: `~/Projects/repo/stacs` at `v0.1.1`
(`7e66b2a`): `src/stacs/{cli,register,verify,validate,catalogue,__init__}.py`, `pyproject.toml`.

What was run, not just read:
- `pytest tests/ -q`: 87 passed.
- In a temp copy (the repo was not touched): removing `require = "thumbnail"` from
  stacs.toml turns 4 tests red (`test_required_asset_is_the_modules`,
  `test_audit_passes_items_as_we_build_them`, `..._without_a_thumbnail`,
  `test_a_flag_cannot_loosen...`). Changing the environment.yml pin to `v0.1.10` turns
  `test_every_install_path_pins_the_same_tag` red.
- `stacs register --config stacs.toml --mode all --dryrun` from the repo root: rc 0,
  `asset audit: require=thumbnail forbid=-`, published 10100, no API or ssh probe.
- `stacs register --config stacs.toml` (no `--mode`): rc 2, argparse "required: --mode".
- Installed: stacs 0.1.1, `direct_url.json` `requested_revision: v0.1.1`, commit
  `7e66b2a` = the tag. Python 3.12.14.
- `conda run ... pip install "stacs @ git+...@v0.1.1"`: conda 26.3.2 keeps the spaced
  argument whole (argv checked); pip resolves it. Repo is public, so no credentials.
- `dig images.a11s.one` = 146.190.12.8 (the IP in the stacs.toml comment).

## Mechanism

Confirmed as you stated it: one body of facts about stacs (the commands, what register,
drift and verify do, what the test pins) restated in eight places, each written from
memory or from another restatement rather than from `cli.py` / `register.py`. Round 1's
three defects were all one copy disagreeing with the source while the others agreed.

Two sub-shapes of it show up in what is left:

1. **Copied from a sibling document, not from the source.** stacs.toml's header synopsis
   (`stacs register|verify|audit --config stacs.toml`) is stac_dem_bc's stacs.toml
   header, carried over. It reads as a command and is not one (finding 1). Same class as
   round 1's missing-`--mode` copy.
2. **A term whose meaning moved in this branch, fixed in one copy only.** "Registration"
   used to mean `05_stac_register.py`; the branch introduces "pgstac registration" after
   the sync. CLAUDE.md:55 was reworded for exactly that reason ("Item generation ... runs
   before the sync"); the same sentence in run_pipeline.sh:16 and scripts/README.md:31
   was not (finding 3).

## Findings

- **[fragile]** stacs.toml:2 — `#   stacs register|verify|audit --config stacs.toml`. As a
  command it does not run: `register` without `--mode` exits 2 (measured), and `audit`
  without `--dir` reads paths from stdin, so it waits on the terminal. Fails loud and
  writes nothing, but it is the one remaining command-shaped line in the diff that does
  not run as written. Inherited verbatim in shape from stac_dem_bc's header.

- **[fragile]** CLAUDE.md:88-90 and scripts/README.md:237-240 — "`register` fetches ...
  every item it links, **audits them** / **audits all of them** (collection id, a
  `thumbnail` asset on each, no id twice) before anything is written". This is stated as
  register's behaviour in general, and the next sentences describe `--mode drift`. In
  drift only the items being sent are audited (`register.py:548-556`,
  `audit_items(todo_paths, ...)`, `todo = missing ∪ changed`). True for `--mode all`,
  which is the command shown. Consequence is small (an unsent item already matches the
  API byte for byte), but the sentence is false for drift, and a reader choosing drift
  as "the cheaper choice" (CLAUDE.md:93) would believe the whole catalogue was audited.

- **[fragile]** scripts/run_pipeline.sh:16 ("Registration runs BEFORE the S3 sync") and
  scripts/README.md:31 (`Rscript scripts/04_s3_upload.R   # AFTER registration, not
  before`). Unchanged lines in changed files. Each file now also says the opposite in
  the new vocabulary: run_pipeline.sh:65 "Register into pgstac" after the sync;
  scripts/README.md:228 "register it into pgstac ... after the S3 sync". CLAUDE.md:55 was
  reworded to "Item generation (`05_stac_register.py`) runs **before** the sync" to
  remove exactly this collision; these two copies kept the old wording. (04_s3_upload.R
  lines 3-4 and 25-26 use "registration" the same way; not in the changed set.)

No bugs, no security issues, nothing that loses data. Every command in a fenced block or
heredoc runs as written (two of them measured above).

## Enumeration: every command and factual sentence about stacs / the test / the toml

T = true against v0.1.1; F = false; P = partly (true for the case shown, false in
another). Source lines are v0.1.1 unless they name a file in this repo.

### CLAUDE.md (above the marker)

| # | line | claim | verdict | source |
|---|---|---|---|---|
| 1 | 27-28 | registered into pgstac with stacs | T | register.py:8-11 (ssh + `pypgstac load`) |
| 2 | 55-56 | `05_stac_register.py` runs before the sync; pgstac registration after | T | run_pipeline.sh:55-60, heredoc 64-75 |
| 3 | 77-79 | stacs pinned to a tag in environment.yml | T | environment.yml:23 `@v0.1.1` |
| 4 | 79-81 | stacs.toml declares API, collection id, bucket, required `thumbnail`, STAC host `root@geopro` over the tailnet | T | stacs.toml:11-13,18,30 |
| 5 | 81-83 | the test pins collection id, bucket and asset key to `05_stac_register.py` | T | test_stacs_config.py:68-77; mutation above |
| 6 | 82-83 | API and host are in no module, so only a live run checks them | T | no `a11s`/`geopro` in 05_stac_register.py (grep); `--dryrun` skips both probes (register.py:461-474) |
| 7 | 85 | `stacs register --config stacs.toml --mode all` | T, runs | cli.py:293-300; dryrun measured |
| 8 | 86 | `stacs verify --config stacs.toml` | T, runs | cli.py:286-291 (no `--mode`; transport not needed, cli.py:167) |
| 9 | 88 | register fetches the published `collection.json` and every item it links | T | register.py:414-419, 455, 480 |
| 10 | 88-90 | audits them (collection id, thumbnail on each, no id twice) before anything is written | **P** | all: register.py:456,555 audit every id; drift: only `todo` (548-556). Finding 2 |
| 11 | 90 | upserts the collection and then the items | T | register.py:565-568 |
| 12 | 90 | checks the API serves what was sent | T | register.py:571-606 |
| 13 | 91 | Nothing is deleted | T | register.py:3; `--method upsert` only (264) |
| 14 | 91 | `--mode all` re-sends every item | T | register.py:456 `todo = sorted(by_id)` |
| 15 | 91-93 | drift sends only items the API lacks or serves with a different body, with the collection | T | register.py:505 `missing ∪ changed`; 565 collection load whenever anything is sent; 543-545 nothing sent when in sync |
| 16 | 92 | the body digest is over canonical JSON | T | verify.py:291-313 (RFC 8785, `links` dropped, nulls dropped) |
| 17 | 93 | so drift refreshes items a rebuild rewrote | T | `changed` = digest differs (verify.py:358); airphoto round trip measured IN SYNC (stacs evidence `20261006_parity_stacs_airphoto.log`) |
| 18 | 95 | verify compares every body in both directions | T (loosely: id sets both ways, bodies on the intersection, plus the collection) | register.py:494-505, 523-528 |
| 19 | 95-96 | unlike register, verify fails on orphans | T | register.py:517-522 (verify rc=1); 590 "Orphans are not this run's failure"; drift ignores `orphaned` |
| 20 | 96-97 | `--dryrun` on `--mode all` reads only collection.json, probes neither API nor host | T | register.py:461-467 return before 472-474; measured |
| 21 | 98-100 | rtj's `stac_register-pypgstac.sh` deletes then reloads | not stacs; unchanged claim | — |
| 22 | 292-293 | Known issues: `stacs register --config stacs.toml --mode all` | T, runs | cli.py:297 |

### scripts/README.md

| # | line | claim | verdict | source |
|---|---|---|---|---|
| 23 | 67 | `test_stacs_config.py` pins stacs.toml to `05_stac_register.py` | T | test:68-77 |
| 24 | 67 | ... and the installed stacs to its tag | T | test:49-55 (`__version__` + `requested_revision`) |
| 25 | 67 | ... and runs `stacs audit` over items shaped like ours | T | test:116-125 `stacs_main(["audit", ...])` |
| 26 | 98-100 | re-register with `stacs register --config stacs.toml --mode all` | T, runs | cli.py:297 |
| 27 | 222 | Python env has stacs at the tag environment.yml pins | T | environment.yml:23 |
| 28 | 223 | tailnet ssh to `root@geopro` with a key that logs in non-interactively | T | register.py:278 `BatchMode=yes` |
| 29 | 223 | stacs runs here and loads through `pypgstac` on the host | T | register.py:263-264, 319 |
| 30 | 223 | the database password stays on the host | T | register.py:257-262 (`password_env` expanded remotely, no `--dsn`) |
| 31 | 228 | register after the S3 sync, from the repo root | T | config path is relative |
| 32 | 231-232 | the two commands | T, run | as #7, #8 |
| 33 | 235-236 | stacs.toml declares API, collection id, bucket, thumbnail, host | T | stacs.toml |
| 34 | 237 | register reads the published collection.json, fetches every item it links | T | register.py:414-480 |
| 35 | 238-239 | audits all of them (collection id, thumbnail, no id twice) before the database | **P** | as #10. Finding 2 |
| 36 | 239-240 | upserts collection then items, checks the API serves the bodies it sent | T | register.py:565-606 |
| 37 | 240 | Nothing is deleted | T | as #13 |
| 38 | 242 | `--mode all` re-sends every item | T | as #14 |
| 39 | 242-244 | drift compares each published body with the API's by digest, sends the collection and only missing + different items, so it refreshes rewritten items | T | as #15-17 |
| 40 | 245-247 | verify makes the same comparison in both directions, changes nothing, is the one that fails on orphans | T | register.py:398 `writes = mode != "verify"`; 507-533 |
| 41 | 247-248 | `--out-dir` writes the id lists | T | register.py:507-512 (missing/orphaned/changed + collection_state.txt) |
| 42 | 248-249 | `--dryrun` on `--mode all` reads collection.json only, probes neither | T | as #20 |
| 43 | 251-253 | a collection.json listing only the newest AOI would register just that AOI, and verify would report the rest orphaned | T | register.py:455-456 (published set = links); verify.py:221-238 orphaned = registered − published |
| 44 | 260 | registering loads into the PostgreSQL behind the API | T | register.py:8 |
| 45 | 271-272 | conda recipe `pip install ... "stacs @ git+...@v0.1.1"` | T, runs | conda 26.3.2 keeps the argument whole; pip resolves (measured); repo public |
| 46 | 275-276 | the tag here and in environment.yml must agree; the test fails when they do not | T | test:58-65; mutation above |

### scripts/run_pipeline.sh

| # | line | claim | verdict | source |
|---|---|---|---|---|
| 47 | 16 | "Registration runs BEFORE the S3 sync" | **P** (true of `05_stac_register.py`; contradicts line 65's pgstac registration) | Finding 3 |
| 48 | 65-66 | from the repo root; stacs reaches the STAC host (`root@geopro`) over ssh | T | register.py:278; stacs.toml:30 |
| 49 | 66 | upserts only and deletes nothing | T | as #13 |
| 50 | 68-69 | the two commands | T, run | as #7, #8 |
| 51 | 71-73 | drift compares bodies, sends the collection and only items lacking or different, which includes every item this run rebuilt | T in effect (an item rebuilt byte-identically is not sent, and needs no sending) | register.py:505, 565 |
| 52 | 73-74 | verify follows register because only verify fails on orphans | T | as #19 |

### scripts/06_catalogue_promote.sh

| # | line | claim | verdict | source |
|---|---|---|---|---|
| 53 | 34-37 | `stacs register` reads the published collection.json that 04 syncs | T | register.py:414-418 (`bucket_url/collection.json`) |
| 54 | 108-109 | register to make searchable; upsert, nothing deleted | T | as #13 |
| 55 | 109 | from the repo root; stacs reaches the STAC host over ssh | T (script itself `cd "$REPO_ROOT"`, line 46) | register.py:278 |
| 56 | 111-112 | the two commands | T, run | as #7, #8 |
| 57 | 114 | `--mode all` because the backfill rewrote every item it touched | T (drift would also catch them; all is the safe choice) | — |
| 58 | 115 | verify compares every body with what the API serves, so it confirms the new properties landed | T | properties are in the digest (verify.py:309, only `links` excluded) |

### stacs.toml

| # | line | claim | verdict | source |
|---|---|---|---|---|
| 59 | 2 | `stacs register\|verify\|audit --config stacs.toml` | **F as a command** (register exits 2; audit waits on stdin) | Finding 1; cli.py:297, 159 |
| 60 | 4-5 | collection id in `COLLECTION_ID`, bucket URL in `S3_BASE`, asset key in `ASSET_THUMBNAIL` | T | 05_stac_register.py:71, 79, 73 |
| 61 | 6 | the test fails if the two disagree | T | test:68-77; mutation |
| 62 | 8 | no setting is a secret; the password stays on the host, named by `password_env` | T | cli.py:29-35 refuses `password`; register.py:257-262 |
| 63 | 16-17 | every item carries its thumbnail COG; `visual` and metadata assets only where they exist | T | 05_stac_register.py:205 (always), 217 (`visual` conditional) |
| 64 | 21 | host shared with stac_dem_bc: same machine, database and loader | T | stac_dem_bc `origin/main:stacs.toml` [transport] identical |
| 65 | 22 | MagicDNS over the tailnet, root-only (rtj#193) | T | rtj#193 body: `/root/.ssh/authorized_keys`, no user account |
| 66 | 23-24 | reserved IP is the same machine: `stacs register --config stacs.toml --host root@146.190.12.8 --mode all` | T, parses | cli.py:263 `--host`; `dig images.a11s.one` = 146.190.12.8 |
| 67 | 25-34 | the transport keys | T, accepted | cli.py:32-33 `CONFIG_KEYS`; `pypgstac` a list (cli.py:123) |

### tests/test_stacs_config.py

| # | line | claim | verdict | source |
|---|---|---|---|---|
| 68 | 4-5 | each value pinned to its module, so a changed id or bucket fails | T | test:68-77 |
| 69 | 7-9 | audit tests run the installed CLI in process; drop `require` and the missing-thumbnail test goes red | T | measured (4 red) |
| 70 | 23-24 | hard import: an env without stacs fails, not skips | T | `import stacs` at module level → collection error |
| 71 | 40-41 | `read_config` refuses unknown tables and keys | T | cli.py:51-59 |
| 72 | 50-52 | `__version__` is pyproject's, so a later commit reads the same; `direct_url.json` records the requested revision | T | `__init__.py` `version("stacs")`; measured `requested_revision: v0.1.1` |
| 73 | 59-61 | environment.yml and the README recipe each install stacs; every pin, whole; a substring test would pass `v0.1.10` | T | regex anchors on `[0-9A-Za-z]` end; mutation `v0.1.10` red |
| 74 | 81-82 | the fence is stacs' refusal of unknown keys | T | cli.py:56-59 |
| 75 | 87-88 | every ConfigError carries the file path; tmp_path is named after the test | T for `read_config`'s errors, the only ones reachable here (cli.py:50-59); not every ConfigError in cli.py (merge_asset_rules' do not). Harmless | pytest truncates to 30 chars, still contains "password" |
| 76 | 98 | `_item` is the shape 05 writes, reduced to what the audit reads | T | validate.py:177-195 reads id, collection, assets |
| 77 | 117-118 | `_audit` is the CLI's own entry point, in process | T | cli.py:331 `main(argv)` |
| 78 | 135-136 | bad item in the middle of the order stacs reads (sorted names) | T | validate.py:94-109 `sorted` |
| 79 | 141 | "1 item(s)" says the good ones were not flagged | T | validate.py:198-205 count of hits |
| 80 | 157 | another collection id on the command line does not drop `require` | T | cli.py:225 `merge_asset_rules` independent of `--collection-id` |

### environment.yml, 05_stac_register.py

| # | line | claim | verdict | source |
|---|---|---|---|---|
| 81 | env 9 | 3.11 is stacs' floor | T | pyproject `requires-python = ">=3.11"`; cli.py imports `tomllib` |
| 82 | env 20-22 | pinned to a tag; the test also pins it, so a bump here alone fails | T | test:30, 49-65; mutation |
| 83 | 05:72 | the asset every item carries; stacs.toml requires it; tests pin the two | T | 05:205; stacs.toml:18; test:76-77 |

Count: 83 claims. 79 T, 3 P (#10, #35, #47), 1 F-as-command (#59). The P and F rows
are the three findings above. Nothing else in the eight places disagrees with v0.1.1.
