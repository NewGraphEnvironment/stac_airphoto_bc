# se_c — Southeast BC C

Generated 2026-08-29

## Summary

- Frames in the 8 km fetch window: **1013**
- Frames selected: **78**
- Year range obtained: **1967–2004**

## Selected by era

|era       | selected|
|:---------|--------:|
|1980_1999 |       62|
|2000plus  |        7|
|pre1980   |        9|

## Every frame accounted for, by era

|era       | footprint_misses_aoi| selected| digital_unknown_format| no_thumbnail_url|
|:---------|--------------------:|--------:|----------------------:|----------------:|
|1980_1999 |                  565|       62|                      0|                0|
|2000plus  |                   48|        7|                    203|                0|
|pre1980   |                  116|        9|                      0|                3|

## Why frames were rejected

|rejected_reason        | frames|
|:----------------------|------:|
|digital_unknown_format |    203|
|footprint_misses_aoi   |    729|
|no_thumbnail_url       |      3|
|selected               |     78|

Rejection reasons:

- `digital_unknown_format` — a digital frame. `fly` (>= 0.4.0) will not
  size a footprint it cannot derive, because a sensor's width is not in
  the centroid metadata (fly#32). These are the frames the published
  Neexdzii Kwa collection sized as 9-inch negatives, which is why one of
  them ships an 11,435 m footprint. Excluding them stops shipping that.
- `footprint_misses_aoi` — sized, but the ground footprint does not reach
  the AOI. Expected: the window is buffered by 8 km precisely so no
  overlapping frame is missed, and most of that buffer does not overlap.
- `no_thumbnail_url` — the catalogue has no thumbnail for this frame.
- `fetch_failed` / `georef_failed` — the frame was selected and the
  pipeline could not produce an asset for it.
