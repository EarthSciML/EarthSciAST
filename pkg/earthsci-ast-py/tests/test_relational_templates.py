"""The ``argmin`` / ``argmax`` templates of ``lib/relational.esm`` against the
``argmin`` / ``argmax`` arg-witness ops.

Every scenario of ``tests/conformance/relational_templates/scenarios.json`` is
run twice: through the expanded template (the numpy interpreter) and through
the op (the value-invention front door, with the candidates as a caller
array). The template must return the scenario's ``expected`` index; the op
must return the same index, except where the scenario pins ``op_expected``
(a NaN candidate after the first, which the op skips and the template picks).
The tier's two documents also pass their own inline tests under both
compilers.
"""

from __future__ import annotations

import json
import math
import warnings
from typing import Any

import numpy as np
import pytest
from conftest import REPO_ROOT

from earthsci_ast import load_string
from earthsci_ast.expr_walk import walk
from earthsci_ast.inline_tests import run_inline_tests
from earthsci_ast.numpy_interpreter import evaluate
from earthsci_ast.value_invention import materialize_value_invention

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


def _op_value(op: str, values: list) -> int:
    model = {
        "index_sets": {
            "points": {"kind": "interval", "size": 1},
            "cands": {"kind": "interval", "size": len(values)},
        },
        "variables": {
            "c": {"type": "parameter", "shape": ["cands"]},
            "a": {"type": "unknown", "shape": ["points"]},
        },
        "equations": [
            {
                "lhs": {"op": "index", "args": ["a", "i"]},
                "rhs": {
                    "op": "faq",
                    "output_idx": ["i"],
                    "ranges": {"i": {"from": "points"}},
                    "args": ["c"],
                    "expr": {
                        "op": op,
                        "args": ["c"],
                        "arg": "g",
                        "ranges": {"g": {"from": "cands"}},
                        "expr": {"op": "index", "args": ["c", "g"]},
                    },
                },
            }
        ],
    }
    ca = {"c": np.array([_decode(v) for v in values])}
    (idx,) = materialize_value_invention(model, ca, {}).assignments["a"]
    return idx


@pytest.mark.parametrize("scenario", SCENARIOS, ids=[s["name"] for s in SCENARIOS])
def test_template_index_matches_the_op(scenario: dict) -> None:
    op, values, expected = scenario["op"], scenario["values"], scenario["expected"]
    via_template = _template_value(op, values)
    assert via_template == float(expected), f"template gives {via_template!r}"
    via_op = _op_value(op, values)
    assert via_op == scenario.get("op_expected", expected), f"op gives {via_op!r}"


@pytest.mark.parametrize("fixture", ["argmin_template.esm", "nearest_generator_template_ode.esm"])
@pytest.mark.parametrize("compiler", ["interpreter", "native"])
def test_tier_document_inline_tests(fixture: str, compiler: str) -> None:
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", RuntimeWarning)
        results = run_inline_tests(str(TIER / "fixtures" / fixture), compiler=compiler)
    assert results
    failed = [r for r in results if not r.passed]
    assert not failed, failed


# --- Fixture rewrite: each op node (no ``join``/``filter``) becomes the
# template, the op's ``arg`` renamed to the template's loop symbol and n the
# size of its candidate set. Caller data become ``x ~ const(data)`` unknowns,
# and each arg-witness output ``a`` drives a state ``w_a`` with
# ``D(w_a[i]) = a[i]``, so an inline test reads the assignment at t = 1.


def _rename(e: Any, old: str, new: str) -> Any:
    if isinstance(e, str):
        return new if e == old else e
    if isinstance(e, list):
        return [_rename(x, old, new) for x in e]
    if isinstance(e, dict):
        return {k: _rename(v, old, new) for k, v in e.items()}
    return e


def _is_witness(e: Any) -> bool:
    return isinstance(e, dict) and e.get("op") in ("argmin", "argmax")


def _to_template(e: Any, index_sets: dict) -> Any:
    if _is_witness(e):
        assert "join" not in e and "filter" not in e
        op, arg = e["op"], e["arg"]
        ((sym, spec),) = e["ranges"].items()
        assert sym == arg
        n = index_sets[spec["from"]]["size"]
        return {
            "op": "apply_expression_template",
            "args": [],
            "name": op,
            "bindings": {"f": _rename(e["expr"], arg, f"k_{op}_1"), "n": n},
        }
    if isinstance(e, dict):
        return {k: _to_template(v, index_sets) for k, v in e.items()}
    if isinstance(e, list):
        return [_to_template(x, index_sets) for x in e]
    return e


