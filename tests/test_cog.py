"""Tests for the single-write COG stage and the checks around it (#23, #30).

Synthetic GeoTIFFs shaped like fly's output — a grey frame with nodata 0, an RGBA
frame with an alpha mask — so the tests run on a fresh clone with no data.

Run:
    conda run -n stac-airphoto-bc pytest tests/ -q
"""

import importlib.util
import json
import sys
from pathlib import Path

import numpy as np
import pytest
import rasterio
from rasterio.enums import ColorInterp
from rasterio.transform import from_origin

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS))

from airphoto_props import (  # noqa: E402
    REQUIRED_BUILD_PROPERTIES,
    build_properties,
    cog_layout_ok,
    file_meta,
)

_spec = importlib.util.spec_from_file_location("cog", SCRIPTS / "03_cog.py")
cog = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cog)


def fly_like(path: Path, rgba: bool) -> Path:
    rng = np.random.default_rng(1)
    count = 4 if rgba else 1
    data = rng.integers(1, 256, size=(count, 64, 64), dtype=np.uint8)
    data[:, :4, :] = 0  # a collar
    profile = dict(driver="GTiff", width=64, height=64, count=count, dtype="uint8",
                   crs="EPSG:3005", transform=from_origin(1_200_000, 900_000, 50, 50))
    if rgba:
        data[3] = np.where(data[0] == 0, 0, 255)
    else:
        profile["nodata"] = 0
    with rasterio.open(path, "w", **profile) as ds:
        ds.write(data)
        if rgba:
            ds.colorinterp = [ColorInterp.red, ColorInterp.green, ColorInterp.blue,
                              ColorInterp.alpha]
    return path


@pytest.mark.parametrize("rgba", [False, True])
def test_write_keeps_the_raster_and_moves_it_by_exactly_the_shift(tmp_path, rgba):
    src = fly_like(tmp_path / "src.tif", rgba)
    out = tmp_path / "out.tif"
    out.write_bytes(cog.write_cog(src, out, {"AIRP_ID": "1"}, 150.5, -40.25))
    with rasterio.open(src) as a, rasterio.open(out) as b:
        assert b.colorinterp == a.colorinterp
        assert b.nodata == a.nodata
        assert b.mask_flag_enums == a.mask_flag_enums
        assert np.array_equal(a.read(), b.read())
        assert b.bounds.left - a.bounds.left == pytest.approx(150.5, abs=1e-9)
        assert b.bounds.top - a.bounds.top == pytest.approx(-40.25, abs=1e-9)
        assert b.tags()["AIRP_ID"] == "1"


def test_the_write_is_a_valid_cog_layout(tmp_path):
    src = fly_like(tmp_path / "src.tif", rgba=True)
    out = tmp_path / "out.tif"
    out.write_bytes(cog.write_cog(src, out, {"AIRP_ID": "1"}, 0.0, 0.0))
    assert cog_layout_ok(out)


def test_an_in_place_tag_edit_breaks_the_layout_and_the_check_sees_it(tmp_path):
    # The defect this stage replaced, restored: tag a finished COG in place.
    src = fly_like(tmp_path / "src.tif", rgba=False)
    out = tmp_path / "out.tif"
    out.write_bytes(cog.write_cog(src, out, {}, 0.0, 0.0))
    with rasterio.open(out, "r+", IGNORE_COG_LAYOUT_BREAK="YES") as ds:
        ds.update_tags(FILENAME="x" * 2000)
    assert not cog_layout_ok(out)


def test_the_write_is_deterministic(tmp_path):
    src = fly_like(tmp_path / "src.tif", rgba=True)
    out = tmp_path / "out.tif"
    first = cog.write_cog(src, out, {"AIRP_ID": "1"}, 10.0, 10.0)
    assert cog.write_cog(src, out, {"AIRP_ID": "1"}, 10.0, 10.0) == first


def test_a_rotated_geotransform_is_refused(tmp_path):
    src = tmp_path / "rot.tif"
    with rasterio.open(src, "w", driver="GTiff", width=8, height=8, count=1, dtype="uint8",
                       crs="EPSG:3005",
                       transform=rasterio.Affine(50, 5, 1_200_000, 5, -50, 900_000)) as ds:
        ds.write(np.ones((1, 8, 8), dtype=np.uint8))
    with pytest.raises(SystemExit, match="rotated"):
        cog.write_cog(src, tmp_path / "o.tif", {}, 1.0, 1.0)


@pytest.mark.parametrize("dx,dy", [(float("nan"), 0), (0, float("inf")), (None, 0), ("x", 0)])
def test_a_shift_that_is_not_two_finite_numbers_is_refused(dx, dy):
    with pytest.raises(SystemExit):
        cog.shift_of({"airp_id": 1, "shift_x_m_3005": dx, "shift_y_m_3005": dy})


def test_tags_omit_absent_values_rather_than_writing_nan():
    tags = cog.frame_tags({"airp_id": 1, "height_source": float("nan"),
                           "rotation": None, "shift_x_m_3005": 0.0,
                           "photo_year": 1968}, "bc5282_165")
    assert "HEIGHT_SOURCE" not in tags and "ROTATION" not in tags
    assert tags["SHIFT_X_M_3005"] == "0"
    assert tags["PHOTO_DATE"] == "1968" and "PHOTO_YEAR" not in tags


# --- airphoto_props build helpers -----------------------------------------

def test_file_meta_is_a_sha256_multihash(tmp_path):
    f = tmp_path / "x"
    f.write_bytes(b"abc")
    m = file_meta(f)
    assert m["file:checksum"] == (
        "1220ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    assert m["file:size"] == 3


def test_build_properties_types_and_omissions():
    p = build_properties({"rotation": 90, "rotation_source": "measured",
                          "placement_source": "none", "shift_x_m_3005": 0,
                          "shift_y_m_3005": 12.5, "height_source": float("nan"),
                          "fly_version": "0.14.1", "fly_sha": "abc",
                          "pipeline_sha": "def"})
    assert p["airphoto:rotation"] == 90 and isinstance(p["airphoto:rotation"], int)
    assert p["airphoto:shift_x_m_3005"] == 0.0 and isinstance(p["airphoto:shift_x_m_3005"], float)
    assert "airphoto:height_source" not in p
    json.dumps(p)  # no NaN reaches JSON


def test_every_required_build_property_is_produced_somewhere():
    produced = set(build_properties({k: "x" for k in (
        "placement_source", "fly_version", "fly_sha", "pipeline_sha")} |
        {"shift_x_m_3005": 0, "shift_y_m_3005": 0}))
    # produced_datetime is stamped by 05 from the COG's mtime, not from a window row.
    assert set(REQUIRED_BUILD_PROPERTIES) - produced == {"nge:produced_datetime"}
