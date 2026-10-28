"""Cross-language pin for the EXACT TREE a reaction system lowers to.

Drives the shared, hand-written corpus at
``tests/conformance/reactions/lowering_form.json``: every binding's
:func:`derive_odes` and :func:`flatten` must produce the same expressions for a
reaction network, compared as JSON with integer and non-integer numbers kept
apart (esm-libraries-spec §4.6.2). Derived documents copy flattened terms
verbatim, so a binding that lowers a reaction to a different tree writes
different bytes.

The comparison runs on this binding's own expression writer
(``_serialize_expression``), which is what a derived document carries. That
writer narrows an integral float to an integer, so it cannot show a stray
``-1.0`` by itself; :func:`_integral_floats` checks the tree before writing.
"""

from __future__ import annotations

import json
import math

import pytest
from conftest import CONFORMANCE_DIR

from earthsci_ast import derive_odes, flatten, load_document
from earthsci_ast.esm_types import ExprNode
from earthsci_ast.serialize import _serialize_expression

CORPUS = json.loads((CONFORMANCE_DIR / "reactions" / "lowering_form.json").read_text())
CASES: list[dict] = CORPUS["cases"]
CASE_IDS: list[str] = [case["name"] for case in CASES]


def _same(actual, expected, path: str = "$") -> None:
    """JSON equality that keeps integers and non-integers apart."""
    if isinstance(expected, bool) or isinstance(actual, bool):
        assert actual is expected, f"{path}: {actual!r} != {expected!r}"
    elif isinstance(expected, (int, float)):
        assert isinstance(actual, (int, float)), f"{path}: {actual!r} is not a number"
        assert isinstance(actual, int) == isinstance(expected, int), (
            f"{path}: {actual!r} and {expected!r} differ in kind (integer vs non-integer)"
        )
        assert actual == expected, f"{path}: {actual!r} != {expected!r}"
    elif isinstance(expected, dict):
        assert isinstance(actual, dict), f"{path}: {actual!r} is not an object"
        assert sorted(actual) == sorted(expected), (
            f"{path}: keys {sorted(actual)} != {sorted(expected)}"
        )
        for key in expected:
            _same(actual[key], expected[key], f"{path}.{key}")
    elif isinstance(expected, list):
        assert isinstance(actual, list), f"{path}: {actual!r} is not an array"
        assert len(actual) == len(expected), f"{path}: length {len(actual)} != {len(expected)}"
        for i, (a, e) in enumerate(zip(actual, expected)):
            _same(a, e, f"{path}[{i}]")
    else:
        assert actual == expected, f"{path}: {actual!r} != {expected!r}"


def _integral_floats(expr) -> list[float]:
    """Every integral float literal in ``expr`` -- CONFORMANCE_SPEC §5.5.3.1
    rule 3 makes each of them an integer literal."""
    if isinstance(expr, float):
        return [expr] if math.isfinite(expr) and expr.is_integer() else []
    if isinstance(expr, ExprNode):
        return [x for arg in expr.args for x in _integral_floats(arg)]
    return []


def _check(actual_expr, expected, where: str) -> None:
    assert not _integral_floats(actual_expr), f"{where}: integral float literal in {actual_expr!r}"
    _same(_serialize_expression(actual_expr), expected, where)


def _species(lhs: dict) -> str:
    """The species a flattened left-hand side differentiates: ``D(x, t)``, or
    the lift's ``faq`` over ``D(index(x, ...), t)``."""
    if lhs["op"] == "faq":
        derivative = lhs["expr"]
        assert derivative["op"] == "D", lhs
        indexed = derivative["args"][0]
        assert indexed["op"] == "index", lhs
        return indexed["args"][0]
    assert lhs["op"] == "D", lhs
    return lhs["args"][0]


def test_corpus_was_actually_read() -> None:
    """Anti-vacuity: an empty or missing corpus must fail, not pass silently."""
    assert len(CASES) >= 3, f"expected at least 3 corpus cases, got {len(CASES)}"


@pytest.mark.parametrize("case", CASES, ids=CASE_IDS)
def test_derive_odes_tree(case: dict) -> None:
    system = load_document(case["document"]).reaction_systems[case["system"]]
    equations = derive_odes(system).equations
    expected = case["derive_odes"]
    assert len(equations) == len(expected)
    for k, (eq, exp) in enumerate(zip(equations, expected)):
        _check(eq.lhs, exp["lhs"], f"derive_odes[{k}].lhs")
        _check(eq.rhs, exp["rhs"], f"derive_odes[{k}].rhs")


@pytest.mark.parametrize("case", CASES, ids=CASE_IDS)
def test_flatten_tree(case: dict) -> None:
    origin = [{"component": case["system"]}]
    flat = flatten(load_document(case["document"]))
    selected = []
    for eq in flat.equations:
        mine = [c for c in eq.contributions if [o.to_json() for o in c.origins] == origin]
        if mine:
            assert len(mine) == 1, f"{len(mine)} contributions from {origin} in one equation"
            selected.append((eq, mine[0]))
    expected = case["flatten"]
    assert len(selected) == len(expected)
    for k, ((eq, contribution), exp) in enumerate(zip(selected, expected)):
        assert _species(_serialize_expression(eq.lhs)) == exp["species"]
        _check(contribution.expr, exp["contribution"], f"flatten[{k}].contribution")
        if not case["lifted"]:
            assert len(eq.contributions) == 1
            _check(eq.rhs, exp["contribution"], f"flatten[{k}].rhs")
            _same(
                _serialize_expression(eq.lhs),
                {"op": "D", "args": [exp["species"]], "wrt": "t"},
                f"flatten[{k}].lhs",
            )
