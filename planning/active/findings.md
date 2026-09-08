# Findings — Selection does not use a DEM, discards fly's reporting columns, and pins no fly version (#20)

## fly API, measured 2026-09-07 against `~/Projects/repo/fly` (HEAD `5d95a1c`)

| | version |
|---|---|
| Working tree | **0.10.0** (`fly/DESCRIPTION:3-4`, dated 2026-09-06) |
| Installed here | **0.5.0** (`~/Library/R/arm64/4.5/library/fly`, built 2026-08-30) |

The install carries no `Packaged:` and no `Remote*` fields, so it is a plain
`R CMD INSTALL .` of the working tree as it stood at the v0.5.0 tag — not CRAN, not a
tarball, not `remotes`/`pak`. v0.5.1, 0.6.0, 0.7.0, 0.7.1, 0.8.0, 0.9.0 and 0.10.0 have
all landed since. **Signatures are identical between 0.5.0 and 0.10.0** for
`fly_footprint()`, `fly_filter()` and `fly_georef()`, so a signature check cannot
reveal the staleness — only behaviour and exports can.

### `dem` reaches selection because `fly_filter()` takes it

`fly_filter()` already has the argument — `fly/R/fly_filter.R:28-29` — and forwards it
to `fly_footprint()` at `fly/R/fly_filter.R:50`. It passes **only** `dem`;
`negative_size` and `format_size` are not exposed. So the issue's fix 1 needs no
upstream change.

`fly_georef()` takes it too (`fly/R/fly_georef.R:160-162`) and sizes its own footprints
at `fly/R/fly_georef.R:183`. That is why the DEM has to reach 02_georef.R as well: a
DEM in selection but not in georef publishes a GeoTIFF whose footprint disagrees with
the one that selected it. The issue does not name this.

### What `fly_footprint()` returns

Assigned at `fly/R/fly_footprint.R:986-1001`, into the dropped-geometry frame rather
than as trailing `st_sf()` arguments — that assignment *is* the fly#35 fix.

| column | type | values |
|---|---|---|
| `footprint_basis` | character | the frame's `media` verbatim, or `inferred_format` / `assumed_default` / `unknown_format` |
| `footprint_terrain` | character | `nominal_scale`, `gsd_scaled`, `dem_agl`, `no_dem_coverage`, `NA` where there is no footprint |
| `height_agl` | numeric | metres above ground; `NA` unless DEM-corrected |
| `dem_coverage` | numeric | fraction in [0,1], `pmin(1, got/expected)` (`fly_footprint.R:237`); `0` is a measured zero, `NA` means no DEM or no footprint |

Two more not in the issue: `width_source` (character, names the calibration file or the
refusal reason) and `footprint_bearing` (numeric azimuth, added 0.9.0).

`dem_coverage` is the check on the DEM buffer, not the buffer arithmetic — fly warns
below `fly_dem_coverage_min()` = 0.95 (`fly_footprint.R:176`, `:888-900`).

### `dem` accepts a SpatRaster

`fly/R/fly_footprint.R:601-624`: a `terra::SpatRaster` passes through as-is; anything
else goes to `terra::rast()`, so a path or `/vsicurl/` URL both work. A CRS is
required. `flying_height` and `focal_length` columns are required on the centroids when
`dem` is supplied — both present in the 29-column catalogue row.

**There is no DEM-fetching helper in fly.** It takes a URL the caller already has.
fly documents MRDEM-30 as the recommended default (`fly_footprint.R:526-537`) — the
same raster `flooded::fl_dem_aoi()` defaults to.

### Buffer guidance

`fly/R/fly_footprint.R:539-553`: extent matters more than resolution, and the buffer
must clear the **corner** of the widest footprint — `half_side * sqrt(2)`, not
`half_side`. The widest film footprint on this collection is 7,242 m (`CLAUDE.md:163`),
so `3621 * sqrt(2)` = **5,121 m** past the fetch window. Allow extra, because the
correction enlarges footprints before the second sampling pass.

## Why the guard names no version at all

**Superseded, and kept because the reasoning moved twice.** The issue prescribes a
floor of `>= 0.6.0`. A version *window* `[0.6.0, 0.9.0)` was designed and then
dropped; what shipped is a capability assert with no version comparison in it.

The floor is stale: #20 was filed **2026-08-30**, the day fly 0.6.0 and 0.7.0 shipped,
and never edited. 0.7.1, 0.8.0 (09-01), 0.9.0 (09-02) and 0.10.0 (09-07) landed after
it, and #23 — filed 09-06 — wants fly 0.9 at a pinned SHA.

The window was dropped for two reasons:

1. It would have pinned this repo to **0.8.0**, superseded on 09-02, which #23 lifts
   within its own scope.
