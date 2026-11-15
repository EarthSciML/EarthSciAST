"""Typeset unit spellings: LaTeX and Typst, with no unit package.

Port of ``formal/Esm/Units/Typeset.lean``, with the ``Esm.Units`` helpers it uses.

**LaTeX**: the canonical spelling's layout inside ``\\mathrm{…}``: numerator factors
joined by ``\\,``, a denominator after ``/`` (parenthesized when it has more than
one factor), exponents as braced superscripts, ``_`` and ``%`` escaped.

**Typst**: one ``upright("sym")^(exp)`` per factor with its signed exponent,
factors separated by `` thin ``.

A factor is ``(symbol, Fraction)``; a factor list is a tuple of factors.
"""

from __future__ import annotations

from fractions import Fraction
from functools import lru_cache
from typing import Callable

ONE = Fraction(1)


def _is_ident(c: str) -> bool:
    return ("a" <= c <= "z") or ("A" <= c <= "Z") or ("0" <= c <= "9") or c == "_"


def num_factors(l: tuple) -> tuple:
    """``Esm.Units.numFactors``: the factors with a positive exponent."""
    return tuple(f for f in l if f[1] > 0)


def den_factors(l: tuple) -> tuple:
    """``Esm.Units.denFactors``: the factors with a nonpositive exponent."""
    return tuple(f for f in l if f[1] <= 0)


def sym_ok(s: str) -> bool:
    """``Esm.Units.symOK``: ``%``, or a symbol run, and not ``dimensionless``."""
    run = s != "" and all(_is_ident(c) for c in s) and not all("0" <= c <= "9" for c in s)
    return (s == "%" or run) and s != "dimensionless"


def digs(n: int) -> str:
    """``Esm.Units.digs``: the decimal digits of ``n`` (empty for ``0``)."""
    return "" if n == 0 else str(n)


def _p_digits(s: str, i: int):
    j = i
    while j < len(s) and "0" <= s[j] <= "9":
        j += 1
    if j == i:
        return None
    return int(s[i:j]), j


def join_with(pr: Callable, sep: str, l: tuple) -> str:
    return sep.join(pr(f) for f in l)


def p_sep_by(pf: Callable, sep: str, s: str, i: int):
    """``Esm.Units.pSepBy``: items read by ``pf``, separated by ``sep``."""
    out = []
    while True:
        r = pf(s, i)
        if r is None:
            return None
        out.append(r[0])
        if s.startswith(sep, r[1]):
            i = r[1] + len(sep)
        else:
            return tuple(out), r[1]


def _ratio(p: Fraction, d: int) -> Fraction:
    """Lean's rational division (``x / 0 = 0``)."""
    return Fraction(0) if d == 0 else p / d


# ## LaTeX


def latex_sym(s: str) -> str:
    """``Esm.Units.latexSym``: ``_`` and ``%`` escaped with a backslash."""
    return s.replace("_", "\\_").replace("%", "\\%")


def latex_exp(q: Fraction) -> str:
    """``Esm.Units.latexExp``: a positive exponent as a braced superscript."""
    if q == 1:
        return ""
    out = "^{" + digs(abs(q.numerator))
    if q.denominator != 1:
        out += "/" + digs(q.denominator)
    return out + "}"


def latex_factor(f: tuple) -> str:
    """``Esm.Units.latexFactor``: one factor, with the absolute value of its
    exponent."""
    return latex_sym(f[0]) + latex_exp(abs(f[1]))


LATEX_SEP = "\\,"
MATHRM_OPEN = "\\mathrm{"


def latex_body(l: tuple) -> str:
    """``Esm.Units.latexBody``: the body of ``\\mathrm{…}``."""
    nf = num_factors(l)
    out = join_with(latex_factor, LATEX_SEP, nf) if nf else "1"
    df = den_factors(l)
    if len(df) == 1:
        out += "/" + latex_factor(df[0])
    elif df:
        out += "/(" + join_with(latex_factor, LATEX_SEP, df) + ")"
    return out


def latex(l: tuple) -> str:
    """``Esm.Units.latex``."""
    return MATHRM_OPEN + latex_body(l) + "}"


def _p_l_sym(s: str, i: int):
    out = []
    n = len(s)
    while i < n:
        c = s[i]
        if _is_ident(c) or c == "%":
            out.append(c)
            i += 1
        elif c == "\\" and i + 1 < n and s[i + 1] in "_%":
            out.append(s[i + 1])
            i += 2
        else:
            break
    return "".join(out), i


def _p_l_exp(s: str, i: int):
    if s.startswith("^{", i):
        r = _p_digits(s, i + 2)
        if r is None:
            return None
        p, j = r
        if s.startswith("}", j):
            return Fraction(p), j + 1
        if s.startswith("/", j):
            r2 = _p_digits(s, j + 1)
            if r2 is not None and s.startswith("}", r2[1]):
                return _ratio(Fraction(p), r2[0]), r2[1] + 1
        return None
    return ONE, i


def _p_l_factor(s: str, i: int):
    sym, j = _p_l_sym(s, i)
    if not sym:
        return None
    r = _p_l_exp(s, j)
    if r is None:
        return None
    return (sym, r[0]), r[1]


