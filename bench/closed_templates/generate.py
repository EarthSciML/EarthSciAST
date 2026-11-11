#!/usr/bin/env python3
"""Standard-library template workloads (`lib/*.esm`) for the native compilers.

* ``solar_year_tpl_H<h>``: `lib/solar.esm` over a year of hourly
  timestamps. Each solar observed becomes an array over an `hours` index set
  (t_utc[h] = T0 + 3600 (h - 1) + t, so every call moves every timestamp and
  nothing is a build constant), and a state per hour relaxes toward the zenith
  angle; the datetime fields are the `lib/calendar.esm` templates.
* ``regrid_<manifold>_tpl_N<n>``: conservative regrid of an n x n
  lat-lon grid of 1-degree cells onto a 2/3-degree grid (the
  `tests/conformance/scaling` `regrid` family's assembly: a broad phase joined
  on one integer bin column per coordinate, the `lib/geometry.esm` overlap-area
  template per candidate pair, row-sum normalisation, applied every call).
  Every target cell lies inside one broad-phase bin, so the candidate set keeps
  every overlapping pair.
* ``nearest_tpl_P<p>_G<g>``: the nearest-generator assignment of
  `tests/conformance/value_invention_geometry` at p points and g generators,
  by the `lib/relational.esm` argmin template, feeding a right-hand side
  through a gather.
* ``mesh_rank_tpl_E<e>``: edge enumeration of a triangulated n x n
  vertex-grid mesh with e unique edges (the MPAS-scale rank workload, modelled
  on `edge_enumeration_*`): a `distinct` over every face's three vertex pairs,
  keyed by `edge_key`, invents the edge set, each edge's dense id is its loop
  index, `n_edges` grows by the set's size, a state per edge id (an interval
  set of the known edge count, as `edge_enumeration_ode`'s `edge_ids`) relaxes
  toward its id and a state per face toward the sum of its edges' states, read
  through each face's edge ids computed by `rank_of_set` over the derived set.
* ``regrid_scaling_<manifold>_tpl_N<n>``: the scaling family's regrid
  documents with the `lib/geometry.esm` template for `manifold`.

Nothing here is committed: the harnesses call this script, writing into
``--out`` (default ``$CLOSED_TEMPLATES_DIR``, else ``closed_templates`` under
``$TMPDIR``).

Usage:

    python3 bench/closed_templates/generate.py                         # every family, default sizes
    python3 bench/closed_templates/generate.py --out DIR --only nearest
    python3 bench/closed_templates/generate.py --out DIR --only mesh --mesh 57 --mesh 182 --mesh 577   # ~1e4, 1e5, 1e6 edges

Template imports are `esm:std/<file>` refs to the bundled standard library;
`--lib` points them instead at another directory holding `calendar.esm`,
`geometry.esm` and `relational.esm`. Timing: `bench_julia.jl` (Julia native) and the Rust criterion group
`closed_templates` in `pkg/earthsci-ast-rs/benches/benchmarks.rs`.
"""

import argparse
import copy
import json
import math
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
ESM_VERSION = "2.0.0"
T0 = 1767225600.0  # 2026-01-01T00:00:00Z

DEFAULTS = {
    "hours": [8760],
    "n": [12],
    "nearest": [(500, 100)],
    "mesh": [8],
}

# The lib/calendar.esm datetime-field templates lib/solar.esm calls.
CALENDAR = ["year", "month", "day", "hour", "minute", "second", "day_of_year", "julian_day", "is_leap_year"]


def op(o, *args, **fields):
    d = {"op": o, "args": list(args)}
    d.update(fields)
    return d


def ix(var, *subs):
    return op("index", var, *subs)


def const(v):
    return {"op": "const", "args": [], "value": v}


def apply(name, **bindings):
    return {"op": "apply_expression_template", "args": [], "name": name, "bindings": bindings}


def faq(expr, out, ranges, **kw):
    d = {"op": "faq", "args": [], "output_idx": list(out), "ranges": ranges, "expr": expr}
    d.update(kw)
    return d


