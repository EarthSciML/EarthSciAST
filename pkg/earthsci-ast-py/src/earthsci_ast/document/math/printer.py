"""The printer: expressions to tokens.

Port of ``formal/Esm/Document/Math/Print.lean``. :func:`pr` prints an expression
with its precedence level; :meth:`Out.at` wraps it for a position that needs a
level at least ``L``. The levels, loosest first (spec §4.1.1):

====== ==================================================================
level  construct
====== ==================================================================
1      ``or`` chain
2      ``and`` chain
3      a comparison
4      ``+`` chain, binary ``-``
5      ``*`` chain, unary ``-``
6      ``not``; a derivative applied to a parenthesized operand
7      Typst fraction; a negative literal and a quantity
8      power
9      index
10     atoms
====== ==================================================================

Which notation a node gets is decided from its exact JSON shape; anything
without a native or call notation prints in the generic escape form.
"""

from __future__ import annotations

from typing import Any, NamedTuple

from ...esm_types import NODE_ANNOTATION_KEYS
from ..value import MISSING, Dec, Obj, look, num_wf
from . import token as K
from . import units as U
from .expr import (
    REMOVED_SET,
    Sym,
    is_e,
    is_formula,
    is_id_char,
    is_id_start,
    is_single,
    keys_sorted,
    name_ok,
    pieces,
    seg_ok,
    sub_parts,
)

# ## Text pieces

_ESC_SET = frozenset("_^\\{}")


def esc_t(s: str) -> str:
    """``Math.escT``: escape the text of ``\\mathit{}`` and the like."""
    if not any(c in _ESC_SET for c in s):
        return s
    return "".join("\\" + c if c in _ESC_SET else c for c in s)


def unesc_t(s: str) -> str:
    """``Math.unescT``: drop the backslash of every ``\\c`` pair."""
    if "\\" not in s:
        return s
    out = []
    i, n = 0, len(s)
    while i < n:
        if s[i] == "\\" and i + 1 < n:
            out.append(s[i + 1])
            i += 2
        else:
            out.append(s[i])
            i += 1
    return "".join(out)


_KEY_SPECIAL = frozenset("$%&#~^\\")


def key_special(c: str) -> bool:
    return c in _KEY_SPECIAL


def dig3(n: int) -> str:
    return f"{n // 100 % 10}{n // 10 % 10}{n % 10}"


def esc_k(s: str) -> str:
    """``Math.escK``: escape a field key for ``\\mathrm{}``."""
    out = []
    for c in s:
        if c in _KEY_SPECIAL:
            out.append("{\\char" + dig3(ord(c)) + "}")
        elif c in "_{}":
            out.append("\\" + c)
        else:
            out.append(c)
    return "".join(out)


def char_digit_nat(c: str) -> int:
    """``Number.charDigit``: ``c.toNat - 48``, saturating."""
    return max(0, ord(c) - 48)


def char_of_nat(n: int) -> str:
    """Lean's ``Char.ofNat``: an invalid code point is ``\\0``."""
    if n > 0x10FFFF or 0xD800 <= n <= 0xDFFF:
        return "\0"
    return chr(n)


def unesc_k(s: str) -> str:
    """``Math.unescK``: undo :func:`esc_k`."""
    out = []
    i, n = 0, len(s)
    while i < n:
        if s.startswith("{\\char", i) and i + 9 < n and s[i + 9] == "}":
            a, b, d = s[i + 6], s[i + 7], s[i + 8]
            out.append(
                char_of_nat(100 * char_digit_nat(a) + 10 * char_digit_nat(b) + char_digit_nat(d))
            )
            i += 10
        elif s[i] == "\\" and i + 1 < n:
            out.append(s[i + 1])
            i += 2
        else:
            out.append(s[i])
            i += 1
    return "".join(out)


# ## The printing context


class Ctx(NamedTuple):
    """``Math.Ctx``: the surface and the symbol table."""

    sf: str
    s: Sym


def rp_g(sf: str) -> str:
    """``Math.rpG``: the closing token of a grouping parenthesis."""
    return K.RPG if sf == K.LATEX else K.RP


def grp(sf: str, ts: list) -> list:
    """``Math.grp``: grouping parentheses."""
    return [K.LPG, *ts, rp_g(sf)]


def sep_by(sep: list, xs: list) -> list:
    """``Math.sepBy``: items joined by a separator."""
    out: list = []
    for i, x in enumerate(xs):
        if i:
            out.extend(sep)
        out.extend(x)
    return out


# ## Names


def base_tok(g: str) -> tuple:
    """``Math.baseTok``: a single letter or a Greek name as a token."""
    return ("letter", g) if len(g) == 1 else ("greek", g)


def sub_txt(sf: str, r: str) -> list:
    """``Math.subTxt``: the subscript text of a name, upright."""
    if sf == K.LATEX:
        return [K.US, K.LB, ("rm", esc_t(r)), K.RB]
    return [K.US, K.LPG, ("ups", ((r, ""),)), K.RP]


def formula_raw(g: str) -> str:
    """``Math.formulaRaw``: the raw ``\\mathrm{}`` content of a formula."""
    return "".join(a + ("_{" + b + "}" if b else "") for a, b in pieces(g))


def form_tok(sf: str, g: str) -> tuple:
    """``Math.formTok``: a formula name."""
    if sf == K.LATEX:
        return ("rm", formula_raw(g))
    return ("ups", tuple(pieces(g)))


def seg_toks(sf: str, g: str) -> list:
    """``Math.segToks``: one segment of a name, by its shape."""
    if is_single(g):
        return [base_tok(g)]
    sp = sub_parts(g)
    if sp is not None:
        return [base_tok(sp[0]), *sub_txt(sf, sp[1])]
    if is_formula(g):
        return [form_tok(sf, g)]
    return [("it", g)]


def explicit_name(s: Sym, n: str) -> bool:
    """``Math.explicitName``: an undeclared ``e`` or ``d`` prints in the explicit
    form."""
    return (n == "e" or n == "d") and n not in s.names


def name_toks(c: Ctx, s: str) -> list:
    """``Math.nameToks``: the tokens of a name."""
    if explicit_name(c.s, s):
        return [("it", s)]
    return sep_by([K.SDOT], [seg_toks(c.sf, g) for g in s.split(".")])


def plain_last(s: str) -> bool:
    """``Math.plainLast``: the last segment of a name prints with no subscript."""
    g = s.split(".")[-1]
    return is_single(g) or (sub_parts(g) is None and not is_formula(g))


# ## JSON inside escape nodes (LaTeX)


def json_toks(j: Any) -> list:
    """``Math.jsonToks``."""
    out: list = []
    _json_toks_into(j, out)
    return out


