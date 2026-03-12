"""05_stac_register.py — generate STAC collection + items for BC airphotos.

Usage:
    conda activate stac-airphoto-bc
    python scripts/05_stac_register.py
"""

import json
from datetime import datetime, timezone
from pathlib import Path

import pyarrow.parquet as pq
import pystac
import rasterio
from shapely.geometry import box, mapping

# --- Config ---------------------------------------------------------------

BUCKET = "stac-airphoto-bc"
S3_REGION = "us-west-2"
COLLECTION_ID = "stac-airphoto-bc"
STAC_DIR = Path("data/stac")
CACHE_PATH = Path("data/centroids_raw.parquet")

S3_BASE = f"https://{BUCKET}.s3.{S3_REGION}.amazonaws.com"


def s3_href(rel_path: str) -> str:
    """Build public S3 URL from path relative to data/stac/."""
    return f"{S3_BASE}/{rel_path}"


# --- Load centroids metadata ----------------------------------------------

table = pq.read_table(CACHE_PATH)
centroids = table.to_pydict()

# Build lookup by airp_id
meta_by_id = {}
for i in range(len(centroids["airp_id"])):
    aid = centroids["airp_id"][i]
    meta_by_id[aid] = {
        "airp_id": aid,
        "photo_year": centroids.get("photo_year", [None])[i],
        "photo_date": centroids.get("photo_date", [None])[i],
        "scale": centroids.get("scale", [None])[i],
        "focal_length": centroids.get("focal_length", [None])[i],
        "flying_height": centroids.get("flying_height", [None])[i],
        "film_roll": centroids.get("film_roll", [None])[i],
        "frame_number": centroids.get("frame_number", [None])[i],
        "longitude": centroids.get("longitude", [None])[i],
        "latitude": centroids.get("latitude", [None])[i],
    }

# --- Scan COGs on disk ----------------------------------------------------

thumb_cogs = sorted(STAC_DIR.glob("thumbs/**/*.tif"))
scan_cogs = sorted(STAC_DIR.glob("scans/**/*.tif"))

print(f"Found {len(thumb_cogs)} thumbnail COGs, {len(scan_cogs)} scan COGs")

# Map airp_id -> COG paths by matching filename to centroids
# Thumbnail filenames are like bc5281_084_thumb.tif — match via thumbnail_image_url
url_to_id = {}
for i in range(len(centroids["airp_id"])):
    url = centroids.get("thumbnail_image_url", [None])[i]
    if url:
        fname = url.rstrip("/").split("/")[-1]
        base = fname.rsplit(".", 1)[0]  # e.g. bc5281_084_thumb
        url_to_id[base] = centroids["airp_id"][i]


# --- Build STAC items -----------------------------------------------------

items = []
item_paths = []

