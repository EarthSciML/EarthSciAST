#!/usr/bin/env python3
"""Write scenarios.json and the two fixture documents of the
relational_templates tier. The goldens are minted separately from the Julia
interpreter (scripts/run-inline-tests-conformance.py --write-golden)."""

import copy
import json
from pathlib import Path

TIER = Path(__file__).resolve().parent
ROOT = TIER.parents[2]
LIB_REF = "esm:std/relational.esm"

NAN, INF, NINF = "NaN", "Inf", "-Inf"
# (name, op, candidate values, expected index, the op's index where it differs, note)
S = [
    ("distinct_minimum", "argmin", [3.0, 1.0, 2.0], 2, None, "one smallest candidate"),
    ("first_is_extreme", "argmin", [0.5, 2.0, 3.0], 1, None, "the first candidate"),
    ("last_is_extreme", "argmin", [4.0, 3.0, 2.0, 1.0], 4, None, "the last candidate"),
    ("negative_values", "argmin", [-1.0, -3.0, -2.0], 2, None, "negative candidates"),
    ("tie_two", "argmin", [2.0, 1.0, 1.0], 2, None, "a tie goes to the smaller index"),
    ("tie_first_last", "argmin", [1.0, 2.0, 1.0], 1, None, "a tie between the first and last candidates"),
    ("all_equal", "argmin", [5.0, 5.0, 5.0], 1, None, "every candidate equal"),
    ("single_candidate", "argmin", [7.0], 1, None, "one candidate"),
    ("signed_zero_tie", "argmin", [0.0, -0.0], 1, None, "-0.0 == 0.0, so a tie"),
    ("signed_zero_tie_reversed", "argmin", [-0.0, 0.0], 1, None, "-0.0 == 0.0, so a tie"),
    ("subnormal_tie", "argmin", [5e-324, 1.0, 5e-324], 1, None, "equal subnormal candidates"),
    (
        "equidistant_generators",
        "argmin",
        [2.25, 0.25, 0.25],
        2,
        None,
        "the nearest_generator tie: point 1.5 to generators 0, 1, 2",
    ),
    ("pos_inf_candidate", "argmin", [INF, 1.0], 2, None, "+Inf is never the minimum of finite candidates"),
    ("all_pos_inf", "argmin", [INF, INF], 1, None, "every candidate +Inf: a tie"),
    ("neg_inf_tie", "argmin", [1.0, NINF, NINF], 2, None, "-Inf tie"),
    ("nan_first", "argmin", [NAN, 0.0, 1.0], 1, None, "a NaN candidate wins at its first occurrence"),
    ("nan_middle", "argmin", [3.0, NAN, 1.0, NAN], 2, 3, "first NaN, not the smallest number"),
    ("nan_last", "argmin", [1.0, 2.0, NAN], 3, 1, "a NaN after the minimum"),
    ("nan_and_neg_inf", "argmin", [NINF, NAN], 2, 1, "NaN beats -Inf"),
    ("all_nan", "argmin", [NAN, NAN], 1, None, "every candidate NaN"),
    ("max_distinct", "argmax", [3.0, 1.0, 2.0], 1, None, "one largest candidate"),
    ("max_last", "argmax", [1.0, 2.0, 3.0, 4.0], 4, None, "the last candidate"),
    ("max_tie", "argmax", [1.0, 4.0, 4.0], 2, None, "a tie goes to the smaller index"),
    (
        "max_farthest_tie",
        "argmax",
        [1.0, 0.0, 1.0],
        1,
        None,
        "the farthest-generator tie (point 1.0 to generators 0, 1, 2)",
    ),
    ("max_all_equal", "argmax", [-2.0, -2.0], 1, None, "every candidate equal"),
    ("max_single_candidate", "argmax", [-7.0], 1, None, "one candidate"),
    ("max_signed_zero_tie", "argmax", [-0.0, 0.0], 1, None, "-0.0 == 0.0, so a tie"),
    ("max_pos_inf_tie", "argmax", [1.0, INF, INF], 2, None, "+Inf tie"),
    ("max_all_neg_inf", "argmax", [NINF, NINF, NINF], 1, None, "every candidate -Inf: a tie"),
    ("max_nan_first", "argmax", [NAN, 5.0], 1, None, "a NaN candidate wins at its first occurrence"),
    ("max_nan_middle", "argmax", [1.0, 9.0, NAN, 2.0, NAN], 3, 2, "first NaN, not the largest number"),
    ("max_nan_and_pos_inf", "argmax", [INF, NAN], 2, 1, "NaN beats +Inf"),
]


def dump(obj, path):
    with open(path, "w") as fh:
        json.dump(obj, fh, indent=2, ensure_ascii=False)
        fh.write("\n")


def num_den(v):
    """A candidate as num / den, so a non-finite one fits in a `const`."""
    return {NAN: (0.0, 0.0), INF: (1.0, 0.0), NINF: (-1.0, 0.0)}.get(v, (v, 1.0))


def const(v):
    return {"op": "const", "args": [], "value": v}


def rename(e, a, b):
    if isinstance(e, str):
        return b if e == a else e
    if isinstance(e, list):
        return [rename(x, a, b) for x in e]
    if isinstance(e, dict):
        return {k: rename(v, a, b) for k, v in e.items()}
    return e


