"""Causal self-reference (recurrence) along one index axis — esm-spec §4.3.1.1.

An equation whose LHS names an array-shaped unknown ``V`` and whose RHS
``aggregate`` body reads ``index(V, …)`` at a strictly earlier position along
exactly ONE of the aggregate's output axes is a **recurrence definition** of
``V``. There is no new op and no new schema field: the construct is recognized
structurally, so a document that contains no self-read takes exactly the paths
it took before this module existed.

This module owns the STATIC half — recognition, well-foundedness, and the
derivation of the recurrence axis and its lag bound. The numeric sweep lives in
:mod:`earthsci_ast.numpy_interpreter` (:func:`~earthsci_ast.numpy_interpreter.sweep_recurrence`),
which is the only executor Python has for array bodies.

**Why one implementation and not two.** The Rust reference carries two
near-identical copies of this analysis — one in the compiler, one in the
structural validator — because they run at different points. Python has the same
two consumers, but they read the same tree in two REPRESENTATIONS: the load-time
validator sees the raw ``dict`` decoded from JSON, the evaluator sees parsed
:class:`~earthsci_ast.esm_types.ExprNode` objects. Duplicating the analysis to
match would mean two chances for the validator and the evaluator to disagree
about which documents are legal, which is the one disagreement this construct
cannot tolerate (a document that validates and then produces a plausible wrong
number is the failure §4.3.1.1 exists to close). So the walk goes through the
three tiny accessors below, which read either representation, and both consumers
call :func:`analyze_recurrence`.

The two axes the consumers genuinely differ on are parameters, not code paths:

* how an index symbol's integer bounds are resolved (``symbol_bounds``) — the
  validator resolves ``{"from": NAME}`` against the document registry, the
  evaluator against the already-resolved ranges in scope;
* whether the recurrence axis must be a static unit-step ascending interval
  (``require_static_axis``) — the evaluator needs one to sweep at all; the
  validator does not enforce it, mirroring the Rust validator, which leaves that
  rejection to the runtime.
"""

from __future__ import annotations

from collections.abc import Iterable
from dataclasses import dataclass
from typing import Any, Callable

# The two esm-spec §4.3.1.1 rejection codes. Imported from the code registry so
# there is one spelling of each string in this binding.
from .error_handling import RECURRENCE_NOT_WELLFOUNDED, RECURRENCE_UNSUPPORTED_FORM

__all__ = [
    "Recurrence",
    "RecurrenceError",
    "analyze_recurrence",
    "cell_restricted_body",
    "find_self_reads",
    "is_recurrence_candidate",
    "mentions",
]


class RecurrenceError(Exception):
    """A self-read that is not a well-founded causal read (esm-spec §4.3.1.1).

    Carries the diagnostic ``code`` separately from the message so the
    structural validator can report it as a coded finding while the evaluator
    can raise it as text; ``str(err)`` is prefixed with the code either way, so
    the code survives every channel it is funnelled through (a wrapped
    interpreter error, a per-assertion message) without a second field to plumb.
    """

    def __init__(self, code: str, message: str) -> None:
        super().__init__(f"{code}: {message}")
        self.code = code
        self.message = message


def _not_wellfounded(message: str) -> RecurrenceError:
    return RecurrenceError(RECURRENCE_NOT_WELLFOUNDED, message)


def _unsupported_form(message: str) -> RecurrenceError:
    return RecurrenceError(RECURRENCE_UNSUPPORTED_FORM, message)


# ---------------------------------------------------------------------------
# Representation-agnostic accessors
# ---------------------------------------------------------------------------
#
# A node is either a raw ``dict`` (the load-time validator's view) or an
# ``ExprNode`` (the evaluator's). A leaf is a ``str`` symbol or a number. These
# three functions are the only place that distinction is made.


def _op(node: Any) -> str | None:
    """The operator name of ``node``, or ``None`` when it is a leaf."""
    if isinstance(node, dict):
        op = node.get("op")
        return op if isinstance(op, str) else None
    op = getattr(node, "op", None)
    return op if isinstance(op, str) else None


