"""A construct the simulation tier cannot run is REFUSED, never answered around.

Each test here names the wrong answer a dropped equation would report, and
asserts the diagnostic that replaces it. esm-libraries-spec §2.5.2 makes a
failed build raise rather than return a code, and esm-spec §9.6.6 makes a
construct an evaluator cannot run a named diagnostic rather than a dropped
equation.

The other half of the same rule is here too: an equation whose meaning IS
defined (esm-spec §6.3.1) is applied on every pathway rather than refused on
one and honoured on the other.
"""

from __future__ import annotations

import json

import numpy as np
import pytest

pytest.importorskip("scipy")
pytest.importorskip("sympy")

from earthsci_ast import load_string
from earthsci_ast.expression import SimulationError, UnsupportedConstructError
from earthsci_ast.problem import esm_problem, solve

# ---------------------------------------------------------------------------
# Documents
# ---------------------------------------------------------------------------


def _doc(models: dict) -> str:
    return json.dumps({"esm": "1.0.0", "metadata": {"name": "Refusals"}, "models": models})


#: An equilibrium pair whose second equation cannot be solved for the unknown it
#: constrains: `sp.solve` meets three generators (`z`, `exp(z)`, `log(z)`) and
#: gives up. Balanced — two unknowns (`K`, `z`), two equations.
UNSOLVABLE_CONSTRAINT = _doc(
    {
        "M": {
            "variables": {
                "K": {"type": "unknown", "default": 1.0},
                "z": {"type": "unknown", "default": 1.0},
                "p": {"type": "parameter", "default": 2.0},
            },
            "equations": [
                {"lhs": "K", "rhs": "p"},
                {
                    "lhs": "K",
                    "rhs": {
                        "op": "+",
                        "args": [
                            {"op": "exp", "args": ["z"]},
                            {"op": "log", "args": ["z"]},
                            {"op": "^", "args": ["z", 3]},
                        ],
                    },
                },
            ],
        }
    }
)

#: A second definition of `K` whose right-hand side binds no other unknown: one
#: unknown, two equations (esm-spec §4.9.4).
REDUNDANT_SECOND_DEFINITION = _doc(
    {
        "M": {
            "variables": {
                "K": {"type": "unknown", "default": 1.0},
                "p": {"type": "parameter", "default": 2.0},
            },
            "equations": [
                {"lhs": "K", "rhs": "p"},
                {"lhs": "K", "rhs": {"op": "*", "args": [2.0, "p"]}},
            ],
        }
    }
)

#: `x` carries both a derivative equation and a bare-LHS one. The two right-hand
#: sides DIFFER, because `flatten` collapses a pair whose rendered RHS matches.
DOUBLY_DEFINED_STATE = _doc(
    {
        "M": {
            "variables": {
                "x": {"type": "unknown", "default": 1.0},
                "k": {"type": "parameter", "default": 1.0},
            },
            "equations": [
                {"lhs": {"op": "D", "args": ["x"], "wrt": "t"}, "rhs": "k"},
                {"lhs": "x", "rhs": {"op": "*", "args": [2.0, "k"]}},
            ],
        }
    }
)

#: A subsystem unknown DEFINED by the parent's equation. `flatten` reads the
#: observed set from each component's OWN equations, so `sub.w` is filed as a
#: state of `sub` while the equation that defines it belongs to `M` — the shape
#: that made the array pathway integrate a frozen `-999.0` (issue #425).
SUBSYSTEM_ALGEBRAIC_UNKNOWN = _doc(
    {
        "M": {
            "subsystems": {
                "sub": {
                    "variables": {"w": {"type": "unknown", "default": -999.0}},
                    "equations": [],
                }
            },
            "variables": {
                "x": {"type": "unknown", "default": 0.0},
                "k": {"type": "parameter", "default": 3.0},
            },
            "equations": [
                {"lhs": "sub.w", "rhs": {"op": "*", "args": ["k", "k"]}},
                {"lhs": {"op": "D", "args": ["x"], "wrt": "t"}, "rhs": "sub.w"},
            ],
        }
    }
)


def _build(text: str, compiler: str | None = None):
    """Build the document under a NAMED compiler (``API_SPEC.md`` §5.8).

    This used to monkeypatch ``_choose_pathway``, the content-based router that
    no longer exists: which machinery builds a document is now the caller's to
    name, and naming it is the whole point of the keyword.
    """
    return esm_problem(
        load_string(text), model_name="M", tspan=(0.0, 1.0), compiler=compiler
    )


