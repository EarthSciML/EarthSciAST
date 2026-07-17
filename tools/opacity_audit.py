#!/usr/bin/env python3
"""Corrected-predicate audit for RFC out-of-line-expression-templates §7.3.

Divergence predicate: a match pattern can fail to fire under Option B only if
some structural (non-metavariable) pattern position must match tree content
supplied by a SURVIVING (target-free) apply_expression_template reference.

Part 1 (rules): for every match rule in the corpus, report
  - pure structural fragments: pattern subtrees that are op-nodes containing
    NO rewrite-target op (these are the only fragments a surviving reference
    could hide, since anything containing a T op is force-expanded eagerly);
  - ground literal args: non-param strings in args positions (match only a
    bare variable reference; a surviving reference would not match);
  - where-shape constraints (fail on a surviving reference; under Option A
    they passed only if the inlined body was a bare variable name).

Part 2 (use sites): for every authored document, find apply_expression_template
call sites in EXPRESSION positions (not inside expression_templates registries,
whose bodies are rule/DAG content, and not import blocks). For each, resolve
target-bearing-ness (transitively, by global name lookup). Report any surviving
(target-free) reference that sits BELOW a rewrite-target node in the same
expression tree - the only configuration in which a pattern must see through it.

Part 3 (degenerates): templates whose composed body is a single bare variable
name (the where-shape divergence needs one of these bound at a matched site).
"""
import json, os, sys, re
from pathlib import Path

ROOTS = [
    "/Users/ctessum/code/earthsciml/EarthSciDiscretizations",
    "/Users/ctessum/code/earthsciml/EarthSciAST",
    "/Users/ctessum/code/earthsciml/reseact.esm",
    "/Users/ctessum/code/earthsciml/wildlandfire.esm",
]
EXCLUDE = ("/.claude/", "/archive/", "/node_modules/", "/.git/")

CLOSED_CORE = {
    "+","-","*","/","^",
    "<","<=",">",">=","==","!=","and","or","not","ifelse",
    "D","ic",
    "exp","log","log10","sqrt","abs","sign","sin","cos","tan","asin","acos","atan","atan2",
    "sinh","cosh","tanh","asinh","acosh","atanh","min","max","floor","ceil",
    "Pre","const","true",
    "aggregate","makearray","index","broadcast","reshape","transpose","concat",
    "skolem","rank","argmin","argmax","intersect_polygon","polygon_intersection_area",
    "fn","apply_expression_template","table_lookup","enum",
}
SUGAR_T = {"grad","div","laplacian","integral","table_lookup","enum"}

def is_T(node):
    """Is this op-node a rewrite-target (member of T)? D counts always: template
    bodies/bindings and pattern positions are RHS content, where any D is a
    rewrite-target per RFC §7.2 / spec §4.2."""
    if not isinstance(node, dict) or "op" not in node:
        return False
    op = node["op"]
    if op == "D": return True
    if op in SUGAR_T: return True
    if op not in CLOSED_CORE: return True   # open-namespace custom op
    return False

def walk(node):
    yield node
    if isinstance(node, dict):
        for k, v in node.items():
            if k == "op": continue
            yield from walk(v)
    elif isinstance(node, list):
        for v in node:
            yield from walk(v)

def contains_T(node):
    return any(is_T(n) for n in walk(node))

def load_esm_files():
    files = {}
    for root in ROOTS:
        for p in Path(root).rglob("*.esm"):
            sp = str(p)
            if any(x in sp for x in EXCLUDE): continue
            try:
                files[sp] = json.loads(p.read_text())
            except Exception as e:
                print(f"  [unparseable] {sp}: {e}", file=sys.stderr)
    return files

def iter_registries(doc):
    """Yield (component_path, registry_dict) for every expression_templates block."""
    if isinstance(doc.get("expression_templates"), dict):
        yield ("<top>", doc["expression_templates"])
    for kind in ("models","reaction_systems"):
        for name, comp in (doc.get(kind) or {}).items():
            if isinstance(comp, dict) and isinstance(comp.get("expression_templates"), dict):
                yield (f"{kind}.{name}", comp["expression_templates"])

# ---------- Part 1: rules ----------
def pure_fragments(pattern, params, path="match"):
    """Maximal pattern subtrees that are op-nodes with no T descendant."""
    out = []
    def rec(node, path):
        if isinstance(node, dict) and "op" in node:
            if not contains_T(node):
                out.append((path, node))
                return  # maximal: don't descend
            args = node.get("args", [])
            for i, a in enumerate(args):
                rec(a, f"{path}.args[{i}]")
            for k, v in node.items():
                if k in ("op","args"): continue
                rec(v, f"{path}.{k}")
        elif isinstance(node, list):
            for i, v in enumerate(node):
                rec(v, f"{path}[{i}]")
    # only interior positions matter: start below the root op's own fields
    if isinstance(pattern, dict):
        for i, a in enumerate(pattern.get("args", [])):
            rec(a, f"{path}.args[{i}]")
        for k, v in pattern.items():
            if k in ("op","args"): continue
            rec(v, f"{path}.{k}")
    return out

