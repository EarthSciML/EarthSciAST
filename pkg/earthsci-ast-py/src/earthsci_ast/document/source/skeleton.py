"""The document skeleton: front matter, description, path blocks, and one section
per model or reaction system, with the path-keyed fallback for every field without
a native surface.

Port of ``formal/Esm/Document/Source/Skeleton.lean``. The mapping is total: every
field a container cannot spell natively falls back to a block keyed by its JSON
path relative to the enclosing section. :class:`Caps` are the container's
predicates saying which values it spells natively.

A math entry (``Source.Mx``) is a tuple: ``("eq", role, eqn)``, ``("rxn", rxn)``,
``("plot", attrs)`` or ``("tm", tm)``; a role is the name of its field.
"""

from __future__ import annotations

from typing import Any

from ..math.expr import Sym, is_e, keys_sorted
from ..value import MISSING, Dec, Obj, look, wf
from .keys import FAIL, at_, join_field, pick_one, sort_keys, split_opt

# ## The canonical form of a document


def sorted_deep(j: Any) -> bool:
    """``Source.sortedDeep``: every object, at every depth, has strictly increasing
    keys."""
    t = type(j)
    if t is Obj:
        return keys_sorted(j) and all(sorted_deep(v) for _, v in j)
    if t is list:
        return all(sorted_deep(x) for x in j)
    return True


def canon_doc(j: Any) -> bool:
    """``Source.canonDoc``: a JSON object, well formed, with sorted keys at every
    depth."""
    return type(j) is Obj and wf(j) and sorted_deep(j)


MODEL = "model"
RS = "rs"

# Source.DKind
VAR = "var"
PARAM = "param"
SPECIES = "species"
SUB = "subsystem"

# Source.Role, as its field
EQN = "equations"
INIT = "initialization_equations"
CONS = "constraint_equations"


class Decl:
    """``Source.Decl``: the directive, the declared name, and the other fields of
    the declared object as attributes."""

    __slots__ = ("kind", "name", "attrs")

    def __init__(self, kind: str, name: str, attrs: list):
        self.kind = kind
        self.name = name
        self.attrs = attrs


class Eqn:
    """``Source.Eqn``: ``lhs = rhs``, with its optional ``_comment``."""

    __slots__ = ("comment", "lhs", "rhs")

    def __init__(self, comment: str | None, lhs: Any, rhs: Any):
        self.comment = comment
        self.lhs = lhs
        self.rhs = rhs


class Rxn:
    """``Source.Rxn``: a reaction's ``id``, sides (``None`` for an empty side; a
    term is ``(species, coefficient)``), rate (the expression, or its math text)
    and other fields."""

    __slots__ = ("id", "subs", "prods", "rate", "attrs")

    def __init__(self, id: str, subs, prods, rate, attrs: list):
        self.id = id
        self.subs = subs
        self.prods = prods
        self.rate = rate
        self.attrs = attrs

    def with_rate(self, rate) -> Rxn:
        return Rxn(self.id, self.subs, self.prods, rate, self.attrs)


class Tm:
    """``Source.Tm``: an entry of ``expression_templates``: a template (``lhs is
    None``) or a rewrite rule (``lhs`` its match)."""

    __slots__ = ("name", "params", "lhs", "body", "attrs")

    def __init__(self, name: str, params: list, lhs, body, attrs: list):
        self.name = name
        self.params = params
        self.lhs = lhs
        self.body = body
        self.attrs = attrs

    def ps(self) -> list:
        """``Tm.ps``: a template's header parameters; a rule's ``params``
        attribute."""
        if self.lhs is None:
            return self.params
        return strs_of(look("params", self.attrs))

    def scope(self, s: Sym) -> Sym:
        """``Tm.scope``: the table around it, with the parameters declared."""
        ps = self.ps()
        if not ps:
            return s
        return Sym(s.names | frozenset(ps), s.templates)

    def mscope(self, s: Sym) -> Sym:
        """``Tm.mscope``: the table a rule's ``match`` pattern is read under: its
        body's, with no templates. A pattern never applies a template (spec §9.7.3),
        so an operator in it named like a template in scope (a rule is in scope
        under its own name) reads as that operator, in the call form."""
        return Sym(self.scope(s).names, ())


