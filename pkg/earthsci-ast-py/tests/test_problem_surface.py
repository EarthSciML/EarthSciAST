"""The Problem / ``solve`` surface (esm-libraries-spec §2.5, API_SPEC §5.8).

One noun and one verb replace ``simulate``. These tests pin the parts of §2.5
that are contract rather than numerics — the return-code vocabulary, name-keyed
indexing, ``remake``'s no-rebuild promise, the REPLACE (not merge) rule for a
``solve`` callback, the stepping lifecycle, ensembles, and the rule that
building a Problem never needs the solver — plus one end-to-end integration
against a closed-form answer (§2.4.2), so the surface is not merely present but
correct.
"""

from __future__ import annotations

import math

import numpy as np
import pytest

import earthsci_ast
from earthsci_ast.esm_types import (
    EsmFile,
    Metadata,
    Parameter,
    Reaction,
    ReactionSystem,
    Species,
)
from earthsci_ast.problem import (
    CallbackSet,
    EnsembleProblem,
    Integrator,
    Problem,
    ReturnCode,
    Solution,
    callbacks,
    esm_problem,
    init,
    remake,
    solve,
    solve_all,
    step,
)
from earthsci_ast.sympy_bridge import SimulationError

pytest.importorskip("scipy")  # the solve() half of the surface needs the solver


def _decay_file(k: float = 0.5) -> EsmFile:
    """``A -> ∅`` at rate ``k`` — closed form ``A(t) = A0 · exp(-k·t)``."""
    rs = ReactionSystem(
        name="Decay",
        species=[Species(name="A")],
        parameters=[Parameter(name="k", value=k)],
        reactions=[Reaction(name="decay", reactants={"A": 1.0}, products={}, rate_constant="k")],
    )
    return EsmFile(
        version="0.1.0",
        metadata=Metadata(title="decay"),
        reaction_systems={"Decay": rs},
    )


# --------------------------------------------------------------------------- #
# §2.5.1 — `simulate` does not exist
# --------------------------------------------------------------------------- #


def test_simulate_and_prepare_are_gone() -> None:
    """§2.5.1: `simulate` is DELETED, not deprecated — and `prepare` /
    `PreparedModel` are replaced by Problem construction, not kept beside it."""
    for gone in ("simulate", "prepare", "PreparedModel", "SimulationResult"):
        assert gone not in earthsci_ast.__all__
        assert not hasattr(earthsci_ast, gone), f"{gone} is still reachable"
    from earthsci_ast import simulation as sim

    assert not hasattr(sim, "simulate")
    with pytest.raises(ImportError):
        from earthsci_ast import prepare  # noqa: F401


# --------------------------------------------------------------------------- #
# §2.4.2 — it actually integrates, and the numbers are right
# --------------------------------------------------------------------------- #


def test_solve_integrates_to_the_closed_form() -> None:
    prob = esm_problem(_decay_file(k=0.5), (0.0, 4.0), u0={"A": 2.0})
    sol = solve(prob)
    assert sol.retcode is ReturnCode.Success
    # §2.5.7: indexed by NAME, not by position in the state vector.
    a = sol["Decay.A"]
    assert a[0] == pytest.approx(2.0, rel=1e-9)
    assert a[-1] == pytest.approx(2.0 * math.exp(-0.5 * 4.0), rel=1e-6)
    # The bare local name resolves too.
    np.testing.assert_allclose(sol["A"], a)
    assert "Decay.A" in sol
    assert sol.keys() == sol.vars
    with pytest.raises(KeyError):
        sol["nope"]


def test_canonical_tolerance_defaults() -> None:
    """API_SPEC §5.8 pins the cross-binding defaults at reltol 1e-10 / abstol
    1e-14 so two bindings solving one document are comparable."""
    import inspect

    sig = inspect.signature(solve)
    assert sig.parameters["reltol"].default == 1e-10
    assert sig.parameters["abstol"].default == 1e-14
    # SciPy's spellings must NOT be the surface (API_SPEC §4).
    assert "rtol" not in sig.parameters
    assert "atol" not in sig.parameters
    assert "method" not in sig.parameters
    assert "t_eval" not in sig.parameters


