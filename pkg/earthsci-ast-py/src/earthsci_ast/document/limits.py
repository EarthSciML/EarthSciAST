"""What the readers bound that the Lean model leaves unbounded.

Port of the Rust binding's ``document/limits.rs``. The Lean model's numbers,
exponents and recursion are unbounded. The readers refuse, with
``parse_error``, a document past one of these bounds, rather than read it as
something else or run out of stack:

* **Nesting.** At most :data:`MAX_NESTING` constructs open at once across the
  recursive-descent readers: math sub-expressions (a bracket, a fraction, a
  prefix ``-`` or ``\\lnot``, a ``cases`` row, a JSON value in an escape node),
  Typst values, YAML blocks and flow collections. Each calls :func:`enter`
  before it reads its contents and :func:`leave` when it is done, at the same
  points as the Rust readers' ``Nest::enter``, so every binding refuses at the
  same depth.
* **Depth.** A document read from Markdown or Typst nests at most
  :data:`MAX_JSON_DEPTH` arrays and objects, the depth ``serde_json`` reads. A
  left-nested chain (``a - b - c - …``, LaTeX ``a / b / c``, Typst ``a / b / c``)
  is checked as it grows (:func:`shallow`), since it deepens the value without
  nesting the reader.
* **Numbers.** A decimal beyond the binary64 range (``1.0e400``) has no value a
  JSON document can hold; the document functions refuse it.

The readers stay ports of the Lean functions, which return ``None`` for every
refusal; :func:`reading` collects what a read ran into, so the refusal can say
which bound it hit, and which removed operator its math names.
"""

from __future__ import annotations

import threading
from typing import Any, Callable, NamedTuple

from .value import Dec, Obj

#: The most constructs a reader holds open at once.
MAX_NESTING = 128

#: The deepest nesting of arrays and objects in a document: the most
#: ``serde_json`` reads (its recursion limit of 128 counts the outermost value
#: too).
MAX_JSON_DEPTH = 127


class _State(threading.local):
    def __init__(self) -> None:
        self.depth = 0
        self.too_deep = False
        self.removed_op: str | None = None


_STATE = _State()


class Findings(NamedTuple):
    """What one read ran into, besides its result."""

    #: A construct nested past :data:`MAX_NESTING`, or a value deeper than
    #: :data:`MAX_JSON_DEPTH`.
    too_deep: bool
    #: The first removed operator (esm-spec §4.2) the math parser met in a call
    #: or escape form.
    removed_op: str | None


def reading(f: Callable[[], Any]) -> tuple[Any, Findings]:
    """Run one read and collect its :class:`Findings`."""
    st = _STATE
    saved = (st.depth, st.too_deep, st.removed_op)
    st.depth, st.too_deep, st.removed_op = 0, False, None
    try:
        out = f()
        return out, Findings(st.too_deep, st.removed_op)
    finally:
        st.depth, st.too_deep, st.removed_op = saved


def too_deep() -> None:
    """Record that the read went past a bound."""
    _STATE.too_deep = True


def removed_op(op: str) -> None:
    """Record a removed operator the math names (the first one is kept)."""
    if _STATE.removed_op is None:
        _STATE.removed_op = op


def enter() -> bool:
    """Open a construct: ``False``, recorded as :func:`too_deep`, when
    :data:`MAX_NESTING` are open already. Every ``True`` is paired with one
    :func:`leave` (in a ``finally``)."""
    st = _STATE
    if st.depth < MAX_NESTING:
        st.depth += 1
        return True
    st.too_deep = True
    return False


def leave() -> None:
    """Close the construct the last :func:`enter` opened."""
    _STATE.depth -= 1


def json_depth(j: Any) -> int:
    """The nesting depth of arrays and objects in a document value (``0`` for a
    scalar), found without recursion."""
    best = 0
    stack = [(j, 0)]
    while stack:
        v, d = stack.pop()
        t = type(v)
        if t is list:
            best = max(best, d + 1)
            stack.extend((x, d + 1) for x in v)
        elif t is Obj:
            best = max(best, d + 1)
            stack.extend((x, d + 1) for _, x in v)
    return best


def shallow(j: Any) -> Any:
    """``j`` when it is no deeper than :data:`MAX_JSON_DEPTH`; otherwise
    ``None``, recorded as :func:`too_deep`. (``None`` is also JSON ``null``, which
    no caller passes: they pass operator nodes.)"""
    if json_depth(j) <= MAX_JSON_DEPTH:
        return j
    too_deep()
    return None


def out_of_range(j: Any) -> Dec | None:
    """The first decimal in a document value that is beyond the binary64 range
    (``1.0e400``), which no JSON document can hold; ``None`` when there is none.
    Found without recursion."""
    from .number import print_num

    stack = [j]
    while stack:
        v = stack.pop()
        t = type(v)
        if t is list:
            stack.extend(reversed(v))
        elif t is Obj:
            stack.extend(x for _, x in reversed(v))
        elif t is Dec and float(print_num(v)) in (float("inf"), float("-inf")):
            return v
    return None
