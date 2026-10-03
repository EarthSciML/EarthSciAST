"""Cross-language conformance: a SHAPED parameter with no data supplied at the
front door (esm-spec §10.10, CONFORMANCE_SPEC §5.32.5).

The manifest lives under ``tests/conformance/missing_data/`` (repo root); the
Julia runner (``conformance_missing_data_test.jl``) and the Rust runner
(``missing_data_conformance.rs``) read the same file. Without data every
compiler refuses the construction with ``E_TREEWALK_MISSING_DATA``, naming a
parameter that has no value; with the case's ``const_arrays`` every compiler
builds, and the right-hand side at the manifest's probe state is bit-for-bit
the same under ``native`` and ``interpreter``.
"""

from __future__ import annotations

import json
from pathlib import Path

import numpy as np
import pytest

from earthsci_ast import esm_problem

_ROOT = Path(__file__).resolve().parents[3] / "tests" / "conformance" / "missing_data"
_MANIFEST = _ROOT / "manifest.json"


def _manifest() -> dict:
    return json.loads(_MANIFEST.read_text())


def _rhs(prob) -> np.ndarray:
    build = prob.build
    assert build is not None, "no array right-hand side was built"
    n = int(np.asarray(build.y0).size)
    state = np.array([1.0 + 0.1 * np.sin(0.37 * k) for k in range(n)], dtype=float)
    return np.asarray(build.rhs_function(0.0, state), dtype=float)


def test_manifest_declares_its_bindings() -> None:
    manifest = _manifest()
    assert manifest["category"] == "missing_data"
    assert "python" in manifest["bindings_required"]
    assert manifest["cases"]


@pytest.mark.parametrize("compiler", _manifest()["compilers"])
@pytest.mark.parametrize("case", _manifest()["cases"], ids=lambda c: c["id"])
def test_without_data(case: dict, compiler: str) -> None:
    fixture = str(_ROOT / case["fixture"])
    if case["missing"] is None:
        prob = esm_problem(fixture, (0.0, 1.0), compiler=compiler)
        if "expected_rhs_without_data" in case:
            assert _rhs(prob).tolist() == [float(x) for x in case["expected_rhs_without_data"]]
        return
    with pytest.raises(Exception) as info:
        esm_problem(fixture, (0.0, 1.0), compiler=compiler)
    msg = str(info.value)
    assert case.get("error_code", _manifest()["error_code"]) in msg, msg
    assert any(f"'{m}'" in msg or f"'{m.rsplit('.', 1)[-1]}'" in msg for m in case["missing"]), msg


@pytest.mark.parametrize("case", _manifest()["cases"], ids=lambda c: c["id"])
def test_with_data(case: dict) -> None:
    supply = case.get("supply") or {}
    if case["const_arrays"] is None and not supply:
        pytest.skip("refusal-only case")
    fixture = str(_ROOT / case["fixture"])
    answers = []
    for compiler in _manifest()["compilers"]:
        arrays = {k: np.asarray(v, dtype=float) for k, v in (case["const_arrays"] or {}).items()}
        prob = esm_problem(
            fixture,
            (0.0, 1.0),
            compiler=compiler,
            const_arrays=arrays,
            p=supply.get("p"),
            u0=supply.get("u0"),
        )
        if not case["rhs"]:
            continue
        dy = _rhs(prob)
        assert np.all(np.isfinite(dy)), (compiler, dy)
        if "expected_rhs" in case:
            assert dy.tolist() == [float(x) for x in case["expected_rhs"]]
        answers.append(dy)
    if len(answers) == 2:
        a, b = answers
        assert a.shape == b.shape and (a.view(np.uint64) == b.view(np.uint64)).all()
