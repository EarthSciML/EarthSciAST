"""Dead-observed tolerance on the NumPy array/PDE simulate path.

An observed variable that no live equation reads (a DEAD observed) whose body
cannot be evaluated must never abort the integration. The Julia reference
tree-walk only evaluates observeds in the state-derivative dependency cone, so it
never touches such a dead observed; the NumPy path must match that
(``_materialize_observeds(..., skip_unresolved=True)`` in both the per-step RHS
driver and the read-only ``BuildInspection`` fill).

The skip only drops an observed nothing consumes: a LIVE observed a driver
equation actually reads still surfaces a clear ``Unresolved symbol`` error when
that equation evaluates (the NumPy interpreter never defaults an unbound name),
so no real defect is masked — see ``test_needed_broken_observed_still_errors``.

**These are RUNTIME pins, and the doc they use is deliberately INVALID.** This
file used to justify its unbound ``NY`` by claiming a passive-axis count closed
at a template-import edge "stays a bare symbol after §9.7 resolution in every
binding". That claim is FALSE: esm-spec §9.7.6 says a metaparameter in an
ordinary *expression position* "is substituted as an integer literal at load"
(``{"op":"/","args":[360,"NLON"]}`` becomes ``{"op":"/","args":[360,144]}``), an
unbound one is ``metaparameter_unbound``, and "validators run on the folded,
expanded form". A bare ``NY`` in an observed expression is therefore simply an
undefined variable, and §4.9.5 reference integrity now correctly REJECTS it at
load (pinned by ``tests/invalid/undefined_variable_in_observed_expression.esm``).

The runtime tolerance is still worth pinning — ``simulate()`` also runs on
programmatically built ``EsmFile`` objects that never pass through ``load()`` —
so these tests build the doc with the structural gate bypassed, and
``test_dead_observed_doc_is_rejected_by_load`` pins the load-time rejection.
"""

from __future__ import annotations

import json

import numpy as np
import pytest

import earthsci_ast.parse as _parse
from earthsci_ast.parse import load
from earthsci_ast.simulation import BuildInspection, simulate


def _load_unvalidated(doc_json: str):
    """``load()`` with the §4.9.5 structural gate bypassed.

    The fixtures below are intentionally invalid documents (an undefined ``NY``
    in an observed expression). Only the RUNTIME behaviour of the array
    evaluator is under test here, so the load-time reference-integrity check —
    which correctly rejects them — is suppressed for the build.
    """
    original = _parse._validate_structural
    _parse._validate_structural = lambda *a, **k: None
    try:
        return _parse.load(doc_json)
    finally:
        _parse._validate_structural = original


def _doc(dead_body):
    """A 3-cell array model ``D(u[i]) = live`` with ``live = k`` (=3) driving the
    state, plus a second observed ``dead`` whose body is ``dead_body``. The
    aggregate/index ops route the run through the NumPy array path (the one the
    passive-axis 2-D cases exercise). ``dead`` is referenced by nothing."""
    return {
        "esm": "0.8.0",
        "metadata": {"name": "DeadObservedFixture"},
        "index_sets": {"cells": {"kind": "interval", "size": 3}},
        "models": {
            "M": {
                "variables": {
                    "u": {"type": "state", "shape": ["cells"], "default": 0.0},
                    "k": {"type": "parameter", "default": 3.0},
                    "live": {"type": "observed", "expression": "k"},
                    "dead": {"type": "observed", "expression": dead_body},
                },
                "equations": [
                    {
                        "lhs": {
                            "op": "aggregate",
                            "args": [],
                            "output_idx": ["i"],
                            "ranges": {"i": {"from": "cells"}},
                            "expr": {
                                "op": "D",
                                "args": [{"op": "index", "args": ["u", "i"]}],
                                "wrt": "t",
                            },
                        },
                        "rhs": {
                            "op": "aggregate",
                            "args": [],
                            "output_idx": ["i"],
                            "ranges": {"i": {"from": "cells"}},
                            "expr": "live",
                        },
                    }
                ],
            }
        },
    }


