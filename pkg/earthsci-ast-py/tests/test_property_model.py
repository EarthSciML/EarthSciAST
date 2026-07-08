"""Property-based tests for model flattening + simulation (gt-3aql).

Phase 3 of the cross-binding fuzzing initiative (gt-72z). Phase 1
(``test_property_expression.py``) fuzzed the expression round-trip. This
module extends the approach to the next layer: *whole models*. We generate
small valid scalar ODE models and assert:

  1. Flatten is deterministic — ``flatten(m)`` called twice on the same input
     produces the same :class:`FlattenedSystem`.
  2. Flatten is stable under the JSON round-trip —
     ``flatten(m) == flatten(load(save(m)))`` structurally.
  3. Flatten is idempotent (the phase-3 invariant). Because ``flatten`` has
     signature ``EsmFile -> FlattenedSystem``, we express the property by
     reconstructing a single-model EsmFile from the flattened output and
     asserting that a second flatten pass reproduces the same system
     structurally. (See :func:`_flat_to_esm` for the reconstruction.)
  4. Simulation equivalence — for a curated subset of generated models that
     simulate without numerical blow-up, ``simulate(m)`` and
     ``simulate(flatten(m))`` agree within solver tolerance. This confirms the
     two entry points into the simulation pipeline remain interchangeable.

Scope (matches the gt-3aql brief): scalar-only models, 1-3 state variables,
0-2 parameters, no domains, no couplings, no spatial operators. The RHS
generator is a deliberately restricted subset of the full expression strategy
used in phase 1 — we need expressions that (a) reference only declared
variables so the model passes structural validation on round-trip and
(b) remain numerically tame enough to simulate.
"""

from __future__ import annotations

import copy
import json
import math
from collections import OrderedDict
from typing import List

import pytest

hypothesis = pytest.importorskip("hypothesis")
pytest.importorskip("scipy")  # simulate() path needs scipy

import numpy as np
from hypothesis import HealthCheck, assume, given, settings, strategies as st

from earthsci_ast.esm_types import (
    EsmFile,
    Equation,
    Expr,
    ExprNode,
    Metadata,
    Model,
    ModelVariable,
)
from earthsci_ast.flatten import FlattenedSystem, flatten
from earthsci_ast.parse import load
from earthsci_ast.serialize import _serialize_expression, save
from earthsci_ast.simulation import simulate


# ---------------------------------------------------------------------------
# Atomic strategies
# ---------------------------------------------------------------------------

# Identifier strategy for local variable names. We exclude ``t`` (reserved as
# the independent variable) and keep names short so they stay readable in any
# failing Hypothesis example.
_ident = st.from_regex(r"\A[a-z][a-z0-9]{0,3}\Z", fullmatch=True).filter(lambda s: s != "t")

# Model names use a single capital-prefixed identifier. Kept separate from the
# variable space so we never accidentally alias a variable and its parent model.
_model_name = st.from_regex(r"\A[A-Z][a-z]{1,4}\Z", fullmatch=True)

# Finite numeric literals small enough to keep simulate() in a well-behaved
# regime. The phase-1 strategy uses [-1e9, 1e9]; that range is fine for
# parse/serialize round-trips, but larger magnitudes invite overflow once the
# expression is fed to a stiff solver.
_literal_float = st.floats(
    min_value=-4.0,
    max_value=4.0,
    allow_nan=False,
    allow_infinity=False,
    width=64,
)
_literal_int = st.integers(min_value=-4, max_value=4)
_literal = st.one_of(_literal_int, _literal_float)


# ---------------------------------------------------------------------------
# RHS expression strategy (restricted, references a fixed pool of names)
# ---------------------------------------------------------------------------


def _safe_rhs_strategy(names: List[str]) -> st.SearchStrategy:
    """Generate a scalar expression that references only ``names``.

    The operator set is deliberately narrow:
      - n-ary ``+``, ``*`` (with at most 3 operands)
      - binary / unary ``-``
      - ``sin`` / ``cos`` (globally bounded, never blow up)

    Division, exponentiation, logs, and ``sqrt`` are excluded: they pose
    domain-restriction problems (``x/0``, ``log(-1)``, ``(-1)**0.5``) that
    would force us to carry numeric-safety predicates through the generator.
    The phase-1 file already exercises those operators for *parse* round-trip
    — the point here is to test flatten + simulate, so the operator surface
    can be smaller.
    """
    if not names:
        # Degenerate: constant-only expressions. Still useful for the flatten
        # invariants, since they don't depend on any variable being defined.
        leaf = _literal
    else:
        leaf = st.one_of(_literal, st.sampled_from(names))

    def _extend(child: st.SearchStrategy) -> st.SearchStrategy:
        return st.one_of(
            st.lists(child, min_size=2, max_size=3).map(lambda args: ExprNode(op="+", args=args)),
            st.lists(child, min_size=2, max_size=3).map(lambda args: ExprNode(op="*", args=args)),
            # unary and binary minus
            child.map(lambda a: ExprNode(op="-", args=[a])),
            st.tuples(child, child).map(lambda ab: ExprNode(op="-", args=list(ab))),
            # globally bounded transcendentals
            child.map(lambda a: ExprNode(op="sin", args=[a])),
            child.map(lambda a: ExprNode(op="cos", args=[a])),
        )

    return st.recursive(leaf, _extend, max_leaves=4)


