"""03_cog_tag.py — embed centroids metadata as GDAL tags on COGs.

Called from 03_cog.R after COG conversion. Uses rasterio to write
metadata tags (airp_id, photo_date, scale, etc.) into each COG.

Tags are visible in QGIS: Layer Properties → Metadata tab.
"""

from pathlib import Path

import pyarrow.parquet as pq
import rasterio

STAC_DIR = Path("data/stac/thumbs")
CACHE_PATH = Path("data/centroids_raw.parquet")

TAG_FIELDS = [
    "airp_id", "photo_date", "photo_year", "scale",
    "film_roll", "frame_number", "focal_length", "flying_height",
]

# --- Load centroids metadata ----------------------------------------------

table = pq.read_table(CACHE_PATH)
centroids = table.to_pydict()

# Build lookup: thumbnail URL stem → metadata dict
meta_by_stem = {}
for i in range(len(centroids["airp_id"])):
    url = centroids.get("thumbnail_image_url", [None])[i]
    if not url:
        continue
    fname = url.rstrip("/").split("/")[-1]
    stem = fname.rsplit(".", 1)[0]  # e.g. bc5283_040_thumb
    meta = {}
    for field in TAG_FIELDS:
        val = centroids.get(field, [None])[i]
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

    # Check if already tagged (with FILENAME — new field)
    with rasterio.open(cog) as ds:
        existing = ds.tags()
    if "FILENAME" in existing:
        skipped += 1
        continue

    with rasterio.open(cog, "r+", IGNORE_COG_LAYOUT_BREAK="YES") as ds:
        ds.update_tags(**meta)
    tagged += 1

print(f"Tagged {tagged} COGs, skipped {skipped}")
