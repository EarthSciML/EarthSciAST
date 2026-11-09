#!/usr/bin/env python3
"""Elementwise template application (esm-spec §9.6.11) against the forms it replaces.

Each workload is written three times, the same model in each, so a timing
difference is the spelling's:

* ``fn``  - the closed function (``interp.linear`` / ``interp.bilinear`` /
  ``interp.searchsorted``) applied to an array query, the form models used
  before the elementwise rule;
* ``tpl`` - the ``lib/interp.esm`` template applied to the same array query,
  defining an observed declared without a shape, which the build lifts into a
  per-cell ``faq`` (the elementwise lift);
* ``faq`` - the hand-written per-cell ``faq`` over the template applied to one
  element, the output the lift is meant to produce.

Every workload has a state ``u`` over its cells, a query ``x = u + off`` (``off``
a per-cell offset computed from the cell index, so the queries cover the axis
and move with the state), a lookup ``L`` of the query, and
``D(u) = 0.5 (L - u)``. Tables and axes are inline ``const`` arrays of T entries
on a non-uniform axis.

Workloads (``<case>_<spelling>_<size>.esm``):

* ``lin1d``  - ``linear`` over a ``[c]`` query, N cells, T knots;
* ``lin3d``  - ``linear`` over a ``[lon, lat, lev]`` query;
* ``levcol`` - ``linear`` over a ``[lev]`` column of queries, multiplied by a
  ``[lon, lat, lev]`` state ``w``, so the column replicates over lon and lat
  (``L = w * linear(col)``, ``D(w) = 0.5 (1 + 0.3 L - w)``);
* ``bilin1`` / ``bilin2`` - ``bilinear`` with x over ``[c]`` and y a scalar
  parameter / both x and y over ``[c]``, a TX x TY table;
* ``ssorted`` - ``searchsorted`` over a ``[c]`` query.

The ``levcol`` ``fn`` spelling is not a baseline today: Julia refuses it
(``E_TREEWALK_INDEX_NDIM``) and Rust evaluates the replicated column to NaN,
under both compilers. Compare its ``tpl`` against ``faq`` only.

Usage:

    python3 bench/template_array_args/generate.py            # the committed documents
    python3 bench/template_array_args/generate.py --check    # committed documents are current
    python3 bench/template_array_args/generate.py --out DIR --large   # also the large sizes

Timing: ``bench_julia.jl`` (Julia native) and the Rust criterion group
``template_array_args`` in ``pkg/earthsci-ast-rs/benches/benchmarks.rs``.
"""

import argparse
import json
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
ESM_VERSION = "1.2.0"
SPELLINGS = ("fn", "tpl", "faq")


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


def faq(expr, out, ranges):
    return {"op": "faq", "args": [], "output_idx": list(out), "ranges": ranges, "expr": expr}


LOOPS = ["i", "j", "k"]


def ranges(shape):
    return {lp: {"from": s} for lp, s in zip(LOOPS, shape)}


def axis(t):
    """A strictly increasing, non-uniform axis of t knots over [0, 10]."""
    return [round(10.0 * (k / (t - 1)) ** 1.3, 12) for k in range(t)]


def table(t, phase=0.0):
    return [round(1.0 + math.sin(0.37 * k + phase) + 0.01 * k, 12) for k in range(t)]


def lookup(kind, spelling, x, y=None, t=10, ty=None):
    """The lookup of query x (and y) in the given spelling; x / y are expressions."""
    if kind == "linear":
        tb, ax = const(table(t)), const(axis(t))
        if spelling == "fn":
            return op("fn", tb, ax, x, name="interp.linear")
        return apply("linear", table=tb, axis=ax, x=x, n=t)
    if kind == "searchsorted":
        ax = const(axis(t))
        if spelling == "fn":
            return op("fn", x, ax, name="interp.searchsorted")
        return apply("searchsorted", x=x, xs=ax, n=t)
    if kind == "bilinear":
        tb = const(
            [
                [
                    round(math.sin(0.3 * a) * math.cos(0.2 * b) + 0.01 * (a + b), 12)
                    for b in range(ty)
                ]
                for a in range(t)
            ]
        )
        axx, axy = const(axis(t)), const([v * 0.5 for v in axis(ty)])
        if spelling == "fn":
            return op("fn", tb, axx, axy, x, y, name="interp.bilinear")
        return apply("bilinear", table=tb, axis_x=axx, axis_y=axy, x=x, y=y, nx=t, ny=ty)
    raise ValueError(kind)


