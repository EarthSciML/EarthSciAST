#!/usr/bin/env python3
"""Generate tests/conformance/geometry_templates/pairs.json: the polygon pairs every
binding runs through the `lib/geometry.esm` overlap templates.

Usage:
  scripts/gen-geometry-template-pairs.py          # write pairs.json
  scripts/gen-geometry-template-pairs.py --check  # fail if pairs.json is stale

The pairs come from every `overlap_area_planar` / `overlap_area_spherical` call
of a document under tests/ whose polygon operands are written in the document
(`const` equations or array `default`s; a spherical call's unit-vector stacks
are traced back to the lon-lat stacks their `lonlat_to_unit` equations read),
and the canonical inputs of tests/conformance/geometry/manifest.json. Each
group is one (document, ring stack, ring stack, manifold) the document clips. A group keeps
every pair whose closed bounding boxes meet (planar) or every pair (spherical),
plus up to two disjoint pairs, at most MAX_PAIRS in all.

Each pair carries a `reference` area computed in exact (planar, rational
Sutherland-Hodgman on the vertices as written) or 40-digit (spherical: the
gnomonic projection maps great-circle edges to straight lines, so the clip is
planar and exact, and the area is the Van Oosterom-Strackee fan of the
back-projected overlap) arithmetic, rounded to binary64. It is an oracle for
the template, independent of it. `same_grid` marks a pair
of cells from one grid (identical rings, or two cells of the same stack): the
planar template must give the reference exactly there. A second copy of every
group, `<id>:padded`, appends a closing duplicate and a repeated last vertex to
every ring; the template must give the unpadded group's bits on it.
"""

from __future__ import annotations

import glob
import json
import os
import sys
from fractions import Fraction

import mpmath

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
OUT = os.path.join(REPO, "tests", "conformance", "geometry_templates", "pairs.json")
MAX_PAIRS = 16
MAX_DISJOINT = 2
TEMPLATES = {"overlap_area_planar": "planar", "overlap_area_spherical": "spherical"}


# --------------------------------------------------------------------------- scanning


def _walk(node, out):
    if isinstance(node, dict):
        if node.get("op") == "apply_expression_template" and node.get("name") in TEMPLATES:
            out.append(node)
        for v in node.values():
            _walk(v, out)
    elif isinstance(node, list):
        for v in node:
            _walk(v, out)


def _derived_stacks(model):
    """Ring-stack variable -> the variable it is built from, for the two stack
    equations a document writes around the templates: a `lonlat_to_unit` faq (a
    unit-vector stack of a lon-lat stack) and a one-cell stack `index(ring, v, d)`
    of a bare [verts, 2] ring (the codemod's form of a whole-ring operand)."""
    out = {}
    for eq in model.get("equations") or []:
        lhs, rhs = eq.get("lhs"), eq.get("rhs")
        if not (isinstance(lhs, str) and isinstance(rhs, dict) and rhs.get("op") == "faq"):
            continue
        body = rhs.get("expr")
        if not isinstance(body, dict):
            continue
        if body.get("op") == "apply_expression_template" and body.get("name") == "lonlat_to_unit":
            out[lhs] = ("unit", body["bindings"]["ring"])
        elif (
            body.get("op") == "index"
            and len(body["args"]) == 3
            and len(rhs.get("output_idx") or []) == 3
            and body["args"][1:] == rhs["output_idx"][1:]
        ):
            out[lhs] = ("one_cell", body["args"][0])
    return out


def _leaf_form(call, derived):
    """The template call as (manifold, operand a, operand b), each operand an
    `index(stack, cell)` of the lon-lat stack or a bare ring name."""
    b = call["bindings"]

    def operand(ring, cell):
        kind, src = derived.get(ring, (None, None))
        if kind == "unit":
            ring = src
            kind, src = derived.get(ring, (None, None))
        if kind == "one_cell":
            return src
        return {"op": "index", "args": [ring, cell]}

    return TEMPLATES[call["name"]], [operand(b["ring_a"], b["cell_a"]), operand(b["ring_b"], b["cell_b"])]


