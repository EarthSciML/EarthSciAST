#!/usr/bin/env python3
"""Generate the `faq_equality_scatter` fixtures and their goldens.

Every fixture is an ODE document whose right-hand side is one or more `faq`
nodes with an equality conjunct on an output index (esm-spec §4.3.1, "One-pass
scatter for an equality filter"). The golden of each fixture is the right-hand
side at the document's own initial state, computed HERE by plain Python float
loops that follow the definition literally: for each output cell, visit the
contracted indices in increasing order, test the whole filter, fold the
admitted terms into an accumulator seeded with the additive identity. No
EarthSciAST code is imported, so the goldens are an oracle outside every
binding.

    python3 tests/conformance/faq_equality_scatter/generate.py          # write
    python3 tests/conformance/faq_equality_scatter/generate.py --check  # verify

Each output cell's terms come from ONE varying contracted index, so no golden
depends on the order a binding nests two contracted indices in (that order is
not pinned across bindings).
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
MODEL = "Scatter"

# --------------------------------------------------------------------------- #
# Data. Magnitudes 1e16 apart from unit terms, so any fold order other than
# ascending changes a cell's bits (esm-spec §4.3.1's [1e16, 1, -1e16, 1]).
# --------------------------------------------------------------------------- #

C12 = [1e16, 1.0, -1e16, 1.0, 1.0, 1e16, 1.0, -1e16, 3.0, 1e16, -1e16, 5.0]
C18 = [
    1e16, 2.0, 1.0, 3.0, -1e16, 1.0,
    1.0, 1e16, 3.0, 1.0, 1.0, -1e16,
    -1e16, 5.0, 1.0, 1.0, 1e16, 7.0,
]
NEGZ = [-0.0, -0.0, 2.0, -0.0]
# max/min data: num[i] / den[i] is NaN where both are 0 and num[i] elsewhere.
MNUM = [1e16, 1.0, -1e16, 1.0, 1.0, 0.0, 1.0, -1e16, 0.0, 1e16, -1e16, 5.0, 2.0, 0.0, 4.0, 1.0]
MDEN = [1.0, 1.0, 1.0, 1.0, 1.0, 0.0, 1.0, 1.0, 0.0, 1.0, 1.0, 1.0, 1.0, 0.0, 1.0, 1.0]
R3 = [1.0, -1.0, 0.5]
G4 = [0.5, 0.25, 2.0, 4.0]
# Ragged: four rows of 6, 3, 0 and 3 positions over members 1..12, padding 0.
ROWLEN = [6, 3, 0, 3]
ROWS = [[1, 2, 3, 4, 5, 6], [7, 8, 9, 0, 0, 0], [0, 0, 0, 0, 0, 0], [10, 11, 12, 0, 0, 0]]
WMEM = C12  # one weight per member

NS = 24  # length of the source state s (D(s) = 0, default 1)

# --------------------------------------------------------------------------- #
# AST helpers
# --------------------------------------------------------------------------- #


def op(name, *args, **kw):
    node = {"op": name, "args": list(args)}
    node.update(kw)
    return node


def const(values):
    return {"op": "const", "args": [], "value": values}


def ix(arr, *subs):
    return op("index", arr, *subs)


def floordiv(expr, k):
    """floor(expr / k)."""
    return op("floor", op("/", expr, k))


def block(sym, width):
    """floor((sym - 1) / width) + 1: positions 1..width map to 1, and so on."""
    return op("+", floordiv(op("-", sym, 1), width), 1)


def faq(output_idx, ranges, expr, filt=None, reduce=None):
    node = {"op": "faq", "args": [], "output_idx": output_idx, "ranges": ranges, "expr": expr}
    if reduce is not None:
        node["reduce"] = reduce
    if filt is not None:
        node["filter"] = filt
    return node


def d_lhs(var, idx, ranges):
    """The indexed-faq LHS `D(var[idx...])` over `ranges`."""
    return faq(idx, ranges, op("D", ix(var, *idx), wrt="t"))


def s_of(sym):
    return ix("s", sym)


# --------------------------------------------------------------------------- #
# The naive oracle
# --------------------------------------------------------------------------- #

def fold(red, terms):
    """The naive left fold of the admitted terms, in visit order.

    `+` is seeded with +0.0 (esm-spec §4.3.1). `max` / `min` start from the
    identity and take a term only if it beats the accumulator, except that a
    NaN term, wherever it is, makes the result NaN (esm-spec §4.2). An empty
    fold is the identity.
    """
    if red == "+":
        acc = 0.0
        for t in terms:
            acc = acc + t
        return acc
    beats = (lambda t, a: t > a) if red == "max" else (lambda t, a: t < a)
    acc = -math.inf if red == "max" else math.inf
    for t in terms:
        if math.isnan(t) or math.isnan(acc):
            acc = math.nan
        elif beats(t, acc):
            acc = t
    return acc


def rng(lo, hi):
    return range(lo, hi + 1)


def fdiv(a, b):
    if b == 0.0:
        return math.nan if a == 0.0 or math.isnan(a) else math.copysign(math.inf, a)
    return a / b


def blk(i, w):
    return math.floor((i - 1) / w) + 1


# --------------------------------------------------------------------------- #
# Cases. Each returns (description, variables, equations, du) where du maps an
# element name ("w[2]", "w[1,3]") to its golden value.
# --------------------------------------------------------------------------- #


def source_state():
    variables = {
        "s": {
            "type": "unknown", "units": "1", "shape": ["ns"], "default": 1.0,
            "description": "A source state held constant (D(s) = 0) at 1, so every body reads a state and the scatter runs on the right-hand side.",
        }
    }
    eqs = [{"lhs": d_lhs("s", ["q"], {"q": {"from": "ns"}}), "rhs": faq(["q"], {"q": {"from": "ns"}}, 0.0)}]
    du = {f"s[{q}]": 0.0 for q in rng(1, NS)}
    return variables, eqs, du


def state_var(name, shape, desc):
    return {"type": "unknown", "units": "1", "shape": shape, "default": 0.0, "description": desc}


def put1(du, name, values):
    for k, v in enumerate(values, start=1):
        du[f"{name}[{k}]"] = v


def put2(du, name, table):
    for a, row in enumerate(table, start=1):
        for b, v in enumerate(row, start=1):
            du[f"{name}[{a},{b}]"] = v


def case_plus_cancelling():
    variables, eqs, du = source_state()
    # w: four cells of four terms each over i = 1..12 and an empty fourth cell.
    variables["w"] = state_var("w", ["n4"], "sum_{i : j == floor((i-1)/4)+1} C[i] s[i], j = 1..4 (cell 4 receives no term).")
    eqs.append({
        "lhs": d_lhs("w", ["j"], {"j": {"from": "n4"}}),
        "rhs": faq(["j"], {"j": {"from": "n4"}, "i": [1, 12]},
                   op("*", ix(const(C12), "i"), s_of("i")),
                   filt=op("==", "j", block("i", 4)), reduce="+"),
    })
    put1(du, "w", [fold("+", [C12[i - 1] * 1.0 for i in rng(1, 12) if blk(i, 4) == j]) for j in rng(1, 4)])
    # b: the issue's band transpose, spelled e == j: sum_{i : i + 1 == j} C[i] s[i].
    variables["b"] = state_var("b", ["n12"], "The issue's band transpose, sum_{i : i+1 == j} C[i] s[i], e on the LEFT of ==; cell 1 receives no term.")
    eqs.append({
        "lhs": d_lhs("b", ["j"], {"j": {"from": "n12"}}),
        "rhs": faq(["j"], {"j": [1, 12], "i": [1, 11]},
                   op("*", ix(const(C12), "i"), s_of("i")),
                   filt=op("==", op("+", "i", 1), "j")),
    })
    put1(du, "b", [fold("+", [C12[i - 1] for i in rng(1, 11) if i + 1 == j]) for j in rng(1, 12)])
    # z: terms that are all -0.0 fold to +0.0 from the +0.0 seed.
    variables["z"] = state_var("z", ["n2"], "sum over two-term cells of -0.0, -0.0 | 2, -0.0: cell 1 is +0.0 (the seed), cell 2 is 2.")
    eqs.append({
        "lhs": d_lhs("z", ["j"], {"j": {"from": "n2"}}),
        "rhs": faq(["j"], {"j": {"from": "n2"}, "i": [1, 4]},
                   op("*", ix(const(NEGZ), "i"), s_of("i")),
                   filt=op("==", "j", block("i", 2)), reduce="+"),
    })
    put1(du, "z", [fold("+", [NEGZ[i - 1] for i in rng(1, 4) if blk(i, 2) == j]) for j in rng(1, 2)])
    return ("`+` over cancelling data, both spellings (`j == e`, `e == j`), an empty cell, and an all-`-0.0` cell.",
            {"n2": 2, "n4": 4, "n12": 12}, variables, eqs, du)


def finite_marker(x):
    """NaN -> -1, -Inf -> -2, +Inf -> 2, else x: the right-hand side must be
    finite (a binding may refuse a non-finite derivative), so the reduction is
    an observed and the state's derivative reports it through this map."""
    if math.isnan(x):
        return -1.0
    if x < -1e300:
        return -2.0
    if x > 1e300:
        return 2.0
    return x


