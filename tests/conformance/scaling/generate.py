#!/usr/bin/env python3
"""The scaling tier's one document generator (see README.md in this directory).

Each family is a function of a nominal size N that returns one ESM document.
Generation is deterministic: the same family and N give byte-identical JSON,
so the committed small fixtures can be checked against the generator
(`--check`) and every binding measures the same documents.

    generate.py --out DIR [--family F ...] [--max-n N] [--sizes pr|sweep]
        writes DIR/<family>/<family>_N<n>.esm and DIR/index.json
    generate.py --check
        regenerates the committed fixtures in memory and fails on any drift
    generate.py --write-fixtures
        rewrites fixtures/ from the generator (then commit the result)

Nothing here reads outside the repository: the reaction mechanism is vendored
under vendor/, and the size ladders come from manifest.json.
"""

import argparse
import json
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
MANIFEST = os.path.join(HERE, "manifest.json")
FIXTURES = os.path.join(HERE, "fixtures")
POLLU = os.path.join(HERE, "vendor", "pollu_reaction_system.json")
ESM_VERSION = "1.1.0"
AUTHORS = ["EarthSciAST scaling conformance tier"]


# ---------------------------------------------------------------------------
# Expression helpers
# ---------------------------------------------------------------------------


def op(o, *args):
    return {"op": o, "args": list(args)}


def ix(var, *subs):
    return {"op": "index", "args": [var, *subs]}


def shift(sym, k):
    if k == 0:
        return sym
    return op("+" if k > 0 else "-", sym, abs(k))


def faq_lhs(var, idxs, ranges):
    return {
        "op": "faq",
        "args": [],
        "output_idx": list(idxs),
        "expr": {"op": "D", "args": [ix(var, *idxs)], "wrt": "t"},
        "ranges": ranges,
    }


def faq(expr, idxs, ranges, **extra):
    node = {"op": "faq", "args": [], "output_idx": list(idxs), "ranges": ranges}
    node.update(extra)
    node["expr"] = expr
    return node


def metadata(name, description):
    return {"name": name, "description": description, "authors": AUTHORS}


def doc(name, description, index_sets, models, **top):
    d = {"esm": ESM_VERSION, "metadata": metadata(name, description)}
    if index_sets:
        d["index_sets"] = {k: {"kind": "interval", "size": v} for k, v in index_sets.items()}
    d.update(top)
    d["models"] = models
    return d


def side_for(n, rank):
    """Grid side whose rank-th power is nearest the nominal cell count."""
    return max(1, int(round(n ** (1.0 / rank))))


# ---------------------------------------------------------------------------
# Families
# ---------------------------------------------------------------------------

AXES = ["w", "x", "y", "z"]
LOOPS = ["i", "j", "k", "l"]


def stencil(rank, n):
    """Rank-`rank` diffusion, kappa * (sum of the 2*rank neighbours - 2*rank*u).

    Out-of-range neighbours read the homogeneous-Dirichlet zero ghost that
    esm-spec 4.3.3 gives a state gather, so there is no boundary region: the
    whole grid is one affine box. Neighbour order in the sum is, per axis in
    declaration order, the +1 neighbour then the -1 neighbour; the hand loops
    follow that order so their dy is bit-identical.
    """
    s = side_for(n, rank)
    axes = ["x", "y", "z"][:rank] if rank <= 3 else AXES
    idxs = LOOPS[:rank]
    ranges = {sym: [1, s] for sym in idxs}
    terms = []
    for a in range(rank):
        for k in (1, -1):
            terms.append(ix("u", *[shift(sym, k if d == a else 0) for d, sym in enumerate(idxs)]))
    lap = op("-", op("+", *terms), op("*", 2 * rank, ix("u", *idxs)))
    model = {
        "variables": {
            "u": {"type": "unknown", "units": "1", "default": 1.0, "shape": axes},
            "kappa": {"type": "parameter", "units": "1", "default": 0.1},
        },
        "equations": [
            {"lhs": faq_lhs("u", idxs, ranges), "rhs": faq(op("*", "kappa", lap), idxs, ranges)}
        ],
    }
    name = f"stencil_{rank}d"
    desc = f"{rank}-D diffusion on a {'x'.join([str(s)] * rank)} grid, zero-ghost boundaries"
    return doc(name, desc, {a: s for a in axes}, {"Diffusion": model}), {
        "cells": s**rank,
        "states": s**rank,
        "side": s,
    }


