"""NumPy array simulation path (NumPy AST interpreter).

Implements the array-op / discretized-PDE simulation pathway — the Python
analogue of the Rust binding's ``simulate_array.rs``: state layout and
initial-condition folding, per-equation RHS evaluation through the NumPy AST
interpreter, observed ordering / materialization, value-invention detection
and join-key buffers, the :class:`BuildInspection` observability sink,
:func:`_build_numpy_rhs`, :func:`evaluate_rhs`, and
:func:`_simulate_with_numpy`.
``earthsci_ast.simulation`` re-exports this module's API.
"""
from __future__ import annotations

import warnings
from dataclasses import dataclass, field
from typing import Any, Callable

import numpy as np

from .esm_types import EsmFile, Expr, ExprNode, is_aggregate_op
from .expr_walk import iter_children, map_children
from .flatten import (
    FlattenedEquation,
    FlattenedSystem,
    UnsupportedDimensionalityError,
    _expand_range,
    flatten,
    infer_variable_shapes,
)
from .numpy_interpreter import (
    EvalContext,
    NumpyInterpreterError,
    _RaggedRange,
    _resolve_range_spec,
    eval_expr,
    ragged_factor_scope,
)
from .simulation_common import (
    DENSE_OUTPUT_MIN_POINTS,
    SimulationResult,
    _failure_result,
    _observed_rows,
    _resolve_override,
    solve_ivp,
)
from .sympy_bridge import SimulationError


def _linear_pos(shape: tuple[int, ...], one_based: list[int]) -> int:
    """Convert a 1-based index tuple to a linear position (row-major)."""
    if len(shape) != len(one_based):
        raise SimulationError(f"index rank mismatch: shape={shape} idx={one_based}")
    lin = 0
    for d, i in enumerate(one_based):
        zero = int(i) - 1
        if zero < 0 or zero >= shape[d]:
            raise SimulationError(f"index {i} out of range for dim {d} of shape {shape}")
        lin = lin * shape[d] + zero
    return lin


def _densify_solution(
    sol: Any, tspan: tuple[float, float], min_points: int = DENSE_OUTPUT_MIN_POINTS
) -> tuple[np.ndarray, np.ndarray]:
    """Resample a ``solve_ivp`` result onto a dense uniform grid.

    The fixture runners consume ``SimulationResult`` via linear
    interpolation (``np.interp``) while the Julia reference uses the
    solver's continuous interpolant. SciPy's native step points are too
    sparse for ``np.interp`` to hit fixture tolerances on smooth curves,
    so we lean on ``dense_output=True`` and sample a uniform grid of at
    least ``min_points`` nodes (plus the solver's native step points so
    event-driven kinks are preserved).
    """
    if not sol.success or getattr(sol, "sol", None) is None:
        return sol.t, sol.y
    t0, t1 = float(tspan[0]), float(tspan[1])
    # Resample onto at least ``min_points`` nodes, but scale to 4× the solver's own
    # step count so a stiff / eventful run (many native steps) gets proportionally
    # denser output than the flat ``min_points`` floor would give — enough
    # inter-step nodes for the fixture runners' linear interp to track the curve.
    n = max(min_points, int(len(sol.t)) * 4)
    grid = np.linspace(t0, t1, n)
    t_out = np.unique(np.concatenate([grid, np.asarray(sol.t, dtype=float)]))
    t_out = t_out[(t_out >= t0) & (t_out <= t1)]
    y_out = sol.sol(t_out)
    return t_out, y_out


def _element_names(state_names: list[str], shapes: dict[str, tuple[int, ...]]) -> list[str]:
    """Return a flat list of namespaced element names in layout order.

    Scalar variables appear as the namespaced name. Array variables are
    unpacked into ``name[i]``, ``name[i,j]``, … in row-major order.
    """
    elem_names: list[str] = []
    for name in state_names:
        shape = shapes.get(name, ())
        if not shape:
            elem_names.append(name)
            continue
        for multi in np.ndindex(*shape):
            one_based = ",".join(str(i + 1) for i in multi)
            elem_names.append(f"{name}[{one_based}]")
    return elem_names


def _parse_element_key(key: str) -> tuple[str, list[int] | None]:
    """Parse ``"u[1,2]"`` into ``("u", [1, 2])``. Bare names return ``(key, None)``."""
    if "[" not in key or not key.endswith("]"):
        return key, None
    base, rest = key.split("[", 1)
    inner = rest[:-1]  # strip trailing ']'
    try:
        indices = [int(s.strip()) for s in inner.split(",")]
    except ValueError:
        return key, None
    return base, indices


def _resolve_state_element(
    key: str,
    state_names: list[str],
    shapes: dict[str, tuple[int, ...]],
    state_layout: dict[str, slice],
) -> tuple[str, int] | None:
    """Resolve an element key like ``"u[1]"`` or ``"Chem.u[1]"`` to ``(var_name, flat_pos)``.

    Accepts both namespaced and bare forms. Returns ``None`` if the key does
    not resolve.
    """
    base, idx = _parse_element_key(key)
    # Match base against state names: an EXACT name wins outright; otherwise fall
    # back to dot-suffix (`*.base`) matches. Refuse to pick arbitrarily among
    # several suffix matches — an ambiguous bare IC key must not be silently
    # assigned to whichever state happens to sort first (mirrors
    # numpy_interpreter.ragged_factor_scope's deliberate ambiguity refusal).
    if base in state_names:
        var_name = base
    else:
        matches = [n for n in state_names if n.endswith("." + base)]
        if not matches:
            return None
        if len(matches) > 1:
            raise SimulationError(
                f"initial condition key {key!r} is ambiguous: bare name {base!r} "
                f"matches multiple states {sorted(matches)}; use the full "
                f"dot-namespaced state name"
            )
        var_name = matches[0]
    shape = shapes.get(var_name, ())
    if idx is None:
        if shape:
            return None
        return var_name, state_layout[var_name].start
    if not shape:
        return None
    flat_pos = state_layout[var_name].start + _linear_pos(shape, idx)
    return var_name, flat_pos


def _grid_coords_from_spatial(spatial: dict[str, Any]) -> dict[str, np.ndarray]:
    """Build a 1-D coordinate array for each spatial dimension.

    The point count matches the method-of-lines discretization
    (``spatial_discretize._grid_sizes``): ``round((max - min)/grid_spacing) + 1``
    nodes from ``min`` to ``max`` inclusive. Returns an insertion-ordered map
    ``dim_name -> coordinate ndarray`` (dict preserves order on py>=3.7).
    """
    coords: dict[str, np.ndarray] = {}
    for dim_name, spec in spatial.items():
        lo = float(spec.min)
        hi = float(spec.max)
        spacing = getattr(spec, "grid_spacing", None)
        if spacing is None or float(spacing) <= 0:
            raise NumpyInterpreterError(
                f"expression initial condition needs a positive grid_spacing on "
                f"spatial dimension {dim_name!r} to build grid coordinates"
            )
        n_points = int(round((hi - lo) / float(spacing))) + 1
        coords[dim_name] = np.linspace(lo, hi, n_points)
    return coords


def _apply_initial_conditions(
    y0: np.ndarray,
    state_layout: dict[str, slice],
    shapes: dict[str, tuple[int, ...]],
    state_names: list[str],
    initial_conditions: dict[str, float],
) -> None:
    """Write initial-value overrides into ``y0``.

    Keys may be bare (``"u[1]"``) or namespaced (``"Chem.u[1]"``); scalar state
    variables use a bare name without brackets.
    """
    for key, value in initial_conditions.items():
        resolved = _resolve_state_element(key, state_names, shapes, state_layout)
        if resolved is None:
            # Might be a broadcast default: ``"u": 1.0`` assigns every element of a
            # whole-array state. Prefer an exact name; a >1-way ambiguous bare key
            # already raised in _resolve_state_element, so a lone unique dot-suffix
            # match is the only fallback (exact-name-wins parity with resolution).
            base, idx = _parse_element_key(key)
            if idx is None:
                if base in state_names:
                    name = base
                else:
                    matches = [n for n in state_names if n.endswith("." + base)]
                    name = matches[0] if len(matches) == 1 else None
                if name is not None:
                    sl = state_layout[name]
                    y0[sl] = float(value)
                    continue
            continue
        _, flat_pos = resolved
        y0[flat_pos] = float(value)


def _collect_algebraic_substitutions(
    equations: list[FlattenedEquation],
) -> tuple[list[FlattenedEquation], dict[str, tuple[list[str], Expr]]]:
    """Eliminate simple algebraic arrayop equations of the form ``v[i,...] = <body>``.

    Detects equations whose LHS is ``arrayop(expr=index(v, i, j, ...))`` where
    the index list is just the symbolic indices from ``output_idx`` (no
    offsets), and whose RHS is ``arrayop(expr=<body>)`` over the same index
    set. Returns the remaining equations and a substitution table keyed by
    the variable name, mapping to ``(idx_syms, rhs_body)``.

    This covers fixture 02 (``v[i] = -u[i]``). More complex algebraic forms
    (fixture 06) fall through to the remaining-equations list and simply get
    ignored — the solver will still run and the fixture's smoke assertion
    (initial value) passes.
    """
    subs: dict[str, tuple[list[str], Expr]] = {}
    kept: list[FlattenedEquation] = []
    for eq in equations:
        lhs = eq.lhs
        rhs = eq.rhs
        if isinstance(lhs, ExprNode) and is_aggregate_op(lhs.op):
            body = lhs.expr
            if isinstance(body, ExprNode) and body.op == "index" and body.args:
                head = body.args[0]
                if isinstance(head, str):
                    idx_syms = [a for a in body.args[1:] if isinstance(a, str)]
                    if (
                        len(idx_syms) == len(body.args) - 1
                        and isinstance(rhs, ExprNode)
                        and is_aggregate_op(rhs.op)
                        and rhs.expr is not None
                    ):
                        subs[head] = (idx_syms, rhs.expr)
                        continue
        kept.append(eq)
    return kept, subs


