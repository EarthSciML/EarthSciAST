"""Variable bounds ``lb`` / ``ub`` (esm-spec §6.3.2, esm 2.1.0): round-trip,
the four validity rules, the version gate, and flattening
(esm-libraries-spec §4.7.5, "Bounds follow the renaming")."""

from __future__ import annotations

import copy
import json

import pytest
from conftest import FIXTURES_ROOT, INVALID_DIR, VALID_DIR

from earthsci_ast import flatten, load_document, load_path, to_ascii, validate
from earthsci_ast.serialize import to_json
from earthsci_ast.validation import validate_path, validate_text

_EXPECTED = json.loads((INVALID_DIR / "expected_errors.json").read_text())

_VALID = ["variable_bounds.esm", "variable_bounds_shaped.esm", "variable_bounds_coupled.esm"]


def _authored_bounds(doc: dict) -> dict[str, dict]:
    """Every model variable's ``lb`` / ``ub`` keys as written, by pointer."""
    out: dict[str, dict] = {}

    def walk(pointer: str, model: dict) -> None:
        for name, var in (model.get("variables") or {}).items():
            out[f"{pointer}/variables/{name}"] = {k: var[k] for k in ("lb", "ub") if k in var}
        for name, sub in (model.get("subsystems") or {}).items():
            walk(f"{pointer}/subsystems/{name}", sub)

    for name, model in (doc.get("models") or {}).items():
        walk(f"/models/{name}", model)
    return out


# --- round-trip --------------------------------------------------------------


@pytest.mark.parametrize("fname", _VALID)
def test_round_trip_preserves_bounds_as_authored(fname):
    """A number stays the number written (an int stays an int), a reference
    stays the string written, and an absent bound is not written."""
    raw = json.loads((VALID_DIR / fname).read_text())
    emitted = json.loads(to_json(load_path(VALID_DIR / fname)))
    want = _authored_bounds(raw)
    got = _authored_bounds(emitted)
    assert got == want
    for pointer, bounds in want.items():
        for key, value in bounds.items():
            assert type(got[pointer][key]) is type(value), (pointer, key)
    assert any(want.values())


@pytest.mark.parametrize("fname", _VALID)
def test_valid_fixtures_validate_clean(fname):
    result = validate_path(str(VALID_DIR / fname))
    assert result.is_valid, [(e.code, e.path, e.message) for e in result.structural_errors]


def test_version_compatibility_fixture_loads():
    path = FIXTURES_ROOT / "version_compatibility" / "version_2_1_0_variable_bounds.esm"
    var = load_path(path).models["Decay"].variables["N"]
    assert (var.lb, var.ub) == (0, "N0")


# --- the shared invalid fixtures ---------------------------------------------

_INVALID = [
    "variable_bound_unresolved.esm",
    "variable_bound_shape_mismatch.esm",
    "variable_bound_shape_mismatch_axes.esm",
    "variable_bound_shape_mismatch_nested_reaction.esm",
    "variable_bound_circular_self.esm",
    "variable_bound_circular_observed.esm",
    "variable_bounds_inverted.esm",
]


@pytest.mark.parametrize("fname", _INVALID)
def test_invalid_fixture_matches_expected_errors(fname):
    """Each fixture yields exactly its pinned (path, code, details), and the
    pinned message."""
    expected = _EXPECTED[fname]
    result = validate_path(str(INVALID_DIR / fname))
    assert not result.is_valid
    assert result.schema_errors == []
    got = [(e.path, e.code, e.details, e.message) for e in result.structural_errors]
    want = [
        (e["path"], e["code"], e["details"], e["message"]) for e in expected["structural_errors"]
    ]
    assert got == want


def test_version_too_old_fixture_is_refused_at_load():
    fname = "variable_bounds_version_too_old.esm"
    with pytest.raises(Exception) as excinfo:
        load_path(INVALID_DIR / fname)
    assert excinfo.value.code == _EXPECTED[fname]["resolver_error_code"]
    assert "/models/M/variables/x/lb" in str(excinfo.value)


# --- edge cases on documents built here ----------------------------------------


def _unknown(**kw) -> dict:
    return {"type": "unknown", "units": "1", **kw}


