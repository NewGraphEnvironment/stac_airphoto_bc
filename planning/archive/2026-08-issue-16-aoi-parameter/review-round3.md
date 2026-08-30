# Code review — round 3 (issue #16, AOI registry)

Reviewer: fresh-eyes agent, third pass. Read `review-round1.md`, `review-round2.md`,
`git show HEAD`, `scripts/05_stac_register.py` in full, `scripts/aoi.R`,
`scripts/02_georef.R`, `scripts/04_s3_upload.R`. Focus was **round 2's fixes**.

Every claim below was probed. Probes ran against copies in
`scratchpad/r3/` with `build_items`, `load_centroids`, `load_footprint_basis`
and `fetch_published_collection` replaced and `--out` pointed at a tmpdir —
**nothing under `data/` was written**. The only live reads were
`pq.read_table("data/centroids/*.parquet")` and a `curl` of the published
`collection.json`.

## Findings

- **[bug]** `scripts/05_stac_register.py:263, 278, 374` — **a published body that
  parses as falsy JSON silently takes the replace-everything path with rc=0 and
  no assertion.** `fetch_published_collection()` documents itself as *"Raises
  rather than returning None if it cannot be read"* (line 66) and lines 65–74
  explain at length why a missing collection must never be inferred. But `main()`
  gates both the merge (278) and **every** assertion (374) on the *truthiness* of
  the returned object, not on its validity. A 200 response whose body is `null`,
  `{}`, `[]`, `false`, `0` or `""` therefore reaches `if published:` as False:
  `old_links`, `old_bbox` and `old_interval` stay empty, the collection is rebuilt
  from local COGs alone, and the four `if published:` assertions plus the
  `len(written_item_links) < len(old_links)` backstop are all no-ops because
  `old_links` is the empty set.

  Probed with the real `main()`, one local item, `fetch_published_collection`
  returning each body in turn:
  ```
  null (JSON `null`)       rc=0 item_links_written=1 bbox=[[-116.08, 49.09, -116.06, 49.11]] fails=[]
  empty object `{}`        rc=0 item_links_written=1 bbox=[[-116.08, 49.09, -116.06, 49.11]] fails=[]
  empty array `[]`         rc=0 item_links_written=1 bbox=[[-116.08, 49.09, -116.06, 49.11]] fails=[]
  `false`                  rc=0 item_links_written=1 bbox=[[-116.08, 49.09, -116.06, 49.11]] fails=[]
  valid collection         rc=0 item_links_written=6 bbox=[[-126.96, 49.09, -116.06, 54.74]] fails=[]
  ```
  The script then prints `merge assertions passed`, promotes `collection.json`,
  and `04_s3_upload.R` syncs it — after which the geopro registration deletes and
  reloads from `collection.json`, so the **9,976 published item links** (measured
  live, below) are gone. This is `--no-merge` behaviour reached without
  `--no-merge`.

  Likelihood is low — it needs the S3 object to be literally one of those
  values; a truncated or non-JSON body raises `JSONDecodeError` and fails loud,
  and a network failure raises `URLError`. But it is the one remaining place
  where the module's stated invariant is not enforced, the consequence is total,
  and the fix is one line at the end of `fetch_published_collection`:
  ```python
  if not isinstance(data, dict) or "extent" not in data or "links" not in data:
      raise SystemExit(f"{url} did not return a STAC collection ...")
  ```
  Checklist: *"A guard must not fail toward 'skip'"* and *"Empty is not unset"*.
  Verified latent, not active: the live object is
  `type=dict truthy=True`, 9,976 item links, bbox
  `[[-126.9605625124543, 48.97611415010284, -115.86181457466488, 54.73610913846966]]`,
  interval `[['1967-07-11T00:00:00Z', '2019-09-18T00:00:00Z']]`.

## Verified clean (probed, no action needed)

### 1. Temporal merge — the full matrix, 24 cells, all correct
Six published shapes (closed, open-start, open-end, fully-open, naive,
naive+open-end) × four new-item ranges (earlier, later, inside, spanning). Every
cell rc=0 with no assertion firing and the correct written interval:

```
closed       earlier   [['1950-01-01T00:00:00Z','2019-09-18T00:00:00Z']]
closed       later     [['1968-05-09T00:00:00Z','2035-01-01T00:00:00Z']]
closed       inside    [['1968-05-09T00:00:00Z','2019-09-18T00:00:00Z']]
open_start   later     [[None,'2035-01-01T00:00:00Z']]
open_end     earlier   [['1950-01-01T00:00:00Z',None]]
fully_open   spanning  [[None,None]]
naive        earlier   [['1950-01-01T00:00:00Z','2019-09-18T00:00:00Z']]
naive_open_e later     [['1968-05-09T00:00:00Z',None]]
```
No combination narrows or drops the published range, and no combination can
invert it: `merged_start = min(...starts)` and `merged_end = max(...ends)` with
`new_interval[0] <= new_interval[1]`, so `merged_start <= merged_end` always.
Round 2's finding 1 and finding 5 (naive timestamps) are both genuinely fixed.

**And the assertions can go red.** Restored round 2's defect verbatim
(`if old_interval and all(old_interval): … else: replace`) in a copy:
```
brokenA open_end    rc=1 item_jsons=0 collection=NO
        fails=['written interval starts after the published one',
               'written interval closed a published open end']
brokenA fully_open  rc=1 item_jsons=0 collection=NO
        fails=['written interval closed a published open start',
               'written interval closed a published open end']
```
Restored the full replace-everything defect (links + bbox + interval): all five
remaining assertions fire on every published shape, rc=1, no collection, **zero
item JSONs**.

### 2. Sub-extents — nothing still reads them, and the collapse is clean
`grep -rn 'bbox\|interval\|extent'` over every `.R`, `.py`, `.sh`, `.Rmd`, `.md`
in the repo: no consumer of `bbox[1:]` or `interval[1:]` outside
`05_stac_register.py` itself and the planning files. Fed a published collection
with the exact 3-entry shape the old code wrote:
```
bbox     [[-126.96, 49.09, -116.04, 54.74]]        (was 3 entries)
interval [['1968-05-09T00:00:00Z','2019-09-18T00:00:00Z']]   (was 3)
rc 0, fails []
rerun with the written collection as published -> identical: True
```
No coverage is lost: STAC requires `bbox[0]` to be the overall extent, and the
old code only ever appended sub-boxes that were subsets of it. The live
collection already carries a single-entry extent, so the collapse has already
happened in production without incident.

### 3. `link_id()` — no distinct item can collide, and a net drop is caught
Extracted the function verbatim from source and ran it over 15 hrefs:
```
'695106'  <- '…/695106.json'      '695106'  <- '…/695106.json/'
'695106'  <- '…s3.amazonaws.com/695106.json'   '695106'  <- '…/695106%2Ejson'
'695106'  <- '…/items/695106.json'  '695106'  <- '…/695106.json?versionId=abc'
'695106.0'<- '…/695106.0.json'      'thumbs/1968/695106' <- '…/thumbs%2F1968%2F695106.json'
'bc5281_084_thumb' <- '…/thumbs/1968/bc5281_084_thumb.tif'
'stac-airphoto-bc.s3.us-west-2.amazonaws' <- '…amazonaws.com/'   '' <- ''
```
Every collision is between **aliases of the same item**, which is the intent. An
id containing a dot survives (`695106.0`), a trailing slash and percent-encoding
both normalise, and asset hrefs are unreachable because only `rel == "item"`
links are read. Measured on the live collection: **9,976 hrefs → 9,976 distinct
`link_id`s, zero ids carried by more than one href.** Item hrefs are flat
`<id>.json` and `airp_id` is `int32`, so two distinct items cannot collide.

Even if they somehow did, `len(written_item_links) < len(old_links)` (405) is an
unconditional backstop that catches a net drop. (It can be masked if the same
run also adds a genuinely new item — written count stays equal — but that needs
a collision that cannot occur here.)