def _substitute_algebraic(
    expr: Expr,
    subs: dict[str, tuple[list[str], Expr]],
) -> Expr:
    """Replace ``index(v, ...)`` with the algebraic body of ``v`` where defined."""
    if not isinstance(expr, ExprNode):
        return expr
    node = map_children(expr, lambda c: _substitute_algebraic(c, subs))
    # If this is index(v, e1, e2, ...) with v eliminated, inline the body.
    if node.op == "index" and node.args:
        head = node.args[0]
        if isinstance(head, str) and head in subs:
            idx_syms, body = subs[head]
            caller_idx = node.args[1:]
            if len(caller_idx) == len(idx_syms):
                bindings = dict(zip(idx_syms, caller_idx))
                return _rebind_index_syms(body, bindings)
    return node


def _rebind_index_syms(expr: Expr, bindings: dict[str, Expr]) -> Expr:
    """Replace bare string references to index symbols with their target expressions."""
    if isinstance(expr, str):
        return bindings.get(expr, expr)
    if isinstance(expr, ExprNode):
        return map_children(expr, lambda c: _rebind_index_syms(c, bindings))
    return expr


def _iter_arrayop_points(lhs: ExprNode, ctx: EvalContext) -> tuple[list[str], list[list[int]]]:
    """Return ``(output_idx_symbols, expanded_ranges)`` for an aggregate LHS.

    Output ranges may be dense ``[lo, hi]`` tuples or ``{"from": <name>}``
    index-set references (RFC §5.2), resolved against ``ctx.index_sets``.
    """
    if lhs.ranges is None or lhs.output_idx is None:
        raise SimulationError("aggregate / arrayop LHS missing output_idx/ranges")
    syms = [s for s in lhs.output_idx if isinstance(s, str)]
    ranges: list[list[int]] = []
    for s in syms:
        resolved = _resolve_range_spec(lhs.ranges[s], ctx)
        if isinstance(resolved, _RaggedRange):
            raise SimulationError(
                f"aggregate / arrayop output index {s!r} cannot reference a "
                f"ragged index set (RFC §5.2)"
            )
        ranges.append(_expand_range(resolved))
    return syms, ranges


def _scatter_arrayop_rhs(
    lhs: ExprNode,
    rhs: Expr,
    idx_exprs: list[Expr],
    head: str,
    ctx: EvalContext,
    shapes: dict[str, tuple[int, ...]],
    state_layout: dict[str, slice],
    dy: np.ndarray,
) -> None:
    """Evaluate an aggregate / arrayop ODE RHS through the interpreter and scatter
    it into ``dy`` — the single evaluation path for the
    ``aggregate(D(index(var, i…)), ranges) = <rhs>`` array-state derivative form.

    Two RHS shapes are supported:

    * A SELF-CONTAINED aggregate RHS (the discretized-stencil / sum-product form,
      possibly carrying a named ``semiring``, ``{"from": ...}`` index sets, a
      ``join`` / ``filter`` gate, or contracted reduction indices): the full NumPy
      interpreter materializes the whole output-box array in ONE pass — reductions
      and gates included — and each element is written to the matching flat-state
      slot. The LHS and RHS output boxes share index symbols, so element ``multi``
      of the result maps to ``var[idx_exprs(multi)]`` (a scalar result broadcasts
      to every cell).
    * A BARE-expression RHS that references the LHS output-index symbols: it is
      evaluated PER output cell with those symbols bound to the cell's index
      values, yielding one scalar per cell.

    Evaluating the RHS through the interpreter (rather than a hand-rolled unroll)
    keeps the reduction / semiring / index-set / join / filter semantics in ONE
    place — the interpreter's vectorized materialization is contractually
    byte-for-byte identical to its scalar fallback.
    """
    syms, ranges = _iter_arrayop_points(lhs, ctx)
    shape = shapes[head]
    layout_start = state_layout[head].start
    it = np.ndindex(*(len(r) for r in ranges)) if ranges else [()]
    # A self-contained aggregate binds its own output_idx internally and
    # materializes the whole output box in one pass; a bare expression references
    # the LHS output-index symbols and must be evaluated per cell with them bound.
    rhs_is_box = isinstance(rhs, ExprNode) and is_aggregate_op(rhs.op)
    result = np.asarray(eval_expr(rhs, ctx), dtype=float) if rhs_is_box else None
    prev_locals = dict(ctx.locals)
    try:
        for multi in it:
            for s, pos in zip(syms, multi):
                ctx.locals[s] = ranges[syms.index(s)][pos]
            idx_vals = [int(round(float(eval_expr(e, ctx)))) for e in idx_exprs]
            flat_pos = layout_start + _linear_pos(shape, idx_vals)
            if rhs_is_box:
                dy[flat_pos] = float(result[multi]) if result.ndim else float(result)
            else:
                dy[flat_pos] = float(eval_expr(rhs, ctx))
    finally:
        ctx.locals = prev_locals


def _apply_aggregate_ode_to_dy(
    lhs: ExprNode,
    rhs: Expr,
    ctx: EvalContext,
    shapes: dict[str, tuple[int, ...]],
    state_layout: dict[str, slice],
    dy: np.ndarray,
) -> bool:
    """Evaluate the aggregate / arrayop ODE form and scatter it into ``dy``.

    Handles ``arrayop(D(index(var, i, ...), t), ranges=...) = <rhs>`` — an array
    state derivative written over a range box. Returns ``True`` if ``lhs`` matched
    this shape (and its contribution was written into ``dy``), ``False`` otherwise
    so :func:`_apply_equation_to_dy` can fall through to its remaining cases.

    Every matching node is evaluated through the full NumPy interpreter via
    :func:`_scatter_arrayop_rhs` — the interpreter carries the reduction /
    semiring / index-set / join / filter semantics (and its vectorized
    materialization is contractually byte-for-byte identical to its scalar
    fallback), so there is no hand-rolled unroll to keep in sync.
    """
    if isinstance(lhs, ExprNode) and is_aggregate_op(lhs.op) and lhs.expr is not None:
        body = lhs.expr
        if isinstance(body, ExprNode) and body.op == "D" and body.args:
            inner = body.args[0]
            if isinstance(inner, ExprNode) and inner.op == "index" and inner.args:
                head = inner.args[0]
                if isinstance(head, str) and head in state_layout:
                    _scatter_arrayop_rhs(
                        lhs,
                        rhs,
                        inner.args[1:],
                        head,
                        ctx,
                        shapes,
                        state_layout,
                        dy,
                    )
                    return True
    return False


def _apply_equation_to_dy(
    eq: FlattenedEquation,
    ctx: EvalContext,
    shapes: dict[str, tuple[int, ...]],
    state_layout: dict[str, slice],
    dy: np.ndarray,
) -> None:
    """Evaluate one equation and write its contribution into ``dy``.

    Handles three shapes:

    * ``D(scalar_state, t) = rhs`` — scalar state derivative.
    * ``D(index(var, k1, ...), t) = rhs`` — single element of an array state.
    * ``arrayop(D(index(var, i, ...), t), ranges=...) = <rhs>`` — array state
      derivative over a range box.
    """
    lhs = eq.lhs
    rhs = eq.rhs

    # Case A: bare-name state LHS — D(var, t) with var a bare string.
    if isinstance(lhs, ExprNode) and lhs.op == "D" and lhs.args:
        inner = lhs.args[0]
        if isinstance(inner, str):
            if inner not in state_layout:
                return
            shape = shapes.get(inner, ())
            if shape:
                # Whole-array derivative ``D(SST) = <array rhs>`` (esm-spec §11):
                # the declared-shape array state is integrated per cell. Evaluate
                # the array-valued RHS and scatter it element-wise across the
                # state's flat slots (a scalar RHS broadcasts to every cell).
                n = int(np.prod(shape))
                start = state_layout[inner].start
                arr = np.asarray(eval_expr(rhs, ctx), dtype=float).reshape(-1)
                if arr.size == 1:
                    dy[start : start + n] = float(arr[0])
                elif arr.size == n:
                    dy[start : start + n] = arr
                else:
                    raise SimulationError(
                        f"D({inner}): RHS produced {arr.size} elements for a "
                        f"state of shape {shape} ({n} cells)"
                    )
                return
            val = float(eval_expr(rhs, ctx))
            dy[state_layout[inner].start] = val
            return
        if isinstance(inner, ExprNode) and inner.op == "index" and inner.args:
            head = inner.args[0]
            if isinstance(head, str) and head in state_layout:
                idx_vals = [int(round(float(eval_expr(e, ctx)))) for e in inner.args[1:]]
                shape = shapes[head]
                flat_pos = state_layout[head].start + _linear_pos(shape, idx_vals)
                val = float(eval_expr(rhs, ctx))
                dy[flat_pos] = val
                return

    # Case B: aggregate / arrayop LHS wrapping D(index(var, ...)).
    if _apply_aggregate_ode_to_dy(lhs, rhs, ctx, shapes, state_layout, dy):
        return

    # Case C: an equation left over after elimination whose LHS matched neither a
    # scalar/element state derivative (Case A) nor an aggregate ODE (Case B), so
    # nothing is written to ``dy``. A scalar ``ic`` op is an intentional no-op on
    # the RHS (its initial value is folded into u0 at build time), so it is NOT
    # "unrecognized" and must not warn. Every other shape means a state this
    # equation was meant to constrain silently stays frozen at its initial value —
    # emit a diagnostic naming it rather than dropping it silently (Python dedups
    # per distinct message, so this fires once per LHS).
    if isinstance(lhs, ExprNode) and lhs.op == "ic":
        return
    warnings.warn(
        f"simulate: unrecognized algebraic equation with LHS {eq.lhs!r} was not "
        f"applied to the ODE RHS; any state it constrains stays frozen at its "
        f"initial value",
        RuntimeWarning,
        stacklevel=2,
    )
    return


