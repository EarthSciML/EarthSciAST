"""End-to-end tests for simulate() consuming a FlattenedSystem.

These cover the new spec-§4.7.5 contract: simulate() routes through flatten()
and rejects PDE inputs with UnsupportedDimensionalityError.
"""

import numpy as np
import pytest

pytest.importorskip("scipy")  # the simulate path requires scipy

from earthsci_toolkit.esm_types import (
    EsmFile,
    Equation,
    ExprNode,
    Metadata,
    Model,
    ModelVariable,
    Parameter,
    Reaction,
    ReactionSystem,
    Species,
)
from earthsci_toolkit.flatten import (
    UnsupportedDimensionalityError,
    flatten,
)
from earthsci_toolkit.simulation import simulate
from earthsci_toolkit.sympy_bridge import _compile_flat_rhs


def _metadata() -> Metadata:
    return Metadata(title="test")


def _decay_file() -> EsmFile:
    species_a = Species(name="A", default=1.0)
    species_b = Species(name="B", default=0.0)
    k = Parameter(name="k", value=0.5)
    reaction = Reaction(
        name="decay",
        reactants={"A": 1.0},
        products={"B": 1.0},
        rate_constant=0.5,
    )
    rs = ReactionSystem(
        name="Decay",
        species=[species_a, species_b],
        parameters=[k],
        reactions=[reaction],
    )
    return EsmFile(version="0.1.0", metadata=_metadata(), reaction_systems={"Decay": rs})


# ----------------------------------------------------------------------------
# simulate(esm_file) routes through flatten()
# ----------------------------------------------------------------------------


def test_simulate_esm_file_runs_through_flatten():
    file = _decay_file()
    result = simulate(
        file,
        tspan=(0.0, 5.0),
        parameters={},
        initial_conditions={"A": 1.0, "B": 0.0},
        method="RK45",
    )
    assert result.success, f"simulate() failed: {result.message}"
    # State variables are dot-namespaced.
    assert "Decay.A" in result.vars
    assert "Decay.B" in result.vars
    a_idx = result.vars.index("Decay.A")
    b_idx = result.vars.index("Decay.B")
    # A decays, B grows, mass is conserved.
    assert result.y[a_idx, -1] < result.y[a_idx, 0]
    assert result.y[b_idx, -1] > result.y[b_idx, 0]
    total = result.y[a_idx, :] + result.y[b_idx, :]
    assert np.allclose(total, 1.0, atol=1e-5)


# ----------------------------------------------------------------------------
# simulate(flatten(esm_file)) gives the same result
# ----------------------------------------------------------------------------


def test_simulate_flatten_round_trip_matches_esm_file_path():
    file = _decay_file()
    initial = {"A": 1.0, "B": 0.0}

    via_file = simulate(
        file, tspan=(0.0, 5.0), parameters={}, initial_conditions=initial, method="RK45"
    )
    via_flat = simulate(
        flatten(file), tspan=(0.0, 5.0), parameters={}, initial_conditions=initial, method="RK45"
    )

    assert via_file.success and via_flat.success
    assert via_file.vars == via_flat.vars
    # Same final state to numerical tolerance — both paths use the same RHS.
    assert np.allclose(via_file.y[:, -1], via_flat.y[:, -1], atol=1e-9)


# ----------------------------------------------------------------------------
# PDE rejection: simulate() raises on spatial independent variables
# ----------------------------------------------------------------------------


def test_simulate_rejects_pde_systems():
    """A model with an unlowered spatial operator should raise
    UnsupportedDimensionalityError carrying the uniform `unlowered_operator`
    code (esm-spec §4.2 / §9.6.8), superseding the old per-binding code."""
    var_u = ModelVariable(type="state", default=0.0)
    eq = Equation(
        lhs=ExprNode(op="D", args=["u"], wrt="t"),
        rhs=ExprNode(op="grad", args=["u"], dim="x"),
    )
    model = Model(name="Adv", variables={"u": var_u}, equations=[eq])
    file = EsmFile(version="0.1.0", metadata=_metadata(), models={"Adv": model})

    with pytest.raises(UnsupportedDimensionalityError) as excinfo:
        simulate(file, tspan=(0.0, 1.0))

    msg = str(excinfo.value)
    assert excinfo.value.code == "unlowered_operator"
    assert "unlowered_operator" in msg
    assert "spatial" in msg.lower()


# ----------------------------------------------------------------------------
# Models with explicit ODEs (no reaction system) work
# ----------------------------------------------------------------------------


def test_simulate_works_for_pure_ode_model():
    """A Model with explicit equations (no reactions) should run end-to-end."""
    var_x = ModelVariable(type="state", default=2.0)
    var_k = ModelVariable(type="parameter", default=0.3)
    eq = Equation(
        lhs=ExprNode(op="D", args=["x"], wrt="t"),
        rhs=ExprNode(op="*", args=[ExprNode(op="-", args=["k"]), "x"]),
    )
    model = Model(name="Decay", variables={"x": var_x, "k": var_k}, equations=[eq])
    file = EsmFile(version="0.1.0", metadata=_metadata(), models={"Decay": model})

    result = simulate(
        file,
        tspan=(0.0, 5.0),
        initial_conditions={"x": 2.0},
        method="RK45",
    )
    assert result.success, f"simulate() failed: {result.message}"
    idx = result.vars.index("Decay.x")
    # Analytical solution: x(t) = 2*exp(-0.3*t); at t=5 → 2*exp(-1.5) ≈ 0.4463.
    assert abs(result.y[idx, -1] - 2.0 * np.exp(-1.5)) < 1e-3


