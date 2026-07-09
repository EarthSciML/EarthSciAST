"""Coupling-library files + ``coupling_import`` role binding (esm-spec §10.9–§10.11).

Python counterpart of ``pkg/earthsci-ast-ts/src/coupling-imports.test.ts``:
detection, expansion, import-vs-inline flatten equivalence, multiple
instantiation, the §4.2 substitution surface, and each §10.11 diagnostic code.
"""

import json
import os

import pytest

from earthsci_ast import flatten, is_coupling_library_doc, load
from earthsci_ast.coupling_imports import (
    _rewrite_entry_in_place,
    _rewrite_scoped_ref,
    expand_coupling_imports,
)
from earthsci_ast.esm_types import CouplingImport, VariableMapCoupling
from earthsci_ast.lower_expression_templates import ExpressionTemplateError


# A coupling-library file: roles + role-scoped edges, no models/loaders.
LIB = {
    "esm": "0.8.0",
    "metadata": {"name": "RothermelFuelCoupling"},
    "coupling_roles": {
        "Fuel": {"description": "fuel-property source"},
        "Spread": {"description": "Rothermel spread model"},
    },
    "coupling": [
        {"type": "variable_map", "from": "Fuel.sigma", "to": "Spread.sigma", "transform": "param_to_var"},
        {"type": "variable_map", "from": "Fuel.w_0", "to": "Spread.w0", "transform": "param_to_var"},
    ],
}


def _assembly(coupling):
    """An assembly mounting the two components the library wires."""
    return load(
        {
            "esm": "0.8.0",
            "metadata": {"name": "wildfire"},
            "models": {
                "FuelModelLookup": {
                    "variables": {
                        "sigma": {"type": "parameter", "units": "1/m", "default": 1},
                        "w_0": {"type": "parameter", "units": "kg/m^2", "default": 1},
                    },
                    "equations": [],
                },
                "RothermelFireSpread": {
                    "variables": {
                        "sigma": {"type": "parameter", "units": "1/m", "default": 0},
                        "w0": {"type": "parameter", "units": "kg/m^2", "default": 0},
                    },
                    "equations": [],
                },
            },
            "coupling": coupling,
        }
    )


def _load_ref(ref, base_path):
    return LIB


def _err_code(fn):
    try:
        fn()
        return "NO_ERROR"
    except ExpressionTemplateError as e:
        return e.code
    except Exception:  # noqa: BLE001
        return "NON_CODE_ERROR"


def _import_entry(bind, ref="lib.esm"):
    return [{"type": "coupling_import", "ref": ref, "bind": bind}]


# ---------------------------------------------------------------------------
# is_coupling_library_doc
# ---------------------------------------------------------------------------


def test_is_coupling_library_doc_identifies_by_coupling_roles():
    assert is_coupling_library_doc(LIB) is True
    assert is_coupling_library_doc({"esm": "0.8.0", "models": {}}) is False
    assert is_coupling_library_doc(None) is False


# ---------------------------------------------------------------------------
# expand_coupling_imports
# ---------------------------------------------------------------------------


def test_expand_substitutes_roles_into_library_edges():
    f = _assembly(
        _import_entry({"Fuel": "FuelModelLookup", "Spread": "RothermelFireSpread"})
    )
    expanded = expand_coupling_imports(f, load_ref=_load_ref)
    assert all(isinstance(e, VariableMapCoupling) for e in expanded)
    assert [(e.from_var, e.to_var, e.transform) for e in expanded] == [
        ("FuelModelLookup.sigma", "RothermelFireSpread.sigma", "param_to_var"),
        ("FuelModelLookup.w_0", "RothermelFireSpread.w0", "param_to_var"),
    ]


def test_expand_leaves_file_without_import_untouched():
    coupling = [
        {"type": "variable_map", "from": "FuelModelLookup.sigma", "to": "RothermelFireSpread.sigma", "transform": "param_to_var"}
    ]
    f = _assembly(coupling)
    out = expand_coupling_imports(f)  # no options needed, never touches disk
    assert out == list(f.coupling)
    assert all(not isinstance(e, CouplingImport) for e in out)


def test_expand_supports_multiple_instantiation():
    f = _assembly(
        [
            {"type": "coupling_import", "ref": "lib.esm", "bind": {"Fuel": "FuelModelLookup", "Spread": "RothermelFireSpread"}},
            {"type": "coupling_import", "ref": "lib.esm", "bind": {"Fuel": "RothermelFireSpread", "Spread": "FuelModelLookup"}},
        ]
    )
    expanded = expand_coupling_imports(f, load_ref=_load_ref)
    assert len(expanded) == 4
    assert (expanded[2].from_var, expanded[2].to_var) == (
        "RothermelFireSpread.sigma",
        "FuelModelLookup.sigma",
    )


