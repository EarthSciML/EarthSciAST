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

from earthsci_ast.inline_tests import run_inline_tests

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

    results = run_inline_tests(
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


def test_a_shaped_parameter_with_no_value_at_all_is_not_zero_filled(tmp_path: Path) -> None:
    """The broadcast covers a SUPPLIED value, never the ``0.0`` stand-in.

    ``_resolve_override`` substitutes ``0.0`` for a missing (or non-numeric)
    ``default``, the way the scalar ``param_values`` binding always has. Feeding
    that stand-in to the §6.3 broadcast would fill the whole grid with zeros and
    turn "this shaped parameter has no value yet" — a name an `update` binding or
    a forcing buffer is meant to fill — into a silent, plausible answer: the
    document below integrates ``p[k]`` and would report ``x[2](1) == 1.0``,
    PASSING, with nothing anywhere naming ``p``.

    Rust (`lower_inline_array_parameters` skips a ``None`` default) and Julia
    (``scalar === nothing`` skips) both leave such a name alone, so Python does
    too: the read stays scalar and ``index(p, k)`` says so.
    """
    doc = {
        "esm": "1.0.0",
        "metadata": {"name": "NoValueShapedParameter", "authors": ["conformance"]},
        "index_sets": {"lev": {"kind": "interval", "size": 3}},
        "models": {
            "C": {
                "variables": {
                    "p": {"type": "parameter", "units": "K/s", "shape": ["lev"]},
                    "x": {"type": "unknown", "units": "K", "shape": ["lev"], "default": 1.0},
                },
                "equations": [
                    {
                        "lhs": {
                            "op": "faq",
                            "args": [],
                            "output_idx": ["k"],
                            "ranges": {"k": {"from": "lev"}},
                            "expr": {
                                "op": "D",
                                "args": [{"op": "index", "args": ["x", "k"]}],
                                "wrt": "t",
                            },
                        },
                        "rhs": {
                            "op": "faq",
                            "args": [],
                            "output_idx": ["k"],
                            "ranges": {"k": {"from": "lev"}},
                            "expr": {"op": "index", "args": ["p", "k"]},
                        },
                    }
                ],
                "tests": [
                    {
                        "id": "t",
                        "time_span": {"start": 0.0, "end": 1.0},
                        "assertions": [
                            {"variable": "x", "time": 1.0, "coords": {"lev": 2}, "expected": 1.0}
                        ],
                    }
                ],
            }
        },
    }
    path = tmp_path / "no_value_shaped_parameter.esm"
    path.write_text(json.dumps(doc))

    results = run_inline_tests(str(path), model_name="C", method="RK45", rtol=1e-10, atol=1e-12)
    assert len(results) == 1
    r = results[0]
    assert not r.passed, (
        "a shaped parameter with no supplied value was broadcast as a column of zeros, "
        "so the assertion passed on a value nothing in the document supplies"
    )
    assert "index applied to scalar value" in r.message, r.message
