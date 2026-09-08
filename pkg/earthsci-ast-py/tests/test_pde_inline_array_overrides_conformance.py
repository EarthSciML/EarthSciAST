"""Cross-language conformance: a SHAPED variable's INLINE ARRAY DATA reaches the
run (esm-spec §6.6.2 "Shaped values", §6.3, §11.4 state-free-array-observed
``ic``).

Shared fixtures + Julia-minted goldens live under
``tests/conformance/pde_inline_array_overrides/`` (repo root); the Julia runner
(``conformance_pde_inline_array_overrides_test.jl``) and the Rust runner
(``pde_inline_array_overrides_conformance.rs``) gate the same goldens.

Before this, a shaped variable's ``default`` and a test's
``parameter_overrides`` / ``initial_conditions`` values were ``number``-only in
``esm-schema.json``, and an ``ic`` whose RHS names a state-free array observed
was rejected at build. A §6.6 inline test therefore could not supply a SHAPED
input at all — which is exactly what a column-physics test replaying a Fortran
kernel dump needs, its inputs being columns (θ, q_v, u, v, p, dz, K profiles).
Each fixture here is ONE shared component whose regimes are ordinary tests of
the same document, which is the shape §6.6 already describes for 0-D
components.

Python binds an array-valued parameter through the interpreter's
``input_arrays`` channel (``simulation_array._build_numpy_rhs``), writes an
array-valued initial condition cell-by-cell into ``y0``
(``_write_state_field``), and materializes the state-free observeds an ``ic``
reads (``_buildtime_observed_arrays``); this suite pins all three against the
reference binding.
"""

from __future__ import annotations

import json
from pathlib import Path

import numpy as np
import pytest

from earthsci_ast.inline_tests import run_inline_tests

_ROOT = Path(__file__).resolve().parents[3] / "tests" / "conformance" / "pde_inline_array_overrides"
_MANIFEST = _ROOT / "manifest.json"


def _manifest() -> dict:
    return json.loads(_MANIFEST.read_text())


def test_manifest_declares_the_three_executing_bindings() -> None:
    manifest = _manifest()
    assert manifest["category"] == "pde_inline_array_overrides"
    assert manifest["reference_binding"] == "julia"
    assert set(manifest["bindings_required"]) == {"julia", "python", "rust"}
    assert manifest["fixtures"]


@pytest.mark.parametrize("fixture", _manifest()["fixtures"], ids=lambda f: f["id"])
def test_array_overrides_match_golden(fixture: dict) -> None:
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

    # Keyed by (test_id, assertion_idx): each fixture carries several tests of
    # ONE model, distinguished only by their inline array data.
    by_key = {(r.test_id, r.assertion_idx): r for r in results}
    for g in golden["assertions"]:
        key = (g["test_id"], int(g["assertion_idx"]))
        assert key in by_key, f"missing assertion {key}"
        r = by_key[key]
        assert r.passed, f"{key}: {r.message}"
        assert r.actual is not None
        assert r.actual == pytest.approx(float(g["actual"]), rel=rtol, abs=atol)


def test_rank2_inline_array_is_read_row_major() -> None:
    """The nesting order of §6.6.2, pinned directly rather than through the
    runner: axis 1 of ``shape`` is the OUTER JSON array, so ``data[i][j]`` is the
    element at ``(i, j)``. The fixture's 2x3 slab has unequal extents and
    pairwise-distinct values, so a column-major read disagrees on every
    off-diagonal cell instead of coincidentally agreeing."""
    from earthsci_ast.parse import load_path
    from earthsci_ast.problem import ReturnCode, esm_problem, solve

    esm = load_path(str(_ROOT / "fixtures" / "slab_array_overrides_rank2.esm"))
    declared = esm.models["Slab"].variables["kprof"].default
    assert np.shape(declared) == (2, 3)

    result = solve(esm_problem(esm, (0.0, 1.0)), alg="RK45", reltol=1e-12, abstol=1e-14)
    assert result.retcode is ReturnCode.Success, result.message
    idx = {name: k for k, name in enumerate(result.vars)}
    for i in range(2):
        for j in range(3):
            cell = f"Slab.a[{i + 1},{j + 1}]"
            assert result.y[idx[cell]][0] == pytest.approx(float(declared[i][j]))


def test_inline_array_shape_mismatch_is_a_load_time_error() -> None:
    """esm-spec §6.6.2: the array MUST match the declared shape after
    metaparameter folding, and a mismatch is a load-time error — never a
    silently truncated or broadcast column."""
    from earthsci_ast.parse import load_path
    from earthsci_ast.problem import esm_problem
    from earthsci_ast.sympy_bridge import SimulationError

    esm = load_path(str(_ROOT / "fixtures" / "column_array_overrides.esm"))
    with pytest.raises(SimulationError, match="does not match the declared shape"):
        esm_problem(esm, (0.0, 1.0), p={"theta0": [1.0, 2.0]})