def _field(node: Any, name: str) -> Any:
    """One named field of an operator node (``expr``, ``ranges``, `filter`, …)."""
    if isinstance(node, dict):
        return node.get(name)
    return getattr(node, name, None)


def _args(node: Any) -> list:
    args = _field(node, "args")
    return list(args) if args else []


def _is_symbol(node: Any, name: str) -> bool:
    """Is ``node`` a BARE reference to ``name``? A ``bool`` is a literal, not a
    symbol, and ``bool`` is an ``int`` subclass, so it is excluded explicitly."""
    return isinstance(node, str) and node == name


def _int_literal(node: Any) -> int | None:
    """``node`` as an exact integer, or ``None``.

    A JSON document spells ``1`` and ``1.0`` interchangeably, so a whole float
    counts; a non-integral or non-finite number does not, because an index
    argument that is not an integer offset names no cell.
    """
    if isinstance(node, bool):
        return None
    if isinstance(node, int):
        return int(node)
    if isinstance(node, float):
        if node != node or node in (float("inf"), float("-inf")) or node != int(node):
            return None
        return int(node)
    return None


# ---------------------------------------------------------------------------
# Affine index arithmetic
# ---------------------------------------------------------------------------


def _affine_in_sym(
    node: Any,
    sym: str,
    env: dict[str, tuple[int, int]],
) -> tuple[int, tuple[int, int] | None] | None:
    """``(coefficient of sym, bounds of the symbol-free part)``, or ``None``.

    The two halves carry different weight, and the asymmetry is normative
    (esm-spec §4.3.1.1 "Admitted lag"). The **coefficient** must be provable:
    unless the expression carries ``sym`` exactly once with coefficient 1 it
    does not name a position relative to the cell being written, and which axis
    the recurrence folds along — and in which direction — is undecidable. The
    **constant part** need not be: an unprovable offset is a lag of unknown
    sign, which the spec admits and leaves to the runtime's fail-closed read.
    A cell the sweep has not published cannot be read, so an unprovable lag
    cannot produce a wrong number, only a fault. ``None`` for that half means
    "not proved", not "illegal".

    Treating an unresolvable symbol as fatal instead would make the VALIDATOR
    reject documents this binding's own evaluator accepts — the validator sees
    ``ranges`` before they are resolved against the ``index_sets`` registry and
    so proves strictly less — which is the one divergence between the two that
    is never defensible.

    Deliberately small otherwise: integer literals, symbols, ``+``, ``-``, and
    multiplication by a PINNED integer. Mirrors the Rust reference's
    ``affine_in_sym`` / ``structural_affine_in_sym``.
    """
    lit = _int_literal(node)
    if lit is not None:
        return (0, (lit, lit))
    if isinstance(node, str):
        if node == sym:
            return (1, (0, 0))
        # A symbol whose range is not in scope (a parameter, an unresolved
        # index set): the coefficient is still provably 0, the offset is not
        # provable at all.
        return (0, env.get(node))
    op = _op(node)
    args = _args(node)
    if op is None or len(args) != 2:
        return None
    left = _affine_in_sym(args[0], sym, env)
    right = _affine_in_sym(args[1], sym, env)
    if left is None or right is None:
        return None
    ca, ka = left
    cb, kb = right
    both = (ka, kb) if (ka is not None and kb is not None) else None
    if op == "+":
        return (ca + cb, (ka[0] + kb[0], ka[1] + kb[1]) if both else None)
    if op == "-":
        return (ca - cb, (ka[0] - kb[1], ka[1] - kb[0]) if both else None)
    if op == "*":
        # Scaling only by a symbol-free integer whose value is PINNED
        # (lo == hi): otherwise the product is not affine with a known
        # coefficient, and the coefficient is the half that must be provable.
        if ca == 0 and ka is not None and ka[0] == ka[1]:
            k, (coef, konst) = ka[0], (cb, kb)
        elif cb == 0 and kb is not None and kb[0] == kb[1]:
            k, (coef, konst) = kb[0], (ca, ka)
        else:
            return None
        if konst is None:
            return (coef * k, None)
        p, q = konst[0] * k, konst[1] * k
        return (coef * k, (min(p, q), max(p, q)))
    return None


