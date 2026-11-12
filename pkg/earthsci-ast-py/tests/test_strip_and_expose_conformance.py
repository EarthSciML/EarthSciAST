"""Strip and expose (issue #543, CONFORMANCE_SPEC §5.57), driven by the shared
manifest at ``tests/conformance/strip_and_expose/``.

Python implements ``strip`` and ``stripped`` in full and refuses
``compile_kernels`` with ``compiler_unavailable`` (API_SPEC §5.8).
"""

from __future__ import annotations

import json

import pytest
from conftest import CONFORMANCE_DIR

from earthsci_ast import compile_kernels, is_stripped, stripped
from earthsci_ast.compiler import CompilerUnavailableError
from earthsci_ast.problem import EnsembleProblem, esm_problem, init, remake, solve
from earthsci_ast.strip import StrippedProblemNotSolvableError, canonical_json_value

CATEGORY_DIR = CONFORMANCE_DIR / "strip_and_expose"
MANIFEST = json.loads((CATEGORY_DIR / "manifest.json").read_text())


def _path(rel: str) -> str:
    return str(CATEGORY_DIR / rel)


@pytest.mark.parametrize("case", MANIFEST["per_class"], ids=lambda c: c["id"])
def test_per_class_strip(case):
    if case["builds_with"] is not None:
        esm_problem(_path(case["path"]), (0.0, 1.0), strip=case["builds_with"])
    for classes in case["refuses_with"]:
        with pytest.raises(Exception) as info:
            esm_problem(_path(case["path"]), (0.0, 1.0), strip=classes)
        code = case.get("refusal_code")
        if code is not None:
            assert code in str(info.value) or getattr(info.value, "code", None) == code, (
                f"{case['id']} with {classes}: {info.value}"
            )


@pytest.mark.parametrize("case", MANIFEST["stripped_goldens"], ids=lambda c: c["id"])
def test_stripped_object_matches_the_golden(case):
    prob = esm_problem(
        _path(case["path"]),
        tuple(case.get("tspan", (0.0, 1.0))),
        p=case.get("p") or None,
        strip=case["strip"],
    )
    want = (CATEGORY_DIR / case["golden"]).read_text()
    assert stripped(prob).canonical_json() == want


@pytest.mark.parametrize("case", MANIFEST["not_solvable"], ids=lambda c: c["id"])
def test_a_stripped_problem_is_not_solvable(case):
    prob = esm_problem(_path(case["path"]), tuple(case["tspan"]), strip=case["strip"])
    if case["expect"] == "solves":
        assert not is_stripped(prob)
        solve(prob)
        return
    assert is_stripped(prob)
    for call in (solve, init):
        with pytest.raises(StrippedProblemNotSolvableError) as info:
            call(prob)
        assert info.value.code == case["expect"]


def test_a_remade_stripped_problem_is_still_not_solvable():
    case = next(c for c in MANIFEST["not_solvable"] if c["id"] == "stripped_discrete_event")
    prob = esm_problem(_path(case["path"]), tuple(case["tspan"]), strip=case["strip"])
    remade = remake(prob, tspan=(0.0, 2.0))
    assert is_stripped(remade)
    assert stripped(remade).canonical_json() == stripped(prob).canonical_json()
    for call in (solve, init):
        with pytest.raises(StrippedProblemNotSolvableError):
            call(remade)
    ens = EnsembleProblem(prob, lambda p, i: remake(p, tspan=(0.0, 1.0 + i)))
    with pytest.raises(StrippedProblemNotSolvableError):
        solve(ens, trajectories=2)


def test_z_layout_follows_the_callers_metaparameters():
    prob = esm_problem(
        _path("fixtures/z0_warm_start.esm"),
        (0.5, 1.0),
        metaparameters={"NC": 4},
        strip=["algebraic"],
    )
    s = stripped(prob)
    assert s.z_layout["W.v"] == {"base": 2, "shape": [4]}
    assert s.z0 == [2.5] + [1.5] * 4


def test_compile_kernels_is_unavailable():
    case = MANIFEST["kernels"][0]
    prob = esm_problem(_path(case["path"]), (0.0, 1.0), strip=case["strip"])
    with pytest.raises(CompilerUnavailableError):
        compile_kernels(prob, case["specs"])


def test_canonical_numbers_are_julia_style():
    assert canonical_json_value([1.0e-9, 1.5e-5, 0.000123456, 999999.5, 1.0e6, 2.0, -0.25]) == (
        "[1.0e-9,1.5e-5,0.000123456,999999.5,1000000,2,-0.25]"
    )
    assert canonical_json_value(1.0000005e6) == "1.0000005e6"
    assert canonical_json_value({"b": 1, "a": None}) == '{"a":null,"b":1}'


def test_an_unknown_class_is_refused():
    case = MANIFEST["kernels"][0]
    with pytest.raises(ValueError):
        esm_problem(_path(case["path"]), (0.0, 1.0), strip=["wiener"])