def mx_field(m: tuple) -> str:
    """``Mx.field``."""
    tag = m[0]
    if tag == "eq":
        return m[1]
    if tag == "rxn":
        return "reactions"
    if tag == "plot":
        return "analyses"
    return "expression_templates"


def mx_head(m: tuple):
    """``Mx.head``: the symbol-table entry of a template or rule."""
    if m[0] == "tm":
        return (m[1].name, tuple(m[1].ps()))
    return None


#: ``Source.mathFields``.
MATH_FIELDS = (
    "analyses",
    "constraint_equations",
    "equations",
    "expression_templates",
    "initialization_equations",
    "reactions",
)
_MATH_FIELD_SET = frozenset(MATH_FIELDS)


def is_math_field(k: str) -> bool:
    return k in _MATH_FIELD_SET


class Comp:
    """``Source.Comp``: one component section."""

    __slots__ = ("kind", "name", "desc", "decls", "math", "math_blocks", "blocks")

    def __init__(self, kind, name, desc=None, decls=None, math=None, math_blocks=None, blocks=None):
        self.kind = kind
        self.name = name
        self.desc = desc
        self.decls = decls if decls is not None else []
        self.math = math if math is not None else []
        self.math_blocks = math_blocks if math_blocks is not None else []
        self.blocks = blocks if blocks is not None else []

    def with_math(self, math: list) -> Comp:
        return Comp(
            self.kind, self.name, self.desc, self.decls, math, self.math_blocks, self.blocks
        )


class Doc:
    """``Source.Doc``: a document skeleton."""

    __slots__ = ("front", "desc", "blocks", "math", "comps")

    def __init__(self, front, desc, blocks, math, comps):
        self.front = front
        self.desc = desc
        self.blocks = blocks
        self.math = math
        self.comps = comps


# ## Expressions inside path blocks


class _Any:
    __slots__ = ()

    def __repr__(self) -> str:
        return "ANY"


#: A path segment matching every element of an array and every value of an
#: object (``Notation.Seg.any``).
ANY: Any = _Any()


class _Elem:
    __slots__ = ()

    def __repr__(self) -> str:
        return "ELEM"


#: A path segment matching every element of an array only, the array form of a
#: field that is one object or an array of them (``Notation.Seg.elem``).
ELEM: Any = _Elem()

#: ``Notation.compExprPaths``: the expression-valued fields of a component's path
#: blocks, as paths from the block's key (esm-schema.json; an update is one rule
#: or an array of them). A value there that is a well-formed expression prints as
#: math (``Source.mathify``).
COMP_EXPR_PATHS: tuple = (
    ("continuous_events", ANY, "affect_neg", ANY, "rhs"),
    ("continuous_events", ANY, "affects", ANY, "rhs"),
    ("continuous_events", ANY, "conditions", ANY),
    ("discrete_events", ANY, "affects", ANY, "rhs"),
    ("discrete_events", ANY, "trigger", "expression"),
    ("guesses", ANY),
    ("parameters", ANY, "update", "expression"),
    ("parameters", ANY, "update", "from", "unit_conversion"),
    ("parameters", ANY, "update", "when"),
    ("parameters", ANY, "update", ELEM, "expression"),
    ("parameters", ANY, "update", ELEM, "from", "unit_conversion"),
    ("parameters", ANY, "update", ELEM, "when"),
    ("tests", ANY, "assertions", ANY, "reference"),
    ("variables", ANY, "update", "expression"),
    ("variables", ANY, "update", "from", "unit_conversion"),
    ("variables", ANY, "update", "when"),
    ("variables", ANY, "update", ELEM, "expression"),
    ("variables", ANY, "update", ELEM, "from", "unit_conversion"),
    ("variables", ANY, "update", ELEM, "when"),
)