def finite_marker_ast(ref):
    return op("ifelse", op("==", ref, ref),
              op("ifelse", op("<", ref, -1e300), -2.0, op("ifelse", op(">", ref, 1e300), 2.0, ref)),
              -1.0)


def observed_then_rate(variables, eqs, du, name, shape_set, red_rhs, values, desc):
    """`name` = the reduction (an observed), and D(d<name>[j]) = marker(name[j])."""
    obs = name.upper()
    variables[obs] = {"type": "unknown", "units": "1", "shape": [shape_set], "description": desc}
    eqs.append({"lhs": obs, "rhs": red_rhs})
    rate = "d" + name
    variables[rate] = state_var(rate, [shape_set], f"D({rate}[j]) = {obs}[j], with NaN reported as -1 and -Inf as -2.")
    eqs.append({
        "lhs": d_lhs(rate, ["j"], {"j": {"from": shape_set}}),
        "rhs": faq(["j"], {"j": {"from": shape_set}}, finite_marker_ast(ix(obs, "j"))),
    })
    put1(du, rate, [finite_marker(v) for v in values])


def case_max_min_nan():
    variables, eqs, du = source_state()
    body = op("*", op("/", ix(const(MNUM), "i"), ix(const(MDEN), "i")), s_of("i"))
    terms = [fdiv(MNUM[i - 1], MDEN[i - 1]) for i in rng(1, 16)]
    for red, name in (("max", "mx"), ("min", "mn")):
        observed_then_rate(
            variables, eqs, du, name, "n3",
            faq(["j"], {"j": {"from": "n3"}, "i": [1, 16]}, body,
                filt=op("==", "j", block("i", 4)), reduce=red),
            [fold(red, [terms[i - 1] for i in rng(1, 16) if blk(i, 4) == j]) for j in rng(1, 3)],
            f"{red}_{{i : j == floor((i-1)/4)+1}} num[i]/den[i] s[i] over i = 1..16, j = 1..3: cell 1 holds numbers only, cell 2 a NaN after a number (i = 6), cell 3 a NaN first (i = 9); the NaN at i = 14 maps to j = 4, outside j's range, and must reach no cell.",
        )
    observed_then_rate(
        variables, eqs, du, "me", "n2",
        faq(["j"], {"j": {"from": "n2"}, "i": [1, 3]}, s_of("i"),
            filt=op("==", "j", op("+", "i", 5)), reduce="max"),
        [fold("max", [1.0 for i in rng(1, 3) if i + 5 == j]) for j in rng(1, 2)],
        "max over a filter that admits nothing (j == i + 5, i = 1..3, j = 1..2): every cell is the max identity, -Inf.",
    )
    return ("`max` and `min` with a NaN after a number in one cell, a NaN first in another, one at a point no cell admits, and an all-empty `max`. "
            "The reductions are observeds read by the right-hand side, which reports NaN as -1 and -Inf as -2 so every derivative is finite. "
            "A NaN term propagates wherever it is in the window (esm-spec §4.2).",
            {"n2": 2, "n3": 3}, variables, eqs, du)


