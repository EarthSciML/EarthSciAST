"""Index-range expansion — a dependency-free leaf module.

Holds :func:`expand_range`, the expansion of an arrayop / aggregate range spec
(``[start, stop]`` or ``[start, step, stop]``) into the explicit list of 1-based
index values. It lives here, importing **nothing** from the rest of the package,
so both :mod:`earthsci_ast.flatten` and :mod:`earthsci_ast.numpy_interpreter` can
import it at module load without the historical import cycle that forced three
function-local ``from .flatten import _expand_range`` imports in the interpreter.

:mod:`earthsci_ast.flatten` re-exports it as ``_expand_range`` for its existing
callers.
"""

from __future__ import annotations


def expand_range(r: list[int]) -> list[int]:
    """Expand a range spec ``[start, stop]`` or ``[start, step, stop]``.

    Ranges are inclusive on both ends (matching Julia ``start:stop``).
    """
    if len(r) == 2:
        start, stop = r
        step = 1
    elif len(r) == 3:
        start, step, stop = r
    else:
        raise ValueError(f"Invalid range spec: {r}")
    if step == 0:
        raise ValueError(f"Range step cannot be zero: {r}")
    vals: list[int] = []
    v = int(start)
    stop = int(stop)
    step = int(step)
    if step > 0:
        while v <= stop:
            vals.append(v)
            v += step
    else:
        while v >= stop:
            vals.append(v)
            v += step
    return vals
