"""Expressions as JSON values, and the symbol table.

Port of ``formal/Esm/Document/Math/Expr.lean``. An expression is the JSON value at
an expression position (spec §4.1): a number, a name (dot-separated identifier
segments), or a node (``op``, ``args`` and any other fields). :func:`is_e` is the
well-formedness check; :class:`Sym` is what a document declares.
"""

from __future__ import annotations

from functools import lru_cache
from typing import Any, NamedTuple

from ..value import MISSING, Dec, Obj, look, num_wf, wf

# ## Characters: ASCII only.


def is_letter(c: str) -> bool:
    return ("a" <= c <= "z") or ("A" <= c <= "Z")


def is_upper(c: str) -> bool:
    return "A" <= c <= "Z"


def is_lower(c: str) -> bool:
    return "a" <= c <= "z"


def is_dig(c: str) -> bool:
    return "0" <= c <= "9"


def is_id_start(c: str) -> bool:
    return is_letter(c) or c == "_"


def is_id_char(c: str) -> bool:
    return is_letter(c) or is_dig(c) or c == "_"


# ## Names


def seg_ok(s: str) -> bool:
    """``Math.segOK``: an identifier segment ``[A-Za-z_][A-Za-z0-9_]*``."""
    return s != "" and is_id_start(s[0]) and all(is_id_char(c) for c in s[1:])


@lru_cache(maxsize=65536)
def name_ok(s: str) -> bool:
    """``Math.nameOK``: dot-separated identifier segments."""
    return all(seg_ok(g) for g in s.split("."))


#: ``Math.greek``: the Greek letter names that are a LaTeX command and a Typst
#: symbol.
GREEK = frozenset(
    {
        "alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta", "iota",
        "kappa", "lambda", "mu", "nu", "xi", "pi", "rho", "sigma", "tau", "upsilon", "phi",
        "chi", "psi", "omega", "Gamma", "Delta", "Theta", "Lambda", "Xi", "Pi", "Sigma",
        "Upsilon", "Phi", "Psi", "Omega",
    }
)  # fmt: skip


def is_greek(s: str) -> bool:
    return s in GREEK


def is_single(s: str) -> bool:
    """``Math.isSingle``: one letter, or a Greek letter name."""
    if len(s) == 1:
        return is_letter(s)
    return s in GREEK


#: ``Math.elements``: the element symbols a chemical-formula name is built from.
ELEMENTS = frozenset(
    {
        "H", "He", "Li", "Be", "B", "C", "N", "O", "F", "Ne", "Na", "Mg", "Al", "Si", "P",
        "S", "Cl", "Ar", "K", "Ca", "Ti", "Cr", "Mn", "Fe", "Co", "Ni", "Cu", "Zn", "Br",
        "Kr", "Ag", "Sn", "I", "Xe", "Hg", "Pb", "Rn",
    }
)  # fmt: skip


def pieces(s: str) -> list[tuple[str, str]]:
    """``Math.pieces``: a run of letters and the run of digits after it,
    repeatedly. ``CH2O`` is ``[("CH", "2"), ("O", "")]``."""
    out = []
    i, n = 0, len(s)
    while i < n:
        j = i
        while j < n and is_letter(s[j]):
            j += 1
        k = j
        while k < n and is_dig(s[k]):
            k += 1
        if j == i:
            break
        out.append((s[i:j], s[j:k]))
        i = k
    return out


def elem_toks(cs: str) -> list[str] | None:
    """``Math.elemToks``: an uppercase letter, then an optional lowercase one,
    greedily."""
    out = []
    i, n = 0, len(cs)
    while i < n:
        c = cs[i]
        if not is_upper(c):
            return None
        if i + 1 < n and is_lower(cs[i + 1]):
            out.append(cs[i : i + 2])
            i += 2
        else:
            out.append(c)
            i += 1
    return out


@lru_cache(maxsize=65536)
def is_formula(s: str) -> bool:
    """``Math.isFormula``: letters and digits only, read as element symbols and
    counts, starting with an element, with at least two tokens."""
    if not s or not all(is_letter(c) or is_dig(c) for c in s) or not is_upper(s[0]):
        return False
    ps = pieces(s)
    if "".join(a + b for a, b in ps) != s:
        return False
    count = 0
    for a, b in ps:
        ts = elem_toks(a)
        if ts is None or not all(t in ELEMENTS for t in ts):
            return False
        count += len(ts) + (1 if b else 0)
    return count >= 2


def sub_parts(s: str) -> tuple[str, str] | None:
    """``Math.subParts``: the subscripted shape ``b_r``: the base and the rest."""
    i = s.find("_")
    if i < 0:
        return None
    b, rest = s[:i], s[i + 1 :]
    if is_single(b) and rest:
        return b, rest
    return None


# ## JSON well-formedness, as checks

num_ok = num_wf
jwf = wf


def keys_sorted(kvs: list) -> bool:
    """``Math.keysSorted``: object keys strictly increasing."""
    return all(kvs[i][0] < kvs[i + 1][0] for i in range(len(kvs) - 1))


# ## Operators

#: ``Math.removedOps``: spec §4.2 "Removed ops", refused by name.
REMOVED_OPS = (
    "arrayop",
    "aggregate",
    "fn",
    "table_lookup",
    "skolem",
    "rank",
    "argmin",
    "argmax",
    "polygon_intersection_area",
    "intersect_polygon",
    "grad",
    "div",
    "laplacian",
)
REMOVED_SET = frozenset(REMOVED_OPS)

#: ``Math.deprecatedOps``: read in the call form and rewritten, never printed.
DEPRECATED_OPS = frozenset({"neg", "pow"})


def op_ok(s: str) -> bool:
    """``Math.opOK``: ``[A-Za-z_][A-Za-z0-9_.]*`` or ``[-+*/^<>=!]+``."""
    if not s:
        return False
    if is_id_start(s[0]) and all(is_id_char(d) or d == "." for d in s[1:]):
        return True
    return all(d in "-+*/^<>=!" for d in s)


def op_field_ok(kvs: list) -> bool:
    """``Math.opFieldOK``: an ``op`` that is neither removed nor deprecated."""
    o = look("op", kvs)
    return type(o) is str and op_ok(o) and o not in REMOVED_SET and o not in DEPRECATED_OPS


def is_e(e: Any) -> bool:
    """``Math.isE``: a well-formed expression (canonical form)."""
    t = type(e)
    if t is int or t is Dec:
        return num_wf(e)
    if t is str:
        return name_ok(e)
    if t is Obj:
        if not (keys_sorted(e) and op_field_ok(e) and look("args", e) is not MISSING):
            return False
        for k, v in e:
            if k == "args":
                if type(v) is not list or not all(is_e(x) for x in v):
                    return False
            elif k != "op" and not wf(v):
                return False
        return True
    return False


class Sym(NamedTuple):
    """``Math.Sym``: the names a document declares and the parameter list of every
    template in scope."""

    #: The declared names (only membership is ever asked).
    names: frozenset = frozenset()
    #: ``(name, params)`` per template, the first entry for a name winning.
    templates: tuple = ()


EMPTY_SYM = Sym(frozenset(), ())
