# se_a — Southeast BC A

Generated 2026-08-29

## Summary

- Frames in the 8 km fetch window: **818**
- Frames selected: **109**
- Year range obtained: **1972–2005**

## Selected by era

|era       | selected|
|:---------|--------:|
|1980_1999 |       55|
|2000plus  |       14|
|pre1980   |       40|

## Every frame accounted for, by era

|era       | footprint_misses_aoi| selected| digital_unknown_format| no_thumbnail_url|
|:---------|--------------------:|--------:|----------------------:|----------------:|
|1980_1999 |                  317|       55|                      0|                0|
|2000plus  |                   93|       14|                     18|                0|
|pre1980   |                  274|       40|                      0|                7|

## Why frames were rejected

|rejected_reason        | frames|
|:----------------------|------:|
|digital_unknown_format |     18|
|footprint_misses_aoi   |    684|
|no_thumbnail_url       |      7|
|selected               |    109|

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