def faq_lhs(var, out, ranges):
    return faq(op("D", ix(var, *out), wrt="t"), out, ranges)


def imports(lib, out_dir, names):
    """Template imports: the bundled standard library (`esm:std/<file>`), or,
    with `--lib`, a relative path to that directory's copy."""
    if lib is None:
        return [{"ref": f"esm:std/{f}", "only": n} for f, n in names]
    return [{"ref": os.path.relpath(os.path.join(lib, f), out_dir), "only": n} for f, n in names]


def strip_units(e):
    if isinstance(e, dict):
        return {k: strip_units(v) for k, v in e.items() if k != "units"}
    if isinstance(e, list):
        return [strip_units(v) for v in e]
    return e


# ---------------------------------------------------------------------------
# Calendar: lib/solar.esm over an hours index set.
# ---------------------------------------------------------------------------


def per_hour(e, arrayed):
    if isinstance(e, str):
        return ix(e, "h") if e in arrayed else e
    if isinstance(e, list):
        return [per_hour(v, arrayed) for v in e]
    if isinstance(e, dict):
        out = {}
        for k, v in e.items():
            out[k] = per_hour(v, arrayed) if k in ("args", "bindings", "expr") or isinstance(v, (dict, list)) else v
        if e.get("op") == "apply_expression_template":
            out["bindings"] = {b: per_hour(v, arrayed) for b, v in e["bindings"].items()}
        return out
    return e


def solar_year(hours, lib, out_dir):
    solar = json.load(open(os.path.join(REPO, "lib", "solar.esm")))
    m = solar["models"]["Solar"]
    H = {"h": {"from": "hours"}}
    variables = {}
    arrayed = {"t_utc"}
    for k, v in m["variables"].items():
        if v["type"] == "parameter" and k != "t_utc":
            variables[k] = {"type": "parameter", "default": v["default"]}
        elif k != "t_utc":
            arrayed.add(k)
    for k in sorted(arrayed):
        variables[k] = {"type": "unknown", "shape": ["hours"]}
    variables["lat"]["default"] = 40.1
    variables["lon"]["default"] = -88.2
    eqs = [{"lhs": "t_utc", "rhs": faq(op("+", T0, op("*", 3600, op("-", "h", 1)), "t"), ["h"], H)}]
    for e in m["equations"]:
        rhs = per_hour(strip_units(e["rhs"]), arrayed)
        eqs.append({"lhs": e["lhs"], "rhs": faq(rhs, ["h"], H)})
    variables["z"] = {"type": "unknown", "shape": ["hours"], "default": 1.0}
    eqs.append({"lhs": faq_lhs("z", ["h"], H),
                "rhs": faq(op("*", 0.01, op("-", ix("solar_zenith_angle", "h"), ix("z", "h"))), ["h"], H)})
    model = {"variables": variables, "equations": eqs,
             "expression_template_imports": imports(lib, out_dir, [("calendar.esm", CALENDAR)])}
    return {
        "esm": ESM_VERSION,
        "metadata": {"name": f"solar_year_tpl_H{hours}",
                     "description": f"lib/solar.esm over {hours} hourly timestamps from 2026-01-01, datetime fields as lib/calendar.esm templates."},
        "index_sets": {"hours": {"kind": "interval", "size": hours}},
        "models": {"SolarYear": model},
    }


# ---------------------------------------------------------------------------
# Geometry: lat-lon to lat-lon conservative regrid.
# ---------------------------------------------------------------------------

GEOMETRY_TEMPLATE = {"planar": "overlap_area_planar", "spherical": "overlap_area_spherical"}


def overlap_template(manifold):
    """The overlap area of src cell i and tgt cell j through lib/geometry.esm: the
    lon-lat rings themselves (planar) or their unit-vector stacks (spherical)."""
    a, b = ("src_poly", "tgt_poly") if manifold == "planar" else ("src_xyz", "tgt_xyz")
    return apply(GEOMETRY_TEMPLATE[manifold], ring_a=a, cell_a="i", nv_a=4, ring_b=b, cell_b="j", nv_b=4)


