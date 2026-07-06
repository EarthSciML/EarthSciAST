"""Cross-language conformance: a pure-I/O data loader MOUNTED AS A MODEL
SUBSYSTEM, consumed by the owning model's OWN equations (RFC
pure-io-data-loaders §4.3; CONFORMANCE_SPEC.md §5.11).

Shared fixture + analytic golden live under
``tests/conformance/subsystem_loader/`` (repo root); the Julia runner
(`subsystem_loader_conformance_test.jl`) reproduces the same golden.

Model ``Box`` mounts a static (CONST) loader ``raw`` (vars ``k``, ``wind``) and
its single ODE consumes both a BARE-SCALAR reference ``raw.k`` (lowered to the
observed ``Box.raw.k``) and a GATHER ``index(raw.wind, 2)`` (``Box.raw.wind``),
integrating ``D(c) = (raw.k + wind[2]) - c``, c(0)=0. With the offline CONST
provider (k=2, wind[2]=5) the forcing ``F = 7`` is constant, so
``c(t) = 7 (1 - e^-t)`` is analytic.
"""

from __future__ import annotations

import json
from pathlib import Path

import numpy as np
import pytest

from earthsci_toolkit.flatten import LoaderField, flatten
from earthsci_toolkit.parse import load
from earthsci_toolkit.simulation import simulate

_ROOT = Path(__file__).resolve().parents[3] / "tests" / "conformance" / "subsystem_loader"
_FIXTURE = _ROOT / "fixtures" / "subsystem_loader_ode.esm"
_GOLDEN = _ROOT / "golden" / "subsystem_loader_ode.json"


def _golden() -> dict:
    return json.loads(_GOLDEN.read_text())


def _provider(golden: dict):
    """Offline CONST provider seeded from the golden's native loader values,
    dispatching on the loader variable name (matching each field by ``var``)."""
    native = {name.split(".")[-1]: np.asarray(spec["native"], dtype=float)
              for name, spec in golden["loaders"].items()}

    def provider(field: LoaderField, t: float) -> np.ndarray:
        return native[field.var]

    return provider


def test_flatten_lowers_subsystem_loader_to_observeds() -> None:
    flat = flatten(load(str(_FIXTURE)))
    by_name = {lf.name: lf for lf in flat.loader_fields}
    assert set(by_name) == {"Box.raw.k", "Box.raw.wind"}
    assert by_name["Box.raw.k"].cadence == "const"
    assert by_name["Box.raw.wind"].cadence == "const"
    # Materialized as observeds with NO defining equation (value is injected).
    assert "Box.raw.k" in flat.observed_variables
    assert "Box.raw.wind" in flat.observed_variables
    observed_lhs = {eq.lhs for eq in flat.equations if isinstance(eq.lhs, str)}
    assert "Box.raw.k" not in observed_lhs
    assert "Box.raw.wind" not in observed_lhs


def test_subsystem_loader_trajectory_matches_golden() -> None:
    golden = _golden()
    esm = load(str(_FIXTURE))
    t0, t1 = golden["cadence"]["tspan"]
    result = simulate(esm, tspan=(float(t0), float(t1)), method="LSODA",
                      loader_provider=_provider(golden))
    assert result.success, result.message
    assert result.vars == golden["state_order"]

    traj = golden["trajectory"]
    for tk, expected in traj.items():
        if tk == "comment":
            continue
        t = float(tk)
        c = float(np.interp(t, result.t, result.y[0]))
        assert c == pytest.approx(expected["Box.c"], rel=1e-4, abs=1e-6)
