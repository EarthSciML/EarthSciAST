"""BuildInspection observability + model-scope keyed-factor resolution.

Python mirror of the Julia tree-walk seams (EarthSciSerialization.jl
``BuildInspection`` / ``_factor_scope``):

1. ``simulate(...; inspect=BuildInspection())`` fills the sink with the named
   build-time products (state-free setup arrays, const-array registry, the
   dependency-ordered observed map) and NEVER changes the simulation — proven
   here by bit-identical trajectories with and without the sink.
2. A RAGGED index set's ``offsets`` / ``values`` keyed factors bind by BARE
   name in the model scope (esm-spec §5.4 / RFC semiring-faq-unified-ir §5.2),
   while flattening prefixes every variable with its owning component path.
   ``ragged_factor_scope`` maps bare factor names to in-scope variables: exact
   name wins, else the unique dot-suffix match at the shallowest namespace
   depth; a genuine ambiguity keeps the name bare so the standard
   unresolved-symbol error surfaces.
3. ``run_pde_tests`` §6.6.5 assertions may target a state-free ARRAY OBSERVED
   (the observed-assertion form): the field is read from the inspection's
   setup arrays.
"""

from __future__ import annotations

import json

import numpy as np
import pytest

from earthsci_toolkit.esm_types import ExprNode
from earthsci_toolkit.numpy_interpreter import (
    EvalContext,
    NumpyInterpreterError,
    eval_expr,
    ragged_factor_scope,
)
from earthsci_toolkit.parse import load
from earthsci_toolkit.pde_inline_tests import run_pde_tests, simulate_states
from earthsci_toolkit.simulation import BuildInspection, simulate


# ---------------------------------------------------------------------------
# ragged_factor_scope — the model-scope keyed-factor resolution rule.
# ---------------------------------------------------------------------------


_RAGGED_SETS = {
    "cells": {"kind": "interval", "size": 2},
    "edges_of_cell": {"kind": "ragged", "of": ["cells"], "offsets": "nedges", "values": "edges"},
}


def test_factor_scope_exact_name_wins() -> None:
    """An exact-name variable wins: no map entry (bare already resolves)."""
    scope = ragged_factor_scope(_RAGGED_SETS, ["nedges", "edges", "M.nedges", "M.edges"])
    assert scope == {}


def test_factor_scope_unique_shallowest_suffix() -> None:
    """The dot-suffix match at the SHALLOWEST depth binds — the model's own
    re-exposed alias, not the mounted subsystem's original."""
    scope = ragged_factor_scope(
        _RAGGED_SETS, ["M.nedges", "M.mesh.nedges", "M.edges", "M.mesh.edges", "M.u"]
    )
    assert scope == {"nedges": "M.nedges", "edges": "M.edges"}


def test_factor_scope_ambiguity_leaves_bare() -> None:
    """Two candidates at the same shallowest depth: no binding (the standard
    unresolved-symbol error then surfaces) — same semantics as the Julia
    tree-walk ``_factor_scope``."""
    scope = ragged_factor_scope(_RAGGED_SETS, ["A.nedges", "B.nedges", "A.edges"])
    assert "nedges" not in scope
    assert scope == {"edges": "A.edges"}


def test_factor_scope_empty_without_ragged_sets() -> None:
    scope = ragged_factor_scope({"cells": {"kind": "interval", "size": 3}}, ["M.nedges"])
    assert scope == {}


