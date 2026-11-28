"""The initialization system (esm 2.5.0; esm-spec §11.4.2–§11.4.3).

An *initialization equation* mentions ``ic`` anywhere. Flatten splits them:
an EXPLICIT initial condition ``ic(u) ~ e`` (``e`` mentions no ``ic``) goes to
``FlattenedSystem.field_ics`` and is folded by the builders as before; every
other one goes to ``FlattenedSystem.initialization_equations``, the equations
of the initialization system, which this module plans:

1. a trajectory read (a state, bare or under ``D``, outside ``ic``) is refused
   with ``ic_reads_state`` (:func:`refuse_trajectory_reads`);
2. ``ic(y)`` of an observed and ``ic(D(x))`` are expanded into the starting
   values they read (§11.4.2 item 8, :func:`expand_start_values`);
3. the system is balanced per element — supplied values of ODE states and the
   cells explicit initial conditions set are its knowns, every other starting
   value an equation mentions is an unknown, and a ``default`` is never a
   value of the system — or refused with ``ic_system_unbalanced``;
4. the triangular part (each equation ``ic(u) ~ e`` explicit in one unknown,
   acyclic) becomes ordered :attr:`InitPlan.steps` the builder evaluates by
   substitution; the rest (equations not explicit in their unknown, cycles,
   and the equations downstream of their unknowns) is refused with
   ``unsupported_construct``, or, under ``strip`` class ``initialization``,
   handed to the caller (:func:`initialization_member`).

Python has no nonlinear initialization solve, so ``ic_system_unsolved`` is never
raised here.
"""

from __future__ import annotations

import math
from collections.abc import Callable, Iterable
from dataclasses import dataclass, field
from typing import Any

import numpy as np

from .error_handling import IC_SYSTEM_UNBALANCED
from .errors import IcReadsStateError, SimulationError
from .esm_types import Expr, ExprNode
from .expr_walk import map_children, walk

__all__ = [
    "IcSystemUnbalancedError",
    "InitPlan",
    "expand_start_values",
    "initialization_member",
    "plan_initialization",
    "refuse_trajectory_reads",
    "start_value_reads",
    "starting_values_as_states",
]


class IcSystemUnbalancedError(SimulationError):
    """``ic_system_unbalanced`` (esm-spec §11.4.3): the initialization system
    has more scalar equations than unknowns, or fewer, or no assignment of a
    distinct equation to every unknown."""

    code = IC_SYSTEM_UNBALANCED


# ---------------------------------------------------------------------------
# Expression helpers
# ---------------------------------------------------------------------------


def _is_ic(e: Any) -> bool:
    return isinstance(e, ExprNode) and e.op == "ic" and len(e.args) == 1


def start_value_reads(expr: Expr) -> set[str]:
    """The unknowns whose starting value ``expr`` reads: the ``w`` of every
    ``ic(w)``."""
    out: set[str] = set()
    for n in walk(expr):
        if _is_ic(n) and isinstance(n.args[0], str):
            out.add(n.args[0])
    return out


def _outside_ic(expr: Expr) -> Expr:
    """``expr`` with every ``ic(·)`` subtree replaced by ``0``: what remains is
    what it reads of the trajectory."""
    if _is_ic(expr):
        return 0.0
    if isinstance(expr, ExprNode):
        return map_children(expr, _outside_ic)
    return expr


def starting_values_as_states(expr: Expr) -> Expr:
    """``expr`` with every ``ic(w)`` read as the bare ``w``. The builders
    evaluate a step against a scope that binds each state's name to its
    starting value, which is what ``ic(w)`` denotes there; a bare state read
    outside ``ic`` was refused before (:func:`refuse_trajectory_reads`)."""
    if _is_ic(expr) and isinstance(expr.args[0], str):
        return expr.args[0]
    if isinstance(expr, ExprNode):
        return map_children(expr, starting_values_as_states)
    return expr


def _unsupported(construct: str, detail: str) -> Exception:
    from .expression import UnsupportedConstructError

    return UnsupportedConstructError(construct, detail, "NumPy interpreter")


