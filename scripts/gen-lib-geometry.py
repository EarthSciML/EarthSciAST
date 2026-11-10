#!/usr/bin/env python3
"""Generate lib/geometry.esm, the pure-AST convex overlap-area templates
(esm-spec §8.6.1, §9.7.1).

Three public match-less templates give the overlap area of two convex polygons:

    overlap_area_planar(ring_a, cell_a, nv_a, ring_b, cell_b, nv_b)
    overlap_area_spherical(ring_a, cell_a, nv_a, ring_b, cell_b, nv_b)
    lonlat_to_unit(ring, cell, vert, comp)

Each operand is cell `cell` of a ring stack (`[cells, nv, 2]` x-y on the plane,
`[cells, nv, 3]` unit vectors on the sphere) with `nv` vertex slots, an integer
used as a `faq` `ranges` bound (esm-spec §9.6.1).

By Green's theorem the overlap is the sum over every edge of each polygon of its
boundary contribution restricted to the part inside the other polygon, which for
convex cells is one chord-parameter interval [t0, t1]: t0 a `max` and t1 a `min`
`faq` over the other polygon's closed half-planes. Each step is written once, as
a helper template (prefix `geo_`), and called by reference
(`apply_expression_template`, esm-spec §9.7.3):

    geo_next(v, n)                     the next vertex slot, cyclic
    geo_cross2 / geo_side2 / geo_l1    planar cross product, signed side, L1 norm
    geo_tol2                           the planar on-the-line tolerance
    geo_dot3 / geo_triple / geo_side3  spherical dot, o . (a x b), (a x b) . p
    geo_sign(x)                        +1 when x >= 0, else -1 (orientation)
    geo_t0 / geo_t1                    the bounds one half-plane imposes on an edge
    geo_contrib2                       a planar edge's half-shoelace contribution
    geo_vos(t, ...)                    the Van Oosterom-Strackee term of a spherical
                                       edge's prefix up to chord parameter t
    geo_contrib3                       a spherical edge's contribution
    <template>_fan_a / _fan_b          a ring's orientation fan sum (the faq keeps
                                       the public template's loop symbol)

The loop symbols (`k_<template>_<n>`) and every `faq` stay in the public bodies,
so expanding every reference gives exactly the tree a fully inlined body would.
`--check` also verifies that the expanded public bodies equal `--inline` output.

Usage:
    scripts/gen-lib-geometry.py            # write lib/geometry.esm
    scripts/gen-lib-geometry.py --check    # exit 1 if lib/geometry.esm is stale
    scripts/gen-lib-geometry.py --inline OUT.esm   # the fully inlined library
Then `scripts/sync-lib.sh` mirrors it into docs/static/lib/.
"""

import copy
import json
import sys
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / "lib" / "geometry.esm"

DEG2RAD = 0.017453292519943295  # binary64 pi/180, the constant math.radians / deg2rad / S2 use
TOL_PLANAR = 1e-12  # relative: |g| <= TOL_PLANAR * L1(edge) * (L1(p0) + L1(p1) + L1(edge start))
TOL_SPHERICAL = 1e-14  # absolute, in unit-vector triple-product units

INLINE = False  # set by --inline: helpers are expanded in place instead of referenced


def op(name, *args, **fields):
    node = {"op": name, "args": list(args)}
    node.update(fields)
    return node


def add(*a):
    return op("+", *a)


def sub(a, b):
    return op("-", a, b)


def mul(*a):
    return op("*", *a)


def div(a, b):
    return op("/", a, b)


def neg(a):
    return op("-", a)


def ifelse(c, a, b):
    return op("ifelse", c, a, b)


def absn(a):
    return op("abs", a)


def faq(sym, n, body, reduce, arrays):
    return {
        "op": "faq",
        "args": list(arrays),
        "output_idx": [],
        "reduce": reduce,
        "ranges": {sym: [1, n]},
        "expr": body,
    }


