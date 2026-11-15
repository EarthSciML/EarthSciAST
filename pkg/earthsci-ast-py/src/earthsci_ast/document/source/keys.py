"""Objects in canonical form: sorting entries, and splitting an object between
surfaces.

Port of ``formal/Esm/Document/Source/Keys.lean``. An absent optional value is
:data:`~earthsci_ast.document.value.MISSING` (``null`` is a value); a refusal is
:data:`FAIL`.
"""

from __future__ import annotations

from typing import Any, Callable

from ..value import MISSING, Obj


class _Fail:
    __slots__ = ()

    def __repr__(self) -> str:
        return "FAIL"


#: What a function that may refuse returns when it does (Lean's outer ``none``).
FAIL: Any = _Fail()


def sort_keys(l: list) -> list:
    """``Source.sortKeys``: the entries ordered by key (a stable sort)."""
    return sorted(l, key=lambda kv: kv[0])


def at_(k: str, l: list) -> list:
    """``Source.at_``: the entries of ``l`` with key ``k``."""
    return [kv for kv in l if kv[0] == k]


def split_field(pick: Callable, v: Any) -> tuple[list, Any]:
    """``Source.splitField``: the entries of an object-valued field that ``pick``
    takes, and the residue (``MISSING`` when every entry was taken and there was
    at least one)."""
    if type(v) is Obj:
        ps = []
        rs = []
        for k, x in v:
            p = pick(k, x)
            if p is not None:
                ps.append(p)
            else:
                rs.append((k, x))
        return ps, (MISSING if ps and not rs else Obj(rs))
    return [], v


def split_opt(pick: Callable, v: Any) -> tuple[list, Any]:
    """``Source.splitOpt``: ``splitField`` of a field that may be absent."""
    if v is MISSING:
        return [], MISSING
    return split_field(pick, v)


def join_field(back: Callable, ps: list, r: Any) -> Any:
    """``Source.joinField``: the field rebuilt from its pieces and its residue:
    ``FAIL`` when they do not fit together, ``MISSING`` when the field is
    absent."""
    if not ps:
        return r
    es = []
    for p in ps:
        e = back(p)
        if e is None:
            return FAIL
        es.append(e)
    if r is MISSING:
        return Obj(sort_keys(es))
    if type(r) is Obj:
        return Obj(sort_keys(es + list(r)))
    return FAIL


def pick_one(k: str, l: list) -> Any:
    """``Source.pickOne``: the value of key ``k`` (``MISSING`` when absent), or
    ``FAIL`` when it occurs more than once."""
    found = [v for k2, v in l if k2 == k]
    if not found:
        return MISSING
    if len(found) == 1:
        return found[0]
    return FAIL