def ground_args(pattern, params):
    out = []
    def rec(node, path):
        if isinstance(node, dict):
            for i, a in enumerate(node.get("args", [])):
                if isinstance(a, str) and a not in params:
                    out.append((f"{path}.args[{i}]", a))
                else:
                    rec(a, f"{path}.args[{i}]")
            for k, v in node.items():
                if k in ("op","args"): continue
                rec(v, f"{path}.{k}")
        elif isinstance(node, list):
            for i, v in enumerate(node):
                rec(v, f"{path}[{i}]")
    rec(pattern, "match")
    return out

# ---------- Part 2: use sites ----------
def build_global_registry(files):
    reg = {}  # name -> list of (file, decl)
    for f, doc in files.items():
        if not isinstance(doc, dict): continue
        for cpath, r in iter_registries(doc):
            for name, decl in r.items():
                reg.setdefault(name, []).append((f, decl))
    return reg

def target_bearing(name, reg, seen=None):
    """Transitive target-bearing check by name over the global registry.
    Conservative: if ANY registration of the name is target-bearing, or the
    name is unknown (import-renamed out of view), treat as target-bearing
    (i.e. eager -> NOT a surviving reference -> not divergence-relevant).
    Wait: unknown => we cannot prove target-free => treat as UNKNOWN and
    report separately, since claiming eager would understate risk."""
    if seen is None: seen = set()
    if name in seen: return False
    seen.add(name)
    if name not in reg:
        # approximate import-rename resolution: strip leading dotted prefixes
        parts = name.split(".")
        for i in range(1, len(parts)):
            suffix = ".".join(parts[i:])
            if suffix in reg:
                name = suffix
                break
        else:
            return None  # unknown
    verdict = False
    for f, decl in reg[name]:
        body = decl.get("body")
        if body is None: continue
        if contains_T(body): return True
        for n in walk(body):
            if isinstance(n, dict) and n.get("op") == "apply_expression_template":
                sub = target_bearing(n.get("name",""), reg, seen)
                if sub is True: return True
                if sub is None: verdict = None
                for bv in (n.get("bindings") or {}).values():
                    if contains_T(bv): return True
    return verdict

def expression_positions(doc):
    """Yield (path, expr_tree) for authored expression positions: everything
    except expression_templates registries and expression_template_imports."""
    SKIP_KEYS = {"expression_templates", "expression_template_imports"}
    def rec(node, path):
        if isinstance(node, dict):
            for k, v in node.items():
                if k in SKIP_KEYS: continue
                yield from rec(v, f"{path}.{k}")
            if node.get("op") == "apply_expression_template":
                yield (path, node)
        elif isinstance(node, list):
            for i, v in enumerate(node):
                yield from rec(v, f"{path}[{i}]")
    yield from rec(doc, "$")

def refs_below_T(doc):
    """Find apply_expression_template nodes that sit below a T node, outside
    registries/imports."""
    SKIP_KEYS = {"expression_templates", "expression_template_imports"}
    hits = []
    def rec(node, path, t_anc):
        if isinstance(node, dict):
            here_T = is_T(node)
            if node.get("op") == "apply_expression_template" and t_anc:
                hits.append((path, node.get("name")))
            for k, v in node.items():
                if k in SKIP_KEYS: continue
                rec(v, f"{path}.{k}", t_anc or here_T)
        elif isinstance(node, list):
            for i, v in enumerate(node):
                rec(v, f"{path}[{i}]", t_anc)
    rec(doc, "$", False)
    return hits