def transport(n):
    """The 3-D transport benchmark (tests/bench/transport_3axis_7cubed_fullrank.esm) at side s.

    Built here rather than resized from the bench file so the structure is
    explicit; at s = 7 it reproduces that file's expression templates exactly.
    Each axis derivative is a five-region makearray (two one-sided faces, two
    near-face centred classes, a wide limited interior), every region value an
    expression-template reference to a rank-3 faq.
    """
    s = max(5, side_for(n, 3))
    axes = ["x", "y", "z"]
    loops = ["i", "j", "k"]

    def at(a, sub):
        return [sub if d == a else loops[d] for d in range(3)]

    def body(a, rng, expr):
        ranges = {loops[d]: (rng if d == a else {"from": axes[d]}) for d in range(3)}
        return {"op": "faq", "output_idx": loops, "args": ["f"], "ranges": ranges, "expr": expr}

    def f(a, sub):
        return ix("f", *at(a, sub))

    tmpl = {}
    for a, ax in enumerate(axes):
        i = loops[a]
        p1, m1, p2, m2, c = (
            f(a, op("+", i, 1)),
            f(a, op("-", i, 1)),
            f(a, op("+", i, 2)),
            f(a, op("-", i, 2)),
            f(a, i),
        )
        interior = op(
            "+",
            op("*", 0.6666666666666666, op("-", p1, m1)),
            op("*", -0.08333333333333333, op("-", p2, m2)),
            op("*", 0.05, op("-", op("min", p1, c), op("max", m1, c))),
            op("*", 0.025, op("-", op("min", p2, p1), op("max", m2, m1))),
        )
        tmpl[f"s{ax}_int"] = {"params": ["f"], "body": body(a, [3, s - 2], interior)}
        tmpl[f"s{ax}_c1"] = {
            "params": ["f"],
            "body": body(
                a,
                [1, 1],
                op(
                    "-",
                    op("*", 1.5, op("-", f(a, 2), f(a, 1))),
                    op("*", 0.5, op("-", f(a, 3), f(a, 2))),
                ),
            ),
        }
        tmpl[f"s{ax}_c2"] = {
            "params": ["f"],
            "body": body(a, [2, 2], op("*", 0.5, op("-", f(a, 3), f(a, 1)))),
        }
        tmpl[f"s{ax}_c6"] = {
            "params": ["f"],
            "body": body(a, [s - 1, s - 1], op("*", 0.5, op("-", f(a, s), f(a, s - 2)))),
        }
        tmpl[f"s{ax}_c7"] = {
            "params": ["f"],
            "body": body(
                a,
                [s, s],
                op(
                    "-",
                    op("*", 1.5, op("-", f(a, s), f(a, s - 1))),
                    op("*", 0.5, op("-", f(a, s - 1), f(a, s - 2))),
                ),
            ),
        }

        def region(r):
            return [r if d == a else [1, s] for d in range(3)]

        classes = [
            ("int", [3, s - 2]),
            ("c1", [1, 1]),
            ("c2", [2, 2]),
            ("c6", [s - 1, s - 1]),
            ("c7", [s, s]),
        ]
        tmpl[f"D{ax}"] = {
            "params": ["f"],
            "match": {"op": "D", "args": ["f"], "wrt": ax},
            "body": {
                "op": "makearray",
                "args": [],
                "regions": [region(r) for _, r in classes],
                "values": [
                    {
                        "op": "apply_expression_template",
                        "args": [],
                        "name": f"s{ax}_{cl}",
                        "bindings": {"f": "f"},
                    }
                    for cl, _ in classes
                ],
            },
        }
    rhs = op("-", op("+", *[{"op": "D", "args": ["q"], "wrt": ax} for ax in axes]))
    model = {
        "expression_templates": tmpl,
        "variables": {"q": {"type": "unknown", "units": "1", "shape": axes, "default": 1.5}},
        "equations": [{"lhs": {"op": "D", "args": ["q"], "wrt": "t"}, "rhs": rhs}],
    }
    desc = (
        f"3-D limited transport benchmark on a {s}x{s}x{s} grid: -(Dx(q)+Dy(q)+Dz(q)), each axis "
        "derivative a five-class makearray of expression-template references"
    )
    return doc("transport_3d", desc, {a: s for a in axes}, {"Transport": model}), {
        "cells": s**3,
        "states": s**3,
        "side": s,
    }


