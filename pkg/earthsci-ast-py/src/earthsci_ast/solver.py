"""Document-scoped solver hints (esm-spec §2.2).

The `solver` block records numerics the document knows about *itself* —
stiffness, integration tolerances, and a splitting hint — which each binding
maps to its own integrator.

Every field is ADVISORY: a binding may ignore any or all of them and still
conform. Advisory governs the MECHANISM, never the OUTCOME — the
CONFORMANCE_SPEC §5.9 requirement to integrate successfully and agree within
the error band is untouched by this block and is not excused by it.

This module carries the two things that are NOT advisory: the spec-version
gate (§2.2.4) and the tolerance resolution order (§2.2.2).
"""

from __future__ import annotations

import re
from typing import Any

from .error_handling import SOLVER_VERSION_TOO_OLD

__all__ = [
    "SolverBlockError",
    "reject_solver_pre_v11",
    "resolve_tolerances",
]

#: Binding defaults (API_SPEC §5.8), the bottom of the §2.2.2 chain.
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
    esm = view.get("esm")
    if not isinstance(esm, str):
        return
    m = re.match(r"^(\d+)\.(\d+)\.(\d+)$", esm)
    if not m:
        return
    major, minor = int(m.group(1)), int(m.group(2))
    if (major, minor) >= (1, 1):
        return
    raise SolverBlockError(
        SOLVER_VERSION_TOO_OLD,
        f"the top-level `solver` block requires esm >= 1.1.0; file declares {esm}. "
        "Offending path: /solver",
    )


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
    resolved_abstol = abstol if abstol is not None else (
        doc_abstol if doc_abstol is not None else DEFAULT_ABSTOL
    )
    resolved_reltol = reltol if reltol is not None else (
        doc_reltol if doc_reltol is not None else DEFAULT_RELTOL
    )
    return resolved_abstol, resolved_reltol
