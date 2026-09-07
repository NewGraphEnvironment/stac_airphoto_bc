# #21 — Carry the catalogue metadata on items

Every STAC item now carries the BC Data Catalogue's own metadata as queryable
`airphoto:` properties, and the catalogue's retrievable files as `metadata`-role
assets. "Which frames have a photogrammetric solution?" is a property filter
instead of a WFS query and a join.

All 29 catalogue columns were already cached on disk — `01_fetch.R` collects the
whole row with no `select()`. The generator simply subset to a hardcoded 10-key
tuple. The substantial half was the **backfill**: 9,741 of 9,976 published items
were built on a machine whose `data/` is gone, so `build_items()` cannot
regenerate them and the merge only carries their links forward. A half-carried
collection — answering for the southeast AOIs and silently not for Neexdzii Kwa
— is worse than not answering at all, so all 9,976 items were fetched from S3,
patched and republished.

Closed by PR #25. Published, verified over HTTPS, **not yet queryable**: pgstac
still holds the old items until the geopro reload, which was deliberately left
for a human because it deletes before it reloads.

## Measurement

Over all 9,976 published items, 2026-09-07:

```
georef_metadata true       1775  (17.8%)   patb_georef asset   1775
camera_calibration asset   1302            flight_log asset    8133
ground_sample_distance present            7336   absent 2640
metadata assets with no media type           0
georef_metadata_ind x patb_georef_url  off-diagonal 0, neither-Y-nor-N 0
```

The diagonal the issue rests on was measured on 2,671 rows from three small AOIs
during planning; measuring it over the population turned an assumption into a
fact, which is what lets the validator assert `georef_metadata` is present on
**every** item rather than treating an absence as expected.

Two defects a `Plan` review caught, both verified before acting:

- **`ground_sample_distance == 0` is a sentinel, not a measurement.** 473 items,
  every one digital, against a smallest real value of 12 cm (the catalogue
  documents the column as centimetres). The `is not None` guard fired on the
  2,167 honest nulls and missed all 473 — the worse half, because an absent key
  sends a consumer elsewhere while a published `0` satisfies `is not None` and
  reads as a measurement, and `fly` sizes digital footprints from it. `airphoto:`
  has no schema, so pystac validated it clean.
- **`.OR` is a fourth PAT-B spelling.** 24 assets shipped with no media type,
  because the suffix map was written from 2,671 rows across three AOIs that
  contain none. The test meant to cover this parametrised `A.ORI` — a spelling
  that exists (226 rows) and already worked.

Both are the same shape: a fact about a third party derived from a subset and
stated as if it were the population.

## Evidence

- `findings.md` — the column measurements, the population cross-tab, the review
  findings and the one correction back to the reviewer.
- `progress.md` — phase-by-phase, with commit refs.
- `scripts/06_catalogue_validate.py` — seven guards, each with its own `FAIL`
  tag; 9/9 restore-the-bug proofs fired their own tag and the restored tree then
  validated clean. The proof harness is not committed (it mutates a hardlinked
  copy of a gitignored tree); the guards and their tags are.
- Batch-size probe: `bcdata` POSTs the CQL, so the limit is body size, not URL
  length. Measured 1,000 ids OK / 1,050 fails loudly.

## Wrong turns worth keeping

- The first VALUES guard compared each item against the **raw** catalogue column
  while the writer applied the zero-sentinel rule, so it fired on all 473 correct
  omissions. Both sides now run through `catalogue_properties()` — and because
  that makes a bug inside that function invisible to VALUES, a separate SENTINEL
  guard counts straight off the raw column.
- `--limit N` looked like a usable smoke test. Item links are sorted by href and
  the first frame with a solution is at index **1915**, so any smaller run has 0
  true, 0 `patb_georef` and 0 `camera_calibration` — DIAGONAL compares two
  constants and cannot fail. The validator now prints `VACUOUS:` rather than
  letting a green partial run read as evidence.
- The guard proofs were first run against a 50-item tree, which for the same
  reason could not reach half the branches. They were re-run against the full
  9,976.
