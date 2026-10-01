"""Tests for the render check (#40): what the panels show and what the diff counts.

Run:
    conda run -n stac-airphoto-bc pytest tests/ -q
"""

import importlib.util
from pathlib import Path

import numpy as np
import rasterio

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
_spec = importlib.util.spec_from_file_location("render", SCRIPTS / "cog_render-compare.py")
render = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(render)


def gray_alpha(h=32, w=32):
    data = np.zeros((2, h, w), dtype=np.uint8)
    data[0, :, :] = 0      # genuine black everywhere...
    data[1, :, :] = 255    # ...opaque...
    data[1, :4, :] = 0     # ...except a collar
    return data


def test_fill_draws_as_checkerboard_and_black_stays_black():
    out = render.composite(gray_alpha())
    board = render.checkerboard(32, 32)
    assert np.array_equal(out[:, :4, :], np.repeat(board[None, :4, :], 3, axis=0))
    assert (out[:, 4:, :] == 0).all()
    # Neither checker colour is black, so fill and black cannot be confused.
    assert 0 not in render.CHECKER


def test_rgba_uses_its_own_colours():
    data = np.zeros((4, 8, 8), dtype=np.uint8)
    data[0], data[3] = 200, 255
    out = render.composite(data)
    assert (out[0] == 200).all() and (out[1] == 0).all() and (out[2] == 0).all()


def test_the_diff_marks_exactly_the_pixels_that_differ_in_any_band():
    a = gray_alpha()
    b = a.copy()
    b[0, 10, 10] = 1       # an image value
    b[1, 20, 20] = 0       # an alpha value alone
    panel, n = render.diff_panel(a, b, render.composite(b))
    assert n == 2
    magenta = (panel == render.MAGENTA[:, None, None]).all(axis=0)
    assert magenta.sum() == 2 and magenta[10, 10] and magenta[20, 20]


def test_identical_inputs_draw_no_magenta():
    a = gray_alpha()
    panel, n = render.diff_panel(a, a.copy(), render.composite(a))
    assert n == 0
    assert not (panel == render.MAGENTA[:, None, None]).all(axis=0).any()


def test_stats_count_black_under_an_opaque_alpha_only():
    data = gray_alpha()
    s = render.stats(data, {"shape": "gray|alpha", "nodata": None})
    assert s["black_under_opaque"] == 28 * 32
    assert s["fill_fraction"] == round(4 / 32, 4)
    assert s["alpha_binary"] is True


def test_the_png_is_the_panels_side_by_side(tmp_path):
    p = tmp_path / "x.png"
    a, b = render.composite(gray_alpha()), render.composite(gray_alpha(16, 16))
    render.write_png(p, [a, b], gap=8)
    with rasterio.open(p) as ds:
        assert (ds.count, ds.height, ds.width) == (3, 32, 32 + 8 + 16)
        assert np.array_equal(ds.read()[:, :, :32], a)


# --- frame(): bytes, overviews, an unpublished frame -----------------------
# `locate` and `published_sha256` are swapped for local files, so these run offline.

import hashlib  # noqa: E402
import http.client  # noqa: E402

import pytest  # noqa: E402

from rasterio.shutil import copy as rio_copy  # noqa: E402
from rasterio.transform import from_origin  # noqa: E402


