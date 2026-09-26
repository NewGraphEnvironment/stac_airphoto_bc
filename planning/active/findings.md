# Findings — Rebuild the collection on current fly (#23)

## Issue context

## Problem

The collection was last rebuilt in March under #13 (fly 0.3.0,
`rotation = "auto"`). Since then three things have changed, and the published
items have not:

1. **`fly_georef()` now refuses to write a bearing-rotated film frame without a
   per-roll `rotation`.** The corner mapping is a scanning convention it cannot
   derive. Since #20 the pipeline hands those frames to that refusal, so they land in
   the ledger as `georef_failed` (77 of 88 on `se_c`): loud and unpublished, rather than
   placed wrongly. *(Revised 2026-09-26: said "would silently skip".)*
2. **That per-roll rotation is now known for 67 of the 69** film rolls in the
   measured area (not the whole collection). 48 come from the correlator against
   reference imagery, 14 of them since confirmed by a person looking at the frames. The
   other 19 are rolls the correlator could not resolve, decided by eye. No visual check
   has contradicted the correlator. Both documented rolls (`bc5282` = 0, `bc83062` = 90)
   reproduce. It is a per-roll constant, where `aoi_rotation()` derives it per frame from
   bearing with a fixed-180 fallback. *(Revised 2026-09-25: was 49 of 69 from the
   correlator alone after a stricter acceptance gate on 2026-09-13; two rounds of
   placement review added the rest. The two still unknown could not be judged by eye.)*
3. **Digital frames are badly sized.** `bcd12008`-class 2012 frames ship an
   11,435 m footprint; the true value from the published photogrammetric solution
   is about 5,193 m. 2019 frames are wrong the other way.

Measured against reference imagery, per-frame corner RMS error. The fly 0.9 column
was built **with** the DEM (fly `9703bf8`, MRDEM-30), so it measures the rebuild as
proposed, not rotation alone:

| set | as published | fly 0.9 + DEM |
|---|---|---|
| digital 2019 | 429 m | **14 m** |
| digital 2013 | 969 m | **211 m** |
| film (paired sample) | 300 m | **193 m** |

### The DEM is tested, and it fixes size *(added 2026-09-26)*

Two independent measurements, neither of them fly checking itself:

- **Against the published photogrammetric solution** (695 frames, 1996 on): with the DEM,
  fly's footprint width agrees to **0-2%** for every sensor it can size. Without it,
  2007 film comes out at 0.86x, and 2012 digital gets **no footprint at all** (207 of 207).
  2013 and 2019 are sized from ground sample distance and the DEM does not touch them.
- **Against the orthophotos, film** (the 50 paired frames above, 37 of them before 1996):
  the correlator fits a scale as well as a shift. Published, sized from nominal scale
  with no DEM, fits at a median **0.909**, about 9% too small. fly 0.9 + DEM fits at
  **1.000**, and is closer to 1.0 on 45 of the 50 (4 ties). The scale search steps 5%, so
  this resolves the ~7-9% the DEM adds, not finer.

What is not isolated: nobody ran fly 0.9 with and without the DEM on corner RMS with
everything else held fixed, so the 300 → 193 m film gain is rotation and size together.
The fitted scale is the size half, measured on its own. fly#54 (the `FLYING_HEIGHT` unit
slip, 110 km footprints) was a real DEM-path defect and is fixed in fly 0.12.0.

## Proposed solution

Rebuild on current fly, **0.12.0 or later** (0.14.1 on 2026-09-26). No version pin:
#20 settled on asserting the capabilities the pipeline needs rather than a version, and
#30 records the fly version and SHA on every item, which is what a pinned SHA was for.
*(Revised 2026-09-26: said "fly 0.9 at a pinned SHA".)*

- fly 0.12.0's `flying_height` check (fly#54): 13 rolls carry a unit slip that sizes
  frames at ~110 km with a DEM. fly repairs them and adds `height_source`. That is #29,
  folded in here.
- georeference from the **intact window**, not a per-year subset of the selected set,
  so the bearing `fly_georef()` uses is the one the ledger records. That is #28, folded in
  here.

