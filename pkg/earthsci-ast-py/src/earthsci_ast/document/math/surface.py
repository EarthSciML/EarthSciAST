"""Pieces the LaTeX and Typst spellings share: binary operator tokens and the
reading of numbers (a JSON spelling, or a scientific literal
``mantissa × 10^exponent`` whose tail each surface reads with its own ``sciExp``).

Port of ``formal/Esm/Document/Math/Surface.lean``.
"""

from __future__ import annotations

from typing import Any, Callable

from .. import number
from ..value import Dec, num_wf
from . import token as K

#: ``Math.isBin``: the binary operator tokens.
BIN = frozenset(
    {K.PLUS, K.EQ, K.NE, K.LT, K.GT, K.LE, K.GE, K.LAND, K.LOR, K.CDOT, K.TIMES, K.AMP, K.NL, K.INN}
)


def is_bin(t: Any) -> bool:
    return type(t) is str and t in BIN


def sci_split(n: Any) -> tuple[str, int] | None:
    """``Math.sciSplit``: the mantissa (with its sign) and exponent of a number
    printed in scientific notation."""
    if type(n) is Dec:
        neg, ds, e10 = n
        if ds and (e10 < -4 or e10 > 5):
            return ("-" if neg else "") + ds[0] + "." + (ds[1:] or "0"), e10
    return None


def neg_num(n: Any) -> bool:
    """``Math.negNum``: a number below zero."""
    if type(n) is int:
        return n < 0
    return n.neg


def sci_num(n0: Any, z: int) -> Any:
    """``Math.sciNum``: the value of a mantissa times ``10^z``, in canonical form
    (``None`` when it is not well formed)."""
    if type(n0) is Dec:
        m = number.canonize(Dec(n0.neg, n0.digits, n0.e10 + z))
    else:
        ds = str(abs(n0))
        m = number.canonize(number.mk_dec(n0 < 0, ds, len(ds) - 1 + z))
    return m if num_wf(m) else None


def lex_num(sci_exp: Callable, s: str, i: int):
    """``Math.lexNum``: a number: its JSON spelling, or a decimal mantissa
    followed by a scientific tail that ``sci_exp`` reads."""
    r = number.parse_raw(s, i)
    if r is None:
        return None
    n0, j = r
    tail = sci_exp(s, j)
    if tail is not None:
        m = sci_num(n0, tail[0])
        if m is not None:
            return ("num", m), tail[1]
    p = number.parse(s, i)
    return None if p is None else (("num", p[0]), p[1])


def lex_signed(sci_exp: Callable, s: str, i: int):
    """``Math.lexSigned``: a number where ``-`` starts it only when the value is
    below zero (otherwise the ``-`` is a minus sign of its own)."""
    if s.startswith("-", i):
        r = lex_num(sci_exp, s, i)
        if r is None:
            return None
        if neg_num(r[0][1]):
            return r
        return K.MINUS, i + 1
    return lex_num(sci_exp, s, i)
