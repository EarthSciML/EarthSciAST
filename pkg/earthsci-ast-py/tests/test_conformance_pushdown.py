"""Conformance harness adapter — pushdown category (Phase 3).

Contract (tests/conformance/pushdown/README.md): run ``desugar_pushdown`` on
each manifest input and deep-compare the result to the committed golden as
parsed JSON (key order free, numbers by value); assert idempotency on the
golden and input purity. The goldens are emitted by the Julia reference
(scripts/generate-pushdown-goldens.jl), so this is the cross-language
agreement gate for the Python port.
"""

from __future__ import annotations

import copy
import json
from pathlib import Path

import pytest

from earthsci_ast.pushdown_rewrite import desugar_pushdown

_TESTS_DIR = Path(__file__).resolve().parents[3] / "tests"
_MANIFEST = _TESTS_DIR / "conformance" / "pushdown" / "manifest.json"


def _deep_eq(a, b, path="$"):
    """Deep equality on parsed JSON: dict key order free, numbers by value
    (0 == 0.0 but True != 1), lists element-wise in order. Returns a list of
    difference descriptions (empty ⇒ equal) so failures localize."""
    diffs = []
    if isinstance(a, dict) and isinstance(b, dict):
        if set(a) != set(b):
            diffs.append(f"{path}: key sets differ: {sorted(set(a) ^ set(b))}")
            return diffs
        for k in a:
            diffs.extend(_deep_eq(a[k], b[k], f"{path}.{k}"))
    elif isinstance(a, list) and isinstance(b, list):
        if len(a) != len(b):
            diffs.append(f"{path}: list lengths {len(a)} != {len(b)}")
            return diffs
        for i, (x, y) in enumerate(zip(a, b)):
            diffs.extend(_deep_eq(x, y, f"{path}[{i}]"))
    elif isinstance(a, bool) or isinstance(b, bool):
        if a is not b:
            diffs.append(f"{path}: {a!r} != {b!r}")
    elif isinstance(a, (int, float)) and isinstance(b, (int, float)):
        if not (a == b or (a != a and b != b)):  # NaN-tolerant exact equality
            diffs.append(f"{path}: {a!r} != {b!r}")
    elif a != b:
        diffs.append(f"{path}: {a!r} != {b!r}")
    return diffs


def _fixtures():
    manifest = json.loads(_MANIFEST.read_text())
    assert manifest["category"] == "pushdown"
    assert manifest["fixtures"]
    return [pytest.param(f, id=f["id"]) for f in manifest["fixtures"]]


@pytest.mark.parametrize("fixture", _fixtures())
def test_pushdown_rewrite_matches_golden(fixture):
    input_path = _TESTS_DIR / fixture["input"]
    golden_path = _TESTS_DIR / fixture["golden"]
    doc = json.loads(input_path.read_text())
    pristine = copy.deepcopy(doc)
    golden = json.loads(golden_path.read_text())

    rewritten = desugar_pushdown(doc, model_name=fixture.get("model_name"))
    assert rewritten is not doc, "the pattern must fire on the input fixture"

    diffs = _deep_eq(rewritten, golden)
    assert not diffs, "rewritten document differs from golden:\n" + "\n".join(diffs[:40])

    # Idempotency: the golden (and our own output) never re-desugars.
    assert desugar_pushdown(rewritten) is rewritten
    assert desugar_pushdown(golden) is golden

    # Input purity: the rewrite returned a fresh document.
    assert not _deep_eq(doc, pristine)
