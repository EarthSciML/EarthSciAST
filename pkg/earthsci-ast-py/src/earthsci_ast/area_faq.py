"""``polygon_area`` as a ``sum_product`` FAQ over the clipped ring (RFC
``semiring-faq-unified-ir`` §8.1; ``CONFORMANCE_SPEC.md`` §5.8; bead ess-d4g.1).

``polygon_area`` is **not** a new op: the area of a clipped vertex ring is an
ordinary ``sum_product`` aggregate over the ring index set. This module builds
that FAQ as an :class:`ExprNode` and evaluates it through the **same** generic
aggregate machinery the interpreter uses (:func:`.eval_expr`) — so the production
polygon area is the FAQ, and the imperative :func:`geometry.polygon_area` /
``_spherical_signed_area`` loops are only its cross-check oracle.

Two manifolds, the same aggregate shape (the planar sibling and the spherical
sibling are tolerance-identical across the Julia / Python / Rust bindings):

* **planar** — the Gauss–Green shoelace ``0.5·Σ_v (x_v·y_{v+1} − x_{v+1}·y_v)``.
* **spherical / geodesic** — the great-circle fan triangulation
  ``Σ_v E(v_1, v_v, v_{v+1})`` of Van Oosterom–Strackee spherical excesses
  ``E = 2·atan2(a·(b×c), 1 + a·b + b·c + c·a)``, built from the ``sin`` / ``cos`` /
  ``atan2`` scalar leaves (no new primitive).

The ring is evaluated CLOSED (``n+1`` rows, first vertex repeated) so the wrap
edge ``v→1`` is the ordinary 1-based ``v+1`` lookup, and the contraction ranges
over the ``n`` distinct vertices. Ranging the full ring is exact for the spherical
fan: the two degenerate endpoints carry zero excess, collapsing the sum to the
``Σ_{i=2}^{n-1}`` fan the oracle computes — the same trick the shoelace uses.

This is the Python sibling of ``pkg/earthsci-ast-rs/src/area_faq.rs``
(``polygon_area_faq``) and ``EarthSciAST.jl``'s ``area_faq.jl``.
"""

from __future__ import annotations

import math

import numpy as np

from .esm_types import ExprNode
from .numpy_interpreter import EvalContext, eval_expr

__all__ = ["polygon_area_via_faq"]


def _shoelace_area_faq() -> ExprNode:
    """The planar ``polygon_area`` FAQ over the derived clip ring:
    ``0.5·Σ_v (x_v·y_{v+1} − x_{v+1}·y_v)`` — an ordinary ``sum_product``
    aggregate (§8.1), the same AST baked into the planar geometry fixture."""

    def col(idx: object, c: int) -> ExprNode:
        return ExprNode(op="index", args=["overlap_clip", idx, c])

    v_next = ExprNode(op="+", args=["v", 1])
    cross = ExprNode(
        op="-",
        args=[
            ExprNode(op="*", args=[col("v", 1), col(v_next, 2)]),
            ExprNode(op="*", args=[col(v_next, 1), col("v", 2)]),
        ],
    )
    return ExprNode(
        op="aggregate",
        semiring="sum_product",
        output_idx=[],
        args=["overlap_clip"],
        ranges={"v": {"from": "clip_ring"}},
        expr=ExprNode(op="*", args=[0.5, cross]),
    )


# Degrees→radians factor — the same constant ``math.radians`` applies, so the
# FAQ's lon-lat→sphere map matches the imperative oracle to the last ULP.
_DEG2RAD = math.pi / 180.0


def _clip_unit_vec(idx: object) -> tuple[ExprNode, ExprNode, ExprNode]:
    """AST for the unit 3-vector of clip-ring vertex ``idx`` (lon = col 1, lat =
    col 2, degrees): ``(cosφ·cosλ, cosφ·sinλ, sinφ)`` — the same lon-lat→sphere map
    the oracle :func:`geometry._lonlat_to_unit` uses, built from the ``sin`` / ``cos``
    scalar leaves so the per-triangle excess is a closed-form AST (no new op)."""

    def col(c: int) -> ExprNode:
        return ExprNode(op="index", args=["overlap_clip", idx, c])

    lon = ExprNode(op="*", args=[col(1), _DEG2RAD])
    lat = ExprNode(op="*", args=[col(2), _DEG2RAD])
    cos_lat = ExprNode(op="cos", args=[lat])
    return (
        ExprNode(op="*", args=[cos_lat, ExprNode(op="cos", args=[lon])]),
        ExprNode(op="*", args=[cos_lat, ExprNode(op="sin", args=[lon])]),
        ExprNode(op="sin", args=[lat]),
    )


