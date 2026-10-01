"""cog_render-compare.py — draw COGs the way a GDAL client does, published beside local.

Usage:
    conda run -n stac-airphoto-bc python scripts/cog_render-compare.py
    conda run -n stac-airphoto-bc python scripts/cog_render-compare.py 695106 --source published
    conda run -n stac-airphoto-bc python scripts/cog_render-compare.py --sample 5 --seed 7

Each frame is composited over a checkerboard through its alpha, so fill shows as
checkerboard and genuine black shows as black (#36). With `--source both` (the
default) the PNG is published | local | diff, the diff marking every pixel that
differs between the two in magenta.

A spot check of the frames it draws, not a census: a sync that changes other
frames shows nothing here. For those frames it compares the bytes (sha256 of the
published object against the local file) and counts differing pixels at full
resolution and at every overview level, which is what a client draws zoomed out.
`--expect-same` exits 1 unless every drawn frame is byte-identical, for after a
sync. A frame not yet published is reported, not fatal.

Reads only. Writes one PNG per frame and `summary.csv` under
`data/logs/render/<UTC stamp>/` (#40).
"""

import argparse
import csv
import datetime as dt
import hashlib
import http.client
import json
import random
import sys
import urllib.request
import warnings
from pathlib import Path

import numpy as np
import rasterio
from rasterio.enums import Resampling
from rasterio.errors import NotGeoreferencedWarning

BUCKET_URL = "https://stac-airphoto-bc.s3.us-west-2.amazonaws.com/"
STAC_DIR = Path("data/stac")
OUT_DIR = Path("data/logs/render")
SHAPES = ("gray|alpha", "red|green|blue|alpha")
CHECKER = (205, 150)  # light and dark squares, never pure black or white
MAGENTA = np.array([255, 0, 255], dtype=np.uint8)
# Everything a read can raise: RasterioIOError, URLError and HTTPError are OSErrors,
# IncompleteRead is not. Every read in this script goes through one of these handlers.
READ_ERRORS = (OSError, http.client.HTTPException)


