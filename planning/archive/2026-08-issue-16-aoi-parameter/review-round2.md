# Code review — round 2 (issue #16, AOI registry)

Reviewer: fresh-eyes agent, second pass. Read `planning/active/review-round1.md`,
`git diff HEAD~2..HEAD`, and every changed file in full. Focus was the round 1
**fixes**, not the original diff.

Every claim below was probed. Probes ran against copies in
`scratchpad/probe/` and `scratchpad/ledgerprobe/` with `build_items`,
`load_centroids`, `load_footprint_basis` and `fetch_published_collection` all
replaced and `--out` pointed at a tmpdir — **nothing under `data/` was written**.

## What round 1 asked for, and whether it landed

| round 1 finding | verdict |
|---|---|
| merge assertions are tautologies | **fixed for 3 of 4.** Restored the replace-everything defect in a copy (`broken.py`, three edits: `all_links = sorted(new_links)`, `overall_bbox = new_bbox`, `overall_interval = new_interval`) and all four printed `MERGE ASSERTION FAILED`, rc=1, `collection.json` not promoted, `.tmp` cleaned up. The duplicate-links assertion is still unreachable — finding 4. |
| 403-vs-404 bootstrap | fixed (raises with an actionable message). `--no-merge` verified still working, and `SystemExit(str)` exits 1 with the message on stderr — not swallowed. |
| sub-extents destroyed after run 2 | **carried forward correctly**, but the sub-extent it *appends* is wrong — finding 2. Three-run sequence with disjoint per-run item sets: sub-extents preserved, run-4 re-run byte-identical (bbox, interval and link count all unchanged). |
| `old_dts` unbound / open-ended interval | crash fixed; replaced by a **silent shrink** — finding 1. Naive-timestamp crash unfixed — finding 5. |
| collection.json written before checks | fixed for `collection.json`; item JSONs still written early — finding 7. |
| dedupe on exact href | `link_id()` added, but the assertion still compares raw strings — finding 3. |
| date-keyed S3 backup | fixed (`%Y%m%dT%H%M%S`). |
| ledger guard is a tautology | improved, with a residual — finding 9. |
| `georef_failed` never cleared | fixed; one reachable over-reset — finding 8. |
| `aoi_path()` swallows a typo | fixed. All 14 call sites pass `centroids`/`selected`/`ledger`/`aoi`/`report`/`fetch_log`/`georef_log` — every one still accepted. |
| `centroids.get(field, [None])[i]` | fixed (`[None] * N_ROWS`). |
| tagging failure was a `warning()` | fixed (`stop()` + `--no-capture-output`). |
| `test_pipeline.R` upload before register | ordering fixed; production sync remains — finding 10. |
| `.gitignore` | **correct.** `data/reports/*.md` tracked (3 files in `git ls-files`); `data/centroids/*.parquet`, `data/logs/*/`, `data/stac/`, `data/backup/` all ignored. |

`run_pipeline.sh`'s `AOI_IDS=("$@")` under `set -euo pipefail` was checked on the
real macOS bash 3.2.57 with zero args: `empty ok`, exit 0.

## Findings

- **[bug]** `scripts/05_stac_register.py:331-342, 392` — **a published open-ended
  temporal interval silently discards the entire published temporal extent, and
  no assertion fires.** `[start, null]` and `[null, null]` are both legal STAC.
  `all(old_interval)` is False for either, so the `else` at 341-342 sets
  `overall_interval, intervals = new_interval, [new_interval]` — dropping the
  published overall interval *and* every published sub-interval — and line 392's
  `if old_dts:` disables the only assertion that would have caught it.
  Probed against a published collection of 9,741 links with interval
  `['1968-05-09T00:00:00Z', null]`:
  ```
  written time: [['1972-06-01T00:00:00Z', '1972-06-01T00:00:00Z']]
  rc 0        MERGE ASSERTION lines: none
  ```
  This is the temporal twin of the spatial defect round 1 found. The spatial side
  is safe only by luck: `if old_bbox:` (315) is always true for a valid
  collection, so it has no equivalent escape hatch. Fix: fall back to the old
  interval's *known* endpoint rather than discarding it, and gate the assertion on
  `old_interval` rather than on `old_dts`, so "we could not parse the published
  interval" reports itself instead of licensing a replace.

