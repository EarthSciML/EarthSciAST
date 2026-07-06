"""
Structural-validation conformance for the cadence-partition fixtures (bead
ess-my4.3.6).

Every fixture under ``tests/valid/cadence/`` is the schema-valid, evaluator-free
form of one of the three RFC ``semiring-faq-unified-ir`` §6.1 dependency-
partition examples — ``mixed_stencil`` (all three cadence classes + both
frontier thresholds + the gather split), ``pure_topology`` (all CONST, empty hot
tree), and ``pure_pointwise`` (all CONTINUOUS, empty per-event handler). Each
carries an ``expect_cadence`` assertion on every meaningful node (the additive
ExpressionNode diagnostic field the partition pass checks against its derived
class).

This module locks in that the fixtures pass the full structural ``validate()``
verdict — not merely JSON-schema validation — so the additive ``expect_cadence``
field and the fixtures' shapes (an LHS-aggregate stencil, an algebraically-
assigned topology system, a pointwise continuous-``t`` forcing) never regress a
validator into a spurious ``equation_count_mismatch`` / ``undefined_variable``.
The cross-binding cadence CLASS / materialization-point / CONST-fold golden is
asserted separately by ``scripts/run-cadence-conformance.py --self-test``
(CONFORMANCE_SPEC.md §5.7); the Python binding does no partition-pass evaluation
yet (that lands with ess-my4.3.7's Julia/Rust/Python siblings).

RFC: ``docs/content/rfcs/semiring-faq-unified-ir.md`` §6.1; CONFORMANCE_SPEC.md §5.7.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import List

import pytest
from conftest import VALID_DIR

from earthsci_toolkit.validation import validate


_FIXTURES_DIR = VALID_DIR / "cadence"

_EXPECTED = {"mixed_stencil", "pure_topology", "pure_pointwise"}


def _collect_fixtures() -> List[Path]:
    if not _FIXTURES_DIR.is_dir():
        return []
    return sorted(_FIXTURES_DIR.glob("*.esm"))


def test_has_cadence_fixtures() -> None:
    found = {p.stem for p in _collect_fixtures()}
    assert _EXPECTED <= found, (
        f"missing cadence fixtures under {_FIXTURES_DIR}: {_EXPECTED - found}"
    )


@pytest.mark.parametrize("fixture_path", _collect_fixtures(), ids=lambda p: p.name)
def test_cadence_fixture_structurally_valid(fixture_path: Path) -> None:
    """A cadence fixture must pass both schema and structural validation."""
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


@pytest.mark.parametrize("fixture_path", _collect_fixtures(), ids=lambda p: p.name)
def test_cadence_fixture_has_expect_cadence(fixture_path: Path) -> None:
    """Each fixture must carry at least one `expect_cadence` assertion, with only
    the closed enum values — the partition pass's checked author hint (§5.7)."""
    text = fixture_path.read_text()
    assert '"expect_cadence"' in text, (
        f"{fixture_path.name}: carries no expect_cadence assertion"
    )
    doc = json.loads(text)
    seen: List[str] = []

    def walk(node: object) -> None:
        if isinstance(node, dict):
            if "expect_cadence" in node:
                seen.append(node["expect_cadence"])
            for v in node.values():
                walk(v)
        elif isinstance(node, list):
            for v in node:
                walk(v)

    walk(doc)
    assert seen, f"{fixture_path.name}: no expect_cadence found by walk"
    assert set(seen) <= {"const", "discrete", "continuous"}, (
        f"{fixture_path.name}: expect_cadence outside the closed enum: {set(seen)}"
    )