def _json_toks_into(j: Any, out: list) -> None:
    t = type(j)
    if j is None:
        out.append(("word", "null"))
    elif j is True:
        out.append(("word", "true"))
    elif j is False:
        out.append(("word", "false"))
    elif t is int or t is Dec:
        out.append(("num", j))
    elif t is str:
        out.append(("jstr", j))
    elif t is Obj:
        out.append(K.LB)
        for i, (k, v) in enumerate(j):
            if i:
                out.append(K.COMMA)
            out.append(("jstr", k))
            out.append(K.COLON)
            _json_toks_into(v, out)
        out.append(K.RB)
    else:
        out.append(K.LBK)
        for i, x in enumerate(j):
            if i:
                out.append(K.COMMA)
            _json_toks_into(x, out)
        out.append(K.RBK)


# ## Operator tables

#: ``Math.fnKw``: unary functions with a native spelling, and their keyword.
FN_KW = {
    "exp": K.EXP,
    "log": K.LN,
    "sin": K.SIN,
    "cos": K.COS,
    "tan": K.TAN,
    "asin": K.ASIN,
    "acos": K.ACOS,
    "atan": K.ATAN,
    "sinh": K.SINH,
    "cosh": K.COSH,
    "tanh": K.TANH,
}

#: ``Math.cmpKw``: comparisons and their token.
CMP_KW = {"<": K.LT, "<=": K.LE, ">": K.GT, ">=": K.GE, "==": K.EQ, "!=": K.NE}

#: ``Math.callOps``: core operators in the call form.
CALL_OPS = frozenset({"sign", "atan2", "asinh", "acosh", "atanh", "Pre", "enum"})

#: ``Math.fieldCallOps``: core operators with no notation of their own that print in
#: the call form, their fields as named arguments after ``;`` (when no field
#: annotates the node).
FIELD_CALL_OPS = frozenset(
    {"broadcast", "reshape", "transpose", "concat", "faq", "makearray", "const"}
)


def reserved_opn(n: str) -> bool:
    """``Math.reservedOpn``: names ``\\operatorname{…}`` never means a template or
    an open operator by."""
    return n in CALL_OPS or n in ("D", "neg", "pow") or n in REMOVED_SET


#: ``Math.coreOps``.
CORE_OPS = frozenset(
    {
        "+", "-", "*", "/", "^", "pow", "neg", "<", "<=", ">", ">=", "==", "!=", "and", "or",
        "not", "true", "false", "ifelse", "exp", "log", "log10", "sqrt", "abs", "sign",
        "floor", "ceil", "sin", "cos", "tan", "asin", "acos", "atan", "sinh", "cosh", "tanh",
        "asinh", "acosh", "atanh", "atan2", "min", "max", "D", "ic", "Pre", "enum", "const",
        "faq", "makearray", "index", "broadcast", "reshape", "transpose", "concat",
        "apply_operator",
    }
)  # fmt: skip


def opn_ok(s: str) -> bool:
    """``Math.opnOK``: identifier characters and dots."""
    return s != "" and is_id_start(s[0]) and all(is_id_char(d) or d == "." for d in s[1:])


#: ``Math.annotKeys``: the fields that annotate a node.
ANNOT_KEYS = NODE_ANNOTATION_KEYS


def call_form_ok(o: str, fs: list) -> bool:
    """``Math.callFormOK``: an operator prints in the call form: an open operator, or
    a core operator of :data:`FIELD_CALL_OPS` none of whose fields annotates it."""
    return o not in CORE_OPS or (o in FIELD_CALL_OPS and all(k not in ANNOT_KEYS for k, _ in fs))


#: ``Math.mathKeys``: the fields of a core operator in the call form that hold an
#: expression; the others print as JSON, even a string that is a name.
MATH_KEYS = frozenset({"expr", "filter", "key"})


def math_field(o: str, kv: tuple) -> bool:
    """``Math.mathField``: a field of a call-form node prints as math: its value is
    an expression and, for a core operator, the field holds one."""
    return is_e(kv[1]) and (o not in CORE_OPS or kv[0] in MATH_KEYS)


def key_ok(s: str) -> bool:
    """``Math.keyOK``: a field key printed upright in a call: an identifier."""
    return seg_ok(s)


def ins_kv(kv: tuple, entries: list) -> list:
    """``Math.insKV``: sorted insertion by key."""
    entries = list(entries)
    for i, e in enumerate(entries):
        if kv[0] < e[0]:
            entries.insert(i, kv)
            return entries
    entries.append(kv)
    return entries


def fields_of(kvs: list) -> list:
    """``Math.fieldsOf``: the fields of a node other than ``op`` and ``args``."""
    return [kv for kv in kvs if kv[0] != "op" and kv[0] != "args"]


def mk_node(o: str, args: list, fs: list) -> Obj:
    """``Math.mkNode``: a node from its operator, operands and other fields."""
    return Obj(ins_kv(("args", args), ins_kv(("op", o), fs)))


def node(o: str, args: list) -> Obj:
    """``Math.node``: the plain two-field node."""
    return Obj([("args", args), ("op", o)])


def is_neg_num(j: Any) -> bool:
    t = type(j)
    if t is int:
        return j < 0
    if t is Dec:
        return j.neg
    return False


def simple_tok(t: Any) -> bool:
    """``Math.simpleTok``: Typst exponent and subscript tokens that need no
    parentheses."""
    if type(t) is not tuple:
        return False
    tag = t[0]
    if tag == "num":
        n = t[1]
        if type(n) is int:
            return n >= 0
        return not n.neg and -4 <= n.e10 <= 5
    return tag == "letter" or tag == "greek"


def starts_num(ts: list) -> bool:
    return bool(ts) and type(ts[0]) is tuple and ts[0][0] == "num"


def tparams(s: Sym, n: str):
    """``Math.tparams``: the template parameter list, when the symbol table knows
    it."""
    for name, ps in s.templates:
        if name == n:
            return ps
    return None


def _nodup(xs) -> bool:
    return len(set(xs)) == len(xs)


def positional(s: Sym, n: str, bs: list):
    """``Math.positional``: positional template arguments."""
    ps = tparams(s, n)
    if ps is None:
        return None
    if _nodup(ps) and len(ps) == len(bs) and all(look(p, bs) is not MISSING for p in ps):
        return ps
    return None


def raw_b(d: int, s: str, i: int):
    """``Math.rawB``: balanced text up to the ``}`` that closes depth 0; ``\\x`` is
    one unit. ``(text, position after the brace)``."""
    start = i
    n = len(s)
    while i < n:
        c = s[i]
        if c == "\\" and i + 1 < n:
            i += 2
        elif c == "}":
            if d == 0:
                return s[start:i], i + 1
            d -= 1
            i += 1
        elif c == "{":
            d += 1
            i += 1
        else:
            i += 1
    return None