def _expr_referenced_names(expr: Expr) -> set[str]:
    """Collect every bare-string leaf (a variable / observed reference) in ``expr``.

    Index symbols and other non-variable strings are gathered too; callers
    intersect the result with a known name set to keep only the meaningful
    references. Traversal goes through :func:`earthsci_ast.expr_walk.iter_children`,
    the single canonical child enumeration, so EVERY expression-bearing slot is
    covered — ``args``, the integral bounds ``lower`` / ``upper``, the aggregate
    ``expr`` body, the join ``filter`` / ``key`` predicates, ``values``, and the
    ``table_lookup`` ``table_axes`` — and a dependency edge hidden in a bound or
    a lookup axis is never dropped.
    """
    refs: set[str] = set()
    stack: list[Any] = [expr]
    while stack:
        e = stack.pop()
        if isinstance(e, str):
            refs.add(e)
        elif isinstance(e, ExprNode):
            stack.extend(iter_children(e))
    return refs


def _order_observed_equations(
    observed_eqs: list[tuple[str, Expr]],
    observed_names: set[str],
) -> list[tuple[str, Expr]]:
    """Dependency-order observed assignments so each follows the observeds it reads.

    An observed depends on another observed whose name appears anywhere in its
    RHS (an operand, an aggregate body, a clip leaf, …). Returns ``(name, rhs)``
    pairs in evaluation order via a Kahn sweep that preserves declaration order
    among independent observeds. Any observed left in a cycle (a self-referential
    algebraic block the point-wise driver cannot resolve) is appended in
    declaration order so the run still proceeds — the evaluator then surfaces a
    clear unresolved-symbol error rather than the driver hanging.
    """
    rhs_by_name: dict[str, Expr] = dict(observed_eqs)
    # Only observeds PRODUCED by an equation here impose an ordering constraint.
    # A referenced name that is a known observed but has NO equation in this set
    # — e.g. a data-loader field (``USGS3DEP.raw.elevation``), which flatten
    # records in ``observed_variables`` yet supplies EXTERNALLY via
    # ``loader_arrays``/``input_arrays`` — is bound into the eval context BEFORE
    # any observed is materialized, so it is always available and must NOT block
    # the sweep. Blocking on such an equation-less input would strand its whole
    # consumer cone (``F_elev`` → ``elev_xy`` → ``dzdx`` → ``tan_phi`` → ``S_n``
    # …) in the declaration-order fallback below, which then evaluates consumers
    # before producers and raises a spurious "Unresolved symbol" for a live
    # observed. (``observed_names`` is kept for the caller's contract.)
    produced: set[str] = set(rhs_by_name)
    deps: dict[str, set[str]] = {}
    for name, rhs in observed_eqs:
        refs = _expr_referenced_names(rhs) & produced
        refs.discard(name)
        deps[name] = refs

    ordered: list[tuple[str, Expr]] = []
    placed: set[str] = set()
    remaining = [name for name, _ in observed_eqs]
    progress = True
    while remaining and progress:
        progress = False
        still: list[str] = []
        for name in remaining:
            if deps[name] <= placed:
                ordered.append((name, rhs_by_name[name]))
                placed.add(name)
                progress = True
            else:
                still.append(name)
        remaining = still
    for name in remaining:  # cyclic / dangling — keep declaration order
        ordered.append((name, rhs_by_name[name]))
    return ordered


def _time_varying_observeds(
    ordered_observed: list[tuple[str, Expr]],
    state_names: set[str],
) -> set[str]:
    """Names of observeds that change in time (transitively reference a state or ``t``).

    ``ordered_observed`` is already dependency-sorted, so a single forward pass
    propagates time-variance: an observed is time-varying if it references a
    state variable, ``t``, or another already-seen time-varying observed.
    The complement is constant along the trajectory and can be evaluated once
    and broadcast instead of re-sampled at every output node (the common case
    for a fixed-geometry clip/area whose inputs are constants/parameters).
    """
    state_and_t = set(state_names) | {"t"}
    varying: set[str] = set()
    for name, rhs in ordered_observed:
        refs = _expr_referenced_names(rhs)
        if (refs & state_and_t) or (refs & varying):
            varying.add(name)
    return varying


def _loader_volatile_observeds(
    ordered_observed: list[tuple[str, Expr]],
    volatile_loader_names: set[str],
) -> set[str]:
    """Names of observeds that change between cadence SEGMENTS (transitively
    reference a ``discrete``-cadence loader field).

    The loader analog of :func:`_time_varying_observeds`: the same single forward
    pass over the dependency-ordered observeds, but propagating loader-volatility
    instead of state/``t``-variance. An observed is volatile if it references a
    discrete loader field (whose slice the segment driver refreshes at each
    cadence boundary — :func:`simulation_loaders._run_cadence_segmented_solve`) or
    another already-seen volatile observed.

    Its complement — the loader-INVARIANT observeds — depends only on constant
    geometry, parameters, and ``const``-cadence loaders (all fixed for the whole
    run), so it evaluates to the SAME arrays every segment. That is precisely the
    conservative-regrid GEOMETRY (the ``A_ij`` overlap-area clip, its row-sums
    ``A_j``, the normalized weights ``W_ij``) — the expensive half — which the
    build can materialize ONCE and reuse across every segment instead of
    rebuilding per hour. ``volatile_loader_names`` is
    ``{lf.name for lf in flat.loader_fields if lf.cadence == "discrete"}``; empty
    (every loader const, or no loaders) ⇒ every static observed is invariant.
    """
    volatile: set[str] = set()
    for name, rhs in ordered_observed:
        refs = _expr_referenced_names(rhs)
        if (refs & volatile_loader_names) or (refs & volatile):
            volatile.add(name)
    return volatile


def _materialize_observeds(
    ordered_observed: list[tuple[str, Expr]],
    ctx: EvalContext,
    skip_unresolved: bool = False,
) -> None:
    """Evaluate observed assignments into ``ctx`` in dependency order.

    Array-valued observeds (e.g. a clipped polygon ring) are registered in
    ``ctx.derived_rings`` under their namespaced name so a downstream aggregate
    body can ``index`` into them by name; an ``intersect_polygon`` body
    additionally self-registers its clip ring under its node ``id`` (RFC §8.1),
    which is how a ``kind:"derived"`` index set resolves its data-dependent
    extent. Scalar observeds go to ``ctx.observed_values`` for bare-name
    resolution. This is what lets a geometry model — ``clip = intersect_polygon``,
    ``area = sum_product FAQ(clip)``, ``D(tracer) = -area·tracer`` — integrate
    end-to-end through :func:`simulate` (RFC §8.1; CONFORMANCE_SPEC.md §5.8).

    ``skip_unresolved`` silently drops an observed whose body cannot be
    evaluated — a DEAD observed nothing live reads, e.g. a passive-axis
    ``dy = 1/NY`` whose count ``NY`` was closed at an import edge and so stays a
    bare symbol (esm-spec §9.7.6). Such an observed is never consumed, so
    skipping it is lossless; a live observed a downstream reader needs still
    fails clearly at that read. Used by the per-step RHS driver (parity with the
    Julia reference, which evaluates only the state-derivative dependency cone)
    and by the read-only :class:`BuildInspection` fill.
    """
    for name, rhs in ordered_observed:
        if skip_unresolved:
            try:
                val = eval_expr(rhs, ctx)
            except NumpyInterpreterError:
                continue
        else:
            val = eval_expr(rhs, ctx)
        if isinstance(val, np.ndarray) and val.ndim > 0:
            ctx.derived_rings[name] = val
        else:
            ctx.observed_values[name] = float(val)


