"""Loader -> consumer value-injection tests (campfire-e2e C1, bead ess-06y).

These lock in the RFC pure-io-data-loaders §4.3 injection path:

* ``flatten`` no longer SKIPS ``DataLoader`` subsystems — it lowers each loader
  variable to a flattened observed array ``<owner>.<subkey>.<var>`` and records
  a :class:`LoaderField` carrying its cadence (temporal -> discrete, static ->
  const) and the owning model's per-variable regrid spec.
* ``simulate`` executes the loaders and binds their arrays into the NumPy RHS as
  read-only inputs, so a consumer equation that referenced the loader field
  (via a coupling edge) resolves it as a value — not the parameter's constant
  default.
* Const loaders are read once; discrete loaders refresh at their cadence via
  terminal-event segmentation, and the RHS is pure within a segment.

The loaders are driven by a deterministic in-process provider (no network), so
the consumer's trajectory is analytic. The single-component physics is
``dc/dt = F - c`` with a piecewise-constant forcing ``F``; on each segment with
constant ``F`` and start value ``c0`` the closed form is
``c(t) = F + (c0 - F) * exp(-(t - t_start))``.
"""

from __future__ import annotations

import math
from pathlib import Path
from typing import Dict, List

import numpy as np
import pytest

from earthsci_ast.flatten import LoaderField, flatten
from earthsci_ast.parse import load
from earthsci_ast.simulation import simulate


_FIXTURE = Path(__file__).resolve().parent / "fixtures" / "loader_injection" / "loader_consumer.esm"


def _seg_value(t: float) -> float:
    """Wind value u[2] for the segment containing simulation time ``t``.

    Segment [0, 1) -> 10, [1, 2) -> 20, ... (steps every cadence second). The
    provider is queried once per segment at the segment's start, so ``round``
    on the (integer) boundary picks that segment's value.
    """
    return 10.0 + 10.0 * round(t)


def _make_provider(calls: Dict[str, List[float]]):
    """Deterministic loader provider that records the times it is queried.

    ``u`` is a 3-element wind array whose MIDDLE element (1-based index 2) is the
    only one the consumer reads, proving the loader symbol resolves to a real
    multi-element array (not a coincidental scalar). ``z0`` is a static 3-element
    roughness array; its middle element is 1.0.
    """

    def provider(field: LoaderField, t: float) -> np.ndarray:
        calls.setdefault(field.var, []).append(t)
        if field.var == "u":
            return np.array([99.0, _seg_value(t), -99.0])
        if field.var == "z0":
            return np.array([0.25, 1.0, 0.25])
        raise AssertionError(f"unexpected loader var {field.var!r}")

    return provider


def _c_at(result, t: float) -> float:
    return float(np.interp(t, result.t, result.y[0]))


# --------------------------------------------------------------------------
# (a) flatten lowers loader subsystems to observed arrays
# --------------------------------------------------------------------------


def test_flatten_lowers_loaders_to_observed_arrays() -> None:
    flat = flatten(load(_FIXTURE))

    by_name = {lf.name: lf for lf in flat.loader_fields}
    assert set(by_name) == {"Met.pl.u", "Met.sfc.z0"}, (
        "both loader variables must be lowered (loaders are no longer skipped)"
    )

    u = by_name["Met.pl.u"]
    assert (u.owner, u.subkey, u.var) == ("Met", "pl", "u")
    assert u.cadence == "discrete", "a temporal loader seeds discrete cadence"

    z0 = by_name["Met.sfc.z0"]
    assert (z0.owner, z0.subkey, z0.var) == ("Met", "sfc", "z0")
    assert z0.cadence == "const", "a static (no-temporal) loader seeds const cadence"

    # Lowered as observed arrays (the observed-as-array vehicle), with NO
    # defining equation (their value is injected, not computed).
    assert "Met.pl.u" in flat.observed_variables
    assert "Met.sfc.z0" in flat.observed_variables
    observed_lhs = {eq.lhs for eq in flat.equations if isinstance(eq.lhs, str)}
    assert "Met.pl.u" not in observed_lhs
    assert "Met.sfc.z0" not in observed_lhs