def _array_values(model):
    """Variable name -> array value, from `lhs: name, rhs: const` equations and array
    `default`s."""
    vals = {}
    for name, var in (model.get("variables") or {}).items():
        if isinstance(var, dict) and isinstance(var.get("default"), list):
            vals[name] = var["default"]
    for eq in model.get("equations") or []:
        lhs, rhs = eq.get("lhs"), eq.get("rhs")
        if isinstance(lhs, str) and isinstance(rhs, dict) and rhs.get("op") == "const":
            vals[lhs] = rhs["value"]
    return vals


def _operand(arg, vals):
    """('stack', name, [cells][verts][2]) for `index(P, i)`, ('ring', name, [[verts][2]])
    for a whole-ring reference, or None when the document does not carry the data."""
    if isinstance(arg, dict) and arg.get("op") == "index" and len(arg["args"]) == 2:
        name = arg["args"][0]
        if isinstance(name, str) and name in vals:
            return ("stack", name, vals[name])
    if isinstance(arg, str) and arg in vals:
        return ("ring", arg, [vals[arg]])
    return None


def scan_documents():
    groups = []
    for path in sorted(glob.glob(os.path.join(REPO, "tests", "**", "*.esm"), recursive=True)):
        rel = os.path.relpath(path, REPO)
        if rel.startswith(os.path.join("tests", "invalid")):
            continue
        # The relational rewrites copy their source documents' polygons, which
        # this scan already reaches at the source.
        if rel.startswith(os.path.join("tests", "conformance", "relational_templates", "rewrites")):
            continue
        try:
            doc = json.load(open(path))
        except (json.JSONDecodeError, UnicodeDecodeError):
            continue
        for model in (doc.get("models") or {}).values():
            nodes = []
            _walk(model, nodes)
            if not nodes:
                continue
            vals = _array_values(model)
            derived = _derived_stacks(model)
            seen = set()
            for node in nodes:
                manifold, args = _leaf_form(node, derived)
                a = _operand(args[0], vals)
                b = _operand(args[1], vals)
                if a is None or b is None:
                    continue
                key = (a[1], b[1], manifold)
                if key in seen:
                    continue
                seen.add(key)
                groups.append(
                    {
                        "source": rel,
                        "operands": [a[1], b[1]],
                        "manifold": manifold,
                        "a": a[2],
                        "b": b[2],
                        "same_stack": a[1] == b[1],
                    }
                )
    return groups


def manifest_groups():
    path = os.path.join(REPO, "tests", "conformance", "geometry", "manifest.json")
    rel = os.path.relpath(path, REPO)
    out = []
    for fx in json.load(open(path))["fixtures"]:
        canon = fx["inputs"]["canonical"]
        out.append(
            {
                "source": f"{rel}#{fx['id']}",
                "operands": ["src", "tgt"],
                "manifold": fx["manifold"],
                "a": canon["src"],
                "b": canon["tgt"],
                "same_stack": False,
            }
        )
    return out


# --------------------------------------------------------------------------- references


def _dedup_exact(ring):
    out = []
    for p in ring:
        if not out or p != out[-1]:
            out.append(p)
    while len(out) > 1 and out[0] == out[-1]:
        out.pop()
    return out


def _signed2(ring):
    n = len(ring)
    return sum(
        ring[i][0] * ring[(i + 1) % n][1] - ring[(i + 1) % n][0] * ring[i][1] for i in range(n)
    )


def _clip(subject, clip):
    """Sutherland-Hodgman clip of `subject` by the convex `clip` (both lists of
    coordinate pairs in an exact or high-precision field)."""
    if _signed2(clip) < 0:
        clip = clip[::-1]
    out = list(subject)
    n = len(clip)
    for i in range(n):
        if not out:
            break
        a, b = clip[i], clip[(i + 1) % n]

        def side(p):
            return (b[0] - a[0]) * (p[1] - a[1]) - (b[1] - a[1]) * (p[0] - a[0])

        prev, out = out, []
        m = len(prev)
        for j in range(m):
            p, q = prev[j], prev[(j + 1) % m]
            sp, sq = side(p), side(q)
            if sp >= 0:
                out.append(p)
            if (sp >= 0) != (sq >= 0):
                t = sp / (sp - sq)
                out.append((p[0] + t * (q[0] - p[0]), p[1] + t * (q[1] - p[1])))
    return out