def unit_stack(var, poly, cells):
    """xyz[c, v, d]: the unit vector of each lon-lat vertex (lib/geometry.esm `lonlat_to_unit`)."""
    return {"lhs": var, "rhs": faq(apply("lonlat_to_unit", ring=poly, cell="c", vert="v", comp="d"),
                                   ["c", "v", "d"], {"c": {"from": cells}, "v": {"from": "cell_verts"}, "d": [1, 3]})}


def latlon_cells(lons, lats):
    return [[[lons[a], lats[b]], [lons[a + 1], lats[b]], [lons[a + 1], lats[b + 1]], [lons[a], lats[b + 1]]]
            for b in range(len(lats) - 1) for a in range(len(lons) - 1)]


def thirds(n):
    """Edges of a 2/3-degree grid over [0, n], every even degree exact."""
    out = []
    for m in range(0, n, 2):
        out += [float(m), m + 2.0 / 3.0, m + 4.0 / 3.0]
    out.append(float(n))
    return out


def regrid(manifold, n, lib, out_dir):
    assert n % 2 == 0
    lon0, lat0 = -100.0, 30.0
    se = [lon0 + k for k in range(n + 1)]
    sa = [lat0 + k for k in range(n + 1)]
    te = [lon0 + x for x in thirds(n)]
    ta = [lat0 + x for x in thirds(n)]
    src = latlon_cells(se, sa)
    tgt = latlon_cells(te, ta)
    ns, nt = len(src), len(tgt)
    S, T = {"from": "src_cells"}, {"from": "tgt_cells"}
    join = [{"on": [["src_bin_c1", "tgt_bin_c1"], ["src_bin_c2", "tgt_bin_c2"]]}]
    alive = op(">", ix("A_ij", "i", "j"), "atol")

    def bbox_min(var, cells, poly, sym, coord):
        return {"lhs": var, "rhs": faq(ix(poly, sym, "v", coord), [sym], {sym: {"from": cells}, "v": {"from": "cell_verts"}},
                                         reduce="min")}

    # One integer bin column per coordinate, joined pairwise.
    def binkey(var, coord, step, sym, cells):
        return {"lhs": ix(var, sym), "rhs": faq(op("floor", op("/", ix(coord, sym), step)),
                                                [sym], {sym: {"from": cells}}, semiring="sum_product")}

    area = overlap_template(manifold)
    u = lambda shape=None, d=None: {k: v for k, v in (("type", "unknown"), ("shape", shape), ("default", d)) if v is not None}
    v = {
        "src_poly": u(["src_cells", "cell_verts", "coord"]),
        "tgt_poly": u(["tgt_cells", "cell_verts", "coord"]),
        "src_lon": u(["src_cells"]), "src_lat": u(["src_cells"]),
        "tgt_lon": u(["tgt_cells"]), "tgt_lat": u(["tgt_cells"]),
        "src_bin_c1": u(["src_cells"]), "src_bin_c2": u(["src_cells"]),
        "tgt_bin_c1": u(["tgt_cells"]), "tgt_bin_c2": u(["tgt_cells"]),
        "A_ij": u(["src_cells", "tgt_cells"]), "A_j": u(["tgt_cells"]),
        "W_ij": u(["src_cells", "tgt_cells"]), "F_rg": u(["tgt_cells"]),
        "F_src": u(["src_cells"], 10.0), "F_tgt": u(["tgt_cells"], 0.0),
        "dx": {"type": "parameter", "default": 2.0}, "dy": {"type": "parameter", "default": 2.0},
        "atol": {"type": "parameter", "default": 1e-12}, "kd": {"type": "parameter", "default": 0.1},
    }
    eqs = [
        {"lhs": "src_poly", "rhs": const(src)},
        {"lhs": "tgt_poly", "rhs": const(tgt)},
        bbox_min("src_lon", "src_cells", "src_poly", "i", 1),
        bbox_min("src_lat", "src_cells", "src_poly", "i", 2),
        bbox_min("tgt_lon", "tgt_cells", "tgt_poly", "j", 1),
        bbox_min("tgt_lat", "tgt_cells", "tgt_poly", "j", 2),
        binkey("src_bin_c1", "src_lon", "dx", "i", "src_cells"),
        binkey("src_bin_c2", "src_lat", "dy", "i", "src_cells"),
        binkey("tgt_bin_c1", "tgt_lon", "dx", "j", "tgt_cells"),
        binkey("tgt_bin_c2", "tgt_lat", "dy", "j", "tgt_cells"),
        {"lhs": "A_ij", "rhs": faq(area, ["i", "j"], {"i": S, "j": T}, semiring="sum_product", join=join)},
        {"lhs": "A_j", "rhs": faq(ix("A_ij", "i", "j"), ["j"], {"i": S, "j": T}, semiring="sum_product", join=join, filter=alive)},
        {"lhs": "W_ij", "rhs": faq(op("/", ix("A_ij", "i", "j"), ix("A_j", "j")), ["i", "j"], {"i": S, "j": T},
                                   semiring="sum_product", join=join, filter=alive)},
        {"lhs": faq_lhs("F_src", ["i"], {"i": S}), "rhs": faq(op("*", op("-", "kd"), ix("F_src", "i")), ["i"], {"i": S})},
        {"lhs": "F_rg", "rhs": faq(op("*", ix("W_ij", "i", "j"), ix("F_src", "i")), ["j"], {"i": S, "j": T},
                                   semiring="sum_product", join=join, filter=alive)},
        {"lhs": faq_lhs("F_tgt", ["j"], {"j": T}), "rhs": faq(op("-", ix("F_rg", "j"), ix("F_tgt", "j")), ["j"], {"j": T})},
    ]
    names = [GEOMETRY_TEMPLATE[manifold]]
    if manifold == "spherical":
        v["src_xyz"] = u(["src_cells", "cell_verts", "xyz"])
        v["tgt_xyz"] = u(["tgt_cells", "cell_verts", "xyz"])
        eqs[2:2] = [unit_stack("src_xyz", "src_poly", "src_cells"), unit_stack("tgt_xyz", "tgt_poly", "tgt_cells")]
        names.append("lonlat_to_unit")
    model = {"variables": v, "equations": eqs,
             "expression_template_imports": imports(lib, out_dir, [("geometry.esm", names)])}
    return {
        "esm": ESM_VERSION,
        "metadata": {"name": f"regrid_{manifold}_tpl_N{n}",
                     "description": f"{manifold} conservative regrid of an {n}x{n} 1-degree lat-lon grid onto the 2/3-degree grid over it, overlap areas by the lib/geometry.esm template."},
        "index_sets": {"coord": {"kind": "interval", "size": 2}, "xyz": {"kind": "interval", "size": 3}, "cell_verts": {"kind": "interval", "size": 4},
                       "src_cells": {"kind": "interval", "size": ns}, "tgt_cells": {"kind": "interval", "size": nt}},
        "models": {"Regrid": model},
    }


