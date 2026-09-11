"""Tests for the §6.6.5-capable inline-test runner (``inline_tests``) and
its supporting load/simulate capabilities: ``Assertion`` ``coords`` /
``reduce`` / ``reference`` parsing + serialization, coordinate-expression
``ic`` seeding through the NumPy interpreter, ``evaluate_cellwise``,
``field_reduce``, ``state_cells``, and ``run_inline_tests`` — the Python mirror
of the Julia reference's ``inline_tests.jl``."""

from __future__ import annotations

import json
import math
import os

import pytest
from conftest import FIXTURES_ROOT

from earthsci_ast.esm_types import ExprNode, Tolerance
from earthsci_ast.parse import load_string
from earthsci_ast.inline_tests import (
    InlineTestOptions,
    _check_assertion,
    _resolve_tolerance,
    evaluate_cellwise,
    field_reduce,
    run_inline_tests,
    state_cells,
)
from earthsci_ast.serialize import _serialize_esm_file

N = 8


def _x_coord_aggregate() -> dict:
    """Cell-center coordinates x_i = (i - 1/2)/N over the ``x`` index set —
    the §9.7 grid-geometry aggregate shape (post-import expansion)."""
    return {
        "op": "faq",
        "args": [],
        "output_idx": ["i"],
        "ranges": {"i": {"from": "x"}},
        "expr": {"op": "*", "args": [{"op": "-", "args": ["i", 0.5]}, {"op": "/", "args": [1, N]}]},
    }


def _cos_pi_x() -> dict:
    return {"op": "cos", "args": [{"op": "*", "args": [math.pi, _x_coord_aggregate()]}]}


def _decay_doc() -> dict:
    """A lifted field decay model du_i/dt = -u_i seeded by the coordinate
    expression ic(u) = cos(pi x_i); exact solution e^{-t} cos(pi x_i)."""
    idx = {"op": "index", "args": ["u", "i"]}
    return {
        "esm": "1.0.0",
        "metadata": {"name": "pde_inline_decay"},
        "index_sets": {"x": {"kind": "interval", "size": N}},
        "models": {
            "M": {
                "variables": {
                    "u": {"type": "unknown", "units": "1", "shape": ["x"]},
                },
                "equations": [
                    {"lhs": {"op": "ic", "args": ["u"]}, "rhs": _cos_pi_x()},
                    {
                        "lhs": {
                            "op": "faq",
                            "args": [],
                            "output_idx": ["i"],
                            "ranges": {"i": [1, N]},
                            "expr": {"op": "D", "args": [idx], "wrt": "t"},
                        },
                        "rhs": {
                            "op": "faq",
                            "args": [],
                            "output_idx": ["i"],
                            "ranges": {"i": [1, N]},
                            "expr": {"op": "*", "args": [-1, idx]},
                        },
                    },
                ],
                "tests": [
                    {
                        "id": "decay",
                        "time_span": {"start": 0.0, "end": 1.0},
                        "assertions": [
                            # t=0 pins the coordinate-expression ic wiring exactly.
                            {
                                "variable": "u",
                                "time": 0.0,
                                "expected": 0.0,
                                "tolerance": {"abs": 1e-12},
                                "reduce": "L2_error",
                                "reference": _cos_pi_x(),
                            },
                            # t=1: pure integrator error against e^{-1} cos(pi x).
                            {
                                "variable": "u",
                                "time": 1.0,
                                "expected": 0.0,
                                "tolerance": {"abs": 1e-8},
                                "reduce": "L2_error",
                                "reference": {
                                    "op": "*",
                                    "args": [{"op": "exp", "args": [-1]}, _cos_pi_x()],
                                },
                            },
                            # Pure collapser: the symmetric cosine field has zero mean.
                            {
                                "variable": "u",
                                "time": 1.0,
                                "expected": 0.0,
                                "tolerance": {"abs": 1e-9},
                                "reduce": "mean",
                            },
                        ],
                    }
                ],
            }
        },
    }


# ---------------------------------------------------------------------------
# Assertion parsing + serialization (§6.6.5 fields)
# ---------------------------------------------------------------------------


def test_assertion_reduce_reference_parse_and_roundtrip():
    f = load_string(json.dumps(_decay_doc()))
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
        "type": "from_file",
        "path": "ref.nc",
        "format": "netcdf",
    }
    f = load_string(json.dumps(doc))
    a = f.models["M"].tests[0].assertions[0]
    assert a.reference == {"type": "from_file", "path": "ref.nc", "format": "netcdf"}
    ser = _serialize_esm_file(f)["models"]["M"]["tests"][0]["assertions"][0]
    assert ser["reference"] == {"type": "from_file", "path": "ref.nc", "format": "netcdf"}


# ---------------------------------------------------------------------------
# evaluate_cellwise + field_reduce (the §6.6.5 reduction semantics)
# ---------------------------------------------------------------------------


def test_evaluate_cellwise_grid_geometry():
    f = load_string(json.dumps(_decay_doc()))
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
    assert field_reduce("L2_error", actual, reference=ref) == pytest.approx(2.0 / math.sqrt(30.0))
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
    assert state_cells(var_map, "u", "Other") == cells  # bare-stem fallback
    assert state_cells(var_map, "w", "M") == []  # scalars never match


def test_state_cells_qualified_stem_wins_over_a_sibling_models_bare_name():
    """A coupled build reuses one bare array name across sibling components, and
    the model-QUALIFIED stem must win — the array analog of ``_scalar_slot``'s
    two-pass resolution, and identical to the Julia / Rust ``state_cells``.

    The single-pass union this replaces spliced every model's cells into one
    field: four models each declaring ``w[x]`` produced FOUR cells at index
    ``[1]``, so a ``coords`` sample read whichever model sorted first (always the
    same wrong one, silently), a ``reduce`` collapsed over all four models at
    once, and a per-cell ``reference`` then indexed past the end of the field
    (``IndexError``). The bare fallback still answers a bare-keyed build, but
    only when NO qualified element exists."""
    var_map = {
        "A.w[1]": 0,
        "A.w[2]": 1,
        "B.w[1]": 2,
        "B.w[2]": 3,
        "C.w[1]": 4,
        "C.w[2]": 5,
    }
    assert state_cells(var_map, "w", "B") == [([1], 2), ([2], 3)]
    assert state_cells(var_map, "w", "C") == [([1], 4), ([2], 5)]
    # No component of that name at all: the bare-suffix fallback is reached,
    # and only then does it union the siblings (the pre-existing behaviour for
    # a build whose elements carry no qualification).
    assert len(state_cells(var_map, "w", "Nope")) == 6
    # A bare-keyed single-model build still resolves under any model name.
    assert state_cells({"u[1]": 7}, "u", "M") == [([1], 7)]