def planar_reference(a, b):
    ra = [(Fraction(x), Fraction(y)) for x, y in _dedup_exact([tuple(p) for p in a])]
    rb = [(Fraction(x), Fraction(y)) for x, y in _dedup_exact([tuple(p) for p in b])]
    if len(ra) < 3 or len(rb) < 3:
        return None
    ring = _clip(ra, rb)
    if len(ring) < 3:
        return 0.0
    return float(abs(_signed2(ring)) / 2)


def _unit(lon, lat):
    lo = mpmath.radians(mpmath.mpf(lon))
    la = mpmath.radians(mpmath.mpf(lat))
    return mpmath.matrix(
        [mpmath.cos(la) * mpmath.cos(lo), mpmath.cos(la) * mpmath.sin(lo), mpmath.sin(la)]
    )


def _dot(u, v):
    return u[0] * v[0] + u[1] * v[1] + u[2] * v[2]


def _cross(u, v):
    return mpmath.matrix(
        [u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0]]
    )


def spherical_reference(a, b):
    with mpmath.workdps(40):
        ua = [_unit(*p) for p in _dedup_exact([tuple(p) for p in a])]
        ub = [_unit(*p) for p in _dedup_exact([tuple(p) for p in b])]
        tiny = mpmath.mpf(10) ** -30

        def dedup(r):
            out = []
            for v in r:
                if not out or mpmath.norm(v - out[-1]) > tiny:
                    out.append(v)
            while len(out) > 1 and mpmath.norm(out[0] - out[-1]) <= tiny:
                out.pop()
            return out

        ua, ub = dedup(ua), dedup(ub)
        if len(ua) < 3 or len(ub) < 3:
            return None
        c = sum(ua + ub, mpmath.matrix([0, 0, 0]))
        c = c / mpmath.norm(c)
        if min(_dot(v, c) for v in ua + ub) <= mpmath.mpf("0.01"):
            return None  # not within an open hemisphere around the centre
        seed = mpmath.matrix([1, 0, 0]) if abs(c[0]) < 0.9 else mpmath.matrix([0, 1, 0])
        e1 = _cross(c, seed)
        e1 = e1 / mpmath.norm(e1)
        e2 = _cross(c, e1)

        def proj(v):
            w = v / _dot(v, c)
            return (_dot(w, e1), _dot(w, e2))

        ring = _clip([proj(v) for v in ua], [proj(v) for v in ub])
        if len(ring) < 3:
            return 0.0
        verts = []
        for x, y in ring:
            v = c + x * e1 + y * e2
            verts.append(v / mpmath.norm(v))
        o = verts[0]
        total = mpmath.mpf(0)
        for i in range(1, len(verts) - 1):
            p, q = verts[i], verts[i + 1]
            total += 2 * mpmath.atan2(
                _dot(o, _cross(p, q)), 1 + _dot(o, p) + _dot(p, q) + _dot(q, o)
            )
        return float(abs(total))


# --------------------------------------------------------------------------- pairs


def _bbox(ring):
    xs = [p[0] for p in ring]
    ys = [p[1] for p in ring]
    return min(xs), max(xs), min(ys), max(ys)


def _meet(p, q):
    return p[0] <= q[1] and q[0] <= p[1] and p[2] <= q[3] and q[2] <= p[3]


def _nverts(stack):
    n = {len(r) for r in stack}
    assert len(n) == 1, "ragged ring stack"
    return n.pop()


def select_pairs(g):
    a, b = g["a"], g["b"]
    near, far = [], []
    for i, ra in enumerate(a, start=1):
        for j, rb in enumerate(b, start=1):
            if g["manifold"] != "planar" or _meet(_bbox(ra), _bbox(rb)):
                near.append((i, j))
            elif len(far) < MAX_DISJOINT:
                far.append((i, j))
    return (near + far)[:MAX_PAIRS]


