"""The parser: tokens to expressions.

Port of ``formal/Esm/Document/Math/Parse.lean`` (and ``parseToks`` from
Induct.lean). Recursive descent with one function per precedence level (see
:mod:`.printer`), each taking fuel exactly as in Lean: a function at fuel 0 fails,
and every call passes on the fuel its Lean definition passes. The chain loops
(``orLoop``, ``addLoop``, …) are loops here, spending one unit of fuel per
iteration as the Lean recursion does.

Every reader takes the token list and a position and returns ``(value, position
after)`` or ``None``.
"""

from __future__ import annotations

from typing import Any, Callable

from .. import limits
from ..value import Dec, Obj
from . import token as K
from . import units as U
from .expr import DEPRECATED_OPS, REMOVED_SET, is_formula, is_greek, is_letter, op_ok, pieces
from .printer import (
    BMAT_MAX_COLS,
    CALL_OPS,
    Ctx,
    FaqForm,
    MkForm,
    faq_json,
    formula_raw,
    ins_kv,
    mk_json,
    mk_node,
    node,
    prints_call_form,
    simple_tok,
    tname_ok,
    tparams,
    unesc_k,
    unesc_t,
)
from .surface import neg_num

# ## Small pieces


def _at(ts: list, i: int) -> Any:
    return ts[i] if i < len(ts) else None


def _tag(t: Any) -> Any:
    return t[0] if type(t) is tuple else None


def close(o: str, xs: list) -> Any:
    """``Math.close``: one operand is itself, more make a node."""
    return xs[0] if len(xs) == 1 else node(o, xs)


CMP_OF = {K.LT: "<", K.LE: "<=", K.GT: ">", K.GE: ">=", K.EQ: "==", K.NE: "!="}

FN_OF = {
    K.EXP: "exp",
    K.LN: "log",
    K.SIN: "sin",
    K.COS: "cos",
    K.TAN: "tan",
    K.ASIN: "asin",
    K.ACOS: "acos",
    K.ATAN: "atan",
    K.SINH: "sinh",
    K.COSH: "cosh",
    K.TANH: "tanh",
}

_ATOM_START_TAGS = frozenset(
    {"num", "letter", "greek", "word", "it", "rm", "ups", "opn", "txt", "esc"}
)
_ATOM_START_KW = frozenset(
    {
        K.LPG, K.LP, K.LBK, K.LNOT, K.FRAC, K.SQRT, K.EXP, K.LN, K.LOG, K.SIN, K.COS, K.TAN,
        K.ASIN, K.ACOS, K.ATAN, K.SINH, K.COSH, K.TANH, K.MIN, K.MAX, K.LABS, K.LFLOOR,
        K.LCEIL, K.ABS, K.FLOOR, K.CEIL, K.DOTACC, K.BCASES, K.CASES, K.ESMNODE, K.BMAT,
        K.VEC, K.MAT, K.SUM, K.PROD, K.LIMITS, K.LBKG, K.LR, K.NABLA, K.PDIFF,
    }
)  # fmt: skip


def atom_start(t: Any) -> bool:
    """``Math.atomStart``: tokens that can start an operand of a product."""
    if type(t) is str:
        return t in _ATOM_START_KW
    if type(t) is tuple:
        return t[0] in _ATOM_START_TAGS
    return False


def is_lp(t: Any) -> bool:
    return t == K.LP or t == K.LPG


def is_rp(t: Any) -> bool:
    return t == K.RP or t == K.RPG


# ## Names


def _decode_formula(raw: str) -> str:
    return "".join(c for c in raw if c not in "_{}")


def formula_of(sf: str, t: Any) -> str | None:
    """``Math.formulaOf``: the name a formula token spells, if it is
    formula-shaped."""
    tag = _tag(t)
    if tag == "rm" and sf == K.LATEX:
        g = _decode_formula(t[1])
        if is_formula(g) and formula_raw(g) == t[1]:
            return g
    elif tag == "ups" and sf == K.TYPST:
        g = "".join(a + b for a, b in t[1])
        if is_formula(g) and tuple(pieces(g)) == tuple(t[1]):
            return g
    return None


def _sub_or_plain(sf: str, b: str, ts: list, i: int) -> tuple:
    """``Math.subOrPlain``: an optional upright name subscript after a base."""
    if _at(ts, i) == K.US:
        if sf == K.LATEX:
            t3 = _at(ts, i + 2)
            if _at(ts, i + 1) == K.LB and _tag(t3) == "rm" and _at(ts, i + 3) == K.RB:
                return b + "_" + unesc_t(t3[1]), i + 4
        else:
            t3 = _at(ts, i + 2)
            if (
                _at(ts, i + 1) == K.LPG
                and _tag(t3) == "ups"
                and _at(ts, i + 3) == K.RP
                and len(t3[1]) == 1
                and t3[1][0][1] == ""
            ):
                return b + "_" + t3[1][0][0], i + 4
    return b, i


def p_seg(sf: str, ts: list, i: int):
    """``Math.pSeg``: one name segment."""
    t = _at(ts, i)
    tag = _tag(t)
    if tag == "letter":
        return _sub_or_plain(sf, t[1], ts, i + 1) if is_letter(t[1]) else None
    if tag == "greek":
        return _sub_or_plain(sf, t[1], ts, i + 1) if is_greek(t[1]) else None
    if tag == "it":
        return t[1], i + 1
    if t is None:
        return None
    g = formula_of(sf, t)
    return None if g is None else (g, i + 1)


def p_name(sf: str, ts: list, i: int):
    """``Math.pName``: segments joined by the scope dot."""
    r = p_seg(sf, ts, i)
    if r is None:
        return None
    acc, i = r
    while _at(ts, i) == K.SDOT:
        r = p_seg(sf, ts, i + 1)
        if r is None:
            return None
        acc = acc + "." + r[0]
        i = r[1]
    return acc, i


# ## JSON inside LaTeX escape nodes


def p_json(f: int, ts: list, i: int):
    """``Math.pJson``."""
    if f == 0:
        return None
    f -= 1
    if not limits.enter():
        return None
    try:
        t = _at(ts, i)
        tag = _tag(t)
        if tag == "word":
            if t[1] == "null":
                return None, i + 1
            if t[1] == "true":
                return True, i + 1
            if t[1] == "false":
                return False, i + 1
            return None
        if tag == "num" or tag == "jstr":
            return t[1], i + 1
        if t == K.LBK:
            if _at(ts, i + 1) == K.RBK:
                return [], i + 2
            r = _p_json_items(f, ts, i + 1)
            if r is not None and _at(ts, r[1]) == K.RBK:
                return r[0], r[1] + 1
            return None
        if t == K.LB:
            if _at(ts, i + 1) == K.RB:
                return Obj(), i + 2
            r = _p_json_entries(f, ts, i + 1)
            if r is not None and _at(ts, r[1]) == K.RB:
                return Obj(r[0]), r[1] + 1
            return None
        return None
    finally:
        limits.leave()


def _p_json_items(f: int, ts: list, i: int):
    out = []
    while True:
        if f == 0:
            return None
        f -= 1
        r = p_json(f, ts, i)
        if r is None:
            return None
        out.append(r[0])
        if _at(ts, r[1]) == K.COMMA:
            i = r[1] + 1
        else:
            return out, r[1]


def _p_json_entries(f: int, ts: list, i: int):
    out = []
    while True:
        if f == 0:
            return None
        f -= 1
        t = _at(ts, i)
        if _tag(t) != "jstr" or _at(ts, i + 1) != K.COLON:
            return None
        r = p_json(f, ts, i + 2)
        if r is None:
            return None
        out.append((t[1], r[0]))
        if _at(ts, r[1]) == K.COMMA:
            i = r[1] + 1
        else:
            return out, r[1]


# ## Negative literals after an operand


def neg_tok(t: Any) -> bool:
    """``Math.negTok``: a negative literal token."""
    return _tag(t) == "num" and neg_num(t[1])


