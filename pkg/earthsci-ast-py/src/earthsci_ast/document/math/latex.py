"""LaTeX math: spelling and lexing of tokens.

Port of ``formal/Esm/Document/Math/Latex.lean``. :func:`render` spells a token list
as LaTeX math, writing a space between two tokens where the reader needs one
(``needSpace``) and where it reads better (``pretty``); :func:`lex` reads it back,
skipping spaces and the spacing commands.
"""

from __future__ import annotations

from typing import Any

from .. import number
from ..strings import unquote_body
from . import token as K
from . import units as U
from .expr import is_dig, is_greek, is_letter
from .parser import atom_start, units_of_raw
from .printer import char_digit_nat, char_of_nat, dig3, esc_t, key_special, raw_b, unesc_t
from .surface import is_bin, lex_signed, sci_split

# ## Spelling


def fix_us_prefix(s: str, i: int) -> tuple[str, int]:
    """``Latex.fixUs`` up to and including the first closing quote: ``\\_`` as
    ``_``, every other ``\\c`` pair kept. (The Lean function copies the rest of the
    input unchanged after that quote, so the string reader never looks past it.)"""
    out = []
    n = len(s)
    while i < n:
        c = s[i]
        if c == "\\" and i + 1 < n:
            d = s[i + 1]
            out.append("_" if d == "_" else "\\" + d)
            i += 2
        elif c == '"':
            out.append('"')
            break
        else:
            out.append(c)
            i += 1
    return "".join(out), i


def str_plain(c: str) -> bool:
    """``Latex.strPlain``."""
    n = ord(c)
    return 32 <= n <= 126 and not key_special(c) and c not in "_{}"


def esc_s(s: str) -> str:
    """``Latex.escS``: the spelling of a JSON string's characters inside
    ``\\text{"…"}``."""
    out = []
    for c in s:
        if str_plain(c):
            out.append(c)
        elif c in "_{}":
            out.append("\\" + c)
        elif ord(c) < 1000:
            out.append("{\\char" + dig3(ord(c)) + "}")
        else:
            out.append("{\\char" + f"{ord(c) % 10_000_000:07d}" + "}")
    return "".join(out)


def unesc_s(s: str) -> str:
    """``Latex.unescS``: undo :func:`esc_s`."""
    out = []
    i, n = 0, len(s)
    d = char_digit_nat
    while i < n:
        if s.startswith("{\\char", i):
            if i + 9 < n and s[i + 9] == "}":
                out.append(char_of_nat(100 * d(s[i + 6]) + 10 * d(s[i + 7]) + d(s[i + 8])))
                i += 10
                continue
            if i + 13 < n and s[i + 13] == "}":
                v = 0
                for c in s[i + 6 : i + 13]:
                    v = 10 * v + d(c)
                out.append(char_of_nat(v))
                i += 14
                continue
        if s[i] == "\\" and i + 1 < n:
            out.append(s[i + 1])
            i += 2
        else:
            out.append(s[i])
            i += 1
    return "".join(out)


def str_l(s: str) -> str:
    """``Latex.strL``: a JSON string in LaTeX: ``\\text{"…"}``."""
    return '\\text{"' + esc_s(s) + '"}'


def text_tok(raw: str) -> tuple:
    """``Latex.textTok``: a JSON string when the text is double-quoted, else
    text."""
    if len(raw) >= 2 and raw[0] == '"' and raw[-1] == '"':
        return ("jstr", unesc_s(raw[1:-1]))
    return ("txt", raw)


TIMES_TEN = " \\times 10^{"


def num_chars(n: Any) -> str:
    """``Latex.numChars``."""
    sp = sci_split(n)
    if sp is not None:
        return sp[0] + TIMES_TEN + str(sp[1]) + "}"
    return number.print_num(n)