# ---------------------------------------------------------------------------
# Model strategy
# ---------------------------------------------------------------------------


@st.composite
def _scalar_model_file(draw) -> EsmFile:
    """Generate a single-model EsmFile with 1-3 state vars and 0-2 params.

    Each state variable gets exactly one ``D(state, t) = rhs`` equation where
    ``rhs`` is drawn from :func:`_safe_rhs_strategy` over the union of declared
    state + parameter names.
    """
    n_states = draw(st.integers(min_value=1, max_value=3))
    n_params = draw(st.integers(min_value=0, max_value=2))

    # Draw names with uniqueness to avoid collisions in the model's variable
    # dictionary.
    all_names = draw(
        st.lists(_ident, min_size=n_states + n_params, max_size=n_states + n_params, unique=True)
    )
    state_names = all_names[:n_states]
    param_names = all_names[n_states:]

    variables: "OrderedDict[str, ModelVariable]" = OrderedDict()
    for name in state_names:
        variables[name] = ModelVariable(
            type="state",
            default=draw(
                st.floats(
                    min_value=0.1,
                    max_value=2.0,
                    allow_nan=False,
                    allow_infinity=False,
                    width=64,
                )
            ),
        )
    for name in param_names:
        variables[name] = ModelVariable(
            type="parameter",
            default=draw(
                st.floats(
                    min_value=-1.0,
                    max_value=1.0,
                    allow_nan=False,
                    allow_infinity=False,
                    width=64,
                )
            ),
        )

    rhs_strategy = _safe_rhs_strategy(list(variables.keys()))
    equations: List[Equation] = []
    for sname in state_names:
        rhs = draw(rhs_strategy)
        equations.append(
            Equation(
                lhs=ExprNode(op="D", args=[sname], wrt="t"),
                rhs=rhs,
            )
        )

    model_name = draw(_model_name)
    model = Model(name=model_name, variables=dict(variables), equations=equations)
    return EsmFile(
        version="0.1.0",
        metadata=Metadata(title="property-test"),
        models={model_name: model},
    )


# ---------------------------------------------------------------------------
# Structural comparison helpers
# ---------------------------------------------------------------------------


def _flat_signature(flat: FlattenedSystem) -> dict:
    """Canonical, JSON-serializable fingerprint of a FlattenedSystem.

    Two FlattenedSystems are considered structurally equal iff their
    signatures compare equal. We normalize the variable OrderedDicts to plain
    dicts of type labels (values are metadata that we don't want to enforce
    here — names + types + equations are the structural invariant).
    """

    def _eqn_sig(eq) -> dict:
        return {
            "lhs": _serialize_expression(eq.lhs),
            "rhs": _serialize_expression(eq.rhs),
            "source_system": eq.source_system,
        }

    return {
        "independent_variables": sorted(flat.independent_variables),
        "state_variables": {name: fv.type for name, fv in flat.state_variables.items()},
        "parameters": {name: fv.type for name, fv in flat.parameters.items()},
        "observed": {name: fv.type for name, fv in flat.observed_variables.items()},
        "equations": [_eqn_sig(e) for e in flat.equations],
    }


def _sig_equal(a: FlattenedSystem, b: FlattenedSystem) -> bool:
    return json.dumps(_flat_signature(a), sort_keys=True) == json.dumps(
        _flat_signature(b), sort_keys=True
    )


# ---------------------------------------------------------------------------
# FlattenedSystem -> EsmFile reconstruction (used by the idempotence test)
# ---------------------------------------------------------------------------


def _is_number(x) -> bool:
    return isinstance(x, (int, float)) and not isinstance(x, bool)


def _strip_namespace(expr: Expr, prefix: str) -> Expr:
    """Remove ``prefix`` from every variable reference inside ``expr``.

    Mirrors the dual of :func:`earthsci_ast.flatten._namespace_expr`.
    Used by :func:`_flat_to_esm` to de-namespace the flattened equations so a
    re-flatten pass will re-apply exactly the same prefix.
    """
    if expr is None or _is_number(expr):
        return expr
    if isinstance(expr, str):
        return expr[len(prefix) :] if expr.startswith(prefix) else expr
    if isinstance(expr, ExprNode):
        return ExprNode(
            op=expr.op,
            args=[_strip_namespace(a, prefix) for a in expr.args],
            wrt=expr.wrt,
            dim=expr.dim,
            output_idx=expr.output_idx,
            expr=_strip_namespace(expr.expr, prefix) if expr.expr is not None else None,
            reduce=expr.reduce,
            ranges=expr.ranges,
            regions=expr.regions,
            values=(
                [_strip_namespace(v, prefix) for v in expr.values]
                if expr.values is not None
                else None
            ),
            shape=expr.shape,
            perm=expr.perm,
            axis=expr.axis,
            fn=expr.fn,
        )
    return expr


