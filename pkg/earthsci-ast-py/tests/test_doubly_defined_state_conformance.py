"""Cross-language conformance for one unknown carrying two whole definitions.

Drives the shared manifest at ``tests/conformance/doubly_defined_state/``.
``D(x, t) ~ f`` beside ``x ~ g`` is two equations for one unknown (esm-spec
§4.9.4), so the document is unbalanced and ``validate`` reports
``equation_count_mismatch``. The ruling this category pins is that the BUILD
says the same thing rather than tie-breaking in favour of the derivative and
integrating a system free of the constraint the file declares. Each refusal case
must fail the build with that code, naming the unknown and both equations; each
control must still run.
"""

from __future__ import annotations

import json
import warnings

import pytest
from conftest import CONFORMANCE_DIR

from earthsci_ast import load_path, validate
from earthsci_ast.error_handling import ErrorCode
from earthsci_ast.inline_tests import run_inline_tests
from earthsci_ast.problem import esm_problem
from earthsci_ast.sympy_bridge import SimulationError

CATEGORY_DIR = CONFORMANCE_DIR / "doubly_defined_state"
MANIFEST_FILE = CATEGORY_DIR / "manifest.json"


def _load_manifest() -> dict:
    """A missing manifest is a hard failure, not a skip."""
    assert MANIFEST_FILE.exists(), f"manifest not found at {MANIFEST_FILE}"
    return json.loads(MANIFEST_FILE.read_text(encoding="utf-8"))


MANIFEST = _load_manifest()
CASES = MANIFEST["cases"]
REFUSALS = [c for c in CASES if c["expect"] == "refuse"]
CONTROLS = [c for c in CASES if c["expect"] == "run"]


def test_the_manifest_names_the_registered_code():
    assert MANIFEST["code"] == ErrorCode.EQUATION_COUNT_MISMATCH.value
    assert REFUSALS and CONTROLS


@pytest.mark.parametrize("case", REFUSALS, ids=[c["id"] for c in REFUSALS])
@pytest.mark.parametrize("compiler", [None, "native", "interpreter", "sympy"])
def test_the_build_refuses_the_second_definition(case, compiler):
    """Refused under EVERY named compiler: it is a property of the file."""
    file = load_path(str(CATEGORY_DIR / case["path"]))
    with pytest.raises(SimulationError) as info:
        esm_problem(file, (0.0, 1.0), compiler=compiler)
    message = str(info.value)
    assert ErrorCode.EQUATION_COUNT_MISMATCH.value in message
    # The unknown and BOTH equations are named, so the author can see which of
    # the two definitions to remove.
    assert case["unknown"] in message
    assert "D(" in message
    assert "§4.9.4" in message


@pytest.mark.parametrize("case", REFUSALS, ids=[c["id"] for c in REFUSALS])
def test_the_structural_validator_agrees(case):
    """`validate` and the build answer the same document the same way, which is
    what makes the refusal a property of the file rather than of the engine."""
    result = validate(load_path(str(CATEGORY_DIR / case["path"])))
    assert not result.is_valid
    assert ErrorCode.EQUATION_COUNT_MISMATCH.value in [e.code for e in result.structural_errors]


@pytest.mark.parametrize("case", REFUSALS, ids=[c["id"] for c in REFUSALS])
def test_inline_tests_report_the_refusal_rather_than_a_number(case):
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        results = run_inline_tests(str(CATEGORY_DIR / case["path"]))
    assert results, f"{case['id']}: ran no assertions"
    for r in results:
        assert r.passed is False, f"{case['id']}: {r.message}"
        assert r.actual is None, f"{case['id']}: produced {r.actual!r}: {r.message}"
        assert ErrorCode.EQUATION_COUNT_MISMATCH.value in r.message


@pytest.mark.parametrize("case", CONTROLS, ids=[c["id"] for c in CONTROLS])
def test_the_control_still_runs(case):
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        results = run_inline_tests(str(CATEGORY_DIR / case["path"]))
    assert results, f"{case['id']}: ran no assertions"
    for r in results:
        assert r.passed is True, f"{case['id']}: {r.message}"