@dataclass
class BuildInspection:
    """Observability record for :func:`simulate` — the Python mirror of the
    Julia binding's ``BuildInspection`` (``build_evaluator(...; inspect=…)``).

    Pass one via the ``inspect`` keyword
    (``simulate(file, tspan, inspect=BuildInspection())``) and the NumPy
    array/PDE pathway fills it with named BUILD-TIME products that are
    otherwise internal to the evaluator:

    * ``setup_arrays`` — the materialized build-time geometry arrays, keyed by
      (flattened) observed name: the per-pair overlap-area matrix ``A_ij``,
      its row-sums ``A_j``, the normalized weights ``W_ij``, and every other
      STATE-FREE array-valued observed (no transitive state / ``t``
      reference), evaluated once at build. This is the official inspection
      surface for conformance runners that gate per-pair regridding values
      (CONFORMANCE_SPEC §5.8).
    * ``const_arrays`` — the build-time array registry: the value-invention
      join-key buffers (broad-phase bins) and provider-/loader-injected input
      arrays.
    * ``observed_exprs`` — the dependency-ordered observed substitution map
      (flattened name → RHS expression), exactly as the RHS driver
      materializes it each step.
    * ``params`` — the resolved SCALAR parameter values (model defaults with
      any ``parameter_overrides`` applied), keyed by (flattened) parameter
      name. These are load-time CONSTANTS, so a build-time cellwise evaluation
      (``evaluate_cellwise``, a §6.6.5 analytic ``reference``, coordinate-
      expression ``ic`` seeding) may bind them into scope — while STATE stays
      out of scope. The observed-assertion form already binds them (a state-
      free observed is materialized into ``setup_arrays`` with these values);
      ``params`` exposes the same map for the reference / ``ic`` positions.

    Filling the record never changes the simulation: the returned
    :class:`SimulationResult` is identical with or without ``inspect``
    (nothing downstream consults the record). Only the NumPy array-op pathway
    fills it; the scalar SymPy pathway accepts and ignores it.
    """

    setup_arrays: dict[str, np.ndarray] = field(default_factory=dict)
    const_arrays: dict[str, Any] = field(default_factory=dict)
    observed_exprs: dict[str, Expr] = field(default_factory=dict)
    params: dict[str, float] = field(default_factory=dict)


@dataclass
class _NumpyRhsBuild:
    """Everything needed to evaluate (and integrate) a discretized array/PDE
    RHS: the ``rhs_function(t, y)`` closure plus the layout metadata its callers
    need after the fact (state names, shapes, layout, params, observeds)."""

    rhs_function: Callable[[float, Any], Any]
    y0: Any
    total_size: int
    state_names: list[str]
    shapes: dict[str, tuple[int, ...]]
    state_layout: dict[str, slice]
    param_values: dict[str, float]
    ordered_observed: list[tuple[str, Expr]]
    elem_names: list[str]
    # State-free observeds materialized ONCE at build (the const-geometry hoist):
    # ``static_observed`` scalars land in ``static_observed_values``, arrays in
    # ``static_derived_rings``; ``varying_observed`` is the (dependency-ordered)
    # subset that transitively references state / ``t`` and so must be re-evaluated
    # each step. Both the per-step RHS and the output-time observed reconstruction
    # seed a context with the static products and evaluate only ``varying_observed``
    # — identical numerics (a state-free body is constant along the trajectory),
    # but the expensive const geometry (e.g. a conservative-regrid ``A_ij`` clip)
    # runs once instead of per step. Empty when every observed is time-varying.
    varying_observed: list[tuple[str, Expr]] = field(default_factory=list)
    static_observed_values: dict[str, float] = field(default_factory=dict)
    static_derived_rings: dict[str, np.ndarray] = field(default_factory=dict)
    join_key_buffers: dict[str, np.ndarray] = field(default_factory=dict)
    join_key_index_sets: dict[str, str] = field(default_factory=dict)
    # Keyed-factor scope map (bare ragged offsets/values factor → in-scope
    # variable; see numpy_interpreter.ragged_factor_scope). Threaded into every
    # EvalContext this build spawns. Empty without ragged index sets.
    factor_scope: dict[str, str] = field(default_factory=dict)


def _resolve_field_ic(
    target: str,
    rhs: Expr,
    cell: tuple[int, ...],
    loader_arrays: dict[str, np.ndarray],
    index_sets: dict[str, Any] | None = None,
    param_values: dict[str, float] | None = None,
) -> float:
    """Resolve one grid cell's initial value for a scoped-reference / array ``ic``
    equation (esm-spec §11.4.1). ``cell`` is the 1-based integer index tuple.
    Model PARAMETERS (load-time constants) bind via ``param_values``; STATE is
    not in scope.

    Supported RHS forms, in order:

    1. A LOADED FIELD — a bare reference to a ``loader_arrays`` entry supplying
       the initial field over the lifted grid. The cell is read directly when the
       field's rank matches the target grid; a single-element field is broadcast.
    2. A BROADCAST CONSTANT — a numeric RHS applied to every cell.
    3. A COORDINATE EXPRESSION — an elementwise expression over array-producing
       ``aggregate``/``makearray`` nodes (e.g. ``cos(pi * x_coord)`` where
       ``x_coord`` is a grid-geometry aggregate expanded from a §9.7 template
       import). The expression is evaluated through the official NumPy
       interpreter (:func:`earthsci_ast.numpy_interpreter.eval_expr`) in a
       state-free context and indexed at this cell; a scalar result (an RHS
       that const-folds) is broadcast.

    Anything else is a hard error, so a scoped-reference ic that cannot be
    resolved is never silently dropped. Mirrors tree_walk.jl ``_resolve_field_ic``.
    """
    if isinstance(rhs, str) and rhs in loader_arrays:
        arr = np.asarray(loader_arrays[rhs], dtype=float)
        if arr.ndim == len(cell):
            return float(arr[tuple(c - 1 for c in cell)])
        if arr.size == 1:
            return float(arr.flat[0])
        raise SimulationError(
            f"ic({target}): loaded field {rhs!r} has ndim={arr.ndim} which does "
            f"not match the {len(cell)}-D lifted target grid"
        )
    if isinstance(rhs, (int, float)) and not isinstance(rhs, bool):
        return float(rhs)
    if isinstance(rhs, ExprNode):
        try:
            value = _eval_buildtime_field(rhs, index_sets=index_sets, param_values=param_values)
        except (NumpyInterpreterError, SimulationError, ValueError):
            # A coordinate expression the build-time interpreter cannot resolve
            # (unresolved symbol / bad shape) falls through to the hard error
            # below; other exception types are genuine bugs and must surface.
            value = None
        if value is not None:
            if np.ndim(value) == 0:
                return float(value)  # const-folded scalar, broadcast
            arr = np.asarray(value, dtype=float)
            if arr.ndim == len(cell):
                return float(arr[tuple(c - 1 for c in cell)])
            raise SimulationError(
                f"ic({target}): coordinate expression evaluates to ndim="
                f"{arr.ndim}, which does not match the {len(cell)}-D lifted "
                f"target grid"
            )
    detail = f" (no loader_arrays entry named {rhs!r})" if isinstance(rhs, str) else ""
    raise SimulationError(
        f"ic({target}): RHS is neither a loaded const-array field, a constant, "
        f"nor a per-cell coordinate expression{detail}; supply the initial "
        f"field via the data-Provider seam or a grid-geometry expression"
    )


def _eval_buildtime_field(
    expr: Expr,
    index_sets: dict[str, Any] | None = None,
    param_values: dict[str, float] | None = None,
) -> float | np.ndarray:
    """Evaluate a state-free build-time expression (grid geometry, §6.6.5
    analytic references) through the official NumPy interpreter. Array-
    producing ``aggregate``/``makearray`` nodes yield ndarrays; elementwise
    ops broadcast over them.

    STATE references are not in scope — the context carries no states, so any
    state reference raises. Model PARAMETERS (load-time constants) ARE in scope
    when supplied via ``param_values`` (name → value): a parameter-dependent
    coordinate expression / reference then resolves (esm-spec §6.6.5)."""
    from .numpy_interpreter import EvalContext as _EvalCtx
    from .numpy_interpreter import eval_expr as _eval_expr

    ctx = _EvalCtx(
        state_layout={},
        state_shapes={},
        param_values=dict(param_values or {}),
        observed_values={},
        y=np.empty((0,), dtype=float),
        t=0.0,
        index_sets=dict(index_sets or {}),
    )
    return _eval_expr(expr, ctx)


def _fold_field_ics(
    y0: np.ndarray,
    field_ic_eqs: list[tuple[str, Expr]],
    shapes: dict[str, tuple[int, ...]],
    state_layout: dict[str, slice],
    loader_arrays: dict[str, np.ndarray],
    index_sets: dict[str, Any] | None = None,
    param_values: dict[str, float] | None = None,
) -> None:
    """Fold every scoped-reference / array ``ic`` equation into ``y0`` cell-by-cell
    (esm-spec §11.4.1). Each target must name a lifted/array state of the
    flattened system; an unresolved target or RHS is a hard error. Model
    PARAMETERS (load-time constants) bind via ``param_values``; STATE is not in
    scope."""
    for target, rhs in field_ic_eqs:
        if target not in state_layout:
            raise SimulationError(
                f"ic({target}): scoped-reference target is not a state variable "
                f"of the flattened system"
            )
        shape = shapes.get(target, ())
        if not shape:
            raise SimulationError(
                f"ic({target}): scoped-reference target resolves to no array cells; "
                f"the target must name a lifted/array state variable"
            )
        start = state_layout[target].start
        for multi in np.ndindex(*shape):
            cell = tuple(int(i) + 1 for i in multi)
            y0[start + _linear_pos(shape, list(cell))] = _resolve_field_ic(
                target,
                rhs,
                cell,
                loader_arrays,
                index_sets=index_sets,
                param_values=param_values,
            )