KW_CHARS = {
    K.PLUS: "+",
    K.MINUS: "-",
    K.EQ: "=",
    K.NE: "\\ne",
    K.LT: "<",
    K.GT: ">",
    K.LE: "\\le",
    K.GE: "\\ge",
    K.LAND: "\\land",
    K.LOR: "\\lor",
    K.LNOT: "\\lnot",
    K.CDOT: "\\cdot",
    K.TIMES: "\\times",
    K.SLASH: "/",
    K.CARET: "^",
    K.US: "_",
    K.LP: "(",
    K.RP: ")",
    K.LPG: "\\left(",
    K.RPG: "\\right)",
    K.LB: "{",
    K.RB: "}",
    K.LBK: "[",
    K.RBK: "]",
    K.COMMA: ",",
    K.SEMI: ";",
    K.COLON: ":",
    K.AMP: "&",
    K.NL: "\\\\",
    K.SDOT: ".",
    K.FRAC: "\\frac",
    K.SQRT: "\\sqrt",
    K.EXP: "\\exp",
    K.LN: "\\ln",
    K.LOG: "\\log",
    K.SIN: "\\sin",
    K.COS: "\\cos",
    K.TAN: "\\tan",
    K.ASIN: "\\arcsin",
    K.ACOS: "\\arccos",
    K.ATAN: "\\arctan",
    K.SINH: "\\sinh",
    K.COSH: "\\cosh",
    K.TANH: "\\tanh",
    K.MIN: "\\min",
    K.MAX: "\\max",
    K.LABS: "\\left|",
    K.RABS: "\\right|",
    K.LFLOOR: "\\lfloor",
    K.RFLOOR: "\\rfloor",
    K.LCEIL: "\\lceil",
    K.RCEIL: "\\rceil",
    K.PDIFF: "\\partial",
    K.NABLA: "\\nabla",
    K.DOTACC: "\\dot",
    K.BCASES: "\\begin{cases}",
    K.ECASES: "\\end{cases}",
    K.BMAT: "\\begin{bmatrix}",
    K.EMAT: "\\end{bmatrix}",
    K.SUM: "\\sum",
    K.PROD: "\\prod",
    K.INN: "\\in",
    K.SUBSTACK: "\\substack",
    K.LIMITS_L: "\\limits",
    K.LBKG: "\\left[",
    K.RBKG: "\\right]",
    K.BARR: "\\begin{array}{l|l}",
    K.EARR: "\\end{array}",
    K.LSET: "\\{",
    K.RSET: "\\}",
}


def tok_chars(t: Any) -> str:
    """``Latex.tokChars``."""
    if type(t) is str:
        return KW_CHARS.get(t, "")
    tag, v = t
    if tag == "num":
        return num_chars(v)
    if tag == "letter" or tag == "word":
        return v
    if tag == "greek":
        return "\\" + v
    if tag == "it":
        return "\\mathit{" + esc_t(v) + "}"
    if tag == "rm":
        return "\\mathrm{" + v + "}"
    if tag == "opn":
        return "\\operatorname{" + esc_t(v) + "}"
    if tag == "txt":
        return "\\text{" + v + "}"
    if tag == "jstr":
        return str_l(v)
    if tag == "esc":
        return "\\esm{" + esc_t(v) + "}"
    if tag == "units":
        return "\\,\\mathrm{" + U.latex_body(v) + "}"
    if tag == "arrc":
        return "\\begin{array}{" + "c" * v + "}"
    return ""


# ## Spacing

_ATOM_END_KW = frozenset({K.RP, K.RPG, K.RB, K.RBK, K.RABS, K.RFLOOR, K.RCEIL, K.ECASES})
_ATOM_END_TAGS = frozenset(
    {"num", "letter", "greek", "word", "it", "rm", "ups", "txt", "jstr", "code", "units"}
)


def ends_alpha(t: Any) -> bool:
    """``Latex.endsAlpha``: ``t`` ends with letters a following letter would
    extend."""
    if type(t) is str:
        k = KW_CHARS.get(t, "")
        return k != "" and is_letter(k[-1])
    return t[0] in ("letter", "word", "greek")


def merges(t: Any, c: str) -> bool:
    """``Latex.merges``: a space is needed between ``t`` and a following token
    starting with ``c``."""
    return (
        (ends_alpha(t) and is_letter(c))
        or (type(t) is tuple and t[0] == "num" and (is_dig(c) or c == "." or c == "e"))
        or (t == K.MINUS and is_dig(c))
    )


def atom_end(t: Any) -> bool:
    """``Latex.atomEnd``: tokens that end an operand."""
    if type(t) is str:
        return t in _ATOM_END_KW
    return t[0] in _ATOM_END_TAGS


