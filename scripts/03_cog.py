"""03_cog.py — place, tag and write each georeferenced thumbnail as a COG.

Usage:
    uv run python scripts/03_cog.py

One write per file, and it is the last step to touch a published byte (#30).
This used to be two steps: `03_cog.R` wrote the COG and `03_cog_tag.py` then
opened it `r+` with IGNORE_COG_LAYOUT_BREAK=YES to add the tags, which moved the
main IFD to the end of the file. Every COG published that way had lost its COG
layout while its ghost header still claimed IFDS_BEFORE_DATA. Here the tags and
the placement go onto an in-memory copy, and the COG driver writes the result
once, so the layout holds and a checksum taken afterwards describes the object.

Placement (#23): each frame is translated by its measured shift, in EPSG:3005
metres east and north, from `data-raw/placement_frame.csv` via the window
parquets. fly warps onto a north-up EPSG:3005 grid, so moving the geotransform
origin is exactly the translation of the finished footprint the shifts were
measured as. The GeoTIFF fly wrote is never modified, so a re-run applies the
shift exactly once — by construction, not by a skip.

Idempotent by content: a COG is replaced only when the new bytes differ, so an
unchanged frame keeps its mtime and a later `aws s3 sync` does not re-upload it.
That relies on the write being deterministic, which `--check-determinism`
verifies.
"""

import argparse
import hashlib
import sys
import tempfile
from pathlib import Path

import rasterio
from affine import Affine
from rasterio.enums import MaskFlags
from rasterio.io import MemoryFile
from rasterio.shutil import copy as rio_copy

sys.path.insert(0, str(Path(__file__).parent))
from centroids import load_centroids, selected_ids  # noqa: E402

GEOREF_DIR = Path("data/raw/georef/thumbs")
STAC_DIR = Path("data/stac/thumbs")
# 01_fetch.R writes one per AOI: the catalogue row, fly's footprint columns, and
# the rotation, placement and provenance this stage and 05 stamp.
WINDOW_DIR = Path("data/window")
# What each GeoTIFF was written from (02_georef.R), and which frames are selected.
MANIFEST = Path("data/raw/georef/manifest.csv")
LEDGER_DIR = Path("data/select")

COG_OPTIONS = {"compress": "DEFLATE", "overview_resampling": "nearest"}
# The mask of every image band in fly's output: its last band, an alpha (#36).
ALPHA_MASK = [MaskFlags.per_dataset, MaskFlags.alpha]

# Catalogue fields, as before #23.
CATALOGUE_TAGS = [
    "airp_id", "photo_date", "photo_year", "scale",
    "film_roll", "frame_number", "focal_length", "flying_height",
]
# How this raster was made (#23, #30). No run timestamp: it would make the bytes
# differ on every run, and the checksum churn with them. The run time is an item
# property, not a raster tag.
PROVENANCE_TAGS = [
    "footprint_basis", "height_source",
    "rotation", "rotation_source",
    "placement_source", "shift_x_m_3005", "shift_y_m_3005",
    "fly_version", "fly_sha", "pipeline_sha",
]
# Read from the window to vouch for a GeoTIFF; not tagged.
WINDOW_ONLY = ["footprint_digest"]
# Must be the same for every frame in one run: two AOIs sized with different fly
# builds would publish a collection no consumer can describe.
RUN_CONSTANT = ["fly_version", "fly_sha", "pipeline_sha"]


def fmt(value) -> str | None:
    """Tag text for a value, or None to omit the tag.

    NaN and None are both absence; writing them as "nan"/"None" would publish a
    valid-looking value that means nothing.
    """
    if value is None:
        return None
    if isinstance(value, float):
        if value != value:  # NaN
            return None
        if value.is_integer():
            return str(int(value))
    return str(value)


def frame_tags(meta: dict, stem: str) -> dict:
    tags = {}
    for field in CATALOGUE_TAGS + PROVENANCE_TAGS:
        text = fmt(meta.get(field))
        if text is not None:
            tags[field.upper()] = text
    # photo_date when there is one, else the year as PHOTO_DATE — as before.
    if "PHOTO_DATE" in tags:
        tags.pop("PHOTO_YEAR", None)
    elif "PHOTO_YEAR" in tags:
        tags["PHOTO_DATE"] = tags.pop("PHOTO_YEAR")
    tags["FILENAME"] = stem
    return tags


