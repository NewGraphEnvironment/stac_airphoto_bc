# Code-check round 3: #36 (Gray + Alpha COGs)

Reviewer: subagent, 2026-09-28. Diff: `scratchpad/cc/diff3.patch` (staged `scripts/03_cog.py`,
`tests/test_cog.py`, `CLAUDE.md`, `scripts/README.md`). I ran every probe in a temp copy,
`scratchpad/r3.dDvplv`, and touched no repo file except this one.

## The mechanism

All three earlier findings share one assumption: **the attribute you set or check is
taken to determine the property you care about.** Each time, the property was
asserted from its supposed cause instead of being measured.

- Round 1: the overview alpha was said to be binary *because* `overview_resampling="nearest"`.
  The setting was the believed cause; GDAL keeps the alpha binary under any resampling.
- Round 1: "the local tree is rebuilt" was asserted from the plan, not from the files.
- Round 2: "alpha-masked" was inferred from `colorinterp[-1] == alpha`, which is a
  structural attribute. The property a reader sees is `mask_flag_enums`.

The same assumption also produces fixtures that match the author's belief. Such a
fixture cannot separate the proxy from the property, so a test built on it goes green
whether or not the guard works. Two of the findings below come from exactly that.

## Findings

- **[severity: fragile]** `scripts/03_cog.py:134`: the guard still checks a proxy.
  After round 2 it reads `colorinterp[-1] == alpha and nodata is None`. GDAL, however,
  derives an alpha mask only for **2-band and 4-band** datasets. A 3-band
  (Gray, Undefined, Alpha) or 5-band (R, G, B, Undefined, Alpha) GeoTIFF with no NoData
  passes the guard. It also passes `check_same_raster()`, because source and COG agree
  on `all_valid`. It then publishes with **no mask**: the collar reads as valid black.
  Measured on GDAL 3.12.4: `mask_flag_enums` gave `[all_valid]` on every band, the staged
  `write_cog()` **accepted** both, and `read_masks(1)` on the collar of the output COG
  gave `255` while the alpha was `0`. It is not reachable today. Every local thumbnail
  JPG is 1 or 3 bands (measured below), so fly outputs 2 or 4 bands. A 2-band or 4-band
  source would reach it.
  Fix: check the property the reader sees. Refuse unless every image band's mask is
  alpha, alongside the existing checks:
  `any(m != [MaskFlags.per_dataset, MaskFlags.alpha] for m in ds.mask_flag_enums[:-1])`.
  I applied that in the temp copy. All 57 tests pass. It refuses the 3-band and 5-band
  cases, the Gray + Alpha + NoData case (flags `[nodata]`) and the 1-band NoData case.

- **[severity: fragile]** `tests/test_cog.py:133-136` (`test_a_geotiff_with_no_alpha_band_is_refused`):
  this test cannot fail when the alpha half of the guard is removed. Your context says
  "removing ... the alpha check ... turns its tests red", and that does not hold for the
  staged code. The test's only fixture, `pre_alpha()`, also carries `NoData=0`, so the
  NoData half refuses it on its own. I mutated the temp copy to
  `if ds.nodata is not None:`, dropping the colorinterp check: **57 passed**. The
  reverse mutation, keeping only the colorinterp check, correctly turns
  `test_an_alpha_band_beside_a_nodata_is_refused` red (2 failed). So the alpha half is
  untested. It is load-bearing for a source with **no alpha and no NoData**, such as a
  1-band grey or 3-band RGB warped with neither `-dstalpha` nor `-dstnodata`, which
  `check_same_raster()` would accept. The mutation claim was most likely measured before
  round 2 added the NoData half, and not re-run afterwards.
  Fix: add a fixture with no alpha and no NoData, for example 1-band grey with no NoData.
  Mutation-test each half of the guard separately, and the mask-flag check too if it is
  adopted.

- **[severity: fragile, doc]** `CLAUDE.md` Source data, the changed line "Grayscale (1 band)
  pre-1986, RGB post-1986": the year split is false. I counted the local JPGs under
  `data/raw/thumbs` (rasterio band count, all 10,105):
  - pre-1986: 2,766 are 1-band and **22** are 3-band (1972: 11, 1980: 11).
  - 1986 onward: 6,332 are 3-band and **985** are 1-band (for example 1990: 583,
    1989: 176, 1994: 86).

  The band count follows the roll, not the year. The old wording was also wrong, and
  this diff restates the claim. Suggested fix: "1 band (grey) or 3 (RGB), by roll rather
  than by year", with the counts or a date.

## Every place the mechanism reaches, and whether each is sound now

| Place | Sound? |
|---|---|
| Guard `03_cog.py:134` | **No, but only for unreachable shapes.** It proxies on the last band being alpha plus no NoData. It misses 3-band and 5-band sources where alpha is not the mask (finding 1). Checking `mask_flag_enums` removes the proxy. |
| `check_same_raster()` | **Sound for what it claims.** It compares source to COG, including `mask_flag_enums`, and I measured that it refuses an internal-mask RGBA source whose COG mask differs. By construction it cannot see a defect the source already has, which is why the guard must test the property rather than a proxy. The docstring addition is accurate: removing `ALPHA=YES` is refused here (round 1). |
| `profile["alpha"] = "YES"` and its comment | Sound. Measured in round 1: required for 2-band, byte-neutral on RGBA. The CLAUDE.md sentence attributes the behaviour to "rasterio" where it is GDAL's GTiff driver; the code comment has it right. Not a defect. |
| `test_the_fixture_is_the_shape_fly_writes` | Sound. It asserts `mask_flag_enums` (the property), and round 1 matched the fixture to a real `-dstalpha` warp. It checks only band 1, which is enough for the 2-band and 4-band shapes it builds. |
| `test_overviews_carry_the_alpha` + CLAUDE.md overview sentence | Sound after round 1's rewording. Round 2 re-measured off-grid and diagonal edges under three resamplings. |
| `test_a_geotiff_with_no_alpha_band_is_refused` | **Not sound.** Its fixture cannot separate the two halves of the guard (finding 2). |
| `test_an_alpha_band_beside_a_nodata_is_refused` | Sound. It goes red when the NoData half is removed (measured). |
| `scripts/README.md` test row | Overstated to the same extent as finding 2. "a GeoTIFF with no alpha band ... refused" is covered only incidentally, through its NoData. |
| CLAUDE.md "COG bands (#36)" | Accurate about what the guard does. "Alpha 0 is fill" holds for every reachable shape (2-band and 4-band); it would not hold for a 3-band or 5-band shape (finding 1). |
| CLAUDE.md Source data line | **Not sound** (finding 3). |
| CLAUDE.md Known issues bullet | Sound. I measured the local georef tree now: 3,746 grey GeoTIFFs, all 1-band with `NoData=0` and mask `[nodata]`, and 6,354 RGBA. The bullet's "Once the local tree is rebuilt" is correctly future-tense. |

## Checked and not flagged

- The guard's order: CRS, then rotation, then shape. The rotated-geotransform test still
  hits its own refusal.
- An internal per-dataset mask plus an alpha band: the guard passes it (mask flags
  `[per_dataset]`), but `check_same_raster()` refuses it because the COG mask differs.
  It fails toward refusal.
- No security issues.

## Verdict

No bug that ships wrong output from today's inputs. The findings are three fragile items. Two
are the same mechanism as before: the guard still proxies, and one of its tests cannot
reach the half it names. The third is a doc claim that the local data contradicts.