def case_two_pinned_2d():
    variables, eqs, du = source_state()
    variables["w"] = state_var("w", ["n2", "n4"], "w[j1,j2] = sum_{i : j1 == mod(i-1,2)+1, j2 == floor((i-1)/6)+1} C[i] s[i], i = 1..18: three terms per cell, row j2 = 4 empty.")
    e1 = op("+", op("-", op("-", "i", 1), op("*", 2, floordiv(op("-", "i", 1), 2))), 1)
    e2 = block("i", 6)
    eqs.append({
        "lhs": d_lhs("w", ["j1", "j2"], {"j1": {"from": "n2"}, "j2": {"from": "n4"}}),
        "rhs": faq(["j1", "j2"], {"j1": {"from": "n2"}, "j2": {"from": "n4"}, "i": [1, 18]},
                   op("*", ix(const(C18), "i"), s_of("i")),
                   filt=op("and", op("==", "j1", e1), op("==", e2, "j2"))),
    })
    put2(du, "w", [[fold("+", [C18[i - 1] for i in rng(1, 18) if (i - 1) % 2 + 1 == j1 and blk(i, 6) == j2])
                    for j2 in rng(1, 4)] for j1 in rng(1, 2)])
    return ("A 2-D output with both indices pinned, one conjunct each (`j1 == e1`, `e2 == j2`).",
            {"n2": 2, "n4": 4}, variables, eqs, du)