#: ``Notation.topExprPaths``: the same for the document's top-level path blocks.
TOP_EXPR_PATHS: tuple = (
    ("coupling", ANY, "affect_neg", ANY, "rhs"),
    ("coupling", ANY, "affects", ANY, "rhs"),
    ("coupling", ANY, "conditions", ANY),
    ("coupling", ANY, "connector", "equations", ANY, "expression"),
    ("coupling", ANY, "trigger", "expression"),
)


# ## The symbol table of a component


def keys_of(v: Any) -> list:
    """``Source.keysOf``."""
    return [k for k, _ in v] if type(v) is Obj else []


def strs_of(v: Any) -> list:
    """``Source.strsOf``."""
    return [x for x in v if type(x) is str] if type(v) is list else []


def templates_of(v: Any) -> list:
    """``Source.templatesOf``."""
    if type(v) is not Obj:
        return []
    return [(k, tuple(strs_of(look("params", t)))) for k, t in v if type(t) is Obj]


def root_ts(root: list, rm: list) -> list:
    """``Source.rootTs``."""
    out = templates_of(look("expression_templates", root))
    out.extend(h for h in map(mx_head, rm) if h is not None)
    return out


def comp_ts(c: Comp) -> list:
    """``Source.compTs``."""
    out = templates_of(look("expression_templates", c.math_blocks))
    out.extend(h for h in map(mx_head, c.math) if h is not None)
    return out


def sym_with(root: list, rt: list, c: Comp, ct: list) -> Sym:
    """``Source.symWith``."""
    names = [d.name for d in c.decls if d.kind != SUB]
    names.extend(keys_of(look("variables", c.blocks)))
    names.extend(keys_of(look("species", c.blocks)))
    names.extend(keys_of(look("parameters", c.blocks)))
    names.extend(keys_of(look("index_sets", root)))
    return Sym(frozenset(names), tuple(rt) + tuple(ct))


def sym_for(d: Doc, c: Comp) -> Sym:
    """``Source.symFor``: the symbol table of a component."""
    return sym_with(d.blocks, root_ts(d.blocks, d.math), c, comp_ts(c))


def top_sym(d: Doc) -> Sym:
    """``Source.topSym``: the symbol table of the top-level templates."""
    return Sym(frozenset(keys_of(look("index_sets", d.blocks))), tuple(root_ts(d.blocks, d.math)))


class Caps:
    """``Source.Caps``: what a container spells natively."""

    def front_key(self, k: str) -> bool:
        raise NotImplementedError

    def desc(self, s: str) -> bool:
        raise NotImplementedError

    def comp_name(self, n: str) -> bool:
        raise NotImplementedError

    def decl_name(self, n: str) -> bool:
        raise NotImplementedError

    def attr(self, a: tuple) -> bool:
        raise NotImplementedError

    def eqn(self, s: Sym, e: Eqn) -> bool:
        raise NotImplementedError

    def rxn(self, s: Sym, x: Rxn) -> bool:
        raise NotImplementedError

    def plot(self, a: list) -> bool:
        raise NotImplementedError

    def tm(self, s: Sym, t: Tm) -> bool:
        raise NotImplementedError

    def item(self, s: Sym, m: tuple) -> bool:
        """``Caps.item``: a list entry the container spells."""
        tag = m[0]
        if tag == "eq":
            return self.eqn(s, m[2])
        if tag == "rxn":
            return self.rxn(s, m[1])
        if tag == "plot":
            return self.plot(m[1])
        return self.tm(m[1].scope(s), m[1])


# ## Equations and the other math entries


def eqn_json(e: Eqn) -> Obj:
    """``Source.eqnJson``."""
    if e.comment is not None:
        return Obj([("_comment", e.comment), ("lhs", e.lhs), ("rhs", e.rhs)])
    return Obj([("lhs", e.lhs), ("rhs", e.rhs)])


