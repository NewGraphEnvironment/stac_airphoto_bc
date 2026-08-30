# se_b — Southeast BC B

Generated 2026-08-29

## Summary

- Frames in the 8 km fetch window: **840**
- Frames selected: **108**
- Year range obtained: **1972–2005**

## Selected by era

|era       | selected|
|:---------|--------:|
|1980_1999 |       57|
|2000plus  |       15|
|pre1980   |       36|

## Every frame accounted for, by era

|era       | footprint_misses_aoi| selected| digital_unknown_format| no_thumbnail_url|
|:---------|--------------------:|--------:|----------------------:|----------------:|
|1980_1999 |                  313|       57|                      0|                0|
|2000plus  |                   98|       15|                     34|                0|
|pre1980   |                  281|       36|                      0|                6|

## Why frames were rejected

|rejected_reason        | frames|
|:----------------------|------:|
|digital_unknown_format |     34|
|footprint_misses_aoi   |    692|
|no_thumbnail_url       |      6|
|selected               |    108|

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