def negate(n: Any) -> Any:
    """``Math.negate``: the number with the opposite sign."""
    if type(n) is int:
        return -n
    return Dec(not n.neg, n.digits, n.e10)


# ## Expressions


def _all_pos(xs: list):
    if all(a[0] == "pos" for a in xs):
        return [a[1] for a in xs]
    return None


def _all_named(xs: list):
    if all(a[0] == "named" for a in xs):
        return [(a[1], a[2]) for a in xs]
    return None


def sort_kv(xs: list) -> list:
    """``Math.sortKV``: sort bindings by key (equal keys keep their order)."""
    out: list = []
    for kv in reversed(xs):
        out = ins_kv(kv, out)
    return out


def units_of_raw(raw: str):
    """``Math.unitsOfRaw``: the unit a LaTeX ``\\mathrm{…}`` after a number
    spells."""
    return U.parse_latex(U.MATHRM_OPEN + raw + "}")


def qty(n: Any, fs: tuple) -> Obj:
    """``Math.qty``: a quantity node."""
    return Obj([("args", []), ("op", "const"), ("units", U.spell(fs)), ("value", n)])


def d_node(x: Any, w: str) -> Obj:
    """``Math.dNode``: a time-derivative node (``d_node(x, "t")``)."""
    return Obj([("args", [x]), ("op", "D"), ("wrt", w)])


def p_node(x: Any, w: str) -> Obj:
    """``Math.pNode``: a ``partial`` node, the spatial derivative (spec §4.2)."""
    return Obj([("args", [x]), ("op", "partial"), ("wrt", w)])


def deriv_node(x: Any, w: str) -> Obj:
    """``Math.derivNode``: the derivative a fraction of differentials reads as:
    the time derivative ``D`` along ``t``, ``partial`` along any other axis."""
    return d_node(x, "t") if w == "t" else p_node(x, w)


def nab_tail(sf: str, ts: list, i: int) -> tuple:
    """``Math.nabTail``: after ``\\nabla``, which form it is (``\\cdot`` div,
    ``\\times`` curl, ``^{2}`` laplacian, nothing grad) and where its operand
    starts."""
    t = _at(ts, i)
    if t == K.CDOT:
        return "div", i + 1
    if t == K.TIMES:
        return "curl", i + 1
    if t == K.CARET:
        if sf == K.LATEX:
            if _at(ts, i + 1) == K.LB and _is_int(_at(ts, i + 2), 2) and _at(ts, i + 3) == K.RB:
                return "laplacian", i + 4
        elif _is_int(_at(ts, i + 1), 2):
            return "laplacian", i + 2
    return "grad", i


def t_node(n: str, bs: list) -> Obj:
    """``Math.tNode``: a template application node."""
    return Obj([("args", []), ("bindings", Obj(bs)), ("name", n), ("op", "apply_operator")])


def const_node(v: Any, u: str | None) -> Obj:
    """``Math.constNode``: the value, and the units when there are some."""
    if u is None:
        return Obj([("args", []), ("op", "const"), ("value", v)])
    return Obj([("args", []), ("op", "const"), ("units", u), ("value", v)])


def _p_cells(sep: str, ts: list, i: int):
    """``Math.pCells``: numbers separated by ``sep``, up to the first other
    token."""
    out = []
    while True:
        t = _at(ts, i)
        if _tag(t) != "num":
            return None
        out.append(t[1])
        t2 = _at(ts, i + 1)
        if type(t2) is str and t2 == sep:
            i += 2
            continue
        return out, i + 1


def _p_grid(csep: str, rsep: str, close_k: str, ts: list, i: int):
    """``Math.pGrid``: rows of numbers."""
    out = []
    while True:
        r = _p_cells(csep, ts, i)
        if r is None:
            return None
        t = _at(ts, r[1])
        if type(t) is not str:
            return None
        out.append(r[0])
        if t == rsep:
            i = r[1] + 1
        elif t == close_k:
            return out, r[1] + 1
        else:
            return None


def _grid_json(rows: list) -> list:
    """``Math.gridJson``: one cell per row is a column (rank 1)."""
    if all(len(r) == 1 for r in rows):
        return [r[0] for r in rows]
    return [list(r) for r in rows]


def _const_tail(v: Any, ts: list, i: int):
    t = _at(ts, i)
    if _tag(t) == "units":
        return const_node(v, U.spell(t[1])), i + 1
    return const_node(v, None), i


def _ic_tail_p(sf: str, ts: list, i: int):
    """``Math.icTailP``: the ``ic`` tail ``(t_{0})`` / ``(t_0)``."""
    if _at(ts, i) == K.LP and _at(ts, i + 1) == ("letter", "t") and _at(ts, i + 2) == K.US:
        j = i + 3
        if sf == K.LATEX:
            if (
                _at(ts, j) == K.LB
                and _is_int(_at(ts, j + 1), 0)
                and _at(ts, j + 2) == K.RB
                and _at(ts, j + 3) == K.RP
            ):
                return j + 4
        elif _is_int(_at(ts, j), 0) and _at(ts, j + 1) == K.RP:
            return j + 2
    return None


def _is_int(t: Any, v: int) -> bool:
    return _tag(t) == "num" and type(t[1]) is int and t[1] == v


def _json_start(ts: list, i: int) -> bool:
    t = _at(ts, i)
    return t == K.LB or t == K.LBK or _tag(t) == "jstr" or _tag(t) == "word"


def _key_of(c: Ctx, ts: list, i: int):
    """``Math.keyOf``: LaTeX ``\\mathrm{key} =``, Typst ``upright("key") =``."""
    t = _at(ts, i)
    if _at(ts, i + 1) != K.EQ:
        return None
    if c.sf == K.LATEX:
        if _tag(t) == "rm":
            return unesc_k(t[1]), i + 2
    elif _tag(t) == "ups" and len(t[1]) == 1 and t[1][0][1] == "":
        return t[1][0][0], i + 2
    return None


def _declared(c: Ctx, n: str) -> bool:
    return n in c.s.names


def _euler_head(c: Ctx, ts: list, i: int) -> bool:
    """``Math.eulerHead``: the input starts with Euler's number raised to a
    power."""
    if _at(ts, i + 1) != K.CARET:
        return False
    t = _at(ts, i)
    tag = _tag(t)
    if tag == "rm":
        return t[1] == "e"
    if tag == "ups":
        return len(t[1]) == 1 and t[1][0][0] == "e" and t[1][0][1] == ""
    if tag == "letter":
        return t[1] == "e" and not _declared(c, "e")
    return False


def _p_name_prim(c: Ctx, ts: list, i: int):
    """``Math.pNamePrim``: a name, or an initial condition ``N(t_{0})``."""
    r = p_name(c.sf, ts, i)
    if r is None:
        return None
    j = _ic_tail_p(c.sf, ts, r[1])
    if j is not None:
        return node("ic", [r[0]]), j
    return r


def _p_word(c: Ctx, w: str, i: int):
    """``Math.pWord``: the declared name when only it is declared, the product of
    its letters when only they are."""
    whole = _declared(c, w)
    letters = all(_declared(c, ch) for ch in w)
    if whole and not letters:
        return w, i
    if letters and not whole:
        return node("*", list(w)), i
    return None


def _d_name(c: Ctx, k: str, ts: list, i: int):
    """``Math.dName``: ``d`` then a name, up to a closing token ``k``."""
    t = _at(ts, i)
    tag = _tag(t)
    if tag == "word":
        if _at(ts, i + 1) == k and not _declared(c, t[1]) and t[1][0] == "d":
            return t[1][1:], i + 2
        return None
    if t == ("letter", "d"):
        r = p_name(c.sf, ts, i + 1)
        if r is not None and _at(ts, r[1]) == k:
            return r[0], r[1] + 1
    return None


