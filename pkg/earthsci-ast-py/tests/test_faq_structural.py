"""
Structural-validation conformance for the aggregate / semiring / index-set
fixtures (bead ess-my4.1.7).

Every fixture under ``tests/valid/faq/`` is schema-valid AND must pass the
full structural ``validate()`` verdict — not merely schema validation. These
fixtures exercise the aggregate IR: LHS-aggregate ODEs (``op:aggregate`` whose
contracted body is ``D(index(v, i))``), relational element assignments
(``index(v, i) = aggregate(...)`` from skolem / distinct / rank), and contracted
index symbols (``i``, ``j``, ``e``).

The Python structural pass counts one equation entry per declared equation and
does not walk equation expressions for undefined references, so it recognises an
LHS-aggregate equation as the equation for its state variable and never flags a
contracted index symbol — i.e. it is structurally aggregate-clean. This module
locks that contract in (the TypeScript binding asserts the same in
``faq-fixtures.test.ts``); a regression that makes ``validate()`` reject a
schema-valid aggregate model — e.g. a spurious ``equation_count_mismatch`` or
``undefined_variable`` — fails here.

RFC: ``docs/content/rfcs/semiring-faq-unified-ir.md`` §5.1 / §5.2 / §8.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import List

import pytest
from conftest import CONFORMANCE_DIR, INVALID_DIR, VALID_DIR

from earthsci_ast.validation import validate_text


_FIXTURES_DIR = VALID_DIR / "faq"


def _collect_fixtures() -> List[Path]:
    if not _FIXTURES_DIR.is_dir():
        return []
    return sorted(_FIXTURES_DIR.glob("*.esm"))


def test_has_aggregate_fixtures() -> None:
    assert _collect_fixtures(), f"no aggregate fixtures found under {_FIXTURES_DIR}"


@pytest.mark.parametrize("fixture_path", _collect_fixtures(), ids=lambda p: p.name)
def test_aggregate_fixture_structurally_valid(fixture_path: Path) -> None:
    """A schema-valid aggregate fixture must also pass the structural verdict."""
    data = json.loads(fixture_path.read_text())

    result = validate_text(json.dumps(data))

    assert not result.schema_errors, (
        f"{fixture_path.name}: unexpected schema errors: "
        f"{[e.message for e in result.schema_errors]}"
    )
    assert not result.structural_errors, (
        f"{fixture_path.name}: unexpected structural errors: "
        f"{[(e.code, e.path, e.message) for e in result.structural_errors]}"
    )
    assert result.is_valid, f"{fixture_path.name}: validate().is_valid is False"


_AGNOSTIC_LEAF = (
    CONFORMANCE_DIR / "expression_templates" / "inject_agnostic_faq" / "fixture.esm"
)


def test_agnostic_leaf_aggregate_range_is_not_undefined_index_set() -> None:
    """A §9.7.10 discretization-agnostic leaf declares no `index_sets` of its own.

    Its registry arrives from a grid library injected into the component's scope
    at mount / test time (§6.6.6), so an `aggregate` range naming a set the
    document does not declare is NOT decidable at standalone load and MUST NOT
    be reported as ``undefined_index_set`` — mirroring §9.6.1, where
    ``template_constraint_unknown_index_set`` does not run for a library file
    validated standalone. Before issue #185 the check resolved against
    ``data["index_sets"]`` unconditionally, so every conforming leaf was
    rejected at ``load_path()``.
    """
    result = validate_text(_AGNOSTIC_LEAF.read_text())

    assert not result.schema_errors, [e.message for e in result.schema_errors]
    assert [e.code for e in result.structural_errors] == []
    assert result.is_valid


def test_undeclared_range_still_rejected_when_the_document_declares_a_registry() -> None:
    """The negative control: the deferral is scoped to a document with NO registry.

    A document that declares one is resolved against it, so a typo'd `from` name
    is still an ``undefined_index_set`` at validate() — the typo-catching value
    the issue asked to preserve.
    """
    fixture = INVALID_DIR / "faq" / "undeclared_from_name.esm"

    result = validate_text(fixture.read_text())

    assert not result.is_valid
    assert "undefined_index_set" in {e.code for e in result.structural_errors}
