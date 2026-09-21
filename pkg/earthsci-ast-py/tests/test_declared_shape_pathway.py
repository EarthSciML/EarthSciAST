"""A DECLARED ``shape`` is what makes a variable an array — not the spelling of
its defining equation (issue #231), and no longer what decides which machinery
builds the document either.

The defect these tests were written for: ``_choose_pathway`` read array-ness out
of EQUATION CONTENT alone, so a document whose only array-ness is a declared
``shape`` — a bare whole-array ``D(theta) ~ 1`` over ``"shape": ["lev"]``, with
no array op anywhere — went to the SCALAR (SymPy) pathway, where the shaped
state got no cells at all and a ``coords`` assertion could not find it. The
identical semantics in the ``faq`` spelling went to the array pathway and
worked, so the SPELLING, not the model, decided the answer.

The router is now gone. ``API_SPEC.md`` §5.8 makes the choice of machinery the
caller's (``compiler=``) and esm-libraries-spec §2.5.10 forbids a binding
switching strategy inside ``native`` on document content at all, so the defect's
whole CLASS is closed: every document here builds with the same vectorized NumPy
machinery, whatever its shape declarations say. These tests keep the two claims
that outlive the router — a declared ``shape`` gives the variable real CELLS in
the layout, and the two spellings produce the same number — and add the one the
new rule brings: a scalar document and a shaped one are built alike.

``_declares_resolvable_shape`` survives as the authority ``compiler="sympy"``
refuses an array document on, which is the one place array-ness still selects
anything, so its unit coverage stays.

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
from earthsci_ast.inline_tests import run_inline_tests
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
    "esm": "1.1.0",
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
                        "op": "faq",
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
                        "op": "faq",
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

# ONLY an OBSERVED declares a resolvable shape: the state is scalar, there is no
# parameter, and no equation carries an array op. This is the third of the §6.3
# roles the arm consults, and it is a real supported path rather than a latent
# one — ``_build_numpy_rhs`` resolves declared shapes for observeds through the
# SAME resolver the routing arm reads, so routing and layout agree.
OBSERVED_ONLY_SHAPE = {
    "esm": "1.0.0",
    "metadata": {"name": "ObservedOnlyShape", "authors": ["repro"]},
    "index_sets": {"lev": {"kind": "interval", "size": 4}},
    "models": {
        "Column": {
            "variables": {
                "c": {"type": "unknown", "units": "1", "default": 1.0},
                "flux": {"type": "unknown", "units": "1", "shape": ["lev"]},
            },
            "equations": [
                {"lhs": {"op": "D", "args": ["c"], "wrt": "t"}, "rhs": 1.0},
                {"lhs": "flux", "rhs": {"op": "*", "args": ["c", 2.0]}},
            ],
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


def test_bare_whole_array_derivative_over_a_declared_shape_lays_out_as_an_array(tmp_path):
    """The issue's reproducer: the shaped state had no cells at all."""
    path = _write(tmp_path, BARE, "bare.esm.json")

    prob = esm_problem(path, (0.0, 1.0))
    assert prob.compiler == "native"

    # The state really is arrayed — four cells, one per `lev`, not one scalar
    # slot. This is what the `coords` assertion needs to exist.
    assert prob.build is not None
    layout = prob.build.state_layout["Column.theta"]
    assert layout.stop - layout.start == 4


def test_the_bare_spelling_passes_its_inline_coords_assertion(tmp_path):
    """``run_inline_tests`` reported ``array state 'theta' has no cells in
    var_map``; ``D(theta) ~ 1`` from ``theta(0) = 1`` must reach 2.0 at t=1."""
    path = _write(tmp_path, BARE, "bare.esm.json")

    results = run_inline_tests(path)
    assert len(results) == 1
    r = results[0]
    assert r.passed, r.message
    assert r.actual == pytest.approx(2.0, rel=1e-6)


def test_the_bare_and_aggregate_spellings_agree(tmp_path):
    """Identical semantics, two spellings: built by the same machinery, and the
    same number comes out. The spelling must not decide the answer."""
    bare = _write(tmp_path, BARE, "bare.esm.json")
    agg = _write(tmp_path, AGGREGATE, "agg.esm.json")

    bare_prob = esm_problem(bare, (0.0, 1.0))
    agg_prob = esm_problem(agg, (0.0, 1.0))
    assert bare_prob.compiler == agg_prob.compiler == "native"
    assert bare_prob.engine == agg_prob.engine

    (bare_result,) = run_inline_tests(bare)
    (agg_result,) = run_inline_tests(agg)
    assert bare_result.passed, bare_result.message
    assert agg_result.passed, agg_result.message
    assert bare_result.actual == pytest.approx(agg_result.actual, rel=1e-6)


def test_a_shaped_parameter_with_inline_array_data_binds_on_the_bare_spelling(tmp_path):
    """The related symptom: the SymPy tier refused the §6.3 inline array data
    with ``carries inline ARRAY data ... which this pathway cannot bind``. The
    vectorized NumPy machinery binds it, and each cell integrates its own
    rate — and under a strict `native` that machinery is what every document
    gets, so the symptom has nowhere left to occur."""
    path = _write(tmp_path, BARE_INLINE_ARRAY_PARAM, "inline.esm.json")

    prob = esm_problem(path, (0.0, 1.0))
    assert prob.build is not None

    sol = solve(prob)
    assert sol.retcode.name == "Success", sol
    # ``sol[name]`` stacks an array state's element rows, so the final field is
    # the last COLUMN: one value per `lev` cell.
    trajectory = np.asarray(sol["Column.theta"])
    assert trajectory.shape[0] == 4
    # theta(0) = 0, D(theta) = ramp, so theta(1) = ramp, cell by cell.
    assert list(trajectory[:, -1]) == pytest.approx([1.0, 2.0, 3.0, 4.0], rel=1e-5, abs=1e-6)


