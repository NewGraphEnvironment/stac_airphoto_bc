## Outcome

stac_dem_bc#42 made `catalogue_register.sh` register any collection. So the documented
registration became one command everywhere the repo says how: CLAUDE.md, scripts/README.md,
`run_pipeline.sh`'s closing hint and `06_catalogue_promote.sh`'s. The command is
`( export STAC_COLLECTION STAC_BUCKET_URL STAC_REQUIRE_ASSET=thumbnail; catalogue_register.sh
--all && --verify )`. Three of those places still printed the delete-and-reload
`stac_register-pypgstac.sh`. The issue asked for `--drift`. Exploration showed that
`--drift` and `--verify` diff **id sets** only, so an item a rebuild rewrote is never
refreshed and never reported. The user chose `--all` at the plan gate, and the content gap
went upstream as stac_dem_bc#45.

Code-check took three rounds and then an enumeration. Each round's best finding sat in
something added the round before. The round-3 reviewer named the mechanism: every
command had been exercised only in the state where the answer is already yes, a
reachable and in-sync catalogue. The shapes it took:
- `PYTHON=` naming a directory, which passes `[ -x ]`.
- Exported variables leaking into a later DEM run.
- A `/search` check that could not fail.
- Its replacement, a one-item API-vs-S3 check that passed on `null == null` offline and
  always sampled the same item.
- Trailing comments that break a zsh paste.

The spot-check was removed rather than hardened, because a doc snippet cannot fix a tool
that does not compare content. The misleading "run from the repo root" error went
upstream as stac_dem_bc#44.

## Measurement

- `audit-items --require-asset thumbnail --expect 10100` over the 10,100 local items: OK.
  With `dem` required instead: FAIL on all 10,100, so the check fires.
- Live `--verify` with the documented env: `asset audit: require=thumbnail`, 10,100
  published, 10,100 registered, 0 missing, 0 orphaned. It took 14 s.
- The documented block, run verbatim under bash and under zsh with `nointeractivecomments`:
  - with `--dryrun`: exit 0, 10,100 would be fetched, IN SYNC;
  - against a nonexistent bucket: exit 22, and `--verify` is skipped;
  - variables do not leak out of the subshell.
- API vs S3 `properties`: equal on 30 of 30 sampled items, and a tampered copy compares
  false. This was the measurement behind the spot-check that was later removed.
- The API returns `numberMatched: null`. Before this change, the promote script told the
  operator to expect 1775 from it.

Closed by: PR (this branch, `33-register-with-catalogue-register-sh-drif`)