- **[bug]** `scripts/05_stac_register.py:267-270, 321` — **the sub-extent appended
  each run is the union over the whole global COG tree, not the AOI just
  processed, so the sub-extent list decays into exactly the empty-through-the-
  middle box the comment at 317-319 says it prevents.** `new_bbox` is min/max over
  `items`, and `items` is every thumbnail COG in `data/stac`, which `aoi.R:13`
  documents as deliberately shared across AOIs. Probed the realistic sequence —
  the same published Neexdzii Kwa collection, with `data/stac` holding 1, then 2,
  then 3 AOIs' COGs (this is what actually happens as AOIs are added, because
  `build_items` rescans the whole tree every run):
  ```
  run 1  sub2  [-116.08, 49.09, -116.06, 49.11]     <- se_a alone, correct
  run 2  sub3  [-116.08, 49.09, -116.04, 49.12]     <- se_a ∪ se_b
  run 3  sub4  [-117.99, 49.09, -116.04, 49.25]     <- se_a ∪ se_b ∪ se_c
  ```
  `sub4` spans se_c to se_b and is empty through the middle. The list also grows
  by one entry on every run that adds a COG, without bound. Round 1's three-run
  probe (and mine, above) missed this because both fed a *disjoint* item set per
  run, which the script never does. Derive the appended sub-bbox per AOI — from
  `data/aoi/<id>.gpkg` or `data/selected/<id>.parquet` — rather than from
  `items`.

- **[bug]** `scripts/05_stac_register.py:383-387` — **the merge dedupes by item id
  but the "published links absent" assertion compares raw href strings, so the two
  disagree exactly in the case `link_id()` was added for, and the run hard-fails
  instead of migrating.** Probed with a published link in an equivalent-but-
  different S3 URL form for an id the run regenerates
  (`https://stac-airphoto-bc.s3.amazonaws.com/1387694.json`):
  ```
  rc 1
  MERGE ASSERTION FAILED: 1 published item links absent from the written collection
  written links: ['https://stac-airphoto-bc.s3.amazonaws.com/1387694.json']
  ```
  The merge did the right thing — the old href was replaced by the same item's new
  one — and the assertion then aborted the run and wrote nothing. So `link_id()`
  is unusable: the first time the href shape moves, every run fails until someone
  edits the assertion. Round 1 asked for ids on *both* sides; only the dedupe got
  them. Compare id sets:
  `{link_id(h) for h in old_links} - {link_id(h) for h in written_item_links}`.

- **[fragile]** `scripts/05_stac_register.py:397-398` — **the duplicate-item-links
  assertion is still structurally unable to fail.** `all_links = sorted(by_id.values())`
  (313) where `by_id` is a dict keyed by `link_id(h)`, a pure function of the
  value — so two distinct keys can never carry the same href and the values are
  unique by construction. Reading the file back does not change this, because the
  written links are a faithful serialisation of `all_links`. Probed: a published
  collection carrying the identical href twice, and one carrying `…/700001.json`
  alongside `…/700001.json/`; both collapsed before the write and the assertion
  never fired in any scenario tried. This is the one of round 1's four tautologies
  still standing. Either drop it or move it upstream, e.g. assert
  `len(by_id) == len(set(link_id(h) for h in old_links | new_links))`.

- **[fragile]** `scripts/05_stac_register.py:325-326, 334` — **a published
  timestamp without a timezone still crashes, uncaught.** Round 1 reported this
  beside the `[null, null]` case; only the latter was guarded. Probed with
  published interval `('1968-05-09T00:00:00', '2019-09-18T00:00:00')`:
  `TypeError: can't compare offset-naive and offset-aware datetimes`, traceback,
  no collection written. Latent while pystac keeps emitting `Z`, and it fails
  loud, so this is well below finding 1 — but `parse_dt` is two lines from making
  it impossible: `dt.replace(tzinfo=timezone.utc) if dt.tzinfo is None else dt`.

