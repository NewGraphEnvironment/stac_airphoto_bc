"""stac_validate.py — check every local item against its COG before a sync (#30).

Usage:
    conda run -n stac-airphoto-bc python scripts/stac_validate.py

Run by 04_s3_upload.R before anything is uploaded, and its `check_item()` by
05_stac_register.py before anything is written. Exits non-zero on any problem.

Per item whose thumbnail COG is on this machine:
  - `file:checksum` recomputed from the bytes on disk, and `file:size`
  - the file extension declared
  - the build properties every item carries, as a NAMED set: a check that
    compares items with one another cannot see a key missing from all of them
  - the rotation keys on every film item, and the closed vocabularies
  - COG layout: IFDs before data, by offset rather than by the ghost header's claim

Items published before #23 are not on this machine and are not checked; the
rebuild replaces them.
"""

import json
import sys
from pathlib import Path
from urllib.parse import unquote, urlparse

sys.path.insert(0, str(Path(__file__).parent))
from airphoto_props import (  # noqa: E402
    BUILD_PROPERTY_FIELDS,
    FILE_EXTENSION,
    PLACEMENT_SOURCES,
    REQUIRED_BUILD_PROPERTIES,
    REQUIRED_FILM_PROPERTIES,
    ROTATION_SOURCES,
    cog_layout_ok,
    file_meta,
)

STAC_DIR = Path("data/stac")


def local_path(href: str, stac_dir: Path) -> Path:
    """The file under data/stac/ an S3 href was built from (inverse of s3_href)."""
    return stac_dir / unquote(urlparse(href).path.lstrip("/"))


def tags_disagree(path: Path, props: dict) -> list[str]:
    """The COG's embedded build tags against the item's properties.

    Both are stamped from the same window row, by two scripts; a raster rebuilt
    without re-registering, or an item regenerated over a stale raster, is where
    they part. Compared as text, since tags are text.
    """
    import rasterio

    with rasterio.open(path) as ds:
        tags = ds.tags()
    out = []
    for field, key in BUILD_PROPERTY_FIELDS.items():
        tag = tags.get(field.upper())
        prop = props.get(key)
        prop_text = None if prop is None else (
            str(int(prop)) if isinstance(prop, float) and prop.is_integer() else str(prop))
        if tag != prop_text:
            out.append(f"COG tag {field.upper()}={tag!r} but item {key}={prop!r}")
    return out


def check_item(doc: dict, stac_dir: Path = STAC_DIR) -> list[str]:
    """Every problem with one item dict, empty when it is publishable."""
    problems = []
    props = doc.get("properties", {})

    if FILE_EXTENSION not in doc.get("stac_extensions", []):
        problems.append("file extension not declared")

    thumb = doc.get("assets", {}).get("thumbnail")
    if thumb is None:
        problems.append("no thumbnail asset")
    else:
        path = local_path(thumb["href"], stac_dir)
        if not path.exists():
            problems.append(f"thumbnail not on disk at {path}")
        else:
            actual = file_meta(path)
            for key in ("file:checksum", "file:size"):
                if thumb.get(key) != actual[key]:
                    problems.append(f"{key} {thumb.get(key)!r} does not match the "
                                    f"file ({actual[key]!r})")
            if not cog_layout_ok(path):
                problems.append(f"{path.name} is not a valid COG layout (IFD after data)")
            problems.extend(tags_disagree(path, props))

    for key in REQUIRED_BUILD_PROPERTIES:
        if key not in props:
            problems.append(f"missing {key}")

    film = str(props.get("airphoto:media", "")).startswith("Film")
    if film:
        for key in REQUIRED_FILM_PROPERTIES:
            if key not in props:
                problems.append(f"film item missing {key}")
    elif "airphoto:rotation" in props:
        # A supplied rotation overrides fly's measured digital corner mapping.
        problems.append("non-film item carries airphoto:rotation")

    rs = props.get("airphoto:rotation_source")
    if rs is not None and rs not in ROTATION_SOURCES:
        problems.append(f"unknown airphoto:rotation_source {rs!r}")
    ps = props.get("airphoto:placement_source")
    if ps is not None and ps not in PLACEMENT_SOURCES:
        problems.append(f"unknown airphoto:placement_source {ps!r}")
    if ps == "none" and (props.get("airphoto:shift_x_m_3005"),
                         props.get("airphoto:shift_y_m_3005")) != (0.0, 0.0):
        problems.append("placement_source none with a non-zero shift")

    return problems


def main() -> int:
    items = [p for p in sorted(STAC_DIR.glob("*.json")) if p.name != "collection.json"]
    if not items:
        print(f"No item JSONs in {STAC_DIR} — run 05_stac_register.py first.")
        return 1
    bad = 0
    for p in items:
        problems = check_item(json.loads(p.read_text()), STAC_DIR)
        for problem in problems:
            print(f"  FAIL: {p.stem} — {problem}")
        bad += bool(problems)
    print(f"{len(items) - bad} of {len(items)} items pass")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
