"""pde_inline_tests — the §6.6.5-capable inline-test runner over the NumPy
simulation pathway (the Python mirror of the Julia binding's
``pde_inline_tests.jl``).

A PDE model's inline tests (esm-spec §6.6.5) assert REDUCTIONS of a spatial
field — ``reduce: L2_error | Linf_error`` against an analytic ``reference``
expression, or the pure collapsers ``integral | mean | max | min`` — or
point-sample it via ``coords``. This module drives the official NumPy
tree-walk pipeline (:func:`earthsci_ast.simulation.simulate` over the
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
- :func:`run_pde_tests` — run every inline test of the selected model(s);
  returns per-assertion results carrying the ACTUAL reduction values
  (conformance runners record these).
"""

from __future__ import annotations

import copy
import json
import math
import os
import re
from collections.abc import Sequence
from dataclasses import dataclass
from typing import Any

import numpy as np

from .esm_types import EsmFile, Expr, ExprNode, Tolerance
from .parse import load
from .simulation import BuildInspection, _eval_buildtime_field, simulate

# esm-spec §6.6.4: the default tolerance when neither the assertion, its test,
# nor the model declares one (same constant as the Julia run_tests reference).
_DEFAULT_REL_TOL = 1e-6

# Default scipy ``solve_ivp`` accuracy for the PDE simulation pathway (the
# solver tolerances the inline-test runs pin unless a caller overrides them).
_DEFAULT_SOLVER_RTOL = 1e-10
_DEFAULT_SOLVER_ATOL = 1e-12

