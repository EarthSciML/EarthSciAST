"""JSON values of an ESM document, in canonical form.

Port of ``formal/Esm/Document/Json.lean`` (and of the Rust binding's
``document/json.rs``). The document codecs and the math layer work on this value
representation, not on the plain ``dict``/``list``/``float`` values the rest of the
package uses:

* ``None``, ``True``/``False``, ``str`` as usual;
* an integer is a Python ``int`` (well formed when it fits in Int64);
* every other number is a :class:`Dec`: the value ``±d1.d2d3… × 10^e10`` with its
  shortest round-trip digits (CONFORMANCE §5.5.3.1);
* an array is a ``list``;
* an object is an :class:`Obj`, a ``list`` of ``(key, value)`` pairs that keeps
  its entry order and its duplicate keys (so a reader can refuse them, as Lean's
  ``Json.WF`` does);
* a :class:`Math` is the math text of an expression inside a path block
  (``Json.math``). It exists only between a container's printer or reader and the
  skeleton: a document never holds one (:func:`wf` is false on it).

Every type test is exact (``type(v) is list``): ``bool`` is a subclass of ``int``
and :class:`Obj` one of ``list``. :func:`from_plain` and :func:`to_plain` convert at
the public boundary.
"""

from __future__ import annotations

from decimal import Decimal
from typing import Any, NamedTuple

INT64_MIN = -(2**63)
INT64_MAX = 2**63 - 1


class Dec(NamedTuple):
    """A decimal ``±d1.d2… × 10^e10`` (``JNum.dec``); ``digits`` is a string of
    decimal digit characters."""

    neg: bool
    digits: str
    e10: int


class Obj(list):
    """A JSON object: its ``(key, value)`` entries, in order.

    Equal only to another :class:`Obj` with the same entries in the same order (the
    derived equality of Lean's ``Json``), never to a plain list.
    """

    __slots__ = ()

    def __eq__(self, other: object) -> bool:
        return type(other) is Obj and list.__eq__(self, other)

    def __ne__(self, other: object) -> bool:
        return not self.__eq__(other)

    __hash__ = None


class Math(NamedTuple):
    """``Json.math``: an expression's math text, as a path block holds it
    (``$…$`` in both containers)."""

    text: str


def math_ok(s: str) -> bool:
    """``Json.mathOK``: math text a container can delimit with ``$``: not empty,
    no ``$``, no line break, and not ending in a backslash (which would escape the
    closing ``$``)."""
    return s != "" and "$" not in s and "\n" not in s and "\r" not in s and not s.endswith("\\")


def math_leaf_at(s: str, i: int):
    """``Json.pMath``: a math leaf ``$…$`` at ``s[i] == "$"``: the text up to the
    next ``$``, which must be :func:`math_ok`. ``(Math, position)`` or ``None``."""
    j = s.find("$", i + 1)
    if j < 0:
        return None
    t = s[i + 1 : j]
    return (Math(t), j + 1) if math_ok(t) else None


def is_int(v: Any) -> bool:
    return type(v) is int


def is_num(v: Any) -> bool:
    return type(v) is int or type(v) is Dec


def is_str(v: Any) -> bool:
    return type(v) is str


def is_arr(v: Any) -> bool:
    return type(v) is list


def is_obj(v: Any) -> bool:
    return type(v) is Obj


def in_int64(z: int) -> bool:
    """``JNum.InInt64``."""
    return INT64_MIN <= z <= INT64_MAX


def dec_int64(neg: bool, ds: str, e10: int) -> int | None:
    """The integer a decimal denotes, when it is integral and in Int64
    (``JNum.decInt?`` followed by the Int64 check). A decimal whose first digit
    sits at exponent 19 or above is at least ``10^19``, outside Int64."""
    n = len(ds)
    if n > e10 + 1 or e10 > 18:
        return None
    m = int(ds) * 10 ** (e10 + 1 - n)
    if neg:
        m = -m
    return m if in_int64(m) else None


def num_wf(n: Any) -> bool:
    """``JNum.wfb`` / ``Math.numOK``: the number is in canonical form."""
    if type(n) is int:
        return in_int64(n)
    neg, ds, e10 = n
    return (
        ds != ""
        and ds[0] != "0"
        and ds[-1] != "0"
        and all("0" <= c <= "9" for c in ds)
        and dec_int64(neg, ds, e10) is None
    )


