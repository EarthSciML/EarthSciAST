"""Cross-language conformance: generalized ``ic`` equations and the
initialization system (esm 2.5.0; esm-spec §11.4.2–§11.4.4, API_SPEC §5.8).

Shared fixtures and the manifest live under ``tests/conformance/ic_system/``
(repo root); Julia and Rust run the same cases. A *case* builds its fixture with
the case's ``tspan``, ``p``, ``u0`` and ``strip`` and checks the whole initial
state, or the construction refusal's code, or members of the stripped object.
A *load* checks what the loader made of the document: its warnings, the
equations it appended, its ``guesses``, a load refusal, or ``validate``'s codes.

Every refusal is compared by its machine-readable ``code``, exactly. A case on a
scalar document with no ``strip`` also runs under ``compiler="sympy"``, the
scalar pathway, which must agree with the native build.
"""

from __future__ import annotations

import json
import re
import warnings
from pathlib import Path

import pytest

from earthsci_ast.parse import load_path
from earthsci_ast.problem import ReturnCode, esm_problem, solve
from earthsci_ast.serialize import _serialize_esm_file
from earthsci_ast.strip import is_stripped, stripped
from earthsci_ast.validation import validate

_ROOT = Path(__file__).resolve().parents[3] / "tests" / "conformance" / "ic_system"
_MANIFEST = json.loads((_ROOT / "manifest.json").read_text())
_TOL = _MANIFEST["tolerances"]


def _build(case: dict, compiler: str | None = None):
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        return esm_problem(
            str(_ROOT / case["fixture"]),
            tuple(float(x) for x in case["tspan"]),
            p={k: float(v) for k, v in case.get("p", {}).items()},
            u0={k: float(v) for k, v in case.get("u0", {}).items()},
            strip=tuple(case.get("strip", ())),
            compiler=compiler,
        )


def _initial_state(prob) -> dict[str, float]:
    if prob.compiler == "sympy":
        build = prob.scalar_build
        return {name: float(build.y0[k]) for k, name in enumerate(build.state_names)}
    build = prob.build
    assert build is not None, "the native build keeps its initial state"
    return {name: float(build.y0[k]) for k, name in enumerate(build.elem_names)}


def _is_scalar(fixture: str) -> bool:
    """A document the scalar pathway runs: no index sets, no shaped variable."""
    doc = json.loads((_ROOT / fixture).read_text())
    if doc.get("index_sets"):
        return False
    return not any(
        v.get("shape")
        for m in doc.get("models", {}).values()
        for v in m.get("variables", {}).values()
    )


def _code(err: BaseException) -> str | None:
    return getattr(err, "code", None)


def _close(got: float, want: float) -> bool:
    return abs(got - want) <= float(_TOL["atol"]) + float(_TOL["rtol"]) * abs(want)


def _same_json(got, want) -> bool:
    """Structural equality with numbers compared by value."""
    if isinstance(want, bool) or isinstance(got, bool):
        return got == want
    if isinstance(want, (int, float)) and isinstance(got, (int, float)):
        return float(got) == float(want)
    if isinstance(want, dict):
        return (
            isinstance(got, dict)
            and set(got) == set(want)
            and all(_same_json(got[k], want[k]) for k in want)
        )
    if isinstance(want, list):
        return (
            isinstance(got, list)
            and len(got) == len(want)
            and all(_same_json(a, b) for a, b in zip(got, want))
        )
    return got == want


def test_manifest_requires_python() -> None:
    assert _MANIFEST["category"] == "ic_system"
    assert "python" in _MANIFEST["bindings_required"]
    assert len(_MANIFEST["cases"]) >= 20 and len(_MANIFEST["loads"]) >= 8


def _check_case(case: dict, compiler: str | None = None) -> None:
    cid = case["id"] if compiler is None else f"{case['id']} under {compiler}"
    if "error_code" in case:
        with pytest.raises(Exception) as excinfo:
            _build(case, compiler)
        err = excinfo.value
        assert _code(err) == case["error_code"], (
            f"{cid}: expected {case['error_code']}, got {type(err).__name__} "
            f"(code {_code(err)!r}): {err}"
        )
        return
    prob = _build(case, compiler)
    start = _initial_state(prob)
    # The `z` unknowns `strip=["algebraic"]` removed leave the state layout `u`
    # (API_SPEC §5.8); this binding's build keeps their slots internally.
    if case.get("strip"):
        z = set(stripped(prob).unknowns)
        start = {n: v for n, v in start.items() if n.split("[", 1)[0] not in z}
    want = case["expected"]
    assert sorted(start) == sorted(want), f"{cid}: the state elements"
    for name, value in want.items():
        assert _close(start[name], float(value)), f"{cid}: {name} = {start[name]}, expected {value}"
    if "stripped" in case:
        got = json.loads(stripped(prob).canonical_json())
        for member, value in case["stripped"].items():
            if member == "algebraic_z0":
                assert _same_json(got["algebraic"]["z0"], value), (
                    f"{cid}: z0 {got['algebraic']['z0']}, expected {value}"
                )
            elif isinstance(value, dict):
                # The keys of the member the case names.
                for key, sub in value.items():
                    assert _same_json(got[member][key], sub), (
                        f"{cid}: stripped {member}.{key} {got[member][key]}, expected {sub}"
                    )
            else:
                assert _same_json(got[member], value), (
                    f"{cid}: stripped {member} {got[member]}, expected {value}"
                )
    if case.get("not_solvable"):
        assert is_stripped(prob)
        with pytest.raises(Exception) as excinfo:
            solve(prob)
        assert _code(excinfo.value) == "stripped_problem_not_solvable"
    elif not case.get("strip"):
        t0 = float(case["tspan"][0])
        sol = solve(prob, saveat=[t0])
        assert sol.retcode is ReturnCode.Success, sol.message
        first = {name: float(sol.y[k][0]) for k, name in enumerate(sol.vars)}
        for name, value in want.items():
            assert _close(first[name], float(value)), f"{cid}: solve starts {name} at {first[name]}"