def bal_ok(raw: str) -> bool:
    """``Math.balOK``: raw text that :func:`raw_b` reads back whole."""
    r = raw_b(0, raw + "}", 0)
    return r is not None and r[0] == raw and r[1] == len(raw) + 1


factors_of = U.factors_of


def units_ok(sf: str, u: str) -> bool:
    """``Math.unitsOK``: the units of a quantity print typeset."""
    fs = factors_of(u)
    if not fs or U.spell(fs) != u:
        return False
    if not all(U.sym_ok(f[0]) and f[1] != 0 for f in fs):
        return False
    if sf == K.LATEX:
        return U.parse_latex(U.latex(fs)) == fs and bal_ok(U.latex_body(fs))
    return U.num_factors(fs) + U.den_factors(fs) == fs


# ## The printer


def wrap(sf: str, need: int, lvl: int, ts: list) -> list:
    """``Math.wrap``: wrap a printed form for a position needing level ``L``."""
    return ts if need <= lvl else grp(sf, ts)


def mul_toks(xs: list) -> list:
    """``Math.mulToks``: juxtaposition, ``\\cdot`` before a factor that starts with
    a number."""
    out: list = []
    for i, y in enumerate(xs):
        if i and starts_num(y):
            out.append(K.CDOT)
        out.extend(y)
    return out


# Math.OpK: the printer kind of a plain node's operator.
_MINUS, _DIV, _POW, _LNOT, _TRU, _FLS, _ITE, _IC, _INDEX = range(9)
_CMP, _UN, _PLUS, _TIMES, _LAND, _LOR, _MM, _CALL, _OTHER = range(9, 18)

_UN_KW = {
    **FN_KW,
    "log10": K.LOG,
    "sqrt": K.SQRT,
    "abs": K.ABS,
    "floor": K.FLOOR,
    "ceil": K.CEIL,
}

_KIND_TABLE = {
    "-": (_MINUS, None),
    "/": (_DIV, None),
    "^": (_POW, None),
    "not": (_LNOT, None),
    "true": (_TRU, None),
    "false": (_FLS, None),
    "ifelse": (_ITE, None),
    "ic": (_IC, None),
    "index": (_INDEX, None),
    "+": (_PLUS, None),
    "*": (_TIMES, None),
    "and": (_LAND, None),
    "or": (_LOR, None),
    "min": (_MM, K.MIN),
    "max": (_MM, K.MAX),
}


def kind_of(o: str) -> tuple:
    """``Math.kindOf``."""
    k = CMP_KW.get(o)
    if k is not None:
        return _CMP, k
    k = _UN_KW.get(o)
    if k is not None:
        return _UN, k
    r = _KIND_TABLE.get(o)
    if r is not None:
        return r
    return (_CALL, None) if o in CALL_OPS else (_OTHER, None)


_OTHERWISE = [K.AMP, ("txt", "otherwise")]


class Out:
    """``Math.Out``: the printed form of an expression and its level. ``crow`` is
    the form as the last rows of a ``cases`` block."""

    __slots__ = ("lvl", "toks", "_crow")

    def __init__(self, lvl: int, toks: list, crow: list | None = None):
        self.lvl = lvl
        self.toks = toks
        self._crow = crow

    @property
    def crow(self) -> list:
        if self._crow is None:
            return self.toks + _OTHERWISE
        return self._crow

    def at(self, sf: str, need: int) -> list:
        """``Math.Out.at``."""
        return self.toks if need <= self.lvl else grp(sf, self.toks)


def esc_toks(sf: str, o: str, fs: list, args: list) -> list:
    """``Math.escToks``: LaTeX ``\\esm{op}{fields}{args}``, Typst
    ``esm.node("op", #(fields), args)``."""
    if sf == K.LATEX:
        return [("esc", o), K.LB, *json_toks(Obj(fs)), K.RB, K.LB, *sep_by([K.COMMA], args), K.RB]
    out = [K.ESMNODE, K.LP, ("txt", o), K.COMMA, ("code", Obj(fs))]
    for a in args:
        out.append(K.COMMA)
        out.extend(a)
    out.append(K.RP)
    return out


def call_toks(sf: str, head: list, args: list) -> list:
    """``Math.callToks``: ``name(args)`` with call parentheses."""
    return [*head, K.LP, *sep_by([K.COMMA], args), K.RP]


def un_toks(sf: str, k: str, t: list) -> list:
    """``Math.unToks``: a unary function applied to the printed operand ``t``."""
    if sf == K.LATEX:
        if k == K.SQRT:
            return [K.SQRT, K.LB, *t, K.RB]
        if k == K.ABS:
            return [K.LABS, *t, K.RABS]
        if k == K.FLOOR:
            return [K.LFLOOR, *t, K.RFLOOR]
        if k == K.CEIL:
            return [K.LCEIL, *t, K.RCEIL]
        if k == K.LOG:
            return [K.LOG, K.US, K.LB, ("num", 10), K.RB, *call_toks(sf, [], [t])]
    elif k == K.LOG:
        return [K.LOG, K.US, ("num", 10), *call_toks(sf, [], [t])]
    return call_toks(sf, [k], [t])


def case_row(sf: str, v: list, cnd: list) -> list:
    """``Math.caseRow``: ``value & \\text{if } condition``, then the row break."""
    return [*v, K.AMP, ("txt", "if "), *cnd, K.NL if sf == K.LATEX else K.COMMA]


def cases_toks(sf: str, rows: list) -> list:
    if sf == K.LATEX:
        return [K.BCASES, *rows, K.ECASES]
    return [K.CASES, K.LP, *rows, K.RP]


def ic_tail(sf: str) -> list:
    """``Math.icTail``: ``t_{0}`` in an initial condition ``N(t_{0})``."""
    if sf == K.LATEX:
        return [K.LP, ("letter", "t"), K.US, K.LB, ("num", 0), K.RB, K.RP]
    return [K.LP, ("letter", "t"), K.US, ("num", 0), K.RP]


def sub_list(sf: str, simp: Any, args: list) -> list:
    """``Math.subList``: LaTeX ``_{a, b}``; Typst ``_a`` for one simple token, else
    ``_(a, b)``."""
    if sf == K.LATEX:
        return [K.US, K.LB, *sep_by([K.COMMA], args), K.RB]
    if simp is not None:
        return [K.US, simp]
    return [K.US, K.LPG, *sep_by([K.COMMA], args), K.RP]


def simple_e(c: Ctx, j: Any):
    """``Math.simpleE``: the one token a Typst exponent or subscript may be
    written as without parentheses."""
    t = type(j)
    if t is int or t is Dec:
        tok = ("num", j)
        return tok if simple_tok(tok) else None
    if t is str:
        ts = name_toks(c, j)
        if len(ts) == 1 and simple_tok(ts[0]):
            return ts[0]
    return None