- per-roll `rotation` from the measured table, supplied as a **column** — the
  `rotation` *argument* does not reach bearing-rotated frames
- `fly_footprint(dem = )` — footprints grow a median 1.067x in width, and 207
  digital frames have no footprint at all without it
- digital sizing via the current digital path, not as 9-inch negatives
- **every roll ships, none is skipped.** A roll with no known rotation gets a default,
  passed by the rebuild script like any other per-roll value. `fly_georef()` refuses to
  guess a rotation, and rightly, since it records how the negative was scanned, which no
  frame can reveal. But skipping unknown rolls drops them from the collection, and keeping
  their current items keeps the per-frame bearing guess this work showed is wrong.

  The default follows the **roll series**, not the decade. A first version set it by
  decade (0 before 1970, 90 after), and the placement review proved that wrong for
  `bc5420`, `bc5440` and `bc5688`, 1970s rolls of the older series. The known rolls:

  | series | 0 | 90 | 180 | default |
  |---|---|---|---|---|
  | `bc5xxx`, through 1974 | 11 | 0 | 0 | **0** |
  | `bc5xxx`, 1975-76 | 0 | 2 | 1 | none reliable: **90, and review every roll** |
  | every other series (`bc7xxx` on, `bcb`, `bcc`) | 0 | 53 | 0 | **90** |

  A wrong default is visible, 90 degrees off, not subtly wrong. Rolls outside the measured
  area take the same rule, which assumes the convention followed the roll series rather
  than place.
- **each item records where its rotation came from**: a `rotation_source` property,
  `measured`, `reviewed` or `assumed_by_series`, so assumed frames can be filtered, checked by eye and
  corrected as measurements arrive, without a full rebuild
- **frame placement from measured shifts** *(added 2026-09-25)*: a per-frame translation,
  in **EPSG:3005 metres** (east, north), applied to each footprint **after**
  `fly_footprint()` has built it from the catalogue centroids. Not to the centroids
  before: fly takes a film frame's bearing from its neighbours' centroids, so uneven
  shifts there would turn frames, including uncorrected ones. fly centres every footprint
  on the centroid, so the translation does not depend on the fly build that measured it. Each frame's source, in order of precedence:
  `fly_georef()` takes no footprint and no shift, so the rebuild applies the translation
  to the GeoTIFF it writes, moving the EPSG:3005 origin by (east, north). The warp is
  north-up, so this is the same translation as moving the finished footprint. It will be
  checked against the review page's `shift_footprint()` output on sample frames.
  *(Decided 2026-09-26.)*

  1. **manual**: a person's call, one frame at a time
  2. **correlator**: the frame's own accepted fit against reference imagery
  3. **roll_model**: the roll's median shift, in map or along/cross-track terms, whichever
     the roll's own held-out frames favour. Used only where at least three frames outside
     the fit, with at least one in each flight direction, got closer under it (median),
     overall and within each direction, and leave-one-out over the fit frames beat no
     shift *(revised 2026-09-26: a roll whose held-out frames were all flown one way, or
     whose lines run on more than one orientation, is no longer corrected)*
  4. **none**: the centroid as catalogued

  In the measured area this corrects 252 frames by their own fit and 211 by roll model on
  3 rolls, 135 of those 211 lying outside the measured area, where the correction is
  carried along the roll untested. Every other frame keeps its centroid. Checked against the published
  photogrammetric solution, a film frame's own accepted fit, applied, agrees to a median of
  25 m (9 frames; 10 m across all 115, most of them digital). Items
  record a `placement_source` property beside `rotation_source`. Two rolls whose rotation a
  reviewer disputes get no correction until that is settled.
- **every published COG is overwritten in place; none is backed up** *(decided
  2026-09-26)*. The published COGs are known-wrong and can be rebuilt from fly
  `v0.3.0` and the openmaps JPGs. The item JSON is kept before the overwrite, and
  the rebuild is the first upload carrying `file:checksum` and run provenance, fly SHA
  included, which records per item what a pinned SHA was meant to. Both are #30.
