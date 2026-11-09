"""esm-spec §9.6.11: an expression template applied with an array bound to a
scalar-role parameter is evaluated elementwise.

The nine single-model cases run as the ``template_array_args`` inline-test
conformance tier. This pins the coupled case (parameters the component declares
scalar, fed grid arrays by ``variable_map``) bit for bit against the
``interp.*`` form under both compilers, and the refusal of arrays over unrelated
index sets.
"""

from __future__ import annotations

import json
from pathlib import Path

import numpy as np
import pytest

from earthsci_ast.elementwise_lift import ElementwiseLiftError
from earthsci_ast.problem import _rhs_of, esm_problem

ROOT = Path(__file__).resolve().parents[3]
COUPLED = ROOT / "tests" / "conformance" / "template_array_args" / "coupled"


def _rhs(path: Path, compiler: str) -> dict[str, float]:
    prob = esm_problem(str(path), (0.0, 1.0), compiler=compiler)
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