def expand_start_values(
    expr: Expr,
    observed_defs: dict[str, Expr],
    tendencies: dict[str, Expr],
    unknowns: set[str],
) -> Expr:
    """esm-spec §11.4.2 item 8: ``ic(y)`` of an observed ``y`` is ``y``'s
    defining expression with each unknown ``w`` it reads replaced by
    ``ic(w)``; ``ic(D(x))`` is ``x``'s tendency read the same way. Every other
    ``ic(w)`` is kept."""

    def at_start(e: Expr, seen: frozenset[str]) -> Expr:
        if isinstance(e, str):
            if e in observed_defs:
                if e in seen:
                    raise SimulationError(f"ic({e}): the observed's definition reads itself")
                return at_start(observed_defs[e], seen | {e})
            if e in unknowns:
                return ExprNode(op="ic", args=[e])
            return e
        if _is_ic(e):
            return expand(e, seen)
        if isinstance(e, ExprNode):
            return map_children(e, lambda c: at_start(c, seen))
        return e

    def expand(e: Expr, seen: frozenset[str] = frozenset()) -> Expr:
        if _is_ic(e):
            a = e.args[0]
            if isinstance(a, str):
                if a in observed_defs:
                    if a in seen:
                        raise SimulationError(f"ic({a}): the observed's definition reads itself")
                    return at_start(observed_defs[a], seen | {a})
                return e
            if isinstance(a, ExprNode) and a.op == "D" and a.args and isinstance(a.args[0], str):
                x = a.args[0]
                if x not in tendencies:
                    raise _unsupported(
                        f"the starting tendency ic(D({x}))",
                        f"({x} has no whole-variable `D({x})` equation to read it from)",
                    )
                return at_start(tendencies[x], seen)
            return e
        if isinstance(e, ExprNode):
            return map_children(e, lambda c: expand(c, seen))
        return e

    return expand(expr)


def refuse_trajectory_reads(
    equations: Iterable[Any],
    definitions: dict[str, list[Expr]],
    states: set[str],
    bound: Callable[[str], bool] = lambda _n: False,
) -> None:
    """esm-spec §11.4.2: an initialization equation holds at ``t0`` only, so
    one that reads a state's trajectory value — bare, or under ``D``, outside
    ``ic`` — directly or through observeds, is refused with ``ic_reads_state``.
    ``D(x) ~ -(x - ic(x))/tau`` is such an equation."""
    from .simulation_array import _ic_state_read

    for eq in equations:
        label = _equation_label(eq)
        for side in (eq.lhs, eq.rhs):
            hit = _ic_state_read(_outside_ic(side), definitions, states, bound)
            if hit is not None:
                chain, state = hit
                raise IcReadsStateError(label, state, chain)


def _describe(eq: Any) -> str:
    """An equation as compact JSON, ``lhs ~ rhs``, for a diagnostic."""
    from .serialize import _serialize_expression, canonical_json_value

    return (
        f"{canonical_json_value(_serialize_expression(eq.lhs))} ~ "
        f"{canonical_json_value(_serialize_expression(eq.rhs))}"
    )


def _equation_label(eq: Any) -> str:
    """The name an ``ic_reads_state`` diagnostic gives an equation: its
    ``ic`` target when it has one, else the equation."""
    for side in (eq.lhs, eq.rhs):
        if _is_ic(side) and isinstance(side.args[0], str):
            return side.args[0]
    reads = sorted(start_value_reads(eq.lhs) | start_value_reads(eq.rhs))
    return reads[0] if reads else _describe(eq)


# ---------------------------------------------------------------------------
# The plan
# ---------------------------------------------------------------------------


@dataclass
class _SysEq:
    eq: Any
    target: str | None  # the unknown a solved equation is explicit in
    rhs: Expr  # the right-hand side with item-8 expansions
    cells: list[int]  # the target's cells it sets (solved), as state positions
    reads: set[str]  # the unknowns whose starting values it reads
    size: int  # scalar equations


@dataclass
class InitPlan:
    """What the builder does with the initialization system."""

    #: The triangular part, in dependency order: ``(target, rhs, cells)``;
    #: ``rhs`` reads starting values as ``ic(w)``, ``cells`` the state positions
    #: of ``target`` it sets.
    steps: list[tuple[str, Expr, list[int]]] = field(default_factory=list)
    #: The truly implicit part handed to the caller (``strip`` class
    #: ``initialization``), in flattened order.
    removed: list[Any] = field(default_factory=list)
    #: The state positions of the removed part's unknowns.
    removed_cells: list[int] = field(default_factory=list)