# How one index argument of a causal self-read relates to its frame symbol,
# stated in terms of the LAG ``sym - <index expression>`` so a POSITIVE lag is an
# earlier position (esm-spec §4.3.1.1 "Admitted lag").
_IDENTITY = "identity"  # lag == [0, 0]: the read stays on this axis's own cell
_OFFSET = "offset"  # not provably zero-or-forward: this IS the recurrence axis
_FORWARD = "forward"  # provably <= 0: same-cell or later, which no order satisfies
_BAD = "bad"  # not affine in the frame symbol with coefficient 1


def _classify_self_index(
    arg: Any,
    sym: str,
    env: dict[str, tuple[int, int]],
) -> tuple[str, bool, int]:
    """``(kind, lag_proven, max_lag)`` for one index argument of a self-read.

    ``lag_proven`` is False for a lag that STRADDLES zero — earlier for some
    values of an index symbol in scope and not for others — and for one that is
    not provable at all. Both are admitted (esm-spec §4.3.1.1) because the
    runtime is fail-closed without the static proof: a cell the sweep has not
    published cannot be read, so the cells where the read would be ill-founded
    either never evaluate (a guard in the body selects the other branch) or
    fault. Requiring the proof would reject the natural spelling of a
    bounded-lag fold — one aggregate whose contracted index runs from 0 — force
    one hand-written term per lag, and reject a parameter-valued lag outright.
    """
    affine = _affine_in_sym(arg, sym, env)
    if affine is None:
        return (_BAD, False, 0)
    coef, konst = affine
    if coef != 1:
        return (_BAD, False, 0)
    if konst is None:
        # A lag whose SIGN could not be proved at all (a parameter-valued
        # offset, a symbol with no resolvable range). Admitted as the recurrence
        # axis — it is not the identity and it is not provably wrong — and the
        # cells where it would be ill-founded cannot be read, because the sweep
        # has not published them. `max_lag` stays 0: nothing is known, and no
        # evaluation rule depends on it.
        return (_OFFSET, False, 0)
    clo, chi = konst
    lag_lo, lag_hi = -chi, -clo
    if lag_lo == 0 and lag_hi == 0:
        return (_IDENTITY, True, 0)
    if lag_hi <= 0:
        return (_FORWARD, False, 0)
    return (_OFFSET, lag_lo >= 1, lag_hi)


# ---------------------------------------------------------------------------
# Collecting the self-reads
# ---------------------------------------------------------------------------

#: Ops whose operands are consumed WHOLE. A self-read underneath one of these
#: names a cell of an array that has to exist in full before the op can run, so
#: no cell-by-cell sweep can supply it — `recurrence_unsupported_form`, not a
#: well-foundedness question about the read itself.
#:
#: ``apply_expression_template`` is deliberately NOT here. Its operands ride the
# ``bindings`` field, which this walk does not visit (and must not start
# visiting unilaterally — five bindings mirror this field set and §5.19.5 is
# exact agreement), so listing it would be a rule that barely reaches what it
# names. It is unreachable in practice anyway: a template application surviving
# into an evaluation position is already an `unlowered_operator` error
# (esm-spec §9.6.4). This list therefore names only the ops that legitimately
# reach evaluation and consume an operand whole.
_WHOLE_OPERAND_OPS = frozenset({"reshape", "transpose", "concat", "broadcast"})


