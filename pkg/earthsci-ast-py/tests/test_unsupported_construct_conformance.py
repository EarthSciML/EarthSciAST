"""Cross-language conformance for the two constructs no Python evaluator runs:
a discrete event and an implicit equation (EarthSciML/EarthSciAST#264).

Drives the shared manifest at ``tests/conformance/unsupported_construct/``.
Both constructs used to validate and then vanish: the event never fired and the
residual equation was never applied (the array interpreter only warned), so an
inline test reported the initial value as its answer. Every refusal case must
now fail with ``unsupported_construct`` naming the construct and the evaluator;
the control must still run.
"""

from __future__ import annotations

import json
import warnings

import pytest
from conftest import CONFORMANCE_DIR

from earthsci_ast import load_path
from earthsci_ast.error_handling import UNSUPPORTED_CONSTRUCT
from earthsci_ast.expression import UnsupportedConstructError
from earthsci_ast.inline_tests import run_inline_tests
from earthsci_ast.problem import esm_problem

CATEGORY_DIR = CONFORMANCE_DIR / "unsupported_construct"
MANIFEST_FILE = CATEGORY_DIR / "manifest.json"


def _load_manifest() -> dict:
    """A missing manifest is a hard failure, not a skip."""
    assert MANIFEST_FILE.exists(), f"manifest not found at {MANIFEST_FILE}"
    return json.loads(MANIFEST_FILE.read_text(encoding="utf-8"))


MANIFEST = _load_manifest()
CASES = MANIFEST["cases"]
REFUSALS = [c for c in CASES if c["expect"] == "refuse"]
CONTROLS = [c for c in CASES if c["expect"] == "run"]
EVALUATORS = {"array": "Python array interpreter", "scalar": "Python scalar interpreter"}


def test_the_manifest_names_the_registered_code():
    assert MANIFEST["code"] == UNSUPPORTED_CONSTRUCT == UnsupportedConstructError.code
    assert REFUSALS and CONTROLS


@pytest.mark.parametrize("case", REFUSALS, ids=[c["id"] for c in REFUSALS])
def test_the_build_refuses_the_construct(case):
    file = load_path(str(CATEGORY_DIR / case["path"]))
    with pytest.raises(UnsupportedConstructError) as info:
        esm_problem(file, (0.0, 1.0))
    err = info.value
    assert err.code == UNSUPPORTED_CONSTRUCT
    assert err.construct == case["construct"]
    assert err.evaluator == EVALUATORS[case["evaluator_path"]]
    assert str(err).startswith(f"{UNSUPPORTED_CONSTRUCT}: {case['construct']}")


@pytest.mark.parametrize("case", REFUSALS, ids=[c["id"] for c in REFUSALS])
def test_inline_tests_report_the_refusal_rather_than_a_number(case):
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        results = run_inline_tests(str(CATEGORY_DIR / case["path"]))
    assert results, f"{case['id']}: ran no assertions"
    for r in results:
        assert r.passed is False, f"{case['id']}: {r.message}"
        assert r.actual is None, f"{case['id']}: produced {r.actual!r}: {r.message}"
        assert f"{UNSUPPORTED_CONSTRUCT}: {case['construct']}" in r.message
        assert EVALUATORS[case["evaluator_path"]] in r.message


@pytest.mark.parametrize("case", CONTROLS, ids=[c["id"] for c in CONTROLS])
def test_the_control_still_runs(case):
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        results = run_inline_tests(str(CATEGORY_DIR / case["path"]))
    assert results, f"{case['id']}: ran no assertions"
    for r in results:
        assert r.passed is True, f"{case['id']}: {r.message}"