def test_tolerance_precedence_and_isapprox_semantics():
    model_tol = Tolerance(rel=1e-2, abs=None)
    test_tol = Tolerance(rel=None, abs=1e-3)
    assertion_tol = Tolerance(rel=1e-6, abs=1e-9)
    assert _resolve_tolerance(model_tol, test_tol, assertion_tol) == (1e-6, 1e-9)
    # PER FIELD (§6.6.4): the test declares only ``abs``, so the model's ``rel``
    # survives. This returned ``(0.0, 1e-3)`` before #228 — the test's block won
    # wholesale and the model's relative bound vanished.
    assert _resolve_tolerance(model_tol, test_tol, None) == (1e-2, 1e-3)
    assert _resolve_tolerance(model_tol, None, None) == (1e-2, 0.0)
    assert _resolve_tolerance(None, None, None) == (1e-6, 0.0)
    # The implementation default is the FOURTH LEVEL of the same per-field
    # merge, not a fallback reached only when levels 1-3 are silent: an
    # `abs`-only block still takes `rel = 1e-6` from it.
    abs_only = Tolerance(rel=None, abs=1e-4)
    assert _resolve_tolerance(None, None, abs_only) == (1e-6, 1e-4)
    assert _resolve_tolerance(abs_only, None, None) == (1e-6, 1e-4)
    # ... and `rel: 0` is the only way to opt out of it. An explicit zero is a
    # DECLARATION, so it stops the fallthrough at the default too.
    assert _resolve_tolerance(None, None, Tolerance(rel=0.0, abs=1e-4)) == (0.0, 1e-4)
    # A declared outer `rel` still beats the default, however far out it sits.
    assert _resolve_tolerance(Tolerance(rel=1e-3, abs=None), None, abs_only) == (1e-3, 1e-4)
    # Julia isapprox: |a-e| <= max(atol, rtol*max(|a|,|e|)).
    assert _check_assertion(1.0000009, 1.0, 1e-6, 0.0)
    assert not _check_assertion(1.000002, 1.0, 1e-6, 0.0)
    assert _check_assertion(0.0, 1e-10, 0.0, 1e-9)
    assert _check_assertion(2.0, 2.0, 0.0, 0.0)  # exact-equality mode
    assert not _check_assertion(2.0, 2.0000001, 0.0, 0.0)


def test_relative_bound_is_symmetric_in_actual_and_expected():
    """esm-spec §6.6.3: the relative bound scales by ``max(|actual|,
    |expected|)`` — the larger of the two magnitudes — NOT by ``|expected|``
    alone.

    §6.6.3 used to state both readings: the normative box (and the schema's
    ``Tolerance`` description) gave the ``|expected|``-only denominator while
    the finiteness rationale further down the same section reasoned from
    ``max(|inf|, |expected|)``. All three executing bindings implemented the
    symmetric one; EarthSciML/EarthSciAST#193 settled the spec as symmetric.

    Their VERDICTS disagree only inside ``rtol*|e| < |a − e| <= rtol*|a|``,
    which needs an overshoot (``|actual| > |expected|``) whose margin is itself
    of order ``rtol``. Everywhere else ``max(|a|, |e|) == |e|`` or the
    difference falls on the same side of both bounds, which is why the
    divergence went unnoticed: every pre-existing tolerance case in every
    binding gets the same verdict under both readings, and the
    ``assertion_nonfinite`` category compares verdicts on non-finite actuals.
    Reverting ``_check_assertion`` to the ``|expected|`` denominator must turn
    this red.
    """
    # The discriminator (issue #193): the symmetric scale is 1.6, not 1.0.
    #   symmetric:  0.6 <= 0.5 * max(1.6, 1.0) = 0.8  -> PASS
    #   |expected|: 0.6 <= 0.5 * 1.0           = 0.5  -> FAIL
    assert _check_assertion(1.6, 1.0, 0.5, 0.0)
    # Past the symmetric bound too, so both readings agree again.
    assert not _check_assertion(3.0, 1.0, 0.5, 0.0)

    # Symmetry as the property, not just the one case: swapping the arguments
    # cannot change the verdict. Under an |expected|-only denominator the first
    # pair below disagrees with itself reversed.
    for a, e in ((1.6, 1.0), (1.0, 1.6), (3.0, 1.0), (1.0, 3.0), (-2.0, -1.2)):
        assert _check_assertion(a, e, 0.5, 0.0) == _check_assertion(e, a, 0.5, 0.0)

    # No epsilon floor, and none permitted: the bound is a product, not a
    # quotient, so expected == 0 needs no protection. It reads |a| <= rel*|a|,
    # which a nonzero actual clears only at rel >= 1 — a purely relative
    # tolerance says nothing about how close to zero is close enough.
    assert not _check_assertion(1.0, 0.0, 0.5, 0.0)
    assert _check_assertion(1.0, 0.0, 1.0, 0.0)
    assert _check_assertion(1.0, 0.0, 0.0, 1.0)  # an abs bound is the way to spell it
    assert _check_assertion(0.0, 0.0, 0.0, 0.0)  # exact-equality clause

    # Zero ACTUAL against a nonzero expected — the mirror of the case above.
    # Here the symmetric scale IS |e|, so both readings agree; it is pinned
    # because the other one-sided reading (scale by |actual| alone) would make
    # the bound zero and reject every inexact match.
    assert not _check_assertion(0.0, 1.0, 0.5, 0.0)
    assert _check_assertion(0.0, 1.0, 1.0, 0.0)

    # OPPOSITE SIGNS. rel >= 1 is vacuous only for a pair that shares a sign;
    # across a sign change the bound still bites, which is why §6.6.3 says
    # rel >= 1 is not a substitute for an abs bound at expected == 0.
    assert not _check_assertion(1.0, -1.0, 1.0, 0.0)
    assert _check_assertion(-1.0, 1.0, 2.0, 0.0)

    # NON-FINITE actuals. The symmetric scale is precisely what makes the
    # finiteness clause load-bearing: |inf − e| <= rel*max(inf, |e|) is
    # inf <= inf, so the bound ALONE would pass every expected value
    # (§6.6.3; the assertion_nonfinite category, CONFORMANCE_SPEC §5.20).
    assert not _check_assertion(math.inf, 1.0, 0.5, 0.0)
    assert not _check_assertion(-math.inf, 1.0, 0.5, 0.0)
    assert not _check_assertion(math.nan, 1.0, 0.5, 0.0)
    assert _check_assertion(math.inf, math.inf, 0.5, 0.0)  # same infinity
    assert not _check_assertion(math.inf, -math.inf, 0.5, 0.0)

    # abs/rel interaction, both directions. An abs bound never narrows what rel
    # already admits — the predicate takes the MAX of the two — so a tiny abs
    # must not turn the overshoot case red:
    assert _check_assertion(1.6, 1.0, 0.5, 1e-12)
    # and abs admits what the symmetric rel rejects (same inputs as the
    # `not _check_assertion(3.0, 1.0, 0.5, 0.0)` rejection above):
    assert _check_assertion(3.0, 1.0, 0.5, 2.5)


