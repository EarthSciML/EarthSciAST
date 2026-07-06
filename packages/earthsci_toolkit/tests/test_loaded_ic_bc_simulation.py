"""End-to-end simulation of the worked scoped-reference-``ic`` fixture
``tests/valid/advection_reaction_loaded_ic_bc.esm`` through the Python NumPy
runner (:func:`earthsci_toolkit.simulation.simulate`), with every loaded field
injected through the data-**Provider** seam (DESIGN pde_simulation_pipeline §2).

Python counterpart of the Julia reference
``packages/EarthSciSerialization.jl/test/loaded_ic_bc_simulation_test.jl``.

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
  * The loader→consumer ``variable_map`` bindings (spec §11.5): the wind field
    (``Meteorology.u_wind → Advection.u_wind``) and the per-species western
    inflow BCs (``BoundaryConditions.{O3,NO,NO2}_inflow → Advection.*_inflow``).

Provider injection (NOT raw arrays keyed by consumer name): a static stub
provider serves the fixture's DECLARED loader variables (keyed ``<Loader>.<var>``)
from the manifest ``inputs`` arrays. The reaction system's own inline ``tests``
block is the source of truth: this runner executes every assertion in it.
"""

from __future__ import annotations

import json
import os
from typing import Any, Dict, Optional, Tuple

import numpy as np
import pytest
from conftest import CONFORMANCE_DIR, VALID_DIR

pytest.importorskip("scipy")

from earthsci_toolkit.parse import load
from earthsci_toolkit.simulation import simulate


FIXTURE = str(VALID_DIR / "advection_reaction_loaded_ic_bc.esm")
MANIFEST = str(CONFORMANCE_DIR / "pde_simulation_pipeline" / "manifest.json")


class _StubLoaderProvider:
    """Static CONST stub Provider (DESIGN §2). Serves one declared loader
    variable's field from the manifest ``inputs`` arrays; sampled once at build
    time. ``sample(t)`` returns the same array for every ``t`` (const)."""

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
    # Every loaded field the model consumes is served by the stub provider, keyed
    # by its DECLARED loader name (<Loader>.<var>). No field is injected by an
    # internal consumer name (R1): keys are all loader-qualified.
    providers = {name: _StubLoaderProvider(field) for name, field in inputs.items()}
    for name in providers:
        loader = name.split(".", 1)[0]
        assert loader in {"InitialConditions", "BoundaryConditions", "Meteorology"}, (
            f"provider key {name!r} is not a declared loader field"
        )

    file = load(FIXTURE)

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
