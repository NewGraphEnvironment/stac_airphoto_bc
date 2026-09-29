# Code-check round 2 — #36 (Gray + Alpha COGs)

Reviewer: subagent, 2026-09-28. Diff: staged `scripts/03_cog.py`, `tests/test_cog.py`,
`CLAUDE.md`, `scripts/README.md`. Probes ran in a scratchpad copy; no repo file touched
except this one.

## Findings

- **[severity: fragile]** `scripts/03_cog.py:133` — the new guard checks a proxy
  (the last band is alpha), not the property #36 exists for (interior black is not
  masked). A GeoTIFF that is Gray + Alpha **and** carries `NoData=0` passes the guard,
  passes `check_same_raster()` (the source and the COG agree, both having NoData), and
  is published with interior black masked. That is the defect #36 fixes. GDAL gives
  NoData precedence over alpha, so the mask flags are `[nodata]` and not `[per_dataset, alpha]`.
  Measured, GDAL 3.12.4 via the `stac-airphoto-bc` env: a 2-band Gray + Alpha GeoTIFF
  written with `alpha="YES", nodata=0` and a 5x5 block of 0 inside the frame gives
  `mask_flag_enums ([nodata], [nodata])`, and `write_cog()` **accepts** it. The COG
  masks all 25 interior pixels.
  CLAUDE.md's new "COG bands (#36)" section says "Every COG ends in an alpha band and
  carries no NoData" and that `03_cog.py` refuses the old shape, but the code enforces
  only the first half. fly 0.19.0 writes no NoData (round 1), so nothing is broken
  today. The guard does not fire, though, if a later fly, or a `-dstnodata` left in
  place beside `-dstalpha` (the pair `code-check-spatial.md` warns about), brings the
  NoData back. Fix: also refuse `ds.nodata is not None`. Stronger: refuse unless
  every entry of `ds.mask_flag_enums` is `[MaskFlags.per_dataset, MaskFlags.alpha]`,
  which checks the property a reader sees.

## Checked and not flagged

- **Round 1 fix 1 (overview wording):** it holds. I re-measured with a collar edge
  that does not align with the overview factors (row 63) and a diagonal edge, on 2048²,
  with `nearest`, `average` and `cubic`. The alpha stays exactly {0, 255} at every
  level, and `read_masks` equals the alpha. The test's `read(out_shape=...)` really
  reads the overview: it is array-equal to an `OVERVIEW_LEVEL=i` open. So the test pins
  what it now claims, and the CLAUDE.md sentence "GDAL keeps it binary whatever
  `overview_resampling` says" matches the measurement.
- **Round 1 fix 2 ("Once the local tree is rebuilt..."):** it reads correctly.
- **Partial writes on refusal:** the guard sits in the per-file write loop, but a GeoTIFF
  from an older fly fails `vouched()` (fly_sha) before any write, unless every window
  was built on that older fly. In that case grey years sort first under `thumbs/{year}/`,
  so the run aborts on the first frame. It does not leave a mixed tree.
- **Downstream:** `stac_validate.py`, `05_stac_register.py` and `airphoto_props.py` read
  no band count, NoData or colorinterp.