def _resolve_index_set_shape(
    decl_shape: list[str],
    index_sets: dict[str, Any],
    derived_extents: dict[str, int] | None = None,
) -> tuple[int, ...] | None:
    """Resolve a declared ``shape`` (index-set names) to an integer tuple.

    Each axis names an index set: an ``interval`` contributes its ``size``, a
    ``derived`` set its materialized ``from_faq`` extent (when known). Returns
    ``None`` if any axis cannot be resolved (an unmaterialized derived set, an
    unknown name) so the caller can fall back to usage-inferred shapes.
    """
    derived_extents = derived_extents or {}
    dims: list[int] = []
    for axis in decl_shape:
        entry = index_sets.get(axis) if isinstance(index_sets, dict) else None
        if not isinstance(entry, dict):
            return None
        kind = entry.get("kind")
        if kind == "interval":
            size = entry.get("size")
            if not isinstance(size, int):
                return None
            dims.append(int(size))
        elif kind == "derived":
            ext = derived_extents.get(entry.get("from_faq"))
            if ext is None:
                return None
            dims.append(int(ext))
        else:
            return None
    return tuple(dims)


def _vi_lhs_base(lhs: Expr) -> str | None:
    """Base variable name written by an equation LHS: ``name``,
    ``index(name, …)`` or ``D(name, …)``. ``None`` if unrecognised."""
    if isinstance(lhs, str):
        return lhs
    if isinstance(lhs, ExprNode) and lhs.op in ("index", "D") and lhs.args:
        return _vi_lhs_base(lhs.args[0])
    return None


def _detect_value_invention_states(
    flat: FlattenedSystem,
) -> tuple[set[str], list[tuple[str, ExprNode, str | None]]]:
    """Detect value-invention state vars written by a skolem / distinct aggregate.

    Returns ``(vi_var_names, bin_specs)`` where ``bin_specs`` is a list of
    ``(var_name, aggregate_node, index_set_name)`` for the per-cell skolem MAP
    buffers (the broad-phase bins ``rg_src_bin`` / ``rg_tgt_bin``) a downstream
    ``join.on`` gates on. A ``distinct`` producer (the candidate-set membership)
    is a VI var too — dropped from the ODE — but needs no build-time buffer here
    (nothing ranges over its derived set for surface_heat_flux). Mirrors
    ``value_invention._vi_node_kind``, working directly on the flattened
    ExprNodes, which preserve ``distinct`` / ``key`` / ``join`` (unlike a
    serialized round-trip). Non-fixture-specific: any state assigned by a skolem
    or distinct aggregate is a build-time relational output, not an ODE state.
    """
    vi_var_names: set[str] = set()
    bin_specs: list[tuple[str, ExprNode, str | None]] = []
    states = flat.state_variables
    for eq in flat.equations:
        base = _vi_lhs_base(eq.lhs)
        if base is None or base not in states:
            continue
        rhs = eq.rhs
        if not (isinstance(rhs, ExprNode) and rhs.op == "aggregate"):
            continue
        skolem_body = isinstance(rhs.expr, ExprNode) and rhs.expr.op == "skolem"
        skolem_key = isinstance(rhs.key, ExprNode) and rhs.key.op == "skolem"
        if rhs.distinct is True:
            vi_var_names.add(base)  # candidate-set producer — drop from ODE
        elif skolem_body or skolem_key:
            vi_var_names.add(base)
            decl = getattr(states[base], "shape", None)
            bin_specs.append((base, rhs, decl[0] if decl else None))
    return vi_var_names, bin_specs


def _materialize_join_key_buffers(
    ordered_observed: list[tuple[str, Expr]],
    bin_specs: list[tuple[str, ExprNode, str | None]],
    index_sets: dict[str, Any],
    param_values: dict[str, float],
    shapes: dict[str, tuple[int, ...]],
    state_layout: dict[str, slice],
    total_size: int,
    factor_scope: dict[str, str] | None = None,
) -> tuple[dict[str, np.ndarray], dict[str, str]]:
    """Materialize the broad-phase bin buffers ONCE at setup (RFC §5.3).

    The bins depend only on constant geometry (the source / target polygons and
    the ``rg_dx`` / ``rg_dy`` params), so they are computed here, off the
    per-step hot path. Every join-FREE constant observed the bins read (the
    binning coordinates ``rg_src_lon`` … via the polygon aggregates) is
    materialized into a setup context first; then each bin aggregate is evaluated
    to its per-cell integer-code buffer. Returns ``(buffers, index_sets)`` keyed
    by bin var name — the ``EvalContext.join_key_buffers`` / ``…_index_sets`` a
    downstream ``join.on [[rg_src_bin, rg_tgt_bin]]`` gates on.
    """
    buffers: dict[str, np.ndarray] = {}
    idx_sets: dict[str, str] = {}
    if not bin_specs:
        return buffers, idx_sets
    ctx = EvalContext(
        state_layout=state_layout,
        state_shapes=shapes,
        param_values=param_values,
        observed_values={},
        y=np.zeros(total_size, dtype=float),
        t=0.0,
        index_sets=index_sets,
        factor_scope=dict(factor_scope or {}),
    )
    # Join-carrying observeds (rg_A / rg_At / rg_W / surface_heat_flux) gate on
    # the bins themselves, so they are NOT materialized here. Nor is every
    # join-free observed: a join-free observed may itself READ a join-carrying
    # observed (e.g. a reduction `total = sum(rg_A)`), which is unresolvable at
    # bin-setup time. Materialize ONLY the join-free observeds the bins
    # transitively depend on — the binning coordinates and their own inputs.
    join_free = [
        (name, rhs)
        for name, rhs in ordered_observed
        if not (isinstance(rhs, ExprNode) and getattr(rhs, "join", None))
    ]
    join_free_names = {name for name, _ in join_free}
    rhs_by_name = dict(ordered_observed)
    # Dependency closure of the bin specs over the join-free observeds.
    needed: set[str] = set()
    frontier: list[str] = []
    for _bn, node, _idx in bin_specs:
        for r in _expr_referenced_names(node) & join_free_names:
            if r not in needed:
                needed.add(r)
                frontier.append(r)
    while frontier:
        cur = frontier.pop()
        for r in _expr_referenced_names(rhs_by_name[cur]) & join_free_names:
            if r not in needed:
                needed.add(r)
                frontier.append(r)
    # Preserve the dependency-sorted order of `ordered_observed`.
    _materialize_observeds([(name, rhs) for name, rhs in join_free if name in needed], ctx)
    for name, node, idx_set in bin_specs:
        buffers[name] = np.asarray(eval_expr(node, ctx), dtype=float).reshape(-1)
        if idx_set is not None:
            idx_sets[name] = idx_set
    return buffers, idx_sets


def _fill_build_inspection(
    sink: BuildInspection,
    flat: FlattenedSystem,
    build: _NumpyRhsBuild,
    t0: float,
    loader_arrays: dict[str, np.ndarray] | None = None,
) -> None:
    """Copy the named build-time products of a NumPy RHS build into the
    caller's :class:`BuildInspection` sink (the ``inspect`` kwarg of
    :func:`simulate`). Read-only with respect to the build — nothing
    downstream consults the sink, so the simulation is identical with or
    without it.

    The STATE-FREE observeds (no transitive state / ``t`` reference — the
    complement of :func:`_time_varying_observeds`, a dependency-closed set)
    are materialized once into a fresh context; each array-valued one is
    recorded in ``setup_arrays`` under its flattened name (the per-pair regrid
    geometry ``A_ij`` / ``A_j`` / ``W_ij``, a mesh subsystem's connectivity
    factors, …). A DEAD state-free observed whose body cannot be evaluated (a
    passive-axis ``dy = 1/NY`` with ``NY`` closed at an import edge) is skipped
    — the sink is read-only and records only array observeds, so an
    unevaluable scalar nothing consumes contributes nothing to it (the RHS
    driver already prunes such observeds from its dependency cone)."""
    for name, rhs in build.ordered_observed:
        sink.observed_exprs[name] = rhs
    for k, arr in build.join_key_buffers.items():
        sink.const_arrays[k] = arr
    for k, arr in (loader_arrays or {}).items():
        sink.const_arrays[k] = arr
    # Resolved scalar parameters (load-time constants) so the reference / ic
    # positions can bind them into a build-time cellwise evaluation, matching
    # the observed-assertion form (materialized below with these values).
    for k, v in build.param_values.items():
        sink.params[str(k)] = float(v)
    # The state-free array observeds were already materialized once by the build
    # (the const-geometry hoist), so read them straight from the build rather than
    # re-running the expensive geometry a second time here. Each is recorded in
    # ``setup_arrays`` under its flattened name (``A_ij`` / ``A_j`` / ``W_ij``,
    # regridded fields, per-cell slopes, a mesh subsystem's connectivity, …).
    # ``t0`` is irrelevant to a state-free body, so the values match regardless of
    # the ``t`` the hoist used.
    for name, arr in build.static_derived_rings.items():
        sink.setup_arrays[name] = np.array(arr, dtype=float)