def load_pollu():
    with open(POLLU) as fh:
        return json.load(fh)


def chemistry_grid(n):
    """The Pollu mechanism (20 species, 25 reactions) lifted pointwise onto a lon x lat grid.

    `operator_compose` with `lifting: pointwise` adds the reaction network to a
    per-species upwind-free centred advection along lon (one-sided at the two
    lon faces). This is the shape of tests/valid/advection_reaction_loaded_ic_bc.esm
    without loaded data.
    """
    nlon = max(3, int(round(math.sqrt(n))))
    nlat = max(1, int(round(n / nlon)))
    p = load_pollu()
    rs = {
        "reference": p["reference"],
        "parameters": p["parameters"],
        "species": p["species"],
        "reactions": p["reactions"],
    }
    if rs["reference"] is None:
        del rs["reference"]
    species = list(rs["species"])

    def fv(a, b):
        return ix("f", a, b)

    grad = {
        "params": ["f"],
        "match": {"op": "grad", "args": ["f"], "dim": "lon"},
        "body": {
            "op": "makearray",
            "args": [],
            "regions": [[[2, nlon - 1], [1, nlat]], [[1, 1], [1, nlat]], [[nlon, nlon], [1, nlat]]],
            "values": [
                op(
                    "/",
                    op("-", fv(op("+", "i", 1), "j"), fv(op("-", "i", 1), "j")),
                    op("*", 2, "dx"),
                ),
                op("/", op("-", fv(op("+", "i", 1), "j"), fv("i", "j")), "dx"),
                op("/", op("-", fv("i", "j"), fv(op("-", "i", 1), "j")), "dx"),
            ],
        },
    }
    eqs = [
        {
            "lhs": {"op": "D", "args": [f"Pollu.{s}"], "wrt": "t"},
            "rhs": op("*", op("-", "u_wind"), {"op": "grad", "args": [f"Pollu.{s}"], "dim": "lon"}),
        }
        for s in species
    ]
    models = {
        "Advection": {
            "variables": {
                "u_wind": {"type": "parameter", "units": "m/s", "default": 1.0},
                "dx": {"type": "parameter", "units": "m", "default": 1000.0},
            },
            "expression_templates": {"grad_lon": grad},
            "equations": eqs,
        }
    }
    desc = f"Pollu (20 species, 25 reactions) lifted pointwise onto a {nlon}x{nlat} lon-lat grid with lon advection"
    d = doc(
        "chemistry_grid",
        desc,
        {"lon": nlon, "lat": nlat},
        models,
        reaction_systems={"Pollu": rs},
    )
    d["coupling"] = [
        {"type": "operator_compose", "systems": ["Pollu", "Advection"], "lifting": "pointwise"}
    ]
    cells = nlon * nlat
    return d, {"cells": cells, "states": cells * len(species), "nlon": nlon, "nlat": nlat}