@pytest.mark.parametrize("case", _MANIFEST["cases"], ids=lambda c: c["id"])
def test_case(case: dict) -> None:
    _check_case(case)


_SCALAR_CASES = [c for c in _MANIFEST["cases"] if not c.get("strip") and _is_scalar(c["fixture"])]


def test_scalar_cases_exist() -> None:
    assert len(_SCALAR_CASES) >= 10


@pytest.mark.parametrize("case", _SCALAR_CASES, ids=lambda c: c["id"])
def test_case_scalar_pathway(case: dict) -> None:
    """The scalar (SymPy) pathway plans and evaluates the initialization system
    with the native build's planner and step evaluation, and agrees with it."""
    _check_case(case, "sympy")


def _load(entry: dict) -> tuple[object, list[str]]:
    with warnings.catch_warnings(record=True) as caught:
        warnings.simplefilter("always")
        file = load_path(str(_ROOT / entry["fixture"]))
    return file, [str(w.message) for w in caught]


_WARNING_CODE = re.compile(r"^([a-z][a-z0-9_]*): ")


@pytest.mark.parametrize("entry", _MANIFEST["loads"], ids=lambda e: e["id"])
def test_load(entry: dict) -> None:
    lid = entry["id"]
    if "load_error" in entry:
        with pytest.raises(Exception) as excinfo:
            _load(entry)
        assert _code(excinfo.value) == entry["load_error"], (
            f"{lid}: {type(excinfo.value).__name__} (code {_code(excinfo.value)!r}): "
            f"{excinfo.value}"
        )
        return
    file, messages = _load(entry)
    if "warnings" in entry:
        codes = sorted({m.group(1) for m in map(_WARNING_CODE.match, messages) if m})
        assert codes == sorted(entry["warnings"]), f"{lid}: {messages}"
    doc = _serialize_esm_file(file)
    if "model" in entry:
        model = doc["models"][entry["model"]]
        assert entry.get("no_field", "initialization_equations") not in model
        if "equations_tail" in entry:
            tail = entry["equations_tail"]
            got = model["equations"][-len(tail) :]
            assert _same_json([{"lhs": e["lhs"], "rhs": e["rhs"]} for e in got], tail), (
                f"{lid}: appended {got}"
            )
        if "equations_count" in entry:
            assert len(model.get("equations", [])) == entry["equations_count"]
        for name, value in entry.get("parameter_defaults", {}).items():
            got = model["variables"][name].get("default")
            assert _same_json(got, value), f"{lid}: {name}'s default {got}, expected {value}"
        if "guesses" in entry:
            assert _same_json(model.get("guesses"), entry["guesses"]), model.get("guesses")
    if "validate_errors" in entry:
        codes = [e.code for e in validate(file).structural_errors]
        if entry["validate_errors"]:
            for code in entry["validate_errors"]:
                assert code in codes, f"{lid}: {codes}"
        else:
            assert not [c for c in codes if c.startswith("ic_")], f"{lid}: {codes}"


def test_remake_reruns_the_triangular_part() -> None:
    """``remake`` with a new supplied value re-evaluates the equations that read
    it (esm-spec §11.4.3), and a stripped Problem's rebuild keeps its implicit
    initialization system stripped."""
    from earthsci_ast.problem import remake

    by_id = {c["id"]: c for c in _MANIFEST["cases"]}
    base = by_id["triangular_defaults"]
    moved = remake(_build(base), u0={"M.x": 10.0})
    want = by_id["triangular_u0_of_an_explicit_state"]["expected"]
    start = _initial_state(moved)
    for name, value in want.items():
        assert _close(start[name], float(value)), f"{name} = {start[name]}, expected {value}"

    prob = _build(by_id["implicit_stripped"])
    again = remake(prob, p={"M.total": 20.0})
    assert is_stripped(again)
    assert _initial_state(again)["M.w"] == 7.0