def checkerboard(h: int, w: int, square: int = 16) -> np.ndarray:
    yy, xx = np.mgrid[0:h, 0:w]
    light = ((yy // square + xx // square) % 2) == 0
    return np.where(light, CHECKER[0], CHECKER[1]).astype(np.uint8)


def composite(bands: np.ndarray) -> np.ndarray:
    """(count, h, w) uint8 image bands then alpha -> (3, h, w) over a checkerboard."""
    image, alpha = bands[:-1], bands[-1].astype(np.float32) / 255.0
    rgb = np.repeat(image, 3, axis=0) if image.shape[0] == 1 else image[:3]
    board = checkerboard(*alpha.shape)
    out = rgb.astype(np.float32) * alpha + board.astype(np.float32) * (1.0 - alpha)
    return np.clip(np.rint(out), 0, 255).astype(np.uint8)


def diff_panel(a: np.ndarray, b: np.ndarray, base: np.ndarray) -> tuple[np.ndarray, int]:
    """Magenta where a and b differ in any band, over a dimmed `base` (3, h, w)."""
    differs = (a != b).any(axis=0)
    out = (base.astype(np.float32) * 0.4).astype(np.uint8)
    out[:, differs] = MAGENTA[:, None]
    return out, int(differs.sum())


def read(src: str, size: int | None = None) -> tuple[np.ndarray, dict]:
    """Every band (at most `size` px on the long side) and what describes the file."""
    with rasterio.open(src) as ds:
        shape = None
        if size and max(ds.height, ds.width) > size:
            f = size / max(ds.height, ds.width)
            shape = (ds.count, max(1, round(ds.height * f)), max(1, round(ds.width * f)))
        data = ds.read(out_shape=shape, resampling=Resampling.nearest)
        meta = {"shape": "|".join(c.name for c in ds.colorinterp), "nodata": ds.nodata,
                "transform": tuple(ds.transform)[:6], "size": (ds.height, ds.width),
                "mask": ds.mask_flag_enums}
    return data, meta


def stats(full: np.ndarray, meta: dict) -> dict:
    alpha = full[-1]
    has_alpha = meta["shape"].endswith("alpha")
    return {
        "shape": meta["shape"],
        "nodata": "" if meta["nodata"] is None else meta["nodata"],
        "fill_fraction": round(float((alpha == 0).mean()), 4) if has_alpha else "",
        "alpha_binary": bool(np.isin(alpha, (0, 255)).all()) if has_alpha else "",
        "black_under_opaque": int(((full[:-1] == 0).all(axis=0) & (alpha == 255)).sum())
        if has_alpha else "",
    }


def write_png(path: Path, panels: list[np.ndarray], gap: int = 8) -> None:
    h = max(p.shape[1] for p in panels)
    w = sum(p.shape[2] for p in panels) + gap * (len(panels) - 1)
    sheet = np.full((3, h, w), 255, dtype=np.uint8)
    x = 0
    for p in panels:
        sheet[:, : p.shape[1], x: x + p.shape[2]] = p
        x += p.shape[2] + gap
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", NotGeoreferencedWarning)
        with rasterio.open(path, "w", driver="PNG", width=w, height=h, count=3,
                           dtype="uint8") as dst:
            dst.write(sheet)


def level_diffs(a_src: str, b_src: str) -> tuple[bool, int]:
    """(same overview structure, pixels differing summed over every overview level)."""
    with rasterio.open(a_src) as a, rasterio.open(b_src) as b:
        if a.overviews(1) != b.overviews(1):
            return False, 0
        n = len(a.overviews(1))
    total = 0
    for k in range(n):
        with rasterio.open(a_src, overview_level=k) as a, \
                rasterio.open(b_src, overview_level=k) as b:
            total += int((a.read() != b.read()).any(axis=0).sum())
    return True, total


def published_sha256(key: str) -> str:
    with urllib.request.urlopen(BUCKET_URL + key, timeout=120) as r:
        return hashlib.sha256(r.read()).hexdigest()


def magenta(shape: tuple) -> np.ndarray:
    return np.broadcast_to(MAGENTA[:, None, None], shape).copy()


def why(e: Exception) -> str:
    return (str(e).split("\n")[0] or type(e).__name__)[:120]


def frame(key: str, sources: tuple, size: int) -> tuple[dict, list]:
    """One frame's summary row and its panels, one panel per source and then the diff.

    A side that cannot be read keeps its slot as a solid magenta panel, so the
    order printed for the run is the order in every PNG. The bucket refuses
    listing, so a key that does not exist answers 403: before a sync, that is a
    frame not published yet.
    """
    row, full, small, meta = {}, {}, {}, {}
    for s in sources:
        try:
            f, m = read(locate(key, s))
            sm, _ = read(locate(key, s), size)
        except READ_ERRORS as e:
            row[f"{s}_unreadable"] = why(e)
            continue
        full[s], meta[s], small[s] = f, m, sm
        row |= {f"{s}_{k}": v for k, v in stats(f, m).items()}
    drawn = {s: composite(small[s]) for s in small}
    shape = next((d.shape for d in drawn.values()), (3, size, size))
    panels = [drawn[s] if s in drawn else magenta(shape) for s in sources]
    if len(sources) == 1:
        return row, panels

    row["bytes_same"] = False  # until shown otherwise
    if len(full) < 2:
        panels.append(magenta(shape))
        return row, panels
    a, b = full["published"], full["local"]
    row["grid_same"] = (a.shape == b.shape
                        and meta["published"]["transform"] == meta["local"]["transform"])
    if row["grid_same"]:
        row["pixels_differing"] = int((a != b).any(axis=0).sum())
    try:
        same = published_sha256(key) == hashlib.sha256(
            Path(locate(key, "local")).read_bytes()).hexdigest()
        if row["grid_same"]:
            row["overviews_same"], row["overview_pixels_differing"] = level_diffs(
                locate(key, "published"), locate(key, "local"))
        row["bytes_same"] = same
    except READ_ERRORS as e:
        row["compare_error"] = why(e)
    if row["grid_same"] and small["published"].shape == small["local"].shape:
        panels.append(diff_panel(small["published"], small["local"], drawn["local"])[0])
    else:
        panels.append(magenta(shape))
    return row, panels


def items() -> dict:
    """airp_id -> the thumbnail's key under the bucket, from the local item JSONs."""
    out = {}
    for p in sorted(STAC_DIR.glob("[0-9]*.json")):
        item = json.loads(p.read_text())
        href = item["assets"]["thumbnail"]["href"]
        if not href.startswith(BUCKET_URL):
            raise SystemExit(f"{p}: thumbnail href {href} is not under {BUCKET_URL}")
        out[item["id"]] = href[len(BUCKET_URL):]
    if not out:
        raise SystemExit(f"No item JSONs under {STAC_DIR} — run 05_stac_register.py, "
                         "or sync them down from the bucket.")
    return out


def pick(keys: dict, ids: list[str], n: int, seed: int, source: str) -> list[str]:
    """The named ids, then n frames of each band shape in a seeded random order."""
    missing = [i for i in ids if i not in keys]
    if missing:
        raise SystemExit(f"No item for {', '.join(missing)}")
    chosen, want, skipped = list(ids), {s: n for s in SHAPES}, 0
    order = sorted(keys)
    random.Random(seed).shuffle(order)
    side = "published" if source == "published" else "local"
    for i in order:
        if not any(want.values()):
            break
        if i in chosen:
            continue
        try:
            with rasterio.open(locate(keys[i], side)) as ds:
                s = "|".join(c.name for c in ds.colorinterp)
        except READ_ERRORS:
            skipped += 1  # e.g. not published yet; name it to draw it anyway
            continue
        if want.get(s, 0) > 0:
            chosen.append(i)
            want[s] -= 1
    if skipped:
        print(f"  sampling skipped {skipped} frame(s) unreadable on the {side} side")
    short = {s: k for s, k in want.items() if k}
    if short:
        print(f"  only found {', '.join(f'{n - k} of {n} {s}' for s, k in short.items())}")
    return chosen


def locate(key: str, source: str) -> str:
    if source == "published":
        return "/vsicurl/" + BUCKET_URL + key
    return str(STAC_DIR / key)  # the bucket mirrors data/stac (04_s3_upload.R)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("ids", nargs="*", help="airp_ids to draw, before the sample")
    ap.add_argument("--source", choices=("both", "published", "local"), default="both")
    ap.add_argument("--sample", type=int, default=2, help="frames per band shape (default 2)")
    ap.add_argument("--seed", type=int, default=36, help="sample order (default 36)")
    ap.add_argument("--size", type=int, default=600, help="long side of each panel, px")
    ap.add_argument("--out", type=Path, default=None)
    ap.add_argument("--expect-same", action="store_true",
                    help="exit 1 unless every frame drawn is byte-identical published vs local")
    args = ap.parse_args()
    if args.expect_same and args.source != "both":
        raise SystemExit("--expect-same compares published with local; use --source both")

    keys = items()
    chosen = pick(keys, args.ids, args.sample, args.seed, args.source)
    out = args.out or OUT_DIR / dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    out.mkdir(parents=True, exist_ok=True)
    sources = ("published", "local") if args.source == "both" else (args.source,)

    rows = []
    for i in chosen:
        key = keys[i]
        detail, panels = frame(key, sources, args.size)
        row = {"airp_id": i, "file": Path(key).name} | detail
        png = out / f"{i}_{Path(key).stem}.png"
        if panels:
            write_png(png, panels)
        rows.append(row)
        print(f"  {png.name}: " + ", ".join(f"{k}={v}" for k, v in row.items()
                                             if k not in ("airp_id", "file")))

    fields = list(dict.fromkeys(k for r in rows for k in r))
    with (out / "summary.csv").open("w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=fields, restval="")
        w.writeheader()
        w.writerows(rows)
    panels_note = " | ".join(sources) + (" | diff (magenta = differs)" if len(sources) == 2 else "")
    print(f"{len(rows)} frame(s) drawn as [{panels_note}] -> {out}")
    return verdict(rows) if args.expect_same else 0


def verdict(rows: list[dict]) -> int:
    """For --expect-same: 1 unless every frame drawn is byte-identical, unreadable included."""
    differ = [r["airp_id"] for r in rows if r.get("bytes_same") is not True]
    if differ or not rows:
        print(f"NOT SAME: {len(differ)} of {len(rows)} frame(s) differ published vs local: "
              + ", ".join(differ))
        return 1
    print(f"SAME: all {len(rows)} frame(s) byte-identical published vs local")
    return 0


if __name__ == "__main__":
    sys.exit(main())
