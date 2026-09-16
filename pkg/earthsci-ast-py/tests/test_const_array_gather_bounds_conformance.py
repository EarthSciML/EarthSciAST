"""Cross-language conformance: an out-of-range const-array gather
(esm-spec §4.3.3, CONFORMANCE_SPEC §5.5.5 and §5.40).

The shared fixtures live under ``tests/conformance/const_array_gather_bounds/``
(repo root); the Julia runner (``conformance_const_array_gather_bounds_test.jl``)
and the Rust runner (``const_array_gather_bounds_conformance.rs``) gate the same
manifest. An ``index`` whose base is a ``const`` literal written inline, or an
observed defined by one, must fail with ``E_TREEWALK_CONSTARRAY_OOB`` when any
index lies outside its own axis.
"""

from __future__ import annotations

import json
from pathlib import Path

import numpy as np
import pytest

from earthsci_ast.esm_types import ExprNode
from earthsci_ast.inline_tests import run_inline_tests
from earthsci_ast.numpy_codegen import _gather_hoisted
from earthsci_ast.numpy_interpreter import (
    EvalContext,
    NumpyInterpreterError,
    _compile_expr,
    eval_expr,
)

_ROOT = Path(__file__).resolve().parents[3] / "tests" / "conformance" / "const_array_gather_bounds"


def _manifest() -> dict:
    return json.loads((_ROOT / "manifest.json").read_text())


def test_manifest_requires_python() -> None:
    m = _manifest()
    assert m["category"] == "const_array_gather_bounds"
    assert "python" in m["bindings_required"]
    outcomes = {f["outcome"] for f in m["fixtures"]}
    assert outcomes == {"pass", "error"}


@pytest.mark.parametrize("fixture", _manifest()["fixtures"], ids=lambda f: f["id"])
def test_fixture(fixture: dict) -> None:
    results = run_inline_tests(str(_ROOT / fixture["path"]), model_name=fixture["model"])
    assert len(results) == 1
    r = results[0]
    if fixture["outcome"] == "pass":
        assert r.passed, r.message
        assert r.actual == fixture["expected"]
    else:
        assert not r.passed
        assert r.actual is None
        assert fixture["error_code"] in (r.message or ""), r.message


def _ctx(const_names: frozenset[str] = frozenset()) -> EvalContext:
    return EvalContext(
        state_layout={},
        state_shapes={},
        param_values={},
        observed_values={},
        y=np.empty(0),
        t=0.0,
        derived_rings={"tbl": np.array([[1.0, 2.0], [3.0, 4.0], [5.0, 6.0]])},
        const_array_names=const_names,
    )


_INLINE = ExprNode(op="const", args=[], value=[[1.0, 2.0], [3.0, 4.0], [5.0, 6.0]])


@pytest.mark.parametrize("base", ["named", "inline"])
@pytest.mark.parametrize("idx", [(0, 1), (4, 1), (1, 0), (1, 3)])
def test_both_evaluators_raise_per_axis(base: str, idx: tuple[int, int]) -> None:
    """The tree walker and the compiled closure agree: out of range on either axis
    is the spec code, whether the table is named or written inline."""
    node = ExprNode(op="index", args=["tbl" if base == "named" else _INLINE, *idx])
    ctx = _ctx(frozenset({"tbl"}))
    for evaluate in (lambda: eval_expr(node, ctx), lambda: _compile_expr(node)(ctx)):
        with pytest.raises(NumpyInterpreterError, match="E_TREEWALK_CONSTARRAY_OOB"):
            evaluate()


def test_a_named_array_that_is_not_const_is_not_checked() -> None:
    """The rule follows the base: the same array under a name the context does not
    list as const keeps the existing gather."""
    node = ExprNode(op="index", args=["tbl", 3, 2])
    assert eval_expr(node, _ctx()) == 6.0


def test_hoisted_gather_checks_per_axis() -> None:
    arr = np.array([[1.0, 2.0], [3.0, 4.0], [5.0, 6.0]])
    zi = (np.array([0, 3]), np.array([0, 0]))  # 1-based rows 1 and 4
    with pytest.raises(NumpyInterpreterError, match="E_TREEWALK_CONSTARRAY_OOB"):
        _gather_hoisted(arr, zi, "tbl")