# ---------------------------------------------------------------------------
# The §4.2 occurrence surface (operator_compose + event)
# ---------------------------------------------------------------------------


def test_rewrite_surface_operator_compose():
    edge = {
        "type": "operator_compose",
        "systems": ["A", "B"],
        "translate": {"A.u": "B.v", "A.w": {"var": "B.z", "factor": 2}},
    }
    bind = {"A": "Adv", "B": "React"}
    _rewrite_entry_in_place(edge, lambda r: _rewrite_scoped_ref(r, bind), lambda r: _rewrite_scoped_ref(r, bind))
    assert edge["systems"] == ["Adv", "React"]
    assert edge["translate"] == {"Adv.u": "React.v", "Adv.w": {"var": "React.z", "factor": 2}}


def test_rewrite_surface_event_full():
    edge = {
        "type": "event",
        "conditions": [{"op": ">", "args": ["Sensor.temp", 500]}],
        "affects": [{"lhs": "Fire.state", "rhs": {"op": "+", "args": ["Fire.state", 1]}}],
        "affect_neg": [{"lhs": "Fire.state", "rhs": "Sensor.temp"}],
        "trigger": {"type": "condition", "expression": {"op": "<", "args": ["Sensor.temp", "t"]}},
        "functional_affect": {
            "read_vars": ["Sensor.temp"],
            "read_params": ["Fire.rate"],
            "modified_params": ["Fire.rate"],
        },
        "discrete_parameters": ["Fire.rate"],
    }
    bind = {"Sensor": "TempProbe", "Fire": "Burn"}
    rw = lambda r: _rewrite_scoped_ref(r, bind)
    _rewrite_entry_in_place(edge, rw, rw)
    assert edge["conditions"][0]["args"][0] == "TempProbe.temp"
    assert edge["affects"][0]["lhs"] == "Burn.state"
    assert edge["affects"][0]["rhs"]["args"][0] == "Burn.state"
    assert edge["affect_neg"][0]["lhs"] == "Burn.state"
    assert edge["affect_neg"][0]["rhs"] == "TempProbe.temp"
    # bare "t" (no dot) is not a role and is left untouched
    assert edge["trigger"]["expression"]["args"] == ["TempProbe.temp", "t"]
    assert edge["functional_affect"]["read_vars"] == ["TempProbe.temp"]
    assert edge["functional_affect"]["read_params"] == ["Burn.rate"]
    assert edge["functional_affect"]["modified_params"] == ["Burn.rate"]
    assert edge["discrete_parameters"] == ["Burn.rate"]


def test_rewrite_surface_apply_expression_template_binding_values():
    # apply_expression_template `bindings` VALUES are free-variable targets.
    edge = {
        "type": "variable_map",
        "from": "Fuel.sigma",
        "to": "Spread.sigma",
        "transform": {
            "op": "apply_expression_template",
            "name": "scale",
            "args": [],
            "bindings": {"x": "Fuel.sigma", "y": 3},
        },
    }
    bind = {"Fuel": "FML", "Spread": "RFS"}
    rw = lambda r: _rewrite_scoped_ref(r, bind)
    _rewrite_entry_in_place(edge, rw, rw)
    assert edge["from"] == "FML.sigma"
    assert edge["to"] == "RFS.sigma"
    assert edge["transform"]["bindings"] == {"x": "FML.sigma", "y": 3}


# ---------------------------------------------------------------------------
# flatten equivalence (esm-spec §10.10.3)
# ---------------------------------------------------------------------------


def test_import_and_inline_flatten_identically():
    imported = flatten(
        _assembly(_import_entry({"Fuel": "FuelModelLookup", "Spread": "RothermelFireSpread"})),
        load_ref=_load_ref,
    )
    inline = flatten(
        _assembly(
            [
                {"type": "variable_map", "from": "FuelModelLookup.sigma", "to": "RothermelFireSpread.sigma", "transform": "param_to_var"},
                {"type": "variable_map", "from": "FuelModelLookup.w_0", "to": "RothermelFireSpread.w0", "transform": "param_to_var"},
            ]
        )
    )
    assert imported == inline


# ---------------------------------------------------------------------------
# Diagnostics (esm-spec §10.11)
# ---------------------------------------------------------------------------


def test_diag_role_unbound():
    assert (
        _err_code(
            lambda: expand_coupling_imports(
                _assembly(_import_entry({"Fuel": "FuelModelLookup"})), load_ref=_load_ref
            )
        )
        == "coupling_import_role_unbound"
    )


def test_diag_unknown_role():
    assert (
        _err_code(
            lambda: expand_coupling_imports(
                _assembly(
                    _import_entry(
                        {"Fuel": "FuelModelLookup", "Spread": "RothermelFireSpread", "Ghost": "FuelModelLookup"}
                    )
                ),
                load_ref=_load_ref,
            )
        )
        == "coupling_import_unknown_role"
    )