def _param(**kw) -> dict:
    return {"type": "parameter", "units": "1", "default": 1.0, **kw}


def _decay(name: str) -> dict:
    return {"lhs": {"op": "D", "args": [name], "wrt": "t"}, "rhs": {"op": "-", "args": [name]}}


def _doc(models: dict, esm: str = "2.1.0", **extra) -> dict:
    return {"esm": esm, "metadata": {"name": "t", "authors": ["t"]}, "models": models, **extra}


def _errors(doc: dict) -> list[tuple[str, str, dict]]:
    result = validate_text(json.dumps(doc))
    return [(e.code, e.path, e.details) for e in result.structural_errors + result.schema_errors]


def _two_level(sub_x: dict) -> dict:
    """``M`` with a state ``y`` and a subsystem ``S`` whose state ``x`` is
    declared as ``sub_x``; ``N`` is a second model with a parameter ``cap``."""
    return _doc(
        {
            "M": {
                "variables": {"y": _unknown(default=1.0), "ycap": _param()},
                "equations": [_decay("y")],
                "subsystems": {
                    "S": {
                        "variables": {"x": sub_x, "xcap": _param()},
                        "equations": [_decay("x")],
                    }
                },
            },
            "N": {"variables": {"cap": _param()}, "equations": []},
        }
    )


def test_unresolved_bound_in_a_subsystem_pins_the_subsystem_pointer():
    doc = _two_level(_unknown(default=1.0, ub="nope"))
    assert _errors(doc) == [
        (
            "undefined_variable",
            "/models/M/subsystems/S/variables/x/ub",
            {"variable": "nope", "bound": "ub"},
        )
    ]


def test_a_bare_bound_resolves_in_its_own_node_only():
    """``ycap`` is a variable of the parent ``M``, not of ``S``: a bare name
    is the owning node's, so it does not resolve from inside ``S``."""
    doc = _two_level(_unknown(default=1.0, ub="ycap"))
    assert [e[:2] for e in _errors(doc)] == [
        ("undefined_variable", "/models/M/subsystems/S/variables/x/ub")
    ]


@pytest.mark.parametrize(
    "where, ref",
    [
        ("sub", "xcap"),  # bare, own node
        ("sub", "N.cap"),  # a top-level system path
        ("sub", "M.ycap"),  # a top-level path into the parent
        ("top", "S.xcap"),  # relative to the node's own subsystem
        ("top", "M.S.xcap"),  # the same variable by its full path
    ],
)
def test_bound_references_that_resolve(where, ref):
    doc = _two_level(_unknown(default=1.0))
    if where == "sub":
        doc["models"]["M"]["subsystems"]["S"]["variables"]["x"]["ub"] = ref
    else:
        doc["models"]["M"]["variables"]["y"]["ub"] = ref
    assert _errors(doc) == []


def test_a_dotted_bound_into_an_undeclared_variable_is_undefined():
    doc = _two_level(_unknown(default=1.0))
    doc["models"]["M"]["variables"]["y"]["lb"] = "S.missing"
    assert _errors(doc) == [
        ("undefined_variable", "/models/M/variables/y/lb", {"variable": "S.missing", "bound": "lb"})
    ]


def test_a_bound_on_a_reaction_species_reference_resolves():
    doc = _doc(
        {"M": {"variables": {"x": _unknown(default=1.0, ub="R.O3")}, "equations": [_decay("x")]}},
        reaction_systems={
            "R": {
                "species": {"O3": {"units": "1", "default": 1.0}},
                "parameters": {"k": {"units": "1/s", "default": 0.1}},
                "reactions": [
                    {
                        "id": "R1",
                        "substrates": [{"species": "O3", "stoichiometry": 1}],
                        "products": None,
                        "rate": "k",
                    }
                ],
            }
        },
    )
    assert _errors(doc) == []