def _flat_to_esm(flat: FlattenedSystem) -> EsmFile:
    """Rebuild an ``EsmFile`` that flattens back to ``flat``.

    For every flattened variable we look up its source system, strip the
    ``<system>.`` prefix from the name, and rebuild a :class:`Model` keyed by
    the system name. Equations are similarly de-namespaced so that the next
    :func:`flatten` pass re-applies the exact same prefix.

    Limitations (acceptable for the phase-3 scope):
      - Only state and parameter variables are reconstructed. Flattened
        "species" from reaction systems are left out; the strategy in this
        module never produces them.
      - Couplings are not preserved. The scalar-only generator in this file
        never produces couplings.
    """
    systems_vars: "OrderedDict[str, OrderedDict[str, ModelVariable]]" = OrderedDict()
    systems_eqs: "OrderedDict[str, list]" = OrderedDict()

    def _collect(name: str, fv, vtype: str) -> None:
        sys = fv.source_system or name.split(".", 1)[0]
        local = name[len(sys) + 1 :] if name.startswith(sys + ".") else name
        systems_vars.setdefault(sys, OrderedDict())[local] = ModelVariable(
            type=vtype,
            units=fv.units,
            default=fv.default,
            description=fv.description,
        )
        systems_eqs.setdefault(sys, [])

    for name, fv in flat.state_variables.items():
        _collect(name, fv, "state")
    for name, fv in flat.parameters.items():
        _collect(name, fv, "parameter")
    for name, fv in flat.observed_variables.items():
        _collect(name, fv, "observed")

    for feq in flat.equations:
        systems_eqs.setdefault(feq.source_system, []).append(feq)

    models: "OrderedDict[str, Model]" = OrderedDict()
    for sys_name, local_vars in systems_vars.items():
        prefix = sys_name + "."
        equations = [
            Equation(
                lhs=_strip_namespace(feq.lhs, prefix),
                rhs=_strip_namespace(feq.rhs, prefix),
            )
            for feq in systems_eqs.get(sys_name, [])
        ]
        models[sys_name] = Model(
            name=sys_name,
            variables=dict(local_vars),
            equations=equations,
        )

    return EsmFile(
        version="0.1.0",
        metadata=Metadata(title="reconstructed"),
        models=dict(models),
    )


# ---------------------------------------------------------------------------
# Hypothesis settings
# ---------------------------------------------------------------------------


# 30 examples / property keeps the suite under ~30s even with the simulate
# property, which is the slowest. Bump via ``--hypothesis-seed`` or
# ``PYTEST_ADDOPTS=-o python_functions=test_*`` when investigating.
_settings = settings(
    max_examples=30,
    deadline=None,
    suppress_health_check=[HealthCheck.too_slow, HealthCheck.data_too_large],
)


# ---------------------------------------------------------------------------
# Properties
# ---------------------------------------------------------------------------


@given(_scalar_model_file())
@_settings
def test_flatten_deterministic(esm_file: EsmFile) -> None:
    """``flatten(m)`` twice must produce structurally identical results."""
    flat_a = flatten(esm_file)
    # Deep-copy the input to defend against any hidden aliasing that would
    # let flatten mutate-and-return the same object.
    flat_b = flatten(copy.deepcopy(esm_file))
    assert _sig_equal(flat_a, flat_b)


@given(_scalar_model_file())
@_settings
def test_flatten_stable_under_json_round_trip(esm_file: EsmFile) -> None:
    """Serializing + reloading a model must not change its flattened form."""
    json_str = save(esm_file)
    try:
        reloaded = load(json_str)
    except Exception:  # pragma: no cover — surface as a Hypothesis shrink case
        pytest.fail(
            "Hypothesis-generated model failed to JSON round-trip "
            "(should be a clean failure rather than silently discarded). "
            f"Model: {esm_file}"
        )
    assert _sig_equal(flatten(esm_file), flatten(reloaded))


@given(_scalar_model_file())
@_settings
def test_flatten_idempotent(esm_file: EsmFile) -> None:
    """Phase-3 idempotence: flatten is a fixed point under reconstruction.

    ``flatten`` has signature ``EsmFile -> FlattenedSystem``. To state
    idempotence over that signature we reconstruct a single-model EsmFile
    from the flattened output (see :func:`_flat_to_esm`) and verify the
    second flatten pass reproduces the first's signature.
    """
    flat_once = flatten(esm_file)
    rebuilt = _flat_to_esm(flat_once)
    flat_twice = flatten(rebuilt)
    assert _sig_equal(flat_once, flat_twice)