def simple_arg(c: Ctx, xs: list):
    return simple_e(c, xs[0]) if len(xs) == 1 else None


def sub_ok(s: Sym, base: Any, is_: list) -> bool:
    """``Math.subOK``: the index prints with a subscript."""
    if type(base) is not str:
        return False
    if not (name_ok(base) and plain_last(base) and not explicit_name(s, base)):
        return False
    if len(is_) == 1:
        x = is_[0]
        if type(x) is str:
            return not ("." not in x and is_formula(x))
        if type(x) is int:
            return not (x >= 0 and f"{base}_{x}" in s.names)
    return True


def sub_pat(sf: str, ts: list) -> bool:
    """``Math.subPat``: an upright name subscript at the front."""
    if len(ts) < 4:
        return False
    t1, t2, t3, t4 = ts[0], ts[1], ts[2], ts[3]
    if t1 != K.US or type(t3) is not tuple:
        return False
    if t2 == K.LB and t3[0] == "rm" and t4 == K.RB:
        return sf == K.LATEX
    if t2 == K.LPG and t3[0] == "ups" and t4 == K.RP and len(t3[1]) == 1 and t3[1][0][1] == "":
        return sf == K.TYPST
    return False


def key_toks(sf: str, k: str) -> list:
    """``Math.keyToks``: a field key, upright."""
    if sf == K.LATEX:
        return [("rm", esc_k(k))]
    return [("ups", ((k, ""),))]


def json_val(sf: str, v: Any) -> list:
    """``Math.jsonVal``: a field value that is not an expression, as JSON."""
    return json_toks(v) if sf == K.LATEX else [("code", v)]


def open_toks(sf: str, o: str, args: list, fields: list) -> list:
    """``Math.openToks``: the open-operator call."""
    out = [("opn", o), K.LP, *sep_by([K.COMMA], args)]
    if fields:
        out.append(K.SEMI)
        out.extend(sep_by([K.COMMA], fields))
    out.append(K.RP)
    return out


_RM_D = ("rm", "d")
_LT_T = ("letter", "t")


def d_time(sf: str, a: Out) -> Out:
    """``Math.dTime``: the time derivative."""
    a1 = a.at(sf, 1)
    inline = a.lvl >= 9
    if sf == K.LATEX:
        if inline:
            return Out(10, [K.FRAC, K.LB, _RM_D, *a1, K.RB, K.LB, _RM_D, _LT_T, K.RB])
        return Out(6, [K.FRAC, K.LB, _RM_D, K.RB, K.LB, _RM_D, _LT_T, K.RB, *grp(sf, a1)])
    if inline:
        return Out(7, [K.LPG, K.DIF, *a1, K.RP, K.SLASH, K.LPG, K.DIF, _LT_T, K.RP])
    return Out(6, [K.LPG, K.DIF, K.RP, K.SLASH, K.LPG, K.DIF, _LT_T, K.RP, *grp(sf, a1)])


def d_space(sf: str, w: list, a: Out) -> Out:
    """``Math.dSpace``: the spatial derivative along the axis printed ``w``."""
    a1 = a.at(sf, 1)
    inline = a.lvl >= 9
    if sf == K.LATEX:
        if inline:
            return Out(10, [K.FRAC, K.LB, K.PDIFF, *a1, K.RB, K.LB, K.PDIFF, *w, K.RB])
        return Out(6, [K.FRAC, K.LB, K.PDIFF, K.RB, K.LB, K.PDIFF, *w, K.RB, *grp(sf, a1)])
    if inline:
        return Out(7, [K.LPG, K.PDIFF, *a1, K.RP, K.SLASH, K.LPG, K.PDIFF, *w, K.RP])
    return Out(6, [K.LPG, K.PDIFF, K.RP, K.SLASH, K.LPG, K.PDIFF, *w, K.RP, *grp(sf, a1)])


def d_call(sf: str, w: list, args: list) -> list:
    """``Math.dCall``: ``\\operatorname{D}_{x}(u, a, b)``."""
    if sf == K.LATEX:
        return [("opn", "D"), K.US, K.LB, *w, K.RB, *call_toks(sf, [], args)]
    return [("opn", "D"), K.US, K.LPG, *w, K.RP, *call_toks(sf, [], args)]


# ## Constant arrays


def nums_of(xs: list):
    """``Math.numsOf``: the entries of a list that are all well-formed numbers."""
    for x in xs:
        t = type(x)
        if not ((t is int or t is Dec) and num_wf(x)):
            return None
    return xs


def rows_of(xs: list):
    rows = []
    for x in xs:
        if type(x) is not list or nums_of(x) is None:
            return None
        rows.append(x)
    return rows


def arr_form(xs: list):
    """``Math.arrForm``: a constant array printed natively, of any size:
    ``("col", ns)`` or ``("mat", rows)``."""
    ns = nums_of(xs)
    if ns is not None:
        return ("col", ns) if ns else None
    rs = rows_of(xs)
    if rs:
        r = rs[0]
        if len(r) >= 2 and all(len(q) == len(r) for q in rs[1:]):
            return ("mat", rs)
    return None


def _num_toks(ns: list) -> list:
    return [[("num", n)] for n in ns]


#: The most columns amsmath's ``bmatrix`` typesets (its ``MaxMatrixCols``).
BMAT_MAX_COLS = 10


def arr_toks(sf: str, a: tuple) -> list:
    """``Math.arrToks``: LaTeX ``bmatrix`` (a matrix wider than
    :data:`BMAT_MAX_COLS` as ``\\left[\\begin{array}{c…c} … \\end{array}\\right]``),
    Typst ``vec(…)`` / ``mat(…)``."""
    kind, v = a
    if kind == "col":
        if sf == K.LATEX:
            return [K.BMAT, *sep_by([K.NL], _num_toks(v)), K.EMAT]
        return [K.VEC, K.LP, *sep_by([K.COMMA], _num_toks(v)), K.RP]
    if sf == K.LATEX:
        rows = sep_by([K.NL], [sep_by([K.AMP], _num_toks(r)) for r in v])
        if len(v[0]) > BMAT_MAX_COLS:
            return [K.LBKG, ("arrc", len(v[0])), *rows, K.EARR, K.RBKG]
        return [K.BMAT, *rows, K.EMAT]
    return [K.MAT, K.LP, *sep_by([K.SEMI], [sep_by([K.COMMA], _num_toks(r)) for r in v]), K.RP]


# ## Reductions (`faq`)


def _idx_base(kvs: list):
    o = look("op", kvs)
    xs = look("args", kvs)
    if o == "index" and type(xs) is list and xs and type(xs[0]) is str:
        return xs[0]
    return None


