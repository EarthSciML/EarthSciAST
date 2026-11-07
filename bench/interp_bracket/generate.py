#!/usr/bin/env python3
"""The interpolation-bracket A/B documents (issue #588), parametric in N.

One ODE, three spellings of its table lookups. A column of N levels holds three
states u, v and th; each relaxes toward a table interpolated at its level's query
height, which a persistent forcing moves so the solver never coasts:

    xq[l]      = zq[l] + 150 sin(0.3 t)
    D(u[l])    = 0.5 (interp(U, z, xq[l]) - u[l])        (and v from V, th from TH)

The three lookups of a level share one axis z (N knots) and one query, so the
composed spelling computes one bracket per level and hands it to all three.

Spellings (one document each, per N):

* ``interp_bracket_const_fn_N<n>.esm`` - the hand-written fast form:
  ``interp.linear`` calls on inline ``const`` tables and axis (esm-spec 9.2).
* ``interp_bracket_const_compose_N<n>.esm`` - the native composition as an
  author writes it, the ``bracket_index`` / ``interp_linear_bracketed`` templates
  of EqWeFiC's ``lib/table_interp.esm`` over the same tables, here observeds
  whose equation is a ``const`` node (a const array, esm-spec 4.3.3). The bracket
  is a rank-0 ``faq`` counting the knots at or below the query.
* ``interp_bracket_runtime_compose_N<n>.esm`` - the same composition over an
  axis and tables the document computes from formulas of the knot index and a
  parameter (the knot spacing dz0), so the axis is a run-time array and no
  ``interp.linear`` spelling of it is legal (9.2's const rule); its fast
  reference is a hand-written count (the Rust bench's hand loop).

The fused spelling is the composition document under a compiler that recognises
the bracket (the Rust tape's count instruction); the unfused one is the same
document with that recognition off. All three spellings give bit-identical
trajectories: the knots, tables and queries are exact in binary64 or rounded
the same way in every spelling (the const arrays are the formulas evaluated in
the order the runtime document writes them).

Usage:

    python3 bench/interp_bracket/generate.py               # rewrite the committed N = 59, 200
    python3 bench/interp_bracket/generate.py --check       # committed documents are current
    python3 bench/interp_bracket/generate.py --n 400 --out "$BUILD"   # any N, anywhere

Timing: ``ab.py`` here runs the spellings' whole solves interleaved (any binary
with an ``esm simulate``); the Rust criterion group ``interp_bracket`` in
``pkg/earthsci-ast-rs/benches/benchmarks.rs`` times one right-hand side of
each against a hand-written loop, and ``bench_julia.jl`` times the same
spellings under the Julia native compiler.
"""

import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
COMMITTED_N = [59, 200]
ESM_VERSION = "1.2.0"  # a unit-bearing `const` (esm-spec 4.8.5)
SPELLINGS = ["const_fn", "const_compose", "runtime_compose"]


def op(o, *args):
    return {"op": o, "args": list(args)}


def ix(var, *subs):
    return op("index", var, *subs)


def const(values):
    return {"op": "const", "args": [], "value": values}


def apply(name, **bindings):
    return {"op": "apply_expression_template", "args": [], "name": name, "bindings": bindings}


def faq(expr, idxs, ranges):
    return {"op": "faq", "args": [], "output_idx": list(idxs), "ranges": ranges, "expr": expr}


# ---------------------------------------------------------------------------
# The column: knots, tables and queries. Each formula is written once as an
# AST and once as the Python that evaluates it in the same operation order, so
# a const array holds exactly what the runtime document computes.
# ---------------------------------------------------------------------------


def km1(k):
    return op("-", k, 1)


def z_ast(k):
    """Knot height: (k - 1) (dz0 + (k - 1)), a stretched grid of exact integers.
    dz0 is a parameter (default 100), so nothing about the axis is known
    before the solve starts."""
    return op("*", km1(k), op("+", "dz0", km1(k)))


def z_py(k):
    return float((k - 1) * (100 + (k - 1)))


def u_ast(k):
    return op("-", op("+", 10, op("*", 0.5, k)), op("*", 0.002, op("*", k, k)))