- **the measured tables are committed here** *(decided 2026-09-26)*, in reduced form:
  roll → rotation and `rotation_source`, frame → shift and `placement_source`, each
  naming the private-repo commit it came from. The review notes stay private.
- **the rebuilt set is the union** *(decided 2026-09-26)*: every published `airp_id`
  plus anything the DEM-corrected selection adds, so no item keeps the old geometry and
  none drops out of the collection.

## Blocked on / sequencing

- ~~Decide whether to ship a partial rebuild.~~ **Decided 2026-09-24: ship every
  roll**, with unknown rolls at a per-series default and labelled (above).
- *(Revised 2026-09-25.)* Rotation has been confirmed by eye on 14 correlator-decided
  rolls and decided by eye on 19 more (item 2). **Placement** was reviewed by eye
  (2026-09-26): a frame's own fit moved it closer on all 6 frames shown. The roll model
  was mixed, and the roll where it went wrong is no longer corrected. The three rolls that
  keep a roll model are checked against the published photogrammetric solution, not by eye.
- ~~Digital sizing should be settled from the photogrammetric solution first.~~
  **Settled** (2026-09-06, measured): fly with a DEM agrees with it to 0-2% for 2012,
  2013 and 2019 (above), so digital is rebuilt once, on fly's digital path.
- #30 (checksums, run provenance, item JSON kept before overwrite) lands first, so
  the rebuild is the first hashed upload.
- NewGraphEnvironment/stac_orthophoto_bc#45: its "as published" baseline reads live S3 and must be
  frozen before this publishes.

## Notes

- #13 is the *previous* rebuild and is closed; this is its successor, not a
  reopening.
- #20 (DEM to selection, fly's reporting columns, capability not version) merged in
  PR #27. It left `aoi_dem_enabled()` off for this issue to turn on.
- The measurements behind this were made against reference imagery in a separate
  private repo; the numbers above are the shareable output.



## Planning-time measurements (2026-09-26)

- fly installed 0.11.0; fly main is 0.14.1. 0.12.0 adds `height_source` (fly#54 unit slip), 0.14.0 adds `dem_shortfall_m`, `dem_elev_sd`.
- `fly_georef()` (0.14.1) takes no shift or footprint; it footprints every row of `photos_sf` and georeferences only `fetch_result` rows — so passing the intact window fixes #28 with no fly change.
- Bucket versioning `Suspended`: the publish overwrites COGs irreversibly. Decided: no COG backup (known-wrong, rebuildable from fly v0.3.0 + openmaps JPGs); item JSON kept (#30).
- Published COGs have lost COG layout: `bcb90128_239_thumb.tif` first IFD at byte 1,920,680 of 1,921,813 after in-place tagging (`03_cog_tag.py`, `IGNORE_COG_LAYOUT_BREAK`). Recorded in #30.
- Coverage: 9,976 published items on 227 rolls; 69 rolls in the rotation table (all Neexdzii Kwa); 8,956 film items, 4,731 on measured rolls. `placement_frame.csv` covers 5,774 of the published ids.
- DEM evidence (from `stac_orthophoto_bc` `results_film_sample.csv`, accepted fits, 50 paired frames): fitted scale published 0.909 → fly09+DEM 1.000; fly09 closer to 1.0 on 45, tie 4. Pre-1996 (37): 0.909 → 1.000. Scale grid is 5%.
- Placement shifts measured under fly 9703bf8, reproduced under 5c9d87b; stored as EPSG:3005 metres, applied to the finished footprint.

## Errors Encountered

| Error | Resolution |
|-------|------------|

## fly#60 does not block (2026-09-26)

fly#60 (FLYING_HEIGHT under half of scale x focal) is being worked in parallel. Its low tail is
**0 of 8,956** published film frames (min ASL ratio 0.65, before terrain). With terrain
subtracted, frames falling below fly's 1/1.6 band and so to nominal scale: 5 / 78 / 192 at an
assumed 500 / 800 / 1,200 m ground. Those size as they do today; `height_source` marks them.
Rebuild on whatever fly is current at Phase 7.
