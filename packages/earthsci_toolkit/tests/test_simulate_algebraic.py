"""Tests for scalar algebraic-equation elimination in simulate() (esm-y3n).

A model may declare a state variable whose value is determined by an
algebraic equation ``v = body`` rather than by an ODE ``D(v, t) = …``. The
canonical Python simulation runner must:

* Substitute the algebraic body into every other equation that references
  the variable, so the integrator's RHS depends only on the differential
  states (the equivalent of MTK's structural_simplify scalar pass).
* Reconstruct the algebraic value at every output time so the
  SimulationResult exposes correct trajectories for both differential and
  algebraic state variables.
* Reject cyclic algebraic systems with a clear error message.
* Leave pure-ODE models numerically identical to the previous behaviour.
"""

import numpy as np
import pytest

pytest.importorskip("scipy")
pytest.importorskip("sympy")

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
from earthsci_toolkit.simulation import simulate


def _diameter_growth_model() -> EsmFile:
    """Build the Seinfeld & Pandis Fig. 13.2 / Eq. 13.11–13.13 model directly.

    The model has three state variables — ``D_p`` (ODE), ``A`` (algebraic),
    ``I_D`` (algebraic that references ``A`` and ``D_p``) — and exercises
    every part of the elimination pipeline.
    """
    variables = {
        "R_gas": ModelVariable(type="parameter", default=8.314),
        "T": ModelVariable(type="parameter", default=298.0),
        "D_diff": ModelVariable(type="parameter", default=1.0e-5),
        "M_i": ModelVariable(type="parameter", default=0.1),
        "ρ_p": ModelVariable(type="parameter", default=1000.0),
        "Δp": ModelVariable(type="parameter", default=1.0e-4),
        "D_p": ModelVariable(type="state", default=2.0e-7),
        "I_D": ModelVariable(type="state"),
        "A": ModelVariable(type="state"),
    }

    eq_dDp = Equation(
        lhs=ExprNode(op="D", args=["D_p"], wrt="t"),
        rhs="I_D",
    )
    eq_A = Equation(
        lhs="A",
        rhs=ExprNode(
            op="/",
            args=[
                ExprNode(op="*", args=[4, "D_diff", "M_i", "Δp"]),
                ExprNode(op="*", args=["R_gas", "T", "ρ_p"]),
            ],
        ),
    )
    eq_ID = Equation(
        lhs="I_D",
        rhs=ExprNode(op="/", args=["A", "D_p"]),
    )

    model = Model(
        name="DiameterGrowthRate",
        variables=variables,
        equations=[eq_dDp, eq_A, eq_ID],
    )
    return EsmFile(
        version="0.1.0",
        metadata=Metadata(title="DiameterGrowthRate"),
        models={"DiameterGrowthRate": model},
    )


def test_simulate_eliminates_algebraic_states_diameter_growth():
    """``D_p[end]`` must be within 1% of the analytical 6.538e-7 m target."""
    file = _diameter_growth_model()
    result = simulate(
        file,
        tspan=(0.0, 1200.0),
        parameters={},
        initial_conditions={"D_p": 2.0e-7},
        method="LSODA",
    )
    assert result.success, f"simulate() failed: {result.message}"

    dp_idx = result.vars.index("DiameterGrowthRate.D_p")
    final_dp = result.y[dp_idx, -1]
    expected = 6.538165842082e-7
    rel_err = abs(final_dp - expected) / expected
    assert rel_err < 0.01, (
        f"D_p(t=1200) = {final_dp:.6e}, expected {expected:.6e} (rel err {rel_err:.3%})"
    )


def test_simulate_recovers_algebraic_values_at_output():
    """Algebraic states must track their formula along the trajectory."""
    file = _diameter_growth_model()
    result = simulate(
        file,
        tspan=(0.0, 1200.0),
        parameters={},
        initial_conditions={"D_p": 2.0e-7},
        method="LSODA",
    )
    assert result.success

    a_idx = result.vars.index("DiameterGrowthRate.A")
    id_idx = result.vars.index("DiameterGrowthRate.I_D")
    dp_idx = result.vars.index("DiameterGrowthRate.D_p")

    # A is constant (depends only on parameters): every sample equals the
    # closed-form value within solver round-off.
    expected_A = 4 * 1.0e-5 * 0.1 * 1.0e-4 / (8.314 * 298.0 * 1000.0)
    assert np.allclose(result.y[a_idx, :], expected_A, rtol=1e-10, atol=0.0)

    # I_D = A / D_p must hold pointwise.
    expected_id = expected_A / result.y[dp_idx, :]
    assert np.allclose(result.y[id_idx, :], expected_id, rtol=1e-10, atol=0.0)