def _observed_doc(bound: str) -> dict:
    """``x`` and ``z`` are ODE states; observed ``a`` reads ``z`` only and
    observed ``b`` reads ``x``. ``x``'s ub is ``bound``."""
    return _doc(
        {
            "M": {
                "variables": {
                    "x": _unknown(default=1.0, ub=bound),
                    "z": _unknown(default=1.0),
                    "a": _unknown(),
                    "b": _unknown(),
                },
                "equations": [
                    _decay("x"),
                    _decay("z"),
                    {"lhs": "a", "rhs": {"op": "*", "args": [2, "z"]}},
                    {"lhs": "b", "rhs": {"op": "+", "args": ["a", "x"]}},
                ],
            }
        }
    )


def test_a_bound_on_an_observed_of_a_different_state_is_valid():
    assert _errors(_observed_doc("a")) == []


def test_a_bound_on_an_observed_reading_the_bounded_state_is_circular():
    assert _errors(_observed_doc("b")) == [
        (
            "variable_bound_circular",
            "/models/M/variables/x/ub",
            {"variable": "x", "bound": "ub", "reference": "b"},
        )
    ]


def test_the_circular_walk_stops_at_a_state():
    """``x``'s bound is the observed ``a``, which reads the STATE ``z``; ``z``'s
    tendency reads ``x``, but a state's value is not computed from a
    right-hand side, so there is no circularity."""
    doc = _observed_doc("a")
    doc["models"]["M"]["equations"][1] = {
        "lhs": {"op": "D", "args": ["z"], "wrt": "t"},
        "rhs": {"op": "-", "args": ["x"]},
    }
    assert _errors(doc) == []


def test_a_circular_bound_across_models():
    """An observed of another model whose definition reads the bounded
    variable by its scoped name."""
    doc = _doc(
        {
            "M": {
                "variables": {"x": _unknown(default=1.0, ub="N.o")},
                "equations": [_decay("x")],
            },
            "N": {
                "variables": {"o": _unknown()},
                "equations": [{"lhs": "o", "rhs": {"op": "*", "args": [2, "M.x"]}}],
            },
        }
    )
    assert [e[:2] for e in _errors(doc)] == [
        ("variable_bound_circular", "/models/M/variables/x/ub")
    ]


def test_shape_rules():
    """A scalar bound on a shaped variable is legal; a shaped bound of the
    same index sets is legal; a shaped bound of a different order is not."""
    index_sets = {"a": {"kind": "interval", "size": 2}, "b": {"kind": "interval", "size": 2}}

    def doc_with(ref_shape):
        return _doc(
            {
                "M": {
                    "variables": {
                        "u": _param(shape=["a", "b"], ub="cap"),
                        "cap": _param(**({"shape": ref_shape} if ref_shape is not None else {})),
                    },
                    "equations": [],
                }
            },
            index_sets=index_sets,
        )

    assert _errors(doc_with(None)) == []
    assert _errors(doc_with([])) == []
    assert _errors(doc_with(["a", "b"])) == []
    assert [e[:2] for e in _errors(doc_with(["b", "a"]))] == [
        ("variable_bound_shape_mismatch", "/models/M/variables/u/ub")
    ]


def test_inverted_and_equal_numeric_bounds():
    ok = _doc({"M": {"variables": {"p": _param(lb=2, ub=2.0)}, "equations": []}})
    assert _errors(ok) == []
    bad = _doc({"M": {"variables": {"p": _param(lb=2.5, ub=-1)}, "equations": []}})
    assert _errors(bad) == [
        (
            "variable_bounds_inverted",
            "/models/M/variables/p",
            {"variable": "p", "lb": 2.5, "ub": -1},
        )
    ]


def test_validate_reports_a_bound_edited_in_memory():
    """``validate`` checks the parsed tree, so a document changed after load
    is still caught."""
    esm = load_path(VALID_DIR / "variable_bounds.esm")
    esm.models["Salts"].variables["E"].ub = "E"
    errors = [(e.code, e.path) for e in validate(esm).structural_errors]
    assert ("variable_bound_circular", "/models/Salts/variables/E/ub") in errors


# --- version gate ------------------------------------------------------------


def test_the_gate_finds_a_bound_in_a_subsystem():
    doc = _two_level(_unknown(default=1.0, ub="xcap"))
    doc["esm"] = "2.0.0"
    with pytest.raises(Exception) as excinfo:
        load_document(doc)
    assert excinfo.value.code == "variable_bounds_version_too_old"
    assert "/models/M/subsystems/S/variables/x/ub" in str(excinfo.value)


