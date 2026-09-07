#!/usr/bin/env python3
"""06_catalogue_validate.py — refuse a backfill that is not what it claims to be.

Runs over the tree `06_catalogue_backfill.py` wrote, BEFORE anything is promoted
into `data/stac/` or synced. Seven guards, each printing a distinct `FAIL [NAME]`
line so that restoring a defect proves the guard you meant, not merely that
something exited 1 — a suite with seven guards has seven ways to exit 1 and only
one of them is your evidence.

  COUNT      one patched item per published item link
  BOOLEAN    every item carries airphoto:georef_metadata as a JSON boolean
  DIAGONAL   patb_georef asset present iff georef_metadata is true
  VALUES     the item's airphoto:* set equals what the catalogue row produces,
             derived from the parquet rather than read back out of the artifact
  SENTINEL   the count of omitted ground_sample_distance values matches the raw
             catalogue's nulls and zeros -- VALUES runs both sides through
             catalogue_properties(), so a bug inside it moves both together;
             this counts straight off the column and does not
  ADDITIVE   nothing the published item carried was changed or dropped
  SCHEMA     pystac validates every item

ADDITIVE re-fetches the live published items, which is the point: comparing the
patched tree against itself, or against the writer's own record of what it did,
cannot disagree with the writer. It is the expensive guard and it is the one that
catches an overwrite. --sample trades completeness for speed on a smoke run and
says so in the output.

Usage:
    conda run -n stac-airphoto-bc python scripts/06_catalogue_validate.py
    ... --dir /tmp/patch --sample 50
"""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import random
import sys
import urllib.request
from pathlib import Path
from urllib.parse import unquote

import pyarrow.parquet as pq
import pystac

sys.path.insert(0, str(Path(__file__).parent))
from airphoto_props import (  # noqa: E402
    METADATA_ASSET_FIELDS,
    ZERO_IS_MISSING,
    catalogue_assets,
    catalogue_properties,
    georef_metadata,
)

BUCKET = "stac-airphoto-bc"
S3_REGION = "us-west-2"
S3_BASE = f"https://{BUCKET}.s3.{S3_REGION}.amazonaws.com"
COLLECTION_URL = f"{S3_BASE}/collection.json"
CATALOGUE_PATH = Path("data/catalogue/published.parquet")

TIMEOUT = 60
RETRIES = 3


def fetch_json(url: str) -> dict:
    last = None
    for _ in range(RETRIES):
        try:
            with urllib.request.urlopen(url, timeout=TIMEOUT) as resp:
                return json.load(resp)
        except Exception as exc:  # noqa: BLE001
            last = exc
    raise RuntimeError(f"failed to fetch {url}: {last}")


def item_id(href: str) -> str:
    return unquote(href.rstrip("/").split("/")[-1]).rsplit(".", 1)[0]


