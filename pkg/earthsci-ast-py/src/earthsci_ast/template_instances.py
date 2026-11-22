"""Rewriting inside template bodies, once per template instance (esm-spec
§9.6.4 rule 3).

After a component's expression positions reach their §9.6.3 fixpoint (where
every firing wrote a reference, constraint 7), the component's rules, and its
``enum`` lowering, apply inside the bodies of the templates its references
reach — without expanding any reference.

An instance is a template plus, per parameter, the literal bound to it when the
parameter sits in a structural position of the body, and otherwise the kind of
what is bound (a bare variable with its declared shape, a literal, any other
expression). Each instance's body is rewritten once; inside it a parameter is a
leaf (:class:`~earthsci_ast.lower_expression_templates._BodyView`). When every
reachable instance of a template rewrites to the same body, that body replaces
the template's in place — unless a registry entry rule 3 leaves as authored
still references the template, directly or through such entries; otherwise
each distinct body becomes ``<name>.variant<k>``, numbered by canonical bytes,
and every reference is re-pointed to the entry of its instance.

Mirrors ``pkg/EarthSciAST.jl/src/templates/instances.jl``; the cross-binding
choices the spec leaves open (instance keys, variant numbering, placement) are
fixed there and reproduced here byte for byte.
"""

from __future__ import annotations

from typing import Any

from .enums import lower_enum_op
from .error_handling import REWRITE_RULE_NONTERMINATING
from .json_walk import (
    APPLY_OP,
    ExpressionTemplateError,
    _is_array,
    _is_object,
    _rewrite_json,
    _walk_json,
)
from .lower_expression_templates import (
    _NO_LIT,
    FIXED_UNITS_KEY,
    MAX_REWRITE_PASSES,
    _BodyView,
    _canonical_compact,
    _fixed_unit_expr,
    _Lowering,
    _rewrite_to_fixpoint,
    _shape_entry,
    _validate_apply_ref,
)
from .template_imports import _collect_apply_names

# Fields whose value is an Expression (an operand position): a parameter
# string there is an operand; anywhere else it is structural.
_OPERAND_FIELDS = frozenset({"expr", "filter", "key", "lower", "upper"})
_OPERAND_LIST_FIELDS = frozenset({"args", "values"})


def _is_apply(n: Any) -> bool:
    return _is_object(n) and n.get("op") == APPLY_OP


def _structural_params(body: Any, params: list[str]) -> set[str]:
    """The parameters of a template that occur in a structural position of
    ``body`` (esm-spec §9.6.4 rule 3): anywhere but an operand position — a
    scalar field (``wrt``, ``dim``, ``fn``, …), a ``ranges`` bound or ``from``,
    an ``enum`` argument. An operand position is an element of ``args`` or
    ``values`` (but not an ``enum`` op's ``args``), the value of ``expr``,
    ``filter``, ``key``, ``lower`` or ``upper``, a value of a nested reference's
    ``bindings``, or the body itself."""
    P = set(params)
    out: set[str] = set()

    def walk(x: Any, operand: bool) -> None:
        if isinstance(x, str):
            if not operand and x in P:
                out.add(x)
        elif _is_array(x):
            for v in x:
                walk(v, operand)
        elif _is_object(x):
            op = x.get("op")
            ops = "" if op is None else str(op)
            for k, v in x.items():
                ks = str(k)
                if ks == "op" or (ks == "name" and ops == APPLY_OP):
                    continue
                if ks == "bindings" and ops == APPLY_OP and _is_object(v):
                    for bvv in v.values():
                        walk(bvv, True)
                elif ks in _OPERAND_LIST_FIELDS and ops != "enum":
                    walk(v, True)
                elif ks in _OPERAND_FIELDS:
                    walk(v, True)
                else:
                    walk(v, False)

    walk(body, True)
    return out


def _is_scalar_literal(v: Any) -> bool:
    return isinstance(v, (str, int, float, bool))


