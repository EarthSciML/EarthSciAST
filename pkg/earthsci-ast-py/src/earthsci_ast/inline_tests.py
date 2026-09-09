"""inline_tests — the §6.6.5-capable inline-test runner over the NumPy
simulation pathway (the Python mirror of the Julia binding's
``inline_tests.jl``).

A PDE model's inline tests (esm-spec §6.6.5) assert REDUCTIONS of a spatial
field — ``reduce: L2_error | Linf_error`` against an analytic ``reference``
expression, or the pure collapsers ``integral | mean | max | min`` — or
point-sample it via ``coords``. This module drives the official NumPy
tree-walk pipeline (:func:`earthsci_ast.problem.solve` over the
array-op interpreter) and collapses fields per assertion.

Cross-binding pinned conventions (identical in the Julia / Python / Rust
bindings; the esm-spec leaves these open, so determinism requires pinning):

1. ``coords`` point-sampling — coords values are positions in INDEX space
   (1-based, fractional allowed) along the named interval index sets;
   sampling picks the NEAREST grid index, with exact half-way ties rounding
   DOWN toward the lower index (``idx = ceil(c - 1/2)``). Keys must name the
   asserted field's index sets; a strict subset pins only when every
   remaining dimension has exactly one sample; the resolved index must lie
   in ``1..size``. Mutually exclusive with ``reduce``.
2. ``integral`` reduce — the uniform-cell Riemann sum under a UNIT total
   domain measure per axis: ``integral = sum(field) / N_cells = mean(field)``.
   Authors of non-unit physical domains must scale the expectation until the
   spec grows a measure concept. This is exactly the measure convention under
   which the relative-L2 reduction is measure-free (the per-cell measure
   cancels between numerator and denominator).
3. ``from_file`` references — ``{type: "from_file", path, format?}``:
   ``path`` resolves relative to the .esm file's directory (``base_dir``,
   defaulting to the loaded path's directory, else the working directory);
   the default and only v1 ``format`` is ``"json"`` — a row-major nested JSON
   array exactly matching the field's shape (validated; mismatch is a clear
   error). The loaded array is used exactly like an evaluated inline
   reference in the error-norm reductions.

Public surface (1:1 with the Julia reference):

- :func:`evaluate_cellwise` — official per-cell evaluation of an array-valued
  build-time expression (grid geometry / §6.6.5 analytic references) through
  the same NumPy interpreter the evaluator uses for coordinate-expression
  ``ic`` seeding.
- :func:`field_reduce` — the §6.6.5 reduction semantics (relative L2,
  absolute Linf, mean/max/min).
- :func:`state_cells` — (cell-index-tuple, flat-slot) pairs of one array
  state, sorted by cell tuple.
- :func:`simulate_states` — states sampled at requested times, with the
  element-name → row map conformance runners key on.
- :func:`run_inline_tests` — run every inline test of the selected
  component(s) of one or many documents; returns per-assertion results
  carrying the ACTUAL reduction values (conformance runners record these).
- :class:`InlineTestOptions` — the per-document override record a caller's
  ``options_for`` callback returns.

This entry was called ``run_pde_tests`` until it grew the ability to run a
whole corpus. The name was always too narrow — the §6.6.5 spatial reductions
are one assertion FORM, and the same runner has always executed the plain
pointwise assertions of an ODE document through the same frame — so it is now
``run_inline_tests``, with no deprecated alias (the old spelling is exactly
the misunderstanding the rename exists to remove).
"""

from __future__ import annotations

import copy
import glob
import json
import math
import os
import re
from collections.abc import Callable, Iterable, Iterator, Mapping, Sequence
from dataclasses import dataclass, field
from typing import Any

import numpy as np

from .classification import is_observed_unknown
from .esm_types import EsmFile, Expr, ExprNode, Tolerance
from .expr_walk import iter_children
from .flatten import flatten
from .lower_table_lookup import lower_table_lookups
from .parse import load_path, load_string
from .problem import esm_problem, solve
from .simulation import BuildInspection, _eval_buildtime_field, observed_at_state
from .simulation_common import ReturnCode

# esm-spec §6.6.4: the default tolerance when neither the assertion, its test,
# nor the model declares one (same constant as the Julia run_tests reference).
_DEFAULT_REL_TOL = 1e-6

#: Solver tolerances for INLINE-TEST execution, and for any test that asserts a
#: trajectory against a declared or closed-form value.
#:
#: These are deliberately NOT the library's default tolerances
#: (:data:`~earthsci_ast.problem.DEFAULT_RELTOL` / ``DEFAULT_ABSTOL``). A default
#: is what a document gets when its author expressed no opinion about accuracy;
#: a test asserting a number has very much expressed one, and leaning on the
#: default would make it assert something about the library's default rather than
#: about the model. Julia draws the same line, with the same values
#: (``DEFAULT_TEST_RELTOL`` / ``DEFAULT_TEST_ABSTOL`` in ``src/run_tests.jl``).
#:
#: ``TEST_ABSTOL`` is tighter than Julia's ``1e-12``, and deliberately. An
#: absolute tolerance is only meaningful against the magnitude of the states it
#: bounds, and several fixtures here integrate concentrations of order ``1e-6``
#: while asserting a RELATIVE ``1e-6`` -- an absolute bound near ``3.7e-13``.
#: ``1e-12`` is looser than the assertion itself at that scale, so the run could
#: not be accurate enough to be worth asserting on. Julia's fixtures do not go
#: that small, so its ``1e-12`` is fine there; this is a property of the
#: fixtures, not a divergence in the library.
TEST_RELTOL = 1e-10
TEST_ABSTOL = 1e-14

#: The integrator used when neither the caller nor the document says otherwise.
DEFAULT_METHOD = "RK45"

#: The integrator chosen for a document declaring ``solver.stiffness: "high"``
#: (esm-spec §2.2). BDF is scipy's implicit multistep method; LSODA — which is
#: what an unqualified default would reach for — cannot integrate a strongly
#: stiff system like the POLLU benchmark at all: its Fortran callback overflows
#: even with an analytic Jacobian and even over a 60 s window, while BDF does
#: the full 3600 s in ~0.2 s and reproduces the published reference.
STIFF_METHOD = "BDF"


def _method_for(method: str | None, file: EsmFile) -> str:
    """The integrator for ``file``, most-specific first (esm-spec §2.2).

    1. An explicit ``method`` from the caller — wins outright.
    2. Otherwise :data:`STIFF_METHOD` when the document declares
       ``solver.stiffness: "high"``.
    3. Otherwise :data:`DEFAULT_METHOD`.

    ``stiffness`` is ADVISORY: this binding is free to ignore it, and does
    ignore ``"low"`` / ``"moderate"``, which say nothing the default does not
    already handle. Acting on ``"high"`` is what keeps a stiff document from
    being an overflow — and it is the whole reason the block exists, since the
    alternative is a basename lookup table in each binding's own harness that
    cannot travel with the document.

    Note this maps a portable DECLARATION onto THIS binding's integrator names.
    The document never carries ``"BDF"`` itself: an algorithm name is a scipy
    identifier where Julia would want ``Rosenbrock23``, which is exactly what
    esm-spec §2.2.3 rules out.
    """
    if method is not None:
        return method
    solver = getattr(file, "solver", None)
    if getattr(solver, "stiffness", None) == "high":
        return STIFF_METHOD
    return DEFAULT_METHOD


