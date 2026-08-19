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
import warnings
from pathlib import Path

import pytest

from earthsci_ast.pushdown_rewrite import desugar_pushdown, pushdown_diagnostics

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
    doc = json.loads(input_path.read_text())
    pristine = copy.deepcopy(doc)
    mn = fixture.get("model_name")
    # A fixture either carries a rewrite `golden` (the pattern fires) or declares
    # `fires: false` and pins the residual `diagnostics` instead.
    fires = fixture.get("fires", True) is not False

    with warnings.catch_warnings():
        warnings.simplefilter("ignore")   # the residual diagnostic is a warning
        rewritten = desugar_pushdown(doc, model_name=mn)

        if fires:
            golden = json.loads((_TESTS_DIR / fixture["golden"]).read_text())
            assert rewritten is not doc, "the pattern must fire on the input fixture"
            diffs = _deep_eq(rewritten, golden)
            assert not diffs, "rewritten document differs from golden:\n" + "\n".join(
                diffs[:40]
            )
            # Idempotency: the golden (and our own output) never re-desugars.
            assert desugar_pushdown(rewritten) is rewritten
            assert desugar_pushdown(golden) is golden
        else:
            # A `fires: false` fixture is NOT rewritten — and says why.
            assert rewritten is doc, "the pattern must NOT fire on this fixture"

        dg = fixture.get("diagnostics")
        if dg is not None:
            golden_dg = json.loads((_TESTS_DIR / dg).read_text())
            diffs = _deep_eq(pushdown_diagnostics(doc, model_name=mn), golden_dg)
            assert not diffs, "diagnostics differ from golden:\n" + "\n".join(diffs[:40])

    # Input purity: the rewrite returned a fresh document.
    assert not _deep_eq(doc, pristine)
