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
        field_reduce("wat", actual)  # unknown kind


def test_field_reduce_integral_is_unit_measure_mean():
    """Pinned cross-binding convention: `integral` is the uniform-cell
    Riemann sum under a UNIT total domain measure per axis — Σ field /
    N_cells, exactly `mean` (NOT the bare sum)."""
    f = [1.0, 2.0, 3.0]
    assert field_reduce("integral", f) == 2.0
    assert field_reduce("integral", f) == field_reduce("mean", f)
    g = [(i - 0.5) / 8 for i in range(1, 9)]
    assert field_reduce("integral", g) == 0.5
    with pytest.raises(ValueError):
        field_reduce("integral", [])


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


# ---------------------------------------------------------------------------
# §6.6.5 coords point-sampling (pinned convention: 1-based INDEX space,
# nearest grid index, exact half-way ties round DOWN)
# ---------------------------------------------------------------------------


def _coords_assert(coords, *, time=0.0, expected=0.0, abs_tol=1e-9, var="u"):
    return {"variable": var, "time": time, "expected": expected,
            "tolerance": {"abs": abs_tol}, "coords": dict(coords)}


def _run(doc_or_file, **kwargs):
    f = load(json.dumps(doc_or_file)) if isinstance(doc_or_file, dict) \
        else doc_or_file
    return run_pde_tests(f, model_name="M", method="LSODA",
                         rtol=1e-12, atol=1e-14, **kwargs)


def test_run_pde_tests_coords_sampling_nearest_ties_down():
    u3 = math.cos(math.pi * 2.5 / N)
    u6 = math.cos(math.pi * 5.5 / N)
    u8 = math.cos(math.pi * 7.5 / N)
    doc = _decay_doc()
    doc["models"]["M"]["tests"][0]["assertions"] = [
        _coords_assert({"x": 3}, expected=u3),
        _coords_assert({"x": 3.5}, expected=u3),   # tie → lower index 3
        _coords_assert({"x": 2.5}, expected=math.cos(math.pi * 1.5 / N)),  # tie → 2
        _coords_assert({"x": 5.6}, expected=u6),   # nearest → 6
        _coords_assert({"x": 8.5}, expected=u8),   # tie at top edge → 8
        _coords_assert({"x": 3}, time=1.0, expected=math.exp(-1.0) * u3,
                       abs_tol=1e-8),
    ]
    results = _run(doc)
    assert len(results) == 6
    assert all(r.passed for r in results), \
        [(r.assertion_idx, r.message) for r in results]
    assert all(r.reduce is None for r in results)
    assert results[0].actual == results[1].actual


def test_run_pde_tests_coords_validation_rejections():
    doc = _decay_doc()
    doc["models"]["M"]["tests"][0]["assertions"] = [
        _coords_assert({"y": 1.0}),
        _coords_assert({"x": 0.4}),   # → index 0
        _coords_assert({"x": 8.6}),   # → index 9
    ]
    results = _run(doc)
    assert len(results) == 3
    assert all(not r.passed and r.actual is None for r in results)
    assert "names unknown dimension 'y'" in results[0].message
    assert "outside 1..8" in results[1].message
    assert "resolves to index 0" in results[1].message
    assert "resolves to index 9" in results[2].message


def test_run_pde_tests_coords_on_scalar_variable_rejected():
    """coords on a scalar (0-D) variable is ill-formed per §6.6.5."""
    doc = {
        "esm": "0.8.0",
        "metadata": {"name": "scalar_coords"},
        "models": {"M": {
            "variables": {"z": {"type": "state", "units": "1", "default": 1.0}},
            "equations": [
                {"lhs": {"op": "D", "args": ["z"], "wrt": "t"}, "rhs": 0.0}],
            "tests": [{
                "id": "scalar",
                "time_span": {"start": 0.0, "end": 1.0},
                "assertions": [_coords_assert({"x": 1.0}, time=1.0, var="z")],
            }],
        }},
    }
    results = _run(doc)
    assert len(results) == 1
    assert not results[0].passed
    assert "requires a spatially-shaped variable" in results[0].message


def test_coords_and_reduce_are_mutually_exclusive_at_load():
    from earthsci_toolkit.parse import SchemaValidationError

    doc = _decay_doc()
    doc["models"]["M"]["tests"][0]["assertions"] = [
        {"variable": "u", "time": 0.0, "expected": 0.0,
         "coords": {"x": 1}, "reduce": "mean"},
    ]
    with pytest.raises(SchemaValidationError):
        load(json.dumps(doc))


def _doc_2d(ny):
    """du_ij/dt = 1 with u(0) = 0, so u(t) = t everywhere: pins the
    strict-subset rule — pinning only `x` is legal iff `y` is singleton."""
    idx = {"op": "index", "args": ["u", "i", "j"]}
    ranges = {"i": [1, 4], "j": [1, ny]}
    return {
        "esm": "0.8.0",
        "metadata": {"name": "pde_inline_2d"},
        "index_sets": {"x": {"kind": "interval", "size": 4},
                       "y": {"kind": "interval", "size": ny}},
        "models": {"M": {
            "variables": {"u": {"type": "state", "units": "1",
                                "shape": ["x", "y"]}},
            "equations": [
                {"lhs": {"op": "ic", "args": ["u"]}, "rhs": 0.0},
                {"lhs": {"op": "aggregate", "args": [],
                         "output_idx": ["i", "j"], "ranges": ranges,
                         "expr": {"op": "D", "args": [idx], "wrt": "t"}},
                 "rhs": {"op": "aggregate", "args": [],
                         "output_idx": ["i", "j"], "ranges": ranges,
                         "expr": 1.0}},
            ],
            "tests": [{
                "id": "subset",
                "time_span": {"start": 0.0, "end": 1.0},
                "assertions": [_coords_assert({"x": 2}, time=1.0,
                                              expected=1.0, abs_tol=1e-8)],
            }],
        }},
    }


