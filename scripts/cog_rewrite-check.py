"""cog_rewrite-check.py — would this environment write every local COG with the same bytes?

Usage:
    uv run python scripts/cog_rewrite-check.py              # every COG
    uv run python scripts/cog_rewrite-check.py --workers 4

Run it right after changing the Python environment (a `uv lock --upgrade-package`: a new
rasterio and so a new bundled GDAL, or a new pyarrow that reads the windows differently)
and BEFORE any stage runs under the new lock. The reference is the local COG, so it must
still be the published one: once 03 has run under the new lock it has overwritten every
COG whose bytes changed, and this check then compares the new environment with itself
and passes. A lock-only bump does not move `pipeline_sha` (#45), so 03 does not refuse
to run; nothing stops that ordering but this paragraph. For every COG under data/stac/thumbs it makes 03's
own call, in a temp dir: `write_cog()` on the GeoTIFF behind it, with `frame_tags()` and
`shift_of()` of that frame's window row, read through pyarrow as 03 reads it. Then it
compares the bytes. Tags read back off the COG would hold the tag text fixed, and so
could not see an upgrade that changes it. Nothing under data/ is written except the report.

A "differs" is the environment, or an input changed since 03 last wrote the COG: windows
rebuilt by 01, a GeoTIFF rewritten by 02, or 03_cog.py itself. Run it with the windows,
GeoTIFFs and COGs from one run. 03's guards (run constants, ledger selection, manifest
vouching, orphans) are skipped: none changes the bytes written. Item JSON is not
covered: for that, run `05_stac_register.py --out <scratch dir>` and compare it with
data/stac, also before 05 runs under the new lock, which would rewrite data/stac.

Why not 03_cog.py itself: it writes. A changed byte replaces the local COG, so the
reference is gone by the time anyone looks; this check writes only to a temp dir. (On
a tree whose windows carry another pipeline SHA, as on #44's branch, 03 also refuses
to run at all.) And why not `cog_render-compare.py --expect-same`: it
compares files already written, so it says the same thing under any environment.

Measured 2026-10-07 (#44): all 10,100 matched under uv.lock's environment
(`data/logs/rewrite/20261007T172650Z.csv`, gitignored). Under the conda env it replaced,
an earlier form of this check, with the tags read back off each COG, also matched all
10,100; that form could see a rasterio/GDAL change but not a pyarrow one. One per-frame row goes to
data/logs/rewrite/<stamp>.csv. Exit 1 unless every COG is the same.
"""

import argparse
import csv
import datetime
import importlib.util
import os
import sys
import tempfile
from multiprocessing import Pool
from pathlib import Path

import rasterio

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
_spec = importlib.util.spec_from_file_location("cog", ROOT / "scripts" / "03_cog.py")
cog = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cog)

STAC = cog.STAC_DIR
GEOREF = cog.GEOREF_DIR
LOG_DIR = ROOT / "data" / "logs" / "rewrite"


def rewrite(job: tuple[Path, dict | None]) -> list[str]:
    """[cog, verdict]: `same`, `differs`, or `error: <why>`."""
    dst, meta = job
    rel = dst.relative_to(STAC)
    if meta is None:
        return [str(rel), "error: no window row"]
    try:
        # 03_cog.py main()'s call, verbatim: frame_tags() and shift_of() of the row.
        dx, dy = cog.shift_of(meta)
        with tempfile.TemporaryDirectory() as tmp:
            new = cog.write_cog(GEOREF / rel, Path(tmp) / dst.name,
                                cog.frame_tags(meta, dst.stem), dx, dy)
    except BaseException as e:  # shift_of() and write_cog()'s guards raise SystemExit
        return [str(rel), f"error: {e}"]
    return [str(rel), "same" if new == dst.read_bytes() else "differs"]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--workers", type=int, default=max(1, (os.cpu_count() or 2) - 2))
    args = ap.parse_args()

    cogs = sorted(STAC.glob("**/*.tif"))
    if not cogs:
        raise SystemExit(f"No COGs under {STAC} — nothing to compare.")
    # load_windows(), not run_constants(): the check must run on a tree whose windows
    # carry another pipeline SHA than the code, which run_constants() refuses.
    by_stem = cog.load_windows()
    print(f"rasterio {rasterio.__version__}, GDAL {rasterio.__gdal_version__}: "
          f"rewriting {len(cogs)} COGs on {args.workers} workers", flush=True)
    with Pool(args.workers) as pool:
        rows = pool.map(rewrite, [(c, by_stem.get(c.stem)) for c in cogs], chunksize=50)

    LOG_DIR.mkdir(parents=True, exist_ok=True)
    out = LOG_DIR / f"{datetime.datetime.now(datetime.UTC):%Y%m%dT%H%M%SZ}.csv"
    with out.open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["cog", "verdict"])
        w.writerows(rows)

    bad = [r for r in rows if r[1] != "same"]
    for r in bad[:10]:
        print(f"  {r[0]}: {r[1]}")
    print(f"{len(rows) - len(bad)} same, {len(bad)} not -> {out.relative_to(ROOT)}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
