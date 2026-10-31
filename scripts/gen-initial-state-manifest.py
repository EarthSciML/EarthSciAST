#!/usr/bin/env python3
"""Write tests/conformance/initial_state/manifest.json.

    python3 scripts/gen-initial-state-manifest.py           # write it
    python3 scripts/gen-initial-state-manifest.py --check   # diff only

The case table below is the source of truth for each case's document, `p` and
`u0`. The expected values are not: this script reads every `ic` equation, every
initialization equation and every declared default from the referenced
fixture, and evaluates them in binary64 in the operation order the document
writes, so a fixture edit shows up as a stale manifest under --check. See
CONFORMANCE_SPEC.md §5.53.

The evaluator covers what the referenced fixtures use (`+ - * /`, `cos`, `!=`,
and a one-index `faq` over an explicit range or an index set) and refuses
anything else, rather than guess.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONFORMANCE = os.path.join(ROOT, "tests", "conformance")
MANIFEST = os.path.join(CONFORMANCE, "initial_state", "manifest.json")

SCALAR_IC = "scalar_ic/fixtures/scalar_ic.esm"
ARRAY_MODEL = "scalar_ic/fixtures/scalar_ic_in_array_model.esm"
INIT_EQ = "scalar_ic/fixtures/faq_initialization_equation.esm"
COORD_IC = "pde_inline_ic_param_override/fixtures/ic_param_override.esm"

CASES = [
    {
        "id": "scalar_ic_defaults",
        "fixture": SCALAR_IC,
        "p": {},
        "u0": {},
        "note": "each state seeded by its own `ic` (u = 3, q = 1.5 + 2*0.25, w = 2*A with A at its default 2, y = 0); z has no `ic` and keeps its declared default 7",
    },
    {
        "id": "scalar_ic_parameter",
        "fixture": SCALAR_IC,
        "p": {"A": 10.0},
        "u0": {},
        "note": "the Problem's parameter A = 10 binds in the `ic` scope (esm-spec 6.6.5): w = 2*10",
    },
    {
        "id": "scalar_ic_u0_override",
        "fixture": SCALAR_IC,
        "p": {},
        "u0": {"u": 9.0},
        "note": "the Problem's u0 entry beats the `ic` equation for u only",
    },
    {
        "id": "array_model_defaults",
        "fixture": ARRAY_MODEL,
        "p": {},
        "u0": {},
        "note": "the array `ic` broadcasts 1.5 over every cell; the 0-D `ic` gives s = 2*B with B at its default 3",
    },
    {
        "id": "array_model_parameter",
        "fixture": ARRAY_MODEL,
        "p": {"B": 10.0},
        "u0": {},
        "note": "B = 10 reaches the 0-D `ic` in the array runtime",
    },
    {
        "id": "initialization_equation_defaults",
        "fixture": INIT_EQ,
        "p": {},
        "u0": {},
        "note": "initialization equations (esm-spec 6.2): u = A*i + B; w = 10*i over cells 2..4, 0 at the filtered-out cell 3, and the declared default 9 outside the range; y keeps its default",
    },
    {
        "id": "initialization_equation_parameter",
        "fixture": INIT_EQ,
        "p": {"A": 1.0},
        "u0": {},
        "note": "A = 1 reaches the initialization equation: u = i + 3",
    },
    {
        "id": "initialization_equation_u0_override",
        "fixture": INIT_EQ,
        "p": {},
        "u0": {"u[2]": 7.0},
        "note": "a u0 entry for one cell beats the initialization equation for that cell only",
    },
    {
        "id": "coordinate_ic_defaults",
        "fixture": COORD_IC,
        "p": {},
        "u0": {},
        "note": "coordinate-expression `ic`s (esm-spec 11.4.1): u = A*cos(pi*(i - 1/2)/5) with A at its default 1, v = cos(pi*(i - 1/2)/5)",
    },
    {
        "id": "coordinate_ic_parameter",
        "fixture": COORD_IC,
        "p": {"A": 2.0},
        "u0": {},
        "note": "A = 2 binds in the coordinate-expression `ic` of u; v is parameter-free",
    },
    {
        "id": "coordinate_ic_parameter_zero",
        "fixture": COORD_IC,
        "p": {"A": 0.0},
        "u0": {},
        "note": "A = 0: u is identically zero",
    },
]

HEADER = {
    "category": "initial_state",
    "version": "1.0",
    "description": "Cross-binding conformance for the public initial-state accessor (API_SPEC 5.8 `initial_state`, CONFORMANCE_SPEC 5.53): the state a Problem integrates from, one value per state element keyed by its flattened name, built as a solve builds it. Per element the first of: the Problem's `u0` entry, an initialization equation (esm-spec 6.2), an `ic` equation or field initial condition (11.4, 11.4.1), the declared `default`; the Problem's `p` (else the parameter defaults) bound in every initial condition's scope (6.6.5). Every fixture is REFERENCED from another category, where its inline tests pin the same values at t = 0 through a solve. The expected values are the documents' own formulas, evaluated in binary64 in the operation order the documents write, by scripts/gen-initial-state-manifest.py.",
    "bindings_required": ["rust"],
    "bindings_pending": {
        "julia": "no exported accessor: the seeded initial state is the `prob.u0` field (an extension seam, not stable API), indexed through `prob.var_map`",
        "python": "no accessor: `prob.u0` is the caller's override dict, and the built state is reachable only as `init(prob).u` before the first step (SciPy required; refused for the segmented engines)",
    },
    "scope_excluded": {
        "go": "parse and validate only; no simulator",
        "typescript": "no simulator",
    },
    "tolerances": {"rtol": 1e-14, "atol": 1e-15},
}


def fold(op, values):
    acc = values[0]
    for v in values[1:]:
        if op == "+":
            acc = acc + v
        elif op == "*":
            acc = acc * v
        elif op == "-":
            acc = acc - v
        elif op == "/":
            acc = acc / v
    return acc


def evaluate(expr, env, sizes):
    """One value, or a dict {cell: value} for a `faq` (1-based cells)."""
    if isinstance(expr, bool):
        raise ValueError(f"unexpected boolean literal {expr!r}")
    if isinstance(expr, (int, float)):
        return float(expr)
    if isinstance(expr, str):
        return env[expr]
    op = expr["op"]
    if op == "faq":
        (idx,) = expr["output_idx"]
        if expr.get("args") or set(expr["ranges"]) != {idx}:
            raise ValueError(f"unsupported faq shape: {json.dumps(expr)}")
        rng = expr["ranges"][idx]
        lo, hi = (1, sizes[rng["from"]]) if isinstance(rng, dict) else rng
        out = {}
        for i in range(lo, hi + 1):
            scope = dict(env, **{idx: float(i)})
            if "filter" in expr and not evaluate(expr["filter"], scope, sizes):
                # A filtered-out cell inside the range is written as zero.
                out[i] = 0.0
                continue
            out[i] = evaluate(expr["expr"], scope, sizes)
        return out
    args = [evaluate(a, env, sizes) for a in expr["args"]]
    if op == "cos":
        (x,) = args
        return {i: math.cos(v) for i, v in x.items()} if isinstance(x, dict) else math.cos(x)
    if op == "!=":
        return args[0] != args[1]
    if op not in ("+", "-", "*", "/"):
        raise ValueError(f"unsupported op {op!r}")
    if len(args) < 2:
        raise ValueError(f"unsupported unary {op!r}")
    cells = next((a for a in args if isinstance(a, dict)), None)
    if cells is None:
        return fold(op, args)
    return {i: fold(op, [a[i] if isinstance(a, dict) else a for a in args]) for i in cells}


def expected(case):
    with open(os.path.join(CONFORMANCE, case["fixture"])) as f:
        doc = json.load(f)
    sizes = {name: s["size"] for name, s in doc.get("index_sets", {}).items()}
    ((model_name, model),) = doc["models"].items()
    variables = model["variables"]
    env = {n: float(v["default"]) for n, v in variables.items() if v["type"] == "parameter"}
    env.update(case["p"])

    def cells(name):
        shape = variables[name].get("shape", [])
        if not shape:
            return [None]
        (dim,) = shape
        return list(range(1, sizes[dim] + 1))

    states = [n for n, v in variables.items() if v["type"] == "unknown"]
    # Lowest priority first: the declared default, then an `ic`, then an
    # initialization equation, then the Problem's `u0`.
    state = {}
    for name in states:
        for c in cells(name):
            state[(name, c)] = variables[name].get("default")
    for eq in model.get("equations", []):
        lhs = eq["lhs"]
        if isinstance(lhs, dict) and lhs.get("op") == "ic":
            (name,) = lhs["args"]
            value = evaluate(eq["rhs"], env, sizes)
            for c in cells(name):
                state[(name, c)] = value[c] if isinstance(value, dict) else value
    for eq in model.get("initialization_equations", []) or []:
        name = eq["lhs"]
        value = evaluate(eq["rhs"], env, sizes)
        for c, v in value.items() if isinstance(value, dict) else [(None, value)]:
            state[(name, c)] = v
    for key, v in case["u0"].items():
        name, _, rest = key.partition("[")
        state[(name, int(rest.rstrip("]")) if rest else None)] = v

    out = {}
    for name in states:
        for c in cells(name):
            v = state[(name, c)]
            if v is None:
                raise ValueError(f"{case['id']}: {name}[{c}] has no initial value")
            flat = f"{model_name}.{name}" if c is None else f"{model_name}.{name}[{c}]"
            out[flat] = float(v)
    return out


def build():
    cases = []
    for case in CASES:
        cases.append(
            {
                "id": case["id"],
                "fixture": case["fixture"],
                "p": case["p"],
                "u0": case["u0"],
                "expected": expected(case),
                "note": case["note"],
            }
        )
    return dict(HEADER, cases=cases)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()
    text = json.dumps(build(), indent=2) + "\n"
    if args.check:
        cur = open(MANIFEST).read() if os.path.exists(MANIFEST) else ""
        if cur != text:
            print(f"{MANIFEST} is stale; rerun without --check", file=sys.stderr)
            return 1
        return 0
    with open(MANIFEST, "w") as f:
        f.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
