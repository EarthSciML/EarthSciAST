"""The canonical number spelling (CONFORMANCE §5.5.3.1).

Port of ``formal/Esm/Document/Number.lean``.

* An integer prints plainly, ``-`` for a negative one.
* A decimal prints its digits positionally when its decimal exponent is in
  ``[-4, 5]``, and otherwise as ``d.f…e<exp>`` with at least one fraction digit.

:func:`parse` reads any decimal spelling and returns the canonical number;
:func:`parse_raw` reads the token as written. The readers take a string and a
position and return ``(value, position after)`` or ``None``.
"""

from __future__ import annotations

from typing import Any

from .value import Dec, dec_int64, num_wf


def _digit_run(s: str, i: int) -> int:
    n = len(s)
    j = i
    while j < n and "0" <= s[j] <= "9":
        j += 1
    return j


def _int_of(run: str) -> int | None:
    try:
        return int(run)
    except ValueError:  # beyond the interpreter's digit limit: no canonical form
        return None


def parse_nat(s: str, i: int) -> tuple[int, int] | None:
    """``Number.parseNat``."""
    j = _digit_run(s, i)
    if j == i:
        return None
    v = _int_of(s[i:j])
    return None if v is None else (v, j)


def parse_int(s: str, i: int) -> tuple[int, int] | None:
    """``Number.parseInt``: an optional ``-``, then digits."""
    if i < len(s) and s[i] == "-":
        r = parse_nat(s, i + 1)
        return None if r is None else (-r[0], r[1])
    return parse_nat(s, i)


def dec_body(ds: str, e10: int) -> str:
    """``Number.decBody``: the unsigned spelling of ``d1.d2… × 10^e10``."""
    if not -4 <= e10 <= 5:
        if not ds:
            return ""
        return f"{ds[0]}.{ds[1:] or '0'}e{e10}"
    if e10 < 0:
        return "0." + "0" * (-e10 - 1) + ds
    k = e10 + 1
    head = ds[:k] + "0" * max(0, k - len(ds))
    return f"{head}.{ds[k:] or '0'}"


def print_num(n: Any) -> str:
    """``Number.print``: the canonical spelling of a number."""
    if type(n) is int:
        return str(n)
    neg, ds, e10 = n
    return ("-" if neg else "") + dec_body(ds, e10)


def mk_dec(neg: bool, ds: str, e10: int) -> Dec:
    """``Number.mkDec``: the decimal with digits ``ds`` (leading and trailing zeros
    dropped) whose first listed digit sits at decimal exponent ``e10``."""
    core = ds.lstrip("0")
    lead = len(ds) - len(core)
    return Dec(neg, core.rstrip("0"), e10 - lead)


def finish_dec(neg: bool, ds: str, e10: int, s: str, i: int) -> tuple[Any, int] | None:
    """``Number.finishDec``: an optional ``e`` exponent after the fraction digits."""
    if i < len(s) and s[i] == "e":
        r = parse_int(s, i + 1)
        if r is None:
            return None
        return mk_dec(neg, ds, e10 + r[0]), r[1]
    return mk_dec(neg, ds, e10), i


def after_int(neg: bool, ip: str, s: str, i: int) -> tuple[Any, int] | None:
    """``Number.afterInt``."""
    if i < len(s) and s[i] == ".":
        j = _digit_run(s, i + 1)
        if j == i + 1:
            return None
        return finish_dec(neg, ip + s[i + 1 : j], len(ip) - 1, s, j)
    v = _int_of(ip)
    if v is None:
        return None
    return (-v if neg else v), i


def parse_raw(s: str, i: int) -> tuple[Any, int] | None:
    """``Number.parseRaw``: a number token as written, not yet canonical."""
    neg = i < len(s) and s[i] == "-"
    k = i + 1 if neg else i
    j = _digit_run(s, k)
    if j == k or (j - k > 1 and s[k] == "0"):
        return None
    return after_int(neg, s[k:j], s, j)


def canonize(n: Any) -> Any:
    """``Number.canonize``."""
    if type(n) is Dec:
        neg, ds, e10 = n
        if not ds:
            return 0
        z = dec_int64(neg, ds, e10)
        if z is not None:
            return z
    return n


def parse(s: str, i: int) -> tuple[Any, int] | None:
    """``Number.parse``: a number token, in canonical form."""
    r = parse_raw(s, i)
    if r is None:
        return None
    c = canonize(r[0])
    return (c, r[1]) if num_wf(c) else None