# ---------------------------------------------------------------------------
# The refusals
# ---------------------------------------------------------------------------


def test_unsolvable_algebraic_constraint_is_refused():
    """A constraint `sp.solve` cannot invert determines `z` and nothing else.

    Dropping it leaves `z` at its default for the whole run and reports that as
    the answer, so the build is refused and the equation named.

    This is the SymPy compiler's refusal, and §5.8 keeps it there: `sympy` "
    "refuses an algebraic constraint it cannot solve rather than dropping the
    equation". The NumPy compilers have no algebraic solve to fail at and so
    have never checked this shape — a gap the strict `native` default makes
    reachable by DEFAULT rather than one it creates, and one that belongs to
    whoever gives the array engine a constraint check.
    """
    with pytest.raises(UnsupportedConstructError) as excinfo:
        _build(UNSOLVABLE_CONSTRAINT, "sympy")
    message = str(excinfo.value)
    assert excinfo.value.code == "unsupported_construct"
    # The equation and the unknown it was to determine are both named.
    assert "M.K" in message
    assert "M.z" in message
    assert "exp(M.z)" in message


def test_second_definition_binding_no_unknown_is_refused():
    """A second definition that binds no unknown is a count mismatch, not a no-op.

    The document is state-free, which is the branch `esm_problem` tolerates a
    SymPy lowering failure in — a coded REFUSAL must still come through it.

    Named on `sympy` for the reason the unsolvable-constraint test above gives:
    the count check is the SymPy bridge's, and the array engine does not carry
    one.
    """
    with pytest.raises(SimulationError) as excinfo:
        _build(REDUNDANT_SECOND_DEFINITION, "sympy")
    message = str(excinfo.value)
    assert "equation_count_mismatch" in message
    assert "M.K" in message
    assert "§4.9.4" in message


def test_state_with_both_a_derivative_and_an_algebraic_equation_is_refused():
    """Two equations for one unknown, refused under EVERY compiler.

    Tie-breaking in favour of the derivative runs the model without the
    constraint the file declares; `esm_problem` is the one front door, so the
    refusal does not depend on which compiler the caller names — which is now
    something the test can state directly instead of forcing a route.
    """
    for compiler in (None, "sympy", "native", "interpreter"):
        with pytest.raises(SimulationError) as excinfo:
            _build(DOUBLY_DEFINED_STATE, compiler)
        message = str(excinfo.value)
        assert "equation_count_mismatch" in message
        assert "M.x" in message
        assert "D(M.x, t)" in message


def test_doubly_defined_state_is_invalid_by_the_structural_check_too():
    """The build's refusal and `validate`'s agree on the same document, which is
    what makes it a property of the file rather than of the engine."""
    from earthsci_ast import validate

    result = validate(load_string(DOUBLY_DEFINED_STATE))
    assert not result.is_valid
    assert [e.code for e in result.structural_errors] == ["equation_count_mismatch"]


# ---------------------------------------------------------------------------
# The equation that is now applied instead of dropped
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("compiler", ["native", "interpreter", "sympy"])
def test_subsystem_algebraic_unknown_is_applied_under_every_compiler(compiler):
    """`D(x) ~ sub.w` with `sub.w ~ k*k` integrates 9, not the frozen default.

    `sub.w` is an algebraic unknown, so it belongs on the observed side rather
    than in an ODE slot no equation writes; holding a slot would integrate its
    `-999.0` default. Every compiler answers the same document alike, which is
    the claim the old two-pathway parametrization was making and can now make
    over the named vocabulary.
    """
    prob = _build(SUBSYSTEM_ALGEBRAIC_UNKNOWN, compiler)
    assert prob.compiler == compiler
    sol = solve(prob)
    assert float(np.asarray(sol["M.sub.w"])[-1]) == pytest.approx(9.0)
    assert float(np.asarray(sol["M.x"])[-1]) == pytest.approx(9.0, rel=1e-6)


def test_array_build_refuses_a_driver_equation_it_cannot_apply(monkeypatch):
    """An equation whose LHS reaches no slot of ``dy`` is named at the BUILD.

    Removing the reclassification leaves the bare-LHS state equation in the
    driver set, which is the shape the per-step right-hand side cannot write into
    `dy`.
    """
    import earthsci_ast.simulation_array as simulation_array

    monkeypatch.setattr(simulation_array, "_algebraically_defined_states", lambda flat, vi: set())
    with pytest.raises(UnsupportedConstructError) as excinfo:
        _build(SUBSYSTEM_ALGEBRAIC_UNKNOWN, "native")
    message = str(excinfo.value)
    assert excinfo.value.code == "unsupported_construct"
    assert "M.sub.w" in message
    assert "Python array interpreter" in message


