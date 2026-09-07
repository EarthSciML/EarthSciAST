"""A DECLARED ``shape`` is what makes a variable an array — not the spelling of
its defining equation (issue #231).

``_choose_pathway`` used to read array-ness out of EQUATION CONTENT alone: a
``providers`` / ``const_arrays`` injection, a ``loader_fields`` seam, or an
``index`` / ``aggregate`` / ``arrayop`` node somewhere in an equation. A
document whose only array-ness is a declared ``shape`` — a bare whole-array
``D(theta) ~ 1`` over ``"shape": ["lev"]``, with no array op anywhere — routed
to the SCALAR (SymPy) pathway, where the shaped state got no cells at all and a
``coords`` assertion could not find it. Rewriting the identical semantics in the
``aggregate`` spelling routed to the array pathway and worked, so the SPELLING,
not the model, decided the answer.

esm-spec §6.3 makes ``shape`` — "the ordered list of index-set names the
variable is arrayed over" — the authoritative statement of array-ness, and §11
already treats it as authoritative over usage inference inside the array build
(``_build_numpy_rhs`` resolves declared shapes against the ``index_sets``
registry before it lays out the state vector). These tests pin the routing at
the same authority, including the two cases the arm must NOT change: a shape it
cannot resolve, and a genuinely scalar document.

The coverage is deliberately Python-LOCAL rather than a shared conformance
fixture: the bare whole-array spelling is not supported by every binding today
(see issue #232 for the Julia side), so a shared fixture pinning it would fail
bindings this fix says nothing about.
"""

from __future__ import annotations

import json

import numpy as np
import pytest

from earthsci_ast.parse import load_path
from earthsci_ast.pde_inline_tests import run_pde_tests
from earthsci_ast.problem import esm_problem, solve

# The issue's minimal reproducer, verbatim in substance: no parameters at all,
# so it cannot be confused with the shaped-PARAMETER defect of #219 / #229.
BARE = {
    "esm": "1.0.0",
    "metadata": {"name": "BareShapedNoParams", "authors": ["repro"]},
    "index_sets": {"lev": {"kind": "interval", "size": 4}},
    "models": {
        "Column": {
            "variables": {
                "theta": {"type": "unknown", "units": "K", "default": 1.0, "shape": ["lev"]}
            },
            "equations": [{"lhs": {"op": "D", "args": ["theta"], "wrt": "t"}, "rhs": 1.0}],
            "tests": [
                {
                    "id": "theta_ramps",
                    "time_span": {"start": 0.0, "end": 1.0},
                    "assertions": [
                        {
                            "variable": "theta",
                            "time": 1.0,
                            "coords": {"lev": 2},
                            "expected": 2.0,
                        }
                    ],
                }
            ],
        }
    },
}

# The SAME semantics in the `aggregate` spelling — the one the corpus already
# drives, because it is the one every executing binding routes to its array
# runtime. `_has_array_op` sees the aggregate, so this routed to the array
# pathway even before the fix.
AGGREGATE = {
    "esm": "1.0.0",
    "metadata": {"name": "AggregateShapedNoParams", "authors": ["repro"]},
    "index_sets": {"lev": {"kind": "interval", "size": 4}},
    "models": {
        "Column": {
            "variables": {
                "theta": {"type": "unknown", "units": "K", "default": 1.0, "shape": ["lev"]}
            },
            "equations": [
                {
                    "lhs": {
                        "op": "aggregate",
                        "args": [],
                        "output_idx": ["k"],
                        "expr": {
                            "op": "D",
                            "args": [{"op": "index", "args": ["theta", "k"]}],
                            "wrt": "t",
                        },
                        "ranges": {"k": {"from": "lev"}},
                    },
                    "rhs": {
                        "op": "aggregate",
                        "args": [],
                        "output_idx": ["k"],
                        "expr": 1.0,
                        "ranges": {"k": {"from": "lev"}},
                    },
                }
            ],
            "tests": [
                {
                    "id": "theta_ramps",
                    "time_span": {"start": 0.0, "end": 1.0},
                    "assertions": [
                        {
                            "variable": "theta",
                            "time": 1.0,
                            "coords": {"lev": 2},
                            "expected": 2.0,
                        }
                    ],
                }
            ],
        }
    },
}

# The related symptom the issue records: a shaped PARAMETER carrying inline
# array data (§6.3 "Inline array data") on the same bare spelling. The scalar
# pathway detects a value it cannot bind and says so explicitly, so the routing
# gap shows up in the error text rather than in a missing cell.
BARE_INLINE_ARRAY_PARAM = {
    "esm": "1.0.0",
    "metadata": {"name": "BareShapedInlineArrayParam", "authors": ["repro"]},
    "index_sets": {"lev": {"kind": "interval", "size": 4}},
    "models": {
        "Column": {
            "variables": {
                "theta": {"type": "unknown", "units": "K", "default": 0.0, "shape": ["lev"]},
                "ramp": {
                    "type": "parameter",
                    "units": "K/s",
                    "shape": ["lev"],
                    "default": [1.0, 2.0, 3.0, 4.0],
                },
            },
            "equations": [{"lhs": {"op": "D", "args": ["theta"], "wrt": "t"}, "rhs": "ramp"}],
        }
    },
}

# A declared shape whose axes name NO index-set registry entry. The array build
# would fall back to usage inference here and infer exactly the scalar the
# scalar pathway already runs, so routing on it would change the engine without
# changing the answer — the arm must leave this document alone.
UNRESOLVABLE_SHAPE = {
    "esm": "1.0.0",
    "metadata": {"name": "UnresolvableShape", "authors": ["repro"]},
    "models": {
        "Column": {
            "variables": {
                "theta": {"type": "unknown", "units": "K", "default": 1.0, "shape": ["lev"]}
            },
            "equations": [{"lhs": {"op": "D", "args": ["theta"], "wrt": "t"}, "rhs": 1.0}],
        }
    },
}