def u_py(k):
    return (10.0 + 0.5 * k) - 0.002 * float(k * k)


def v_ast(k):
    return op("-", 2, op("*", 0.05, k))


def v_py(k):
    return 2.0 - 0.05 * k


def th_ast(k):
    return op("+", 290, op("*", 0.004, z_ast(k)))


def th_py(k):
    return 290.0 + 0.004 * z_py(k)


TABLES = [("U", u_ast, u_py), ("V", v_ast, v_py), ("TH", th_ast, th_py)]
STATES = [("u", "U", 10.0), ("v", "V", 2.0), ("th", "TH", 290.0)]


def zq_ast(l):
    """Query height of level l: between knots l and l + 1."""
    s = op("-", l, 0.6)
    return op("*", s, op("+", 100, s))


def per_second(v):
    return {"op": "const", "args": [], "value": v, "units": "1/s"}


def xq_ast(l):
    return op("+", zq_ast(l), op("*", 150, op("sin", op("*", per_second(0.3), "t"))))


# ---------------------------------------------------------------------------
# The templates: EqWeFiC lib/table_interp.esm's linear subset, verbatim.
# ---------------------------------------------------------------------------


def templates():
    return {
        "bracket_index": {
            "params": ["axis", "x", "n"],
            "description": "Lower bracketing index of x on the strictly increasing axis (n entries): the number of axis levels at or below x, held to [1, n-1].",
            "body": op(
                "min",
                op(
                    "max",
                    {
                        "op": "faq",
                        "output_idx": [],
                        "reduce": "+",
                        "args": ["axis"],
                        "ranges": {"k_bracket": [1, "n"]},
                        "expr": op("ifelse", op("<=", ix("axis", "k_bracket"), "x"), 1, 0),
                    },
                    1,
                ),
                op("-", "n", 1),
            ),
        },
        "bracket_weight": {
            "params": ["axis", "x", "i_lo"],
            "description": "Fractional position of x between axis[i_lo] and axis[i_lo+1].",
            "body": op(
                "/",
                op("-", "x", ix("axis", "i_lo")),
                op("-", ix("axis", op("+", "i_lo", 1)), ix("axis", "i_lo")),
            ),
        },
        "lerp": {
            "params": ["lo", "hi", "frac"],
            "description": "Linear blend lo + frac (hi - lo), the order esm-spec 9.2 pins.",
            "body": op("+", "lo", op("*", "frac", op("-", "hi", "lo"))),
        },
        "interp_linear_bracketed": {
            "params": ["table", "axis", "x", "i_lo", "n"],
            "description": "interp.linear(table, axis, x) for a run-time table and axis of n entries, given i_lo = bracket_index(axis, x, n).",
            "body": op(
                "ifelse",
                op("<=", "x", ix("axis", 1)),
                ix("table", 1),
                op(
                    "ifelse",
                    op(">=", "x", ix("axis", "n")),
                    ix("table", "n"),
                    apply(
                        "lerp",
                        lo=ix("table", "i_lo"),
                        hi=ix("table", op("+", "i_lo", 1)),
                        frac=apply("bracket_weight", axis="axis", x="x", i_lo="i_lo"),
                    ),
                ),
            ),
        },
    }


# ---------------------------------------------------------------------------
# Documents
# ---------------------------------------------------------------------------


def variable(kind, desc, shape=None, default=None):
    v = {"type": kind, "units": "1", "description": desc}
    if shape is not None:
        v["shape"] = shape
    if default is not None:
        v["default"] = default
    return v


def lev_faq(expr):
    return faq(expr, ["l"], {"l": {"from": "lev"}})


def d_lhs(var):
    return {
        "op": "faq",
        "args": [],
        "output_idx": ["l"],
        "ranges": {"l": {"from": "lev"}},
        "expr": {"op": "D", "args": [ix(var, "l")], "wrt": "t"},
    }


def relax(var, lookup):
    return lev_faq(op("*", per_second(0.5), op("-", lookup, ix(var, "l"))))