def case_one_free():
    variables, eqs, du = source_state()
    body = op("*", op("*", ix(const(C12), "i"), s_of("i")), ix(const(R3), "r"))
    variables["wrj"] = state_var("wrj", ["n3", "n3"], "wrj[r,j] = sum_{i : j == floor((i-1)/4)+1} C[i] s[i] R[r]: r free (first), j pinned.")
    eqs.append({
        "lhs": d_lhs("wrj", ["r", "j"], {"r": {"from": "n3"}, "j": {"from": "n3"}}),
        "rhs": faq(["r", "j"], {"r": {"from": "n3"}, "j": {"from": "n3"}, "i": [1, 12]}, body,
                   filt=op("==", "j", block("i", 4))),
    })
    put2(du, "wrj", [[fold("+", [C12[i - 1] * 1.0 * R3[r - 1] for i in rng(1, 12) if blk(i, 4) == j])
                      for j in rng(1, 3)] for r in rng(1, 3)])
    variables["wjr"] = state_var("wjr", ["n3", "n3"], "wjr[j,r], the same with the pinned index first in output_idx.")
    eqs.append({
        "lhs": d_lhs("wjr", ["j", "r"], {"j": {"from": "n3"}, "r": {"from": "n3"}}),
        "rhs": faq(["j", "r"], {"j": {"from": "n3"}, "r": {"from": "n3"}, "i": [1, 12]}, body,
                   filt=op("==", "j", block("i", 4))),
    })
    put2(du, "wjr", [[fold("+", [C12[i - 1] * 1.0 * R3[r - 1] for i in rng(1, 12) if blk(i, 4) == j])
                      for r in rng(1, 3)] for j in rng(1, 3)])
    return ("One output index pinned, one left free, in both positions of `output_idx`.",
            {"n3": 3}, variables, eqs, du)


def case_out_of_range():
    variables, eqs, du = source_state()
    variables["h"] = state_var("h", ["n6"], "h[j] = sum_{i : j == i/2} C[i] s[i], i = 1..12: an odd i gives a non-integer e, which no cell admits.")
    eqs.append({
        "lhs": d_lhs("h", ["j"], {"j": {"from": "n6"}}),
        "rhs": faq(["j"], {"j": {"from": "n6"}, "i": [1, 12]},
                   op("*", ix(const(C12), "i"), s_of("i")),
                   filt=op("==", "j", op("/", "i", 2))),
    })
    put1(du, "h", [fold("+", [C12[i - 1] for i in rng(1, 12) if i / 2 == j]) for j in rng(1, 6)])
    variables["o"] = state_var("o", ["n5"], "o[j] = sum_{i : j == i - 3} C[i] s[i], i = 1..12, j = 1..5: e falls below the range for i <= 3 and above it for i >= 9.")
    eqs.append({
        "lhs": d_lhs("o", ["j"], {"j": {"from": "n5"}}),
        "rhs": faq(["j"], {"j": {"from": "n5"}, "i": [1, 12]},
                   op("*", ix(const(C12), "i"), s_of("i")),
                   filt=op("==", "j", op("-", "i", 3))),
    })
    put1(du, "o", [fold("+", [C12[i - 1] for i in rng(1, 12) if i - 3 == j]) for j in rng(1, 5)])
    return ("An `e` that is not an integer, and one that falls below and above the pinned index's range.",
            {"n5": 5, "n6": 6}, variables, eqs, du)


def case_scan_comparison():
    variables, eqs, du = source_state()
    body = op("*", ix(const(C12), "i"), s_of("i"))
    variables["v"] = state_var("v", ["n4", "n3"], "v[r,j] = sum_{i : j == floor((i-1)/4)+1, r <= i} C[i] s[i]: the second conjunct alone would be a reverse scan in r, but the node has an equality conjunct, so it folds ASCENDING.")
    eqs.append({
        "lhs": d_lhs("v", ["r", "j"], {"r": {"from": "n4"}, "j": {"from": "n3"}}),
        "rhs": faq(["r", "j"], {"r": {"from": "n4"}, "j": {"from": "n3"}, "i": [1, 12]}, body,
                   filt=op("and", op("==", "j", block("i", 4)), op("<=", "r", "i"))),
    })
    put2(du, "v", [[fold("+", [C12[i - 1] for i in rng(1, 12) if blk(i, 4) == j and r <= i])
                    for j in rng(1, 3)] for r in rng(1, 4)])
    variables["vf"] = state_var("vf", ["n4", "n3"], "vf[r,j]: the same with the forward comparison i <= r.")
    eqs.append({
        "lhs": d_lhs("vf", ["r", "j"], {"r": {"from": "n4"}, "j": {"from": "n3"}}),
        "rhs": faq(["r", "j"], {"r": {"from": "n4"}, "j": {"from": "n3"}, "i": [1, 12]}, body,
                   filt=op("and", op("<=", "i", op("*", 3, "r")), op("==", "j", block("i", 4)))),
    })
    put2(du, "vf", [[fold("+", [C12[i - 1] for i in rng(1, 12) if i <= 3 * r and blk(i, 4) == j])
                     for j in rng(1, 3)] for r in rng(1, 4)])
    return ("An equality conjunct beside a scan comparison on another output index: never a scan, folds ascending.",
            {"n3": 3, "n4": 4}, variables, eqs, du)


