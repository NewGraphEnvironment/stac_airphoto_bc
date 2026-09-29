# Findings — Grayscale georef outputs become Gray + Alpha (#36)

## Issue context

## Problem

fly's next release (NewGraphEnvironment/fly#56) changes the shape of every **grayscale** GeoTIFF `fly_georef()` writes: **1 band with `NoData=0` → 2 bands, Gray + Alpha, no NoData.** RGB is unchanged (4 bands, RGBA). The reason: under `-dstnodata 0` GDAL rewrote genuine black inside the frame as 1 so it would not read as fill. Measured on the output of the 182 calibration grayscale thumbnails: 161 frames warped axis-aligned, up to 3.6% of a frame on roll bcb94081, and 41 frames at a 30-degree bearing, up to 0.26%. It happens silently on sf's GDAL 3.8.5 and is printed as a warning by other builds, including the Windows CI runner's, which also gave masked grayscale 2 bands (fly#68). *(Body corrected 2026-09-28: an earlier version said the black was "written as nodata", quoted the source-side 3.5%, and called the shift Windows-specific. fly's own review measured all three as wrong.)*

## What breaks here

Measured by running this repo's own `write_cog()` (imported from `scripts/03_cog.py`, conda env `stac-airphoto-bc`, writing to a scratch dir) on two gray+alpha outputs from the fly branch:

```
the COG differs from fly's raster beyond the shift (count 2/2, nodata None/None,
colorinterp (gray, alpha)/(gray, undefined))
```

`check_same_raster()` refuses it, so the pipeline fails loudly on every grayscale frame rather than publishing a wrong file. The loss happens in the in-memory GTiff: rasterio ignores `mem.colorinterp = (gray, alpha)` on a 2-band dataset unless that dataset is **created with `alpha="YES"`**. With that one creation option, the COG keeps `(gray, alpha)` and mask flags `[per_dataset, alpha]`.

## To do

- [ ] In `write_cog()`, pass `alpha="YES"` in the MemoryFile profile when the last band's colorinterp is alpha. RGBA already round-trips, so check it still does.
- [ ] Update `tests/test_cog.py`. Its "grey frame with nodata 0" fixture describes the old shape.
- [ ] Republish all grayscale frames. `fly_sha` changes, so `02_georef.R` regenerates them anyway. Until then the published collection mixes 1-band and 2-band grayscale COGs.
- [ ] Before the republish, confirm COG overviews respect alpha.




## Probe (plan mode, 2026-09-28)

I reproduced this in scratch (rasterio 1.5.1, GDAL 3.12.4) on a gdalwarp `-dstalpha` output:
- **Current code:** refused, with colorinterp `(gray, alpha)/(gray, undefined)`.
- **With `profile["alpha"] = "YES"` when the last band is alpha:**
  - the COG keeps `(gray, alpha)` and mask flags `[per_dataset, alpha]`
  - the write is deterministic and `cog_layout_ok` is True
  - the x2 and x4 overviews carry alpha values `{0, 255}` only, `read_masks` equals the alpha band, and the fill fraction matches full resolution (0.490)
  - RGBA and the old 1-band `NoData=0` shape write **byte-identical** COGs, before and after the fix
- Nothing else in `scripts/` depends on band count or nodata (grep).

fly 0.19.0 released 2026-09-28 (fly#56, PR fly#79); installed here 0.15.0.

## Errors Encountered

| Error | Resolution |
|-------|------------|

## Pre-rebuild baseline (2026-09-28, fly 0.15.0 tree)

Snapshot in `data/_pre36/` (ledgers, windows, 10,100 item JSONs + collection, georef manifest).
Measured by the scratch probe `measure36.py`, which reported zero diff when run against the unchanged tree:

- COGs: 6,354 RGBA `(red, green, blue, alpha)`, no NoData; **3,746 grayscale 1-band `(gray)`, NoData 0** — the shape #36 replaces
- Ledgers: 17,529 rows; 10,254 selected (aoi, id) = 10,100 unique ids; 7,007 footprint_misses_aoi, 268 no_thumbnail_url
- height_source on selected: reported 9,474, NA 564 (digital, GSD-sized), implausible 202, corrected_unit_slip 14
- fly 0.19.0 installed from GitHub main (`0eeb977`); `tests/test_aoi.R` all pass, footprint-column check included

## Code-check (phases 1–3): four rounds, ended by enumeration

| Round | Findings | Fixed | Accepted | Inside previous fix? |
|---|---|---|---|---|
| plan review | 1 conditional blocker, 6 gaps, 5 ordering, 6 assumptions, 4 scope, 5 acceptance | see `review-plan.md` | — | — |
| 1 | 2 (overview comment credited nearest resampling, and GDAL 3.12.4 keeps alpha binary under average and cubic too; the known-issue bullet asserted a rebuild that had not happened) | 2 | 0 | — |
| 2 | 1 (Gray + Alpha + NoData 0 passed the guard; GDAL lets the NoData win, so interior black is masked again, and `check_same_raster()` can't see it because both sides carry the NoData) | 1 | 0 | n (a gap in the original guard) |
| 3 | 3 (the round-2 NoData half made the no-alpha test vacuous, since its fixture also had NoData 0; the guard checked colorinterp, which is a proxy for the mask, so 3- and 5-band sets ending in alpha passed unmasked; the Source data line was false) | 3 | 0 | **y** |

**Mechanism (round 3):** a setting or a colorinterp was credited with a property it doesn't guarantee. The guard now checks the property: every image band's `mask_flag_enums` is `[per_dataset, alpha]`.

**Enumeration that ends the loop.** `SHAPES` in `tests/test_cog.py` covers band count 1–5, with and without a trailing alpha, with and without a NoData, and each fixture's actual mask flags were printed and match its label. Mutation table:

| Mutation | Red |
|---|---|
| drop `not image` | 2 (both 1-band shapes) |
| drop `any(...)` | 5 (every refused shape with ≥2 bands) |
| drop the guard | all 7 refused shapes |
| mask over all bands, not `[:-1]` | 10 (every accepted write) |
| drop `alpha=YES` | 5 (every grey write) |

Source JPG band counts, measured: <1986 1-band 2,766, 3-band 22; ≥1986 1-band 985, 3-band 6,332. So band count follows the roll, not the year.

fly main `0eeb977` has no R/, inst/, DESCRIPTION or NAMESPACE diff from `v0.19.0`. That SHA is what `nge:fly_sha` will record.

`published.parquet` refreshed: 9,976 → 10,100 rows. The freshness guard is filed as #37.