### 4. Removing the duplicate-links assertion was right
`all_links = sorted(by_id.values())` where `by_id` is keyed by `link_id(h)`, a
pure function of the value. Two entries carrying the same href would key
identically, so the values are unique by construction and reading the file back
cannot change that — round 2's finding 4 stands, and deletion is the correct
resolution rather than relocation. The case it nominally covered (a duplicated
published link) is still handled: the merge collapses it, and the count backstop
at 405 reports the resulting shrink.

### 5. Nothing durable survives a failed run
- `if not items: return 1` (250) precedes every write.
- Item JSONs moved behind the checks: with the defect restored, `item_jsons=0`
  in the output directory on every failing scenario (measured above).
- Both failure returns `unlink(missing_ok=True)` the tmp; `collection.json.tmp`
  matches neither sync filter (`*.tif`, `*.json`), so a tmp left by an uncaught
  exception cannot be uploaded.
- **Previous run's artifacts:** a failed run leaves the previous run's item
  JSONs *and* the previous `collection.json` untouched — a consistent pair, and
  re-syncing them is a no-op. Every run rewrites every item JSON for the whole
  global `data/stac` tree, so there is no stale-item path.
- No accidental `--no-merge`: `run_pipeline.sh:51`, `scripts/README.md:30` and
  `test_pipeline.R:93` all invoke the script bare.

### 6. `aoi_ledger_write()` — the new check is falsifiable, the residual is unchanged
`dplyr::n_distinct(ledger$airp_id) != nrow(ledger)` is a real check: in
`01_fetch.R` both counts come from the same cache so the row-count guard agrees
by construction, but a duplicated `airp_id` in the cache would still trip the new
one. Both call sites pass the new two-argument signature
(`01_fetch.R:141`, `02_georef.R:98`); the removed `window_n` parameter has no
stragglers.

The residual round 2 named is still open and unchanged: neither check compares
the ledger's `airp_id` **set** against the cache's, so a ledger with the right
count of distinct ids but a different set passes. Reaching it needs a cache
refresh between stages that returns an exactly equal-sized, differently-composed
window — contrived enough that I am not raising it as a new finding, but
`setdiff(ledger$airp_id, cache$airp_id)` is still one line.

### Also probed, no action
- **Thumbnail basenames are globally unique**, so `02_georef.R:49-52`'s
  `match()` against the global `data/raw/thumbs/` tree cannot attribute another
  AOI's file to this AOI's `airp_id`: 0 duplicate basenames within any cache and
  0 basenames mapping to more than one `airp_id` across all three caches
  (818/840/1013 rows).
- `pystac.Item(datetime=None)` raises `STACError`, so `min(new_dts)` on an empty
  list (259) is unreachable — but by the same token a catalogue row with neither
  `photo_date` nor `photo_year` would abort `build_items` with an unhandled
  traceback. Measured: **0 of 2,671 live rows** are in that state and 0 have an
  unparseable date, and it fails in the safe direction (rc≠0, nothing written),
  so not flagged.
- `02_georef.R:95`'s reset cannot flip a `digital_unknown_format` or
  `footprint_misses_aoi` row: those never enter `data/selected/*.parquet`, so
  they cannot appear in `georef_results`. Round 2's finding 8 (truncated JPEG)
  is unchanged and remains the only reachable route.
- Empty `georef_results` (no years) is safe: `NULL[NULL]` → `NULL`,
  `%in% NULL` → all FALSE, `sum(NULL)` → 0.

## Verdict

**One new finding**, and it predates round 2 rather than sitting inside a round 2
fix. All three round 2 defects are fixed, the fixes are falsifiable against a
restored bug, and the areas the brief flagged for interrogation — the temporal
matrix, the sub-extent removal, `link_id()` on both sides, the deleted assertion,
and the write ordering — each probed clean. Round 2's own residual findings
(truncated-JPEG reset, ledger id-set, `test_pipeline.R` publishing to production)
are unchanged and were out of this round's scope.

This looks like convergence: the second pass found bugs inside the first pass's
fixes, the third pass found none inside the second's.
