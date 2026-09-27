"""centroids.py — read the per-AOI centroid caches as one table.

The AOI became a parameter in issue #16, so `data/centroids/` holds one parquet
per AOI rather than a single `centroids_raw.parquet`. The COG and STAC stages
walk the *global* output tree, so both must read every cache: reading one would
leave every other AOI's COGs untagged and drop their items from the collection,
and neither failure raises — a missing `airp_id` just skips.

Columns are merged key-by-key rather than through `pyarrow.concat_tables`, so a
schema difference between two caches cannot abort the read. A key absent from
one cache is padded with None for that cache's rows, keeping every column the
same length as the row count.
"""

from pathlib import Path

import pyarrow.parquet as pq


def centroid_cache_paths(cache_dir: Path) -> list[Path]:
    """Every per-AOI cache, sorted so a run is reproducible."""
    return sorted(Path(cache_dir).glob("*.parquet"))


def load_centroids(cache_dir: Path) -> dict:
    """Merge every per-AOI centroid cache into one dict of columns.

    Rows for an `airp_id` present in two AOIs appear twice; callers key by
    `airp_id` or by thumbnail stem, so the duplicate collapses on lookup.
    """
    paths = centroid_cache_paths(cache_dir)
    if not paths:
        raise FileNotFoundError(
            f"No centroid caches in {cache_dir} — run 01_fetch.R first."
        )

    merged: dict[str, list] = {}
    n_rows = 0

    for path in paths:
        table = pq.read_table(path).to_pydict()
        rows = len(next(iter(table.values()))) if table else 0

        for key, values in table.items():
            # Pad a column this cache introduces back over earlier rows.
            merged.setdefault(key, [None] * n_rows).extend(values)

        n_rows += rows

        # Pad columns earlier caches had and this one lacks.
        for key, values in merged.items():
            if len(values) < n_rows:
                values.extend([None] * (n_rows - len(values)))

    print(f"Loaded {n_rows} centroid rows from {len(paths)} AOI cache(s)")
    return merged


def selected_ids(ledger_dir: Path) -> set:
    """airp_ids a ledger currently selects, across every AOI, as strings.

    A GeoTIFF or COG for any other frame is left from an earlier run —
    deselected by a fly upgrade, a DEM or catalogue refresh, a new `no_bearing` —
    and would otherwise ship stamped with the current run's provenance, because
    its stem still has a window row (the window is every frame, not the selected
    ones). 03_cog.py and 05_stac_register.py both refuse such a frame.
    """
    import csv

    paths = sorted(Path(ledger_dir).glob("*.csv"))
    if not paths:
        raise FileNotFoundError(
            f"No ledgers in {ledger_dir} — run 01_fetch.R and 02_georef.R first.")
    ids = set()
    for path in paths:
        with path.open() as fh:
            for row in csv.DictReader(fh):
                if row["rejected_reason"] == "selected":
                    ids.add(str(row["airp_id"]))
    return ids
