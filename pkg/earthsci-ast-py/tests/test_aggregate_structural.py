"""
Structural-validation conformance for the aggregate / semiring / index-set
fixtures (bead ess-my4.1.7).

Every fixture under ``tests/valid/aggregate/`` is schema-valid AND must pass the
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
``aggregate-fixtures.test.ts``); a regression that makes ``validate()`` reject a
schema-valid aggregate model — e.g. a spurious ``equation_count_mismatch`` or
``undefined_variable`` — fails here.

RFC: ``docs/content/rfcs/semiring-faq-unified-ir.md`` §5.1 / §5.2 / §8.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import List

import pytest
from conftest import VALID_DIR

from earthsci_ast.validation import validate


_FIXTURES_DIR = VALID_DIR / "aggregate"


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

    result = validate(data)

    assert not result.schema_errors, (
        f"{fixture_path.name}: unexpected schema errors: "
        f"{[e.message for e in result.schema_errors]}"
    )
    assert not result.structural_errors, (
        f"{fixture_path.name}: unexpected structural errors: "
        f"{[(e.code, e.path, e.message) for e in result.structural_errors]}"
    )
    assert result.is_valid, f"{fixture_path.name}: validate().is_valid is False"