def prefix_scan(n):
    """An inclusive, measure-weighted prefix scan feeding a column settling term.

    The idiom of tests/valid/faq/cumulative_prefix_reduction.esm: a running
    sum is an ordinary faq whose filter compares the contracted index to the
    output index. D(u[i]) = -0.001 * burden_below[i], burden_below[i] =
    sum_{j <= i} u[j] * dz[j].
    """
    ranges_i = {"i": {"from": "x"}}
    ranges_ij = {"i": {"from": "x"}, "j": {"from": "x"}}
    model = {
        "variables": {
            "u": {"type": "unknown", "units": "kg/m^3", "shape": ["x"], "default": 1.0},
            "dz": {"type": "parameter", "units": "m", "shape": ["x"], "default": 100.0},
            "burden_below": {"type": "unknown", "units": "kg/m^2", "shape": ["x"]},
        },
        "equations": [
            {
                "lhs": faq_lhs("u", ["i"], ranges_i),
                "rhs": faq(op("*", -0.001, ix("burden_below", "i")), ["i"], ranges_i),
            },
            {
                "lhs": "burden_below",
                "rhs": faq(
                    op("*", ix("u", "j"), ix("dz", "j")),
                    ["i"],
                    ranges_ij,
                    reduce="+",
                    filter=op("<=", "j", "i"),
                ),
            },
        ],
    }
    desc = f"inclusive measure-weighted prefix scan over a {n}-layer column"
    return doc("prefix_scan", desc, {"x": n}, {"Column": model}), {"cells": n, "states": n}


def source_receptor(n):
    """A square dense source-receptor contraction, D(c[i]) = sum_j K[i,j] * e[j].

    K is an n x n parameter with a scalar default, so the document stays small
    while the contraction is dense; the emissions e decay at rate kd.
    """
    model = {
        "variables": {
            "c": {"type": "unknown", "units": "1", "shape": ["rcv"], "default": 0.0},
            "e": {"type": "unknown", "units": "1", "shape": ["src"], "default": 1.0},
            "K": {"type": "parameter", "units": "1", "shape": ["rcv", "src"], "default": 0.001},
            "kd": {"type": "parameter", "units": "1", "default": 0.1},
        },
        "equations": [
            {
                "lhs": faq_lhs("c", ["i"], {"i": {"from": "rcv"}}),
                "rhs": faq(
                    op("*", ix("K", "i", "j"), ix("e", "j")),
                    ["i"],
                    {"i": {"from": "rcv"}, "j": {"from": "src"}},
                ),
            },
            {
                "lhs": faq_lhs("e", ["j"], {"j": {"from": "src"}}),
                "rhs": faq(op("*", op("-", "kd"), ix("e", "j")), ["j"], {"j": {"from": "src"}}),
            },
        ],
    }
    desc = f"dense square source-receptor contraction, {n} sources x {n} receptors"
    return doc("source_receptor", desc, {"src": n, "rcv": n}, {"SourceReceptor": model}), {
        "cells": n,
        "states": 2 * n,
    }