def _bases_j(j: Any, acc: list) -> None:
    t = type(j)
    if t is Obj:
        s = _idx_base(j)
        if s is not None and s not in acc:
            acc.append(s)
        for _, v in j:
            _bases_j(v, acc)
    elif t is list:
        for x in j:
            _bases_j(x, acc)


def bases(e: Any) -> list:
    """``Math.bases``: the arrays an expression indexes, in first-use order."""
    acc: list = []
    _bases_j(e, acc)
    return acc


# Math.RedK: the reductions with a native spelling.
RED_KW = {"sum": K.SUM, "prod": K.PROD, "max": K.MAX, "min": K.MIN}
_RED_FIELD = {
    "sum": [],
    "prod": [("reduce", "*")],
    "max": [("reduce", "max")],
    "min": [("reduce", "min")],
}


class FaqForm:
    """``Math.FaqForm``: a ``faq`` node with a native spelling, by its parts.
    ``marked``: ``args`` lists the arrays the body indexes; otherwise ``args`` is
    ``set`` (empty, or names printed as a superscript set)."""

    __slots__ = ("red", "marked", "out", "ranges", "expr", "filter", "set")

    def __init__(self, red, marked, out, ranges, expr, filter, set):
        self.red = red
        self.marked = marked
        self.out = out
        self.ranges = ranges
        self.expr = expr
        #: ``MISSING`` when the node has no filter.
        self.filter = filter
        self.set = set

    def args(self) -> list:
        """``FaqForm.args``: the ``args`` of a native ``faq``."""
        return list(bases(self.expr)) if self.marked else list(self.set)

    def sup(self) -> list:
        """``FaqForm.sup``: the names a superscript set shows: ``set`` when ``args``
        is not the body's arrays."""
        return [] if self.marked else self.set


def faq_json(f: FaqForm) -> Obj:
    """``Math.faqJson``."""
    kvs = [("args", f.args()), ("expr", f.expr)]
    if f.filter is not MISSING:
        kvs.append(("filter", f.filter))
    kvs.append(("op", "faq"))
    kvs.append(("output_idx", f.out))
    if f.ranges:
        kvs.append(("ranges", Obj(f.ranges)))
    kvs.extend(_RED_FIELD[f.red])
    return Obj(kvs)


def faq_cand(kvs: list):
    """``Math.faqCand``: the parts a ``faq`` node would have."""
    e = look("expr", kvs)
    out = look("output_idx", kvs)
    args = look("args", kvs)
    if e is MISSING or type(out) is not list or type(args) is not list:
        return None
    r = look("reduce", kvs)
    if r is MISSING:
        red = "sum"
    elif r == "*" and type(r) is str:
        red = "prod"
    elif r == "max":
        red = "max"
    elif r == "min":
        red = "min"
    else:
        return None
    rs = look("ranges", kvs)
    if rs is MISSING:
        rs = []
    elif type(rs) is Obj:
        rs = list(rs)
    else:
        return None
    if not args:
        marked, st = False, []
    elif args == bases(e):
        marked, st = True, []
    elif all(type(a) is str for a in args):
        marked, st = False, list(args)
    else:
        return None
    return FaqForm(red, marked, out, rs, e, look("filter", kvs), st)


def faq_form(kvs: Obj):
    """``Math.faqForm``: the parts of a ``faq`` node, when it is exactly the node
    they rebuild."""
    f = faq_cand(kvs)
    if f is None:
        return None
    return f if faq_json(f) == kvs else None


def range_ok(j: Any) -> bool:
    """``Math.rangeOK``: a range a row can spell."""
    t = type(j)
    if t is list:
        return len(j) == 2 and is_e(j[0]) and is_e(j[1])
    if t is Obj:
        if len(j) == 1:
            ((k, s),) = j
            return k == "from" and type(s) is str and name_ok(s)
        if len(j) == 2:
            (k, s), (k2, ps) = j
            return (
                k == "from"
                and k2 == "of"
                and type(s) is str
                and type(ps) is list
                and name_ok(s)
                and len(ps) > 0
                and all(type(p) is str and name_ok(p) for p in ps)
            )
    return False


def out_names(out: list) -> list:
    return [j for j in out if type(j) is str]


def out_ok(j: Any) -> bool:
    """``Math.outOK``: a name, or the singleton dimension ``1``."""
    if type(j) is str:
        return name_ok(j)
    return type(j) is int and j == 1


def occurs_j(k: str, j: Any) -> bool:
    """``Math.occursJ``: a bare name occurs in an expression."""
    t = type(j)
    if t is str:
        return j == k
    if t is list:
        return any(occurs_j(k, x) for x in j)
    if t is Obj:
        return any(occurs_j(k, v) for _, v in j)
    return False


def faq_ok(f: FaqForm) -> bool:
    """``Math.faqOK``: the conditions under which the native spelling reads
    back."""
    names = out_names(f.out)
    if not is_e(f.expr):
        return False
    if f.filter is not MISSING and not is_e(f.filter):
        return False
    if not all(out_ok(j) for j in f.out) or not _nodup(names):
        return False
    if not all(name_ok(s) for s in f.set) or not keys_sorted(f.ranges):
        return False
    for k, v in f.ranges:
        if not (name_ok(k) and range_ok(v)):
            return False
        if not (
            k in names or occurs_j(k, f.expr) or (f.filter is not MISSING and occurs_j(k, f.filter))
        ):
            return False
    return True


def row_toks(c: Ctx, k: str, v: Any) -> list:
    """``Math.rowToks``: ``a \\le k \\le b``, ``k \\in S``, ``k \\in S(i, j)``."""
    t = type(v)
    if t is list and len(v) == 2:
        return [*pa(c, 4, v[0]), K.LE, *name_toks(c, k), K.LE, *pa(c, 4, v[1])]
    if t is Obj:
        if len(v) == 1 and v[0][0] == "from" and type(v[0][1]) is str:
            return [*name_toks(c, k), K.INN, *name_toks(c, v[0][1])]
        if (
            len(v) == 2
            and v[0][0] == "from"
            and type(v[0][1]) is str
            and v[1][0] == "of"
            and type(v[1][1]) is list
        ):
            ps = [name_toks(c, q) if type(q) is str else [] for q in v[1][1]]
            return [
                *name_toks(c, k),
                K.INN,
                *name_toks(c, v[0][1]),
                K.LP,
                *sep_by([K.COMMA], ps),
                K.RP,
            ]
    return []


def red_ranges(f: FaqForm) -> list:
    """``Math.redRanges``: the ranges of indices that are not output indices."""
    names = out_names(f.out)
    return [kv for kv in f.ranges if kv[0] not in names]