def _faq_cells(target: str, rhs: Expr, shape: tuple[int, ...], start: int, index_sets) -> list[int]:
    from .simulation_array import _faq_output_ranges, _linear_pos

    if not shape:
        return [start]
    if isinstance(rhs, ExprNode) and rhs.op == "faq" and rhs.output_idx:
        ranges = _faq_output_ranges(rhs, index_sets or {})
        if len(ranges) != len(shape):
            raise SimulationError(
                f"ic({target}): {len(ranges)} output indices for a {len(shape)}-D state"
            )
        extents = tuple(max(hi - lo + 1, 0) for lo, hi in ranges)
        return [
            start + _linear_pos(shape, [lo + int(k) for k, (lo, _) in zip(multi, ranges)])
            for multi in np.ndindex(*extents)
        ]
    return list(range(start, start + int(np.prod(shape))))


def _equation_size(
    eq: Any, var_axes: dict[str, tuple[str, ...]], sizes: dict[str, int], index_sets
) -> int:
    """Scalar equations in an implicit equation: its ``faq`` output box, else
    the union of its named array operands' index sets (esm-spec §4.3.4), else
    one."""
    from .simulation_array import _faq_output_ranges

    for side in (eq.lhs, eq.rhs):
        if isinstance(side, ExprNode) and side.op == "faq" and side.output_idx:
            return int(
                np.prod([max(hi - lo + 1, 0) for lo, hi in _faq_output_ranges(side, index_sets)])
            )
    axes: list[str] = []
    for side in (eq.lhs, eq.rhs):
        for n in walk(side):
            if isinstance(n, str):
                for a in var_axes.get(n, ()):
                    if a not in axes:
                        axes.append(a)
    return int(np.prod([sizes.get(a, 1) for a in axes])) if axes else 1


def _max_flow(
    eqs: list[_SysEq], caps: dict[str, int], edges: list[set[str]]
) -> tuple[int, list[int], dict[str, int]]:
    """Assign scalar equations to scalar unknowns on the variable-level graph:
    source → equation (its size) → each unknown it reads (unbounded) → sink
    (the unknown's free cells). Returns ``(flow, per-equation flow, per-unknown
    flow)``."""
    n = len(eqs)
    eq_flow = [0] * n
    var_flow = dict.fromkeys(caps, 0)
    # residual eq→var flow
    ev: dict[tuple[int, str], int] = {}
    total = 0
    while True:
        # BFS from source over: eq (if eq_flow < size) -> var (always) ;
        # var -> eq (if ev>0, reverse) ; var -> sink (if var_flow < cap)
        parent: dict[Any, Any] = {}
        frontier = [("e", i) for i in range(n) if eq_flow[i] < eqs[i].size]
        for node in frontier:
            parent[node] = None
        found = None
        while frontier and found is None:
            nxt = []
            for kind, x in frontier:
                if kind == "e":
                    for v in sorted(edges[x]):
                        node = ("v", v)
                        if node not in parent:
                            parent[node] = (kind, x)
                            if var_flow[v] < caps[v]:
                                found = node
                                break
                            nxt.append(node)
                else:
                    for i in range(n):
                        if ev.get((i, x), 0) > 0 and ("e", i) not in parent:
                            parent[("e", i)] = (kind, x)
                            nxt.append(("e", i))
                if found is not None:
                    break
            frontier = nxt
        if found is None:
            break
        # bottleneck
        path = []
        node = found
        while node is not None:
            path.append(node)
            node = parent[node]
        path.reverse()
        b = caps[found[1]] - var_flow[found[1]]
        b = min(b, eqs[path[0][1]].size - eq_flow[path[0][1]])
        for a, c in zip(path, path[1:]):
            if a[0] == "v" and c[0] == "e":
                b = min(b, ev[(c[1], a[1])])
        for a, c in zip(path, path[1:]):
            if a[0] == "e":
                ev[(a[1], c[1])] = ev.get((a[1], c[1]), 0) + b
            else:
                ev[(c[1], a[1])] -= b
        eq_flow[path[0][1]] += b
        var_flow[found[1]] += b
        total += b
    return total, eq_flow, var_flow