def case_pinned_twice():
    variables, eqs, du = source_state()
    variables["w"] = state_var("w", ["n4"], "w[j] = sum_{i : j == floor((i-1)/4)+1, j == floor(i/4)+1} C[i] s[i]: the first conjunct pins j, the second is an ordinary remaining conjunct (it admits i mod 4 != 0).")
    eqs.append({
        "lhs": d_lhs("w", ["j"], {"j": {"from": "n4"}}),
        "rhs": faq(["j"], {"j": {"from": "n4"}, "i": [1, 12]},
                   op("*", ix(const(C12), "i"), s_of("i")),
                   filt=op("and", op("==", "j", block("i", 4)),
                           op("==", "j", op("+", floordiv("i", 4), 1)))),
    })
    put1(du, "w", [fold("+", [C12[i - 1] for i in rng(1, 12)
                              if blk(i, 4) == j and math.floor(i / 4) + 1 == j]) for j in rng(1, 4)])
    return ("One output index pinned twice: the second equality is an ordinary remaining conjunct.",
            {"n4": 4}, variables, eqs, du)


def case_nested_rank0():
    variables, eqs, du = source_state()
    nested_ge = faq([], {"k": [1, 4]}, ix(const(G4), "k"), filt=op(">=", "k", "j"), reduce="+")
    variables["w"] = state_var("w", ["n3"], "w[j] = sum_{i : j == floor((i-1)/4)+1} C[i] s[i] N(j), N(j) = sum_{k >= j} G[k] a rank-0 faq nested in the body that reads the pinned j.")
    eqs.append({
        "lhs": d_lhs("w", ["j"], {"j": {"from": "n3"}}),
        "rhs": faq(["j"], {"j": {"from": "n3"}, "i": [1, 12]},
                   op("*", op("*", ix(const(C12), "i"), s_of("i")), nested_ge),
                   filt=op("==", "j", block("i", 4))),
    })
    nested = {j: fold("+", [G4[k - 1] for k in rng(1, 4) if k >= j]) for j in rng(1, 3)}
    put1(du, "w", [fold("+", [C12[i - 1] * 1.0 * nested[j] for i in rng(1, 12) if blk(i, 4) == j])
                   for j in rng(1, 3)])
    # The equality is inside the nested rank-0 node, on the ENCLOSING index:
    # the nested node has no output index, so the rule does not apply to it.
    nested_eq = faq([], {"k": [1, 12]}, op("*", ix(const(C12), "k"), s_of("k")),
                    filt=op("==", "i", block("k", 4)), reduce="+")
    variables["x"] = state_var("x", ["n4"], "x[i] = s[i] * sum_{k : i == floor((k-1)/4)+1} C[k] s[k], the equality inside a nested rank-0 faq on the enclosing index; cell 4 is empty.")
    eqs.append({
        "lhs": d_lhs("x", ["i"], {"i": {"from": "n4"}}),
        "rhs": faq(["i"], {"i": {"from": "n4"}}, op("*", s_of("i"), nested_eq)),
    })
    put1(du, "x", [1.0 * fold("+", [C12[k - 1] for k in rng(1, 12) if blk(k, 4) == i]) for i in rng(1, 4)])
    return ("A rank-0 `faq` nested in a scatter body (reading the pinned index), and an equality inside a nested rank-0 node (not a scatter).",
            {"n3": 3, "n4": 4}, variables, eqs, du)


