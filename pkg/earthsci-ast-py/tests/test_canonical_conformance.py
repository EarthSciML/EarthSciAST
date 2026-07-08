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

from earthsci_ast.canonicalize import canonical_json
from earthsci_ast.esm_types import ExprNode

FIXTURES_DIR = CONFORMANCE_DIR / "canonical"


def _wire_to_expr(node):
    """Convert a JSON-deserialized fixture into an ESM expression tree."""
    if isinstance(node, dict) and "op" in node and "args" in node:
        kwargs = {k: v for k, v in node.items() if k not in ("op", "args")}
        return ExprNode(
            op=node["op"],
            args=[_wire_to_expr(a) for a in node["args"]],
            **kwargs,
        )
    if isinstance(node, list):
        return [_wire_to_expr(a) for a in node]
    # Bare numbers / strings round-trip natively. Python's json preserves int
    # vs float on parse, so {"op":"+","args":[1, 2.5]} yields an int and a float.
    return node


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
    got = canonical_json(expr)
    assert got == fixture["expected"], (
        f"\n  id: {fixture_id}\n  got:  {got}\n  want: {fixture['expected']}"
    )
