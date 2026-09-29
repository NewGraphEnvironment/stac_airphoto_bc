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
