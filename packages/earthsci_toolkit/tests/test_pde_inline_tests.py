"""Tests for the §6.6.5-capable inline-test runner (``pde_inline_tests``) and
its supporting load/simulate capabilities: ``Assertion`` ``coords`` /
``reduce`` / ``reference`` parsing + serialization, coordinate-expression
``ic`` seeding through the NumPy interpreter, ``evaluate_cellwise``,
``field_reduce``, ``state_cells``, and ``run_pde_tests`` — the Python mirror
of the Julia reference's ``pde_inline_tests.jl``."""
from __future__ import annotations

import json
import math

import pytest

from earthsci_toolkit.esm_types import ExprNode, Tolerance
from earthsci_toolkit.parse import load
from earthsci_toolkit.pde_inline_tests import (
    _check_assertion,
    _resolve_tolerance,
    evaluate_cellwise,
    field_reduce,
    run_pde_tests,
    state_cells,
)
from earthsci_toolkit.serialize import _serialize_esm_file

N = 8


def _x_coord_aggregate() -> dict:
    """Cell-center coordinates x_i = (i - 1/2)/N over the ``x`` index set —
    the §9.7 grid-geometry aggregate shape (post-import expansion)."""
    return {
        "op": "aggregate", "args": [], "output_idx": ["i"],
        "ranges": {"i": {"from": "x"}},
        "expr": {"op": "*",
                 "args": [{"op": "-", "args": ["i", 0.5]},
                          {"op": "/", "args": [1, N]}]},
    }


def _cos_pi_x() -> dict:
    return {"op": "cos",
            "args": [{"op": "*", "args": [math.pi, _x_coord_aggregate()]}]}


def _decay_doc() -> dict:
    """A lifted field decay model du_i/dt = -u_i seeded by the coordinate
    expression ic(u) = cos(pi x_i); exact solution e^{-t} cos(pi x_i)."""
    idx = {"op": "index", "args": ["u", "i"]}
    return {
        "esm": "0.8.0",
        "metadata": {"name": "pde_inline_decay"},
        "index_sets": {"x": {"kind": "interval", "size": N}},
        "models": {"M": {
            "variables": {
                "u": {"type": "state", "units": "1", "shape": ["x"]},
            },
            "equations": [
                {"lhs": {"op": "ic", "args": ["u"]}, "rhs": _cos_pi_x()},
                {"lhs": {"op": "aggregate", "args": [], "output_idx": ["i"],
                         "ranges": {"i": [1, N]},
                         "expr": {"op": "D", "args": [idx], "wrt": "t"}},
                 "rhs": {"op": "aggregate", "args": [], "output_idx": ["i"],
                         "ranges": {"i": [1, N]},
                         "expr": {"op": "*", "args": [-1, idx]}}},
            ],
            "tests": [{
                "id": "decay",
                "time_span": {"start": 0.0, "end": 1.0},
                "assertions": [
                    # t=0 pins the coordinate-expression ic wiring exactly.
                    {"variable": "u", "time": 0.0, "expected": 0.0,
                     "tolerance": {"abs": 1e-12}, "reduce": "L2_error",
                     "reference": _cos_pi_x()},
                    # t=1: pure integrator error against e^{-1} cos(pi x).
                    {"variable": "u", "time": 1.0, "expected": 0.0,
                     "tolerance": {"abs": 1e-8}, "reduce": "L2_error",
                     "reference": {"op": "*",
                                   "args": [{"op": "exp", "args": [-1]},
                                            _cos_pi_x()]}},
                    # Pure collapser: the symmetric cosine field has zero mean.
                    {"variable": "u", "time": 1.0, "expected": 0.0,
                     "tolerance": {"abs": 1e-9}, "reduce": "mean"},
                ],
            }],
        }},
    }


# ---------------------------------------------------------------------------
# Assertion parsing + serialization (§6.6.5 fields)
# ---------------------------------------------------------------------------


def test_assertion_reduce_reference_parse_and_roundtrip():
    f = load(json.dumps(_decay_doc()))
    a = f.models["M"].tests[0].assertions[0]
    assert a.reduce == "L2_error"
    assert isinstance(a.reference, ExprNode)
    assert a.reference.op == "cos"
    assert a.coords is None
    out = _serialize_esm_file(f)
    ser = out["models"]["M"]["tests"][0]["assertions"][0]
    assert ser["reduce"] == "L2_error"
    assert ser["reference"]["op"] == "cos"
    # The scalar form still omits every §6.6.5 key.
    ser_mean = out["models"]["M"]["tests"][0]["assertions"][2]
    assert "reference" not in ser_mean and ser_mean["reduce"] == "mean"


def test_assertion_from_file_reference_roundtrips_verbatim():
    doc = _decay_doc()
    doc["models"]["M"]["tests"][0]["assertions"][0]["reference"] = {
        "type": "from_file", "path": "ref.nc", "format": "netcdf"}
    f = load(json.dumps(doc))
    a = f.models["M"].tests[0].assertions[0]
    assert a.reference == {"type": "from_file", "path": "ref.nc",
                           "format": "netcdf"}
    ser = _serialize_esm_file(f)["models"]["M"]["tests"][0]["assertions"][0]
    assert ser["reference"] == {"type": "from_file", "path": "ref.nc",
                                "format": "netcdf"}


# ---------------------------------------------------------------------------
# evaluate_cellwise + field_reduce (the §6.6.5 reduction semantics)
# ---------------------------------------------------------------------------