def eqn_of(v: Any) -> Eqn | None:
    """``Source.eqnOf``: exactly the keys ``lhs``, ``rhs`` and optionally a string
    ``_comment``, both sides well-formed expressions."""
    if type(v) is not Obj:
        return None
    if len(v) == 3:
        (c, cm), (lk, lv), (r, rv) = v
        if c == "_comment" and type(cm) is str and lk == "lhs" and r == "rhs":
            return Eqn(cm, lv, rv) if is_e(lv) and is_e(rv) else None
        return None
    if len(v) == 2:
        (lk, lv), (r, rv) = v
        if lk == "lhs" and r == "rhs":
            return Eqn(None, lv, rv) if is_e(lv) and is_e(rv) else None
    return None


def term_json(t: tuple) -> Obj:
    return Obj([("species", t[0]), ("stoichiometry", t[1])])


def term_of(v: Any):
    if type(v) is Obj and len(v) == 2:
        (a, s), (b, n) = v
        if a == "species" and type(s) is str and b == "stoichiometry" and type(n) in (int, Dec):
            return (s, n)
    return None


def side_json(s) -> Any:
    return None if s is None else [term_json(t) for t in s]


def side_of(v: Any) -> Any:
    """``Source.sideOf``: ``null`` (an empty side, ``None``), or a non-empty array
    of terms; ``FAIL`` otherwise."""
    if v is None:
        return None
    if type(v) is list and v:
        out = []
        for x in v:
            t = term_of(x)
            if t is None:
                return FAIL
            out.append(t)
        return out
    return FAIL


RXN_KEYS = frozenset({"id", "products", "rate", "substrates"})


def rxn_json(x: Rxn) -> Obj:
    """``Source.rxnJson``."""
    kvs = [
        ("id", x.id),
        ("products", side_json(x.prods)),
        ("rate", x.rate),
        ("substrates", side_json(x.subs)),
    ]
    kvs.extend(x.attrs)
    return Obj(sort_keys(kvs))


def rxn_of(v: Any) -> Rxn | None:
    """``Source.rxnOf``: checked by printing it back."""
    if type(v) is not Obj:
        return None
    i = look("id", v)
    sv = look("substrates", v)
    pv = look("products", v)
    r = look("rate", v)
    if type(i) is not str or sv is MISSING or pv is MISSING or r is MISSING:
        return None
    s = side_of(sv)
    p = side_of(pv)
    if s is FAIL or p is FAIL:
        return None
    x = Rxn(i, s, p, r, [kv for kv in v if kv[0] not in RXN_KEYS])
    return x if rxn_json(x) == v and is_e(r) else None


def plot_json(attrs: list) -> Obj:
    """``Source.plotJson``."""
    return Obj(sort_keys([("plots", [v]) if k == "plot" else (k, v) for k, v in attrs]))


def plot_of(v: Any):
    """``Source.plotOf``: an analysis with exactly one plot and no ``plot`` field,
    checked by printing it back."""
    if type(v) is not Obj:
        return None
    ps = look("plots", v)
    if type(ps) is list and len(ps) == 1 and look("plot", v) is MISSING:
        a = [("plot", ps[0]) if k == "plots" else (k, x) for k, x in v]
        return a if plot_json(a) == v else None
    return None


def tm_json(t: Tm) -> Obj:
    """``Source.tmJson``."""
    if t.lhs is None:
        kvs = [("body", t.body), ("params", list(t.params))]
    else:
        kvs = [("body", t.body), ("match", t.lhs)]
    kvs.extend(t.attrs)
    return Obj(sort_keys(kvs))


def tm_of(n: str, v: Any) -> Tm | None:
    """``Source.tmOf``: the template or rule an entry of ``expression_templates``
    is, checked by printing it back."""
    if type(v) is not Obj:
        return None
    b = look("body", v)
    m = look("match", v)
    ps = look("params", v)
    if b is not MISSING and m is MISSING and type(ps) is list:
        if not all(type(p) is str for p in ps):
            return None
        t = Tm(n, list(ps), None, b, [kv for kv in v if kv[0] != "body" and kv[0] != "params"])
        return t if tm_json(t) == v and is_e(b) else None
    if b is not MISSING and m is not MISSING:
        t = Tm(n, [], m, b, [kv for kv in v if kv[0] != "body" and kv[0] != "match"])
        return t if tm_json(t) == v and is_e(b) and is_e(m) else None
    return None


