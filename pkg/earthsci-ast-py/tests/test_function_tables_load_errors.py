"""The esm-spec §9.5.5 table checks and their pinned order, driven from the
shared ledger ``tests/conformance/function_tables/load_errors/cases.json``.

Each case is one function table (id ``T``) and one ``table_lookup`` reading it.
The table is built IN MEMORY -- the schema would reject the one-value and empty
axes, and JSON cannot carry the NaNs and infinities several cases need (the
ledger spells them ``"NaN"``, ``"Inf"``, ``"-Inf"``). Each case runs through
the SAME load-time table check ``load`` and ``validate()`` use
(:func:`~earthsci_ast.load_checks.iter_document_errors`, ruling Q-106), and
through this binding's real §9.5.3 lowering,
:func:`~earthsci_ast.lower_table_lookup.lower_table_lookups`. Every case runs;
Python's table ``data`` holds binary64 NaNs and infinities, so none is skipped.
The cases a document can carry live in ``tests/invalid/function_table_*.esm``
(``test_closed_functions.py`` sweeps them).
"""

from __future__ import annotations

import json
import math

import pytest
from conftest import CONFORMANCE_DIR

from earthsci_ast import load_document, validate
from earthsci_ast.esm_types import ExprNode, FunctionTable, FunctionTableAxis
from earthsci_ast.load_checks import check_document, iter_document_errors
from earthsci_ast.lower_table_lookup import TableLookupError, lower_table_lookups

LEDGER = CONFORMANCE_DIR / "function_tables" / "load_errors" / "cases.json"
_SPEC = json.loads(LEDGER.read_text())
CASES = _SPEC["cases"]

# A document with one equation to hang the lookup on. Its own table is a
# placeholder: each case replaces it with the table it builds.
_DOC = {
    "esm": "1.0.0",
    "metadata": {"name": "load_errors", "authors": ["test"]},
    "function_tables": {
        "T": {
            "axes": [{"name": "x", "values": [0.0, 1.0]}],
            "data": [0.0, 1.0],
        }
    },
    "models": {
        "M": {
            "variables": {"y": {"type": "unknown", "default": 0.0}},
            "equations": [{"lhs": "y", "rhs": 0.0}],
        }
    },
}


_NON_FINITE = {"NaN": math.nan, "Inf": math.inf, "-Inf": -math.inf}


def _nan(value):
    """The ledger's ``"NaN"`` / ``"Inf"`` / ``"-Inf"`` strings as binary64
    values, anywhere in a value."""
    if isinstance(value, str) and value in _NON_FINITE:
        return _NON_FINITE[value]
    if isinstance(value, list):
        return [_nan(v) for v in value]
    return value


def _table(spec: dict) -> FunctionTable:
    return FunctionTable(
        axes=[FunctionTableAxis(name=a["name"], values=_nan(a["values"])) for a in spec["axes"]],
        data=_nan(spec["data"]),
        interpolation=spec.get("interpolation"),
        out_of_bounds=spec.get("out_of_bounds"),
        outputs=list(spec["outputs"]) if "outputs" in spec else None,
        shape=list(spec["shape"]) if "shape" in spec else None,
    )


def _lookup(spec: dict) -> ExprNode:
    return ExprNode(
        op="table_lookup",
        args=list(spec.get("args", [])),
        table=spec["table"],
        table_axes=dict(spec["axes"]),
        output=spec.get("output"),
    )


def test_the_ledger_is_not_empty():
    """A ledger that lost its cases would make every parametrized case vanish
    silently; pin that it holds them, and that the case names are unique."""
    assert _SPEC["table_id"] == "T"
    assert len(CASES) >= 15
    assert any(c["name"].startswith("data_neg_inf") for c in CASES)
    names = [c["name"] for c in CASES]
    assert len(set(names)) == len(names)


@pytest.mark.parametrize("case", CASES, ids=[c["name"] for c in CASES])
def test_a_table_reports_the_first_rule_it_breaks(case):
    file = load_document(_DOC)
    file.function_tables = {_SPEC["table_id"]: _table(case["table"])}
    file.models["M"].equations[0].rhs = _lookup(case["lookup"])

    expected = case["expected_error_code"]

    # The load-time check (the one `load` runs, ruling Q-106) and validate().
    found = [(path, err.code) for path, err in iter_document_errors(file)]
    result = validate(file)
    if expected is None:
        assert found == [], found
        check_document(file)
        assert not [e for e in result.structural_errors if e.code.startswith("table_")]
    else:
        assert found and found[0][1] == expected, (case["breaks"], found)
        with pytest.raises(TableLookupError) as excinfo:
            check_document(file)
        assert excinfo.value.code == expected
        assert not result.is_valid
        assert expected in [e.code for e in result.structural_errors]

    # The lowering repeats the checks (esm-spec §9.5.5: a binding MAY).
    if expected is None:
        lowered = lower_table_lookups(file)
        rhs = lowered.models["M"].equations[0].rhs
        assert isinstance(rhs, ExprNode) and rhs.op == "fn"
        return
    with pytest.raises(TableLookupError) as excinfo:
        lower_table_lookups(file)
    assert excinfo.value.code == expected, (case["breaks"], str(excinfo.value))