# ---------------------------------------------------------------------------
# run_inline_tests end-to-end (coordinate-expression ic + reductions)
# ---------------------------------------------------------------------------


def test_run_inline_tests_decay_field():
    f = load_string(json.dumps(_decay_doc()))
    results = run_inline_tests(f, model_name="M", method="LSODA", rtol=1e-12, atol=1e-14)
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


def _free_x_cos() -> dict:
    """cos(pi (x - 1/2)/N) with the dimension name ``x`` FREE (esm-spec §6.6.5)."""
    return {
        "op": "cos",
        "args": [
            {
                "op": "*",
                "args": [math.pi, {"op": "/", "args": [{"op": "-", "args": ["x", 0.5]}, N]}],
            }
        ],
    }


def test_bind_dimension_names_wraps_only_a_free_mention():
    from earthsci_ast.esm_types import ExprNode
    from earthsci_ast.inline_tests import bind_dimension_names

    lit = ExprNode(op="*", args=[2.0, "k"])
    assert bind_dimension_names(lit, ["x"]) is lit
    free = ExprNode(op="+", args=["x", 1])
    wrapped = bind_dimension_names(free, ["x"])
    assert isinstance(wrapped, ExprNode) and wrapped.op == "faq"
    assert wrapped.output_idx == ["x"]
    assert wrapped.ranges == {"x": {"from": "x"}}
    assert wrapped.expr is free
    bound = ExprNode(
        op="faq", args=[], output_idx=["x"], ranges={"x": {"from": "x"}}, expr=free
    )
    assert bind_dimension_names(bound, ["x"]) is bound
    integ = ExprNode(
        op="integral", args=[ExprNode(op="*", args=[2, "x"])], var="x", lower=0, upper=1
    )
    assert bind_dimension_names(integ, ["x"]) is integ
    # A `wrt` is a differentiation TARGET, not a free read of the enclosing
    # scope, so it does not trigger the wrap (the Julia and Rust predicates
    # ignore `wrt` too).
    deriv = ExprNode(op="D", args=["u"], wrt="x")
    assert bind_dimension_names(deriv, ["x"]) is deriv
    assert bind_dimension_names(free, []) is free


def test_bind_dimension_names_rejects_a_dimension_that_shadows_a_parameter():
    """A dimension name the parameter scope ALSO binds is a fault, not a silent
    rebinding: wrapping would shadow the parameter with the cell index, so a
    reference that used to read the parameter would quietly return a different
    number. One name, two meanings, one scope — ill-formed."""
    import pytest

    from earthsci_ast.esm_types import ExprNode
    from earthsci_ast.inline_tests import bind_dimension_names

    free = ExprNode(op="+", args=["x", 1])
    with pytest.raises(RuntimeError, match="a parameter"):
        bind_dimension_names(free, ["x"], {"x": 3.0})
    # No mention of the clashing name: unaffected.
    lit = ExprNode(op="*", args=[2.0, "k"])
    assert bind_dimension_names(lit, ["x"], {"x": 3.0}) is lit
    # A gather that rebinds `x` itself keeps working.
    bound = ExprNode(
        op="faq", args=[], output_idx=["x"], ranges={"x": {"from": "x"}}, expr=free
    )
    assert bind_dimension_names(bound, ["x"], {"x": 3.0}) is bound
    # And with no scope supplied the wrap is unchanged.
    assert bind_dimension_names(free, ["x"]).op == "faq"


def test_bind_dimension_names_rejects_a_dimension_a_build_array_binds():
    """esm-spec §6.6.5's clash scope is the WHOLE build-time scope, not the
    parameter half of it (issue #226).

    A build ARRAY named after a shape index set — an array ``lev`` over the
    index set ``lev`` — is a name a reference could already read, so wrapping it
    would rebind it to the cell's 1-based index: the same expression, a
    different number, no diagnostic. Julia is where that channel is live, but
    all three bindings must reject the same documents.
    """
    import pytest

    from earthsci_ast.esm_types import ExprNode
    from earthsci_ast.inline_tests import _array_scope_names, bind_dimension_names

    free = ExprNode(op="index", args=["table", "lev"])
    # The flattened name AND its unambiguous bare alias are both in scope.
    for names in ({"lev": None}, {"M.lev": None}):
        arrays = _array_scope_names(names)
        with pytest.raises(RuntimeError, match="a build-time array"):
            bind_dimension_names(free, ["lev"], None, arrays)
    # An AMBIGUOUS bare alias is not in scope under either spelling, so it does
    # not clash — the same rule `_param_scope_with_aliases` applies.
    ambiguous = _array_scope_names({"A.lev": None, "B.lev": None})
    assert "lev" not in ambiguous
    assert bind_dimension_names(free, ["lev"], None, ambiguous).op == "faq"
    # A reference that does not mention the name is unaffected, and so is a
    # gather that rebinds it as its own loop symbol.
    arrays = _array_scope_names({"lev": None})
    lit = ExprNode(op="*", args=[2.0, "k"])
    assert bind_dimension_names(lit, ["lev"], None, arrays) is lit
    bound = ExprNode(
        op="faq", args=[], output_idx=["lev"], ranges={"lev": {"from": "lev"}}, expr=free
    )
    assert bind_dimension_names(bound, ["lev"], None, arrays) is bound


