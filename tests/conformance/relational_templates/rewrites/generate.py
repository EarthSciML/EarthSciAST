#!/usr/bin/env python3
"""Write the template rewrites of the skolem / rank / gated-argmin fixtures.

Each rewrite is its source document with the value-invention ops replaced by
lib/relational.esm templates (user rulings on the skolem/rank design):

- a `distinct` producer's `skolem` key becomes `edge_key` (undirected),
  `pair_key` (directed; nested for three components) or the bare component
  (one component); the skolem `label` is dropped;
- a map whose body is a two-component `skolem` and which is read only as a
  `join.on` column becomes one integer column per component (`<name>_c1`,
  `<name>_c2`), and every `on` pair naming it becomes one pair per component;
- `rank(S)` over a set's own members becomes the loop index (1-based);
- an `argmin` / `argmax` with an `on` join becomes `argmin_where` /
  `argmax_where` whose predicate is the conjunction of the column equalities.

manifest.json beside this script lists each rewrite with its source; the
binding harnesses compare the two forms.
"""

import copy
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
LIB_REF = "esm:std/relational.esm"  # the bundled standard library (esm-spec §4.7)


def op(o, *a):
    return {"op": o, "args": list(a)}


def apply(name, **b):
    return {"op": "apply_expression_template", "args": [], "name": name, "bindings": b}


def rename(e, a, b):
    if isinstance(e, str):
        return b if e == a else e
    if isinstance(e, list):
        return [rename(x, a, b) for x in e]
    if isinstance(e, dict):
        return {k: rename(v, a, b) for k, v in e.items()}
    return e


def walk(e, fn):
    """Post-order rewrite: fn(node) returns a replacement or None."""
    if isinstance(e, list):
        return [walk(x, fn) for x in e]
    if isinstance(e, dict):
        e = {k: walk(v, fn) for k, v in e.items()}
        r = fn(e)
        return e if r is None else r
    return e


def key_template(comps, spec):
    kind = spec["kind"]
    if kind == "scalar":
        assert len(comps) == 1
        return comps[0]
    if kind == "edge":
        u, v = comps
        return apply("edge_key", u=u, v=v, lo=spec["lo"], n=spec["n"])
    if kind == "pair":
        a, b = comps
        return apply(
            "pair_key", a=a, b=b, lo_a=spec["lo"][0], lo_b=spec["lo"][1], n_a=spec["n"][0], n_b=spec["n"][1]
        )
    if kind == "triple":
        a, b, c = comps
        (la, lb, lc), (na, nb, nc) = spec["lo"], spec["n"]
        ab = apply("pair_key", a=a, b=b, lo_a=la, lo_b=lb, n_a=na, n_b=nb)
        return apply("pair_key", a=ab, b=c, lo_a=0, lo_b=lc, n_a=na * nb, n_b=nc)
    raise ValueError(kind)