def regrid(n):
    """Conservative regrid of a decaying source field onto a shifted target strip grid.

    The assembly of tests/valid/geometry/conservative_regrid_assembly.esm
    (bin-skolem broad phase, inline polygon_intersection_area narrow phase,
    row-sum normalisation), with the source field made a state so the apply
    step runs on every right-hand-side call:
        D(F_src[i]) = -kd * F_src[i]
        F_rg[j] = sum_i W[i,j] * F_src[i]
        D(F_tgt[j]) = F_rg[j] - F_tgt[j]
    The source cells are the unit strips [i-1, i] x [0, 1]; the target cells
    have boundaries at 0, 1.5, 2.5, ..., n - 0.5, n, so every target cell
    overlaps two source cells fractionally except at the ends.
    """
    src = [[[float(i), 0.0], [i + 1.0, 0.0], [i + 1.0, 1.0], [float(i), 1.0]] for i in range(n)]
    bnd = [0.0] + [j + 0.5 for j in range(1, n)] + [float(n)]
    tgt = [[[bnd[j], 0.0], [bnd[j + 1], 0.0], [bnd[j + 1], 1.0], [bnd[j], 1.0]] for j in range(n)]
    S = {"from": "src_cells"}
    T = {"from": "tgt_cells"}
    join = [{"on": [["src_bin", "tgt_bin"]]}]
    alive = op(">", ix("A_ij", "i", "j"), "atol")

    def bbox_min(var, cells, sym, coord):
        return {
            "lhs": var,
            "rhs": {
                "op": "faq",
                "output_idx": [sym],
                "args": [],
                "reduce": "min",
                "ranges": {sym: {"from": cells}, "v": {"from": "cell_verts"}},
                "expr": ix(cells.split("_")[0] + "_poly", sym, "v", coord),
            },
        }

    def binkey(var, lon, lat, sym, cells):
        return {
            "lhs": ix(var, sym),
            "rhs": faq(
                {
                    "op": "skolem",
                    "label": "bin",
                    "args": [
                        op("floor", op("/", ix(lon, sym), "dx")),
                        op("floor", op("/", ix(lat, sym), "dy")),
                    ],
                },
                [sym],
                {sym: {"from": cells}},
                semiring="sum_product",
            ),
        }

    v = {
        "src_poly": {
            "type": "unknown",
            "units": "1",
            "shape": ["src_cells", "cell_verts", "coord"],
        },
        "tgt_poly": {
            "type": "unknown",
            "units": "1",
            "shape": ["tgt_cells", "cell_verts", "coord"],
        },
        "src_lon": {"type": "unknown", "units": "1", "shape": ["src_cells"]},
        "src_lat": {"type": "unknown", "units": "1", "shape": ["src_cells"]},
        "tgt_lon": {"type": "unknown", "units": "1", "shape": ["tgt_cells"]},
        "tgt_lat": {"type": "unknown", "units": "1", "shape": ["tgt_cells"]},
        "src_bin": {"type": "unknown", "units": "1", "shape": ["src_cells"]},
        "tgt_bin": {"type": "unknown", "units": "1", "shape": ["tgt_cells"]},
        "A_ij": {"type": "unknown", "units": "1", "shape": ["src_cells", "tgt_cells"]},
        "A_j": {"type": "unknown", "units": "1", "shape": ["tgt_cells"]},
        "W_ij": {"type": "unknown", "units": "1", "shape": ["src_cells", "tgt_cells"]},
        "F_rg": {"type": "unknown", "units": "1", "shape": ["tgt_cells"]},
        "F_src": {"type": "unknown", "units": "1", "shape": ["src_cells"], "default": 10.0},
        "F_tgt": {"type": "unknown", "units": "1", "shape": ["tgt_cells"], "default": 0.0},
        "dx": {"type": "parameter", "units": "1", "default": 2.0},
        "dy": {"type": "parameter", "units": "1", "default": 2.0},
        "atol": {"type": "parameter", "units": "1", "default": 1e-12},
        "kd": {"type": "parameter", "units": "1", "default": 0.1},
    }
    eqs = [
        {"lhs": "src_poly", "rhs": {"op": "const", "args": [], "value": src}},
        {"lhs": "tgt_poly", "rhs": {"op": "const", "args": [], "value": tgt}},
        bbox_min("src_lon", "src_cells", "i", 1),
        bbox_min("src_lat", "src_cells", "i", 2),
        bbox_min("tgt_lon", "tgt_cells", "j", 1),
        bbox_min("tgt_lat", "tgt_cells", "j", 2),
        binkey("src_bin", "src_lon", "src_lat", "i", "src_cells"),
        binkey("tgt_bin", "tgt_lon", "tgt_lat", "j", "tgt_cells"),
        {
            "lhs": "A_ij",
            "rhs": faq(
                {
                    "op": "polygon_intersection_area",
                    "manifold": "planar",
                    "args": [ix("src_poly", "i"), ix("tgt_poly", "j")],
                },
                ["i", "j"],
                {"i": S, "j": T},
                semiring="sum_product",
                join=join,
            ),
        },
        {
            "lhs": "A_j",
            "rhs": faq(
                ix("A_ij", "i", "j"),
                ["j"],
                {"i": S, "j": T},
                semiring="sum_product",
                join=join,
                filter=alive,
            ),
        },
        {
            "lhs": "W_ij",
            "rhs": faq(
                op("/", ix("A_ij", "i", "j"), ix("A_j", "j")),
                ["i", "j"],
                {"i": S, "j": T},
                semiring="sum_product",
                join=join,
                filter=alive,
            ),
        },
        {
            "lhs": faq_lhs("F_src", ["i"], {"i": S}),
            "rhs": faq(op("*", op("-", "kd"), ix("F_src", "i")), ["i"], {"i": S}),
        },
        {
            "lhs": "F_rg",
            "rhs": faq(
                op("*", ix("W_ij", "i", "j"), ix("F_src", "i")),
                ["j"],
                {"i": S, "j": T},
                semiring="sum_product",
                join=join,
                filter=alive,
            ),
        },
        {
            "lhs": faq_lhs("F_tgt", ["j"], {"j": T}),
            "rhs": faq(op("-", ix("F_rg", "j"), ix("F_tgt", "j")), ["j"], {"j": T}),
        },
    ]
    desc = f"conservative regrid of {n} unit source strips onto {n} shifted target strips, applied every call"
    isets = {"coord": 2, "cell_verts": 4, "src_cells": n, "tgt_cells": n}
    return doc("regrid", desc, isets, {"Regrid": {"variables": v, "equations": eqs}}), {
        "cells": n,
        "states": 2 * n,
    }


