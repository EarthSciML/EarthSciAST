"""Typst math: spelling and lexing of tokens.

Port of ``formal/Esm/Document/Math/Typst.lean``. Typst has one parenthesis: the
lexer reads ``(`` right after a name, a digit, ``)`` or ``"`` as a call parenthesis
and any other ``(`` as a grouping one; the renderer writes no space between a
function name and its ``(`` and a space between an operand and a following
grouping ``(``.
"""

from __future__ import annotations

from typing import Any

from .. import number, typst_dict
from ..strings import parse_quoted, quote
from . import token as K
from . import units as U
from .expr import is_dig, is_greek, is_letter
from .parser import atom_start
from .surface import is_bin, lex_signed, sci_split

# ## Spelling

TIMES_TEN = " times 10^"


def num_chars(n: Any) -> str:
    """``Typst.numChars``."""
    sp = sci_split(n)
    if sp is not None:
        m, e = sp
        return m + TIMES_TEN + (f"({e})" if e < 0 else str(e))
    return number.print_num(n)


KW_CHARS = {
    K.PLUS: "+",
    K.MINUS: "-",
    K.EQ: "=",
    K.NE: "!=",
    K.LT: "<",
    K.GT: ">",
    K.LE: "<=",
    K.GE: ">=",
    K.LAND: "and",
    K.LOR: "or",
    K.LNOT: "not",
    K.CDOT: "dot",
    K.TIMES: "times",
    K.SLASH: "/",
    K.CARET: "^",
    K.US: "_",
    K.LP: "(",
    K.LPG: "(",
    K.RP: ")",
    K.LBK: "[",
    K.RBK: "]",
    K.COMMA: ",",
    K.SEMI: ";",
    K.COLON: ":",
    K.AMP: "&",
    K.SDOT: '"."',
    K.SQRT: "sqrt",
    K.EXP: "exp",
    K.LN: "ln",
    K.LOG: "log",
    K.SIN: "sin",
    K.COS: "cos",
    K.TAN: "tan",
    K.ASIN: "arcsin",
    K.ACOS: "arccos",
    K.ATAN: "arctan",
    K.SINH: "sinh",
    K.COSH: "cosh",
    K.TANH: "tanh",
    K.MIN: "min",
    K.MAX: "max",
    K.ABS: "abs",
    K.FLOOR: "floor",
    K.CEIL: "ceil",
    K.PDIFF: "partial",
    K.NABLA: "nabla",
    K.DIF: "dif",
    K.CASES: "cases",
    K.ESMNODE: "esm.node",
    K.VEC: "vec",
    K.MAT: "mat",
    K.SUM: "sum",
    K.PROD: "product",
    K.INN: "in",
    K.LIMITS: "limits",
    K.LR: "lr",
    K.NL: "\\",
    K.LSET: "{",
    K.RSET: "}",
}


def piece_chars(p: tuple) -> str:
    """``Typst.pieceChars``."""
    out = "upright(" + quote(True, p[0]) + ")"
    return out + "_" + p[1] if p[1] else out


def unit_chars(fs: tuple) -> str:
    """``Typst.unitChars``."""
    return "thin " + U.join_with(U.typst_factor, U.THIN_SEP, fs)


def tok_chars(t: Any) -> str:
    """``Typst.tokChars``."""
    if type(t) is str:
        return KW_CHARS.get(t, "")
    tag, v = t
    if tag == "num":
        return num_chars(v)
    if tag == "letter" or tag == "greek" or tag == "word":
        return v
    if tag == "it":
        return "italic(" + quote(True, v) + ")"
    if tag == "ups":
        return "".join(piece_chars(p) for p in v)
    if tag == "opn":
        return "op(" + quote(True, v) + ")"
    if tag == "txt":
        return quote(True, v)
    if tag == "code":
        return "#" + typst_dict.encode(v)
    if tag == "units":
        return unit_chars(v)
    return ""


# ## Spacing


def is_id_c(c: str) -> bool:
    return is_letter(c) or is_dig(c)


