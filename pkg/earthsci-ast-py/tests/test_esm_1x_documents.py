"""A 1.x document that uses no removed construct loads at esm 2.0.0, on its own
and as a mounted leaf; its 1.x version gates stay live; the major version alone
never refuses it (user ruling, closed-AST phase 5)."""

from __future__ import annotations

import json

import pytest

from earthsci_ast import SCHEMA_VERSION, load_path
from earthsci_ast.errors import ParseError
from earthsci_ast.parse import (
    _CURRENT_VERSION,
    UnsupportedVersionError,
    _check_version_compatibility,
)


def _model(esm: str, rhs) -> dict:
    return {
        "esm": esm,
        "metadata": {"name": f"doc_{esm}"},
        "models": {
            "Leaf": {
                "variables": {
                    "x": {"type": "unknown", "default": 1.0, "units": "1"},
                    "k": {"type": "parameter", "default": 0.5, "units": "1/s"},
                },
                "equations": [{"lhs": {"op": "D", "args": ["x"], "wrt": "t"}, "rhs": rhs}],
            }
        },
    }


_DECAY = {"op": "*", "args": [{"op": "-", "args": ["k"]}, "x"]}


def _write(tmp_path, doc, name):
    path = tmp_path / name
    path.write_text(json.dumps(doc), encoding="utf-8")
    return path


@pytest.mark.parametrize("esm", ["1.0.0", "1.1.0", "1.3.0"])
def test_a_1x_document_without_removed_ops_loads(tmp_path, esm):
    f = load_path(str(_write(tmp_path, _model(esm, _DECAY), "leaf.esm")))
    assert f.esm == esm
    assert "Leaf" in f.models


def test_a_1x_leaf_mounts_under_a_current_root(tmp_path):
    _write(tmp_path, _model("1.1.0", _DECAY), "leaf.esm")
    root = {
        "esm": SCHEMA_VERSION,
        "metadata": {"name": "root"},
        "models": {
            "Root": {
                "variables": {"y": {"type": "unknown", "default": 0.0, "units": "1"}},
                "equations": [{"lhs": {"op": "D", "args": ["y"], "wrt": "t"}, "rhs": 0.0}],
                "subsystems": {"Leaf": {"ref": "leaf.esm"}},
            }
        },
    }
    f = load_path(str(_write(tmp_path, root, "root.esm")))
    assert "Leaf" in f.models["Root"].subsystems


def test_a_1x_leaf_with_a_removed_op_is_still_removed_op(tmp_path):
    _write(
        tmp_path, _model("1.3.0", {"op": "fn", "name": "datetime.year", "args": ["t"]}), "leaf.esm"
    )
    root = _model(SCHEMA_VERSION, _DECAY)
    root["models"]["Leaf"]["subsystems"] = {"Inner": {"ref": "leaf.esm"}}
    with pytest.raises(ParseError, match="removed_op"):
        load_path(str(_write(tmp_path, root, "root.esm")))


def test_a_1x_version_gate_still_fires(tmp_path):
    # `faq` arrives at esm 1.1.0.
    faq = {
        "op": "faq",
        "args": [],
        "output_idx": [],
        "ranges": {"i": [1, 2]},
        "expr": "x",
    }
    with pytest.raises(ParseError, match="faq_version_too_old"):
        load_path(str(_write(tmp_path, _model("1.0.0", faq), "old.esm")))


def test_a_1x_const_units_gate_still_fires(tmp_path):
    # A `const` carrying `units` arrives at esm 1.2.0.
    rhs = {"op": "const", "args": [], "value": 0.5, "units": "1/s"}
    with pytest.raises(Exception) as excinfo:
        load_path(str(_write(tmp_path, _model("1.1.0", rhs), "old.esm")))
    assert getattr(excinfo.value, "code", None) == "const_units_version_too_old"


@pytest.mark.parametrize("major", [1, _CURRENT_VERSION[0]])
def test_major_1_and_the_current_major_are_accepted(major):
    _check_version_compatibility(f"{major}.0.0")


@pytest.mark.parametrize("major", [0, _CURRENT_VERSION[0] + 1, 12])
def test_other_majors_are_refused(major):
    with pytest.raises(UnsupportedVersionError, match=f"Unsupported major version {major}"):
        _check_version_compatibility(f"{major}.0.0")
