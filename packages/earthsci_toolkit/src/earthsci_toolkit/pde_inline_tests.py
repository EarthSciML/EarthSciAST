"""pde_inline_tests — the §6.6.5-capable inline-test runner over the NumPy
simulation pathway (the Python mirror of the Julia binding's
``pde_inline_tests.jl``).

A PDE model's inline tests (esm-spec §6.6.5) assert REDUCTIONS of a spatial
field — ``reduce: L2_error | Linf_error`` against an analytic ``reference``
expression, or the pure collapsers ``mean | max | min`` — rather than scalar
point samples. This module drives the official NumPy tree-walk pipeline
(:func:`earthsci_toolkit.simulation.simulate` over the array-op interpreter)
and collapses fields per assertion.

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
- :func:`run_pde_tests` — run every inline test of the selected model(s);
  returns per-assertion results carrying the ACTUAL reduction values
  (conformance runners record these).
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Any, Dict, List, Optional, Sequence, Tuple, Union

import numpy as np

from .esm_types import EsmFile, Expr, ExprNode, Tolerance
from .parse import load
from .simulation import _eval_buildtime_field, simulate

# esm-spec §6.6.4: the default tolerance when neither the assertion, its test,
# nor the model declares one (same constant as the Julia run_tests reference).
_DEFAULT_REL_TOL = 1e-6

_CELL_NAME_RE = re.compile(r"^(.+)\[([0-9,]+)\]$")


@dataclass
class PdeAssertionResult:
    """Outcome of one §6.6.5 inline-test assertion evaluated through the
    NumPy simulation pathway. ``actual`` is the computed reduction value
    (``None`` when the simulation or reduction itself failed); ``message``
    carries the diff or error text for non-passing results."""

    model: str
    test_id: str
    assertion_idx: int
    variable: str
    time: float
    reduce: Optional[str]
    expected: float
    actual: Optional[float]
    rtol: float
    atol: float
    passed: bool
    message: str


def evaluate_cellwise(
    expr: Expr,
    cells: Sequence[Sequence[int]],
    index_sets: Optional[Dict[str, Any]] = None,
) -> List[float]:
    """Evaluate an array-valued expression (elementwise ops over
    array-producing ``aggregate``/``makearray`` nodes — e.g. a grid-geometry
    template expanded by a §9.7 import, or a §6.6.5 analytic ``reference``)
    at each 1-based integer cell of ``cells``, returning one float per cell.

    This is the public entry to the same build-time machinery the evaluator
    uses to seed coordinate-expression ``ic`` fields
    (:func:`earthsci_toolkit.simulation._eval_buildtime_field`); state
    references are not in scope. A scalar (const-folded) result broadcasts.
    """
    value = _eval_buildtime_field(expr, index_sets=index_sets)
    if np.ndim(value) == 0:
        return [float(value)] * len(cells)
    arr = np.asarray(value, dtype=float)
    out: List[float] = []
    for cell in cells:
        if len(cell) != arr.ndim:
            raise ValueError(
                f"evaluate_cellwise: cell {tuple(cell)} has {len(cell)} indices "
                f"but the field has ndim={arr.ndim}"
            )
        out.append(float(arr[tuple(int(c) - 1 for c in cell)]))
    return out


def field_reduce(
    kind: str,
    actual: Sequence[float],
    reference: Optional[Sequence[float]] = None,
) -> float:
    """Collapse a spatial field to the scalar a §6.6.5 ``reduce`` assertion
    compares (esm-spec §6.6.5); semantics identical to the Julia reference:

    - ``"L2_error"``  — ``‖actual − reference‖₂ / ‖reference‖₂`` (relative L2
      over the domain; requires ``reference``).
    - ``"Linf_error"`` — ``max |actual − reference|`` (absolute supremum norm;
      requires ``reference``).
    - ``"mean" | "max" | "min"`` — pure collapsers of ``actual``.

    ``"integral"`` requires the grid measure and is not implemented here.
    """
    k = str(kind)
    a = np.asarray(actual, dtype=float)
    if k in ("L2_error", "Linf_error"):
        if reference is None:
            raise ValueError(f"field_reduce: `{k}` requires a reference field")
        r = np.asarray(reference, dtype=float)
        if r.shape != a.shape:
            raise ValueError(
                f"field_reduce: actual has {a.size} cells but reference has {r.size}"
            )
        diff = a - r
        if k == "L2_error":
            refnorm = float(np.sqrt(np.sum(r * r)))
            if refnorm == 0.0:
                raise ValueError("field_reduce: L2_error reference has zero norm")
            return float(np.sqrt(np.sum(diff * diff)) / refnorm)
        return float(np.max(np.abs(diff)))
    if k == "mean":
        if a.size == 0:
            raise ValueError("field_reduce: empty field")
        return float(np.sum(a) / a.size)
    if k == "max":
        return float(np.max(a))
    if k == "min":
        return float(np.min(a))
    raise ValueError(f"field_reduce: unsupported reduce kind '{k}'")


def state_cells(
    var_map: Dict[str, int],
    variable: str,
    model: str,
) -> List[Tuple[List[int], int]]:
    """Collect the (cell-index-tuple, flat-slot) pairs of one array state from
    a ``var_map`` (element name → row/slot). Flattening may prefix element
    names with the owning model (``"Heat.u[3]"``); a name matches when its
    element stem equals ``variable`` bare, or ``model.variable`` qualified.
    Sorted by cell tuple so callers get a deterministic pairing (identical to
    the Julia reference's ``_state_cells``)."""
    out: List[Tuple[List[int], int]] = []
    qualified = f"{model}.{variable}"
    for name, slot in var_map.items():
        m = _CELL_NAME_RE.match(str(name))
        if m is None:
            continue
        stem = m.group(1)
        bare = stem.split(".", 1)[1] if "." in stem else stem
        if stem not in (qualified, variable) and bare != variable:
            continue
        out.append(([int(x) for x in m.group(2).split(",")], int(slot)))
    out.sort(key=lambda p: p[0])
    return out


def _scalar_slot(var_map: Dict[str, int], variable: str, model: str) -> Optional[int]:
    """Flat slot of a SCALAR state by bare or model-qualified name."""
    qualified = f"{model}.{variable}"
    for name, slot in var_map.items():
        s = str(name)
        bare = s.split(".", 1)[1] if "." in s else s
        if s in (qualified, variable) or bare == variable:
            return int(slot)
    return None


@dataclass
class SimulatedStates:
    """States of one simulation sampled at requested times: ``states[k]`` is
    the flat state vector at ``times[k]``; ``var_map`` maps each element name
    (``"Heat.u[3]"``) to its row in that vector."""

    times: List[float]
    states: List[np.ndarray]
    var_map: Dict[str, int]


def simulate_states(
    file: EsmFile,
    tspan: Tuple[float, float],
    *,
    method: str = "RK45",
    rtol: float = 1e-10,
    atol: float = 1e-12,
    saveat: Sequence[float],
    parameters: Optional[Dict[str, float]] = None,
    initial_conditions: Optional[Dict[str, float]] = None,
) -> SimulatedStates:
    """Run the official :func:`earthsci_toolkit.simulation.simulate` pathway
    and sample the trajectory at each time of ``saveat`` (which must lie on
    the solver's output grid to within ``1e-9 · max(1, |t|)`` — trajectory
    output is dense over ``tspan``, so span endpoints always qualify).
    Raises :class:`RuntimeError` when the solve fails."""
    result = simulate(
        file, tspan,
        parameters=dict(parameters or {}),
        initial_conditions=dict(initial_conditions or {}),
        method=method, rtol=rtol, atol=atol,
    )
    if not result.success:
        raise RuntimeError(f"simulate failed: {result.message}")
    var_map = {str(name): i for i, name in enumerate(result.vars)}
    times: List[float] = []
    states: List[np.ndarray] = []
    for t in saveat:
        ti = int(np.argmin(np.abs(result.t - float(t))))
        if abs(float(result.t[ti]) - float(t)) > 1e-9 * max(1.0, abs(float(t))):
            raise RuntimeError(
                f"no saved state at t={t} (nearest {float(result.t[ti])})"
            )
        times.append(float(result.t[ti]))
        states.append(np.asarray(result.y[:, ti], dtype=float))
    return SimulatedStates(times=times, states=states, var_map=var_map)


def _resolve_tolerance(
    model_tol: Optional[Tolerance],
    test_tol: Optional[Tolerance],
    assertion_tol: Optional[Tolerance],
) -> Tuple[float, float]:
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
    """Julia ``isapprox`` semantics: ``|a − e| ≤ max(atol, rtol·max(|a|, |e|))``
    (exact equality when both tolerances are zero)."""
    if rtol == 0.0 and atol == 0.0:
        return float(actual) == float(expected)
    return abs(float(actual) - float(expected)) <= max(
        atol, rtol * max(abs(float(actual)), abs(float(expected)))
    )


def run_pde_tests(
    input: Union[str, EsmFile],
    *,
    model_name: Optional[str] = None,
    method: str = "RK45",
    rtol: float = 1e-10,
    atol: float = 1e-12,
) -> List[PdeAssertionResult]:
    """Run every inline test (esm-spec §6.6, including the §6.6.5 PDE
    assertions) of the selected model(s) of ``input`` (a path or a loaded
    :class:`EsmFile`) through the official NumPy simulation pathway, and
    return one :class:`PdeAssertionResult` per assertion — carrying the ACTUAL
    reduction value alongside pass/fail, so conformance harnesses can record
    and cross-compare the numbers.

    Per test: simulate over the test's ``time_span`` (with its
    ``initial_conditions`` / ``parameter_overrides`` applied, ``method`` /
    ``rtol`` / ``atol`` pinning scipy's ``solve_ivp``); then per assertion the
    asserted variable's field is read at the assertion time and collapsed per
    its ``reduce`` (error norms evaluate the analytic ``reference`` expression
    cellwise via :func:`evaluate_cellwise`). An assertion with neither
    ``coords`` nor ``reduce`` samples a scalar state. ``coords``
    point-sampling and ``from_file`` references are not supported and yield
    failed results with explanatory messages. Mirrors the Julia binding's
    ``run_pde_tests`` 1:1 (tolerances per §6.6.4; the pass predicate is Julia
    ``isapprox``)."""
    file = load(input) if isinstance(input, str) else input
    if not isinstance(file, EsmFile):
        raise TypeError(f"run_pde_tests expects a path or EsmFile, got {type(input)}")
    results: List[PdeAssertionResult] = []
    for mname, model in (file.models or {}).items():
        if model_name is not None and str(mname) != str(model_name):
            continue
        if not model.tests:
            continue
        for t in model.tests:
            times = sorted({float(a.time) for a in t.assertions})
            sim: Optional[SimulatedStates] = None
            sim_err = ""
            try:
                sim = simulate_states(
                    file, (t.time_span.start, t.time_span.end),
                    method=method, rtol=rtol, atol=atol, saveat=times,
                    parameters=t.parameter_overrides,
                    initial_conditions=t.initial_conditions,
                )
            except Exception as err:  # noqa: BLE001 — recorded per assertion
                sim_err = f"simulate failed: {err}"
                sim = None
            for i, a in enumerate(t.assertions, start=1):
                a_rtol, a_atol = _resolve_tolerance(model.tolerance, t.tolerance,
                                                    a.tolerance)
                if sim is None:
                    results.append(PdeAssertionResult(
                        str(mname), t.id, i, a.variable, a.time, a.reduce,
                        a.expected, None, a_rtol, a_atol, False, sim_err))
                    continue
                actual: Optional[float] = None
                msg = ""
                try:
                    ti = times.index(float(a.time))
                    state = sim.states[ti]
                    if a.coords is not None:
                        raise RuntimeError(
                            "`coords` point-sampling is not supported by run_pde_tests")
                    if a.reduce is None:
                        slot = _scalar_slot(sim.var_map, a.variable, str(mname))
                        if slot is None:
                            raise RuntimeError(
                                f"scalar state '{a.variable}' not found")
                        actual = float(state[slot])
                    else:
                        cells = state_cells(sim.var_map, a.variable, str(mname))
                        if not cells:
                            raise RuntimeError(
                                f"array state '{a.variable}' has no cells in var_map")
                        field = [float(state[slot]) for _, slot in cells]
                        ref = None
                        if a.reference is not None:
                            if not isinstance(a.reference, (ExprNode, int, float, str)):
                                raise RuntimeError(
                                    "only inline-expression `reference` is supported "
                                    "(from_file references are not)")
                            ref = evaluate_cellwise(a.reference,
                                                    [c for c, _ in cells],
                                                    index_sets=file.index_sets)
                        actual = field_reduce(a.reduce, field, reference=ref)
                except Exception as err:  # noqa: BLE001 — recorded per assertion
                    msg = f"assertion evaluation failed: {err}"
                if actual is None:
                    results.append(PdeAssertionResult(
                        str(mname), t.id, i, a.variable, a.time, a.reduce,
                        a.expected, None, a_rtol, a_atol, False, msg))
                else:
                    ok = _check_assertion(actual, a.expected, a_rtol, a_atol)
                    if not ok:
                        msg = (f"actual={actual} expected={a.expected} "
                               f"(rtol={a_rtol}, atol={a_atol})")
                    results.append(PdeAssertionResult(
                        str(mname), t.id, i, a.variable, a.time, a.reduce,
                        a.expected, actual, a_rtol, a_atol, ok, msg))
    return results


__all__ = [
    "PdeAssertionResult",
    "SimulatedStates",
    "evaluate_cellwise",
    "field_reduce",
    "run_pde_tests",
    "simulate_states",
    "state_cells",
]