# ---------------------------------------------------------------------------
# The state-free build no longer defers its compile failure
# ---------------------------------------------------------------------------


STATE_FREE_OBSERVED_ONLY = _doc(
    {
        "M": {
            "variables": {
                "flux": {"type": "unknown", "default": 0.0},
                "k": {"type": "parameter", "default": 4.0},
            },
            "equations": [{"lhs": "flux", "rhs": {"op": "*", "args": ["k", 2.0]}}],
        }
    }
)


def test_state_free_document_still_builds_and_reads_back_its_observed():
    """API_SPEC §5.8: `observed_field` on a document with no state variables.

    Under the strict `native` default there is no SymPy compile at all — a
    state-free document is built by the same vectorized machinery as every
    other, and the interpreter build IS the product `observed_field` reads. The
    SymPy tier is still compiled under `compiler="sympy"`, where `solve` samples
    the observed bodies over the span through it and the document has no ODE
    right-hand side for that compile to produce.
    """
    from earthsci_ast.problem import observed_field

    prob = esm_problem(load_string(STATE_FREE_OBSERVED_ONLY), model_name="M", tspan=(0.0, 1.0))
    assert not prob.flat.state_variables
    assert prob.compiler == "native"
    assert prob.scalar_build is None
    assert prob.build is not None
    assert prob.scalar_build_error is None
    assert float(np.asarray(observed_field(prob, "M.flux"))) == pytest.approx(8.0)

    lam = esm_problem(
        load_string(STATE_FREE_OBSERVED_ONLY),
        model_name="M",
        tspan=(0.0, 1.0),
        compiler="sympy",
    )
    assert lam.scalar_build is not None
    assert lam.scalar_build.rhs_function is None
    assert lam.scalar_build_error is None
    assert float(np.asarray(observed_field(lam, "M.flux"))) == pytest.approx(8.0)


def test_state_free_scalar_compile_failure_is_recorded_not_dropped(monkeypatch):
    """A body the SymPy tier cannot lower still builds — Julia and Rust evaluate
    these, and `observed_field` is stable API for exactly these documents — but
    the reason is KEPT on the problem and named by the call that needs it.

    Discarding the exception would leave no account of it but whatever a later
    `solve` raises on its own recompile.
    """
    import earthsci_ast.problem as problem_module
    from earthsci_ast.problem import init, observed_field

    def boom(*args, **kwargs):
        raise TypeError("cannot lower this body")

    monkeypatch.setattr(problem_module, "_build_scalar_rhs", boom)
    # The tolerance is the SymPy compiler's own: `native` never reaches that
    # tier, so the document has to be built on the compiler whose failure this
    # is about.
    prob = esm_problem(
        load_string(STATE_FREE_OBSERVED_ONLY), model_name="M", tspan=(0.0, 1.0), compiler="sympy"
    )
    assert prob.scalar_build is None
    assert isinstance(prob.scalar_build_error, TypeError)
    # The interpreter build is the product this document asked for, and it works.
    assert float(np.asarray(observed_field(prob, "M.flux"))) == pytest.approx(8.0)
    # The call that does need the SymPy tier names the cause instead of meeting
    # it blind.
    with pytest.raises(SimulationError, match="cannot lower this body") as excinfo:
        init(prob)
    assert isinstance(excinfo.value.__cause__, TypeError)


def test_an_untaken_ifelse_branch_the_sympy_tier_cannot_lower_still_builds():
    """`ifelse(false, 1/0, 1)`: `false` has no SymPy lowering, and Julia and Rust
    both answer the taken branch. The document builds and reads back."""
    from earthsci_ast.problem import observed_field

    text = _doc(
        {
            "M": {
                "variables": {
                    "flux": {"type": "unknown", "default": 0.0},
                    "k": {"type": "parameter", "default": 4.0},
                },
                "equations": [
                    {
                        "lhs": "flux",
                        "rhs": {
                            "op": "ifelse",
                            "args": [
                                {"op": "false", "args": []},
                                {"op": "/", "args": [1.0, 0.0]},
                                1.0,
                            ],
                        },
                    }
                ],
            }
        }
    )
    prob = esm_problem(load_string(text), model_name="M", tspan=(0.0, 1.0), compiler="sympy")
    assert prob.scalar_build is None
    assert prob.scalar_build_error is not None
    assert float(np.asarray(observed_field(prob, "M.flux"))) == pytest.approx(1.0)
