"""Cross-language conformance for a data-fed parameter nothing bound
(esm-spec §9.6.6 ``data_source_unbound``, CONFORMANCE_SPEC §5.46).

Drives the shared manifest at ``tests/conformance/data_source_unbound/``.

Before the ruling this binding built such a document, chose the cadence-
segmented ``loaders`` engine for it, let the in-tree default provider try the
URL the source declares, stashed the failure on the problem as a ``Failure``
Solution, and then tripped over it inside ``solve`` with an ``AttributeError``
from the loader driver — an uncoded crash where the answer is a registered
refusal. A caller who pinned the parameter with ``p`` took the same path and got
the same crash, so the documented escape hatch did not work either.
"""

from __future__ import annotations

import json
import warnings

import pytest
from conftest import CONFORMANCE_DIR

from earthsci_ast import esm_problem, load_path, solve
from earthsci_ast.error_handling import DATA_SOURCE_UNBOUND
from earthsci_ast.expression import DataSourceUnboundError
from earthsci_ast.inline_tests import run_inline_tests

CATEGORY_DIR = CONFORMANCE_DIR / "data_source_unbound"
MANIFEST_FILE = CATEGORY_DIR / "manifest.json"


def _load_manifest() -> dict:
    """A missing manifest is a hard failure, not a skip."""
    assert MANIFEST_FILE.exists(), f"manifest not found at {MANIFEST_FILE}"
    return json.loads(MANIFEST_FILE.read_text(encoding="utf-8"))


MANIFEST = _load_manifest()
CASES = MANIFEST["cases"]
REFUSALS = [c for c in CASES if c["expect"] == "refuse"]
CONTROLS = [c for c in CASES if c["expect"] == "run"]
COMPILERS = ["native", "interpreter"]


def _codes_of(exc: Exception) -> set[str]:
    """Every registered code ``exc`` reports.

    A build refusal carries one on ``.code``; a structural-validation failure
    carries one per finding and spells none of them in its prose, so reading
    the message alone would make this tier pass on a coincidence of wording.
    """
    codes = {c for c in [getattr(exc, "code", None)] if c}
    for finding in getattr(exc, "findings", None) or []:
        code = finding[0] if isinstance(finding, tuple) else getattr(finding, "code", None)
        if code:
            codes.add(code)
    return codes


def test_the_manifest_names_the_registered_code():
    assert MANIFEST["code"] == DATA_SOURCE_UNBOUND == DataSourceUnboundError.code
    assert REFUSALS and CONTROLS


@pytest.mark.parametrize("compiler", COMPILERS)
@pytest.mark.parametrize("case", REFUSALS, ids=[c["id"] for c in REFUSALS])
def test_both_compilers_refuse_an_unbound_data_feed_with_the_same_code(case, compiler):
    """The heart of the category: one answer, whichever compiler is named.

    A binding whose two compilers disagree is reporting a compiler property
    where the question is about the document.
    """
    path = str(CATEGORY_DIR / case["path"])
    with pytest.raises(Exception) as info:  # noqa: PT011 — the code is the assertion
        esm_problem(path, (0.0, 1.0), compiler=compiler)
    codes = _codes_of(info.value)
    assert codes & set(case["accepts"]), (
        f"{case['id']} under {compiler}: refused with {codes or 'no code'}, none of "
        f"{case['accepts']}: {info.value}"
    )
    # An unresolvable source is refused by the LOAD's structural validation,
    # which speaks about the `update.source` and not about a parameter binding;
    # the build-time refusal is the one that must name the parameter.
    if DATA_SOURCE_UNBOUND in codes:
        text = str(info.value)
        assert case["parameter"] in text
        assert case["source"] in text


def test_a_pinned_parameter_builds_and_its_value_is_the_one_that_runs():
    """A ``p`` value BINDS the parameter, and reaches the right-hand side.

    The second half is what matters: a build that merely stopped refusing and
    then integrated the ``default`` would pass a refusal test and defeat its
    purpose. 0.5 is the pin and 0.1 is the document's default, so ``exp(-0.5)``
    and ``exp(-0.1)`` tell them apart at the third digit.
    """
    path = str(CATEGORY_DIR / "fixtures/unbound_scalar_forcing.esm")
    for compiler in COMPILERS:
        prob = esm_problem(path, (0.0, 1.0), p={"Forcing.k": 0.5}, compiler=compiler)
        # The pin takes the parameter out of the loader machinery entirely:
        # nothing is going to fetch a source for it, so the document is one
        # build for the whole span.
        assert prob.engine == "array", compiler
        sol = solve(prob, saveat=[0.0, 1.0])
        # The band is the solver's, not the ruling's: exp(-0.5) and exp(-0.1)
        # differ by a third of their value, so nothing here needs a tight one.
        assert sol.y[0][-1] == pytest.approx(0.6065306597126334, rel=1e-4), (
            f"{compiler}: the pinned rate 0.5 must be the one integrated, not the "
            "document's default 0.1 (which gives 0.9048…)"
        )


@pytest.mark.parametrize("case", CONTROLS, ids=[c["id"] for c in CONTROLS])
def test_the_controls_still_run(case):
    """Through the inline-test runner, which is where the pin control's
    ``parameter_overrides`` lives and which is the surface an author uses."""
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        results = run_inline_tests(str(CATEGORY_DIR / case["path"]))
    assert results, f"{case['id']}: ran no assertions"
    for r in results:
        assert r.passed, f"{case['id']}: {r.message}"


@pytest.mark.parametrize("case", REFUSALS, ids=[c["id"] for c in REFUSALS])
def test_the_inline_test_runner_reports_the_refusal_rather_than_a_number(case):
    path = str(CATEGORY_DIR / case["path"])
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        try:
            results = run_inline_tests(path)
        except Exception as exc:  # noqa: BLE001
            # A binding whose LOAD validates structurally never reaches the
            # runner; that refusal is the same answer one layer earlier.
            assert _codes_of(exc) & set(case["accepts"]), str(exc)
            with pytest.raises(Exception):  # noqa: PT011
                load_path(path)
            return
    assert results, f"{case['id']}: ran no assertions"
    for r in results:
        assert r.passed is False, f"{case['id']}: {r.message}"
        assert r.actual is None, f"{case['id']}: produced {r.actual!r}: {r.message}"
        assert any(code in r.message for code in case["accepts"]), r.message

