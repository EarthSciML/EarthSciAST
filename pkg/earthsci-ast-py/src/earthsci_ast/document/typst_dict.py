"""The Typst value codec: a JSON value as a Typst code-mode value.

Port of ``formal/Esm/Document/TypstDict.lean``.

* ``none``, ``true``, ``false``; numbers in the canonical spelling, except
  ``-2^63``, printed ``(-9223372036854775807 - 1)`` because Typst reads the literal
  ``-9223372036854775808`` as a float;
* strings with Typst escapes (``\\u{XXXX}``);
* arrays ``(a, b)``, ``()`` empty; dictionaries ``(key: v, "quoted key": v)``,
  ``(:)`` empty. A key is bare when it is an identifier and not a Typst keyword;
* a math leaf ``$…$``, Typst math content (path blocks only).

The canonical layout is one element per line, each indented two spaces deeper than
the opening line and followed by ``,``. The reader skips whitespace between
tokens, accepts a trailing comma or none, and rejects a one-element array without
its comma (Typst reads ``(x)`` as ``x``).
"""

from __future__ import annotations

from typing import Any

from . import limits, number
from .strings import parse_key, parse_quoted, print_key, quote
from .value import INT64_MIN, Dec, Math, Obj, math_leaf_at, wfm

#: ``TypstDict.keywords``: Typst keywords, which cannot be bare dictionary keys.
KEYWORDS = frozenset(
    {
        "none", "auto", "true", "false", "not", "and", "or", "let", "set", "show", "if",
        "else", "for", "in", "while", "break", "continue", "return", "import", "include",
        "context", "as", "_",
    }
)  # fmt: skip

_MIN_LIT = "-9223372036854775807"


def reserved(k: str) -> bool:
    """``TypstDict.reserved``."""
    return k in KEYWORDS


def print_num(n: Any) -> str:
    """``TypstDict.printNum``."""
    if type(n) is int and n == INT64_MIN:
        return "(-9223372036854775807 - 1)"
    return number.print_num(n)


def _enc(m: int, v: Any, out: list[str]) -> None:
    t = type(v)
    if v is None:
        out.append("none")
    elif v is True:
        out.append("true")
    elif v is False:
        out.append("false")
    elif t is int or t is Dec:
        out.append(print_num(v))
    elif t is str:
        out.append(quote(True, v))
    elif t is Math:
        out.append("$" + v.text + "$")
    elif t is Obj:
        if not v:
            out.append("(:)")
            return
        out.append("(\n")
        pad = " " * (m + 2)
        for k, x in v:
            out.append(pad + print_key(True, reserved, k) + ": ")
            _enc(m + 2, x, out)
            out.append(",\n")
        out.append(" " * m + ")")
    else:
        if not v:
            out.append("()")
            return
        out.append("(\n")
        pad = " " * (m + 2)
        for x in v:
            out.append(pad)
            _enc(m + 2, x, out)
            out.append(",\n")
        out.append(" " * m + ")")


def encode(v: Any) -> str:
    """``TypstDict.encode``: the canonical Typst spelling of a value."""
    out: list[str] = []
    _enc(0, v, out)
    return "".join(out)


def skip_ws(s: str, i: int) -> int:
    """``TypstDict.skipWs``."""
    n = len(s)
    while i < n and s[i] in " \n\t\r":
        i += 1
    return i


def _is_entry(s: str, i: int) -> bool:
    r = parse_key(True, reserved, s, i)
    if r is None:
        return False
    return s.startswith(":", skip_ws(s, r[1]))


_MORE, _CLOSE_COMMA, _CLOSE = 0, 1, 2


def _p_next(s: str, i: int):
    j = skip_ws(s, i)
    if s.startswith(",", j):
        k = skip_ws(s, j + 1)
        if s.startswith(")", k):
            return _CLOSE_COMMA, k + 1
        return _MORE, k
    if s.startswith(")", j):
        return _CLOSE, j + 1
    return None


def _p_min(s: str, i: int) -> int | None:
    if not s.startswith(_MIN_LIT, i):
        return None
    j = skip_ws(s, i + len(_MIN_LIT))
    if not s.startswith("-", j):
        return None
    j = skip_ws(s, j + 1)
    if not s.startswith("1", j):
        return None
    j = skip_ws(s, j + 1)
    if not s.startswith(")", j):
        return None
    return j + 1


def p_val(s: str, i: int):
    """``TypstDict.pVal``: a value, at its first character; ``(value, position)``."""
    if not limits.enter():
        return None
    try:
        if i >= len(s):
            return None
        c = s[i]
        if c == "(":
            j = skip_ws(s, i + 1)
            k = _p_min(s, j)
            if k is not None:
                return INT64_MIN, k
            return _p_paren(s, j)
        if c == '"':
            return parse_quoted(True, s, i)
        if c == "$":
            return math_leaf_at(s, i)
        if c == "n":
            return (None, i + 4) if s.startswith("none", i) else None
        if c == "t":
            return (True, i + 4) if s.startswith("true", i) else None
        if c == "f":
            return (False, i + 5) if s.startswith("false", i) else None
        return number.parse(s, i)
    finally:
        limits.leave()


def _p_paren(s: str, i: int):
    if i >= len(s):
        return None
    c = s[i]
    if c == ")":
        return [], i + 1
    if c == ":":
        j = skip_ws(s, i + 1)
        return (Obj(), j + 1) if s.startswith(")", j) else None
    if _is_entry(s, i):
        return _p_entries(s, i)
    return _p_items(s, i)


def _p_items(s: str, i: int):
    out = []
    first = True
    while True:
        r = p_val(s, i)
        if r is None:
            return None
        out.append(r[0])
        nx = _p_next(s, r[1])
        if nx is None:
            return None
        if nx[0] == _MORE:
            i = nx[1]
            first = False
            continue
        if first and nx[0] == _CLOSE:
            return None
        return out, nx[1]


def _p_entries(s: str, i: int):
    out = []
    while True:
        k = parse_key(True, reserved, s, i)
        if k is None:
            return None
        j = skip_ws(s, k[1])
        if not s.startswith(":", j):
            return None
        r = p_val(s, skip_ws(s, j + 1))
        if r is None:
            return None
        out.append((k[0], r[0]))
        nx = _p_next(s, r[1])
        if nx is None:
            return None
        if nx[0] == _MORE:
            i = nx[1]
            continue
        return Obj(out), nx[1]


def decode(s: str):
    """``TypstDict.decode``: whitespace, the value, whitespace, end of input; the
    value well formed (math leaves allowed). ``(value,)`` or ``None``."""
    r = p_val(s, skip_ws(s, 0))
    if r is None or skip_ws(s, r[1]) != len(s) or not wfm(r[0]):
        return None
    return (r[0],)
