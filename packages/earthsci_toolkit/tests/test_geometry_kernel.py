"""Conservative-regridding geometry kernel — Python evaluator conformance.

Bead ess-my4.4.4 (the Python ``intersect_polygon`` kernel). RFC
``semiring-faq-unified-ir`` §8.1 / Appendix B; ``CONFORMANCE_SPEC.md`` §5.8.

Three layers are exercised:

1. **Structural parity** — the shared ``tests/valid/geometry/*.esm`` fixtures are
   schema- and structurally valid on the Python side too (the Go and TS bindings
   assert the same in ``geometry_fixtures_test.go`` / ``geometry-fixtures.test.ts``),
   and the invalid fixtures are rejected.
2. **Evaluator** — the ``intersect_polygon`` leaf clips via the planar
   Sutherland–Hodgman path (dependency-free) and via ``spherely`` (S2) when it is
   installed (skipped otherwise); ``polygon_area`` evaluates as an ordinary
   ``sum_product`` FAQ over the derived clip-ring index set, reusing the M1
   ``_eval_arrayop`` machinery — including the actual AST baked into the planar
   fixture.
3. **Tolerance** — the B.5 / §5.8.2 combined rel+abs area gate with the sliver
   floor.

``spherely`` is pre-1.0 and PINNED as the optional ``[geometry]`` extra; the
spherical *clip* tests skip when it is absent, but the spherical *area* (closed
form Van Oosterom–Strackee excess) needs no backend and is always exercised.
"""

from __future__ import annotations

import json
import math
from pathlib import Path
from typing import List

import numpy as np
import pytest
from conftest import INVALID_DIR, VALID_DIR

from earthsci_toolkit import area_faq
from earthsci_toolkit import geometry as geom
from earthsci_toolkit.esm_types import ExprNode
from earthsci_toolkit.numpy_interpreter import (
    EvalContext,
    NumpyInterpreterError,
    eval_expr,
    expr_contains_array_op,
)
from earthsci_toolkit.parse import load
from earthsci_toolkit.serialize import save
from earthsci_toolkit.validation import validate


_VALID_GEOM = VALID_DIR / "geometry"
_INVALID_GEOM = INVALID_DIR / "geometry"

# Two unit-aligned squares overlapping in the [1,2]×[1,2] box → overlap area 1.0.
_SQUARE_A = np.array([[0.0, 0.0], [2.0, 0.0], [2.0, 2.0], [0.0, 2.0]])
_SQUARE_B = np.array([[1.0, 1.0], [3.0, 1.0], [3.0, 3.0], [1.0, 3.0]])

try:  # the spherical clip path needs the pinned optional dependency
    import spherely  # noqa: F401

    _HAVE_SPHERELY = True
except ImportError:
    _HAVE_SPHERELY = False


# --------------------------------------------------------------------------- #
# 1. Structural parity with the Go / TS geometry suites
# --------------------------------------------------------------------------- #


def _valid_fixtures() -> List[Path]:
    return sorted(_VALID_GEOM.glob("*.esm")) if _VALID_GEOM.is_dir() else []


def _invalid_fixtures() -> List[Path]:
    return sorted(_INVALID_GEOM.glob("*.esm")) if _INVALID_GEOM.is_dir() else []


def test_geometry_fixtures_present() -> None:
    assert _valid_fixtures(), f"no valid geometry fixtures under {_VALID_GEOM}"
    assert _invalid_fixtures(), f"no invalid geometry fixtures under {_INVALID_GEOM}"


@pytest.mark.parametrize("fixture", _valid_fixtures(), ids=lambda p: p.name)
def test_valid_geometry_fixture_is_valid(fixture: Path) -> None:
    """Every shared valid geometry fixture passes schema + structural validation."""
    result = validate(json.loads(fixture.read_text()))
    assert not result.schema_errors, (
        f"{fixture.name}: schema errors {[e.message for e in result.schema_errors]}"
    )
    assert not result.structural_errors, (
        f"{fixture.name}: structural errors "
        f"{[(e.code, e.path, e.message) for e in result.structural_errors]}"
    )
    assert result.is_valid