def test_reference_binds_the_field_dimension_names():
    """esm-spec §6.6.5: the analytic cell-centre form with ``x`` free, a table
    lookup by ``x``, and a gather that REBINDS ``x`` as its own loop symbol
    (which must not be wrapped again) all read the same field."""
    table = [math.cos(math.pi * (i - 0.5) / N) for i in range(1, N + 1)]
    doc = _decay_doc()
    doc["models"]["M"]["tests"][0]["assertions"] = [
        {
            "variable": "u",
            "time": 0.0,
            "expected": 0.0,
            "tolerance": {"abs": 1e-12},
            "reduce": "L2_error",
            "reference": _free_x_cos(),
        },
        {
            "variable": "u",
            "time": 0.0,
            "expected": 0.0,
            "tolerance": {"abs": 1e-12},
            "reduce": "Linf_error",
            "reference": {
                "op": "index",
                "args": [{"op": "const", "args": [], "value": table}, "x"],
            },
        },
        {
            "variable": "u",
            "time": 0.0,
            "expected": 0.0,
            "tolerance": {"abs": 1e-12},
            "reduce": "L2_error",
            "reference": {
                "op": "faq",
                "args": [],
                "output_idx": ["x"],
                "ranges": {"x": {"from": "x"}},
                "expr": _free_x_cos(),
            },
        },
        {
            "variable": "u",
            "time": 1.0,
            "expected": 0.0,
            "tolerance": {"abs": 1e-8},
            "reduce": "L2_error",
            "reference": {"op": "*", "args": [{"op": "exp", "args": [-1]}, _free_x_cos()]},
        },
    ]
    results = run_inline_tests(
        load_string(json.dumps(doc)), model_name="M", method="LSODA", rtol=1e-12, atol=1e-14
    )
    assert len(results) == 4
    for r in results:
        assert r.passed, f"assertion {r.assertion_idx}: {r.message}"


def test_subsystem_parameter_override_in_every_spelling():
    """esm-spec §4.6 / §6.6.2: inside ``P``, ``P.sub.g`` is the fully qualified
    spelling of the mounted subsystem parameter; it resolves in an equation and
    as an override key in every spelling (``P.sub.g``, ``sub.g``, ``g``)."""
    doc = _decay_doc()
    doc["models"]["P"] = doc["models"].pop("M")
    doc["models"]["P"]["subsystems"] = {
        "sub": {
            "variables": {"g": {"type": "parameter", "units": "1", "default": 9.81}},
            "equations": [],
        }
    }
    doc["models"]["P"]["variables"]["gg"] = {"type": "unknown", "units": "1"}
    doc["models"]["P"]["equations"].append({"lhs": "gg", "rhs": "P.sub.g"})

    def gg(want: float) -> list:
        return [{"variable": "gg", "time": 0.0, "expected": want, "tolerance": {"rel": 1e-12}}]

    span = {"start": 0.0, "end": 1.0}
    doc["models"]["P"]["tests"] = [
        {"id": "default", "time_span": span, "assertions": gg(9.81)},
        {
            "id": "qualified",
            "time_span": span,
            "parameter_overrides": {"P.sub.g": 1.5},
            "assertions": gg(1.5),
        },
        {
            "id": "relative",
            "time_span": span,
            "parameter_overrides": {"sub.g": 2.5},
            "assertions": gg(2.5),
        },
        {"id": "bare", "time_span": span, "parameter_overrides": {"g": 3.5}, "assertions": gg(3.5)},
    ]
    results = run_inline_tests(
        load_string(json.dumps(doc)), model_name="P", method="LSODA", rtol=1e-12, atol=1e-14
    )
    assert len(results) == 4
    for r in results:
        assert r.passed, f"test {r.test_id}: {r.message}"


def _array_observed_doc() -> dict:
    """Both kinds of array OBSERVED on one document: ``g`` is STATE-FREE (a
    pure index expression the build materializes once), ``h = u + 1`` is
    STATE-DEPENDENT (its field exists only on the trajectory), and ``nope`` is
    no variable of the component at all."""
    agg_g = {
        "op": "faq",
        "args": [],
        "output_idx": ["i"],
        "ranges": {"i": {"from": "x"}},
        "expr": {"op": "*", "args": ["i", "i"]},
    }
    return {
        "esm": "1.0.0",
        "metadata": {"name": "pde_inline_array_observed"},
        "index_sets": {"x": {"kind": "interval", "size": 3}},
        "models": {
            "M": {
                "variables": {
                    "u": {"type": "unknown", "units": "1", "shape": ["x"]},
                    "g": {"type": "unknown", "units": "1", "shape": ["x"]},
                    "h": {"type": "unknown", "units": "1", "shape": ["x"]},
                },
                "equations": [
                    {"lhs": "g", "rhs": agg_g},
                    {"lhs": "h", "rhs": {"op": "+", "args": ["u", 1]}},
                    {"lhs": {"op": "ic", "args": ["u"]}, "rhs": 0.0},
                    {"lhs": {"op": "D", "args": ["u"], "wrt": "t"}, "rhs": "h"},
                ],
                "tests": [
                    {
                        "id": "obs",
                        "time_span": {"start": 0.0, "end": 1.0},
                        "assertions": [
                            {
                                "variable": "g",
                                "time": 1.0,
                                "expected": 9.0,
                                "tolerance": {"abs": 1e-12},
                                "reduce": "max",
                            },
                            {
                                "variable": "h",
                                "time": 0.0,
                                "expected": 1.0,
                                "tolerance": {"abs": 1e-12},
                                "reduce": "max",
                            },
                            {
                                "variable": "h",
                                "time": 0.0,
                                "expected": 1.0,
                                "tolerance": {"abs": 1e-12},
                                "coords": {"x": 2},
                            },
                            {
                                "variable": "nope",
                                "time": 0.0,
                                "expected": 0.0,
                                "tolerance": {"abs": 1e-12},
                                "reduce": "max",
                            },
                        ],
                    }
                ],
            }
        },
    }