# ---------------------------------------------------------------------------
# Relational: nearest-generator assignment.
# ---------------------------------------------------------------------------

ARGMIN_SYMBOL = "k_argmin_1"


def lcg(seed):
    s = seed
    while True:
        s = (6364136223846793005 * s + 1442695040888963407) % (1 << 64)
        yield (s >> 11) / float(1 << 53)


def nearest(p, g, lib, out_dir):
    r = lcg(2026)
    # Coordinates on a 1/1024 lattice, so squared distances are exact and ties real.
    px = [math.floor(next(r) * 1024) / 1024 for _ in range(p)]
    py = [math.floor(next(r) * 1024) / 1024 for _ in range(p)]
    gx = [math.floor(next(r) * 64) / 64 for _ in range(g)]
    gy = [math.floor(next(r) * 64) / 64 for _ in range(g)]

    def dist(k):
        dx = op("-", ix("px", "i"), ix("gx", k))
        dy = op("-", ix("py", "i"), ix("gy", k))
        return op("+", op("*", dx, dx), op("*", dy, dy))

    P = {"i": {"from": "points"}}
    assign = apply("argmin", f=dist(ARGMIN_SYMBOL), n=g)
    v = {k: {"type": "unknown", "shape": [s]} for k, s in
         (("px", "points"), ("py", "points"), ("gx", "generators"), ("gy", "generators"), ("assign", "points"))}
    v["w"] = {"type": "unknown", "shape": ["points"], "default": 0.0}
    eqs = [
        {"lhs": "px", "rhs": const(px)}, {"lhs": "py", "rhs": const(py)},
        {"lhs": "gx", "rhs": const(gx)}, {"lhs": "gy", "rhs": const(gy)},
        {"lhs": ix("assign", "i"), "rhs": faq(assign, ["i"], P, args=["px", "py", "gx", "gy"])},
        {"lhs": faq_lhs("w", ["i"], P),
         "rhs": faq(op("-", ix("gx", ix("assign", "i")), ix("w", "i")), ["i"], P, args=["gx", "assign"])},
    ]
    model = {"variables": v, "equations": eqs,
             "expression_template_imports": imports(lib, out_dir, [("relational.esm", ["argmin"])])}
    return {
        "esm": ESM_VERSION,
        "metadata": {"name": f"nearest_tpl_P{p}_G{g}",
                     "description": f"nearest-generator assignment of {p} points among {g} generators by the lib/relational.esm argmin template, feeding a gather."},
        "index_sets": {"points": {"kind": "interval", "size": p}, "generators": {"kind": "interval", "size": g}},
        "models": {"Nearest": model},
    }