def cog(path, resampling, size=1024):
    rng = np.random.default_rng(3)
    data = rng.integers(0, 256, size=(2, size, size), dtype=np.uint8)
    data[1] = 255
    data[1, : size // 16, :] = 0
    src = path.with_suffix(".src.tif")
    with rasterio.open(src, "w", driver="GTiff", width=size, height=size, count=2,
                       dtype="uint8", crs="EPSG:3005", alpha="YES",
                       transform=from_origin(1_200_000, 900_000, 5, 5)) as ds:
        ds.write(data)
        ds.colorinterp = [rasterio.enums.ColorInterp.gray, rasterio.enums.ColorInterp.alpha]
    rio_copy(src, path, driver="COG", compress="DEFLATE", overview_resampling=resampling)
    return path


def wire(monkeypatch, published, local):
    paths = {"published": str(published), "local": str(local)}
    monkeypatch.setattr(render, "locate", lambda key, s: paths[s])
    monkeypatch.setattr(render, "published_sha256",
                        lambda key: hashlib.sha256(published.read_bytes()).hexdigest()
                        if published.exists() else "")


def test_identical_files_are_the_same_at_every_level(tmp_path, monkeypatch):
    a = cog(tmp_path / "a.tif", "nearest")
    b = tmp_path / "b.tif"
    b.write_bytes(a.read_bytes())
    wire(monkeypatch, a, b)
    row, panels = render.frame("k", ("published", "local"), 200)
    assert row["bytes_same"] is True and row["grid_same"] is True
    assert row["pixels_differing"] == 0 and row["overview_pixels_differing"] == 0
    assert len(panels) == 3


def test_a_difference_only_in_the_overviews_is_counted(tmp_path, monkeypatch):
    # Same full-resolution pixels, different overviews: what a client draws zoomed out.
    a, b = cog(tmp_path / "a.tif", "nearest"), cog(tmp_path / "b.tif", "average")
    wire(monkeypatch, a, b)
    row, _ = render.frame("k", ("published", "local"), 200)
    assert row["pixels_differing"] == 0
    assert row["overview_pixels_differing"] > 0
    assert row["bytes_same"] is False


def test_a_frame_not_yet_published_is_reported_not_fatal(tmp_path, monkeypatch):
    b = cog(tmp_path / "b.tif", "nearest")
    wire(monkeypatch, tmp_path / "missing.tif", b)
    row, panels = render.frame("k", ("published", "local"), 200)
    assert "published_unreadable" in row and row["bytes_same"] is False
    # The slots never shift: magenta where published would be, local, magenta diff.
    assert len(panels) == 3
    assert is_magenta(panels[0]) and is_magenta(panels[2]) and not is_magenta(panels[1])


def is_magenta(panel):
    return bool((panel == render.MAGENTA[:, None, None]).all())


def test_a_read_that_fails_on_the_second_open_is_reported_not_fatal(tmp_path, monkeypatch):
    a = cog(tmp_path / "a.tif", "nearest")
    b = tmp_path / "b.tif"
    b.write_bytes(a.read_bytes())
    wire(monkeypatch, a, b)
    real = render.read

    def flaky(src, size=None):
        if src == str(a) and size:
            raise OSError("connection reset")
        return real(src, size)
    monkeypatch.setattr(render, "read", flaky)
    row, panels = render.frame("k", ("published", "local"), 200)
    assert row["published_unreadable"] == "connection reset" and row["bytes_same"] is False
    assert "published_shape" not in row and len(panels) == 3


@pytest.mark.parametrize("err", [OSError("timed out"), http.client.IncompleteRead(b"")])
def test_a_failed_hash_fetch_is_not_same(tmp_path, monkeypatch, err):
    a = cog(tmp_path / "a.tif", "nearest")
    b = tmp_path / "b.tif"
    b.write_bytes(a.read_bytes())
    wire(monkeypatch, a, b)

    def fail(key):
        raise err
    monkeypatch.setattr(render, "published_sha256", fail)
    row, _ = render.frame("k", ("published", "local"), 200)
    assert row["bytes_same"] is False and "compare_error" in row


def test_sampling_skips_a_frame_it_cannot_read(tmp_path, monkeypatch):
    good = cog(tmp_path / "good.tif", "nearest", size=64)
    keys = {"1": "missing", "2": "good"}
    monkeypatch.setattr(render, "locate",
                        lambda key, s: str(good) if key == "good" else str(tmp_path / "x.tif"))
    assert render.pick(keys, [], 1, 36, "published") == ["2"]


def test_expect_same_fails_on_any_difference_and_on_nothing_drawn():
    assert render.verdict([{"airp_id": "1", "bytes_same": True}]) == 0
    assert render.verdict([{"airp_id": "1", "bytes_same": True},
                           {"airp_id": "2", "bytes_same": False}]) == 1
    assert render.verdict([{"airp_id": "3", "published_unreadable": "403"}]) == 1
    assert render.verdict([]) == 1
