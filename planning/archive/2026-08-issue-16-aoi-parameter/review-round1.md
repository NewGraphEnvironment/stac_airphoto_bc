# Code review — round 1 (issue #16, AOI registry)

Reviewer: fresh-eyes agent. Staged diff of 13 files, each read in full plus the
`fly` source for `fly_georef()`. Claims below were probed, not reasoned about;
the probe is named on each finding.

## Findings

### 05_stac_register.py

- **[bug]** `scripts/05_stac_register.py:314-326` — **all four merge assertions are
  tautologies. The block cannot go red for any input.** Each compares a value
  against something derived from it:
  - `missing = old_links - set(all_links)` where `all_links = sorted(old_links | new_links)` (line 270) — always empty.
  - `bbox_contains(overall_bbox, old_bbox)` where `overall_bbox = bbox_union(old_bbox, new_bbox)` (line 273) — a union always contains its operand.
  - `overall_interval[0] > old_dts[0]` where `overall_interval[0] = min(old_dts[0], …)` (line 286) — a min is never greater.
  - `len(all_links) != len(set(all_links))` where `all_links` is `sorted(<a set>)` — duplicates are impossible by construction.

  Probed: simulated the exact disaster the block is named for — a published
  collection of 9,741 links and a 600 km-distant extent, merged against a single
  new item — and got `failures = []`. The header comment "the collection must
  only ever grow" and the success line "merge assertions passed" (line 346) are
  both unearned. This is `code-check.md` → *"Restore the bug and confirm the test
  fails"* and *"A comparison test proves nothing if the fixture makes both sides
  identical"*.

  To make them real, assert against values read back **independently** of the
  merge — e.g. re-fetch the published collection after the write and compare, or
  compare `len(all_links) >= len(old_links)` against the count `published`
  reported, and assert item **ids** (parsed out of hrefs) rather than the href
  strings the merge itself produced.

- **[bug]** `scripts/05_stac_register.py:65-74` — **the `404 → None` bootstrap path
  is unreachable on this bucket.** Measured live:
  ```
  collection.json -> HTTP 200
  missing key     -> HTTP 403
  ```
  The bucket grants `s3:GetObject` but not `s3:ListBucket`, so S3 answers **403
  AccessDenied** for an absent key, never 404 (this is the `code-check.md` entry
  *"Public bucket ≠ listable: GetObject vs ListBucket"* surfacing here). So
  `except HTTPError: if exc.code == 404` never fires, `"No published collection
  yet — starting fresh"` can never print, and a fresh bucket (or a deleted
  `collection.json`) aborts with a 403 traceback. The only way through is
  `--no-merge`, which the module docstring warns discards published links.
  Accept `exc.code in (403, 404)` — or, safer, treat 403 as "absent" only after
  confirming the bucket is reachable at all.

- **[bug]** `scripts/05_stac_register.py:266, 277, 285, 288` — **the per-region
  sub-extents are destroyed after the second run, and the extent is not
  idempotent.** Only `bbox[0]` and `interval[0]` are read back from the published
  collection, but `bbox[0]` is by definition the *overall* box the previous run
  wrote. Simulated the real sequence (published Neexdzii Kwa, then se_a, se_b, se_c):
  ```
  run 1: [[-126.96,49.09,-116.06,54.74], [-126.96,53.98,-125.74,54.74], [-116.08,49.09,-116.06,49.11]]
  run 2: [[-126.96,49.09,-116.04,54.74], [-126.96,49.09,-116.06,54.74], [-116.05,49.11,-116.04,49.12]]
  run 3: [[-126.96,49.09,-116.04,54.74], [-126.96,49.09,-116.04,54.74], [-117.98,49.24,-117.97,49.25]]
  se_a's own region still listed after 3 runs? False
  ```
  From run 2 on, `bboxes[1]` is a duplicate of `bboxes[0]` and every region but
  the most recent is gone — exactly the "600 km-wide box that is empty through
  the middle" the comment at 274-276 says the list prevents. It also makes the
  docstring's *"Running twice is idempotent"* false for the extent: run 1 and run
  2 differ on unchanged input (it converges at run 2). Carry the sub-extents
  forward: read `bbox[1:]` / `interval[1:]` and rebuild
  `[union(all), *old_subs, new_bbox]`, deduped.