# ---------------------------------------------------------------------------
# Relational: MPAS-scale edge enumeration and rank.
# ---------------------------------------------------------------------------


def mesh_faces(n):
    """The triangles of an n x n grid of unit squares, two per square, as
    (lo, hi) vertex-id pairs per face edge (1-based vertex ids, lo < hi), the
    faces in a fixed pseudo-random order so neighbouring queries are not
    neighbouring keys."""
    def vid(i, j):
        return 1 + j * (n + 1) + i

    faces = []
    for j in range(n):
        for i in range(n):
            a, b, c, d = vid(i, j), vid(i + 1, j), vid(i, j + 1), vid(i + 1, j + 1)
            for tri in ((a, b, d), (a, d, c)):
                faces.append([tuple(sorted((tri[k], tri[(k + 1) % 3]))) for k in range(3)])
    r = lcg(577)
    for k in range(len(faces) - 1, 0, -1):
        m = int(next(r) * (k + 1))
        faces[k], faces[m] = faces[m], faces[k]
    return faces, (n + 1) * (n + 1)


def mesh_edge_count(n):
    return 3 * n * n + 2 * n


def mesh_rank(n, lib, out_dir):
    faces, nv = mesh_faces(n)
    lo = [[e[0] for e in f] for f in faces]
    hi = [[e[1] for e in f] for f in faces]
    ne = mesh_edge_count(n)
    F = {"f": {"from": "faces"}}
    FL = {"f": {"from": "faces"}, "le": {"from": "local_edges"}}
    E = {"e": {"from": "edges"}}
    W = {"e": {"from": "edge_ids"}}
    v = {k: {"type": "unknown", "shape": ["faces", "local_edges"]} for k in ("edge_lo", "edge_hi")}
    v["edge_exists"] = {"type": "unknown", "shape": ["edges"]}
    v["edge_dense_id"] = {"type": "unknown", "shape": ["edges"]}
    v["n_edges"] = {"type": "unknown", "default": 0.0}
    v["w"] = {"type": "unknown", "shape": ["edge_ids"], "default": 0.0}
    v["q"] = {"type": "unknown", "shape": ["faces"], "default": 0.0}
    v["q_in"] = {"type": "unknown", "shape": ["faces"]}
    a, b = ix("edge_lo", "f", "le"), ix("edge_hi", "f", "le")
    key = apply("edge_key", u=a, v=b, lo=1, n=nv)
    dense = op("-", "e", 1)
    face_edge = "face_edge_rank"
    v["edge_members"] = {"type": "parameter", "shape": ["edges"], "default": 0.0}
    v[face_edge] = {"type": "unknown", "shape": ["faces", "local_edges"]}
    extra = [{"lhs": ix(face_edge, "f", "le"),
              "rhs": faq(apply("rank_of_set", x=apply("edge_key", u=a, v=b, lo=1, n=nv),
                               members="edge_members", S="edges"),
                         ["f", "le"], FL, args=["edge_lo", "edge_hi", "edge_members"])}]
    eqs = [
        {"lhs": "edge_lo", "rhs": const(lo)}, {"lhs": "edge_hi", "rhs": const(hi)},
        {"lhs": ix("edge_exists", "e"),
         "rhs": faq(op("true"), ["e"], FL, id="edge_set", args=["edge_lo", "edge_hi"], semiring="bool_and_or",
                    distinct=True, key=key, filter=op("true"))},
        {"lhs": ix("edge_dense_id", "e"), "rhs": faq(dense, ["e"], E, semiring="sum_product")},
    ] + extra + [
        {"lhs": op("D", "n_edges", wrt="t"), "rhs": faq(1.0, [], E, semiring="sum_product")},
        {"lhs": faq_lhs("w", ["e"], W), "rhs": faq(op("-", "e", ix("w", "e")), ["e"], W)},
        # The edge-state sum is its own observed: Julia builds a gather of a state
        # by a data subscript as a whole-array contraction, not under an elementwise op.
        {"lhs": ix("q_in", "f"),
         "rhs": faq(ix("w", ix(face_edge, "f", "le")), ["f"], FL, args=["w", face_edge], semiring="sum_product")},
        {"lhs": faq_lhs("q", ["f"], F), "rhs": faq(op("-", ix("q_in", "f"), ix("q", "f")), ["f"], F)},
    ]
    model = {"variables": v, "equations": eqs,
             "expression_template_imports": imports(lib, out_dir, [("relational.esm", ["edge_key", "rank_of_set"])])}
    edges = {"kind": "derived", "from_faq": "edge_set", "member_factor": "edge_members"}
    return {
        "esm": ESM_VERSION,
        "metadata": {"name": f"mesh_rank_tpl_E{ne}",
                     "description": f"edge enumeration of a {n} x {n} triangulated grid ({len(faces)} faces, {ne} unique edges) by "
                     "an edge_key key and the loop index, the face edge ids by rank_of_set over the derived set"
                     "; a state per edge id and per face, the face's read through its edge ids."},
        "index_sets": {"faces": {"kind": "interval", "size": len(faces)},
                       "local_edges": {"kind": "interval", "size": 3}, "edges": edges,
                       "edge_ids": {"kind": "interval", "size": ne}},
        "models": {"MeshRank": model},
    }