# --------------------------------------------------------------------------- helpers

HELPERS = {}  # name -> (params, body builder, description)


def helper(name, params, description):
    """Register `fn(*params)` as the body of match-less template `name`; calling the
    returned function gives an `apply_expression_template` reference (or, under
    --inline, the body with the arguments substituted)."""

    def wrap(fn):
        HELPERS[name] = (params, fn, description)

        def call(*args):
            assert len(args) == len(params), name
            if INLINE:
                return fn(*args)
            return {
                "op": "apply_expression_template",
                "args": [],
                "name": name,
                "bindings": dict(zip(params, args)),
            }

        return call

    return wrap


@helper(
    "geo_next",
    ["gn_v", "gn_n"],
    "The vertex slot after `gn_v` in a ring of `gn_n` slots: gn_v + 1, wrapping to 1.",
)
def geo_next(v, n):
    return ifelse(op("<", v, n), add(v, 1), 1)


@helper(
    "geo_cross2",
    ["gc_ux", "gc_uy", "gc_wx", "gc_wy"],
    "The planar cross product u x w = ux wy - uy wx.",
)
def geo_cross2(ux, uy, wx, wy):
    return sub(mul(ux, wy), mul(uy, wx))


@helper(
    "geo_side2",
    ["gs_px", "gs_py", "gs_ax", "gs_ay", "gs_bx", "gs_by"],
    "(b - a) x (p - a): positive when p is left of the directed line a -> b.",
)
def geo_side2(px, py, ax, ay, bx, by):
    return geo_cross2(sub(bx, ax), sub(by, ay), sub(px, ax), sub(py, ay))


@helper("geo_l1", ["gl_x", "gl_y"], "The L1 norm |x| + |y|.")
def geo_l1(x, y):
    return add(absn(x), absn(y))


@helper(
    "geo_tol2",
    ["gt_px", "gt_py", "gt_qx", "gt_qy", "gt_ax", "gt_ay", "gt_bx", "gt_by"],
    f"The planar on-the-line tolerance of edge p -> q against the half-plane of edge a -> b: "
    f"L1(b - a) (L1(p) + L1(q) + L1(a)) {TOL_PLANAR:g}.",
)
def geo_tol2(px, py, qx, qy, ax, ay, bx, by):
    return mul(
        geo_l1(sub(bx, ax), sub(by, ay)),
        add(geo_l1(px, py), geo_l1(qx, qy), geo_l1(ax, ay)),
        TOL_PLANAR,
    )


@helper(
    "geo_dot3",
    ["gd_ux", "gd_uy", "gd_uz", "gd_wx", "gd_wy", "gd_wz"],
    "The dot product u . w.",
)
def geo_dot3(ux, uy, uz, wx, wy, wz):
    return add(mul(ux, wx), mul(uy, wy), mul(uz, wz))


def _cross3(ax, ay, az, bx, by, bz):
    return (
        sub(mul(ay, bz), mul(az, by)),
        sub(mul(az, bx), mul(ax, bz)),
        sub(mul(ax, by), mul(ay, bx)),
    )


@helper(
    "geo_triple",
    ["gr_ox", "gr_oy", "gr_oz", "gr_ax", "gr_ay", "gr_az", "gr_bx", "gr_by", "gr_bz"],
    "The triple product o . (a x b).",
)
def geo_triple(ox, oy, oz, ax, ay, az, bx, by, bz):
    return geo_dot3(ox, oy, oz, *_cross3(ax, ay, az, bx, by, bz))


@helper(
    "geo_side3",
    ["gh_px", "gh_py", "gh_pz", "gh_ax", "gh_ay", "gh_az", "gh_bx", "gh_by", "gh_bz"],
    "(a x b) . p: positive when p is left of the great circle a -> b.",
)
def geo_side3(px, py, pz, ax, ay, az, bx, by, bz):
    return geo_dot3(*_cross3(ax, ay, az, bx, by, bz), px, py, pz)