def test_array_observed_assertions_read_both_the_build_and_the_trajectory():
    """esm-spec §6.6.5 admits ANY shaped variable in a ``coords`` / ``reduce``
    assertion, and §5.23 makes a reference denote its expansion — so a
    STATE-DEPENDENT array observed is assertable exactly like a state-free one.

    Only the state-free half used to work: a state-dependent array observed is
    absent from the build inspection's setup arrays BY CONSTRUCTION (its value
    moves with the state) and the output-node reconstruction exposes only
    SCALAR observeds as rows, so every such assertion errored with "has no
    cells in var_map". It is now evaluated at the trajectory sample through the
    same observed driver the RHS uses."""
    f = load_string(json.dumps(_array_observed_doc()))
    results = run_inline_tests(f, model_name="M", method="LSODA", rtol=1e-12, atol=1e-14)
    assert len(results) == 4
    by_idx = {r.assertion_idx: r for r in results}
    # g = [1, 4, 9] is state-free: read from the build's materialized field.
    assert by_idx[1].passed, by_idx[1].message
    assert by_idx[1].actual == pytest.approx(9.0)
    # h = u + 1 reads the state; at t=0 (u seeded to 0) it is [1, 1, 1], and
    # both the reduce and the coords form must find it there.
    assert by_idx[2].passed, by_idx[2].message
    assert by_idx[2].actual == pytest.approx(1.0)
    assert by_idx[3].passed, by_idx[3].message
    assert by_idx[3].actual == pytest.approx(1.0)
    # A name that is no variable of the component still errors — the fallback
    # resolves names, it never invents them.
    assert not by_idx[4].passed
    assert by_idx[4].actual is None
    assert "has no cells in var_map" in by_idx[4].message


def _sibling_array_observed_doc() -> dict:
    """Two components; only ``M1`` defines the array observed ``g``. ``M2``'s
    test asserts a bare ``g`` it does not declare."""
    zero = {
        "op": "faq",
        "args": [],
        "output_idx": ["i"],
        "ranges": {"i": {"from": "x"}},
        "expr": 0.0,
    }
    m1 = {
        "variables": {
            "u": {"type": "unknown", "units": "1", "shape": ["x"]},
            "g": {"type": "unknown", "units": "1", "shape": ["x"]},
        },
        "equations": [
            {"lhs": {"op": "ic", "args": ["u"]}, "rhs": zero},
            {"lhs": {"op": "D", "args": ["u"], "wrt": "t"}, "rhs": zero},
            {"lhs": "g", "rhs": {"op": "+", "args": ["u", 900]}},
        ],
        "tests": [],
    }
    m2 = {
        "variables": {"u": {"type": "unknown", "units": "1", "shape": ["x"]}},
        "equations": [
            {"lhs": {"op": "ic", "args": ["u"]}, "rhs": zero},
            {"lhs": {"op": "D", "args": ["u"], "wrt": "t"}, "rhs": zero},
        ],
        "tests": [
            {
                "id": "borrowed",
                "time_span": {"start": 0.0, "end": 1.0},
                "assertions": [
                    {
                        "variable": "g",
                        "time": 0.0,
                        "expected": 900.0,
                        "tolerance": {"abs": 1e-12},
                        "reduce": "max",
                    }
                ],
            }
        ],
    }
    return {
        "esm": "1.0.0",
        "metadata": {"name": "pde_inline_sibling_array_observed"},
        "index_sets": {"x": {"kind": "interval", "size": 3}},
        "models": {"M1": m1, "M2": m2},
    }


def test_array_observed_assertion_never_reads_a_sibling_components_field():
    """An array observed field belongs to the ASSERTED component
    (CONFORMANCE_SPEC §5.27.1), and that holds for the trajectory-replay source
    exactly as it does for `state_cells`.

    Both field sources resolve a bare name by a unique ``.<name>`` suffix over
    the FLATTENED build, which spans every sibling component. Without the
    declaration guard an ``M2`` assertion on a ``g`` only ``M1`` defines
    silently answered 900.0 — M1's field, off a component the test never named
    — instead of erroring. Rust (`observed_field`, `assertion_observed_requests`)
    and Julia (`_observed_field`) both require the asserted model to declare the
    name; Python now does too."""
    f = load_string(json.dumps(_sibling_array_observed_doc()))
    results = run_inline_tests(f, model_name="M2", method="LSODA", rtol=1e-12, atol=1e-14)
    assert len(results) == 1
    r = results[0]
    assert not r.passed, f"M2 must not borrow M1's g (actual={r.actual})"
    assert r.actual is None
    assert "has no cells in var_map" in r.message


def test_run_inline_tests_reports_failing_assertion_with_actual():
    doc = _decay_doc()
    # An impossible expectation: the decayed field cannot still match its
    # initial state at t=1 to 1e-12.
    doc["models"]["M"]["tests"][0]["assertions"] = [
        {
            "variable": "u",
            "time": 1.0,
            "expected": 0.0,
            "tolerance": {"abs": 1e-12},
            "reduce": "L2_error",
            "reference": _cos_pi_x(),
        },
    ]
    results = run_inline_tests(
        load_string(json.dumps(doc)), model_name="M", method="LSODA", rtol=1e-12, atol=1e-14
    )
    assert len(results) == 1
    r = results[0]
    assert not r.passed
    assert r.actual == pytest.approx(1.0 - math.exp(-1.0), rel=1e-6)
    assert "actual=" in r.message


def test_coordinate_expression_ic_seeds_grid(tmp_path):
    """The §11.4.1 case-3 seeding path in isolation: u(0) = cos(pi x_i)."""
    from earthsci_ast.inline_tests import simulate_states

    f = load_string(json.dumps(_decay_doc()))
    sim = simulate_states(f, (0.0, 1.0), method="LSODA", rtol=1e-12, atol=1e-14, saveat=[0.0])
    cells = state_cells(sim.var_map, "u", "M")
    got = [sim.states[0][slot] for _, slot in cells]
    want = [math.cos(math.pi * (i - 0.5) / N) for i in range(1, N + 1)]
    assert got == pytest.approx(want, abs=1e-15)


# ---------------------------------------------------------------------------
# §6.6.5 coords point-sampling (pinned convention: 1-based INDEX space,
# nearest grid index, exact half-way ties round DOWN)
# ---------------------------------------------------------------------------


def _coords_assert(coords, *, time=0.0, expected=0.0, abs_tol=1e-9, var="u"):
    return {
        "variable": var,
        "time": time,
        "expected": expected,
        "tolerance": {"abs": abs_tol},
        "coords": dict(coords),
    }


def _run(doc_or_file, **kwargs):
    f = load_string(json.dumps(doc_or_file)) if isinstance(doc_or_file, dict) else doc_or_file
    return run_inline_tests(f, model_name="M", method="LSODA", rtol=1e-12, atol=1e-14, **kwargs)


