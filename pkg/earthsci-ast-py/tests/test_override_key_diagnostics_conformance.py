"""Cross-language conformance: unrecognized ``parameter_overrides`` keys raise
(esm-spec §6.6.2 "Unrecognized override keys").

Shared fixture + manifest live under
``tests/conformance/override_key_diagnostics/`` (repo root); the Julia runner
(``conformance_override_key_diagnostics_test.jl``) and the Rust runner
(``override_key_diagnostics_conformance.rs``) drive the same cases.

The category carries no numeric golden — it compares DIAGNOSTIC OUTCOMES. Each
binding raises its own idiomatic error type (the manifest's ``error_surface``
records which); what must agree across the three is the *classification* of
each key: resolved, ambiguous, or unknown.

Python and Julia used to ignore an unmatched key silently, so an author's
override did nothing and the run still reported a verdict — the same
silent-wrong-answer shape that made a mis-keyed override invisible before the
§6.6.2 name resolution existed. Rust already raised ``InvalidParameter``.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from earthsci_ast.errors import AmbiguousParameterError, UnknownParameterError
from earthsci_ast.parse import load
from earthsci_ast.simulation import simulate

_ROOT = (
    Path(__file__).resolve().parents[3] / "tests" / "conformance" / "override_key_diagnostics"
)
_MANIFEST = _ROOT / "manifest.json"


def _manifest() -> dict:
    return json.loads(_MANIFEST.read_text())


def _fixture() -> dict:
    return _manifest()["fixtures"][0]


def _load_fixture():
    return load(str(_ROOT / _fixture()["path"]))


def test_manifest_shape() -> None:
    manifest = _manifest()
    assert manifest["category"] == "override_key_diagnostics"
    assert set(manifest["bindings_required"]) == {"julia", "python", "rust"}
    outcomes = {c["outcome"] for c in _fixture()["cases"]}
    # All three outcomes must be exercised, or the category proves nothing about
    # ambiguous-vs-unknown being distinct.
    assert outcomes == {"resolved", "ambiguous", "unknown"}


def test_flattened_parameter_names_match_the_manifest() -> None:
    """The whole category rests on `gain` being carried by two components and
    `solo` by one; pin that so a change in flattening cannot quietly defuse it."""
    from earthsci_ast.flatten import flatten

    flat = flatten(_load_fixture())
    assert sorted(flat.parameters) == sorted(_fixture()["parameters"])


@pytest.mark.parametrize("case", _fixture()["cases"], ids=lambda c: c["key"])
def test_override_key_outcome(case: dict) -> None:
    esm = _load_fixture()
    manifest = _manifest()
    rtol = float(manifest["tolerances"]["trajectory_rtol"])
    atol = float(manifest["tolerances"]["trajectory_atol"])
    params = {case["key"]: float(case["value"])}
    kw = {"method": "RK45", "rtol": 1e-12, "atol": 1e-14}

    if case["outcome"] == "resolved":
        result = simulate(esm, tspan=(0.0, 1.0), parameters=params, **kw)
        assert result.success, result.message
        expected = case["trajectory_at_t1"]
        idx = {n: k for k, n in enumerate(result.vars)}
        for name, want in expected.items():
            got = float(result.y[idx[name]][-1])
            assert got == pytest.approx(want, rel=rtol, abs=atol), name
    elif case["outcome"] == "ambiguous":
        with pytest.raises(AmbiguousParameterError) as exc:
            simulate(esm, tspan=(0.0, 1.0), parameters=params, **kw)
        # The diagnostic must name the offending key AND every candidate, or it
        # does not tell the author how to qualify it.
        assert case["key"] in str(exc.value)
        for cand in case["candidates"]:
            assert cand in str(exc.value)
    else:
        with pytest.raises(UnknownParameterError) as exc:
            simulate(esm, tspan=(0.0, 1.0), parameters=params, **kw)
        assert case["key"] in str(exc.value)
        # Ambiguous is a SUBCLASS of unknown, so an unknown key must not be
        # reported as the ambiguous one.
        assert not isinstance(exc.value, AmbiguousParameterError)


def test_defaults_run_without_overrides() -> None:
    """Non-vacuity: the fixture itself integrates, so a rejection above is about
    the key and not about the document."""
    manifest = _manifest()
    result = simulate(_load_fixture(), tspan=(0.0, 1.0), method="RK45", rtol=1e-12, atol=1e-14)
    assert result.success, result.message
    idx = {n: k for k, n in enumerate(result.vars)}
    for name, want in _fixture()["defaults_at_t1"].items():
        assert float(result.y[idx[name]][-1]) == pytest.approx(
            want,
            rel=float(manifest["tolerances"]["trajectory_rtol"]),
            abs=float(manifest["tolerances"]["trajectory_atol"]),
        )
