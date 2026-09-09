"""``reaction_systems[].tests`` reach the runner, and a right-hand-side
structural ``D(x, t)`` resolves to the state's tendency (issue #206 items 1
and 2). The Python mirror of the Rust binding's
``tests/reaction_system_inline_tests.rs`` and ``tests/rhs_time_derivative.rs``.

Before this, ``run_inline_tests`` enumerated ``file.models`` alone — so a
document whose only tests live on a mechanism (esm-spec §7.2, and the shipped
``tests/simulation/autocatalytic_reaction.esm``) produced no assertion rows at
all — and an observed written ``dxdt ~ D(x, t)`` was unrunnable: this binding
raised ``unlowered_operator`` where the Rust binding silently returned ``0``.

Sabotage checks: drop the ``reaction_systems`` loop from
``_test_components`` and every §7.2 test here reports no rows; delete
the ``_resolve_rhs_time_derivatives`` call from ``flatten`` and every tendency
test here errors with ``unlowered_operator``.
"""

from __future__ import annotations

import json
import math

import pytest

from conftest import FIXTURES_ROOT

from earthsci_ast.flatten import flatten
from earthsci_ast.parse import load_path, load_string
from earthsci_ast.inline_tests import run_inline_tests

_META = {
    "name": "Issue206",
    "description": "issue #206 regression",
    "authors": ["issue-206"],
    "created": "2026-09-07T00:00:00Z",
}


def _decay_mechanism(tests: list) -> dict:
    """A first-order decay `A -> B` at rate `k`, with the whole suite on the
    reaction system and no model in the document at all."""
    return {
        "esm": "1.0.0",
        "metadata": _META,
        "reaction_systems": {
            "Chem": {
                "species": {
                    "A": {"units": "mol/mol", "default": 4.0},
                    "B": {"units": "mol/mol", "default": 0.0},
                },
                "parameters": {"k": {"units": "1/s", "default": 0.5}},
                "reactions": [
                    {
                        "id": "R1",
                        "substrates": [{"species": "A", "stoichiometry": 1}],
                        "products": [{"species": "B", "stoichiometry": 1}],
                        "rate": "k",
                    }
                ],
                "tests": tests,
            }
        },
        "domain": {"temporal": {}},
    }


def _run(doc: dict):
    return run_inline_tests(load_string(json.dumps(doc)))


# ---------------------------------------------------------------------------
# Item 1 — reaction_systems[].tests are discovered and run (esm-spec §7.2)
# ---------------------------------------------------------------------------


def test_reaction_system_tests_are_discovered_and_run():
    results = _run(
        _decay_mechanism(
            [
                {
                    "id": "initial_state",
                    "time_span": {"start": 0.0, "end": 1.0},
                    "assertions": [
                        {
                            "variable": "A",
                            "time": 0.0,
                            "expected": 4.0,
                            "tolerance": {"abs": 1e-12},
                        },
                        {
                            "variable": "B",
                            "time": 0.0,
                            "expected": 0.0,
                            "tolerance": {"abs": 1e-12},
                        },
                    ],
                }
            ]
        )
    )
    assert len(results) == 2, results
    assert all(r.model == "Chem" for r in results)
    assert all(r.passed for r in results), results


def test_reaction_system_species_are_actually_integrated():
    """``A(t) = A0 · exp(-k t)``, so ``A(2) = 4 · exp(-1)`` — not the default."""
    results = _run(
        _decay_mechanism(
            [
                {
                    "id": "decays",
                    "time_span": {"start": 0.0, "end": 2.0},
                    "tolerance": {"rel": 1e-6},
                    "assertions": [
                        {"variable": "A", "time": 2.0, "expected": 4.0 * math.exp(-1.0)}
                    ],
                }
            ]
        )
    )
    assert len(results) == 1
    assert results[0].passed, results[0]


def test_reaction_system_tolerance_is_the_component_level():
    """esm-spec §7.2 / §6.6.4: the system's own ``tolerance`` is the component
    level of the precedence chain, exactly as a model's is."""
    doc = _decay_mechanism(
        [
            {
                "id": "loose",
                "time_span": {"start": 0.0, "end": 1.0},
                "assertions": [{"variable": "A", "time": 0.0, "expected": 4.0}],
            }
        ]
    )
    doc["reaction_systems"]["Chem"]["tolerance"] = {"rel": 1e-3, "abs": 1e-4}
    results = _run(doc)
    assert (results[0].rtol, results[0].atol) == (1e-3, 1e-4), results[0]


def test_component_selector_reaches_a_reaction_system():
    doc = _decay_mechanism(
        [
            {
                "id": "initial_state",
                "time_span": {"start": 0.0, "end": 1.0},
                "assertions": [
                    {
                        "variable": "A",
                        "time": 0.0,
                        "expected": 4.0,
                        "tolerance": {"abs": 1e-12},
                    }
                ],
            }
        ]
    )
    file = load_string(json.dumps(doc))
    assert len(run_inline_tests(file, model_name="Chem")) == 1
    assert run_inline_tests(file, model_name="NotAComponent") == []


