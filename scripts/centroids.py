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
