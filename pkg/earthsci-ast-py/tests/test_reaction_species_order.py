"""Cross-language pin for SPECIES ORDER in the Analysis-tier reaction ops.

Drives the shared, hand-written corpus at
``tests/conformance/reactions/species_order.json``. Canonical order is
DECLARATION order — the order the document writes the ``species`` object's keys
in — in BOTH :func:`stoichiometric_matrix` (its row order) and
:func:`derive_odes` (its equation order). See API_SPEC.md §5.10.

The pin exists because five bindings diverged here unnoticed for the length of
the project: nothing in ``tests/`` asserted the order, so Go sorted in both
operations and Rust sorted in ``stoichiometric_matrix`` while Julia, Python and
TypeScript used declaration order. Species order is observable — it *is* the
matrix's row order and the derived model's equation order — so it is a contract.

Every case declares its species in an order that is NOT their sorted order (the
``test_fixture_is_discriminating`` guard below re-checks that per case), so a
binding that sorts fails rather than passing by coincidence.

``ode_states`` is deliberately NOT used: it sorts its result by design
(esm-spec §6.3.1), so an assertion built on it passes vacuously everywhere. The
equation list is read directly and each LHS ``D(<species>, t)`` node's first
argument taken.
"""

from __future__ import annotations

import json

import numpy as np
import pytest
from conftest import CONFORMANCE_DIR

from earthsci_ast import derive_odes, load_document, stoichiometric_matrix
from earthsci_ast.esm_types import ReactionSystem

CORPUS = json.loads((CONFORMANCE_DIR / "reactions" / "species_order.json").read_text())
CASES: list[dict] = CORPUS["cases"]
CASE_IDS: list[str] = [case["name"] for case in CASES]


def _system(case: dict) -> ReactionSystem:
    """Load the case document and return the reaction system it names."""
    return load_document(case["document"]).reaction_systems[case["system"]]


def _equation_species(case: dict) -> list[str]:
    """Species of each derived equation, in the order ``derive_odes`` emits them.

    Reads each equation's LHS ``D(<species>, t)`` node and takes its first
    argument — NOT ``ode_states``, which sorts.
    """
    species: list[str] = []
    for equation in derive_odes(_system(case)).equations:
        lhs = equation.lhs
        assert getattr(lhs, "op", None) == "D", f"non-derivative LHS in derived model: {lhs!r}"
        species.append(lhs.args[0])
    return species


def test_corpus_was_actually_read() -> None:
    """Anti-vacuity: an empty or missing corpus must fail, not pass silently."""
    assert len(CASES) >= 2, f"expected at least 2 corpus cases, got {len(CASES)}"


@pytest.mark.parametrize("case", CASES, ids=CASE_IDS)
def test_fixture_is_discriminating(case: dict) -> None:
    """Anti-vacuity: declaration order must differ from sorted order per case.

    If a case is ever edited into alphabetical declaration order, a sorting
    binding would pass this file by coincidence.
    """
    declaration_order = case["species_declaration_order"]
    sorted_order = case["species_sorted_order"]
    assert sorted(declaration_order) == sorted_order, "species_sorted_order is not the sorted order"
    assert declaration_order != sorted_order, (
        "case declares its species in sorted order, so a sorting binding would pass vacuously"
    )


@pytest.mark.parametrize("case", CASES, ids=CASE_IDS)
def test_stoichiometric_matrix_rows_are_declaration_order(case: dict) -> None:
    """Matrix rows follow declaration order (a reservoir species keeps its row)."""
    actual = np.asarray(stoichiometric_matrix(_system(case))).tolist()
    assert actual == case["stoichiometric_matrix"]


@pytest.mark.parametrize("case", CASES, ids=CASE_IDS)
def test_derive_odes_equations_are_declaration_order(case: dict) -> None:
    """Derived equations follow declaration order (a reservoir species has none)."""
    assert _equation_species(case) == case["derive_odes_equation_species"]
