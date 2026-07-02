"""Conservative-regridding geometry kernel — the M4 ``intersect_polygon`` leaf.

RFC ``semiring-faq-unified-ir`` §8.1 / Appendix B; ``CONFORMANCE_SPEC.md`` §5.8.

The conservative-regridding overlap-area factor ``A_ij = area(cell_i ∩ cell_j)``
splits at the same boundary that makes ``acos`` a leaf but ``Σ coeff·acos(…)`` a
FAQ:

- ``intersect_polygon`` — the **required kernel leaf**. It clips two lon-lat
  polygon rings and returns the overlap vertex ring of *data-dependent* length.
  Polygon clipping (Sutherland–Hodgman / great-circle overlay) is iterative,
  control-flow-heavy, and robustness-critical, so it genuinely cannot be written
  as a semiring aggregate — the IR orchestrates it, the binding supplies the
  implementation (the same status as ``acos``/``sqrt``). It carries a
  ``manifold`` flag and its cross-binding conformance is *tolerance-based*, not
  bit-for-bit (§5.8.2 / B.5).
- ``polygon_area`` — **NOT a new op.** The area of a vertex ring is an ordinary
  ``sum_product`` FAQ over the ring index set (planar shoelace / Gauss–Green, or
  the spherical-excess sum), evaluated by
  :func:`earthsci_toolkit.numpy_interpreter._eval_arrayop`. The pure helpers here
  (:func:`polygon_area`) provide the *reference* area used to cross-check that FAQ
  and to back the spherical manifold; they are the same formula the FAQ body
  encodes, not a parallel implementation of the op.

Manifolds (``CONFORMANCE_SPEC.md`` §5.8.4 — bindings compare only same-manifold):

``planar``
    Flat lon-lat plane. Sutherland–Hodgman convex clip + planar shoelace area.
    Dependency-free (numpy only); the portable path exercised by the conformance
    fixtures. A flat plane is wrong at the poles/antimeridian (RFC §B.4) — that is
    the modelling error the spherical manifolds avoid, not a bug in this path.

``spherical`` / ``geodesic``
    True S2 spherical clipping via `spherely` (vectorized S2 / s2geography). The
    clip is delegated to spherely; the area uses the closed-form spherical-excess
    sum so it needs no extra dependency. `spherely` is pre-1.0, so it is **pinned**
    (``pyproject.toml`` ``[project.optional-dependencies] geometry``) and imported
    lazily — the planar path and the rest of the toolkit never require it.
"""

from __future__ import annotations

import math
from typing import List, Optional, Tuple

import numpy as np

# Manifolds the geometry kernel understands (matches the closed schema enum on
# the ``intersect_polygon`` op — esm-schema.json; additive in ess-my4.4.2).
MANIFOLDS: Tuple[str, ...] = ("planar", "spherical", "geodesic")

# B.5 / §5.8.2 sliver floor: ``atol ≈ 1e-15·R²``. Near-tangent overlaps are the
# regime where two clippers legitimately disagree on whether a tiny intersection
# even exists, so sub-``atol`` areas are treated as equal-to-zero.
SLIVER_ATOL_FACTOR: float = 1e-15


class GeometryError(Exception):
    """A polygon-clip / area evaluation failed (bad operand, degenerate input)."""


class GeometryBackendUnavailable(GeometryError):
    """A spherical/geodesic clip was requested but `spherely` is not installed.

    The spherical manifolds delegate the clip to `spherely` (S2 via s2geography),
    which is pre-1.0 and an *optional* pinned dependency
    (``pip install 'earthsci_toolkit[geometry]'``). The planar manifold needs no
    backend. Conformance suites skip the spherical path when this is raised rather
    than failing — same posture as the ``deferred_in`` tag in the byte-golden
    conformance manifests.
    """


# --------------------------------------------------------------------------- #
# Operand coercion
# --------------------------------------------------------------------------- #

