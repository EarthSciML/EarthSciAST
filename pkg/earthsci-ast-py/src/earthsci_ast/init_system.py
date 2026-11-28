"""The initialization system (esm 2.5.0; esm-spec §11.4.2–§11.4.3).

An *initialization equation* mentions ``ic`` anywhere. Flatten splits them
(:mod:`.classification` answers which is which): an EXPLICIT initial condition
``ic(u) ~ e`` (``e`` mentions no ``ic``, ``u`` not an observed) goes to
``FlattenedSystem.field_ics`` and is folded by the builders; every other one
goes to ``FlattenedSystem.initialization_equations``, the equations of the
initialization system, which this module plans:

1. a trajectory read (a state, bare or under ``D``, outside ``ic``) is refused
   with ``ic_reads_state`` (:func:`refuse_trajectory_reads`);
2. ``ic(y)`` of an observed and ``ic(D(x))`` are expanded into the starting
   values they read (§11.4.2 item 8, :func:`expand_start_values`);
3. the knowns are the cells the explicit initial conditions set, the supplied
   values of ODE states, and the declared defaults of ODE states that no
   equation in solved form determines ("Declared defaults"); an equation in
   solved form whose target is already set (not by a default) is not
   explicit in an undetermined unknown. Every other starting value an
   equation mentions is an unknown, and the system is balanced per variable
   or refused with ``ic_system_unbalanced``;
4. the triangular part (each equation in solved form whose reads are all
   determined) becomes ordered :attr:`InitPlan.steps` the builder evaluates
   by substitution; the rest is refused with ``unsupported_construct``, or,
   under ``strip`` class ``initialization``, handed to the caller
   (:func:`initialization_member`) with the values substitution gave as its
   knowns.

Python has no nonlinear initialization solve, so ``ic_system_unsolved`` is never
raised here.
"""

from __future__ import annotations

import math
from collections.abc import Callable, Iterable
from dataclasses import dataclass, field
from typing import Any

import numpy as np

from .classification import (
    cells_set,
    equation_shape,
    ic_as_values,
    ic_target,
    solved_form,
    start_value_reads,
)
from .error_handling import IC_SYSTEM_UNBALANCED
from .errors import IcReadsStateError, SimulationError
from .esm_types import Expr, ExprNode
from .expr_walk import map_children

__all__ = [
    "IcSystemUnbalancedError",
    "InitPlan",
    "expand_start_values",
    "initialization_member",
    "plan_initialization",
    "outside_ic",
    "refuse_trajectory_reads",
]


class IcSystemUnbalancedError(SimulationError):
    """``ic_system_unbalanced`` (esm-spec §11.4.3): the initialization system
    has more scalar equations than unknowns, or fewer, or no assignment of a
    distinct equation to every unknown."""

    code = IC_SYSTEM_UNBALANCED


# ---------------------------------------------------------------------------
# Expression helpers
# ---------------------------------------------------------------------------


def outside_ic(expr: Expr) -> Expr:
    """``expr`` with every ``ic(·)`` subtree replaced by ``0``: what remains is
    what it reads of the trajectory, and the names it reads outside ``ic``."""
    if isinstance(expr, ExprNode) and expr.op == "ic":
        return 0.0
    if isinstance(expr, ExprNode):
        return map_children(expr, outside_ic)
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
        if isinstance(e, ExprNode) and e.op == "ic":
            return expand(e, seen)
        if isinstance(e, ExprNode):
            return map_children(e, lambda c: at_start(c, seen))
        return e

    def expand(e: Expr, seen: frozenset[str] = frozenset()) -> Expr:
        if isinstance(e, ExprNode) and e.op == "ic" and len(e.args) == 1:
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
            hit = _ic_state_read(outside_ic(side), definitions, states, bound)
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
        target = ic_target(side)
        if target is not None:
            return target
    reads = sorted(start_value_reads(eq.lhs) | start_value_reads(eq.rhs))
    return reads[0] if reads else _describe(eq)


# ---------------------------------------------------------------------------
# The plan
# ---------------------------------------------------------------------------


@dataclass
class _SysEq:
    eq: Any
    target: str | None  # the unknown an equation in solved form determines
    rhs: Expr  # its value side (solved), with item-8 expansions
    cells: list[int]  # the target's cells it sets (solved), as state positions
    reads: set[str]  # the unknowns whose starting values it reads
    size: int  # scalar equations


@dataclass
class InitPlan:
    """What the builder does with the initialization system."""

    #: The triangular part, in dependency order: ``(target, value, cells)``;
    #: ``value`` reads starting values as ``ic(w)``, ``cells`` are the state
    #: positions of ``target`` it sets, in the row-major order of its value.
    steps: list[tuple[str, Expr, list[int]]] = field(default_factory=list)
    #: The truly implicit part handed to the caller (``strip`` class
    #: ``initialization``), in flattened order.
    removed: list[Any] = field(default_factory=list)
    #: The state positions of the removed part's unknowns: the starting values
    #: its equations leave undetermined.
    removed_cells: list[int] = field(default_factory=list)


