"""The YAML subset of front matter and container bodies.

Port of ``formal/Esm/Document/Yaml.lean``. The printed text is block-style YAML 1.2:

* a non-empty object is one ``key: value`` line per entry, a non-empty array one
  ``- item`` line per element, at the current indentation;
* a scalar, ``[]`` or ``{}`` follows its ``key: `` or ``- `` on the same line;
* a non-empty container under a key starts on the next line, two spaces deeper; a
  non-empty object as an array element starts on the ``- `` line, its other
  entries aligned with its first key; a non-empty array as an element starts on
  the next line, two spaces deeper.

Strings are always double-quoted with JSON-style escapes, so a math leaf (path
blocks only) is the plain scalar ``$…$``; a key is bare when it is
an identifier and not one of YAML's special plain scalars in any letter case; a
key longer than 1024 characters uses the explicit ``? "key"`` form. The reader
accepts only this layout and well-formed values. No YAML library is involved.
"""

from __future__ import annotations

from typing import Any

from . import limits, number
from .strings import is_ident_start, parse_key, parse_quoted, print_key, quote
from .value import Dec, Math, Obj, math_leaf_at, wfm

#: ``Yaml.specialWords``.
SPECIAL_WORDS = frozenset({"true", "false", "null", "yes", "no", "on", "off", "y", "n"})


def reserved(k: str) -> bool:
    """``Yaml.reserved``: a key equal (in any ASCII letter case) to a special plain
    scalar."""
    return len(k) <= 5 and k.lower() in SPECIAL_WORDS and k.isascii()


def _key_part(m: int, k: str, out: list[str]) -> None:
    """``Yaml.keyPart``."""
    p = print_key(False, reserved, k)
    if len(p) > 1024:
        out.append("? " + quote(False, k) + "\n" + " " * m)
    else:
        out.append(p)


def inline(v: Any) -> str:
    """``Yaml.inline``: the one-line spelling of a scalar or an empty container."""
    t = type(v)
    if v is None:
        return "null"
    if v is True:
        return "true"
    if v is False:
        return "false"
    if t is int or t is Dec:
        return number.print_num(v)
    if t is str:
        return quote(False, v)
    if t is Math:
        return "$" + v.text + "$"
    if t is Obj:
        return "{}"
    return "[]"


def _enc_items(m: int, vs: list, out: list[str]) -> None:
    for v in vs:
        out.append(" " * m + "-")
        _item_body(m, v, out)


def _item_body(m: int, v: Any, out: list[str]) -> None:
    t = type(v)
    if t is list and v:
        out.append("\n")
        _enc_items(m + 2, v, out)
    elif t is Obj and v:
        k, x = v[0]
        out.append(" ")
        _key_part(m + 2, k, out)
        out.append(":")
        _val_body(m + 2, x, out)
        _enc_entries(m + 2, v[1:], out)
    else:
        out.append(" " + inline(v) + "\n")


def _enc_entries(m: int, es: list, out: list[str]) -> None:
    for k, v in es:
        out.append(" " * m)
        _key_part(m, k, out)
        out.append(":")
        _val_body(m, v, out)


def _val_body(m: int, v: Any, out: list[str]) -> None:
    t = type(v)
    if t is list and v:
        out.append("\n")
        _enc_items(m + 2, v, out)
    elif t is Obj and v:
        out.append("\n")
        _enc_entries(m + 2, v, out)
    else:
        out.append(" " + inline(v) + "\n")


def encode(v: Any) -> str:
    """``Yaml.encode``: the canonical YAML spelling of a value."""
    out: list[str] = []
    t = type(v)
    if t is list and v:
        _enc_items(0, v, out)
    elif t is Obj and v:
        _enc_entries(0, v, out)
    else:
        out.append(inline(v) + "\n")
    return "".join(out)


# ## Reader


def _drop_sp(n: int, s: str, i: int) -> int | None:
    """``Yaml.dropSp``: exactly ``n`` leading spaces."""
    if s.startswith(" " * n, i):
        return i + n
    return None


