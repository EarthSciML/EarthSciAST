#!/usr/bin/env python3
"""Template-versus-closed-form workloads for the phase-3 standard-library templates.

Each workload is written twice, once with the closed form it replaces (an `fn`
call, a geometry leaf, a relational op) and once with the pure-AST template of
`lib/*.esm` applied in its place. Everything else in the two documents is the
same, so a timing difference is the template's.

* ``solar_year_<spelling>_H<h>``: `lib/solar.esm` over a year of hourly
  timestamps. Each solar observed becomes an array over an `hours` index set
  (t_utc[h] = T0 + 3600 (h - 1) + t, so every call moves every timestamp and
  nothing is a build constant), and a state per hour relaxes toward the zenith
  angle. `fn` spelling: `fn datetime.*`; `tpl`: the `lib/calendar.esm`
  templates.
* ``regrid_<manifold>_<spelling>_N<n>``: conservative regrid of an n x n
  lat-lon grid of 1-degree cells onto a 2/3-degree grid (the
  `tests/conformance/scaling` `regrid` family's assembly: bin-skolem broad
  phase, overlap area per candidate pair, row-sum normalisation, applied every
  call). Every target cell lies inside one broad-phase bin, so the candidate
  set keeps every overlapping pair. `leaf` spelling: `polygon_intersection_area`;
  `tpl`: the `lib/geometry.esm` overlap-area template.
* ``nearest_<spelling>_P<p>_G<g>``: the nearest-generator assignment of
  `tests/conformance/value_invention_geometry` at p points and g generators,
  feeding a right-hand side through a gather. `op` spelling: `argmin`; `tpl`:
  the `lib/relational.esm` argmin template.

Usage:

    python3 bench/closed_templates/generate.py              # rewrite the committed documents
    python3 bench/closed_templates/generate.py --check      # committed documents are current
    python3 bench/closed_templates/generate.py --out DIR --lib LIBDIR [--hours H] [--n N] ...

`--lib` points the template imports at another directory holding
`calendar.esm`, `geometry.esm` and `relational.esm` (default: the repository's
`lib/`). Timing: `bench_julia.jl` (Julia native) and the Rust criterion group
`closed_templates` in `pkg/earthsci-ast-rs/benches/benchmarks.rs`.
"""

import argparse
import copy
import json
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
ESM_VERSION = "1.2.0"
T0 = 1767225600.0  # 2026-01-01T00:00:00Z

COMMITTED = {
    "hours": [8760],
    "n": [12],
    "nearest": [(500, 100)],
}

# The template that stands in for each closed form. The geometry and argmin
# signatures are the library owners'; each is built by one function below.
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


def calendar_spelling(e, spelling):
    """Every datetime field call in `e` as an `fn` call or a calendar template."""
    if isinstance(e, list):
        return [calendar_spelling(v, spelling) for v in e]
    if not isinstance(e, dict):
        return e
    if e.get("op") == "fn" and e.get("name", "").startswith("datetime."):
        field = e["name"].split(".", 1)[1]
        arg = calendar_spelling(e["args"][0], spelling)
        return e if spelling == "fn" else apply(field, t=arg)
    if e.get("op") == "apply_expression_template" and e.get("name") in CALENDAR:
        arg = calendar_spelling(e["bindings"]["t"], spelling)
        return apply(e["name"], t=arg) if spelling == "tpl" else op("fn", arg, name="datetime." + e["name"])
    return {k: calendar_spelling(v, spelling) for k, v in e.items()}


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