def _integration_tolerances(
    file: EsmFile, rtol: float | None, atol: float | None
) -> tuple[float, float]:
    """The INTEGRATION tolerances a run of ``file`` solves at (esm-spec §2.2.2).

    Most-specific first:

    1. An explicit ``rtol`` / ``atol`` from the caller — wins outright.
    2. Otherwise this document's ``solver.reltol`` / ``solver.abstol``.
    3. Otherwise this runner's :data:`TEST_RELTOL` / :data:`TEST_ABSTOL`.

    The runner values sit at the BOTTOM of the chain — they are binding
    defaults, not a caller's opinion — so a stiff document can ask for its own
    integration accuracy without every caller naming it. They are still what an
    assertion-bearing test gets by default, which is the property the comment on
    ``TEST_RELTOL`` is about. The two resolve INDEPENDENTLY, so a document
    declaring only ``reltol`` leaves ``atol`` on the runner default.

    ``is not None``, never truthiness: ``0.0`` is a value the document SET, and
    ``or`` would silently swap it for the runner default instead of letting the
    integrator refuse it. The schema forbids a non-positive tolerance, but this
    takes an ``EsmFile`` a caller may have built in memory and never re-validates
    it.

    Not :func:`~earthsci_ast.solver.resolve_tolerances` because that function's
    level 3 is the ``solve()`` binding defaults; only the bottom of the chain
    differs.

    These are INTEGRATION tolerances. The tolerance each assertion is COMPARED
    at is resolved separately (§6.6.4) and is untouched here.
    """
    solver = getattr(file, "solver", None)
    doc_reltol = getattr(solver, "reltol", None)
    doc_abstol = getattr(solver, "abstol", None)
    return (
        rtol if rtol is not None else (doc_reltol if doc_reltol is not None else TEST_RELTOL),
        atol if atol is not None else (doc_abstol if doc_abstol is not None else TEST_ABSTOL),
    )


# Historical private spellings, kept so existing call sites keep working.
_DEFAULT_SOLVER_RTOL = TEST_RELTOL
_DEFAULT_SOLVER_ATOL = TEST_ABSTOL

# Relative slack for matching a requested ``saveat`` time to the solver's dense
# output grid (``_SAVEAT_MATCH_TOL · max(1, |t|)``); span endpoints always fit.
_SAVEAT_MATCH_TOL = 1e-9

_CELL_NAME_RE = re.compile(r"^(.+)\[([0-9,]+)\]$")


@dataclass
class AssertionResult:
    """Outcome of one §6.6.5 inline-test assertion evaluated through the
    NumPy simulation pathway. ``actual`` is the computed reduction value
    (``None`` when the simulation or reduction itself failed); ``message``
    carries the diff or error text for non-passing results."""

    model: str
    test_id: str
    assertion_idx: int
    variable: str
    time: float
    reduce: str | None
    expected: float
    actual: float | None
    rtol: float
    atol: float
    passed: bool
    message: str


@dataclass(frozen=True)
class InlineTestOptions:
    """Per-document overrides for :func:`run_inline_tests`, returned by its
    ``options_for`` callback.

    Every field is optional, and a field left ``None`` INHERITS the value the
    caller passed to :func:`run_inline_tests` itself. So a callback that cares
    about one document's solver and nothing else returns
    ``InlineTestOptions(method="BDF")`` and the rest of the run is unchanged.

    This record exists so that site-specific policy stays at the site. A CI
    gate over a model corpus routinely carries basename-keyed tables — a
    ``cse`` allowlist, a stiff-solver map, an initial-condition seed for the
    documents whose tests do not state one — and each of those is a reason
    the gate could not call the library entry and re-implemented esm-spec
    §6.6 instead. One callback absorbs all of them without this module
    learning anything about the corpus.

    ``initial_conditions`` / ``parameter_overrides`` are SEEDS: they are
    applied BENEATH the test's own maps, so a test that states a value keeps
    it and a test that is silent gets the caller's. They are merged with the
    test's map BEFORE :func:`_scope_to_component` runs, and so are keyed and
    resolved exactly like a test's own keys — which is what makes the
    precedence well defined. Merging afterwards would hand the build two keys
    (``T`` and ``M.T``) designating one parameter with two values.
    """

    #: Run only this component of the document (``None`` runs every one).
    model_name: str | None = None
    #: scipy ``solve_ivp`` method.
    method: str | None = None
    #: Solver relative tolerance.
    rtol: float | None = None
    #: Solver absolute tolerance.
    atol: float | None = None
    #: Directory that anchors ``from_file`` reference paths (§6.6.5).
    base_dir: str | None = None
    #: Common-subexpression elimination in the right-hand-side build.
    cse: bool | None = None
    #: Initial-condition seed, applied beneath each test's own map.
    initial_conditions: Mapping[str, Any] | None = None
    #: Parameter-override seed, applied beneath each test's own map.
    parameter_overrides: Mapping[str, Any] | None = None


@dataclass(frozen=True)
class _ResolvedOptions:
    """One document's options after ``options_for`` has been folded onto the
    call-level defaults. Internal.

    ``method`` / ``rtol`` / ``atol`` may still be ``None``: those three resolve
    further against the DOCUMENT's own ``solver`` block (esm-spec §2.2.2,
    §2.2.3), which is only reachable once the document is loaded. ``None`` here
    means "neither ``options_for`` nor the caller named one", which is what
    keeps the document's own opinion expressible."""

    model_name: str | None
    method: str | None
    rtol: float | None
    atol: float | None
    base_dir: str | None
    cse: bool
    initial_conditions: Mapping[str, Any] = field(default_factory=dict)
    parameter_overrides: Mapping[str, Any] = field(default_factory=dict)


def evaluate_cellwise(
    expr: Expr,
    cells: Sequence[Sequence[int]],
    index_sets: dict[str, Any] | None = None,
    params: dict[str, float] | None = None,
) -> list[float]:
    """Evaluate an array-valued expression (elementwise ops over
    array-producing ``aggregate``/``makearray`` nodes — e.g. a grid-geometry
    template expanded by a §9.7 import, or a §6.6.5 analytic ``reference``)
    at each 1-based integer cell of ``cells``, returning one float per cell.

    This is the public entry to the same build-time machinery the evaluator
    uses to seed coordinate-expression ``ic`` fields
    (:func:`earthsci_ast.simulation._eval_buildtime_field`).

    STATE references are not in scope. Model PARAMETERS (load-time constants)
    ARE: pass their resolved values as ``params`` (name → value, e.g. a build's
    :attr:`BuildInspection.params`) and a parameter-dependent expression
    resolves (esm-spec §6.6.5). A scalar (const-folded) result broadcasts.
    """
    value = _eval_buildtime_field(expr, index_sets=index_sets, param_values=params)
    if np.ndim(value) == 0:
        return [float(value)] * len(cells)
    arr = np.asarray(value, dtype=float)
    out: list[float] = []
    for cell in cells:
        if len(cell) != arr.ndim:
            raise ValueError(
                f"evaluate_cellwise: cell {tuple(cell)} has {len(cell)} indices "
                f"but the field has ndim={arr.ndim}"
            )
        out.append(float(arr[tuple(int(c) - 1 for c in cell)]))
    return out


def _mentions_free(expr: Expr, name: str) -> bool:
    """Whether ``name`` occurs FREE in ``expr``: as a variable reference not
    bound by an enclosing ``aggregate`` / ``arrayop`` / ``makearray`` loop
    symbol (``output_idx``, a ``ranges`` key) or an ``integral``'s integration
    variable. A node that binds ``name`` shadows it for its whole subtree."""
    if isinstance(expr, str):
        return expr == name
    if not isinstance(expr, ExprNode):
        return False
    if name in (expr.output_idx or []) or name in (expr.ranges or {}) or expr.var == name:
        return False
    return any(_mentions_free(child, name) for child in iter_children(expr))