def sub_rows(c: Ctx, f: FaqForm) -> list:
    rows = [row_toks(c, k, v) for k, v in red_ranges(f)]
    if f.filter is not MISSING:
        rows.append(pa(c, 1, f.filter))
    return rows


def head_toks(sf: str, f: FaqForm) -> list:
    """``Math.headToks``: the operator, marked when ``args`` is listed."""
    kw = RED_KW[f.red]
    if sf == K.LATEX:
        return [kw, K.LIMITS_L] if f.marked else [kw]
    return [K.LIMITS, K.LP, kw, K.RP] if f.marked else [kw]


def sub_toks_l(c: Ctx, f: FaqForm) -> list:
    """``Math.subToksL``: none, one row, a lone dense range ``_{k=a}^{b}`` (not when
    ``args`` is a superscript set), or ``\\substack``."""
    rr = red_ranges(f)
    if (
        len(rr) == 1
        and f.filter is MISSING
        and not f.sup()
        and type(rr[0][1]) is list
        and len(rr[0][1]) == 2
    ):
        k, ab = rr[0]
        return [
            K.US,
            K.LB,
            *name_toks(c, k),
            K.EQ,
            *pa(c, 4, ab[0]),
            K.RB,
            K.CARET,
            K.LB,
            *pa(c, 1, ab[1]),
            K.RB,
        ]
    rows = sub_rows(c, f)
    if not rows:
        return []
    if len(rows) == 1:
        return [K.US, K.LB, *rows[0], K.RB]
    return [K.US, K.LB, K.SUBSTACK, K.LB, *sep_by([K.NL], rows), K.RB, K.RB]


def sub_toks_t(c: Ctx, f: FaqForm) -> list:
    rows = sub_rows(c, f)
    if not rows:
        return []
    return [K.US, K.LPG, *sep_by([K.NL], rows), K.RP]


def sup_toks(c: Ctx, ns: list) -> list:
    """``Math.supToks``: the superscript set of names: LaTeX ``^{\\{f, g\\}}``,
    Typst ``^({f, g})``."""
    names = sep_by([K.COMMA], [name_toks(c, n) for n in ns])
    if c.sf == K.LATEX:
        return [K.CARET, K.LB, K.LSET, *names, K.RSET, K.RB]
    return [K.CARET, K.LPG, K.LSET, *names, K.RSET, K.RP]


def sup_t(c: Ctx, f: FaqForm) -> list:
    """``Math.supT``: the ``args`` set of a ``faq``, as a superscript, when it is
    one."""
    st = f.sup()
    return sup_toks(c, st) if st else []


def red_toks(c: Ctx, f: FaqForm) -> list:
    """``Math.redToks``: operator, subscript, the superscript set (on the operator
    only when there are no output indices), body at level 5."""
    sub = sub_toks_l(c, f) if c.sf == K.LATEX else sub_toks_t(c, f)
    sup = sup_t(c, f) if not f.out else []
    return [*head_toks(c.sf, f), *sub, *sup, *pa(c, 5, f.expr)]


def entry_toks(c: Ctx, f: FaqForm, j: Any) -> list:
    """``Math.entryToks``: an output entry: its range row when it has one."""
    if type(j) is str:
        v = look(j, f.ranges)
        if v is not MISSING:
            return row_toks(c, j, v)
        return name_toks(c, j)
    return [("num", 1)]


def faq_out(c: Ctx, f: FaqForm) -> Out:
    """``Math.faqOut``: the native ``faq``, wrapped with its output indices when it
    has some. A superscript set goes on the bracket, before its subscript; the form
    is then a power's level (a power of it, or an index into it, is
    parenthesized)."""
    if not f.out:
        return Out(5, red_toks(c, f))
    es = sep_by([K.COMMA], [entry_toks(c, f, j) for j in f.out])
    sup = sup_t(c, f)
    lvl = 8 if sup else 10
    if c.sf == K.LATEX:
        return Out(lvl, [K.LBKG, *red_toks(c, f), K.RBKG, *sup, K.US, K.LB, *es, K.RB])
    return Out(lvl, [K.LR, K.LP, K.LBK, *red_toks(c, f), K.RBK, K.RP, *sup, K.US, K.LPG, *es, K.RP])


# ## Block assembly (`makearray`)


def _strs_of(xs: list):
    """``Math.strsOf``: the strings of a list, when they are all strings."""
    return list(xs) if all(type(x) is str for x in xs) else None


class MkForm(NamedTuple):
    """``Math.MkForm``: a ``makearray`` node with a native spelling, by its parts:
    the output indices (empty when the node has no ``output_idx``), and the regions
    (lists of bound pairs) with their values."""

    out: list
    regions: list
    values: list


def mk_json(m: MkForm) -> Obj:
    """``Math.mkJson``."""
    kvs: list = [("args", []), ("op", "makearray")]
    if m.out:
        kvs.append(("output_idx", list(m.out)))
    kvs.append(("regions", [[[a, b] for a, b in r] for r in m.regions]))
    kvs.append(("values", m.values))
    return Obj(kvs)


def _regions_of(rs: list):
    """``Math.regionsOf``: the regions of a ``regions`` list, each a list of bound
    pairs."""
    out = []
    for r in rs:
        if type(r) is not list:
            return None
        ps = []
        for p in r:
            if type(p) is not list or len(p) != 2:
                return None
            ps.append((p[0], p[1]))
        out.append(ps)
    return out


def mk_cand(kvs: list):
    """``Math.mkCand``: the parts a ``makearray`` node would have."""
    rs = look("regions", kvs)
    vs = look("values", kvs)
    if type(rs) is not list or type(vs) is not list:
        return None
    o = look("output_idx", kvs)
    if o is MISSING:
        out: list | None = []
    elif type(o) is list:
        out = _strs_of(o)
    else:
        out = None
    regs = _regions_of(rs)
    if out is None or regs is None:
        return None
    return MkForm(out, regs, vs)


def mk_form(kvs: Obj):
    """``Math.mkForm``: the parts of a ``makearray`` node, when it is exactly the
    node they rebuild."""
    m = mk_cand(kvs)
    if m is None:
        return None
    return m if mk_json(m) == kvs else None


def mk_ok(m: MkForm) -> bool:
    """``Math.mkOK``: the conditions under which the native spelling reads back."""
    return (
        bool(m.values)
        and len(m.regions) == len(m.values)
        and all(is_e(v) for v in m.values)
        and all(r and all(is_e(a) and is_e(b) for a, b in r) for r in m.regions)
        and all(name_ok(n) for n in m.out)
    )


def _pair_toks(c: Ctx, p: tuple) -> list:
    """``Math.pairToks``: a bound pair ``a, b`` (its brackets are written around
    it)."""
    return [*pa(c, 1, p[0]), K.COMMA, *pa(c, 1, p[1])]