def load_catalogue(path: Path) -> dict:
    table = pq.read_table(path).to_pydict()
    n = len(table["airp_id"])
    return {str(table["airp_id"][i]): {k: v[i] for k, v in table.items()}
            for i in range(n)}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--dir", type=Path, default=Path("data/stac_patched"))
    ap.add_argument("--limit", type=int,
                    help="expect only the first N published items, matching a "
                         "backfill run with the same --limit (smoke test)")
    ap.add_argument("--sample", type=int,
                    help="check ADDITIVE against this many live items, not all")
    ap.add_argument("--workers", type=int, default=16)
    args = ap.parse_args()

    if not args.dir.is_dir():
        print(f"FAIL [COUNT] {args.dir} does not exist", file=sys.stderr)
        return 1

    if not CATALOGUE_PATH.exists():
        print(f"FAIL [VALUES] no catalogue at {CATALOGUE_PATH} — run "
              "scripts/06_catalogue_fetch.R", file=sys.stderr)
        return 1

    catalogue = load_catalogue(CATALOGUE_PATH)
    collection = fetch_json(COLLECTION_URL)
    links = [l["href"] for l in collection.get("links", [])
             if l.get("rel") == "item"]

    # --limit takes the FIRST N links, in the collection's own order, which is
    # exactly what the backfill's --limit takes. The two therefore name the same
    # set, and COUNT stays a real guard on a smoke run instead of a known
    # failure everyone learns to ignore.
    if args.limit:
        links = links[:args.limit]
        print(f"--limit {args.limit}: PARTIAL CHECK over the first "
              f"{len(links)} published item(s). Not a release gate.\n")
        # And a weak one in a specific way. Item links are sorted by href, and
        # the first item with a photogrammetric solution sits at index 1915 —
        # so any --limit below that yields a set where georef_metadata is false
        # on every item and no patb_georef or camera_calibration asset exists at
        # all. DIAGONAL then compares two constants and cannot fail. The
        # vacuity warning below says so rather than letting a green partial run
        # read as evidence.

    hrefs = {item_id(h): h for h in links}

    paths = sorted(p for p in args.dir.glob("*.json")
                   if p.name != "collection.json")
    patched = {p.stem: json.loads(p.read_text()) for p in paths}

    print(f"{len(patched)} patched item(s) in {args.dir}")
    print(f"{len(hrefs)} published item link(s)")
    print(f"{len(catalogue)} catalogue row(s)\n")

    failures: list[str] = []

    # --- COUNT --------------------------------------------------------------
    # Both directions. A patched set that is short leaves items unimproved; one
    # that is long means a file is in the tree that the collection does not
    # publish, and the sync would upload it.
    short = set(hrefs) - set(patched)
    over = set(patched) - set(hrefs)
    if short:
        failures.append(
            f"FAIL [COUNT] {len(short)} published item(s) not in {args.dir}: "
            f"{', '.join(sorted(short)[:10])}")
    if over:
        failures.append(
            f"FAIL [COUNT] {len(over)} file(s) in {args.dir} that the published "
            f"collection does not list: {', '.join(sorted(over)[:10])}")

    # --- BOOLEAN, DIAGONAL, VALUES -----------------------------------------
    # georef_metadata_ind was Y or N on all 9,976 rows and the cross-tab against
    # patb_georef_url was perfectly diagonal (06_catalogue_fetch.R prints both).
    # So a missing property or an off-diagonal asset is a defect here, not an
    # expected absence — which is only true because it was measured, and is why
    # the fetch prints those numbers on every run.
    no_bool, wrong_type, off_diag, wrong_value = [], [], [], []

    for iid, item in patched.items():
        props = item.get("properties", {})
        assets = item.get("assets", {})
        meta = catalogue.get(iid)

        value = props.get("airphoto:georef_metadata")
        if "airphoto:georef_metadata" not in props:
            no_bool.append(iid)
        elif not isinstance(value, bool):
            wrong_type.append((iid, value))

        has_patb = "patb_georef" in assets
        if value is True and not has_patb:
            off_diag.append(f"{iid}: georef_metadata true, no patb_georef asset")
        elif value is False and has_patb:
            off_diag.append(f"{iid}: georef_metadata false, patb_georef asset present")

        if meta is None:
            wrong_value.append(f"{iid}: no catalogue row")
            continue

        # Re-derived from the parquet. Reading the expectation back out of the
        # item would compare the artifact with itself and could never disagree.
        expected_bool = georef_metadata(meta.get("georef_metadata_ind"))
        if expected_bool is not None and value != expected_bool:
            wrong_value.append(
                f"{iid}: georef_metadata {value!r}, catalogue says {expected_bool!r}")

        # Both sides through the same rule, applied to the catalogue rather than
        # read back out of the item. A first version compared each item against
        # the raw column and fired on all 473 sentinel omissions -- the guard was
        # deriving "what should be here" one way and the writer another, which is
        # one fact derived twice. `footprint_basis` is excluded because the
        # generator sets it from fly, not from the catalogue.
        expected_props = {k: v for k, v in catalogue_properties(meta).items()}
        actual_props = {k: v for k, v in props.items()
                        if k.startswith("airphoto:")
                        and k != "airphoto:footprint_basis"}
        if actual_props != expected_props:
            for key in set(expected_props) | set(actual_props):
                if expected_props.get(key) != actual_props.get(key):
                    wrong_value.append(
                        f"{iid}: {key} is {actual_props.get(key)!r}, "
                        f"catalogue says {expected_props.get(key)!r}")

        expected_assets = catalogue_assets(meta)
        actual_meta_assets = {k: v for k, v in assets.items()
                              if k in METADATA_ASSET_FIELDS}
        if actual_meta_assets != expected_assets:
            for key in set(expected_assets) | set(actual_meta_assets):
                if expected_assets.get(key) != actual_meta_assets.get(key):
                    wrong_value.append(
                        f"{iid}: asset {key} does not match the catalogue")

    if no_bool:
        failures.append(
            f"FAIL [BOOLEAN] {len(no_bool)} item(s) have no "
            f"airphoto:georef_metadata: {', '.join(sorted(no_bool)[:10])}")
    if wrong_type:
        failures.append(
            f"FAIL [BOOLEAN] {len(wrong_type)} item(s) carry a non-boolean "
            f"airphoto:georef_metadata: {wrong_type[:5]}")
    if off_diag:
        failures.append(
            f"FAIL [DIAGONAL] {len(off_diag)} item(s) break "
            f"patb_georef-iff-georef_metadata: {'; '.join(off_diag[:5])}")
    if wrong_value:
        failures.append(
            f"FAIL [VALUES] {len(wrong_value)} property/asset mismatch(es) "
            f"against the catalogue: {'; '.join(wrong_value[:5])}")

    # --- SENTINEL -----------------------------------------------------------
    # VALUES now derives both sides through catalogue_properties(), which is the
    # only way it can agree with the writer about a sentinel — but it also means
    # a bug inside that function is invisible to it, because both sides move
    # together. This guard is the one that does not: it counts, straight off the
    # raw catalogue column, how many items SHOULD have no ground_sample_distance
    # (null or zero) and compares that to how many actually do not.
    for field in ZERO_IS_MISSING:
        key = f"airphoto:{field}"
        raw_absent = {iid for iid in patched
                      if catalogue.get(iid, {}).get(field) in (None, 0)}
        item_absent = {iid for iid in patched if key not in patched[iid].get(
            "properties", {})}
        if raw_absent != item_absent:
            failures.append(
                f"FAIL [SENTINEL] {key}: {len(item_absent)} item(s) omit it, "
                f"but {len(raw_absent)} catalogue row(s) are null or zero "
                f"(differ on {len(raw_absent ^ item_absent)})")
        else:
            print(f"SENTINEL {key}: absent on {len(item_absent)} item(s), "
                  f"matching the catalogue's nulls and zeros")

    # --- ADDITIVE -----------------------------------------------------------
    ids = sorted(set(patched) & set(hrefs))
    if args.sample and args.sample < len(ids):
        ids = random.Random(42).sample(ids, args.sample)
        print(f"ADDITIVE: sampling {len(ids)} live item(s) — NOT a complete check")
    else:
        print(f"ADDITIVE: comparing all {len(ids)} item(s) against the live "
              f"published copies")

    additive = []

    def compare(iid: str) -> list[str]:
        live = fetch_json(hrefs[iid])
        new = patched[iid]
        out = []
        for key, value in live.get("properties", {}).items():
            if key not in new.get("properties", {}):
                out.append(f"{iid}: property {key} dropped")
            elif new["properties"][key] != value:
                out.append(f"{iid}: property {key} changed")
        for key, value in live.get("assets", {}).items():
            if key not in new.get("assets", {}):
                out.append(f"{iid}: asset {key} dropped")
            elif new["assets"][key] != value:
                out.append(f"{iid}: asset {key} changed")
        for key in ("id", "geometry", "bbox", "stac_version", "stac_extensions",
                    "collection", "links"):
            if key in live and live[key] != new.get(key):
                out.append(f"{iid}: {key} changed")
        return out

    with concurrent.futures.ThreadPoolExecutor(args.workers) as pool:
        for i, result in enumerate(pool.map(compare, ids), 1):
            additive.extend(result)
            if i % 1000 == 0:
                print(f"  {i}/{len(ids)}")

    if additive:
        failures.append(
            f"FAIL [ADDITIVE] {len(additive)} change(s) to already-published "
            f"content: {'; '.join(additive[:5])}")

    # --- SCHEMA -------------------------------------------------------------
    schema_errors = []
    for iid, item in patched.items():
        try:
            pystac.Item.from_dict(item).validate()
        except Exception as exc:  # noqa: BLE001
            schema_errors.append(f"{iid}: {exc}")
    if schema_errors:
        failures.append(
            f"FAIL [SCHEMA] {len(schema_errors)} item(s) do not validate: "
            f"{'; '.join(schema_errors[:3])}")

    # --- Report -------------------------------------------------------------
    n_true = sum(1 for i in patched.values()
                 if i["properties"].get("airphoto:georef_metadata") is True)
    print(f"\nairphoto:georef_metadata true on {n_true} of {len(patched)} item(s)")
    for key in METADATA_ASSET_FIELDS:
        n = sum(1 for i in patched.values() if key in i.get("assets", {}))
        print(f"{key} asset on {n} item(s)")

    n_typeless = sum(1 for i in patched.values()
                     for k, a in i.get("assets", {}).items()
                     if k in METADATA_ASSET_FIELDS and "type" not in a)
    print(f"metadata assets with no media type: {n_typeless}")

    # A guard that cannot fail on the set it was given has proved nothing, and a
    # green run is exactly when nobody looks. Say it out loud rather than
    # printing a pass the reader will over-read. Not a failure: a deliberately
    # narrow run is legitimate, it just is not evidence about these branches.
    vacuous = []
    if n_true == 0:
        vacuous.append("DIAGONAL — no item has georef_metadata true, so the "
                       "'patb_georef present when true' arm never ran")
    if n_true == len(patched):
        vacuous.append("DIAGONAL — every item is true, so the 'absent when "
                       "false' arm never ran")
    if not any("airphoto:ground_sample_distance" not in i["properties"]
               for i in patched.values()):
        vacuous.append("VALUES — every item carries a ground_sample_distance, "
                       "so neither the null nor the zero-sentinel arm ran")
    for v in vacuous:
        print(f"VACUOUS: {v}")

    if failures:
        print()
        for f in failures:
            print(f, file=sys.stderr)
        return 1

    print("\nAll guards passed: COUNT BOOLEAN DIAGONAL VALUES SENTINEL "
          "ADDITIVE SCHEMA")
    return 0


if __name__ == "__main__":
    sys.exit(main())