def item_json(m: tuple) -> Obj:
    """``Source.itemJson``."""
    tag = m[0]
    if tag == "eq":
        return eqn_json(m[2])
    if tag == "rxn":
        return rxn_json(m[1])
    if tag == "plot":
        return plot_json(m[1])
    return tm_json(m[1])


def field_json(f: str, ms: list) -> Any:
    """``Source.fieldJson``: an object keyed by the entries' names for
    ``expression_templates``, a list otherwise."""
    if f == "expression_templates":
        return Obj((m[1].name if m[0] == "tm" else "", item_json(m)) for m in ms)
    return [item_json(m) for m in ms]


_ROLES = frozenset({EQN, INIT, CONS})


def item_of(f: str, v: Any):
    """``Source.itemOf``."""
    if f == "reactions":
        x = rxn_of(v)
        return None if x is None else ("rxn", x)
    if f == "analyses":
        a = plot_of(v)
        return None if a is None else ("plot", a)
    if f in _ROLES:
        e = eqn_of(v)
        return None if e is None else ("eq", f, e)
    return None


def math_of(caps: Caps, s: Sym, f: str, v: Any):
    """``Source.mathOf``: the entries of a math field, when all of them print
    natively."""
    ms = []
    if type(v) is list and v:
        if f == "expression_templates":
            return None
        for x in v:
            m = item_of(f, x)
            if m is None:
                return None
            ms.append(m)
    elif type(v) is Obj and v:
        if f != "expression_templates":
            return None
        for k, x in v:
            t = tm_of(k, x)
            if t is None:
                return None
            ms.append(("tm", t))
    else:
        return None
    return ms if all(caps.item(s, m) for m in ms) else None


def desc_of(caps: Caps, v: Any):
    """``Source.descOf``."""
    if type(v) is str and caps.desc(v):
        return v
    return None


def meta_of(caps: Caps, v: Any):
    """``Source.metaOf``: ``metadata`` printed in the front matter: the
    front-matter entries and the description."""
    if type(v) is Obj and v and look("esm", v) is MISSING and all(caps.front_key(k) for k, _ in v):
        d = desc_of(caps, look("description", v))
        es = [kv for kv in v if not (kv[0] == "description" and d is not None)]
        return es, d
    return None


def pick_var(caps: Caps, n: str, v: Any):
    """``Source.pickVar``: a model variable as a declaration."""
    if not caps.decl_name(n) or type(v) is not Obj:
        return None
    t = look("type", v)
    if t is MISSING:
        return None
    if t == "parameter" and type(t) is str:
        kind, attrs = PARAM, [kv for kv in v if kv[0] != "type"]
    elif t == "unknown" and type(t) is str:
        kind, attrs = VAR, [kv for kv in v if kv[0] != "type"]
    else:
        kind, attrs = VAR, list(v)
    if all(caps.attr(a) for a in attrs):
        return Decl(kind, n, attrs)
    return None


def pick_plain(caps: Caps, k: str, n: str, v: Any):
    """``Source.pickPlain``: a reaction-system species or parameter as a
    declaration of kind ``k``."""
    if not caps.decl_name(n):
        return None
    if type(v) is Obj and all(caps.attr(a) for a in v):
        return Decl(k, n, list(v))
    return None


def pick_sub(caps: Caps, n: str, v: Any):
    """``Source.pickSub``: a subsystem included by reference."""
    if type(v) is Obj and look("ref", v) is not MISSING:
        return pick_plain(caps, SUB, n, v)
    return None


def _picker(caps: Caps, p: str):
    if p == "var":
        return lambda n, v: pick_var(caps, n, v)
    if p == "sub":
        return lambda n, v: pick_sub(caps, n, v)
    return lambda n, v: pick_plain(caps, p, n, v)