def keys_distinct(kvs: list) -> bool:
    seen = set()
    for k, _ in kvs:
        if k in seen:
            return False
        seen.add(k)
    return True


def wf(j: Any) -> bool:
    """``Json.wfb`` / ``Math.jwf``: every number canonical, every object with
    distinct keys, and no math leaf."""
    t = type(j)
    if t is int or t is Dec:
        return num_wf(j)
    if t is list:
        return all(wf(x) for x in j)
    if t is Obj:
        return keys_distinct(j) and all(wf(v) for _, v in j)
    return t is not Math


def wfm(j: Any) -> bool:
    """``Json.wfmb``: :func:`wf`, with math leaves of :func:`math_ok` text allowed
    (what the codecs print and read)."""
    t = type(j)
    if t is int or t is Dec:
        return num_wf(j)
    if t is list:
        return all(wfm(x) for x in j)
    if t is Obj:
        return keys_distinct(j) and all(wfm(v) for _, v in j)
    if t is Math:
        return math_ok(j.text)
    return True


class _Missing:
    __slots__ = ()

    def __repr__(self) -> str:
        return "MISSING"


#: What :func:`look` returns for an absent key (``null`` is a value).
MISSING: Any = _Missing()


def look(k: str, kvs: list) -> Any:
    """``Math.look``: the value of the first entry with key ``k``, or
    :data:`MISSING`."""
    for k2, v in kvs:
        if k2 == k:
            return v
    return MISSING


def sort_obj(j: Any) -> Any:
    """Every object's entries sorted by key (code point order), at every depth."""
    t = type(j)
    if t is list:
        return [sort_obj(x) for x in j]
    if t is Obj:
        return Obj(sorted(((k, sort_obj(v)) for k, v in j), key=lambda kv: kv[0]))
    return j


def dec_of_float(f: float) -> Any:
    """The canonical number of a finite float (§5.5.3.1): an integral value in
    Int64 is the integer, any other its shortest round-trip digits."""
    if f == 0.0:
        return 0
    if f.is_integer() and -(2.0**63) <= f < 2.0**63:
        return int(f)
    _, digs, exp = Decimal(repr(abs(f))).as_tuple()
    ds = "".join(str(d) for d in digs).lstrip("0")
    stripped = ds.rstrip("0")
    e = int(exp) + len(ds) - len(stripped)
    return Dec(f < 0, stripped, e + len(stripped) - 1)


def from_plain(v: Any) -> Any:
    """A decoded JSON value (``dict``/``list``/``int``/``float``/…) as a document
    value. A non-finite float, which JSON cannot hold, becomes ``null``."""
    t = type(v)
    if t is dict:
        return Obj((k, from_plain(x)) for k, x in v.items())
    if t is list:
        return [from_plain(x) for x in v]
    if t is bool or v is None or t is str:
        return v
    if t is int:
        if in_int64(v):
            return v
        return dec_of_float(float(v))
    if t is float:
        if v != v or v in (float("inf"), float("-inf")):
            return None
        return dec_of_float(v)
    if isinstance(v, dict):
        return Obj((k, from_plain(x)) for k, x in v.items())
    if isinstance(v, (list, tuple)):
        return [from_plain(x) for x in v]
    if isinstance(v, bool):
        return bool(v)
    if isinstance(v, int):
        return from_plain(int(v))
    if isinstance(v, float):
        return from_plain(float(v))
    if isinstance(v, str):
        return str(v)
    raise TypeError(f"not a JSON value: {v!r}")


def to_plain(j: Any) -> Any:
    """A document value as plain decoded JSON: a :class:`Dec` is the float its
    canonical spelling reads as (a float even when integral outside Int64). A
    nonzero decimal below the smallest subnormal (``1.0e-400``) reads as zero, as
    every binding's JSON reader rounds it, and is the canonical zero, the integer
    ``0``, as ``canonicalize_document`` makes a JSON ``1e-400``. A decimal beyond
    the binary64 range has no value here; the document readers refuse it first
    (:func:`.limits.out_of_range`)."""
    from .number import print_num

    t = type(j)
    if t is Obj:
        return {k: to_plain(v) for k, v in j}
    if t is list:
        return [to_plain(x) for x in j]
    if t is Dec:
        f = float(print_num(j))
        return 0 if f == 0.0 else f
    if t is int and not in_int64(j):
        return float(j)
    return j
