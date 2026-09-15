"""esm-spec §9.6.6 ``unevaluable_operator``: an evaluable-core op with no rule.

An op that IS in the §4.2 evaluable core but that the NumPy interpreter has no
evaluation rule for must be refused with the coded ``unevaluable_operator``
diagnostic, naming the op — never with an uncoded interpreter error, and never
evaluated to a number. The check precedes evaluation: an op in the untaken
branch of an ``ifelse`` is refused too, so a reactive raise (one that fires only
when evaluation reaches the node) does not satisfy it.
"""

from __future__ import annotations

import json

import pytest
from conftest import CONFORMANCE_DIR

from earthsci_ast import numpy_interpreter
from earthsci_ast.esm_types import ExprNode
from earthsci_ast.numpy_interpreter import (
    NumpyInterpreterError,
    UnevaluableOperatorError,
    UnreachableSpatialOperatorError,
    evaluate,
)
from earthsci_ast.parse import load_path
from earthsci_ast.problem import esm_problem

_FIXTURE = json.loads((CONFORMANCE_DIR / "unevaluable_operator" / "cases.json").read_text())


def _refusal(fn) -> Exception:
    with pytest.raises(Exception) as info:
        fn()
    return info.value


def _expr(obj) -> object:
    if isinstance(obj, dict):
        return ExprNode(
            op=obj["op"],
            args=[_expr(a) for a in obj.get("args", [])],
            **{
                k: (_expr(v) if k == "expr" else v)
                for k, v in obj.items()
                if k not in ("op", "args")
            },
        )
    return obj


@pytest.mark.parametrize("case", _FIXTURE["cases"], ids=lambda c: c["id"])
def test_shared_fixture_is_refused_before_evaluation(case) -> None:
    err = _refusal(lambda: evaluate(_expr(case["expression"]), _FIXTURE["bindings"]))
    assert getattr(err, "code", None) == _FIXTURE["code"], repr(err)
    assert f"'{case['op']}'" in str(err)
    # Still a NumpyInterpreterError, so existing `except` clauses keep working.
    assert isinstance(err, NumpyInterpreterError)


def test_shared_fixture_control_still_evaluates() -> None:
    control = _FIXTURE["control"]
    assert evaluate(_expr(control["expression"]), _FIXTURE["bindings"]) == control["expected"]


@pytest.mark.parametrize(
    "op, args",
    [
        ("rank", ["x"]),
        ("distinct", ["x"]),
        ("argmin", ["x"]),
        ("argmax", ["x"]),
        ("apply_expression_template", []),
        ("table_lookup", ["x"]),
        ("ic", ["x"]),
        ("Pre", ["x"]),
        ("enum", ["colors", "red"]),
    ],
)
def test_core_op_without_rule_is_coded(op, args) -> None:
    err = _refusal(lambda: evaluate(ExprNode(op=op, args=args), {"x": 1.0}))
    assert getattr(err, "code", None) == "unevaluable_operator", repr(err)
    assert f"'{op}'" in str(err)


def test_open_tier_op_stays_unlowered() -> None:
    err = _refusal(lambda: evaluate(ExprNode(op="godunov_hamiltonian", args=["x"]), {"x": 1.0}))
    assert isinstance(err, UnreachableSpatialOperatorError)
    assert err.code == "unlowered_operator"


def _scalar_probe(tmp_path, rhs: dict):
    doc = {
        "esm": "1.0.0",
        "metadata": {"name": "UnevaluableProbe"},
        "models": {
            "M": {
                "variables": {
                    "p": {"type": "parameter", "units": "1", "default": 2.0},
                    "u": {"type": "unknown", "units": "1", "default": 1.0},
                },
                "equations": [{"lhs": {"op": "D", "args": ["u"], "wrt": "t"}, "rhs": rhs}],
            }
        },
    }
    path = tmp_path / "probe.esm"
    path.write_text(json.dumps(doc))
    return load_path(str(path))


@pytest.mark.parametrize("case", _FIXTURE["cases"], ids=lambda c: c["id"])
def test_model_build_refuses_before_evaluation(tmp_path, case) -> None:
    """The simulation front door walks every equation before anything is built
    or evaluated, so a model carrying the op is refused up front."""
    file = _scalar_probe(tmp_path, case["expression"])
    err = _refusal(lambda: esm_problem(file, (0.0, 1.0)))
    assert getattr(err, "code", None) == _FIXTURE["code"], repr(err)
    assert f"'{case['op']}'" in str(err)


def test_model_build_accepts_the_control(tmp_path) -> None:
    file = _scalar_probe(tmp_path, _FIXTURE["control"]["expression"])
    esm_problem(file, (0.0, 1.0))


def test_no_rule_set_matches_the_dispatch() -> None:
    """Every core op either has an :func:`eval_expr` rule or is in
    ``_NO_RULE_OPS`` — never both, never neither. The dispatch is probed with the
    walk bypassed, so an op listed as rule-less that actually has a rule (or the
    reverse) fails here."""
    ctx = numpy_interpreter.EvalContext(
        state_layout={},
        state_shapes={},
        param_values={"x": 0.5},
        observed_values={},
        y=numpy_interpreter.np.empty((0,)),
        t=0.0,
    )
    for op in sorted(numpy_interpreter._EVALUABLE_CORE_OPS - {"D"}):
        try:
            numpy_interpreter.eval_expr(ExprNode(op=op, args=["x"]), ctx)
            has_rule = True
        except UnevaluableOperatorError:
            has_rule = False
        except Exception:  # an arity or payload error: the arm exists
            has_rule = True
        assert has_rule == (op not in numpy_interpreter._NO_RULE_OPS), op