@pytest.mark.parametrize("fixture", _invalid_fixtures(), ids=lambda p: p.name)
def test_invalid_geometry_fixture_is_rejected(fixture: Path) -> None:
    """Missing manifold / wrong arity fail schema validation; an out-of-set
    manifold fails the post-expansion validator (`geometry_manifold_invalid`,
    esm-spec §9.6.4 — the schema admits any string there since the §9.6.1
    scalar-field substitution-site widening). Both surface as load-time
    rejection through ``validate``."""
    result = validate(json.loads(fixture.read_text()))
    assert result.schema_errors or result.structural_errors, (
        f"{fixture.name}: expected load-time rejection (missing manifold / 3 operands / "
        f"out-of-set manifold) but validation passed"
    )


# --------------------------------------------------------------------------- #
# 2a. intersect_polygon leaf — planar clip
# --------------------------------------------------------------------------- #


def test_planar_clip_overlapping_squares() -> None:
    ring = geom.intersect_polygon(_SQUARE_A, _SQUARE_B, "planar")
    # Distinct overlap vertices are the unit square (1,1)-(2,1)-(2,2)-(1,2) in
    # some rotation; compare as an unordered vertex set.
    verts = {tuple(np.round(p, 9)) for p in ring}
    assert verts == {(1.0, 1.0), (2.0, 1.0), (2.0, 2.0), (1.0, 2.0)}
    assert math.isclose(geom.polygon_area(ring, "planar"), 1.0, abs_tol=1e-12)


def test_planar_clip_disjoint_is_empty() -> None:
    far = np.array([[5.0, 5.0], [6.0, 5.0], [6.0, 6.0], [5.0, 6.0]])
    ring = geom.intersect_polygon(_SQUARE_A, far, "planar")
    assert ring.shape == (0, 2)
    assert geom.polygon_area(ring, "planar") == 0.0


def test_planar_clip_is_orientation_robust() -> None:
    """A clockwise operand still yields the correct (positive) overlap area."""
    a_cw = _SQUARE_A[::-1].copy()
    b_cw = _SQUARE_B[::-1].copy()
    ring = geom.intersect_polygon(a_cw, b_cw, "planar")
    assert math.isclose(geom.polygon_area(ring, "planar"), 1.0, abs_tol=1e-12)


def test_intersect_polygon_via_eval_expr_registers_derived_ring() -> None:
    ctx = _empty_ctx()
    node = ExprNode(
        op="intersect_polygon",
        id="clip0",
        manifold="planar",
        args=[
            ExprNode(op="const", value=_SQUARE_A.tolist()),
            ExprNode(op="const", value=_SQUARE_B.tolist()),
        ],
    )
    closed = eval_expr(node, ctx)
    # The interpreter returns a CLOSED ring (first vertex repeated) and registers
    # it under the node id so a derived index set can resolve its extent.
    assert closed.shape == (5, 2)
    assert np.allclose(closed[0], closed[-1])
    assert "clip0" in ctx.derived_rings


def test_expr_contains_array_op_flags_intersect_polygon() -> None:
    node = ExprNode(op="intersect_polygon", manifold="planar", args=["a", "b"])
    assert expr_contains_array_op(node) is True


def test_intersect_polygon_requires_manifold() -> None:
    node = ExprNode(op="intersect_polygon", args=["a", "b"])  # no manifold
    with pytest.raises(NumpyInterpreterError, match="manifold"):
        eval_expr(node, _ctx_with_polys())


def test_intersect_polygon_is_strictly_binary() -> None:
    node = ExprNode(
        op="intersect_polygon",
        manifold="planar",
        args=[ExprNode(op="const", value=_SQUARE_A.tolist())],  # one operand
    )
    with pytest.raises(NumpyInterpreterError, match="binary"):
        eval_expr(node, _empty_ctx())


# --------------------------------------------------------------------------- #
# 2b. polygon_area as a sum_product FAQ over the derived clip ring
# --------------------------------------------------------------------------- #


def test_polygon_area_faq_over_derived_clip_ring() -> None:
    """polygon_area is an ordinary sum_product FAQ over the clip-ring index set."""
    ctx = _ctx_with_polys()
    ctx.index_sets = {"clip_ring": {"kind": "derived", "from_faq": "overlap_clip"}}

    clip = ExprNode(
        op="intersect_polygon", id="overlap_clip", manifold="planar", args=["src_poly", "tgt_poly"]
    )
    eval_expr(clip, ctx)  # materializes the derived ring under "overlap_clip"

    area = _shoelace_faq(clip_symbol="overlap_clip", ring_set="clip_ring")
    assert math.isclose(float(eval_expr(area, ctx)), 1.0, abs_tol=1e-12)