def case_runtime_map():
    variables, eqs, du = source_state()
    variables["p"] = {"type": "parameter", "units": "1", "default": 2.0,
                      "description": "A run-time shift the scatter map reads."}
    variables["w"] = state_var("w", ["n5"], "w[j] = sum_{i : j == floor((i-1)/4) + p} C[i] s[i], p = 2: e reads a parameter, so the map cannot be built once; cells 1 and 5 are empty.")
    eqs.append({
        "lhs": d_lhs("w", ["j"], {"j": {"from": "n5"}}),
        "rhs": faq(["j"], {"j": {"from": "n5"}, "i": [1, 12]},
                   op("*", ix(const(C12), "i"), s_of("i")),
                   filt=op("==", "j", op("+", floordiv(op("-", "i", 1), 4), "p"))),
    })
    put1(du, "w", [fold("+", [C12[i - 1] for i in rng(1, 12) if math.floor((i - 1) / 4) + 2.0 == j])
                   for j in rng(1, 5)])
    variables["g"] = {"type": "unknown", "units": "1", "default": 1.0,
                      "description": "A scalar state held at 1 (D(g) = 0) that the second map reads."}
    eqs.append({"lhs": op("D", "g", wrt="t"), "rhs": 0.0})
    du["g"] = 0.0
    variables["y"] = state_var("y", ["n4"], "y[j] = sum_{i : j == floor((i-1)/4) + g} C[i] s[i], g = 1 a state: e reads a state.")
    eqs.append({
        "lhs": d_lhs("y", ["j"], {"j": {"from": "n4"}}),
        "rhs": faq(["j"], {"j": {"from": "n4"}, "i": [1, 12]},
                   op("*", ix(const(C12), "i"), s_of("i")),
                   filt=op("==", "j", op("+", floordiv(op("-", "i", 1), 4), "g"))),
    })
    put1(du, "y", [fold("+", [C12[i - 1] for i in rng(1, 12) if math.floor((i - 1) / 4) + 1.0 == j])
                   for j in rng(1, 4)])
    return ("An `e` that reads a parameter, and one that reads a state: the map is a run-time value.",
            {"n4": 4, "n5": 5}, variables, eqs, du)


def ragged_setup():
    variables, eqs, du = source_state()
    variables["rowLen"] = {"type": "unknown", "units": "1", "shape": ["rows"],
                           "description": "offsets: each row's length (6, 3, 0, 3)."}
    variables["rowMem"] = {"type": "unknown", "units": "1", "shape": ["rows", "maxLen"],
                           "description": "values: row r's members in positions 1..rowLen[r]; padding 0."}
    eqs.append({"lhs": "rowLen", "rhs": const(ROWLEN)})
    eqs.append({"lhs": "rowMem", "rhs": const(ROWS)})
    return variables, eqs, du


def case_ragged():
    variables, eqs, du = ragged_setup()
    member = ix("rowMem", "r", "k")
    body = op("*", ix(const(WMEM), member), ix("s", member))
    variables["pr"] = state_var("pr", ["rows", "n2"], "pr[r,j] = sum_{k in row r : j == floor((k-1)/3)+1} W[rowMem[r,k]] s[...]: r free and the ragged parent, e reads the POSITION k.")
    eqs.append({
        "lhs": d_lhs("pr", ["r", "j"], {"r": {"from": "rows"}, "j": {"from": "n2"}}),
        "rhs": faq(["r", "j"], {"r": {"from": "rows"}, "j": {"from": "n2"},
                                "k": {"from": "row_members", "of": ["r"]}}, body,
                   filt=op("==", "j", block("k", 3))),
    })
    put2(du, "pr", [[fold("+", [WMEM[ROWS[r - 1][k - 1] - 1] for k in rng(1, ROWLEN[r - 1]) if blk(k, 3) == j])
                     for j in rng(1, 2)] for r in rng(1, 4)])
    sets = {"rows": {"kind": "interval", "size": 4}, "maxLen": {"kind": "interval", "size": 6},
            "row_members": {"kind": "ragged", "of": ["rows"], "offsets": "rowLen", "values": "rowMem"},
            "n2": 2}
    return ("A ragged `from`/`of` range under a free parent: `e` reads the position symbol.",
            sets, variables, eqs, du)


def case_ragged_contracted_parent():
    variables, eqs, du = ragged_setup()
    member = ix("rowMem", "r", "k")
    body = op("*", ix(const(WMEM), member), ix("s", member))
    variables["pm"] = state_var("pm", ["n5"], "pm[j] = sum_{r, k in row r : j == floor((rowMem[r,k]-1)/3)+1} W[...] s[...]: r contracted, e reads the member gathered at position k; each cell's terms come from one row.")
    eqs.append({
        "lhs": d_lhs("pm", ["j"], {"j": {"from": "n5"}}),
        "rhs": faq(["j"], {"j": {"from": "n5"}, "r": {"from": "rows"},
                           "k": {"from": "row_members", "of": ["r"]}}, body,
                   filt=op("==", "j", block(member, 3))),
    })
    put1(du, "pm", [fold("+", [WMEM[ROWS[r - 1][k - 1] - 1] for r in rng(1, 4) for k in rng(1, ROWLEN[r - 1])
                               if blk(ROWS[r - 1][k - 1], 3) == j]) for j in rng(1, 5)])
    sets = {"rows": {"kind": "interval", "size": 4}, "maxLen": {"kind": "interval", "size": 6},
            "row_members": {"kind": "ragged", "of": ["rows"], "offsets": "rowLen", "values": "rowMem"},
            "n5": 5}
    return ("A ragged `from`/`of` range whose parent is contracted: `e` reads the member gathered at the position.",
            sets, variables, eqs, du)