@helper("geo_sign", ["gg_x"], "The orientation sign of a fan sum: 1 when gg_x >= 0, else -1.")
def geo_sign(x):
    return ifelse(op(">=", x, 0), 1, -1)


def _bounds_parts(g0, g1, s, tol):
    collinear = op("and", op("<=", absn(g0), tol), op("<=", absn(g1), tol))
    den = ifelse(op("==", g0, g1), 1, sub(g0, g1))
    root = div(g0, den)
    out0 = op("<", mul(s, g0), neg(tol))
    out1 = op("<", mul(s, g1), neg(tol))
    return collinear, root, out0, out1


@helper(
    "geo_t0",
    ["gb_g0", "gb_g1", "gb_s", "gb_tol", "gb_cl"],
    "The lower chord-parameter bound one closed half-plane imposes on an edge whose endpoints "
    "lie at signed distances s g0, s g1 (>= 0 inside; s is the half-plane polygon's orientation, "
    "which cancels from the root g0 / (g0 - g1)). A distance within `tol` of zero is on the line; "
    "both endpoints on the line make a collinear edge, whose bound is `cl` (0: no constraint, "
    "1: excluded). An endpoint on the line enters at exactly that endpoint.",
)
def geo_t0(g0, g1, s, tol, cl):
    collinear, root, out0, out1 = _bounds_parts(g0, g1, s, tol)
    enter = ifelse(op("<=", absn(g1), tol), 1, root)
    return ifelse(collinear, cl, ifelse(out0, ifelse(out1, 1, enter), 0))


@helper(
    "geo_t1",
    ["gb_g0", "gb_g1", "gb_s", "gb_tol"],
    "The upper chord-parameter bound one closed half-plane imposes on an edge (see geo_t0); a "
    "collinear edge is not bounded above, and an endpoint on the line leaves at exactly that "
    "endpoint.",
)
def geo_t1(g0, g1, s, tol):
    collinear, root, out0, out1 = _bounds_parts(g0, g1, s, tol)
    leave = ifelse(op("<=", absn(g0), tol), 0, root)
    return ifelse(collinear, 1, ifelse(out0, 1, ifelse(out1, leave, 1)))


@helper(
    "geo_contrib2",
    ["gp_s", "gp_t0", "gp_t1", "gp_px", "gp_py", "gp_qx", "gp_qy", "gp_ox", "gp_oy"],
    "A planar edge p -> q's contribution over the chord interval [t0, t1], about the origin o: "
    "s max(0, t1 - t0) ((p - o) x (q - o)) / 2, s the edge's polygon's orientation.",
)
def geo_contrib2(s, t0, t1, px, py, qx, qy, ox, oy):
    # The float literal goes last: JSON3 (Julia) reads every integer in a container
    # that follows a float in the same array as a float.
    return mul(
        s,
        op("max", 0, sub(t1, t0)),
        geo_cross2(sub(px, ox), sub(py, oy), sub(qx, ox), sub(qy, oy)),
        0.5,
    )


@helper(
    "geo_vos",
    ["gv_t", "gv_tau", "gv_oa1", "gv_lin", "gv_dd"],
    "atan2 of the Van Oosterom-Strackee half-angle of the spherical triangle (o, a, x(t)), x(t) the "
    "point at chord parameter t on the edge a -> q: atan2(t tau, (1 + o.a)(|a + t d| + 1) + t "
    "(o.d + a.d)) with d = q - a, tau = o . (a x q), dd = d . d and |a + t d| = sqrt(1 - t (1 - t) dd).",
)
def geo_vos(t, tau, oa1, lin, dd):
    chord = op("sqrt", sub(1, mul(t, sub(1, t), dd)))
    den = add(mul(oa1, add(chord, 1)), mul(t, lin))
    return op("atan2", mul(t, tau), den)