def _as_ring(poly: object, *, who: str) -> np.ndarray:
    """Coerce a clip operand to an ``[n, 2]`` float array of *distinct* lon-lat
    vertices.

    Accepts a 2-D ``[n, 2]`` array (the ``[verts, coord]`` polygon shape).
    Consecutive duplicate vertices AND a closing duplicate final vertex
    (``ring[-1] == ring[0]``) are removed so the returned ring is the ``n``
    distinct vertices with closure left implicit (esm-spec §8.6.1). A padded
    ring — e.g. an MPAS pentagon stored in a hexagon-shaped ``[cells, NVERT, 2]``
    array with its final vertex repeated to fill the rectangular slot — MUST be
    accepted and evaluated as the deduplicated ring. Dedup happens HERE, before
    any backend clip, because backend tolerance differs (the planar
    Sutherland–Hodgman clip treats a zero-length edge as a no-op, but S2 — the
    spherical backend via ``spherely`` — rejects it as a degenerate edge), and
    the op's cross-binding contract cannot depend on that. A ring with fewer than
    3 distinct vertices is degenerate and rejected.
    """
    arr = np.asarray(poly, dtype=float)
    if arr.ndim != 2 or arr.shape[1] != 2:
        raise GeometryError(
            f"intersect_polygon {who} must be an [verts, 2] lon-lat ring, "
            f"got array of shape {arr.shape}"
        )
    # _dedup_consecutive drops consecutive duplicates AND the wrap pair (a
    # closing first==last duplicate), so padding and explicit closure both
    # collapse to the n distinct vertices with implicit closure.
    arr = _dedup_consecutive(arr)
    if arr.shape[0] < 3:
        raise GeometryError(
            f"intersect_polygon {who} needs ≥3 distinct vertices, got {arr.shape[0]}"
        )
    return arr


# --------------------------------------------------------------------------- #
# Planar clip — Sutherland–Hodgman (convex clip polygon)
# --------------------------------------------------------------------------- #

def _cross(o: np.ndarray, a: np.ndarray, b: np.ndarray) -> float:
    """Signed area of the ``o→a``, ``o→b`` parallelogram (z of the cross product).

    Positive ⇒ ``b`` is left of the directed line ``o→a``'s companion; used as the
    inside test against a CCW clip edge.
    """
    return float((a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0]))


def _segment_intersection(
    a: np.ndarray, b: np.ndarray, p: np.ndarray, q: np.ndarray
) -> np.ndarray:
    """Intersection of the infinite clip line ``a→b`` with subject segment ``p→q``."""
    r = b - a
    s = q - p
    denom = r[0] * s[1] - r[1] * s[0]
    if abs(denom) < 1e-300:
        # Parallel / degenerate: fall back to the segment endpoint inside the
        # half-plane (the caller only reaches here when p,q straddle the line).
        return q
    t = ((p[0] - a[0]) * s[1] - (p[1] - a[1]) * s[0]) / denom
    return a + t * r


def _planar_clip(subject: np.ndarray, clip: np.ndarray) -> np.ndarray:
    """Sutherland–Hodgman clip of ``subject`` against the **convex** ``clip`` ring.

    Both rings are ``[n, 2]`` distinct CCW vertices. Returns the overlap ring as
    distinct CCW vertices, or an empty ``(0, 2)`` array when the polygons do not
    overlap. Conservative-regridding cells are convex quads, so the convex-clipper
    restriction is satisfied; a non-convex clip operand would silently give the
    convex-edge intersection and is out of contract.
    """
    # Orient the clip ring CCW so "inside == left of each directed edge" holds.
    if _signed_area(clip) < 0:
        clip = clip[::-1]
    output: List[np.ndarray] = [row for row in subject]
    n_clip = clip.shape[0]
    for i in range(n_clip):
        if not output:
            break
        a = clip[i]
        b = clip[(i + 1) % n_clip]
        prev = output
        output = []
        m = len(prev)
        for j in range(m):
            p = prev[j]
            q = prev[(j + 1) % m]
            p_in = _cross(a, b, p) >= 0.0
            q_in = _cross(a, b, q) >= 0.0
            if p_in:
                output.append(p)
                if not q_in:
                    output.append(_segment_intersection(a, b, p, q))
            elif q_in:
                output.append(_segment_intersection(a, b, p, q))
    if not output:
        return np.zeros((0, 2), dtype=float)
    ring = np.asarray(output, dtype=float)
    return _dedup_consecutive(ring)