def test_derived_range_unmaterialized_raises() -> None:
    ctx = _empty_ctx()
    ctx.index_sets = {"clip_ring": {"kind": "derived", "from_faq": "missing"}}
    area = _shoelace_faq(clip_symbol="missing", ring_set="clip_ring")
    with pytest.raises(NumpyInterpreterError, match="not materialized"):
        eval_expr(area, ctx)


def test_planar_fixture_clip_and_area_evaluate() -> None:
    """The shared planar fixture's actual clip + area-FAQ AST evaluates to 1.0."""
    fixture = _VALID_GEOM / "intersect_polygon_planar_area.esm"
    doc = load(str(fixture))
    model = doc.models["PolygonClipAreaPlanar"]
    ctx = _ctx_with_polys()
    # index_sets is document-scoped (v0.8.0): read it from the top-level file.
    ctx.index_sets = doc.index_sets

    closed = eval_expr(model.variables["clip"].expression, ctx)
    ctx.derived_rings["clip"] = closed  # bind the observed `clip` to its ring
    area = float(eval_expr(model.variables["area"].expression, ctx))
    assert math.isclose(area, 1.0, abs_tol=1e-12)


# --------------------------------------------------------------------------- #
# 2b′. polygon_intersection_area — the fused scalar clip+area leaf (§8.6.1)
# --------------------------------------------------------------------------- #


def _polygon_intersection_area_node(manifold: str = "planar") -> ExprNode:
    return ExprNode(
        op="polygon_intersection_area",
        manifold=manifold,
        args=[
            ExprNode(op="const", value=_SQUARE_A.tolist()),
            ExprNode(op="const", value=_SQUARE_B.tolist()),
        ],
    )


def test_polygon_intersection_area_via_eval_expr_is_scalar_one() -> None:
    """The fused leaf returns the SCALAR overlap area (1.0) — a plain float."""
    ctx = _empty_ctx()
    val = eval_expr(_polygon_intersection_area_node("planar"), ctx)
    assert isinstance(val, float)  # scalar leaf, not an array-valued ring
    assert math.isclose(val, 1.0, abs_tol=1e-9)
    # No clip ring / derived index set is exposed by the fused form.
    assert ctx.derived_rings == {}


def test_polygon_intersection_area_equals_clip_then_area() -> None:
    """It equals polygon_area(intersect_polygon(a, b)) at the same manifold."""
    ring = geom.intersect_polygon(_SQUARE_A, _SQUARE_B, "planar")
    fused = float(eval_expr(_polygon_intersection_area_node("planar"), _empty_ctx()))
    assert math.isclose(fused, geom.polygon_area(ring, "planar"), abs_tol=1e-12)
    assert math.isclose(fused, area_faq.polygon_area_via_faq(ring, "planar"), abs_tol=1e-12)


def test_polygon_intersection_area_disjoint_is_zero() -> None:
    """Non-overlapping operands give a zero fused area (empty clip)."""
    far = np.array([[5.0, 5.0], [6.0, 5.0], [6.0, 6.0], [5.0, 6.0]])
    node = ExprNode(
        op="polygon_intersection_area",
        manifold="planar",
        args=[
            ExprNode(op="const", value=_SQUARE_A.tolist()),
            ExprNode(op="const", value=far.tolist()),
        ],
    )
    assert float(eval_expr(node, _empty_ctx())) == 0.0


def test_polygon_intersection_area_inside_aggregate_body() -> None:
    """As a scalar leaf it evaluates inside an aggregate body (a 1-term sum)."""
    agg = ExprNode(
        op="aggregate",
        semiring="sum_product",
        output_idx=[],
        args=[],
        ranges={"k": [1, 1]},
        expr=_polygon_intersection_area_node("planar"),
    )
    assert math.isclose(float(eval_expr(agg, _empty_ctx())), 1.0, abs_tol=1e-9)


def test_polygon_intersection_area_requires_manifold() -> None:
    node = ExprNode(op="polygon_intersection_area", args=["a", "b"])  # no manifold
    with pytest.raises(NumpyInterpreterError, match="manifold"):
        eval_expr(node, _ctx_with_polys())