def test_coords_strict_subset_requires_singleton_remainder():
    ok = _run(_doc_2d(1))
    assert len(ok) == 1
    assert ok[0].passed, ok[0].message
    assert ok[0].actual == pytest.approx(1.0, abs=1e-8)

    bad = _run(_doc_2d(3))
    assert len(bad) == 1
    assert not bad[0].passed
    assert "leaves dimension 'y' unpinned with 3 samples" in bad[0].message


# ---------------------------------------------------------------------------
# §6.6.5 from_file references (pinned convention: path relative to the .esm
# file's directory; v1 format json — row-major nested array in field shape)
# ---------------------------------------------------------------------------


def _from_file_assert(ref, *, reduce="L2_error", abs_tol=1e-12):
    return {"variable": "u", "time": 0.0, "expected": 0.0,
            "tolerance": {"abs": abs_tol}, "reduce": reduce, "reference": ref}


def test_from_file_reference_happy_path(tmp_path):
    from earthsci_toolkit.pde_inline_tests import simulate_states

    # The binding's own evaluated ic field, so the diff is exactly 0 (the
    # loaded array is used exactly like an evaluated reference field).
    f0 = load(json.dumps(_decay_doc()))
    sim0 = simulate_states(f0, (0.0, 1.0), method="LSODA", rtol=1e-12,
                           atol=1e-14, saveat=[0.0])
    vals = [float(sim0.states[0][slot])
            for _, slot in state_cells(sim0.var_map, "u", "M")]
    (tmp_path / "ref.json").write_text(json.dumps(vals))
    doc = _decay_doc()
    doc["models"]["M"]["tests"][0]["assertions"] = [
        _from_file_assert({"type": "from_file", "path": "ref.json"}),
        _from_file_assert({"type": "from_file", "path": "ref.json",
                           "format": "json"}, reduce="Linf_error"),
    ]
    prob = tmp_path / "prob.esm"
    prob.write_text(json.dumps(doc))

    # Path input: base_dir defaults to the .esm file's directory.
    results = run_pde_tests(str(prob), model_name="M", method="LSODA",
                            rtol=1e-12, atol=1e-14)
    assert len(results) == 2
    for r in results:
        assert r.passed, r.message
        assert r.actual == 0.0

    # EsmFile input: explicit base_dir resolves the same way.
    results2 = _run(doc, base_dir=str(tmp_path))
    assert all(r.passed for r in results2)


def test_from_file_reference_shape_mismatch(tmp_path):
    vals = [math.cos(math.pi * (i - 0.5) / N) for i in range(1, N + 1)]
    (tmp_path / "short.json").write_text(json.dumps(vals[:7]))
    doc = _decay_doc()
    doc["models"]["M"]["tests"][0]["assertions"] = [
        _from_file_assert({"type": "from_file", "path": "short.json"})]
    r = _run(doc, base_dir=str(tmp_path))[0]
    assert not r.passed
    assert ("shape mismatch along dimension 1: expected length 8, found 7"
            in r.message)

    # Deeper nesting than the field's rank.
    (tmp_path / "deep.json").write_text(json.dumps([[v] for v in vals]))
    doc["models"]["M"]["tests"][0]["assertions"] = [
        _from_file_assert({"type": "from_file", "path": "deep.json"})]
    r = _run(doc, base_dir=str(tmp_path))[0]
    assert not r.passed
    assert "expected a number" in r.message


def test_from_file_reference_missing_file_and_format(tmp_path):
    doc = _decay_doc()
    doc["models"]["M"]["tests"][0]["assertions"] = [
        _from_file_assert({"type": "from_file", "path": "nope.json"})]
    r = _run(doc, base_dir=str(tmp_path))[0]
    assert not r.passed
    assert "file not found" in r.message

    (tmp_path / "ref.json").write_text("[1, 2, 3, 4, 5, 6, 7, 8]")
    doc["models"]["M"]["tests"][0]["assertions"] = [
        _from_file_assert({"type": "from_file", "path": "ref.json",
                           "format": "netcdf"})]
    r = _run(doc, base_dir=str(tmp_path))[0]
    assert not r.passed
    assert "format 'netcdf' is not supported" in r.message


# ---------------------------------------------------------------------------
# Shared executable fixture (identical input across the three bindings)
# ---------------------------------------------------------------------------


def test_shared_fixture_pde_inline_assertions_exec():
    import os

    fixture = os.path.join(
        os.path.dirname(__file__), "..", "..", "..",
        "tests", "spatial", "pde_inline_assertions_exec.esm")
    assert os.path.isfile(fixture)
    results = run_pde_tests(fixture, model_name="M", method="LSODA",
                            rtol=1e-12, atol=1e-14)
    assert len(results) == 7
    assert all(r.passed for r in results), \
        [(r.assertion_idx, r.message) for r in results]
    # The two tie-sampling coords assertions hit the SAME cell.
    assert results[0].actual == results[1].actual
    # integral == mean == 0 for the symmetric cosine field.
    assert abs(results[4].actual) < 1e-12
    # from_file error norms are ~0 against the committed exact snapshot.
    assert results[5].actual < 1e-12
    assert results[6].actual < 1e-12