def test_run_inline_tests_coords_sampling_nearest_ties_down():
    u3 = math.cos(math.pi * 2.5 / N)
    u6 = math.cos(math.pi * 5.5 / N)
    u8 = math.cos(math.pi * 7.5 / N)
    doc = _decay_doc()
    doc["models"]["M"]["tests"][0]["assertions"] = [
        _coords_assert({"x": 3}, expected=u3),
        _coords_assert({"x": 3.5}, expected=u3),  # tie → lower index 3
        _coords_assert({"x": 2.5}, expected=math.cos(math.pi * 1.5 / N)),  # tie → 2
        _coords_assert({"x": 5.6}, expected=u6),  # nearest → 6
        _coords_assert({"x": 8.5}, expected=u8),  # tie at top edge → 8
        _coords_assert({"x": 3}, time=1.0, expected=math.exp(-1.0) * u3, abs_tol=1e-8),
    ]
    results = _run(doc)
    assert len(results) == 6
    assert all(r.passed for r in results), [(r.assertion_idx, r.message) for r in results]
    assert all(r.reduce is None for r in results)
    assert results[0].actual == results[1].actual


def test_run_inline_tests_coords_validation_rejections():
    doc = _decay_doc()
    doc["models"]["M"]["tests"][0]["assertions"] = [
        _coords_assert({"y": 1.0}),
        _coords_assert({"x": 0.4}),  # → index 0
        _coords_assert({"x": 8.6}),  # → index 9
    ]
    results = _run(doc)
    assert len(results) == 3
    assert all(not r.passed and r.actual is None for r in results)
    assert "names unknown dimension 'y'" in results[0].message
    assert "outside 1..8" in results[1].message
    assert "resolves to index 0" in results[1].message
    assert "resolves to index 9" in results[2].message


def test_run_inline_tests_coords_on_scalar_variable_rejected():
    """coords on a scalar (0-D) variable is ill-formed per §6.6.5."""
    doc = {
        "esm": "1.0.0",
        "metadata": {"name": "scalar_coords"},
        "models": {
            "M": {
                "variables": {"z": {"type": "unknown", "units": "1", "default": 1.0}},
                "equations": [{"lhs": {"op": "D", "args": ["z"], "wrt": "t"}, "rhs": 0.0}],
                "tests": [
                    {
                        "id": "scalar",
                        "time_span": {"start": 0.0, "end": 1.0},
                        "assertions": [_coords_assert({"x": 1.0}, time=1.0, var="z")],
                    }
                ],
            }
        },
    }
    results = _run(doc)
    assert len(results) == 1
    assert not results[0].passed
    assert "requires a spatially-shaped variable" in results[0].message


def test_coords_and_reduce_are_mutually_exclusive_at_load():
    from earthsci_ast.parse import SchemaValidationError

    doc = _decay_doc()
    doc["models"]["M"]["tests"][0]["assertions"] = [
        {"variable": "u", "time": 0.0, "expected": 0.0, "coords": {"x": 1}, "reduce": "mean"},
    ]
    with pytest.raises(SchemaValidationError):
        load_string(json.dumps(doc))


def _doc_2d(ny):
    """du_ij/dt = 1 with u(0) = 0, so u(t) = t everywhere: pins the
    strict-subset rule — pinning only `x` is legal iff `y` is singleton."""
    idx = {"op": "index", "args": ["u", "i", "j"]}
    ranges = {"i": [1, 4], "j": [1, ny]}
    return {
        "esm": "1.0.0",
        "metadata": {"name": "pde_inline_2d"},
        "index_sets": {"x": {"kind": "interval", "size": 4}, "y": {"kind": "interval", "size": ny}},
        "models": {
            "M": {
                "variables": {"u": {"type": "unknown", "units": "1", "shape": ["x", "y"]}},
                "equations": [
                    {"lhs": {"op": "ic", "args": ["u"]}, "rhs": 0.0},
                    {
                        "lhs": {
                            "op": "faq",
                            "args": [],
                            "output_idx": ["i", "j"],
                            "ranges": ranges,
                            "expr": {"op": "D", "args": [idx], "wrt": "t"},
                        },
                        "rhs": {
                            "op": "faq",
                            "args": [],
                            "output_idx": ["i", "j"],
                            "ranges": ranges,
                            "expr": 1.0,
                        },
                    },
                ],
                "tests": [
                    {
                        "id": "subset",
                        "time_span": {"start": 0.0, "end": 1.0},
                        "assertions": [
                            _coords_assert({"x": 2}, time=1.0, expected=1.0, abs_tol=1e-8)
                        ],
                    }
                ],
            }
        },
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
    return {
        "variable": "u",
        "time": 0.0,
        "expected": 0.0,
        "tolerance": {"abs": abs_tol},
        "reduce": reduce,
        "reference": ref,
    }


def test_from_file_reference_happy_path(tmp_path):
    from earthsci_ast.inline_tests import simulate_states

    # The binding's own evaluated ic field, so the diff is exactly 0 (the
    # loaded array is used exactly like an evaluated reference field).
    f0 = load_string(json.dumps(_decay_doc()))
    sim0 = simulate_states(f0, (0.0, 1.0), method="LSODA", rtol=1e-12, atol=1e-14, saveat=[0.0])
    vals = [float(sim0.states[0][slot]) for _, slot in state_cells(sim0.var_map, "u", "M")]
    (tmp_path / "ref.json").write_text(json.dumps(vals))
    doc = _decay_doc()
    doc["models"]["M"]["tests"][0]["assertions"] = [
        _from_file_assert({"type": "from_file", "path": "ref.json"}),
        _from_file_assert(
            {"type": "from_file", "path": "ref.json", "format": "json"}, reduce="Linf_error"
        ),
    ]
    prob = tmp_path / "prob.esm"
    prob.write_text(json.dumps(doc))

    # Path input: base_dir defaults to the .esm file's directory.
    results = run_inline_tests(str(prob), model_name="M", method="LSODA", rtol=1e-12, atol=1e-14)
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
        _from_file_assert({"type": "from_file", "path": "short.json"})
    ]
    r = _run(doc, base_dir=str(tmp_path))[0]
    assert not r.passed
    assert "shape mismatch along dimension 1: expected length 8, found 7" in r.message

    # Deeper nesting than the field's rank.
    (tmp_path / "deep.json").write_text(json.dumps([[v] for v in vals]))
    doc["models"]["M"]["tests"][0]["assertions"] = [
        _from_file_assert({"type": "from_file", "path": "deep.json"})
    ]
    r = _run(doc, base_dir=str(tmp_path))[0]
    assert not r.passed
    assert "expected a number" in r.message


