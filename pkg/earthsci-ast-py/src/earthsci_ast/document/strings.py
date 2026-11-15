"""Lexical pieces shared by the YAML and Typst codecs.

Port of ``formal/Esm/Document/Strings.lean``: double-quoted strings with
JSON-style escapes (YAML writes the hex escape ``\\uXXXX``, Typst ``\\u{XXXX}``;
``braces`` selects the Typst spelling), bare identifier keys, and the characters a
number or a key never starts with.
"""

from __future__ import annotations

from typing import Callable

_HEX = "0123456789abcdef"


def hex4(n: int) -> str:
    """``Strings.hex4``."""
    return _HEX[n // 4096 % 16] + _HEX[n // 256 % 16] + _HEX[n // 16 % 16] + _HEX[n % 16]


def hex_val(c: str) -> int | None:
    """``Strings.hexVal``: the value of a hex digit (either case)."""
    if "0" <= c <= "9":
        return ord(c) - 48
    if "a" <= c <= "f":
        return ord(c) - 87
    if "A" <= c <= "F":
        return ord(c) - 55
    return None


def needs_hex(c: str) -> bool:
    """``Strings.needsHex``: characters written as a hex escape."""
    n = ord(c)
    return (
        n < 0x20
        or n == 0x7F
        or 0x80 <= n <= 0x9F
        or n in (0x2028, 0x2029, 0xFEFF, 0xFFFE, 0xFFFF)
    )


_SIMPLE_ESC = {'"': '\\"', "\\": "\\\\", "\n": "\\n", "\t": "\\t", "\r": "\\r"}


def esc_char(braces: bool, c: str) -> str:
    """``Strings.escChar``."""
    e = _SIMPLE_ESC.get(c)
    if e is not None:
        return e
    if needs_hex(c):
        return "\\u{" + hex4(ord(c)) + "}" if braces else "\\u" + hex4(ord(c))
    return c


def escape(braces: bool, s: str) -> str:
    """``Strings.escape``: the escaped characters of a string, without the quotes."""
    return "".join(esc_char(braces, c) for c in s)


def quote(braces: bool, s: str) -> str:
    """``Strings.quote``: a double-quoted string literal."""
    return '"' + escape(braces, s) + '"'


def char_of(n: int) -> str:
    """Lean's ``Char.ofNat``: a surrogate (or out-of-range) code point is ``\\0``."""
    if n > 0x10FFFF or 0xD800 <= n <= 0xDFFF:
        return "\0"
    return chr(n)


def _hex4_at(s: str, i: int) -> int | None:
    if i + 4 > len(s):
        return None
    v = 0
    for c in s[i : i + 4]:
        d = hex_val(c)
        if d is None:
            return None
        v = v * 16 + d
    return v


def unquote_body(braces: bool, s: str, i: int) -> tuple[str, int] | None:
    """``Strings.unquoteBody``: the characters up to the closing quote, and the
    position after it."""
    out: list[str] = []
    n = len(s)
    while True:
        if i >= n:
            return None
        c = s[i]
        if c == '"':
            return "".join(out), i + 1
        if c != "\\":
            out.append(c)
            i += 1
            continue
        if i + 1 >= n:
            return None
        d = s[i + 1]
        if d == '"':
            out.append('"')
        elif d == "\\":
            out.append("\\")
        elif d == "n":
            out.append("\n")
        elif d == "t":
            out.append("\t")
        elif d == "r":
            out.append("\r")
        elif d == "u":
            if i + 7 < n and s[i + 2] == "{" and s[i + 7] == "}":
                # `\u{XXXX}`: the Typst spelling only
                if not braces:
                    return None
                v = _hex4_at(s, i + 3)
                if v is None:
                    return None
                out.append(char_of(v))
                i += 8
                continue
            if braces:
                return None
            v = _hex4_at(s, i + 2)
            if v is None:
                return None
            out.append(char_of(v))
            i += 6
            continue
        else:
            return None
        i += 2


def parse_quoted(braces: bool, s: str, i: int) -> tuple[str, int] | None:
    """``Strings.parseQuoted``."""
    if i < len(s) and s[i] == '"':
        return unquote_body(braces, s, i + 1)
    return None


def is_ident_start(c: str) -> bool:
    """``Strings.isIdentStart`` (ASCII letters, as Lean's ``Char.isAlpha``)."""
    return ("a" <= c <= "z") or ("A" <= c <= "Z") or c == "_"


def is_ident_char(c: str) -> bool:
    """``Strings.isIdentChar``."""
    return ("a" <= c <= "z") or ("A" <= c <= "Z") or ("0" <= c <= "9") or c == "_"


def is_ident(s: str) -> bool:
    """``Strings.isIdent``: ``[A-Za-z_][A-Za-z0-9_]*``."""
    return s != "" and is_ident_start(s[0]) and all(is_ident_char(c) for c in s[1:])


def read_ident(s: str, i: int) -> int:
    """``Strings.readIdent``: the end of the maximal run of identifier characters
    at ``i``."""
    n = len(s)
    while i < n and is_ident_char(s[i]):
        i += 1
    return i


def bare_key(reserved: Callable[[str], bool], k: str) -> bool:
    """``Strings.bareKey``: a key prints bare when it is an identifier and not one
    of the codec's reserved words."""
    return is_ident(k) and not reserved(k)


def print_key(braces: bool, reserved: Callable[[str], bool], k: str) -> str:
    """``Strings.printKey``."""
    return k if bare_key(reserved, k) else quote(braces, k)


def parse_key(braces: bool, reserved: Callable[[str], bool], s: str, i: int):
    """``Strings.parseKey``: quoted, or an identifier that is not a reserved word."""
    if i >= len(s):
        return None
    c = s[i]
    if c == '"':
        return parse_quoted(braces, s, i)
    if is_ident_start(c):
        j = read_ident(s, i)
        k = s[i:j]
        return None if reserved(k) else (k, j)
    return None