def test_flatten_without_loaders_has_empty_loader_fields() -> None:
    # Regression guard: a plain model carries no loader fields, so simulate()
    # never enters the injection path (cross-binding / existing models intact).
    doc = {
        "esm": "0.7.0",
        "metadata": {"name": "plain"},
        "models": {
            "M": {
                "variables": {"x": {"type": "state", "default": 1.0}},
                "equations": [
                    {
                        "lhs": {"op": "D", "args": ["x"], "wrt": "t"},
                        "rhs": {"op": "-", "args": ["x"]},
                    }
                ],
            }
        },
    }
    assert flatten(load(doc)).loader_fields == []


# --------------------------------------------------------------------------
# (b) simulate injects loader arrays at the right cadence
# --------------------------------------------------------------------------


def test_discrete_and_const_cadence_injection() -> None:
    esm = load(_FIXTURE)
    calls: Dict[str, List[float]] = {}
    result = simulate(
        esm,
        tspan=(0.0, 2.0),
        method="LSODA",
        loader_provider=_make_provider(calls),
    )
    assert result.success, result.message
    assert result.vars == ["Plume.c"]

    # Analytic piecewise solution of dc/dt = (u[2] + z0[2]) - c, c(0) = 0.
    z0 = 1.0
    f0 = _seg_value(0.0) + z0  # 11 on [0, 1)
    f1 = _seg_value(1.0) + z0  # 21 on [1, 2)
    c1 = f0 * (1.0 - math.exp(-1.0))
    c2 = f1 + (c1 - f1) * math.exp(-1.0)

    assert _c_at(result, 1.0) == pytest.approx(c1, rel=1e-4)
    assert _c_at(result, 2.0) == pytest.approx(c2, rel=1e-4)


def test_const_loader_read_once_discrete_per_segment() -> None:
    esm = load(_FIXTURE)
    calls: Dict[str, List[float]] = {}
    result = simulate(
        esm,
        tspan=(0.0, 2.0),
        method="LSODA",
        loader_provider=_make_provider(calls),
    )
    assert result.success, result.message

    # Const loader: executed exactly once, before integration.
    assert calls["z0"] == [0.0], "static loader must be read once (const cadence)"

    # Discrete loader: once at the start, once per interior cadence boundary
    # (here a single boundary at t=1) — and NOTHING per RHS evaluation. With
    # hundreds of solver RHS calls, a provider hit count of 2 is the proof that
    # the RHS is pure within a segment.
    assert calls["u"] == [0.0, 1.0]
    assert result.nfev > 10
    assert len(calls["u"]) < result.nfev


def test_injected_values_not_constant_defaults() -> None:
    # The consumer's `wind`/`rough` params default to 0.0. If injection failed
    # and the RHS saw the defaults, the forcing would be 0 and c would stay 0.
    # A constant non-zero provider drives c toward its injected steady state
    # F = u[2] + z0[2], proving real array values reach the RHS.
    esm = load(_FIXTURE)

    def steady_provider(field: LoaderField, t: float) -> np.ndarray:
        if field.var == "u":
            return np.array([0.0, 7.0, 0.0])
        return np.array([0.0, 3.0, 0.0])

    result = simulate(
        esm,
        tspan=(0.0, 50.0),
        method="LSODA",
        loader_provider=steady_provider,
    )
    assert result.success, result.message
    # Steady state F = 7 + 3 = 10, far from the all-defaults value of 0.
    assert _c_at(result, 50.0) == pytest.approx(10.0, rel=1e-3)
    assert _c_at(result, 50.0) > 9.0


def test_loader_arrays_resolve_via_coupling_edge() -> None:
    # The consumer equation referenced `Plume.wind` / `Plume.rough`; the coupling
    # edges substituted the producer symbols `Met.pl.u` / `Met.sfc.z0`. The run
    # succeeding (symbols resolve) AND tracking the injected value confirms the
    # substituted loader symbol resolves to the injected array at the RHS.
    esm = load(_FIXTURE)
    calls: Dict[str, List[float]] = {}
    result = simulate(
        esm,
        tspan=(0.0, 1.0),
        method="LSODA",
        loader_provider=_make_provider(calls),
    )
    assert result.success, result.message
    # On [0, 1): F = 11, c(1) = 11 (1 - e^-1) ~= 6.953. A failure to resolve the
    # coupled loader symbol would raise (caught -> success False).
    assert _c_at(result, 1.0) == pytest.approx(11.0 * (1.0 - math.exp(-1.0)), rel=1e-4)
