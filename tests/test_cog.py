"""Tests for the single-write COG stage and the checks around it (#23, #30).

Synthetic GeoTIFFs shaped like fly's output — a grey frame as Gray + Alpha and an
RGB frame as RGBA, neither with a NoData (fly 0.19.0, fly#56) — so the tests run on
a fresh clone with no data.

Run:
    uv run pytest tests/ -q
"""

import importlib.util
import json
import sys
from pathlib import Path

import numpy as np
import pytest
import rasterio
from rasterio.enums import ColorInterp, MaskFlags
from rasterio.transform import from_origin

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS))

from airphoto_props import (  # noqa: E402
    FILE_EXTENSION,
    PROCESSING_EXTENSION,
    PROJECTION_EXTENSION,
    REQUIRED_BUILD_PROPERTIES,
    build_properties,
    cog_layout_ok,
    file_meta,
)
from stac_validate import check_item, tags_disagree  # noqa: E402

_spec = importlib.util.spec_from_file_location("cog", SCRIPTS / "03_cog.py")
cog = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cog)


def fly_like(path: Path, rgba: bool, size: int = 64) -> Path:
    """fly_georef()'s output: image bands then an alpha, 0 in the collar."""
    rng = np.random.default_rng(1)
    count = 4 if rgba else 2
    # Genuine black inside the frame: under -dstnodata 0 it was rewritten as 1.
    data = rng.integers(0, 256, size=(count, size, size), dtype=np.uint8)
    data[:, : size // 16, :] = 0  # a collar
    data[-1] = 255
    data[-1, : size // 16, :] = 0
    profile = dict(driver="GTiff", width=size, height=size, count=count, dtype="uint8",
                   crs="EPSG:3005", transform=from_origin(1_200_000, 900_000, 50, 50),
                   alpha="YES")
    with rasterio.open(path, "w", **profile) as ds:
        ds.write(data)
        ds.colorinterp = ([ColorInterp.red, ColorInterp.green, ColorInterp.blue] if rgba
                          else [ColorInterp.gray]) + [ColorInterp.alpha]
    return path


def shaped(path: Path, interp: list, nodata=None) -> Path:
    """A GeoTIFF with these colour interpretations and NoData, alpha 0 in a collar."""
    count = len(interp)
    data = np.random.default_rng(1).integers(0, 256, size=(count, 64, 64), dtype=np.uint8)
    data[:, :4, :] = 0
    if interp[-1] == ColorInterp.alpha:
        data[-1] = 255
        data[-1, :4, :] = 0
    with rasterio.open(path, "w", driver="GTiff", width=64, height=64, count=count,
                       dtype="uint8", crs="EPSG:3005", nodata=nodata,
                       transform=from_origin(1_200_000, 900_000, 50, 50),
                       **({"alpha": "YES"} if interp[-1] == ColorInterp.alpha else {})) as ds:
        ds.write(data)
        ds.colorinterp = interp
    return path


G, R, Gr, B, A, U = (ColorInterp.gray, ColorInterp.red, ColorInterp.green,
                     ColorInterp.blue, ColorInterp.alpha, ColorInterp.undefined)
# Every shape the guard has to classify. Band count x trailing alpha x NoData.
SHAPES = {
    "gray+alpha (fly 0.19)":        ([G, A], None, True),
    "rgba (fly 0.19)":              ([R, Gr, B, A], None, True),
    "gray, nodata 0 (fly < 0.19)":  ([G], 0, False),
    "gray, no nodata":              ([G], None, False),
    "rgb, no nodata":               ([R, Gr, B], None, False),
    "gray+alpha, nodata 0":         ([G, A], 0, False),
    "rgba, nodata 0":               ([R, Gr, B, A], 0, False),
    "gray+undefined+alpha":         ([G, U, A], None, False),
    "rgb+undefined+alpha":        ([R, Gr, B, U, A], None, False),
}


@pytest.mark.parametrize("rgba", [False, True])
def test_the_fixture_is_the_shape_fly_writes(tmp_path, rgba):
    with rasterio.open(fly_like(tmp_path / "src.tif", rgba)) as ds:
        assert ds.count == (4 if rgba else 2) and ds.nodata is None
        assert ds.colorinterp[-1] == ColorInterp.alpha
        assert ds.mask_flag_enums[0] == [MaskFlags.per_dataset, MaskFlags.alpha]


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


@pytest.mark.parametrize("rgba", [False, True])
def test_the_write_is_deterministic(tmp_path, rgba):
    src = fly_like(tmp_path / "src.tif", rgba)
    out = tmp_path / "out.tif"
    first = cog.write_cog(src, out, {"AIRP_ID": "1"}, 10.0, 10.0)
    assert cog.write_cog(src, out, {"AIRP_ID": "1"}, 10.0, 10.0) == first


@pytest.mark.parametrize("rgba", [False, True])
def test_overviews_carry_the_alpha(tmp_path, rgba):
    # Large enough that the COG driver builds overviews. At each level the alpha
    # must stay binary and be the mask a reader sees. This pins that property, not
    # nearest resampling: GDAL 3.12.4 keeps an alpha overview binary under
    # `average` and `cubic` too (measured, code-check round 1).
    src = fly_like(tmp_path / "src.tif", rgba, size=1024)
    out = tmp_path / "out.tif"
    out.write_bytes(cog.write_cog(src, out, {}, 0.0, 0.0))
    with rasterio.open(out) as ds:
        assert ds.overviews(1)
        for f in ds.overviews(1):
            h, w = ds.height // f, ds.width // f
            alpha = ds.read(ds.count, out_shape=(h, w))
            assert set(np.unique(alpha).tolist()) == {0, 255}
            assert np.array_equal(ds.read_masks(1, out_shape=(h, w)), alpha)


@pytest.mark.parametrize("name", SHAPES)
def test_only_an_alpha_masked_geotiff_is_written(tmp_path, name):
    # Refused shapes: fly < 0.19.0's NoData 0 rewrote genuine black as 1; a NoData
    # beside an alpha wins over it, masking that black again; an alpha in a 3- or
    # 5-band dataset masks nothing. check_same_raster() cannot see the last three,
    # because the source and the COG agree.
    interp, nodata, ok = SHAPES[name]
    src = shaped(tmp_path / "src.tif", interp, nodata)
    if ok:
        cog.write_cog(src, tmp_path / "o.tif", {}, 0.0, 0.0)
    else:
        with pytest.raises(SystemExit, match="alpha-masked shape"):
            cog.write_cog(src, tmp_path / "o.tif", {}, 0.0, 0.0)


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


def test_build_properties_puts_the_run_in_the_processing_extension():
    p = build_properties({"placement_source": "none", "fly_version": "0.14.1",
                          "fly_sha": "abc", "pipeline_sha": "def"})
    # The fly build as semver build metadata: one string names the version and the commit.
    assert p["processing:software"] == {"fly": "0.14.1+abc"}
    assert p["processing:version"] == "def"
    assert not [k for k in p if k.startswith("nge:")]


@pytest.mark.parametrize("missing", ["fly_version", "fly_sha"])
@pytest.mark.parametrize("absent", [None, float("nan")])
def test_a_fly_build_missing_either_part_is_omitted_not_half_written(missing, absent):
    meta = {"fly_version": "0.14.1", "fly_sha": "abc", "pipeline_sha": "def"}
    meta[missing] = absent
    p = build_properties(meta)
    # Never "0.14.1+None" or "nan+abc": the validator refuses the item as missing it.
    assert "processing:software" not in p
    assert "missing processing:software" in check_item(_doc(p))


def test_every_required_build_property_is_produced_somewhere():
    produced = set(build_properties({k: "x" for k in (
        "placement_source", "fly_version", "fly_sha", "pipeline_sha")} |
        {"shift_x_m_3005": 0, "shift_y_m_3005": 0}))
    # processing:datetime is stamped by 05 from the COG's mtime, not from a window row.
    assert set(REQUIRED_BUILD_PROPERTIES) - produced == {"processing:datetime"}


# --- stac_validate: field names and the tags behind them (#47) --------------

def _props(**extra) -> dict:
    """Build properties of a publishable digital frame, nothing missing."""
    return {"airphoto:media": "Digital - Colour", "airphoto:placement_source": "none",
            "airphoto:shift_x_m_3005": 0.0, "airphoto:shift_y_m_3005": 0.0,
            "processing:software": {"fly": "0.19.0+0eeb977c3893"},
            "processing:version": "e16dd5307f57",
            "processing:datetime": "2026-09-29T08:52:35.374882+00:00", **extra}


def _doc(props: dict, extensions=None, assets=None) -> dict:
    return {"stac_extensions": extensions if extensions is not None else
            [PROJECTION_EXTENSION, FILE_EXTENSION, PROCESSING_EXTENSION],
            "properties": props, "assets": assets or {}}


def _field_problems(doc: dict) -> list[str]:
    # No thumbnail on disk in these fixtures; that problem is not the one under test.
    return [p for p in check_item(doc) if p != "no thumbnail asset"]


def test_a_publishable_items_fields_pass():
    assert _field_problems(_doc(_props(**{"proj:epsg": 3005}))) == []


@pytest.mark.parametrize("key", ["nge:fly_version", "nge:produced_datetime", "xyz:thing"])
def test_a_property_with_an_undeclared_prefix_is_refused(key):
    problems = _field_problems(_doc(_props(**{key: "x"})))
    assert any(key in p and "undeclared" in p for p in problems), problems


def test_an_asset_field_with_an_undeclared_prefix_is_refused():
    assets = {"flight_log": {"href": "https://x/y.jpg", "roles": ["metadata"],
                             "nge:kept": True}}
    problems = _field_problems(_doc(_props(), assets=assets))
    assert any("nge:kept" in p and "flight_log" in p for p in problems), problems


def test_processing_fields_without_the_extension_are_refused():
    problems = _field_problems(_doc(_props(), [PROJECTION_EXTENSION, FILE_EXTENSION]))
    assert any(PROCESSING_EXTENSION in p for p in problems), problems


@pytest.mark.parametrize("software", [{}, {"gdal": "3.12.4"}, "0.19.0+abc"])
def test_processing_software_without_a_fly_entry_is_refused(software):
    problems = _field_problems(_doc(_props(**{"processing:software": software})))
    assert any("processing:software" in p for p in problems), problems


def _tagged(path: Path, **tags) -> Path:
    fly_like(path, rgba=False)
    with rasterio.open(path, "r+") as ds:
        ds.update_tags(**tags)
    return path


def test_tags_agreeing_with_the_processing_fields_pass(tmp_path):
    cog_path = _tagged(tmp_path / "x.tif", FLY_VERSION="0.19.0", FLY_SHA="0eeb977c3893",
                       PIPELINE_SHA="e16dd5307f57", PLACEMENT_SOURCE="none",
                       SHIFT_X_M_3005="0", SHIFT_Y_M_3005="0")
    assert tags_disagree(cog_path, _props()) == []


@pytest.mark.parametrize("tag,value", [("FLY_VERSION", "0.18.0"), ("FLY_SHA", "ffffffffffff"),
                                       ("PIPELINE_SHA", "000000000000")])
def test_a_tag_disagreeing_with_the_processing_fields_is_reported(tmp_path, tag, value):
    tags = dict(FLY_VERSION="0.19.0", FLY_SHA="0eeb977c3893", PIPELINE_SHA="e16dd5307f57",
                PLACEMENT_SOURCE="none", SHIFT_X_M_3005="0", SHIFT_Y_M_3005="0")
    tags[tag] = value
    problems = tags_disagree(_tagged(tmp_path / "x.tif", **tags), _props())
    assert any(tag in p for p in problems), problems