- **[bug]** `scripts/05_stac_register.py:285, 323` — **`old_dts` is defined under
  `if old_interval:` but consumed under `if published:`.** Those are different
  conditions, so a published collection with a falsy interval reaches line 323
  with `old_dts` unbound → `NameError`. Related and more reachable: a **legal
  open-ended STAC interval** `[null, null]` crashes earlier, at line 286:
  ```
  open-ended STAC [null,null]  -> TypeError: '<' not supported between 'datetime' and 'NoneType'
  naive published timestamp    -> TypeError: can't compare offset-naive and offset-aware datetimes
  ```
  The live collection is currently well-formed (`['1968-05-09T00:00:00Z',
  '2019-09-18T00:00:00Z']`), so both are latent. Guard `parse_dt` returning
  `None`, and gate line 323 on `old_interval` rather than `published`.

- **[bug]** `scripts/05_stac_register.py:244-246, 310` — **item JSONs and
  `collection.json` are written before the failure checks at 338-344.** A run that
  fails validation or a merge assertion still leaves a complete
  `data/stac/collection.json` on disk. `run_pipeline.sh` has `set -euo pipefail`
  and stops there, so the happy path is protected — but any bare
  `Rscript scripts/04_s3_upload.R` afterwards, or `test_pipeline.R` (which only
  `warning()`s on a nonzero exit at line 95), will sync that file over the
  published one. Same class as `code-check.md` → *"`cmd > file` truncates before
  `cmd` runs"*. Write to `out_dir/collection.json.tmp` and `os.replace()` only
  after `failures` and `errors` are both empty.

- **[fragile]** `scripts/05_stac_register.py:260-270` — the merge dedupes item
  links by **exact href string**. Confirmed safe today: the published links are
  `https://stac-airphoto-bc.s3.us-west-2.amazonaws.com/695106.json`, byte-identical
  to what `s3_href(f"{i.id}.json")` now produces. But `quote()` was *added to
  `s3_href` in this diff* — any future change of that shape adds a second link for
  the same item instead of replacing it, and the "duplicate item links" assertion
  is set-based so it cannot report it. Dedupe on the item id parsed out of the
  href.

### 04_s3_upload.R

- **[bug]** `scripts/04_s3_upload.R:27, 33` — **the backup key is date-only, so the
  second run of a day overwrites the backup with the already-damaged
  collection.** The block's own comment says `collection.json` "is the only record
  of which items are published". Sequence: run 1 at 10:00 backs up the good copy;
  run 1 publishes a bad `collection.json`; run 2 at 14:00 backs up the **bad**
  copy to the same `backup/collection-<date>.json` key and to the same
  `data/backup/collection-<date>.json` — the good copy is gone from both places.
  `test_pipeline.R:89` sources this script too, so a test run destroys the day's
  backup. Use `format(Sys.time(), "%Y%m%dT%H%M%S")`, or rely on S3 object
  versioning.

- Verified clean: the `--exclude '.*' --exclude '*' --include '*.tif'` ordering is
  correct (later rules win, so only `.tif` uploads; the first `--exclude` is dead
  but harmless), `run()` stops on any nonzero exit so the backup cannot silently
  fail, and `LOCAL_DIR`/`BUCKET` are constants with no shell metacharacters.

### 02_georef.R / aoi.R

- **[bug]** `scripts/02_georef.R:90` + `scripts/aoi.R:207-214` — **the ledger
  reconciliation guard cannot fail.** 02 passes `window_n = nrow(ledger)` —
  literally the value the guard compares `nrow(ledger)` against. 01_fetch.R:141
  passes `nrow(window)`, but `ledger` is a `transmute()` of `window`, which
  preserves row count, so that call site is a tautology too. Probed:
  `aoi_ledger_write(led, "se_a", window_n = nrow(led))` → passes for any input.
  The comment at aoi.R:198-200 claims this is "what makes 'what selection
  rejected and why' answerable rather than asserted" — as written it asserts.
  In 02, reconcile against a number the ledger did not produce: the row count
  of the centroid cache (`nrow(arrow::read_parquet(aoi_path("centroids", id)))`).

- **[bug]** `scripts/02_georef.R:86-88` — **`georef_failed` is set but never
  cleared.** The ledger is read back from CSV and only ever mutated toward
  failure. Because `fly_georef()` returns `success = TRUE` for an output that
  already exists (fly/R/fly_georef.R:156-159, `!overwrite && file.exists`), a
  frame that failed once and succeeds on a re-run keeps `georef_failed` in both
  the ledger and the report permanently. 01_fetch.R rebuilds its ledger from
  scratch each run so `fetch_failed` self-heals; 02 does not. Reset the selected
  rows before applying `failed`, or recompute the reason from
  `georef_results$success` for every row it covers.