for cog_path in thumb_cogs:
    stem = cog_path.stem  # e.g. bc5281_084_thumb
    airp_id = url_to_id.get(stem)

    if airp_id is None:
        # Try matching without _thumb suffix
        alt_stem = stem.replace("_thumb", "")
        airp_id = url_to_id.get(alt_stem)

    if airp_id is None:
        print(f"  WARN: no airp_id match for {cog_path.name}, skipping")
        continue

    meta = meta_by_id.get(airp_id)
    if meta is None:
        print(f"  WARN: no metadata for airp_id={airp_id}, skipping")
        continue

    # Read COG bounds
    with rasterio.open(cog_path) as ds:
        native_bounds = ds.bounds
        native_crs = ds.crs
        width = ds.width
        height = ds.height
        transform = list(ds.transform)[:6]

        # Reproject bounds to WGS84 for STAC geometry
        from rasterio.warp import transform_bounds
        wgs84_bounds = transform_bounds(native_crs, "EPSG:4326",
                                         *native_bounds)

    # Datetime
    dt = None
    if meta["photo_date"]:
        try:
            dt = datetime.fromisoformat(str(meta["photo_date"]))
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)
        except (ValueError, TypeError):
            pass
    if dt is None and meta["photo_year"]:
        dt = datetime(int(meta["photo_year"]), 1, 1, tzinfo=timezone.utc)

    # Geometry (WGS84 bbox polygon)
    geom = mapping(box(*wgs84_bounds))

    # Relative path from stac dir for S3 href
    rel = cog_path.relative_to(STAC_DIR)

    # Build assets
    assets = {
        "thumbnail": pystac.Asset(
            href=s3_href(str(rel)),
            media_type=pystac.MediaType.COG,
            roles=["data", "thumbnail"],
        )
    }

    # Check for matching scan
    scan_match = list(STAC_DIR.glob(f"scans/**/{cog_path.stem.replace('_thumb', '')}.tif"))
    if scan_match:
        scan_rel = scan_match[0].relative_to(STAC_DIR)
        assets["visual"] = pystac.Asset(
            href=s3_href(str(scan_rel)),
            media_type=pystac.MediaType.COG,
            roles=["data", "visual"],
        )

    # Properties
    properties = {
        "proj:epsg": native_crs.to_epsg(),
        "proj:bbox": list(native_bounds),
        "proj:shape": [height, width],
        "proj:transform": transform,
    }
    for key in ("scale", "focal_length", "flying_height", "film_roll", "frame_number"):
        val = meta.get(key)
        if val is not None:
            properties[f"airphoto:{key}"] = val

    # Title: airp_id — roll_frame — date (for display in QGIS / STAC browsers)
    roll = meta.get("film_roll", "")
    frame = meta.get("frame_number", "")
    roll_frame = f"{roll}_{frame}" if roll and frame else stem
    date_str = str(meta["photo_date"]) if meta["photo_date"] else str(meta.get("photo_year", ""))
    title = f"{airp_id} — {roll_frame} — {date_str}"

    properties["title"] = title

    item = pystac.Item(
        id=str(airp_id),
        geometry=geom,
        bbox=list(wgs84_bounds),
        datetime=dt,
        properties=properties,
        assets=assets,
        stac_extensions=[
            "https://stac-extensions.github.io/projection/v1.1.0/schema.json",
        ],
    )
    item.collection_id = COLLECTION_ID
    item.add_link(pystac.Link(
        rel="collection",
        target=s3_href("collection.json"),
        media_type="application/json",
    ))

    items.append(item)

    # Save item JSON at stac root (flat)
    item_path = STAC_DIR / f"{airp_id}.json"
    item_path.write_text(json.dumps(item.to_dict(), indent=2))
    item_paths.append(item_path)

print(f"Generated {len(items)} STAC items")

# --- Build collection -----------------------------------------------------

if items:
    all_bboxes = [i.bbox for i in items]
    spatial_extent = pystac.SpatialExtent(
        bboxes=[[
            min(b[0] for b in all_bboxes),
            min(b[1] for b in all_bboxes),
            max(b[2] for b in all_bboxes),
            max(b[3] for b in all_bboxes),
        ]]
    )
    all_dts = [i.datetime for i in items if i.datetime]
    temporal_extent = pystac.TemporalExtent(
        intervals=[[min(all_dts), max(all_dts)]]
    )
else:
    spatial_extent = pystac.SpatialExtent(bboxes=[[-139, 48, -114, 60]])
    temporal_extent = pystac.TemporalExtent(intervals=[[None, None]])

collection = pystac.Collection(
    id=COLLECTION_ID,
    title="Historical Aerial Photographs of British Columbia",
    description="Georeferenced thumbnails of historical aerial photographs of British Columbia.",
    extent=pystac.Extent(spatial=spatial_extent, temporal=temporal_extent),
    license="proprietary",
)

# Add item links
for item in items:
    collection.add_link(pystac.Link(
        rel="item",
        target=s3_href(f"{item.id}.json"),
        media_type="application/json",
    ))

collection_path = STAC_DIR / "collection.json"
collection_path.write_text(json.dumps(collection.to_dict(), indent=2))

# --- Validate -------------------------------------------------------------

print("Validating...")
errors = 0
for item in items:
    try:
        item.validate()
    except Exception as e:
        print(f"  FAIL: {item.id} — {e}")
        errors += 1

try:
    collection.validate()
except Exception as e:
    print(f"  Collection FAIL: {e}")
    errors += 1

if errors:
    print(f"VALIDATION FAILED: {errors} error(s)")
else:
    print(f"{len(items)} items + collection valid")

print(f"\nCollection written to {collection_path}")
print(f"Run 04_s3_upload.R to sync, then pypgstac to register")