def lcg_permutation(m, seed=12345):
    """A fixed pseudo-random permutation of 0..m-1 (Fisher-Yates over a 64-bit LCG).

    Implemented here rather than with `random` so the numbering is the same on
    every Python version, and so a binding's hand loop can rebuild it if it
    wants to (the adapters read the table from the document instead).
    """
    perm = list(range(m))
    state = seed
    for k in range(m - 1, 0, -1):
        state = (state * 6364136223846793005 + 1442695040888963407) % (1 << 64)
        r = (state >> 33) % (k + 1)
        perm[k], perm[r] = perm[r], perm[k]
    return perm


def unstructured_gather(n):
    """A neighbour gather over an unstructured numbering of a periodic 2-D mesh.

    The cells of an s x s periodic grid are renumbered by a fixed permutation,
    and the four neighbours of each cell are listed in an inline const table
    nbr[c, k] (k = east, west, north, south). D(u[c]) = kappa * sum_k (u[nbr[c,k]] - u[c]):
    the indirect gather u[nbr[i,k]] of a finite-volume scheme on a mesh.
    """
    s = max(3, side_for(n, 2))
    m = s * s
    perm = lcg_permutation(m)  # perm[grid cell] = mesh cell id (0-based)
    nbr = [None] * m
    for gi in range(s):
        for gj in range(s):
            me = perm[gi * s + gj]
            nb = [((gi + 1) % s, gj), ((gi - 1) % s, gj), (gi, (gj + 1) % s), (gi, (gj - 1) % s)]
            nbr[me] = [perm[a * s + b] + 1 for a, b in nb]
    table = {"op": "const", "args": [], "value": nbr}
    body = op("*", "kappa", op("-", ix("u", ix(table, "i", "k")), ix("u", "i")))
    model = {
        "variables": {
            "u": {"type": "unknown", "units": "1", "default": 1.0, "shape": ["cells"]},
            "kappa": {"type": "parameter", "units": "1", "default": 0.1},
        },
        "equations": [
            {
                "lhs": faq_lhs("u", ["i"], {"i": {"from": "cells"}}),
                "rhs": faq(body, ["i"], {"i": {"from": "cells"}, "k": {"from": "nb"}}),
            }
        ],
    }
    desc = f"four-neighbour gather over a permuted numbering of a {s}x{s} periodic mesh"
    return doc("unstructured_gather", desc, {"cells": m, "nb": 4}, {"Mesh": model}), {
        "cells": m,
        "states": m,
        "side": s,
    }


