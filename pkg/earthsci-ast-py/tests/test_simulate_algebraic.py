"""Tests for scalar algebraic-equation elimination on the solve() path (esm-y3n).

esm 1.0.0 declares only ``unknown`` and ``parameter``; whether an unknown is
an ODE state, an observed quantity or an algebraic one is DERIVED from the
model's equations (§6.3.1). So an unknown whose value is determined by
``v ~ body`` rather than by ``D(v, t) ~ …`` is exactly what this file
exercises. The canonical Python simulation runner must:

* Substitute the defining body into every other equation that references
  the variable, so the integrator's RHS depends only on the ODE states
  (the equivalent of MTK's structural_simplify scalar pass).
* Reconstruct the derived value at every output time so the
  Solution exposes correct trajectories for both ODE-state and
  non-differential unknowns.
* Reject cyclic algebraic systems with a clear error message.
* Leave pure-ODE models numerically identical to the previous behaviour.
"""

import numpy as np
import pytest

pytest.importorskip("scipy")
pytest.importorskip("sympy")

from earthsci_ast.esm_types import (
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
from earthsci_ast.problem import ReturnCode, esm_problem, solve
from earthsci_ast.sympy_bridge import SimulationError


def _diameter_growth_model() -> EsmFile:
    """Build the Seinfeld & Pandis Fig. 13.2 / Eq. 13.11–13.13 model directly.

    The model has three unknowns — ``D_p`` (an ODE state), ``A`` (defined by
    ``A ~ …``), ``I_D`` (defined by ``I_D ~ A / D_p``) — and exercises every
    part of the elimination pipeline. None of that is declared: all three are
    ``type: "unknown"`` and the equations say which is which.
    """
    variables = {
        "R_gas": ModelVariable(type="parameter", default=8.314),
        "T": ModelVariable(type="parameter", default=298.0),
        "D_diff": ModelVariable(type="parameter", default=1.0e-5),
        "M_i": ModelVariable(type="parameter", default=0.1),
        "ρ_p": ModelVariable(type="parameter", default=1000.0),
        "Δp": ModelVariable(type="parameter", default=1.0e-4),
        "D_p": ModelVariable(type="unknown", default=2.0e-7),
        "I_D": ModelVariable(type="unknown"),
        "A": ModelVariable(type="unknown"),
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
        version="1.0.0",
        metadata=Metadata(title="DiameterGrowthRate"),
        models={"DiameterGrowthRate": model},
    )


def test_simulate_eliminates_algebraic_states_diameter_growth():
    """``D_p[end]`` must be within 1% of the analytical 6.538e-7 m target."""
    file = _diameter_growth_model()
    result = solve(esm_problem(file, (0.0, 1200.0), p={}, u0={"D_p": 2.0e-7}), alg="LSODA")
    assert (result.retcode is ReturnCode.Success), f"solve() did not succeed: {result.message}"

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
    result = solve(esm_problem(file, (0.0, 1200.0), p={}, u0={"D_p": 2.0e-7}), alg="LSODA")
    assert (result.retcode is ReturnCode.Success)

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
    """A self-referential / mutually-cyclic system of definitions must error out.

    ``X ~ Y + 1`` / ``Y ~ X + 1`` are bare-variable LHSs, so under esm 1.0.0
    §6.3.1 both X and Y are OBSERVED unknowns — which is what the diagnostic
    names. (Under 0.x they were declared ``state`` and the same cycle was
    reported against the "algebraic" equation class.)
    """
    variables = {
        "X": ModelVariable(type="unknown", default=0.0),
        "Y": ModelVariable(type="unknown", default=0.0),
        "Z": ModelVariable(type="unknown", default=0.0),
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
        version="1.0.0",
        metadata=Metadata(title="Cyclic"),
        models={"Cyclic": model},
    )

    # The compile happens at CONSTRUCTION (esm-libraries-spec §2.5.2), so a
    # cyclic observed graph is a build error — there is no run to give a return
    # code to.
    with pytest.raises(SimulationError) as exc:
        esm_problem(file, (0.0, 1.0), p={}, u0={})
    assert "Cyclic observed equations detected" in str(exc.value)
    assert "Cyclic.X" in str(exc.value) and "Cyclic.Y" in str(exc.value)


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
        "K_w": ModelVariable(type="unknown"),
        "OH_minus": ModelVariable(type="unknown"),
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
        version="1.0.0",
        metadata=Metadata(title="EquilibriumDAE"),
        models={"Eq": model},
    )

    result = solve(esm_problem(file, (0.0, 1.0), p={"T": 298.0, "H_plus": 1.0e-4}, u0={}))
    assert (result.retcode is ReturnCode.Success), f"solve() did not succeed: {result.message}"

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
        version="1.0.0",
        metadata=Metadata(title="decay"),
        reaction_systems={"Decay": rs},
    )

    result = solve(esm_problem(file, (0.0, 5.0), p={}, u0={"A": 1.0, "B": 0.0}), alg="RK45")
    assert (result.retcode is ReturnCode.Success), f"solve() did not succeed: {result.message}"

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
        "gamma": ModelVariable(type="unknown"),
        "R_c": ModelVariable(type="unknown"),
    }
    equations = [
        Equation(
            lhs="gamma",
            rhs=ExprNode(
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
        Equation(
            lhs="R_c",
            rhs=ExprNode(
                op="/",
                args=[
                    "tau_c",
                    ExprNode(op="+", args=["tau_c", "gamma"]),
                ],
            ),
        ),
    ]
    model = Model(name="CloudAlbedo", variables=variables, equations=equations)
    file = EsmFile(
        version="1.0.0",
        metadata=Metadata(title="cloud_albedo"),
        models={"CloudAlbedo": model},
    )

    result = solve(esm_problem(file, (0.0, 1.0), p={"tau_c": 10.0, "g": 0.85}, u0={}))
    assert (result.retcode is ReturnCode.Success), f"solve() did not succeed: {result.message}"

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
        "C": ModelVariable(type="unknown", default=1.0),
        "C_analytical": ModelVariable(type="unknown"),
    }
    eq_dC = Equation(
        lhs=ExprNode(op="D", args=["C"], wrt="t"),
        rhs=ExprNode(op="*", args=[-1, "k", "C"]),
    )
    eq_analytical = Equation(
        lhs="C_analytical",
        rhs=ExprNode(
            op="exp",
            args=[ExprNode(op="*", args=[-1, "k", "t"])],
        ),
    )
    model = Model(name="Decay", variables=variables, equations=[eq_dC, eq_analytical])
    file = EsmFile(
        version="1.0.0",
        metadata=Metadata(title="decay"),
        models={"Decay": model},
    )

    result = solve(esm_problem(file, (0.0, 2.0), p={"k": 0.5}, u0={"C": 1.0}))
    assert (result.retcode is ReturnCode.Success), f"solve() did not succeed: {result.message}"

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
        "NO2": ModelVariable(type="unknown", default=1.0),
        # Photolysis rate j_NO2 = k0 / T (depends only on parameters); its
        # bare-variable equation below is what makes it an OBSERVED unknown.
        "j_NO2": ModelVariable(type="unknown"),
    }
    eq_dNO2 = Equation(
        lhs=ExprNode(op="D", args=["NO2"], wrt="t"),
        rhs=ExprNode(op="*", args=[-1, "j_NO2", "NO2"]),
    )
    eq_j = Equation(lhs="j_NO2", rhs=ExprNode(op="/", args=["k0", "T"]))
    model = Model(name="Decay", variables=variables, equations=[eq_dNO2, eq_j])
    file = EsmFile(
        version="1.0.0",
        metadata=Metadata(title="namespaced-observed-in-diff-rhs"),
        models={"Decay": model},
    )

    result = solve(esm_problem(file, (0.0, 1.0), p={"k0": 2.0, "T": 300.0}, u0={"NO2": 1.0}))
    assert (result.retcode is ReturnCode.Success), f"solve() did not succeed: {result.message}"

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
        "x": ModelVariable(type="unknown", default=1.0),
        "C": ModelVariable(type="unknown"),
        "D": ModelVariable(type="unknown"),
        "E": ModelVariable(type="unknown"),
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
        version="1.0.0",
        metadata=Metadata(title="deep_alg_chain"),
        models={"Chain": model},
    )

    result = solve(esm_problem(file, (0.0, 1.0), p={}, u0={"x": 1.0}))
    assert (result.retcode is ReturnCode.Success), f"solve() did not succeed: {result.message}"

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