def plan_initialization(
    flat: Any,
    *,
    shapes: dict[str, tuple[int, ...]],
    state_layout: dict[str, slice],
    known: set[int],
    supplied: dict[str, list[int]],
    observed_defs: dict[str, Expr],
    var_axes: dict[str, tuple[str, ...]],
    strip: bool,
) -> InitPlan:
    """Plan the initialization system of ``flat`` (esm-spec §11.4.3).

    ``known`` holds the state positions the explicit initial conditions set
    and the supplied values of ODE states set (precedence item 1); ``supplied``
    names, per ODE state, the positions a supplied value set (for the
    diagnostic). ``observed_defs`` maps each observed to its definition.
    Raises ``ic_system_unbalanced`` or, without ``strip``, ``unsupported_construct``
    for a truly implicit part."""
    from .index_alignment import axis_sizes

    system = list(getattr(flat, "initialization_equations", None) or [])
    if not system:
        return InitPlan()
    index_sets = flat.index_sets
    sizes = axis_sizes(index_sets or {})
    unknown_names = set(state_layout) | set(observed_defs)
    tendencies: dict[str, Expr] = {}
    for eq in flat.equations:
        lhs = eq.lhs
        if (
            isinstance(lhs, ExprNode)
            and lhs.op == "D"
            and lhs.args
            and isinstance(lhs.args[0], str)
        ):
            tendencies.setdefault(lhs.args[0], eq.rhs)

    def expand(e: Expr) -> Expr:
        return expand_start_values(e, observed_defs, tendencies, unknown_names)

    eqs: list[_SysEq] = []
    for eq in system:
        # Solved form (esm-spec §11.4.3): `ic(u) ~ e`, or `e ~ ic(u)`, with
        # `e` reading no `ic(u)`; the left-hand spelling is tried first.
        target = None
        rhs = expand(eq.rhs)
        lhs = eq.lhs
        for side, other in ((eq.lhs, eq.rhs), (eq.rhs, eq.lhs)):
            if not (_is_ic(side) and isinstance(side.args[0], str)):
                continue
            body = expand(other)
            if side.args[0] in state_layout and side.args[0] not in start_value_reads(body):
                target, rhs, lhs = side.args[0], body, side
                break
        if target is not None:
            sl = state_layout[target]
            cells = _faq_cells(target, rhs, tuple(shapes.get(target, ())), sl.start, index_sets)
            reads = start_value_reads(rhs)
            eqs.append(_SysEq(eq, target, rhs, cells, reads, len(cells)))
        else:
            reads = start_value_reads(expand(eq.lhs)) | start_value_reads(rhs)
            eqs.append(
                _SysEq(eq, None, rhs, [], reads, _equation_size(eq, var_axes, sizes, index_sets))
            )

    # A starting value an equation reads must be an unknown's.
    for e in eqs:
        for w in e.reads:
            if w not in state_layout:
                raise SimulationError(
                    f"{_describe(e.eq)}: ic({w}) names no unknown of the "
                    "flattened system that has a starting value (esm-spec §11.4.2)"
                )

    # The unknowns of the system, per cell (esm-spec §11.4.3): what a solved
    # equation sets, and every starting value an equation reads, that neither
    # an explicit initial condition nor a supplied ODE-state value gives.
    def free(v: str) -> set[int]:
        sl = state_layout[v]
        return set(range(sl.start, sl.stop)) - known

    unknown_cells: dict[str, set[int]] = {}
    edges: list[set[str]] = []
    for e in eqs:
        mine: set[str] = set()
        if e.target is not None:
            c = set(e.cells) - known
            if c:
                unknown_cells.setdefault(e.target, set()).update(c)
                mine.add(e.target)
        for w in e.reads:
            c = free(w)
            if c:
                unknown_cells.setdefault(w, set()).update(c)
                mine.add(w)
        edges.append(mine)
    caps = {v: len(c) for v, c in unknown_cells.items()}
    n_eq = sum(e.size for e in eqs)
    n_unk = sum(caps.values())
    flow, eq_flow, var_flow = _max_flow(eqs, caps, edges)
    if not (flow == n_eq == n_unk):
        direction = (
            "over-determined"
            if n_eq > n_unk
            else "under-determined"
            if n_eq < n_unk
            else "not assignable (no distinct equation for every unknown)"
        )
        left_unknowns = sorted(v for v in caps if var_flow[v] < caps[v])
        left_eqs = [_describe(e.eq) for i, e in enumerate(eqs) if eq_flow[i] < e.size]
        mentioned = {v for e in eqs for v in ({e.target} if e.target else set()) | e.reads}
        by_supply = sorted(v for v in supplied if v in mentioned and supplied[v])
        msg = (
            f"{IC_SYSTEM_UNBALANCED}: the initialization system is {direction}: {n_eq} scalar "
            f"equation(s), {n_unk} scalar unknown(s). Unknowns no equation is left to "
            f"determine: {left_unknowns or 'none'}. Equations no unknown is left for: "
            f"{left_eqs or 'none'}."
        )
        if by_supply:
            msg += (
                f" A supplied value (u0 or a run-time override) of the ODE state(s) "
                f"{by_supply} is a known of the system, not an unknown."
            )
        msg += (
            " A `default` is never an equation of the system (esm-spec §11.4.3); give each "
            "unknown exactly one initialization equation."
        )
        raise IcSystemUnbalancedError(msg)

    # The triangular part, in dependency order; everything an implicit
    # equation or a cycle determines, and everything downstream of it, is the
    # implicit part.
    solved = [i for i, e in enumerate(eqs) if e.target is not None]
    bad = {i for i, e in enumerate(eqs) if e.target is None}
    bad_vars: set[str] = set()
    for i in bad:
        bad_vars |= edges[i]
    target_eqs: dict[str, list[int]] = {}
    for i in solved:
        target_eqs.setdefault(eqs[i].target, []).append(i)
    done: set[int] = set()
    order: list[int] = []
    changed = True
    while changed:
        changed = False
        for i in solved:
            if i in done or i in bad:
                continue
            e = eqs[i]
            if e.reads & bad_vars:
                bad.add(i)
                bad_vars.add(e.target)
                changed = True
                continue
            deps = [j for w in e.reads for j in target_eqs.get(w, ()) if j != i]
            if all(j in done for j in deps):
                done.add(i)
                order.append(i)
                changed = True
    for i in solved:
        if i not in done and i not in bad:
            bad.add(i)
            bad_vars.add(eqs[i].target)
    plan = InitPlan(steps=[(eqs[i].target, eqs[i].rhs, eqs[i].cells) for i in order])
    if not bad:
        return plan
    removed = [eqs[i].eq for i in sorted(bad)]
    if not strip:
        shown = "; ".join(_describe(eq) for eq in removed)
        raise _unsupported(
            "the truly implicit initialization system",
            f"[{shown}] (esm-spec §11.4.3: equations that must be solved simultaneously, or "
            "that are not explicit in their unknown; this binding has no nonlinear "
            "initialization solve). Solve it yourself under `strip=['initialization']`",
        )
    plan.removed = removed
    plan.removed_cells = sorted(c for v in bad_vars for c in unknown_cells.get(v, ()))
    return plan


