"""Tests for metaparameter-EXPRESSION binding values at import / subsystem
edges (esm-spec §9.7.6).

Before this feature both ``TemplateImport.bindings`` and ``SubsystemRef.bindings``
accepted only integer literals, so a child metaparameter could be unified with a
parent one by *rename* (name→name) but never *derived* as an arithmetic
combination (``NTGT = NX*NY``). This relaxes the binding VALUE to a metaparameter
expression (integer literal, name, or ``{op: +|-|*|/, args}``) whose free names
resolve in the importing document's metaparameter scope:

* **import edge** — the value is carried symbolically into the child and folds
  when the importing document closes (the importer's names are not yet closed at
  edge time, innermost-first);
* **subsystem / model edge** — the referenced document is resolved to concrete
  integers at the mount, so the value folds immediately against the mounting
  document's already-closed metaparameter environment.

This is the Python reference the other four bindings mirror.
"""

from __future__ import annotations

import json
import os

import pytest

from earthsci_ast.parse import load
from earthsci_ast.template_imports import (
    ExpressionTemplateError,
    eval_meta_expr,
    require_meta_expr,
    resolve_template_machinery,
)


def _write(dirpath, name, doc):
    path = os.path.join(dirpath, name)
    with open(path, "w") as fh:
        json.dump(doc, fh)
    return path


def _err(fn):
    try:
        fn()
        return None
    except ExpressionTemplateError as e:
        return e.code


# --------------------------------------------------------------------------
# 1. The folding / validation helpers
# --------------------------------------------------------------------------


def test_eval_meta_expr_folds_product():
    assert eval_meta_expr({"op": "*", "args": ["NX", "NY"]}, {"NX": 18, "NY": 20}, "t") == 360


def test_eval_meta_expr_name_and_literal():
    assert eval_meta_expr("NX", {"NX": 7}, "t") == 7
    assert eval_meta_expr(5, {}, "t") == 5


def test_eval_meta_expr_nested_arithmetic():
    # (NX + 2) * NY  with NX=4, NY=3  ->  18
    expr = {"op": "*", "args": [{"op": "+", "args": ["NX", 2]}, "NY"]}
    assert eval_meta_expr(expr, {"NX": 4, "NY": 3}, "t") == 18


def test_require_meta_expr_returns_unfolded():
    expr = {"op": "*", "args": ["NX", "NY"]}
    assert require_meta_expr(expr, "t") == expr  # unchanged, unfolded


@pytest.mark.parametrize(
    "expr, env, code",
    [
        # Bad op is caught structurally at the edge, even with a symbolic arg.
        ({"op": "%", "args": ["NX", 2]}, {}, "metaparameter_type_error"),
        ({"op": "*", "args": []}, {}, "metaparameter_type_error"),
        (1.5, {}, "metaparameter_type_error"),
        # Unknown free name is caught at fold time.
        ({"op": "*", "args": ["NZ", "NY"]}, {"NX": 18, "NY": 20}, "template_import_unknown_name"),
        # Inexact division is rejected.
        ({"op": "/", "args": ["NX", 7]}, {"NX": 18}, "metaparameter_type_error"),
    ],
)
def test_helper_diagnostics(expr, env, code):
    assert _err(lambda: (require_meta_expr(expr, "t"), eval_meta_expr(expr, env, "t"))) == code


# --------------------------------------------------------------------------
# 2. Import edge: GX = NX*NY carried symbolically, folds at the doc close
# --------------------------------------------------------------------------


def _lib_grid():
    return {
        "esm": "0.8.0",
        "metadata": {"name": "lib_grid"},
        "metaparameters": {"GX": {"type": "integer", "default": 2}},
        "index_sets": {"cells": {"kind": "interval", "size": "GX"}},
        "expression_templates": {
            "one": {"params": [], "body": {"op": "const", "value": 1, "args": []}}
        },
    }


def _model_importing(binding):
    return {
        "esm": "0.8.0",
        "metadata": {"name": "model_import"},
        "metaparameters": {
            "NX": {"type": "integer", "default": 3},
            "NY": {"type": "integer", "default": 4},
        },
        "models": {
            "M": {
                "expression_template_imports": [
                    {"ref": "./lib_grid.esm", "bindings": {"GX": binding}}
                ],
                "variables": {"a": {"type": "parameter", "shape": ["cells"], "default": 0.0}},
                "equations": [],
            }
        },
    }