def test_diag_bind_not_a_component():
    assert (
        _err_code(
            lambda: expand_coupling_imports(
                _assembly(_import_entry({"Fuel": "FuelModelLookup", "Spread": "DoesNotExist"})),
                load_ref=_load_ref,
            )
        )
        == "coupling_import_bind_not_a_component"
    )


def test_diag_not_library():
    assert (
        _err_code(
            lambda: expand_coupling_imports(
                _assembly(_import_entry({"Fuel": "FuelModelLookup", "Spread": "RothermelFireSpread"})),
                load_ref=lambda r, b: {"esm": "0.8.0", "metadata": {"name": "x"}, "models": {}},
            )
        )
        == "coupling_import_not_library"
    )


def test_diag_illegal_payload_declares_models():
    assert (
        _err_code(
            lambda: expand_coupling_imports(
                _assembly(_import_entry({"Fuel": "FuelModelLookup", "Spread": "RothermelFireSpread"})),
                load_ref=lambda r, b: {**LIB, "models": {}},
            )
        )
        == "coupling_library_illegal_payload"
    )


def test_diag_role_unused():
    assert (
        _err_code(
            lambda: expand_coupling_imports(
                _assembly(
                    _import_entry(
                        {"Fuel": "FuelModelLookup", "Spread": "RothermelFireSpread", "Extra": "FuelModelLookup"}
                    )
                ),
                load_ref=lambda r, b: {**LIB, "coupling_roles": {**LIB["coupling_roles"], "Extra": {}}},
            )
        )
        == "coupling_role_unused"
    )


def test_diag_edge_unknown_role():
    assert (
        _err_code(
            lambda: expand_coupling_imports(
                _assembly(_import_entry({"Fuel": "FuelModelLookup", "Spread": "RothermelFireSpread"})),
                load_ref=lambda r, b: {
                    **LIB,
                    "coupling": [{"type": "variable_map", "from": "Ghost.sigma", "to": "Spread.sigma", "transform": "param_to_var"}],
                },
            )
        )
        == "coupling_edge_unknown_role"
    )


def test_diag_nested_import():
    assert (
        _err_code(
            lambda: expand_coupling_imports(
                _assembly(_import_entry({"Fuel": "FuelModelLookup", "Spread": "RothermelFireSpread"})),
                load_ref=lambda r, b: {
                    **LIB,
                    "coupling": LIB["coupling"] + [{"type": "coupling_import", "ref": "other.esm", "bind": {}}],
                },
            )
        )
        == "coupling_library_nested_import"
    )


def test_diag_unresolved_missing_file():
    # The default disk loader reports a missing ref as coupling_import_unresolved.
    f = _assembly(_import_entry({"Fuel": "FuelModelLookup", "Spread": "RothermelFireSpread"}, ref="nope.esm"))
    assert (
        _err_code(lambda: expand_coupling_imports(f, base_path="/nonexistent-dir"))
        == "coupling_import_unresolved"
    )


def test_diag_unresolved_loader_raises():
    def boom(ref, base):
        raise RuntimeError("kaboom")

    f = _assembly(_import_entry({"Fuel": "FuelModelLookup", "Spread": "RothermelFireSpread"}))
    assert _err_code(lambda: expand_coupling_imports(f, load_ref=boom)) == "coupling_import_unresolved"


# ---------------------------------------------------------------------------
# Cross-mechanism gates (loaded from disk via load())
# ---------------------------------------------------------------------------


def _write(dir_, name, doc):
    path = os.path.join(dir_, name)
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(doc, fh)
    return path


# A parameter-only model passes structural validation (no state var needs an
# equation), so ref/import resolution — where the gates live — is reached.
def _param_model(**extra):
    return {"variables": {"x": {"type": "parameter", "default": 0}}, "equations": [], **extra}


def test_subsystem_ref_to_coupling_library_is_rejected(tmp_path):
    _write(str(tmp_path), "couplib.esm", LIB)
    assembly = {
        "esm": "0.8.0",
        "metadata": {"name": "a"},
        "models": {"M": _param_model(subsystems={"Sub": {"ref": "couplib.esm"}})},
    }
    path = _write(str(tmp_path), "assembly.esm", assembly)
    assert _err_code(lambda: load(path)) == "subsystem_ref_is_coupling_library"


def test_template_import_of_coupling_library_is_rejected(tmp_path):
    _write(str(tmp_path), "couplib.esm", LIB)
    # A component-level expression_template_imports edge is resolved at load; the
    # gate fires when its target turns out to be a coupling-library file.
    assembly = {
        "esm": "0.8.0",
        "metadata": {"name": "a"},
        "models": {"M": _param_model(expression_template_imports=[{"ref": "couplib.esm"}])},
    }
    path = _write(str(tmp_path), "assembly.esm", assembly)
    assert _err_code(lambda: load(path)) == "template_import_is_coupling_library"