def _p_italic_d(c: Ctx, ts: list, i: int):
    """``Math.pItalicD``: the italic-d derivative variant."""
    if _declared(c, "d"):
        return None
    if c.sf == K.LATEX:
        r = _d_name(c, K.RB, ts, i)
        if r is not None and _at(ts, r[1]) == K.LB:
            r2 = _d_name(c, K.RB, ts, r[1] + 1)
            if r2 is not None:
                return deriv_node(r[0], r2[0]), r2[1]
        return None
    r = _d_name(c, K.RP, ts, i)
    if r is not None and _at(ts, r[1]) == K.SLASH and _at(ts, r[1] + 1) == K.LPG:
        r2 = _d_name(c, K.RP, ts, r[1] + 2)
        if r2 is not None:
            return deriv_node(r[0], r2[0]), r2[1]
    return None


_RED_OF = {K.SUM: "sum", K.PROD: "prod", K.MAX: "max", K.MIN: "min"}


def _p_red_head(sf: str, ts: list, i: int):
    """``Math.pRedHead``: the operator of a reduction and whether it is marked."""
    t = _at(ts, i)
    if type(t) is not str:
        return None
    t2 = _at(ts, i + 2)
    if t == K.LIMITS and _at(ts, i + 1) == K.LP and type(t2) is str and _at(ts, i + 3) == K.RP:
        if sf == K.TYPST and t2 in _RED_OF:
            return _RED_OF[t2], True, i + 4
        return None
    red = _RED_OF.get(t)
    if red is None:
        return None
    if _at(ts, i + 1) == K.LIMITS_L and sf == K.LATEX:
        return red, True, i + 2
    return red, False, i + 1


def _p_names(sf: str, ts: list, i: int):
    """``Math.pNames``: names separated by commas."""
    out = []
    while True:
        r = p_name(sf, ts, i)
        if r is None:
            return None
        out.append(r[0])
        if _at(ts, r[1]) == K.COMMA:
            i = r[1] + 1
        else:
            return out, r[1]


def _row_parts(rows: list):
    """``Math.rowParts``: ranges, then at most one filter, last."""
    rg = []
    fl: Any = _NOFILTER
    n = len(rows)
    for i, row in enumerate(rows):
        if row[0] == "rng":
            rg.append((row[1], row[2]))
        elif i + 1 == n:
            fl = row[1]
        else:
            return None
    return rg, fl


_NOFILTER = object()


def _entry_parts(rows: list):
    """``Math.entryParts``: the output entries of a list of entry rows, with their
    ranges."""
    outs = []
    rs = []
    for row in rows:
        if row[0] == "rng":
            outs.append(row[1])
            rs.append((row[1], row[2]))
        else:
            x = row[1]
            if type(x) is str:
                outs.append(x)
            elif type(x) is int and x == 1:
                outs.append(1)
            else:
                return None
    return outs, rs


# ## The level parsers


def p_or(c: Ctx, f: int, ts: list, i: int):
    """``Math.pOr``: level 1, an ``or`` chain."""
    if f == 0:
        return None
    f -= 1
    r = p_and(c, f, ts, i)
    if r is None:
        return None
    acc = [r[0]]
    i = r[1]
    while True:
        if f == 0:
            return None
        f -= 1
        if _at(ts, i) == K.LOR:
            r = p_and(c, f, ts, i + 1)
            if r is None:
                return None
            acc.append(r[0])
            i = r[1]
        else:
            return close("or", acc), i


def p_and(c: Ctx, f: int, ts: list, i: int):
    """``Math.pAnd``: level 2, an ``and`` chain."""
    if f == 0:
        return None
    f -= 1
    r = p_cmp(c, f, ts, i)
    if r is None:
        return None
    acc = [r[0]]
    i = r[1]
    while True:
        if f == 0:
            return None
        f -= 1
        if _at(ts, i) == K.LAND:
            r = p_cmp(c, f, ts, i + 1)
            if r is None:
                return None
            acc.append(r[0])
            i = r[1]
        else:
            return close("and", acc), i


def p_cmp(c: Ctx, f: int, ts: list, i: int):
    """``Math.pCmp``: level 3, one comparison."""
    if f == 0:
        return None
    f -= 1
    r = p_add(c, f, ts, i)
    if r is None:
        return None
    x, i = r
    if f == 0:
        return None
    f -= 1
    t = _at(ts, i)
    o = CMP_OF.get(t) if type(t) is str else None
    if o is None:
        return x, i
    r = p_add(c, f, ts, i + 1)
    if r is None:
        return None
    return node(o, [x, r[0]]), r[1]


def p_add(c: Ctx, f: int, ts: list, i: int):
    """``Math.pAdd``: level 4, ``+`` chains and binary ``-``. After a negative
    literal right after an operand (``negTail``), the list is read with the
    number's sign removed, as Lean does."""
    if f == 0:
        return None
    f -= 1
    r = p_mul(c, f, ts, i)
    if r is None:
        return None
    acc = [r[0]]
    i = r[1]
    while True:
        if f == 0:
            return None
        f -= 1
        t = _at(ts, i)
        if t == K.PLUS:
            r = p_mul(c, f, ts, i + 1)
            if r is None:
                return None
            acc.append(r[0])
            i = r[1]
        elif t == K.MINUS:
            r = p_mul(c, f, ts, i + 1)
            if r is None:
                return None
            x = limits.shallow(node("-", [close("+", acc), r[0]]))
            if x is None:
                return None
            acc = [x]
            i = r[1]
        elif _tag(t) == "num" and neg_num(t[1]):
            from ..value import num_wf

            m = negate(t[1])
            if not num_wf(m):
                return close("+", acc), i
            ts2 = list(ts)
            ts2[i] = ("num", m)
            r = p_mul(c, f, ts2, i)
            if r is None:
                return None
            x = limits.shallow(node("-", [close("+", acc), r[0]]))
            if x is None:
                return None
            acc = [x]
            i = r[1]
        else:
            return close("+", acc), i


def p_mul(c: Ctx, f: int, ts: list, i: int):
    """``Math.pMul``: level 5, unary minus and ``*`` chains."""
    if f == 0:
        return None
    f -= 1
    if not limits.enter():
        return None
    try:
        if _at(ts, i) == K.MINUS:
            r = p_mul(c, f, ts, i + 1)
            return None if r is None else (node("-", [r[0]]), r[1])
        r = p_not(c, f, ts, i)
        if r is None:
            return None
        acc = [r[0]]
        i = r[1]
        while True:
            if f == 0:
                return None
            f -= 1
            t = _at(ts, i)
            if t == K.CDOT or t == K.TIMES:
                r = p_not(c, f, ts, i + 1)
                if r is None:
                    return None
                acc.append(r[0])
                i = r[1]
            elif t == K.SLASH:
                if c.sf != K.LATEX:
                    return close("*", acc), i
                r = p_not(c, f, ts, i + 1)
                if r is None:
                    return None
                x = limits.shallow(node("/", [close("*", acc), r[0]]))
                if x is None:
                    return None
                acc = [x]
                i = r[1]
            elif t is not None and atom_start(t) and not neg_tok(t):
                r = p_not(c, f, ts, i)
                if r is None:
                    return None
                acc.append(r[0])
                i = r[1]
            else:
                return close("*", acc), i
    finally:
        limits.leave()


def p_not(c: Ctx, f: int, ts: list, i: int):
    """``Math.pNot``: level 6, ``not``, and the ``\\nabla`` forms, whose operand is
    read at level 9."""
    if f == 0:
        return None
    f -= 1
    if not limits.enter():
        return None
    try:
        t = _at(ts, i)
        if t == K.LNOT:
            r = p_not(c, f, ts, i + 1)
            return None if r is None else (node("not", [r[0]]), r[1])
        if t == K.NABLA:
            o, j = nab_tail(c.sf, ts, i + 1)
            r = _p_nab_arg(c, f, ts, j)
            return None if r is None else (node(o, [r[0]]), r[1])
        return p_frac(c, f, ts, i)
    finally:
        limits.leave()