def _p_l_den(s: str, i: int):
    if s.startswith("(", i):
        r = p_sep_by(_p_l_factor, LATEX_SEP, s, i + 1)
        if r is not None and r[1] == len(s) - 1 and s[r[1]] == ")":
            return r[0]
        return None
    r = p_sep_by(_p_l_factor, LATEX_SEP, s, i)
    if r is not None and r[1] == len(s) and len(r[0]) == 1:
        return r[0]
    return None


@lru_cache(maxsize=4096)
def parse_latex(s: str):
    """``Esm.Units.parseLatex``: a LaTeX unit back to its two-sided factor list."""
    if not s.startswith(MATHRM_OPEN) or not s.endswith("}") or len(s) <= len(MATHRM_OPEN):
        return None
    b = s[len(MATHRM_OPEN) : -1]
    r = p_sep_by(_p_l_factor, LATEX_SEP, b, 0)
    if r is None:
        return None
    num, j = r
    if len(num) == 1 and num[0][0] == "1" and num[0][1] == 1:
        num = ()
    if j == len(b):
        return num
    if b[j] == "/":
        den = _p_l_den(b, j + 1)
        if den is None:
            return None
        return num + tuple((sym, -q) for sym, q in den)
    return None


# ## Typst

UPRIGHT_OPEN = 'upright("'
UPRIGHT_CLOSE = '")'
THIN_SEP = " thin "


def typst_exp(q: Fraction) -> str:
    """``Esm.Units.typstExp``: nothing for 1, ``^n``, ``^(-n)``, ``^(p\\/q)``,
    ``^(-p\\/q)``."""
    if q == 1:
        return ""
    n = digs(abs(q.numerator))
    if q.denominator == 1:
        return "^" + n if q > 0 else "^(-" + n + ")"
    return "^(" + ("-" if q < 0 else "") + n + "\\/" + digs(q.denominator) + ")"


def typst_factor(f: tuple) -> str:
    """``Esm.Units.typstFactor``."""
    return UPRIGHT_OPEN + f[0] + UPRIGHT_CLOSE + typst_exp(f[1])


def _p_t_paren(s: str, i: int):
    neg = s.startswith("-", i)
    r = _p_digits(s, i + 1 if neg else i)
    if r is None:
        return None
    p, j = r
    sp = Fraction(-p if neg else p)
    if s.startswith(")", j):
        return sp, j + 1
    if s.startswith("\\/", j):
        r2 = _p_digits(s, j + 2)
        if r2 is not None and s.startswith(")", r2[1]):
            return _ratio(sp, r2[0]), r2[1] + 1
    return None


def _p_t_exp(s: str, i: int):
    if s.startswith("^", i):
        if s.startswith("(", i + 1):
            return _p_t_paren(s, i + 2)
        if i + 1 >= len(s):
            return None
        r = _p_digits(s, i + 1)
        return None if r is None else (Fraction(r[0]), r[1])
    return ONE, i


def p_t_factor(s: str, i: int):
    """``Esm.Units.pTFactor``."""
    if not s.startswith(UPRIGHT_OPEN, i):
        return None
    j = i + len(UPRIGHT_OPEN)
    k = s.find('"', j)
    if k < 0:
        return None
    sym = s[j:k]
    if not s.startswith(UPRIGHT_CLOSE, k):
        return None
    r = _p_t_exp(s, k + len(UPRIGHT_CLOSE))
    if r is None:
        return None
    return (sym, r[0]), r[1]


# ## The unit strings of the document (`Math.factorsOf`, `Esm.Units.spell`)


@lru_cache(maxsize=4096)
def factors_of(unit: str) -> tuple:
    """The two-sided factor list of a units string (``Math.factorsOf``): the parse's
    factors normalized per side (``Esm.Units.norm2``), positive exponents first.
    Empty when the string does not parse (and for the dimensionless unit)."""
    from ...units import _canon_lex, _canon_side, _CanonParser, _NoCanonicalSpelling
    from ...units import normalize_unit_string

    if unit == "":
        return ()
    try:
        factors = _CanonParser(_canon_lex(normalize_unit_string(unit))).parse()
    except _NoCanonicalSpelling:
        return ()
    num = _canon_side([f for f in factors if f[1] > 0])
    den = _canon_side([f for f in factors if f[1] <= 0])
    return tuple(num) + tuple(den)


def _spell_factor(s: str, q: Fraction) -> str:
    q = abs(q)
    if q == 1:
        return s
    if q.denominator == 1:
        return f"{s}^{q.numerator}"
    return f"{s}^({q.numerator}/{q.denominator})"


def spell(l: tuple) -> str:
    """The canonical spelling of a factor list (``Esm.Units.spell``)."""
    num = [_spell_factor(s, q) for s, q in l if q > 0]
    den = [_spell_factor(s, q) for s, q in l if not q > 0]
    out = "*".join(num) if num else "1"
    if len(den) == 1:
        out += "/" + den[0]
    elif den:
        out += "/(" + "*".join(den) + ")"
    return out