# The dead observed's body ``1 / NY`` references an unbound symbol NY — exactly
# the shape of a passive-axis ``dy`` once its count is closed at an import edge.
_DEAD_BODY = {"op": "/", "args": [1.0, "NY"]}


def test_dead_unresolvable_observed_does_not_break_array_rhs() -> None:
    """The per-step RHS driver skips the dead ``dead = 1/NY`` and integrates the
    live dynamics (``D(u) = k = 3`` from u(0)=0 gives u(1)=3 in every cell)."""
    result = simulate(
        _load_unvalidated(json.dumps(_doc(_DEAD_BODY))),
        (0.0, 1.0),
        method="LSODA",
        rtol=1e-10,
        atol=1e-12,
    )
    assert result.success, result.message
    final = result.y[:, -1]
    np.testing.assert_allclose(final[:3], [3.0, 3.0, 3.0], rtol=1e-6)


def test_dead_unresolvable_observed_tolerated_by_build_inspection() -> None:
    """``inspect=BuildInspection()`` (the sink the PDE inline-test runner passes)
    must not abort on the dead observed either; it records only array observeds,
    so the unevaluable scalar simply never lands in ``setup_arrays``."""
    insp = BuildInspection()
    result = simulate(
        _load_unvalidated(json.dumps(_doc(_DEAD_BODY))),
        (0.0, 1.0),
        method="LSODA",
        rtol=1e-10,
        atol=1e-12,
        inspect=insp,
    )
    assert result.success, result.message
    assert not any(name.endswith("dead") for name in insp.setup_arrays), sorted(insp.setup_arrays)


def test_inspect_never_changes_the_trajectory_with_a_dead_observed() -> None:
    """The returned trajectory is identical with and without ``inspect`` even
    when a dead unresolvable observed is present (the skip is lossless)."""
    plain = simulate(
        _load_unvalidated(json.dumps(_doc(_DEAD_BODY))),
        (0.0, 1.0),
        method="LSODA",
        rtol=1e-10,
        atol=1e-12,
    )
    inspected = simulate(
        _load_unvalidated(json.dumps(_doc(_DEAD_BODY))),
        (0.0, 1.0),
        method="LSODA",
        rtol=1e-10,
        atol=1e-12,
        inspect=BuildInspection(),
    )
    assert plain.success and inspected.success
    assert plain.vars == inspected.vars
    np.testing.assert_array_equal(plain.y, inspected.y)


def test_needed_broken_observed_still_errors() -> None:
    """Safety pin: the tolerant skip must NOT mask a real defect. When the LIVE
    observed the ODE reads is itself unresolvable, the driver equation that
    consumes it still fails with a clear unresolved-symbol error rather than
    silently producing a wrong trajectory."""
    doc = _doc(_DEAD_BODY)
    # Break the LIVE observed the ODE actually reads.
    doc["models"]["M"]["variables"]["live"]["expression"] = {"op": "/", "args": [1.0, "Z"]}
    result = simulate(
        _load_unvalidated(json.dumps(doc)), (0.0, 1.0), method="LSODA", rtol=1e-10, atol=1e-12
    )
    assert not result.success
    assert "Unresolved symbol" in (result.message or "")
    assert "live" in (result.message or "")


def test_dead_observed_doc_is_rejected_by_load() -> None:
    """The counterpart of the runtime skip: the document above is INVALID, and
    plain ``load()`` must say so. `NY` is an undefined name in an observed
    expression — esm-spec §4.9.5 reference integrity applies to every
    expression-bearing field, not just `equations`."""
    from earthsci_ast.parse import SchemaValidationError

    with pytest.raises(SchemaValidationError) as exc:
        load(json.dumps(_doc(_DEAD_BODY)))
    assert "NY" in str(exc.value)
