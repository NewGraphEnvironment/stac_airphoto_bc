## Outcome

`01_fetch.R` built the ledger with `transmute(aoi_id = id, ...)`, and data masking
resolved `id` to the catalogue's own `id` column, so every `data/select/<id>.csv` carried
WFS feature ids in `aoi_id`. Fixed with `aoi_id = !!id`, plus a runtime guard,
`aoi_ledger_check_id()`, called in `aoi_ledger_write()` before the write and on
`02_georef.R`'s read before any work (read with `aoi_id` as character). The on-disk
ledgers were repaired in place. The learning is in the review: three `/code-check`
rounds found that the wiring tests kept assuming their locator was present and that a
name's presence was its call's position. The terminal form asserts the check CALL sits
before every file-touching call, with every anchor required to be found.

## Measurement

Before: distinct `aoi_id` values per ledger = row count, all feature ids —
`neexdzii_kwa` 14,858, `se_a` 818, `se_b` 840, `se_c` 1,013. After the repair: one value
per file, the AOI id; header, row count and every other column byte-identical
(`cut -d, -f2-`). No published item and no tracked report changed; nothing read `aoi_id`.

Mutation tables (in `progress.md`): 13 mutations over the fix and its wiring, all red
except `.env$id` (accepted spelling) and dropping `is.na()` (equivalent mutant: `vals[NA]`
is NA). Review round 2 found two placements the round-1 test passed (anchor absent →
`Inf`; check moved after `unlink()`), round 3 one more on the writer (call after
`write_csv()`, or a bare symbol).

Closed by: PR (see branch `32-the-ledger-s-aoi-id-holds-wfs-feature-i`)