def test_polygon_intersection_area_is_strictly_binary() -> None:
    node = ExprNode(
        op="polygon_intersection_area",
        manifold="planar",
        args=[ExprNode(op="const", value=_SQUARE_A.tolist())],  # one operand
    )
    with pytest.raises(NumpyInterpreterError, match="binary"):
        eval_expr(node, _empty_ctx())


def test_expr_contains_array_op_flags_polygon_intersection_area() -> None:
    node = ExprNode(op="polygon_intersection_area", manifold="planar", args=["a", "b"])
    assert expr_contains_array_op(node) is True


# --------------------------------------------------------------------------- #
# 2c. Spherical / geodesic — area always; clip when spherely is present
# --------------------------------------------------------------------------- #


def test_spherical_area_octant_is_pi_over_two() -> None:
    """A spherical octant triangle has area π/2 on the unit sphere (R=1)."""
    octant = np.array([[0.0, 0.0], [90.0, 0.0], [0.0, 90.0]])
    assert math.isclose(geom.polygon_area(octant, "spherical"), math.pi / 2, abs_tol=1e-12)


def test_spherical_area_matches_planar_for_tiny_cell() -> None:
    """For a sub-degree cell the spherical area ≈ the planar area (in rad²)."""
    cell = np.array([[0.0, 0.0], [1e-3, 0.0], [1e-3, 1e-3], [0.0, 1e-3]])
    sph = geom.polygon_area(cell, "spherical")
    planar_rad2 = geom.polygon_area(cell, "planar") * math.radians(1.0) ** 2
    assert math.isclose(sph, planar_rad2, rel_tol=1e-3)


def test_geodesic_uses_same_great_circle_area_as_spherical() -> None:
    octant = np.array([[0.0, 0.0], [90.0, 0.0], [0.0, 90.0]])
    assert geom.polygon_area(octant, "geodesic") == geom.polygon_area(octant, "spherical")


# --------------------------------------------------------------------------- #
# 2c-faq. Spherical polygon_area as a sum_product FAQ over the derived clip ring
#         (the spherical sibling of the planar shoelace FAQ; ess-d4g.1). The FAQ
#         is what the production polygon-area path now evaluates
#         (area_faq.polygon_area_via_faq); the imperative geometry.polygon_area is
#         its cross-check oracle.
# --------------------------------------------------------------------------- #


def _spherical_faq_area(ring: np.ndarray) -> float:
    """Evaluate the production spherical-area FAQ over ``ring`` through eval_expr
    (the :func:`area_faq.polygon_area_via_faq` entry point; no spherely needed —
    the area FAQ is closed-form)."""
    return area_faq.polygon_area_via_faq(ring, "spherical")


def test_spherical_area_faq_octant_via_eval_expr() -> None:
    """The spherical ``polygon_area`` FAQ (Van Oosterom–Strackee fan excess)
    evaluates the octant to π/2 through the generic ``sum_product`` machinery —
    the spherical sibling of the planar ``test_polygon_area_faq_over_derived_clip_ring``."""
    octant = np.array([[0.0, 0.0], [90.0, 0.0], [0.0, 90.0]])
    assert math.isclose(_spherical_faq_area(octant), math.pi / 2, abs_tol=1e-12)


@pytest.mark.parametrize("manifold", ["spherical", "geodesic"])
def test_spherical_area_faq_matches_imperative_oracle(manifold: str) -> None:
    """The FAQ-evaluated spherical area equals the imperative
    ``geometry.polygon_area`` oracle for a general (non-degenerate) ring — the
    oracle is now only the cross-check, the FAQ is the production path."""
    ring = np.array([[10.0, 20.0], [30.0, 22.0], [28.0, 40.0], [8.0, 38.0]])
    assert math.isclose(
        _spherical_faq_area(ring),
        geom.polygon_area(ring, manifold),
        rel_tol=1e-12,
    )


def test_spherical_clip_area_via_faq_matches_oracle() -> None:
    """The spherical clip's area routed through the FAQ
    (:func:`area_faq.polygon_area_via_faq`) matches the imperative
    ``geometry.polygon_area`` oracle on the clipped ring."""
    if not _HAVE_SPHERELY:
        pytest.skip("spherely (S2) not installed; the spherical clip cannot run")
    clipped = geom.intersect_polygon(_SQUARE_A, _SQUARE_B, "spherical")
    assert math.isclose(
        _spherical_faq_area(clipped),
        geom.polygon_area(clipped, "spherical"),
        rel_tol=1e-9,
    )


