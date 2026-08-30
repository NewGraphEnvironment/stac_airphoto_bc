"""05_stac_register.py — generate STAC items and merge them into the collection.

Usage:
    conda run -n stac-airphoto-bc python scripts/05_stac_register.py
    ... --out /tmp/dry            # dry run: write elsewhere, touch nothing live
    ... --no-merge                # rebuild from local COGs only (see WARNING)

Merging, not replacing
----------------------
This script used to compute `collection.json` purely from the COGs on the
machine that ran it. That is safe only while one machine holds every COG ever
published. It does not: `data/` is gitignored, the 9,741 Neexdzii Kwa items
live on S3, and a run over a new AOI would have emitted a collection describing
that AOI alone — dropping every existing item link and shrinking the extent to
the new region. Issue #16 requires the opposite: extend coverage, never replace.

So the published collection is fetched and treated as the base. New items are
merged into it by href, and the extent is recomputed over the union. Running
twice is idempotent.

`--no-merge` restores the old replace-everything behaviour. It is correct only
for a full rebuild from a complete local tree, and it will discard published
item links otherwise.
"""

import argparse
import json
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import quote, unquote

import pystac
import rasterio
from rasterio.warp import transform_bounds
from shapely.geometry import box, mapping

sys.path.insert(0, str(Path(__file__).parent))
from centroids import load_centroids  # noqa: E402

# --- Config ---------------------------------------------------------------

BUCKET = "stac-airphoto-bc"
S3_REGION = "us-west-2"
COLLECTION_ID = "stac-airphoto-bc"
STAC_DIR = Path("data/stac")
CACHE_DIR = Path("data/centroids")
SELECTED_DIR = Path("data/selected")

S3_BASE = f"https://{BUCKET}.s3.{S3_REGION}.amazonaws.com"


def s3_href(rel_path: str) -> str:
    """Public S3 URL for a path relative to data/stac/.

    The path is percent-encoded at construction. Lenient clients accept a raw
    space and strict ones do not, so an unencoded href works until the day a
    consumer changes and then every fetch fails at once.
    """
    return f"{S3_BASE}/{quote(str(rel_path))}"


def fetch_published_collection(url: str):
    """The live collection. Raises rather than returning None if it cannot be read.

    The bucket grants s3:GetObject but not s3:ListBucket, so S3 answers **403**,
    not 404, for a key that does not exist — a missing collection and a
    permissions failure are indistinguishable from here. Treating either as
    "no collection yet" would silently take the replace-everything path against
    a bucket holding 9,741 published items, so neither is handled: a first run
    against an empty bucket passes --no-merge explicitly.
    """
    try:
        with urllib.request.urlopen(url, timeout=60) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as exc:
        raise SystemExit(
            f"Could not read the published collection at {url} (HTTP {exc.code}).\n"
            "This bucket returns 403 for both a missing key and a denied one, so "
            "this is NOT treated as 'no collection yet'.\n"
            "If the bucket really is empty, re-run with --no-merge."
        ) from exc


def load_footprint_basis(selected_dir: Path) -> dict:
    """airp_id -> footprint_basis, for the frames this pipeline selected.

    Stamped onto new items so a future DEM-corrected or digital-capable rebuild
    is a queryable delta rather than archaeology. Existing published items carry
    no basis: they predate the column.
    """
    import pyarrow.parquet as pq

    basis = {}
    for path in sorted(selected_dir.glob("*.parquet")):
        table = pq.read_table(path).to_pydict()
        if "footprint_basis" not in table:
            continue
        for aid, b in zip(table["airp_id"], table["footprint_basis"]):
            if b is not None:
                basis[aid] = b
    return basis


