"""Cross-language conformance for the text-form expression parser.

Drives the shared corpus at ``tests/conformance/expression_parse/cases.json``
(generated from the TypeScript oracle, ``@earthsciml/ast`` parseExpression /
parseEquation). Every binding must satisfy the same three-part contract on each
accepted expression, plus the two refusal lists:

1. ``parse_expression(text)`` serialized to JSON deep-equals ``ast``;
2. ``to_ascii(parse_expression(text)) == reprint``;
3. ``parse_expression(reprint)`` serialized deep-equals ``ast`` (the printer is
   idempotent on its own output, so a reprint re-parses to the same tree).

``expression_errors`` / ``equation_errors`` entries must be REFUSED with
:class:`~earthsci_ast.parse_expression.ExpressionParseError`; each entry's
``reason`` is prose written for a human and is deliberately NOT asserted — only
the refusal itself is a cross-language contract.

The comparison is done on the JSON view of the parsed tree (see
:func:`_as_json`), not on Python object identity: JSON is the language-neutral
surface the corpus pins, so a binding cannot "pass" by matching its own internal
representation.
"""

from __future__ import annotations

import json

import pytest
from conftest import CONFORMANCE_DIR

from earthsci_ast import ExpressionParseError, parse_equation, parse_expression, to_ascii
from earthsci_ast.esm_types import ExprNode
from earthsci_ast.serialize import _serialize_expression

CASES_FILE = CONFORMANCE_DIR / "expression_parse" / "cases.json"


def _load_corpus() -> dict:
    """Read the shared corpus; a missing file is a hard failure, not a skip —
    the corpus IS the contract this module exists to enforce."""
    assert CASES_FILE.exists(), f"expression-parse corpus not found at {CASES_FILE}"
    return json.loads(CASES_FILE.read_text(encoding="utf-8"))


CORPUS = _load_corpus()


def _as_json(value):
    """JSON view of a parsed expression, for deep comparison with the corpus.

    The text parser emits operator nodes as JSON-shaped dicts (see
    ``earthsci_ast.parse_expression``), so this walks dicts and lists and routes
    every scalar leaf through the package's own
    :func:`~earthsci_ast.serialize._serialize_expression` — which applies the
    CONFORMANCE_SPEC §5.5.3.1 number canonicalization (an integral float emits as
    an integer) and also accepts a typed ``ExprNode`` should one ever appear in a
    tree. Nothing here re-implements serialization.
    """
    if isinstance(value, dict):
        return {k: _as_json(v) for k, v in value.items()}
    if isinstance(value, list):
        return [_as_json(v) for v in value]
    if isinstance(value, (int, float, str, ExprNode)):
        return _serialize_expression(value)
    return value


def _case_id(case: dict) -> str:
    """Readable pytest id: the source text (with its tier, when one is given)."""
    tier = case.get("tier")
    text = case["text"] or "<empty>"
    return f"{tier}:{text}" if tier else text


_EXPRESSIONS = CORPUS["expressions"]
_EXPRESSION_ERRORS = CORPUS["expression_errors"]
_EQUATIONS = CORPUS["equations"]
_EQUATION_ERRORS = CORPUS["equation_errors"]


def test_corpus_is_fully_populated():
    """Guard against a truncated / silently emptied corpus making the
    parametrized tests below vacuously green."""
    assert len(_EXPRESSIONS) == 240
    assert len(_EXPRESSION_ERRORS) == 9
    assert len(_EQUATIONS) == 3
    assert len(_EQUATION_ERRORS) == 2


@pytest.mark.parametrize("case", _EXPRESSIONS, ids=_case_id)
def test_expression_parses_to_the_pinned_ast(case):
    """Contract 1: the text parses to exactly the AST the oracle pins."""
    assert _as_json(parse_expression(case["text"])) == case["ast"]


@pytest.mark.parametrize("case", _EXPRESSIONS, ids=_case_id)
def test_expression_reprints_to_the_pinned_text(case):
    """Contract 2: `to_ascii` of the parse is the pinned reprint — the parser is
    the printer's inverse."""
    assert to_ascii(parse_expression(case["text"])) == case["reprint"]


@pytest.mark.parametrize("case", _EXPRESSIONS, ids=_case_id)
def test_reprint_reparses_to_the_same_ast(case):
    """Contract 3: re-parsing the reprint lands on the same AST, so text is a
    stable round-trip surface for an editor."""
    assert _as_json(parse_expression(case["reprint"])) == case["ast"]


@pytest.mark.parametrize("case", _EXPRESSION_ERRORS, ids=_case_id)
def test_malformed_expression_is_refused(case):
    """Refusals are part of the contract: an op with no text surface, or a
    malformed string, must raise rather than silently parse to something else.
    The corpus `reason` is prose and is not asserted."""
    with pytest.raises(ExpressionParseError):
        parse_expression(case["text"])


@pytest.mark.parametrize("case", _EQUATIONS, ids=lambda c: c["text"])
def test_equation_splits_on_the_top_level_lone_equals(case):
    equation = parse_equation(case["text"])
    assert _as_json(equation.lhs) == case["lhs"]
    assert _as_json(equation.rhs) == case["rhs"]


@pytest.mark.parametrize("case", _EQUATION_ERRORS, ids=lambda c: c["text"])
def test_malformed_equation_is_refused(case):
    with pytest.raises(ExpressionParseError):
        parse_equation(case["text"])


def test_parse_error_carries_a_source_offset():
    """`pos` is the 0-based character offset of the failure — the field an editor
    needs to place a squiggle. Pinned here because no corpus entry asserts it."""
    with pytest.raises(ExpressionParseError) as excinfo:
        parse_expression("a + b @ c")
    assert excinfo.value.pos == 6
    # Subclasses ValueError (errors.py convention), so `except ValueError` callers
    # keep catching it.
    assert isinstance(excinfo.value, ValueError)
