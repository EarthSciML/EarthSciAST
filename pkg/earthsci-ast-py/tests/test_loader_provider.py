"""Provider-object loader consumer (PY-N1, bead ess-14f.1).

C1 (``ess-06y``) built the segmented-solve skeleton + the by-reference
``loader_arrays`` registry; N1 re-points that seam at the **EarthSciIO Provider
contract**. ``simulate()`` now (by default, and via an injected
``provider_factory``) builds one
:class:`~earthsci_ast.data_loaders.provider.Provider` per loader field at
setup and drives it at cadence — CONST → ``materialize()`` once, DISCRETE →
``refresh(t)`` at the seed and each boundary — with the segment boundaries taken
from ``Provider.refresh_times()`` rather than local frequency arithmetic.

EarthSciIO is a separate rig (no cross-repo import), so these tests inject a
stub provider that returns the EarthSciIO ``NativeDataset`` *shape*
(``.variables`` / ``.coords`` of native fields), proving the consumer GETs and
REFRESHes through that contract. The legacy per-call ``loader_provider`` callable
(exercised in ``test_loader_injection.py``) stays green and unchanged.
"""

from __future__ import annotations

import datetime as _dt
import math
from pathlib import Path
from types import SimpleNamespace
from typing import Dict, List, Optional

import numpy as np
import pytest

from earthsci_ast.flatten import LoaderField, flatten
from earthsci_ast.parse import load
from earthsci_ast.simulation import (
    _provider_array,
    simulate,
)
from earthsci_ast.data_loaders.provider import (
    LoadDataProvider,
    Provider,
    build_default_provider,
)

_FIXTURE = Path(__file__).resolve().parent / "fixtures" / "loader_injection" / "loader_consumer.esm"

_EPOCH = _dt.datetime(2018, 1, 1)  # the fixture loader's temporal.start


# --------------------------------------------------------------------------
# EarthSciIO NativeDataset/NativeField shape (duck-typed; no cross-repo import)
# --------------------------------------------------------------------------


class _NativeField:
    """Mirror of earthsciio.native.NativeField (``.data`` + ``.dims``)."""

    def __init__(self, data, dims):
        self.data = np.asarray(data, dtype=float)
        self.dims = tuple(dims)


class _NativeDataset:
    """Mirror of earthsciio.native.NativeDataset (``.variables`` + ``.coords``)."""

    def __init__(self, variables, coords=None):
        self.variables = dict(variables)
        self.coords = dict(coords or {})


def _c_at(result, t: float) -> float:
    return float(np.interp(t, result.t, result.y[0]))


def _seg_value(t: float) -> float:
    """Wind u[2] for the segment containing time ``t`` (matches C1's fixture)."""
    return 10.0 + 10.0 * round(t)


# --------------------------------------------------------------------------
# A stub EarthSciIO-shaped Provider, built per field by a provider_factory
# --------------------------------------------------------------------------


def _make_factory(calls: Dict[str, List], *, anchors_seconds: Optional[List[float]] = None):
    """Provider factory returning native-dataset-shaped records and logging calls.

    ``anchors_seconds`` overrides the discrete loader's ``refresh_times`` (as
    offsets from the epoch) — used to prove the boundaries come from the provider,
    not the loader's ``frequency``. Defaults to the loader's 1 s cadence.
    """

    class _StubProvider:
        def __init__(self, field: LoaderField, window):
            self.field = field
            self.window = window

        def materialize(self):
            calls.setdefault(self.field.var, []).append("materialize")
            return _NativeDataset({self.field.var: _NativeField([0.25, 1.0, 0.25], ("x",))})

        def refresh(self, t: _dt.datetime):
            secs = (t - _EPOCH).total_seconds()
            calls.setdefault(self.field.var, []).append(secs)
            if self.field.var == "u":
                return _NativeDataset({"u": _NativeField([99.0, _seg_value(secs), -99.0], ("x",))})
            return _NativeDataset({self.field.var: _NativeField([0.25, 1.0, 0.25], ("x",))})

        def refresh_times(self) -> List[_dt.datetime]:
            if self.field.loader.temporal is None or self.window is None:
                return []
            if anchors_seconds is not None:
                return [_EPOCH + _dt.timedelta(seconds=s) for s in anchors_seconds]
            # default: 1 s cadence over the window, aligned to the epoch
            out: List[_dt.datetime] = []
            a = max(self.window[0], _EPOCH)
            while a < self.window[1]:
                out.append(a)
                a = a + _dt.timedelta(seconds=1)
            return out

    return lambda field, window: _StubProvider(field, window)