def target_cells(
    target: str,
    value: Expr,
    shapes: dict[str, tuple[int, ...]],
    state_layout: dict[str, slice],
    index_sets: Any,
) -> list[int]:
    """The state positions an initial condition ``ic(target) ~ value`` sets, in
    the row-major order of its value: a ``faq`` with output indices sets its
    box, anything else every cell (esm-spec §11.4.3)."""
    start = state_layout[target].start
    try:
        offsets = cells_set(value, tuple(shapes.get(target, ())), index_sets)
    except ValueError as err:
        raise SimulationError(f"ic({target}): {err}") from err
    return [start + k for k in offsets]


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
    explicit: set[int],
    supplied: dict[str, list[int]],
    defaulted: set[int],
    caller: set[str],
    observed_defs: dict[str, Expr],
    var_axes: dict[str, tuple[str, ...]],
    strip: bool,
) -> InitPlan:
    """Plan the initialization system of ``flat`` (esm-spec §11.4.3).

    ``explicit`` holds the state positions the explicit initial conditions
    set; ``supplied`` names, per ODE state, the positions a supplied value set
    (precedence item 1); ``defaulted`` the positions of ODE states that hold a
    declared default; ``caller`` the unknowns whose starting value is the
    caller's to find (the algebraic unknowns ``strip`` class ``algebraic``
    took); ``observed_defs`` maps each observed to its definition. Raises
    ``ic_system_unbalanced`` or, without ``strip``, ``unsupported_construct``
    for a truly implicit part."""
    system = list(getattr(flat, "initialization_equations", None) or [])
    if not system:
        return InitPlan()
    index_sets = flat.index_sets
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

    def cells_of(v: str) -> set[int]:
        sl = state_layout[v]
        return set(range(sl.start, sl.stop))

    def can_target(u: str) -> bool:
        return u in state_layout and u not in observed_defs

    # Set before the system: by an explicit initial condition, or by a
    # supplied value of an ODE state. A default is not among these.
    hard_known = set(explicit).union(*supplied.values())

    eqs: list[_SysEq] = []
    for eq in system:
        lhs, rhs = expand(eq.lhs), expand(eq.rhs)
        found = solved_form(lhs, rhs, can_target)
        if found is not None:
            target, value = found
            cells = target_cells(target, value, shapes, state_layout, index_sets)
            # Its target already set: not explicit in an undetermined unknown
            # (esm-spec §11.4.3), so an equation of the implicit part.
            if not set(cells) & hard_known:
                eqs.append(_SysEq(eq, target, value, cells, start_value_reads(value), len(cells)))
                continue
        size = math.prod(equation_shape(lhs, rhs, lambda n: var_axes.get(n, ()), index_sets))
        reads = start_value_reads(lhs) | start_value_reads(rhs)
        eqs.append(_SysEq(eq, None, rhs, [], reads, size))

    # A starting value an equation reads must be an unknown's.
    for e in eqs:
        for w in e.reads:
            if w not in state_layout:
                raise SimulationError(
                    f"{_describe(e.eq)}: ic({w}) names no unknown of the "
                    "flattened system that has a starting value (esm-spec §11.4.2)"
                )

    # The knowns (esm-spec §11.4.3): what was set before the system, the
    # default of an ODE state no equation in solved form determines
    # ("Declared defaults"), and a starting value that is the caller's.
    solved_cells = {c for e in eqs for c in e.cells}
    caller_cells = set().union(*(cells_of(v) for v in caller if v in state_layout))
    caller_cells -= hard_known | solved_cells
    known = hard_known | (defaulted - solved_cells) | caller_cells

    unknown_cells: dict[str, set[int]] = {}
    edges: list[set[str]] = []
    for e in eqs:
        mine: set[str] = set()
        for v, c in ([(e.target, set(e.cells))] if e.target else []) + [
            (w, cells_of(w)) for w in e.reads
        ]:
            free = c - known
            if free:
                unknown_cells.setdefault(v, set()).update(free)
                mine.add(v)
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
            " The declared default of an ODE state is a known of the system unless an "
            "equation in solved form determines it (esm-spec §11.4.3); give each unknown "
            "exactly one initialization equation."
        )
        raise IcSystemUnbalancedError(msg)

    # The triangular part, by substitution in dependency order: an equation
    # in solved form whose reads are all determined. A caller's value never
    # is, so an equation that reads one stays in the implicit part.
    determined = known - caller_cells
    done: set[int] = set()
    order: list[int] = []
    changed = True
    while changed:
        changed = False
        for i, e in enumerate(eqs):
            if i in done or e.target is None:
                continue
            if all(cells_of(w) <= determined for w in e.reads):
                done.add(i)
                order.append(i)
                determined |= set(e.cells)
                changed = True
    plan = InitPlan(steps=[(eqs[i].target, eqs[i].rhs, eqs[i].cells) for i in order])
    if len(done) == len(eqs):
        return plan
    removed = [e.eq for i, e in enumerate(eqs) if i not in done]
    if not strip:
        shown = "; ".join(_describe(eq) for eq in removed)
        raise _unsupported(
            "the truly implicit initialization system",
            f"[{shown}] (esm-spec §11.4.3: equations that must be solved simultaneously, or "
            "that are not explicit in their unknown; this binding has no nonlinear "
            "initialization solve). Solve it yourself under `strip=['initialization']`",
        )
    # The implicit part determines only what substitution left undetermined.
    plan.removed = removed
    plan.removed_cells = sorted(set().union(*unknown_cells.values()) - determined)
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
    """The stripped object's ``initialization`` member (API_SPEC §5.8):
    ``unknowns`` as element names in the order of the state layout (0-d by
    sorted name, then arrays by sorted name, each column-major, the order
    ``z`` follows),
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
        return _set_sizes(_expr_sets(ic_as_values(expr), flat), flat)
    except ValueError:
        return []


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
    """Write each removed unknown's starting point into ``y0`` (API_SPEC §5.8
    ``x0``): the supplied value of an algebraic unknown (already in ``y0`` at a
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