def _dedup_consecutive(ring: np.ndarray) -> np.ndarray:
    """Drop consecutive duplicate vertices (incl. the wrap pair) a clip can emit."""
    if ring.shape[0] <= 1:
        return ring
    keep = [0]
    for i in range(1, ring.shape[0]):
        if not np.allclose(ring[i], ring[keep[-1]]):
            keep.append(i)
    out = ring[keep]
    if out.shape[0] >= 2 and np.allclose(out[0], out[-1]):
        out = out[:-1]
    return out


# --------------------------------------------------------------------------- #
# Spherical clip — spherely (S2 / s2geography), pinned + lazy
# --------------------------------------------------------------------------- #

def _spherical_clip(subject: np.ndarray, clip: np.ndarray) -> np.ndarray:
    """Clip two lon-lat rings on the sphere via `spherely` (S2 / s2geography).

    Returns the overlap ring as ``[n, 2]`` distinct lon-lat vertices, or an empty
    ``(0, 2)`` array when the spherical intersection is empty. Raises
    :class:`GeometryBackendUnavailable` if `spherely` is not importable.
    """
    try:
        import spherely  # pinned optional dependency — see module docstring
    except ImportError as exc:  # pragma: no cover - exercised only without spherely
        raise GeometryBackendUnavailable(
            "spherical/geodesic intersect_polygon requires the pinned optional "
            "dependency `spherely` (S2 via s2geography). Install it with "
            "`pip install 'earthsci_toolkit[geometry]'`. The planar manifold "
            "needs no backend."
        ) from exc

    a = _spherely_polygon(subject)
    b = _spherely_polygon(clip)
    overlap = spherely.intersection(a, b)
    return _spherely_ring_lonlat(overlap)


def _spherely_polygon(ring: np.ndarray) -> object:
    """Build a spherely polygon from a lon-lat ring across its pre-1.0 API.

    spherely exposes polygon construction as either the ``spherely.polygon``
    function or the ``spherely.Polygon`` class depending on the release; both
    take a shell of ``(lon, lat)`` tuples in degrees. Probe both so a pin bump
    within the pre-1.0 line does not silently break the clip.
    """
    import spherely

    shell = [(float(lon), float(lat)) for lon, lat in ring]
    ctor = getattr(spherely, "polygon", None) or getattr(spherely, "Polygon", None)
    if ctor is None:  # pragma: no cover - exercised only with an off-contract spherely
        raise GeometryBackendUnavailable(
            "installed `spherely` exposes neither `polygon` nor `Polygon`; pin a "
            "release that constructs polygons from a lon-lat shell."
        )
    return ctor(shell)


def _spherely_ring_lonlat(geometry: object) -> np.ndarray:
    """Extract the exterior-ring lon-lat vertices from a spherely geography.

    Returns ``(0, 2)`` for an empty geometry. Uses the lon-lat coordinate accessor
    and drops the closing duplicate so the result matches the planar convention
    (distinct vertices, implicit closure).
    """
    import spherely

    if geometry is None or spherely.is_empty(geometry):
        return np.zeros((0, 2), dtype=float)
    # spherely exposes ring vertices via get_x / get_y (longitude / latitude in
    # degrees) over the geography's points; fall back through the documented
    # accessors. The exact accessor name has shifted across pre-1.0 releases, so
    # probe the stable ones.
    coords = _spherely_coords(geometry)
    if coords.shape[0] >= 2 and np.allclose(coords[0], coords[-1]):
        coords = coords[:-1]
    return coords


