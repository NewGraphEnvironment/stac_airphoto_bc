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

## Column measurements — three southeast caches, 2,671 rows

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

## Errors Encountered

| Error | Resolution |
|-------|------------|
