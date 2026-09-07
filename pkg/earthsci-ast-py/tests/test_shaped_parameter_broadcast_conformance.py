"""Cross-language conformance: a SCALAR on a shaped PARAMETER broadcasts over its
declared grid (esm-spec §6.3 "Inline array data", §6.6.2 "Shaped values").

Shared fixture + Julia-minted golden live under
``tests/conformance/shaped_parameter_broadcast/`` (repo root); the Julia runner
(``conformance_shaped_parameter_broadcast_test.jl``) and the Rust runner
(``shaped_parameter_broadcast_conformance.rs``) gate the same golden.

Python bound such a parameter only in the scalar ``param_values`` map, so a BARE
read broadcast correctly but ``index(p, k)`` raised "index applied to scalar
value" — the per-cell spelling a column component actually writes. The build now
also registers the value BROADCAST onto the declared grid on the array channel
(``loader_arrays`` → the interpreter's ``input_arrays``), which is the same
channel the array-valued spelling of the same §6.3 union already took;
``setdefault`` keeps a provider-fed field of that name authoritative.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from earthsci_ast.pde_inline_tests import run_pde_tests

_ROOT = Path(__file__).resolve().parents[3] / "tests" / "conformance" / "shaped_parameter_broadcast"
_MANIFEST = _ROOT / "manifest.json"


def _manifest() -> dict:
    return json.loads(_MANIFEST.read_text())


def test_manifest_declares_the_three_executing_bindings() -> None:
    manifest = _manifest()
    assert manifest["category"] == "shaped_parameter_broadcast"
    assert manifest["reference_binding"] == "julia"
    assert set(manifest["bindings_required"]) == {"julia", "python", "rust"}
    assert manifest["fixtures"]


@pytest.mark.parametrize("fixture", _manifest()["fixtures"], ids=lambda f: f["id"])
def test_shaped_parameter_broadcast_matches_golden(fixture: dict) -> None:
    manifest = _manifest()
    rtol = float(manifest["tolerances"]["assertion_rtol"])
    atol = float(manifest["tolerances"]["assertion_atol"])
    integ = manifest["integrators"]["python"]

    esm_path = _ROOT / fixture["path"]
    golden = json.loads((_ROOT / fixture["golden"]).read_text())
    assert golden["reference_binding"] == "julia"

    results = run_pde_tests(
        str(esm_path),
        model_name=fixture["model"],
        method=integ["method"],
        rtol=float(integ["rtol"]),
        atol=float(integ["atol"]),
    )
    assert len(results) == len(golden["assertions"])

    by_key = {(r.test_id, r.assertion_idx): r for r in results}
    for g in golden["assertions"]:
        key = (g["test_id"], int(g["assertion_idx"]))
        assert key in by_key, f"missing assertion {key}"
        r = by_key[key]
        assert r.passed, f"{key}: {r.message}"
        assert r.actual is not None
        want = float(g["actual"])
        assert abs(r.actual - want) <= max(atol, rtol * max(abs(want), abs(r.actual))), (
            f"{key}: actual {r.actual} vs golden {want}"
        )
