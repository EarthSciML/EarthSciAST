#!/usr/bin/env python3
# Audit of esm-spec §9.6.4 rule 4 case (d) (2.4.0 header-note difference 4) over the real-model corpus.
#
# Case (d): a rule fires on a node inside the `bindings` of a reference that survives load. The in-place
# (2.3.0) engine expanded a reference eagerly iff its template's body (transitively) or its bindings held a
# rewrite-target op (spatial or any `D`, grad/div/laplacian, integral, enum, any op outside the evaluable
# core); every other reference survived as a leaf and its bindings were never rewritten. So case (d) needs a
# node, in the bindings of such a surviving reference, that some rule's `match` pattern matches, and that node
# is built from core ops only (else the reference was eager). Hence the matching rule's pattern must itself
# be built from core ops only (every op node in the pattern core; a `D` of any `wrt` counts as a target).
#
# Tiers:
#  1. Every match rule in the corpus: classify its pattern (root op; whether every op node is core).
#     A rule with a non-core node anywhere in its pattern can never match a core-only node: it cannot
#     produce case (d).
#  2. Candidate scan (structural, ignoring `where` and component scoping, i.e. a superset): every
#     apply_expression_template node anywhere in a document -- equations, observed definitions, template
#     bodies (incl. rule bodies, which is where rule-written references come from), coupling -- whose
#     bindings hold no target op and whose template (resolved in the same file; unresolved = assumed
#     surviving) is not target-bearing; does any node inside its bindings match any core-only pattern of
#     the corpus? Also reported: core-only nodes inside surviving template bodies that a core-only pattern
#     matches (rule 3 now rewrites inside every reachable body; the in-place engine never looked inside a
#     surviving reference's body either).
#
# usage: audit_case_d.py <root>...
import json, os, sys, collections

# The evaluable core exactly as the in-place engine (EarthSciAST.jl at the esa-tmpl-a1 wt15 tree) defined it:
# keys of `_OP_INDEX` minus `_REWRITE_TARGET_OPS` (D, grad, div, laplacian, integral, enum). Every other op
# (incl. `fn`, `table_lookup`, `aggregate`, user ops) made a reference eager. apply_expression_template is not a target.
CORE = set(["!=","*","+","-","/","<","<=","==",">",">=","Pre","^","abs","acos","acosh","and","asin","asinh","atan",
            "atan2","atanh","broadcast","ceil","concat","const","cos","cosh","distinct","e","exp","false","faq",
            "floor","ic","ifelse","index","log","log10","makearray","max","min","neg","not","or","pi","pow",
            "reshape","sign","sin","sinh","sqrt","tan","tanh","transpose","true","\u03c0","apply_expression_template"])

def is_target(x):
    op = x.get('op')
    return isinstance(op, str) and op not in CORE

def has_target(x):
    if isinstance(x, dict):
        if is_target(x): return True
        return any(has_target(v) for v in x.values())
    if isinstance(x, list): return any(has_target(v) for v in x)
    return False

def refs_in(x, out):
    if isinstance(x, dict):
        if x.get('op') == 'apply_expression_template': out.append(x)
        for v in x.values(): refs_in(v, out)
    elif isinstance(x, list):
        for v in x: refs_in(v, out)

def nodes(x):
    if isinstance(x, dict):
        if 'op' in x: yield x
        for v in x.values(): yield from nodes(v)
    elif isinstance(x, list):
        for v in x: yield from nodes(v)

def match(pat, x, params):
    """Structural match ignoring `where` and binding consistency (a superset of the real matcher)."""
    if isinstance(pat, str) and pat in params: return True
    if isinstance(pat, dict):
        if not isinstance(x, dict) or pat.get('op') != x.get('op'): return False
        for k, pv in pat.items():
            if k == 'op': continue
            if k not in x: return False
            if not match(pv, x[k], params): return False
        return True
    if isinstance(pat, list):
        return isinstance(x, list) and len(x) == len(pat) and all(match(p, v, params) for p, v in zip(pat, x))
    return pat == x

def load(p):
    try:
        with open(p) as f: return json.load(f)
    except Exception: return None

def walk_files(roots):
    for root in roots:
        for dp, dn, fn in os.walk(root):
            dn[:] = sorted(d for d in dn if not d.startswith('.') and d not in ('archive', 'node_modules'))
            for f in sorted(fn):
                if f.endswith('.esm'): yield os.path.join(dp, f)

def registries(d):
    out = []
    def w(x):
        if isinstance(x, dict):
            et = x.get('expression_templates')
            if isinstance(et, dict): out.append(et)
            for v in x.values(): w(v)
        elif isinstance(x, list):
            for v in x: w(v)
    w(d); return out

def main():
    roots = sys.argv[1:]
    st = collections.Counter(); roots_ops = collections.Counter(); core_rules = []
    files = []
    for p in walk_files(roots):
        d = load(p)
        if d is None: st['unparseable_files'] += 1; continue
        st['files'] += 1; files.append(p)
        for et in registries(d):
            for n, t in et.items():
                if not isinstance(t, dict) or 'match' not in t: continue
                st['rules'] += 1
                m = t['match']; params = set(t.get('params', []))
                r = m.get('op') if isinstance(m, dict) else ('<metavariable>' if m in params else '<literal>')
                roots_ops['custom op (outside core)' if isinstance(m, dict) and r not in CORE and r not in ('D','grad','div','laplacian','integral','enum') else r] += 1
                if not has_target(m) and not (isinstance(m, dict) and m.get('op') == 'D'):
                    core_rules.append((p, n, m, params))
                elif isinstance(m, dict) and any(x.get('op') == 'D' and x.get('wrt') == 't' for x in nodes(m)):
                    st['rules_with_time_D_in_pattern'] += 1
    st['core_only_patterns'] = len(core_rules)
    print('tier 1:', dict(st))
    print('  pattern root ops:', dict(roots_ops.most_common()))
    for p, n, m, _ in core_rules: print('  CORE-ONLY PATTERN', p, n, json.dumps(m)[:300])

    hits = []; st2 = collections.Counter()
    for p in files:
        d = load(p); regs = registries(d)
        tmpl = {}
        for et in regs:
            for n, t in et.items():
                if isinstance(t, dict): tmpl.setdefault(n, t)
        memo = {}
        def tb(name, stack=()):
            # template body (transitively) holds a target op
            if name in memo: return memo[name]
            t = tmpl.get(name)
            if t is None or name in stack: return False
            body = t.get('body'); rs = []; refs_in(body, rs)
            v = has_target(body) or any(tb(r.get('name'), stack + (name,)) for r in rs)
            memo[name] = v; return v
        allrefs = []; refs_in(d, allrefs)
        for r in allrefs:
            st2['references'] += 1
            b = r.get('bindings', {})
            if has_target(b) or tb(r.get('name')): st2['eager_in_old_engine'] += 1; continue
            st2['surviving_in_old_engine'] += 1
            for x in nodes(b):
                for rp, rn, m, params in core_rules:
                    if match(m, x, params): hits.append(('bindings', p, r.get('name'), rp, rn))
        for n, t in tmpl.items():
            if 'match' in t or tb(n): continue
            st2['surviving_template_bodies'] += 1
            for x in nodes(t.get('body')):
                for rp, rn, m, params in core_rules:
                    if match(m, x, params): hits.append(('body', p, n, rp, rn))
    print('tier 2:', dict(st2), 'candidates:', len(hits))
    for h in hits: print('  CANDIDATE', *h)

if __name__ == '__main__':
    main()
