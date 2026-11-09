"""esm-spec §9.6.11: an expression template applied with an array bound to a
scalar-role parameter is evaluated elementwise.

The nine single-model cases run as the ``template_array_args`` inline-test
conformance tier. This pins the coupled case (parameters the component declares
scalar, fed grid arrays by ``variable_map``) bit for bit against the
``interp.*`` form under both compilers, the refusals (arrays over unrelated
index sets, an anonymous array argument), and what is not lifted: a template
whose operands its body takes whole, and a shaped read written by hand.
"""

from __future__ import annotations

import json
from pathlib import Path

import numpy as np
import pytest

from earthsci_ast.elementwise_lift import ElementwiseLiftError, lift_elementwise_applications
from earthsci_ast.flatten import flatten
from earthsci_ast.parse import load_string
from earthsci_ast.problem import _rhs_of, esm_problem

ROOT = Path(__file__).resolve().parents[3]
COUPLED = ROOT / "tests" / "conformance" / "template_array_args" / "coupled"


def _rhs(path: Path | dict, compiler: str) -> dict[str, float]:
    prob = esm_problem(path if isinstance(path, dict) else str(path), (0.0, 1.0), compiler=compiler)
    rhs, y0, names = _rhs_of(prob)
    du = np.asarray(rhs(0.0, np.asarray(y0, dtype=float)), dtype=float)
    return dict(zip(names, du.tolist()))


@pytest.mark.parametrize("compiler", ["interpreter", "native"])
def test_coupled_scalar_parameters_fed_grid_arrays_match_the_fn_form(compiler):
    ref = _rhs(COUPLED / "fn.esm", compiler)
    got = _rhs(COUPLED / "template.esm", compiler)
    assert len(ref) == 48
    assert got.keys() == ref.keys()
    for k, v in ref.items():
        assert np.float64(got[k]).tobytes() == np.float64(v).tobytes(), (k, got[k], v)


def test_arrays_over_unrelated_index_sets_are_refused():
    c = lambda v: {"op": "const", "args": [], "value": v}  # noqa: E731
    doc = {
        "esm": "1.2.0",
        "metadata": {"name": "taa_mismatch"},
        "index_sets": {"a": {"kind": "interval", "size": 2}, "b": {"kind": "interval", "size": 3}},
        "models": {
            "M": {
                "expression_template_imports": [
                    {"ref": "esm:std/interp.esm", "only": ["bilinear"]}
                ],
                "variables": {
                    "px": {"type": "parameter", "shape": ["a"], "default": [0.5, 1.5]},
                    "py": {"type": "parameter", "shape": ["b"], "default": [10.0, 15.0, 20.0]},
                    "B": {"type": "unknown"},
                    "s": {"type": "unknown", "default": 0.0},
                },
                "equations": [
                    {
                        "lhs": "B",
                        "rhs": {
                            "op": "apply_expression_template",
                            "args": [],
                            "name": "bilinear",
                            "bindings": {
                                "table": c([[1.0, 2.0], [3.0, 4.0]]),
                                "axis_x": c([0.0, 2.0]),
                                "axis_y": c([10.0, 20.0]),
                                "x": "px",
                                "y": "py",
                                "nx": 2,
                                "ny": 2,
                            },
                        },
                    },
                    {"lhs": {"op": "D", "args": ["s"], "wrt": "t"}, "rhs": 1.0},
                ],
            }
        },
    }
    with pytest.raises(ElementwiseLiftError, match="array_shape_mismatch"):
        esm_problem(json.loads(json.dumps(doc)), (0.0, 1.0), compiler="interpreter")


def _const(v):
    return {"op": "const", "args": [], "value": v}


def _model_doc(variables, equations, templates=None, imports=None):
    model = {"variables": variables, "equations": equations}
    if templates is not None:
        model["expression_templates"] = templates
    if imports is not None:
        model["expression_template_imports"] = imports
    return {
        "esm": "1.2.0",
        "metadata": {"name": "taa_probe"},
        "index_sets": {
            "c": {"kind": "interval", "size": 3},
            "verts": {"kind": "interval", "size": 4},
            "coord": {"kind": "interval", "size": 2},
        },
        "models": {"M": model},
    }


def test_an_anonymous_array_argument_is_refused():
    doc = _model_doc(
        {"y": {"type": "unknown"}, "s": {"type": "unknown", "default": 0.0}},
        [
            {
                "lhs": "y",
                "rhs": {
                    "op": "apply_expression_template",
                    "args": [],
                    "name": "linear",
                    "bindings": {
                        "table": _const([1.0, 2.0, 4.0]),
                        "axis": _const([0.0, 1.0, 2.0]),
                        "x": _const([0.5, 1.5]),
                        "n": 3,
                    },
                },
            },
            {"lhs": {"op": "D", "args": ["s"], "wrt": "t"}, "rhs": 1.0},
        ],
        imports=[{"ref": "esm:std/interp.esm", "only": ["linear"]}],
    )
    with pytest.raises(ElementwiseLiftError, match="array_shape_mismatch: 'M.y'.*anonymous array"):
        esm_problem(doc, (0.0, 1.0), compiler="interpreter")


_SQUARE_A = [[0.0, 0.0], [2.0, 0.0], [2.0, 2.0], [0.0, 2.0]]
_SQUARE_B = [[1.0, 1.0], [3.0, 1.0], [3.0, 3.0], [1.0, 3.0]]


@pytest.mark.parametrize("compiler", ["interpreter", "native"])
def test_a_template_over_geometry_operands_is_not_lifted(compiler):
    # Both rings are array-role (a geometry operator takes them whole), so
    # binding arrays to them is not an elementwise application.
    doc = _model_doc(
        {
            "pa": {"type": "parameter", "shape": ["verts", "coord"], "default": _SQUARE_A},
            "pb": {"type": "parameter", "shape": ["verts", "coord"], "default": _SQUARE_B},
            "area": {"type": "unknown"},
            "s": {"type": "unknown", "default": 0.0},
        },
        [
            {
                "lhs": "area",
                "rhs": {
                    "op": "apply_expression_template",
                    "args": [],
                    "name": "overlap",
                    "bindings": {"a": "pa", "b": "pb"},
                },
            },
            {"lhs": {"op": "D", "args": ["s"], "wrt": "t"}, "rhs": "area"},
        ],
        templates={
            "overlap": {
                "params": ["a", "b"],
                "body": {
                    "op": "polygon_intersection_area",
                    "manifold": "planar",
                    "args": ["a", "b"],
                },
            }
        },
    )
    flat = flatten(load_string(json.dumps(doc)))
    assert lift_elementwise_applications(flat) is flat
    assert _rhs(doc, compiler) == {"M.s": 1.0}


def test_a_shaped_read_written_by_hand_is_not_lifted():
    # The same reduction the `linear` expansion holds, written by hand: no
    # template application, so the lift leaves it as written.
    doc = _model_doc(
        {
            "u": {"type": "parameter", "shape": ["c"], "default": [1.0, 2.0, 3.0]},
            "tot": {"type": "unknown"},
            "s": {"type": "unknown", "default": 0.0},
        },
        [
            {
                "lhs": "tot",
                "rhs": {
                    "op": "faq",
                    "args": [],
                    "output_idx": [],
                    "ranges": {"k": {"from": "c"}},
                    "expr": "u",
                },
            },
            {"lhs": {"op": "D", "args": ["s"], "wrt": "t"}, "rhs": "tot"},
        ],
    )
    flat = flatten(load_string(json.dumps(doc)))
    assert lift_elementwise_applications(flat) is flat