def bind_dimension_names(
    expr: Expr, dims: Sequence[str], scope: Mapping[str, float] | None = None
) -> Expr:
    """esm-spec §6.6.5: an inline ``reference``'s free variables are the
    domain DIMENSION NAMES. For a field shaped over index sets those are the
    asserted variable's ``shape`` entries, each bound at every grid point to
    the 1-based position along its axis — the same index space ``coords``
    reads (convention 1) — so ``index(table, lev)`` reads the cell's entry of
    a lookup array and ``sin(pi * (x - 0.5) / N)`` is the cell-centre analytic
    form, with no explicit gather. A reference that mentions a dimension name
    FREE is turned into the whole field by wrapping it in an ``aggregate``
    whose output indices ARE the dimension names (in shape order, each ranging
    over its index set); one that mentions none — a literal, a parameter
    expression, or an ``aggregate`` that already produces the field under its
    own loop symbols — is returned untouched, so nothing that evaluated before
    evaluates differently. Mirrors the Julia / Rust ``bind_dimension_names``.

    ``scope`` is the reference's build-time parameter scope (flattened names
    plus their unambiguous bare aliases). "Nothing that evaluated before
    evaluates differently" holds only because a dimension name that scope ALSO
    binds is rejected here: wrapping would silently shadow the parameter with
    the cell's index — the same expression, a different number, no diagnostic.
    One name meaning two things in one scope is an ill-formed document, so it
    is a fault."""
    dims = [str(d) for d in dims]
    mentioned = [d for d in dims if _mentions_free(expr, d)]
    if not mentioned:
        return expr
    clash = next((d for d in mentioned if scope is not None and d in scope), None)
    if clash is not None:
        raise RuntimeError(
            f"inline `reference` mentions {clash!r}, which is both a dimension of the "
            "asserted field and a parameter in scope. esm-spec §6.6.5 binds a free "
            "dimension name to the cell's 1-based position, which would shadow the "
            "parameter. Rename one of them, or gather explicitly with "
            f"`aggregate(i from {clash}; …)`."
        )
    return ExprNode(
        op="aggregate",
        args=[],
        output_idx=list(dims),
        ranges={d: {"from": d} for d in dims},
        expr=expr,
    )


def field_reduce(
    kind: str,
    actual: Sequence[float],
    reference: Sequence[float] | None = None,
) -> float:
    """Collapse a spatial field to the scalar a §6.6.5 ``reduce`` assertion
    compares (esm-spec §6.6.5); semantics identical to the Julia reference:

    - ``"L2_error"``  — ``‖actual − reference‖₂ / ‖reference‖₂`` (relative L2
      over the domain; requires ``reference``).
    - ``"Linf_error"`` — ``max |actual − reference|`` (absolute supremum norm;
      requires ``reference``).
    - ``"integral"`` — the uniform-cell Riemann sum under a UNIT total domain
      measure per axis: ``sum(field) / N_cells``, i.e. exactly ``mean``. This
      is the pinned cross-binding convention (the same measure convention
      under which the relative-L2 reduction is measure-free); non-unit
      physical domains must be scaled by the author until the spec grows a
      measure concept.
    - ``"mean" | "max" | "min"`` — pure collapsers of ``actual``.
    """
    k = str(kind)
    a = np.asarray(actual, dtype=float)
    if k in ("L2_error", "Linf_error"):
        if reference is None:
            raise ValueError(f"field_reduce: `{k}` requires a reference field")
        r = np.asarray(reference, dtype=float)
        if r.shape != a.shape:
            raise ValueError(f"field_reduce: actual has {a.size} cells but reference has {r.size}")
        diff = a - r
        if k == "L2_error":
            refnorm = float(np.sqrt(np.sum(r * r)))
            if refnorm == 0.0:
                raise ValueError("field_reduce: L2_error reference has zero norm")
            return float(np.sqrt(np.sum(diff * diff)) / refnorm)
        return float(np.max(np.abs(diff)))
    if k in ("mean", "integral"):
        if a.size == 0:
            raise ValueError("field_reduce: empty field")
        return float(np.sum(a) / a.size)
    if k == "max":
        return float(np.max(a))
    if k == "min":
        return float(np.min(a))
    raise ValueError(f"field_reduce: unsupported reduce kind '{k}'")


def state_cells(
    var_map: dict[str, int],
    variable: str,
    model: str,
) -> list[tuple[list[int], int]]:
    """Collect the (cell-index-tuple, flat-slot) pairs of one array state from
    a ``var_map`` (element name → row/slot). Flattening prefixes element names
    with the owning model (``"Heat.u[3]"``), and a coupled build routinely
    reuses the same bare array name across sibling components (``M1.u`` /
    ``M2.u``). So the model-qualified stem MUST win, in two passes: exact
    ``model.variable`` / exact-bare stem matches first, and a bare-SUFFIX
    fallback reached only when no exact stem matched (a bare-keyed
    single-model build).

    A single pass that unioned both — what this used to do — spliced EVERY
    sibling model's cells into one field: a document with four models each
    declaring ``w[x]`` produced four cells at index ``[1]``, and a ``coords``
    sample read whichever model sorted first (always the same wrong one), while
    a ``reduce`` collapsed over all four models at once and a per-cell
    ``reference`` then indexed past the end of the field. Identical to the
    Julia reference's ``_state_cells`` and the Rust ``state_cells``, and the
    array analog of :func:`_scalar_slot`'s qualified-first resolution.

    Sorted by cell tuple so callers get a deterministic pairing."""
    exact: list[tuple[list[int], int]] = []
    fallback: list[tuple[list[int], int]] = []
    qualified = f"{model}.{variable}"
    for name, slot in var_map.items():
        m = _CELL_NAME_RE.match(str(name))
        if m is None:
            continue
        stem = m.group(1)
        cell = ([int(x) for x in m.group(2).split(",")], int(slot))
        if stem in (qualified, variable):
            exact.append(cell)
            continue
        bare = stem.split(".", 1)[1] if "." in stem else stem
        if bare == variable:
            fallback.append(cell)
    out = exact if exact else fallback
    out.sort(key=lambda p: p[0])
    return out


def _param_scope_with_aliases(params: dict[str, float] | None) -> dict[str, float]:
    """Build-time scalar-parameter scope for §6.6.5 cellwise references, with
    bare aliases. :attr:`BuildInspection.params` is keyed by the FLATTENED
    parameter name (``"M.k"``) — matching a resolved observed expression, which
    flattening qualifies. A test author's analytic ``reference``, though, names
    the parameter BARE (``"k"``). So we expose BOTH: the flattened key verbatim,
    plus an unambiguous bare alias (the final dotted segment). On a bare-name
    collision across subsystems the flattened key stays authoritative and the
    ambiguous alias is dropped (the qualified reference still resolves).
    Mirrors the Julia ``_param_scope_with_aliases``."""
    if not params:
        return {}
    out: dict[str, float] = {str(k): float(v) for k, v in params.items()}
    counts: dict[str, int] = {}
    for k in params:
        bare = str(k).rsplit(".", 1)[-1]
        counts[bare] = counts.get(bare, 0) + 1
    for k, v in params.items():
        s = str(k)
        bare = s.rsplit(".", 1)[-1]
        if bare != s and counts[bare] == 1 and bare not in out:
            out[bare] = float(v)
    return out


def _declares_observed(file: EsmFile, model: str, variable: str) -> bool:
    """Does ``model`` itself declare ``variable`` as an OBSERVED of its own?

    The gate on every array-observed field lookup, and the reason a field
    belongs to ONE component (CONFORMANCE_SPEC §5.27.1). Both field sources
    resolve a bare name by a unique ``.<name>`` suffix across the FLATTENED
    build, which spans every sibling component — so without this a model
    asserting a name it does not declare silently reads whichever sibling
    happens to declare it. A four-component document where only ``M1`` defines
    ``g`` answered an ``M2`` assertion on ``g`` with M1's field instead of the
    error the name deserves.

    Identical to the guard the other two bindings already apply before they
    look at all: Rust ``observed_field`` (``model.variables.get(variable)`` plus
    ``Classification::is_observed``) and Julia ``_observed_field``
    (``observed_unknowns(model)``). OBSERVED is derived from the equations
    (esm-spec §6.3.1), not declared, so both halves are required: a declared
    name that no equation defines as an observed is not one."""
    model_obj = (file.models or {}).get(str(model))
    if model_obj is None:
        return False
    if str(variable) not in (model_obj.variables or {}):
        return False
    return is_observed_unknown(model_obj, str(variable))