def test_shipped_reaction_system_fixture_produces_rows():
    """The corpus fixture the issue names: its whole suite is on a reaction
    system, and it produced no rows at all before this change."""
    path = FIXTURES_ROOT / "simulation" / "autocatalytic_reaction.esm"
    results = run_inline_tests(str(path))
    assert len(results) == 3, results
    assert all(r.passed for r in results), results


# ---------------------------------------------------------------------------
# Item 2 — a right-hand-side D(state, t) is that state's tendency
# ---------------------------------------------------------------------------

_OWN_STATE_DOC = {
    "esm": "1.0.0",
    "metadata": _META,
    "models": {
        "M": {
            "variables": {
                "x": {"type": "unknown", "units": "kg", "default": 2.0},
                "k": {"type": "parameter", "units": "1/s", "default": 3.0},
                "dxdt": {"type": "unknown", "units": "kg/s"},
            },
            "equations": [
                {
                    "lhs": {"op": "D", "args": ["x"], "wrt": "t"},
                    "rhs": {"op": "*", "args": [{"op": "-", "args": ["k"]}, "x"]},
                },
                {"lhs": "dxdt", "rhs": {"op": "D", "args": ["x"], "wrt": "t"}},
            ],
            "tests": [
                {
                    "id": "tendency_at_zero",
                    "time_span": {"start": 0.0, "end": 1.0},
                    "assertions": [
                        {
                            "variable": "dxdt",
                            "time": 0.0,
                            "expected": -6.0,
                            "tolerance": {"abs": 1e-9},
                        }
                    ],
                }
            ],
        }
    },
    "domain": {"temporal": {}},
}


def test_observed_derivative_of_own_state_is_the_tendency():
    results = _run(_OWN_STATE_DOC)
    assert len(results) == 1
    assert results[0].passed, results[0]
    assert results[0].actual == -6.0, results[0]


def test_observed_derivative_of_a_sibling_reaction_systems_species():
    """The scoped-reference form the issue reports: a wrapper model observes
    the tendency of a species owned by a sibling REACTION SYSTEM. The
    mass-action ODE ``D(Chem.A)/dt = -k·A`` is generated by flatten (§7.4), so
    the substitution resolves against it with no runner-side knowledge of
    reactions. ``k = 0.5``, ``A(0) = 4`` ⇒ ``dAdt(0) = -2``."""
    doc = {
        "esm": "1.0.0",
        "metadata": _META,
        "reaction_systems": {
            "Chem": {
                "species": {
                    "A": {"units": "mol/mol", "default": 4.0},
                    "B": {"units": "mol/mol", "default": 0.0},
                },
                "parameters": {"k": {"units": "1/s", "default": 0.5}},
                "reactions": [
                    {
                        "id": "R1",
                        "substrates": [{"species": "A", "stoichiometry": 1}],
                        "products": [{"species": "B", "stoichiometry": 1}],
                        "rate": "k",
                    }
                ],
            }
        },
        "models": {
            "Probe": {
                "variables": {"dAdt": {"type": "unknown", "units": "mol/mol/s"}},
                "equations": [{"lhs": "dAdt", "rhs": {"op": "D", "args": ["Chem.A"], "wrt": "t"}}],
                "tests": [
                    {
                        "id": "scoped_tendency_at_zero",
                        "time_span": {"start": 0.0, "end": 1.0},
                        "assertions": [
                            {
                                "variable": "dAdt",
                                "time": 0.0,
                                "expected": -2.0,
                                "tolerance": {"abs": 1e-9},
                            }
                        ],
                    }
                ],
            }
        },
        "domain": {"temporal": {}},
    }
    results = _run(doc)
    assert len(results) == 1
    assert results[0].passed, results[0]
    assert results[0].actual == -2.0, results[0]


