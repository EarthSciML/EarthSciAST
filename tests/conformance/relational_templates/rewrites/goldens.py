#!/usr/bin/env python3
"""Write the expected values of the relational rewrites (golden/<id>.json).

Each value is computed from the OP form (the source document, with its
`skolem` / `rank` / gated-`argmin` ops) by the Python binding's interpreter,
the reference binding, for every caller-data case of manifest.json:

- `sets`: each compared derived set's members (the op's tuples) and extent;
- `rank`: the 1-based dense IDs of the set's members (the op's 0-based rank
  plus one);
- `rank_lookup`: each row's tuple (its columns, sorted) looked up in the op
  set, 0-based rank plus one, flat with rows outermost;
- `assignments`: the op's arg-witness buffer;
- `rhs`: the right-hand side at a probe state, both keyed by state element
  `<variable>[<index>,...]` (no index for a scalar): `state` holds the probe
  (`1 + 0.1 sin(0.37 k)` over the reference's state order), `dy` the result;
- `inline_tests`: the op form's inline-test actuals, in result order, with each
  assertion's tolerance: they come from an integrator, so a binding matches one
  within that tolerance (`|actual - golden| <= max(atol, rtol * |golden|)`),
  not bit for bit.

Every binding that runs the rewrites tier asserts its op form AND its template
form against these values, so a second binding's interpreter cross-checks the
reference on every run. An entry compared by another tier (`compare.tier`)
takes its expected values from that tier; a `load_only` entry has no values.

Run from the repository root with the Python binding importable:

    PYTHONPATH=pkg/earthsci-ast-py/src python3 tests/conformance/relational_templates/rewrites/goldens.py

`--check` exits 1 when a golden file is missing or stale.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import warnings
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]

from earthsci_ast import relational  # noqa: E402
from earthsci_ast.inline_tests import run_inline_tests  # noqa: E402
from earthsci_ast.problem import esm_problem  # noqa: E402
from earthsci_ast.value_invention import materialize_value_invention  # noqa: E402


def ode_states(doc: dict, model: str) -> list[str]:
    def target(lhs):
        if isinstance(lhs, dict):
            if lhs.get("op") == "D":
                a = lhs["args"][0]
                return a if isinstance(a, str) else a["args"][0]
            if lhs.get("op") == "faq":
                return target(lhs.get("expr"))
        return None

    return [t for t in (target(eq.get("lhs")) for eq in doc["models"][model]["equations"]) if t]


def build(path: Path, case: dict, model: str):
    doc = json.loads(path.read_text())
    doc["models"] = {model: doc["models"][model]}
    ca = {f"{model}.{k}": np.asarray(v, dtype=float) for k, v in case["const_arrays"].items()}
    u0 = {f"{model}.{s}": 1.0 for s in ode_states(doc, model)}
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", RuntimeWarning)
        return esm_problem(
            doc,
            (0.0, 1.0),
            p=dict(case["params"]),
            u0=u0,
            model_name=model,
            const_arrays=ca,
            compiler="interpreter",
            base_path=str(path.parent),
        )


def raw_vi(path: Path, case: dict, model: str):
    src = json.loads(path.read_text())
    raw = {**src["models"][model], "index_sets": src["index_sets"]}
    ca = {k: np.asarray(v, dtype=float) for k, v in case["const_arrays"].items()}
    ca.update({f"{model}.{k}": v for k, v in list(ca.items())})
    return materialize_value_invention(raw, ca, case["params"])


def num(x) -> float | int:
    x = float(x)
    if not np.isfinite(x):
        raise ValueError(f"non-finite golden value {x}")
    return x


def probe_state(n: int) -> np.ndarray:
    """`u_k = 1 + 0.1 sin(0.37 k)` over the reference's state order (k from 0)."""
    return np.array([1.0 + 0.1 * np.sin(0.37 * k) for k in range(n)])


def elem_key(name: str, model: str) -> str:
    """`Model.var[1, 2]` -> `var[1,2]`."""
    name = name[len(model) + 1 :] if name.startswith(model + ".") else name
    return re.sub(r"\s+", "", name)