def build_items(centroids: dict, basis_by_id: dict, stac_dir: Path) -> list:
    """One STAC item per thumbnail COG on disk."""
    meta_by_id = {}
    url_to_id = {}
    n = len(centroids["airp_id"])

    for i in range(n):
        aid = centroids["airp_id"][i]
        meta_by_id[aid] = {k: centroids.get(k, [None] * n)[i] for k in (
            "airp_id", "photo_year", "photo_date", "scale", "focal_length",
            "flying_height", "film_roll", "frame_number", "longitude",
            "latitude",
        )}
        url = centroids.get("thumbnail_image_url", [None] * n)[i]
        if url:
            stem = url.rstrip("/").split("/")[-1].rsplit(".", 1)[0]
            url_to_id[stem] = aid

    thumb_cogs = sorted(stac_dir.glob("thumbs/**/*.tif"))
    scan_cogs = sorted(stac_dir.glob("scans/**/*.tif"))
    print(f"Found {len(thumb_cogs)} thumbnail COGs, {len(scan_cogs)} scan COGs")

    items = []
    unmatched = 0

    for cog_path in thumb_cogs:
        stem = cog_path.stem
        airp_id = url_to_id.get(stem) or url_to_id.get(stem.replace("_thumb", ""))
        if airp_id is None:
            unmatched += 1
            continue

        meta = meta_by_id.get(airp_id)
        if meta is None:
            unmatched += 1
            continue

        with rasterio.open(cog_path) as ds:
            native_bounds = ds.bounds
            native_crs = ds.crs
            width, height = ds.width, ds.height
            transform = list(ds.transform)[:6]
            wgs84_bounds = transform_bounds(native_crs, "EPSG:4326", *native_bounds)

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

        rel = cog_path.relative_to(stac_dir)
        assets = {
            "thumbnail": pystac.Asset(
                href=s3_href(rel),
                media_type=pystac.MediaType.COG,
                roles=["data", "thumbnail"],
            )
        }
        scan_match = list(stac_dir.glob(
            f"scans/**/{cog_path.stem.replace('_thumb', '')}.tif"))
        if scan_match:
            assets["visual"] = pystac.Asset(
                href=s3_href(scan_match[0].relative_to(stac_dir)),
                media_type=pystac.MediaType.COG,
                roles=["data", "visual"],
            )

        properties = {
            "proj:epsg": native_crs.to_epsg(),
            "proj:bbox": list(native_bounds),
            "proj:shape": [height, width],
            "proj:transform": transform,
        }
        for key in ("scale", "focal_length", "flying_height", "film_roll",
                    "frame_number"):
            val = meta.get(key)
            if val is not None:
                properties[f"airphoto:{key}"] = val

        if airp_id in basis_by_id:
            properties["airphoto:footprint_basis"] = basis_by_id[airp_id]

        roll = meta.get("film_roll", "")
        frame = meta.get("frame_number", "")
        roll_frame = f"{roll}_{frame}" if roll and frame else stem
        date_str = str(meta["photo_date"]) if meta["photo_date"] \
            else str(meta.get("photo_year", ""))
        properties["title"] = f"{airp_id} — {roll_frame} — {date_str}"

        item = pystac.Item(
            id=str(airp_id),
            geometry=mapping(box(*wgs84_bounds)),
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

    if unmatched:
        print(f"  WARN: {unmatched} COGs had no metadata match and were skipped")
    return items


def _dedupe(seq):
    """Order-preserving dedupe for extent lists (which are unhashable)."""
    out = []
    for x in seq:
        if x not in out:
            out.append(x)
    return out


def bbox_union(a, b):
    return [min(a[0], b[0]), min(a[1], b[1]), max(a[2], b[2]), max(a[3], b[3])]


def bbox_contains(outer, inner, tol=1e-9):
    return (outer[0] <= inner[0] + tol and outer[1] <= inner[1] + tol
            and outer[2] >= inner[2] - tol and outer[3] >= inner[3] - tol)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", default=str(STAC_DIR),
                    help="output directory (default data/stac)")
    ap.add_argument("--no-merge", action="store_true",
                    help="rebuild from local COGs only; discards published links")
    args = ap.parse_args()

    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)

    centroids = load_centroids(CACHE_DIR)
    basis_by_id = load_footprint_basis(SELECTED_DIR)
    items = build_items(centroids, basis_by_id, STAC_DIR)
    print(f"Generated {len(items)} STAC items from local COGs")

    if not items:
        print("No items built — nothing to write")
        return 1

    for item in items:
        (out_dir / f"{item.id}.json").write_text(
            json.dumps(item.to_dict(), indent=2))

    new_bbox = [
        min(i.bbox[0] for i in items), min(i.bbox[1] for i in items),
        max(i.bbox[2] for i in items), max(i.bbox[3] for i in items),
    ]
    new_dts = [i.datetime for i in items if i.datetime]
    new_interval = [min(new_dts), max(new_dts)]

    # --- Merge with the published collection --------------------------------

    published = None if args.no_merge else fetch_published_collection(
        f"{S3_BASE}/collection.json")

    def link_id(href: str) -> str:
        """Item id from a link href, so dedupe survives an href-format change.

        quote() was added to s3_href in this change. Deduping on the raw string
        would add a second link for the same item the next time that shape
        moves, and a set-based duplicate check cannot see it.
        """
        return unquote(href.rstrip("/").split("/")[-1]).rsplit(".", 1)[0]

    new_links = {s3_href(f"{i.id}.json") for i in items}
    old_links, old_bbox, old_interval = set(), None, None

    old_sub_bboxes, old_sub_intervals = [], []
    if published:
        old_links = {l["href"] for l in published.get("links", [])
                     if l.get("rel") == "item"}
        sp = published["extent"]["spatial"]["bbox"]
        tp = published["extent"]["temporal"]["interval"]
        old_bbox, old_interval = sp[0], tp[0]
        # bbox[0] is the OVERALL extent; bbox[1:] are the per-region sub-extents
        # a previous run wrote. Reading only bbox[0] and re-listing it as a
        # region would make run 2 duplicate the overall box and drop every
        # region but the newest — the extent would stop being idempotent and
        # the sub-extents would decay to exactly the empty-through-the-middle
        # box they exist to prevent.
        old_sub_bboxes = [b for b in sp[1:]]
        old_sub_intervals = [t for t in tp[1:]]
        print(f"Published collection carries {len(old_links)} item links "
              f"and {len(old_sub_bboxes)} sub-extent(s)")

    # New items win where an id appears in both, so a regenerated item replaces
    # its published link rather than sitting beside it.
    by_id = {link_id(h): h for h in sorted(old_links)}
    by_id.update({link_id(h): h for h in sorted(new_links)})
    all_links = sorted(by_id.values())

    if old_bbox:
        overall_bbox = bbox_union(old_bbox, new_bbox)
        # STAC 1.1: bbox[0] is the overall extent, the rest are sub-extents.
        # Listing the regions separately stops the collection claiming a
        # 600 km-wide box that is empty through the middle.
        regions = old_sub_bboxes or [old_bbox]
        bboxes = [overall_bbox] + _dedupe(regions + [new_bbox])
    else:
        overall_bbox, bboxes = new_bbox, [new_bbox]

    def parse_dt(s):
        return datetime.fromisoformat(s.replace("Z", "+00:00")) if s else None

    # A published temporal extent may legitimately be open-ended ([null, null]
    # is valid STAC). `[None, None]` is a truthy list, so testing the list
    # rather than its contents would reach min(None, datetime) and raise.
    old_dts = None
    if old_interval and all(old_interval):
        old_dts = [parse_dt(old_interval[0]), parse_dt(old_interval[1])]
        overall_interval = [min(old_dts[0], new_interval[0]),
                            max(old_dts[1], new_interval[1])]
        sub = old_sub_intervals or [old_interval]
        parsed_subs = [[parse_dt(a), parse_dt(b)] for a, b in sub
                       if a and b]
        intervals = [overall_interval] + _dedupe(
            parsed_subs + [new_interval])
    else:
        overall_interval, intervals = new_interval, [new_interval]

    collection = pystac.Collection(
        id=COLLECTION_ID,
        title="Historical Aerial Photographs of British Columbia",
        description=(
            "Georeferenced thumbnails of historical aerial photographs of "
            "British Columbia."
        ),
        extent=pystac.Extent(
            spatial=pystac.SpatialExtent(bboxes=bboxes),
            temporal=pystac.TemporalExtent(intervals=intervals),
        ),
        license="proprietary",
    )
    for href in all_links:
        collection.add_link(pystac.Link(
            rel="item", target=href, media_type="application/json"))

    # Write to a temp file and promote only once every check has passed. A
    # collection written before its checks is a poisoned artifact: a later bare
    # `Rscript scripts/04_s3_upload.R` would sync it over the published one.
    collection_path = out_dir / "collection.json"
    collection_tmp = out_dir / "collection.json.tmp"
    collection_tmp.write_text(json.dumps(collection.to_dict(), indent=2))

    # --- Assertions: the collection must only ever grow ---------------------
    # Read the file back rather than re-checking the expressions that produced
    # it. Asserting `bbox_contains(overall_bbox, old_bbox)` when overall_bbox is
    # *defined* as their union is a check that cannot fail — it tests the value
    # just computed, not the artifact about to be published. These read the
    # written JSON, so a serialisation bug or a later refactor is caught too.

    written = json.loads(collection_tmp.read_text())
    written_item_links = [l["href"] for l in written.get("links", [])
                          if l.get("rel") == "item"]
    written_bbox = written["extent"]["spatial"]["bbox"][0]
    written_interval = written["extent"]["temporal"]["interval"][0]

    failures = []
    if published:
        missing = old_links - set(written_item_links)
        if missing:
            failures.append(
                f"{len(missing)} published item links absent from the written "
                f"collection")
        if not bbox_contains(written_bbox, old_bbox):
            failures.append(
                f"written bbox {written_bbox} does not contain published "
                f"{old_bbox}")
        if old_dts:
            w0, w1 = parse_dt(written_interval[0]), parse_dt(written_interval[1])
            if w0 is None or w1 is None or w0 > old_dts[0] or w1 < old_dts[1]:
                failures.append(
                    "written temporal interval does not contain the published one")
    if len(written_item_links) != len(set(written_item_links)):
        failures.append("duplicate item links in the written collection")
    if len(written_item_links) < len(old_links):
        failures.append(
            f"written collection has {len(written_item_links)} item links, "
            f"fewer than the {len(old_links)} already published")

    print(f"\nItem links: {len(old_links)} published + {len(new_links)} local "
          f"-> {len(written_item_links)} written")
    print(f"Overall bbox: {written_bbox}")

    # --- Validate -----------------------------------------------------------

    errors = sum(1 for item in items if not _valid(item))
    if not _valid(collection):
        errors += 1

    if failures:
        for f in failures:
            print(f"  MERGE ASSERTION FAILED: {f}")
        collection_tmp.unlink(missing_ok=True)
        return 1
    if errors:
        print(f"VALIDATION FAILED: {errors} error(s)")
        collection_tmp.unlink(missing_ok=True)
        return 1

    collection_tmp.replace(collection_path)
    print(f"{len(items)} items + collection valid; merge assertions passed")
    print(f"Collection written to {collection_path}")
    return 0


def _valid(obj) -> bool:
    try:
        obj.validate()
        return True
    except Exception as exc:  # noqa: BLE001 — report and count, don't abort
        print(f"  FAIL: {getattr(obj, 'id', obj)} — {exc}")
        return False


if __name__ == "__main__":
    sys.exit(main())