@given(_scalar_model_file())
@_settings
def test_simulate_matches_simulate_via_flatten(esm_file: EsmFile) -> None:
    """For numerically tame generated models, ``simulate(m)`` and
    ``simulate(flatten(m))`` agree within solver tolerance.

    The sim equivalence is a curated-subset invariant. Hypothesis will
    occasionally produce a combination of constants, trigonometrics, and
    parameters that stiffens the solver or produces an essentially infinite
    trajectory — we filter those out with ``assume()``. We're asserting that
    *when both paths succeed* they agree, not that every generated model is
    simulable.
    """
    tspan = (0.0, 0.5)
    initial = {
        f"{m.name}.{vname}": 1.0
        for m in esm_file.models.values()
        for vname, v in m.variables.items()
        if v.type == "state"
    }

    via_file = simulate(esm_file, tspan=tspan, initial_conditions=initial, method="RK45")
    via_flat = simulate(flatten(esm_file), tspan=tspan, initial_conditions=initial, method="RK45")

    # Both paths must agree on success. If simulate() fails on one side it
    # must fail on the other — divergent success would be a real bug.
    assert via_file.success == via_flat.success

    assume(via_file.success and via_flat.success)
    # Drop trajectories that integrated into overflow territory. The comparison
    # is meaningless if either side diverged.
    assume(np.all(np.isfinite(via_file.y)))
    assume(np.all(np.isfinite(via_flat.y)))

    assert via_file.vars == via_flat.vars
    # Both paths use the same RHS, so the final state should be identical to
    # floating-point precision. We permit a small tolerance to accommodate any
    # reordering of operations inside the two entry points.
    assert np.allclose(via_file.y[:, -1], via_flat.y[:, -1], atol=1e-9, rtol=1e-9)


# ---------------------------------------------------------------------------
# Targeted regressions — hand-written fixtures derived from Hypothesis shrinks
# ---------------------------------------------------------------------------


def test_flatten_idempotent_multi_state_decay() -> None:
    """A two-state coupled decay round-trips through reconstruction."""
    model = Model(
        name="Chem",
        variables={
            "A": ModelVariable(type="state", default=1.0),
            "B": ModelVariable(type="state", default=0.5),
            "k": ModelVariable(type="parameter", default=0.3),
        },
        equations=[
            Equation(
                lhs=ExprNode(op="D", args=["A"], wrt="t"),
                rhs=ExprNode(op="*", args=[ExprNode(op="-", args=["k"]), "A"]),
            ),
            Equation(
                lhs=ExprNode(op="D", args=["B"], wrt="t"),
                rhs=ExprNode(op="*", args=["k", "A"]),
            ),
        ],
    )
    esm_file = EsmFile(
        version="0.1.0",
        metadata=Metadata(title="regression"),
        models={"Chem": model},
    )
    flat_once = flatten(esm_file)
    flat_twice = flatten(_flat_to_esm(flat_once))
    assert _sig_equal(flat_once, flat_twice)
    # Sanity: the reconstruction actually produced the flat names.
    assert "Chem.A" in flat_twice.state_variables
    assert "Chem.B" in flat_twice.state_variables
    assert "Chem.k" in flat_twice.parameters


def test_simulate_matches_simulate_via_flatten_linear_decay() -> None:
    """Regression: a known analytical solution for the simulate equivalence."""
    model = Model(
        name="Decay",
        variables={
            "x": ModelVariable(type="state", default=1.0),
            "k": ModelVariable(type="parameter", default=0.5),
        },
        equations=[
            Equation(
                lhs=ExprNode(op="D", args=["x"], wrt="t"),
                rhs=ExprNode(op="*", args=[ExprNode(op="-", args=["k"]), "x"]),
            ),
        ],
    )
    esm_file = EsmFile(
        version="0.1.0",
        metadata=Metadata(title="regression"),
        models={"Decay": model},
    )

    via_file = simulate(
        esm_file, tspan=(0.0, 2.0), initial_conditions={"Decay.x": 1.0}, method="RK45"
    )
    via_flat = simulate(
        flatten(esm_file), tspan=(0.0, 2.0), initial_conditions={"Decay.x": 1.0}, method="RK45"
    )

    assert via_file.success and via_flat.success
    idx = via_file.vars.index("Decay.x")
    # Analytical: x(2) = exp(-1) ≈ 0.3679.
    assert abs(via_file.y[idx, -1] - math.exp(-1.0)) < 1e-3
    assert np.allclose(via_file.y[:, -1], via_flat.y[:, -1], atol=1e-9)
