"""The deprecated ``neg`` and ``pow`` spellings (esm-spec §4.2 "Deprecated ops").

A loader rewrites ``neg(x)`` to unary ``-``, ``pow(x, n)`` to ``^`` and a
``broadcast`` ``fn`` of ``neg`` to ``-`` at the wire boundary, and warns
``deprecated_op`` once per document naming every rewritten node.
"""

from __future__ import annotations

import copy
import json
import warnings

import pytest
from conftest import CONFORMANCE_DIR, FIXTURES_ROOT, VALID_DIR

from earthsci_ast.error_handling import DEPRECATED_OP
from earthsci_ast.op_registry import DEPRECATED_OPS
from earthsci_ast.parse import (
    EsmDeprecationWarning,
    load_document,
    load_path,
    rewrite_deprecated_ops,
)

SCALAR_OPS = CONFORMANCE_DIR / "scalar_operator_semantics" / "fixtures"


def _deprecated_op_warnings(record) -> list[str]:
    return [
        str(w.message)
        for w in record
        if issubclass(w.category, EsmDeprecationWarning)
        and str(w.message).startswith(DEPRECATED_OP)
    ]


def _rhs(esm_file, model: str, lhs: str):
    for eq in esm_file.models[model].equations:
        if eq.lhs == lhs:
            return eq.rhs
    raise AssertionError(f"no equation for {lhs}")


def test_registry_names_the_replacements():
    assert DEPRECATED_OPS == {"neg": "-", "pow": "^"}


def test_pow_alias_fixture_rewrites_pow_to_caret_with_one_warning():
    with warnings.catch_warnings(record=True) as record:
        warnings.simplefilter("always")
        f = load_path(SCALAR_OPS / "pow_alias.esm")
    msgs = _deprecated_op_warnings(record)
    assert len(msgs) == 1
    assert "/models/PowAlias/equations/0/rhs (pow)" in msgs[0]
    rhs = _rhs(f, "PowAlias", "pow_power")
    assert rhs.op == "^"
    assert rhs.args == ["two", 3]


def test_negated_observed_rewrites_neg_to_unary_minus():
    with warnings.catch_warnings(record=True) as record:
        warnings.simplefilter("always")
        f = load_path(SCALAR_OPS / "scalar_operator_semantics.esm")
    msgs = _deprecated_op_warnings(record)
    assert len(msgs) == 1
    assert "(neg)" in msgs[0]
    rhs = _rhs(f, "Ops", "negated")
    assert rhs.op == "-"
    assert rhs.args == ["four"]


def test_broadcast_fn_neg_is_rewritten():
    raw = json.loads((FIXTURES_ROOT / "fixtures" / "faq" / "27_broadcast_unary.esm").read_text())
    sites = rewrite_deprecated_ops(raw)
    assert len(sites) == 1 and sites[0].endswith("(broadcast fn neg)")
    text = json.dumps(raw)
    assert '"fn": "neg"' not in text


def test_rewrite_keeps_other_fields_and_skips_wrong_arity():
    doc = {
        "a": {"op": "neg", "args": ["x"], "id": "keep"},
        "b": {"op": "neg", "args": ["x", "y"]},
        "c": {"op": "pow", "args": ["x"]},
        "d": {"op": "pow", "args": ["x", 2]},
    }
    sites = rewrite_deprecated_ops(doc)
    assert sites == ["/a (neg)", "/d (pow)"]
    assert doc["a"] == {"op": "-", "args": ["x"], "id": "keep"}
    assert doc["b"]["op"] == "neg"
    assert doc["c"]["op"] == "pow"
    assert doc["d"]["op"] == "^"


def test_load_document_does_not_mutate_caller_and_warns_once():
    raw = json.loads((SCALAR_OPS / "pow_alias.esm").read_text())
    before = copy.deepcopy(raw)
    with pytest.warns(EsmDeprecationWarning, match=DEPRECATED_OP):
        load_document(raw)
    assert raw == before


@pytest.mark.parametrize(
    "path",
    [
        VALID_DIR / "solver_block.esm",
        VALID_DIR / "solver_time_span.esm",
        CONFORMANCE_DIR / "solver_time_span" / "fixtures" / "numbers.esm",
    ],
)
def test_migrated_fixture_loads_without_deprecated_op(path):
    with warnings.catch_warnings(record=True) as record:
        warnings.simplefilter("always")
        load_path(path)
    assert _deprecated_op_warnings(record) == []