#: ``Source.declFields``: the declaration fields of a component kind, with their
#: pickers (``var``, ``sub``, or the kind of a plain declaration).
DECL_FIELDS = {
    MODEL: (("variables", "var"), ("subsystems", "sub")),
    RS: (("species", SPECIES), ("parameters", PARAM), ("subsystems", "sub")),
}

DECL_FIELD_NAMES = {MODEL: ("variables", "subsystems"), RS: ("species", "parameters", "subsystems")}


def decl_field(k: str, d: str):
    """``Source.declField``."""
    if d == SUB:
        return "subsystems"
    if k == MODEL:
        return "variables" if d in (VAR, PARAM) else None
    if d == SPECIES:
        return "species"
    if d == PARAM:
        return "parameters"
    return None


def back_decl(k: str, d: Decl):
    """``Source.backDecl``: the entry a declaration stands for."""
    has_type = any(kv[0] == "type" for kv in d.attrs)

    def with_type(t: str) -> Obj:
        return Obj(sort_keys([("type", t), *d.attrs]))

    if k == MODEL and d.kind == PARAM:
        return None if has_type else (d.name, with_type("parameter"))
    if k == MODEL and d.kind == VAR:
        if has_type:
            return d.name, Obj(sort_keys(list(d.attrs)))
        return d.name, with_type("unknown")
    if (k == RS and d.kind in (SPECIES, PARAM)) or d.kind == SUB:
        return d.name, Obj(sort_keys(list(d.attrs)))
    return None


def comp_block(caps: Caps, k: str, desc, kv: tuple):
    """``Source.compBlock``: where an entry of a component goes when it is not a
    native surface."""
    key = kv[0]
    if key == "description":
        return None if desc is not None else kv
    if is_math_field(key):
        return None
    for f, p in DECL_FIELDS[k]:
        if f == key:
            r = split_opt(_picker(caps, p), kv[1])[1]
            return None if r is MISSING else (key, r)
    return kv


def comp_base(caps: Caps, k: str, name: str, kvs: list) -> Comp:
    """``Source.compBase``: a component before its equations are decided."""
    desc = desc_of(caps, look("description", kvs))
    decls = []
    for f, p in DECL_FIELDS[k]:
        decls.extend(split_opt(_picker(caps, p), look(f, kvs))[0])
    blocks = [b for b in (comp_block(caps, k, desc, kv) for kv in kvs) if b is not None]
    return Comp(k, name, desc, decls, [], [], blocks)


def comp_of(caps: Caps, root: list, rt: list, k: str, name: str, kvs: list) -> Comp:
    """``Source.compOf``: a component, with its math fields decided."""
    c = comp_base(caps, k, name, kvs)
    s = sym_with(root, rt, c, templates_of(look("expression_templates", kvs)))
    for f in MATH_FIELDS:
        v = look(f, kvs)
        if v is MISSING:
            continue
        ms = math_of(caps, s, f, v)
        if ms is not None:
            c.math.extend(ms)
        else:
            c.math_blocks.append((f, v))
    return c


def pick_comp(caps: Caps, n: str, v: Any):
    """``Source.pickComp``."""
    if type(v) is Obj and caps.comp_name(n):
        return n, list(v)
    return None


def top_math(caps: Caps, kvs: list):
    """``Source.topMath``: the top-level templates, when every one prints
    natively."""
    v = look("expression_templates", kvs)
    if v is MISSING:
        return None
    s = Sym(frozenset(keys_of(look("index_sets", kvs))), tuple(templates_of(v)))
    return math_of(caps, s, "expression_templates", v)


def root_block(caps: Caps, tn: bool, kv: tuple):
    """``Source.rootBlock``."""
    k = kv[0]
    if k == "esm":
        return None
    if k == "metadata":
        return None if meta_of(caps, kv[1]) is not None else kv
    if k == "models" or k == "reaction_systems":
        r = split_opt(lambda n, v: pick_comp(caps, n, v), kv[1])[1]
        return None if r is MISSING else (k, r)
    if k == "expression_templates" and tn:
        return None
    return kv


