# se_c — Southeast BC C

Generated 2026-09-29

## Summary

- Frames in the 8 km fetch window: **1013**
- Frames selected: **102** (100 by footprint, 2 because already published)
- Year range obtained: **1967–2018**

## Selected by era

|era       | selected|
|:---------|--------:|
|1980_1999 |       70|
|2000plus  |       21|
|pre1980   |       11|

## Every frame accounted for, by era

|era       | footprint_misses_aoi| selected| no_thumbnail_url|
|:---------|--------------------:|--------:|----------------:|
|1980_1999 |                  557|       70|                0|
|2000plus  |                  237|       21|                0|
|pre1980   |                  114|       11|                3|

## How each footprint was sized

|footprint_terrain | frames|
|:-----------------|------:|
|dem_agl           |    815|
|gsd_scaled        |    188|
|nominal_scale     |     10|

- Frames with a terrain-corrected footprint: **815**
- `dem_coverage` range: **1–1**
- Frames below fly's 0.95 coverage threshold: **0**

## Where rotation, placement and height came from (selected frames)

|rotation_source   | frames|
|:-----------------|------:|
|(none: digital)   |     10|
|assumed_by_series |     89|
|reviewed          |      3|

|placement_source | frames|
|:----------------|------:|
|none             |    102|

|height_source | frames|
|:-------------|------:|
|(not judged)  |     10|
|reported      |     92|

- Rolls at `assumed_by_series`: `bc5255`, `bc78142`, `bc80079`, `bc80116`, `bc82021`, `bc88011`, `bcb00031`, `bcb90128`, `bcb90129`, `bcb94081`, `bcb95088`, `bcb96027`, `bcb99033`, `bcb99042`, `bcc04003`, `bcc04008`, `bcc95037`, `bcc959`, `bcc98035`
- Rolls at `disputed`: none
- `bc5xxx` rolls flown 1975-76, **review each by eye**: none

## Why frames were rejected

|rejected_reason      | frames|
|:--------------------|------:|
|footprint_misses_aoi |    908|
|no_thumbnail_url     |      3|
|selected             |    102|

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