- **[fragile]** `scripts/aoi.R:124-136` — **`aoi_path()`'s switch default swallows a
  typo.** Probed: `aoi_path("centroid", "se_a")` returns
  `data/logs/centroid/se_a.csv` and *creates the directory*, rather than erroring.
  Any unrecognised `what` becomes a plausible-looking log path, so a misspelled
  stage would write its artifact somewhere nothing reads and every later
  `file.exists()` guard would report "run 01_fetch.R first". `what` is a fixed
  six-value vocabulary — validate it and `stop()` on anything else.

### 03_cog_tag.py / 03_cog.R

- **[fragile]** `scripts/03_cog_tag.py:33, 40` — **`centroids.get(field, [None])[i]`
  raises `IndexError` for `i > 0`.** The default is a length-1 list where it needs
  to be `[None] * n`; `05_stac_register.py:105,110` gets this right and this file
  does not. Probed against merged caches:
  `IndexError: list index out of range`. It fires when a `TAG_FIELDS` entry is
  absent from *every* cache. Pre-existing, but newly relevant: with one cache per
  AOI from separate WFS queries, schema variation between caches is now possible
  where a single cache made it impossible.

- **[fragile]** `scripts/03_cog.R:60-61` — tagging failure is a `warning()`, not a
  `stop()`. Rscript exits 0 on warnings, so `set -euo pipefail` in
  `run_pipeline.sh` does not catch it and the pipeline proceeds to STAC
  registration and S3 upload with untagged COGs. `system()` here also lacks
  `--no-capture-output`, so the Python error text is buffered away. Same shape at
  `test_pipeline.R:95` for STAC registration.

### test_pipeline.R

- **[fragile]** `scripts/test_pipeline.R:86-95` — runs `04_s3_upload.R` **before**
  `05_stac_register.py`, contradicting the new header of 04_s3_upload.R ("Runs
  AFTER 05_stac_register.py, … It used to run before, which meant a run's own
  STAC output was never uploaded by that run") and the ordering fix in
  `run_pipeline.sh:50-55`. The test script therefore uploads the *previous*
  collection and never uploads what it just registered. It also performs a real
  backup + `aws s3 sync` against the production bucket — combined with the
  date-keyed backup above, a test run silently overwrites the day's backup.

## Verified clean (probed, no action needed)

- `scripts/centroids.py` column padding is **correct**. Probed with three ragged
  caches (`{airp_id, film_roll}` × 3 rows, `{airp_id, rotation}` × 2,
  `{airp_id, film_roll, extra}` × 1): every column came back length 6 with values
  in the right row positions. `setdefault([None] * n_rows)` before the increment
  and the trailing pad loop after it cover both directions.
- `scripts/aoi.R:111-115` — `aoi_ids()` validates every id before any work:
  `aoi_ids(c("se_a","se_x"))` → `Unknown AOI id 'se_x'. Registered: …`.
- `scripts/aoi.R:124-136` — the `switch()` default *mechanism* is right (a single
  trailing unnamed argument is R's default arm; there is no fall-through hazard
  here because every named arm has a value). Only the missing validation is a
  concern, above.
- `rotation = "auto"` at `02_georef.R:78` and `test_pipeline.R:76` is **safe**, and
  the comment at aoi.R:151-170 is accurate. Read `fly/R/fly_georef.R:127-140`:
  `has_rotation_col <- "rotation" %in% names(photos_sf)` and the auto-compute runs
  only `if (auto_rotation && !has_rotation_col)`, so the carried column wins. The
  column does survive: 01_fetch.R:77 sets it, :114 writes it to the selected
  parquet, `aoi_centroids_as_sf()` preserves it, and `ph` is a `filter()` of it.
- Ledger CSV round-trip preserves types — `airp_id` is `numeric` on both the
  `georef_log` and ledger sides, so the `%in%` match at 02_georef.R:88 works, and
  `write_csv(read_csv(x))` is byte-identical to `x` on the real `se_a` ledger.
- `environment.yml` — dropping `defaults` is safe; only `python` and `pip` come
  from conda, both on conda-forge.

## Suggested priority

1. `05_stac_register.py` merge assertions (they are the entire safety story for a
   9,741-item published collection, and they are decoration).
2. The 403-vs-404 bootstrap, and writing `collection.json` before the checks pass.
3. The date-keyed backup in `04_s3_upload.R`.
4. Sub-extent degradation, `old_dts` scope, ledger guard, `georef_failed` stickiness.