- **[fragile]** `scripts/05_stac_register.py:337-338` — **`parsed_subs`' `if a and b`
  filter drops any sub-interval with a null endpoint, so the spatial and temporal
  sub-extent lists silently stop corresponding.** Probed with a published
  collection carrying 2 sub-bboxes and 2 sub-intervals, one of them
  `('1990-01-01T00:00:00Z', null)`:
  ```
  sub bboxes kept: 3      sub intervals kept: 2
  ```
  A region's temporal record is dropped with no message, and every later index is
  shifted relative to its bbox. Same call for the fix as finding 1: keep the known
  endpoint rather than discarding the pair.

- **[fragile]** `scripts/05_stac_register.py:263-265` — **round 1 named item JSONs
  *and* `collection.json` as written before the checks; only `collection.json` was
  moved behind `.tmp` + `.replace()`.** Item JSONs are still written
  unconditionally at 263-265, ahead of both the merge assertions and validation.
  Probed with the defect-restored copy — after four assertion failures and rc=1:
  ```
  files left in out dir: ['1387694.json']
  ```
  `run_pipeline.sh` stops at the nonzero exit, so the happy path is protected; a
  bare `Rscript scripts/04_s3_upload.R` afterwards still publishes them, and
  `--include '*.json'` in the sync picks them up. Lower consequence than the
  round 1 case (an unreferenced item object rather than a replaced collection),
  but the same shape and the same one-line fix — write them into the tmp
  directory, or after the checks.

- **[fragile]** `scripts/02_georef.R:95` with `scripts/02_georef.R:48-55` — **the
  reset can flip a legitimate `fetch_failed` row back to `selected`.**
  `fetch_result` hardcodes `success = TRUE` for every `.jpg` found under
  `data/raw/thumbs/`, so any frame with a file on disk enters `georef_results` and
  a successful georef resets it. Two of the three ways in are closed, and I
  checked both rather than assuming:
  - `no_thumbnail_url` rows **cannot** be reached — 01_fetch.R:105 keeps only
    `selected` rows in the parquet, so they are never in `selected$airp_id`.
  - a 404 leaves **no** file: probed `utils::download.file(<missing key>, mode="wb")`
    against the real openmaps host — `success reported: FALSE`,
    `file left on disk: FALSE`.
  - a **mid-transfer abort** does leave one. `fly/R/fly_fetch.R:99-107` has no
    `unlink()` on the failure path, and `ok` is only `file.exists && size > 0`; a
    truncated-but-non-empty JPEG that GDAL still reads therefore reports
    `georef success` and overwrites `fetch_failed` with `selected`, with the
    ledger and the per-AOI report then claiming coverage for a corrupt asset.
    On a re-run of 01_fetch the same file also short-circuits
    `!overwrite && file.exists(dest_file)` to `success = TRUE`.
  Reachable but not deterministic (needs a dropped connection mid-download, which
  6 parallel workers over ~800 files will meet eventually). Cheapest fix is a size
  or `magic bytes` check where `fetch_result` is built, so the reset is gated on a
  file that is actually a JPEG.

- **[fragile]** `scripts/aoi.R:226-240` — **the reconciliation is now independent
  in 02_georef.R but is still equal-by-construction in 01_fetch.R, and it checks
  only the row count.** In 01, `ledger` is a `transmute()` of
  `aoi_centroids_as_sf(read_parquet(cache))`, and nothing between those two can
  change the count: probed `sf::st_as_sf(df, coords = c("longitude","latitude"))`
  with an NA coordinate — it **errors** (`missing values in coordinates not
  allowed`) rather than dropping the row, and `transmute()` preserves `nrow`. So
  on that path the guard still cannot go red. It *is* a real check in 02, where
  the ledger comes back from CSV, and it does fail on a genuinely wrong count
  (probed in a temp dir: dropping one row → `Ledger does not reconcile for 'se_a':
  19 rows against 20 frames`). Residual: a ledger whose `airp_id` set does not
  match the cache's, or whose reasons are wrong, passes — comparing
  `setdiff(ledger$airp_id, cache$airp_id)` costs one line and closes it.
  (Side note from the same probe: because `aoi_centroids_as_sf()` errors on NA
  coordinates, a single catalogue row with a null lon/lat would abort 01_fetch for
  that AOI. Latent — all three live caches have 0 NA in both columns.)