def test_from_file_reference_missing_file_and_format(tmp_path):
    doc = _decay_doc()
    doc["models"]["M"]["tests"][0]["assertions"] = [
        _from_file_assert({"type": "from_file", "path": "nope.json"})
    ]
    r = _run(doc, base_dir=str(tmp_path))[0]
    assert not r.passed
    assert "file not found" in r.message

    (tmp_path / "ref.json").write_text("[1, 2, 3, 4, 5, 6, 7, 8]")
    doc["models"]["M"]["tests"][0]["assertions"] = [
        _from_file_assert({"type": "from_file", "path": "ref.json", "format": "netcdf"})
    ]
    r = _run(doc, base_dir=str(tmp_path))[0]
    assert not r.passed
    assert "format 'netcdf' is not supported" in r.message


# ---------------------------------------------------------------------------
# Shared executable fixture (identical input across the three bindings)
# ---------------------------------------------------------------------------


def test_shared_fixture_pde_inline_assertions_exec():
    fixture = FIXTURES_ROOT / "spatial" / "pde_inline_assertions_exec.esm"
    assert fixture.is_file()
    results = run_inline_tests(str(fixture), model_name="M", method="LSODA", rtol=1e-12, atol=1e-14)
    assert len(results) == 7
    assert all(r.passed for r in results), [(r.assertion_idx, r.message) for r in results]
    # The two tie-sampling coords assertions hit the SAME cell.
    assert results[0].actual == results[1].actual
    # integral == mean == 0 for the symmetric cosine field.
    assert abs(results[4].actual) < 1e-12
    # from_file error norms are ~0 against the committed exact snapshot.
    assert results[5].actual < 1e-12
    assert results[6].actual < 1e-12


# ---------------------------------------------------------------------------
# Regression: a SCALAR OBSERVED asserted under per-test parameter_overrides
# must be read from the ASSERTED MODEL's slot and reflect that test's
# overrides — not the first same-bare-name observed of a sibling component.
# ---------------------------------------------------------------------------


def _scalar_observed_doc() -> dict:
    """Two independent components, each with a scalar observed ``k = a·T`` and
    a trivial constant state ``x`` (so the scalar SymPy pathway exposes the
    observed on the trajectory). The bare name ``k`` is shared across ``M1``
    and ``M2`` — flattening qualifies them as ``M1.k`` / ``M2.k``. ``M2`` owns
    the tests; each overrides ``T`` differently, so a correct runner reads
    ``M2.k`` (a=5) and returns ``5·T``."""

    def component(a: float, tests: list) -> dict:
        return {
            "variables": {
                "T": {"type": "parameter", "units": "K", "default": 10.0},
                "a": {"type": "parameter", "units": "1", "default": a},
                "x": {"type": "unknown", "units": "1", "default": 1.0},
                # `k` is an OBSERVED unknown -- what makes it one is the
                # bare-variable-LHS equation below, not a declared type
                # (esm-spec §6.3.1).
                "k": {"type": "unknown", "units": "1"},
            },
            "equations": [
                {"lhs": {"op": "D", "args": ["x"], "wrt": "t"}, "rhs": 0.0},
                {"lhs": "k", "rhs": {"op": "*", "args": ["a", "T"]}},
            ],
            "tests": tests,
        }

    return {
        "esm": "1.0.0",
        "metadata": {"name": "scalar_observed_param_override"},
        "models": {
            # M1 (a=2) is laid out first, so its `k` shadows M2's under a
            # bare-name-only slot match — the exact bug this guards.
            "M1": component(2.0, []),
            "M2": component(
                5.0,
                [
                    {
                        "id": "t_lo",
                        "time_span": {"start": 0.0, "end": 1.0},
                        "parameter_overrides": {"T": 10.0},
                        "assertions": [
                            {
                                "variable": "k",
                                "time": 1.0,
                                "expected": 50.0,
                                "tolerance": {"rel": 1e-9},
                            }
                        ],
                    },
                    {
                        "id": "t_hi",
                        "time_span": {"start": 0.0, "end": 1.0},
                        "parameter_overrides": {"T": 20.0},
                        "assertions": [
                            {
                                "variable": "k",
                                "time": 1.0,
                                "expected": 100.0,
                                "tolerance": {"rel": 1e-9},
                            }
                        ],
                    },
                ],
            ),
        },
    }


def test_run_inline_tests_scalar_observed_tracks_parameter_overrides():
    f = load_string(json.dumps(_scalar_observed_doc()))
    results = run_inline_tests(f, model_name="M2", method="LSODA", rtol=1e-12, atol=1e-14)
    by_id = {r.test_id: r for r in results}
    assert set(by_id) == {"t_lo", "t_hi"}
    # Each test's override must flow through: M2.k = 5·T, distinct per test —
    # not M1.k (=2·T) and not a single shared default value.
    assert by_id["t_lo"].actual == pytest.approx(50.0, rel=1e-9)
    assert by_id["t_hi"].actual == pytest.approx(100.0, rel=1e-9)
    assert by_id["t_lo"].actual != by_id["t_hi"].actual
    assert all(r.passed for r in results), [(r.test_id, r.message) for r in results]


# ---------------------------------------------------------------------------
# Issue #194: reaction-system coverage, the per-document options hook, `cse`
# ---------------------------------------------------------------------------