def _spherely_coords(geometry: object) -> np.ndarray:
    """Best-effort lon-lat vertex extraction across spherely's pre-1.0 accessors."""
    import spherely

    # Preferred: to_geojson / __geo_interface__ gives ordered ring coordinates.
    geo = getattr(geometry, "__geo_interface__", None)
    if geo is not None:
        return _coords_from_geojson(geo)
    if hasattr(spherely, "to_geojson"):
        import json

        return _coords_from_geojson(json.loads(spherely.to_geojson(geometry)))
    raise GeometryBackendUnavailable(
        "installed `spherely` exposes no GeoJSON / __geo_interface__ accessor to "
        "read clip-ring vertices; pin a spherely release that provides one "
        "(the s2geography C++ surface beneath is stable)."
    )


def _coords_from_geojson(geo: dict) -> np.ndarray:
    """Pull the first polygon exterior ring out of a GeoJSON-ish mapping."""
    geom = geo.get("geometry", geo)
    gtype = geom.get("type")
    coords = geom.get("coordinates")
    if gtype == "Polygon":
        ring = coords[0] if coords else []
    elif gtype == "MultiPolygon":
        ring = coords[0][0] if coords and coords[0] else []
    else:
        return np.zeros((0, 2), dtype=float)
    return np.asarray(ring, dtype=float) if ring else np.zeros((0, 2), dtype=float)


# --------------------------------------------------------------------------- #
# Public clip entry point
# --------------------------------------------------------------------------- #

def intersect_polygon(poly_a: object, poly_b: object, manifold: str) -> np.ndarray:
    """Clip two lon-lat polygon rings; return the overlap ring (RFC §8.1).

    ``poly_a`` / ``poly_b`` are ``[verts, 2]`` lon-lat coordinate arrays.
    ``manifold`` is one of :data:`MANIFOLDS` and is **required** — the geometry
    interpretation is part of the op's contract and is never inferred
    (CONFORMANCE_SPEC.md §5.8.4). Returns the overlap as ``[n, 2]`` *distinct*
    lon-lat vertices (data-dependent ``n``), or an empty ``(0, 2)`` array when the
    cells do not overlap.
    """
    if manifold is None:
        raise GeometryError(
            "intersect_polygon requires a `manifold` (planar / spherical / "
            "geodesic); it carries no default (CONFORMANCE_SPEC.md §5.8.4)."
        )
    if manifold not in MANIFOLDS:
        raise GeometryError(
            f"unknown manifold {manifold!r}; the closed set is {list(MANIFOLDS)}"
        )
    a = _as_ring(poly_a, who="poly_a")
    b = _as_ring(poly_b, who="poly_b")
    if manifold == "planar":
        return _planar_clip(a, b)
    return _spherical_clip(a, b)


def close_ring(ring: np.ndarray) -> np.ndarray:
    """Append the first vertex so edge ``n→1`` is addressable as ``ring[n+1]``.

    The area FAQ ranges over the ``n`` distinct vertices but its shoelace body
    reads ``ring[v]`` and ``ring[v+1]``; closing the ring makes the wrap edge an
    ordinary ``v+1`` lookup with no modular arithmetic in the AST.
    """
    ring = np.asarray(ring, dtype=float)
    if ring.shape[0] == 0:
        return ring
    return np.vstack([ring, ring[0]])


# --------------------------------------------------------------------------- #
# Polar-edge densification — great-circle-edge accuracy (RFC §B.4 / §5.8.4)
# --------------------------------------------------------------------------- #

