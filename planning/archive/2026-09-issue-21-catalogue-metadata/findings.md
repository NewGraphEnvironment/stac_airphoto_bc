# Findings — Carry the catalogue metadata on items (#21)

## The precedent is in another repo

Issue #21's body says the change is "the same way #6 promoted `cog` from an asset field
to a queryable item property". **This repo's #6 is "Initialize CLAUDE.md."** The real
pointer is
[stac_orthophoto_bc#6](https://github.com/NewGraphEnvironment/stac_orthophoto_bc/issues/6),
whose implementation is `~/Projects/repo/stac_orthophoto_bc/scripts/item_cog_backfill.py`
— a standalone patcher over published item JSONs that writes only to `--out-dir`, takes
`--limit` for smoke runs, and errors on a partial write. That shape is what Phase 4
follows. The issue body is corrected in Phase 5.

## All 29 catalogue columns are already on disk

`01_fetch.R:52-63` collects the whole WFS row with no `select()` and caches it:

```r
raw <- bcdata::bcdc_query_geodata(BCDC_CENTROIDS) |>
  bcdata::filter(INTERSECTS(aoi_buf)) |>
  bcdata::collect()
names(raw) <- tolower(names(raw))
raw |> sf::st_drop_geometry() |> arrow::write_parquet(tmp)
```

`data/centroids/se_a.parquet` carries 29 columns; `data/selected/se_a.parquet` carries
33 (the same plus `year`, `era`, `rotation`, `footprint_basis`). Only the **ledger CSV**
is subset, by the `transmute` at `01_fetch.R:89-103`.

So nothing was missing upstream. `05_stac_register.py:128-132` lifts a hardcoded
10-key tuple into `meta_by_id` and promotes five of them at `:200-203`. Widening that
tuple is the whole of the generation-side change.

## Column measurements — three southeast caches, 2,671 ROWS (2,002 distinct frames)

These are row counts, not frame counts: the three AOIs overlap and
`centroids.py` concatenates rather than dedupes, so 669 `airp_id`s appear twice.
They are superseded by the population measurement further down, and are kept
because they are what the first version of the media-type map was built from —
which is how it missed `.OR`.

| column | measured |
|---|---|
| `georef_metadata_ind` | 0 nulls, 2 distinct: `N`=2331, `Y`=340 |
| `patb_georef_url` | 2331 null / **340 non-null** — perfectly diagonal against the flag |
| `camera_calibration_url` | 2346 null / 325 non-null, all `.zip` |
| `flight_log_url` | 342 null / 2329 non-null (87%), all `.jpg` |
| `ground_sample_distance` | 903 null / 1768 non-null (66%) |
| `media` | 3 values: `Film - BW` 1687, `Film - Colour` 729, `Digital - Colour` 255 |
| `bcgs_tile` | 0 nulls, 70 distinct |
| `nts_tile` | 0 nulls, 6 distinct |
| `published_ind` | 0 nulls, **1 distinct** (`Y`) — carries no information; not promoted |

The diagonal is the fact the issue rests on and it holds here. It is measured again
collection-wide in Phase 3 rather than assumed — 2,671 rows from three small AOIs is
not the population.

### Metadata URL extensions, which fix the asset media types

| column | ext | n | example |
|---|---|---|---|
| `camera_calibration_url` | `.zip` | 325 | `.../calib_report_zips/13181_2001.zip` |
| `flight_log_url` | `.jpg` | 2329 | `.../logbooks/1972/roll_pages/bc7433_2.jpg` |
| `patb_georef_url` | `.zip` | 240 | `.../patb_files/d_002_fi_16_georef.zip` |
| `patb_georef_url` | `.ori` | 85 | `.../patb_files/82fg_ln01_13.ori` |
| `patb_georef_url` | `.csv` | 15 | `.../patb_files/d_003_fi_11_georef.csv` |

Three PAT-B formats, exactly as the issue warned. The flight log is a **scan of a
logbook page**, not structured data — an `image/jpeg` with a `metadata` role.

## `media` and `airphoto:footprint_basis` are identical today

Cross-tabbed over all 295 selected frames in `data/selected/*.parquet`:

```
214  ('Film - BW',     'Film - BW')
 81  ('Film - Colour', 'Film - Colour')
```

No off-diagonal. `footprint_basis` only diverges for digital frames, which come back
`unknown_format` and are all rejected (`01_fetch.R:97-98`, fly#32). Both are carried
anyway: `media` is what the catalogue says the film or sensor was, `footprint_basis` is
what `fly` used to size the footprint, and they separate the moment digital frames are
supported. The 9,741 published Neexdzii Kwa items carry **no** `footprint_basis` at all
— it postdates them — so `media` is the only media fact the backfill can give them.

## The backfill is the substantial half

- Published `collection.json` carries **9,976 item links**.
- Locally: **236** item JSONs (235 items + collection) and three southeast AOI caches.
- The 9,741 Neexdzii Kwa COGs and the `neexdzii_kwa` centroid cache are gone from this
  machine (`data/` is gitignored).

`build_items()` is COG-driven — it globs `data/stac/thumbs/**/*.tif` — so a re-run
regenerates 235 items and merges *links* for the other 9,741. Their item JSONs are never
rewritten. The only route is to fetch each published item JSON and patch it.

Their catalogue rows are re-queried **by `airp_id`** rather than by re-resolving the
watershed: `neexdzii_kwa` is `type = "watershed"` and `aoi_resolve()` needs
`fresh::frs_db_conn()` and a live Postgres host. Item ids *are* `airp_id`s, so querying
by id both drops that dependency and gives an exact denominator to reconcile against.

## A published item today, for comparison

`https://stac-airphoto-bc.s3.us-west-2.amazonaws.com/695106.json`:

```json
"properties": {
  "proj:epsg": 3005, "proj:bbox": [...], "proj:shape": [...], "proj:transform": [...],
  "airphoto:scale": "1:31680", "airphoto:focal_length": 153,
  "airphoto:flying_height": 5944, "airphoto:film_roll": "bc5281",
  "airphoto:frame_number": 84,
  "title": "695106 — bc5281_84 — 1968-05-09", "datetime": "1968-05-09T00:00:00Z"
}
"assets": ["thumbnail"]
```

No `footprint_basis`, one asset. `stac_version` 1.1.0 (from pystac, never set
explicitly). One extension declared, `projection/v1.1.0`. `airphoto:` is a bare
namespace with no schema — fine for pgstac `query` / CQL2, but nothing validates it.

## Environment

`pytest` and `requests` are both absent from the `stac-airphoto-bc` conda env. `pytest`
is added in Phase 1; `requests` is not needed — `05_stac_register.py` already uses
`urllib.request` and the backfill follows it.

## The diagonal, measured on the population (2026-09-07)

The issue asserts `georef_metadata_ind` and `patb_georef_url` are exactly
equivalent. That was measured here on 2,671 rows from three small AOIs, which is
not the population. `06_catalogue_fetch.R` re-measured it over all **9,976**
published items:

```
                   has_patb_url
georef_metadata_ind FALSE TRUE
                  N  8201    0
                  Y     0 1775
off-diagonal rows: 0
georef_metadata_ind neither Y nor N: 0
```

Perfectly diagonal, and the flag is 100% populated with `Y`/`N`. So:

- `airphoto:georef_metadata` can be asserted **present on every item** by the
  validator — a missing one is a defect, not an expected absence.
- `patb_georef` asset present iff `georef_metadata` is true is a real invariant
  over this collection, not an assumption carried from a subset.
- 1,775 of 9,976 frames (17.8%) have a photogrammetric solution — higher than the
  12.7% measured on the southeast AOIs alone.

The catalogue query by `airp_id` reconciles exactly: 9,976 requested, 9,976
returned, 0 missing, 0 unasked-for. `bcdata::filter(AIRP_ID %in% ids)` translates
to a CQL `IN`; batches of 200, 500 and 1000 each returned exactly what was asked
for in 1.2-1.6 s. The full run is 20 batches in 24 s.

## Plan review, and the two defects it caught (2026-09-07)

A `Plan` subagent reviewed the task plan against the issue and the tree. Both
blockers were verified independently before acting on them, and both were real.

### `ground_sample_distance == 0` is a sentinel

Measured over all 9,976 published rows:

| value | n | media |
|---|---|---|
| positive (12-97) | 7,336 | film and digital |
| null | 2,167 | film only |
| **zero** | **473** | **`Digital - Colour` only** |

Zero occurs on no film frame, and the smallest real value is 12. The catalogue's
own column comment says the field is *"the distance on the ground in centimetres
represented by a single pixel"* — 0 cm is not a value any sensor produces.

The null guard could not see this. It fires on the 2,167 honest nulls and misses
every instance of the thing it exists for, which is the worse half: an absent key
sends a consumer elsewhere, a published `0` satisfies `is not None` and reads as
a measurement. `fly` sizes digital footprints from GSD, so the consumer that
matters most would have taken it. `pystac` cannot catch it either — `airphoto:`
has no schema, and an item carrying `0` validates clean.

Fixed with `ZERO_IS_MISSING` in `airphoto_props.py`, and pinned by a **SENTINEL**
guard that counts nulls-and-zeros straight off the raw column. That guard exists
because the VALUES guard runs both sides through `catalogue_properties()`, so a
bug inside that function moves both sides together and VALUES cannot see it.

### `.OR` is a fourth PAT-B spelling

`patb_georef_url` suffixes over 9,976 rows: `.ori` 505, `.ORI` 226, `.zip` 547,
`.csv` 473, **`.OR` 24**. The issue body, this file and the first version of the
media-type map all said *three* formats — a count taken from 2,671 rows across
three southeast AOIs, which contain no `.OR` at all. 24 assets shipped with no
media type.

The test that was meant to cover case-insensitivity parametrised `A.ORI`. That is
a real spelling (226 rows) and it was already handled; varying the case of a
suffix that works does not test the suffix that does not. Both `.OR` and a real
`93BCFGJK.OR` URL are now in the parametrised set.

### Other review findings folded in

- The batch-size comment claimed a URL-length limit. `bcdata` **POSTs** the CQL
  form-encoded, so the constraint is body size. Measured ceiling: 1,000 ids OK,
  1,050 fails loudly on the `resultType=hits` probe. 500 keeps ~2x headroom, not
  the open-ended margin the comment implied.
- "Additive only" was asserted in a docstring while `dict.update()` can overwrite
  the five properties published items already carry. It is now stated as what the
  ADDITIVE guard checks, with the measurement (0 changes over 9,976) beside it.
- `--limit N` takes the first N links in href order, and the first item with a
  photogrammetric solution is at index **1915** — so any smoke run below that has
  0 true, 0 `patb_georef` and 0 `camera_calibration`, and the DIAGONAL guard
  compares two constants. The validator now prints `VACUOUS:` when a guard could
  not have failed on the set it was given.
- `HEAD` on `openmaps.gov.bc.ca` returns **404** for URLs that a ranged `GET`
  serves 206 for, including flight logs `fly::fly_fetch()` downloads
  successfully. Any liveness probe on these assets must not use `HEAD`.

### The metadata assets are many-to-one

| column | items | **distinct URLs** |
|---|---|---|
| `patb_georef_url` | 1,775 | **12** |
| `camera_calibration_url` | 1,302 | **10** |
| `flight_log_url` | 8,133 | 198 |

A PAT-B file is a shared bundle covering a whole block, not a per-frame record —
1,775 items point at 12 files. The href does not identify which record inside the
file belongs to this frame. That does not affect linking, and it is exactly the
join #23 will have to solve.

### Casing is the catalogue's own convention, not a defect

`bcdc_describe_feature` documents `BCGS_TILE` as e.g. `104a01414` (lowercase, and
1:20,000 / 1:10,000 / 1:5,000 resolutions share the column — 548 seven-character
and 9,428 nine-character values) and `NTS_TILE` as `104A03` (uppercase). The
issue body's `"093L047"` example is upper-case and matches nothing. pgstac `=`
is case-sensitive, so this is recorded in `scripts/README.md`.

### One correction to the review

It suggested the "1000 ids returns exactly what was asked for" measurement was
taken against a list holding only 818 real ids. It was not — the probe read
9,976 real published ids and sliced the first 1,000. The review's own independent
measurement agrees (1,000 OK). What was wrong in that comment was the
*mechanism*, not the number.

### A note on the two-producer key order

The generator builds assets through `pystac.Asset` and serialises
`href, type, title, roles`; the backfill emits `href, title, roles, type`. Same
values, different bytes. Do not write a byte-equality check between the two
producers — compare parsed content. `06_catalogue_promote.sh` runs the generator
last so each item has exactly one producer.

## Errors Encountered

| Error | Resolution |
|-------|------------|