def _inspection_field(
    insp: BuildInspection | None,
    model: str,
    variable: str,
) -> np.ndarray | None:
    """The state-free ARRAY OBSERVED field named by a §6.6.5 assertion, read
    from the build inspection's setup arrays — the observed-assertion form:
    the asserted ``variable`` is an array observed (the MPAS rule output
    ``div_flux`` asserted max/min = 0), not a state, and being state-free it
    is constant along the trajectory, so the build-time materialization IS
    its value at every assertion time. Flattening prefixes each observed with
    its owning model (``"Divergence.div_flux"``), so try the qualified name,
    the bare name, then a unique ``.<name>`` suffix match — the same lookup
    the Julia conformance runner applies to its ``BuildInspection``. Returns
    ``None`` when the inspection carries no such array (the caller then
    surfaces its standard missing-variable error)."""
    if insp is None:
        return None
    for key in (f"{model}.{variable}", variable):
        arr = insp.setup_arrays.get(key)
        if arr is not None:
            return np.asarray(arr, dtype=float)
    hits = [k for k in insp.setup_arrays if k.endswith("." + variable)]
    if len(hits) == 1:
        return np.asarray(insp.setup_arrays[hits[0]], dtype=float)
    return None


def _observed_sample(
    sim: SimulatedStates,
    model: str,
    variable: str,
    state: np.ndarray,
    t: float,
) -> np.ndarray | None:
    """The ARRAY OBSERVED ``variable`` evaluated at ONE trajectory sample — the
    §6.6.5 answer for a STATE-DEPENDENT array observed.

    A state-free array observed is constant along the trajectory and the build
    materialized it (:func:`_inspection_field` reads it back). A state-dependent
    one cannot be read that way at all: its value moves with the state, and the
    output-node reconstruction exposes only SCALAR observeds as rows. So it is
    computed the only way that is faithful to §5.23's "a reference denotes its
    expansion" — replaying the observed's own expression through the official
    NumPy observed driver at this sample, which is exactly what
    :func:`~earthsci_ast.simulation_array.observed_at_state` does.

    Returns the field as an ``ndarray``, or ``None`` when the run kept no built
    problem, the name is not an observed of this build, or its value at this
    sample is 0-D (a scalar observed is not a field; the caller then reports the
    missing-field error, as before)."""
    prob = getattr(sim, "problem", None)
    build = getattr(prob, "build", None)
    if build is None:
        return None
    for name in (f"{model}.{variable}", str(variable)):
        value = observed_at_state(build, prob.flat, name, float(t), state)
        if value is None:
            continue
        arr = np.asarray(value, dtype=float)
        if arr.ndim == 0:
            return None
        return arr
    return None


def _scalar_slot(var_map: dict[str, int], variable: str, model: str) -> int | None:
    """Flat slot of a SCALAR state / scalar OBSERVED by model-qualified name
    (preferred) or bare name.

    Flattening qualifies every element with its owning model (``"arrh.k"``),
    and a coupled build routinely reuses the same bare observed name across
    sibling components — several reaction-rate coefficients all named ``k``.
    So the model-qualified name MUST win: a bare-name match alone returns the
    first ``k`` in layout order (``rate_toppb.k``) for every model's ``k``
    assertion, reading the wrong component's value. We therefore do two passes
    — an exact qualified / exact-bare match first, then a bare-suffix fallback
    (reached only when the qualified element is absent, e.g. a bare-keyed
    single-model build)."""
    qualified = f"{model}.{variable}"
    for name, slot in var_map.items():
        if str(name) in (qualified, variable):
            return int(slot)
    for name, slot in var_map.items():
        s = str(name)
        bare = s.split(".", 1)[1] if "." in s else s
        if bare == variable:
            return int(slot)
    return None


def _test_components(file: EsmFile, model_name: str | None) -> Iterator[tuple[str, Any]]:
    """The document's TEST-BEARING components, models first and then reaction
    systems, each in the document's own key order.

    esm-spec §6.6 hangs ``tests`` off a component, and the schema gives
    ``reaction_systems`` the same ``tests`` / ``tolerance`` members it gives
    ``models``. The runner iterated ``models`` alone until this was fixed, so
    a chemical mechanism's inline tests were not run and not reported — the
    silent half of a coverage gap, since a component with no rows and a
    component that was never looked at are indistinguishable in the result
    list.

    Reaction-system species are 0-D, so their assertions take the pointwise
    (scalar-slot) form; nothing about the build changes, because the whole
    document is flattened either way and a species becomes an ordinary state.
    """
    for kind in ((file.models or {}), (file.reaction_systems or {})):
        for name, component in kind.items():
            if model_name is not None and str(name) != str(model_name):
                continue
            if not getattr(component, "tests", None):
                continue
            yield str(name), component


def _variable_shape(file: EsmFile, mname: str, variable: str) -> list[str]:
    """The asserted variable's declared spatial shape (ordered index-set
    names). Raises when the variable is missing or scalar — a ``coords``
    assertion is ill-formed on a 0-D variable per esm-spec §6.6.5. Identical
    to the Julia reference's ``_variable_shape``."""
    model = (file.models or {}).get(str(mname))
    if model is None:
        if str(mname) in (file.reaction_systems or {}):
            # A reaction system declares SPECIES, and a species is 0-D. So the
            # answer is the coords-specific rejection, not "model not found":
            # the component exists, and what is ill-formed is asking a scalar
            # for a grid cell.
            raise RuntimeError(
                f"`coords` requires a spatially-shaped variable; '{variable}' is scalar"
            )
        raise RuntimeError(f"model '{mname}' not found")
    v = (model.variables or {}).get(str(variable))
    if v is None:
        raise RuntimeError(f"variable '{variable}' is not declared in model '{mname}'")
    if not v.shape:
        raise RuntimeError(f"`coords` requires a spatially-shaped variable; '{variable}' is scalar")
    return [str(s) for s in v.shape]


def _coords_cell(
    coords: dict[str, float],
    shape: list[str],
    index_sets: dict[str, Any] | None,
) -> list[int]:
    """Resolve a §6.6.5 ``coords`` map to a concrete 1-based cell tuple over
    ``shape`` (the field's ordered index-set names), per the pinned
    cross-binding convention: coords values are positions in INDEX space
    (1-based, fractional allowed) along interval index sets; sampling =
    nearest grid index with exact half-way ties rounding DOWN
    (``idx = ceil(c - 1/2)``). A strict subset of dimensions may be pinned
    only when every remaining dimension is singleton. Identical to the Julia
    reference's ``_coords_cell``."""
    for k in coords:
        if str(k) not in shape:
            raise RuntimeError(
                f"`coords` names unknown dimension '{k}' (field dimensions: {', '.join(shape)})"
            )
    index_sets = index_sets or {}
    cell: list[int] = []
    for s in shape:
        entry = index_sets.get(s)
        size = (
            entry.get("size")
            if isinstance(entry, dict) and entry.get("kind") == "interval"
            else None
        )
        if not isinstance(size, int) or isinstance(size, bool):
            raise RuntimeError(
                f"`coords` sampling requires interval index sets with a "
                f"declared size; '{s}' is not one"
            )
        n = int(size)
        if s in coords:
            c = float(coords[s])
            idx = math.ceil(c - 0.5)  # nearest index; exact ties round DOWN
            if not 1 <= idx <= n:
                raise RuntimeError(
                    f"`coords` position {c} along '{s}' resolves to index {idx}, outside 1..{n}"
                )
            cell.append(int(idx))
        else:
            if n != 1:
                raise RuntimeError(
                    f"`coords` leaves dimension '{s}' unpinned with {n} "
                    f"samples; a strict subset pins only when every "
                    f"remaining dimension is singleton"
                )
            cell.append(1)
    return cell


def _nested_at(data: Any, cell: list[int], exts: list[int]) -> float:
    """Walk a row-major nested JSON array to the value at 1-based ``cell``,
    validating each level's extent against ``exts`` (the field's
    per-dimension extents). The full Cartesian cell sweep visits every node,
    so ragged or mis-sized payloads always surface a shape-mismatch error."""
    node = data
    for d, i in enumerate(cell, start=1):
        if not isinstance(node, list):
            raise RuntimeError(
                f"from_file reference shape mismatch along dimension {d}: "
                f"expected a nested array of length {exts[d - 1]}"
            )
        if len(node) != exts[d - 1]:
            raise RuntimeError(
                f"from_file reference shape mismatch along dimension {d}: "
                f"expected length {exts[d - 1]}, found {len(node)}"
            )
        node = node[i - 1]
    if not isinstance(node, (int, float)) or isinstance(node, bool):
        raise RuntimeError(
            f"from_file reference shape mismatch at cell "
            f"[{','.join(str(c) for c in cell)}]: expected a number"
        )
    return float(node)