def _p_nab_arg(c: Ctx, f: int, ts: list, i: int):
    """``Math.pNabArg``: the operand of a ``\\nabla`` form: another ``\\nabla``
    form, or a postfix-level operand."""
    if f == 0:
        return None
    f -= 1
    if _at(ts, i) == K.NABLA:
        return p_not(c, f, ts, i)
    return p_post(c, f, ts, i)


def p_frac(c: Ctx, f: int, ts: list, i: int):
    """``Math.pFrac``: level 7, the Typst fraction, grouping to the left."""
    if f == 0:
        return None
    f -= 1
    r = p_pow(c, f, ts, i)
    if r is None:
        return None
    x, i = r
    while True:
        if f == 0:
            return None
        f -= 1
        if c.sf == K.TYPST and _at(ts, i) == K.SLASH:
            r = p_pow(c, f, ts, i + 1)
            if r is None:
                return None
            x = limits.shallow(node("/", [x, r[0]]))
            if x is None:
                return None
            i = r[1]
        else:
            return x, i


def p_pow(c: Ctx, f: int, ts: list, i: int):
    """``Math.pPow``: level 8, a power."""
    if f == 0:
        return None
    f -= 1
    r = p_post(c, f, ts, i)
    if r is None:
        return None
    if _at(ts, r[1]) == K.CARET:
        r2 = _p_expo(c, f, ts, r[1] + 1)
        return None if r2 is None else (node("^", [r[0], r2[0]]), r2[1])
    return r


def _p_expo(c: Ctx, f: int, ts: list, i: int):
    """``Math.pExpo``: LaTeX ``{…}``; Typst ``(…)`` or one simple token."""
    if f == 0:
        return None
    f -= 1
    t = _at(ts, i)
    if c.sf == K.LATEX:
        if t == K.LB:
            r = p_or(c, f, ts, i + 1)
            if r is not None and _at(ts, r[1]) == K.RB:
                return r[0], r[1] + 1
        return None
    if t == K.LPG:
        r = p_or(c, f, ts, i + 1)
        if r is not None and is_rp(_at(ts, r[1])):
            return r[0], r[1] + 1
        return None
    if t is not None and simple_tok(t):
        r = p_prim(c, f, [t], 0)
        if r is not None and r[1] == 1:
            return r[0], i + 1
    return None


def p_post(c: Ctx, f: int, ts: list, i: int):
    """``Math.pPost``: level 9, postfix index, ``_{…}`` or ``[…]``."""
    if f == 0:
        return None
    f -= 1
    r = p_prim(c, f, ts, i)
    if r is None:
        return None
    x, i = r
    while True:
        if f == 0:
            return None
        f -= 1
        t = _at(ts, i)
        if t == K.US:
            t1 = _at(ts, i + 1)
            if c.sf == K.LATEX:
                if t1 != K.LB:
                    return None
                r = p_list(c, f, 1, ts, i + 2)
                if r is None or _at(ts, r[1]) != K.RB or not r[0]:
                    return None
                x = node("index", [x, *r[0]])
                i = r[1] + 1
            elif t1 == K.LPG:
                r = p_list(c, f, 1, ts, i + 2)
                if r is None or not is_rp(_at(ts, r[1])) or not r[0]:
                    return None
                x = node("index", [x, *r[0]])
                i = r[1] + 1
            elif t1 is not None and simple_tok(t1):
                r = p_prim(c, f, [t1], 0)
                if r is None or r[1] != 1:
                    return None
                x = node("index", [x, r[0]])
                i += 2
            else:
                return None
        elif t == K.LBK:
            r = p_list(c, f, 1, ts, i + 1)
            if r is None or _at(ts, r[1]) != K.RBK or not r[0]:
                return None
            x = node("index", [x, *r[0]])
            i = r[1] + 1
        else:
            return x, i


def p_list(c: Ctx, f: int, level: int, ts: list, i: int):
    """``Math.pList``: a comma-separated list at level ``L`` (1 or 4), possibly
    empty when the next token closes it."""
    if f == 0:
        return None
    f -= 1
    t = _at(ts, i)
    if t is None or is_rp(t) or t == K.RB or t == K.RBK:
        return [], i
    return _p_items(c, f, level, ts, i)


def _p_items(c: Ctx, f: int, level: int, ts: list, i: int):
    out = []
    while True:
        if f == 0:
            return None
        f -= 1
        r = _p_lv(c, f, level, ts, i)
        if r is None:
            return None
        out.append(r[0])
        if _at(ts, r[1]) == K.COMMA:
            i = r[1] + 1
        else:
            return out, r[1]


def _p_lv(c: Ctx, f: int, level: int, ts: list, i: int):
    if f == 0:
        return None
    f -= 1
    return p_add(c, f, ts, i) if level == 4 else p_or(c, f, ts, i)


def _p_call_args(c: Ctx, f: int, ts: list, i: int):
    """``Math.pCallArgs``: each positional, or ``name = value``. An argument is
    ``("pos", v)`` or ``("named", k, v)``."""
    if f == 0:
        return None
    f -= 1
    t = _at(ts, i)
    if t == K.RP or t == K.SEMI:
        return [], i
    out: list = []
    while True:
        if f == 0:
            return None
        f -= 1
        r = p_add(c, f, ts, i)
        if r is None:
            return None
        x, j = r
        if type(x) is str and _at(ts, j) == K.EQ:
            r2 = p_add(c, f, ts, j + 1)
            if r2 is None:
                return None
            out.append(("named", x, r2[0]))
            j = r2[1]
        else:
            out.append(("pos", x))
        if _at(ts, j) == K.COMMA:
            i = j + 1
        else:
            return out, j


def _p_fields(c: Ctx, f: int, ts: list, i: int):
    """``Math.pFields``: open-operator fields after ``;``."""
    out = []
    while True:
        if f == 0:
            return None
        f -= 1
        k = _key_of(c, ts, i)
        if k is None:
            return None
        r = _p_val(c, f, ts, k[1])
        if r is None:
            return None
        out.append((k[0], r[0]))
        if _at(ts, r[1]) == K.COMMA:
            i = r[1] + 1
        else:
            return out, r[1]


def _p_val(c: Ctx, f: int, ts: list, i: int):
    """``Math.pVal``: JSON (LaTeX JSON tokens, Typst ``#value``) or an
    expression."""
    if f == 0:
        return None
    f -= 1
    if c.sf == K.TYPST:
        t = _at(ts, i)
        if _tag(t) == "code":
            return t[1], i + 1
        return p_add(c, f, ts, i)
    if _json_start(ts, i):
        return p_json(f, ts, i)
    return p_add(c, f, ts, i)


def _nodup_keys(xs: list) -> bool:
    return len({k for k, _ in xs}) == len(xs)


def _p_opn(c: Ctx, f: int, n: str, ts: list, i: int):
    """``Math.pOpn``: ``\\operatorname{n}(…)``."""
    if f == 0:
        return None
    f -= 1
    t0 = _at(ts, i)
    if t0 is None:
        return (t_node(n, []), i) if _bare_ok(c, n) else None
    if is_lp(t0):
        r = _p_call_args(c, f, ts, i + 1)
        if r is None:
            return None
        args, j = r
        tj = _at(ts, j)
        if tj == K.RP:
            j += 1
            if n in CALL_OPS:
                vs = _all_pos(args)
                return None if vs is None else (node(n, vs), j)
            if n == "neg":
                vs = _all_pos(args)
                return (node("-", vs), j) if vs is not None and len(vs) == 1 else None
            if n == "pow":
                vs = _all_pos(args)
                return (node("^", vs), j) if vs is not None and len(vs) == 2 else None
            if n in REMOVED_SET or n == "D":
                return None
            ps = tparams(c.s, n)
            vs = _all_pos(args)
            if ps is not None and vs is not None:
                if len(ps) == len(vs):
                    return t_node(n, sort_kv(list(zip(ps, vs)))), j
                return None
            bs = _all_named(args)
            if bs:
                return (t_node(n, sort_kv(bs)), j) if _nodup_keys(bs) else None
            if ps is None and vs is not None:
                return mk_node(n, vs, []), j
            return None
        if tj == K.SEMI:
            if n in REMOVED_SET:
                return None
            vs = _all_pos(args)
            fr = _p_fields(c, f, ts, j + 1)
            if vs is None or fr is None or _at(ts, fr[1]) != K.RP:
                return None
            ks = [k for k, _ in fr[0]]
            if "op" in ks or "args" in ks or not _nodup_keys(fr[0]):
                return None
            x = mk_node(n, vs, fr[0])
            # canonical only: the node the printer writes in this call form
            return (x, fr[1] + 1) if prints_call_form(c, x) else None
        return None
    if t0 == K.US:
        return _p_d_call(c, f, ts, i + 1) if n == "D" else None
    if _bare_ok(c, n):
        return t_node(n, []), i
    return None


