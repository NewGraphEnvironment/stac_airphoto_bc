# Issue #16 — Point the pipeline at a second area

**Outcome:** the AOI is a parameter. `scripts/aoi.R` holds a registry resolving
either a watershed spec or a WGS84 bbox to an sf polygon; every stage takes AOI
ids on the command line and aborts on an unknown one. Three small southeast BC
AOIs were run end to end and published: the collection went from 9,741 items
over one watershed to **9,976 over two regions**, with the original 9,741
unchanged and the extent covering both. Live verification after registration:
watershed 9,741 (baseline preserved), AOI A 116, B 121, C 78 — all three were 0.

**The load-bearing discovery** was not in the issue. `05_stac_register.py`
computed `collection.json` purely from the COGs on the machine that ran it, and
the geopro registration **deletes the collection and reloads from those item
links** — so a run over a new AOI would have deleted 9,741 published items from
the catalog. Registration now merges with the published collection and refuses
to promote one that drops a link.

**Selection changed during planning, on a measurement.** The plan was minimal
set-cover per era; measured, `fly_select(minimal, 0.95)` picked exactly one
frame per era, because film footprints here are 2.3–7.2 km wide against a
~1 km² AOI — 9 photos for the whole issue. Every footprint-overlapping frame is
kept instead, with era as a reporting dimension.

**Review found more than the issue did.** Three passes: 12 findings, then 10
(three of them *inside* the first pass's fixes), then 1 (none inside the
second's) — convergence. The second pass was the valuable one.

Other things that would have shipped silently: the pipeline synced to S3 before
registration wrote its item JSONs; `fly_georef(rotation = "auto")` collapsed to a
fixed 180° on any filtered set; and `fly_footprint()` drops `footprint_basis` on
tibble input, which is what `bcdata` returns — filed upstream as
[fly#35](https://github.com/NewGraphEnvironment/fly/issues/35) and worked around
here.

**Follow-ups:** fly#35 (delete the coercion once fixed); fly#32 (digital sensor
widths — the share varies 2.2%/4%/20% across these three AOIs); DEM-corrected
footprints for both regions together; the ~1,400 digital frames already
published under the 9-inch-negative assumption, one of which ships an 11,435 m
footprint.

Closed by PR for branch `16-point-the-pipeline-at-a-second-area-lift`.