def _from_file_reference(
    ref: dict[str, Any],
    base_dir: str,
    cell_tuples: list[list[int]],
) -> list[float]:
    """Load a ``{type: "from_file", path, format?}`` reference (esm-spec
    §6.6.5) as the per-cell reference field over ``cell_tuples``, per the
    pinned cross-binding convention: ``path`` resolves relative to
    ``base_dir`` (the .esm file's directory); the default and only v1
    ``format`` is ``"json"`` — a row-major nested array exactly matching the
    field's shape. Identical to the Julia reference's
    ``_from_file_reference``."""
    fmt_raw = ref.get("format")
    fmt = "json" if fmt_raw is None else str(fmt_raw).lower()
    if fmt != "json":
        raise RuntimeError(
            f"from_file reference format '{fmt}' is not supported (v1 supports \"json\" only)"
        )
    path_raw = ref.get("path")
    if path_raw is None:
        raise RuntimeError("from_file reference is missing `path`")
    p = str(path_raw)
    resolved = p if os.path.isabs(p) else os.path.join(str(base_dir), p)
    if not os.path.isfile(resolved):
        raise RuntimeError(f"from_file reference file not found: {resolved}")
    with open(resolved, encoding="utf-8") as fh:
        data = json.load(fh)
    if not cell_tuples:
        raise RuntimeError("from_file reference: field has no cells")
    nd = len(cell_tuples[0])
    exts = [max(c[d] for c in cell_tuples) for d in range(nd)]
    return [_nested_at(data, c, exts) for c in cell_tuples]


@dataclass
class SimulatedStates:
    """States of one simulation sampled at requested times: ``states[k]`` is
    the flat state vector at ``times[k]``; ``var_map`` maps each element name
    (``"Heat.u[3]"``) to its row in that vector.

    ``problem`` is the built :class:`~earthsci_ast.problem.EsmProblem` the run
    came from, kept so an assertion on a STATE-DEPENDENT array observed can
    replay that observed's own expression at a trajectory sample
    (:func:`~earthsci_ast.simulation_array.observed_at_state`) — such a value is
    in neither the state vector nor any build-time product. ``None`` for a
    caller that built the states some other way."""

    times: list[float]
    states: list[np.ndarray]
    var_map: dict[str, int]
    problem: Any = None


def _scope_to_component(
    overrides: dict[str, float] | None, model_name: str, file: EsmFile
) -> dict[str, float]:
    """Qualify a test's override keys with the component that OWNS the test.

    esm-spec §6.6.2 keys `parameter_overrides` / `initial_conditions` by LOCAL
    name — local to the *enclosing component*, since a test "exercises one model
    in isolation" (§6.6). The runner hands them to :func:`~earthsci_ast.problem.esm_problem`, which
    resolves against the WHOLE flattened document, where that locality is gone:
    two mounted components that each declare a `T` flatten to `M1.T` / `M2.T`,
    and the bare `T` in `M2`'s test is then ambiguous document-wide even though
    it is unambiguous where it was written.

    So re-attach the scope the runner still knows: a key whose
    ``<model>.<key>`` form names a real variable of the flattened system is
    rewritten to it. A key that does not (already qualified, a scoped reference
    the prefix would double up, or simply wrong) is passed through untouched, so
    `esm_problem` reports on it exactly as it would have.

    This is what makes the runner's answer differ from handing the authored
    map to :func:`~earthsci_ast.problem.esm_problem` raw and letting bare-name
    resolution find it. The scoped spelling is fully qualified, which is an
    EXACT hit under the forward, longest-dotted-suffix resolution of esm-spec
    §6.6.2 rule 2 — so the two rules agree here rather than compete, and the
    scoped one additionally survives a document where a sibling component
    declares the same bare name. A seed supplied by an
    :class:`InlineTestOptions` callback is merged onto the authored map
    before this runs, so it is keyed and scoped by the same rule.
    """
    if not overrides:
        return {}
    try:
        flat = flatten(file)
    except Exception:  # noqa: BLE001 — let `esm_problem` report the real failure
        return dict(overrides)
    known = set(flat.parameters) | set(flat.state_variables)
    out: dict[str, float] = {}
    for key, value in overrides.items():
        qualified = f"{model_name}.{key}"
        out[qualified if qualified in known else key] = value
    return out


def simulate_states(
    file: EsmFile,
    tspan: tuple[float, float],
    *,
    method: str | None = None,
    rtol: float | None = None,
    atol: float | None = None,
    saveat: Sequence[float],
    parameters: dict[str, float] | None = None,
    initial_conditions: dict[str, float] | None = None,
    cse: bool = True,
    inspect: BuildInspection | None = None,
) -> SimulatedStates:
    """Run the official :func:`earthsci_ast.problem.solve` pathway
    and sample the trajectory at each time of ``saveat`` (which must lie on
    the solver's output grid to within ``1e-9 · max(1, |t|)`` — trajectory
    output is dense over ``tspan``, so span endpoints always qualify).
    Raises :class:`RuntimeError` when the solve does not return
    :attr:`~earthsci_ast.simulation_common.ReturnCode.Success`.

    ``inspect`` is forwarded to :func:`~earthsci_ast.problem.esm_problem` — an
    optional :class:`~earthsci_ast.simulation.BuildInspection` sink the NumPy
    pathway fills with the build-time setup arrays / observed map (results
    are identical with or without it).

    ``cse`` is forwarded too. It is the right-hand-side build's
    common-subexpression elimination, and it is a knob rather than a constant
    because a large enough document can make the CSE pass itself the
    expensive part of a build that is then run once — so a corpus gate that
    is memory- or time-bounded per document needs to be able to say
    ``cse=False``. It does not change what is computed."""
    prob = esm_problem(
        file,
        tspan,
        p=dict(parameters or {}),
        u0=dict(initial_conditions or {}),
        cse=cse,
        inspect=inspect,
    )
    # esm-spec §2.2.2, most-specific first: an explicit `rtol` / `atol` here
    # wins, else this document's `solver` block, else the runner's own
    # TEST_RELTOL / TEST_ABSTOL. The runner values sit at the BOTTOM of the
    # chain — they are binding defaults, not a caller's opinion — so a stiff
    # document can ask for its own integration accuracy without every caller
    # naming it. They are still what an assertion-bearing test gets by default,
    # which is the property the comment on TEST_RELTOL is about.
    #
    # Note this is the INTEGRATION tolerance. The tolerance each assertion is
    # COMPARED at is resolved separately (§6.6.4) and is untouched here.
    eff_rtol, eff_atol = _integration_tolerances(file, rtol, atol)
    result = solve(prob, alg=_method_for(method, file), reltol=eff_rtol, abstol=eff_atol)
    if result.retcode is not ReturnCode.Success:
        raise RuntimeError(f"solve returned {result.retcode.value}: {result.message}")
    var_map = {str(name): i for i, name in enumerate(result.vars)}
    times: list[float] = []
    states: list[np.ndarray] = []
    for t in saveat:
        ti = int(np.argmin(np.abs(result.t - float(t))))
        if abs(float(result.t[ti]) - float(t)) > _SAVEAT_MATCH_TOL * max(1.0, abs(float(t))):
            raise RuntimeError(f"no saved state at t={t} (nearest {float(result.t[ti])})")
        times.append(float(result.t[ti]))
        states.append(np.asarray(result.y[:, ti], dtype=float))
    return SimulatedStates(times=times, states=states, var_map=var_map, problem=prob)


def _resolve_tolerance(
    model_tol: Tolerance | None,
    test_tol: Tolerance | None,
    assertion_tol: Tolerance | None,
) -> tuple[float, float]:
    """esm-spec §6.6.4 precedence: assertion > test > model > default
    ``rel=1e-6`` (identical to the Julia run_tests reference)."""
    for candidate in (assertion_tol, test_tol, model_tol):
        if candidate is None:
            continue
        rel = 0.0 if candidate.rel is None else float(candidate.rel)
        abs_ = 0.0 if candidate.abs is None else float(candidate.abs)
        return (rel, abs_)
    return (_DEFAULT_REL_TOL, 0.0)