def _bare_ok(c: Ctx, n: str) -> bool:
    """A bare ``\\operatorname{n}``: the template application with no bindings,
    which prints bare unless a template ``n`` with no parameters is in scope (that
    one prints ``\\operatorname{n}()``)."""
    if not tname_ok(n):
        return False
    ps = tparams(c.s, n)
    return ps is None or len(ps) > 0


def _p_d_call(c: Ctx, f: int, ts: list, i: int):
    """``Math.pDCall``: ``\\partial_{x}(u, a, b)``, and the earlier
    ``\\operatorname{D}_{x}(u, a, b)`` (read, never printed), after the ``_``:
    ``partial`` with trailing operands."""
    if f == 0:
        return None
    f -= 1
    t = _at(ts, i)
    if c.sf == K.LATEX:
        open_k, close_k = K.LB, K.RB
    else:
        open_k, close_k = K.LPG, K.RP
    if t != open_k:
        return None
    r = p_name(c.sf, ts, i + 1)
    if r is None or _at(ts, r[1]) != close_k:
        return None
    w, j = r[0], r[1] + 1
    if not is_lp(_at(ts, j)):
        return None
    r2 = _p_call_args(c, f, ts, j + 1)
    if r2 is None or _at(ts, r2[1]) != K.RP:
        return None
    xs = _all_pos(r2[0])
    if xs is None:
        return None
    return Obj([("args", xs), ("op", "partial"), ("wrt", w)]), r2[1] + 1


def _op_allowed(o: str) -> bool:
    return op_ok(o) and o not in REMOVED_SET and o not in DEPRECATED_OPS


def _note_removed_op(ts: list, i: int) -> None:
    """Record a removed operator written in the call or escape form at ``ts[i]``,
    so a refusal can name it (CONFORMANCE §7.1). Not in Lean, whose reader
    refuses every bad input alike."""
    t = _at(ts, i)
    if t == K.ESMNODE:
        t = _at(ts, i + 2)
        if _tag(t) != "txt" or _at(ts, i + 1) is None:
            return
    elif _tag(t) not in ("opn", "esc"):
        return
    if t[1] in REMOVED_SET:
        limits.removed_op(t[1])


def p_prim(c: Ctx, f: int, ts: list, i: int):
    """``Math.pPrim``: a primary."""
    if f == 0:
        return None
    f -= 1
    _note_removed_op(ts, i)
    t = _at(ts, i)
    if t is None:
        return None
    sf = c.sf
    if type(t) is tuple:
        tag = t[0]
        if tag == "num":
            t1 = _at(ts, i + 1)
            if _tag(t1) == "units":
                return qty(t[1], t1[1]), i + 2
            return t[1], i + 1
        if tag == "txt":
            if t[1] == "true":
                return node("true", []), i + 1
            if t[1] == "false":
                return node("false", []), i + 1
        elif tag == "opn":
            return _p_opn(c, f, t[1], ts, i + 1)
        elif tag == "esc":
            if _at(ts, i + 1) != K.LB:
                return _p_prim_name(c, f, ts, i)
            r = p_json(f, ts, i + 2)
            if (
                r is None
                or type(r[0]) is not Obj
                or _at(ts, r[1]) != K.RB
                or _at(ts, r[1] + 1) != K.LB
            ):
                return None
            r2 = p_list(c, f, 1, ts, r[1] + 2)
            if r2 is None or _at(ts, r2[1]) != K.RB:
                return None
            if not _op_allowed(t[1]):
                return None
            return mk_node(t[1], r2[0], list(r[0])), r2[1] + 1
        elif tag == "word":
            return _p_word(c, t[1], i + 1)
        return _p_prim_name(c, f, ts, i)
    # a keyword
    t1 = _at(ts, i + 1)
    if t == K.BMAT:
        r = _p_grid(K.AMP, K.NL, K.EMAT, ts, i + 1)
        if r is None or any(len(q) > BMAT_MAX_COLS for q in r[0]):
            return None
        return _const_tail(_grid_json(r[0]), ts, r[1])
    if t == K.LBKG and _tag(t1) == "arrc":
        # a matrix wider than ``bmatrix`` allows: one ``c`` per column
        r = _p_grid(K.AMP, K.NL, K.EARR, ts, i + 2)
        n = t1[1]
        if r is None or _at(ts, r[1]) != K.RBKG or n <= BMAT_MAX_COLS:
            return None
        if any(len(q) != n for q in r[0]):
            return None
        return _const_tail([list(q) for q in r[0]], ts, r[1] + 1)
    if t == K.VEC and t1 is not None:
        if not is_lp(t1):
            return None
        r = _p_cells(K.COMMA, ts, i + 2)
        if r is None or _at(ts, r[1]) != K.RP:
            return None
        return _const_tail(list(r[0]), ts, r[1] + 1)
    if t == K.MAT and t1 == K.LP and _mat_head(ts, i + 2):
        r = _p_mk_rows(c, f, K.COMMA, K.SEMI, K.RP, ts, i + 10)
        return None if r is None else _mk_tail(c.sf, r[0], ts, r[1])
    if t == K.MAT and t1 is not None:
        if not is_lp(t1):
            return None
        r = _p_grid(K.COMMA, K.SEMI, K.RP, ts, i + 2)
        if r is None:
            return None
        return _const_tail([list(q) for q in r[0]], ts, r[1])
    if t == K.LPG or t == K.LP:
        if sf == K.TYPST:
            if t1 == K.DIF:
                return _p_dt(c, f, K.DIF, ts, i + 2)
            if t1 == K.PDIFF and _at(ts, i + 2) == K.US:
                r = p_or(c, f, ts, i + 1)
                if r is not None and is_rp(_at(ts, r[1])):
                    return r[0], r[1] + 1
                return None
            if t1 == K.PDIFF:
                return _p_dt(c, f, K.PDIFF, ts, i + 2)
            if t1 == ("letter", "d"):
                r = _p_italic_d(c, ts, i + 1)
                if r is not None:
                    return r
        r = p_or(c, f, ts, i + 1)
        if r is not None and is_rp(_at(ts, r[1])):
            return r[0], r[1] + 1
        return None
    if t == K.LBK:
        r = p_or(c, f, ts, i + 1)
        if r is not None and _at(ts, r[1]) == K.RBK:
            return r[0], r[1] + 1
        return None
    if t == K.FRAC and t1 == K.LB:
        return _p_frac_l(c, f, ts, i + 2)
    if t == K.PDIFF and t1 == K.US:
        return _p_d_call(c, f, ts, i + 2)
    if t == K.SQRT:
        if sf == K.LATEX:
            if t1 == K.LB:
                return _closed(c, f, ts, i + 2, K.RB, "sqrt")
            return None
        if t1 is not None and is_lp(t1):
            return _p_fn1(c, f, "sqrt", ts, i + 2)
        return None
    if t == K.LOG and t1 == K.US:
        if sf == K.LATEX:
            if (
                _at(ts, i + 2) == K.LB
                and _is_int(_at(ts, i + 3), 10)
                and _at(ts, i + 4) == K.RB
                and _at(ts, i + 5) is not None
            ):
                if is_lp(_at(ts, i + 5)):
                    return _p_fn1(c, f, "log10", ts, i + 6)
                return None
            return None
        if _is_int(_at(ts, i + 2), 10) and _at(ts, i + 3) is not None:
            if is_lp(_at(ts, i + 3)):
                return _p_fn1(c, f, "log10", ts, i + 4)
            return None
        return None
    if t == K.LABS:
        return _closed(c, f, ts, i + 1, K.RABS, "abs")
    if t == K.LFLOOR:
        return _closed(c, f, ts, i + 1, K.RFLOOR, "floor")
    if t == K.LCEIL:
        return _closed(c, f, ts, i + 1, K.RCEIL, "ceil")
    if (t == K.MIN or t == K.MAX) and t1 is not None:
        if t1 == K.LP:
            r = p_list(c, f, 1, ts, i + 2)
            if r is not None and _at(ts, r[1]) == K.RP:
                if len(r[0]) >= 2:
                    return node("min" if t == K.MIN else "max", r[0]), r[1] + 1
                return None
            return None
        return _p_red(c, f, ts, i)
    if t == K.LBKG and t1 == K.BARR:
        r = _p_mk_rows(c, f, K.AMP, K.NL, K.EARR, ts, i + 2)
        if r is None or _at(ts, r[1]) != K.RBKG:
            return None
        return _mk_tail(c.sf, r[0], ts, r[1] + 1)
    if t in (K.SUM, K.PROD, K.LIMITS, K.LBKG):
        return _p_red(c, f, ts, i)
    if t == K.LR and t1 == K.LP and _at(ts, i + 2) == K.LBK:
        return _p_red(c, f, ts, i)
    if t == K.BCASES:
        return _p_cases(c, f, ts, i + 1)
    if t == K.CASES and t1 is not None:
        if is_lp(t1):
            return _p_cases(c, f, ts, i + 2)
        return None
    if t == K.ESMNODE:
        t2 = _at(ts, i + 2)
        t4 = _at(ts, i + 4)
        if (
            t1 is not None
            and _tag(t2) == "txt"
            and _at(ts, i + 3) == K.COMMA
            and _tag(t4) == "code"
            and type(t4[1]) is Obj
        ):
            if not is_lp(t1):
                return None
            r = _p_esc_args(c, f, ts, i + 5)
            if r is None:
                return None
            if not _op_allowed(t2[1]):
                return None
            return mk_node(t2[1], r[0], list(t4[1])), r[1]
    if t == K.DOTACC and t1 == K.LB:
        r = p_or(c, f, ts, i + 2)
        if r is not None and _at(ts, r[1]) == K.RB:
            return d_node(r[0], "t"), r[1] + 1
        return None
    if t == K.CDOT and t1 == K.LP:
        r = p_or(c, f, ts, i + 2)
        if r is not None and _at(ts, r[1]) == K.RP:
            return d_node(r[0], "t"), r[1] + 1
        return None
    if t1 is not None:
        if not is_lp(t1):
            return None
        if t == K.LOG:
            return _p_fn1(c, f, "log", ts, i + 2)
        if t == K.ABS:
            return _p_fn1(c, f, "abs", ts, i + 2)
        if t == K.FLOOR:
            return _p_fn1(c, f, "floor", ts, i + 2)
        if t == K.CEIL:
            return _p_fn1(c, f, "ceil", ts, i + 2)
        o = FN_OF.get(t)
        if o is not None:
            return _p_fn1(c, f, o, ts, i + 2)
        return None
    return _p_prim_name(c, f, ts, i)