@helper(
    "geo_contrib3",
    [
        "gq_s",
        "gq_t0",
        "gq_t1",
        "gq_ax",
        "gq_ay",
        "gq_az",
        "gq_qx",
        "gq_qy",
        "gq_qz",
        "gq_ox",
        "gq_oy",
        "gq_oz",
    ],
    "A spherical edge a -> q's contribution over the chord interval [t0, t1], about the vertex o: "
    "the signed area 2 s (vos(t1) - vos(t0)) of the spherical triangle the clipped edge spans with o "
    "when t1 > t0, else 0; s is the edge's polygon's orientation.",
)
def geo_contrib3(s, t0, t1, ax, ay, az, qx, qy, qz, ox, oy, oz):
    a = (ax, ay, az)
    q = (qx, qy, qz)
    o = (ox, oy, oz)
    d = tuple(sub(q[i], a[i]) for i in range(3))
    tau = geo_triple(*o, *a, *q)
    oa1 = add(1, geo_dot3(*o, *a))
    lin = add(geo_dot3(*o, *d), geo_dot3(*a, *d))
    dd = geo_dot3(*d, *d)
    return ifelse(
        op(">", t1, t0),
        mul(2, s, sub(geo_vos(t1, tau, oa1, lin, dd), geo_vos(t0, tau, oa1, lin, dd))),
        0,
    )


# --------------------------------------------------------------------------- bodies


class Ring:
    """Ring stack `arr` [cells, verts, dim], cell index `cell`, vertex-slot count `n`."""

    def __init__(self, arr, cell, n, dim):
        self.arr, self.cell, self.n, self.dim = arr, cell, n, dim

    def pt(self, v):
        return tuple(op("index", self.arr, self.cell, v, c) for c in range(1, self.dim + 1))

    def nxt(self, v):
        return geo_next(v, self.n)


def fan_helper(tname, which, sym, ofan, arrays, dim):
    """`<tname>_fan_<which>(ring, cell, n, other)`: ring `ring`'s signed orientation fan
    sum, a `faq` over the template's loop symbol `sym` (a helper per symbol, so the
    expanded tree keeps the symbol). `other` is the other ring stack, listed in the
    `faq` `args` as the public body lists both."""
    name = f"{tname}_fan_{which}"
    params = ["gf_ring", "gf_cell", "gf_n", "gf_other"]
    if name not in HELPERS:
        first = which == "a"

        def body(ring, cell, n, other):
            r = Ring(ring, cell, n, dim)
            args = [ring, other] if first else [other, ring]
            return faq(sym, n, ofan(r, sym), "+", args)

        helper(
            name,
            params,
            f"The signed orientation fan sum of ring `gf_ring` (cell `gf_cell`, `gf_n` slots): positive when it runs counter-clockwise. Loop symbol `{sym}`.",
        )(body)
    params_, fn, _ = HELPERS[name]

    def call(*a):
        if INLINE:
            return fn(*a)
        return {
            "op": "apply_expression_template",
            "args": [],
            "name": name,
            "bindings": dict(zip(params_, a)),
        }

    return call