def shift_of(meta: dict) -> tuple[float, float]:
    """The frame's translation, refusing anything that is not two finite numbers.

    A frame with no correction carries (0, 0), never NaN: NaN would propagate
    into the geotransform and write a raster with no location.
    """
    dx, dy = meta.get("shift_x_m_3005"), meta.get("shift_y_m_3005")
    try:
        dx, dy = float(dx), float(dy)
    except (TypeError, ValueError):
        raise SystemExit(f"{meta.get('airp_id')}: shift is not numeric ({dx!r}, {dy!r})")
    if dx != dx or dy != dy or abs(dx) == float("inf") or abs(dy) == float("inf"):
        raise SystemExit(f"{meta.get('airp_id')}: shift is not finite ({dx}, {dy})")
    return dx, dy


def write_cog(src: Path, dst: Path, tags: dict, dx: float, dy: float) -> bytes:
    """Translate, tag and COG-write `src`; return the bytes that were written."""
    with rasterio.open(src) as ds:
        if ds.crs is None or ds.crs.to_epsg() != 3005:
            raise SystemExit(f"{src}: expected EPSG:3005, got {ds.crs} — the shift is in 3005 metres")
        t = ds.transform
        if t.b != 0 or t.d != 0:
            raise SystemExit(f"{src}: geotransform is rotated; a translation of the origin "
                             "would not be a translation of the footprint")
        # fly 0.19.0 (fly#56) ends every frame in an alpha band and sets no NoData.
        # Before it, grey frames were NoData 0, and GDAL rewrote genuine black
        # inside them as 1 so it would not read as fill. So check the mask a reader
        # sees, not the colorinterp: a NoData beside the alpha wins over it, and an
        # alpha in a 3- or 5-band dataset masks nothing. A 1-band raster has no
        # image band left once the last is set aside, hence `not image`.
        image = ds.mask_flag_enums[:-1]
        if not image or any(f != ALPHA_MASK for f in image):
            raise SystemExit(f"{src}: not fly's alpha-masked shape (colorinterp "
                             f"{ds.colorinterp}, nodata {ds.nodata}, mask "
                             f"{ds.mask_flag_enums}) — install fly from GitHub and "
                             "re-run 01_fetch.R and 02_georef.R for every AOI")
        profile = ds.profile.copy()
        data = ds.read()
        colorinterp = ds.colorinterp
        src_tags = ds.tags()
        # Rotated/sheared transforms were refused above, so moving the origin by
        # (dx, dy) moves every pixel by exactly (dx, dy) on the ground.
        profile.update(driver="GTiff", transform=Affine.translation(dx, dy) * t)

    # A GTiff created without ALPHA=YES ignores an alpha colorinterp on a 2-band
    # (Gray + Alpha) dataset and writes it as undefined; RGBA keeps it either way.
    profile["alpha"] = "YES"
    with MemoryFile() as mf:
        with mf.open(**profile) as mem:
            mem.write(data)
            mem.colorinterp = colorinterp
            mem.update_tags(**{**src_tags, **tags})
        with mf.open() as mem, tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / dst.name
            rio_copy(mem, out, driver="COG", **COG_OPTIONS)
            check_same_raster(src, out, dx, dy)
            return out.read_bytes()


def check_same_raster(src: Path, out: Path, dx: float, dy: float) -> None:
    """Refuse a COG that is not fly's raster, moved.

    The writer this replaced (`terra::writeRaster(filetype = "COG")`) set NoData to
    255 and dropped the colour interpretation on every band, so a published RGBA
    frame read its whole alpha-masked interior as nodata and a grey frame masked
    its genuinely white pixels. Nothing failed. So the properties a consumer
    reads are compared here on every file, not once in a test. That caught the
    next one too: a Gray + Alpha frame losing its alpha colorinterp (#36).
    """
    with rasterio.open(src) as a, rasterio.open(out) as b:
        same = (a.count == b.count and a.dtypes == b.dtypes and a.nodata == b.nodata
                and a.colorinterp == b.colorinterp and a.mask_flag_enums == b.mask_flag_enums
                and a.width == b.width and a.height == b.height)
        moved = (abs((b.transform.c - a.transform.c) - dx) < 1e-6
                 and abs((b.transform.f - a.transform.f) - dy) < 1e-6
                 and b.transform.a == a.transform.a and b.transform.e == a.transform.e)
        if not same or not moved:
            raise SystemExit(f"{src}: the COG differs from fly's raster beyond the shift "
                             f"(count {a.count}/{b.count}, nodata {a.nodata}/{b.nodata}, "
                             f"colorinterp {a.colorinterp}/{b.colorinterp})")
        if not (a.read() == b.read()).all():
            raise SystemExit(f"{src}: pixel values changed in the COG write")


