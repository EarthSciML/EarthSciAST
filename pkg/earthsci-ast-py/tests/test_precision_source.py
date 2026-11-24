"""esm-spec §11.3.3 P8: validation warns, on its non-unit ``warnings`` channel,
about an unspecified variable used directly as an equality or join key.
Fixtures shared with the other four bindings
(``tests/conformance/precision_source/``)."""

from __future__ import annotations

import json

import pytest
from conftest import FIXTURES_ROOT

from earthsci_ast import validate
from earthsci_ast.parse import load_string

FIXTURES = FIXTURES_ROOT / "conformance" / "precision_source"
EXPECTED = json.loads((FIXTURES / "expected.json").read_text())


def _pairs(warnings) -> list[tuple[str, str]]:
    return sorted(
        (w["code"], w["path"]) if isinstance(w, dict) else (w.code, w.path) for w in warnings
    )


@pytest.mark.parametrize("fixture", sorted(EXPECTED["warnings"]))
def test_an_unspecified_key_warns_on_the_non_unit_channel(fixture):
    result = validate(load_string((FIXTURES / fixture).read_text()))
    want = EXPECTED["warnings"][fixture]
    assert result.is_valid, result
    assert _pairs(result.warnings) == _pairs(want)
    codes = {w["code"] for w in want}
    assert not [w for w in result.unit_warnings if w.code in codes]


@pytest.mark.parametrize("fixture", sorted(EXPECTED["warnings"]))
def test_a_root_below_the_gate_draws_no_warning(fixture):
    doc = json.loads((FIXTURES / fixture).read_text())
    doc["esm"] = EXPECTED["legacy_version"]
    assert validate(load_string(json.dumps(doc))).warnings == []