# No shape anywhere: still the lambdified SymPy pathway.
PLAIN_SCALAR = {
    "esm": "1.0.0",
    "metadata": {"name": "PlainScalar", "authors": ["repro"]},
    "models": {
        "Box": {
            "variables": {"c": {"type": "unknown", "units": "1", "default": 1.0}},
            "equations": [{"lhs": {"op": "D", "args": ["c"], "wrt": "t"}, "rhs": 1.0}],
        }
    },
}


def _write(tmp_path, doc, name):
    path = tmp_path / name
    path.write_text(json.dumps(doc))
    return str(path)


def test_bare_whole_array_derivative_over_a_declared_shape_routes_to_the_array_pathway(tmp_path):
    """The issue's reproducer: ``pathway`` was ``"scalar"``, and the shaped
    state had no cells at all."""
    path = _write(tmp_path, BARE, "bare.esm.json")

    prob = esm_problem(path, (0.0, 1.0))
    assert prob.pathway == "array"

    # The state really is arrayed now — four cells, one per `lev`, not one
    # scalar slot. This is what the `coords` assertion needs to exist.
    assert prob.build is not None
    layout = prob.build.state_layout["Column.theta"]
    assert layout.stop - layout.start == 4


def test_the_bare_spelling_passes_its_inline_coords_assertion(tmp_path):
    """``run_pde_tests`` reported ``array state 'theta' has no cells in
    var_map``; ``D(theta) ~ 1`` from ``theta(0) = 1`` must reach 2.0 at t=1."""
    path = _write(tmp_path, BARE, "bare.esm.json")

    results = run_pde_tests(path)
    assert len(results) == 1
    r = results[0]
    assert r.passed, r.message
    assert r.actual == pytest.approx(2.0, rel=1e-6)


def test_the_bare_and_aggregate_spellings_agree(tmp_path):
    """Identical semantics, two spellings: both route to the array pathway and
    produce the same number. The spelling must not decide the answer."""
    bare = _write(tmp_path, BARE, "bare.esm.json")
    agg = _write(tmp_path, AGGREGATE, "agg.esm.json")

    assert esm_problem(bare, (0.0, 1.0)).pathway == "array"
    assert esm_problem(agg, (0.0, 1.0)).pathway == "array"

    (bare_result,) = run_pde_tests(bare)
    (agg_result,) = run_pde_tests(agg)
    assert bare_result.passed, bare_result.message
    assert agg_result.passed, agg_result.message
    assert bare_result.actual == pytest.approx(agg_result.actual, rel=1e-6)


def test_a_shaped_parameter_with_inline_array_data_binds_on_the_bare_spelling(tmp_path):
    """The related symptom: the scalar pathway refused the §6.3 inline array
    data with ``carries inline ARRAY data ... which this pathway cannot bind``.
    Routing on the declared shape puts the document on the pathway that binds
    it, and each cell integrates its own rate."""
    path = _write(tmp_path, BARE_INLINE_ARRAY_PARAM, "inline.esm.json")

    prob = esm_problem(path, (0.0, 1.0))
    assert prob.pathway == "array"

    sol = solve(prob)
    assert sol.retcode.name == "Success", sol
    # ``sol[name]`` stacks an array state's element rows, so the final field is
    # the last COLUMN: one value per `lev` cell.
    trajectory = np.asarray(sol["Column.theta"])
    assert trajectory.shape[0] == 4
    # theta(0) = 0, D(theta) = ramp, so theta(1) = ramp, cell by cell.
    assert list(trajectory[:, -1]) == pytest.approx([1.0, 2.0, 3.0, 4.0], rel=1e-5, abs=1e-6)


def test_an_unresolvable_declared_shape_still_routes_to_the_scalar_pathway(tmp_path):
    """The arm mirrors ``_build_numpy_rhs``'s own fallback: a shape whose axes
    resolve against no ``index_sets`` entry is not evidence of a concrete
    extent, so the routing is left exactly as it was."""
    path = _write(tmp_path, UNRESOLVABLE_SHAPE, "unresolvable.esm.json")

    assert esm_problem(path, (0.0, 1.0)).pathway == "scalar"


def test_a_document_with_no_shape_anywhere_still_routes_to_the_scalar_pathway(tmp_path):
    """The lambdified SymPy pathway is still where a scalar-only system goes."""
    path = _write(tmp_path, PLAIN_SCALAR, "plain.esm.json")

    assert esm_problem(path, (0.0, 1.0)).pathway == "scalar"


def test_the_shape_arm_reads_states_parameters_and_observeds(tmp_path):
    """``_declares_resolvable_shape`` is the unit under the routing arm; every
    §6.3 variable role carries ``shape``, so it consults all three maps."""
    from earthsci_ast.flatten import flatten
    from earthsci_ast.problem import _declares_resolvable_shape

    assert _declares_resolvable_shape(flatten(load_path(_write(tmp_path, BARE, "b.esm.json"))))
    assert _declares_resolvable_shape(
        flatten(load_path(_write(tmp_path, BARE_INLINE_ARRAY_PARAM, "i.esm.json")))
    )
    assert not _declares_resolvable_shape(
        flatten(load_path(_write(tmp_path, UNRESOLVABLE_SHAPE, "u.esm.json")))
    )
    assert not _declares_resolvable_shape(
        flatten(load_path(_write(tmp_path, PLAIN_SCALAR, "p.esm.json")))
    )
