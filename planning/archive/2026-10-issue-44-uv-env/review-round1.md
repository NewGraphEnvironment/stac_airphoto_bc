# Code-check round 1 — #44 (conda → uv), staged diff + HEAD (pyproject/.python-version/.gitignore)

## Findings

- **[fragile]** scripts/cog_rewrite-check.py:50-57 (and the claims at CLAUDE.md:74-83, scripts/README.md "Building the Python environment", the tool's own docstring line 1)
  The check holds the tag dict fixed: it reads the tags back off the existing COG
  (`ds.tags()`) and feeds them to `write_cog()`. In `03_cog.py` the tags are not read
  back. They are computed: `load_windows()` → `centroids.load_centroids()` (pyarrow)
  → `frame_tags()`/`fmt()` (03_cog.py:94-104, 347). So the check covers rasterio/GDAL,
  which is the main risk, but it cannot see an environment change anywhere upstream of
  `write_cog`. Example: a pyarrow bump that changes how a window column comes back
  (`photo_date` arrives as `datetime.date`; `rotation` as `int`; `shift_*` as `float`;
  measured on a 300-frame sample) changes the TAG TEXT 03 writes. That changes every
  affected COG's bytes and `file:checksum`, and this tool would still report
  "10,100 same, 0 not" and exit 0.
  The docs present it as the gate for "any change to the Python environment" and say
  it "reports any whose bytes would change". For a non-rasterio upgrade that is a guard
  that fails toward pass. It is also the only writer check on that path, since 03
  refuses to run and #45 means `pipeline_sha` does not move.
  The fix is cheap and closes the gap without needing 03's pipeline-SHA gate:
  `load_windows()` does not call `run_constants()`, so the tool can load the windows
  once and either pass `cog.frame_tags(window[stem], stem)` to `write_cog()` instead of
  the read-back tags, or assert they equal the read-back tags before the write. I probed
  the second form, read-only: on 300 random frames, `frame_tags(window)` equals the COG's
  tags for 300/300 under the current lock. The shift has the same gap. `shift_of()` is
  fed the tag strings, not the window's `shift_x_m_3005`/`shift_y_m_3005`, so it should
  be taken from the same window row.
  Alternatively, narrow the docs to "a rasterio/GDAL change". Then a pyarrow/numpy bump
  has no writer check, and that should be said.

Nothing else found. I checked these and they hold:
- The `uv run --locked` call sites (run_pipeline.sh, test_pipeline.R, 04_s3_upload.R
  `run()`, 06_catalogue_promote.sh) propagate the child's exit status. The R
  `system()` path was measured with SystemExit(3) → 3.
- `--locked` refuses a stale lock rather than re-resolving. `pipefail` is still set.
- The pin tests in test_stacs_config.py fail loudly on a duplicate or missing stacs
  entry, a non-tag source, or a tag/commit mismatch. `.venv`'s direct_url.json matches
  uv.lock's `7e66b2a…`.
- cog_rewrite-check.py fails toward fail. An orphan COG, a missing GeoTIFF or a guard
  `SystemExit` becomes an `error:` row and exit 1. An empty tree aborts.
- No live `conda`/`environment.yml` reference is left outside planning/ and the soul
  convention lines.
