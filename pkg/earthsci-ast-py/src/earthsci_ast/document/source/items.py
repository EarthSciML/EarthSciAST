"""The skeleton as a sequence of constructs; equations as math; reaction sides;
multi-line equations.

Port of ``formal/Esm/Document/Source/Items.lean``, ``Equation.lean``,
``Reaction.lean`` and ``MultiLine.lean``. :func:`items` lists the constructs of a
skeleton in the printer's order; :func:`unitems` reads a construct sequence back.
Math entries are held as the container's math text at this layer;
:func:`raw_doc` prints them under each component's symbol table and
:func:`cook_doc` reads them back.

A construct (``Source.RItem``) is a tuple: ``("desc", s)``, ``("block", k, v)``,
``("comp", kind, name)``, ``("decl", decl)``, ``("eqn", raw)``,
``("eqx", role, raw)``, ``("rxn", rxn)``, ``("plot", attrs)`` or ``("tm", tm)``.
"""

from __future__ import annotations

from typing import Any, Callable

from ..math import token as K
from ..math.expr import Sym, is_dig, is_e, is_formula, is_letter, name_ok, num_ok
from ..math.parser import parse_toks
from ..strings import is_ident_char
from ..value import Dec, Math, Obj, math_ok
from .keys import FAIL
from .skeleton import (
    ANY,
    COMP_EXPR_PATHS,
    EQN,
    TOP_EXPR_PATHS,
    Comp,
    Doc,
    Eqn,
    Tm,
    is_math_field,
    sym_for,
    top_sym,
)

# ## Constructs


def m_item(m: tuple) -> tuple:
    """``Source.mItem``: the construct of a math entry."""
    tag = m[0]
    if tag == "eq":
        return ("eqn", m[2]) if m[1] == EQN else ("eqx", m[1], m[2])
    return m


def _comp_items(c: Comp, out: list) -> None:
    out.append(("comp", c.kind, c.name))
    if c.desc is not None:
        out.append(("desc", c.desc))
    out.extend(("decl", d) for d in c.decls)
    out.extend(m_item(m) for m in c.math)
    out.extend(("block", k, v) for k, v in c.math_blocks)
    out.extend(("block", k, v) for k, v in c.blocks)


def items(d: Doc) -> list:
    """``Source.items``: the constructs of a skeleton, in the printer's order."""
    out: list = [] if d.desc is None else [("desc", d.desc)]
    out.extend(("block", k, v) for k, v in d.blocks)
    out.extend(m_item(m) for m in d.math)
    for c in d.comps:
        _comp_items(c, out)
    return out


def _add_to(c: Comp, it: tuple) -> bool:
    """``Source.addTo``: add a construct to a component section; a second
    description is refused."""
    tag = it[0]
    if tag == "desc":
        if c.desc is not None:
            return False
        c.desc = it[1]
    elif tag == "block":
        (c.math_blocks if is_math_field(it[1]) else c.blocks).append((it[1], it[2]))
    elif tag == "decl":
        c.decls.append(it[1])
    elif tag == "eqn":
        c.math.append(("eq", EQN, it[1]))
    elif tag == "eqx":
        c.math.append(("eq", it[1], it[2]))
    elif tag == "comp":
        return False
    else:
        c.math.append(it)
    return True


def unitems(front: list, its: list):
    """``Source.unitems``: read a construct sequence (with the front matter) into a
    skeleton (``None`` when the sequence is out of order). Before the first
    directive only a description, blocks and templates are allowed."""
    desc = None
    blocks: list = []
    math: list = []
    comps: list = []
    cur = None
    for it in its:
        tag = it[0]
        if tag == "comp":
            if cur is not None:
                comps.append(cur)
            cur = Comp(it[1], it[2])
        elif cur is not None:
            if not _add_to(cur, it):
                return None
        elif tag == "desc":
            if desc is not None:
                return None
            desc = it[1]
        elif tag == "block":
            blocks.append((it[1], it[2]))
        elif tag == "tm":
            math.append(it)
        else:
            return None
    if cur is not None:
        comps.append(cur)
    return Doc(front, desc, blocks, math, comps)