def _check_assertion(actual: float, expected: float, rtol: float, atol: float) -> bool:
    """The esm-spec §6.6.3 pass predicate — ``actual == expected``, or both
    values FINITE and ``|a − e| ≤ max(atol, rtol·max(|a|, |e|))`` (see also
    CONFORMANCE_SPEC §5.20). This is Julia ``isapprox``.

    **The relative bound is SYMMETRIC** in ``actual`` and ``expected``: its
    scale is ``max(|a|, |e|)``, the larger of the two magnitudes, not ``|e|``
    alone. §6.6.3 used to state both readings at once — the normative box gave
    an ``|expected|``-only denominator while the finiteness rationale further
    down that same section reasoned from ``max(|inf|, |expected|)`` — and this
    function was written against the second. EarthSciML/EarthSciAST#193 settled
    the spec as symmetric, so the two now agree and this line is normative
    rather than merely conventional. The verdicts differ only inside
    ``rtol*|e| < |a − e| <= rtol*|a|``, which needs an overshoot
    (``|actual| > |expected|``) of order ``rtol``;
    ``test_relative_bound_is_symmetric_in_actual_and_expected`` pins that seam.

    **Finiteness is judged BEFORE tolerance**, and that clause is not a
    corollary of the bound — it contradicts it. With ``actual = ±inf`` both
    sides of ``|actual − expected| <= max(atol, rtol*max(|actual|, |expected|))``
    are ``inf``, so the comparison held for EVERY finite ``expected``: an
    assertion on an overflowed product, a division by a zero denominator or a
    ``log(0)`` reported PASS whatever it expected. NaN never had the problem
    (every IEEE-754 comparison with NaN is false), which is why the hole was
    specific to an infinity. Julia's ``isapprox`` — the semantics this
    docstring claims — has always carried the guard
    (``x == y || (isfinite(x) && isfinite(y) && ...)``).

    ``actual == expected`` keeps the one case a non-finite value legitimately
    matches: the SAME infinity, with the same sign. An ``.esm`` document cannot
    spell an infinite ``expected`` (JSON has no infinite literal), so within a
    document the rule reduces to "a non-finite actual always fails". It also
    keeps the zero-tolerance exact-equality mode, and ``-0.0 == 0.0`` under
    IEEE-754, so a signed zero is unaffected.
    """
    a = float(actual)
    e = float(expected)
    if a == e:
        return True
    if not (math.isfinite(a) and math.isfinite(e)):
        return False
    if rtol == 0.0 and atol == 0.0:
        # Exact-equality mode; the equality above already answered it.
        return False
    return abs(a - e) <= max(atol, rtol * max(abs(a), abs(e)))


def _ephemeral_injected_file(
    file: EsmFile,
    source_path: str | None,
    mname: str,
    imports: list[Any],
    base_dir: str,
) -> EsmFile:
    """esm-spec §9.7.10 form C: build a throwaway :class:`EsmFile` in which
    component ``mname`` has the test's ``imports`` (raw §9.7.2 entries) appended
    to its own ``expression_template_imports``, so the ordinary import resolver
    + §9.6.3 fixpoint lower its rewrite-targets under the test-chosen
    discretization. The persisted ``file`` is never mutated.

    The raw base is re-read from ``source_path`` when the runner input was a
    path (relative ``ref``\\ s resolve against its directory), else re-serialized
    from the loaded ``file`` (``base_dir`` anchors the injected ``ref``\\ s).
    This is what lets one test suite exercise a discretization-agnostic PDE leaf
    under several schemes with no conflict between tests. Mirrors the Julia
    reference ``_ephemeral_injected_file``."""
    from .serialize import _serialize_esm_file

    if source_path is not None:
        with open(source_path, encoding="utf-8") as fh:
            raw = json.load(fh)
    else:
        raw = _serialize_esm_file(file)

    injected = False
    for kind in ("models", "reaction_systems"):
        comps = raw.get(kind)
        if not isinstance(comps, dict) or mname not in comps:
            continue
        comp = comps[mname]
        if not isinstance(comp, dict):
            continue
        existing = comp.get("expression_template_imports")
        base = list(existing) if isinstance(existing, list) else []
        for e in imports:
            base.append(copy.deepcopy(e))
        comp["expression_template_imports"] = base
        injected = True
        break
    if not injected:
        raise ValueError(f"component '{mname}' not found for per-test injection (esm-spec §9.7.10)")
    return load_string(json.dumps(raw), base_path=str(base_dir))


def _result(
    mname: Any,
    test: Any,
    idx: int,
    assertion: Any,
    a_rtol: float,
    a_atol: float,
    actual: float | None,
    passed: bool,
    message: str,
) -> AssertionResult:
    """Build one :class:`AssertionResult`, filling the assertion-identity
    fields (model / test / index / variable / time / reduce / expected) from
    the ``test`` + ``assertion`` and taking the outcome fields verbatim. The
    three result sites of :func:`run_inline_tests` share this shape."""
    return AssertionResult(
        str(mname),
        test.id,
        idx,
        assertion.variable,
        assertion.time,
        assertion.reduce,
        assertion.expected,
        actual,
        a_rtol,
        a_atol,
        passed,
        message,
    )


def _evaluate_assertion(
    assertion: Any,
    sim: SimulatedStates,
    times: list[float],
    mname: Any,
    eval_file: EsmFile,
    insp: BuildInspection,
    resolved_base: str,
) -> tuple[float | None, str]:
    """Evaluate one §6.6.5 assertion against an already-run simulation,
    returning ``(actual, message)`` — the computed sample / reduction value
    (``None`` on failure) and any error text. Point-samples per ``coords``,
    collapses per ``reduce`` (evaluating an analytic or ``from_file``
    ``reference`` for the error norms), or reads a scalar state when the
    assertion has neither. The per-assertion body of :func:`run_inline_tests`."""
    a = assertion
    actual: float | None = None
    msg = ""
    try:
        ti = times.index(float(a.time))
        state = sim.states[ti]
        if a.coords is not None and a.reduce is not None:
            raise RuntimeError("`coords` and `reduce` are mutually exclusive")
        if a.coords is None and a.reduce is None:
            slot = _scalar_slot(sim.var_map, a.variable, str(mname))
            if slot is None:
                raise RuntimeError(f"scalar state '{a.variable}' not found")
            actual = float(state[slot])
        else:
            # `coords` validation runs BEFORE field
            # materialization so a coords assertion on a scalar
            # variable fails with the §6.6.5 coords-specific
            # message (identical to the Julia reference).
            coords_target: list[int] | None = None
            if a.coords is not None:
                shape = _variable_shape(eval_file, str(mname), str(a.variable))
                coords_target = _coords_cell(a.coords, shape, eval_file.index_sets)
            cells = state_cells(sim.var_map, a.variable, str(mname))
            if cells:
                cell_tuples = [c for c, _ in cells]
                field = [float(state[slot]) for _, slot in cells]
            else:
                # §6.6.5 observed-assertion form: the asserted
                # variable is an ARRAY OBSERVED, which carries no
                # ODE slot. Two sources, cheapest first:
                #   * the build inspection's setup arrays — a
                #     STATE-FREE observed the const-geometry hoist
                #     already materialized (the MPAS rule output
                #     div_flux max/min);
                #   * failing that, the observed's own expression
                #     replayed at this trajectory sample, which is
                #     the only source for a STATE-DEPENDENT one
                #     (`dudt = D(D(u,lev),lev)`, `g = 2*u`): its
                #     value moves with the state, so no build-time
                #     product can carry it and the output-node
                #     reconstruction skips it for not being a
                #     scalar row. §6.6.5 admits ANY shaped variable
                #     here, and §5.23 makes a reference denote its
                #     expansion, so both are readable.
                # Both sources resolve a bare name across the whole
                # flattened build, so the ASSERTED component must be
                # the one that declares the observed (§5.27.1);
                # otherwise a sibling's field answers silently.
                obs = None
                if _declares_observed(eval_file, str(mname), a.variable):
                    obs = _inspection_field(insp, str(mname), a.variable)
                    if obs is None:
                        obs = _observed_sample(sim, str(mname), a.variable, state, times[ti])
                if obs is None:
                    raise RuntimeError(
                        f"array state '{a.variable}' has no cells "
                        f"in var_map, and no array observed of "
                        f"that name is exposed by the build or "
                        f"evaluable at the assertion time"
                    )
                idxs = list(np.ndindex(*obs.shape))
                cell_tuples = [[int(i) + 1 for i in idx] for idx in idxs]
                field = [float(obs[idx]) for idx in idxs]
            if coords_target is not None:
                try:
                    pos = cell_tuples.index(coords_target)
                except ValueError:
                    raise RuntimeError(
                        f"no grid sample at cell "
                        f"[{','.join(str(c) for c in coords_target)}]"
                        f" of '{a.variable}'"
                    ) from None
                actual = float(field[pos])
            else:
                ref = None
                if a.reference is not None:
                    if isinstance(a.reference, dict) and a.reference.get("type") == "from_file":
                        ref = _from_file_reference(a.reference, resolved_base, cell_tuples)
                    elif isinstance(a.reference, (ExprNode, int, float, str)):
                        # Model parameters (load-time constants) are
                        # in scope for a §6.6.5 analytic reference;
                        # state is not. `insp.params` carries the
                        # build's resolved scalar params. The field's
                        # dimension names are in scope too, bound per
                        # cell (`bind_dimension_names`).
                        try:
                            dims = _variable_shape(eval_file, str(mname), str(a.variable))
                        except RuntimeError:
                            dims = []
                        scope = _param_scope_with_aliases(insp.params)
                        ref = evaluate_cellwise(
                            bind_dimension_names(a.reference, dims, scope),
                            cell_tuples,
                            index_sets=eval_file.index_sets,
                            params=scope,
                        )
                    else:
                        raise RuntimeError(f"unsupported `reference` shape {type(a.reference)}")
                actual = field_reduce(a.reduce, field, reference=ref)
    except Exception as err:  # noqa: BLE001 — recorded per assertion
        msg = f"assertion evaluation failed: {err}"
    return actual, msg