# ---------------------------------------------------------------------------
# The stripped `initialization` member (API_SPEC §5.8; esm 2.5.0)
# ---------------------------------------------------------------------------


def empty_initialization_member() -> dict[str, list]:
    """The member when nothing was removed."""
    return {"residuals": [], "unknowns": [], "x0": []}


def _column_major_names(
    state_layout: dict[str, slice], shapes: dict[str, tuple[int, ...]], cells: set[int]
) -> list[tuple[str, int]]:
    """``(element name, state position)`` of ``cells`` in state-layout order
    (API_SPEC §5.8 "Layouts"): 0-d variables by sorted name, then arrays by
    sorted name, each column-major."""
    from .simulation_array import _linear_pos

    out: list[tuple[str, int]] = []
    names = sorted(state_layout, key=lambda n: (bool(shapes.get(n)), n))
    for n in names:
        shape = tuple(shapes.get(n, ()))
        start = state_layout[n].start
        if not shape:
            if start in cells:
                out.append((n, start))
            continue
        for multi in np.ndindex(*reversed(shape)):
            idx = [k + 1 for k in reversed(multi)]
            pos = start + _linear_pos(shape, idx)
            if pos in cells:
                out.append((f"{n}[{','.join(str(i) for i in idx)}]", pos))
    return out


