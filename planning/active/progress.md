# Progress — The ledger's aoi_id holds WFS feature ids, not the AOI id (#32)

## Session 2026-09-27

- Plan-mode exploration — phases approved by user
- Created branch `32-the-ledger-s-aoi-id-holds-wfs-feature-i` off main
- Scaffolded PWF baseline from issue #32 with approved phases
- Next: start Phase 1
- Phase 1: tests written. `Rscript tests/test_aoi.R` → 7 new assertions fail (the
  parse pair on the bare `aoi_id = id`; `aoi_ledger_check_id()` absent). The mix / NA /
  missing-column refusals pass vacuously until the function exists — the Phase 2
  mutation run is what proves them.
- Phase 2: `aoi_id = !!id`; `aoi_ledger_check_id()` called from `aoi_ledger_write()` and
  02_georef.R's read; wiring asserted from the parse tree. Probe: `transmute(d, id)` over a
  frame with an `id` column gives the feature id, `!!id` the loop value.
  Mutation table (copy of scripts/, tests/, data-raw symlinked; tree `shasum`-checked after):
  bare `id` red · `.env$id` green (accepted spelling) · missing-column guard removed red ·
  stop removed red · writer call dropped red · 02 read call dropped red · remedy dropped
  red · value dropped red · `is.na()` dropped **green** — equivalent mutant, `vals[NA]` is
  NA so an NA is refused either way; kept for readability.
- Mistake: a stray `git checkout -- .` in the mutation command reverted the uncommitted
  Phase 2 edits. Recovered the test from the mutation copy and re-applied the script edits
  verbatim; suite green after.
- Plan review (background, Plan agent): wiring gap (already closed), numeric-looking AOI
  id would be guessed as double on 02's read → `col_types = cols(aoi_id = "c")`,
  `scripts/README.md` lists the writer's checks → updated. Repair via `readLines`/`sub`.
- /code-check, three rounds (review-round{1,2,3}.md):
  1. Clean; noted "on the read" test only checked presence.
  2. Two defects inside that fix: absent `fly_georef` anchor → `Inf` passes any placement;
     anchoring on `fly_georef` alone lets the check move after `unlink()` of stale
     GeoTIFFs. Fixed: all anchors finite, check between `read_csv` and
     `map_dfr`/`fly_footprint`/`unlink`/`fly_georef`.
  3. Mechanism: "a locator is present, and a name's presence is its call's position".
     Enumerated every #32 assertion; one more instance — the writer test accepted the call
     after `write_csv()` or a bare symbol. Fixed with a statement-order check on real calls.
     Mutations (call after write, bare symbol, dropped, write anchor absent) all red.
  Ended by enumeration.
- Phase 3: repaired the four gitignored ledgers in place (backups in the session
  scratchpad first):
  `x <- readLines(f); x[-1] <- sub("^[^,]*", id, x[-1]); writeLines(x, f)`, after asserting
  the header starts `aoi_id,` and no field is quoted. Verified per file: row count, header,
  and `cut -d, -f2-` byte-identical; `aoi_id` now the one AOI id (neexdzii_kwa 14,858,
  se_a 818, se_b 840, se_c 1,013 rows). The guard, read as 02 reads, accepts all four and
  refuses the pre-repair se_c backup with the intended message. `data/reports/` unchanged.
  Any other machine holding pre-#32 `data/select/` needs the same one-liner or a 01 re-run.
- CLAUDE.md: dropped the #32 Known issues line (above the soul marker).
