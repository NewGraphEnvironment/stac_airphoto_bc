## Outcome

pgstac registration moved from stac_dem_bc's shell scripts to the `stacs` package, pinned
at `v0.1.1` in `environment.yml` and in the conda recipe in `scripts/README.md`. The
registration this repo documented was already broken when the work started.
stac_dem_bc#49 had deleted `catalogue_register.sh` from that repo's `main`, and
`06_catalogue_promote.sh` carried a second copy of the same block.

The catalogue now declares itself in `stacs.toml`: API, collection id, bucket, the
required `thumbnail` asset, and the geopro transport (the same values as stac_dem_bc's).
`tests/test_stacs_config.py` pins three of those to `05_stac_register.py`: the collection
id, the bucket and the new `ASSET_THUMBNAIL` constant. It also checks that the install
came from the tag, and runs `stacs audit` in process. Both scripts now print
`stacs register --mode all` then `stacs verify`. The old note that drift never refreshes
rebuilt items is corrected.

What was learned:
- `--mode all --dryrun` returns before both the API probe and the ssh probe, so it proves
  less than `verify`. Only `--mode drift` run without `--dryrun`, against an in-sync API,
  exercises the probes and still writes nothing.
- The review loop's defects were all prose. The same facts about stacs were restated in
  eight places, written from memory rather than from the source. "Registration" also
  changed meaning in this branch: it now names pgstac registration as well as item
  generation. Round 3 enumerated every one of the 83 claims against the v0.1.1 source.

## Measurement

Live, read-only, 2026-10-07, with the committed `stacs.toml`:
- `stacs audit --dir data/stac --expect 10100`: OK, 2.5 s. This proves this machine's
  tree only.
- `stacs verify`: IN SYNC, 10,100/10,100, 0 missing / orphaned / changed, collection
  `same`, 1m11s. The verify line the script prints, run verbatim: IN SYNC, exit 0.
- `stacs register --mode drift`: the API probe and the ssh probe to `root@geopro` passed,
  nothing to register, 1m07s, no write.
- **Not exercised:** the remote `pypgstac` load path. The first real `--mode all` is its
  first live test, here and for stac_dem_bc.

Review loop:
- A plan review folded in five changes, including the second heredoc.
- Code-check ran three rounds:
  - Round 1: Clean.
  - Round 2: three doc errors.
  - Round 3: three doc errors, found by the 83-claim enumeration.
- No defect sat inside a previous fix. The loop ended on the enumeration.

## Evidence

Reviews: `review-*.md` in this directory. The live-check output is in `findings.md`; no
logs were committed.

Closed by: PR (see `/gh-pr-push`), commits 5e17e70, 35dcf87, 1abe872