def densify_parallel_edges(
    ring: object, max_segment_deg: float, *, lat_atol: float = 1e-9
) -> np.ndarray:
    """Subdivide each *parallel* edge of a lon-lat ``ring`` into short great-circle segments.

    Each parallel edge (constant latitude) wider than ``max_segment_deg`` degrees
    of longitude is split into great-circle segments at most ``max_segment_deg``
    wide, inserting the intermediate vertices **on the parallel** (linear in
    lon-lat).

    The ``spherical`` / ``geodesic`` manifolds model every polygon edge — the
    clip's and the ``polygon_area`` FAQ's — as a **great-circle geodesic** (RFC
    §B.4 / §5.8.4). A lon-lat cell edge running along a parallel is a *small
    circle*, not a great circle, so a single wide great-circle edge bows off the
    parallel and a coarse polar cell carries a real area error: ≈4% for a 30° cell
    next to the pole, ≈1% at 15°, scaling with the **square of the cell's
    longitude width**. Replacing one wide parallel edge with many short
    great-circle chords that each stay on the parallel drives that error toward
    zero — the standard mitigation (XIOS) for coarse polar lat-lon grids.

    This is an **opt-in pre-clip** step: apply it to each operand before
    :func:`intersect_polygon` (and the ``polygon_area`` FAQ) when polar accuracy
    matters. It is **off by default** — nothing in the evaluator calls it — so the
    default clip / area behaviour is unchanged. Only parallel edges are touched: a
    meridian already lies on a great circle, and a slanted edge is not a parallel,
    so both are returned whole. ``max_segment_deg`` must be positive; ``lat_atol``
    (degrees) is the tolerance for judging an edge to lie along a parallel. Returns
    the densified ring as ``[n, 2]`` *distinct* lon-lat vertices (implicit closure
    preserved).
    """
    if not max_segment_deg > 0:
        raise GeometryError(
            f"densify_parallel_edges max_segment_deg must be positive, got {max_segment_deg}"
        )
    r = _as_ring(ring, who="ring")
    n = r.shape[0]
    out: List[np.ndarray] = []
    for i in range(n):
        a = r[i]
        b = r[(i + 1) % n]
        out.append(a)
        dlon = b[0] - a[0]
        if abs(a[1] - b[1]) <= lat_atol and abs(dlon) > max_segment_deg:
            n_seg = math.ceil(abs(dlon) / max_segment_deg)
            for k in range(1, n_seg):
                t = k / n_seg
                out.append(a + t * (b - a))
    return np.asarray(out, dtype=float)


# --------------------------------------------------------------------------- #
# Reference area (the same formula the polygon_area FAQ body encodes)
# --------------------------------------------------------------------------- #

def _signed_area(ring: np.ndarray) -> float:
    """Planar shoelace signed area of an ``[n, 2]`` ring (implicit closure)."""
    n = ring.shape[0]
    if n < 3:
        return 0.0
    acc = 0.0
    for i in range(n):
        x_i, y_i = ring[i]
        x_j, y_j = ring[(i + 1) % n]
        acc += x_i * y_j - x_j * y_i
    return 0.5 * acc


def _lonlat_to_unit(lon_deg: float, lat_deg: float) -> Tuple[float, float, float]:
    """Lon-lat (degrees) → unit vector on the sphere."""
    lon = math.radians(lon_deg)
    lat = math.radians(lat_deg)
    cos_lat = math.cos(lat)
    return (cos_lat * math.cos(lon), cos_lat * math.sin(lon), math.sin(lat))


def _spherical_triangle_excess(
    a: Tuple[float, float, float],
    b: Tuple[float, float, float],
    c: Tuple[float, float, float],
) -> float:
    """Signed solid angle (spherical excess) of triangle ``a,b,c`` on the unit sphere.

    Van Oosterom–Strackee: ``E = 2·atan2(a·(b×c), 1 + a·b + b·c + c·a)``. Exact for
    great-circle edges, so it matches an S2 / `spherely` area — the same
    geodesic-edge model the spherical clip uses (CONFORMANCE_SPEC.md §5.8.4),
    unlike a flat lon-lat trapezoid sum.
    """
    cross = (
        b[1] * c[2] - b[2] * c[1],
        b[2] * c[0] - b[0] * c[2],
        b[0] * c[1] - b[1] * c[0],
    )
    triple = a[0] * cross[0] + a[1] * cross[1] + a[2] * cross[2]
    dot_ab = a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
    dot_bc = b[0] * c[0] + b[1] * c[1] + b[2] * c[2]
    dot_ca = c[0] * a[0] + c[1] * a[1] + c[2] * a[2]
    return 2.0 * math.atan2(triple, 1.0 + dot_ab + dot_bc + dot_ca)


