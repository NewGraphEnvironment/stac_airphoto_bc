# Task: Carry the catalogue metadata on items, including whether a photogrammetric solution exists (#21)

Items in `stac-airphoto-bc` carry 11 curated properties. The BC Data Catalogue row
behind each frame carries **29 columns**, and several of the omitted ones are
load-bearing: `georef_metadata_ind`, `patb_georef_url`, `media`,
`ground_sample_distance`, `camera_calibration_url`, `bcgs_tile` / `nts_tile`.

Two consequences today:

1. Anything that regenerates georeferencing has to go back to `bcdata` for fields the
   collection could simply carry. The STAC item describes the *output* but not the
   inputs that produced it.
2. "Which frames have a photogrammetric solution?" is a `georef_metadata_ind` filter,
   and today it needs a WFS query against a different service and a join.

## Decisions taken at the plan gate

- **Link** the PAT-B / calibration / flight-log files as `metadata`-role assets; do not
  parse their contents. Every QA filter named is a catalogue column promoted here; the
  per-frame exterior orientation inside PAT-B is an input to a corrected footprint (#23),
  not a query surface.
- Field set = the issue's six **plus `flight_log_url`** as a third metadata asset.
- Add `airphoto:media` alongside `airphoto:footprint_basis` despite today's identical
  values — `media` is the catalogue's fact, `footprint_basis` is fly's sizing basis.
- Backfill all 9,976 published items in this issue.

Reference implementation: `stac_orthophoto_bc/scripts/item_cog_backfill.py`
(that repo's #6 — this repo's #6 is unrelated; see findings.md).

## Phase 1: Shared property/asset module, tests first

- [x] Add `pytest` to `environment.yml` and install into the conda env
- [x] Write `tests/test_airphoto_props.py` — failing, before the module exists
- [x] Write `scripts/airphoto_props.py`: `catalogue_properties()`,
      `georef_metadata()`, `catalogue_assets()`
- [x] `pytest tests/ -q` green

## Phase 2: Wire into item generation

- [x] Widen the `meta_by_id` key tuple in `05_stac_register.py`
- [x] Replace the inline property loop with the shared module; keep `footprint_basis`
- [x] Merge `catalogue_assets()` into the assets dict
- [x] Report the count of `georef_metadata_ind` values that were neither `Y` nor `N`
- [x] Dry run to `/tmp/dry21`; diff **all 235** items, not a sample — new keys
      present, nothing pre-existing changed or dropped

## Phase 3: Catalogue rows for the published items

- [x] `scripts/06_catalogue_fetch.R` — item ids from the published `collection.json`,
      batched `AIRP_ID %in%` query, writes `data/catalogue/published.parquet`
- [x] Reconcile requested vs returned ids; refuse on a shortfall
- [x] Measure and record the `georef_metadata_ind` x `patb_georef_url` cross-tab over
      all 9,976 rather than assuming the diagonal measured on 2,671

## Phase 4: Backfill the published items

- [x] `scripts/06_catalogue_backfill.py` — threaded, timed-out, writes to
      `--out-dir`, `--limit` for smoke runs
- [x] `scripts/06_catalogue_validate.py` — seven guards: COUNT, BOOLEAN,
      DIAGONAL, VALUES, SENTINEL, ADDITIVE, SCHEMA
- [x] Smoke run `--limit 50`, validator over it
- [x] Full run over 9,976; validator green
- [x] Restore each defect in turn and confirm the *specific* guard message fires

### Fixed after the plan review (see findings.md)

- [x] **`ground_sample_distance == 0` is a sentinel, not a measurement** — 473
      items, every one digital, smallest real value 12 cm. Omitted, with a
      SENTINEL guard counting straight off the raw column.
- [x] **`.OR` is a fourth PAT-B spelling** — 24 assets shipped with no media
      type because the map was written from three AOIs that contain none.
- [x] Batch-size comment named URL length; `bcdata` POSTs. Real ceiling measured
      at 1,000 OK / 1,050 FAIL.
- [x] "Additive only" was a comment, not a check — now stated as what the
      ADDITIVE guard enforces, with the measurement beside it.
- [x] Validator warns `VACUOUS` when a guard could not have failed on the set it
      was given.

## Phase 5: Promote, sync, register, document

- [x] `scripts/06_catalogue_promote.sh` — validate, promote, regenerate,
      **validate the promoted tree**, sync. The gate must run on the bytes that
      ship, not only on `--out-dir`.
- [x] Re-running `05_stac_register.py` before the sync is what keeps a stale
      local `collection.json` from being pushed over the published one
- [x] Verify a published item over HTTPS carries the new properties and assets
- [x] Docs: CLAUDE.md, README.Rmd (+ rebuild README.md), scripts/README.md
- [x] Correct the issue body's stale "#6" pointer and its wrong-case tile example
- [ ] Hand over the geopro pypgstac reload (destructive; not automated) with the
      CQL acceptance query that proves the point of the issue

## Validation

- [x] Tests pass
- [x] `/code-check` clean on each commit
- [x] PWF checkboxes match landed work
- [ ] `/planning-archive` on completion

## Non-goals

- Parsing PAT-B contents (belongs with #23)
- New GDAL tags on COGs — `03_cog_tag.py` is untouched
- Changing the ledger CSV schema in `01_fetch.R`
- Per-AOI sub-extents or any other collection-extent change
