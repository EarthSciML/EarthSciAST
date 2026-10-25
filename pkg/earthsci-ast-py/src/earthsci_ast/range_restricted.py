"""The public right-hand side and its range restrictions: programs, forcing
sets, operator selection, tiles and lanes.

API_SPEC.md §5.8, "The public right-hand side" and "Range-restricted right-hand
sides". Julia and Rust implement these under ``compiler="native"``. Python has
no native program, so each entry point exists and raises
``compiler_unavailable``, naming the call; none is answered by evaluating the
whole right-hand side and discarding the rest.
"""

from __future__ import annotations

from typing import Any

from .compiler import CompilerUnavailableError

__all__ = [
    "rhs_program",
    "forcing_set",
    "default_forcing_set",
    "select",
    "halo",
    "restrict",
    "lanes",
]


def _unavailable(call: str, compiler: Any = "native") -> CompilerUnavailableError:
    return CompilerUnavailableError(
        str(compiler),
        f"`{call}` (API_SPEC §5.8, the public right-hand side) has no Python "
        f"implementation; use the Julia or Rust binding",
    )


def rhs_program(prob: Any) -> Any:
    """The Problem's right-hand side as a program value. Raises ``compiler_unavailable``."""
    raise _unavailable("rhs_program", getattr(prob, "compiler", "native"))


def forcing_set(prog: Any, bufs: Any) -> Any:
    """An epoch-stamped forcing set for ``prog``. Raises ``compiler_unavailable``."""
    raise _unavailable("forcing_set")


def default_forcing_set(prog: Any) -> Any:
    """The Problem's forcing as a forcing set. Raises ``compiler_unavailable``."""
    raise _unavailable("default_forcing_set")


def select(prog: Any, *, writes: Any = "all", terms: Any = "all") -> Any:
    """One operator's program, by provenance. Raises ``compiler_unavailable``."""
    raise _unavailable("select")


def halo(op: Any, dec: Any) -> Any:
    """The halo report of ``op`` along ``dec``. Raises ``compiler_unavailable``."""
    raise _unavailable("halo")


def restrict(op: Any, dec: Any, *, owned: Any, storage: Any) -> Any:
    """``op`` restricted to one tile. Raises ``compiler_unavailable``."""
    raise _unavailable("restrict")


def lanes(op: Any, kind: str, sets: Any) -> Any:
    """``op`` over a run-time list of cells or columns. Raises ``compiler_unavailable``."""
    raise _unavailable("lanes")
