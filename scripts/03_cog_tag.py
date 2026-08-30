"""03_cog_tag.py — embed centroids metadata as GDAL tags on COGs.

Called from 03_cog.R after COG conversion. Uses rasterio to write
metadata tags (airp_id, photo_date, scale, etc.) into each COG.

Tags are visible in QGIS: Layer Properties → Metadata tab.
"""

from pathlib import Path

import rasterio

from centroids import load_centroids

STAC_DIR = Path("data/stac/thumbs")
# One cache per AOI (issue #16). The COG tree is global, so tagging must read
# every cache — reading one would leave every other AOI's COGs untagged, with
# no error, since a missing airp_id just skips.
CACHE_DIR = Path("data/centroids")

TAG_FIELDS = [
    "airp_id", "photo_date", "photo_year", "scale",
    "film_roll", "frame_number", "focal_length", "flying_height",
]

# --- Load centroids metadata ----------------------------------------------

centroids = load_centroids(CACHE_DIR)
# Length of every column, for the padded .get() defaults below. A bare [None]
# default is a length-1 list and raises IndexError on the second row whenever a
# TAG_FIELD is absent from every cache — newly reachable now that each AOI is a
# separate WFS query and the schemas need not agree.
N_ROWS = len(centroids["airp_id"])

# Build lookup: thumbnail URL stem → metadata dict
meta_by_stem = {}
for i in range(len(centroids["airp_id"])):
    url = centroids.get("thumbnail_image_url", [None] * N_ROWS)[i]
    if not url:
        continue
    fname = url.rstrip("/").split("/")[-1]
    stem = fname.rsplit(".", 1)[0]  # e.g. bc5283_040_thumb
    meta = {}
    for field in TAG_FIELDS:
        val = centroids.get(field, [None] * N_ROWS)[i]
        if val is not None:
            meta[field.upper()] = str(val)
    # Use photo_date if available, fall back to photo_year
    if "PHOTO_DATE" in meta:
        meta.pop("PHOTO_YEAR", None)
    elif "PHOTO_YEAR" in meta:
        meta["PHOTO_DATE"] = meta.pop("PHOTO_YEAR")
    meta["FILENAME"] = stem
    meta_by_stem[stem] = meta

# --- Tag COGs -------------------------------------------------------------

cog_files = sorted(STAC_DIR.glob("**/*.tif"))
tagged = 0
skipped = 0

for cog in cog_files:
    stem = cog.stem
    meta = meta_by_stem.get(stem)
    if meta is None:
        skipped += 1
        continue

    # Check if already tagged (with FILENAME — most recent field)
    with rasterio.open(cog) as ds:
        existing = ds.tags()
    if "FILENAME" in existing:
        skipped += 1
        continue

    with rasterio.open(cog, "r+", IGNORE_COG_LAYOUT_BREAK="YES") as ds:
        ds.update_tags(**meta)
    tagged += 1

print(f"Tagged {tagged} COGs, skipped {skipped}")