def _template_document(rel: str, model_name: str, data: dict, want: list) -> dict:
    doc = json.loads((REPO_ROOT / rel).read_text())
    isets = doc["index_sets"]
    m = doc["models"][model_name]
    witness = [eq for eq in m["equations"] if "argm" in json.dumps(eq["rhs"])]
    text = json.dumps([eq["rhs"] for eq in witness])
    variables: dict[str, Any] = {}
    equations: list[dict] = []
    for k, v in data.items():
        if f'"{k}"' not in text:
            continue
        variables[k] = {"type": "unknown", "shape": m["variables"][k]["shape"]}
        equations.append({"lhs": k, "rhs": _const(v)})
    assertions = []
    for eq in witness:
        a, i = eq["lhs"]["args"]
        shape = m["variables"][a]["shape"]
        variables[a] = {"type": "unknown", "shape": shape}
        variables[f"w_{a}"] = {"type": "unknown", "shape": shape, "default": 0.0}
        equations.append({"lhs": eq["lhs"], "rhs": _to_template(eq["rhs"], isets)})
        rng = {i: {"from": shape[0]}}
        equations.append(
            {
                "lhs": {
                    "op": "faq",
                    "args": [],
                    "output_idx": [i],
                    "ranges": rng,
                    "expr": {
                        "op": "D",
                        "args": [{"op": "index", "args": [f"w_{a}", i]}],
                        "wrt": "t",
                    },
                },
                "rhs": {
                    "op": "faq",
                    "args": [a],
                    "output_idx": [i],
                    "ranges": rng,
                    "expr": {"op": "index", "args": [a, i]},
                },
            }
        )
        assertions += [
            {"variable": f"w_{a}[{k + 1}]", "time": 1.0, "expected": float(x)}
            for k, x in enumerate(want)
        ]
    return {
        "esm": "1.1.0",
        "metadata": {"name": "relational_fixture_rewrite"},
        "index_sets": isets,
        "models": {
            "M": {
                "expression_template_imports": [{"ref": str(LIBRARY)}],
                "variables": variables,
                "equations": equations,
                "tests": [
                    {
                        "id": "assignment",
                        "time_span": {"start": 0.0, "end": 1.0},
                        "tolerance": {"rel": 1e-9, "abs": 1e-12},
                        "assertions": assertions,
                    }
                ],
            }
        },
    }


_GEN = {"gx": [0.0, 1.0, 2.0], "gy": [0.0, 0.0, 0.0]}
_FIXTURES = [
    (
        "tests/valid/faq/nearest_generator_argmin.esm",
        "NearestGeneratorArgmin",
        {**_GEN, "px": [0.0, 1.0, 1.5, 2.0], "py": [0.0, 0.5, 0.0, 0.0]},
        [1, 2, 2, 3],
    ),
    (
        "tests/valid/faq/nearest_generator_argmin.esm",
        "NearestGeneratorArgmin",
        {**_GEN, "px": [2.0, 0.5, 0.5, 1.5], "py": [0.0, 0.0, 1.0, -0.5]},
        [3, 1, 1, 2],
    ),
    (
        "tests/valid/faq/nearest_generator_centroid.esm",
        "NearestGeneratorCentroid",
        {"gx": [0.0, 1.0, 2.0], "px": [0.0, 0.75, 1.25, 2.0], "rho": [1.0, 1.0, 3.0, 4.0]},
        [1, 2, 2, 3],
    ),
]


@pytest.mark.parametrize("case", range(len(_FIXTURES)))
@pytest.mark.parametrize("compiler", ["interpreter", "native"])
def test_fixture_rewritten_as_the_template_gives_the_op_buffer(case: int, compiler: str) -> None:
    rel, model_name, data, want = _FIXTURES[case]
    doc = json.loads((REPO_ROOT / rel).read_text())
    model = doc["models"][model_name]
    if "index_sets" not in model:
        model = {**model, "index_sets": doc["index_sets"]}
    ca = {k: np.array(v) for k, v in data.items()}
    assert materialize_value_invention(model, ca, {}).assignments["assign"] == want
    results = run_inline_tests(
        load_string(json.dumps(_template_document(rel, model_name, data, want))),
        compiler=compiler,
    )
    assert len(results) == len(want)
    failed = [r for r in results if not r.passed]
    assert not failed, failed
