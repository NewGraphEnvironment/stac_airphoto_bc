"""stacs.toml is this catalogue's declaration to stacs (#42), and a second copy of
values 05_stac_register.py already defines.

Each value is pinned to its module here, so a collection id or bucket changed in one
place and not the other fails rather than registering against the wrong target.

The audit tests run the installed `stacs` CLI, in process, against items shaped like
05_stac_register.py's, so they prove the config is wired, not just present: drop
`require` from stacs.toml and the missing-thumbnail test goes red.

Run:
    conda run -n stac-airphoto-bc pytest tests/ -q
"""

import importlib.metadata
import importlib.util
import json
import re
from pathlib import Path

import pytest

# A hard import, not importorskip: an environment built without stacs must fail
# here, not skip the only tests that pin the catalogue's rules.
import stacs
from stacs.cli import ConfigError, main as stacs_main, read_config

ROOT = Path(__file__).resolve().parents[1]
CONFIG = ROOT / "stacs.toml"
STACS_VERSION = "0.1.1"

_spec = importlib.util.spec_from_file_location(
    "stac_register", ROOT / "scripts" / "05_stac_register.py")
stac_register = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(stac_register)


@pytest.fixture(scope="module")
def cfg():
    # read_config refuses unknown tables and keys, so a typo is an error here rather
    # than a setting stacs silently ignores.
    return read_config(str(CONFIG))


# =============================================================================
# The toml agrees with the module, and the install with the pin
# =============================================================================

def test_the_pinned_stacs_is_the_one_installed():
    """From the tag, not merely at its version: `__version__` is pyproject's, so an
    install from a later commit on main reads the same. direct_url.json records the
    revision pip was asked for."""
    assert stacs.__version__ == STACS_VERSION
    direct = json.loads(importlib.metadata.distribution("stacs").read_text("direct_url.json"))
    assert direct["vcs_info"]["requested_revision"] == f"v{STACS_VERSION}"


def test_every_install_path_pins_the_same_tag():
    """environment.yml and the conda recipe in scripts/README.md each install stacs; a
    bump in one only would build one version on one machine and another elsewhere.
    Every pin in each file, whole: a substring test would pass `v0.1.10`."""
    pin = re.compile(r"stacs@v([0-9][0-9A-Za-z.\-]*[0-9A-Za-z])")
    for rel in ("environment.yml", "scripts/README.md"):
        assert pin.findall((ROOT / rel).read_text()) == [STACS_VERSION], \
            f"{rel} does not pin v{STACS_VERSION}"


def test_collection_id_is_the_modules(cfg):
    assert cfg["catalogue"]["collection_id"] == stac_register.COLLECTION_ID


def test_bucket_url_is_the_modules(cfg):
    assert cfg["catalogue"]["bucket_url"] == stac_register.S3_BASE


def test_required_asset_is_the_modules(cfg):
    assert cfg["assets"]["require"] == stac_register.ASSET_THUMBNAIL


def test_the_password_is_named_never_given(cfg, tmp_path):
    """The fence is stacs' refusal of unknown keys: a `password` line is an error,
    not a setting silently ignored. Proven on a copy of this file."""
    assert cfg["transport"]["password_env"] == "POSTGRES_PASSWORD"
    leaky = tmp_path / "stacs.toml"
    leaky.write_text(CONFIG.read_text().replace(
        "[transport]\n", "[transport]\npassword = \"x\"\n", 1))
    # The refusal itself, not the bare word: every ConfigError carries the file path,
    # and pytest names tmp_path after this test, so "password" alone always matches.
    with pytest.raises(ConfigError, match=r"unknown key\(s\) in \[transport\]: password$"):
        read_config(str(leaky))


# =============================================================================
# The rules as stacs applies them, over items shaped like ours
# =============================================================================

def _item(item_id):
    """The shape 05_stac_register.py writes, reduced to what the audit reads."""
    return {
        "type": "Feature", "stac_version": "1.1.0", "id": item_id,
        "collection": stac_register.COLLECTION_ID,
        "geometry": {"type": "Polygon", "coordinates": [[[0, 0]]]},
        "bbox": [0, 0, 1, 1],
        "properties": {"datetime": "1968-07-15T00:00:00Z"},
        "assets": {
            stac_register.ASSET_THUMBNAIL: {
                "href": f"{stac_register.S3_BASE}/thumbs/1968/{item_id}_thumb.tif",
                "roles": ["data", "thumbnail"],
            },
            "flight_log": {"href": "https://example.invalid/log.jpg", "roles": ["metadata"]},
        },
        "links": [],
    }


def _audit(tmp_path, capsys, items, *extra):
    """`stacs audit --config stacs.toml`, in process: the CLI's own entry point,
    without depending on where the console script was installed."""
    d = tmp_path / "items"
    d.mkdir()
    for it in items:
        (d / f"{it['id']}.json").write_text(json.dumps(it))
    capsys.readouterr()
    rc = stacs_main(["audit", "--config", str(CONFIG), "--dir", str(d), *extra])
    return rc, capsys.readouterr().err


def test_audit_passes_items_as_we_build_them(tmp_path, capsys):
    rc, err = _audit(tmp_path, capsys, [_item(f"10{i}") for i in range(3)], "--expect", "3")
    assert rc == 0, err
    assert f"require={stac_register.ASSET_THUMBNAIL}" in err


def test_audit_catches_one_item_without_a_thumbnail(tmp_path, capsys):
    """The bad item sits in the MIDDLE of the order stacs reads (sorted names), so an
    audit that checked only the first or the last item read still fails here."""
    bare = _item("m_bare")
    del bare["assets"][stac_register.ASSET_THUMBNAIL]
    rc, err = _audit(tmp_path, capsys, [_item("a_good"), bare, _item("z_good")])
    assert rc == 1
    # A count, not just a category: "1 item(s)" says the good ones were not flagged.
    assert f"1 item(s) lack asset '{stac_register.ASSET_THUMBNAIL}'" in err
    assert "m_bare" in err
    assert "name another collection" not in err


def test_audit_catches_one_item_in_another_collection(tmp_path, capsys):
    stray = _item("m_stray")
    stray["collection"] = "stac-elevation-bc"
    rc, err = _audit(tmp_path, capsys, [_item("a_good"), stray, _item("z_good")])
    assert rc == 1
    assert "1 item(s) name another collection" in err
    assert "m_stray" in err


def test_a_flag_cannot_loosen_the_declared_asset_rule(tmp_path, capsys):
    """Naming another collection id on the command line does not drop `require`."""
    bare = _item("bare")
    bare["collection"] = "elsewhere"
    del bare["assets"][stac_register.ASSET_THUMBNAIL]
    rc, err = _audit(tmp_path, capsys, [bare], "--collection-id", "elsewhere")
    assert rc == 1
    assert f"lack asset '{stac_register.ASSET_THUMBNAIL}'" in err
