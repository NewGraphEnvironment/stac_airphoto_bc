# Review round 2 — #42 cumulative branch diff (Phase 1 + staged Phase 2)

Scope: environment.yml, scripts/05_stac_register.py, stacs.toml, tests/test_stacs_config.py,
scripts/run_pipeline.sh, scripts/06_catalogue_promote.sh, scripts/README.md, CLAUDE.md
(above the soul marker). Every claim about stacs was checked against
`~/Projects/repo/stacs` at `v0.1.1` (`src/stacs/{cli,register,verify,validate,catalogue}.py`,
`pyproject.toml`).

Verdict: nothing that breaks or loses data. Three doc sentences are wrong, all of them
minor (listed below). No code defects.

## Findings

- **[fragile]** CLAUDE.md:288-289 (Known issues, last bullet): "Register with
  `stacs register --config stacs.toml` instead". That command has no `--mode`, which
  `stacs register` requires (`cli.py`: `p.add_argument("--mode", required=True, ...)`).
  Pasted as written it exits 2 with an argparse usage error. It fails loudly and writes
  nothing, but it is the one copy of the command that does not run. Every other copy
  (CLAUDE.md Pipeline, scripts/README.md, both heredocs) carries `--mode all`.

- **[fragile]** CLAUDE.md:81 says "`tests/test_stacs_config.py` pins those values to
  `05_stac_register.py`", right after listing five values: API, collection id, bucket,
  required asset, STAC host. The test pins three of them (collection id, bucket,
  `require`). The API URL and the transport host are in neither `05_stac_register.py`
  nor the test, so a wrong `api` or `host` in stacs.toml passes the suite. stacs.toml's
  own header is accurate ("the collection id ..., the bucket URL ..., the asset key ...").
  A reader who trusts the CLAUDE.md sentence would assume the suite catches an API or
  host typo, and it does not.

- **[fragile, cosmetic]** scripts/run_pipeline.sh heredoc: "--mode drift ... refreshes
  the items this run rebuilt and sends nothing else." Drift also upserts the
  collection whenever it registers anything or the collection body differs
  (`register.py` `_run`: `load(target.transport, "collections", [coll_file])` runs
  before the items on every non-empty drift). A pipeline run always rewrites the merged
  collection, so drift does send it. This is harmless because a collection upsert is
  the intended behaviour, but the sentence is literally false. CLAUDE.md's wording
  ("sends only what the API lacks or serves with a different body") has the same gap
  if "what" is read as items only.

## Claims checked and found true against stacs v0.1.1

| claim (where) | evidence |
|---|---|
| register audits collection id, the `thumbnail` asset and "no id twice" before any write (CLAUDE.md, scripts/README.md) | `collection_item_links` raises on a repeated id; `audit_items` checks `collection`, `_is_asset(require)` and repeated ids, with `expect_ids=todo`, before the first `load`. In drift mode it audits only the items it sends. |
| "checks the API serves what was sent / the bodies it sent" | `--mode all` re-compares every published digest with `bodies_registered`; drift with an unchanged collection reads back `todo` through `bodies_serving` and compares digests |
| "Nothing is deleted" | no delete path in register.py; `--method upsert` only |
| drift = missing ∪ changed, by digest over canonical JSON | `content_diff` + `body_digest` (RFC 8785, `links` removed, null members dropped) |
| verify, unlike register, fails on orphans | verify sets rc=1 on orphaned; `all` comments "Orphans are not this run's failure"; drift ignores `orphaned` |
| `--dryrun` on `--mode all` reads only collection.json and probes neither API nor host | `_run` returns from the `mode in ("all","ids")` dryrun branch before `_api_probe` / `probe`; `build_transport` only runs the local `Transport.check()` |
| `--out-dir` writes the id lists (verify) | `cmd_verify` → `missing.txt` / `orphaned.txt` / `changed.txt` / `collection_state.txt` |
| `--host` override in the stacs.toml comment | `_transport_flags` on `register` |
| python>=3.11 floor | stacs `requires-python = ">=3.11"`; `cli.py` imports `tomllib` |
| stacs.toml transport matches the reference adoption | identical to `stac_dem_bc` `origin/main:stacs.toml` [transport] |
| `password` key refused (test) | `read_config` raises `unknown key(s) in [transport]: password` |

Heredocs in run_pipeline.sh and 06_catalogue_promote.sh are `<<'EOF'`, so the backticks
in them are printed as text. The test guards fail in the right direction: no
`direct_url.json` raises `TypeError`, a missing pin gives `[] != ["0.1.1"]`, and the hard
`import stacs` turns a missing install into a collection error. No stale reference to
`catalogue_register.sh` is left outside planning/archive.