def _instance_entry(
    v: Any, structural: bool, L: _Lowering, bv: _BodyView | None
) -> tuple[str, Any]:
    """The instance entry (esm-spec §9.6.4 rule 3) for one parameter bound to
    ``v``: inside a body (``bv``), a binding that is one of the body's own
    parameters forwards the enclosing instance's entry; a structural parameter
    takes the literal bound (``"L" + canonical bytes``); otherwise the kind —
    ``"V" + shape`` for a bare variable with a declared shape, ``"V"`` for one
    without, ``"N"`` for a number or boolean literal, ``"E"`` for any other
    expression. The second value is the literal a structural position reads,
    or ``_NO_LIT``."""
    if isinstance(v, str) and bv is not None and v in bv.params:
        return bv.entries[v], bv.lit.get(v, _NO_LIT)
    if structural:
        if _is_scalar_literal(v):
            return "L" + _canonical_compact(v), v
        return "E", _NO_LIT
    if isinstance(v, str):
        shp = L.shape_env.get(v)
        return ("V" if shp is None else _shape_entry(shp)), _NO_LIT
    if isinstance(v, (int, float, bool)):
        return "N", _NO_LIT
    return "E", _NO_LIT


class _InstanceResult:
    """One rewritten template instance: the template's ``name``, the body as
    rule 3 rewrote it (references not yet re-pointed to variants), the instance
    key of every reference in that body (by node identity, ``id -> (node,
    key)``), and its height — the deepest rewrite depth below the reference
    that names it (own passes, or a written reference's pass plus the height of
    the instance it names)."""

    __slots__ = ("key", "name", "body", "refs", "height")

    def __init__(self, key: str, name: str, body: Any, refs: dict, height: int) -> None:
        self.key = key
        self.name = name
        self.body = body
        self.refs = refs
        self.height = height


class _Rule3State:
    __slots__ = ("L", "done", "active", "structural", "order")

    def __init__(self, L: _Lowering) -> None:
        self.L = L
        self.done: dict[str, _InstanceResult] = {}
        self.active: list[str] = []
        self.structural: dict[str, set[str]] = {}
        self.order: list[str] = []


def _template_structural(st: _Rule3State, name: str, decl: dict) -> set[str]:
    """The structural parameters of template ``name``
    (:func:`_structural_params`), plus each parameter forwarded whole into a
    structural parameter of a template its body references (transitively):
    through the reference the parameter reaches a structural position of the
    expansion. Memoized; a template reached again while being computed
    contributes its direct set."""
    r = st.structural.get(name)
    if r is not None:
        return r
    params = list(decl.get("params", []))
    body = decl.get("body")
    S = _structural_params(body, params)
    st.structural[name] = S  # a cycle reads the direct set
    P = set(params)

    def visit(n: dict, _path: str) -> None:
        if n.get("op") != APPLY_OP:
            return
        inner = n.get("name")
        b = n.get("bindings")
        if not (isinstance(inner, str) and _is_object(b)):
            return
        idecl = st.L.named.get(inner)
        if idecl is None:
            return
        IS = _template_structural(st, inner, idecl)
        for k, v in b.items():
            if isinstance(v, str) and v in P and str(k) in IS:
                S.add(v)

    _walk_json(body, on_obj=visit, dedup=True)
    return S


def _nonterminating(scope: str, msg: str) -> ExpressionTemplateError:
    return ExpressionTemplateError(
        REWRITE_RULE_NONTERMINATING, f"{scope}: {msg} (esm-spec §9.6.4 rule 3)"
    )


def _ref_instance(st: _Rule3State, n: dict, bv: _BodyView | None, scope: str) -> _InstanceResult:
    """The rewritten instance a reference ``n`` names, computed once per
    instance. A reference the author wrote must name a match-less template
    (§9.6.2); one a firing wrote (it has a depth) names its rule. ``bv`` is the
    enclosing body's view when ``n`` sits in a template body, ``None`` at a
    call site."""
    written = st.L.depth_of(n) is not None
    _validate_apply_ref(n, st.L.named, scope, reject_match_rule=not written)
    name = n["name"]
    decl = st.L.named[name]
    b = n["bindings"]
    params = list(decl.get("params", []))
    S = _template_structural(st, name, decl)
    entries: list[str] = []
    lits: dict[str, Any] = {}
    for p in params:
        e, lit = _instance_entry(b.get(p), p in S, st.L, bv)
        entries.append(e)
        if lit is not _NO_LIT:
            lits[p] = lit
    return _instance(st, name, decl, params, entries, lits)