def _p_prim_name(c: Ctx, f: int, ts: list, i: int):
    """The last case of ``Math.pPrim``: ``e`` raised to a power, or a name."""
    if _euler_head(c, ts, i):
        return _p_euler_exp(c, f, ts, i + 2)
    return _p_name_prim(c, ts, i)


def _closed(c: Ctx, f: int, ts: list, i: int, k: str, o: str):
    r = p_or(c, f, ts, i)
    if r is not None and _at(ts, r[1]) == k:
        return node(o, [r[0]]), r[1] + 1
    return None


def _p_euler_exp(c: Ctx, f: int, ts: list, i: int):
    """``Math.pEulerExp``: ``\\exp`` written as a power of e."""
    if f == 0:
        return None
    f -= 1
    r = _p_expo(c, f, ts, i)
    return None if r is None else (node("exp", [r[0]]), r[1])


def _p_set(sf: str, ts: list, i: int):
    """``Math.pSet``: a name, or in Typst one upright word."""
    r = p_name(sf, ts, i)
    if r is not None:
        return r
    t = _at(ts, i)
    if sf == K.TYPST and _tag(t) == "ups" and len(t[1]) == 1 and t[1][0][1] == "":
        return t[1][0][0], i + 1
    return None


def _p_range(c: Ctx, f: int, ts: list, i: int):
    """``Math.pRange``: ``k \\in S``, ``k \\in S(i, j)``, ``a \\le k \\le b``.
    A row is ``("rng", k, value)`` or ``("filt", value)``."""
    if f == 0:
        return None
    f -= 1
    r = p_add(c, f, ts, i)
    if r is None:
        return None
    x, j = r
    tj = _at(ts, j)
    if type(x) is str and tj == K.INN:
        r2 = _p_set(c.sf, ts, j + 1)
        if r2 is None:
            return None
        s, k = r2
        if _at(ts, k) == K.LP:
            r3 = _p_names(c.sf, ts, k + 1)
            if r3 is not None and _at(ts, r3[1]) == K.RP:
                return ("rng", x, Obj([("from", s), ("of", list(r3[0]))])), r3[1] + 1
            return None
        return ("rng", x, Obj([("from", s)])), k
    if tj == K.LE:
        r2 = p_add(c, f, ts, j + 1)
        if r2 is not None and type(r2[0]) is str and _at(ts, r2[1]) == K.LE:
            r3 = p_add(c, f, ts, r2[1] + 1)
            if r3 is None:
                return None
            return ("rng", r2[0], [x, r3[0]]), r3[1]
        return None
    return None


def _p_row(c: Ctx, f: int, is_end: Callable, ts: list, i: int):
    """``Math.pRow``: an expression read whole first, else a range."""
    if f == 0:
        return None
    f -= 1
    r = p_or(c, f, ts, i)
    if r is not None and r[1] < len(ts):
        if is_end(ts[r[1]]):
            return ("filt", r[0]), r[1]
    return _p_range(c, f, ts, i)


def _p_rows(c: Ctx, f: int, sep: str, close_k: str, ts: list, i: int):
    """``Math.pRows``: rows separated by ``sep``, up to ``close`` (consumed)."""
    out = []

    def is_end(t: Any) -> bool:
        return t == sep or t == close_k

    while True:
        if f == 0:
            return None
        f -= 1
        r = _p_row(c, f, is_end, ts, i)
        if r is None:
            return None
        t = _at(ts, r[1])
        if type(t) is not str:
            return None
        out.append(r[0])
        if t == sep:
            i = r[1] + 1
        elif t == close_k:
            return out, r[1] + 1
        else:
            return None


def _lone_eq(x: Any):
    """The ``.obj [("args", .arr [.str k, a]), ("op", .str "==")]`` pattern."""
    if type(x) is Obj and len(x) == 2:
        (ka, xs), (ko, o) = x
        if ka == "args" and ko == "op" and o == "==" and type(xs) is list and len(xs) == 2:
            if type(xs[0]) is str:
                return xs[0], xs[1]
    return None