# --------------------------------------------------------------------------
# (a) the provider-object path: GET + REFRESH at refresh_times() boundaries
# --------------------------------------------------------------------------


def test_provider_object_path_refreshes_at_cadence() -> None:
    esm = load(_FIXTURE)
    calls: Dict[str, List] = {}
    result = simulate(
        esm,
        tspan=(0.0, 2.0),
        method="LSODA",
        provider_factory=_make_factory(calls),
    )
    assert result.success, result.message
    assert result.vars == ["Plume.c"]

    # Same analytic piecewise solution as C1 (dc/dt = (u[2] + z0[2]) - c, c0=0),
    # proving the refreshed native arrays reach the RHS and dependent vars
    # (the coupled wind/rough forcing) pick them up between segments.
    f0, f1 = _seg_value(0.0) + 1.0, _seg_value(1.0) + 1.0  # 11 on [0,1), 21 on [1,2)
    c1 = f0 * (1.0 - math.exp(-1.0))
    c2 = f1 + (c1 - f1) * math.exp(-1.0)
    assert _c_at(result, 1.0) == pytest.approx(c1, rel=1e-4)
    assert _c_at(result, 2.0) == pytest.approx(c2, rel=1e-4)


def test_const_materialized_once_discrete_refreshed_per_boundary() -> None:
    esm = load(_FIXTURE)
    calls: Dict[str, List] = {}
    result = simulate(
        esm,
        tspan=(0.0, 2.0),
        method="LSODA",
        provider_factory=_make_factory(calls),
    )
    assert result.success, result.message

    # CONST loader: materialize() exactly once, never refreshed.
    assert calls["z0"] == ["materialize"]

    # DISCRETE loader: refresh() at the seed (t=0) + once per interior cadence
    # boundary (t=1 for the 1 s cadence over [0,2)) — and NOTHING per RHS eval.
    # invocation count == #segments (boundaries), << #RHS calls.
    assert calls["u"] == [0.0, 1.0]
    assert result.nfev > 10
    assert len(calls["u"]) < result.nfev


def test_boundaries_come_from_refresh_times_not_frequency() -> None:
    # The loader's frequency is 1 s (PT1S) → frequency arithmetic would put the
    # only interior boundary at t=1. Override refresh_times() with a 0.5 s/1.5 s
    # schedule: if the driver honours the provider, the discrete loader refreshes
    # at exactly those instants (seed + 0.5 + 1.5), not at t=1.
    esm = load(_FIXTURE)
    calls: Dict[str, List] = {}
    result = simulate(
        esm,
        tspan=(0.0, 2.0),
        method="LSODA",
        provider_factory=_make_factory(calls, anchors_seconds=[0.0, 0.5, 1.5]),
    )
    assert result.success, result.message
    assert calls["u"] == [0.0, 0.5, 1.5]


def test_provider_factory_ignored_when_callable_given() -> None:
    # Legacy precedence: an explicit loader_provider callable wins over a
    # provider_factory, so existing offline-stub call sites keep their behaviour.
    esm = load(_FIXTURE)
    factory_calls: Dict[str, List] = {}
    callable_calls: List[str] = []

    def _legacy(field: LoaderField, t: float) -> np.ndarray:
        callable_calls.append(field.var)
        if field.var == "u":
            return np.array([99.0, _seg_value(t), -99.0])
        return np.array([0.25, 1.0, 0.25])

    result = simulate(
        esm,
        tspan=(0.0, 2.0),
        method="LSODA",
        loader_provider=_legacy,
        provider_factory=_make_factory(factory_calls),
    )
    assert result.success, result.message
    assert callable_calls, "legacy callable must be the one consulted"
    assert factory_calls == {}, "provider_factory must be ignored when a callable is given"


# --------------------------------------------------------------------------
# (b) in-tree LoadDataProvider: refresh_times computed from the loader cadence
# --------------------------------------------------------------------------


def test_load_data_provider_refresh_times_from_temporal() -> None:
    flat = flatten(load(_FIXTURE))
    u_field = next(f for f in flat.loader_fields if f.var == "u")
    z0_field = next(f for f in flat.loader_fields if f.var == "z0")

    window = (_EPOCH, _EPOCH + _dt.timedelta(seconds=3))
    prov = build_default_provider(u_field, window)
    assert isinstance(prov, LoadDataProvider)
    assert isinstance(prov, Provider)  # structural conformance to the contract
    # PT1S cadence aligned to the epoch, anchors in [start, start+3).
    assert prov.refresh_times() == [
        _EPOCH,
        _EPOCH + _dt.timedelta(seconds=1),
        _EPOCH + _dt.timedelta(seconds=2),
    ]
    # CONST loader (no temporal) contributes no tstops.
    assert build_default_provider(z0_field, None).refresh_times() == []