def case_golden(entry: dict, case: dict) -> dict:
    cmp = entry["compare"]
    model = entry["models"][0]
    src = ROOT / entry["source"]
    out: dict = {}
    if cmp.get("vi_only"):
        vi = raw_vi(src, case, model)
        members, extents = vi.members, vi.extents
        prob = None
    else:
        prob = build(src, case, model)
        members, extents = prob.build.vi_members, prob.build.derived_extents
    if "sets" in cmp:
        out["sets"] = {
            s["faq"]: {
                "members": [[int(c) for c in m] for m in members[s["faq"]]],
                "extent": int(extents[s["faq"]]),
            }
            for s in cmp["sets"]
        }
    if "rank" in cmp:
        op_members = [tuple(m) for m in members[cmp["rank"]["faq"]]]
        ids = relational.rank(op_members, base=0)
        out["rank"] = {
            "variable": cmp["rank"]["variable"],
            "values": [num(ids[m] + 1) for m in op_members],
        }
    if "rank_lookup" in cmp:
        rl = cmp["rank_lookup"]
        op_members = [tuple(m) for m in members[rl["faq"]]]
        ids = relational.rank(op_members, base=0)
        cols = [np.asarray(case["const_arrays"][c], dtype=float).ravel() for c in rl["columns"]]
        out["rank_lookup"] = {
            "variable": rl["variable"],
            "values": [
                num(ids[tuple(sorted(int(c[i]) for c in cols))] + 1) for i in range(cols[0].size)
            ],
        }
    for a in cmp.get("assignments", []):
        vi = raw_vi(src, case, model)
        out.setdefault("assignments", {})[a["template"]] = [
            num(x) for x in np.asarray(vi.assignments[a["op"]], dtype=float).ravel()
        ]
    if cmp.get("rhs"):
        b = prob.build
        names = [elem_key(n, model) for n in b.elem_names]
        y = probe_state(len(names))
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", RuntimeWarning)
            dy = b.rhs_function(0.0, y)
        out["rhs"] = {
            "state": {n: num(v) for n, v in zip(names, y)},
            "dy": {n: num(v) for n, v in zip(names, dy)},
        }
    return out


def golden(entry: dict) -> dict | None:
    cmp = entry["compare"]
    if cmp.get("tier") or cmp.get("load_only"):
        return None
    g: dict = {
        "fixture": entry["id"],
        "reference_binding": "python",
        "reference_compiler": "interpreter",
        "reference_form": "op",
    }
    if cmp.get("inline_tests"):
        res = run_inline_tests(str(ROOT / entry["source"]), compiler="interpreter")
        g["inline_tests"] = [
            {
                "test_id": r.test_id,
                "assertion_idx": r.assertion_idx,
                "variable": r.variable,
                "actual": num(r.actual),
                "rtol": num(r.rtol),
                "atol": num(r.atol),
            }
            for r in res
        ]
    g["cases"] = [case_golden(entry, c) for c in entry["cases"]]
    return g


def render(g: dict) -> str:
    return json.dumps(g, indent=2) + "\n"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()
    manifest_path = HERE / "manifest.json"
    manifest = json.loads(manifest_path.read_text())
    stale = []
    for entry in manifest["rewrites"]:
        g = golden(entry)
        rel = f"golden/{entry['id']}.json"
        if g is None:
            if entry.get("golden"):
                stale.append(f"{entry['id']}: has a golden but no values to check")
            continue
        path = HERE / rel
        text = render(g)
        if args.check:
            if not path.exists() or path.read_text() != text or entry.get("golden") != rel:
                stale.append(rel)
        else:
            path.parent.mkdir(exist_ok=True)
            path.write_text(text)
            entry["golden"] = rel
    if args.check:
        for s in stale:
            print(f"stale: {s}")
        return 1 if stale else 0
    manifest_path.write_text(json.dumps(manifest, indent=1, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