def build_group(g, gid):
    """The group's pairs, with each stack cut down to the cells they use (`cells_a` /
    `cells_b` give each kept cell's 1-based index in the document's stack)."""
    chosen = select_pairs(g)
    cells_a = sorted({i for i, _ in chosen})
    cells_b = sorted({j for _, j in chosen})
    pairs = []
    for i, j in chosen:
        ra, rb = g["a"][i - 1], g["b"][j - 1]
        ref = planar_reference(ra, rb) if g["manifold"] == "planar" else spherical_reference(ra, rb)
        pairs.append(
            {
                "i": cells_a.index(i) + 1,
                "j": cells_b.index(j) + 1,
                "reference": ref,
                "same_grid": bool(g["same_stack"] or ra == rb),
            }
        )
    return {
        "id": gid,
        "source": g["source"],
        "operands": g["operands"],
        "manifold": g["manifold"],
        "cells_a": cells_a,
        "cells_b": cells_b,
        "nv_a": _nverts(g["a"]),
        "nv_b": _nverts(g["b"]),
        "ring_a": [g["a"][i - 1] for i in cells_a],
        "ring_b": [g["b"][j - 1] for j in cells_b],
        "pairs": pairs,
    }


def padded(group):
    """ring_a gets a closing duplicate twice; ring_b a repeated last vertex, then a
    closing duplicate."""
    out = dict(group)
    out["id"] = group["id"] + ":padded"
    out["padding_of"] = group["id"]
    out["ring_a"] = [r + [r[0], r[0]] for r in group["ring_a"]]
    out["ring_b"] = [r + [r[-1], r[0]] for r in group["ring_b"]]
    out["nv_a"] = group["nv_a"] + 2
    out["nv_b"] = group["nv_b"] + 2
    return out


def build():
    raw = scan_documents() + manifest_groups()
    groups = []
    for g in raw:
        stem = (
            g["source"].split("#")[-1]
            if "#" in g["source"]
            else os.path.splitext(os.path.basename(g["source"]))[0]
        )
        gid = f"{stem}:{g['operands'][0]}:{g['operands'][1]}:{g['manifold']}"
        if g["source"].startswith("tests/conformance/geometry/manifest.json"):
            gid = f"geometry_manifest:{g['source'].split('#')[1]}:{g['manifold']}"
        groups.append(build_group(g, gid))
    groups += [padded(g) for g in groups]
    return {
        "description": (
            "Polygon pairs for the lib/geometry.esm agreement tests (generated by "
            "scripts/gen-geometry-template-pairs.py; do not edit). Each group is one "
            "(document, ring stack, ring stack, manifold) a document clips: ring_a / ring_b "
            "are [cells, nv, 2] lon-lat stacks (the document's cells cells_a / cells_b) and "
            "each pair names cells (i, j) of them, 1-based, "
            "with an exact (planar) or 40-digit (spherical, steradians) reference area. A "
            "`padding_of` group is its sibling with every ring padded by two repeated "
            "vertices; the template must give the sibling's bits there. Tolerance: "
            "CONFORMANCE_SPEC 5.8.2, |A - A_ref| <= atol + rtol * A_ref with rtol 1e-9 "
            "and atol 1e-15 * R^2, R = max(1, largest |coordinate|) planar, 1 spherical."
        ),
        "tolerance": {"rtol": 1e-9, "atol_factor": 1e-15},
        "groups": groups,
    }


def main():
    text = json.dumps(build(), indent=1) + "\n"
    if "--check" in sys.argv[1:]:
        current = open(OUT).read() if os.path.exists(OUT) else ""
        if current != text:
            print(
                f"STALE: {os.path.relpath(OUT, REPO)}; run scripts/gen-geometry-template-pairs.py"
            )
            sys.exit(1)
        print(f"OK: {os.path.relpath(OUT, REPO)}")
        return
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w") as fh:
        fh.write(text)
    print(f"wrote {os.path.relpath(OUT, REPO)}")


if __name__ == "__main__":
    main()
