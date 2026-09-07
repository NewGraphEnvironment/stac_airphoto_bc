# Progress — Selection does not use a DEM, discards fly's reporting columns, and pins no fly version (#20)

## Session 2026-09-07

- Plan-mode exploration — read `01_fetch.R`, `aoi.R`, `02_georef.R`, `05_stac_register.py`,
  the #16 and #21 archives, and issue #23. Explore agent read the fly working tree.
- Four scope forks put to the user and answered: DEM wired-but-off, ledger-only
  reporting columns, fly guard as a **window** rather than a floor, and
  `flooded::fl_dem_aoi()` as the DEM source.
- Two findings the issue does not name: `fly_georef()` sizes its own footprints so the
  DEM has to reach 02_georef.R too, and fly ≥ 0.9 degrades this pipeline silently.
- Created branch `20-dem-to-selection-fly-columns-version-window` off main
- Scaffolded PWF baseline with approved phases
- Next: Phase 1