def _spherical_signed_area(ring: np.ndarray, radius: float) -> float:
    """Spherical-excess signed area via a great-circle fan triangulation.

    ``A = R² · Σ_{i=2}^{n-1} E(v_1, v_i, v_{i+1})`` where ``E`` is the
    Van Oosterom–Strackee spherical excess of each fan triangle. This is the
    spherical-excess form RFC §8.1 names (great-circle edges, matching S2), built
    from the ``atan2``/`sqrt` scalar leaf family — the same fan a spherical
    ``polygon_area`` FAQ ranges over.
    """
    n = ring.shape[0]
    if n < 3:
        return 0.0
    verts = [_lonlat_to_unit(float(ring[i, 0]), float(ring[i, 1])) for i in range(n)]
    total = 0.0
    for i in range(1, n - 1):
        total += _spherical_triangle_excess(verts[0], verts[i], verts[i + 1])
    return radius * radius * total


def polygon_area(ring: np.ndarray, manifold: str, radius: float = 1.0) -> float:
    """Reference (unsigned) area of an overlap ring under ``manifold``.

    Planar ⇒ shoelace / Gauss–Green; spherical / geodesic ⇒ the spherical-excess
    sum (``radius`` = sphere radius / characteristic length, default the unit
    sphere). Returns ``0.0`` for a degenerate (< 3 vertex) ring — an empty clip.
    This is the imperative **cross-check oracle** for the ``sum_product``
    ``polygon_area`` FAQ: the production polygon area now routes through that FAQ
    (:func:`earthsci_toolkit.area_faq.polygon_area_via_faq`) for both manifolds,
    and this function encodes the same formula the FAQ body does.
    """
    ring = np.asarray(ring, dtype=float)
    if ring.shape[0] >= 2 and np.allclose(ring[0], ring[-1]):
        ring = ring[:-1]
    if ring.shape[0] < 3:
        return 0.0
    if manifold == "planar":
        return abs(_signed_area(ring))
    if manifold in ("spherical", "geodesic"):
        return abs(_spherical_signed_area(ring, radius))
    raise GeometryError(
        f"unknown manifold {manifold!r}; the closed set is {list(MANIFOLDS)}"
    )


# --------------------------------------------------------------------------- #
# B.5 / §5.8.2 tolerance gate
# --------------------------------------------------------------------------- #

def area_tolerance_ok(
    area_x: float,
    area_ref: float,
    rtol: float,
    radius: float = 1.0,
    atol: Optional[float] = None,
) -> bool:
    """Combined rel+abs area-agreement gate with a sliver floor (B.5 / §5.8.2).

    ``|A_x − A_ref| ≤ atol + rtol·A_ref`` with ``atol ≈ 1e-15·R²`` the sliver
    floor: sub-``atol`` areas are treated as equal-to-zero, so a "present-but-tiny"
    overlap and an "absent" one **both pass**. ``rtol`` is empirically calibrated
    per the loosest binding pair (GeometryOps-vs-S2); Python and Rust share the S2
    core and agree far tighter. Pass an explicit ``atol`` to override the floor.
    """
    if atol is None:
        atol = SLIVER_ATOL_FACTOR * radius * radius
    a_x = 0.0 if abs(area_x) <= atol else area_x
    a_ref = 0.0 if abs(area_ref) <= atol else area_ref
    return abs(a_x - a_ref) <= atol + rtol * abs(a_ref)