def test_ragged_offsets_resolve_through_factor_scope() -> None:
    """A ragged bound's offsets factor resolves through ctx.factor_scope when
    the backing variable carries a flattening namespace prefix."""
    ctx = EvalContext(
        state_layout={"M.nedges": slice(0, 2)},
        state_shapes={"M.nedges": (2,)},
        param_values={},
        observed_values={},
        y=np.array([2.0, 3.0]),
        t=0.0,
        index_sets=dict(_RAGGED_SETS),
        factor_scope={"nedges": "M.nedges"},
    )
    # out[i] = sum_{k=1..nedges[i]} k  ->  [1+2, 1+2+3] = [3, 6]
    node = ExprNode(
        op="aggregate",
        args=[],
        output_idx=["i"],
        expr="k",
        ranges={"i": {"from": "cells"}, "k": {"from": "edges_of_cell", "of": ["i"]}},
    )
    np.testing.assert_allclose(eval_expr(node, ctx), [3.0, 6.0])
    # Without the scope entry the bare name misses — the standard error.
    ctx.factor_scope = {}
    with pytest.raises(NumpyInterpreterError, match="nedges"):
        eval_expr(node, ctx)


# ---------------------------------------------------------------------------
# End-to-end miniature: 2-cell ragged CSR document through simulate /
# run_pde_tests (the MPAS keyed-factor wiring contract, in miniature).
# ---------------------------------------------------------------------------

# Cell valences [2, 3] over 5 edges; edge weights w = [10, 20, 30, 40, 50].
# gathered[i] = sum_{k<=nedges[i]} w[edges[i,k]] -> [10+20, 30+40+50] = [30, 120].
_RAGGED_DOC = {
    "esm": "0.8.0",
    "metadata": {
        "name": "ragged_csr_miniature",
        "description": "2-cell ragged CSR keyed-factor miniature.",
    },
    "index_sets": {
        "cells": {"kind": "interval", "size": 2},
        "edges": {"kind": "interval", "size": 5},
        "maxe": {"kind": "interval", "size": 3},
        "edges_of_cell": {
            "kind": "ragged",
            "of": ["cells"],
            "offsets": "nedges",
            "values": "edges_on_cell",
        },
    },
    "models": {
        "Rag": {
            "variables": {
                "u": {"type": "state", "units": "1", "shape": ["cells"], "default": 0.0},
                "nedges": {
                    "type": "observed",
                    "shape": ["cells"],
                    "expression": {"op": "const", "args": [], "value": [2, 3]},
                },
                "edges_on_cell": {
                    "type": "observed",
                    "shape": ["cells", "maxe"],
                    "expression": {"op": "const", "args": [], "value": [[1, 2, 0], [3, 4, 5]]},
                },
                "w": {
                    "type": "observed",
                    "shape": ["edges"],
                    "expression": {"op": "const", "args": [], "value": [10, 20, 30, 40, 50]},
                },
                "gathered": {
                    "type": "observed",
                    "shape": ["cells"],
                    "expression": {
                        "op": "aggregate",
                        "args": ["w", "edges_on_cell"],
                        "output_idx": ["i"],
                        "ranges": {
                            "i": {"from": "cells"},
                            "k": {"from": "edges_of_cell", "of": ["i"]},
                        },
                        "expr": {
                            "op": "index",
                            "args": ["w", {"op": "index", "args": ["edges_on_cell", "i", "k"]}],
                        },
                    },
                },
            },
            "equations": [
                {
                    "lhs": {"op": "D", "args": ["u"], "wrt": "t"},
                    "rhs": {
                        "op": "aggregate",
                        "args": ["w", "edges_on_cell"],
                        "output_idx": ["i"],
                        "ranges": {
                            "i": {"from": "cells"},
                            "k": {"from": "edges_of_cell", "of": ["i"]},
                        },
                        "expr": {
                            "op": "index",
                            "args": ["w", {"op": "index", "args": ["edges_on_cell", "i", "k"]}],
                        },
                    },
                },
            ],
            "tests": [
                {
                    "id": "ragged_gather",
                    "time_span": {"start": 0.0, "end": 1.0},
                    "assertions": [
                        # u(1) = gathered * 1 (constant RHS integrated from 0);
                        # mean([30, 120]) = 75.
                        {
                            "variable": "u",
                            "time": 1.0,
                            "expected": 75.0,
                            "tolerance": {"abs": 1e-8},
                            "reduce": "mean",
                        },
                        # Observed-assertion form: state-free ARRAY OBSERVED.
                        {
                            "variable": "gathered",
                            "time": 1.0,
                            "expected": 120.0,
                            "tolerance": {"abs": 1e-9},
                            "reduce": "max",
                        },
                        {
                            "variable": "gathered",
                            "time": 1.0,
                            "expected": 30.0,
                            "tolerance": {"abs": 1e-9},
                            "reduce": "min",
                        },
                    ],
                },
            ],
        }
    },
}