# ---------------------------------------------------------------------------
# The scaling family's regrid documents, on either manifold's template.
# ---------------------------------------------------------------------------

SCALING = os.path.join(REPO, "tests", "conformance", "scaling", "fixtures", "regrid")


def scaling_regrid(manifold, n, lib, out_dir):
    """tests/conformance/scaling/fixtures/regrid/regrid_N<n>.esm with its overlap
    areas by the lib/geometry.esm template for `manifold`."""
    d = json.load(open(os.path.join(SCALING, f"regrid_N{n}.esm")))
    d["esm"] = ESM_VERSION
    d["metadata"]["name"] = f"regrid_scaling_{manifold}_tpl_N{n}"
    m = d["models"]["Regrid"]
    for e in m["equations"]:
        if e["lhs"] == "A_ij":
            e["rhs"]["expr"] = overlap_template(manifold)
    names = [GEOMETRY_TEMPLATE[manifold]]
    if manifold == "spherical":
        d["index_sets"]["xyz"] = {"kind": "interval", "size": 3}
        for xyz, poly, cells in (("src_xyz", "src_poly", "src_cells"), ("tgt_xyz", "tgt_poly", "tgt_cells")):
            m["variables"][xyz] = {"type": "unknown", "units": "1", "shape": [cells, "cell_verts", "xyz"]}
            m["equations"].insert(2, unit_stack(xyz, poly, cells))
        names.append("lonlat_to_unit")
    m["expression_template_imports"] = imports(lib, out_dir, [("geometry.esm", names)])
    return d