def to_doc(caps: Caps, d: Any) -> Doc:
    """``Source.toDoc``: the skeleton of a document."""
    if type(d) is not Obj:
        return Doc([], None, [], [], [])
    kvs = d
    m = meta_of(caps, look("metadata", kvs))
    tm = top_math(caps, kvs)
    blocks = [b for b in (root_block(caps, tm is not None, kv) for kv in kvs) if b is not None]
    rt = templates_of(look("expression_templates", kvs))
    cs = []
    for k, f in ((MODEL, "models"), (RS, "reaction_systems")):
        for n, ckvs in split_opt(lambda n, v: pick_comp(caps, n, v), look(f, kvs))[0]:
            cs.append(comp_of(caps, blocks, rt, k, n, ckvs))
    front = at_("esm", kvs)
    desc = None
    if m is not None:
        front.extend(m[0])
        desc = m[1]
    return Doc(front, desc, blocks, tm if tm is not None else [], cs)


# ## From a skeleton back to the document


def _math_kv(c: Comp, f: str):
    """``Source.mathKv``: one rebuilt math field (``FAIL`` when it does not fit)."""
    ms = [m for m in c.math if mx_field(m) == f]
    bs = at_(f, c.math_blocks)
    if not ms:
        if not bs:
            return []
        if len(bs) == 1:
            return [(f, bs[0][1])]
        return FAIL
    if not bs:
        return [(f, field_json(f, ms))]
    return FAIL


def _decl_kvs(k: str, c: Comp):
    """``Source.declKvs``: a declaration of a kind the component does not have is
    refused."""
    if not all(decl_field(k, d.kind) is not None for d in c.decls):
        return FAIL
    out = []
    for f in DECL_FIELD_NAMES[k]:
        r = pick_one(f, c.blocks)
        if r is FAIL:
            return FAIL
        ds = [d for d in c.decls if decl_field(k, d.kind) == f]
        v = join_field(lambda d: back_decl(k, d), ds, r)
        if v is FAIL:
            return FAIL
        if v is not MISSING:
            out.append((f, v))
    return out


def of_comp(c: Comp):
    """``Source.ofComp``: a component rebuilt from its section (``None`` when it
    does not fit)."""
    ds = _decl_kvs(c.kind, c)
    if ds is FAIL:
        return None
    es = []
    for f in MATH_FIELDS:
        r = _math_kv(c, f)
        if r is FAIL:
            return None
        es.extend(r)
    names = DECL_FIELD_NAMES[c.kind]
    kvs = [] if c.desc is None else [("description", c.desc)]
    kvs.extend(ds)
    kvs.extend(es)
    kvs.extend(kv for kv in c.blocks if kv[0] not in names)
    return Obj(sort_keys(kvs))


def _back_comp(c: Comp):
    v = of_comp(c)
    return None if v is None else (c.name, v)


def of_doc(d: Doc):
    """``Source.ofDoc``: a document rebuilt from its skeleton, checked to be
    canonical (``None`` otherwise)."""
    esm_kv = at_("esm", d.front)
    meta_es = [kv for kv in d.front if kv[0] != "esm"]
    if d.desc is not None:
        meta_es.append(("description", d.desc))
    kvs = list(esm_kv)
    if meta_es:
        kvs.append(("metadata", Obj(sort_keys(meta_es))))
    for kind, f in ((MODEL, "models"), (RS, "reaction_systems")):
        r = pick_one(f, d.blocks)
        if r is FAIL:
            return None
        cs = [c for c in d.comps if c.kind == kind]
        v = join_field(_back_comp, cs, r)
        if v is FAIL:
            return None
        if v is not MISSING:
            kvs.append((f, v))
    if d.math:
        kvs.append(("expression_templates", field_json("expression_templates", d.math)))
    kvs.extend(kv for kv in d.blocks if kv[0] != "models" and kv[0] != "reaction_systems")
    doc = Obj(sort_keys(kvs))
    return doc if canon_doc(doc) else None