def _reaction_decay_doc() -> dict:
    """A first-order decay written as a REACTION SYSTEM: A → B at rate k·[A],
    so A(t) = e^{-kt} and B(t) = 1 − e^{-kt} exactly.

    ``reaction_systems`` carries the same ``tests`` member ``models`` does
    (esm-spec §6.6), and the runner iterated ``models`` alone until issue
    #194 — so every assertion of a chemical mechanism was skipped, and
    skipped SILENTLY, since a component that produced no rows is
    indistinguishable in the result list from one that was never looked at."""
    return {
        "esm": "1.0.0",
        "metadata": {"name": "inline_test_reaction_system"},
        "reaction_systems": {
            "Decay": {
                "species": {
                    "A": {"units": "mol/mol", "default": 1.0},
                    "B": {"units": "mol/mol", "default": 0.0},
                },
                "parameters": {"k": {"units": "1/s", "default": 1.0}},
                "reactions": [
                    {
                        "id": "R1",
                        "substrates": [{"species": "A", "stoichiometry": 1}],
                        "products": [{"species": "B", "stoichiometry": 1}],
                        "rate": "k",
                    }
                ],
                "tests": [
                    {
                        "id": "decays",
                        "time_span": {"start": 0.0, "end": 1.0},
                        "assertions": [
                            {
                                "variable": "A",
                                "time": 1.0,
                                "expected": math.exp(-1.0),
                                "tolerance": {"rel": 1e-6},
                            },
                            {
                                "variable": "B",
                                "time": 1.0,
                                "expected": 1.0 - math.exp(-1.0),
                                "tolerance": {"rel": 1e-6},
                            },
                        ],
                    }
                ],
            }
        },
    }


def test_run_inline_tests_covers_reaction_systems():
    f = load_string(json.dumps(_reaction_decay_doc()))
    results = run_inline_tests(f, method="LSODA", rtol=1e-12, atol=1e-14)
    # Two assertions, both from a component that is NOT a `models` entry.
    assert [r.model for r in results] == ["Decay", "Decay"]
    assert [r.variable for r in results] == ["A", "B"]
    assert results[0].actual == pytest.approx(math.exp(-1.0), rel=1e-6)
    assert results[1].actual == pytest.approx(1.0 - math.exp(-1.0), rel=1e-6)
    assert all(r.passed for r in results), [(r.variable, r.message) for r in results]


def _ramp_doc(expected: float, test_overrides: dict | None = None) -> dict:
    """``D(y)/dt = T`` from ``y(0) = 0``, so ``y(1) = T`` exactly whatever
    ``T`` is. The assertion's ``expected`` is therefore a direct read-out of
    the ``T`` the run actually used — which is what makes it a probe for
    where an override came from."""
    test: dict = {
        "id": "ramp",
        "time_span": {"start": 0.0, "end": 1.0},
        "assertions": [
            {"variable": "y", "time": 1.0, "expected": expected, "tolerance": {"rel": 1e-9}}
        ],
    }
    if test_overrides is not None:
        test["parameter_overrides"] = test_overrides
    return {
        "esm": "1.0.0",
        "metadata": {"name": "ramp"},
        "models": {
            "M": {
                "variables": {
                    "T": {"type": "parameter", "units": "1", "default": 1.0},
                    "y": {"type": "unknown", "units": "1", "default": 0.0},
                },
                "equations": [{"lhs": {"op": "D", "args": ["y"], "wrt": "t"}, "rhs": "T"}],
                "tests": [test],
            }
        },
    }


def test_run_inline_tests_options_for_is_consulted_per_document(tmp_path):
    """The issue's key ask: site policy lives in the CALLER. Two documents in
    one directory, each needing a different parameter, and one callback that
    knows which is which — with nothing document-specific reaching this
    module."""
    (tmp_path / "a.esm").write_text(json.dumps(_ramp_doc(3.0)))
    (tmp_path / "b.esm").write_text(json.dumps(_ramp_doc(7.0)))
    seeds = {"a.esm": 3.0, "b.esm": 7.0}

    def options_for(path):
        return InlineTestOptions(
            method="LSODA",
            rtol=1e-12,
            atol=1e-14,
            parameter_overrides={"T": seeds[os.path.basename(path)]},
        )

    # A DIRECTORY expands to the .esm files under it, sorted.
    results = run_inline_tests(str(tmp_path), options_for=options_for)
    assert len(results) == 2
    assert results[0].actual == pytest.approx(3.0, rel=1e-9)
    assert results[1].actual == pytest.approx(7.0, rel=1e-9)
    assert all(r.passed for r in results), [(r.model, r.message) for r in results]

    # Without the callback both documents run at T's default of 1.0 and both
    # assertions fail — so the callback is load-bearing, not decorative.
    bare = run_inline_tests(str(tmp_path), method="LSODA", rtol=1e-12, atol=1e-14)
    assert not any(r.passed for r in bare)


def test_run_inline_tests_options_seed_yields_to_the_tests_own_override():
    """A seed supplies what the document left unsaid; it never overrules what
    the document said. The test names ``T = 5`` and the caller seeds
    ``T = 99``, so ``y(1)`` must be 5."""
    f = load_string(json.dumps(_ramp_doc(5.0, test_overrides={"T": 5.0})))
    results = run_inline_tests(
        [f],
        options_for=lambda _doc: InlineTestOptions(
            method="LSODA", rtol=1e-12, atol=1e-14, parameter_overrides={"T": 99.0}
        ),
    )
    assert len(results) == 1
    assert results[0].actual == pytest.approx(5.0, rel=1e-9)
    assert results[0].passed, results[0].message


def test_run_inline_tests_cse_false_agrees_with_cse_true():
    """``cse`` reaches the problem builder and is a performance knob only: the
    two runs must agree to the last bit, since neither changes what is
    computed."""
    f = load_string(json.dumps(_decay_doc()))
    on = run_inline_tests(f, model_name="M", method="LSODA", rtol=1e-12, atol=1e-14, cse=True)
    off = run_inline_tests(f, model_name="M", method="LSODA", rtol=1e-12, atol=1e-14, cse=False)
    assert [r.actual for r in on] == [r.actual for r in off]
    assert all(r.passed for r in on + off)


def test_run_inline_tests_batch_records_an_unreadable_document_as_a_row(tmp_path):
    """One bad file must not cost a corpus run every other file's verdicts —
    and must not vanish either, which would be indistinguishable from a
    pass."""
    (tmp_path / "good.esm").write_text(json.dumps(_ramp_doc(1.0)))
    (tmp_path / "bad.esm").write_text("{ not json")
    results = run_inline_tests(str(tmp_path), method="LSODA", rtol=1e-12, atol=1e-14)
    by_test = {r.test_id: r for r in results}
    assert set(by_test) == {"ramp", "<load>"}
    assert by_test["ramp"].passed
    assert not by_test["<load>"].passed
    assert by_test["<load>"].model.endswith("bad.esm")
    assert "load failed" in by_test["<load>"].message

    # A SINGLE document keeps the old behaviour: the load raises.
    with pytest.raises(Exception):  # noqa: B017 — the loader's own error type
        run_inline_tests(str(tmp_path / "bad.esm"))