@dataclass
class SelfRead:
    """One ``index(V, …)`` read of ``V`` inside ``V``'s own defining RHS."""

    #: The index arguments (everything after the array operand).
    args: list
    #: Symbol bounds in scope where the read was found (innermost binding wins).
    env: dict[str, tuple[int, int]]
    #: True when the read is reachable only through a construct that cannot be
    #: restricted to one cell — a ``makearray`` region value, or a whole-operand
    #: op above.
    unsequenceable: bool


def _aggregate_range_env(
    node: Any,
    symbol_bounds: Callable[[Any], tuple[int, int] | None],
) -> list[tuple[str, tuple[int, int]]]:
    """Bounds every ``ranges`` entry of an aggregate contributes to the scope.

    A range whose bounds cannot be resolved contributes NOTHING rather than a
    guess: an unknown symbol makes a lag unprovable (so the read is admitted and
    the runtime rules it out), never illegal.
    """
    ranges = _field(node, "ranges")
    if not isinstance(ranges, dict):
        return []
    out: list[tuple[str, tuple[int, int]]] = []
    for key, spec in ranges.items():
        bounds = symbol_bounds(spec)
        if bounds is not None:
            out.append((str(key), bounds))
    return out


def _side_fields(node: Any) -> Iterable[Any]:
    """The expression-bearing fields of an operator node other than ``args``.

    Every one is walked, so a self-read hidden in a ``filter`` predicate, an
    integral bound or a join key is found rather than silently admitted.
    """
    for name in ("expr", "filter", "key", "lower", "upper"):
        side = _field(node, name)
        if side is not None:
            yield side


def mentions(node: Any, var: str) -> bool:
    """Does ``var`` appear anywhere in ``node``, bare or as an operand name?

    A cheap NECESSARY condition for ``node`` to be a recurrence definition of
    ``var``, so the full well-foundedness walk is paid only by an equation that
    could possibly be one. Memoized on the node when the representation allows
    it (an ``ExprNode`` does, a raw ``dict`` does not), which keeps a per-step
    observed from re-walking its own tree on every RHS evaluation — the RFC's
    claim that this construct costs an unrelated document nothing on the hot
    path rests on this.
    """
    cache = getattr(node, "_recurrence_mentions", None)
    if isinstance(cache, dict) and var in cache:
        return cache[var]

    found = False
    stack: list[Any] = [node]
    while stack and not found:
        e = stack.pop()
        if _op(e) is None:
            found = _is_symbol(e, var)
            continue
        stack.extend(_args(e))
        stack.extend(_side_fields(e))
        values = _field(e, "values")
        if isinstance(values, (list, tuple)):
            stack.extend(values)

    if cache is None and not isinstance(node, dict):
        try:
            node._recurrence_mentions = {var: found}
        except (AttributeError, TypeError):  # pragma: no cover — a frozen node
            pass
    elif isinstance(cache, dict):
        cache[var] = found
    return found


def find_self_reads(
    node: Any,
    var: str,
    symbol_bounds: Callable[[Any], tuple[int, int] | None],
) -> tuple[list[SelfRead], bool]:
    """Every ``index(var, …)`` read in ``node``, plus whether ``var`` is read BARE.

    A bare read is never a causal read (esm-spec §4.3.1.1 rejection 4): it names
    the whole array, which does not exist at any point during the sweep.
    """
    reads: list[SelfRead] = []
    bare = [False]
    env: list[tuple[str, tuple[int, int]]] = []

    def walk(e: Any, blocked: bool) -> None:
        if _op(e) is None:
            if _is_symbol(e, var):
                bare[0] = True
            return
        op = _op(e)
        added = _aggregate_range_env(e, symbol_bounds) if op == "aggregate" else []
        env.extend(added)
        try:
            args = _args(e)
            is_self_index = op == "index" and args and _is_symbol(args[0], var)
            if is_self_index:
                reads.append(SelfRead(args=list(args[1:]), env=dict(env), unsequenceable=blocked))
            # `args[0]` of a self-read is the NAME, not a bare read of the array;
            # every other operand is walked normally, since an index expression
            # may itself contain a self-read.
            blocked_children = blocked or op in _WHOLE_OPERAND_OPS
            for a in args[1:] if is_self_index else args:
                walk(a, blocked_children)
            for side in _side_fields(e):
                walk(side, blocked_children)
            # A `makearray` REGION VALUE is evaluated once for the whole region,
            # so a self-read inside one cannot be sequenced: §4.3.2's region
            # order fixes which write WINS, not which cell is evaluated when.
            values = _field(e, "values")
            if isinstance(values, (list, tuple)):
                for v in values:
                    walk(v, True)
        finally:
            del env[len(env) - len(added) :]

    walk(node, False)
    return reads, bare[0]


