# se_a — Southeast BC A

Generated 2026-09-26

## Summary

- Frames in the 8 km fetch window: **818**
- Frames selected: **167** (119 by footprint, 48 because already published)
- Year range obtained: **1972–2005**

## Selected by era

|era       | selected|
|:---------|--------:|
|1980_1999 |       87|
|2000plus  |       23|
|pre1980   |       57|

## Every frame accounted for, by era

|era       | footprint_misses_aoi| selected| no_thumbnail_url|
|:---------|--------------------:|--------:|----------------:|
|1980_1999 |                  285|       87|                0|
|2000plus  |                  102|       23|                0|
|pre1980   |                  255|       57|                9|

## How each footprint was sized

|footprint_terrain | frames|
|:-----------------|------:|
|dem_agl           |    793|
|gsd_scaled        |     18|
|nominal_scale     |      7|

- Frames with a terrain-corrected footprint: **793**
- `dem_coverage` range: **1–1**
- Frames below fly's 0.95 coverage threshold: **0**

## Where rotation, placement and height came from (selected frames)

|rotation_source   | frames|
|:-----------------|------:|
|assumed_by_series |    167|

|placement_source | frames|
|:----------------|------:|
|none             |    167|

|height_source       | frames|
|:-------------------|------:|
|corrected_unit_slip |      6|
|implausible         |      5|
|reported            |    156|

- Rolls at `assumed_by_series`: `bc5674`, `bc5675`, `bc7434`, `bc77033`, `bc77034`, `bc77108`, `bc78107`, `bc78142`, `bc79058`, `bc80055`, `bc80108`, `bc81034`, `bc81035`, `bc81106`, `bc82035`, `bc88029`, `bc88030`, `bcb00003`, `bcb93015`, `bcb93018`, `bcb95088`, `bcc04024`, `bcc04025`, `bcc05001`, `bcc273`, `bcc72`, `bcc73`, `bcc74`, `bcc837`, `bcc838`, `bcc839`
- Rolls at `disputed`: none
- `bc5xxx` rolls flown 1975-76, **review each by eye**: `bc5674`, `bc5675`

## Why frames were rejected

|rejected_reason      | frames|
|:--------------------|------:|
|footprint_misses_aoi |    642|
|no_thumbnail_url     |      9|
|selected             |    167|

Rejection reasons:

- `no_footprint` — `fly` could not size this frame, so it has no ground
  footprint to select on. Keyed on `footprint_terrain` being absent, which
  is the property itself; it used to be keyed on a `footprint_basis` string
  fly stopped writing once it could size digital frames, and those frames
  then fell through to `footprint_misses_aoi` — reported as *sized, but
  missing the AOI* for a frame that was never sized at all.
- `footprint_misses_aoi` — sized, but the ground footprint does not reach
  the AOI. Expected: the window is buffered by 8 km precisely so no
  overlapping frame is missed, and most of that buffer does not overlap.
- `no_bearing` — a film frame with no adjacent roll neighbour in the window,
  so fly draws its footprint axis-aligned. Its per-roll rotation would place
  the picture as though the aircraft flew due north, so it is withheld.
- `no_thumbnail_url` — the catalogue has no thumbnail for this frame.
- `fetch_failed` / `georef_failed` — the frame was selected and the
  pipeline could not produce an asset for it.