def case_derived_sum():
    """The spelling an EarthSciASTDiff product document uses (issue #613):
    a whole-array derivative `D(v) = F1 + F2` whose operands are
    equality-filtered `faq`s over INTEGER output bounds `[1, n]` (not index
    sets), one output index per axis named `_j1`, `_j2`."""
    variables, eqs, du = source_state()
    wd = lambda v: op("D", v, wrt="t")
    # v: the band transpose of a tridiagonal, (i - 1) == _j1 plus (i + 1) == _j1.
    variables["v"] = state_var("v", ["n8"], "D(v) = F1 + F2, F1[_j1] = sum_{i in 2..7 : i - 1 == _j1} C[i] s[i], F2[_j1] = sum_{i in 2..7 : i + 1 == _j1} -0.5 C[i] s[i].")
    f1 = faq(["_j1"], {"_j1": [1, 8], "i": [2, 7]}, op("*", ix(const(C12), "i"), s_of("i")),
             filt=op("==", op("-", "i", 1), "_j1"))
    f2 = faq(["_j1"], {"_j1": [1, 8], "i": [2, 7]}, op("*", -0.5, op("*", ix(const(C12), "i"), s_of("i"))),
             filt=op("==", op("+", "i", 1), "_j1"))
    eqs.append({"lhs": wd("v"), "rhs": op("+", f1, f2)})
    put1(du, "v", [
        fold("+", [C12[i - 1] for i in rng(2, 7) if i - 1 == j]) +
        fold("+", [-0.5 * C12[i - 1] for i in rng(2, 7) if i + 1 == j])
        for j in rng(1, 8)
    ])
    # g: an `ifelse` guard repeating the filter, where the reduced name j
    # appears only in the filter and the guard; each cell's terms vary along i.
    variables["g"] = state_var("g", ["n5"], "D(g) = F1 + F2, F1[_j1] = sum_{i, j : j <= i and j == _j1} ifelse(same, C[i] s[i], 0), F2[_j1] = sum_{i : i == _j1} 2 s[i].")
    guard = op("and", op("<=", "j", "i"), op("==", "j", "_j1"))
    g1 = faq(["_j1"], {"_j1": [1, 5], "i": [1, 5], "j": [1, 5]},
             op("ifelse", guard, op("*", ix(const(C12), "i"), s_of("i")), 0.0), filt=guard)
    g2 = faq(["_j1"], {"_j1": [1, 5], "i": [1, 5]}, op("*", 2, s_of("i")), filt=op("==", "i", "_j1"))
    eqs.append({"lhs": wd("g"), "rhs": op("+", g1, g2)})
    put1(du, "g", [
        fold("+", [C12[i - 1] for i in rng(1, 5) if j <= i]) +
        fold("+", [2.0 for i in rng(1, 5) if i == j])
        for j in rng(1, 5)
    ])
    # q: a 2-D output, both indices pinned, plus a constant pin `1 == _j1`.
    T34 = [C12[0:4], C12[4:8], C12[8:12]]
    variables["q"] = state_var("q", ["n3", "n4"], "D(q) = Q1 + Q2, Q1[_j1,_j2] = sum_{gi, gk : gi == _j1 and gk == _j2} T[gi,gk] s[gk], Q2[_j1,_j2] = sum_{i : 1 == _j1 and i + 1 == _j2} C[i] s[i].")
    q1 = faq(["_j1", "_j2"], {"_j1": [1, 3], "_j2": [1, 4], "gi": [1, 3], "gk": [1, 4]},
             op("*", ix(const(T34), "gi", "gk"), s_of("gk")),
             filt=op("and", op("==", "gi", "_j1"), op("==", "gk", "_j2")))
    q2 = faq(["_j1", "_j2"], {"_j1": [1, 3], "_j2": [1, 4], "i": [1, 4]},
             op("*", ix(const(C12), "i"), s_of("i")),
             filt=op("and", op("==", 1, "_j1"), op("==", op("+", "i", 1), "_j2")))
    eqs.append({"lhs": wd("q"), "rhs": op("+", q1, q2)})
    put2(du, "q", [[
        fold("+", [T34[gi - 1][gk - 1] for gk in rng(1, 4) for gi in rng(1, 3) if gi == a and gk == b]) +
        fold("+", [C12[i - 1] for i in rng(1, 4) if a == 1 and i + 1 == b])
        for b in rng(1, 4)] for a in rng(1, 3)])
    return ("The EarthSciASTDiff product-document spelling: whole-array sums of equality-filtered `faq`s over integer output bounds, an `ifelse` guard repeating the filter, a 2-D output and a constant pin.",
            {"n3": 3, "n4": 4, "n5": 5, "n8": 8}, variables, eqs, du)