def test_a_chained_tendency_resolves_transitively():
    """The shipped ``tests/end_to_end/land_atmosphere_hydrology.esm`` shape,
    ``D(lai)/dt ~ sla · D(biomass)/dt``: substitution recurses, so the chained
    state integrates against the real rate rather than standing still.
    ``D(b)/dt = 5``, ``sla = 2`` ⇒ ``D(l)/dt = 10``, so ``l(3) = 1 + 30``."""
    doc = {
        "esm": "1.0.0",
        "metadata": _META,
        "models": {
            "M": {
                "variables": {
                    "b": {"type": "unknown", "units": "kg", "default": 0.0},
                    "l": {"type": "unknown", "units": "m^2", "default": 1.0},
                    "growth": {"type": "parameter", "units": "kg/s", "default": 5.0},
                    "sla": {"type": "parameter", "units": "m^2/kg", "default": 2.0},
                },
                "equations": [
                    {"lhs": {"op": "D", "args": ["b"], "wrt": "t"}, "rhs": "growth"},
                    {
                        "lhs": {"op": "D", "args": ["l"], "wrt": "t"},
                        "rhs": {
                            "op": "*",
                            "args": ["sla", {"op": "D", "args": ["b"], "wrt": "t"}],
                        },
                    },
                ],
                "tests": [
                    {
                        "id": "chained",
                        "time_span": {"start": 0.0, "end": 3.0},
                        "tolerance": {"rel": 1e-8},
                        "assertions": [
                            {"variable": "b", "time": 3.0, "expected": 15.0},
                            {"variable": "l", "time": 3.0, "expected": 31.0},
                        ],
                    }
                ],
            }
        },
        "domain": {"temporal": {}},
    }
    results = _run(doc)
    assert len(results) == 2, results
    assert all(r.passed for r in results), results


def test_the_flattened_form_carries_the_substituted_tendency():
    """The transform is a FLATTEN-layer rewrite, so every ``FlattenedSystem``
    consumer agrees by construction rather than by each learning the rule."""
    flat = flatten(load_string(json.dumps(_OWN_STATE_DOC)))
    (eq,) = [e for e in flat.equations if e.lhs == "M.dxdt"]
    rendered = json.dumps(eq.rhs, default=lambda o: o.__dict__)
    assert '"D"' not in rendered, rendered
    assert "M.k" in rendered and "M.x" in rendered, rendered


def test_a_spatial_derivative_is_left_for_the_discretization_rule():
    """Scope guard: a SPATIAL ``D`` is a rewrite target for a discretization
    rule (esm-spec §9.6.8), not a tendency, and must survive this phase so the
    ``unlowered_operator`` gate still owns it."""
    doc = {
        "esm": "1.0.0",
        "metadata": _META,
        "models": {
            "M": {
                "variables": {
                    "u": {"type": "unknown", "units": "K", "default": 1.0},
                    "a": {"type": "parameter", "units": "m/s", "default": 1.0},
                },
                "equations": [
                    {
                        "lhs": {"op": "D", "args": ["u"], "wrt": "t"},
                        "rhs": {
                            "op": "*",
                            "args": [
                                {"op": "-", "args": ["a"]},
                                {"op": "D", "args": ["u"], "wrt": "x"},
                            ],
                        },
                    }
                ],
            }
        },
        "domain": {"temporal": {}},
    }
    flat = flatten(load_string(json.dumps(doc)))
    rendered = json.dumps(flat.equations[0].rhs, default=lambda o: o.__dict__)
    assert '"D"' in rendered and '"x"' in rendered, rendered


def test_load_path_still_round_trips_the_shipped_fixture():
    """Guard that nothing in this change perturbs loading the fixture whose
    reaction-system tests are now executed."""
    file = load_path(str(FIXTURES_ROOT / "simulation" / "autocatalytic_reaction.esm"))
    assert file.reaction_systems is not None
    assert len(file.reaction_systems["ChemicalSystem"].tests) == 1


def test_the_linearity_fixture_runs_and_both_sides_agree() -> None:
    """``tests/validation/mathematical_correctness.esm`` is the motivating case for
    esm-spec §4.2's CHAIN RULE, and it is now executed rather than merely shipped.

    ``LinearityTest`` writes both sides of d(alpha*u + beta*v)/dt as observeds over
    a right-hand-side structural ``D``. The left side goes through the observed
    ``linear_combination``, so it needs the chain rule; the right side needs only
    the states' own tendencies. Before the rule was stated in full this model could
    not run at all — Python and Julia refused the left-hand observed, Rust answered
    ``0`` for it — so the linearity the fixture is named for was untestable, and
    the whole document was reachable only through a round-trip test.

    Both sides must come back equal AND non-zero: equality alone would be
    satisfied by a binding that answered ``0`` for both."""
    path = FIXTURES_ROOT / "validation" / "mathematical_correctness.esm"
    results = run_inline_tests(str(path), model_name="LinearityTest")
    assert results, "the fixture declares inline tests and they must be discovered"
    by_var = {r.variable: r for r in results}
    for name in ("derivative_of_combination", "combination_of_derivatives"):
        r = by_var[name]
        assert r.actual is not None, f"{name}: {r.message}"
        assert r.passed, f"{name}: {r.message}"
    left = by_var["derivative_of_combination"].actual
    right = by_var["combination_of_derivatives"].actual
    assert left == pytest.approx(right, rel=1e-12), "d(a*u+b*v)/dt != a*du/dt + b*dv/dt"
    assert left == pytest.approx(-0.45, rel=1e-9)
    assert abs(left) > 1e-6, "a binding answering 0 for both sides would satisfy equality alone"