def test_spherical_clip_without_backend_raises_unavailable() -> None:
    if _HAVE_SPHERELY:
        pytest.skip("spherely is installed; the unavailable path is not reachable")
    with pytest.raises(geom.GeometryBackendUnavailable):
        geom.intersect_polygon(_SQUARE_A, _SQUARE_B, "spherical")


@pytest.mark.skipif(not _HAVE_SPHERELY, reason="spherely (S2) not installed")
def test_spherical_clip_overlapping_squares_with_spherely() -> None:
    ring = geom.intersect_polygon(_SQUARE_A, _SQUARE_B, "spherical")
    assert ring.shape[0] >= 3
    # The closed-form spherical-excess reference (great-circle edges, R=1) must
    # agree with spherely's own S2 area of the SAME clipped ring to the tight
    # S2-vs-S2 tolerance (B.5 / §5.8.2) — both share the S2 geodesic-edge model.
    area_excess = geom.polygon_area(ring, "spherical")
    area_spherely = float(spherely.area(geom._spherely_polygon(ring)))
    assert geom.area_tolerance_ok(area_excess, area_spherely, rtol=1e-9)


# --------------------------------------------------------------------------- #
# 2d. Polar-edge densification — great-circle-edge accuracy (ess-my4.4.9)
# --------------------------------------------------------------------------- #


def _true_cell_area(lon1: float, lon2: float, lat1: float, lat2: float) -> float:
    """Exact area of a lon-lat cell on the unit sphere: ``Δλ·(sin φ₂ − sin φ₁)``.

    The small-circle (true parallel-edge) area — the ground truth the
    great-circle-edge ``polygon_area`` is compared against (RFC §B.4).
    """
    return math.radians(lon2 - lon1) * (math.sin(math.radians(lat2)) - math.sin(math.radians(lat1)))


def test_densification_reduces_coarse_polar_cell_area_error() -> None:
    """A coarse polar cell's great-circle-edge area error collapses under densification (RFC §B.4)."""
    # A 30°-wide coarse cell at high latitude.
    cell = np.array([[0.0, 60.0], [30.0, 60.0], [30.0, 80.0], [0.0, 80.0]])
    a_true = _true_cell_area(0.0, 30.0, 60.0, 80.0)
    a_coarse = geom.polygon_area(cell, "spherical")
    err_coarse = abs(a_coarse - a_true) / a_true
    # The undensified great-circle cell really is off by a few percent (≈3.6%
    # here — the ~4% the RFC quotes for a 30° polar cell).
    assert err_coarse > 0.02
    # Densify the parallel edges to ≤1° segments → the error collapses by >100×.
    dense = geom.densify_parallel_edges(cell, 1.0)
    assert dense.shape[0] > cell.shape[0]  # vertices were inserted
    a_dense = geom.polygon_area(dense, "spherical")
    err_dense = abs(a_dense - a_true) / a_true
    assert err_dense < err_coarse  # densification reduces the error
    assert err_dense < 1e-3  # and converges to the true area
    # Monotone: finer densification ⇒ smaller error.
    err_5 = (
        abs(geom.polygon_area(geom.densify_parallel_edges(cell, 5.0), "spherical") - a_true)
        / a_true
    )
    assert err_dense < err_5 < err_coarse


def test_densification_only_touches_parallel_edges_and_is_opt_in() -> None:
    # Two meridian edges (constant lon) + two 1°-wide parallel edges.
    quad = np.array([[0.0, 0.0], [0.0, 10.0], [1.0, 10.0], [1.0, 0.0]])
    dense = geom.densify_parallel_edges(quad, 0.5)
    # Only the two parallels split (1° > 0.5° ⇒ one interior point each); the two
    # 10° meridians are left whole — a meridian is already a great circle.
    assert dense.shape[0] == 4 + 2
    # A cell already finer than the segment cap is unchanged.
    assert geom.densify_parallel_edges(quad, 5.0).shape[0] == 4
    # Off-by-default opt-in: a non-positive cap is rejected.
    with pytest.raises(geom.GeometryError):
        geom.densify_parallel_edges(quad, 0.0)