def is_recurrence_candidate(var: str, rhs: Any, *, array_shaped: bool) -> bool:
    """Does the recurrence check OWN the diagnosis for this equation?

    A **candidate** is an array-shaped unknown with at least one ``index(var, …)``
    read in its own RHS — **well founded or not**. This is the predicate every
    pre-existing check that would fire on the self-edge (a cadence seeder, an
    observed-cycle detector, a trivial-DAE factoring) must be exempted by, and
    CONFORMANCE_SPEC §5.19.5 is explicit that it MUST NOT be the well-foundedness
    verdict instead.

    Gating on the verdict is the intuitive choice and it destroys exactly what
    §5.19.5 requires. An ill-founded self-read is by definition not well founded,
    so the exemption would not apply to it, so the pre-existing cycle check fires
    and collapses the document to one cycle error — and the
    ``recurrence_not_wellfounded`` / ``recurrence_unsupported_form`` diagnosis is
    never reached. That is the original masking defect moved from the legal case
    to the illegal one: the construct exists to replace a mis-attributed failure
    with a named one, and verdict-gating gives the name back up.

    Candidacy is also not merely "the equation reads its own name". A scalar
    ``x ~ x + 1`` has no ``index`` read and can never be a recurrence — it has no
    axis to fold along — and neither can a bare ``s ~ s + 1`` over an array. Both
    keep whatever diagnosis they already had, because the recurrence check does
    not own them.
    """
    if not array_shaped:
        return False
    # Symbol bounds are irrelevant here: candidacy counts self-reads, it does not
    # weigh them, so nothing needs resolving.
    reads, _bare = find_self_reads(rhs, var, lambda _spec: None)
    return bool(reads)


# ---------------------------------------------------------------------------
# The recognized recurrence
# ---------------------------------------------------------------------------


@dataclass
class Recurrence:
    """A recognized, well-founded causal self-reference."""

    #: The variable the recurrence defines.
    var: str
    #: The cell frame's index symbols, in ``output_idx`` order.
    idx_names: list[str]
    #: Position within ``idx_names`` of the axis the sweep folds along.
    axis: int
    #: The aggregate node that carries the cell frame (the RHS aggregate, or the
    #: §4.3 indexed-aggregate LHS). ``None`` when the frame came from an LHS the
    #: caller supplied without one.
    frame_node: Any
    #: Largest lag any self-read takes along ``axis``, DERIVED from the reads and
    #: never declared. Reported for observability; no evaluation rule uses it.
    max_lag: int
    #: Whether every self-read was PROVED strictly earlier statically. False
    #: means at least one lag straddles zero and the runtime's fail-closed read
    #: is what rules the ill-founded cells out.
    lag_proven: bool


def _frame_node(var: str, lhs: Any, rhs: Any) -> Any:
    """The aggregate node carrying the cell frame, or ``None``.

    Either the §4.3 indexed-aggregate LHS form (``aggregate{expr: V[k…]} ~ …``)
    or a bare LHS whose RHS is an aggregate over ``V``'s axes. Anything else has
    no frame to sweep.
    """
    if _op(lhs) == "aggregate":
        return lhs
    if _is_symbol(lhs, var) and _op(rhs) == "aggregate":
        return rhs
    return None