def merges(t: Any, last: str, c: str) -> bool:
    """``Typst.merges``: a space is needed between ``t`` (whose spelling ends with
    ``last``) and a following token starting with ``c``."""
    if last != "" and is_letter(last) and is_id_c(c):
        return True
    if type(t) is str:
        return (
            (t == K.MINUS and is_dig(c))
            or ((t == K.LT or t == K.GT) and c == "=")
            or (t == K.SLASH and c == "/")
        )
    tag = t[0]
    return (
        (tag == "num" and (is_id_c(c) or c == "."))
        or (tag == "ups" and (is_dig(c) or c == "u" or c == "_"))
        or (tag == "code" and is_id_c(c))
        or (tag == "units" and (is_dig(c) or c == "^"))
    )


def call_end(last: str) -> bool:
    """``Typst.callEnd``: a spelling ending with a character after which ``(`` is
    a call parenthesis."""
    return last != "" and (is_id_c(last) or last == ")" or last == '"')


_ATOM_END_TAGS = frozenset({"num", "letter", "greek", "word", "it", "ups", "txt", "code", "units"})


def atom_end(t: Any) -> bool:
    """``Typst.atomEnd``."""
    if type(t) is str:
        return t == K.RP or t == K.RBK
    return t[0] in _ATOM_END_TAGS


def _pretty(p: Any, t1: Any, t2: Any) -> bool:
    return (
        is_bin(t1)
        or is_bin(t2)
        or t1 in (K.COMMA, K.COLON, K.SEMI)
        or (t2 == K.MINUS and atom_end(t1))
        or (t1 == K.MINUS and p is not None and atom_end(p))
        or (atom_end(t1) and atom_start(t2))
        or (type(t2) is tuple and t2[0] == "units")
    )


def render(ts: list) -> str:
    """``Typst.render``: no space before a call parenthesis, nor before the ``[`` of
    an index."""
    chars = [tok_chars(t) for t in ts]
    out = []
    n = len(ts)
    for i in range(n):
        t = ts[i]
        c1 = chars[i]
        out.append(c1)
        if i + 1 < n:
            t2 = ts[i + 1]
            c2 = chars[i + 1]
            last = c1[-1] if c1 else ""
            if t2 == K.LPG:
                need = call_end(last)
            elif t2 == K.LP:
                need = False
            else:
                need = c2 != "" and merges(t, last, c2[0])
            p = ts[i - 1] if i > 0 else None
            if need or (_pretty(p, t, t2) and t2 != K.LP and not (t2 == K.LBK and atom_end(t))):
                out.append(" ")
    return "".join(out)


# ## Lexing

IDENT_KW = {
    "and": K.LAND,
    "or": K.LOR,
    "not": K.LNOT,
    "dot": K.CDOT,
    "times": K.TIMES,
    "sqrt": K.SQRT,
    "exp": K.EXP,
    "ln": K.LN,
    "log": K.LOG,
    "sin": K.SIN,
    "cos": K.COS,
    "tan": K.TAN,
    "arcsin": K.ASIN,
    "arccos": K.ACOS,
    "arctan": K.ATAN,
    "sinh": K.SINH,
    "cosh": K.COSH,
    "tanh": K.TANH,
    "min": K.MIN,
    "max": K.MAX,
    "abs": K.ABS,
    "floor": K.FLOOR,
    "ceil": K.CEIL,
    "partial": K.PDIFF,
    "nabla": K.NABLA,
    "dif": K.DIF,
    "cases": K.CASES,
    "vec": K.VEC,
    "mat": K.MAT,
    "sum": K.SUM,
    "product": K.PROD,
    "in": K.INN,
    "limits": K.LIMITS,
    "lr": K.LR,
}


def _id_end(s: str, i: int) -> int:
    n = len(s)
    while i < n and is_id_c(s[i]):
        i += 1
    return i


def _quoted_arg(s: str, i: int):
    """``Typst.quotedArg``: ``("…")`` after a function name."""
    if not s.startswith("(", i):
        return None
    r = parse_quoted(True, s, i + 1)
    if r is None or not s.startswith(")", r[1]):
        return None
    return r[0], r[1] + 1


def _upright_pieces(s: str, i: int):
    """``Typst.pieces``: adjacent ``upright("…")`` pieces, each with an optional
    digit subscript."""
    out: list = []
    while True:
        if not s.startswith("upright", i):
            return out, i
        r = _quoted_arg(s, i + 7)
        if r is None:
            return out, i
        txt, j = r
        d = ""
        if s.startswith("_", j):
            k = j + 1
            while k < len(s) and is_dig(s[k]):
                k += 1
            if k > j + 1:
                d = s[j + 1 : k]
                j = k
        out.append((txt, d))
        i = j


