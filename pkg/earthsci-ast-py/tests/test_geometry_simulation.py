"""Conservative-regridding geometry kernel — simulate()-path ODE conformance.

Bead ess-my4.4.13 (the Python simulate() driver wiring). RFC
``semiring-faq-unified-ir`` §8.1; ``CONFORMANCE_SPEC.md`` §5.8.

The companion :mod:`test_geometry_kernel` exercises the ``intersect_polygon``
leaf and the ``polygon_area`` FAQ at the ``eval_expr`` level. This module closes
the loop: it drives the shared ``tests/valid/geometry/*.esm`` fixtures that carry
inline ``tests`` blocks END-TO-END through :func:`simulate`, exactly as
:mod:`test_aggregate_conformance` does for the M1 semiring fixtures (the
"Mechanism-A" runner).

A geometry-ODE fixture integrates as a real ODE only because the array-op
simulate driver now materializes, in dependency order, each array-valued
observed (the clipped overlap ring → the derived ``clip_ring`` index set) and
each scalar observed (``area = sum_product FAQ(clip)``) into the eval context
before the state derivatives — so ``D(tracer) = -area·tracer`` can resolve
``area`` and integrate.

The shared runnable fixture uses the dependency-free ``planar`` manifold, so it
runs without the optional ``spherely`` (S2) backend; a fixture whose clip needs a
spherical/geodesic backend is skipped when ``spherely`` is absent.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Dict, List, Tuple

import numpy as np
import pytest
from conftest import VALID_DIR

from earthsci_ast.esm_types import ExprNode
from earthsci_ast.parse import load
from earthsci_ast.simulation import (
    _order_observed_equations,
    _time_varying_observeds,
    simulate,
)

_GEOM_DIR = VALID_DIR / "geometry"

try:  # the spherical/geodesic clip path needs the pinned optional dependency
    import spherely  # noqa: F401

    _HAVE_SPHERELY = True
except ImportError:
    _HAVE_SPHERELY = False


def _collect_fixtures() -> List[Path]:
    """Geometry fixtures that carry at least one inline model ``tests`` block."""
    if not _GEOM_DIR.is_dir():
        return []
    out: List[Path] = []
    for p in sorted(_GEOM_DIR.glob("*.esm")):
        raw = json.loads(p.read_text())
        if any(m.get("tests") for m in (raw.get("models") or {}).values()):
            out.append(p)
    return out


def _needs_spherely(raw: dict) -> bool:
    """True if any geometry-kernel leaf in the file declares a non-planar manifold.

    Covers both the ``intersect_polygon`` clip and the fused
    ``polygon_intersection_area`` leaf — either uses the pinned S2 backend under a
    ``spherical`` / ``geodesic`` manifold.
    """
    found = False

    def walk(node: object) -> None:
        nonlocal found
        if isinstance(node, dict):
            if node.get("op") in (
                "intersect_polygon",
                "polygon_intersection_area",
            ) and node.get("manifold") not in (
                None,
                "planar",
            ):
                found = True
            for v in node.values():
                walk(v)
        elif isinstance(node, list):
            for v in node:
                walk(v)

    walk(raw)
    return found


def _resolve_tolerance(*levels: Dict[str, float]) -> Tuple[float, float]:
    merged: Dict[str, float] = {}
    for t in levels:
        if t:
            merged.update(t)
    return float(merged.get("rel", 0.0)), float(merged.get("abs", 0.0))


def _lookup(result, var_key: str, time: float) -> float:
    match = None
    for i, name in enumerate(result.vars):
        if name == var_key or name.endswith("." + var_key):
            match = i
            break
    if match is None:
        raise AssertionError(f"variable {var_key!r} not in result vars: {result.vars}")
    row = result.y[match, :]
    if len(result.t) == 0:
        raise AssertionError("result has no time points")
    if time <= result.t[0]:
        return float(row[0])
    if time >= result.t[-1]:
        return float(row[-1])
    return float(np.interp(time, result.t, row))


def _passes(actual: float, expected: float, rel: float, ab: float) -> bool:
    diff = abs(actual - expected)
    if ab > 0 and diff <= ab:
        return True
    if rel > 0 and diff / max(abs(expected), 1e-12) <= rel:
        return True
    if ab == 0 and rel == 0:
        return diff == 0.0
    return False


def test_at_least_one_runnable_geometry_fixture() -> None:
    """At least one geometry fixture must be drivable end-to-end through simulate()."""
    assert _collect_fixtures(), (
        f"no executable geometry fixtures (inline `tests`) under {_GEOM_DIR}; "
        "the simulate()-path geometry ODE is unexercised"
    )


@pytest.mark.parametrize("fixture_path", _collect_fixtures(), ids=lambda p: p.name)
def test_geometry_fixture_simulate_conformance(fixture_path: Path) -> None:
    """Run every inline test in a geometry ODE fixture through :func:`simulate`."""
    raw = json.loads(fixture_path.read_text())
    if _needs_spherely(raw) and not _HAVE_SPHERELY:
        pytest.skip(f"{fixture_path.name}: spherical clip needs spherely (S2), absent")

    esm_file = load(fixture_path)
    any_assertions = False
    for model_name, model_raw in (raw.get("models") or {}).items():
        model_tol = model_raw.get("tolerance") or {}
        for test in model_raw.get("tests") or []:
            test_id = test.get("id", "?")
            tspan_raw = test["time_span"]
            tspan = (float(tspan_raw["start"]), float(tspan_raw["end"]))
            ics = {k: float(v) for k, v in (test.get("initial_conditions") or {}).items()}
            params = {k: float(v) for k, v in (test.get("parameter_overrides") or {}).items()}

            result = simulate(esm_file, tspan=tspan, initial_conditions=ics, parameters=params)
            assert result.success, (
                f"{fixture_path.name}::{model_name}::{test_id} simulation failed: {result.message}"
            )

            test_tol = test.get("tolerance") or {}
            for assertion in test.get("assertions", []):
                any_assertions = True
                var_key = assertion["variable"]
                time = float(assertion["time"])
                expected = float(assertion["expected"])
                rel, ab = _resolve_tolerance(model_tol, test_tol, assertion.get("tolerance") or {})
                actual = _lookup(result, var_key, time)
                assert _passes(actual, expected, rel, ab), (
                    f"{fixture_path.name}::{model_name}::{test_id} "
                    f"assertion {var_key}@t={time} expected={expected} "
                    f"actual={actual} tol(rel={rel}, abs={ab})"
                )

    assert any_assertions, f"{fixture_path.name}: no assertions were checked"


def test_polygon_intersection_area_planar_fixture_simulates_to_one() -> None:
    """Focused end-to-end check of the fused polygon_intersection_area leaf.

    Loads the shared ``polygon_intersection_area_planar.esm`` fixture (two unit
    squares overlapping in [1,2]×[1,2]) and integrates it through
    :func:`simulate`. ``D(area_state)/dt = overlap_area`` from a zero IC, so
    ``area_state(1) = overlap_area = 1.0`` — the scalar planar overlap area of the
    fused leaf, to within 1e-9.
    """
    fixture = _GEOM_DIR / "polygon_intersection_area_planar.esm"
    esm_file = load(fixture)
    result = simulate(esm_file, tspan=(0.0, 1.0))
    assert result.success, f"simulation failed: {result.message}"
    area_state = _lookup(result, "area_state", 1.0)
    assert abs(area_state - 1.0) <= 1e-9, f"area_state(1.0) = {area_state}, expected 1.0"


# --------------------------------------------------------------------------- #
# Unit coverage for the driver's observed-scheduling helpers
# --------------------------------------------------------------------------- #


def test_order_observed_equations_is_dependency_sorted() -> None:
    """An observed is ordered after every observed its RHS references."""
    clip = ExprNode(op="intersect_polygon", id="c", manifold="planar", args=["src", "tgt"])
    area = ExprNode(
        op="aggregate",
        semiring="sum_product",
        output_idx=[],
        args=["clip"],
        ranges={"v": {"from": "ring"}},
        expr=ExprNode(op="index", args=["clip", "v", 1]),
    )
    src = ExprNode(op="const", args=[], value=[[0.0, 0.0]])
    tgt = ExprNode(op="const", args=[], value=[[1.0, 1.0]])
    # Declared in dependent-first order to prove the sort actually reorders.
    observed_eqs = [("area", area), ("clip", clip), ("src", src), ("tgt", tgt)]
    names = {"area", "clip", "src", "tgt"}
    order = [n for n, _ in _order_observed_equations(observed_eqs, names)]
    assert order.index("src") < order.index("clip")
    assert order.index("tgt") < order.index("clip")
    assert order.index("clip") < order.index("area")


def test_time_varying_observeds_flags_state_t_and_transitive() -> None:
    """Constant observeds are excluded; state / ``t`` / transitive deps are flagged."""
    const_poly = ExprNode(op="const", args=[], value=[[0.0, 0.0]])
    # depends on a state variable directly
    rate = ExprNode(op="*", args=["k", "tracer"])
    # depends on `t` directly
    ramp = ExprNode(op="*", args=["t", 2.0])
    # depends transitively on the state-dependent observed `rate`
    scaled = ExprNode(op="*", args=["rate", 3.0])
    ordered = [("poly", const_poly), ("rate", rate), ("ramp", ramp), ("scaled", scaled)]
    varying = _time_varying_observeds(ordered, state_names={"tracer"})
    assert "poly" not in varying
    assert varying == {"rate", "ramp", "scaled"}


# ---------------------------------------------------------------------------
# §8.6.1 operand rings: padding / consecutive-duplicate dedup + degenerate
# reject (mirrors the Julia reference _as_ring / _dedup_consecutive)
# ---------------------------------------------------------------------------


def test_as_ring_dedups_padded_and_closing_vertices() -> None:
    """§8.6.1: a padded ring (consecutive duplicate vertices, e.g. an MPAS
    pentagon in a hexagon-shaped slot) and an explicitly-closed ring both
    collapse to their distinct vertices with implicit closure — dedup happens in
    operand coercion, before any backend clip."""
    from earthsci_ast.geometry import _as_ring

    padded = [[0.5, 0.5], [2.5, 0.5], [2.5, 2.5], [0.5, 2.5], [0.5, 2.5]]
    r = _as_ring(padded, who="poly_a")
    assert r.shape[0] == 4
    padded2 = [[1.5, 1.5], [3.5, 1.5], [3.5, 3.5], [1.5, 3.5], [1.5, 3.5], [1.5, 3.5]]
    assert _as_ring(padded2, who="poly_b").shape[0] == 4
    closed = [[0.0, 0.0], [1.0, 0.0], [1.0, 1.0], [0.0, 1.0], [0.0, 0.0]]
    assert _as_ring(closed, who="ring").shape[0] == 4


def test_as_ring_rejects_degenerate_ring() -> None:
    """§8.6.1: fewer than 3 distinct vertices after dedup is degenerate."""
    from earthsci_ast.geometry import GeometryError, _as_ring

    with pytest.raises(GeometryError):
        _as_ring([[0.0, 0.0], [0.0, 0.0], [1.0, 1.0]], who="poly_a")


def test_padded_ring_planar_overlap_area_is_one() -> None:
    """§8.6.1 pin end-to-end (planar): the padded rings' overlap area equals the
    deduplicated-ring overlap — the [1.5,2.5]x[1.5,2.5] box, exactly 1.0."""
    from earthsci_ast.geometry import intersect_polygon, polygon_area

    src = [[0.5, 0.5], [2.5, 0.5], [2.5, 2.5], [0.5, 2.5], [0.5, 2.5]]
    tgt = [[1.5, 1.5], [3.5, 1.5], [3.5, 3.5], [1.5, 3.5], [1.5, 3.5], [1.5, 3.5]]
    overlap = intersect_polygon(src, tgt, "planar")
    assert polygon_area(overlap, "planar") == pytest.approx(1.0, abs=1e-12)
