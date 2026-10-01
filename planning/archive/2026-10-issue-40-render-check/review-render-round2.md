# Review — render check (#40), round 2

Scope: staged diff (`scripts/cog_render-compare.py`, `tests/test_render.py`,
`scripts/README.md`, the CLAUDE.md "Render check" paragraph), with the four round-1
fixes as the focus.

What was probed, not just read:

- Live `frame()` against the bucket for `695106` (both sources): `bytes_same` True,
  `overviews_same` True, 0 pixels differing at every level; the COG has overviews
  `[2, 4]`, both levels opened through `/vsicurl` with `overview_level=k`.
- Live `frame()` on a key that exists on neither side: row carries
  `published_unreadable` ("HTTP response code: 403"), `local_unreadable`,
  `bytes_same` False, one solid-magenta panel — sane PNG and row. `--source published`
  alone: row with `published_unreadable`, no panels, no PNG written, exit 0.
- All 10,100 local item JSONs resolve to a local COG under the bucket prefix, so the
  default (`--source both`, sampled by local) cannot hit a missing local file today.
- `test_render.py` passes (10) in a temp copy.
- `verdict()`: with `--source both`, both branches of `frame()` set `bytes_same`, and
  `verdict` tests `is not True`, so a missing key, `False`, or an unreadable side all
  fail; empty rows fail. No fail-toward-pass found. A no-overview COG gives `n = 0`
  and is fine; differing overview counts return `(False, 0)` and are reported as
  `overviews_same=False` (and `--expect-same` still fails on `bytes_same`).
- `published_sha256`: a direct S3 virtual-host URL (no CDN, S3 is read-after-write
  consistent), urllib follows redirects, and `http.client` raises `IncompleteRead` on
  a short body rather than returning a partial hash, so a truncated read cannot
  produce a false SAME.

## Findings

- **[bug]** scripts/cog_render-compare.py:198 — `pick()` still crashes on a frame
  unreadable on the side it samples by. Round-1 fix 2 caught `RasterioIOError` in
  `frame()` only; the shape probe in `pick()` opens each sampled frame with no
  handler. With `--source published` (a documented usage line) run before a sync
  that adds frames, any sampled item whose COG is local-only answers 403 and the
  whole run dies with a traceback (an empty `data/logs/render/<stamp>/` is left).
  Reproduced: `pick({"1": "thumbs/1900/not_yet_published.tif"}, [], 2, 36,
  "published")` -> `RasterioIOError: HTTP response code: 403`. Same for a missing
  local COG under `both`/`local` (none today, but the item-JSON set and the COG set
  are independent). Skip an unreadable frame in the sample rather than abort.

- **[fragile]** scripts/cog_render-compare.py:127-129, 153 — `published_sha256()` has
  no handler. A frame that `/vsicurl` read moments earlier but whose GET then fails
  (timeout at 120 s, connection reset, a transient 5xx) raises `URLError`/`HTTPError`
  /`IncompleteRead` out of `frame()` and `main()`, killing the run; `summary.csv` is
  written only after the loop, so every row already computed is lost. Fails toward
  abort, not pass, but it is the same "one frame takes down the run" class fix 2 was
  meant to close. Recording it as `bytes_same=False` plus an error column would keep
  `--expect-same` failing.

- **[fragile]** scripts/cog_render-compare.py:136-145 — `full[s]` and `small[s]` are
  two separate opens inside one `try`. If the first read succeeds and the second
  raises `RasterioIOError` (transient `/vsicurl` failure), `full[s]` is set,
  `small[s]` is not, and line 145 (`composite(small[s]) for s in full`) raises
  `KeyError`. Low probability; assign both only after both reads succeed.

- **[fragile]** scripts/cog_render-compare.py:145-151, 252 — when the published side
  is unreadable the PNG is `[local, magenta]`, yet the run prints the panel order as
  `[published | local | diff]`, and PNGs carry no labels (no Pillow, by design). A
  person looking at that PNG reads the local frame in the "published" position and
  can conclude the frame is published and looks fine. The CSV row is correct
  (`published_unreadable`), so this only misleads someone reading the image alone;
  a placeholder panel for the missing side would keep positions stable.

No defect found in the overview comparison, the byte comparison, `verdict()`, or the
doc wording.

/Users/airvine/Projects/repo/stac_airphoto_bc/planning/active/review-render-round2.md