def _run_document_tests(
    file: EsmFile,
    source: str | None,
    opts: _ResolvedOptions,
    results: list[AssertionResult],
) -> None:
    """Run one document's inline tests, appending to ``results``.

    ``source`` is the path the document was loaded from, or ``None`` for an
    already-loaded :class:`EsmFile` — it anchors ``from_file`` references and
    the §9.7.10 per-test injection. The per-document body of
    :func:`run_inline_tests`."""
    # esm-spec §9.5.3 lowering, ahead of the per-test builds. `esm_problem`
    # lowers the document it builds, but a §6.6.5 assertion's analytic
    # `reference` is evaluated HERE, off that path — so a `table_lookup` in a
    # reference would otherwise reach `evaluate_cellwise`, which cannot
    # evaluate it. Pure, so the caller's EsmFile keeps its authored form.
    file = lower_table_lookups(file)
    if opts.base_dir is not None:
        resolved_base = str(opts.base_dir)
    elif source is not None and os.path.isfile(source):
        # `load_path` needs a real path; only a real path anchors
        # from_file references at the .esm file's directory.
        resolved_base = os.path.dirname(os.path.abspath(source))
    else:
        resolved_base = os.getcwd()
    # esm-spec §2.2.2, most-specific first: an `options_for` override, then the
    # call-level argument, then THIS DOCUMENT's `solver` block, then the runner
    # defaults. `opts.rtol` / `opts.atol` already carry the first two folded
    # together — `None` there means neither was named — so this call appends the
    # last two. Same chain for `method` via `_method_for` at the solve below
    # (§2.2.3, where the document speaks through `solver.stiffness`).
    #
    # These are INTEGRATION tolerances; the tolerance each assertion is COMPARED
    # at resolves separately (§6.6.4) and is untouched here.
    doc_rtol, doc_atol = _integration_tolerances(file, opts.rtol, opts.atol)
    for mname, component in _test_components(file, opts.model_name):
        for t in component.tests:
            times = sorted({float(a.time) for a in t.assertions})
            sim: SimulatedStates | None = None
            sim_err = ""
            # esm-spec §9.7.10 form C: a test that injects a discretization runs
            # against an EPHEMERAL instance of this component with the test's
            # imports appended to its scope and its rewrite-targets lowered; the
            # persisted `file` is untouched. A test with no injection runs
            # against the file as loaded.
            run_file: EsmFile | None = file
            run_component = component
            if t.expression_template_imports:
                try:
                    run_file = _ephemeral_injected_file(
                        file, source, mname, t.expression_template_imports, resolved_base
                    )
                    rm = (run_file.models or {}).get(mname) or (
                        run_file.reaction_systems or {}
                    ).get(mname)
                    if rm is None:
                        raise RuntimeError(f"component '{mname}' vanished from the ephemeral build")
                    run_component = rm
                except Exception as err:  # noqa: BLE001 — recorded per assertion
                    sim_err = f"per-test discretization injection failed: {err}"
                    run_file = None
            # Build inspection sink: a §6.6.5 assertion may target a
            # state-free ARRAY OBSERVED (the observed-assertion form); its
            # field is read from the setup arrays the build materializes.
            insp = BuildInspection()
            if run_file is not None:
                try:
                    # The caller's seeds go UNDER the test's own maps — the
                    # document is authoritative about its own test and the
                    # seed supplies only what the document left unsaid — and
                    # the merge happens BEFORE scoping, so a seed key and a
                    # test key that name the same variable collide on the one
                    # spelling and the test's value wins. Merging after
                    # scoping would instead hand the build BOTH `T` and
                    # `M.T`, two keys designating one parameter with two
                    # values.
                    sim = simulate_states(
                        run_file,
                        (t.time_span.start, t.time_span.end),
                        method=_method_for(opts.method, run_file),
                        rtol=doc_rtol,
                        atol=doc_atol,
                        saveat=times,
                        parameters=_scope_to_component(
                            {**dict(opts.parameter_overrides), **(t.parameter_overrides or {})},
                            mname,
                            run_file,
                        ),
                        initial_conditions=_scope_to_component(
                            {**dict(opts.initial_conditions), **(t.initial_conditions or {})},
                            mname,
                            run_file,
                        ),
                        cse=opts.cse,
                        inspect=insp,
                    )
                except Exception as err:  # noqa: BLE001 — recorded per assertion
                    sim_err = f"solve failed: {err}"
                    sim = None
            eval_file = file if run_file is None else run_file
            for i, a in enumerate(t.assertions, start=1):
                a_rtol, a_atol = _resolve_tolerance(
                    run_component.tolerance, t.tolerance, a.tolerance
                )
                if sim is None:
                    results.append(_result(mname, t, i, a, a_rtol, a_atol, None, False, sim_err))
                    continue
                actual, msg = _evaluate_assertion(
                    a, sim, times, mname, eval_file, insp, resolved_base
                )
                if actual is None:
                    results.append(_result(mname, t, i, a, a_rtol, a_atol, None, False, msg))
                else:
                    ok = _check_assertion(actual, a.expected, a_rtol, a_atol)
                    if not ok:
                        msg = (
                            f"actual={actual} expected={a.expected} (rtol={a_rtol}, atol={a_atol})"
                        )
                    results.append(_result(mname, t, i, a, a_rtol, a_atol, actual, ok, msg))


def _esm_files_under(directory: str) -> list[str]:
    """Every ``.esm`` document under ``directory``, recursively, sorted.

    Sorted because a result list whose ORDER depends on the filesystem is not
    comparable between two runs, let alone between two machines."""
    return sorted(glob.glob(os.path.join(directory, "**", "*.esm"), recursive=True))


