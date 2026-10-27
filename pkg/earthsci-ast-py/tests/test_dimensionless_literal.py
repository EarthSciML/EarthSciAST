"""The esm-spec §4.8.6 warning stage: a bare numeric literal read as
dimensionless at scale 1 (the literal zero excepted).

Gates `tests/conformance/dimensionless_literal/`: every file in the golden is
VALID, and carries exactly the pinned `units_dimensionless_literal_mismatch`
warnings, at the pinned JSON Pointers.
"""
from __future__ import annotations

import json

import pytest
from conftest import CONFORMANCE_DIR, REPO_ROOT

from earthsci_ast import validate_path
from earthsci_ast.units import UNIT_FINDING_DIMENSIONLESS_LITERAL, UnitValidator

GOLDEN = json.loads(
    (CONFORMANCE_DIR / "dimensionless_literal" / "golden" / "expected_warnings.json").read_text()
)


def test_the_golden_names_the_registered_code():
    assert GOLDEN["code"] == UNIT_FINDING_DIMENSIONLESS_LITERAL


@pytest.mark.parametrize("rel", sorted(GOLDEN["files"]))
def test_the_warnings_are_pinned_and_validity_is_unchanged(rel):
    result = validate_path(REPO_ROOT / rel)
    assert result.is_valid, [(e.code, e.path) for e in result.structural_errors]
    got = sorted(
        w.path for w in result.unit_warnings if w.code == UNIT_FINDING_DIMENSIONLESS_LITERAL
    )
    assert got == GOLDEN["files"][rel]


def test_the_warning_names_the_literal_and_the_repair():
    rel = "tests/conformance/dimensionless_literal/fixtures/dimensionless_literal.esm"
    result = validate_path(REPO_ROOT / rel)
    by_path = {
        w.path: w.message
        for w in result.unit_warnings
        if w.code == UNIT_FINDING_DIMENSIONLESS_LITERAL
    }
    message = by_path["/models/Literals/equations/0"]
    assert "273.15" in message
    assert "[temperature]" in message
    assert "const(" in message


@pytest.mark.parametrize(
    ("value", "expected"),
    [(0, None), (0.0, None), (-0.0, None), (2, "dimensionless"), (-1.5, "dimensionless")],
)
def test_zero_stays_neutral_and_every_other_literal_is_dimensionless(value, expected):
    validator = UnitValidator()
    assert validator._type(value) is None
    validator.dimensionless_literals = True
    typed = validator._type(value)
    if expected is None:
        assert typed is None
    else:
        assert typed == validator._dimensionless
