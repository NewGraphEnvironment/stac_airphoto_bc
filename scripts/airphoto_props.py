"""airphoto_props.py — catalogue columns to STAC item properties and assets.

Shared by the two callers that must agree: `05_stac_register.py`, which builds
items for COGs on this machine, and `06_catalogue_backfill.py`, which patches the
9,741 items published before those COGs left it. Computing the same two facts in
both places is how one of them silently keeps a defect the other had fixed, so
neither builds a property or an asset itself.

What is here and what is not
----------------------------
The BC Data Catalogue row carries 29 columns and `data/centroids/<aoi>.parquet`
caches all of them. Nine become `airphoto:` properties and three URL columns
become `metadata`-role assets. Deliberately left out:

  `published_ind`   one distinct value (`Y`) across every row measured, so it
                    carries no information and would only look like a filter.
  `airp_id`         it is the item id. Carrying it twice invites the two to
                    disagree.
  `objectid`, `id`, `film_record_id`, `operation_id`,
  `flight_line_segment_id`, `se_anno_cad_data`
                    internal catalogue keys, not facts about the photograph.

The files behind `patb_georef_url` and `camera_calibration_url` are linked, not
parsed. What is unique to a PAT-B file is per-frame exterior orientation, which
is an input to a corrected footprint (#23) rather than something anyone filters
on — and the files arrive in three incompatible formats, one keyed by an internal
photo number this pipeline has no join for. Every question the collection is
being asked to answer is a catalogue column promoted here.
"""

from __future__ import annotations

import os

# Promoted verbatim, prefixed, `None` omitted. The first five predate this module
# and their names and values are unchanged, so no published item's meaning moves.
CATALOGUE_PROPERTY_FIELDS = (
    "scale",
    "focal_length",
    "flying_height",
    "film_roll",
    "frame_number",
    "media",
    "ground_sample_distance",
    "bcgs_tile",
    "nts_tile",
)

# asset key -> catalogue column holding its URL
METADATA_ASSET_FIELDS = {
    "patb_georef": "patb_georef_url",
    "camera_calibration": "camera_calibration_url",
    "flight_log": "flight_log_url",
}

# Human titles, so the asset reads as something in a client's asset list.
_ASSET_TITLES = {
    "patb_georef": "PAT-B photogrammetric solution",
    "camera_calibration": "Camera calibration report",
    "flight_log": "Flight log page",
}

# Suffixes measured over all 9,976 published catalogue rows, 2026-09-07:
#
#   patb_georef_url          .ori 731 (505 lower + 226 `.ORI`), .zip 547,
#                            .csv 473, `.OR` 24        -- FOUR spellings, not three
#   camera_calibration_url   .zip 1302
#   flight_log_url           .jpg 8133
#
# `.OR` is the one that matters: an earlier version of this map was written from
# 2,671 rows out of three small AOIs, where `.OR` does not occur at all, and 24
# assets shipped with no media type. A suffix map is a fact about a third party's
# behaviour, not a contract this repo chose, so it is read off the URL, measured
# against the population rather than a subset, and an unrecognised suffix leaves
# `type` absent instead of asserting one nobody checked.
_MEDIA_TYPES = {
    ".zip": "application/zip",
    ".csv": "text/csv",
    ".ori": "text/plain",
    ".or": "text/plain",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".pdf": "application/pdf",
    ".txt": "text/plain",
}

# Columns where 0 is a missing-value sentinel rather than a measurement.
#
# `ground_sample_distance` is the distance on the ground in CENTIMETRES that one
# pixel represents (the catalogue's own column comment). Measured over 9,976
# rows: 7,336 positive spanning 12-97, 2,167 null, and 473 zero — every zero a
# `Digital - Colour` frame, and zero occurring on no film frame at all. A GSD of
# 0 cm is not a value any sensor produces.
#
# The null guard above cannot see this. It fires on the 2,167 honest nulls and
# misses every instance of the thing it exists for, which is the more dangerous
# half: an absent key makes a consumer look elsewhere, while a published 0
# satisfies every `is not None` test and reads as a measurement. `fly` sizes a
# digital footprint from GSD, so the one consumer that matters most would take it.
ZERO_IS_MISSING = ("ground_sample_distance",)


def georef_metadata(value):
    """`Y`/`N` -> True/False. Anything else -> None, meaning "omit the property".

    The catalogue stores this as a one-character string, and `bool("N")` is True —
    so a truthiness test publishes the exact inverse of the fact for the 87% of
    frames that have no photogrammetric solution. The coercion is therefore
    explicit and closed: two recognised values, and no third answer invented.

    Returning None rather than raising is deliberate. The column was 100%
    populated with `Y`/`N` across every row measured, so an unrecognised value is
    a change upstream, not a broken row — the caller counts and reports them
    (`05_stac_register.py`, `06_catalogue_backfill.py`) rather than aborting a
    9,976-item run over one surprise. The validator then fails on any item that
    ended up without the property, which is where a silent drift becomes loud.
    """
    if value == "Y":
        return True
    if value == "N":
        return False
    return None


def catalogue_properties(meta: dict) -> dict:
    """`airphoto:`-prefixed properties for one catalogue row.

    A null or absent column yields no key at all, matching what the generator has
    always done — consumers test for absence, not for null.
    """
    props = {}

    for field in CATALOGUE_PROPERTY_FIELDS:
        value = meta.get(field)
        if value is None:
            continue
        # `is None` is not the whole of "missing" — see ZERO_IS_MISSING.
        if field in ZERO_IS_MISSING and value == 0:
            continue
        props[f"airphoto:{field}"] = value

    georef = georef_metadata(meta.get("georef_metadata_ind"))
    if georef is not None:
        props["airphoto:georef_metadata"] = georef

    return props


def _media_type(url: str) -> str | None:
    return _MEDIA_TYPES.get(os.path.splitext(url)[1].lower())


def catalogue_assets(meta: dict) -> dict:
    """`metadata`-role assets for the catalogue's retrievable files.

    Plain dicts rather than `pystac.Asset`, because the backfill patches raw item
    JSON and the generator can build an Asset from these itself. One shape, two
    callers.
    """
    assets = {}

    for key, field in METADATA_ASSET_FIELDS.items():
        url = meta.get(field)
        if not url:
            continue

        asset = {"href": url, "title": _ASSET_TITLES[key], "roles": ["metadata"]}
        media_type = _media_type(url)
        if media_type is not None:
            asset["type"] = media_type

        assets[key] = asset

    return assets
