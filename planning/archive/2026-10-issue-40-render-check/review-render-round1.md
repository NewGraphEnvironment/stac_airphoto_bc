# Review — render check (#40), round 1

Scope: staged diff `render1.patch` — `scripts/cog_render-compare.py`, `tests/test_render.py`,
the `scripts/README.md` rows, the CLAUDE.md "Render check, around every sync (#40)" paragraph.
Probes ran in a temp dir (`mktemp -d`) against a copy of the script; nothing in the repo was
modified except this file.

## Findings

- **[fragile]** scripts/cog_render-compare.py:171-184 — **`pixels_differing` counts full resolution only; overviews are never counted, and only one overview level is ever drawn.**
  `full[s]` is read at full res and is what the count compares; the panels are read with
  `out_shape` (`read(..., args.size)`), which GDAL serves from an overview. A real local COG
  (`bc84041_216_12n_thumb.tif`, 1311 px, overviews `[2, 4]`) at `--size 600` reads overview 2
  (655 px), so overview 4 is never compared by anything. Probe: two COGs with identical full-res
  bands and identical grids, overviews built `nearest` vs `average` →
  `full differing 0`, `small differing 358222`. So summary.csv says `pixels_differing=0` while
  the panel is full of magenta; and a change confined to overview 4 (or any level other than the
  one `--size` happens to select) gives no magenta *and* 0. Overviews are what a client draws
  when zoomed out, and the alpha in overviews is exactly what #36 / `test_cog.py` care about, so
  the "after a sync, no magenta and pixels_differing=0" claim can pass when the published
  overviews differ. Fix: compare every overview level (`ds.read(..., out_shape=...)` per
  `ds.overviews(1)` factor, or open with `OVERVIEW_LEVEL=n`) and count them in the summary, or
  compare the published object's bytes/sha256 to the local file (the sync writes
  `--checksum-algorithm SHA256`, so the object carries one).

- **[fragile]** scripts/cog_render-compare.py:133,171 — **A frame that is local but not yet published aborts the whole run — the pre-sync case the tool is documented for.**
  `pick()` samples on the *local* file's shape when `--source both`, and items come from the
  local item JSONs, which 05_stac_register.py has already written before the sync. A new frame
  (new AOI, or any named new `airp_id`) then hits `/vsicurl/` on a missing key; the bucket grants
  no ListBucket, so it answers **403** (probed: `RasterioIOError HTTP response code: 403`) and the
  script dies with a traceback. Loud, not silent — but PNGs already written stay on disk and
  `summary.csv`, written only after the loop (l.195-199), is never produced. Before a sync that
  adds frames the check cannot run at all if one is sampled/named. Treat "not published" as a
  row outcome (e.g. `published_shape=absent`, all-magenta diff) rather than an exception, or at
  least catch it per frame and still write the summary.

- **[fragile]** CLAUDE.md "Render check" paragraph; scripts/cog_render-compare.py:120-141 — **"Before the sync, shows in magenta what the sync will change" fails toward pass.**
  The sample is ~4 seeded frames out of 10,100, chosen without regard to which frames differ.
  A sync that will overwrite hundreds of COGs reads as "no magenta, pixels_differing=0" whenever
  none of those four is among them — and with a fixed default seed it is the *same* four every
  time, so frames a rebuild changes may never be sampled across successive syncs. The tool cannot
  disagree with "nothing will change". Either reword the claim (a sample shows *how* the sampled
  frames will change), or bias the sample toward frames that will change: the local item's
  `file:checksum` vs the published object's SHA-256 (or the published item JSON) identifies them.

- **[fragile]** scripts/cog_render-compare.py:202 — **Always exits 0**, including with
  `pixels_differing > 0` or `grid_same=False` after a sync. The post-sync check is therefore a
  human reading PNGs/CSV; nothing can gate on it (e.g. in `run_pipeline.sh`). If the after-sync
  check is meant as a control, return non-zero when any row has `grid_same=False` or
  `pixels_differing != 0`, perhaps behind a flag so the pre-sync run still exits 0.

## Checked and fine

- No silent "identical" pass from a failed read: `read()` has no try/except, so any open/read
  failure on either side raises rather than producing equal arrays.
- Grid guard: shape (including band count) and the 6-term transform must match before a pixel
  diff is taken; otherwise the diff panel is solid magenta and the count is blank, not 0.
  (A band-count mismatch is labelled `grid_same=False`, which is misleading wording but loud.)
- The count is on full-resolution arrays, all bands including alpha, not on the downsampled panels.
- `pick()` cost: stops as soon as each shape is filled; colorinterp names match `SHAPES`
  (`ColorInterp(1).name == "gray"`, confirmed), and 03_cog.py enforces gray|alpha / RGBA, so it
  does not walk all 10,100 files in practice.
- `items()` glob `[0-9]*.json` excludes `collection.json`; 10,100 item JSONs and 10,100 local COGs.
- Writes: PNGs and summary.csv under `data/logs/render/<stamp>/` (or `--out`); `data/*` is
  gitignored, so nothing lands in git. Nothing written elsewhere.
- Tests: the six tests exercise composite/diff/stats/write_png as described.