def test_an_unresolvable_declared_shape_is_not_a_routing_signal_and_is_refused(tmp_path):
    """The arm mirrors ``_build_numpy_rhs``'s own fallback: a shape whose axes
    resolve against no ``index_sets`` entry is not evidence of a concrete
    extent, so it does not route the document to the array pathway.

    Nor may the build lay ``theta`` out as one scalar slot: ``lev`` names no
    registry entry and no equation indexes ``theta``, so it has no extent at
    all. ``esm_problem`` refuses it, as Julia and Rust do (issue #249)."""
    from earthsci_ast.flatten import flatten
    from earthsci_ast.problem import _declares_resolvable_shape
    from earthsci_ast.sympy_bridge import SimulationError

    path = _write(tmp_path, UNRESOLVABLE_SHAPE, "unresolvable.esm.json")

    assert not _declares_resolvable_shape(flatten(load_path(path)))
    with pytest.raises(SimulationError, match="E_REF_UNDECLARED_INDEX_SET"):
        esm_problem(path, (0.0, 1.0))


def test_a_scalar_document_and_a_shaped_one_are_built_by_the_same_machinery(tmp_path):
    """The rule that replaced the router (esm-libraries-spec §2.5.10).

    A binding "MUST NOT switch strategy inside ``native`` on document content: a
    scalar document and a gridded one are built by the same machinery, so that
    what ran is a property of the name and not of the input". That is the whole
    defect class this file was opened for, closed at the root rather than at one
    of its symptoms: there is no longer a content test that could send these two
    documents to different engines.
    """
    plain = esm_problem(_write(tmp_path, PLAIN_SCALAR, "plain.esm.json"), (0.0, 1.0))
    shaped = esm_problem(_write(tmp_path, BARE, "bare.esm.json"), (0.0, 1.0))

    assert plain.compiler == shaped.compiler == "native"
    assert plain.engine == shaped.engine == "array"
    assert plain.build is not None and shaped.build is not None
    assert plain.scalar_build is None and shaped.scalar_build is None


def test_the_lambdified_scalar_form_is_still_reachable_by_name(tmp_path):
    """`compiler="sympy"` is where the lambdified scalar right-hand side went:
    still available, now asked for rather than inferred."""
    path = _write(tmp_path, PLAIN_SCALAR, "plain.esm.json")

    prob = esm_problem(path, (0.0, 1.0), compiler="sympy")
    assert prob.engine == "scalar"
    assert prob.scalar_build is not None


def test_the_shape_arm_reads_states_parameters_and_observeds(tmp_path):
    """``_declares_resolvable_shape`` is the unit that now decides whether
    ``compiler="sympy"`` refuses a document as arrayed; every §6.3 variable role
    carries ``shape``, so it consults all three maps."""
    from earthsci_ast.flatten import flatten
    from earthsci_ast.problem import _declares_resolvable_shape

    assert _declares_resolvable_shape(flatten(load_path(_write(tmp_path, BARE, "b.esm.json"))))
    assert _declares_resolvable_shape(
        flatten(load_path(_write(tmp_path, BARE_INLINE_ARRAY_PARAM, "i.esm.json")))
    )
    # The observed map, whose only shaped variable is an observed: no shaped
    # state, no shaped parameter, no array op anywhere.
    assert _declares_resolvable_shape(
        flatten(load_path(_write(tmp_path, OBSERVED_ONLY_SHAPE, "o.esm.json")))
    )
    assert not _declares_resolvable_shape(
        flatten(load_path(_write(tmp_path, UNRESOLVABLE_SHAPE, "u.esm.json")))
    )
    assert not _declares_resolvable_shape(
        flatten(load_path(_write(tmp_path, PLAIN_SCALAR, "p.esm.json")))
    )


def test_an_observed_only_declared_shape_lays_out_as_an_array(tmp_path):
    """An OBSERVED's declared ``shape`` is authoritative over usage inference.

    ``_declares_resolvable_shape`` reads this document as arrayed on the
    strength of an OBSERVED's declared ``shape``, so ``_build_numpy_rhs``
    has to honour that same declaration: usage inference sees a whole-array body
    (``flux = c * 2``, no ``index`` anywhere) and would give the observed no
    extent at all, which is the under-report §11 makes the declaration
    authoritative over. Before the build learned to resolve observed shapes,
    ``build.shapes`` carried no ``Column.flux`` entry whatsoever.
    """
    path = _write(tmp_path, OBSERVED_ONLY_SHAPE, "observed_only.esm.json")

    prob = esm_problem(path, (0.0, 1.0))
    assert prob.build is not None
    assert prob.build.shapes["Column.flux"] == (4,)
    # The scalar state stays scalar — the declaration is per variable, not a
    # blanket promotion of the whole system.
    assert prob.build.shapes["Column.c"] == ()

    sol = solve(prob)
    assert sol.retcode.name == "Success", sol
    # c(0) = 1, D(c) = 1, so c(1) = 2 and flux = 2c = 4 in every cell.
    assert np.asarray(sol["Column.flux"])[..., -1] == pytest.approx(4.0, rel=1e-5)
