"""End-to-end simulation of the worked scoped-reference-``ic`` fixture
``tests/valid/advection_reaction_loaded_ic_bc.esm`` through the Python NumPy
runner (:func:`earthsci_ast.simulation.simulate`), with every loaded field
injected through the data-**Provider** seam (DESIGN pde_simulation_pipeline §2).

Python counterpart of the Julia reference
``pkg/EarthSciAST.jl/test/loaded_ic_bc_simulation_test.jl``.

What this exercises:
  * A REAL ``reaction_systems`` Chemistry (O3/NO/NO2, R1/R2) lowered to generic
    per-species ODEs, then SPATIALLY LIFTED onto the 4x2 lon/lat grid by
    ``operator_compose(Chemistry, Advection)`` + ``lifting:"pointwise"``. The
    flattener's pointwise lift (``_apply_pointwise_lift``) array-ifies the merged
    reaction+advection state ODEs so the reaction network runs per grid cell.
  * SCOPED-REFERENCE ``ic`` resolution (spec §11.4.1): ChemistryICs hosts
    ``ic(Chemistry.O3) ~ InitialConditions.O3_init`` (and NO, NO2). Each RHS is a
    LOADED FIELD served by the stub provider; the build-time fold seeds the
    provider [lon,lat] field into u0 cell-by-cell.
  * The source→consumer bindings (esm-spec §8.5): each loaded field is a
    PARAMETER whose ``update`` names its source and file variable — the wind
    (``Advection.u_wind`` ← ``Meteorology``/``U10M``) and the per-species western
    inflow BCs (``Advection.{O3,NO,NO2}_inflow`` ← ``BoundaryConditions``).

Provider injection (NOT raw arrays pre-seeded around the seam): a static stub
provider per data-fed parameter serves its field from the manifest ``inputs``
arrays, keyed by the parameter's flattened name (``<ModelPath>.<param>``) — from
1.0.0 the only name a loaded field has, since a source declares no variables of
its own. The reaction system's own inline ``tests`` block is the source of truth:
this runner executes every assertion in it.
"""

from __future__ import annotations

import json
import os
from typing import Any, Dict, Optional, Tuple

import numpy as np
import pytest
from conftest import CONFORMANCE_DIR, VALID_DIR

pytest.importorskip("scipy")

from earthsci_ast.flatten import flatten
from earthsci_ast.parse import load_path
from earthsci_ast.simulation import simulate


FIXTURE = str(VALID_DIR / "advection_reaction_loaded_ic_bc.esm")
MANIFEST = str(CONFORMANCE_DIR / "pde_simulation_pipeline" / "manifest.json")


class _StubLoaderProvider:
    """Static CONST stub Provider (DESIGN §2). Serves one data-fed PARAMETER's
    field from the manifest ``inputs`` arrays; sampled once at build time.
    ``sample(t)`` returns the same array for every ``t`` (const)."""

    def __init__(self, field: Any) -> None:
        self.field = np.asarray(field, dtype=float)

    def sample(self, t: float) -> np.ndarray:  # noqa: ARG002 - const provider
        return self.field


def _manifest_inputs() -> Dict[str, Any]:
    with open(MANIFEST) as fp:
        manifest = json.load(fp)
    for fx in manifest["fixtures"]:
        if fx["id"] == "advection_reaction_loaded_ic_bc":
            return fx["inputs"]
    raise AssertionError("fixture 'advection_reaction_loaded_ic_bc' not in manifest")


def _resolve_tol(
    model_tol: Optional[Dict[str, Any]],
    test_tol: Optional[Dict[str, Any]],
    assertion_tol: Optional[Dict[str, Any]],
) -> Tuple[float, float]:
    """Resolve (rel, abs) precedence assertion → test → model (fallback rtol=1e-6),
    matching the Julia runner and test_simulation_fixtures_blocks."""
    for cand in (assertion_tol, test_tol, model_tol):
        if cand is None:
            continue
        rel = cand.get("rel")
        abs_ = cand.get("abs")
        return (float(rel) if rel is not None else 0.0, float(abs_) if abs_ is not None else 0.0)
    return (1e-6, 0.0)


def test_loaded_ic_bc_simulation_via_provider() -> None:
    """Run the lifted reaction+advection network with loaded IC/BC/wind fields
    injected ONLY through the provider seam, and assert every inline test."""
    assert os.path.isfile(FIXTURE), FIXTURE

    with open(FIXTURE) as fp:
        raw = json.load(fp)
    chem = raw["reaction_systems"]["Chemistry"]
    model_tol = chem.get("tolerance")
    tests = chem.get("tests") or []
    assert tests, "fixture Chemistry reaction system carries no inline tests block"

    inputs = _manifest_inputs()
    # Every loaded field the model consumes arrives through the provider seam
    # (R1), keyed by the consuming parameter's flattened name. Assert the
    # manifest covers exactly the document's data-fed parameters, so a fixture
    # that gains or renames one cannot silently fall back off the seam.
    providers = {name: _StubLoaderProvider(field) for name, field in inputs.items()}
    declared = {f.name for f in flatten(load_path(FIXTURE)).loader_fields}
    assert set(providers) == declared, (
        f"manifest inputs {sorted(providers)} do not match the document's "
        f"data-fed parameters {sorted(declared)}"
    )

    file = load_path(FIXTURE)

    passed = 0
    total = 0
    for test in tests:
        ts = test["time_span"]
        tspan = (float(ts["start"]), float(ts["end"]))
        test_tol = test.get("tolerance")

        result = simulate(
            file,
            tspan=tspan,
            providers=providers,
            method="RK45",
            rtol=1e-10,
            atol=1e-12,
        )
        assert result.success, f"simulate() failed: {result.message}"

        for a in test["assertions"]:
            total += 1
            # Assertion variables are model-local ("O3[1,1]"); the simulated
            # element is namespaced under the Chemistry reaction system.
            local = a["variable"]
            key = f"Chemistry.{local}"
            assert key in result.vars, f"element {key!r} not in result vars ({result.vars})"
            idx = result.vars.index(key)
            t_eval = float(a["time"])
            expected = float(a["expected"])
            actual = float(np.interp(t_eval, result.t, result.y[idx]))
            rel, abs_ = _resolve_tol(model_tol, test_tol, a.get("tolerance"))
            diff = abs(actual - expected)
            if rel == 0.0 and abs_ == 0.0:
                bound = 1e-6 * max(abs(expected), np.finfo(float).tiny)
            else:
                bound = abs_
                if rel > 0:
                    bound = max(bound, rel * max(abs(expected), np.finfo(float).tiny))
            assert diff <= bound, (
                f"{test['id']} var={local} t={t_eval}: actual={actual:g} "
                f"expected={expected:g} diff={diff:g} bound={bound:g} "
                f"(rel={rel}, abs={abs_})"
            )
            passed += 1

    assert passed == total and total > 0
    # The fixture's inline tests block pins the loaded ICs at t=0 and the coupled
    # reaction+advection trajectory at t=600 (4 + 5 = 9 assertions).
    print(f"loaded_ic_bc provider simulation: {passed}/{total} assertions passed")