def test_evaluate_cellwise_grid_geometry():
    f = load(json.dumps(_decay_doc()))
    expr = f.models["M"].tests[0].assertions[0].reference
    cells = [[i] for i in range(1, N + 1)]
    vals = evaluate_cellwise(expr, cells, index_sets=f.index_sets)
    want = [math.cos(math.pi * (i - 0.5) / N) for i in range(1, N + 1)]
    assert vals == pytest.approx(want, abs=1e-15)
    # A const-folding scalar broadcasts.
    two = ExprNode(op="+", args=[1, 1])
    assert evaluate_cellwise(two, cells) == [2.0] * N


def test_field_reduce_semantics():
    actual = [1.0, 2.0, 3.0]
    ref = [1.0, 2.0, 5.0]
    assert field_reduce("L2_error", actual, reference=ref) == pytest.approx(
        2.0 / math.sqrt(30.0))
    assert field_reduce("Linf_error", actual, reference=ref) == 2.0
    assert field_reduce("mean", actual) == 2.0
    assert field_reduce("max", actual) == 3.0
    assert field_reduce("min", actual) == 1.0
    with pytest.raises(ValueError):
        field_reduce("L2_error", actual)  # reference required
    with pytest.raises(ValueError):
        field_reduce("L2_error", actual, reference=[0.0, 0.0, 0.0])  # zero norm
    with pytest.raises(ValueError):
        field_reduce("integral", actual)


def test_state_cells_matching_and_order():
    var_map = {"M.u[2]": 4, "M.u[1]": 3, "M.u[10]": 9, "M.v[1]": 0, "w": 1}
    cells = state_cells(var_map, "u", "M")
    assert cells == [([1], 3), ([2], 4), ([10], 9)]  # numeric cell order
    assert state_cells(var_map, "u", "Other") == cells  # bare-stem match
    assert state_cells(var_map, "w", "M") == []  # scalars never match


def test_tolerance_precedence_and_isapprox_semantics():
    model_tol = Tolerance(rel=1e-2, abs=None)
    test_tol = Tolerance(rel=None, abs=1e-3)
    assertion_tol = Tolerance(rel=1e-6, abs=1e-9)
    assert _resolve_tolerance(model_tol, test_tol, assertion_tol) == (1e-6, 1e-9)
    assert _resolve_tolerance(model_tol, test_tol, None) == (0.0, 1e-3)
    assert _resolve_tolerance(model_tol, None, None) == (1e-2, 0.0)
    assert _resolve_tolerance(None, None, None) == (1e-6, 0.0)
    # Julia isapprox: |a-e| <= max(atol, rtol*max(|a|,|e|)).
    assert _check_assertion(1.0000009, 1.0, 1e-6, 0.0)
    assert not _check_assertion(1.000002, 1.0, 1e-6, 0.0)
    assert _check_assertion(0.0, 1e-10, 0.0, 1e-9)
    assert _check_assertion(2.0, 2.0, 0.0, 0.0)  # exact-equality mode
    assert not _check_assertion(2.0, 2.0000001, 0.0, 0.0)


# ---------------------------------------------------------------------------
# run_pde_tests end-to-end (coordinate-expression ic + reductions)
# ---------------------------------------------------------------------------


def test_run_pde_tests_decay_field():
    f = load(json.dumps(_decay_doc()))
    results = run_pde_tests(f, model_name="M", method="LSODA",
                            rtol=1e-12, atol=1e-14)
    assert [r.assertion_idx for r in results] == [1, 2, 3]
    by_idx = {r.assertion_idx: r for r in results}
    # t=0: the ic seeding IS the reference — zero up to the dense-output
    # interpolant's t=0 rounding.
    assert by_idx[1].passed and by_idx[1].actual < 1e-14
    # t=1: integrator-level error only.
    assert by_idx[2].passed and by_idx[2].actual < 1e-8
    assert by_idx[3].passed and abs(by_idx[3].actual) < 1e-9
    assert all(r.reduce in ("L2_error", "mean") for r in results)
    assert all(r.model == "M" and r.test_id == "decay" for r in results)


def test_run_pde_tests_reports_failing_assertion_with_actual():
    doc = _decay_doc()
    # An impossible expectation: the decayed field cannot still match its
    # initial state at t=1 to 1e-12.
    doc["models"]["M"]["tests"][0]["assertions"] = [
        {"variable": "u", "time": 1.0, "expected": 0.0,
         "tolerance": {"abs": 1e-12}, "reduce": "L2_error",
         "reference": _cos_pi_x()},
    ]
    results = run_pde_tests(load(json.dumps(doc)), model_name="M",
                            method="LSODA", rtol=1e-12, atol=1e-14)
    assert len(results) == 1
    r = results[0]
    assert not r.passed
    assert r.actual == pytest.approx(1.0 - math.exp(-1.0), rel=1e-6)
    assert "actual=" in r.message


def test_coordinate_expression_ic_seeds_grid(tmp_path):
    """The §11.4.1 case-3 seeding path in isolation: u(0) = cos(pi x_i)."""
    from earthsci_toolkit.pde_inline_tests import simulate_states

    f = load(json.dumps(_decay_doc()))
    sim = simulate_states(f, (0.0, 1.0), method="LSODA", rtol=1e-12,
                          atol=1e-14, saveat=[0.0])
    cells = state_cells(sim.var_map, "u", "M")
    got = [sim.states[0][slot] for _, slot in cells]
    want = [math.cos(math.pi * (i - 0.5) / N) for i in range(1, N + 1)]
    assert got == pytest.approx(want, abs=1e-15)
