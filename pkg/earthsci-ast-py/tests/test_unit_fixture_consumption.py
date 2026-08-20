"""Units fixtures consumption runner (gt-dt0o).

The three ``units_*.esm`` files in ``tests/valid/`` carry inline ``tests``
blocks (id / parameter_overrides / initial_conditions / time_span /
assertions) added in gt-p3v. Schema parse coverage is asserted in
``test_unit_validation.py``'s Cross-binding suite. This file closes the
schema-vs-execution gap: every assertion's target (all of which are
observed variables at t = 0) is actually evaluated under the test's
bindings and compared against the expected value within the resolved
tolerance (assertion → test → model, falling back to rtol = 1e-6).

Corrupting an expected value in any fixture — or reverting the
``pressure_drop`` fix from gt-p3v — must cause this suite to fail.

Python's ``earthsci_ast.esm_types.Model`` does not carry the inline
``tests`` block, so this runner walks the raw JSON directly rather than
going through ``load()``. The shape is schema-validated elsewhere; here
we only need the fields listed above.
"""

from __future__ import annotations

import json
import math
from typing import Any, Dict, Mapping, Tuple

import pytest
from conftest import VALID_DIR

from earthsci_ast.classification import observed_definitions


FIXTURES_DIR = VALID_DIR
FIXTURES = [
    "units_conversions.esm",
    "units_dimensional_analysis.esm",
    "units_propagation.esm",
]


def _evaluate(expr: Any, bindings: Mapping[str, float]) -> float:
    """Evaluate a raw ESM expression (ints, floats, strings, or op dicts).

    Raises ``KeyError`` if a variable reference is not in ``bindings`` —
    the caller uses that signal to retry observed resolution once
    dependencies have been computed.
    """
    if isinstance(expr, bool):  # bool is int subclass; rule it out defensively
        raise TypeError(f"unexpected bool in expression: {expr!r}")
    if isinstance(expr, (int, float)):
        return float(expr)
    if isinstance(expr, str):
        if expr not in bindings:
            raise KeyError(expr)
        return float(bindings[expr])
    if isinstance(expr, dict):
        op = expr["op"]
        args = [_evaluate(a, bindings) for a in expr["args"]]
        if op == "+":
            if len(args) == 1:
                return args[0]
            return sum(args)
        if op == "-":
            if len(args) == 1:
                return -args[0]
            if len(args) == 2:
                return args[0] - args[1]
            raise ValueError(f"'-' needs 1 or 2 args, got {len(args)}")
        if op == "*":
            result = 1.0
            for v in args:
                result *= v
            return result
        if op == "/":
            if len(args) != 2:
                raise ValueError(f"'/' needs 2 args, got {len(args)}")
            return args[0] / args[1]
        if op in ("^", "**"):
            if len(args) != 2:
                raise ValueError(f"'^' needs 2 args, got {len(args)}")
            return args[0] ** args[1]
        if op == "log":
            return math.log(args[0])
        if op == "exp":
            return math.exp(args[0])
        if op == "sqrt":
            return math.sqrt(args[0])
        if op == "sin":
            return math.sin(args[0])
        if op == "cos":
            return math.cos(args[0])
        if op == "tan":
            return math.tan(args[0])
        if op == "abs":
            return abs(args[0])
        raise ValueError(f"unsupported op: {op!r}")
    raise TypeError(f"unsupported expression node: {type(expr).__name__}")


def _resolve_tol(model_tol: Any, test_tol: Any, assertion_tol: Any) -> Tuple[float, float]:
    for cand in (assertion_tol, test_tol, model_tol):
        if cand is None:
            continue
        rel = float(cand.get("rel") or 0.0)
        abs_ = float(cand.get("abs") or 0.0)
        return rel, abs_
    return 1e-6, 0.0


def _resolve_observed(model: Dict[str, Any], bindings: Dict[str, float]) -> None:
    """Evaluate each observed unknown from its DEFINING EQUATION's RHS.

    An observed unknown carries no `expression` from esm 1.0.0 -- it is the
    unknown a bare-variable-LHS equation defines (esm-spec §6.3.1) -- so the
    definitions come from `observed_definitions`, the binding's own §6.3.1
    derivation, rather than from a field on the variable. The fixed-point loop
    is unchanged: it resolves in dependency order without needing one.
    """
    definitions = observed_definitions(model)
    for _ in range(len(definitions) + 1):
        progress = False
        for vname, expr in definitions.items():
            if vname in bindings or expr is None:
                continue
            try:
                bindings[vname] = _evaluate(expr, bindings)
                progress = True
            except KeyError:
                continue
        if not progress:
            return


def _collect_tests():
    cases = []
    for fname in FIXTURES:
        path = FIXTURES_DIR / fname
        raw = json.loads(path.read_text())
        for mname, model in (raw.get("models") or {}).items():
            for t in model.get("tests") or []:
                cases.append(
                    pytest.param(
                        fname,
                        mname,
                        model,
                        t,
                        id=f"{fname}::{mname}::{t['id']}",
                    )
                )
    return cases


@pytest.mark.parametrize("fname,mname,model,test", _collect_tests())
def test_units_fixture_inline_assertion(fname, mname, model, test):
    bindings: Dict[str, float] = {}
    for vname, var in (model.get("variables") or {}).items():
        # A declared default seeds the binding whichever of the two types the
        # variable is: for a parameter it is the value, for an unknown the
        # initial condition.
        if var.get("default") is not None:
            bindings[vname] = float(var["default"])
    for name, val in (test.get("initial_conditions") or {}).items():
        bindings[name] = float(val)
    for name, val in (test.get("parameter_overrides") or {}).items():
        bindings[name] = float(val)

    _resolve_observed(model, bindings)

    for a in test["assertions"]:
        rel, abs_ = _resolve_tol(
            model.get("tolerance"),
            test.get("tolerance"),
            a.get("tolerance"),
        )
        assert a["variable"] in bindings, (
            f"{fname}::{mname}::{test['id']}: {a['variable']} not resolved "
            f"(have {sorted(bindings)})"
        )
        actual = bindings[a["variable"]]
        expected = float(a["expected"])
        if abs_ > 0 and expected == 0.0:
            assert math.isclose(actual, expected, abs_tol=abs_), (
                f"{fname}::{mname}::{test['id']}:{a['variable']} "
                f"actual={actual} expected={expected} atol={abs_}"
            )
        elif rel > 0:
            assert math.isclose(actual, expected, rel_tol=rel, abs_tol=abs_), (
                f"{fname}::{mname}::{test['id']}:{a['variable']} "
                f"actual={actual} expected={expected} rtol={rel} atol={abs_}"
            )
        else:
            assert math.isclose(actual, expected, abs_tol=abs_), (
                f"{fname}::{mname}::{test['id']}:{a['variable']} "
                f"actual={actual} expected={expected} atol={abs_}"
            )


def test_each_fixture_has_at_least_one_test():
    total = 0
    for fname in FIXTURES:
        path = FIXTURES_DIR / fname
        raw = json.loads(path.read_text())
        for model in (raw.get("models") or {}).values():
            total += len(model.get("tests") or [])
    assert total > 0, "expected at least one inline test across the units fixtures"
