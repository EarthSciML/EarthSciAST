"""Cross-binding canonical-form fixture consumer.

Reads ``tests/conformance/canonical/*.json`` and asserts that
``canonical_json(parse(input))`` equals each fixture's ``expected`` field
byte-for-byte. The same fixture set is consumed by every binding's tests —
passing here means this binding produces canonical output that matches the
cross-binding contract.
"""

from __future__ import annotations

import json

import pytest
from conftest import CONFORMANCE_DIR

from earthsci_ast.canonicalize import CanonicalizeError, canonical_json
from earthsci_ast.parse import _parse_expression

FIXTURES_DIR = CONFORMANCE_DIR / "canonical"


def _wire_to_expr(node):
    """Convert a JSON-deserialized fixture into an ESM expression tree through
    the binding's own wire parser, so a fixture carrying a key that is not an
    expression field (a retired one such as ``manifold``) is read the way a
    document's expression is, rather than crashing a hand-built constructor.
    Python's json preserves int vs float on parse, so {"op":"+","args":[1, 2.5]}
    yields an int and a float."""
    return _parse_expression(node)


def _load_manifest():
    path = FIXTURES_DIR / "manifest.json"
    with path.open() as fh:
        return json.load(fh)


@pytest.mark.parametrize(
    "fixture_id",
    [f["id"] for f in _load_manifest()["fixtures"]],
)
def test_canonical_conformance(fixture_id):
    fixture_meta = next(f for f in _load_manifest()["fixtures"] if f["id"] == fixture_id)
    fixture_path = FIXTURES_DIR / fixture_meta["path"]
    with fixture_path.open() as fh:
        fixture = json.load(fh)
    expr = _wire_to_expr(fixture["input"])

    # Fail-closed fixtures: a node carrying a non-emissible field has no faithful
    # canonical JSON, so `canonical_json` must raise the pinned coded error
    # rather than emit bytes (matches the Julia reference / cross-binding
    # contract). Other bindings consume the same `expect_error` fixtures.
    expected_error = fixture.get("expect_error")
    if expected_error is not None:
        with pytest.raises(CanonicalizeError) as excinfo:
            canonical_json(expr)
        assert excinfo.value.code == expected_error, (
            f"\n  id: {fixture_id}\n  got code:  {excinfo.value.code}"
            f"\n  want code: {expected_error}"
        )
        return

    got = canonical_json(expr)
    assert got == fixture["expected"], (
        f"\n  id: {fixture_id}\n  got:  {got}\n  want: {fixture['expected']}"
    )