def offset(names, dims, span=10.0):
    """off[cells] = 1.1 span (linear cell number) / ncells - 0.5, so the
    queries cover the axis and a few fall off each end."""
    n = 1
    for s in dims:
        n *= s
    lin = op("-", LOOPS[0], 1)
    for d, lp in enumerate(LOOPS[1 : len(names)], start=1):
        lin = op("+", op("*", lin, dims[d]), op("-", lp, 1))
    return faq(op("-", op("*", span * 1.1 / n, lin), 0.5), LOOPS[: len(names)], ranges(names))


def var(kind, shape=None, default=None):
    v = {"type": kind}
    if shape is not None:
        v["shape"] = list(shape)
    if default is not None:
        v["default"] = default
    return v


def relax(state, shape, target):
    out = LOOPS[: len(shape)]
    return {
        "lhs": faq(op("D", ix(state, *out), wrt="t"), out, ranges(shape)),
        "rhs": faq(op("*", 0.5, op("-", target, ix(state, *out))), out, ranges(shape)),
    }


def document(case, spelling, size, out_dir, lib):
    """`size` is a dict: shape (index-set sizes), t, ty."""
    dims = size["dims"]
    names = size["names"]
    t, ty = size.get("t", 10), size.get("ty")
    index_sets = {nm: {"kind": "interval", "size": s} for nm, s in zip(names, dims)}
    variables, eqs = {}, []
    full = names
    cols = LOOPS[: len(full)]
    if case == "levcol":
        qshape = [names[-1]]
    else:
        qshape = full
    variables["u"] = var("unknown", qshape, 0.0)
    variables["off"] = var("unknown", qshape)
    if case == "levcol":
        eqs.append({"lhs": "off", "rhs": offset(qshape, [dims[-1]])})
    else:
        eqs.append({"lhs": "off", "rhs": offset(names, dims)})
    kind = {
        "lin1d": "linear",
        "lin3d": "linear",
        "levcol": "linear",
        "bilin1": "bilinear",
        "bilin2": "bilinear",
        "ssorted": "searchsorted",
    }[case]
    y = None
    if case == "bilin1":
        variables["py"] = var("parameter", None, 2.2)
    if case == "bilin2":
        variables["v"] = var("unknown", qshape, 0.0)
        eqs_v = True
    else:
        eqs_v = False

    if spelling == "faq":
        if case == "levcol":
            cell = {"u": ix("u", "k"), "off": ix("off", "k")}
        else:
            cell = {"u": ix("u", *cols), "off": ix("off", *cols)}
        x = op("+", cell["u"], cell["off"])
        if case == "bilin1":
            y = "py"
        elif case == "bilin2":
            y = op("-", op("*", 0.5, ix("v", *cols)), op("*", 0.3, cell["off"]))
    else:
        x = op("+", "u", "off")
        if case == "bilin1":
            y = "py"
        elif case == "bilin2":
            y = op("-", op("*", 0.5, "v"), op("*", 0.3, "off"))
    look = lookup(kind, spelling, x, y, t, ty)

    if case == "levcol":
        variables["w"] = var("unknown", full, 1.0)
        if spelling == "faq":
            rhs = faq(op("*", ix("w", *cols), look), cols, ranges(full))
        else:
            rhs = op("*", "w", look)
        variables["L"] = var("unknown", full if spelling == "faq" else None)
        eqs.append({"lhs": "L", "rhs": rhs})
        eqs.append(relax("w", full, op("+", 1.0, op("*", 0.3, ix("L", *cols)))))
        eqs.append(relax("u", qshape, op("*", 0.1, ix("off", "i"))))
    else:
        if spelling == "faq":
            look = faq(look, cols, ranges(full))
        variables["L"] = var("unknown", full if spelling == "faq" else None)
        eqs.append({"lhs": "L", "rhs": look})
        eqs.append(relax("u", full, ix("L", *cols)))
        if eqs_v:
            eqs.append(relax("v", full, op("*", 0.2, ix("L", *cols))))

    model = {"variables": variables, "equations": eqs}
    if spelling != "fn":
        model["expression_template_imports"] = [
            {"ref": os.path.relpath(os.path.join(lib, "interp.esm"), out_dir), "only": [kind]}
        ]
    what = {
        "fn": f"fn interp.{kind} on an array query",
        "tpl": f"the lib/interp.esm {kind} template on an array query (elementwise, esm-spec 9.6.11)",
        "faq": f"a hand-written per-cell faq over the {kind} template",
    }[spelling]
    return {
        "esm": ESM_VERSION,
        "metadata": {
            "name": f"{case}_{spelling}_{tag(size)}",
            "description": f"{case} over {' x '.join(map(str, dims))} cells, {what}. "
            "Generated by bench/template_array_args/generate.py.",
        },
        "index_sets": index_sets,
        "models": {"M": model},
    }


