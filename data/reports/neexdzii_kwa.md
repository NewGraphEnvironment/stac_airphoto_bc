# neexdzii_kwa — Neexdzii Kwa (Upper Bulkley)

Generated 2026-09-29

## Summary

- Frames in the 8 km fetch window: **14858**
- Frames selected: **9824** (9655 by footprint, 169 because already published)
- Year range obtained: **1968–2019**

## Selected by era

|era       | selected|
|:---------|--------:|
|1980_1999 |     6140|
|2000plus  |     1844|
|pre1980   |     1840|

## Every frame accounted for, by era

|era       | footprint_misses_aoi| selected| no_thumbnail_url|
|:---------|--------------------:|--------:|----------------:|
|1980_1999 |                 3211|     6140|                0|
|2000plus  |                  767|     1844|                0|
|pre1980   |                  807|     1840|              249|

## How each footprint was sized

|footprint_terrain | frames|
|:-----------------|------:|
|dem_agl           |  13816|
|gsd_scaled        |    826|
|nominal_scale     |    216|

- Frames with a terrain-corrected footprint: **13816**
- `dem_coverage` range: **1–1**
- Frames below fly's 0.95 coverage threshold: **0**

## Where rotation, placement and height came from (selected frames)

|rotation_source   | frames|
|:-----------------|------:|
|(none: digital)   |   1027|
|assumed_by_series |   4124|
|disputed          |    252|
|measured          |   2470|
|reviewed          |   1951|

|placement_source | frames|
|:----------------|------:|
|correlator       |    252|
|none             |   9459|
|roll_model       |    113|

|height_source       | frames|
|:-------------------|------:|
|(not judged)        |    554|
|corrected_unit_slip |      2|
|implausible         |    192|
|reported            |   9076|

- Rolls at `assumed_by_series`: `bc5423`, `bc7359`, `bc7360`, `bc7361`, `bc7362`, `bc7481`, `bc7483`, `bc7708`, `bc7726`, `bc7739`, `bc7745`, `bc7746`, `bc7747`, `bc7796`, `bc7824`, `bc80031`, `bc80132`, `bc81048`, `bc83046`, `bc84036`, `bc84041`, `bc84044`, `bc85072`, `bc86048`, `bc87062`, `bc89033`, `bc89041`, `bc89062`, `bc89073`, `bc89074`, `bcb90062`, `bcb90063`, `bcb90064`, `bcb90097`, `bcb90099`, `bcb90102`, `bcb94027`, `bcb94045`, `bcb94046`, `bcb94050`, `bcb96032`, `bcb96049`, `bcb96068`, `bcb96103`, `bcb96105`, `bcc01004`, `bcc03008`, `bcc05056`, `bcc05057`, `bcc05064`, `bcc05065`, `bcc06039`, `bcc06043`, `bcc06044`, `bcc06054`, `bcc06142`, `bcc07021`, `bcc07052`, `bcc07054`, `bcc07055`, `bcc07067`, `bcc1041`, `bcc430`, `bcc432`, `bcc687`, `bcc765`, `bcc806`, `bcc90025`, `bcc90039`, `bcc90040`, `bcc90046`, `bcc90047`, `bcc92102`, `bcc93036`, `bcc93055`, `bcc93056`, `bcc93057`, `bcc93066`, `bcc94061`, `bcc94067`, `bcc94069`, `bcc94070`, `bcc94071`, `bcc94073`, `bcc94113`, `bcc96049`, `bcc96050`, `bcc96063`, `bcc96071`, `bcc96114`, `bcc96122`, `bcc96123`, `bcc96138`, `bcc96141`, `bcc96154`, `bcc96155`, `bcc97146`, `bcc97147`, `bcc97149`, `bcc97160`, `bcc98018`, `bcc98019`, `bcc98020`, `bcc98024`, `bcc98039`
- Rolls at `disputed`: `bc81050`, `bcc668`
- `bc5xxx` rolls flown 1975-76, **review each by eye**: `bc5671`, `bc5688`, `bc5710`

## Why frames were rejected

|rejected_reason      | frames|
|:--------------------|------:|
|footprint_misses_aoi |   4785|
|no_thumbnail_url     |    249|
|selected             |   9824|

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