def _p_red_body(c: Ctx, f: int, red: str, marked: bool, ts: list, i: int):
    """``Math.pRedBody``: the subscript rows, then the body."""
    if f == 0:
        return None
    f -= 1
    rows = None
    if c.sf == K.LATEX:
        if _at(ts, i) == K.US and _at(ts, i + 1) == K.LB:
            if _at(ts, i + 2) == K.SUBSTACK and _at(ts, i + 3) == K.LB:
                r = _p_rows(c, f, K.NL, K.RB, ts, i + 4)
                if r is not None and _at(ts, r[1]) == K.RB:
                    rows = (r[0], r[1] + 1)
            else:
                r = _p_row(c, f, lambda t: t == K.RB, ts, i + 2)
                if r is not None:
                    row, j = r
                    le = _lone_eq(row[1]) if row[0] == "filt" else None
                    if (
                        le is not None
                        and _at(ts, j) == K.RB
                        and _at(ts, j + 1) == K.CARET
                        and _at(ts, j + 2) == K.LB
                    ):
                        if _at(ts, j + 3) == K.LSET:
                            # a superscript set follows: the row is a filter
                            rows = ([row], j + 1)
                        else:
                            r2 = p_or(c, f, ts, j + 3)
                            if r2 is not None and _at(ts, r2[1]) == K.RB:
                                rows = ([("rng", le[0], [le[1], r2[0]])], r2[1] + 1)
                    elif _at(ts, j) == K.RB:
                        rows = ([row], j + 1)
        else:
            rows = ([], i)
    elif _at(ts, i) == K.US and _at(ts, i + 1) == K.LPG:
        rows = _p_rows(c, f, K.NL, K.RP, ts, i + 2)
    else:
        rows = ([], i)
    if rows is None:
        return None
    rp = _row_parts(rows[0])
    sp = _p_sup(c.sf, ts, rows[1])
    if rp is None or sp is None:
        return None
    if marked and sp[0]:
        # a marked head's ``args`` are the body's arrays: no set is printed with it
        return None
    body = p_mul(c, f, ts, sp[1])
    if body is None:
        return None
    rg, fl = rp
    from ..value import MISSING

    form = FaqForm(red, marked, [], rg, body[0], MISSING if fl is _NOFILTER else fl, sp[0])
    return form, body[1]


def _with_out(form: FaqForm, outs: list, ors: list) -> FaqForm:
    """``Math.withOut``."""
    return FaqForm(
        form.red,
        form.marked,
        outs,
        sort_kv(ors + form.ranges),
        form.expr,
        form.filter,
        form.set,
    )


def _with_sup(form: FaqForm, st: list) -> FaqForm:
    """``Math.withSup``: the superscript set read on the bracket of the output
    form (the inner reduction carries none)."""
    return FaqForm(form.red, form.marked, form.out, form.ranges, form.expr, form.filter, st)


def _p_red(c: Ctx, f: int, ts: list, i: int):
    """``Math.pRed``: a rank-0 reduction, or one wrapped with its output
    entries."""
    if f == 0:
        return None
    f -= 1

    def wrapped(j: int, rbr: tuple, sub: tuple, close_k: str):
        h = _p_red_head(c.sf, ts, j)
        if h is None:
            return None
        red, marked, j1 = h
        b = _p_red_body(c, f, red, marked, ts, j1)
        if b is None:
            return None
        form, j2 = b
        if form.set:
            # the set of an output form is written on the bracket only
            return None
        for k, tk in enumerate(rbr):
            if _at(ts, j2 + k) != tk:
                return None
        sp = _p_sup(c.sf, ts, j2 + len(rbr))
        if sp is None:
            return None
        st, j3 = sp
        if marked and st:
            return None
        for k, tk in enumerate(sub):
            if _at(ts, j3 + k) != tk:
                return None
        r = _p_rows(c, f, K.COMMA, close_k, ts, j3 + len(sub))
        if r is None:
            return None
        ep = _entry_parts(r[0])
        if ep is None:
            return None
        return faq_json(_with_sup(_with_out(form, ep[0], ep[1]), st)), r[1]

    t = _at(ts, i)
    if t == K.LBKG:
        return wrapped(i + 1, (K.RBKG,), (K.US, K.LB), K.RB)
    if t == K.LR and _at(ts, i + 1) == K.LP and _at(ts, i + 2) == K.LBK:
        return wrapped(i + 3, (K.RBK, K.RP), (K.US, K.LPG), K.RP)
    h = _p_red_head(c.sf, ts, i)
    if h is None:
        return None
    b = _p_red_body(c, f, h[0], h[1], ts, h[2])
    return None if b is None else (faq_json(b[0]), b[1])


def _p_fn1(c: Ctx, f: int, o: str, ts: list, i: int):
    """``Math.pFn1``: ``f(x)`` after the opening parenthesis."""
    if f == 0:
        return None
    f -= 1
    r = p_or(c, f, ts, i)
    if r is not None and _at(ts, r[1]) == K.RP:
        return node(o, [r[0]]), r[1] + 1
    return None


_RM_D = ("rm", "d")
_T = ("letter", "t")


def _p_frac_l(c: Ctx, f: int, ts: list, i: int):
    """``Math.pFracL``: after ``\\frac{``: a time or spatial derivative, the
    italic-d variant, or a quotient."""
    if f == 0:
        return None
    f -= 1
    t = _at(ts, i)
    if t == _RM_D:
        if (
            _at(ts, i + 1) == K.RB
            and _at(ts, i + 2) == K.LB
            and _at(ts, i + 3) == _RM_D
            and _at(ts, i + 4) == _T
            and _at(ts, i + 5) == K.RB
        ):
            return _p_d_apply(c, f, "t", ts, i + 6)
        r = p_or(c, f, ts, i + 1)
        if r is None:
            return None
        j = r[1]
        if (
            _at(ts, j) == K.RB
            and _at(ts, j + 1) == K.LB
            and _at(ts, j + 2) == _RM_D
            and _at(ts, j + 3) == _T
            and _at(ts, j + 4) == K.RB
        ):
            return d_node(r[0], "t"), j + 5
        return None
    if t == K.PDIFF:
        if _at(ts, i + 1) == K.RB and _at(ts, i + 2) == K.LB and _at(ts, i + 3) == K.PDIFF:
            r = p_name(c.sf, ts, i + 4)
            if r is not None and _at(ts, r[1]) == K.RB:
                return _p_d_apply(c, f, r[0], ts, r[1] + 1)
            return None
        if _at(ts, i + 1) == K.US:
            # `\frac{\partial_{x}(…)…}{…}`: a quotient whose numerator starts
            # with the trailing-operand form.
            r = p_or(c, f, ts, i)
            if r is None or _at(ts, r[1]) != K.RB or _at(ts, r[1] + 1) != K.LB:
                return None
            r2 = p_or(c, f, ts, r[1] + 2)
            if r2 is None or _at(ts, r2[1]) != K.RB:
                return None
            return node("/", [r[0], r2[0]]), r2[1] + 1
        r = p_or(c, f, ts, i + 1)
        if r is None:
            return None
        j = r[1]
        if _at(ts, j) == K.RB and _at(ts, j + 1) == K.LB and _at(ts, j + 2) == K.PDIFF:
            r2 = p_name(c.sf, ts, j + 3)
            if r2 is not None and _at(ts, r2[1]) == K.RB:
                return deriv_node(r[0], r2[0]), r2[1] + 1
        return None
    r = _p_italic_d(c, ts, i)
    if r is not None:
        return r
    r = p_or(c, f, ts, i)
    if r is None or _at(ts, r[1]) != K.RB or _at(ts, r[1] + 1) != K.LB:
        return None
    r2 = p_or(c, f, ts, r[1] + 2)
    if r2 is None or _at(ts, r2[1]) != K.RB:
        return None
    return node("/", [r[0], r2[0]]), r2[1] + 1