def _at_path(v: Any, pat: tuple, leaf: Callable) -> Any:
    """``Source.atPath``: ``leaf`` applied to every value of ``v`` at the path
    ``pat`` (a key, or :data:`ANY` for every element of an array and every value
    of an object); everything else as it is."""
    if not pat:
        return leaf(v)
    seg, rest = pat[0], pat[1:]
    t = type(v)
    if seg is ANY:
        if t is list:
            return [_at_path(x, rest, leaf) for x in v]
        if t is Obj:
            return Obj((k, _at_path(x, rest, leaf)) for k, x in v)
        return v
    if t is Obj:
        return Obj((k, _at_path(x, rest, leaf) if k == seg else x) for k, x in v)
    return v


def mathify(pr_r: Callable, s: Sym, pats: tuple, blocks: list) -> list:
    """``Source.mathify``: in a section's path blocks, every value at an
    expression path (``pats``, keyed by the block's key) that is a well-formed
    expression whose math text (``pr_r`` under ``s``) a container can delimit
    becomes that math leaf; every other value stays as it is."""

    def leaf(v: Any) -> Any:
        if not is_e(v):
            return v
        t = pr_r(s, v)
        return Math(t) if math_ok(t) else v

    out = []
    for k, v in blocks:
        for p in pats:
            if p[0] == k:
                v = _at_path(v, p[1:], leaf)
        out.append((k, v))
    return out


def _cook_val(ck_r: Callable, s: Sym, v: Any) -> Any:
    t = type(v)
    if t is Math:
        r = ck_r(s, v.text)
        return FAIL if r is None else r
    if t is list:
        out = []
        for x in v:
            y = _cook_val(ck_r, s, x)
            if y is FAIL:
                return FAIL
            out.append(y)
        return out
    if t is Obj:
        out = []
        for k, x in v:
            y = _cook_val(ck_r, s, x)
            if y is FAIL:
                return FAIL
            out.append((k, y))
        return Obj(out)
    return v


def cook_blocks(ck_r: Callable, s: Sym, blocks: list):
    """``Source.cookBlocks``: every math leaf of a section's path blocks read
    back as an expression under ``s``, wherever it is. ``None`` when one does
    not read."""
    out = []
    for k, v in blocks:
        y = _cook_val(ck_r, s, v)
        if y is FAIL:
            return None
        out.append((k, y))
    return out


def raw_doc(pr: Callable, pr_r: Callable, d: Doc) -> Doc:
    """``Source.rawDoc``: every math entry printed under its symbol table, and
    every expression of a path block that has math (``mathify``)."""
    ts = top_sym(d)
    comps = []
    for c in d.comps:
        s = sym_for(d, c)
        rc = c.with_math([pr(s, m) for m in c.math])
        rc.blocks = mathify(pr_r, s, COMP_EXPR_PATHS, c.blocks)
        comps.append(rc)
    blocks = mathify(pr_r, ts, TOP_EXPR_PATHS, d.blocks)
    return Doc(d.front, d.desc, blocks, [pr(ts, m) for m in d.math], comps)


def cook_doc(ck: Callable, ck_r: Callable, d: Doc):
    """``Source.cookDoc``: read every math entry of a skeleton (one math text may
    hold several equations) and every math leaf of its path blocks. ``None`` when
    one does not read."""
    ts = top_sym(d)
    rm = []
    for m in d.math:
        r = ck(ts, m)
        if r is None:
            return None
        rm.extend(r)
    cs = []
    for c in d.comps:
        s = sym_for(d, c)
        math = []
        for m in c.math:
            r = ck(s, m)
            if r is None:
                return None
            math.extend(r)
        cc = c.with_math(math)
        cb = cook_blocks(ck_r, s, c.blocks)
        if cb is None:
            return None
        cc.blocks = cb
        cs.append(cc)
    blocks = cook_blocks(ck_r, ts, d.blocks)
    if blocks is None:
        return None
    return Doc(d.front, d.desc, blocks, rm, cs)


