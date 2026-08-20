"""Data source -> consumer value-injection tests (campfire-e2e C1, bead ess-06y).

These lock in the esm-spec §8.5 injection path. From esm 1.0.0 a data source is
NOT a component: there is no loader subsystem and no coupling edge. A model
consumes a source by declaring a PARAMETER whose ``update`` names it —
``{"kind": "data", "source": "<key>", "from": {"file_variable": "U"}}`` — so
the parameter IS the loaded field and owns the units.

* ``flatten`` records a :class:`LoaderField` per such parameter, carrying its
  cadence. The cadence follows the SOURCE, not the parameter: a source WITH a
  ``temporal`` block is time-varying (``discrete``), one without is read once
  (``const``).
* ``simulate`` executes the sources and binds their arrays into the NumPy RHS as
  read-only inputs under the parameter's flattened name, so the consumer
  equation sees the loaded values rather than the parameter's constant default.
* Const sources are read once; discrete sources refresh at their cadence via
  terminal-event segmentation, and the RHS is pure within a segment.

The sources are driven by a deterministic in-process provider (no network), so
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
    """Wind value U[2] for the segment containing simulation time ``t``.

    Segment [0, 1) -> 10, [1, 2) -> 20, ... (steps every cadence second). The
    provider is queried once per segment at the segment's start, so ``round``
    on the (integer) boundary picks that segment's value.
    """
    return 10.0 + 10.0 * round(t)


def _make_provider(calls: Dict[str, List[float]]):
    """Deterministic source provider that records the times it is queried.

    ``U`` is a 3-element wind array whose MIDDLE element (1-based index 2) is
    the only one the consumer reads, proving the bound symbol resolves to a real
    multi-element array (not a coincidental scalar). ``Z0`` is a static
    3-element roughness array; its middle element is 1.0.
    """

    def provider(field: LoaderField, t: float) -> np.ndarray:
        calls.setdefault(field.var, []).append(t)
        if field.var == "U":
            return np.array([99.0, _seg_value(t), -99.0])
        if field.var == "Z0":
            return np.array([0.25, 1.0, 0.25])
        raise AssertionError(f"unexpected source file variable {field.var!r}")

    return provider


def _c_at(result, t: float) -> float:
    return float(np.interp(t, result.t, result.y[0]))


# --------------------------------------------------------------------------
# (a) flatten records a LoaderField per data-fed parameter
# --------------------------------------------------------------------------


def test_flatten_records_a_field_per_data_fed_parameter() -> None:
    flat = flatten(load(_FIXTURE))

    by_name = {lf.name: lf for lf in flat.loader_fields}
    assert set(by_name) == {"Plume.wind", "Plume.rough"}, (
        "each parameter whose update reads a source is a loader field, keyed by "
        "the parameter's namespaced name"
    )

    wind = by_name["Plume.wind"]
    assert (wind.owner, wind.subkey, wind.var) == ("Plume", "pl", "U")
    assert wind.cadence == "discrete", "a source WITH `temporal` seeds discrete cadence"

    rough = by_name["Plume.rough"]
    assert (rough.owner, rough.subkey, rough.var) == ("Plume", "sfc", "Z0")
    assert rough.cadence == "const", "a source WITHOUT `temporal` seeds const cadence"

    # The data-fed parameter is still a PARAMETER of the flattened system -- the
    # source is not a component, so nothing is mounted and nothing is observed --
    # and it carries no defining equation: its value is injected, not computed.
    assert "Plume.wind" in flat.parameters
    assert "Plume.rough" in flat.parameters
    lhs_names = {eq.lhs for eq in flat.equations if isinstance(eq.lhs, str)}
    assert "Plume.wind" not in lhs_names
    assert "Plume.rough" not in lhs_names


def test_flatten_without_data_sources_has_empty_loader_fields() -> None:
    # Regression guard: a plain model carries no loader fields, so simulate()
    # never enters the injection path (cross-binding / existing models intact).
    doc = {
        "esm": "1.0.0",
        "metadata": {"name": "plain"},
        "models": {
            "M": {
                "variables": {"x": {"type": "unknown", "default": 1.0}},
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


def test_a_parameter_naming_an_undeclared_source_is_rejected() -> None:
    # `data_source_undefined` (esm-spec §8). A source is not a component from
    # 1.0.0, so `update.source` is the ONLY way a document can name one -- and it
    # is schema-valid by construction (any string), which is what makes this a
    # genuinely reachable structural finding rather than one masked by a schema
    # error.
    doc = {
        "esm": "1.0.0",
        "metadata": {"name": "dangling"},
        "index_sets": {"cells": {"kind": "interval", "size": 3}},
        "data_sources": {
            "real": {"kind": "static", "source": {"url_template": "file:///x.nc"}}
        },
        "models": {
            "M": {
                "variables": {
                    "x": {"type": "unknown", "default": 1.0},
                    "p": {
                        "type": "parameter",
                        "default": 0.0,
                        "shape": ["cells"],
                        "update": {
                            "kind": "data",
                            "source": "missing",
                            "from": {"file_variable": "P"},
                        },
                    },
                },
                "equations": [
                    {
                        "lhs": {"op": "D", "args": ["x"], "wrt": "t"},
                        "rhs": {"op": "-", "args": ["x"]},
                    }
                ],
            }
        },
    }
    with pytest.raises(Exception) as excinfo:
        load(doc)
    records = getattr(excinfo.value, "records", [])
    assert any(r["code"] == "data_source_undefined" for r in records), records
    finding = next(r for r in records if r["code"] == "data_source_undefined")
    assert finding["path"] == "/models/M/variables/p/update"
    assert finding["details"]["source"] == "missing"
    assert finding["details"]["available_sources"] == ["real"]


# --------------------------------------------------------------------------
# (b) simulate injects the loaded arrays at the right cadence
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

    # Analytic piecewise solution of dc/dt = (wind[2] + rough[2]) - c, c(0) = 0.
    z0 = 1.0
    f0 = _seg_value(0.0) + z0  # 11 on [0, 1)
    f1 = _seg_value(1.0) + z0  # 21 on [1, 2)
    c1 = f0 * (1.0 - math.exp(-1.0))
    c2 = f1 + (c1 - f1) * math.exp(-1.0)

    assert _c_at(result, 1.0) == pytest.approx(c1, rel=1e-4)
    assert _c_at(result, 2.0) == pytest.approx(c2, rel=1e-4)


def test_const_source_read_once_discrete_per_segment() -> None:
    esm = load(_FIXTURE)
    calls: Dict[str, List[float]] = {}
    result = simulate(
        esm,
        tspan=(0.0, 2.0),
        method="LSODA",
        loader_provider=_make_provider(calls),
    )
    assert result.success, result.message

    # Const source: executed exactly once, before integration.
    assert calls["Z0"] == [0.0], "a source with no `temporal` must be read once"

    # Discrete source: once at the start, once per interior cadence boundary
    # (here a single boundary at t=1) — and NOTHING per RHS evaluation. With
    # hundreds of solver RHS calls, a provider hit count of 2 is the proof that
    # the RHS is pure within a segment.
    assert calls["U"] == [0.0, 1.0]
    assert result.nfev > 10
    assert len(calls["U"]) < result.nfev


def test_injected_values_not_constant_defaults() -> None:
    # The consumer's `wind`/`rough` params default to 0.0. If injection failed
    # and the RHS saw the defaults, the forcing would be 0 and c would stay 0.
    # A constant non-zero provider drives c toward its injected steady state
    # F = wind[2] + rough[2], proving real array values reach the RHS.
    esm = load(_FIXTURE)

    def steady_provider(field: LoaderField, t: float) -> np.ndarray:
        if field.var == "U":
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


def test_the_parameter_name_is_what_resolves_at_the_rhs() -> None:
    # The consumer equation names `wind` / `rough` directly: from 1.0.0 the
    # parameter IS the loaded field, so there is no producer symbol to
    # substitute and no coupling edge to resolve. The run succeeding AND
    # tracking the injected value confirms the parameter's namespaced name binds
    # to the injected array at the RHS rather than to its declared default.
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
    # data-fed parameter would raise (caught -> success False).
    assert _c_at(result, 1.0) == pytest.approx(11.0 * (1.0 - math.exp(-1.0)), rel=1e-4)