def build(manifold, tname):
    dim = 2 if manifold == "planar" else 3
    A = Ring("ring_a", "cell_a", "nv_a", dim)
    B = Ring("ring_b", "cell_b", "nv_b", dim)
    arrays = ["ring_a", "ring_b"]
    sym = [f"k_{tname}_{i}" for i in range(1, 9)]
    origin = A.pt(1)

    if dim == 2:

        def ofan(r, v):
            o = r.pt(1)
            p, q = r.pt(v), r.pt(r.nxt(v))
            return geo_cross2(sub(p[0], o[0]), sub(p[1], o[1]), sub(q[0], o[0]), sub(q[1], o[1]))

    else:

        def ofan(r, v):
            return geo_triple(*r.pt(1), *r.pt(v), *r.pt(r.nxt(v)))

    fanA = fan_helper(tname, "a", sym[0], ofan, arrays, dim)("ring_a", "cell_a", "nv_a", "ring_b")
    fanB = fan_helper(tname, "b", sym[1], ofan, arrays, dim)("ring_b", "cell_b", "nv_b", "ring_a")
    sA, sB = geo_sign(fanA), geo_sign(fanB)

    def side(R, S, sR, sS, ks_outer, ks_lo, ks_hi, own):
        """Sum over the edges of R of the part inside S. `own` is True for ring_a: a
        same-direction shared edge is counted there and nowhere else."""
        p0, p1 = R.pt(ks_outer), R.pt(R.nxt(ks_outer))

        def halfplane(m):
            b0, b1 = S.pt(m), S.pt(S.nxt(m))
            if dim == 2:
                g0 = geo_side2(*p0, *b0, *b1)
                g1 = geo_side2(*p1, *b0, *b1)
                tol = geo_tol2(*p0, *p1, *b0, *b1)
                dotd = add(
                    mul(sub(b1[0], b0[0]), sub(p1[0], p0[0])),
                    mul(sub(b1[1], b0[1]), sub(p1[1], p0[1])),
                )
            else:
                g0 = geo_side3(*p0, *b0, *b1)
                g1 = geo_side3(*p1, *b0, *b1)
                tol = TOL_SPHERICAL
                dotd = geo_dot3(
                    *(sub(b1[i], b0[i]) for i in range(3)), *(sub(p1[i], p0[i]) for i in range(3))
                )
            same = mul(sR, sS, dotd)
            if own:
                # An opposite-direction shared edge bounds no area: drop it.
                cl = ifelse(op("<", same, 0), 1, 0)
            else:
                # A shared edge of ring_b was counted by ring_a; a zero-length edge
                # on either side constrains nothing.
                cl = ifelse(op("==", same, 0), 0, 1)
            return g0, g1, tol, cl

        g0, g1, tol, cl = halfplane(ks_lo)
        t0 = faq(ks_lo, S.n, geo_t0(g0, g1, sS, tol, cl), "max", arrays)
        g0, g1, tol, _ = halfplane(ks_hi)
        t1 = faq(ks_hi, S.n, geo_t1(g0, g1, sS, tol), "min", arrays)
        if dim == 2:
            body = geo_contrib2(sR, t0, t1, *p0, *p1, *origin)
        else:
            body = geo_contrib3(sR, t0, t1, *p0, *p1, *origin)
        return faq(ks_outer, R.n, body, "+", arrays)

    # A ring of no extent (every vertex on one line or point) overlaps nothing; its
    # zero-length or collinear edges would otherwise leave the other ring unclipped.
    return ifelse(
        op("or", op("==", fanA, 0), op("==", fanB, 0)),
        0,
        add(
            side(A, B, sA, sB, sym[2], sym[3], sym[4], True),
            side(B, A, sB, sA, sym[5], sym[6], sym[7], False),
        ),
    )


def lonlat_to_unit_body():
    lon = mul(op("index", "ring", "cell", "vert", 1), DEG2RAD)
    lat = mul(op("index", "ring", "cell", "vert", 2), DEG2RAD)
    cl = op("cos", lat)
    return ifelse(
        op("==", "comp", 1),
        mul(cl, op("cos", lon)),
        ifelse(op("==", "comp", 2), mul(cl, op("sin", lon)), op("sin", lat)),
    )


PARAMS = ["ring_a", "cell_a", "nv_a", "ring_b", "cell_b", "nv_b"]


