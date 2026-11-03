"""Which component a top-level ``{ref}`` mount takes from its leaf, and how the
edge reports a leaf it cannot take one from (esm-spec §4.7 "Two mount forms,
one mechanism").

The ``models.<k>`` and ``reaction_systems.<k>`` forms apply the same rule: the
leaf's single component of the form's kind, or the one the edge's selector
(``model`` / ``reaction_system``) names. A leaf with none, a leaf with several
and no selector, an unknown selector and a leaf file that cannot be read are
each ``unresolved_subsystem_ref`` at ``/<block>/<k>``. A failure from inside the
leaf's own resolution is not relabelled as a failure of the edge.
"""

from __future__ import annotations

import json

import pytest

from earthsci_ast import load_path
from earthsci_ast.parse import SubsystemRefError


def _model(var: str) -> dict:
    return {
        "variables": {var: {"type": "unknown", "default": 0.0}},
        "equations": [{"lhs": {"op": "D", "args": [var], "wrt": "t"}, "rhs": 1.0}],
    }


def _reaction_system() -> dict:
    return {
        "species": {
            "A": {"units": "mol/m^3", "default": 1.0},
            "B": {"units": "mol/m^3", "default": 0.0},
        },
        "parameters": {"k": {"units": "1/s", "default": 0.3}},
        "reactions": [
            {
                "id": "R1",
                "substrates": [{"species": "A", "stoichiometry": 1}],
                "products": [{"species": "B", "stoichiometry": 1}],
                "rate": "k",
            }
        ],
    }


def _doc(name: str, **blocks) -> dict:
    return {"esm": "1.0.0", "metadata": {"name": name}, **blocks}


def _write(path, payload) -> str:
    path.write_text(payload if isinstance(payload, str) else json.dumps(payload))
    return str(path)


@pytest.fixture
def two_models(tmp_path):
    _write(tmp_path / "two_models.esm", _doc("two", models={"A": _model("a"), "B": _model("b")}))
    return tmp_path


def _mount_models(tmp_path, edge: dict) -> str:
    return _write(tmp_path / "root.esm", _doc("root", models={"Atm": edge}))


def test_model_selector_picks_the_named_model(two_models):
    doc = load_path(_mount_models(two_models, {"ref": "./two_models.esm", "model": "B"}))
    atm = doc.models["Atm"]
    assert atm.name == "Atm"
    assert set(atm.variables) == {"b"}


def test_single_model_leaf_needs_no_selector(tmp_path):
    _write(tmp_path / "one.esm", _doc("one", models={"Only": _model("x")}))
    doc = load_path(_mount_models(tmp_path, {"ref": "./one.esm"}))
    assert set(doc.models["Atm"].variables) == {"x"}


def _refused(path: str, pointer: str) -> SubsystemRefError:
    with pytest.raises(SubsystemRefError) as info:
        load_path(path)
    assert info.value.code == "unresolved_subsystem_ref", info.value
    assert info.value.path == pointer, info.value
    return info.value


def test_ambiguous_model_leaf_is_refused(two_models):
    exc = _refused(_mount_models(two_models, {"ref": "./two_models.esm"}), "/models/Atm")
    assert "A, B" in str(exc)
    assert "`model` selector" in str(exc)


def test_unknown_model_selector_is_refused(two_models):
    exc = _refused(
        _mount_models(two_models, {"ref": "./two_models.esm", "model": "C"}), "/models/Atm"
    )
    assert "no model 'C'" in str(exc)


def test_leaf_with_no_model_is_refused(tmp_path):
    _write(tmp_path / "rs_only.esm", _doc("rs", reaction_systems={"Chem": _reaction_system()}))
    exc = _refused(_mount_models(tmp_path, {"ref": "./rs_only.esm"}), "/models/Atm")
    assert "no models block" in str(exc)


def test_missing_model_leaf_file_is_refused_at_the_edge(tmp_path):
    _refused(_mount_models(tmp_path, {"ref": "./absent.esm"}), "/models/Atm")


@pytest.mark.parametrize(
    ("block", "selector"), [("models", "model"), ("reaction_systems", "reaction_system")]
)
def test_unparseable_leaf_file_is_refused_at_the_edge(tmp_path, block, selector):
    _write(tmp_path / "broken.esm", "{ not json")
    root = _write(tmp_path / "root.esm", _doc("root", **{block: {"K": {"ref": "./broken.esm"}}}))
    _refused(root, f"/{block}/K")


def test_reaction_system_leaf_schema_error_is_not_an_edge_failure(tmp_path):
    # A leaf that fails schema validation is a problem INSIDE the leaf, not an
    # unresolvable edge: it is not reported as `unresolved_subsystem_ref` at
    # the mount's pointer.
    bad = _reaction_system()
    bad["reactions"] = "not a list"
    _write(tmp_path / "bad_leaf.esm", _doc("bad", reaction_systems={"Chem": bad}))
    root = _write(
        tmp_path / "root.esm", _doc("root", reaction_systems={"Chem": {"ref": "./bad_leaf.esm"}})
    )
    with pytest.raises(SubsystemRefError) as info:
        load_path(root)
    assert "Schema validation failed" in str(info.value)
    assert info.value.code != "unresolved_subsystem_ref"
    assert info.value.path != "/reaction_systems/Chem"


def test_reaction_system_leaf_nested_failure_keeps_its_own_pointer(tmp_path):
    # The leaf is itself an assembly whose own mount is unresolvable: that
    # failure is reported at the leaf's edge, not relabelled at the outer one.
    _write(
        tmp_path / "mid.esm",
        _doc("mid", reaction_systems={"Inner": {"ref": "./absent.esm"}}),
    )
    root = _write(
        tmp_path / "root.esm", _doc("root", reaction_systems={"Outer": {"ref": "./mid.esm"}})
    )
    _refused(root, "/reaction_systems/Inner")