def load_windows() -> dict:
    """stem -> the frame's window row, across every AOI."""
    cols = load_centroids(WINDOW_DIR)
    n = len(cols["airp_id"])
    for need in ("thumbnail_image_url", "in_window", *PROVENANCE_TAGS, *WINDOW_ONLY):
        if need not in cols:
            raise SystemExit(f"Window parquets carry no `{need}` column — re-run 01_fetch.R.")

    by_stem: dict = {}
    for i in range(n):
        url = cols["thumbnail_image_url"][i]
        # Roll neighbours outside a window are there only so fly_bearing() sees the
        # whole roll; a frame is described by a window it belongs to.
        if not url or cols.get("in_window", [True] * n)[i] is False:
            continue
        stem = url.rstrip("/").split("/")[-1].rsplit(".", 1)[0]
        row = {k: v[i] for k, v in cols.items()}
        prev = by_stem.get(stem)
        if prev is not None:
            # A frame in two AOIs' windows. The placement and rotation come from the
            # same tables, so they must agree; if they do not, one window is stale.
            # footprint_digest too: two AOIs that size a shared frame differently
            # would otherwise leave 03 vouching it against whichever sorts first.
            for k in ("rotation", "rotation_source", "placement_source",
                      "shift_x_m_3005", "shift_y_m_3005", "footprint_digest"):
                if fmt(prev.get(k)) != fmt(row.get(k)):
                    raise SystemExit(f"{stem}: two AOI windows disagree on {k} "
                                     f"({prev.get(k)!r} vs {row.get(k)!r}) — re-run 01_fetch.R "
                                     "for both AOIs, with FORCE_REFRESH = TRUE if their catalogue "
                                     "caches were fetched at different times")
            continue
        by_stem[stem] = row
    return by_stem


def run_constants(by_stem: dict) -> dict:
    seen = {k: {fmt(r.get(k)) for r in by_stem.values()} for k in RUN_CONSTANT}
    mixed = {k: v for k, v in seen.items() if len(v) != 1 or None in v}
    if mixed:
        raise SystemExit("Windows disagree on (or lack) run provenance: "
                         + "; ".join(f"{k}={sorted(map(str, v))}" for k, v in mixed.items())
                         + ". Re-run 01_fetch.R for every AOI with one fly and one commit.")
    consts = {k: next(iter(v)) for k, v in seen.items()}
    # The windows name the commit 01_fetch.R ran on. A COG written now must be
    # from that same code, or the items would name a commit that did not write it.
    now = current_pipeline_sha()
    if consts["pipeline_sha"] != now:
        raise SystemExit(f"Windows were built at {consts['pipeline_sha']} but the code is now "
                         f"{now}. Re-run 01_fetch.R and 02_georef.R for every AOI.")
    return consts


def current_pipeline_sha() -> str:
    """The same string aoi_provenance() records: both run scripts/pipeline_sha.sh."""
    import subprocess

    return subprocess.run(["bash", str(Path(__file__).parent / "pipeline_sha.sh")],
                          check=True, capture_output=True, text=True).stdout.strip()


def load_manifest() -> dict:
    """GeoTIFF path -> the inputs 02_georef.R recorded when it wrote it."""
    import csv

    if not MANIFEST.exists():
        raise SystemExit(f"No georef manifest at {MANIFEST} — run 02_georef.R.")
    with MANIFEST.open() as fh:
        return {row["dest"]: row for row in csv.DictReader(fh)}


def md5(path: Path) -> str:
    return hashlib.md5(path.read_bytes()).hexdigest()