def library():
    public = {
        "overlap_area_planar": {
            "params": PARAMS,
            "description": (
                "Overlap area of two convex polygons with straight edges in the plane: cell `cell_a` "
                "of the `[cells, nv_a, 2]` ring stack `ring_a` and cell `cell_b` of `ring_b` "
                "(vertex v = [x, y], e.g. [lon, lat]), in squared coordinate units (esm-spec §8.6.1). "
                "Either ring orientation; repeated vertices contribute exactly zero. "
                "Contributions are taken about the first vertex of `ring_a`, so translating both "
                "polygons together changes the result only by rounding. A half-plane test within "
                "`geo_tol2` of zero counts as on the line, which is what makes shared edges and "
                "vertices exact. Disjoint or edge-touching polygons give 0, and so does a ring of no "
                "extent. Non-convex input is outside the contract."
            ),
            "body": build("planar", "overlap_area_planar"),
        },
        "overlap_area_spherical": {
            "params": PARAMS,
            "description": (
                "Overlap area in steradians (unit sphere) of two convex spherical polygons with "
                "great-circle edges: cell `cell_a` of the `[cells, nv_a, 3]` unit-vector stack "
                "`ring_a` and cell `cell_b` of `ring_b` (build a stack from lon-lat degrees with "
                "`lonlat_to_unit`); multiply by R^2 for a physical area (esm-spec §8.6.1). Either ring "
                "orientation (the interior is the side of less than a hemisphere); repeated vertices "
                "contribute exactly zero. Half-space tests are linear in the chord parameter; each "
                "clipped edge contributes the signed area of the spherical triangle it spans with the "
                "first vertex of `ring_a` (Van Oosterom-Strackee, `atan2`). A half-space test within "
                f"{TOL_SPHERICAL:g} of zero counts as on the great circle. Each polygon must lie "
                "within a hemisphere; non-convex input is outside the contract."
            ),
            "body": build("spherical", "overlap_area_spherical"),
        },
        "lonlat_to_unit": {
            "params": ["ring", "cell", "vert", "comp"],
            "description": (
                "Component `comp` (1, 2, 3 = x, y, z) of the unit vector of vertex `vert` of cell "
                "`cell` of the `[cells, verts, 2]` lon-lat ring stack `ring` (degrees): "
                "(cos(lat) cos(lon), cos(lat) sin(lon), sin(lat)), with degrees converted by the "
                "binary64 constant pi/180. Applied in a `faq` over cells, vertex slots and a "
                "3-element component axis, it builds the `[cells, verts, 3]` stack "
                "`overlap_area_spherical` takes."
            ),
            "body": lonlat_to_unit_body(),
        },
    }
    templates = dict(public)
    if not INLINE:
        for name, (params, fn, description) in HELPERS.items():
            templates[name] = {"params": params, "description": description, "body": fn(*params)}
    return {
        "esm": "2.0.0",
        "metadata": {
            "name": "Geometry",
            "description": (
                "Standard-library polygon-overlap templates (esm-spec §9.7.1 template-library file). "
                "Match-less expression templates giving the pure-AST overlap area of two convex "
                "polygons (esm-spec §8.6.1). `overlap_area_planar(ring_a, cell_a, nv_a, ring_b, cell_b, nv_b)` "
                "takes two `[cells, verts, 2]` lon-lat (or x-y) ring stacks and returns the area with "
                "straight edges, in squared coordinate units. "
                "`overlap_area_spherical(ring_a, cell_a, nv_a, ring_b, cell_b, nv_b)` takes two "
                "`[cells, verts, 3]` stacks of unit vectors and returns the area with great-circle "
                "edges, in steradians; "
                "`lonlat_to_unit(ring, cell, vert, comp)` gives component `comp` of the unit vector of "
                "a lon-lat vertex in degrees, so a caller builds the unit-vector stack once per cell "
                "with a `faq`. `cell` is the cell index and `nv` the number of vertex slots (an integer "
                "used as a `faq` `ranges` bound, esm-spec §9.6.1). Rings close implicitly, may run "
                "either way round, and may carry repeated vertices (an explicit closing duplicate or "
                "rectangular-storage padding): a zero-length edge contributes exactly zero and "
                "constrains nothing. By Green's theorem the overlap area is the sum over every edge of "
                "each polygon of its shoelace (planar) or signed spherical-triangle (spherical, Van "
                "Oosterom-Strackee) contribution restricted to the part inside the other polygon; for "
                "convex polygons that part is one chord-parameter interval, a `max`/`min` `faq` over "
                "the other polygon's closed half-planes. An edge shared by both polygons is counted "
                "once, by `ring_a`, when the two run the same way, and not at all when they run "
                "opposite ways. Each step is a `geo_` helper template the public bodies call by "
                "reference (esm-spec §9.7.3); the loop symbols and every `faq` stay in the public "
                "bodies. Generated by scripts/gen-lib-geometry.py. Import with "
                "`expression_template_imports` and invoke with `apply_expression_template`; see "
                "docs/content/standard_library.md."
            ),
            "authors": ["EarthSciML"],
            "created": "2026-11-07T00:00:00Z",
            "tags": [
                "standard-library",
                "geometry",
                "conservative-regridding",
                "overlap-area",
                "expression-templates",
            ],
            "references": [
                {
                    "citation": "esm-spec.md §8.6.1 (overlap weights, rings, padding); §9.6 (expression templates); §9.7.1 (template-library files); §9.7.3 (references between templates); CONFORMANCE_SPEC.md §5.8 (geometry tolerance contract)."
                },
                {
                    "citation": "Van Oosterom, A. and Strackee, J. (1983). The solid angle of a plane triangle. IEEE Transactions on Biomedical Engineering BME-30(2), 125-126.",
                    "doi": "10.1109/TBME.1983.325207",
                },
            ],
        },
        "expression_templates": templates,
    }