def test_simulate_rejects_cyclic_algebraic_equations():
    """A self-referential / mutually-cyclic algebraic system must error out."""
    variables = {
        "X": ModelVariable(type="state", default=0.0),
        "Y": ModelVariable(type="state", default=0.0),
        "Z": ModelVariable(type="state", default=0.0),
    }
    eq_dz = Equation(
        lhs=ExprNode(op="D", args=["Z"], wrt="t"),
        rhs=1.0,
    )
    eq_x = Equation(lhs="X", rhs=ExprNode(op="+", args=["Y", 1.0]))
    eq_y = Equation(lhs="Y", rhs=ExprNode(op="+", args=["X", 1.0]))

    model = Model(
        name="Cyclic",
        variables=variables,
        equations=[eq_dz, eq_x, eq_y],
    )
    file = EsmFile(
        version="0.1.0",
        metadata=Metadata(title="Cyclic"),
        models={"Cyclic": model},
    )

    result = simulate(
        file,
        tspan=(0.0, 1.0),
        parameters={},
        initial_conditions={},
        method="LSODA",
    )
    assert not result.success
    assert "Cyclic algebraic equations detected" in result.message


def test_simulate_same_lhs_dae_alias_eliminates_to_unbound_state():
    """A single source system may author two algebraic equations with the same
    LHS — e.g. ``K = f(T)`` AND ``K = [H+] * [OH-]`` — as a legitimate DAE.
    The simulator must rewrite the second equation into an alias for the
    unbound state on its RHS (here ``[OH-] = K / [H+]``). Mirrors the
    structural shape of components/aerosol/aq_eq/water.esm."""
    variables = {
        "T": ModelVariable(type="parameter", default=298.0),
        "H_plus": ModelVariable(type="parameter", default=1.0e-4),
        "K_w_298": ModelVariable(type="parameter", default=1.0e-8),
        "K_w": ModelVariable(type="state"),
        "OH_minus": ModelVariable(type="state"),
    }
    eq_K_temp = Equation(lhs="K_w", rhs="K_w_298")
    eq_K_product = Equation(
        lhs="K_w",
        rhs=ExprNode(op="*", args=["H_plus", "OH_minus"]),
    )
    model = Model(
        name="Eq",
        variables=variables,
        equations=[eq_K_temp, eq_K_product],
    )
    file = EsmFile(
        version="0.1.0",
        metadata=Metadata(title="EquilibriumDAE"),
        models={"Eq": model},
    )

    result = simulate(
        file,
        tspan=(0.0, 1.0),
        parameters={"T": 298.0, "H_plus": 1.0e-4},
        initial_conditions={},
    )
    assert result.success, f"simulate() failed: {result.message}"

    k_idx = result.vars.index("Eq.K_w")
    oh_idx = result.vars.index("Eq.OH_minus")
    assert np.isclose(result.y[k_idx, 0], 1.0e-8, rtol=1e-10)
    # OH_minus = K_w / H_plus = 1e-8 / 1e-4 = 1e-4
    assert np.isclose(result.y[oh_idx, 0], 1.0e-4, rtol=1e-10)


def test_simulate_pure_ode_model_unaffected_by_algebraic_pass():
    """A reaction system with no algebraic equations must integrate as before."""
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
    file = EsmFile(
        version="0.1.0",
        metadata=Metadata(title="decay"),
        reaction_systems={"Decay": rs},
    )

    result = simulate(
        file,
        tspan=(0.0, 5.0),
        parameters={},
        initial_conditions={"A": 1.0, "B": 0.0},
        method="RK45",
    )
    assert result.success, f"simulate() failed: {result.message}"

    a_idx = result.vars.index("Decay.A")
    b_idx = result.vars.index("Decay.B")
    total = result.y[a_idx, :] + result.y[b_idx, :]
    assert np.allclose(total, 1.0, atol=1e-5)
    # Closed-form decay: A(t) = exp(-k t).
    assert np.isclose(result.y[a_idx, -1], np.exp(-0.5 * 5.0), rtol=1e-3)