def analyze_recurrence(
    var: str,
    lhs: Any,
    rhs: Any,
    *,
    symbol_bounds: Callable[[Any], tuple[int, int] | None],
    require_static_axis: bool = False,
) -> Recurrence | None:
    """Recognize and check a recurrence definition of ``var``.

    ``None`` — the RHS contains no causal self-read, so the equation is handled
    exactly as it was before this construct existed. Raises
    :class:`RecurrenceError` for a self-read that is not a well-founded causal
    read; never falls back silently, because the pre-feature behaviour for every
    rejected shape here was a plausible wrong number or no number at all.

    ``symbol_bounds`` resolves one ``ranges`` spec to ``(lo, hi)`` or ``None``.
    ``require_static_axis`` additionally demands that every frame axis be a
    static unit-step ascending interval — what an executor needs to sweep, and
    what a ragged / derived / strided axis cannot supply.
    """
    reads, bare = find_self_reads(rhs, var, symbol_bounds)
    if not reads:
        return None

    if bare:
        raise _not_wellfounded(
            f"'{var}' is read bare inside its own defining equation as well as through "
            f"`index`. A bare read names the whole array, which does not exist while the "
            f"recurrence sweeps it; read every self-reference through `index` at a strictly "
            f"earlier position (esm-spec §4.3.1.1)."
        )

    if any(r.unsequenceable for r in reads):
        raise _unsupported_form(
            f"a causal self-read of '{var}' is reached only through a construct that "
            f"evaluates its operand whole — a `makearray` region value, or a "
            f"`reshape`/`transpose`/`concat`/`broadcast` operand — so no cell-by-cell sweep "
            f"can supply it. A `makearray`'s region order fixes which write WINS, not the "
            f"order cells are EVALUATED in (esm-spec §4.3.1.1, §4.3.2); write the recurrence "
            f"as one `aggregate` with the base case as an `ifelse` guard in the body."
        )

    frame = _frame_node(var, lhs, rhs)
    idx_names_raw = _field(frame, "output_idx") if frame is not None else None
    if not idx_names_raw:
        raise _unsupported_form(
            f"the definition of '{var}' reads '{var}' at another position, but the equation "
            f"declares no cell frame to sweep: its RHS is not an `aggregate` over the "
            f"variable's axes and its LHS is not the indexed-aggregate form "
            f"`aggregate{{expr: index({var}, k…)}}` (esm-spec §4.3.1.1)."
        )
    idx_names = [str(s) for s in idx_names_raw]
    # A literal entry in `output_idx` is a pinned singleton dimension, not a
    # symbol, so it names no axis the sweep could advance along.
    if any(_int_literal(s) is not None for s in idx_names_raw):
        raise _unsupported_form(
            f"the recurrence definition of '{var}' has no symbolic output index to fold "
            f"along ({idx_names}); a literal singleton dimension cannot be a recurrence axis "
            f"(esm-spec §4.3.1.1)."
        )

    frame_ranges = _field(frame, "ranges")
    frame_ranges = frame_ranges if isinstance(frame_ranges, dict) else {}
    frame_env: dict[str, tuple[int, int]] = {}
    for name in idx_names:
        bounds = symbol_bounds(frame_ranges.get(name))
        if bounds is not None:
            frame_env[name] = bounds
        elif require_static_axis:
            raise _not_wellfounded(
                f"axis '{name}' of the recurrence definition of '{var}' is not a static "
                f"unit-step ascending interval. A ragged, derived, strided or unresolved axis "
                f"carries no total order to fold along (esm-spec §4.3.1.1)."
            )

    axis: int | None = None
    max_lag = 0
    lag_proven = True
    for read in reads:
        if len(read.args) != len(idx_names):
            raise _not_wellfounded(
                f"a causal self-read of '{var}' supplies {len(read.args)} indices but its "
                f"frame has {len(idx_names)} axes ({idx_names}); every causal self-read "
                f"indexes every axis (esm-spec §4.3.1.1)."
            )
        env = dict(frame_env)
        env.update(read.env)
        lagged: int | None = None
        for d, arg in enumerate(read.args):
            sym = idx_names[d]
            kind, proven, hi = _classify_self_index(arg, sym, env)
            if kind == _IDENTITY:
                continue
            if kind == _FORWARD:
                raise _not_wellfounded(
                    f"index {d} of a causal self-read of '{var}' names the cell being "
                    f"written, or a LATER one, on axis '{sym}'. A causal self-reference "
                    f"reads strictly EARLIER positions; no sweep order can satisfy a "
                    f"same-cell or forward read (esm-spec §4.3.1.1)."
                )
            if kind == _BAD:
                raise _not_wellfounded(
                    f"index {d} of a causal self-read of '{var}' is not an offset of the "
                    f"frame symbol '{sym}' with coefficient 1. A self-read names a position "
                    f"RELATIVE to the cell being written (`{sym} - 1`, `{sym} - a`, "
                    f"`{sym} - a - 2`), which is what makes the recurrence axis and its "
                    f"direction decidable; a bare constant, `2*{sym}`, or another axis's "
                    f"symbol is rejected rather than guessed at (esm-spec §4.3.1.1)."
                )
            if lagged is not None:
                raise _not_wellfounded(
                    f"a causal self-read of '{var}' is offset on more than one axis. A "
                    f"recurrence folds along exactly ONE axis; every other index must be the "
                    f"bare frame symbol (esm-spec §4.3.1.1)."
                )
            lagged = d
            lag_proven = lag_proven and proven
            max_lag = max(max_lag, hi)
        if lagged is None:
            raise _not_wellfounded(
                f"a causal self-read of '{var}' is at the same cell on every axis, so it "
                f"defines '{var}' in terms of itself rather than of an earlier position. A "
                f"causal self-reference must be strictly earlier along one axis "
                f"(esm-spec §4.3.1.1)."
            )
        if axis is None:
            axis = lagged
        elif axis != lagged:
            raise _not_wellfounded(
                f"the causal self-reads of '{var}' disagree on the recurrence axis: one folds "
                f"along '{idx_names[axis]}' and another along '{idx_names[lagged]}'. A "
                f"definition folds along exactly one axis (esm-spec §4.3.1.1)."
            )

    assert axis is not None  # every read set the axis or raised
    return Recurrence(
        var=var,
        idx_names=idx_names,
        axis=axis,
        frame_node=frame,
        max_lag=max_lag,
        lag_proven=lag_proven,
    )