def test_import_edge_product_binding_folds_at_close(tmp_path):
    d = str(tmp_path)
    _write(d, "lib_grid.esm", _lib_grid())
    root = _model_importing({"op": "*", "args": ["NX", "NY"]})
    # explicit API bindings
    out = resolve_template_machinery(root, d, metaparameters={"NX": 3, "NY": 4})
    assert out["index_sets"]["cells"]["size"] == 12
    # via metaparameter defaults (3 * 4)
    out2 = resolve_template_machinery(_model_importing({"op": "*", "args": ["NX", "NY"]}), d)
    assert out2["index_sets"]["cells"]["size"] == 12


# --------------------------------------------------------------------------
# 3. Subsystem / model edge: NTGT = NX*NY folds at the mount
# --------------------------------------------------------------------------


def _child_regrid():
    return {
        "esm": "0.8.0",
        "metadata": {"name": "child_regrid"},
        "metaparameters": {
            "NX": {"type": "integer", "default": 2},
            "NY": {"type": "integer", "default": 2},
            "NTGT": {"type": "integer", "default": 4},
        },
        "index_sets": {
            "tgt_cells": {"kind": "interval", "size": "NTGT"},
            "gx": {"kind": "interval", "size": "NX"},
            "gy": {"kind": "interval", "size": "NY"},
        },
        "models": {
            "Regrid": {
                "variables": {
                    "field": {"type": "parameter", "shape": ["tgt_cells"], "default": 0.0},
                    "grid": {"type": "parameter", "shape": ["gx", "gy"], "default": 0.0},
                },
                "equations": [],
            }
        },
    }


def _parent_mount(bindings):
    return {
        "esm": "0.8.0",
        "metadata": {"name": "parent_mount"},
        "metaparameters": {
            "NX": {"type": "integer", "default": 18},
            "NY": {"type": "integer", "default": 20},
        },
        "models": {"Regrid": {"ref": "./child_regrid.esm", "bindings": bindings}},
    }


def _sizes(esm):
    return {n: (v.get("size") if isinstance(v, dict) else v) for n, v in esm.index_sets.items()}


def test_mount_edge_product_binding_folds_to_concrete(tmp_path):
    d = str(tmp_path)
    _write(d, "child_regrid.esm", _child_regrid())
    path = _write(
        d,
        "parent_mount.esm",
        _parent_mount({"NX": "NX", "NY": "NY", "NTGT": {"op": "*", "args": ["NX", "NY"]}}),
    )
    esm = load(path, metaparameters={"NX": 18, "NY": 20})
    sizes = _sizes(esm)
    assert sizes["tgt_cells"] == 360  # NX*NY, derived — not a hand-supplied literal
    assert sizes["gx"] == 18
    assert sizes["gy"] == 20


def test_mount_edge_folds_against_parent_defaults(tmp_path):
    d = str(tmp_path)
    _write(d, "child_regrid.esm", _child_regrid())
    path = _write(
        d,
        "parent_mount.esm",
        _parent_mount({"NX": "NX", "NY": "NY", "NTGT": {"op": "*", "args": ["NX", "NY"]}}),
    )
    esm = load(path)  # no API bindings -> parent defaults NX=18, NY=20
    assert _sizes(esm)["tgt_cells"] == 360


def test_mount_edge_plain_integer_bindings_regression(tmp_path):
    d = str(tmp_path)
    _write(d, "child_regrid.esm", _child_regrid())
    path = _write(d, "parent_plain.esm", _parent_mount({"NX": 5, "NY": 6, "NTGT": 30}))
    esm = load(path)
    sizes = _sizes(esm)
    assert sizes["tgt_cells"] == 30 and sizes["gx"] == 5 and sizes["gy"] == 6


def test_mount_edge_unknown_parent_name_is_loud(tmp_path):
    d = str(tmp_path)
    _write(d, "child_regrid.esm", _child_regrid())
    path = _write(
        d,
        "parent_bad.esm",
        _parent_mount({"NX": "NX", "NY": "NX", "NTGT": {"op": "*", "args": ["NX", "NZZ"]}}),
    )
    assert _err(lambda: load(path, metaparameters={"NX": 18})) == "template_import_unknown_name"
