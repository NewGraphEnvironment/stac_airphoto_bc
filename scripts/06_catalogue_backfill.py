#!/usr/bin/env python3
"""06_catalogue_backfill.py — add the catalogue metadata to already-published items.

`05_stac_register.py` builds items from the COGs on this machine. 235 of the
9,976 published items have a COG here; the other 9,741 were published from a
machine whose `data/` is long gone, and the merge only carries their *links*
forward — their item JSONs are never rewritten. So the collection would answer
"which frames have a photogrammetric solution?" for the southeast AOIs and
silently not for the Neexdzii Kwa watershed, which is worse than not answering it
at all.

This fetches each published item over HTTPS and adds the same properties and
assets the generator now adds, from the same module, so the two cannot drift.

Additive only — checked, not asserted
------------------------------------
The intent is that no existing property, asset, geometry or link changes. The
published items carry a `proj:transform` and a footprint computed from COGs this
machine does not have; recomputing any of that is out of scope and would be
guesswork.

But `patch()` uses `dict.update()`, and five of the promoted fields — `scale`,
`focal_length`, `flying_height`, `film_roll`, `frame_number` — are already on
every published item, so the code *can* overwrite them if the catalogue has
moved since publication. That is not hypothetical bookkeeping: an item's `title`
bakes in `film_roll` and `frame_number`, its `proj:transform` was computed from
the old `scale` and `focal_length`, and `03_cog_tag.py` wrote those values into
the COG itself — so a silent upstream correction would split one item against
its own title, its own footprint and its own raster tags.

A comment claiming that cannot happen would be a comment instead of a check. So
`06_catalogue_validate.py` compares every patched item against the LIVE
published copy and fails on any changed value. Measured over all 9,976 items,
2026-09-07: zero changes.

Writes only to --out-dir. Nothing here touches S3, `data/stac/`, or
`collection.json`.

Usage:
    conda run -n stac-airphoto-bc python scripts/06_catalogue_backfill.py
    ... --limit 50 --out-dir /tmp/patch      # smoke test
"""

from __future__ import annotations

import argparse
import collections
import concurrent.futures
import json
import sys
import urllib.request
from pathlib import Path
from urllib.parse import unquote

import pyarrow.parquet as pq

sys.path.insert(0, str(Path(__file__).parent))
from airphoto_props import (  # noqa: E402
    catalogue_assets,
    catalogue_properties,
    georef_metadata,
)

BUCKET = "stac-airphoto-bc"
S3_REGION = "us-west-2"
S3_BASE = f"https://{BUCKET}.s3.{S3_REGION}.amazonaws.com"
COLLECTION_URL = f"{S3_BASE}/collection.json"
CATALOGUE_PATH = Path("data/catalogue/published.parquet")

# Every fetch gets a deadline. Without one a single hung connection pins a worker
# slot forever, and from outside a wedged pool and a slow pool look identical --
# there is no signal that distinguishes "still working" from "will never finish".
TIMEOUT = 60
RETRIES = 3


def fetch_json(url: str) -> dict:
    last = None
    for _ in range(RETRIES):
        try:
            with urllib.request.urlopen(url, timeout=TIMEOUT) as resp:
                return json.load(resp)
        except Exception as exc:  # noqa: BLE001 — 10k requests; flakes happen
            last = exc
    raise RuntimeError(f"failed to fetch {url}: {last}")


def item_id(href: str) -> str:
    """Item id from a link href — the same derivation 05_stac_register.py uses."""
    return unquote(href.rstrip("/").split("/")[-1]).rsplit(".", 1)[0]


def load_catalogue(path: Path) -> dict:
    """airp_id (as str, matching the item id) -> catalogue row."""
    if not path.exists():
        raise SystemExit(
            f"No catalogue at {path}. Run:\n"
            "    Rscript scripts/06_catalogue_fetch.R"
        )
    table = pq.read_table(path).to_pydict()
    n = len(table["airp_id"])
    rows = {}
    for i in range(n):
        rows[str(table["airp_id"][i])] = {k: v[i] for k, v in table.items()}
    print(f"Loaded {len(rows)} catalogue row(s) from {path}")
    return rows