def _dot3(u: tuple[ExprNode, ...], v: tuple[ExprNode, ...]) -> ExprNode:
    """AST for the 3-vector dot product ``u·v``."""
    return ExprNode(
        op="+",
        args=[
            ExprNode(op="*", args=[u[0], v[0]]),
            ExprNode(op="*", args=[u[1], v[1]]),
            ExprNode(op="*", args=[u[2], v[2]]),
        ],
    )


def _cross3(
    u: tuple[ExprNode, ...], v: tuple[ExprNode, ...]
) -> tuple[ExprNode, ExprNode, ExprNode]:
    """AST for the 3-vector cross product ``u×v``."""
    return (
        ExprNode(
            op="-", args=[ExprNode(op="*", args=[u[1], v[2]]), ExprNode(op="*", args=[u[2], v[1]])]
        ),
        ExprNode(
            op="-", args=[ExprNode(op="*", args=[u[2], v[0]]), ExprNode(op="*", args=[u[0], v[2]])]
        ),
        ExprNode(
            op="-", args=[ExprNode(op="*", args=[u[0], v[1]]), ExprNode(op="*", args=[u[1], v[0]])]
        ),
    )


def _spherical_excess(
    a: tuple[ExprNode, ...], b: tuple[ExprNode, ...], c: tuple[ExprNode, ...]
) -> ExprNode:
    """AST for the Van Oosterom–Strackee signed solid angle of triangle ``a,b,c``:
    ``2·atan2(a·(b×c), 1 + a·b + b·c + c·a)`` (the per-triangle term of the
    spherical-excess fan). Exact for great-circle edges, matching the spherical
    clip's geodesic-edge model (§5.8.4)."""
    triple = _dot3(a, _cross3(b, c))
    denom = ExprNode(op="+", args=[1.0, _dot3(a, b), _dot3(b, c), _dot3(c, a)])
    return ExprNode(op="*", args=[2.0, ExprNode(op="atan2", args=[triple, denom])])


def _spherical_area_faq() -> ExprNode:
    """The spherical ``polygon_area`` FAQ over the derived clip ring: the
    great-circle fan triangulation ``Σ_v E(v_1, v_v, v_{v+1})`` of Van
    Oosterom–Strackee spherical excesses — an ordinary ``sum_product`` aggregate
    (§8.1), the spherical sibling of :func:`_shoelace_area_faq`.

    Ranging the *full* closed clip ring is exact: the two degenerate fan endpoints
    contribute zero excess — ``v=1`` gives ``E(v_1, v_1, v_2)`` and ``v=n`` gives
    ``E(v_1, v_n, v_{n+1}=v_1)``, both with a collinear-with-apex vertex — so the
    sum collapses to the ``Σ_{i=2}^{n-1}`` fan the oracle
    (:func:`geometry._spherical_signed_area`) computes. Unit sphere (radius 1),
    matching the ``polygon_area`` default."""
    v_next = ExprNode(op="+", args=["v", 1])
    return ExprNode(
        op="aggregate",
        semiring="sum_product",
        output_idx=[],
        args=["overlap_clip"],
        ranges={"v": {"from": "clip_ring"}},
        expr=_spherical_excess(
            _clip_unit_vec(1),
            _clip_unit_vec("v"),
            _clip_unit_vec(v_next),
        ),
    )


def polygon_area_via_faq(ring: np.ndarray, manifold: str) -> float:
    """Evaluate the (unsigned) ``polygon_area`` FAQ for a vertex ``ring`` through
    the generic aggregate machinery — the same :func:`.eval_expr` path the array
    simulator uses. ``ring`` is the (open or closed) ``[n, 2]`` lon/lat vertex
    ring; it is closed internally so the wrap edge ``v→1`` is the ordinary ``v+1``
    lookup. Returns ``0.0`` for a degenerate (``< 3`` distinct vertex) ring.

    Planar uses the Gauss–Green shoelace FAQ; spherical / geodesic uses the Van
    Oosterom–Strackee spherical-excess fan FAQ.
    """
    r = np.asarray(ring, dtype=float)
    if r.shape[0] >= 1 and not np.allclose(r[0], r[-1]):
        closed = np.vstack([r, r[:1]])
    else:
        closed = r
    if closed.shape[0] - 1 < 3:  # n distinct vertices = rows − 1
        return 0.0
    ctx = EvalContext(
        state_layout={},
        state_shapes={},
        param_values={},
        observed_values={},
        y=np.zeros(0),
        t=0.0,
        index_sets={"clip_ring": {"kind": "derived", "from_faq": "overlap_clip"}},
    )
    ctx.derived_rings["overlap_clip"] = closed
    faq = _shoelace_area_faq() if manifold == "planar" else _spherical_area_faq()
    return abs(float(eval_expr(faq, ctx)))
