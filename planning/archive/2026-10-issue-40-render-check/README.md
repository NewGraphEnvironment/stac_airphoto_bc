## Outcome

`scripts/cog_render-compare.py` makes #36's last check, "does a grey item render with a transparent collar", repeatable. It draws a seeded sample of frames the way a GDAL client does: alpha over a checkerboard, published | local | diff with differences in magenta. Per frame it compares the bytes and the pixels at every overview level, and `--expect-same` gives an exit status to gate on after a sync. It is a spot check, not a census; `stac_validate.py` stays the collection-wide check.

Review changed what the tool claims. Round 1:
- Identical full-resolution pixels said nothing about the overviews a client draws zoomed out. Measured: 0 full-res pixels differing against 358,222 differing in a panel.
- A 4-frame seeded sample could not show "what a sync will change".
- The script always exited 0, so nothing could gate on it.

Round 2 found two defects inside round 1's unreadable-frame fix: a `KeyError` when only the second open fails, and panel slots that shifted. The mechanism was I/O sites handled one at a time. That was ended by enumeration: every read goes through one of three handlers on `READ_ERRORS = (OSError, http.client.HTTPException)`, and a mutation table shows each handler is load-bearing. `IncompleteRead` is not an `OSError`, so narrowing to `OSError` turns a test red.

## Measurement

First run, 2026-10-01, after the #36 sync, on 5 frames including the worst grey frame (117783, `bcb94081_042`): `bytes_same=True`, 0 pixels differing at full resolution and at every overview level. The fill draws as checkerboard and the 9,277 genuine-black pixels draw black.

Observed, not investigated: along the frame's bottom edge, transparency reaches into dark shadow. That looks like fly's border mask treating dark pixels connected to the edge as collar.

## Evidence

- Renders: `data/logs/render/40-*` (local, gitignored)
- Reviews: `review-render-round*.md` in this directory

Closed by: PR for #40
