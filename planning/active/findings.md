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

## Why the guard is a window, not the floor the issue names

The issue prescribes `>= 0.6.0`. A bare floor passes on 0.10.0, which is what sits in
the sibling working tree. At **≥ 0.9** this pipeline degrades two ways:

- `fly_bearing()` returns `NA_real_` for a frame with no *adjacent* neighbour by
  `frame_number` (`fly/R/fly_bearing.R:105`, NEWS 0.9.0: "breaking for sampled input").
  The 8 km window is a spatial subset of every roll, so gaps are routine —
  `aoi_rotation()` then falls back to the fixed 180° that fly#25/#26 exist to correct.
  No error, no warning. This is the silent one.
- `fly_georef()` refuses a rotated film frame without the roll's measured `rotation`
  (NEWS 0.9.0), and that table is #23's deliverable.

0.9.0 also changed the **meaning** of the `rotation` column: it used to shift corners on
an axis-aligned square and now shifts them on a ring already rotated onto the bearing.
`aoi_rotation()`'s output is calibrated against the old meaning.

## What upgrading to 0.6.0–0.8.x changes on its own

Not nothing, and this must not be mistaken for a regression when the ledger is diffed.

- **0.6.0 sizes digital frames** (fly#32) from `pixel count × ground_sample_distance`,
  so frames currently rejected `digital_unknown_format` gain footprints and become
  selectable. se_c has the highest digital share of the three southeast AOIs (20%).
- 0.6.0 also records that the catalogue's `SCALE` gives **34% of true width** on a
  digital frame, measured on 40 UltraCam Eagle frames — which is why digital is sized
  from GSD rather than scale.
- **0.8.0 refuses non-POINT geometry everywhere** (fly#37). `aoi_centroids_as_sf()`
  produces POINT, so this is a no-op here.
- Film output is unchanged through 0.8.x; 0.9.0 is where film footprints start rotating.

## Local state, 2026-09-07

Only the 235 southeast frames exist on this machine. `data/centroids/`,
`data/selected/`, `data/select/` and `data/logs/` hold `se_a`, `se_b`, `se_c` only —
neexdzii_kwa has no cache, no thumbnails and no ledger here, which is why re-deriving
both regions is #23's campaign and not this issue's.

`data/reports/*.md` are the only tracked artifacts under `data/` (`.gitignore:1-9`) and
they describe the **published** collection. A verification run rewrites them to describe
a selection nobody published.

## Errors Encountered

| Error | Resolution |
|-------|------------|
| Proposed `bcmaps::cded_terra()` as the DEM source without searching the org for the verb | `flooded::fl_dem_aoi()` already exists — MRDEM-30 default, crop before reproject, returns a SpatRaster. User caught it. `karpathy.md` §7, "Not finding it is not evidence it does not exist". |
