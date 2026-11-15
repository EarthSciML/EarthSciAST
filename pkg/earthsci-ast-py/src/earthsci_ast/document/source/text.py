"""Text scanning shared by the containers: input decoding, prefixes, lines, and
fenced bodies ended by a closing line.

Port of ``formal/Esm/Document/Source/Lines.lean`` and ``Text.lean``. The scanners
take a string and a position.
"""

from __future__ import annotations


def decode_text(s: str) -> str:
    """``Source.decodeText``: no byte-order mark, and LF line endings when the
    first line ends in CRLF."""
    if s.startswith("\ufeff"):
        s = s[1:]
    nl = s.find("\n")
    # `firstCRLF`: a CR right before the first LF
    if nl > 0 and s[nl - 1] == "\r":
        return s.replace("\r\n", "\n")
    return s


def split_line(s: str, i: int) -> tuple[int, int]:
    """``Source.splitLine``: the end of the first line at ``i`` (its newline
    excluded) and the start of the text after it."""
    j = s.find("\n", i)
    if j < 0:
        return len(s), len(s)
    return j, j + 1


def blank(l: str) -> bool:
    """``l.all (· == ' ')``."""
    return l.strip(" ") == ""


def no_stop(stop: str, s: str) -> bool:
    """``Source.noStop``: no line of ``s`` starts with ``stop``."""
    i = 0
    n = len(s)
    while i < n:
        if s.startswith(stop, i):
            return False
        i = split_line(s, i)[1]
    return True


def until_stop(stop: str, s: str, i: int):
    """``Source.untilStop``: lines up to the first one that starts with ``stop``:
    the lines before it (each with its newline), the rest of the closing line, and
    the position after the closing line."""
    start = i
    n = len(s)
    while True:
        if i >= n:
            return None
        if s.startswith(stop, i):
            a, b = split_line(s, i + len(stop))
            return s[start:i], s[i + len(stop) : a], b
        i = split_line(s, i)[1]


def has_sub(p: str, s: str) -> bool:
    """``Source.hasSub``: ``p`` occurs in ``s``."""
    return p in s


def take_while(s: str, i: int, p) -> int:
    """The end of the run at ``i`` whose characters satisfy ``p``."""
    n = len(s)
    while i < n and p(s[i]):
        i += 1
    return i