def test_densified_vertices_stay_on_the_parallel() -> None:
    """Inserted vertices lie exactly on the parallel (constant latitude)."""
    cell = np.array([[0.0, 70.0], [40.0, 70.0], [40.0, 71.0], [0.0, 71.0]])
    dense = geom.densify_parallel_edges(cell, 10.0)
    # Every vertex shares a latitude with one of the two parallel edges.
    lats = {round(float(v), 9) for v in dense[:, 1]}
    assert lats == {70.0, 71.0}


# --------------------------------------------------------------------------- #
# 3. B.5 / §5.8.2 area-tolerance gate
# --------------------------------------------------------------------------- #


def test_tolerance_exact_match_passes() -> None:
    assert geom.area_tolerance_ok(1.0, 1.0, rtol=1e-12)


def test_tolerance_sub_atol_slivers_treated_as_zero() -> None:
    # "present-but-tiny" and "absent" both pass: both are below the sliver floor.
    assert geom.area_tolerance_ok(1e-20, 0.0, rtol=1e-12)
    assert geom.area_tolerance_ok(0.0, 1e-20, rtol=1e-12)


def test_tolerance_gross_disagreement_fails() -> None:
    assert not geom.area_tolerance_ok(1.0, 2.0, rtol=1e-9)


def test_tolerance_relative_band_scales_with_reference() -> None:
    # A 1e-6 relative error passes at rtol 1e-5 but fails at rtol 1e-7.
    assert geom.area_tolerance_ok(1.0 + 1e-6, 1.0, rtol=1e-5)
    assert not geom.area_tolerance_ok(1.0 + 1e-6, 1.0, rtol=1e-7)


# --------------------------------------------------------------------------- #
# 4. manifold / id round-trip + parser contract
# --------------------------------------------------------------------------- #


def test_manifold_and_id_survive_typed_round_trip() -> None:
    fixture = _VALID_GEOM / "intersect_polygon_clip_area.esm"
    dumped = json.loads(save(load(str(fixture))))
    clip = dumped["models"]["PolygonClipArea"]["variables"]["clip"]["expression"]
    assert clip["manifold"] == "spherical"
    assert clip["id"] == "overlap_clip"
    # idempotent: a second round-trip is byte-identical
    assert save(load(str(fixture))) == save(load(str(fixture)))


def test_parser_rejects_intersect_polygon_without_manifold() -> None:
    from earthsci_toolkit.parse import _parse_expression

    with pytest.raises(ValueError, match="manifold"):
        _parse_expression({"op": "intersect_polygon", "args": ["a", "b"]})


def test_parser_rejects_polygon_intersection_area_without_manifold() -> None:
    from earthsci_toolkit.parse import _parse_expression

    with pytest.raises(ValueError, match="manifold"):
        _parse_expression({"op": "polygon_intersection_area", "args": ["a", "b"]})


# --------------------------------------------------------------------------- #
# helpers
# --------------------------------------------------------------------------- #


def _empty_ctx() -> EvalContext:
    return EvalContext(
        state_layout={},
        state_shapes={},
        param_values={},
        observed_values={},
        y=np.empty(0, dtype=float),
        t=0.0,
    )


def _ctx_with_polys() -> EvalContext:
    """An EvalContext binding ``src_poly`` / ``tgt_poly`` as the two test squares."""
    return EvalContext(
        state_layout={"src_poly": slice(0, 8), "tgt_poly": slice(8, 16)},
        state_shapes={"src_poly": (4, 2), "tgt_poly": (4, 2)},
        param_values={},
        observed_values={},
        y=np.concatenate([_SQUARE_A.ravel(), _SQUARE_B.ravel()]),
        t=0.0,
    )


def _shoelace_faq(clip_symbol: str, ring_set: str) -> ExprNode:
    """The planar polygon_area FAQ: 0.5·Σ_v (x_v·y_{v+1} − x_{v+1}·y_v)."""

    def col(idx_expr, c: int) -> ExprNode:
        return ExprNode(op="index", args=[clip_symbol, idx_expr, c])

    v_next = ExprNode(op="+", args=["v", 1])
    cross = ExprNode(
        op="-",
        args=[
            ExprNode(op="*", args=[col("v", 1), col(v_next, 2)]),
            ExprNode(op="*", args=[col(v_next, 1), col("v", 2)]),
        ],
    )
    body = ExprNode(op="*", args=[0.5, cross])
    return ExprNode(
        op="aggregate",
        semiring="sum_product",
        output_idx=[],
        args=[clip_symbol],
        ranges={"v": {"from": ring_set}},
        expr=body,
    )