_WS = " \n\t\r"


def _skip(s: str, i: int) -> int:
    n = len(s)
    while i < n and s[i] in _WS:
        i += 1
    return i


def sci_exp(s: str, i: int):
    """``Typst.sciExp``: the scientific tail ``times 10^exponent``."""
    j = _skip(s, i)
    if not s.startswith("times", j):
        return None
    j += 5
    if j < len(s) and is_id_c(s[j]):
        return None
    j = _skip(s, j)
    if not s.startswith("10", j):
        return None
    j = _skip(s, j + 2)
    if not s.startswith("^", j):
        return None
    j = _skip(s, j + 1)
    if s.startswith("(", j):
        r = number.parse_int(s, _skip(s, j + 1))
        if r is None:
            return None
        k = _skip(s, r[1])
        if not s.startswith(")", k):
            return None
        return r[0], k + 1
    return number.parse_int(s, j)


PUNCT = {
    "+": K.PLUS,
    "-": K.MINUS,
    "=": K.EQ,
    "<": K.LT,
    ">": K.GT,
    "/": K.SLASH,
    "^": K.CARET,
    "_": K.US,
    ")": K.RP,
    "[": K.LBK,
    "]": K.RBK,
    ",": K.COMMA,
    ";": K.SEMI,
    ":": K.COLON,
    "&": K.AMP,
    ".": K.SDOT,
    "\\": K.NL,
    "{": K.LSET,
    "}": K.RSET,
}


def _lex_ident(s: str, i: int):
    """``Typst.lexIdent``: one identifier-started token."""
    j = _id_end(s, i)
    w = s[i:j]
    if w == "upright":
        if s.startswith("(e)", j):
            return ("ups", (("e", ""),)), j + 3
        ps, k = _upright_pieces(s, i)
        if not ps:
            return None
        return ("ups", tuple(ps)), k
    if w == "italic":
        r = _quoted_arg(s, j)
        return None if r is None else (("it", r[0]), r[1])
    if w == "op":
        r = _quoted_arg(s, j)
        return None if r is None else (("opn", r[0]), r[1])
    if w == "thin":
        if not s.startswith(" ", j):
            return None
        r = U.p_sep_by(U.p_t_factor, U.THIN_SEP, s, j + 1)
        return None if r is None else (("units", r[0]), r[1])
    if w == "esm":
        if s.startswith(".node", j):
            return K.ESMNODE, j + 5
        return None
    k = IDENT_KW.get(w)
    if k is not None:
        return k, j
    if is_greek(w):
        return ("greek", w), j
    if len(w) == 1:
        return ("letter", w), j
    return ("word", w), j


def _lex_one(prev: str, s: str, i: int):
    """``Typst.lexOne``: one token at ``i``; ``prev`` is the character just before
    it ("" after a space)."""
    c = s[i]
    if c == "(":
        if prev != "" and (is_id_c(prev) or prev == ")" or prev == '"'):
            return K.LP, i + 1
        return K.LPG, i + 1
    if c == '"':
        r = parse_quoted(True, s, i)
        if r is None:
            return None
        if r[0] == ".":
            return K.SDOT, r[1]
        return ("txt", r[0]), r[1]
    if c == "#":
        r = typst_dict.p_val(s, i + 1)
        return None if r is None else (("code", r[0]), r[1])
    n = len(s)
    if i + 1 < n and s[i + 1] == "=":
        if c == "<":
            return K.LE, i + 2
        if c == ">":
            return K.GE, i + 2
        if c == "!":
            return K.NE, i + 2
    if is_dig(c) or (c == "-" and i + 1 < n and is_dig(s[i + 1])):
        return lex_signed(sci_exp, s, i)
    if is_letter(c):
        return _lex_ident(s, i)
    k = PUNCT.get(c)
    return None if k is None else (k, i + 1)


def lex(s: str):
    """``Typst.lex``: read Typst math into tokens."""
    out: list = []
    prev = ""
    i = 0
    n = len(s)
    while True:
        prev2 = "" if (i < n and s[i] in _WS) else prev
        i = _skip(s, i)
        if i >= n:
            return out
        r = _lex_one(prev2, s, i)
        if r is None:
            return None
        t = r[0]
        ch = tok_chars(t)
        prev = ch[-1] if ch else ""
        out.append(t)
        i = r[1]
