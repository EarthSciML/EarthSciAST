"""Ops and fields removed at esm 2.0.0 are a coded load error, ``removed_op``.

``aggregate`` (the old alias of ``faq``), ``fn``, ``table_lookup``, ``skolem``, ``rank``, ``intersect_polygon``,
``polygon_intersection_area``, ``argmin``, ``argmax`` and the ``function_tables``
block (top-level or on a component) are rejected BY NAME at the wire boundary
(``parse.prepare_document_ops``), before schema validation, so none of them can
load as an open rewrite-target op and fail later as ``unlowered_operator``. The
message names the op or field and its node path, and points at the codemod.
"""

from __future__ import annotations

import copy
import json

import pytest

from earthsci_ast import load_string, validate_text
from earthsci_ast.error_handling import ERROR_CODES, REMOVED_OP
from earthsci_ast.errors import ParseError
from earthsci_ast.op_registry import REMOVED_OPS
from earthsci_ast.parse_expression import ExpressionParseError, parse_expression

REMOVED_AT_2_0_0 = sorted(op for op, version in REMOVED_OPS.items() if version == "2.0.0")


def _doc(rhs) -> dict:
    return {
        "esm": "1.3.0",
        "metadata": {"name": "removed_op_probe"},
        "models": {
            "M": {
                "variables": {
                    "x": {"type": "unknown", "default": 0.0, "units": "1"},
                    "a": {"type": "parameter", "default": 1.0, "units": "1"},
                },
                "equations": [{"lhs": {"op": "D", "args": ["x"], "wrt": "t"}, "rhs": rhs}],
            }
        },
    }


def _load_error(doc: dict) -> ParseError:
    with pytest.raises(ParseError) as excinfo:
        load_string(json.dumps(doc))
    return excinfo.value


def test_the_removed_set_is_the_contract_list():
    assert REMOVED_AT_2_0_0 == sorted(
        [
            "aggregate",
            "fn",
            "table_lookup",
            "skolem",
            "rank",
            "intersect_polygon",
            "polygon_intersection_area",
            "argmin",
            "argmax",
        ]
    )
    assert ERROR_CODES.REMOVED_OP == REMOVED_OP == "removed_op"


@pytest.mark.parametrize("op", REMOVED_AT_2_0_0)
def test_each_removed_op_is_removed_op_naming_op_path_and_codemod(op):
    # Nested under an ordinary op, so the path is not just the equation root.
    err = _load_error(_doc({"op": "+", "args": ["a", {"op": op, "args": ["a"]}]}))
    assert err.code == "removed_op"
    msg = str(err)
    assert msg.startswith("removed_op")
    assert f'"op": "{op}"' in msg
    assert "/models/M/equations/0/rhs/args/1" in msg
    assert "esm 2.0.0" in msg
    assert "python -m earthsci_ast.migrate" in msg


@pytest.mark.parametrize("op", REMOVED_AT_2_0_0)
def test_removed_op_is_rejected_before_schema_validation(op):
    # The node carries none of the op's former fields and the document is
    # otherwise schema-invalid; the name alone decides.
    doc = _doc({"op": op, "args": []})
    doc["models"]["M"]["not_a_field"] = True
    assert _load_error(doc).code == "removed_op"


def test_top_level_function_tables_is_removed_op_naming_the_field():
    doc = _doc("a")
    doc["function_tables"] = {"t": {"axes": [{"name": "x", "values": [0, 1]}], "data": [0, 1]}}
    err = _load_error(doc)
    assert err.code == "removed_op"
    assert "`function_tables`" in str(err)
    assert "/function_tables" in str(err)
    assert "python -m earthsci_ast.migrate" in str(err)


def test_component_function_tables_is_removed_op_naming_the_field():
    doc = _doc("a")
    doc["models"]["M"]["function_tables"] = {}
    err = _load_error(doc)
    assert err.code == "removed_op"
    assert "/models/M/function_tables" in str(err)


def test_removed_op_inside_a_template_body_is_rejected():
    doc = _doc({"op": "apply_expression_template", "args": [], "name": "t", "bindings": {}})
    doc["esm"] = "1.3.0"
    doc["models"]["M"]["expression_templates"] = {
        "t": {"params": [], "body": {"op": "fn", "name": "datetime.year", "args": ["t"]}}
    }
    err = _load_error(doc)
    assert err.code == "removed_op"
    assert "/models/M/expression_templates/t/body" in str(err)


def test_arrayop_keeps_its_own_message():
    err = _load_error(_doc({"op": "arrayop", "args": []}))
    assert err.code == "removed_op"
    assert "esm 0.8.0" in str(err)


def test_a_document_without_removed_constructs_still_loads():
    load_string(json.dumps(_doc({"op": "*", "args": ["a", 2.0]})))


def test_the_input_document_is_not_modified():
    doc = _doc({"op": "skolem", "args": ["a"]})
    before = copy.deepcopy(doc)
    _load_error(doc)
    assert doc == before


def test_validate_reports_the_load_error():
    result = validate_text(json.dumps(_doc({"op": "rank", "args": ["a"]})))
    assert not result.is_valid
    assert any("removed_op" in e.message for e in result.schema_errors)


@pytest.mark.parametrize(
    "text",
    [
        "fn(a)",
        "aggregate(a)",
        "skolem(a, b)",
        "rank(a)",
        "argmin(a)",
        "intersect_polygon(a, b)",
        "polygon_intersection_area(a, b)",
        "table_lookup(a)",
        "datetime.year(t)",
    ],
)
def test_the_text_parser_refuses_a_removed_op(text):
    with pytest.raises(ExpressionParseError, match="removed_op"):
        parse_expression(text)