def documents(out_dir, lib, hours, ns, near, manifolds=("planar", "spherical"), scaling=(), meshes=()):
    docs = {}
    for n in scaling:
        for mf in manifolds:
            docs[f"regrid_scaling_{mf}_tpl_N{n}.esm"] = scaling_regrid(mf, n, lib, out_dir)
    for h in hours:
        docs[f"solar_year_tpl_H{h}.esm"] = solar_year(h, lib, out_dir)
    for n in ns:
        for mf in manifolds:
            docs[f"regrid_{mf}_tpl_N{n}.esm"] = regrid(mf, n, lib, out_dir)
    for p, g in near:
        docs[f"nearest_tpl_P{p}_G{g}.esm"] = nearest(p, g, lib, out_dir)
    for n in meshes:
        docs[f"mesh_rank_tpl_E{mesh_edge_count(n)}.esm"] = mesh_rank(n, lib, out_dir)
    return docs


def dumps(d):
    return json.dumps(d, indent=1) + "\n"


def default_out():
    """Where the harnesses look when given no directory: `$CLOSED_TEMPLATES_DIR`,
    else `closed_templates` under the temporary directory (`$TMPDIR`)."""
    return os.environ.get("CLOSED_TEMPLATES_DIR") or os.path.join(tempfile.gettempdir(), "closed_templates")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", default=None, help="output directory (default: default_out())")
    ap.add_argument("--lib", default=None, help="a lib/ directory to import from instead of esm:std/")
    ap.add_argument("--hours", type=int, action="append")
    ap.add_argument("--n", type=int, action="append")
    ap.add_argument("--nearest", type=lambda s: tuple(int(x) for x in s.split("x")), action="append",
                    help="PxG, e.g. 2000x200")
    ap.add_argument("--manifold", action="append")
    ap.add_argument("--scaling", type=int, action="append", help="a scaling-family regrid size (100, 1000)")
    ap.add_argument("--mesh", type=int, action="append",
                    help="a mesh_rank grid side n (3n^2 + 2n edges: 57, 182, 577 give ~1e4, 1e5, 1e6)")
    ap.add_argument("--only", choices=("solar", "regrid", "nearest", "mesh"), action="append",
                    help="write only these families (repeatable)")
    a = ap.parse_args(argv)
    out = os.path.abspath(a.out or default_out())
    os.makedirs(out, exist_ok=True)
    fams = {"solar": a.hours or DEFAULTS["hours"], "regrid": a.n or DEFAULTS["n"],
            "nearest": a.nearest or DEFAULTS["nearest"], "mesh": a.mesh or DEFAULTS["mesh"]}
    if a.only:
        fams = {k: (v if k in a.only else []) for k, v in fams.items()}
    docs = documents(out, a.lib and os.path.abspath(a.lib), fams["solar"], fams["regrid"], fams["nearest"],
                     tuple(a.manifold or ("planar", "spherical")), tuple(a.scaling or ()), fams["mesh"])
    for name, d in docs.items():
        with open(os.path.join(out, name), "w") as fh:
            fh.write(dumps(d))
    print(f"wrote {len(docs)} documents to {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
