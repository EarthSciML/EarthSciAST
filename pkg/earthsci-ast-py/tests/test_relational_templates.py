"""The ``argmin`` / ``argmax`` templates of ``lib/relational.esm``.

Every scenario of ``tests/conformance/relational_templates/scenarios.json`` runs
through the expanded template (the numpy interpreter), which must return the
scenario's ``expected`` index. The tier's two documents also pass their own
inline tests under both compilers.
"""

from __future__ import annotations

import json
import math
import warnings
from typing import Any

import pytest
from conftest import REPO_ROOT

from earthsci_ast import load_string
from earthsci_ast.expr_walk import walk
from earthsci_ast.inline_tests import run_inline_tests
from earthsci_ast.numpy_interpreter import evaluate

LIBRARY = REPO_ROOT / "lib" / "relational.esm"
TIER = REPO_ROOT / "tests" / "conformance" / "relational_templates"
SCENARIOS = json.loads((TIER / "scenarios.json").read_text())["scenarios"]


def _decode(v: Any) -> float:
    if v == "NaN":
        return math.nan
    if v == "Inf":
        return math.inf
    if v == "-Inf":
        return -math.inf
    return float(v)


def _num_den(v: Any) -> tuple[float, float]:
    """A candidate as ``num / den``, so a non-finite one fits in a ``const``."""
    if v == "NaN":
        return 0.0, 0.0
    if v == "Inf":
        return 1.0, 0.0
    if v == "-Inf":
        return -1.0, 0.0
    return float(v), 1.0


def _const(v: Any) -> dict:
    return {"op": "const", "args": [], "value": v}


def _template_value(op: str, values: list) -> float:
    sym = f"k_{op}_1"
    nums, dens = zip(*(_num_den(v) for v in values))
    f = {
        "op": "/",
        "args": [
            {"op": "index", "args": [_const(list(nums)), sym]},
            {"op": "index", "args": [_const(list(dens)), sym]},
        ],
    }
    doc = {
        "esm": "1.1.0",
        "metadata": {"name": "relational_template_probe"},
        "models": {
            "M": {
                "expression_template_imports": [{"ref": str(LIBRARY)}],
                "variables": {"r": {"type": "unknown", "units": "1", "default": 0.0}},
                "equations": [
                    {
                        "lhs": {"op": "D", "args": ["r"], "wrt": "t"},
                        "rhs": {
                            "op": "apply_expression_template",
                            "args": [],
                            "name": op,
                            "bindings": {"f": f, "n": len(values)},
                        },
                    }
                ],
            }
        },
    }
    (eq,) = load_string(json.dumps(doc)).models["M"].equations
    assert not any(getattr(n, "op", None) == "apply_expression_template" for n in walk(eq.rhs)), (
        "the template reference survived load"
    )
    with warnings.catch_warnings():
        # 0/0 and 1/0 are how the scenario writes a non-finite candidate.
        warnings.simplefilter("ignore", RuntimeWarning)
        return evaluate(eq.rhs, {})


@pytest.mark.parametrize("scenario", SCENARIOS, ids=[s["name"] for s in SCENARIOS])
def test_template_index_matches_the_scenario(scenario: dict) -> None:
    op, values, expected = scenario["op"], scenario["values"], scenario["expected"]
    via_template = _template_value(op, values)
    assert via_template == float(expected), f"template gives {via_template!r}"


@pytest.mark.parametrize("fixture", ["argmin_template.esm", "nearest_generator_template_ode.esm"])
@pytest.mark.parametrize("compiler", ["interpreter", "native"])
def test_tier_document_inline_tests(fixture: str, compiler: str) -> None:
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", RuntimeWarning)
        results = run_inline_tests(str(TIER / "fixtures" / fixture), compiler=compiler)
    assert results
    failed = [r for r in results if not r.passed]
    assert not failed, failed
