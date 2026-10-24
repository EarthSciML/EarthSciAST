"""Document-scoped solver hints (esm-spec §2.2).

The `solver` block records numerics the document knows about *itself* —
stiffness, integration tolerances, and a splitting hint — which each binding
maps to its own integrator, plus ``external``: a reference to a separate
run-configuration document (§2.2.6) that this binding never opens.

Every field is ADVISORY: a binding may ignore any or all of them and still
conform. Advisory governs the MECHANISM, never the OUTCOME — the
CONFORMANCE_SPEC §5.9 requirement to integrate successfully and agree within
the error band is untouched by this block and is not excused by it.

This module carries the things that are NOT advisory: the spec-version gates
(§2.2.4), the ``${`` refusal and the resolution of ``external`` (§2.2.6), and
the tolerance resolution order (§2.2.2).
"""

from __future__ import annotations

import os
import re
from typing import TYPE_CHECKING, Any

from ._data_source_urls import _SCHEME_RE, _remove_dot_segments
from .error_handling import (
    SOLVER_EXTERNAL_UNRESOLVED,
    SOLVER_EXTERNAL_VERSION_TOO_OLD,
    SOLVER_VERSION_TOO_OLD,
)

if TYPE_CHECKING:
    from .esm_types import EsmFile

__all__ = [
    "SolverBlockError",
    "reject_solver_external_pre_v13",
    "reject_solver_external_unresolved",
    "reject_solver_pre_v11",
    "resolve_tolerances",
    "solver_external_location",
]

#: Canonical cross-binding tolerance defaults (API_SPEC §5.8), and the bottom of
#: the §2.2.2 chain: the same knobs under the same names produce comparable
#: trajectories in Julia, Python and Rust.
#:
#: These are Julia's values, and they are LOOSER than what this binding used to
#: default to (1e-10 / 1e-14). A default is what a document gets when its author
#: has expressed no opinion about accuracy, so it is the cheapest of the three
#: rather than the most accurate. A caller who needs tighter integration passes
#: `reltol=` / `abstol=` -- and a TEST that asserts trajectory accuracy must do
#: so, rather than lean on the default and thereby assert something about the
#: library's default instead of about the model.
#:
#: They live HERE, in the lowest module of the two, so `solve()`'s signature and
#: `resolve_tolerances`'s bottom-of-chain cannot drift apart; `problem.py`
#: re-exports them under its historical names. Rust does the same in the other
#: direction (`solver.rs` imports `simulate::DEFAULT_*`).
DEFAULT_RELTOL = 1e-4
DEFAULT_ABSTOL = 1e-6


class SolverBlockError(Exception):
    """Raised for a `solver` block a document may not carry.

    Carries the stable diagnostic ``code`` (esm-spec §2.2.5) alongside the
    message, matching how ``ExpressionTemplateError`` reports the §9.7 gate.
    """

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


def reject_solver_pre_v11(view: Any) -> None:
    """Reject a top-level `solver` block in a file declaring esm < 1.1.0.

    The block arrives at ``esm: 1.1.0``; a document declaring an earlier
    version that carries one is rejected with ``solver_version_too_old``
    (esm-spec §2.2.4). Mirrors :func:`reject_template_imports_pre_v08`.
    """
    if not isinstance(view, dict) or "solver" not in view:
        return
    version = _declared_minor(view)
    if version is None or version >= (1, 1):
        return
    raise SolverBlockError(
        SOLVER_VERSION_TOO_OLD,
        f"the top-level `solver` block requires esm >= 1.1.0; file declares {view['esm']}. "
        "Offending path: /solver",
    )


def _declared_minor(view: Any) -> tuple[int, int] | None:
    """``(major, minor)`` of the document's ``esm`` string, or ``None``."""
    esm = view.get("esm")
    if not isinstance(esm, str):
        return None
    m = re.match(r"^(\d+)\.(\d+)\.(\d+)$", esm)
    if not m:
        return None
    return int(m.group(1)), int(m.group(2))


def reject_solver_external_pre_v13(view: Any) -> None:
    """Reject ``solver.external`` in a file declaring esm < 1.3.0.

    The field arrives at ``esm: 1.3.0``; an earlier document whose ``solver``
    block carries it is rejected with ``solver_external_version_too_old`` at
    ``/solver/external`` (esm-spec §2.2.4 requirement 4). A document below
    1.1.0 never reaches this gate: :func:`reject_solver_pre_v11` refuses its
    whole block first.
    """
    if not isinstance(view, dict):
        return
    block = view.get("solver")
    if not isinstance(block, dict) or "external" not in block:
        return
    version = _declared_minor(view)
    if version is None or version >= (1, 3):
        return
    raise SolverBlockError(
        SOLVER_EXTERNAL_VERSION_TOO_OLD,
        f"`solver.external` requires esm >= 1.3.0; file declares {view['esm']}. "
        "Offending path: /solver/external",
    )


def reject_solver_external_unresolved(view: Any) -> None:
    """Refuse a ``solver.external`` carrying ``${`` (esm-spec §2.2.6).

    There are no substitutions in ``external``: a run configuration chosen by
    the environment is not reproducible, so the reference is refused at load
    with ``solver_external_unresolved`` rather than expanded or passed through.
    """
    if not isinstance(view, dict):
        return
    block = view.get("solver")
    if not isinstance(block, dict):
        return
    external = block.get("external")
    if not isinstance(external, str) or "${" not in external:
        return
    raise SolverBlockError(
        SOLVER_EXTERNAL_UNRESOLVED,
        f"/solver/external: \"{external}\" carries an unexpanded '${{...}}' variable. "
        "esm-spec §2.2.6 does not expand environment variables into a run-"
        "configuration reference: a run configuration chosen by the environment "
        "is not reproducible. Write a path relative to this document, or pass "
        "the run configuration at the call site.",
    )