def test_saveat_names_the_output_times() -> None:
    prob = esm_problem(_decay_file(k=0.5), (0.0, 4.0), u0={"A": 2.0})
    want = [0.0, 1.0, 2.0, 4.0]
    sol = solve(prob, saveat=want)
    np.testing.assert_allclose(sol.t, want)
    np.testing.assert_allclose(
        sol["Decay.A"], [2.0 * math.exp(-0.5 * t) for t in want], rtol=1e-6
    )


# --------------------------------------------------------------------------- #
# §2.5.3 — the return code
# --------------------------------------------------------------------------- #


def test_retcode_vocabulary_is_sciml() -> None:
    for name in ("Success", "MaxIters", "Unstable", "Terminated", "Failure"):
        assert hasattr(ReturnCode, name)
    # It REPLACES the success/message pair: no boolean to branch on.
    sol = solve(esm_problem(_decay_file(), (0.0, 1.0), u0={"A": 1.0}))
    assert not hasattr(sol, "success")
    assert isinstance(sol, Solution)


def test_maxiters_stops_early_with_its_own_code() -> None:
    """A caller must be able to tell "ran to tspan[2]" from "stopped early, here
    is why" WITHOUT parsing prose (§2.5.3)."""
    prob = esm_problem(_decay_file(), (0.0, 100.0), u0={"A": 1.0})
    sol = solve(prob, maxiters=3)
    assert sol.retcode is ReturnCode.MaxIters
    assert sol.retcode is not ReturnCode.Success


# --------------------------------------------------------------------------- #
# §2.5.4 — a `callback` argument REPLACES the Problem's set
# --------------------------------------------------------------------------- #


def test_solve_callback_replaces_the_problems_set() -> None:
    fired: list[str] = []
    prob = esm_problem(
        _decay_file(),
        (0.0, 1.0),
        u0={"A": 1.0},
        callback=lambda t, y: fired.append("problem"),
    )
    assert isinstance(callbacks(prob), CallbackSet)
    assert len(callbacks(prob)) == 1

    solve(prob)
    assert fired == ["problem"]

    fired.clear()
    solve(prob, callback=lambda t, y: fired.append("run"))
    # REPLACES: the Problem's own callback must NOT also fire.
    assert fired == ["run"]

    # To EXTEND, compose explicitly — that is what callbacks(prob) is for.
    fired.clear()
    solve(prob, callback=callbacks(prob) + (lambda t, y: fired.append("run")))
    assert fired == ["problem", "run"]

    # The Problem's own set is untouched by any of that.
    fired.clear()
    solve(prob)
    assert fired == ["problem"]


# --------------------------------------------------------------------------- #
# §2.5.5 — remake
# --------------------------------------------------------------------------- #


def test_remake_is_pure_and_reuses_the_build() -> None:
    prob = esm_problem(_decay_file(k=0.5), (0.0, 4.0), u0={"A": 2.0})
    faster = remake(prob, p={"k": 2.0})

    assert isinstance(faster, Problem)
    assert faster is not prob
    # No mutation of the original.
    assert prob.p == {}
    assert prob.tspan == (0.0, 4.0)
    # Everything the substitution cannot have invalidated is SHARED, not redone.
    assert faster.flat is prob.flat
    assert faster.const_arrays is prob.const_arrays
    assert faster.static_cache is prob.static_cache

    a_slow = solve(prob)["Decay.A"][-1]
    a_fast = solve(faster)["Decay.A"][-1]
    assert a_fast == pytest.approx(2.0 * math.exp(-2.0 * 4.0), abs=1e-9)
    assert a_fast < a_slow


def test_remake_tspan_only_reuses_the_compiled_rhs_verbatim() -> None:
    """A changed interval cannot invalidate the right-hand side, so remake must
    not rebuild it at all."""
    prob = esm_problem(_decay_file(), (0.0, 1.0), u0={"A": 1.0})
    shorter = remake(prob, tspan=(0.0, 0.5))
    assert shorter.tspan == (0.0, 0.5)
    assert shorter.scalar_build is prob.scalar_build
    assert solve(shorter).t[-1] == pytest.approx(0.5)