def vouched(src: Path, meta: dict, manifest: dict, fly_sha: str,
            pipeline_sha: str) -> str | None:
    """None when the manifest says this GeoTIFF was written from this frame's current
    rotation by this run's fly; otherwise why not."""
    row = manifest.get(str(src))
    if row is None:
        return "no manifest row (not written by 02_georef.R since the manifest began)"
    if str(row["airp_id"]) != str(meta.get("airp_id")):
        return f"manifest says airp_id {row['airp_id']}"
    if (row["rotation"] or None) != fmt(meta.get("rotation")):
        return f"written at rotation {row['rotation'] or 'NA'}, window says {fmt(meta.get('rotation'))}"
    if row["fly_sha"] != fly_sha:
        return f"written by fly {row['fly_sha']}, this run is {fly_sha}"
    if row["pipeline_sha"] != pipeline_sha:
        return f"written by pipeline {row['pipeline_sha']}, this run is {pipeline_sha}"
    src_jpg = Path(row["source"])
    if not src_jpg.exists() or md5(src_jpg) != row["source_md5"]:
        return f"source {src_jpg} is missing or changed since it was georeferenced"
    # The footprint: size, position and bearing in one digest. Without it, a
    # window rebuilt by 01 alone (a new DEM, a refreshed catalogue row) would label
    # the old raster with the new window's height_source and footprint_basis.
    if (row["footprint_digest"] or None) != fmt(meta.get("footprint_digest")):
        return "written on a different footprint than the window records"
    return None


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--check-determinism", action="store_true",
                    help="write the first frame twice and refuse if the bytes differ")
    args = ap.parse_args()

    by_stem = load_windows()
    consts = run_constants(by_stem)
    print("Run provenance: " + ", ".join(f"{k}={v}" for k, v in consts.items()))

    sources = sorted(GEOREF_DIR.glob("**/*.tif"))
    print(f"{len(sources)} georeferenced TIFFs found")
    if not sources:
        raise SystemExit(f"No GeoTIFFs under {GEOREF_DIR} — run 02_georef.R first.")

    # Refuse, don't skip, anything the ledgers and the manifest do not vouch for:
    # a skipped stale GeoTIFF is invisible, and a converted one ships with a label
    # that describes a different raster.
    selected = selected_ids(LEDGER_DIR)
    manifest = load_manifest()
    stale = []
    for src in sources:
        meta = by_stem.get(src.stem)
        if meta is None:
            continue  # reported below as unmatched
        if str(meta["airp_id"]) not in selected:
            stale.append(f"{src}: frame {meta['airp_id']} is not selected in any ledger")
            continue
        why = vouched(src, meta, manifest, consts["fly_sha"], consts["pipeline_sha"])
        if why:
            stale.append(f"{src}: {why}")
    if stale:
        for line in stale[:10]:
            print(f"  stale: {line}")
        raise SystemExit(f"{len(stale)} GeoTIFF(s) are not vouched for by the current ledgers "
                         "and manifest. Re-run 02_georef.R for their AOI, or remove them.")

    # And the other direction: a COG with no GeoTIFF behind it is left from a
    # frame 02 deleted as stale and did not rewrite.
    expected = {STAC_DIR / s.relative_to(GEOREF_DIR) for s in sources}
    orphans = [c for c in sorted(STAC_DIR.glob("**/*.tif")) if c not in expected]
    if orphans:
        for c in orphans[:10]:
            print(f"  orphan COG: {c}")
        raise SystemExit(f"{len(orphans)} COG(s) have no GeoTIFF behind them — remove them.")

    written = unchanged = 0
    unmatched = []
    for src in sources:
        meta = by_stem.get(src.stem)
        if meta is None:
            unmatched.append(src)
            continue
        dst = STAC_DIR / src.relative_to(GEOREF_DIR)
        dx, dy = shift_of(meta)
        new = write_cog(src, dst, frame_tags(meta, src.stem), dx, dy)

        if args.check_determinism:
            again = write_cog(src, dst, frame_tags(meta, src.stem), dx, dy)
            if again != new:
                raise SystemExit(f"{src}: two writes of the same input differ — "
                                 "a checksum over these COGs would churn on every run")
            print(f"Deterministic: {src.name} wrote identical bytes twice "
                  f"(sha256 {hashlib.sha256(new).hexdigest()[:16]})")
            return 0

        if dst.exists() and dst.read_bytes() == new:
            unchanged += 1
            continue
        dst.parent.mkdir(parents=True, exist_ok=True)
        tmp = dst.with_suffix(".tif.tmp")
        tmp.write_bytes(new)
        tmp.replace(dst)
        written += 1

    # A GeoTIFF with no window row would ship untagged and unplaced, so it is an
    # error rather than a skip. The usual cause is a GeoTIFF left from an AOI
    # whose window has not been rebuilt.
    if unmatched:
        for p in unmatched[:10]:
            print(f"  no window row: {p}")
        raise SystemExit(f"{len(unmatched)} GeoTIFF(s) have no window row — "
                         "re-run 01_fetch.R for their AOI, or remove the stale files.")

    print(f"{written} COGs written, {unchanged} unchanged")
    return 0


if __name__ == "__main__":
    sys.exit(main())