def pretty(p: Any, t1: Any, t2: Any) -> bool:
    """``Latex.pretty``: spacing for reading."""
    return (
        is_bin(t1)
        or is_bin(t2)
        or t1 in (K.COMMA, K.COLON, K.SEMI)
        or (t2 == K.MINUS and atom_end(t1))
        or (t1 == K.MINUS and p is not None and atom_end(p))
        or (atom_end(t1) and atom_start(t2) and t2 != K.LP and t2 != K.LBK)
        or t1 == K.BARR
        or t2 == K.EARR
    )


def render(ts: list) -> str:
    """``Latex.render``: the LaTeX spelling of a token list."""
    chars = [tok_chars(t) for t in ts]
    out = []
    n = len(ts)
    for i in range(n):
        t = ts[i]
        out.append(chars[i])
        if i + 1 < n:
            t2 = ts[i + 1]
            c2 = chars[i + 1]
            p = ts[i - 1] if i > 0 else None
            if (c2 != "" and merges(t, c2[0])) or pretty(p, t, t2):
                out.append(" ")
    return "".join(out)


# ## Lexing

CTRL_KW = {
    "ne": K.NE,
    "neq": K.NE,
    "le": K.LE,
    "leq": K.LE,
    "ge": K.GE,
    "geq": K.GE,
    "land": K.LAND,
    "lor": K.LOR,
    "lnot": K.LNOT,
    "cdot": K.CDOT,
    "times": K.TIMES,
    "frac": K.FRAC,
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
    "lfloor": K.LFLOOR,
    "rfloor": K.RFLOOR,
    "lceil": K.LCEIL,
    "rceil": K.RCEIL,
    "partial": K.PDIFF,
    "nabla": K.NABLA,
    "dot": K.DOTACC,
    "sum": K.SUM,
    "prod": K.PROD,
    "in": K.INN,
    "substack": K.SUBSTACK,
    "limits": K.LIMITS_L,
}


def _let_end(s: str, i: int) -> int:
    n = len(s)
    while i < n and is_letter(s[i]):
        i += 1
    return i


def ctrl_tok(w: str, s: str, i: int):
    """``Latex.ctrlTok``: after a control word: its token."""
    if w in ("mathit", "mathrm", "operatorname", "text", "esm"):
        if not s.startswith("{", i):
            return None
        r = raw_b(0, s, i + 1)
        if r is None:
            return None
        raw, j = r
        if w == "mathit":
            return ("it", unesc_t(raw)), j
        if w == "mathrm":
            return ("rm", raw), j
        if w == "operatorname":
            return ("opn", unesc_t(raw)), j
        if w == "text":
            return text_tok(raw), j
        return ("esc", unesc_t(raw)), j
    if w in ("left", "bigl", "Bigl"):
        c = s[i] if i < len(s) else ""
        if c == "(":
            return K.LPG, i + 1
        if c == "[":
            return (K.LBKG if w == "left" else K.LBK), i + 1
        if c == "|" and w == "left":
            return K.LABS, i + 1
        return None
    if w in ("right", "bigr", "Bigr"):
        c = s[i] if i < len(s) else ""
        if c == ")":
            return K.RPG, i + 1
        if c == "]":
            return (K.RBKG if w == "right" else K.RBK), i + 1
        if c == "|" and w == "right":
            return K.RABS, i + 1
        return None
    if w == "begin":
        if s.startswith("{cases}", i):
            return K.BCASES, i + 7
        if s.startswith("{bmatrix}", i):
            return K.BMAT, i + 9
        if s.startswith("{array}{l|l}", i):
            return K.BARR, i + 12
        if s.startswith("{array}{c", i):
            j = i + 8
            while j < len(s) and s[j] == "c":
                j += 1
            if s.startswith("}", j):
                return ("arrc", j - i - 8), j + 1
        return None
    if w == "end":
        if s.startswith("{cases}", i):
            return K.ECASES, i + 7
        if s.startswith("{bmatrix}", i):
            return K.EMAT, i + 9
        if s.startswith("{array}", i):
            return K.EARR, i + 7
        return None
    if is_greek(w):
        return ("greek", w), i
    k = CTRL_KW.get(w)
    return None if k is None else (k, i)


_WS = " \n\t\r"


