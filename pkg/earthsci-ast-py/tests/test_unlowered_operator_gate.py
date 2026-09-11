"""The §9.6.3 constraint-6 rewrite-target gate is a WALK, not a reachability test.

esm-spec §9.6.3 constraint 6 words the gate as a whole-tree walk: "before a
component is EVALUATED or COMPILED for simulation, its expression trees are
walked; any node whose ``op`` is not in the evaluable-core set (§4.2) —
including a spatial ``D``, or any ``D`` in a right-hand-side / evaluation
position — is rejected with diagnostic ``unlowered_operator``". §9.6.8 calls it
"the sole guarantee that a rewrite-target op cannot reach evaluation".

Python had no such walk. Both pathways raised ``unlowered_operator``
REACTIVELY, when the evaluator happened to reach the offending node, which made
the gate a property of the ENGINE rather than of the document:

* the scalar-SymPy pathway lambdifies every observed eagerly, so a surviving
  ``div`` in a DEAD observed (one nothing consumes) tripped it;
* the NumPy array pathway evaluates observeds lazily, so it never reached one
  and the same document built and solved.

Which answer you got therefore depended on which engine ``_choose_pathway``
picked — and issue #231's declared-``shape`` routing arm moves documents across
that line. These tests pin the gate at the document, on both pathways.

The gate is deliberately narrow. It rejects a REWRITE-TARGET OP that no rule
lowered; it says nothing about a dead observed whose body is fully lowered.
CONFORMANCE_SPEC §5.27.3 ("a DEAD observed is still an observed") keeps such an
observed READABLE, and ``test_a_dead_but_fully_lowered_observed_is_untouched``
pins that the walk leaves it alone.
"""

from __future__ import annotations

import json

import pytest

from earthsci_ast.numpy_interpreter import UnreachableSpatialOperatorError
from earthsci_ast.problem import esm_problem

# A `div` no rule lowers, sitting in a DEAD observed — `unlowered` is defined
# and never read. The dynamics are a plain scalar ODE, so the SHAPE of the
# document is: everything the engine actually evaluates is fine, and the only
# rewrite-target op is somewhere the evaluator would never go.
DEAD_UNLOWERED_SCALAR = {
    "esm": "1.1.0",
    "metadata": {"name": "DeadUnloweredScalar", "authors": ["repro"]},
    "models": {
        "Box": {
            "variables": {
                "c": {"type": "unknown", "units": "1", "default": 1.0},
                "unlowered": {"type": "unknown", "units": "1"},
            },
            "equations": [
                {"lhs": {"op": "D", "args": ["c"], "wrt": "t"}, "rhs": 1.0},
                {"lhs": "unlowered", "rhs": {"op": "div", "args": ["c"]}},
            ],
        }
    },
}

# The same dead unlowered `div`, but on a document the declared-`shape` arm
# routes to the ARRAY pathway — the pathway whose lazy observed evaluation used
# to let the op through. Under the walk the two pathways agree.
DEAD_UNLOWERED_ARRAY = {
    "esm": "1.1.0",
    "metadata": {"name": "DeadUnloweredArray", "authors": ["repro"]},
    "index_sets": {"lev": {"kind": "interval", "size": 4}},
    "models": {
        "Column": {
            "variables": {
                "theta": {"type": "unknown", "units": "K", "default": 1.0, "shape": ["lev"]},
                "unlowered": {"type": "unknown", "units": "K", "shape": ["lev"]},
            },
            "equations": [
                {"lhs": {"op": "D", "args": ["theta"], "wrt": "t"}, "rhs": 1.0},
                {"lhs": "unlowered", "rhs": {"op": "div", "args": ["theta"]}},
            ],
        }
    },
}

# A dead observed whose body is FULLY LOWERED. Nothing reads `diagnostic`, and
# that is fine: §5.27.3 says a dead observed is still an observed. The walk must
# not touch it — it gates rewrite-target OPS, not deadness.
DEAD_BUT_LOWERED = {
    "esm": "1.1.0",
    "metadata": {"name": "DeadButLowered", "authors": ["repro"]},
    "models": {
        "Box": {
            "variables": {
                "c": {"type": "unknown", "units": "1", "default": 1.0},
                "diagnostic": {"type": "unknown", "units": "1"},
            },
            "equations": [
                {"lhs": {"op": "D", "args": ["c"], "wrt": "t"}, "rhs": 1.0},
                {"lhs": "diagnostic", "rhs": {"op": "*", "args": ["c", 2.0]}},
            ],
        }
    },
}

# The array-level spelling puts a STRUCTURAL time `D` under an `aggregate` on
# the equation LHS. An LHS `D(wrt: "t")` is evaluable-core (§4.2) — it names the
# differentiated state and is never evaluated — and `args` of an LHS node are
# still LHS, so the walk must let this through however deeply it nests.
AGGREGATE_LHS_DERIVATIVE = {
    "esm": "1.1.0",
    "metadata": {"name": "AggregateLhsDerivative", "authors": ["repro"]},
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
        }
    },
}


def _write(tmp_path, doc, name):
    path = tmp_path / name
    path.write_text(json.dumps(doc))
    return str(path)


@pytest.mark.parametrize(
    ("doc", "name"),
    [(DEAD_UNLOWERED_SCALAR, "scalar"), (DEAD_UNLOWERED_ARRAY, "array")],
    ids=["scalar-pathway-document", "array-pathway-document"],
)
def test_a_dead_observed_carrying_an_unlowered_op_is_rejected_on_either_pathway(
    tmp_path, doc, name
):
    """The document, not the engine, decides. The array-pathway case is the one
    that used to build and solve because nothing ever evaluated the dead body."""
    path = _write(tmp_path, doc, f"{name}.esm.json")

    with pytest.raises(UnreachableSpatialOperatorError) as excinfo:
        esm_problem(path, (0.0, 1.0))

    assert excinfo.value.code == "unlowered_operator"
    assert excinfo.value.op == "div"


def test_a_dead_but_fully_lowered_observed_is_untouched(tmp_path):
    """CONFORMANCE_SPEC §5.27.3: a dead observed is still an observed. The walk
    gates rewrite-target OPS, not deadness, so this still builds."""
    path = _write(tmp_path, DEAD_BUT_LOWERED, "lowered.esm.json")

    prob = esm_problem(path, (0.0, 1.0))

    assert prob.pathway == "scalar"


def test_a_structural_time_derivative_under_an_lhs_aggregate_is_still_core(tmp_path):
    """`D(wrt: "t")` on an equation LHS is evaluable-core wherever it sits in
    that tree — otherwise the array-level spelling would stop building."""
    path = _write(tmp_path, AGGREGATE_LHS_DERIVATIVE, "agg.esm.json")

    prob = esm_problem(path, (0.0, 1.0))

    assert prob.pathway == "array"


def test_the_gate_fires_before_any_engine_is_chosen(tmp_path):
    """It is a FRONT-DOOR walk: the rejection happens at ``esm_problem``
    construction, not at ``solve``, so no build of either kind is attempted."""
    path = _write(tmp_path, DEAD_UNLOWERED_ARRAY, "front.esm.json")

    with pytest.raises(UnreachableSpatialOperatorError):
        esm_problem(path, (0.0, 1.0))