def test_simulate_observed_only_model_emits_observed_trajectories():
    """A model with zero state variables but observed bindings (e.g. the
    cloud_albedo two-stream scaffold) must still simulate cleanly: the
    runner samples the observed bodies on a synthetic time grid so inline
    tests can assert against R_c / γ (esm-97q)."""
    variables = {
        "tau_c": ModelVariable(type="parameter", default=10.0),
        "g": ModelVariable(type="parameter", default=0.85),
        "gamma": ModelVariable(
            type="observed",
            expression=ExprNode(
                op="/",
                args=[
                    2,
                    ExprNode(
                        op="*",
                        args=[
                            1.7320508075688772,
                            ExprNode(
                                op="+",
                                args=[
                                    1,
                                    ExprNode(op="*", args=[-1, "g"]),
                                ],
                            ),
                        ],
                    ),
                ],
            ),
        ),
        "R_c": ModelVariable(
            type="observed",
            expression=ExprNode(
                op="/",
                args=[
                    "tau_c",
                    ExprNode(op="+", args=["tau_c", "gamma"]),
                ],
            ),
        ),
    }
    model = Model(name="CloudAlbedo", variables=variables, equations=[])
    file = EsmFile(
        version="0.1.0",
        metadata=Metadata(title="cloud_albedo"),
        models={"CloudAlbedo": model},
    )

    result = simulate(
        file,
        tspan=(0.0, 1.0),
        parameters={"tau_c": 10.0, "g": 0.85},
        initial_conditions={},
    )
    assert result.success, f"simulate() failed: {result.message}"

    assert "CloudAlbedo.gamma" in result.vars
    assert "CloudAlbedo.R_c" in result.vars

    g_idx = result.vars.index("CloudAlbedo.gamma")
    rc_idx = result.vars.index("CloudAlbedo.R_c")
    # γ ≈ 7.698 and R_c(τ=10) ≈ 0.5650 are the upstream Aerosol.jl
    # Figure 24.16 reference values.
    assert np.isclose(result.y[g_idx, 0], 7.698003589195009, rtol=1e-12)
    assert np.isclose(result.y[rc_idx, 0], 0.5650354826521339, rtol=1e-12)
    # Constant-in-time: end-of-tspan sample matches t=0 sample.
    assert np.isclose(result.y[g_idx, -1], result.y[g_idx, 0])
    assert np.isclose(result.y[rc_idx, -1], result.y[rc_idx, 0])


def test_simulate_state_plus_observed_emits_observed_alongside_states():
    """A model with both differential states and observed bindings must
    expose both in the result vector. The observed expression may legally
    reference the independent variable ``t``."""
    variables = {
        "k": ModelVariable(type="parameter", default=0.5),
        "C": ModelVariable(type="state", default=1.0),
        "C_analytical": ModelVariable(
            type="observed",
            expression=ExprNode(
                op="exp",
                args=[ExprNode(op="*", args=[-1, "k", "t"])],
            ),
        ),
    }
    eq_dC = Equation(
        lhs=ExprNode(op="D", args=["C"], wrt="t"),
        rhs=ExprNode(op="*", args=[-1, "k", "C"]),
    )
    model = Model(name="Decay", variables=variables, equations=[eq_dC])
    file = EsmFile(
        version="0.1.0",
        metadata=Metadata(title="decay"),
        models={"Decay": model},
    )

    result = simulate(
        file,
        tspan=(0.0, 2.0),
        parameters={"k": 0.5},
        initial_conditions={"C": 1.0},
    )
    assert result.success, f"simulate() failed: {result.message}"

    c_idx = result.vars.index("Decay.C")
    a_idx = result.vars.index("Decay.C_analytical")
    # Numerical state and analytical observed agree at every output time.
    assert np.allclose(result.y[c_idx, :], result.y[a_idx, :], rtol=1e-3)
    # Time dependence in the observed body is honored: end value equals
    # the closed-form exp(-k * t_end).
    assert np.isclose(result.y[a_idx, -1], np.exp(-0.5 * 2.0), rtol=1e-12)