def patch(item: dict, meta: dict) -> dict:
    """Add the catalogue properties and assets.

    `update()` can overwrite the five catalogue properties published items
    already carry. That it does not is a measurement, not a property of this
    code — see the module docstring, and the ADDITIVE guard that enforces it.
    """
    item["properties"].update(catalogue_properties(meta))

    for key, asset in catalogue_assets(meta).items():
        item.setdefault("assets", {})[key] = asset

    return item


def process(href: str, meta: dict, out_dir: Path) -> str | None:
    """Fetch, patch, write one item. Returns its georef_metadata_ind if odd."""
    item = patch(fetch_json(href), meta)
    (out_dir / f"{item['id']}.json").write_text(json.dumps(item, indent=2))
    flag = meta.get("georef_metadata_ind")
    return None if georef_metadata(flag) is not None else flag


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out-dir", type=Path, default=Path("data/stac_patched"))
    ap.add_argument("--limit", type=int,
                    help="process only the first N items (smoke test)")
    ap.add_argument("--workers", type=int, default=16)
    args = ap.parse_args()

    args.out_dir.mkdir(parents=True, exist_ok=True)

    catalogue = load_catalogue(CATALOGUE_PATH)

    print(f"Fetching {COLLECTION_URL}")
    collection = fetch_json(COLLECTION_URL)
    hrefs = [l["href"] for l in collection.get("links", [])
             if l.get("rel") == "item"]
    if not hrefs:
        raise SystemExit("Published collection carries no item links.")

    if args.limit:
        hrefs = hrefs[:args.limit]
    print(f"{len(hrefs)} published item(s) -> {args.out_dir}")

    # An item whose catalogue row is missing cannot be patched, and silently
    # writing it back unchanged would leave the validator's "every item carries
    # the boolean" check failing with no explanation. 06_catalogue_fetch.R
    # already refuses on a shortfall, so this can only fire when the two are run
    # against different collections — say so rather than producing a partial set.
    absent = [item_id(h) for h in hrefs if item_id(h) not in catalogue]
    if absent:
        raise SystemExit(
            f"{len(absent)} published item(s) have no row in {CATALOGUE_PATH}: "
            f"{', '.join(absent[:10])}{' ...' if len(absent) > 10 else ''}\n"
            "Re-run scripts/06_catalogue_fetch.R — it is keyed to the published "
            "collection and refuses on a shortfall, so this means the parquet "
            "predates the collection it is being used against."
        )

    unrecognised = collections.Counter()
    done = 0

    with concurrent.futures.ThreadPoolExecutor(args.workers) as pool:
        futures = {
            pool.submit(process, h, catalogue[item_id(h)], args.out_dir): h
            for h in hrefs
        }
        for fut in concurrent.futures.as_completed(futures):
            # Let a failure propagate. A patch set silently short of the
            # collection is exactly the input that must never reach a publish
            # step, and this script's whole output is one such input.
            odd = fut.result()
            if odd is not None:
                unrecognised[odd] += 1
            done += 1
            if done % 1000 == 0:
                print(f"  {done}/{len(hrefs)}")

    written = len(list(args.out_dir.glob("*.json")))
    print(f"\nfetched: {len(hrefs)}")
    print(f"written: {written}")

    if unrecognised:
        print("georef_metadata_ind values that are neither Y nor N "
              "(airphoto:georef_metadata is absent on those items):")
        for value, count in unrecognised.most_common():
            print(f"  {value!r}: {count}")

    if written != len(hrefs):
        print(f"ERROR: wrote {written} file(s) for {len(hrefs)} item(s)",
              file=sys.stderr)
        return 1

    print(f"\nNothing published yet. Validate before promoting:\n"
          f"    python scripts/06_catalogue_validate.py --dir {args.out_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