#: A drive-letter path, ``C:/`` or ``C:\\``: absolute on every host (§2.2.6).
_DRIVE_RE = re.compile(r"^[A-Za-z]:[/\\]")

#: The bytes a §2.2.6 location writes as themselves; every other byte of the
#: path's UTF-8 encoding is written ``%XX``.
_LOCATION_SAFE = frozenset(b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/:")


def _is_absolute(path: str) -> bool:
    return path.startswith("/") or _DRIVE_RE.match(path) is not None


def _lexical_absolute(path: str) -> str:
    """An absolute ``path`` with its dot segments removed (RFC 3986 §5.2.4).

    A drive-letter path comes back as ``C:/…``, its ``\\`` read as ``/`` and
    its drive a root that ``..`` does not climb above.
    """
    if _DRIVE_RE.match(path):
        return path[:2] + _remove_dot_segments(path[2:].replace("\\", "/"))
    return _remove_dot_segments(path)


def _absolute_directory(path: str | os.PathLike[str]) -> str:
    """``path`` as the absolute, dot-segment-free directory *D* of §2.2.6.

    A relative ``path`` is taken against the process working directory. Purely
    lexical: never ``realpath``, never touches the filesystem.
    """
    d = os.fspath(path) or "."
    if not _is_absolute(d):
        d = os.getcwd().replace(os.sep, "/") + "/" + d
    return _lexical_absolute(d)


def _file_url(path: str) -> str:
    """``file://`` plus ``path`` (absolute, dot-segment free), percent-encoded."""
    encoded = "".join(chr(b) if b in _LOCATION_SAFE else f"%{b:02X}" for b in path.encode("utf-8"))
    return "file://" + ("" if path.startswith("/") else "/") + encoded


def solver_external_location(
    esm_file: EsmFile, base: str | os.PathLike[str] | None = None
) -> str | None:
    """Where the document's ``solver.external`` points (esm-spec §2.2.6).

    Returns ``None`` when the document has no ``external``. Otherwise:

    - a URL (``scheme://…``) is returned unchanged;
    - an absolute path (``/…``, or a drive-letter ``C:/…`` / ``C:\\…``) has
      its dot segments removed, is percent-encoded and is prefixed ``file://``
      (``file:///C:/…`` for a drive);
    - anything else is joined onto *D*, dot segments removed, percent-encoded,
      and prefixed ``file://``.

    Percent-encoding writes each byte of the path's UTF-8 encoding outside
    ``A-Za-z0-9-._~/:`` as ``%XX``, ``%`` included: the input is a path, not a
    URL.

    *D* is ``base`` when given (a relative ``base`` is taken against the
    process working directory), else the directory the loader recorded: the
    directory of the file read, or the working directory for a string load or
    a document built in memory.

    Purely lexical (RFC 3986 §5.2.4): never ``realpath``, never touches the
    filesystem, so a location that does not exist resolves normally. The
    document keeps, and ``emit`` writes, the authored string.
    """
    solver = getattr(esm_file, "solver", None)
    external = getattr(solver, "external", None) if solver is not None else None
    if external is None:
        return None
    if _SCHEME_RE.match(external):
        return external
    if _is_absolute(external):
        return _file_url(_lexical_absolute(external))
    if base is not None:
        d = _absolute_directory(base)
    else:
        recorded = getattr(esm_file, "document_base", None)
        d = recorded if recorded is not None else _absolute_directory(os.getcwd())
    return _file_url(_lexical_absolute(d + "/" + external))


def resolve_tolerances(
    solver: Any,
    abstol: float | None = None,
    reltol: float | None = None,
) -> tuple[float, float]:
    """Resolve integration tolerances most-specific first (esm-spec §2.2.2).

    ``solver`` may be a :class:`~earthsci_ast.esm_types.Solver`, the raw
    ``solver`` block as a dict (what ``EsmProblem.doc`` carries), or ``None``.

    1. An explicit argument at the ``solve()`` call site — wins outright.
    2. Otherwise the document's ``solver.abstol`` / ``solver.reltol``.
    3. Otherwise the binding default (``reltol`` 1e-4, ``abstol`` 1e-6).

    The two tolerances resolve INDEPENDENTLY: a document that declares only
    ``reltol`` leaves ``abstol`` to fall through to the default, exactly as
    §6.6.4 merges its own chain per field.

    These are INTEGRATION tolerances. They are a different quantity from the
    ``tolerance`` object an assertion is compared at (§6.6.4), which resolves
    on its own chain and is not touched here.
    """
    if isinstance(solver, dict):
        doc_abstol = solver.get("abstol")
        doc_reltol = solver.get("reltol")
    else:
        doc_abstol = getattr(solver, "abstol", None) if solver is not None else None
        doc_reltol = getattr(solver, "reltol", None) if solver is not None else None
    resolved_abstol = (
        abstol if abstol is not None else (doc_abstol if doc_abstol is not None else DEFAULT_ABSTOL)
    )
    resolved_reltol = (
        reltol if reltol is not None else (doc_reltol if doc_reltol is not None else DEFAULT_RELTOL)
    )
    return resolved_abstol, resolved_reltol