def rewrite_model(m, index_sets, keys):
    m = copy.deepcopy(m)
    eqs = m["equations"]
    # 1. two-component skolem maps -> one column per component
    split = {}
    for eq in eqs:
        rhs = eq.get("rhs")
        if isinstance(rhs, dict) and rhs.get("op") == "faq" and isinstance(rhs.get("expr"), dict):
            body = rhs["expr"]
            if body.get("op") == "skolem" and len(body["args"]) > 1 and isinstance(eq["lhs"], dict):
                split[eq["lhs"]["args"][0]] = body["args"]
    new_eqs = []
    for eq in eqs:
        lhs = eq.get("lhs")
        name = lhs["args"][0] if isinstance(lhs, dict) and lhs.get("op") == "index" else None
        if name in split and eq["rhs"].get("op") == "faq" and eq["rhs"]["expr"].get("op") == "skolem":
            for c, comp in enumerate(split[name], 1):
                e2 = copy.deepcopy(eq)
                e2["lhs"]["args"][0] = f"{name}_c{c}"
                e2["rhs"]["expr"] = comp
                e2["rhs"]["args"] = []
                e2["_comment"] = f"Component {c} of the former `{name}` bin key: an integer join column."
                new_eqs.append(e2)
        else:
            new_eqs.append(eq)
    for name, comps in split.items():
        decl = m["variables"].pop(name)
        for c in range(1, len(comps) + 1):
            d = copy.deepcopy(decl)
            d["description"] = f"Component {c} of the bin key formerly `{name}` (an integer join column)."
            m["variables"][f"{name}_c{c}"] = d

    def split_on(join):
        out = []
        for clause in join:
            if "on" in clause:
                pairs = []
                for a, b in clause["on"]:
                    if a in split and b in split:
                        pairs += [[f"{a}_c{c}", f"{b}_c{c}"] for c in range(1, len(split[a]) + 1)]
                    else:
                        pairs.append([a, b])
                clause = {**clause, "on": pairs}
            out.append(clause)
        return out

    def fix(node):
        o = node.get("op")
        if o in ("argmin", "argmax") and "join" in node:
            arg = node["arg"]
            ((sym, rspec),) = node["ranges"].items()
            n = index_sets[rspec["from"]]["size"]
            ks = f"k_{o}_where_1"
            eqs_ = []
            for clause in split_on(node["join"]):
                for a, b in clause["on"]:
                    eqs_.append((a, b))
            # the outer column is indexed by the enclosing map's output symbol (filled in below)
            node = dict(node)
            node["_where"] = (o, arg, ks, n, eqs_)
            return node
        if o == "faq":
            node = dict(node)
            if "join" in node:
                node["join"] = split_on(node["join"])
            if "args" in node:
                node["args"] = [x for x in node["args"] if x not in split] + [
                    f"{x}_c{c}" for x in node["args"] if x in split for c in range(1, len(split[x]) + 1)
                ]
            if node.get("distinct") and "key" in node:
                k = node["key"]
                if k.get("op") == "skolem":
                    node["key"] = key_template(k["args"], keys[node["id"]])
            if isinstance(node.get("expr"), dict) and node["expr"].get("op") == "rank":
                (sym,) = node["output_idx"]
                node["expr"] = sym
            return node
        return None

    out = []
    for eq in new_eqs:
        eq = walk(eq, fix)
        rhs = eq.get("rhs")
        if isinstance(rhs, dict) and isinstance(rhs.get("expr"), dict) and "_where" in rhs["expr"]:
            (outer,) = rhs["output_idx"]
            o, arg, ks, n, pairs = rhs["expr"].pop("_where")
            body = rhs["expr"]
            col_set = {}
            for v in m["variables"]:
                shp = m["variables"][v].get("shape") or []
                col_set[v] = shp[0] if len(shp) == 1 else None
            outer_set = rhs["ranges"][outer]["from"]
            conds = []
            for a, b in pairs:
                # the column over the outer set is read at the outer symbol, the other at the candidate
                if col_set.get(a) == outer_set:
                    conds.append(op("==", op("index", a, outer), op("index", b, ks)))
                else:
                    conds.append(op("==", op("index", b, outer), op("index", a, ks)))
            p = conds[0]
            for c in conds[1:]:
                p = op("and", p, c)
            rhs["expr"] = apply(f"{o}_where", f=rename(body["expr"], arg, ks), p=p, n=n)
            rhs["args"] = [x for x in rhs.get("args", []) if x in m["variables"]]
        for k in ("_comment",):
            if isinstance(eq.get(k), str) and "skolem" in eq[k]:
                eq[k] = eq[k] + " (Template rewrite: see tests/conformance/relational_templates/rewrites/.)"
        out.append(eq)
    # A rank variable the op form left unshaped (it was dropped from the ODE) is
    # now an ordinary observed over the derived set: declare its shape.
    for eq in out:
        lhs, rhs = eq.get("lhs"), eq.get("rhs")
        if (
            isinstance(lhs, dict)
            and lhs.get("op") == "index"
            and isinstance(rhs, dict)
            and rhs.get("op") == "faq"
            and rhs.get("output_idx") == [rhs.get("expr")]
        ):
            var = m["variables"].get(lhs["args"][0])
            if var is not None and not var.get("shape"):
                var["shape"] = [rhs["ranges"][rhs["expr"]]["from"]]
    m["equations"] = out
    return m


def main():
    manifest = json.loads((HERE / "manifest.json").read_text())
    for entry in manifest["rewrites"]:
        src = ROOT / entry["source"]
        doc = json.loads(src.read_text())
        dst = ROOT / entry["out"] if "out" in entry else HERE / f"{entry['id']}.esm"
        for mname in entry["models"]:
            m = rewrite_model(doc["models"][mname], doc["index_sets"], entry.get("keys", {}))
            imports = m.get("expression_template_imports", [])
            m = {
                "expression_template_imports": imports + [{"ref": LIB_REF}],
                **{k: v for k, v in m.items() if k != "expression_template_imports"},
            }
            doc["models"][mname] = m
        extra = entry.get("extra", {})
        for name, patch in extra.get("index_sets", {}).items():
            doc["index_sets"][name].update(patch)
        for mname in entry["models"][:1]:
            doc["models"][mname]["variables"].update(extra.get("variables", {}))
            doc["models"][mname]["equations"] += extra.get("equations", [])
        for other in [
            k for k in doc["models"] if k not in entry["models"] and not entry.get("keep_all_models")
        ]:
            del doc["models"][other]
        doc["metadata"]["name"] = doc["metadata"].get("name", entry["id"]) + "_template"
        doc["metadata"]["description"] = (
            f"Template rewrite of {entry['source']} (generated by "
            f"tests/conformance/relational_templates/rewrites/generate.py): the skolem / rank / gated-argmin "
            f"value-invention ops replaced by lib/relational.esm templates. " + entry["note"]
        )
        with open(dst, "w") as fh:
            json.dump(doc, fh, indent=2, ensure_ascii=False)
            fh.write("\n")


if __name__ == "__main__":
    main()