def mass_action_terms(rs, species_ref):
    """Per species, the ordered list of (net stoichiometry, rate expression).

    `species_ref(name)` spells a species read. Reaction order and substrate
    order are the mechanism's; the hand loops use the same order.
    """
    out = {s: [] for s in rs["species"]}
    for r in rs["reactions"]:
        rate = [r["rate"]]
        for sub in r.get("substrates") or []:
            rate += [species_ref(sub["species"])] * int(sub["stoichiometry"])
        rate_expr = op("*", *rate) if len(rate) > 1 else rate[0]
        for s in rs["species"]:
            net = sum(
                x["stoichiometry"] for x in (r.get("products") or []) if x["species"] == s
            ) - sum(x["stoichiometry"] for x in (r.get("substrates") or []) if x["species"] == s)
            if net:
                out[s].append((net, rate_expr))
    return out


def scalar_chemistry(n):
    """Independent scalar copies of the Pollu box, written out as scalar ODEs.

    The pre-expanded ("scalarized") form a gridded chemistry takes when a tool
    writes one equation per cell: n / 20 boxes of 20 scalar states each, box b's
    species named `<species>_<b>`, rate constants shared. N counts states.
    """
    boxes = max(1, n // 20)
    rs = load_pollu()
    variables = {}
    equations = []
    for pname, pv in rs["parameters"].items():
        variables[pname] = {"type": "parameter", "units": "1", "default": pv["default"]}
    for b in range(1, boxes + 1):
        for s, sv in rs["species"].items():
            variables[f"{s}_{b}"] = {
                "type": "unknown",
                "units": "1",
                "default": sv.get("default", 0.0),
            }
        terms = mass_action_terms(rs, lambda name, b=b: f"{name}_{b}")
        for s in rs["species"]:
            ts = []
            for net, rate in terms[s]:
                ts.append(
                    rate if net == 1 else (op("-", rate) if net == -1 else op("*", net, rate))
                )
            rhs = ts[0] if len(ts) == 1 else (op("+", *ts) if ts else 0.0)
            equations.append({"lhs": {"op": "D", "args": [f"{s}_{b}"], "wrt": "t"}, "rhs": rhs})
    desc = f"{boxes} independent scalar Pollu boxes ({20 * boxes} scalar states), one ODE per species per box"
    d = doc(
        "scalar_chemistry", desc, None, {"Boxes": {"variables": variables, "equations": equations}}
    )
    return d, {"cells": boxes, "states": 20 * boxes, "boxes": boxes}


FAMILIES = {
    "stencil_1d": lambda n: stencil(1, n),
    "stencil_2d": lambda n: stencil(2, n),
    "stencil_3d": lambda n: stencil(3, n),
    "stencil_4d": lambda n: stencil(4, n),
    "transport_3d": transport,
    "chemistry_grid": chemistry_grid,
    "prefix_scan": prefix_scan,
    "source_receptor": source_receptor,
    "regrid": regrid,
    "unstructured_gather": unstructured_gather,
    "scalar_chemistry": scalar_chemistry,
}


# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------


def dumps(d):
    return json.dumps(d, separators=(",", ":"), ensure_ascii=True) + "\n"


def load_manifest():
    with open(MANIFEST) as fh:
        return json.load(fh)


def filename(family, n):
    return f"{family}_N{n}.esm"


def planned(manifest, which, families=None, max_n=None):
    """(family, nominal N) pairs for the `pr` or `sweep` size list."""
    out = []
    for fam, spec in manifest["families"].items():
        if families and fam not in families:
            continue
        for n in spec["pr_sizes" if which == "pr" else "sizes"]:
            if max_n is None or n <= max_n:
                out.append((fam, n))
    return out


def generate(family, n):
    d, info = FAMILIES[family](n)
    return dumps(d), info


def index_entry(family, n, info, rel):
    return {
        "family": family,
        "n": n,
        "path": rel,
        "n_cells": info["cells"],
        "n_states": info["states"],
        "shape": {k: v for k, v in info.items() if k not in ("cells", "states")},
    }


def write_tree(out, pairs):
    index = []
    for fam, n in pairs:
        text, info = generate(fam, n)
        rel = os.path.join(fam, filename(fam, n))
        path = os.path.join(out, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as fh:
            fh.write(text)
        index.append(index_entry(fam, n, info, rel))
        print(
            f"{rel}: {info['cells']} cells, {info['states']} states, {len(text)} bytes",
            file=sys.stderr,
        )
    with open(os.path.join(out, "index.json"), "w") as fh:
        json.dump({"documents": index}, fh, indent=1)
        fh.write("\n")


def check(manifest):
    """Every committed fixture matches the generator, and nothing extra is committed."""
    pairs = planned(manifest, "pr")
    bad = []
    expected = set()
    for fam, n in pairs:
        text, info = generate(fam, n)
        rel = os.path.join(fam, filename(fam, n))
        expected.add(rel)
        path = os.path.join(FIXTURES, rel)
        if not os.path.exists(path):
            bad.append(f"missing fixture {rel}")
            continue
        with open(path) as fh:
            if fh.read() != text:
                bad.append(f"fixture {rel} differs from the generator")
    idx_path = os.path.join(FIXTURES, "index.json")
    want_index = {
        "documents": [
            index_entry(f, n, generate(f, n)[1], os.path.join(f, filename(f, n))) for f, n in pairs
        ]
    }
    if not os.path.exists(idx_path) or json.load(open(idx_path)) != want_index:
        bad.append("fixtures/index.json differs from the generator")
    for root, _, files in os.walk(FIXTURES):
        for name in files:
            rel = os.path.relpath(os.path.join(root, name), FIXTURES)
            if rel != "index.json" and rel not in expected:
                bad.append(f"fixture {rel} is not produced by the generator at a PR size")
    for msg in bad:
        print(f"FAIL: {msg}", file=sys.stderr)
    if bad:
        print(
            "run `python3 tests/conformance/scaling/generate.py --write-fixtures` and commit the result",
            file=sys.stderr,
        )
        return 1
    print(f"ok: {len(pairs)} committed fixtures match the generator", file=sys.stderr)
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument(
        "--out", help="directory to write <family>/<family>_N<n>.esm and index.json into"
    )
    ap.add_argument("--family", action="append", help="restrict to this family (repeatable)")
    ap.add_argument("--max-n", type=int, help="skip nominal sizes above this")
    ap.add_argument(
        "--sizes",
        choices=["pr", "sweep"],
        default="sweep",
        help="the manifest's PR size list or its full sweep ladder (default)",
    )
    ap.add_argument("--check", action="store_true", help="verify the committed fixtures")
    ap.add_argument(
        "--write-fixtures", action="store_true", help="rewrite fixtures/ from the generator"
    )
    a = ap.parse_args(argv)
    manifest = load_manifest()
    for fam in a.family or []:
        if fam not in FAMILIES:
            ap.error(f"unknown family {fam!r}; known: {', '.join(FAMILIES)}")
    if set(manifest["families"]) != set(FAMILIES):
        print("FAIL: manifest.json families and generate.py families differ", file=sys.stderr)
        return 1
    if a.check:
        return check(manifest)
    if a.write_fixtures:
        write_tree(FIXTURES, planned(manifest, "pr"))
        return 0
    if not a.out:
        ap.error("one of --out, --check, --write-fixtures is required")
    write_tree(a.out, planned(manifest, a.sizes, a.family, a.max_n))
    return 0


if __name__ == "__main__":
    sys.exit(main())