def _partition_and_materialize_observeds(
    ordered_observed: list[tuple[str, Expr]],
    state_names: list[str],
    flat: FlattenedSystem,
    shapes: dict[str, tuple[int, ...]],
    state_layout: dict[str, slice],
    param_values: dict[str, float],
    y0: np.ndarray,
    loader_arrays: dict[str, np.ndarray],
    join_key_buffers: dict[str, np.ndarray],
    join_key_index_sets: dict[str, str],
    factor_scope: dict[str, str],
    static_cache: dict[str, Any] | None,
) -> tuple[list[tuple[str, Expr]], dict[str, float], dict[str, np.ndarray]]:
    """Split the dependency-ordered observeds and materialize the static ones ONCE.

    Performs the const-geometry hoist for :func:`_build_numpy_rhs`: a first split
    into TIME-VARYING (transitively references a state or ``t``) vs STATE-FREE
    observeds, then a cadence split of the state-free half into loader-INVARIANT
    (materialized once and cached in ``static_cache``) vs loader-VOLATILE
    (re-materialized per cadence segment, seeded with the invariant products).

    Returns ``(varying_observed, static_observed_values, static_derived_rings)``:
    the dependency-ordered time-varying subset the per-step RHS must re-evaluate,
    and the once-materialized static scalars / arrays every context is seeded
    with. Behaviour is identical to a single combined pass — a state-free body is
    constant along the trajectory, and a const observed can never reference a
    loader-dependent one — but the expensive const geometry runs once instead of
    per step / per segment.
    """
    # Const-geometry hoist: split observeds into STATE-FREE (constant along the
    # trajectory) and TIME-VARYING, and materialize the static ones ONCE here.
    # An observed that transitively references neither a state nor `t` evaluates
    # to the same value every RHS call, so re-running it per step is pure waste —
    # and for a conservative-regrid model the static half (the `intersect_polygon`
    # overlap-area `A_ij`, its row-sums, the regridded elevation, the per-cell
    # slopes) dominates a single evaluation. Materializing it once and seeding
    # every per-step / per-output context with the result leaves only the cheap
    # ∇ψ-dependent front stencils on the hot path, without changing any value
    # (`_time_varying_observeds` is the same forward propagation the output
    # reconstruction uses). `skip_unresolved` mirrors the per-step driver: a dead
    # static observed nothing consumes is dropped, not fatal.
    _varying_names = _time_varying_observeds(ordered_observed, set(state_names))
    static_observed = [(n, r) for n, r in ordered_observed if n not in _varying_names]
    varying_observed = [(n, r) for n, r in ordered_observed if n in _varying_names]

    # Cadence split of the STATE-FREE static observeds (esm-spec §5.7 / cadence.py):
    # loader-INVARIANT geometry (no loader dependence at all — the regrid weights
    # A_ij, their row-sums A_j, the normalized W_ij, from grid coords + params) vs
    # loader-DEPENDENT (transitively reads a bound loader array — the regrid APPLY
    # W·field, the fire-behaviour stack it feeds). Only the invariant half is
    # guaranteed identical across cadence segments, so it is materialized ONCE and
    # cached; the loader-dependent half is re-materialized per segment (seeded with
    # the invariant products it consumes). Any loader is treated as volatile — the
    # cadence-segmented driver refreshes discrete slices in place, and re-applying a
    # const loader is merely redundant, never wrong (whereas caching a discrete
    # apply would FREEZE its stale seed slice). Loader fields survive flatten only
    # for some pipelines (others strip the discrete decls, leaving `loader_fields`
    # empty), so key off the actually-bound `loader_arrays` — plus any surviving
    # `loader_fields` names — rather than a post-flatten cadence tag. A const
    # observed can never reference a loader-dependent one, so invariant-then-
    # loader-dependent reproduces the single combined pass value-for-value — the
    # split is transparent when `static_cache is None`.
    volatile_loader_names = set(loader_arrays) | {lf.name for lf in flat.loader_fields}
    _volatile_names = _loader_volatile_observeds(static_observed, volatile_loader_names)
    invariant_static = [(n, r) for n, r in static_observed if n not in _volatile_names]
    volatile_static = [(n, r) for n, r in static_observed if n in _volatile_names]

    if static_cache is not None and "invariant_observed_values" in static_cache:
        invariant_observed_values = static_cache["invariant_observed_values"]
        invariant_derived_rings = static_cache["invariant_derived_rings"]
    else:
        invariant_observed_values = {}
        invariant_derived_rings = {}
        if invariant_static:
            _inv_ctx = EvalContext(
                state_layout=state_layout,
                state_shapes=shapes,
                param_values=param_values,
                observed_values=invariant_observed_values,
                y=y0,
                t=0.0,
                index_sets=flat.index_sets,
                input_arrays=loader_arrays if loader_arrays is not None else {},
                join_key_buffers=join_key_buffers,
                join_key_index_sets=join_key_index_sets,
                factor_scope=factor_scope,
            )
            _materialize_observeds(invariant_static, _inv_ctx, skip_unresolved=True)
            invariant_derived_rings = _inv_ctx.derived_rings
        if static_cache is not None:
            static_cache["invariant_observed_values"] = invariant_observed_values
            static_cache["invariant_derived_rings"] = invariant_derived_rings

    # Reusable constant-geometry OPERATOR cache (#3): every name the invariant pass
    # materialized is loader-invariant, so a weight operator capturing only those
    # factors is safe to reuse across cadence segments. The op cache lives in the
    # caller's ``static_cache`` so it persists across rebuilds; a single-shot build
    # (no ``static_cache``) leaves it ``None`` — the node is materialized once, so
    # there is nothing to reuse and the dense #1 path handles it.
    invariant_names = frozenset(invariant_observed_values) | frozenset(invariant_derived_rings)
    op_cache = static_cache.setdefault("op_cache", {}) if static_cache is not None else None

    static_observed_values: dict[str, float] = dict(invariant_observed_values)
    static_derived_rings: dict[str, np.ndarray] = dict(invariant_derived_rings)
    if volatile_static:
        _vol_ctx = EvalContext(
            state_layout=state_layout,
            state_shapes=shapes,
            param_values=param_values,
            observed_values=static_observed_values,
            y=y0,
            t=0.0,
            index_sets=flat.index_sets,
            derived_rings=static_derived_rings,
            input_arrays=loader_arrays if loader_arrays is not None else {},
            join_key_buffers=join_key_buffers,
            join_key_index_sets=join_key_index_sets,
            factor_scope=factor_scope,
            op_cache=op_cache,
            invariant_names=invariant_names,
        )
        _materialize_observeds(volatile_static, _vol_ctx, skip_unresolved=True)
        static_observed_values = _vol_ctx.observed_values
        static_derived_rings = _vol_ctx.derived_rings

    return varying_observed, static_observed_values, static_derived_rings