@pytest.mark.parametrize("esm", ["1.3.0", "2.0.0"])
def test_the_gate_refuses_every_earlier_version(esm):
    doc = _doc({"M": {"variables": {"p": _param(lb=0)}, "equations": []}}, esm=esm)
    with pytest.raises(Exception) as excinfo:
        load_document(doc)
    assert excinfo.value.code == "variable_bounds_version_too_old"


def test_an_older_mounted_leaf_is_held_to_its_own_version(tmp_path):
    """A 2.1.0 root does not make a 2.0.0 leaf's bounds legal (esm-spec §4.7)."""
    leaf = _doc({"L": {"variables": {"p": _param(lb=0)}, "equations": []}}, esm="2.0.0")
    (tmp_path / "leaf.esm").write_text(json.dumps(leaf))
    root = _doc({"M": {"variables": {}, "equations": [], "subsystems": {"L": {"ref": "leaf.esm"}}}})
    with pytest.raises(Exception) as excinfo:
        load_document(root, base_path=str(tmp_path))
    assert getattr(excinfo.value, "code", None) == "variable_bounds_version_too_old"


# --- flatten -----------------------------------------------------------------


def _flat_bounds(flat) -> dict[str, tuple]:
    out = {}
    for table in (flat.state_variables, flat.parameters, flat.observed_variables):
        for name, var in table.items():
            out[name] = (
                var.lb if var.lb is None or isinstance(var.lb, (int, float)) else to_ascii(var.lb),
                var.ub if var.ub is None or isinstance(var.ub, (int, float)) else to_ascii(var.ub),
            )
    return out


def test_flatten_rewrites_bounds_with_the_equations_renaming():
    flat = flatten(load_path(VALID_DIR / "variable_bounds_coupled.esm"))
    bounds = _flat_bounds(flat)
    assert bounds["Chem.x"] == ("Chem.x_min", "Met.cap_src")
    assert bounds["Chem.z"] == (0, "Chem.Sub.y")
    assert bounds["Chem.Sub.y"] == (0, "Chem.Sub.y_cap")
    assert bounds["Met.cap_src"] == (0, None)
    # The variable_map target leaves the flattened system with its bounds.
    assert "Chem.x_cap" not in bounds


def test_a_scaled_variable_map_leaves_the_replacement_expression():
    raw = json.loads((VALID_DIR / "variable_bounds_coupled.esm").read_text())
    raw = copy.deepcopy(raw)
    raw["coupling"][0] = {
        "type": "variable_map",
        "from": "Met.cap_src",
        "to": "Chem.x_cap",
        "transform": "conversion_factor",
        "factor": 2.0,
    }
    x = flatten(load_document(raw)).state_variables["Chem.x"]
    assert x.lb == "Chem.x_min"
    assert x.ub.op == "*"
    assert x.ub.args == [2.0, "Met.cap_src"]


def test_a_mounted_leaf_with_bounds_raises_the_emitted_version(tmp_path):
    """A 2.0.0 root mounting a 2.1.0 leaf with bounds has the bounds inlined at
    load, so its emitted form declares 2.1.0 and reads back."""
    leaf = _doc({"L": {"variables": {"p": _param(lb=0, ub="q"), "q": _param()}, "equations": []}})
    (tmp_path / "leaf.esm").write_text(json.dumps(leaf))
    root = _doc(
        {"M": {"variables": {}, "equations": [], "subsystems": {"L": {"ref": "leaf.esm"}}}},
        esm="2.0.0",
    )
    emitted = json.loads(to_json(load_document(root, base_path=str(tmp_path))))
    assert emitted["esm"] == "2.1.0"
    p = load_document(emitted).models["M"].subsystems["L"].variables["p"]
    assert (p.lb, p.ub) == (0, "q")


def test_a_document_without_bounds_keeps_its_version_on_emit():
    doc = _doc({"M": {"variables": {"p": _param()}, "equations": []}}, esm="2.0.0")
    assert json.loads(to_json(load_document(doc)))["esm"] == "2.0.0"
