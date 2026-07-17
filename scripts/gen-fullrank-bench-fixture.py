#!/usr/bin/env python3
"""Generate tests/bench/transport_3axis_7cubed_fullrank.esm.

Pointwise 7x7x7 transport whose per-axis derivative lowers (via a match rule)
to a makearray with FIVE full-rank boundary-class regions, every region value an
apply_expression_template reference. Unlike transport_3axis_7cubed.esm (whose
one-sided faces are rank-2 aggregates -> permanent per-cell fallback), every
region body here is a rank-3 aggregate, so the affine box processor fires and
the branch keys form the genuine 5x5x5 cross-product the RFC's compile-once
tier collapses to 5+5+5.
"""
import json, sys

N = 7
AXES = [("x", 0), ("y", 1), ("z", 2)]
LOOPS = ["i", "j", "k"]


def idx(f, offs, pin=None):
    """index(f, i+offs on the axis dim, j, k) with optional pinned int."""
    args = [f]
    for d, l in enumerate(LOOPS):
        if pin is not None and d == pin[0]:
            args.append(pin[1])
        elif offs is not None and d == offs[0] and offs[1] != 0:
            op = "+" if offs[1] > 0 else "-"
            args.append({"op": op, "args": [l, abs(offs[1])]})
        else:
            args.append(l)
    return {"op": "index", "args": args}


def times(c, e):
    return {"op": "*", "args": [c, e]}


def sub(a, b):
    return {"op": "-", "args": [a, b]}


def add(*a):
    return {"op": "+", "args": list(a)}


def body(axis_d, cls):
    """Rank-3 aggregate body for one axis / boundary class."""
    f = "f"
    if cls == "int":
        rng = [3, N - 2]
        # 4th-order-ish centered difference + a monotone-flavoured min/max term:
        # (2/3)(f[i+1]-f[i-1]) - (1/12)(f[i+2]-f[i-2])
        #   + 0.05*(min(f[i+1],f[i]) - max(f[i-1],f[i]))
        #   + 0.025*(min(f[i+2],f[i+1]) - max(f[i-2],f[i-1]))
        e = add(
            times(0.6666666666666666, sub(idx(f, (axis_d, 1)), idx(f, (axis_d, -1)))),
            times(-0.08333333333333333, sub(idx(f, (axis_d, 2)), idx(f, (axis_d, -2)))),
            times(0.05, sub({"op": "min", "args": [idx(f, (axis_d, 1)), idx(f, None)]},
                            {"op": "max", "args": [idx(f, (axis_d, -1)), idx(f, None)]})),
            times(0.025, sub({"op": "min", "args": [idx(f, (axis_d, 2)), idx(f, (axis_d, 1))]},
                             {"op": "max", "args": [idx(f, (axis_d, -2)), idx(f, (axis_d, -1))]})),
        )
    elif cls == "c1":
        rng = [1, 1]
        e = sub(times(1.5, sub(idx(f, None, (axis_d, 2)), idx(f, None, (axis_d, 1)))),
                times(0.5, sub(idx(f, None, (axis_d, 3)), idx(f, None, (axis_d, 2)))))
    elif cls == "c2":
        rng = [2, 2]
        e = times(0.5, sub(idx(f, None, (axis_d, 3)), idx(f, None, (axis_d, 1))))
    elif cls == "c6":
        rng = [N - 1, N - 1]
        e = times(0.5, sub(idx(f, None, (axis_d, N)), idx(f, None, (axis_d, N - 2))))
    else:  # c7
        rng = [N, N]
        e = sub(times(1.5, sub(idx(f, None, (axis_d, N)), idx(f, None, (axis_d, N - 1)))),
                times(0.5, sub(idx(f, None, (axis_d, N - 1)), idx(f, None, (axis_d, N - 2)))))
    ranges = {}
    for d, l in enumerate(LOOPS):
        ranges[l] = rng if d == axis_d else {"from": ["x", "y", "z"][d]}
    return {"op": "aggregate", "output_idx": list(LOOPS), "args": [f],
            "ranges": ranges, "expr": e}


templates = {}
CLASSES = ["int", "c1", "c2", "c6", "c7"]
REGION = {"int": [3, N - 2], "c1": [1, 1], "c2": [2, 2],
          "c6": [N - 1, N - 1], "c7": [N, N]}
for axis, d in AXES:
    for cls in CLASSES:
        templates[f"s{axis}_{cls}"] = {"params": ["f"], "body": body(d, cls)}
    regions, values = [], []
    for cls in CLASSES:
        reg = []
        for dd in range(3):
            reg.append(REGION[cls] if dd == d else [1, N])
        regions.append(reg)
        values.append({"op": "apply_expression_template", "args": [],
                       "name": f"s{axis}_{cls}", "bindings": {"f": "f"}})
    templates[f"D{axis}"] = {
        "params": ["f"],
        "match": {"op": "D", "args": ["f"], "wrt": axis},
        "body": {"op": "makearray", "args": [], "regions": regions, "values": values},
    }

doc = {
    "esm": "0.9.0",
    "metadata": {
        "name": "transport_3axis_7cubed_fullrank",
        "description": (
            "RFC out-of-line-expression-templates compile-once measurement fixture. "
            "A 7x7x7 single-tracer transport, rhs -(Dx(q)+Dy(q)+Dz(q)); each spatial "
            "derivative lowers by a match rule to a per-axis makearray with FIVE "
            "full-rank boundary-class regions (two one-sided faces, two near-face "
            "centered classes, a wide-stencil interior), every region value an "
            "apply_expression_template reference to a shared per-class stencil "
            "template. All region bodies are rank-3 aggregates, so the affine box "
            "processor fires: fused (expanded) builds compile one spine per "
            "(x-class, y-class, z-class) = 5*5*5 = 125 branch keys, while the "
            "compile-once tier compiles 5+5+5 = 15 body variants plus 125 tiny "
            "parent spines and calls the bodies as sub-kernels."
        ),
    },
    "index_sets": {
        "x": {"kind": "interval", "size": N},
        "y": {"kind": "interval", "size": N},
        "z": {"kind": "interval", "size": N},
    },
    "models": {
        "Transport": {
            "expression_templates": templates,
            "variables": {
                "q": {"type": "state", "units": "1",
                      "shape": ["x", "y", "z"], "default": 1.5},
            },
            "equations": [
                {"lhs": {"op": "D", "args": ["q"], "wrt": "t"},
                 "rhs": {"op": "-", "args": [
                     {"op": "+", "args": [
                         {"op": "D", "args": ["q"], "wrt": "x"},
                         {"op": "D", "args": ["q"], "wrt": "y"},
                         {"op": "D", "args": ["q"], "wrt": "z"}]}]}},
            ],
        }
    },
}

out = sys.argv[1]
with open(out, "w") as fh:
    json.dump(doc, fh, indent=1)
    fh.write("\n")
print("wrote", out)