CASES = {
    "plus_cancelling": case_plus_cancelling,
    "max_min_nan": case_max_min_nan,
    "two_pinned_2d": case_two_pinned_2d,
    "one_free": case_one_free,
    "out_of_range": case_out_of_range,
    "scan_comparison": case_scan_comparison,
    "pinned_twice": case_pinned_twice,
    "nested_rank0": case_nested_rank0,
    "runtime_map": case_runtime_map,
    "ragged": case_ragged,
    "ragged_contracted_parent": case_ragged_contracted_parent,
    "derived_sum": case_derived_sum,
}


#: Per fixture, the bindings that do not run it today and why. Each binding's
#: test asserts that an excluded fixture still FAILS there (a refusal, an
#: error or a wrong value), so a fix makes the stale exclusion red.
EXCLUSIONS = {
    "ragged": {
        "python": "the NumPy evaluator refuses a filter over a ragged contracted range",
    },
    "ragged_contracted_parent": {
        "julia": "E_TREEWALK_UNBOUND_LOOP_VAR on a ragged range whose parent is a contracted index, under both compilers",
        "rust": "the interpreter silently returns 0 for pm[2..4] (only pm[1] is right); native refuses (ragged bound's parent is not an output index)",
        "python": "the NumPy evaluator refuses a filter over a ragged contracted range",
    },
}


def golden_value(x: float):
    if math.isnan(x):
        return "NaN"
    if math.isinf(x):
        return "Infinity" if x > 0 else "-Infinity"
    return x


def build(cid):
    desc, sets, variables, eqs, du = CASES[cid]()
    index_sets = {"ns": {"kind": "interval", "size": NS}}
    for k, v in sets.items():
        index_sets[k] = v if isinstance(v, dict) else {"kind": "interval", "size": v}
    doc = {
        "esm": "1.2.0",
        "metadata": {
            "name": f"faq_equality_scatter_{cid}",
            "description": desc + " Generated by generate.py beside this file; esm-spec §4.3.1, one-pass scatter for an equality filter.",
            "authors": ["EarthSciML Authors and Contributors"],
            "tags": ["native", "conformance", "faq", "equality-scatter"],
        },
        "index_sets": dict(sorted(index_sets.items())),
        "models": {MODEL: {"variables": variables, "equations": eqs}},
    }
    golden = {
        "fixture": cid,
        "model": MODEL,
        "t": 0.0,
        "state": "every state at its document default",
        "reference": "generate.py's naive loop (ascending contracted indices, full filter per point)",
        "du": {k: golden_value(v) for k, v in sorted(du.items())},
    }
    return doc, golden


def dumps(obj):
    return json.dumps(obj, indent=1, ensure_ascii=False) + "\n"


def manifest():
    return {
        "category": "faq_equality_scatter",
        "version": "1.0",
        "description": "Right-hand sides whose faq has an equality conjunct on an output index (esm-spec §4.3.1, one-pass scatter). Each binding builds every fixture under `interpreter` and `native`, evaluates the right-hand side once at the document's initial state with default parameters at t = 0, and requires both to equal golden/<id>.json BIT FOR BIT. The goldens come from generate.py's naive Python loop, outside every binding.",
        "model": MODEL,
        "t": 0.0,
        "tolerance": {"rel": 0.0, "abs": 0.0},
        "excluded": "per fixture, binding -> why it does not run the fixture today; that binding's test asserts the fixture still fails there, so a fixed exclusion turns red until it is removed",
        "golden_encoding": "du maps element names (`w[2]`, `w[1,3]`, `g`) under the model to a number, or to the string NaN, Infinity or -Infinity; -0.0 is written as -0.0 and compared by sign.",
        "fixtures": [
            {"id": cid, "path": f"fixtures/{cid}.esm", "golden": f"golden/{cid}.json",
             "excluded": EXCLUSIONS.get(cid, {})} for cid in CASES
        ],
    }


def outputs():
    out = {HERE / "manifest.json": dumps(manifest())}
    for cid in CASES:
        doc, golden = build(cid)
        out[HERE / "fixtures" / f"{cid}.esm"] = dumps(doc)
        out[HERE / "golden" / f"{cid}.json"] = dumps(golden)
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--check", action="store_true", help="fail if a committed file differs")
    args = ap.parse_args(argv)
    stale = []
    for path, text in outputs().items():
        if args.check:
            if not path.exists() or path.read_text() != text:
                stale.append(path)
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
    if stale:
        for p in stale:
            print(f"stale: {p.relative_to(HERE)}", file=sys.stderr)
        print("run generate.py to regenerate", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