def scenarios():
    out = []
    for name, op, vals, exp, op_exp, note in S:
        e = {"name": name, "op": op, "values": vals, "expected": exp}
        if op_exp is not None:
            e["op_expected"] = op_exp
        e["description"] = note
        out.append(e)
    return {
        "description": (
            "Scenarios for the `argmin` / `argmax` templates of lib/relational.esm. `values` are the "
            'candidate values in index order ("NaN", "Inf" and "-Inf" stand for the non-finite values '
            "JSON cannot write); `expected` is the 1-based index the template returns: the smallest "
            "index on a tie, the first NaN index when any candidate is NaN. `op_expected`, where "
            "present, is what the `argmin` / `argmax` operator form removed at esm 2.0.0 returned on the "
            "same candidates: it ignored a NaN candidate unless it was the first one, so it differs "
            "from the template only when a NaN comes after the first candidate."
        ),
        "scenarios": out,
    }


def argmin_document():
    variables = {
        "s": {
            "type": "unknown",
            "units": "1",
            "default": 0.0,
            "description": "Trivial state, so the document has something to integrate.",
        }
    }
    equations = [{"lhs": {"op": "D", "args": ["s"], "wrt": "t"}, "rhs": 0.0}]
    asserts = []
    for name, op, vals, exp, _, note in S:
        nums, dens = zip(*(num_den(v) for v in vals))
        sym = f"k_{op}_1"
        f = {
            "op": "/",
            "args": [
                {"op": "index", "args": [const(list(nums)), sym]},
                {"op": "index", "args": [const(list(dens)), sym]},
            ],
        }
        variables[f"r_{name}"] = {
            "type": "unknown",
            "units": "1",
            "description": f"`{op}` template on scenario `{name}` of scenarios.json: {note}.",
        }
        equations.append(
            {
                "lhs": f"r_{name}",
                "rhs": {
                    "op": "apply_expression_template",
                    "args": [],
                    "name": op,
                    "bindings": {"f": f, "n": len(vals)},
                },
            }
        )
        asserts.append({"variable": f"r_{name}", "time": 0.0, "expected": float(exp)})
    return {
        "esm": "1.1.0",
        "metadata": {
            "name": "relational_argmin_template",
            "description": (
                "The `argmin` and `argmax` templates of lib/relational.esm applied to every scenario "
                "of tests/conformance/relational_templates/scenarios.json. Candidate k of a scenario "
                "is `num[k] / den[k]` over two `const` arrays, so a NaN (0/0), +Inf (1/0) and -Inf "
                "(-1/0) candidate can be written in JSON; a finite candidate is `v / 1`, which is `v` "
                "exactly. Each scenario is one algebraic unknown `r_<scenario>`; the inline test "
                "asserts its 1-based index exactly (tolerance 0): the smallest index on a tie, the "
                "first NaN index when a candidate is NaN. Run by the `relational_templates` "
                "inline-test tier; written by generate.py."
            ),
            "authors": ["EarthSciML"],
            "tags": [
                "relational",
                "argmin",
                "argmax",
                "arg-witness",
                "expression-templates",
                "standard-library",
            ],
        },
        "models": {
            "relational_argmin_template": {
                "expression_template_imports": [{"ref": LIB_REF}],
                "variables": variables,
                "equations": equations,
                "tolerance": {"abs": 0.0, "rel": 0.0},
                "tests": [
                    {
                        "id": "relational_argmin_template_t0",
                        "description": "Every scenario at t = 0.",
                        "time_span": {"start": 0.0, "end": 1.0},
                        "assertions": asserts,
                    }
                ],
            }
        },
    }


def nearest_generator_document():
    """The value_invention_geometry nearest-generator document with its
    arg-witness written as the `argmin` template."""
    src = ROOT / "tests/conformance/value_invention_geometry/fixtures/nearest_generator_ode.esm"
    d = copy.deepcopy(json.loads(src.read_text()))
    d["metadata"]["name"] = "RelationalNearestGeneratorTemplateODE"
    d["metadata"]["description"] = (
        "The value_invention_geometry document nearest_generator_ode.esm with its arg-witness "
        "written as the `argmin` template of lib/relational.esm: the squared distance over the "
        "template's loop symbol `k_argmin_1`, with n = 3 generators. Point 3 is exactly 0.25 "
        "(squared) from generators 2 and 3 and the template takes the smaller index, so "
        "assign = [1, 2, 2, 3], and w = [0, 1, 1, 2] at t = 1. Written by generate.py."
    )
    m = d["models"].pop("NearestGeneratorODE")
    for eq in m["equations"]:
        rhs = eq["rhs"]
        if isinstance(rhs, dict) and isinstance(rhs.get("expr"), dict) and rhs["expr"].get("op") == "argmin":
            am = rhs["expr"]
            n = d["index_sets"][am["ranges"][am["arg"]]["from"]]["size"]
            rhs["expr"] = {
                "op": "apply_expression_template",
                "args": [],
                "name": "argmin",
                "bindings": {"f": rename(am["expr"], am["arg"], "k_argmin_1"), "n": n},
            }
            eq["_comment"] = (
                "assign[i] = the argmin template over the squared distance from point i to generator k_argmin_1."
            )
    m = {"expression_template_imports": [{"ref": LIB_REF}], **m}
    m["tests"][0]["id"] = "nearest_generator_template_ode"
    d["models"]["NearestGeneratorTemplateODE"] = m
    return d


if __name__ == "__main__":
    dump(scenarios(), TIER / "scenarios.json")
    dump(argmin_document(), TIER / "fixtures" / "argmin_template.esm")
    dump(nearest_generator_document(), TIER / "fixtures" / "nearest_generator_template_ode.esm")