def test_remake_refuses_a_substitution_it_cannot_honour() -> None:
    """§2.5.5: refusal names the parameter, rather than silently rebuilding or
    silently ignoring it."""
    from earthsci_ast.errors import UnknownParameterError

    prob = esm_problem(_decay_file(), (0.0, 1.0), u0={"A": 1.0})
    with pytest.raises(UnknownParameterError) as exc:
        remake(prob, p={"not_a_parameter": 1.0})
    assert "not_a_parameter" in str(exc.value)


# --------------------------------------------------------------------------- #
# §2.5.6 — stepping
# --------------------------------------------------------------------------- #


def test_init_step_and_solve_all() -> None:
    prob = esm_problem(_decay_file(k=0.5), (0.0, 4.0), u0={"A": 2.0})
    integ = init(prob, alg="RK45")
    assert isinstance(integ, Integrator)
    assert integ.t == 0.0
    assert integ["Decay.A"] == pytest.approx(2.0)

    assert step(integ) is None  # still running
    assert integ.t > 0.0

    sol = solve_all(integ)
    assert sol.retcode is ReturnCode.Success
    assert sol.t[-1] == pytest.approx(4.0)
    # Same answer as the one-shot solve, to the solver's own accuracy.
    assert sol["Decay.A"][-1] == pytest.approx(2.0 * math.exp(-2.0), rel=1e-5)


def test_integrator_is_iterable() -> None:
    prob = esm_problem(_decay_file(), (0.0, 1.0), u0={"A": 1.0})
    seen = [(t, float(u[0])) for t, u in init(prob, alg="RK45")]
    assert seen
    assert seen[-1][0] == pytest.approx(1.0)


# --------------------------------------------------------------------------- #
# §2.5.8 — ensembles
# --------------------------------------------------------------------------- #


def test_ensemble_problem_sweeps_a_parameter() -> None:
    ks = [0.25, 0.5, 1.0]
    base = esm_problem(_decay_file(), (0.0, 2.0), u0={"A": 1.0})
    ens = EnsembleProblem(base, lambda prob, i: remake(prob, p={"k": ks[i]}))
    sols = solve(ens, trajectories=len(ks))

    assert len(sols) == len(ks)
    for k, sol in zip(ks, sols):
        assert sol.retcode is ReturnCode.Success
        assert sol["Decay.A"][-1] == pytest.approx(math.exp(-k * 2.0), rel=1e-6)
    # The base Problem is untouched by the sweep.
    assert base.p == {}


def test_ensemble_needs_its_family_size() -> None:
    ens = EnsembleProblem(esm_problem(_decay_file(), (0.0, 1.0), u0={"A": 1.0}))
    with pytest.raises(SimulationError):
        solve(ens)


# --------------------------------------------------------------------------- #
# §2.5.9 — the solver stays optional
# --------------------------------------------------------------------------- #


def test_constructing_a_problem_does_not_need_scipy(monkeypatch) -> None:
    """Only solve / init / step / solve_all may require the solver."""
    import earthsci_ast.problem as problem_mod

    monkeypatch.setattr(problem_mod, "SCIPY_AVAILABLE", False)
    prob = problem_mod.esm_problem(_decay_file(), (0.0, 1.0), u0={"A": 1.0})
    assert isinstance(prob, Problem)
    assert prob.scalar_build is not None  # the compile happened anyway

    sol = problem_mod.solve(prob)
    assert sol.retcode is ReturnCode.Failure
    assert "SciPy" in sol.message
    with pytest.raises(SimulationError):
        problem_mod.init(prob)


def test_problem_module_does_not_import_scipy_at_module_scope() -> None:
    src = (
        __import__("pathlib")
        .Path(__import__("earthsci_ast.problem", fromlist=["__file__"]).__file__)
        .read_text()
    )
    tree = __import__("ast").parse(src)
    ast = __import__("ast")
    for node in tree.body:  # module scope only — `init` imports it lazily
        if isinstance(node, ast.Import):
            assert all(not a.name.startswith("scipy") for a in node.names)
        if isinstance(node, ast.ImportFrom):
            assert not (node.module or "").startswith("scipy")
