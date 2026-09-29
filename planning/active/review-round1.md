# Code-check review — round 1 (#36, staged diff)

Reviewer: subagent, 2026-09-28. All probes ran in a temp copy
(`scratchpad/rv.uoofyd`); nothing in the repo was modified except this file.

## Findings

- **[fragile] tests/test_cog.py `test_overviews_carry_the_alpha` (and CLAUDE.md "COG bands (#36)", last sentence)** —
  the test says "Nearest resampling must keep alpha binary", and CLAUDE.md says
  "Overviews are nearest-resampled, so their alpha stays 0/255 and matches the mask
  (`tests/test_cog.py`)". The test cannot fail on the resampling it names. Mutation,
  temp copy: `COG_OPTIONS["overview_resampling"]` set to `average`, `bilinear` and
  `cubic` in turn, and both parametrisations still pass. A direct probe with a collar
  edge moved off the power-of-two grid (alpha 0 for rows < 61, not 64), read at
  `overview_level=0`, still gave alpha `{0, 255}` under `cubic`. So on this
  GDAL/rasterio (3.12.4 / 1.5.1) the COG driver keeps the alpha overview binary
  whatever `overview_resampling` says. The causal claim in CLAUDE.md ("are
  nearest-resampled, so") is not what makes the alpha binary, and the test pins
  "alpha overviews exist and match the mask", not the resampling. Nothing ships wrong
  today. But the doc sentence and the test comment claim a guard that does not exist.
  If the intent is only "overviews carry a binary alpha that the mask follows",
  reword both. If the intent is to pin nearest resampling, the test needs to assert
  something that changes with resampling, such as a grey-band overview value at an
  edge.

- **[fragile, doc] CLAUDE.md Known issues, new bullet** — "The local tree is rebuilt
  on fly 0.19.0 (Gray + Alpha)" is false at this commit. The newest local grey
  GeoTIFF, `data/raw/georef/thumbs/1978/bc78142_072_thumb.tif` (mtime Sep 26), is
  still 1 band, `NoData=0`. Until `02_georef.R` re-runs, `03_cog.py` now refuses the
  whole local grey tree. That refusal is intended. You said the rebuild follows this
  commit, so this is only wrong if the commit lands without it. Either land the
  bullet with the rebuild, or phrase it as "is to be rebuilt".

## Checked and fine

- **The guard's premise against real fly output.** A thumbnail warped with
  `-t_srs EPSG:3005 -r bilinear -dstalpha` through `sf::gdal_utils("warp")` (sf's
  GDAL 3.8.5, which is fly's path) and through GDAL 3.13 reads back as 2 bands,
  `Gray, Alpha`, no NoData, mask `PER_DATASET ALPHA`, ExtraSamples `unassoc-alpha`.
  That is exactly the `fly_like()` fixture. `fly_georef_warp_opts()` (fly 0.19.0)
  appends `-dstalpha` unconditionally: masked (`-srcalpha`), `srcnodata` fallback and
  unmasked legs alike. So no legitimate fly 0.19.0 output lacks an alpha last band. A
  4-band unmasked source would warp to 5 bands, still ending in alpha.
- **`ALPHA=YES` on RGBA.** `write_cog()` on a real local RGBA GeoTIFF
  (`2018/bcd18704_628_25_8bit_rgb.tif`, unassoc alpha) gives **byte-identical**
  output with and without `profile["alpha"] = "YES"`. So there is no checksum churn
  and no ExtraSamples change on the RGBA path.
- **`ALPHA=YES` on grey.** Remove it and a real Gray + Alpha frame is refused by
  `check_same_raster()` (colorinterp mismatch), as the comment says. The output with
  it is Gray + Alpha, ExtraSamples `unassoc-alpha`, `min-is-black`, overviews [2, 4].
- **Profile conflicts.** `ds.profile` carries no NoData for fly 0.19.0 output, and no
  `photometric` that fights `alpha`. A NoData that did appear would be compared by
  `check_same_raster()` on every file anyway.
- **16-bit.** Not reachable: the thumbnails are 8-bit JPGs, and `fly_mask()` declines
  non-8-bit sources. `ALPHA=YES` is dtype-agnostic in any case.
- **`test_a_geotiff_with_no_alpha_band_is_refused`** reaches the new guard. Without
  it, a 1-band NoData 0 source passes `write_cog()` (`ALPHA=YES` is ignored with no
  extra samples, and `check_same_raster()` is satisfied), so the test is red on the
  mutation.
- **Order of refusals.** The CRS and rotation checks precede the alpha check, so
  `test_a_rotated_geotransform_is_refused` (1-band fixture) still hits its own
  refusal.
- **Downstream stages.** Nothing in `05_stac_register.py`, `stac_validate.py`,
  `airphoto_props.py` or `04_s3_upload.R` depends on band count, NoData or
  colorinterp.

## Verdict

No bug or security issue. Two fragile items, both about documentation and test claims
rather than behaviour.