2. Its main justification was overstated. `fly_georef()` returns `success = FALSE` for
   a rotated film frame with no per-roll rotation (`fly/R/fly_georef.R:284`), and
   `02_georef.R:94-96` folds that into the ledger as `georef_failed`. fly refuses
   loudly by itself, so a ceiling here is a second copy of that refusal — and the copy
   that goes stale. `CLAUDE.md`, "Assert capabilities, not versions".

What survives from that analysis, and is now **measured** rather than reasoned:

- At fly ≥ 0.9, `fly_bearing()` returns `NA_real_` for a frame with no *adjacent*
  neighbour by `frame_number` (`fly/R/fly_bearing.R:105`). The 8 km window is a spatial
  subset of every roll, so gaps are routine and those frames fall to `aoi_rotation()`'s
  fixed 180°. Measured on `se_c`: 3 of 810 film frames have no bearing.
- 0.9.0 changed the **meaning** of the `rotation` column — it used to shift corners on
  an axis-aligned square and now shifts them on a ring already rotated onto the
  bearing. `aoi_rotation()` is calibrated against the old meaning, so film
  georeferencing is not settled by this issue. #23 owns it and has the per-roll table.

## What upgrading fly changes on its own

Not nothing, and it must not be mistaken for a regression when the ledger is diffed.
Measured end to end below.