def main():
    files = load_esm_files()
    print(f"parsed {len(files)} .esm files\n")

    # Part 1
    print("=" * 70)
    print("PART 1 - match rules with structural exposure")
    print("=" * 70)
    n_rules = 0; n_exposed = 0; n_where = 0; n_ground = 0
    for f, doc in sorted(files.items()):
        if not isinstance(doc, dict): continue
        for cpath, r in iter_registries(doc):
            for name, decl in r.items():
                if not isinstance(decl, dict) or "match" not in decl: continue
                n_rules += 1
                params = set(decl.get("params") or [])
                frags = pure_fragments(decl["match"], params)
                grounds = ground_args(decl["match"], params)
                wh = decl.get("where")
                if frags or grounds or wh:
                    short = f.split("/earthsciml/")[-1]
                    flags = []
                    if frags: flags.append(f"pure-fragments={[(p, n.get('op')) for p,n in frags]}")
                    if grounds: flags.append(f"ground-args={grounds}")
                    if wh: flags.append(f"where-params={list(wh)}")
                    if frags: n_exposed += 1
                    if grounds: n_ground += 1
                    if wh: n_where += 1
                    print(f"  {short} :: {name}")
                    for fl in flags: print(f"      {fl}")
    print(f"\n  total match rules: {n_rules}; with pure structural fragments: "
          f"{n_exposed}; with ground args: {n_ground}; with where: {n_where}")

    # Part 2
    print()
    print("=" * 70)
    print("PART 2 - authored expression-position references and T-adjacency")
    print("=" * 70)
    reg = build_global_registry(files)
    n_sites = 0; n_surviving = 0; n_unknown = 0; n_below_T = 0
    for f, doc in sorted(files.items()):
        if not isinstance(doc, dict): continue
        sites = list(expression_positions(doc))
        if not sites: continue
        below = dict()
        for p, nm in refs_below_T(doc):
            below[p] = nm
        for path, node in sites:
            n_sites += 1
            nm = node.get("name","?")
            tb = target_bearing(nm, reg)
            # bindings carrying T also force eagerness
            bind_T = any(contains_T(v) for v in (node.get("bindings") or {}).values())
            surviving = (tb is False) and not bind_T
            status = "SURVIVES" if surviving else ("EAGER" if (tb is True or bind_T) else "UNKNOWN-NAME")
            if tb is None and not bind_T: n_unknown += 1
            if surviving: n_surviving += 1
            flag = ""
            if path in below and surviving:
                n_below_T += 1
                flag = "  <<< SURVIVING REFERENCE BELOW A REWRITE-TARGET NODE"
            short = f.split("/earthsciml/")[-1]
            print(f"  {short}\n      {path} -> '{nm}' [{status}]{flag}")
    print(f"\n  expression-position call sites: {n_sites}; surviving: {n_surviving}; "
          f"unknown-name: {n_unknown}; surviving-below-T: {n_below_T}")

    # Part 4: common op-node ancestor between a surviving reference and a T
    # node (the fully general dangerous configuration: any pattern spanning
    # both would have the reference at a structural position).
    print()
    print("=" * 70)
    print("PART 4 - surviving reference sharing an op-node ancestor with a T op")
    print("=" * 70)
    SKIP_KEYS = {"expression_templates", "expression_template_imports"}
    n_cooccur = 0
    def analyze(node):
        """Return (has_T, surviving_refs_in_subtree); print co-occurrence at
        the LOWEST common op-node ancestor."""
        nonlocal n_cooccur
        if isinstance(node, dict):
            here_is_op = "op" in node
            if node.get("op") == "apply_expression_template":
                nm = node.get("name","?")
                tb = target_bearing(nm, reg)
                bind_T = any(contains_T(v) for v in (node.get("bindings") or {}).values())
                surv = (tb is False) and not bind_T
                # eager node: expansion injects body T-ops and surfaces nested
                # refs into the tree. surviving node: an opaque leaf - nothing
                # inside is pattern-visible.
                eager = (tb is True) or bind_T
                subs = []
                if eager:
                    for k, v in node.items():
                        if k in ("op",): continue
                        t, s = analyze(v)
                        subs.extend(s)
                visible_T = (tb is not False) or bind_T
                return (visible_T if eager or tb is None else False,
                        ([nm] if surv else []) + subs)
            has_T = is_T(node)
            all_refs = []
            child_results = []
            for k, v in node.items():
                if k in SKIP_KEYS or k == "op": continue
                t, s = analyze(v)
                child_results.append((t, s))
                has_T = has_T or t
                all_refs.extend(s)
            if here_is_op and all_refs and has_T:
                # lowest such ancestor: only report if no single child already
                # contained both (avoid duplicate reports up the spine)
                if not any(t and s for t, s in child_results):
                    n_cooccur += 1
                    print(f"    co-occurrence at op '{node.get('op')}': refs {all_refs}")
                    return (has_T, [])  # stop propagating these refs
            return (has_T, all_refs)
        elif isinstance(node, list):
            has_T = False; refs = []
            for v in node:
                t, s = analyze(v)
                has_T = has_T or t; refs.extend(s)
            return (has_T, refs)
        return (False, [])
    for f, doc in sorted(files.items()):
        if not isinstance(doc, dict): continue
        before = n_cooccur
        analyze(doc)
        if n_cooccur > before:
            print(f"  ^ in {f.split('/earthsciml/')[-1]}")
    print(f"\n  co-occurrence sites (surviving ref + T op under one op-node ancestor): {n_cooccur}")

    # Part 3
    print()
    print("=" * 70)
    print("PART 3 - templates whose body is a single bare variable name")
    print("=" * 70)
    n_bare = 0
    for f, doc in sorted(files.items()):
        if not isinstance(doc, dict): continue
        for cpath, r in iter_registries(doc):
            for name, decl in r.items():
                if isinstance(decl, dict) and "match" not in decl and isinstance(decl.get("body"), str):
                    n_bare += 1
                    short = f.split("/earthsciml/")[-1]
                    print(f"  {short} :: {name} body={decl['body']!r}")
    print(f"\n  bare-variable-body templates: {n_bare}")

if __name__ == "__main__":
    main()