def test_ragged_csr_simulation_namespaced_factors() -> None:
    """The flattened doc namespaces nedges -> Rag.nedges; the ragged bound and
    the values gather still evaluate (keyed factors bind by bare name)."""
    file = load(json.dumps(_RAGGED_DOC))
    sim = simulate_states(file, (0.0, 1.0), method="LSODA", rtol=1e-10, atol=1e-12, saveat=[1.0])
    u = [sim.states[-1][sim.var_map[f"Rag.u[{i}]"]] for i in (1, 2)]
    np.testing.assert_allclose(u, [30.0, 120.0], rtol=1e-8)


def test_run_pde_tests_observed_array_assertions() -> None:
    """§6.6.5 assertions on a state-free ARRAY OBSERVED evaluate through the
    build-inspection setup arrays (max/min of `gathered`)."""
    file = load(json.dumps(_RAGGED_DOC))
    results = run_pde_tests(file, model_name="Rag", method="LSODA", rtol=1e-10, atol=1e-12)
    assert len(results) == 3
    for r in results:
        assert r.passed, f"{r.variable} {r.reduce}: {r.message}"
    by_reduce = {(r.variable, r.reduce): r.actual for r in results}
    assert by_reduce[("gathered", "max")] == pytest.approx(120.0)
    assert by_reduce[("gathered", "min")] == pytest.approx(30.0)


# ---------------------------------------------------------------------------
# BuildInspection — filled products + zero-behaviour-change guarantee.
# ---------------------------------------------------------------------------


def test_build_inspection_fills_setup_arrays_and_observed_exprs() -> None:
    file = load(json.dumps(_RAGGED_DOC))
    insp = BuildInspection()
    result = simulate(file, (0.0, 1.0), method="LSODA", rtol=1e-10, atol=1e-12, inspect=insp)
    assert result.success
    # Every state-free array observed is exposed under its flattened name.
    for name in ("Rag.nedges", "Rag.edges_on_cell", "Rag.w", "Rag.gathered"):
        assert name in insp.setup_arrays, sorted(insp.setup_arrays)
    np.testing.assert_allclose(insp.setup_arrays["Rag.gathered"], [30.0, 120.0])
    np.testing.assert_allclose(insp.setup_arrays["Rag.nedges"], [2.0, 3.0])
    # The observed substitution map covers every observed equation.
    assert set(insp.observed_exprs) >= {"Rag.nedges", "Rag.edges_on_cell", "Rag.w", "Rag.gathered"}


def test_build_inspection_never_changes_the_simulation() -> None:
    """The returned trajectory is bit-identical with and without `inspect`."""
    file = load(json.dumps(_RAGGED_DOC))
    plain = simulate(file, (0.0, 1.0), method="LSODA", rtol=1e-10, atol=1e-12)
    inspected = simulate(
        load(json.dumps(_RAGGED_DOC)),
        (0.0, 1.0),
        method="LSODA",
        rtol=1e-10,
        atol=1e-12,
        inspect=BuildInspection(),
    )
    assert plain.success and inspected.success
    assert plain.vars == inspected.vars
    np.testing.assert_array_equal(plain.t, inspected.t)
    np.testing.assert_array_equal(plain.y, inspected.y)


def test_build_inspection_default_is_empty_and_optional() -> None:
    insp = BuildInspection()
    assert insp.setup_arrays == {} and insp.const_arrays == {}
    assert insp.observed_exprs == {}