def cell_restricted_body(node: Any, idx_names: list[str], make_node: Callable[[dict], Any]) -> Any:
    """Restrict a frame-producing ``aggregate`` to ONE cell of its frame.

    Moves the output indices out to the enclosing sweep and keeps the
    contraction, ``filter``, ``reduce``, ``join``, ``key`` and ``semiring``
    intact, so the body evaluates at one cell exactly as §4.3.1 specifies for a
    NON-recurrent aggregate — including §4.3.1's ascending in-body accumulation
    order. Restriction is what makes the recurrence composable: the body's
    arithmetic is never special-cased.

    When nothing is left to contract or gate, the restriction IS the body, so
    the wrapper is dropped — the common shape ``s[k] = f(s[k-1])`` then walks one
    expression per cell instead of re-deriving an empty contraction. ``make_node``
    builds a node of the caller's representation from a field mapping.
    """
    body = _field(node, "expr")
    ranges = _field(node, "ranges")
    ranges = ranges if isinstance(ranges, dict) else {}
    remaining = {k: v for k, v in ranges.items() if str(k) not in idx_names}
    gated = (
        _field(node, "filter") is not None
        or _field(node, "join") is not None
        or _field(node, "key") is not None
        or _field(node, "distinct") is True
    )
    if not remaining and not gated:
        return body
    return make_node({"output_idx": [], "ranges": remaining})