def test_simulate_observed_referenced_in_diff_rhs_no_namespace_leak():
    """Regression for esm-4id: a differential RHS that references an observed
    variable by its dot-namespaced name (e.g. ``D(NO2) = -j_NO2 * NO2`` where
    ``j_NO2`` is observed) must not leak the observed symbol into the
    lambdified RHS. ``sympy.lambdify`` prints free symbols literally, so a
    leaked ``Decay.j_NO2`` symbol becomes Python attribute access on a
    nonexistent ``Decay`` module — exactly the ``NameError: name 'FastJX' is
    not defined`` reported in fastjx.esm. The fix substitutes (already
    fully-resolved) observed bodies into the differential RHS before lambdify
    so no observed symbol survives as a free reference."""
    variables = {
        "k0": ModelVariable(type="parameter", default=2.0),
        "T": ModelVariable(type="parameter", default=300.0),
        "NO2": ModelVariable(type="state", default=1.0),
        # Observed photolysis rate j_NO2 = k0 / T (depends only on parameters).
        "j_NO2": ModelVariable(
            type="observed",
            expression=ExprNode(op="/", args=["k0", "T"]),
        ),
    }
    eq_dNO2 = Equation(
        lhs=ExprNode(op="D", args=["NO2"], wrt="t"),
        rhs=ExprNode(op="*", args=[-1, "j_NO2", "NO2"]),
    )
    model = Model(name="Decay", variables=variables, equations=[eq_dNO2])
    file = EsmFile(
        version="0.1.0",
        metadata=Metadata(title="namespaced-observed-in-diff-rhs"),
        models={"Decay": model},
    )

    result = simulate(
        file,
        tspan=(0.0, 1.0),
        parameters={"k0": 2.0, "T": 300.0},
        initial_conditions={"NO2": 1.0},
    )
    assert result.success, f"simulate() failed: {result.message}"

    no2_idx = result.vars.index("Decay.NO2")
    j_idx = result.vars.index("Decay.j_NO2")
    # Analytical: NO2(t) = exp(-j*t) with j = k0/T = 2/300 ≈ 0.006667.
    j_expected = 2.0 / 300.0
    assert np.isclose(result.y[j_idx, 0], j_expected, rtol=1e-12)
    assert np.isclose(
        result.y[no2_idx, -1],
        np.exp(-j_expected * 1.0),
        rtol=1e-6,
    )


def test_simulate_deep_algebraic_chain_sequential_evaluation():
    """A 3-level algebraic chain must be evaluated in correct topological order.

    Chain: C = a * b (depends only on params)
           D = C * x  (depends on C and state x)
           E = D + C  (depends on D and C)
    ODE:   dx/dt = -E

    With sequential evaluation, C is computed first, then D (using fresh C),
    then E (using fresh C and fresh D).  If evaluation order were wrong (e.g.
    all stale), D and E would use the default/IC value of C rather than the
    computed one.  Analytical: C = a*b = 6, D(t)=C*x(t), E(t)=D(t)+C,
    dx/dt = -(C*x + C) = -C*(x+1), x(t) = (x0+1)*exp(-C*t) - 1.
    """
    variables = {
        "a": ModelVariable(type="parameter", default=2.0),
        "b": ModelVariable(type="parameter", default=3.0),
        "x": ModelVariable(type="state", default=1.0),
        "C": ModelVariable(type="state"),
        "D": ModelVariable(type="state"),
        "E": ModelVariable(type="state"),
    }
    eq_C = Equation(lhs="C", rhs=ExprNode(op="*", args=["a", "b"]))
    eq_D = Equation(lhs="D", rhs=ExprNode(op="*", args=["C", "x"]))
    eq_E = Equation(lhs="E", rhs=ExprNode(op="+", args=["D", "C"]))
    eq_dx = Equation(
        lhs=ExprNode(op="D", args=["x"], wrt="t"),
        rhs=ExprNode(op="*", args=[-1, "E"]),
    )
    model = Model(name="Chain", variables=variables, equations=[eq_C, eq_D, eq_E, eq_dx])
    file = EsmFile(
        version="0.1.0",
        metadata=Metadata(title="deep_alg_chain"),
        models={"Chain": model},
    )

    result = simulate(file, tspan=(0.0, 1.0), parameters={}, initial_conditions={"x": 1.0})
    assert result.success, f"simulate() failed: {result.message}"

    x_idx = result.vars.index("Chain.x")
    c_idx = result.vars.index("Chain.C")
    d_idx = result.vars.index("Chain.D")
    e_idx = result.vars.index("Chain.E")

    C_val = 2.0 * 3.0  # = 6
    # x(t) = (x0 + 1)*exp(-C*t) - 1, x0 = 1 → x(t) = 2*exp(-6t) - 1
    t_end = result.t[-1]
    x_analytical = 2.0 * np.exp(-C_val * t_end) - 1.0
    assert np.isclose(result.y[x_idx, -1], x_analytical, rtol=1e-5)

    # C is constant = a*b = 6 everywhere.
    assert np.allclose(result.y[c_idx, :], C_val, rtol=1e-10)

    # D = C * x at every output time.
    assert np.allclose(result.y[d_idx, :], C_val * result.y[x_idx, :], rtol=1e-10)

    # E = D + C at every output time.
    assert np.allclose(result.y[e_idx, :], result.y[d_idx, :] + C_val, rtol=1e-10)