def initialization_member(
    plan: InitPlan,
    *,
    flat: Any,
    shapes: dict[str, tuple[int, ...]],
    state_layout: dict[str, slice],
    y0: np.ndarray,
) -> dict[str, list]:
    """The stripped object's ``initialization`` member (API_SPEC §5.8, the shape
    PR #820 drafted): ``unknowns`` as element names in state-layout order,
    ``x0`` their starting points as the Problem's initial state holds them
    (:func:`starting_points`), and one residual ``lhs - rhs`` per removed
    equation, ``ic`` kept, in flattened order."""
    from .serialize import _serialize_expression
    from .strip import _equation_origin

    if not plan.removed:
        return empty_initialization_member()
    named = _column_major_names(state_layout, shapes, set(plan.removed_cells))
    counters: dict[str, int] = {}
    residuals = []
    for eq in plan.removed:
        origin, prefix = _equation_origin(eq)
        j = counters[prefix] = counters.get(prefix, 0) + 1
        expr = {"op": "-", "args": [_serialize_expression(eq.lhs), _serialize_expression(eq.rhs)]}
        residuals.append(
            {
                "id": f"{prefix}.initialization[{j}]",
                "origin": origin,
                "shape": _residual_shape(eq, flat),
                "expr": expr,
            }
        )
    return {
        "residuals": residuals,
        "unknowns": [n for n, _ in named],
        "x0": [_finite_or_none(float(y0[p])) for _, p in named],
    }


def _residual_shape(eq: Any, flat: Any) -> list[int]:
    from .serialize import _serialize_expression
    from .strip import _expr_sets, _set_sizes

    expr = {"op": "-", "args": [_serialize_expression(eq.lhs), _serialize_expression(eq.rhs)]}
    try:
        return _set_sizes(_expr_sets(_strip_ic(expr), flat), flat)
    except ValueError:
        return []


def _strip_ic(e: Any) -> Any:
    """A serialized expression with ``ic(w)`` read as ``w``, for its index sets."""
    if isinstance(e, dict):
        if e.get("op") == "ic" and isinstance(e.get("args"), list) and e["args"]:
            a = e["args"][0]
            return a if isinstance(a, str) else 0
        out = dict(e)
        for k in ("args", "values"):
            if isinstance(out.get(k), list):
                out[k] = [_strip_ic(x) for x in out[k]]
        for k in ("expr", "filter", "lower", "upper", "key"):
            if k in out:
                out[k] = _strip_ic(out[k])
        return out
    return e


def _finite_or_none(x: float) -> float | None:
    return x if math.isfinite(x) else None


def starting_points(
    plan: InitPlan,
    *,
    flat: Any,
    shapes: dict[str, tuple[int, ...]],
    state_layout: dict[str, slice],
    y0: np.ndarray,
    supplied_algebraic: set[int],
    evaluate: Callable[[Expr], Any],
) -> None:
    """Write each removed unknown's starting point into ``y0`` (PR #820's draft
    order): the supplied value of an algebraic unknown (already in ``y0`` at a
    position of ``supplied_algebraic``), else its ``guesses`` entry, else its
    declared default (already in ``y0``), else ``0``."""
    guesses = getattr(flat, "guesses", None) or {}
    cells = set(plan.removed_cells)
    for name, sl in state_layout.items():
        mine = [p for p in range(sl.start, sl.stop) if p in cells]
        if not mine:
            continue
        g = None
        if name in guesses:
            g = np.asarray(evaluate(guesses[name]), dtype=float)
        shape = tuple(shapes.get(name, ()))
        for p in mine:
            if p in supplied_algebraic:
                continue
            if g is not None:
                y0[p] = float(
                    g.reshape(-1)[0] if g.size == 1 else g.reshape(shape).reshape(-1)[p - sl.start]
                )
            elif not math.isfinite(y0[p]):
                y0[p] = 0.0