def _p_dt(c: Ctx, f: int, k: str, ts: list, i: int):
    """``Math.pDT``: ``(dif N)/(dif t)`` and ``(partial u)/(partial x)`` after the
    first ``(dif`` / ``(partial``."""
    if f == 0:
        return None
    f -= 1
    if (
        _at(ts, i) == K.RP
        and _at(ts, i + 1) == K.SLASH
        and _at(ts, i + 2) == K.LPG
        and type(_at(ts, i + 3)) is str
    ):
        if _at(ts, i + 3) != k:
            return None
        r = p_name(c.sf, ts, i + 4)
        if r is None or _at(ts, r[1]) != K.RP:
            return None
        if k == K.DIF and r[0] != "t":
            return None
        return _p_d_apply(c, f, r[0], ts, r[1] + 1)
    r = p_or(c, f, ts, i)
    if r is None:
        return None
    j = r[1]
    if not (
        _at(ts, j) == K.RP
        and _at(ts, j + 1) == K.SLASH
        and _at(ts, j + 2) == K.LPG
        and type(_at(ts, j + 3)) is str
    ):
        return None
    if _at(ts, j + 3) != k:
        return None
    r2 = p_name(c.sf, ts, j + 4)
    if r2 is None or _at(ts, r2[1]) != K.RP:
        return None
    if k == K.DIF and r2[0] != "t":
        return None
    return deriv_node(r[0], r2[0]), r2[1] + 1


def _p_d_apply(c: Ctx, f: int, w: str, ts: list, i: int):
    """``Math.pDApply``: a derivative operator applied to a parenthesized
    operand."""
    if f == 0:
        return None
    f -= 1
    if _at(ts, i) != K.LPG:
        return None
    r = p_or(c, f, ts, i + 1)
    if r is not None and is_rp(_at(ts, r[1])):
        return deriv_node(r[0], w), r[1] + 1
    return None


def _p_cases(c: Ctx, f: int, ts: list, i: int):
    """``Math.pCases``: ``cases`` rows; a chain re-nests to the right."""
    if f == 0:
        return None
    f -= 1
    if not limits.enter():
        return None
    try:
        r = p_or(c, f, ts, i)
        if r is None:
            return None
        v, j = r
        if _at(ts, j) != K.AMP:
            return None
        tt = _at(ts, j + 1)
        if tt == ("txt", "otherwise"):
            end = K.ECASES if c.sf == K.LATEX else K.RP
            if _at(ts, j + 2) == end:
                return v, j + 3
            return None
        if tt == ("txt", "if "):
            r2 = p_or(c, f, ts, j + 2)
            if r2 is None:
                return None
            brk = K.NL if c.sf == K.LATEX else K.COMMA
            tk = _at(ts, r2[1])
            if type(tk) is not str or tk != brk:
                return None
            r3 = _p_cases(c, f, ts, r2[1] + 1)
            return None if r3 is None else (node("ifelse", [r2[0], v, r3[0]]), r3[1])
        return None
    finally:
        limits.leave()


def _mat_head(ts: list, i: int) -> bool:
    """The rest of the Typst table head after ``mat(``:
    ``delim: "[", augment: #1,``. ``delim`` and ``augment`` are ordinary words,
    named arguments only at this position."""
    if [_at(ts, i + k) for k in (0, 1, 2, 3, 4, 5, 7)] != [
        ("word", "delim"), K.COLON, ("txt", "["), K.COMMA, ("word", "augment"), K.COLON, K.COMMA
    ]:  # fmt: skip
        return False
    t = _at(ts, i + 6)
    return _tag(t) == "code" and type(t[1]) is int and t[1] == 1


def _p_names_tail(sf: str, close_k: str, ts: list, i: int):
    """Names separated by commas, then ``close_k``: ``(names, position after it)``."""
    r = _p_names(sf, ts, i)
    if r is None or _at(ts, r[1]) != close_k:
        return None
    return r[0], r[1] + 1


def _p_sup(sf: str, ts: list, i: int):
    """``Math.pSup``: the superscript set of a reduction or of an output form, if
    there is one: LaTeX ``^{\\{f, g\\}}``, Typst ``^({f, g})``."""
    grp_k, close_k = (K.LB, K.RB) if sf == K.LATEX else (K.LPG, K.RP)
    if _at(ts, i) == K.CARET and _at(ts, i + 1) == grp_k and _at(ts, i + 2) == K.LSET:
        r = _p_names_tail(sf, K.RSET, ts, i + 3)
        if r is None or _at(ts, r[1]) != close_k:
            return None
        return r[0], r[1] + 1
    return [], i


def _mk_tail(sf: str, rows: list, ts: list, i: int):
    """``Math.mkTail``: the ``makearray`` node of a table read back, with its
    subscript of output indices if one follows."""

    def node_of(out: list) -> Obj:
        return mk_json(MkForm(out, [r for _, r in rows], [v for v, _ in rows]))

    grp_k, close_k = (K.LB, K.RB) if sf == K.LATEX else (K.LPG, K.RP)
    if _at(ts, i) == K.US and _at(ts, i + 1) == grp_k:
        r = _p_names_tail(sf, close_k, ts, i + 2)
        return None if r is None else (node_of(r[0]), r[1])
    return node_of([]), i


def _p_pair(c: Ctx, f: int, ts: list, i: int):
    """``Math.pPair``: a bound pair after its ``[``: ``a, b]``."""
    if f == 0:
        return None
    f -= 1
    r = p_or(c, f, ts, i)
    if r is None or _at(ts, r[1]) != K.COMMA:
        return None
    r2 = p_or(c, f, ts, r[1] + 1)
    if r2 is None or _at(ts, r2[1]) != K.RBK:
        return None
    return (r[0], r2[0]), r2[1] + 1


def _p_reg_tail(c: Ctx, f: int, ts: list, i: int):
    """``Math.pRegTail``: the further bound pairs of a region, each after
    ``\\times [`` (the two tokens ``\\times`` and ``[``)."""
    out = []
    while True:
        if f == 0:
            return None
        f -= 1
        if _at(ts, i) != K.TIMES or _at(ts, i + 1) != K.LBK:
            return out, i
        r = _p_pair(c, f, ts, i + 2)
        if r is None:
            return None
        out.append(r[0])
        i = r[1]


def _p_mk_rows(c: Ctx, f: int, csep: str, rsep: str, close_k: str, ts: list, i: int):
    """``Math.pMkRows``: the rows of a ``makearray`` table: a value, the cell
    separator ``csep``, a region; rows separated by ``rsep``, up to ``close_k``
    (consumed). A row is ``(value, [(a, b), …])``."""
    out = []
    while True:
        if f == 0:
            return None
        f -= 1
        r = p_or(c, f, ts, i)
        if r is None:
            return None
        v, j = r
        if _at(ts, j) != csep or _at(ts, j + 1) != K.LBK:
            return None
        r1 = _p_pair(c, f, ts, j + 2)
        if r1 is None:
            return None
        r2 = _p_reg_tail(c, f, ts, r1[1])
        if r2 is None:
            return None
        out.append((v, [r1[0], *r2[0]]))
        k = _at(ts, r2[1])
        if k == rsep:
            i = r2[1] + 1
        elif k == close_k:
            return out, r2[1] + 1
        else:
            return None


def _p_esc_args(c: Ctx, f: int, ts: list, i: int):
    """``Math.pEscArgs``: Typst escape arguments: ``, a`` repeated, then ``)``."""
    out: list = []
    while True:
        if f == 0:
            return None
        f -= 1
        t = _at(ts, i)
        if t == K.RP:
            return out, i + 1
        if t == K.COMMA:
            r = p_or(c, f, ts, i + 1)
            if r is None:
                return None
            out.append(r[0])
            i = r[1]
        else:
            return None


def need(level: int, n: int) -> int:
    """``Math.need`` (RoundTrip.lean): the fuel a token list of length ``n`` is
    read with at level ``L``."""
    return 30 * n + max(0, 12 - level)


def parse_toks(sf: str, s: Any, ts: list):
    """``Math.parseToks`` (Induct.lean): read a whole token list; ``(value,)`` or
    ``None``."""
    r = p_or(Ctx(sf, s), need(1, len(ts)), ts, 0)
    if r is None or r[1] != len(ts):
        return None
    return (r[0],)