# Relative slack for matching a requested ``saveat`` time to the solver's dense
# output grid (``_SAVEAT_MATCH_TOL · max(1, |t|)``); span endpoints always fit.
_SAVEAT_MATCH_TOL = 1e-9

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
    reduce: str | None
    expected: float
    actual: float | None
    rtol: float
    atol: float
    passed: bool
    message: str


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
    a ``var_map`` (element name → row/slot). Flattening may prefix element
    names with the owning model (``"Heat.u[3]"``); a name matches when its
    element stem equals ``variable`` bare, or ``model.variable`` qualified.
    Sorted by cell tuple so callers get a deterministic pairing (identical to
    the Julia reference's ``_state_cells``)."""
    out: list[tuple[list[int], int]] = []
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


def _variable_shape(file: EsmFile, mname: str, variable: str) -> list[str]:
    """The asserted variable's declared spatial shape (ordered index-set
    names). Raises when the variable is missing or scalar — a ``coords``
    assertion is ill-formed on a 0-D variable per esm-spec §6.6.5. Identical
    to the Julia reference's ``_variable_shape``."""
    model = (file.models or {}).get(str(mname))
    if model is None:
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
    (``"Heat.u[3]"``) to its row in that vector."""

    times: list[float]
    states: list[np.ndarray]
    var_map: dict[str, int]


def simulate_states(
    file: EsmFile,
    tspan: tuple[float, float],
    *,
    method: str = "RK45",
    rtol: float = _DEFAULT_SOLVER_RTOL,
    atol: float = _DEFAULT_SOLVER_ATOL,
    saveat: Sequence[float],
    parameters: dict[str, float] | None = None,
    initial_conditions: dict[str, float] | None = None,
    inspect: BuildInspection | None = None,
) -> SimulatedStates:
    """Run the official :func:`earthsci_ast.simulation.simulate` pathway
    and sample the trajectory at each time of ``saveat`` (which must lie on
    the solver's output grid to within ``1e-9 · max(1, |t|)`` — trajectory
    output is dense over ``tspan``, so span endpoints always qualify).
    Raises :class:`RuntimeError` when the solve fails.

    ``inspect`` is forwarded to :func:`simulate` — an optional
    :class:`~earthsci_ast.simulation.BuildInspection` sink the NumPy
    pathway fills with the build-time setup arrays / observed map (results
    are identical with or without it)."""
    result = simulate(
        file,
        tspan,
        parameters=dict(parameters or {}),
        initial_conditions=dict(initial_conditions or {}),
        method=method,
        rtol=rtol,
        atol=atol,
        inspect=inspect,
    )
    if not result.success:
        raise RuntimeError(f"simulate failed: {result.message}")
    var_map = {str(name): i for i, name in enumerate(result.vars)}
    times: list[float] = []
    states: list[np.ndarray] = []
    for t in saveat:
        ti = int(np.argmin(np.abs(result.t - float(t))))
        if abs(float(result.t[ti]) - float(t)) > _SAVEAT_MATCH_TOL * max(1.0, abs(float(t))):
            raise RuntimeError(f"no saved state at t={t} (nearest {float(result.t[ti])})")
        times.append(float(result.t[ti]))
        states.append(np.asarray(result.y[:, ti], dtype=float))
    return SimulatedStates(times=times, states=states, var_map=var_map)


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
    """Julia ``isapprox`` semantics: ``|a − e| ≤ max(atol, rtol·max(|a|, |e|))``
    (exact equality when both tolerances are zero)."""
    if rtol == 0.0 and atol == 0.0:
        return float(actual) == float(expected)
    return abs(float(actual) - float(expected)) <= max(
        atol, rtol * max(abs(float(actual)), abs(float(expected)))
    )


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
    return load(json.dumps(raw), base_path=str(base_dir))


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
) -> PdeAssertionResult:
    """Build one :class:`PdeAssertionResult`, filling the assertion-identity
    fields (model / test / index / variable / time / reduce / expected) from
    the ``test`` + ``assertion`` and taking the outcome fields verbatim. The
    three result sites of :func:`run_pde_tests` share this shape."""
    return PdeAssertionResult(
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
    assertion has neither. The per-assertion body of :func:`run_pde_tests`."""
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
                # variable is a state-free ARRAY OBSERVED whose
                # field the build inspection materialized (the
                # MPAS rule output div_flux max/min).
                obs = _inspection_field(insp, str(mname), a.variable)
                if obs is None:
                    raise RuntimeError(
                        f"array state '{a.variable}' has no cells "
                        f"in var_map, and no state-free array "
                        f"observed of that name is exposed by the "
                        f"build inspection"
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
                    if (
                        isinstance(a.reference, dict)
                        and a.reference.get("type") == "from_file"
                    ):
                        ref = _from_file_reference(
                            a.reference, resolved_base, cell_tuples
                        )
                    elif isinstance(a.reference, (ExprNode, int, float, str)):
                        # Model parameters (load-time constants) are
                        # in scope for a §6.6.5 analytic reference;
                        # state is not. `insp.params` carries the
                        # build's resolved scalar params.
                        ref = evaluate_cellwise(
                            a.reference,
                            cell_tuples,
                            index_sets=eval_file.index_sets,
                            params=_param_scope_with_aliases(insp.params),
                        )
                    else:
                        raise RuntimeError(
                            f"unsupported `reference` shape {type(a.reference)}"
                        )
                actual = field_reduce(a.reduce, field, reference=ref)
    except Exception as err:  # noqa: BLE001 — recorded per assertion
        msg = f"assertion evaluation failed: {err}"
    return actual, msg


def run_pde_tests(
    pde_input: str | EsmFile,
    *,
    model_name: str | None = None,
    method: str = "RK45",
    rtol: float = _DEFAULT_SOLVER_RTOL,
    atol: float = _DEFAULT_SOLVER_ATOL,
    base_dir: str | None = None,
) -> list[PdeAssertionResult]:
    """Run every inline test (esm-spec §6.6, including the §6.6.5 PDE
    assertions) of the selected model(s) of ``pde_input`` (a path or a loaded
    :class:`EsmFile`) through the official NumPy simulation pathway, and
    return one :class:`PdeAssertionResult` per assertion — carrying the ACTUAL
    reduction value alongside pass/fail, so conformance harnesses can record
    and cross-compare the numbers.

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
    to the .esm file's directory when ``pde_input`` is a path, else the working
    directory. Mirrors the Julia binding's ``run_pde_tests`` 1:1 (tolerances
    per §6.6.4; the pass predicate is Julia ``isapprox``)."""
    file = load(pde_input) if isinstance(pde_input, str) else pde_input
    if not isinstance(file, EsmFile):
        raise TypeError(f"run_pde_tests expects a path or EsmFile, got {type(pde_input)}")
    if base_dir is not None:
        resolved_base = str(base_dir)
    elif isinstance(pde_input, str) and os.path.isfile(pde_input):
        # `load` accepts a path or raw JSON text; only a real path anchors
        # from_file references at the .esm file's directory.
        resolved_base = os.path.dirname(os.path.abspath(pde_input))
    else:
        resolved_base = os.getcwd()
    results: list[PdeAssertionResult] = []
    for mname, model in (file.models or {}).items():
        if model_name is not None and str(mname) != str(model_name):
            continue
        if not model.tests:
            continue
        for t in model.tests:
            times = sorted({float(a.time) for a in t.assertions})
            sim: SimulatedStates | None = None
            sim_err = ""
            # esm-spec §9.7.10 form C: a test that injects a discretization runs
            # against an EPHEMERAL instance of this component with the test's
            # imports appended to its scope and its rewrite-targets lowered; the
            # persisted `file` is untouched. A test with no injection runs
            # against the file as loaded.
            run_file: EsmFile | None = file
            run_model = model
            if t.expression_template_imports:
                try:
                    src = (
                        pde_input
                        if (isinstance(pde_input, str) and os.path.isfile(pde_input))
                        else None
                    )
                    run_file = _ephemeral_injected_file(
                        file, src, str(mname), t.expression_template_imports, resolved_base
                    )
                    rm = (run_file.models or {}).get(str(mname))
                    if rm is None:
                        raise RuntimeError(f"component '{mname}' vanished from the ephemeral build")
                    run_model = rm
                except Exception as err:  # noqa: BLE001 — recorded per assertion
                    sim_err = f"per-test discretization injection failed: {err}"
                    run_file = None
            # Build inspection sink: a §6.6.5 assertion may target a
            # state-free ARRAY OBSERVED (the observed-assertion form); its
            # field is read from the setup arrays the build materializes.
            insp = BuildInspection()
            if run_file is not None:
                try:
                    sim = simulate_states(
                        run_file,
                        (t.time_span.start, t.time_span.end),
                        method=method,
                        rtol=rtol,
                        atol=atol,
                        saveat=times,
                        parameters=t.parameter_overrides,
                        initial_conditions=t.initial_conditions,
                        inspect=insp,
                    )
                except Exception as err:  # noqa: BLE001 — recorded per assertion
                    sim_err = f"simulate failed: {err}"
                    sim = None
            eval_file = file if run_file is None else run_file
            for i, a in enumerate(t.assertions, start=1):
                a_rtol, a_atol = _resolve_tolerance(run_model.tolerance, t.tolerance, a.tolerance)
                if sim is None:
                    results.append(
                        _result(mname, t, i, a, a_rtol, a_atol, None, False, sim_err)
                    )
                    continue
                actual, msg = _evaluate_assertion(
                    a, sim, times, mname, eval_file, insp, resolved_base
                )
                if actual is None:
                    results.append(
                        _result(mname, t, i, a, a_rtol, a_atol, None, False, msg)
                    )
                else:
                    ok = _check_assertion(actual, a.expected, a_rtol, a_atol)
                    if not ok:
                        msg = (
                            f"actual={actual} expected={a.expected} (rtol={a_rtol}, atol={a_atol})"
                        )
                    results.append(
                        _result(mname, t, i, a, a_rtol, a_atol, actual, ok, msg)
                    )
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