# --------------------------------------------------------------------------- expansion check


def substitute(node, bindings):
    if isinstance(node, str):
        return copy.deepcopy(bindings[node]) if node in bindings else node
    if isinstance(node, list):
        return [substitute(x, bindings) for x in node]
    if isinstance(node, dict):
        return {k: (v if k == "op" else substitute(v, bindings)) for k, v in node.items()}
    return node


def expand(node, templates):
    """Expand every `apply_expression_template` reference (esm-spec §9.6.3)."""
    if isinstance(node, list):
        return [expand(x, templates) for x in node]
    if isinstance(node, dict):
        if node.get("op") == "apply_expression_template":
            t = templates[node["name"]]
            bindings = {k: expand(v, templates) for k, v in node["bindings"].items()}
            return expand(substitute(t["body"], bindings), templates)
        return {k: expand(v, templates) for k, v in node.items()}
    return node


def render(lib):
    """Indented JSON, every template body on one line."""
    lib = copy.deepcopy(lib)
    bodies = {}
    for name, tpl in lib["expression_templates"].items():
        key = f"@@BODY:{name}@@"
        bodies[key] = json.dumps(tpl["body"], ensure_ascii=False, separators=(",", ":"))
        tpl["body"] = key
    text = json.dumps(lib, indent=2, ensure_ascii=False)
    for key, body in bodies.items():
        text = text.replace(json.dumps(key), body)
    return text + "\n"


def main():
    global INLINE
    args = sys.argv[1:]
    if args[:1] == ["--inline"]:
        INLINE = True
        Path(args[1]).write_text(render(library()))
        return
    lib = library()
    INLINE = True
    inlined = library()
    INLINE = False
    templates = lib["expression_templates"]
    for name in ("overlap_area_planar", "overlap_area_spherical", "lonlat_to_unit"):
        if (
            expand(templates[name]["body"], templates)
            != inlined["expression_templates"][name]["body"]
        ):
            sys.exit(f"{name}: the expanded body differs from the inlined body")
    text = render(lib)
    if "--check" in args:
        if not OUT.exists() or OUT.read_text() != text:
            sys.exit(f"STALE: {OUT}; run scripts/gen-lib-geometry.py")
        print(f"OK: {OUT}")
        return
    OUT.write_text(text)
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