- **0.6.0 sizes digital frames** (fly#32) from `pixel count x ground_sample_distance`,
  so frames previously rejected as unsizeable gain footprints and become selectable.
- 0.6.0 also records that the catalogue's `SCALE` gives **34% of true width** on a
  digital frame, measured on 40 UltraCam Eagle frames — which is why digital is sized
  from GSD rather than from scale.
- **0.8.0 refuses non-POINT geometry everywhere** (fly#37). `aoi_centroids_as_sf()`
  builds POINT, so this is a no-op here — and it is now the *reason* that function
  keeps its `st_as_sf(coords = )` step, not merely a convenience.
- **0.9.0 rotates film footprints too**, so film selection moves. The issue body's
  premise that 0.6.0 leaves film unchanged held only through 0.8.x.

## Local state, 2026-09-07

Only the 235 southeast frames exist on this machine. `data/centroids/`,
`data/selected/`, `data/select/` and `data/logs/` hold `se_a`, `se_b`, `se_c` only —
neexdzii_kwa has no cache, no thumbnails and no ledger here, which is why re-deriving
both regions is #23's campaign and not this issue's.

`data/reports/*.md` are the only tracked artifacts under `data/` (`.gitignore:1-9`) and
they describe the **published** collection. A verification run rewrites them to describe
a selection nobody published.

## Verification measurements, fly 0.10.0, `se_c` (1,013 frames)

### `fly_footprint()` row alignment — the riskiest assumption in the change

`01_fetch.R` assigns four columns onto `window` **by position** and derives
`cand_ids` from the same object. If `fly_footprint()` reordered or dropped rows,
every column would misalign silently and the candidate set would name the wrong
frames. Measured rather than read:

```
nrow in : 1013      nrow out: 1013
airp_id IDENTICAL and in order: TRUE
film_roll aligned: TRUE     frame_number aligned: TRUE
```

### Replacing `fly_filter()` with one `st_intersects()` is set-identical

`fly_filter()` builds its own footprints (`fly/R/fly_filter.R:50`), so using it
would leave two derivations of one fact — the defect #20 exists to remove. The
replacement was proven equivalent, not assumed:

```
st_intersects n: 91      fly_filter n: 91
SAME SET: TRUE           symmetric difference: 0
```

91 candidates minus the 3 frames with no thumbnail URL is the 88 the ledger
marks `selected`.

### DEM off vs on — the deterministic check

"The selected set must differ" was the plan's original assertion and it is a bad
one: fly 0.6.0's digital sizing moves the set too, so it passes for the wrong
reason, and a small AOI with no frame near the boundary could leave it unmoved
with the plumbing correct. Replaced with a signal only a DEM can produce.

| | DEM off (delivered) | DEM on |
|---|---|---|
| `footprint_terrain` values | `nominal_scale`, `gsd_scaled` | `dem_agl`, `gsd_scaled` |
| rows with `height_agl` | 0 | 825 |
| `selected` | 88 | 104 |
| unsized (`no_footprint`) | 15 | 0 |

`dem_coverage`: n = 825, min **0.9754**, median **1.0**, **0** frames below
fly's 0.95 threshold — so the 6 km corner allowance on top of the 8 km fetch
buffer is measured adequate rather than reasoned adequate. `height_agl` ranges
732–10,253 m.

The 15 frames fly cannot size from GSD all gain footprints under a DEM, which is
what fly's own warning predicts: *"a digital frame needs either a
`ground_sample_distance` and a calibrated pixel count, or `dem` together with
`flying_height` and `focal_length`"*.

### Upgrading fly 0.5.0 → 0.10.0 moves selection on its own

Reconciled against the fly 0.5.0 ledger preserved before the upgrade. 215 of
1,013 rows changed outcome, and every one is accounted for:

| | old | new |
|---|---|---|
| `digital_unknown_format` / `no_footprint` | 203 | 15 |
| `footprint_misses_aoi` | 729 | 907 |
| `selected` | 78 | 88 |
| `no_thumbnail_url` | 3 | 3 |

- **203 digital frames** move: 188 gain a footprint (178 then miss the AOI, 10
  are selected) and 15 remain unsized. fly 0.6.0, fly#32.
- **12 film frames** move, 6 each way. This is the part the #20 issue body did
  not anticipate — it says 0.6.0 leaves film output unchanged, which held only
  through 0.8.x. fly 0.9.0 rotates every footprint onto its flight line, and all
  12 movers are on diagonal bearings (46°, 48°, 84°, 115°, 145°, 169°, 226°,
  242°, 260°, 263°, 264°, 264°) — exactly where a rotated square overlaps its
  axis-aligned self by only 83%.

### The rotation mask works

`rotation` is non-`NA` on all 810 film frames and `NA` on all 203 digital ones,
so `fly_georef()` now reaches `fly_digital_rotation()` for digital frames instead
of being overridden by a film-derived 180.

`02_georef.R se_c` then georeferenced **88/88**, including the 10 digital 2018
frames that fly 0.5.0 could not size at all.

## Errors Encountered

| Error | Resolution |
|-------|------------|
| Proposed `bcmaps::cded_terra()` as the DEM source without searching the org for the verb | `flooded::fl_dem_aoi()` already exists — MRDEM-30 default, crop before reproject, returns a SpatRaster. User caught it. `karpathy.md` §7, "Not finding it is not evidence it does not exist". |
| Designed a fly version *window* `[0.6.0, 0.9.0)`, which would have pinned the repo to a release superseded five days earlier | The user asked whether the issue was out of date. It was — filed the day 0.6.0 shipped, five releases back. Replaced with a capability assert carrying no version at all. |
| `git checkout -- scripts/02_georef.R` to undo a test mutation silently restored the **staged** copy, discarding the DEM thread and the hoisted ledger check | `git checkout <path>` reinstates from the index, not `HEAD`. Re-applied by script. Back up to the scratchpad before mutating, and prefer restoring from that copy. |
| A first version of the ledger schema test built its fixture from `aoi_ledger_cols()` — the function under test — so the assertion was `setdiff(x, x)` and appending a bogus column left the suite green | The schema is a contract this repo chose, so the expectation is hardcoded independently. Proven by mutation: the bogus column now reddens two assertions. |

## Round 3: the rotation column was disarming fly's own refusal

The most expensive finding of the issue, and it inverted a result reported
earlier in this session as a success.

`02_georef.R se_c` was reported as **88/88 georeferenced**, including film. That
was two errors stacked:

1. **The run was the warm path.** `fly_georef(overwrite = FALSE)` skips a GeoTIFF
   already on disk, and the tree was populated from an earlier run. Cleared and
   re-run cold, the same command gives **11 of 88**.
2. **The 88 were only written because this pipeline disarmed fly's safety
   refusal.** fly 0.9.0 rotates every film footprint onto its flight line and
   then refuses such a frame unless the caller supplies that roll's rotation,
   because the corner mapping is a per-roll camera-mount property it cannot
   derive. A user `rotation` column is the highest-precedence input
   (`fly/R/fly_georef.R:316, :321, :345`) and short-circuits the refusal.

Measured on 11 real 1995 film frames:

| | written | warnings |
|---|---|---|
| with the `rotation` column | 11/11 | 0 |
| with `rotation` set to `NA` | **0/11** | 11 film refusals |

And the supplied value is wrong by construction. `aoi_rotation()` derives it per
frame from bearing; the property is a per-roll constant. On `se_c`, **34 of 48
rolls** receive two to four different values:

```
bcb94081  43 frames  4 distinct rotations
bcc95037  80 frames  3
bc80140   60 frames  3
bcc98035  39 frames  3
```

At most one value per roll can be right. The failure direction is the expensive
one — a valid GeoTIFF, correct CRS, correct ground, picture turned a quarter or
half turn, `success = TRUE`, `selected` in the ledger, nothing reporting it.

**This also invalidated the reasoning for dropping the fly version ceiling.** The
argument put to the user was that a ceiling duplicates a refusal *fly already
makes loudly*. fly does make it — and this pipeline was suppressing it, so the
ceiling was protecting something real. Put back to the user with the measurement;
they chose to stay on fly 0.10.0 and let fly refuse.

### Delivered behaviour

`aoi_rotation_ok()` supplies a rotation only where fly has **not** rotated the
ring (`is.na(footprint_bearing)` — fly's own routing condition) and only for
film. Measured cold on `se_c`:

| | n |
|---|---|
| `rotation` supplied | **3** (film, unrotated ring) |
| withheld — rotated film | 807 |
| withheld — digital | 203 |
| georeferenced | **11 of 88** (10 digital 2018 + 1 film) |
| `georef_failed` | 77, every one film, zero digital |

Ledger partitions 907 + 77 + 15 + 3 + 11 = 1,013.

## Round 3: fly reports six columns, not four

`aoi_footprint_cols()` was written against fly 0.5.1 and named four. fly 0.10.0
returns **six** — `width_source` (0.6.0) and `footprint_bearing` (0.9.0) were
being dropped by the very transmute #20 exists to fix. The guard could not see
it, because its expected set is the same literal the code assigns from. Both are
now carried; the ledger is 15 columns.

## Errors Encountered (round 3)

| Error | Resolution |
|-------|------------|
| Reported "88/88 georeferenced" as a success. It was the warm path over a populated tree, and the frames only wrote because fly's refusal was disarmed | Clear the outputs and measure the cold path. `code-check.md`, "Test the cold/create path of idempotent code, not just the warm no-op". |
| Told the user a version ceiling was unnecessary because "fly already refuses loudly by itself" | Measurably false — the refusal was suppressed by the `rotation` column this pipeline supplies. Re-put to the user with the measurement. |
| Three test assertions passed on text that was a comment or an input reference rather than a declaration | Strip comments before scanning, cut the transmute at `rejected_reason =`, and prove each with the mutation that defeated the original. |

## Rounds 4 and 5: the guards were put where they could not run

Round 4 found no bugs and named the residue as one axis — *"every remaining
instance is a guard reading repo text or a repo literal where a real fly object is
already in hand"* — and prescribed closing them all in the block that loads that
object. Following that prescription introduced the next defect: **that block is
gated on `data/centroids/se_c.parquet`, which is gitignored.** Exposure went from
one assertion to five, and a fresh clone printed `All assertions passed.` while
silently running none of them.

Measured on a fresh-clone state (cache moved aside), before the fix:

| mutation | with cache | fresh clone |
|---|---|---|
| `aoi_dem_coverage_min()` 0.95 → 0.42 | RED | **GREEN** |
| drop `dem_coverage` from `aoi_footprint_cols()` | RED | **GREEN** |

The close was to read fly's facts from the **installed package** rather than from a
data file: `fly:::fly_dem_coverage_min()` for the threshold, and
`deparse(fly::fly_footprint)` for the terrain vocabulary. Neither needs a cache, so
both now run everywhere. Only `aoi_footprint_cols()`'s completeness genuinely needs
a real window, and that skip is named and counted.

After: a fresh clone runs **82** assertions against 77, names all four skips, and
the summary reads `All assertions passed (4 skipped).`

### One defect, five spellings

The "is this stage guarded" scan was defeated four times in a row, each fix closing
one spelling:

| round | spelling | closed by |
|---|---|---|
| 2 | total removal | the scan itself |
| 3 | whole-line comment | strip comment lines |
| 4 | **trailing** comment on a code line | `deparse(parse(f))` |
| 5 | mention inside a **string literal** | `all.names(parse(f))` — ask for a *call* |

A wider regex was never the fix — `sub("#.*", "", line)` truncates a `#` inside a
string literal, and `01_fetch.R` has one. Asking the parse tree for a symbol is the
form with no next spelling: a string constant is not a symbol.

### Other round-5 findings, all closed

- **[bug]** `aoi_dem_coverage_min()`'s docstring had been inserted *inside*
  `aoi_terrain_values()`'s, leaving the vocabulary undocumented and `0.95`
  explained by an argument about terrain routes. Split.
- The `tryCatch` around `fly:::fly_dem_coverage_min()` downgraded a fly **rename**
  to a benign SKIP — disarming the pin on the one event that makes the copy stale.
  Removed; a missing internal is now a failure.
- A syntax error in any stage script aborted the suite uncaught, truncating ~30
  assertions and skipping the summary. Now a named finding carrying the parse
  error's line, and the run completes.
- `expected_terrain` is kept but re-labelled honestly: it is a change-detector for
  `aoi_terrain_values()`, not a validation of it. A duplicate of a guess cannot
  check the guess — the fly-side pin does that.

### Errors Encountered (rounds 4-5)

| Error | Resolution |
|-------|------------|
| Followed round 4's prescription to close four literals in one block without checking that the block runs — it is gated on a gitignored cache | Read fly's facts from the installed package instead. The prescription was right about the axis and wrong about the location. |
| Reported a mutation as "STILL GREEN" when the replacement had not applied — the anchor's whitespace had changed | A probe that reports no effect must first prove it took effect. Re-run with the real anchor: the guard fails correctly in both states. |