def solar_year(spelling, hours, lib, out_dir):
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
        rhs = per_hour(strip_units(calendar_spelling(e["rhs"], spelling)), arrayed)
        eqs.append({"lhs": e["lhs"], "rhs": faq(rhs, ["h"], H)})
    variables["z"] = {"type": "unknown", "shape": ["hours"], "default": 1.0}
    eqs.append({"lhs": faq_lhs("z", ["h"], H),
                "rhs": faq(op("*", 0.01, op("-", ix("solar_zenith_angle", "h"), ix("z", "h"))), ["h"], H)})
    model = {"variables": variables, "equations": eqs}
    if spelling == "tpl":
        model["expression_template_imports"] = imports(lib, out_dir, [("calendar.esm", CALENDAR)])
    return {
        "esm": ESM_VERSION,
        "metadata": {"name": f"solar_year_{spelling}_H{hours}",
                     "description": f"lib/solar.esm over {hours} hourly timestamps from 2026-01-01, datetime fields as {'fn calls' if spelling == 'fn' else 'lib/calendar.esm templates'}."},
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


def regrid(manifold, spelling, n, lib, out_dir):
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
    join = [{"on": [["src_bin", "tgt_bin"]]}]
    alive = op(">", ix("A_ij", "i", "j"), "atol")

    def bbox_min(var, cells, poly, sym, coord):
        return {"lhs": var, "rhs": faq(ix(poly, sym, "v", coord), [sym], {sym: {"from": cells}, "v": {"from": "cell_verts"}},
                                         reduce="min")}

    def binkey(var, lon, lat, sym, cells):
        return {"lhs": ix(var, sym), "rhs": faq(
            {"op": "skolem", "label": "bin", "args": [op("floor", op("/", ix(lon, sym), "dx")),
                                                      op("floor", op("/", ix(lat, sym), "dy"))]},
            [sym], {sym: {"from": cells}}, semiring="sum_product")}

    if spelling == "leaf":
        area = op("polygon_intersection_area", ix("src_poly", "i"), ix("tgt_poly", "j"), manifold=manifold)
    else:
        area = overlap_template(manifold)
    u = lambda shape=None, d=None: {k: v for k, v in (("type", "unknown"), ("shape", shape), ("default", d)) if v is not None}
    v = {
        "src_poly": u(["src_cells", "cell_verts", "coord"]),
        "tgt_poly": u(["tgt_cells", "cell_verts", "coord"]),
        "src_lon": u(["src_cells"]), "src_lat": u(["src_cells"]),
        "tgt_lon": u(["tgt_cells"]), "tgt_lat": u(["tgt_cells"]),
        "src_bin": u(["src_cells"]), "tgt_bin": u(["tgt_cells"]),
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
        binkey("src_bin", "src_lon", "src_lat", "i", "src_cells"),
        binkey("tgt_bin", "tgt_lon", "tgt_lat", "j", "tgt_cells"),
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
    if spelling == "tpl" and manifold == "spherical":
        v["src_xyz"] = u(["src_cells", "cell_verts", "xyz"])
        v["tgt_xyz"] = u(["tgt_cells", "cell_verts", "xyz"])
        eqs[2:2] = [unit_stack("src_xyz", "src_poly", "src_cells"), unit_stack("tgt_xyz", "tgt_poly", "tgt_cells")]
        names.append("lonlat_to_unit")
    model = {"variables": v, "equations": eqs}
    if spelling == "tpl":
        model["expression_template_imports"] = imports(lib, out_dir, [("geometry.esm", names)])
    return {
        "esm": ESM_VERSION,
        "metadata": {"name": f"regrid_{manifold}_{spelling}_N{n}",
                     "description": f"{manifold} conservative regrid of an {n}x{n} 1-degree lat-lon grid onto the 2/3-degree grid over it, overlap areas by {'polygon_intersection_area' if spelling == 'leaf' else 'the lib/geometry.esm template'}."},
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


def nearest(spelling, p, g, lib, out_dir):
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
    if spelling == "op":
        assign = op("argmin", "px", "py", "gx", "gy", arg="g", ranges={"g": {"from": "generators"}}, expr=dist("g"))
    else:
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
    model = {"variables": v, "equations": eqs}
    if spelling == "tpl":
        model["expression_template_imports"] = imports(lib, out_dir, [("relational.esm", ["argmin"])])
    return {
        "esm": ESM_VERSION,
        "metadata": {"name": f"nearest_{spelling}_P{p}_G{g}",
                     "description": f"nearest-generator assignment of {p} points among {g} generators by {'the argmin op' if spelling == 'op' else 'the lib/relational.esm argmin template'}, feeding a gather."},
        "index_sets": {"points": {"kind": "interval", "size": p}, "generators": {"kind": "interval", "size": g}},
        "models": {"Nearest": model},
    }


def documents(out_dir, lib, hours, ns, near, manifolds=("planar", "spherical")):
    docs = {}
    for h in hours:
        for s in ("fn", "tpl"):
            docs[f"solar_year_{s}_H{h}.esm"] = solar_year(s, h, lib, out_dir)
    for n in ns:
        for mf in manifolds:
            for s in ("leaf", "tpl"):
                docs[f"regrid_{mf}_{s}_N{n}.esm"] = regrid(mf, s, n, lib, out_dir)
    for p, g in near:
        for s in ("op", "tpl"):
            docs[f"nearest_{s}_P{p}_G{g}.esm"] = nearest(s, p, g, lib, out_dir)
    return docs


def dumps(d):
    return json.dumps(d, indent=1) + "\n"


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true", help="exit 1 if a committed document is stale")
    ap.add_argument("--out", default=HERE)
    ap.add_argument("--lib", default=os.path.join(REPO, "lib"))
    ap.add_argument("--hours", type=int, action="append")
    ap.add_argument("--n", type=int, action="append")
    ap.add_argument("--nearest", type=lambda s: tuple(int(x) for x in s.split("x")), action="append",
                    help="PxG, e.g. 2000x200")
    ap.add_argument("--manifold", action="append")
    a = ap.parse_args(argv)
    out = os.path.abspath(a.out)
    os.makedirs(out, exist_ok=True)
    docs = documents(out, os.path.abspath(a.lib), a.hours or COMMITTED["hours"], a.n or COMMITTED["n"],
                     a.nearest or COMMITTED["nearest"], tuple(a.manifold or ("planar", "spherical")))
    stale = []
    for name, d in docs.items():
        path = os.path.join(out, name)
        text = dumps(d)
        if a.check:
            if not os.path.exists(path) or open(path).read() != text:
                stale.append(name)
        else:
            with open(path, "w") as fh:
                fh.write(text)
    if stale:
        print("stale: " + ", ".join(stale), file=sys.stderr)
        return 1
    if not a.check:
        print(f"wrote {len(docs)} documents to {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