def _reg_toks(c: Ctx, r: list) -> list:
    """``Math.regToks``: a region ``[a, b] \\times [c, d]``, one bound pair per
    dimension."""
    out = [K.LBK, *_pair_toks(c, r[0]), K.RBK]
    for q in r[1:]:
        out.extend([K.TIMES, K.LBK, *_pair_toks(c, q), K.RBK])
    return out


#: ``Math.matHead``: the Typst table head ``mat(delim: "[", augment: #1,``.
MAT_HEAD = [
    K.MAT, K.LP, ("word", "delim"), K.COLON, ("txt", "["), K.COMMA, ("word", "augment"),
    K.COLON, ("code", 1), K.COMMA,
]  # fmt: skip


def _mk_sub(c: Ctx, out: list) -> list:
    """``Math.mkSub``: the output indices as the bracket's subscript."""
    if not out:
        return []
    names = sep_by([K.COMMA], [name_toks(c, n) for n in out])
    if c.sf == K.LATEX:
        return [K.US, K.LB, *names, K.RB]
    return [K.US, K.LPG, *names, K.RP]


def mk_out(c: Ctx, m: MkForm) -> Out:
    """``Math.mkOutT``: the native ``makearray``: a bracketed two-column table,
    value then region, one row per region in order; the output indices as its
    subscript."""
    latex = c.sf == K.LATEX
    cell = K.AMP if latex else K.COMMA
    rows = sep_by(
        [K.NL if latex else K.SEMI],
        [[*pa(c, 1, v), cell, *_reg_toks(c, r)] for v, r in zip(m.values, m.regions)],
    )
    if latex:
        return Out(10, [K.LBKG, K.BARR, *rows, K.EARR, K.RBKG, *_mk_sub(c, m.out)])
    return Out(10, [*MAT_HEAD, *rows, K.RP, *_mk_sub(c, m.out)])


def tname_ok(n: str) -> bool:
    return opn_ok(n) and not reserved_opn(n)


def _esc(c: Ctx, kvs: Obj) -> Out:
    o = look("op", kvs)
    args = look("args", kvs)
    if type(o) is str and type(args) is list:
        return Out(10, esc_toks(c.sf, o, fields_of(kvs), [pa(c, 1, a) for a in args]))
    return Out(10, [])


def _opn(c: Ctx, kvs: Obj) -> Out:
    o = look("op", kvs)
    args = look("args", kvs)
    if type(o) is str and type(args) is list:
        fs = fields_of(kvs)
        if (
            call_form_ok(o, fs)
            and opn_ok(o)
            and tparams(c.s, o) is None
            and all(key_ok(k) for k, _ in fs)
        ):
            fields = [
                [
                    *key_toks(c.sf, k),
                    K.EQ,
                    *(pa(c, 4, v) if math_field(o, (k, v)) else json_val(c.sf, v)),
                ]
                for k, v in fs
            ]
            return Out(10, open_toks(c.sf, o, [pa(c, 4, a) for a in args], fields))
    return _esc(c, kvs)


def prints_call_form(c: Ctx, kvs: Obj) -> bool:
    """The node ``kvs`` (of operator ``o``) is one the reader takes in the call
    form ``\\operatorname{o}(…; …)``: :func:`call_form_ok` holds, ``o`` is an
    operator name, no template ``o`` is in scope, and no native spelling applies.
    Field keys are not checked: a key :func:`key_ok` refuses still reads. Every
    native spelling has a fixed set of identifier keys, so a node with another key
    has none; otherwise :func:`pr` decides."""
    o = look("op", kvs)
    if type(o) is not str:
        return False
    fs = fields_of(kvs)
    if not (call_form_ok(o, fs) and opn_ok(o) and tparams(c.s, o) is None):
        return False
    return not native_form(c.sf, kvs)


def native_form(sf: str, kvs: Obj) -> bool:
    """A node :func:`call_form_ok` admits that :func:`pr` nevertheless writes in a
    native spelling: a ``faq``, a ``makearray`` or a ``const``. Decided from the
    node's own fields, without printing its operands; the other operators
    :func:`call_form_ok` admits have no native spelling."""
    o = look("op", kvs)
    if o == "faq":
        f = faq_form(kvs)
        return f is not None and faq_ok(f)
    if o == "makearray":
        m = mk_form(kvs)
        return m is not None and mk_ok(m)
    if o == "const":
        return const_native(sf, kvs) is not None
    return False


def const_native(sf: str, kvs: Obj):
    """The native spelling of a ``const`` node, if it has one: an array (rank 1 or
    2) of numbers, or a number or such an array with typeset units. ``None`` when
    the node prints in the call form."""
    n = len(kvs)
    if n == 3:
        (k0, args), (k1, o), (k2, v) = kvs
        if (
            k0 == "args"
            and type(args) is list
            and not args
            and k1 == "op"
            and o == "const"
            and k2 == "value"
        ):
            if type(v) is list:
                af = arr_form(v)
                if af is not None:
                    return Out(10, arr_toks(sf, af))
    elif n == 4:
        (k0, args), (k1, o), (k2, u), (k3, v) = kvs
        if (
            k0 == "args"
            and type(args) is list
            and not args
            and k1 == "op"
            and o == "const"
            and k2 == "units"
            and type(u) is str
            and k3 == "value"
            and units_ok(sf, u)
        ):
            tv = type(v)
            if tv is int or tv is Dec:
                return Out(7, [("num", v), ("units", factors_of(u))])
            if tv is list:
                af = arr_form(v)
                if af is not None:
                    return Out(7, [*arr_toks(sf, af), ("units", factors_of(u))])
    return None