# ----------------------------------------------------------------------------
# Compile cache: repeated simulate() on the same FlattenedSystem reuses the
# lambdified RHS instead of recompiling. Different parameter overrides hit
# the cache because parameters are runtime args, not inlined into expressions.
# ----------------------------------------------------------------------------


def test_simulate_caches_compiled_rhs_across_calls():
    flat = flatten(_decay_file())

    # First call populates the cache.
    assert getattr(flat, "_simulate_compile_cache", None) is None
    r1 = simulate(flat, tspan=(0.0, 1.0), initial_conditions={"A": 1.0, "B": 0.0})
    assert r1.success
    cache_after_first = flat._simulate_compile_cache
    assert cache_after_first is not None

    # Second call must reuse the same compiled functions (identity check).
    r2 = simulate(flat, tspan=(0.0, 1.0), initial_conditions={"A": 1.0, "B": 0.0})
    assert r2.success
    assert flat._simulate_compile_cache is cache_after_first
    assert flat._simulate_compile_cache.rhs_vector_func is cache_after_first.rhs_vector_func


def test_simulate_cache_survives_parameter_overrides():
    # Pure-ODE model where k is referenced symbolically in the equation,
    # so a parameter override observably changes the trajectory.
    var_x = ModelVariable(type="state", default=1.0)
    var_k = ModelVariable(type="parameter", default=0.3)
    eq = Equation(
        lhs=ExprNode(op="D", args=["x"], wrt="t"),
        rhs=ExprNode(op="*", args=[ExprNode(op="-", args=["k"]), "x"]),
    )
    model = Model(name="Decay", variables={"x": var_x, "k": var_k}, equations=[eq])
    file = EsmFile(version="0.1.0", metadata=_metadata(), models={"Decay": model})
    flat = flatten(file)

    # Prime the cache with one set of parameters.
    r1 = simulate(flat, tspan=(0.0, 1.0), parameters={"k": 0.5}, initial_conditions={"x": 1.0})
    compile1 = flat._simulate_compile_cache
    assert r1.success and compile1 is not None

    # A different parameter override must not invalidate the compiled RHS:
    # parameter values are passed as runtime arguments, not inlined.
    r2 = simulate(flat, tspan=(0.0, 1.0), parameters={"k": 2.0}, initial_conditions={"x": 1.0})
    assert r2.success
    assert flat._simulate_compile_cache is compile1

    # And the parameter change must actually affect the trajectory.
    x_idx = r1.vars.index("Decay.x")
    # Larger k means faster decay, so r2's x should fall further.
    assert r2.y[x_idx, -1] < r1.y[x_idx, -1] - 1e-3


def test_compile_flat_rhs_returns_parametric_form():
    """_compile_flat_rhs returns vector functions taking states + parameters."""
    flat = flatten(_decay_file())
    compiled = _compile_flat_rhs(flat)

    assert "Decay.A" in compiled.state_names
    assert "Decay.B" in compiled.state_names
    assert "Decay.k" in compiled.parameter_names

    # rhs_vector_func signature: state args followed by parameter args.
    n_states = len(compiled.state_names)
    n_params = len(compiled.parameter_names)
    args = [1.0] * n_states + [0.5] * n_params
    out = compiled.rhs_vector_func(*args)
    assert len(out) == n_states


# ----------------------------------------------------------------------------
# Public ``cse`` kwarg (esm-7tw): downstream consumers (e.g. ESM's inline-test
# runner) need to drive simulate() with cse=False without hand-building
# _CompiledRhs to flip the lambdify flag.
# ----------------------------------------------------------------------------


def test_simulate_accepts_cse_kwarg_and_matches_default():
    """simulate(..., cse=False) produces the same trajectory as the default."""
    flat = flatten(_decay_file())
    r_default = simulate(flat, tspan=(0.0, 1.0), initial_conditions={"A": 1.0, "B": 0.0})
    r_no_cse = simulate(
        flat,
        tspan=(0.0, 1.0),
        initial_conditions={"A": 1.0, "B": 0.0},
        cse=False,
    )
    assert r_default.success and r_no_cse.success
    a_idx = r_default.vars.index("Decay.A")
    assert abs(r_default.y[a_idx, -1] - r_no_cse.y[a_idx, -1]) < 1e-8


def test_simulate_caches_cse_true_and_false_independently():
    """Flipping cse must not invalidate the other compile's cache."""
    flat = flatten(_decay_file())

    simulate(flat, tspan=(0.0, 1.0), initial_conditions={"A": 1.0, "B": 0.0})
    cse_true_cache = flat._simulate_compile_cache
    assert cse_true_cache is not None
    assert getattr(flat, "_simulate_compile_cache_no_cse", None) is None

    simulate(
        flat,
        tspan=(0.0, 1.0),
        initial_conditions={"A": 1.0, "B": 0.0},
        cse=False,
    )
    cse_false_cache = flat._simulate_compile_cache_no_cse
    assert cse_false_cache is not None
    # cse=True cache untouched.
    assert flat._simulate_compile_cache is cse_true_cache
    # The two compiles produce different lambdified callables.
    assert cse_false_cache.rhs_vector_func is not cse_true_cache.rhs_vector_func


def test_compile_flat_rhs_cse_false_skips_lambdify_cse():
    """_compile_flat_rhs(flat, cse=False) is the documented bypass for the
    lambdify CSE pass and stores its result under a separate cache attribute."""
    flat = flatten(_decay_file())
    compiled = _compile_flat_rhs(flat, cse=False)
    assert compiled is flat._simulate_compile_cache_no_cse
    # And the legacy attribute is reserved for the cse=True compile.
    assert getattr(flat, "_simulate_compile_cache", None) is None