def _skip_sp(s: str, i: int) -> int:
    """``Latex.skipSp``: white space and the two-character spacing commands."""
    n = len(s)
    while i < n:
        c = s[i]
        if c in _WS:
            i += 1
        elif c == "\\" and i + 1 < n and s[i + 1] in ";:! ,":
            i += 2
        else:
            break
    return i


def sci_exp(s: str, i: int):
    """``Latex.sciExp``: the scientific tail ``\\times 10^{exponent}``."""
    j = _skip_sp(s, i)
    if not s.startswith("\\times", j):
        return None
    j += 6
    if j < len(s) and is_letter(s[j]):
        return None
    j = _skip_sp(s, j)
    if not s.startswith("10", j):
        return None
    j = _skip_sp(s, j + 2)
    if not s.startswith("^", j):
        return None
    j = _skip_sp(s, j + 1)
    if not s.startswith("{", j):
        return None
    r = number.parse_int(s, _skip_sp(s, j + 1))
    if r is None:
        return None
    j = _skip_sp(s, r[1])
    if not s.startswith("}", j):
        return None
    return r[0], j + 1


def unit_tok(s: str, i: int):
    """``Latex.unitTok``: after ``\\,``: a unit ``\\mathrm{…}``."""
    n = len(s)
    while i < n and s[i] in _WS:
        i += 1
    if not s.startswith(U.MATHRM_OPEN, i):
        return None
    r = raw_b(0, s, i + len(U.MATHRM_OPEN))
    if r is None:
        return None
    fs = units_of_raw(r[0])
    return None if fs is None else (fs, r[1])


PUNCT = {
    "+": K.PLUS,
    "-": K.MINUS,
    "=": K.EQ,
    "<": K.LT,
    ">": K.GT,
    "/": K.SLASH,
    "^": K.CARET,
    "_": K.US,
    "(": K.LP,
    ")": K.RP,
    "{": K.LB,
    "}": K.RB,
    "[": K.LBK,
    "]": K.RBK,
    ",": K.COMMA,
    ";": K.SEMI,
    ":": K.COLON,
    "&": K.AMP,
    ".": K.SDOT,
}


def lex_one(s: str, i: int):
    """``Latex.lexOne``: one token at ``i``."""
    n = len(s)
    c = s[i]
    if c == "\\":
        if i + 1 >= n:
            return None
        d = s[i + 1]
        if is_letter(d):
            j = _let_end(s, i + 1)
            return ctrl_tok(s[i + 1 : j], s, j)
        if d == ",":
            r = unit_tok(s, i + 2)
            return None if r is None else (("units", r[0]), r[1])
        if d == "\\":
            return K.NL, i + 2
        if d == "{":
            return K.LSET, i + 2
        if d == "}":
            return K.RSET, i + 2
        return None
    if c == '"':
        fixed, stop = fix_us_prefix(s, i + 1)
        r = unquote_body(False, fixed, 0)
        if r is None or r[1] != len(fixed):
            return None
        return ("jstr", r[0]), stop + 1
    if is_dig(c) or (c == "-" and i + 1 < n and is_dig(s[i + 1])):
        return lex_signed(sci_exp, s, i)
    if is_letter(c):
        j = _let_end(s, i)
        if j - i == 1:
            return ("letter", c), j
        return ("word", s[i:j]), j
    k = PUNCT.get(c)
    return None if k is None else (k, i + 1)


def _skip_ws(s: str, i: int) -> int:
    """``Latex.skipWs``: spaces and the spacing commands (``\\,`` too, unless a unit
    follows it)."""
    n = len(s)
    while i < n:
        c = s[i]
        if c in _WS:
            i += 1
            continue
        if c == "\\" and i + 1 < n:
            d = s[i + 1]
            if d in ";:! ":
                i += 2
                continue
            if d == ",":
                if unit_tok(s, i + 2) is not None:
                    return i
                i += 2
                continue
            j = _let_end(s, i + 1)
            w = s[i + 1 : j]
            if w == "quad" or w == "qquad":
                i = j
                continue
        return i
    return i


def lex(s: str):
    """``Latex.lex``: read LaTeX math into tokens."""
    out: list = []
    i = 0
    n = len(s)
    while True:
        i = _skip_ws(s, i)
        if i >= n:
            return out
        r = lex_one(s, i)
        if r is None:
            return None
        out.append(r[0])
        i = r[1]