def pr_mx(pr_e: Callable, pr_r: Callable, s: Sym, m: tuple) -> tuple:
    """``Source.prMx``: a math entry's text, from the equation and expression
    printers."""
    tag = m[0]
    if tag == "eq":
        return ("eq", m[1], pr_e(s, m[2]))
    if tag == "rxn":
        return ("rxn", m[1].with_rate(pr_r(s, m[1].rate)))
    if tag == "plot":
        return m
    t = m[1]
    sc = t.scope(s)
    lhs = None if t.lhs is None else pr_r(t.mscope(s), t.lhs)
    return ("tm", Tm(t.name, t.params, lhs, pr_r(sc, t.body), t.attrs))


def ck_mx(ck_e: Callable, ck_r: Callable, s: Sym, m: tuple):
    """``Source.ckMx``: read a math entry's text back (``None`` when it does not
    read)."""
    tag = m[0]
    if tag == "eq":
        es = ck_e(s, m[2])
        return None if es is None else [("eq", m[1], e) for e in es]
    if tag == "rxn":
        j = ck_r(s, m[1].rate)
        return None if j is None else [("rxn", m[1].with_rate(j))]
    if tag == "plot":
        return [m]
    t = m[1]
    sc = t.scope(s)
    lhs = None
    if t.lhs is not None:
        lhs = ck_r(t.mscope(s), t.lhs)
        if lhs is None:
            return None
    body = ck_r(sc, t.body)
    if body is None:
        return None
    return [("tm", Tm(t.name, t.params, lhs, body, t.attrs))]


# ## Equations as math (Equation.lean)


def eq_expr(e: Eqn) -> Obj:
    """``Source.eqExpr``: the expression an equation is printed as."""
    return Obj([("args", [e.lhs, e.rhs]), ("op", "==")])


def eq_sides(j: Any):
    """``Source.eqSides``: the equation sides of a parsed ``==`` node."""
    if type(j) is Obj and len(j) == 2:
        (a, xs), (o, op) = j
        if a == "args" and o == "op" and op == "==" and type(xs) is list and len(xs) == 2:
            return xs[0], xs[1]
    return None


# ## Reaction sides (Reaction.lean)


class RSurf:
    """``Source.RSurf``: how a math piece prints and reads back (under the empty
    symbol table), and the content of the empty-set piece."""

    __slots__ = ("pm", "prm", "empty")

    def __init__(self, pm: Callable, prm: Callable, empty: str):
        self.pm = pm
        self.prm = prm
        self.empty = empty


def _is_alnum_c(c: str) -> bool:
    return is_letter(c) or is_dig(c)


def _species_txt(r: RSurf, n: str) -> str:
    if is_formula(n):
        return n
    return "$" + r.prm(n) + "$"


def _term_txt(r: RSurf, t: tuple) -> str:
    sp, coef = t
    out = "" if (type(coef) is int and coef == 1) else "$" + r.prm(coef) + "$ "
    return out + _species_txt(r, sp)


def side_txt(r: RSurf, s) -> str:
    """``Source.sideTxt``."""
    if s is None:
        return "$" + r.empty + "$"
    return " + ".join(_term_txt(r, t) for t in s)


def _term_ok(r: RSurf, t: tuple) -> bool:
    sp, coef = t
    ps = r.prm(sp)
    if not name_ok(sp):
        return False
    if not (is_formula(sp) or ("$" not in ps and ps != r.empty)):
        return False
    if type(coef) is int and coef == 1:
        return True
    pc = r.prm(coef)
    return num_ok(coef) and "$" not in pc and pc != r.empty


def side_ok(r: RSurf, s) -> bool:
    """``Source.sideOK``."""
    if s is None:
        return True
    return bool(s) and all(_term_ok(r, t) for t in s)


def id_char(c: str) -> bool:
    """``Source.idChar``."""
    return is_ident_char(c) or c in "-.:"


def id_ok(i: str) -> bool:
    """``Source.idOK``: a reaction id the containers spell as a label."""
    return i != "" and all(id_char(c) for c in i)


def p_piece(s: str, i: int):
    """``Source.pPiece``: the text up to the next ``$``, and the position after
    it."""
    j = s.find("$", i)
    if j < 0:
        return None
    return s[i:j], j + 1