def pr(c: Ctx, e: Any) -> Out:
    """``Math.pr``: the printer."""
    t = type(e)
    if t is int or t is Dec:
        return Out(7 if is_neg_num(e) else 10, [("num", e)])
    if t is str:
        return Out(10, name_toks(c, e))
    if t is not Obj:
        return Out(10, [])
    kvs = e
    sf = c.sf
    n = len(kvs)
    if n == 2:
        (k0, args), (k1, o) = kvs
        if k0 == "args" and type(args) is list and k1 == "op" and type(o) is str:
            return _pr_plain(c, kvs, o, args)
    elif n == 3:
        (k0, args), (k1, o), (k2, v2) = kvs
        if (
            k0 == "args"
            and type(args) is list
            and k1 == "op"
            and o == "D"
            and k2 == "wrt"
            and type(v2) is str
        ):
            w = v2
            if len(args) == 1:
                if w == "t":
                    return d_time(sf, pr(c, args[0]))
                if name_ok(w):
                    return d_space(sf, name_toks(c, w), pr(c, args[0]))
                return _esc(c, kvs)
            if len(args) >= 2:
                if w != "t" and name_ok(w):
                    return Out(10, d_call(sf, name_toks(c, w), [pa(c, 4, x) for x in args]))
                return _esc(c, kvs)
            return _esc(c, kvs)
        if (
            k0 == "args"
            and type(args) is list
            and not args
            and k1 == "op"
            and o == "const"
            and k2 == "value"
            and type(v2) is list
        ):
            out = const_native(sf, kvs)
            return out if out is not None else _opn(c, kvs)
    elif n == 4:
        (k0, args), (k1, v1), (k2, v2), (k3, v3) = kvs
        empty_args = k0 == "args" and type(args) is list and not args
        if (
            empty_args
            and k1 == "op"
            and v1 == "const"
            and k2 == "units"
            and type(v2) is str
            and k3 == "value"
        ):
            tv = type(v3)
            if tv is int or tv is Dec or tv is list:
                out = const_native(sf, kvs)
                return out if out is not None else _opn(c, kvs)
        if (
            empty_args
            and k1 == "bindings"
            and type(v1) is Obj
            and k2 == "name"
            and type(v2) is str
            and k3 == "op"
            and v3 == "apply_operator"
        ):
            return _pr_template(c, kvs, v2, v1)
    f = faq_form(kvs)
    if f is not None and faq_ok(f):
        return faq_out(c, f)
    m = mk_form(kvs)
    if m is not None and mk_ok(m):
        return mk_out(c, m)
    return _opn(c, kvs)


def _pr_plain(c: Ctx, kvs: Obj, o: str, args: list) -> Out:
    """The ``[("args", .arr as), ("op", .str o)]`` case of ``Math.pr``."""
    sf = c.sf
    kind, kw = kind_of(o)
    na = len(args)
    if kind == _MINUS:
        if na == 1:
            t = pa(c, 5, args[0])
            body = grp(sf, t) if starts_num(t) else t
            return Out(5, [K.MINUS, *body])
        if na == 2:
            return Out(4, [*pa(c, 4, args[0]), K.MINUS, *pa(c, 5, args[1])])
    elif kind == _DIV:
        if na == 2:
            a, b = args
            if sf == K.LATEX:
                return Out(10, [K.FRAC, K.LB, *pa(c, 1, a), K.RB, K.LB, *pa(c, 1, b), K.RB])
            return Out(7, [*pa(c, 8, a), K.SLASH, *pa(c, 8, b)])
    elif kind == _POW:
        if na == 2:
            a, b = args
            if sf == K.LATEX:
                ex = [K.LB, *pa(c, 1, b), K.RB]
            else:
                st = simple_e(c, b)
                ex = [st] if st is not None else grp(sf, pr(c, b).toks)
            return Out(8, [*pa(c, 9, a), K.CARET, *ex])
    elif kind == _LNOT:
        if na == 1:
            return Out(6, [K.LNOT, *pa(c, 6, args[0])])
    elif kind == _TRU:
        if na == 0:
            return Out(10, [("txt", "true")])
    elif kind == _FLS:
        if na == 0:
            return Out(10, [("txt", "false")])
    elif kind == _ITE:
        if na == 3:
            cnd, a, b = args
            rows = case_row(sf, pa(c, 1, a), pa(c, 1, cnd))
            rows.extend(pr(c, b).crow)
            return Out(10, cases_toks(sf, rows), rows)
    elif kind == _UN:
        if na == 1:
            return Out(10, un_toks(sf, kw, pa(c, 1, args[0])))
    elif kind == _IC:
        if na == 1 and type(args[0]) is str:
            if name_ok(args[0]):
                return Out(10, [*name_toks(c, args[0]), *ic_tail(sf)])
            return _esc(c, kvs)
    elif kind == _INDEX:
        if na >= 2:
            base, is_ = args[0], args[1:]
            subs = [pa(c, 1, x) for x in is_]
            sl = sub_list(sf, simple_arg(c, is_), subs)
            if sub_ok(c.s, base, is_) and not sub_pat(sf, sl):
                return Out(9, [*name_toks(c, base if type(base) is str else ""), *sl])
            return Out(9, [*pa(c, 10, base), K.LBK, *sep_by([K.COMMA], subs), K.RBK])
    elif kind == _CMP:
        if na == 2:
            return Out(3, [*pa(c, 4, args[0]), kw, *pa(c, 4, args[1])])
    elif kind == _PLUS:
        if na >= 2:
            return Out(4, sep_by([K.PLUS], [pa(c, 5, x) for x in args]))
        return _opn(c, kvs)
    elif kind == _TIMES:
        if na >= 2:
            return Out(5, mul_toks([pa(c, 6, x) for x in args]))
        return _opn(c, kvs)
    elif kind == _LAND:
        if na >= 2:
            return Out(2, sep_by([K.LAND], [pa(c, 3, x) for x in args]))
        return _opn(c, kvs)
    elif kind == _LOR:
        if na >= 2:
            return Out(1, sep_by([K.LOR], [pa(c, 2, x) for x in args]))
        return _opn(c, kvs)
    elif kind == _MM:
        if na >= 2:
            return Out(10, call_toks(sf, [kw], [pa(c, 1, x) for x in args]))
        return _opn(c, kvs)
    elif kind == _CALL:
        return Out(10, call_toks(sf, [("opn", o)], [pa(c, 4, x) for x in args]))
    return _opn(c, kvs)


def _pr_template(c: Ctx, kvs: Obj, n: str, bs: Obj) -> Out:
    """The ``apply_expression_template`` case of ``Math.pr``."""
    sf = c.sf
    if not (tname_ok(n) and keys_sorted(bs) and all(is_e(v) for _, v in bs)):
        return _esc(c, kvs)
    vals = [(k, pa(c, 4, v)) for k, v in bs]
    ps = positional(c.s, n, bs)
    if ps is not None:
        args = []
        for p in ps:
            got: list = []
            for k, v in vals:
                if k == p:
                    got = v
                    break
            args.append(got)
        return Out(10, call_toks(sf, [("opn", n)], args))
    if bs and all(name_ok(k) for k, _ in bs):
        return Out(10, call_toks(sf, [("opn", n)], [[*name_toks(c, k), K.EQ, *v] for k, v in vals]))
    if not bs:
        return Out(5, [("opn", n)])
    return _esc(c, kvs)


def pa(c: Ctx, need: int, e: Any) -> list:
    """``Math.pa``: the tokens of an expression for a position needing level
    ``L``."""
    return pr(c, e).at(c.sf, need)


def print_toks(sf: str, s: Sym, e: Any) -> list:
    """``Math.print``: the tokens of a whole expression."""
    return pa(Ctx(sf, s), 1, e)
