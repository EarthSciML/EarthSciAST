"""Adapter for the shared `unit_registry` conformance category.

Drives ``tests/conformance/unit_registry/golden/unit_verdicts.json`` — the one
artifact in the corpus that pins the esm-spec §4.8 contract at the level a
document meets it, a unit STRING at a time — through this binding's parser. The
Julia and Rust adapters read the same file.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from earthsci_ast.units import PINT_AVAILABLE, UnparseableUnitError, parse_unit, ureg

_GOLDEN = (
    Path(__file__).resolve().parents[3]
    / "tests"
    / "conformance"
    / "unit_registry"
    / "golden"
    / "unit_verdicts.json"
)

pytestmark = pytest.mark.skipif(not PINT_AVAILABLE, reason="pint not installed")

_G = json.loads(_GOLDEN.read_text())


@pytest.mark.parametrize("entry", _G["accept"], ids=lambda e: e["units"])
def test_accepted_string_resolves_with_the_pinned_dimension_and_scale(entry):
    got = parse_unit(entry["units"])
    canon = parse_unit(entry["canonical"])
    assert got.dimensionality == canon.dimensionality, entry.get("why", "")
    if entry["scale_to_canonical"] is not None:
        factor = float(ureg.Quantity(1.0, got).to(canon).magnitude)
        assert factor == pytest.approx(entry["scale_to_canonical"], rel=1e-12)


@pytest.mark.parametrize("entry", _G["reject"], ids=lambda e: e["units"])
def test_rejected_string_does_not_resolve(entry):
    with pytest.raises(UnparseableUnitError):
        parse_unit(entry["units"])


@pytest.mark.parametrize("entry", _G["reject_scaling_factor"], ids=lambda e: e["units"])
def test_scaling_factor_is_rejected_and_says_so(entry):
    with pytest.raises(UnparseableUnitError) as exc:
        parse_unit(entry["units"])
    # The one rejection whose REASON an author cannot guess from the string.
    assert "scaling factor" in str(exc.value)