def tag(size):
    s = "x".join(map(str, size["dims"])) + f"_T{size.get('t', 10)}"
    if size.get("ty"):
        s += f"x{size['ty']}"
    return s


G3 = ["lon", "lat", "lev"]
COMMITTED = [
    ("lin1d", {"dims": [100], "names": ["c"], "t": 10}),
    ("lin1d", {"dims": [100], "names": ["c"], "t": 256}),
    ("lin1d", {"dims": [10000], "names": ["c"], "t": 10}),
    ("lin1d", {"dims": [10000], "names": ["c"], "t": 256}),
    ("lin1d", {"dims": [100000], "names": ["c"], "t": 10}),
    ("lin1d", {"dims": [100000], "names": ["c"], "t": 256}),
    ("lin3d", {"dims": [13, 7, 72], "names": G3, "t": 10}),
    ("lin3d", {"dims": [13, 7, 72], "names": G3, "t": 256}),
    ("levcol", {"dims": [13, 7, 72], "names": G3, "t": 10}),
    ("levcol", {"dims": [13, 7, 72], "names": G3, "t": 256}),
    ("bilin1", {"dims": [10000], "names": ["c"], "t": 10, "ty": 8}),
    ("bilin1", {"dims": [10000], "names": ["c"], "t": 200, "ty": 50}),
    ("bilin2", {"dims": [10000], "names": ["c"], "t": 10, "ty": 8}),
    ("bilin2", {"dims": [10000], "names": ["c"], "t": 200, "ty": 50}),
    ("ssorted", {"dims": [10000], "names": ["c"], "t": 10}),
    ("ssorted", {"dims": [10000], "names": ["c"], "t": 256}),
]
LARGE = [
    ("lin3d", {"dims": [72, 46, 72], "names": G3, "t": 10}),
    ("lin3d", {"dims": [72, 46, 72], "names": G3, "t": 256}),
    ("levcol", {"dims": [72, 46, 72], "names": G3, "t": 10}),
    ("levcol", {"dims": [72, 46, 72], "names": G3, "t": 256}),
]


def documents(out_dir, lib, large):
    docs = {}
    for case, size in COMMITTED + (LARGE if large else []):
        for s in SPELLINGS:
            docs[f"{case}_{s}_{tag(size)}.esm"] = document(case, s, size, out_dir, lib)
    return docs


def dumps(d):
    return json.dumps(d, indent=1) + "\n"


def main(argv=None):
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--check", action="store_true", help="exit 1 if a committed document is stale")
    ap.add_argument("--out", default=HERE)
    ap.add_argument("--lib", default=os.path.join(REPO, "lib"))
    ap.add_argument("--large", action="store_true", help="also the 72 x 46 x 72 grids")
    a = ap.parse_args(argv)
    out = os.path.abspath(a.out)
    os.makedirs(out, exist_ok=True)
    docs = documents(out, os.path.abspath(a.lib), a.large)
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
