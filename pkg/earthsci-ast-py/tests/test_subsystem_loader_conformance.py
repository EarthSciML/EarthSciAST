"""Cross-language conformance: a pure-I/O data SOURCE consumed by the owning
model's OWN equations (esm-spec §8.5; CONFORMANCE_SPEC.md §5.11).

Shared fixture + analytic golden live under
``tests/conformance/subsystem_loader/`` (repo root); the Julia runner
(`subsystem_loader_conformance_test.jl`) reproduces the same golden.

From esm 1.0.0 a data source is a document-scoped registry entry, NOT a
component: it can no longer be MOUNTED as a model subsystem. Model ``Box``
therefore declares the two former loader variables as its own PARAMETERS, each
with an `update` naming the static (CONST) source ``raw`` and binding one of its
file variables — scalar ``k`` (file variable ``K``) and 3-element ``wind`` (file
variable ``U``). Its single ODE consumes both a BARE-SCALAR reference ``k`` and
a GATHER ``index(wind, 2)``, integrating ``D(c) = (k + wind[2]) - c``, c(0)=0.
With the offline CONST provider (k=2, wind[2]=5) the forcing ``F = 7`` is
constant, so ``c(t) = 7 (1 - e^-t)`` is analytic.
"""

from __future__ import annotations

import json
from pathlib import Path

import numpy as np
import pytest

from earthsci_ast.flatten import LoaderField, flatten
from earthsci_ast.parse import load_path
from earthsci_ast.simulation import simulate

_ROOT = Path(__file__).resolve().parents[3] / "tests" / "conformance" / "subsystem_loader"
_FIXTURE = _ROOT / "fixtures" / "subsystem_loader_ode.esm"
_GOLDEN = _ROOT / "golden" / "subsystem_loader_ode.json"


def _golden() -> dict:
    return json.loads(_GOLDEN.read_text())


def _provider(golden: dict):
    """Offline CONST provider seeded from the golden's native values, keyed by
    the golden's own PARAMETER names (``Box.k`` / ``Box.wind``) — which are
    exactly the flattened loader-field names from 1.0.0, since the parameter IS
    the loaded field."""
    native = {
        name: np.asarray(spec["native"], dtype=float) for name, spec in golden["loaders"].items()
    }

    def provider(field: LoaderField, t: float) -> np.ndarray:
        return native[field.name]

    return provider


def test_flatten_records_a_field_per_source_fed_parameter() -> None:
    golden = _golden()
    flat = flatten(load_path(str(_FIXTURE)))
    by_name = {lf.name: lf for lf in flat.loader_fields}
    # The golden names the fields by the PARAMETERS that read the source.
    assert set(by_name) == set(golden["loaders"])
    for name, spec in golden["loaders"].items():
        assert by_name[name].cadence == spec["cadence"]
        # The source `raw` declares no `temporal`, so both are CONST.
        assert by_name[name].subkey == "raw"
    # `var` is the ON-DISK name the binding declares, not the parameter's.
    assert by_name["Box.k"].var == "K"
    assert by_name["Box.wind"].var == "U"
    # A data-fed parameter stays a PARAMETER -- the source is not a component,
    # so nothing is mounted -- and carries NO defining equation (its value is
    # injected at the RHS boundary, not computed).
    assert "Box.k" in flat.parameters
    assert "Box.wind" in flat.parameters
    lhs_names = {eq.lhs for eq in flat.equations if isinstance(eq.lhs, str)}
    assert "Box.k" not in lhs_names
    assert "Box.wind" not in lhs_names


def test_subsystem_loader_trajectory_matches_golden() -> None:
    golden = _golden()
    esm = load_path(str(_FIXTURE))
    t0, t1 = golden["cadence"]["tspan"]
    result = simulate(
        esm, tspan=(float(t0), float(t1)), method="LSODA", loader_provider=_provider(golden)
    )
    assert result.success, result.message
    assert result.vars == golden["state_order"]

    traj = golden["trajectory"]
    for tk, expected in traj.items():
        if tk == "comment":
            continue
        t = float(tk)
        c = float(np.interp(t, result.t, result.y[0]))
        assert c == pytest.approx(expected["Box.c"], rel=1e-4, abs=1e-6)