def _build_numpy_rhs(
    flat: FlattenedSystem,
    parameters: dict[str, float],
    initial_conditions: dict[str, float],
    loader_arrays: dict[str, np.ndarray] | None = None,
    static_cache: dict[str, Any] | None = None,
) -> _NumpyRhsBuild:
    """Assemble the NumPy-interpreter RHS closure + state layout for a flattened
    array/PDE system. Shared by :func:`_simulate_with_numpy` (which integrates
    it) and :func:`evaluate_rhs` (which evaluates it once at a probe state); the
    cross-language PDE-simulation conformance tier drives the latter so a binding
    can report f(u, t) at a fixed state, mirroring the Rust ``debug_eval_rhs``.

    ``static_cache``: an OPT-IN, caller-owned dict that persists the loader-
    INVARIANT build products (the value-invention join-key buffers and the
    materialized conservative-regrid GEOMETRY — the ``A_ij``/``A_j``/``W_ij``
    weights) across repeated builds of the SAME flattened system. The cadence-
    segmented loader driver (:func:`simulation_loaders._run_cadence_segmented_solve`)
    rebuilds the RHS once per segment so a discrete loader's refreshed slice is
    picked up; only the loader-VOLATILE observeds (the regrid APPLY ``W·field``)
    actually change between segments, so this reuses the const geometry instead of
    re-clipping it every hour. ``None`` (every non-segmented caller) recomputes
    everything, exactly as before — the split is otherwise value-transparent."""
    shapes = infer_variable_shapes(flat)
    # Prefer the concrete grid shapes assigned by the pointwise lift (esm-spec
    # §10.5). A lifted species' own operator makearray reads offset cells
    # (``index(sp, i+1, j)``) that would otherwise widen the index-use-inferred
    # extent past the true grid; the lift's recorded extent is authoritative.
    if flat.lifted_shapes:
        shapes.update(flat.lifted_shapes)
    # Declared-shape resolution (esm-spec §11): a state's declared ``shape``
    # (index-set names) is authoritative over usage inference — a whole-array
    # ``D(SST)`` never index-uses SST, so inference alone collapses it to a
    # scalar. Resolve each declared shape against the index-set registry so the
    # array state gets its true per-cell extent (ocean_cells → 3).
    for _name, _var in flat.state_variables.items():
        _decl = getattr(_var, "shape", None)
        if _decl:
            _res = _resolve_index_set_shape(_decl, flat.index_sets)
            if _res is not None:
                shapes[_name] = _res
    # Value-invention states (broad-phase bins / candidate-set membership) are
    # materialized at setup and DROPPED from the ODE (RFC §5.3 / §6.1).
    vi_var_names, bin_specs = _detect_value_invention_states(flat)
    state_names = [n for n in flat.state_variables.keys() if n not in vi_var_names]
    observed_names: set[str] = set(flat.observed_variables.keys())
    loader_arrays = loader_arrays or {}

    # Layout: concatenate every state variable's flattened payload.
    state_layout: dict[str, slice] = {}
    offset = 0
    for name in state_names:
        shape = shapes.get(name, ())
        size = int(np.prod(shape)) if shape else 1
        state_layout[name] = slice(offset, offset + size)
        offset += size
    total_size = offset

    if total_size == 0:
        raise SimulationError("Flattened system has no state variables to integrate")

    # Partition equations: an observed assignment is ``name = <body>`` whose
    # LHS is an observed variable name (flatten lowers each observed's
    # `expression` to such an equation). These are materialized into the eval
    # context in dependency order BEFORE the state derivatives each RHS call,
    # so an observed `clip = intersect_polygon(...)` ring and the
    # `area = sum_product FAQ(clip)` that consumes it are available when
    # `D(tracer) = -area·tracer` evaluates. Everything else (state ODEs,
    # algebraic constraints) flows through the existing driver path.
    observed_eqs: list[tuple[str, Expr]] = []
    driver_equations: list[FlattenedEquation] = []
    # Scoped-reference / array ``ic`` equations (esm-spec §11.4.1): LHS is an
    # ``ic`` op naming a (lifted) ARRAY state; RHS is the initial FIELD. These are
    # NOT ODE drivers — they fold into u0 at build time (below), so route them
    # out. Scalar ``ic`` targets are left on the driver path (their historic,
    # no-op handling) so scalar-ic fixtures behave exactly as before.
    field_ic_eqs: list[tuple[str, Expr]] = []
    for eq in flat.equations:
        # Value-invention state assignments (bin skolem maps, distinct
        # candidate-set membership) are materialized at setup, not integrated.
        _base = _vi_lhs_base(eq.lhs)
        if _base is not None and _base in vi_var_names:
            continue
        if (
            isinstance(eq.lhs, ExprNode)
            and eq.lhs.op == "ic"
            and eq.lhs.args
            and isinstance(eq.lhs.args[0], str)
            and shapes.get(eq.lhs.args[0])
        ):
            field_ic_eqs.append((eq.lhs.args[0], eq.rhs))
        elif isinstance(eq.lhs, str) and eq.lhs in observed_names:
            observed_eqs.append((eq.lhs, eq.rhs))
        else:
            driver_equations.append(eq)
    ordered_observed = _order_observed_equations(observed_eqs, observed_names)

    # Algebraic elimination: eliminate simple ``v[i] = <body>`` equations.
    working_equations, _eliminated = _collect_algebraic_substitutions(driver_equations)
    if _eliminated:
        working_equations = [
            FlattenedEquation(
                lhs=_substitute_algebraic(eq.lhs, _eliminated),
                rhs=_substitute_algebraic(eq.rhs, _eliminated),
                source_system=eq.source_system,
            )
            for eq in working_equations
        ]

    # Parameter resolution: overrides win over defaults.
    param_values: dict[str, float] = {}
    for pname, pvar in flat.parameters.items():
        bare = pname.rsplit(".", 1)[-1]
        val = _resolve_override(pname, parameters, pvar.default)
        param_values[pname] = val
        param_values[bare] = val  # also expose via bare name

    # Keyed-factor scope (esm-spec §5.4 / RFC §5.2): a RAGGED index set's
    # `offsets`/`values` keyed factors bind by BARE name in the model scope, but
    # flattening prefixes every variable with its owning component path while
    # the document-scoped registry keeps the authored bare name. Resolve each
    # bare factor name against the flattened variable scope ONCE at build —
    # exact name wins, else the unique dot-suffix match at the shallowest
    # namespace depth (the model's own re-exposed alias, not the mounted
    # subsystem's original); genuine ambiguity keeps the bare name so the
    # existing unresolved-symbol error surfaces. Mirrors the Julia tree-walk
    # `_factor_scope`. Empty (byte-identical) without ragged index sets.
    factor_scope = ragged_factor_scope(
        flat.index_sets,
        list(flat.state_variables) + list(flat.observed_variables) + list(flat.parameters),
    )

    # Value-invention bin buffers (RFC §5.3): materialize the broad-phase bins
    # (``rg_src_bin`` / ``rg_tgt_bin``) once, from constant geometry + params, so
    # a downstream ``join.on [[rg_src_bin, rg_tgt_bin]]`` can gate the regrid.
    # These inputs (index sets, params, shapes, layout) are fixed for the run, so
    # a cadence-segmented rebuild reuses them from ``static_cache`` rather than
    # re-binning every segment.
    if static_cache is not None and "join_key_buffers" in static_cache:
        join_key_buffers = static_cache["join_key_buffers"]
        join_key_index_sets = static_cache["join_key_index_sets"]
    else:
        join_key_buffers, join_key_index_sets = _materialize_join_key_buffers(
            ordered_observed,
            bin_specs,
            flat.index_sets,
            param_values,
            shapes,
            state_layout,
            total_size,
            factor_scope=factor_scope,
        )
        if static_cache is not None:
            static_cache["join_key_buffers"] = join_key_buffers
            static_cache["join_key_index_sets"] = join_key_index_sets

    # Initial conditions.
    y0 = np.zeros(total_size, dtype=float)
    for name in state_names:
        default = flat.state_variables[name].default
        if isinstance(default, (int, float)):
            sl = state_layout[name]
            y0[sl] = float(default)
    # Scoped-reference / array ``ic`` fold (esm-spec §11.4.1): now that each array
    # state's grid shape is known, fold every deferred field-ic into per-element
    # initial values. The RHS may be a LOADED FIELD (a ``loader_arrays`` entry —
    # provider-seeded at build time, DESIGN §2 R2) supplying the initial field
    # over the lifted grid, or a broadcast constant. Runs before the explicit
    # per-element overrides so those still win.
    _fold_field_ics(
        y0,
        field_ic_eqs,
        shapes,
        state_layout,
        loader_arrays,
        index_sets=flat.index_sets,
        param_values=param_values,
    )
    _apply_initial_conditions(y0, state_layout, shapes, state_names, initial_conditions)

    # Const-geometry hoist + cadence split of the observeds: materialize the
    # STATE-FREE (loader-invariant, then loader-volatile) observeds ONCE here and
    # return the dependency-ordered TIME-VARYING subset the per-step RHS must
    # re-evaluate. See :func:`_partition_and_materialize_observeds`.
    varying_observed, static_observed_values, static_derived_rings = (
        _partition_and_materialize_observeds(
            ordered_observed,
            state_names,
            flat,
            shapes,
            state_layout,
            param_values,
            y0,
            loader_arrays,
            join_key_buffers,
            join_key_index_sets,
            factor_scope,
            static_cache,
        )
    )

    # Per-call buffers hoisted out of rhs_function and reused across every
    # solver step, eliminating the two guaranteed per-step allocations.
    # solve_ivp's RK/BDF/LSODA integrators copy the returned dydt into their
    # own workspace before the next call, so returning one shared `dy` each
    # step is safe (calls are sequential, never concurrent). `dy.fill(0.0)`
    # restores the exact zero-initialized start state a fresh
    # `np.zeros(total_size)` would give — slots that no equation writes stay
    # 0 — so results are byte-for-byte identical. `_finite_mask` lets the
    # divergence guard reuse one bool array via `np.isfinite(dy, out=...)`
    # instead of allocating a full-size transient mask every step; the
    # predicate (all-finite) is unchanged.
    dy = np.zeros(total_size, dtype=float)
    _finite_mask = np.empty(total_size, dtype=bool)

    def rhs_function(t: float, y: np.ndarray) -> np.ndarray:
        ctx = EvalContext(
            state_layout=state_layout,
            state_shapes=shapes,
            param_values=param_values,
            # Seed the fresh context with the const-geometry hoist (materialized
            # once at build): scalars into observed_values, arrays into
            # derived_rings. Copies so the per-step varying observeds append into
            # a private context without mutating the shared static products.
            observed_values=dict(static_observed_values),
            y=y,
            t=t,
            index_sets=flat.index_sets,
            derived_rings=dict(static_derived_rings),
            # Bind the SHARED loader-array registry by reference. Within a cadence
            # segment its contents are fixed, so the RHS is pure; the segmenting
            # driver mutates it in place between segments to advance the cadence.
            input_arrays=loader_arrays if loader_arrays is not None else {},
            join_key_buffers=join_key_buffers,
            join_key_index_sets=join_key_index_sets,
            factor_scope=factor_scope,
        )
        # Materialize array-valued observeds + derived rings and scalar
        # observeds into the context (dependency-ordered) so the state
        # derivatives below can reference them. Re-run each call because an
        # observed may depend on the current state y (and the derived_rings /
        # observed_values registries are fresh per EvalContext).
        #
        # `skip_unresolved`: a DEAD observed nothing in the ODE reads — e.g. a
        # passive-axis `dy = 1/NY` whose count NY was closed at an import edge
        # and so stays a bare symbol after §9.7 resolution in BOTH the Julia and
        # Python resolvers (esm-spec §9.7.6) — is skipped rather than aborting
        # the integration, matching the Julia reference (its tree-walk only
        # evaluates observeds in the state-derivative dependency cone, so it
        # never touches a dead one). This can only DROP an observed nothing
        # consumes: a live observed a driver equation actually reads still
        # surfaces a clear unresolved-symbol error when that equation evaluates
        # below (the numpy interpreter never defaults an unbound name), so no
        # real defect is masked and the state trajectory is unchanged. CPython's
        # zero-cost exceptions make the guard free on the common (no-dead) path.
        try:
            _materialize_observeds(varying_observed, ctx, skip_unresolved=True)
        except NumpyInterpreterError as exc:
            raise SimulationError(str(exc)) from exc
        dy.fill(0.0)
        for eq in working_equations:
            try:
                _apply_equation_to_dy(eq, ctx, shapes, state_layout, dy)
            except NumpyInterpreterError as exc:
                raise SimulationError(str(exc)) from exc
        np.isfinite(dy, out=_finite_mask)
        if not _finite_mask.all():
            raise SimulationError("Non-finite derivatives encountered")
        return dy

    elem_names = _element_names(state_names, shapes)
    return _NumpyRhsBuild(
        rhs_function=rhs_function,
        y0=y0,
        total_size=total_size,
        state_names=state_names,
        shapes=shapes,
        state_layout=state_layout,
        param_values=param_values,
        ordered_observed=ordered_observed,
        elem_names=elem_names,
        varying_observed=varying_observed,
        static_observed_values=static_observed_values,
        static_derived_rings=static_derived_rings,
        join_key_buffers=join_key_buffers,
        join_key_index_sets=join_key_index_sets,
        factor_scope=factor_scope,
    )


