"""``observed_field`` on a document with NO state variables (API_SPEC §5.8).

A document that declares no differential equations has nothing to integrate,
but its whole content is its observed graph — and reading that back by name is
what ``observed_field`` is for. Two properties are pinned here:

1. **It works under every compiler that can build the document.** A state-free
   document used to reach the scalar engine or the NumPy one on content the
   caller did not choose — an injected ``const_arrays`` was enough to switch it.
   ``API_SPEC.md`` §5.8 makes that choice the caller's, which turns this file's
   premise from "whichever engine the router picked" into the better claim it
   was reaching for: the compilers AGREE. Each parametrized test below names
   the compiler instead of nudging a router into it.

2. **The name-resolution rule.** A bare name resolves only on a
   SINGLE-component document. On a multi-component one it is refused with the
   candidates named, rather than bound to whichever sorted first — which is the
   wrong-answer-instead-of-missing-answer failure esm-spec §6.6.2 rules
   specifically non-conforming for override keys.
"""

from __future__ import annotations

import math

import numpy as np
import pytest
from conftest import VALID_DIR

from earthsci_ast.expression import SimulationError
from earthsci_ast.problem import esm_problem, observed_field, solve
from earthsci_ast.simulation_common import ReturnCode

ONE_COMPONENT = VALID_DIR / "nonlinear_mogi_shape.esm"
TWO_COMPONENT = VALID_DIR / "nonlinear_two_component_static.esm"


def mogi_oracle() -> tuple[float, float]:
    """The fixture's two closed-form displacements at the declared defaults,
    computed without the library so a shared evaluator bug cannot pass this."""
    dv, d, r, nu = 1.0e6, 3000.0, 1000.0, 0.25
    denom = math.pi * (r * r + d * d) ** 1.5
    return (1.0 - nu) * dv * r / denom, (1.0 - nu) * dv * d / denom


#: The two compilers that can build a state-free scalar document: the strict
#: default's vectorized NumPy, and the lambdified SymPy form. They must answer
#: identically, which is what makes `observed_field` a property of the document.
COMPILERS = [
    pytest.param("native", "array", id="native"),
    pytest.param("sympy", "scalar", id="sympy"),
]


@pytest.mark.parametrize("compiler,expected_engine", COMPILERS)
def test_single_component_answers_both_spellings(compiler, expected_engine):
    prob = esm_problem(str(ONE_COMPONENT), (0.0, 1.0), compiler=compiler)
    assert prob.compiler == compiler
    assert prob.engine == expected_engine
    assert not prob.flat.state_variables

    ur, uz = mogi_oracle()
    assert observed_field(prob, "MogiModel.ur") == pytest.approx(ur)
    assert observed_field(prob, "MogiModel.uz") == pytest.approx(uz)
    # One component, so the bare spelling resolves to the same field.
    assert observed_field(prob, "ur") == pytest.approx(ur)
    assert observed_field(prob, "uz") == pytest.approx(uz)


@pytest.mark.parametrize("compiler,expected_engine", COMPILERS)
def test_bare_name_refused_on_a_multi_component_document(compiler, expected_engine):
    prob = esm_problem(str(TWO_COMPONENT), (0.0, 1.0), compiler=compiler)
    assert prob.engine == expected_engine

    assert observed_field(prob, "Sites.North.u") == pytest.approx(6.0)
    assert observed_field(prob, "Sites.North.ur") == pytest.approx(3.0)
    assert observed_field(prob, "Sites.South.u") == pytest.approx(35.0)

    # Shared local name: refused, with both candidates named.
    with pytest.raises(SimulationError, match="bare name") as exc:
        observed_field(prob, "u")
    assert "Sites.North.u" in str(exc.value)
    assert "Sites.South.u" in str(exc.value)

    # UNIQUE local name: still refused. The component count is the gate, not
    # ambiguity — adding a second component must not silently change what a
    # bare name in an existing script means.
    with pytest.raises(SimulationError, match="bare name") as exc:
        observed_field(prob, "ur")
    assert "Sites.North.ur" in str(exc.value)

    # A partial qualification is not a spelling of anything, and neither is a
    # name the document does not declare.
    with pytest.raises(SimulationError):
        observed_field(prob, "North.u")
    with pytest.raises(SimulationError):
        observed_field(prob, "nope")


def test_parameter_overrides_reach_the_static_fields():
    """`p` binds before the observed graph is materialized, so the fields
    describe the problem that was built, not the document's defaults."""
    ur, _ = mogi_oracle()
    prob = esm_problem(str(ONE_COMPONENT), (0.0, 1.0), p={"MogiModel.dV": 2.0e6})
    # `ur` is linear in `dV`.
    assert observed_field(prob, "MogiModel.ur") == pytest.approx(2.0 * ur)


@pytest.mark.parametrize("compiler,expected_engine", COMPILERS)
def test_saveat_reads_the_same_under_both_compilers(compiler, expected_engine):
    """One ``saveat``, one answer, whichever compiler built the document.

    A state-free document is answered by the NumPy machinery under ``native``
    and by the lambdified SymPy form under ``sympy``, so the two must read a
    ``saveat`` identically or the request means different things for reasons the
    document cannot see. They did not: the array engine's observed-only
    path read the sequence literally, while everything else in this package
    resolves it through ``_saveat_times`` — which reads a ONE-element positive
    sequence as an output STEP measured from the span start (API_SPEC §4) and
    clips the result to the span.

    Sabotage check: restore the literal reading in ``_simulate_observeds_only``
    (``t_out = np.asarray(sorted(saveat_list))``) and the array case of both
    assertions below fails — the first with the single node ``[2.0]``, the
    second with the out-of-span times ``[-1.0, 3.0, 99.0]`` returned as asked.
    """
    prob = esm_problem(str(ONE_COMPONENT), (0.0, 6.0), compiler=compiler)
    assert prob.engine == expected_engine
    assert not prob.flat.state_variables

    # A one-element positive sequence is an output STEP from ``tspan[0]``.
    stepped = solve(prob, saveat=[2.0])
    assert stepped.retcode == ReturnCode.Success
    np.testing.assert_allclose(stepped.t, [0.0, 2.0, 4.0, 6.0])

    # Times outside the span are clipped away, however evaluable the observed
    # bodies are there: the run was asked for ``tspan``.
    clipped = solve(prob, saveat=[-1.0, 3.0, 99.0])
    assert clipped.retcode == ReturnCode.Success
    np.testing.assert_allclose(clipped.t, [3.0])

    # And the values are the document's static fields at every node.
    ur, _ = mogi_oracle()
    np.testing.assert_allclose(stepped["MogiModel.ur"], [ur] * 4, rtol=1e-12)


@pytest.mark.parametrize("compiler,expected_engine", COMPILERS)
def test_solve_still_samples_the_observed_graph(compiler, expected_engine):
    """The observed-only run is unchanged by the name rule under either
    compiler: Success over a sampled grid, keyed by FLATTENED name."""
    sol = solve(esm_problem(str(TWO_COMPONENT), (0.0, 1.0), compiler=compiler))
    assert sol.retcode == ReturnCode.Success
    assert sol.vars == ["Sites.North.u", "Sites.North.ur", "Sites.South.u"]
    assert sol["Sites.South.u"][0] == pytest.approx(35.0)