def document(spelling, n):
    knots = range(1, n + 1)
    variables = {}
    equations = []
    for s, _, d in STATES:
        variables[s] = variable("unknown", f"relaxes toward table {s.upper()} at xq", ["lev"], d)
    variables["xq"] = variable("unknown", "query height of each level, moved by the forcing", ["lev"])
    equations.append({"lhs": "xq", "rhs": lev_faq(xq_ast("l"))})
    top = {}
    if spelling == "const_fn":
        zc = const([z_py(k) for k in knots])
        for s, tab, _ in STATES:
            py = dict((t, p) for t, _, p in TABLES)[tab]
            lookup = {"op": "fn", "name": "interp.linear", "args": [const([py(k) for k in knots]), zc, ix("xq", "l")]}
            equations.append({"lhs": d_lhs(s), "rhs": relax(s, lookup)})
    else:
        top["expression_templates"] = templates()
        variables["z"] = variable("unknown", "the knot heights, the one axis every lookup shares", ["knot"])
        if spelling == "const_compose":
            equations.append({"lhs": "z", "rhs": const([z_py(k) for k in knots])})
        else:
            variables["dz0"] = variable("parameter", "base knot spacing", default=100.0)
            equations.append({"lhs": "z", "rhs": faq(z_ast("k"), ["k"], {"k": {"from": "knot"}})})
        for tab, ast, py in TABLES:
            variables[tab] = variable("unknown", f"table {tab} at the knots", ["knot"])
            if spelling == "const_compose":
                rhs = const([py(k) for k in knots])
            else:
                rhs = faq(ast("k"), ["k"], {"k": {"from": "knot"}})
            equations.append({"lhs": tab, "rhs": rhs})
        variables["ilo"] = variable("unknown", "each level's bracket on z, shared by its three lookups", ["lev"])
        equations.append(
            {"lhs": "ilo", "rhs": lev_faq(apply("bracket_index", axis="z", x=ix("xq", "l"), n=n))}
        )
        for s, tab, _ in STATES:
            lookup = apply(
                "interp_linear_bracketed", table=tab, axis="z", x=ix("xq", "l"), i_lo=ix("ilo", "l"), n=n
            )
            equations.append({"lhs": d_lhs(s), "rhs": relax(s, lookup)})
    model = dict(top)
    model["variables"] = variables
    model["equations"] = equations
    what = {
        "const_fn": "interp.linear on inline const tables (the hand-written fast form)",
        "const_compose": "the bracket_index / interp_linear_bracketed composition over const tables",
        "runtime_compose": "the bracket_index / interp_linear_bracketed composition over computed tables",
    }[spelling]
    return {
        "esm": ESM_VERSION,
        "metadata": {
            "name": f"interp_bracket_{spelling}_N{n}",
            "description": (
                f"Interpolation-bracket benchmark (EarthSciAST issue #588), {n} levels and {n} knots, "
                f"three lookups per level sharing one axis and one query: {what}. "
                "Generated by bench/interp_bracket/generate.py."
            ),
            "authors": ["EarthSciAST interpolation-bracket benchmark"],
        },
        "index_sets": {
            "lev": {"kind": "interval", "size": n},
            "knot": {"kind": "interval", "size": n},
        },
        "models": {"Column": model},
    }


def filename(spelling, n):
    return f"interp_bracket_{spelling}_N{n}.esm"


def dumps(d):
    return json.dumps(d, indent=1) + "\n"


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--n", type=int, action="append", help="level count (repeatable); default the committed sizes")
    ap.add_argument("--out", default=HERE, help="output directory (default: this directory)")
    ap.add_argument("--check", action="store_true", help="exit 1 if a committed document is stale")
    a = ap.parse_args(argv)
    sizes = a.n or COMMITTED_N
    stale = []
    for n in sizes:
        if n < 2:
            sys.exit("N must be at least 2")
        for sp in SPELLINGS:
            path = os.path.join(a.out, filename(sp, n))
            text = dumps(document(sp, n))
            if a.check:
                try:
                    with open(path) as f:
                        if f.read() != text:
                            stale.append(path)
                except FileNotFoundError:
                    stale.append(path)
            else:
                os.makedirs(a.out, exist_ok=True)
                with open(path, "w") as f:
                    f.write(text)
    if stale:
        print("stale (run bench/interp_bracket/generate.py):\n  " + "\n  ".join(stale))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