- **[fragile]** `scripts/test_pipeline.R:92-102` — round 1's ordering complaint was
  fixed, but the other half was not: the test still runs `05_stac_register.py`
  **without `--out`**, so it writes the real `data/stac/collection.json`, and then
  sources `04_s3_upload.R`, which backs up and `aws s3 sync`s against the
  **production** bucket. A "test" run therefore publishes. The script already has
  the flag for this (`--out /tmp/dry`, docstring line 5); pointing the test at a
  tmpdir and skipping the upload keeps it a test.

## Verified clean (probed, no action needed)

- **Merge assertions do go red for the disaster they name.** Restored the
  replace-everything defect (3 edits) → all four assertions fired, rc=1,
  `collection.json` not promoted, `.tmp` unlinked. The claim in the commit message
  is earned.
- **`.tmp` promotion has no leaky early return.** `if not items: return 1` (259-261)
  precedes the write; both failure paths `unlink(missing_ok=True)` then return 1;
  and `collection.json.tmp` does not match either sync filter (`*.tif`, `*.json`),
  so a leftover tmp cannot be uploaded.
- **`--no-merge` still works.** Probed with `fetch_published_collection` replaced
  by a function that raises if called — rc=0, never called.
- **The 403 abort is not swallowed.** `SystemExit(<str>)` exits **1** with the
  message on stderr; `conda run --no-capture-output` propagates it, and both
  `run_pipeline.sh` (`set -euo pipefail`) and `test_pipeline.R:95` check it.
- **`link_id()` parsing is sound for this collection.** `airp_id` is `int32` in
  every cache (probed the pyarrow schema), so `str(airp_id)` is `'1387694'` with
  no `.0` suffix and no dot to confuse `rsplit(".", 1)`. Asset hrefs cannot
  collide with item links — only `rel == "item"` links are read (293-294, 376-377).
- **Sub-extents are genuinely carried forward and the extent is idempotent.**
  Three-run sequence preserved every region; a fourth run over unchanged input
  produced identical bbox, identical interval and identical link count.
- **`intervals` serialises correctly.** Every element of `parsed_subs`,
  `overall_interval` and `new_interval` is a `datetime`, so pystac emits
  `'1968-05-09T00:00:00Z'` throughout — no string/datetime mixing reaches the JSON.
  (The list can still be *incomplete*, per finding 6.)
- **`.gitignore` is right in both directions.** `git ls-files data/` returns the
  three `data/reports/*.md` and nothing else; `git check-ignore` confirms
  `data/centroids/se_a.parquet`, `data/logs/fetch_log/se_a.csv`,
  `data/stac/collection.json` and `data/backup/collection-x.json` are all ignored.
- **`aoi_path()` validation broke no call site.** All 14 call sites across
  `aoi.R`, `00`–`02` and `test_pipeline.R` pass an accepted kind.
- **`run_pipeline.sh` is bash 3.2 safe.** `AOI_IDS=("$@")` with zero args under
  `set -euo pipefail` on the shipped `GNU bash 3.2.57(1)-release (arm64-apple-darwin24)`:
  exit 0.
- **`README.Rmd`'s `aoi_resolve("neexdzii_kwa")`** matches the real signature —
  `fresh::frs_watershed_at_measure(conn, blue_line_key, downstream_route_measure, …)`
  and `fresh::frs_db_conn` both exist. Chunk is `eval=params$update_query`.
- **No duplicate thumbnail basenames** within any selected set (0 in each of
  se_a/se_b/se_c), so `match()` at `02_georef.R:49-52` cannot mis-attribute an
  `airp_id`.

## Suggested priority

1. Finding 1 — the only path where a published extent is silently destroyed with
   rc=0 and no assertion.
2. Finding 3 — `link_id()` is presently a trap: the first href-shape change
   aborts every run.
3. Finding 2 — sub-extents are actively degrading toward the box they exist to
   prevent, and growing without bound.
4. Findings 4–7, then 8–10.