def _expand_inputs(inputs: Any) -> list[str | EsmFile]:
    """Resolve :func:`run_inline_tests`'s ``inputs`` to a flat list of
    documents: a path stays a path, a directory expands to the ``.esm`` files
    under it, an :class:`EsmFile` stays itself.

    A ``str`` and an :class:`EsmFile` are SINGLE inputs — neither is iterated
    element-wise, which for a string would otherwise silently mean "one
    document per character"."""
    if isinstance(inputs, (str, os.PathLike, EsmFile)):
        items: list[Any] = [inputs]
    elif isinstance(inputs, Iterable):
        items = list(inputs)
    else:
        raise TypeError(
            f"run_inline_tests expects a path, an EsmFile, a directory or an "
            f"iterable of those, got {type(inputs)}"
        )
    out: list[str | EsmFile] = []
    for item in items:
        if isinstance(item, EsmFile):
            out.append(item)
        elif isinstance(item, (str, os.PathLike)):
            path = os.fspath(item)
            out.extend(_esm_files_under(path) if os.path.isdir(path) else [path])
        else:
            raise TypeError(f"run_inline_tests: {type(item)} is not a path or EsmFile")
    return out


def _load_failure_result(source: str, err: Exception) -> AssertionResult:
    """The one ERROR row a document that could not be LOADED contributes to a
    batch.

    A corpus run must not lose a file to one bad document, and it must not
    lose it SILENTLY either — a document that vanishes from the result list
    is indistinguishable from one that passed. So the failure becomes a row,
    the same way every other failure in this runner becomes a row. The shape
    mirrors the Julia binding's existing ``<parse>`` / ``<load>`` row."""
    return AssertionResult(
        source,
        "<load>",
        0,
        "",
        math.nan,
        None,
        math.nan,
        None,
        0.0,
        0.0,
        False,
        f"load failed: {err}",
    )


def _fold_options(
    override: InlineTestOptions | None,
    *,
    model_name: str | None,
    method: str | None,
    rtol: float | None,
    atol: float | None,
    base_dir: str | None,
    cse: bool,
) -> _ResolvedOptions:
    """Fold one document's :class:`InlineTestOptions` onto the call-level
    defaults: a field the override left ``None`` inherits, every other field
    wins. ``None`` for the whole record means "inherit everything"."""
    if override is None:
        return _ResolvedOptions(
            model_name=model_name,
            method=method,
            rtol=rtol,
            atol=atol,
            base_dir=base_dir,
            cse=cse,
        )
    if not isinstance(override, InlineTestOptions):
        raise TypeError(
            f"options_for must return an InlineTestOptions or None, got {type(override)}"
        )
    return _ResolvedOptions(
        model_name=model_name if override.model_name is None else override.model_name,
        method=method if override.method is None else override.method,
        rtol=rtol if override.rtol is None else float(override.rtol),
        atol=atol if override.atol is None else float(override.atol),
        base_dir=base_dir if override.base_dir is None else override.base_dir,
        cse=cse if override.cse is None else bool(override.cse),
        initial_conditions=dict(override.initial_conditions or {}),
        parameter_overrides=dict(override.parameter_overrides or {}),
    )


def run_inline_tests(
    inputs: str | EsmFile | Iterable[str | EsmFile],
    *,
    model_name: str | None = None,
    method: str | None = None,
    rtol: float | None = None,
    atol: float | None = None,
    base_dir: str | None = None,
    cse: bool = True,
    options_for: Callable[[Any], InlineTestOptions | None] | None = None,
) -> list[AssertionResult]:
    """Run every inline test (esm-spec §6.6, including the §6.6.5 PDE
    assertions) of the selected component(s) of ``inputs`` through the
    official NumPy simulation pathway, and return one
    :class:`AssertionResult` per assertion — carrying the ACTUAL reduction
    value alongside pass/fail, so conformance harnesses can record and
    cross-compare the numbers.

    ``inputs`` is a path to a ``.esm`` file, a loaded :class:`EsmFile`, a
    DIRECTORY (walked recursively for ``*.esm``, sorted), or any iterable of
    those. Results are concatenated in input order.

    Both kinds of test-bearing component are run: ``models`` first, then
    ``reaction_systems``, which the schema gives the same ``tests`` member and
    which this runner skipped entirely until it was fixed.

    Per test: simulate over the test's ``time_span`` (with its
    ``initial_conditions`` / ``parameter_overrides`` applied, ``method`` /
    ``rtol`` / ``atol`` pinning scipy's ``solve_ivp``); then per assertion the
    asserted variable's field is read at the assertion time and either
    point-sampled per its ``coords`` (positions in 1-based INDEX space;
    nearest grid index, exact ties rounding DOWN — the pinned cross-binding
    convention) or collapsed per its ``reduce`` (error norms evaluate the
    ``reference`` — an analytic expression cellwise via
    :func:`evaluate_cellwise`, or a ``{type: "from_file", path, format?}``
    JSON snapshot resolved against ``base_dir``). An assertion with neither
    ``coords`` nor ``reduce`` samples a scalar state. ``base_dir`` defaults
    to the .esm file's directory when the document came from a path, else the
    working directory. Mirrors the Julia binding's ``run_inline_tests`` 1:1
    (tolerances per §6.6.4; the pass predicate is Julia ``isapprox``).

    ``options_for`` is the seam for site-specific policy. It is called once
    per resolved document — with the document's path when it came from one,
    else the :class:`EsmFile`, and BEFORE the document is loaded, so a
    basename-keyed callback is asked about an unreadable file too and wants a
    default rather than a lookup error — and returns an
    :class:`InlineTestOptions`
    whose non-``None`` fields override the arguments above for that document
    (or ``None`` to change nothing). It exists so that a corpus gate's
    basename-keyed tables — a stiff-solver map, a ``cse`` allowlist, an
    initial-condition seed — can stay in the gate instead of forcing it to
    re-implement §6.6 to get at them.

    ``method`` / ``rtol`` / ``atol`` default to ``None``, and that is load
    bearing rather than merely tidy: it is what keeps the DOCUMENT's own
    opinion expressible. Each resolves most-specific first — an ``options_for``
    override, then the argument here, then this document's ``solver`` block
    (``solver.stiffness`` for the method per esm-spec §2.2.3,
    ``solver.reltol`` / ``solver.abstol`` for the tolerances per §2.2.2), then
    this runner's own :data:`TEST_RELTOL` / :data:`TEST_ABSTOL` and
    :data:`DEFAULT_METHOD`. The runner values sit at the BOTTOM of the chain
    because they are binding defaults, not a caller's opinion, so a stiff
    document gets the integration accuracy it asked for without every caller
    naming it. Passing a value explicitly overrides the document, which is why
    a concrete default here would silently have suppressed it. These are
    INTEGRATION tolerances; the tolerance each assertion is COMPARED at is the
    separate §6.6.4 quantity and is untouched.

    A document that fails to LOAD raises when ``inputs`` names a single
    document, exactly as before. In a BATCH — an iterable or a directory — it
    instead contributes one ERROR row naming the path, so one unreadable file
    cannot cost the run every other file's verdicts.
    """
    documents = _expand_inputs(inputs)
    batch = not isinstance(inputs, EsmFile) and not (
        isinstance(inputs, (str, os.PathLike)) and not os.path.isdir(os.fspath(inputs))
    )
    results: list[AssertionResult] = []
    for document in documents:
        override = options_for(document) if options_for is not None else None
        opts = _fold_options(
            override,
            model_name=model_name,
            method=method,
            rtol=rtol,
            atol=atol,
            base_dir=base_dir,
            cse=cse,
        )
        if isinstance(document, EsmFile):
            _run_document_tests(document, None, opts, results)
            continue
        try:
            file = load_path(document)
        except Exception as err:  # noqa: BLE001 — one bad file must not end a batch
            if not batch:
                raise
            results.append(_load_failure_result(document, err))
            continue
        if not isinstance(file, EsmFile):
            raise TypeError(f"run_inline_tests expects a path or EsmFile, got {type(document)}")
        _run_document_tests(file, document, opts, results)
    return results


__all__ = [
    "InlineTestOptions",
    "AssertionResult",
    "SimulatedStates",
    "bind_dimension_names",
    "evaluate_cellwise",
    "field_reduce",
    "run_inline_tests",
    "simulate_states",
    "state_cells",
]