def _instance(
    st: _Rule3State,
    name: str,
    decl: dict,
    params: list[str],
    entries: list[str],
    lits: dict[str, Any],
) -> _InstanceResult:
    key = "\x1f".join([name, *entries])
    r = st.done.get(key)
    if r is not None:
        return r
    tscope = f"{st.L.scope}.operators.{name}"
    if key in st.active:
        raise _nonterminating(
            tscope,
            f"rewriting template '{name}' needs the same template instance again — a "
            "`match` rule re-introduces its own pattern through the template's body",
        )
    st.active.append(key)
    bv = _BodyView(set(params), lits, dict(zip(params, entries)))
    body = _lower_body_enums(decl.get("body"), bv, st.L.enums)
    body = _instance_partial(body, bv)
    rewritten, passes = _rewrite_to_fixpoint(body, st.L, tscope, bv=bv)
    refs: dict[int, tuple[Any, str]] = {}
    height = [passes]

    def visit(n: dict, _path: str) -> None:
        if n.get("op") != APPLY_OP:
            return
        child = _ref_instance(st, n, bv, tscope)
        refs[id(n)] = (n, child.key)
        d = st.L.depth_of(n)
        height[0] = max(height[0], (0 if d is None else d) + child.height)

    _walk_json(rewritten, on_obj=visit, dedup=True)
    if height[0] > MAX_REWRITE_PASSES:
        raise _nonterminating(
            tscope,
            f"a rewrite inside template '{name}' has depth {height[0]}, beyond "
            f"MAX_REWRITE_PASSES={MAX_REWRITE_PASSES} (depth counts through template bodies)",
        )
    st.active.pop()
    res = _InstanceResult(key, name, rewritten, refs, height[0])
    st.done[key] = res
    st.order.append(key)
    return res


def _rebuild_children(node: dict, recurse, keep: str | None = None) -> dict:
    """``node`` with each value rewritten by ``recurse`` (the value under
    ``keep`` copied as is): a new dict when some value changed, else ``node``."""
    changed = False
    out: dict = {}
    for k, v in node.items():
        if k == keep:
            out[k] = v
            continue
        rv = recurse(v)
        if rv is not v:
            changed = True
        out[k] = rv
    return out if changed else node


def _lower_body_enums(body: Any, bv: _BodyView, enums: Any) -> Any:
    """The ``enum`` lowering of esm-spec §9.3 applied inside a template body for
    one instance (§9.6.4 rule 3): an ``enum`` op whose two arguments are
    strings, or parameters the instance binds to strings, becomes its
    ``const``; one still spelled with an unbound parameter stays as written."""

    def on_object(n: dict, recurse) -> Any:
        if n.get("op") != "enum":
            return _rebuild_children(n, recurse)
        args = n.get("args")
        if not (_is_array(args) and len(args) == 2):
            return n
        resolved = [
            (bv.lit.get(a, _NO_LIT) if (isinstance(a, str) and a in bv.params) else a) for a in args
        ]
        if not all(isinstance(a, str) for a in resolved):
            return n
        n2 = dict(n)
        n2["args"] = resolved
        return lower_enum_op(n2, enums)

    return _rewrite_json(body, on_object=on_object, share=True)


def _instance_partial(body: Any, bv: _BodyView) -> Any:
    """esm-spec §4.2 "Reading earlier documents": a ``D`` whose ``wrt`` is one
    of the definition's ``params`` is decided per instance — where the instance
    binds that parameter to an axis name other than ``"t"``, the ``D`` reads as
    ``partial`` in this instance (the wire boundary left it as written). Bound
    to ``"t"``, it stays the time derivative."""

    def on_object(n: dict, recurse) -> Any:
        rebuilt = _rebuild_children(n, recurse)
        if n.get("op") != "D":
            return rebuilt
        w = n.get("wrt")
        if not (isinstance(w, str) and w in bv.params):
            return rebuilt
        lit = bv.lit.get(w, _NO_LIT)
        if not (isinstance(lit, str) and lit != "t"):
            return rebuilt
        n2 = dict(rebuilt)
        n2["op"] = "partial"
        return n2

    return _rewrite_json(body, on_object=on_object, share=True)