def _p_species(r: RSurf, s: str, i: int):
    if s.startswith("$", i):
        p = p_piece(s, i + 1)
        if p is None:
            return None
        n = r.pm(p[0])
        return (n, p[1]) if type(n) is str else None
    j = i
    while j < len(s) and _is_alnum_c(s[j]):
        j += 1
    return None if j == i else (s[i:j], j)


def _p_term(r: RSurf, s: str, i: int):
    if s.startswith("$", i):
        p = p_piece(s, i + 1)
        if p is None:
            return None
        v = r.pm(p[0])
        if type(v) is int or type(v) is Dec:
            # a number: the coefficient, then a space and the species
            if not s.startswith(" ", p[1]):
                return None
            sp = _p_species(r, s, p[1] + 1)
            return None if sp is None else ((sp[0], v), sp[1])
        if type(v) is str:
            return (v, 1), p[1]
        return None
    sp = _p_species(r, s, i)
    return None if sp is None else ((sp[0], 1), sp[1])


def _p_terms(r: RSurf, s: str, i: int):
    out = []
    while True:
        t = _p_term(r, s, i)
        if t is None:
            return None
        out.append(t[0])
        if s.startswith(" + ", t[1]):
            i = t[1] + 3
        else:
            return out, t[1]


def p_side(r: RSurf, s: str, i: int):
    """``Source.pSide``: the empty-set piece (``None``), or terms; ``(side,
    position)`` or ``None`` when it does not read (so the caller tests the pair)."""
    if s.startswith("$", i):
        p = p_piece(s, i + 1)
        if p is None:
            return None
        if p[0] == r.empty:
            return None, p[1]
    return _p_terms(r, s, i)


# ## Multi-line equations (MultiLine.lean)

_OPEN_KW = frozenset({K.LP, K.LPG, K.LB, K.LBK, K.BCASES, K.BMAT, K.LBKG, K.BARR})
_CLOSE_KW = frozenset({K.RP, K.RPG, K.RB, K.RBK, K.ECASES, K.EMAT, K.RBKG, K.EARR})


def _delta(t: Any) -> int:
    if type(t) is str:
        if t in _OPEN_KW:
            return 1
        if t in _CLOSE_KW:
            return -1
    elif t[0] == "arrc":
        return 1
    return 0


def _cut(k: str, ts: list):
    """``Source.cut``: cut at the first ``k`` at depth 0: ``(before, after)`` with
    ``after`` ``None`` when there is none."""
    d = 0
    for i, t in enumerate(ts):
        if d == 0 and t == k:
            return ts[:i], ts[i + 1 :]
        d += _delta(t)
    return ts, None


def _split_all(k: str, ts: list) -> list:
    out = []
    while True:
        a, r = _cut(k, ts)
        if r is None:
            out.append(ts)
            return out
        out.append(a)
        ts = r


def _group(one: bool, rows: list):
    """``Source.group``: rows into equations (``one``: all rows are one
    equation)."""
    acc: list = []
    for row in rows:
        left, r = _cut(K.AMP, row)
        if r is None:
            if not left:
                continue
            if one and acc:
                acc[-1] = acc[-1] + left
            else:
                acc.append(list(left))
            continue
        if _cut(K.AMP, r)[1] is not None:
            return None
        if not left and not one:
            if not acc:
                return None
            if r and r[0] == K.EQ:
                return None
            acc[-1] = acc[-1] + r
        elif one and acc:
            acc[-1] = acc[-1] + left + r
        else:
            acc.append(left + r)
    return acc


def cook_rows(sf: str, s: Sym, one: bool, ts: list):
    """``Source.cookRows``: read the rows of a multi-line display into
    equations."""
    eqs = _group(one, _split_all(K.NL, ts))
    if eqs is None:
        return None
    out = []
    for t in eqs:
        r = parse_toks(sf, s, t)
        if r is None:
            return None
        sides = eq_sides(r[0])
        if sides is None:
            return None
        out.append(Eqn(None, sides[0], sides[1]))
    return out