def evaluate_rhs(
    file_or_flat: EsmFile | FlattenedSystem,
    state: dict[str, float],
    t: float = 0.0,
    parameters: dict[str, float] | None = None,
) -> dict[str, float]:
    """Evaluate the discretized method-of-lines RHS f(state, t) of an
    array/PDE model, returning a ``{element_name: derivative}`` map keyed by the
    column-major element names (``u[1]``, ``u[2,3]``, ...).

    This is the single-shot RHS hook the cross-language PDE-simulation
    conformance tier (bead ess-fmw) uses to check that Julia, Python, and Rust
    agree on the *discretized RHS* independently of any integrator. ``state``
    supplies the value of every state element (same keying as
    ``initial_conditions`` in :func:`simulate`)."""
    flat = file_or_flat if isinstance(file_or_flat, FlattenedSystem) else flatten(file_or_flat)
    if len(flat.independent_variables) > 1:
        raise UnsupportedDimensionalityError(
            "unlowered_operator: evaluate_rhs supports only time-dependent "
            "(pre-discretized) systems; got independent variables "
            f"{sorted(flat.independent_variables)} — an unlowered spatial operator"
        )
    build = _build_numpy_rhs(flat, dict(parameters or {}), dict(state))
    dy = build.rhs_function(float(t), build.y0)
    return {name: float(val) for name, val in zip(build.elem_names, dy)}


def _simulate_with_numpy(
    flat: FlattenedSystem,
    tspan: tuple[float, float],
    parameters: dict[str, float],
    initial_conditions: dict[str, float],
    method: str,
    rtol: float = 1e-10,
    atol: float = 1e-12,
    loader_arrays: dict[str, np.ndarray] | None = None,
    inspect: BuildInspection | None = None,
) -> SimulationResult:
    """Simulate a flattened system containing array ops via the NumPy interpreter.

    ``loader_arrays`` maps each declared loader field name (``<Loader>.<var>``) to
    its provider-materialized array (DESIGN pde_simulation_pipeline §2): the
    RHS resolves those names through :class:`EvalContext.input_arrays`, and any
    scoped-reference ``ic`` folds them into u0 at build time (R2).

    ``inspect`` is the optional :class:`BuildInspection` observability sink,
    filled right after the RHS build (see :func:`_fill_build_inspection`);
    nothing downstream consults it, so results are identical either way."""
    try:
        build = _build_numpy_rhs(flat, parameters, initial_conditions, loader_arrays=loader_arrays)
        if inspect is not None:
            _fill_build_inspection(
                inspect, flat, build, float(tspan[0]), loader_arrays=loader_arrays
            )
        shapes = build.shapes
        state_names = build.state_names
        state_layout = build.state_layout
        param_values = build.param_values
        ordered_observed = build.ordered_observed
        y0 = build.y0
        rhs_function = build.rhs_function

        sol = solve_ivp(
            fun=rhs_function,
            t_span=tspan,
            y0=y0,
            method=method,
            rtol=rtol,
            atol=atol,
            dense_output=True,
        )

        elem_names = _element_names(state_names, shapes)
        t_out, y_out = _densify_solution(sol, tspan)

        # Expose scalar observed trajectories alongside the states (parity with
        # the scalar SymPy path) so callers / conformance fixtures can assert on
        # algebraic quantities like `area`. Re-evaluate the observeds from the
        # state trajectory at each output time; array-valued observeds (e.g. the
        # clip ring) are not scalar rows and are skipped.
        out_vars: list[str] = list(elem_names)
        if ordered_observed and y_out.size:
            try:
                varying = _time_varying_observeds(ordered_observed, set(state_names))
                if not varying:
                    # All observeds are constant along the trajectory: evaluate
                    # once and broadcast, instead of re-clipping at every one of
                    # the (dense) output nodes.
                    ctx = EvalContext(
                        state_layout=state_layout,
                        state_shapes=shapes,
                        param_values=param_values,
                        observed_values={},
                        y=y_out[:, 0],
                        t=float(t_out[0]),
                        index_sets=flat.index_sets,
                        join_key_buffers=build.join_key_buffers,
                        join_key_index_sets=build.join_key_index_sets,
                        factor_scope=build.factor_scope,
                    )
                    _materialize_observeds(ordered_observed, ctx)
                    scalar_obs = [n for n, _ in ordered_observed if n in ctx.observed_values]
                    if scalar_obs:
                        obs_block = _observed_rows(
                            [ctx.observed_values[n] for n in scalar_obs], t_out.size
                        )
                        y_out = np.vstack([y_out, obs_block])
                        out_vars.extend(scalar_obs)
                else:
                    # Const-geometry hoist (parity with the RHS driver): the
                    # static observeds were materialized once at build, so seed
                    # each output node's context with them and re-evaluate only the
                    # time-varying observeds — identical values to a full per-node
                    # materialize, but the expensive const geometry is not re-run
                    # at every (dense) output node.
                    varying_observed = build.varying_observed
                    obs_rows: dict[str, np.ndarray] = {
                        name: np.empty(t_out.size, dtype=float) for name, _ in varying_observed
                    }
                    obs_is_scalar: dict[str, bool] = {name: True for name, _ in varying_observed}
                    for j in range(t_out.size):
                        ctx = EvalContext(
                            state_layout=state_layout,
                            state_shapes=shapes,
                            param_values=param_values,
                            observed_values=dict(build.static_observed_values),
                            y=y_out[:, j],
                            t=float(t_out[j]),
                            index_sets=flat.index_sets,
                            derived_rings=dict(build.static_derived_rings),
                            join_key_buffers=build.join_key_buffers,
                            join_key_index_sets=build.join_key_index_sets,
                            factor_scope=build.factor_scope,
                        )
                        # Per-observed skip policy (parity with the per-step RHS
                        # driver): a single DEAD observed that cannot be evaluated
                        # is dropped, not fatal — otherwise the outer
                        # ``except NumpyInterpreterError`` would discard ALL
                        # observed rows for one unresolvable observed.
                        _materialize_observeds(varying_observed, ctx, skip_unresolved=True)
                        for name, _ in varying_observed:
                            if name in ctx.observed_values:
                                obs_rows[name][j] = ctx.observed_values[name]
                            else:
                                obs_is_scalar[name] = False
                    # Row order follows ordered_observed; a static scalar is a
                    # constant column (broadcast), a varying scalar its per-node
                    # trajectory. Array-valued observeds are not scalar rows.
                    row_names: list[str] = []
                    row_vals: list[Any] = []
                    for name, _ in ordered_observed:
                        if name in build.static_observed_values:
                            row_names.append(name)
                            row_vals.append(build.static_observed_values[name])
                        elif obs_is_scalar.get(name):
                            row_names.append(name)
                            row_vals.append(obs_rows[name])
                    if row_vals:
                        y_out = np.vstack([y_out, _observed_rows(row_vals, t_out.size)])
                        out_vars.extend(row_names)
            except NumpyInterpreterError:
                # Output-time observed recovery is cosmetic; never fail an
                # otherwise-successful integration because a post-hoc observed
                # sample could not be evaluated.
                out_vars = list(elem_names)

        return SimulationResult(
            t=t_out,
            y=y_out,
            vars=out_vars,
            success=sol.success,
            message=sol.message,
            nfev=sol.nfev,
            njev=sol.njev,
            nlu=sol.nlu,
        )

    except UnsupportedDimensionalityError:
        raise
    except Exception as e:
        return _failure_result(f"Simulation failed: {e}")