def _repoint_refs(x: Any, refs: dict[int, tuple[Any, str]], final: dict[str, str]) -> Any:
    """``x`` with every reference re-pointed to the entry its instance was
    given: ``refs`` maps a reference node (by identity) to its instance key,
    ``final`` an instance key to the registry name its body lives under."""

    def on_object(n: dict, recurse) -> Any:
        if n.get("op") != APPLY_OP:
            return _rebuild_children(n, recurse)
        hit = refs.get(id(n))
        nn = _rebuild_children(n, recurse, keep="name")
        newname = None if hit is None else final[hit[1]]
        if newname is None or newname == str(n.get("name")):
            return nn
        out = dict(nn)
        out["name"] = newname
        return out

    return _rewrite_json(x, on_object=on_object, share=True)


def _rule3_template_order(st: _Rule3State, by_template: dict[str, list[str]]) -> list[str]:
    """The template-level order in which instances are named: a template after
    every template its instances' bodies reference. A cycle is a rule that
    re-introduces itself through a template body."""
    deps: dict[str, list[str]] = {}
    for t, keys_t in by_template.items():
        ds: list[str] = []
        for k in keys_t:
            for _node, ck in st.done[k].refs.values():
                cn = st.done[ck].name
                if cn not in ds:
                    ds.append(cn)
        deps[t] = ds
    order: list[str] = []
    state: dict[str, int] = {}

    def visit(t: str) -> None:
        s = state.get(t, 0)
        if s == 2:
            return
        if s == 1:
            raise _nonterminating(
                st.L.scope,
                f"template '{t}' reaches itself through the references rules wrote in "
                "template bodies",
            )
        state[t] = 1
        for d in deps[t]:
            visit(d)
        state[t] = 2
        order.append(t)

    for t in by_template:
        visit(t)
    return order


def _rule3_multi(st: _Rule3State, by_template: dict[str, list[str]], order: list[str]) -> set[str]:
    """The templates whose reached instances rewrite to more than one distinct
    body. Naming each single-bodied template in place or as ``<name>.variant1``
    renames every reference to it alike, so which bodies are distinct does not
    depend on that choice: this provisional pass names every single-bodied
    template in place."""
    final: dict[str, str] = {}
    multi: set[str] = set()
    for t in order:
        keys_t = by_template[t]
        canon = [
            _canonical_compact(_repoint_refs(st.done[k].body, st.done[k].refs, final))
            for k in keys_t
        ]
        distinct = sorted(set(canon))
        if len(distinct) == 1:
            for k in keys_t:
                final[k] = t
        else:
            multi.add(t)
            for k, c in zip(keys_t, canon):
                final[k] = f"{t}\x1f{distinct.index(c)}"
    return multi


def _rule3_exposed(
    st: _Rule3State, by_template: dict[str, list[str]], order: list[str]
) -> set[str]:
    """The reached match-less templates whose authored body stays reachable from
    a registry entry that rule 3 does not rewrite under its own name (esm-spec
    §9.6.4 rule 3): a match-less entry no reference reaches, one whose instances
    took variants, and, transitively, any reached template such an entry
    references. Such a template keeps its authored body; a single rewritten
    body is registered as ``<name>.variant1`` instead."""
    named = st.L.named

    def matchless(n: str) -> bool:
        d = named.get(n)
        return _is_object(d) and d.get("match") is None

    refs_memo: dict[str, set[str]] = {}

    def refs_of(n: str) -> set[str]:
        r = refs_memo.get(n)
        if r is None:
            r = {
                x
                for x in _collect_apply_names([], named[n].get("body"))
                if x in by_template and matchless(x)
            }
            refs_memo[n] = r
        return r

    stack = [n for n in named if n not in by_template and matchless(n)]
    if any(matchless(t) and refs_of(t) for t in by_template):
        stack.extend(t for t in _rule3_multi(st, by_template, order) if matchless(t))
    visible: set[str] = set()
    while stack:
        n = stack.pop()
        for r in refs_of(n):
            if r not in visible:
                visible.add(r)
                stack.append(r)
    return visible


