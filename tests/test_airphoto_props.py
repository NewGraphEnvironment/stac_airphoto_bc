"""Unit tests for the shared catalogue property/asset builder.

These cover the two coercions that can fail silently:

  * `Y`/`N` -> boolean. A bare truthiness test lands the string "N" as True, which
    is the exact inversion of the fact the issue exists to publish. Anything that
    is not `Y` or `N` must be omitted, never guessed at, and never truthy.
  * a null catalogue value -> an absent key, not a JSON null. The existing
    generator already behaves that way (05_stac_register.py), and pgstac
    consumers therefore test for absence.

Run:
    conda run -n stac-airphoto-bc pytest tests/ -q
"""

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))

from airphoto_props import (  # noqa: E402
    CATALOGUE_PROPERTY_FIELDS,
    METADATA_ASSET_FIELDS,
    catalogue_assets,
    catalogue_properties,
    georef_metadata,
)

# A row shaped like one from data/centroids/<aoi>.parquet, every field populated.
FULL = {
    "airp_id": 1006040,
    "scale": "1:15000",
    "focal_length": 305,
    "flying_height": 6553,
    "film_roll": "bcc837",
    "frame_number": 146,
    "media": "Film - Colour",
    "ground_sample_distance": 25,
    "bcgs_tile": "082e030",
    "nts_tile": "082F01",
    "georef_metadata_ind": "Y",
    "patb_georef_url": "https://openmaps.gov.bc.ca/thumbs/patb_files/82fg_ln01_13.ori",
    "camera_calibration_url": "https://openmaps.gov.bc.ca/thumbs/calib_report_zips/13181_2001.zip",
    "flight_log_url": "https://openmaps.gov.bc.ca/thumbs/logbooks/1972/roll_pages/bc7433_2.jpg",
}


# --- georef_metadata: the coercion that must not fail toward True ----------


def test_yes_and_no_map_to_real_booleans():
    assert georef_metadata("Y") is True
    assert georef_metadata("N") is False


@pytest.mark.parametrize("value", ["y", "n", "", "Unknown", "T", "0", None, 0, 1])
def test_anything_else_is_omitted_and_never_truthy(value):
    """The failure that matters is "N"-like input landing as True.

    Returning None (omit) is the only safe answer for a value we do not
    recognise: a guess in either direction publishes a fact we did not measure.
    """
    out = georef_metadata(value)
    assert out is None, f"{value!r} should be omitted, got {out!r}"
    assert out is not True


def test_property_is_a_json_boolean_not_a_string():
    props = catalogue_properties(FULL)
    assert props["airphoto:georef_metadata"] is True
    assert not isinstance(props["airphoto:georef_metadata"], str)

    props_n = catalogue_properties({**FULL, "georef_metadata_ind": "N"})
    assert props_n["airphoto:georef_metadata"] is False


def test_unrecognised_flag_leaves_the_key_absent():
    props = catalogue_properties({**FULL, "georef_metadata_ind": "maybe"})
    assert "airphoto:georef_metadata" not in props


# --- catalogue_properties -------------------------------------------------


def test_full_row_yields_exactly_the_expected_key_set():
    props = catalogue_properties(FULL)
    expected = {f"airphoto:{f}" for f in CATALOGUE_PROPERTY_FIELDS}
    expected.add("airphoto:georef_metadata")
    assert set(props) == expected


def test_a_null_value_produces_no_key_rather_than_a_null():
    props = catalogue_properties({**FULL, "ground_sample_distance": None})
    assert "airphoto:ground_sample_distance" not in props
    assert None not in props.values()


def test_a_missing_column_is_treated_like_a_null():
    """centroids.load_centroids pads absent columns, but a caller may not."""
    thin = {k: v for k, v in FULL.items() if k != "bcgs_tile"}
    props = catalogue_properties(thin)
    assert "airphoto:bcgs_tile" not in props


def test_every_key_carries_the_airphoto_prefix():
    props = catalogue_properties(FULL)
    assert all(k.startswith("airphoto:") for k in props)


def test_values_pass_through_unchanged():
    props = catalogue_properties(FULL)
    assert props["airphoto:scale"] == "1:15000"
    assert props["airphoto:ground_sample_distance"] == 25
    assert props["airphoto:media"] == "Film - Colour"


def test_airp_id_is_not_promoted():
    """It is the item id; carrying it twice invites the two to disagree."""
    assert "airphoto:airp_id" not in catalogue_properties(FULL)


# --- catalogue_assets -----------------------------------------------------


def test_all_three_assets_when_every_url_is_present():
    assets = catalogue_assets(FULL)
    assert set(assets) == set(METADATA_ASSET_FIELDS)


def test_an_asset_appears_only_for_a_non_null_url():
    assets = catalogue_assets({**FULL, "patb_georef_url": None})
    assert "patb_georef" not in assets
    assert "camera_calibration" in assets and "flight_log" in assets


def test_no_assets_at_all_when_no_urls():
    bare = {k: v for k, v in FULL.items() if not k.endswith("_url")}
    assert catalogue_assets(bare) == {}


def test_every_asset_carries_the_metadata_role():
    for asset in catalogue_assets(FULL).values():
        assert asset["roles"] == ["metadata"]


@pytest.mark.parametrize(
    "url,expected",
    [
        ("https://x/a.zip", "application/zip"),
        ("https://x/a.csv", "text/csv"),
        ("https://x/a.ori", "text/plain"),
        ("https://x/A.ORI", "text/plain"),
        ("https://x/a.jpg", "image/jpeg"),
    ],
)
def test_media_type_comes_from_the_extension(url, expected):
    assets = catalogue_assets({**FULL, "patb_georef_url": url})
    assert assets["patb_georef"]["type"] == expected


def test_an_unknown_extension_omits_the_type_rather_than_guessing():
    """Measured: every calibration URL ends .zip today. That is a fact about a
    third party's behaviour, not a contract, so an unrecognised suffix must
    leave `type` off rather than assert a media type nobody checked."""
    assets = catalogue_assets({**FULL, "patb_georef_url": "https://x/no_extension"})
    assert "type" not in assets["patb_georef"]
    assert assets["patb_georef"]["href"] == "https://x/no_extension"


def test_href_is_carried_verbatim():
    assets = catalogue_assets(FULL)
    assert assets["flight_log"]["href"] == FULL["flight_log_url"]


def test_assets_are_plain_dicts_serialisable_into_an_item():
    import json

    json.dumps(catalogue_assets(FULL))
    json.dumps(catalogue_properties(FULL))
