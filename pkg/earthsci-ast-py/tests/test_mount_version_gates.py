"""A mounted file is held to its OWN declared ``esm`` (esm-spec §4.7): every
file-level version gate the root runs also runs on each ``{ref}`` leaf, so a
newer root cannot make an older leaf's construct legal. (The 1.3.0 gates on
``solver.external`` / ``solver.time_span`` are root-only by §2.2.6/§2.2.7 and
are pinned by the ``solver_external`` / ``solver_time_span`` conformance
manifests.)"""

from __future__ import annotations

import json

import pytest
from conftest import INVALID_DIR, VALID_DIR

from earthsci_ast import load_document, load_path, to_json
from earthsci_ast.serialize import _raise_esm_floors

_EXPECTED = json.loads((INVALID_DIR / "expected_errors.json").read_text())


@pytest.mark.parametrize(
    "fname",
    [
        "version_gate_newer_mounts_older_const_units.esm",
        "version_gate_newer_mounts_older_solver.esm",
    ],
)
def test_a_newer_root_does_not_make_an_older_leaf_legal(fname):
    with pytest.raises(Exception) as excinfo:
        load_path(INVALID_DIR / fname)
    assert getattr(excinfo.value, "code", None) == _EXPECTED[fname]["resolver_error_code"]


def test_a_template_library_is_held_to_its_own_version():
    """A template library is a file held to its own version too (esm-spec §4.7,
    §4.8.5 item 6): a 1.1.0 library whose template body carries a unit-bearing
    const is refused, whatever the importing document declares."""
    fname = "version_gate_library_older_const_units.esm"
    with pytest.raises(Exception) as excinfo:
        load_path(INVALID_DIR / fname)
    assert getattr(excinfo.value, "code", None) == _EXPECTED[fname]["resolver_error_code"]


def test_an_older_root_may_mount_a_newer_leaf():
    load_path(VALID_DIR / "version_gate_older_mounts_newer.esm")


def test_an_older_root_mounting_a_newer_leaf_saves_at_the_leaf_floor():
    """Once the 1.2.0 leaf's unit-bearing const is inlined, the 1.0.0 root
    saves as 1.2.0 (esm-spec §4.7, "Save-time version floors") and reads back."""
    loaded = load_path(VALID_DIR / "version_gate_older_mounts_newer.esm")
    assert loaded.esm == "1.0.0"
    saved = to_json(loaded)
    assert json.loads(saved)["esm"] == "1.2.0"
    load_document(json.loads(saved))


def _floored(esm: str, bound: dict | None = None) -> str:
    variable = {"type": "unknown", "units": "Pa", **(bound or {})}
    doc = {
        "esm": esm,
        "metadata": {"name": "built"},
        "models": {
            "M": {
                "variables": {"x": variable},
                "equations": [
                    {"lhs": "x", "rhs": {"op": "const", "args": [], "value": 1.0, "units": "Pa"}}
                ],
            }
        },
    }
    _raise_esm_floors(doc)
    return doc["esm"]


@pytest.mark.parametrize(
    ("esm", "bound", "want"),
    [
        ("1.0.0", None, "1.2.0"),
        ("1.1.0", None, "1.2.0"),
        ("1.0.0", {"lb": 0.0}, "2.1.0"),
        ("1.2.0", None, "1.2.0"),
        ("2.3.0", {"lb": 0.0}, "2.3.0"),
    ],
)
def test_the_save_floor_takes_the_highest_and_never_lowers(esm, bound, want):
    assert _floored(esm, bound) == want