def _match_stripped(decl: dict) -> dict:
    """A materialized entry: the rule (or variant) without its ``match``,
    ``where`` and ``priority``. A rule for ``partial`` / ``integral`` keeps the
    fixed unit expression its ``match`` gave under a private key, so the unit
    checker still holds the firing's references to it (esm-spec §4.2, §9.6.12
    "Units"); the emitted registry drops that key
    (:func:`~earthsci_ast.lower_expression_templates.materialize_component_block`)."""
    nd = {k: v for k, v in decl.items() if k not in ("match", "where", "priority")}
    fixed = _fixed_unit_expr(decl)
    if fixed is not None:
        nd[FIXED_UNITS_KEY] = fixed
    return nd


def apply_rule3(comp: dict, L: _Lowering, transforms: list[dict]) -> dict:
    """Esm-spec §9.6.4 rule 3 for one component whose expression positions
    (and the coupling ``transforms`` it receives, ``variable_map`` entries) have
    reached the §9.6.3 fixpoint: rewrite the body of every template instance
    their references reach, place each result (in place, or as
    ``<name>.variant<k>``), re-point the references, materialize each
    referenced ``match`` rule without its ``match``, ``where`` and
    ``priority``, and check the rewrite depth of every call site."""
    st = _Rule3State(L)
    site_refs: dict[int, tuple[Any, str]] = {}
    sites: list[tuple[dict, str, str]] = [
        (comp, k, f"{L.scope}.{k}") for k in list(comp.keys()) if k != "operators"
    ]
    for e in transforms:
        sites.append((e, "transform", f"{L.scope} coupling transform"))
    for holder, k, scope in sites:

        def visit(n: dict, _path: str, scope: str = scope) -> None:
            if n.get("op") != APPLY_OP:
                return
            res = _ref_instance(st, n, None, scope)
            site_refs[id(n)] = (n, res.key)
            d0 = L.depth_of(n)
            d = (0 if d0 is None else d0) + res.height
            if d > MAX_REWRITE_PASSES:
                raise _nonterminating(
                    scope,
                    f"a rewrite through template '{res.name}' has depth {d}, beyond "
                    f"MAX_REWRITE_PASSES={MAX_REWRITE_PASSES} (depth counts through "
                    "template bodies)",
                )

        _walk_json(holder[k], on_obj=visit, dedup=True)
    if not st.order:
        return comp

    by_template: dict[str, list[str]] = {}
    for k in st.order:
        by_template.setdefault(st.done[k].name, []).append(k)
    final: dict[str, str] = {}
    block = comp.get("operators")
    if not _is_object(block):
        block = {}
        comp["operators"] = block
    taken = set(L.named.keys())
    order = _rule3_template_order(st, by_template)
    exposed = _rule3_exposed(st, by_template, order)
    for t in order:
        keys_t = by_template[t]
        bodies = [_repoint_refs(st.done[k].body, st.done[k].refs, final) for k in keys_t]
        canon = [_canonical_compact(b) for b in bodies]
        distinct = sorted(set(canon))
        decl = L.named[t]
        if len(distinct) == 1 and not (
            t in exposed and distinct[0] != _canonical_compact(decl.get("body"))
        ):
            for k in keys_t:
                final[k] = t
            is_rule = decl.get("match") is not None
            nd = _match_stripped(decl) if is_rule else dict(decl)
            if distinct[0] != _canonical_compact(decl.get("body")):
                nd["body"] = bodies[0]
            elif not is_rule:
                continue
            L.named[t] = nd
            block[t] = nd
        else:
            names: dict[str, str] = {}
            for i, c in enumerate(distinct, start=1):
                vn = f"{t}.variant{i}"
                while vn in taken:
                    vn += "_"
                taken.add(vn)
                names[c] = vn
                nd = _match_stripped(decl)
                nd["body"] = bodies[canon.index(c)]
                L.named[vn] = nd
                block[vn] = nd
            for k, c in zip(keys_t, canon):
                final[k] = names[c]
    for holder, k, _scope in sites:
        holder[k] = _repoint_refs(holder[k], site_refs, final)
    return comp