def test_load_data_provider_refresh_times_needs_window() -> None:
    flat = flatten(load(_FIXTURE))
    u_field = next(f for f in flat.loader_fields if f.var == "u")
    # Unbounded (no window) → no enumerable schedule (falls back to freq math).
    assert build_default_provider(u_field, None).refresh_times() == []


# --------------------------------------------------------------------------
# (c) native-array → C4 regrid / identity bridge in the consumer
# --------------------------------------------------------------------------


def _campfire_surface_domain():
    sr = (
        "+proj=lcc +lat_1=30.0 +lat_2=60.0 +lat_0=39.0 +lon_0=-97.0 "
        "+x_0=0 +y_0=0 +datum=WGS84 +units=m +no_defs"
    )
    return SimpleNamespace(
        spatial={
            "x": SimpleNamespace(min=-2026020.2, max=-1990020.2, grid_spacing=2000.0),
            "y": SimpleNamespace(min=374725.0, max=414725.0, grid_spacing=2000.0),
        },
        spatial_ref=sr,
    )


def _loader_field(var, method=None):
    return LoaderField(
        name=f"ERA5.pl.{var}",
        owner="ERA5",
        subkey="pl",
        var=var,
        loader=SimpleNamespace(temporal=None),
        cadence="discrete",
    )


def test_provider_array_identity_without_target_or_coords() -> None:
    # No target grid → raw flatten (the native==sim-grid / stub identity path).
    native = _NativeDataset({"u": _NativeField([[1.0, 2.0], [3.0, 4.0]], ("a", "b"))})
    assert np.array_equal(
        _provider_array(_loader_field("u", "bspline"), native, None),
        np.array([1.0, 2.0, 3.0, 4.0]),
    )
    # Target set but the native dataset exposes no coords → keep the raw array.
    out = _provider_array(_loader_field("u", "bspline"), native, object())
    assert np.array_equal(out, np.array([1.0, 2.0, 3.0, 4.0]))


def test_provider_array_resolves_file_variable_band_name() -> None:
    """Gap V: an EarthSciIO reader keys its NativeDataset by the loader's
    ``file_variable`` (a GeoTIFF band ``"Band1"``), but the flattened
    ``field.var`` is the model-facing semantic name (``"fuel_model"``). The
    extraction must remap ``var -> file_variable`` to find the band."""
    loader = SimpleNamespace(
        temporal=None,
        variables={"fuel_model": SimpleNamespace(file_variable="Band1")},
    )
    field = LoaderField(
        name="LANDFIRE.raw.fuel_model",
        owner="LANDFIRE",
        subkey="raw",
        var="fuel_model",
        loader=loader,
        cadence="const",
    )
    native = _NativeDataset({"Band1": _NativeField([[7.0, 8.0], [9.0, 10.0]], ("y", "x"))})
    # No target → raw flatten, but the fuel_model → Band1 remap must still apply.
    out = _provider_array(field, native, None)
    assert np.array_equal(out, np.array([7.0, 8.0, 9.0, 10.0]))


def test_provider_array_file_variable_matching_name_and_stub() -> None:
    """When ``file_variable`` equals ``var`` (ERA5 ``"t"``), or the loader has no
    variables mapping (a stub provider), extraction falls back to the semantic
    ``var`` unchanged — the remap is a no-op."""
    # Matching name: file_variable == var.
    loader = SimpleNamespace(temporal=None, variables={"t": SimpleNamespace(file_variable="t")})
    field = LoaderField(
        name="ERA5.pl.t",
        owner="ERA5",
        subkey="pl",
        var="t",
        loader=loader,
        cadence="discrete",
    )
    native = _NativeDataset({"t": _NativeField([[1.0, 2.0]], ("y", "x"))})
    assert np.array_equal(_provider_array(field, native, None), np.array([1.0, 2.0]))
    # Stub loader (no .variables) → index by the semantic var.
    native2 = _NativeDataset({"u": _NativeField([[5.0, 6.0]], ("y", "x"))})
    assert np.array_equal(
        _provider_array(_loader_field("u", None), native2, None), np.array([5.0, 6.0])
    )