def _parse_key_at(m: int, s: str, i: int):
    """``Yaml.parseKeyAt``."""
    if i >= len(s):
        return None
    if s[i] == "?":
        if not s.startswith(" ", i + 1):
            return None
        r = parse_quoted(False, s, i + 2)
        if r is None or not s.startswith("\n", r[1]):
            return None
        j = _drop_sp(m, s, r[1] + 1)
        return None if j is None else (r[0], j)
    return parse_key(False, reserved, s, i)


def p_inline(s: str, i: int):
    """``Yaml.pInline``: a scalar or an empty container."""
    if i >= len(s):
        return None
    c = s[i]
    if c == "n":
        return (None, i + 4) if s.startswith("null", i) else None
    if c == "t":
        return (True, i + 4) if s.startswith("true", i) else None
    if c == "f":
        return (False, i + 5) if s.startswith("false", i) else None
    if c == "[":
        return ([], i + 2) if s.startswith("[]", i) else None
    if c == "{":
        return (Obj(), i + 2) if s.startswith("{}", i) else None
    if c == '"':
        return parse_quoted(False, s, i)
    if c == "$":
        return math_leaf_at(s, i)
    return number.parse(s, i)


def _p_scalar_line(s: str, i: int):
    r = p_inline(s, i)
    if r is not None and s.startswith("\n", r[1]):
        return r[0], r[1] + 1
    return None


def _is_item_line(m: int, s: str, i: int) -> bool:
    j = _drop_sp(m, s, i)
    return j is not None and s.startswith("-", j)


def _is_entry_line(m: int, s: str, i: int) -> bool:
    j = _drop_sp(m, s, i)
    if j is None or j >= len(s):
        return False
    c = s[j]
    return c == '"' or c == "?" or is_ident_start(c)


def _p_items(m: int, s: str, i: int):
    out = []
    while _is_item_line(m, s, i):
        r = _p_item_body(m, s, i + m + 1)
        if r is None:
            return None
        out.append(r[0])
        i = r[1]
    return out, i


def _p_item_body(m: int, s: str, i: int):
    if not limits.enter():
        return None
    try:
        if i >= len(s):
            return None
        c = s[i]
        if c == "\n":
            r = _p_items(m + 2, s, i + 1)
            return None if r is None else (r[0], r[1])
        if c == " ":
            e = _p_entry(m + 2, s, i + 1)
            if e is not None:
                r = _p_entries(m + 2, s, e[1])
                if r is None:
                    return None
                return Obj([e[0], *r[0]]), r[1]
            return _p_scalar_line(s, i + 1)
        return None
    finally:
        limits.leave()


def _p_entries(m: int, s: str, i: int):
    out = []
    while _is_entry_line(m, s, i):
        r = _p_entry(m, s, i + m)
        if r is None:
            return None
        out.append(r[0])
        i = r[1]
    return out, i


def _p_entry(m: int, s: str, i: int):
    k = _parse_key_at(m, s, i)
    if k is None or not s.startswith(":", k[1]):
        return None
    r = _p_val_body(m, s, k[1] + 1)
    return None if r is None else ((k[0], r[0]), r[1])


def _p_val_body(m: int, s: str, i: int):
    if not limits.enter():
        return None
    try:
        if i >= len(s):
            return None
        c = s[i]
        if c == " ":
            return _p_scalar_line(s, i + 1)
        if c == "\n":
            if _is_item_line(m + 2, s, i + 1):
                return _p_items(m + 2, s, i + 1)
            r = _p_entries(m + 2, s, i + 1)
            return None if r is None else (Obj(r[0]), r[1])
        return None
    finally:
        limits.leave()


def _top_is_array(s: str) -> bool:
    return _is_item_line(0, s, 0) and len(s) > 1 and s[1] in " \n"


def decode(s: str):
    """``Yaml.decode``: all of the input consumed, and the value well formed.
    Returns ``(value,)`` or ``None`` (a one-tuple, since ``null`` is a value)."""
    if _top_is_array(s):
        r = _p_items(0, s, 0)
    else:
        e = _p_entry(0, s, 0)
        if e is not None:
            r2 = _p_entries(0, s, e[1])
            r = None if r2 is None else (Obj([e[0], *r2[0]]), r2[1])
        else:
            r = _p_scalar_line(s, 0)
    if r is None or r[1] != len(s) or not wfm(r[0]):
        return None
    return (r[0],)
