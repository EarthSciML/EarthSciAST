"""
NumPy AST interpreter for array/tensor expression nodes.

This module provides a recursive evaluator for the ESM expression AST that
returns NumPy scalars or ndarrays. It is the Python counterpart of the Rust
``ndarray`` runtime and the Julia ``SymbolicUtils.ArrayOp`` path, and is used
by :mod:`earthsci_ast.simulation` when the flattened system contains any
array op (``arrayop``, ``makearray``, ``index``, ``broadcast``, ``reshape``,
``transpose``, ``concat``).

Design notes
------------
- The evaluator is driven by a tiny context containing the current state,
  parameters, observed values, and the flat-state layout (``{name: slice}``
  plus ``{name: shape}``). It views slices of the flat state vector as
  ndarrays of the appropriate shape.
- Index symbols inside an ``arrayop`` body are threaded through a ``locals``
  dict. The body is evaluated once per point in the output box; results are
  assembled into an output ndarray.
- For simple contraction bodies (``index(A, i, k) * index(B, k, j)`` with
  ``j``, ``k`` implicit / reduced) a vectorized ``np.einsum`` fast path
  (:func:`_eval_arrayop_vectorized`, and the cached weight-operator path in
  :func:`_eval_arrayop_operator_cached`) handles the common scaled-product
  forms; bodies it declines fall through to the generic nested loop. The public
  API is the same either way.
- Shapes are 1-based to match the schema's Julia heritage. When reading an
  element ``u[i]`` we subtract 1 from the declared integer index.
"""

from __future__ import annotations

import functools
from collections.abc import Iterator, Sequence
from contextlib import contextmanager
from dataclasses import dataclass, field
from typing import Any, Callable

import numpy as np

from . import op_registry
from .cadence import Partition
from .cadence import partition as _partition_model
from .errors import EarthSciAstError
from .esm_types import ARRAY_OPS, Expr, ExprNode
from .expr_walk import any_child
from .index_ranges import expand_range as _expand_range
from .registered_functions import (
    INTERP_CONST_ARG_POSITIONS as _INTERP_CONST_ARG_POSITIONS,
)

Shape = tuple[int, ...]


# --- Named interpreter limits (were scattered magic numbers) ---
#: Max distinct index symbols an einsum contraction fast path can name: einsum
#: subscript labels are single lowercase ASCII letters (``chr(ord("a") + i)``),
#: so beyond this the fast path declines (→ ``None``) to the generic reduce.
_EINSUM_MAX_LABELS = 26
#: BLAKE2b digest width (bytes) for the skolem key hash: 6 bytes = 48 bits, the
#: widest integer exactly representable in float64 and stable across processes
#: (mirrors the Julia setup-geometry evaluator's ``hash(Tuple(vals))`` skolem).
_SKOLEM_DIGEST_BYTES = 6


@dataclass
class EvalContext:
    """Runtime data passed to each recursive evaluation step."""

    state_layout: dict[str, slice]
    state_shapes: dict[str, Shape]
    param_values: dict[str, float]
    observed_values: dict[str, float]
    y: np.ndarray
    t: float
    locals: dict[str, int] = field(default_factory=dict)
    # Document-scoped index-set registry (RFC semiring-faq-unified-ir §5.2),
    # keyed by name. Used to resolve arrayop / aggregate range references of the
    # form {"from": <name>}. Empty ⇒ no named sets are declared.
    index_sets: dict[str, Any] = field(default_factory=dict)
    # Runtime materialization of data-derived index sets (RFC §5.5 / §8.1),
    # keyed by the producing node's `id`. An `intersect_polygon` leaf registers
    # its clipped overlap ring here under its `id`; a `kind:"derived"` index set
    # with `from_faq: <id>` then resolves its extent (the vertex count) from the
    # registered ring, and the ring is readable as a bare symbol by that id so a
    # `polygon_area` FAQ body can `index(<id>, v, c)` into it. Each value is the
    # CLOSED ring ndarray (first vertex repeated) of shape [n+1, 2]; the derived
    # set's extent is the n distinct vertices. Empty ⇒ none materialized yet.
    derived_rings: dict[str, np.ndarray] = field(default_factory=dict)
    # Build-time value-invention derived-index-set extents (RFC §6.1 / §5.5),
    # keyed by the producing aggregate's `id` (the `from_faq` target). Populated
    # ONCE at setup by `value_invention.materialize_value_invention` — the
    # skolem/distinct/rank engine runs off the per-step hot path and hands its
    # distinct-set cardinality here, generalizing the geometry clip-ring handoff
    # (`derived_rings`) to the relational engine. A `kind:"derived"` set whose
    # `from_faq` is here resolves to the dense extent `[1, n]`. Empty ⇒ none.
    derived_extents: dict[str, int] = field(default_factory=dict)
    # Externally-injected read-only input arrays (RFC pure-io-data-loaders §4.3),
    # keyed by the flattened observed-array symbol (e.g. ``ERA5.pl.u``). The
    # simulator executes each data loader at its cadence and binds the resulting
    # array here so a consumer equation that referenced the loader field (via a
    # coupling edge) resolves it as a value. Distinct from ``derived_rings``
    # (computed per step from observed equations): these are inputs, refreshed
    # only at cadence boundaries, so the RHS is pure within a segment. Empty ⇒ no
    # data-loader fields are bound. See `simulation._simulate_with_loaders`.
    input_arrays: dict[str, np.ndarray] = field(default_factory=dict)
    # Build-time value-invention MAP buffers (RFC §5.3): a per-cell key buffer
    # (e.g. the broad-phase bins ``rg_src_bin`` / ``rg_tgt_bin``) that an
    # aggregate ``join.on [[rg_src_bin, rg_tgt_bin]]`` gates on. Each value is a
    # 0-based ndarray of integer bin codes; ``join_key_index_sets`` records the
    # buffer's 1-D declared-shape index set so the join resolver can map the key
    # column to the range symbol whose ``{"from": <set>}`` matches. Materialized
    # ONCE at setup (:func:`simulation._materialize_join_key_buffers`) — the
    # skolem/floor bins run off the per-step hot path. Empty ⇒ no buffer joins.
    join_key_buffers: dict[str, np.ndarray] = field(default_factory=dict)
    join_key_index_sets: dict[str, str] = field(default_factory=dict)
    # Keyed-factor scope map (esm-spec §5.4 / RFC semiring-faq-unified-ir §5.2):
    # a RAGGED index set's `offsets` / `values` keyed factors bind by BARE name
    # in the model scope (the grids' wiring contract), but flattening prefixes
    # every variable with its owning component path ("nEdgesOnCell" →
    # "Divergence.nEdgesOnCell") while the document-scoped index-set registry
    # keeps the authored bare name. This maps each bare factor name to the
    # in-scope (possibly namespaced) variable that backs it — built ONCE at
    # setup by :func:`ragged_factor_scope` (exact name wins; else the unique
    # dot-suffix match at the shallowest namespace depth; ambiguity keeps the
    # bare name so the existing unresolved-symbol error surfaces). Empty ⇒ bare
    # names resolve as-is (the pre-namespacing behaviour, byte-identical).
    factor_scope: dict[str, str] = field(default_factory=dict)
    # Build-scoped reusable-operator cache for constant-geometry contractions
    # (perf idea #3), keyed by the aggregate node's ``id``. A ``sum_product``
    # join-gated reduce shaped like the conservative-regrid APPLY
    # ``field_tgt[j] = Σ_i W_ij·field_i`` (join-admitted, ⊗ = ×) factors into a
    # CONSTANT weight operator ``W_op`` (the loader-invariant geometry × the
    # join-admit mask) contracted against a VARYING gathered field. ``W_op`` is
    # built once and cached here so a cadence-segmented rebuild re-applies it (one
    # ``einsum``) to the refreshed field instead of re-walking the weight + re-
    # coding the join every segment. ``None`` ⇒ operator caching is off (the
    # single-shot builds); the dense :func:`_eval_arrayop_reduce_vectorized` path
    # (#1) and the scalar loop remain the always-correct fallbacks.
    op_cache: dict[int, Any] | None = None
    # Names whose materialized value is loader-INVARIANT (constant across cadence
    # segments) — the geometry ``derived_rings`` / ``observed_values`` the build
    # hoisted into the const partition (simulation_array `_build_numpy_rhs`). A
    # weight operator may be cached (above) only when every constant factor it
    # captures is one of these, so a reused ``W_op`` can never freeze a
    # loader-dependent quantity. Empty ⇒ nothing is known-invariant, so the
    # operator path declines and #1's dense reduce handles the node.
    invariant_names: frozenset[str] = field(default_factory=frozenset)


def ragged_factor_scope(
    index_sets: dict[str, Any] | None,
    var_names: Sequence[str],
) -> dict[str, str]:
    """Map each ragged set's bare keyed-factor name to its in-scope variable.

    Mirrors the Julia tree-walk ``_factor_scope`` (tree_walk.jl) exactly: for
    every ``kind: "ragged"`` index set's ``offsets`` and ``values`` factors,
    an EXACT-name variable wins (no map entry — the bare name already
    resolves); otherwise the dot-suffix matches (``*.<factor>``) at the
    SHALLOWEST namespace depth are considered — the model's own re-exposed
    alias (``Divergence.nEdgesOnCell``), not the mounted subsystem's original
    (``Divergence.mesh.nEdgesOnCell``). A unique shallowest match binds; a
    genuine ambiguity (two candidates at the same shallowest depth) leaves the
    name bare so the existing unresolved-symbol error surfaces rather than an
    arbitrary pick. Empty for documents without ragged index sets.
    """
    scope: dict[str, str] = {}
    names = list(var_names)
    for entry in (index_sets or {}).values():
        if not (isinstance(entry, dict) and entry.get("kind") == "ragged"):
            continue
        for factor in (entry.get("offsets"), entry.get("values")):
            if factor is None:
                continue
            fname = str(factor)
            if fname in scope or fname in names:
                continue
            cands = [n for n in names if n.endswith("." + fname)]
            if not cands:
                continue
            mindepth = min(n.count(".") for n in cands)
            best = [n for n in cands if n.count(".") == mindepth]
            if len(best) == 1:
                scope[fname] = best[0]
    return scope


class NumpyInterpreterError(EarthSciAstError):
    """Raised when an expression cannot be evaluated by the NumPy interpreter."""


class UnreachableSpatialOperatorError(NumpyInterpreterError):
    """Raised when an unlowered rewrite-target operator reaches the simulator's
    RHS evaluator — a spatial/right-hand-side ``D`` or a ``grad``/``div``/
    ``laplacian`` sugar op (esm-spec §4.2 / §9.6.8).

    These ops carry NO evaluator: a discretization rule MUST rewrite them into an
    ``aggregate``/``makearray`` stencil before evaluation. Encountering one here
    means no rule lowered it — silently substituting zero (the previous
    behaviour) would mask the broken pipeline. The gate fires before evaluation
    with the uniform, cross-binding ``code = "unlowered_operator"`` diagnostic
    (RFC open-op-namespace-fixpoint-rewrite Change B/C, superseding the old
    per-binding UnreachableSpatialOperator / UnsupportedDimensionality codes).
    """

    #: Stable cross-binding diagnostic code (esm-spec §9.6.6). Every surfaced
    #: unlowered-operator error carries this, regardless of the exception class.
    code = "unlowered_operator"

    def __init__(self, op: str) -> None:
        self.op = op
        super().__init__(
            f"unlowered_operator: rewrite-target op '{op}' reached simulation "
            f"evaluation with no rule to lower it to a stencil. Such ops "
            f"(a spatial/right-hand-side `D`, or `grad`/`div`/`laplacian` sugar) "
            f"must be rewritten by a discretization rule before evaluation "
            f"(esm-spec §4.2 / §9.6.8). Pipeline contract violated."
        )


def _as_array(x: Any) -> np.ndarray:
    if isinstance(x, np.ndarray):
        return x
    return np.asarray(x, dtype=float)


def _view_state_array(name: str, ctx: EvalContext) -> np.ndarray:
    """Return an ndarray view of ``name`` into the flat state vector."""
    sl = ctx.state_layout[name]
    shape = ctx.state_shapes[name]
    data = ctx.y[sl]
    if shape == ():
        return np.asarray(float(data[0]))
    return data.reshape(shape, order="C")


def _resolve_symbol(name: str, ctx: EvalContext) -> float | np.ndarray:
    """Resolve a bare name reference."""
    if name in ctx.locals:
        v = ctx.locals[name]
        # Index symbols are usually scalars, but the vectorized stencil path
        # (``_materialize_map``) binds them to ndarray ranges so a whole region
        # evaluates in one pass; pass arrays through unchanged.
        return v if isinstance(v, np.ndarray) else float(v)
    if name == "t":
        return float(ctx.t)
    # A materialized derived ring (RFC §8.1): an `intersect_polygon` node id
    # resolves to its CLOSED clip ring so a `polygon_area` FAQ body can
    # `index(<id>, v, c)` into the overlap vertices.
    if name in ctx.derived_rings:
        return ctx.derived_rings[name]
    # An externally-injected data-loader field (RFC pure-io-data-loaders §4.3):
    # a coupling edge substituted the loader's producer symbol (e.g. ``ERA5.pl.u``),
    # or the owning model consumed a mounted loader-subsystem field by BARE name
    # (``Box.raw.k``); resolve it to the array bound for the current cadence
    # segment. Checked before state/param so the producer symbol wins. A genuine
    # SCALAR field (0-D or single-element) referenced BARE is scalarised — exactly
    # as the loaded-`ic` path (`_resolve_field_ic`: ``float(arr.flat[0])``) and the
    # Julia gather resolver do — so ``D(c) = raw.k - c`` sees the value, not a
    # 1-vector that later fails ``float(...)``; a multi-element field stays an array
    # for gather / whole-array consumption.
    if name in ctx.input_arrays:
        arr = ctx.input_arrays[name]
        if isinstance(arr, np.ndarray) and arr.size == 1:
            return float(arr.reshape(-1)[0])
        return arr
    if name in ctx.state_layout:
        return _view_state_array(name, ctx)
    if name in ctx.param_values:
        return float(ctx.param_values[name])
    if name in ctx.observed_values:
        return float(ctx.observed_values[name])
    try:
        return float(name)
    except (TypeError, ValueError) as exc:
        raise NumpyInterpreterError(f"Unresolved symbol: {name!r}") from exc


# Unary elementary op -> numpy ufunc. VALUES local (op_registry is a numpy-free
# leaf); the KEY SET is DERIVED from the registry's unary-elementary ops just
# below, so it cannot drift. Building the live dict by iterating that key set
# makes a missing value a loud import-time KeyError.
_SCALAR_FUNCS_IMPL: dict[str, Callable] = {
    "exp": np.exp,
    "log": np.log,
    "log10": np.log10,
    "sqrt": np.sqrt,
    "abs": np.abs,
    "sin": np.sin,
    "cos": np.cos,
    "tan": np.tan,
    "asin": np.arcsin,
    "acos": np.arccos,
    "atan": np.arctan,
    "sinh": np.sinh,
    "cosh": np.cosh,
    "tanh": np.tanh,
    "asinh": np.arcsinh,
    "acosh": np.arccosh,
    "atanh": np.arctanh,
    "floor": np.floor,
    "ceil": np.ceil,
    "sign": np.sign,
}

_SCALAR_FUNCS: dict[str, Callable] = {
    op: _SCALAR_FUNCS_IMPL[op] for op in op_registry.unary_elementary()
}


#: Comparison ops → numpy ufunc. Hoisted to module scope (was rebuilt per
#: comparison inside eval_expr) so both the tree walker and the compiled
#: closure share one table. VALUES local; KEY SET derived from the registry's
#: (non-alias) comparison category so it cannot drift.
_CMP_UFUNCS_IMPL: dict[str, Callable] = {
    ">": np.greater,
    "<": np.less,
    ">=": np.greater_equal,
    "<=": np.less_equal,
    "==": np.equal,
    "!=": np.not_equal,
}

_CMP_UFUNCS: dict[str, Callable] = {
    op: _CMP_UFUNCS_IMPL[op]
    for op in op_registry.by_category("comparison") & op_registry.canonical_names()
}


def _broadcast_fn(fn: str) -> Callable:
    table = {
        "+": np.add,
        "-": np.subtract,
        "*": np.multiply,
        "/": np.true_divide,
        "^": np.power,
        "**": np.power,
        "min": np.minimum,
        "max": np.maximum,
    }
    if fn not in table:
        raise NumpyInterpreterError(f"Unsupported broadcast fn: {fn}")
    return table[fn]


# Closed semiring registry (RFC semiring-faq-unified-ir §5.1). Each entry fixes
# the (⊕, ⊗) operator pair AND both identity elements: ``zero`` (0̄) is the value
# of an empty ⊕-reduction and ``one`` (1̄) the value of an empty ⊗-product. The
# ``reduce`` field of a node names only ⊕; ⊗ and the identities come from this
# table, never from the file. Adding a semiring is a spec change, not a per-file
# extension, so this registry is closed and exhaustive.
_SEMIRINGS: dict[str, dict[str, Any]] = {
    "sum_product": {"oplus": "+", "zero": 0.0, "otimes": "*", "one": 1.0},
    "max_product": {"oplus": "max", "zero": -np.inf, "otimes": "*", "one": 1.0},
    "min_sum": {"oplus": "min", "zero": np.inf, "otimes": "+", "one": 0.0},
    "max_sum": {"oplus": "max", "zero": -np.inf, "otimes": "+", "one": 0.0},
    "bool_and_or": {"oplus": "or", "zero": 0.0, "otimes": "and", "one": 1.0},
}


def _resolve_semiring(expr: ExprNode) -> tuple[str, float, str]:
    """Return ``(reduce_op ⊕, empty_zero 0̄, otimes ⊗)`` for an aggregate node.

    When ``semiring`` is present it supersedes ``reduce``: the ⊕/⊗ operators and
    both identities come from the closed registry (:data:`_SEMIRINGS`). When it
    is absent the legacy behaviour is reproduced exactly — ⊕ is the ``reduce``
    field (default ``"+"``), ⊗ is ``"*"``, and an empty reduction returns ``0.0``
    as it does today (the implicit ``sum_product`` row, RFC §5.1).
    """
    semiring = getattr(expr, "semiring", None)
    if semiring is not None:
        sr = _SEMIRINGS.get(semiring)
        if sr is None:
            raise NumpyInterpreterError(
                f"unregistered semiring {semiring!r}; the closed registry is "
                f"{sorted(_SEMIRINGS)} (RFC semiring-faq-unified-ir §5.1)"
            )
        return sr["oplus"], sr["zero"], sr["otimes"]
    return (expr.reduce or "+"), 0.0, "*"


@dataclass
class _RaggedRange:
    """A resolved ragged / dependent inner index set (RFC §5.2, ``kind: ragged``).

    The member count for each parent tuple is read from the ``offsets`` keyed
    factor at iteration time; the range over the inner index is the per-parent
    dynamic bound ``[1 .. offsets[parent]]``. The actual member at position ``k``
    is gathered through the ``values`` factor by the node body itself (an
    ``index(values, parent…, k)`` reference), so the evaluator only needs the
    bound here — mirroring the Julia ``_expand_int_range_dyn`` dynamic bound.
    """

    name: str
    of: list[str]
    offsets: str
    values: str | None


def _resolve_range_spec(spec: Any, ctx: EvalContext) -> Any:
    """Resolve one arrayop / aggregate range spec against the index-set registry.

    ``spec`` is either a dense integer tuple (``[lo, hi]`` / ``[lo, step, hi]``,
    as today) or an index-set reference ``{"from": <name>, "of": [...]}`` (RFC
    §5.2). Returns a dense list spec for interval / categorical / dense ranges
    (to be expanded by :func:`_expand_range`) or a :class:`_RaggedRange` for
    ragged sets. Raises on an undeclared ``from`` name (no implicit interval
    inference, so a typo cannot silently become an empty set) and on ``derived``
    sets, whose materialization is not part of M1 (RFC §5.5).
    """
    if not isinstance(spec, dict):
        return spec  # dense list — unchanged (today's path)
    name = spec.get("from")
    if name is None:
        raise NumpyInterpreterError(
            f"arrayop / aggregate range reference {spec!r} is missing 'from'"
        )
    entry = ctx.index_sets.get(name)
    if entry is None:
        raise NumpyInterpreterError(
            f"undeclared index set {name!r} referenced by a range 'from'; "
            f"declared index sets are {sorted(ctx.index_sets)} "
            f"(RFC semiring-faq-unified-ir §5.2: no implicit interval inference)"
        )
    kind = entry.get("kind")
    if kind == "interval":
        return [1, int(entry["size"])]
    if kind == "categorical":
        return [1, len(entry.get("members") or [])]
    if kind == "ragged":
        of = list(spec.get("of") or entry.get("of") or [])
        return _RaggedRange(
            name=name,
            of=of,
            offsets=entry["offsets"],
            values=entry.get("values"),
        )
    if kind == "derived":
        # A data-derived index set (RFC §5.5 / §8.1) resolves its extent from a
        # producer materialized off the per-step hot path. Two front-doors share
        # this resolution, exactly as in the Julia reference:
        #   (a) the build-time value-invention engine (skolem/distinct/rank via
        #       the relational engine, §6.1) hands its distinct-set cardinality in
        #       `ctx.derived_extents`, keyed by the producer `id`; and
        #   (b) the `intersect_polygon` clip case materializes a closed ring into
        #       `ctx.derived_rings` at runtime (the producer is evaluated first —
        #       observed clip variables run before the FAQ that consumes them).
        # The derived set's extent is the dense `[1, n]` either way.
        faq = entry.get("from_faq")
        if faq is None:
            raise NumpyInterpreterError(
                f"derived index set {name!r} is missing 'from_faq' (RFC §5.5)"
            )
        extent = ctx.derived_extents.get(faq)
        if extent is not None:
            return [1, int(extent)]
        ring = ctx.derived_rings.get(faq)
        if ring is None:
            raise NumpyInterpreterError(
                f"derived index set {name!r} (from_faq {faq!r}) is not materialized; "
                f"its producing node has not been evaluated. Materialized rings: "
                f"{sorted(ctx.derived_rings)}, value-invention extents: "
                f"{sorted(ctx.derived_extents)} (RFC §5.5 / §8.1)"
            )
        n_vertices = max(int(ring.shape[0]) - 1, 0)  # closed ring has n+1 rows
        return [1, n_vertices]
    raise NumpyInterpreterError(f"index set {name!r} has unknown kind {kind!r}")


def _resolve_keyed_factor(name: str, ctx: EvalContext) -> float | np.ndarray:
    """Resolve a ragged set's keyed factor (``offsets`` / ``values``, §5.4).

    Keyed factors bind by BARE name in the model scope; ``ctx.factor_scope``
    supplies the in-scope (possibly flattening-namespaced) variable backing the
    bare name (exact name wins, else the unique shallowest dot-suffix match —
    see :func:`ragged_factor_scope`). An unmapped name resolves as-is, so an
    unbound factor still surfaces the standard unresolved-symbol error.
    """
    return _resolve_symbol(ctx.factor_scope.get(name, name), ctx)


def _expand_ragged(rr: _RaggedRange, ctx: EvalContext, binding: dict[str, int]) -> list[int]:
    """Expand a ragged inner set to ``[1 .. offsets[parent]]`` for one parent tuple.

    ``binding`` supplies the (1-based) parent index values named in ``rr.of``.
    The per-parent length is read from the ``offsets`` keyed factor, resolved
    through the model-scope keyed-factor map (:func:`_resolve_keyed_factor`).
    """
    off = _resolve_keyed_factor(rr.offsets, ctx)
    if isinstance(off, np.ndarray) and off.ndim > 0:
        try:
            parent_idx = tuple(int(binding[p]) - 1 for p in rr.of)
        except KeyError as exc:
            raise NumpyInterpreterError(
                f"ragged index set {rr.name!r} parent index {exc.args[0]!r} is "
                f"not bound; declare it in 'of' and an enclosing range"
            ) from exc
        n = int(round(float(off[parent_idx])))
    else:
        n = int(round(float(off)))
    return list(range(1, n + 1))


def _eval_fn_lifted(name: str, args: list[Any], const_positions: Sequence[int]):
    """Evaluate a closed function, LIFTING it element-wise over grid-valued args.

    The registered closed functions (``interp.linear``, …) are scalar (0-D). When
    a coupled/discretized system feeds a grid-valued "point" argument — e.g. a
    per-cell LANDFIRE fuel code into ``FuelModelLookup``'s ``interp.linear`` — the
    scalar function must be applied at every cell. The ``const_positions`` args
    (interp tables/axes) are passed whole; the remaining "point" args are
    broadcast together and the function is evaluated per element, returning the
    matching grid. All-scalar point args keep the 0-D fast path (one call → a
    Python float).
    """
    from .registered_functions import evaluate_closed_function

    const = set(const_positions or ())
    point_positions = [i for i in range(len(args)) if i not in const]
    point_arrs = [np.asarray(args[i]) for i in point_positions]
    if not point_arrs or all(a.ndim == 0 for a in point_arrs):
        return float(evaluate_closed_function(name, args))
    # np.broadcast_arrays (long-standing) instead of np.broadcast_shapes (>=1.20).
    bcast = np.broadcast_arrays(*point_arrs)
    shape = np.asarray(bcast[0]).shape
    cols = [np.asarray(b, dtype=float).ravel() for b in bcast]
    out = np.empty(cols[0].size, dtype=float)
    scratch = list(args)
    for k in range(out.size):
        for pos, col in zip(point_positions, cols):
            scratch[pos] = float(col[k])
        out[k] = float(evaluate_closed_function(name, scratch))
    return out.reshape(shape)


# --- Shared per-op scalar/array semantics (single source of truth) ---
# The tree walker (:func:`eval_expr`) and the compiled builder
# (:func:`_build_compiled_node`) BOTH dispatch the same arithmetic / min / max /
# ifelse / comparison / logical ops. To keep the two evaluators from silently
# drifting, the actual value combination for each op lives HERE, exactly once,
# and both paths call it after evaluating the operands (mirroring how
# :func:`_gather_index` centralises the ``index`` gather). These operate on
# ALREADY-EVALUATED operand values, so they are agnostic to how the operands
# were produced (recursive eval vs pre-compiled closure) and therefore cannot
# change the numerics, dtype, broadcasting or NaN/inf behaviour of either path.
# Any op change here updates both evaluators at once.


def _apply_add(vals: list[Any]) -> Any:
    acc = vals[0]
    for v in vals[1:]:
        acc = acc + v
    return acc


def _apply_sub(vals: list[Any]) -> Any:
    if len(vals) == 1:
        return -vals[0]
    acc = vals[0]
    for v in vals[1:]:
        acc = acc - v
    return acc


def _apply_mul(vals: list[Any]) -> Any:
    acc = vals[0]
    for v in vals[1:]:
        acc = acc * v
    return acc


def _apply_div(a: Any, b: Any) -> Any:
    return a / b


def _apply_pow(a: Any, b: Any) -> Any:
    return a**b


def _apply_atan2(a: Any, b: Any) -> Any:
    return np.arctan2(a, b)


def _apply_bool_reduce(vals: list[Any], uf: Callable) -> np.ndarray:
    """``and``/``or`` reduce (``uf`` is ``np.logical_and``/``np.logical_or``),
    coercing the boolean result to float exactly as both original branches did."""
    r = vals[0]
    for v in vals[1:]:
        r = uf(r, v)
    return r.astype(float)


def _apply_not(v: Any) -> np.ndarray:
    return np.logical_not(v).astype(float)


def _apply_minmax(vals: list[Any], uf: Callable) -> Any:
    """``min``/``max`` reduce (``uf`` is ``np.minimum``/``np.maximum``).

    Pairwise reduce (not ``ufunc.reduce``): ``np.minimum.reduce`` stacks the
    operand list into one array first, which fails on mixed array/scalar operands
    (e.g. ``min(field[l], scalar)``); pairwise reduction broadcasts each step,
    keeping array operands array-valued. A single operand is returned unchanged.
    """
    return functools.reduce(uf, vals) if len(vals) > 1 else vals[0]


def _apply_ifelse(cond: Any, a: Any, b: Any) -> np.ndarray:
    return np.where(cond, a, b)


def _apply_cmp(a: Any, b: Any, uf: Callable) -> np.ndarray:
    """Comparison via ``uf`` (a :data:`_CMP_UFUNCS` entry), coerced to float."""
    return uf(a, b).astype(float)


def eval_expr(expr: Expr, ctx: EvalContext) -> float | np.ndarray:
    """Recursively evaluate an ESM expression against ``ctx``.

    Returns a Python float for scalar results or a numpy ndarray for
    array-valued sub-expressions.
    """
    # Interior AST nodes dominate a deep stencil tree and recurse the most, so
    # test ExprNode FIRST (one isinstance on the hot path) and handle the three
    # leaf kinds — string symbol, bool, number — only when it is not a node. This
    # is semantically identical to the leaf-first order but pays a single
    # isinstance per interior node instead of four (`isinstance` was ~13% of the
    # profile's self time).
    if not isinstance(expr, ExprNode):
        if isinstance(expr, str):
            return _resolve_symbol(expr, ctx)
        if isinstance(expr, bool):
            return float(expr)
        if isinstance(expr, (int, float)):
            return float(expr)
        raise NumpyInterpreterError(f"Cannot evaluate expression of type {type(expr).__name__}")

    op = expr.op
    # `index` is the most frequent interior op in a discretized stencil body
    # (every array read is one); dispatch it before the long arithmetic /
    # closed-function chain so an `index` node does not pay ~18 failed string
    # comparisons per evaluation. The duplicate `index` case further down the
    # chain is removed.
    if op == "index":
        return _eval_index(expr, ctx)
    # --- closed function registry ops (esm-spec §9.2 / §9.3) ---
    if op == "const":
        v = expr.value
        if isinstance(v, (list, tuple)):
            return np.asarray(v, dtype=float)
        if isinstance(v, (int, float)) and not isinstance(v, bool):
            return float(v)
        raise NumpyInterpreterError(
            f"`const` op value must be a number or nested array, got {type(v).__name__}"
        )
    if op == "fn":
        from .registered_functions import extract_const_array

        if expr.name is None:
            raise NumpyInterpreterError("`fn` op requires a `name` field")
        evaluated_args = []
        const_arg_positions = _INTERP_CONST_ARG_POSITIONS.get(expr.name, ())
        for i, a in enumerate(expr.args):
            if i in const_arg_positions and isinstance(a, ExprNode) and a.op == "const":
                evaluated_args.append(extract_const_array(a))
            else:
                evaluated_args.append(eval_expr(a, ctx))
        return _eval_fn_lifted(expr.name, evaluated_args, const_arg_positions)
    if op == "enum":
        raise NumpyInterpreterError(
            "`enum` op encountered at evaluate time — `lower_enums(file)` should "
            "have run during load (esm-spec §9.3)"
        )

    # --- scalar arithmetic / elementwise ---
    if op == "+":
        if not expr.args:
            return 0.0
        return _apply_add([eval_expr(a, ctx) for a in expr.args])
    if op == "-":
        return _apply_sub([eval_expr(a, ctx) for a in expr.args])
    if op == "*":
        if not expr.args:
            return 1.0
        return _apply_mul([eval_expr(a, ctx) for a in expr.args])
    if op == "/":
        if len(expr.args) != 2:
            raise NumpyInterpreterError("/ expects 2 args")
        a = eval_expr(expr.args[0], ctx)
        b = eval_expr(expr.args[1], ctx)
        return _apply_div(a, b)
    if op in ("^", "**", "pow"):
        if len(expr.args) != 2:
            raise NumpyInterpreterError(f"{op} expects 2 args")
        a = eval_expr(expr.args[0], ctx)
        b = eval_expr(expr.args[1], ctx)
        return _apply_pow(a, b)
    if op == "atan2":
        if len(expr.args) != 2:
            raise NumpyInterpreterError("atan2 expects 2 args")
        a = eval_expr(expr.args[0], ctx)
        b = eval_expr(expr.args[1], ctx)
        return _apply_atan2(a, b)
    if op in ("and", "or"):
        if len(expr.args) < 2:
            raise NumpyInterpreterError(f"{op} expects at least 2 args")
        vals = [eval_expr(a, ctx) for a in expr.args]
        return _apply_bool_reduce(vals, np.logical_and if op == "and" else np.logical_or)
    if op == "not":
        if len(expr.args) != 1:
            raise NumpyInterpreterError("not expects 1 arg")
        v = eval_expr(expr.args[0], ctx)
        return _apply_not(v)
    if op in _SCALAR_FUNCS:
        if len(expr.args) != 1:
            raise NumpyInterpreterError(f"{op} expects 1 arg")
        v = eval_expr(expr.args[0], ctx)
        return _SCALAR_FUNCS[op](v)
    if op == "min":
        vals = [eval_expr(a, ctx) for a in expr.args]
        return _apply_minmax(vals, np.minimum)
    if op == "max":
        vals = [eval_expr(a, ctx) for a in expr.args]
        return _apply_minmax(vals, np.maximum)
    if op == "ifelse":
        if len(expr.args) != 3:
            raise NumpyInterpreterError("ifelse expects 3 args")
        cond = eval_expr(expr.args[0], ctx)
        a = eval_expr(expr.args[1], ctx)
        b = eval_expr(expr.args[2], ctx)
        return _apply_ifelse(cond, a, b)
    if op in (">", "<", ">=", "<=", "==", "!="):
        if len(expr.args) != 2:
            raise NumpyInterpreterError(f"{op} expects 2 args")
        a = eval_expr(expr.args[0], ctx)
        b = eval_expr(expr.args[1], ctx)
        return _apply_cmp(a, b, _CMP_UFUNCS[op])
    if op == "D":
        # esm-spec §4.2 / §9.6.8 (open-op-namespace RFC, Change B): `D` is an
        # evaluable-core op only in its STRUCTURAL equation-LHS role (consumed by
        # simulation to identify the differentiated state). A `D` reaching the RHS
        # evaluator — a spatial `D`, or any `D` in an RHS / observed / rate
        # position — is an unlowered rewrite-target: a discretization rule must
        # lower it to a stencil before evaluation. The gate fires here, before
        # evaluation, with the uniform `unlowered_operator` code (never the old
        # silently-evaluate-inner behaviour).
        raise UnreachableSpatialOperatorError("D")
    if op in ("grad", "div", "laplacian"):
        # grad/div/laplacian are NOT evaluable-core ops — they are optional
        # rewrite-target sugar over `D` that a discretization rule must lower to
        # an `aggregate`/`makearray` stencil before evaluation. One reaching the
        # evaluator means no rule lowered it. This format ships no discretization
        # rules (they live in EarthSciDiscretizations). Surface the violation
        # rather than substituting zero. Uniform `unlowered_operator` code.
        raise UnreachableSpatialOperatorError(op)

    # --- array ops --- (`index` is dispatched at the top of eval_expr)
    # "aggregate" is the canonical Functional Aggregate Query op tag.
    if op == "aggregate":
        return _eval_arrayop(expr, ctx)
    if op == "makearray":
        return _eval_makearray(expr, ctx)
    if op == "broadcast":
        return _eval_broadcast(expr, ctx)
    if op == "reshape":
        return _eval_reshape(expr, ctx)
    if op == "transpose":
        return _eval_transpose(expr, ctx)
    if op == "concat":
        return _eval_concat(expr, ctx)
    # --- conservative-regridding geometry kernel (RFC §8.1) ---
    if op == "intersect_polygon":
        return _eval_intersect_polygon(expr, ctx)
    if op == "polygon_intersection_area":
        return _eval_polygon_intersection_area(expr, ctx)
    # --- value-invention skolem key (RFC §5.3 / §5.7) ---
    if op == "skolem":
        return _eval_skolem(expr, ctx)
    if op == "true":
        return 1.0
    if op == "false":
        return 0.0

    raise NumpyInterpreterError(f"Unsupported op in NumPy interpreter: {op!r}")


#: Ops the expression compiler lowers to closures. Everything else (aggregate,
#: makearray, fn, broadcast/reshape/transpose/concat, the geometry leaves,
#: skolem, const, the unlowered-operator gates …) is left to :func:`eval_expr`
#: verbatim — the compiler only removes the per-node dispatch of the scalar
#: arithmetic / index / elementwise-math layer that a discretized stencil body
#: is overwhelmingly made of.
_COMPILED_OPS: frozenset = frozenset(
    {"index", "+", "-", "*", "/", "^", "**", "pow", "atan2", "and", "or", "not",
     "min", "max", "ifelse", "true", "false"}
    | set(_SCALAR_FUNCS)
    | set(_CMP_UFUNCS)
)


def _compile_delegate(node: Expr) -> Callable[[EvalContext], Any]:
    """Closure that re-evaluates ``node`` through the tree walker unchanged — the
    compiler's escape hatch for every op it does not lower (so behaviour, errors
    and numerics are byte-identical to :func:`eval_expr`)."""
    return lambda ctx: eval_expr(node, ctx)


def _compile_expr(expr: Expr) -> Callable[[EvalContext], Any]:
    """Compile an expression AST into a ``ctx -> value`` closure that reproduces
    :func:`eval_expr` exactly but pre-dispatches each node's op and pre-compiles
    its children ONCE, so a hot per-step body — the level-set front stencils, a
    ~600-node tree re-walked every implicit-solver step — skips the eval_expr
    ``op ==`` chain, the leaf ``isinstance`` ladder and the per-node ``getattr``
    on every evaluation. The compiled closure performs the identical NumPy
    operations in the identical order (structural ops delegate to
    :func:`eval_expr`), so results are bit-for-bit identical to the tree walker;
    only the Python dispatch overhead is removed.

    The closure is cached on the ExprNode (``_compiled_fn``) so each node compiles
    once per process and every solver step reuses it. Leaves (bare symbol / number)
    are not cached (they are not nodes) but compile to a trivial closure.
    """
    if not isinstance(expr, ExprNode):
        if isinstance(expr, str):
            name = expr
            return lambda ctx: _resolve_symbol(name, ctx)
        if isinstance(expr, bool):
            fv = float(expr)
            return lambda ctx: fv
        if isinstance(expr, (int, float)):
            fv = float(expr)
            return lambda ctx: fv
        return _compile_delegate(expr)  # unknown leaf → same error as eval_expr

    cached = getattr(expr, "_compiled_fn", None)
    if cached is not None:
        return cached
    fn = _build_compiled_node(expr)
    expr._compiled_fn = fn
    return fn


def _build_compiled_node(expr: ExprNode) -> Callable[[EvalContext], Any]:
    """Compile one ExprNode (see :func:`_compile_expr`). Mirrors the corresponding
    eval_expr branch exactly; delegates any op outside ``_COMPILED_OPS`` and any
    wrong-arity node (so the tree walker raises the identical error).

    The per-op value combination is NOT re-implemented here: each closure defers
    to the same ``_apply_*`` helper (``index`` to :func:`_gather_index`) that
    :func:`eval_expr` calls, so the two evaluators cannot drift on op semantics."""
    op = expr.op
    if op not in _COMPILED_OPS:
        return _compile_delegate(expr)
    args = expr.args or []

    if op == "index":
        if not args:
            return _compile_delegate(expr)  # eval_expr raises the arity error
        arr_c = _compile_expr(args[0])
        idx_c = [_compile_expr(a) for a in args[1:]]
        if not idx_c:
            return lambda ctx: _gather_index(arr_c(ctx), [])

        def f_index(ctx):
            return _gather_index(arr_c(ctx), [c(ctx) for c in idx_c])

        return f_index

    if op in _SCALAR_FUNCS:
        if len(args) != 1:
            return _compile_delegate(expr)
        fn = _SCALAR_FUNCS[op]
        c0 = _compile_expr(args[0])
        return lambda ctx: fn(c0(ctx))

    if op in _CMP_UFUNCS:
        if len(args) != 2:
            return _compile_delegate(expr)
        uf = _CMP_UFUNCS[op]
        ac = _compile_expr(args[0])
        bc = _compile_expr(args[1])
        return lambda ctx: _apply_cmp(ac(ctx), bc(ctx), uf)

    if op == "+":
        if not args:
            return lambda ctx: 0.0
        cs = [_compile_expr(a) for a in args]
        return lambda ctx: _apply_add([c(ctx) for c in cs])

    if op == "-":
        cs = [_compile_expr(a) for a in args]
        return lambda ctx: _apply_sub([c(ctx) for c in cs])

    if op == "*":
        if not args:
            return lambda ctx: 1.0
        cs = [_compile_expr(a) for a in args]
        return lambda ctx: _apply_mul([c(ctx) for c in cs])

    if op == "/":
        if len(args) != 2:
            return _compile_delegate(expr)
        ac = _compile_expr(args[0])
        bc = _compile_expr(args[1])
        return lambda ctx: _apply_div(ac(ctx), bc(ctx))

    if op in ("^", "**", "pow"):
        if len(args) != 2:
            return _compile_delegate(expr)
        ac = _compile_expr(args[0])
        bc = _compile_expr(args[1])
        return lambda ctx: _apply_pow(ac(ctx), bc(ctx))

    if op == "atan2":
        if len(args) != 2:
            return _compile_delegate(expr)
        ac = _compile_expr(args[0])
        bc = _compile_expr(args[1])
        return lambda ctx: _apply_atan2(ac(ctx), bc(ctx))

    if op in ("and", "or"):
        if len(args) < 2:
            return _compile_delegate(expr)
        uf = np.logical_and if op == "and" else np.logical_or
        cs = [_compile_expr(a) for a in args]
        return lambda ctx: _apply_bool_reduce([c(ctx) for c in cs], uf)

    if op == "not":
        if len(args) != 1:
            return _compile_delegate(expr)
        c0 = _compile_expr(args[0])
        return lambda ctx: _apply_not(c0(ctx))

    if op in ("min", "max"):
        uf = np.minimum if op == "min" else np.maximum
        cs = [_compile_expr(a) for a in args]
        return lambda ctx: _apply_minmax([c(ctx) for c in cs], uf)

    if op == "ifelse":
        if len(args) != 3:
            return _compile_delegate(expr)
        cc = _compile_expr(args[0])
        ac = _compile_expr(args[1])
        bc = _compile_expr(args[2])
        return lambda ctx: _apply_ifelse(cc(ctx), ac(ctx), bc(ctx))

    if op == "true":
        return lambda ctx: 1.0
    if op == "false":
        return lambda ctx: 0.0

    return _compile_delegate(expr)  # unreachable (op in _COMPILED_OPS covers all)


def _skolem_atom(value: float) -> tuple[str, Any]:
    """Canonicalise one numeric skolem component (integers kept exact)."""
    fv = float(value)
    return ("i", int(fv)) if fv == int(fv) else ("f", repr(fv))


def _skolem_code(parts: Sequence[tuple[str, Any]]) -> float:
    """Hash a canonical skolem-argument tuple to a 48-bit integer code (float).

    BLAKE2b to 48 bits — exactly representable in float64 and stable across
    processes — mirroring the Julia setup-geometry evaluator's
    ``hash(Tuple(vals))`` skolem (tree_walk.jl §433).
    """
    import hashlib

    digest = hashlib.blake2b(
        repr(tuple(parts)).encode("utf-8"), digest_size=_SKOLEM_DIGEST_BYTES
    ).digest()
    return float(int.from_bytes(digest, "big"))


def _eval_skolem(expr: ExprNode, ctx: EvalContext) -> float | np.ndarray:
    """Evaluate a ``skolem`` key node to a deterministic integer code (as float).

    A skolem term is a deterministic identity for its argument tuple; it is only
    ever COMPARED (the broad-phase equi-join, RFC §5.3), so any injective
    encoding of the tuple suffices. EVERY ``args`` entry is a PURE key component:
    it is evaluated and canonicalised (integers kept exact). The relation tag
    lives in the dedicated ``label`` field — it is DOCUMENTARY (both sides of a
    join carry the same label, so it does no disambiguation work) and is NOT
    hashed into the code, which therefore encodes only the pure ``args``.

    Array-aware: when the vectorized map path binds an index symbol to a whole
    range (so a subscript evaluates to an ndarray), the codes are computed
    ELEMENT-WISE and returned as an ndarray — otherwise the per-cell bins would
    collapse to a single code. Scalar args yield a single float code.
    """
    _label = expr.label  # documentary relation tag; NOT encoded into the join code
    evaled: list[tuple[str, Any]] = []
    n: int | None = None
    for a in expr.args:
        arr = np.asarray(eval_expr(a, ctx), dtype=float)
        if arr.ndim == 0:
            evaled.append(("scalar", float(arr)))
        else:
            flat = arr.reshape(-1)
            if n is None:
                n = flat.size
            elif n != flat.size:
                raise NumpyInterpreterError(
                    f"skolem array args have mismatched lengths ({n} vs {flat.size})"
                )
            evaled.append(("array", flat))
    if n is None:
        parts = [_skolem_atom(v) for _, v in evaled]
        return _skolem_code(parts)
    codes = np.empty(n, dtype=float)
    for i in range(n):
        parts = []
        for kind, val in evaled:
            if kind == "scalar":
                parts.append(_skolem_atom(val))
            else:
                parts.append(_skolem_atom(val[i]))
        codes[i] = _skolem_code(parts)
    return codes


def _eval_intersect_polygon(expr: ExprNode, ctx: EvalContext) -> np.ndarray:
    """Evaluate the ``intersect_polygon`` clip leaf (RFC §8.1).

    Clips the two operand polygon rings under the node's required ``manifold``
    and returns the overlap ring as a CLOSED ``[n+1, 2]`` lon-lat array (first
    vertex repeated) so the ``polygon_area`` FAQ can read the wrap edge as an
    ordinary ``index(ring, v+1, …)``. When the node carries an ``id`` the ring is
    registered in ``ctx.derived_rings`` so the ``kind:"derived"`` clip-ring index
    set (``from_faq: <id>``) resolves its extent and the ring is addressable by
    that id — making ``polygon_area`` an ordinary ``sum_product`` FAQ over it.

    The clip is the only geometry-specific kernel; the area is *not* computed
    here. For ``spherical``/``geodesic`` the clip is delegated to the pinned
    optional ``spherely`` (S2); ``planar`` is dependency-free. An empty overlap
    yields an empty ``(0, 2)`` array (registered as an extent-0 derived set).
    """
    from . import geometry

    manifold = getattr(expr, "manifold", None)
    if manifold is None:
        raise NumpyInterpreterError(
            "intersect_polygon requires a 'manifold' field (planar / spherical / "
            "geodesic); it carries no default (CONFORMANCE_SPEC.md §5.8.4)"
        )
    if len(expr.args) != 2:
        raise NumpyInterpreterError(
            f"intersect_polygon is strictly binary; got {len(expr.args)} operand(s)"
        )
    poly_a = _as_array(eval_expr(expr.args[0], ctx))
    poly_b = _as_array(eval_expr(expr.args[1], ctx))
    try:
        ring = geometry.intersect_polygon(poly_a, poly_b, manifold)
    except geometry.GeometryError as exc:
        raise NumpyInterpreterError(str(exc)) from exc
    closed = geometry.close_ring(ring)
    node_id = getattr(expr, "id", None)
    if node_id is not None:
        ctx.derived_rings[node_id] = closed
    return closed


def _eval_polygon_intersection_area(expr: ExprNode, ctx: EvalContext) -> float:
    """Evaluate the fused ``polygon_intersection_area`` leaf (esm-spec.md §8.6.1).

    The SCALAR overlap area of the two operand polygon rings under the node's
    required ``manifold`` — defined to equal
    ``polygon_area(intersect_polygon(a, b))`` at the same manifold, but as a
    single fused leaf with NO exposed clip ring / derived index set. It is the
    fused form of the existing clip + shoelace: it reuses the very same
    :func:`geometry.intersect_polygon` clip and the ``polygon_area`` ``sum_product``
    FAQ (:func:`earthsci_ast.area_faq.polygon_area_via_faq`) that the
    unfused ``intersect_polygon`` + area-FAQ fixture drives — no geometry is
    reimplemented here.

    Because it returns a scalar (a plain ``float``), it evaluates as an ordinary
    scalar leaf: no ring is registered in ``ctx.derived_rings`` and no node ``id``
    is materialized, so it is equally usable inside an ``aggregate`` body or as a
    bare observed. ``planar`` is dependency-free (Sutherland–Hodgman clip +
    shoelace); ``spherical`` / ``geodesic`` inherit the pinned S2 clip + the
    great-circle spherical-excess FAQ. A non-overlapping pair yields ``0.0``.
    """
    from . import geometry
    from .area_faq import polygon_area_via_faq

    manifold = getattr(expr, "manifold", None)
    if manifold is None:
        raise NumpyInterpreterError(
            "polygon_intersection_area requires a 'manifold' field (planar / "
            "spherical / geodesic); it carries no default (CONFORMANCE_SPEC.md §5.8.4)"
        )
    if len(expr.args) != 2:
        raise NumpyInterpreterError(
            f"polygon_intersection_area is strictly binary; got {len(expr.args)} operand(s)"
        )
    poly_a = _as_array(eval_expr(expr.args[0], ctx))
    poly_b = _as_array(eval_expr(expr.args[1], ctx))
    try:
        ring = geometry.intersect_polygon(poly_a, poly_b, manifold)
    except geometry.GeometryError as exc:
        raise NumpyInterpreterError(str(exc)) from exc
    return float(polygon_area_via_faq(ring, manifold))


def _gather_index(
    arr_val: float | np.ndarray, idxs: list[float | np.ndarray]
) -> float | np.ndarray:
    """The gather at the core of an ``index`` node: ``arr_val`` already evaluated
    to a value and ``idxs`` to its (1-based) subscripts. Factored out of
    :func:`_eval_index` so the compiled ``index`` closure (:func:`_compile_expr`)
    performs the byte-identical gather and the two paths can never drift."""
    if not isinstance(arr_val, np.ndarray):
        # Scalar passed through: if no indices, return it; otherwise that's an error.
        if not idxs:
            return float(arr_val)
        raise NumpyInterpreterError("index applied to scalar value")
    # Vectorized gather: at least one subscript is an ndarray (the stencil fast
    # path binds index symbols to ranges). Convert 1-based -> 0-based and gather
    # with the *same* NumPy indexing semantics as the scalar branch below
    # (negative indices wrap), so the two paths are bit-identical. The discretized
    # makearray uses a disjoint interior box + single-cell boundary regions
    # (spatial_discretize._apply_makearray_bcs), so no stencil body reads out of bounds.
    if any(isinstance(i, np.ndarray) for i in idxs):
        if len(idxs) != arr_val.ndim:
            raise NumpyInterpreterError(
                f"index got {len(idxs)} indices for array of shape {arr_val.shape}"
            )
        gathered = [np.rint(np.asarray(i, dtype=float)).astype(np.intp) - 1 for i in idxs]
        return arr_val[tuple(gathered)]
    # 1-based -> 0-based.
    zero_idx = tuple(int(round(float(i))) - 1 for i in idxs)
    if len(zero_idx) > arr_val.ndim:
        raise NumpyInterpreterError(
            f"index got {len(zero_idx)} indices for array of shape {arr_val.shape}"
        )
    # Partial index (fewer subscripts than dims) → the trailing-dims sub-array,
    # e.g. ``index(rg_src_poly[a,v,c], a)`` → the a-th (v,c) vertex ring. A full
    # index yields the scalar element. Mirrors the Julia setup-geometry
    # evaluator's partial-index slice (tree_walk.jl _geo_eval).
    sub = arr_val[zero_idx]
    if np.ndim(sub) == 0:
        return float(sub)
    return np.asarray(sub, dtype=float)


def _eval_index(expr: ExprNode, ctx: EvalContext) -> float | np.ndarray:
    if not expr.args:
        raise NumpyInterpreterError("index requires at least 1 arg (the array)")
    arr_val = eval_expr(expr.args[0], ctx)
    idxs = [eval_expr(a, ctx) for a in expr.args[1:]]
    return _gather_index(arr_val, idxs)


def _decompose_body_as_scaled_product(
    body: Expr,
    all_syms: frozenset,
) -> tuple[float, list[tuple[str, list[str]]]] | None:
    """Try to decompose body as (scalar_coeff, [(var, [sym, ...]), ...]).

    Only handles bodies that are numeric literals or products of ``index(var,
    sym, ...)`` nodes where every subscript is a bare index symbol present in
    ``all_syms``. Returns ``None`` for affine subscripts, unary ops, sums, or
    any other structure that requires the scalar fallback.
    """
    if isinstance(body, bool):
        return None
    if isinstance(body, (int, float)):
        return float(body), []
    if isinstance(body, str):
        return None
    if not isinstance(body, ExprNode):
        return None
    if body.op == "index":
        if not body.args:
            return None
        var = body.args[0]
        if not isinstance(var, str):
            return None
        subscripts: list[str] = []
        for s in body.args[1:]:
            if isinstance(s, str) and s in all_syms:
                subscripts.append(s)
            else:
                return None
        return 1.0, [(var, subscripts)]
    if body.op == "*":
        coeff = 1.0
        terms: list[tuple[str, list[str]]] = []
        for arg in body.args:
            r = _decompose_body_as_scaled_product(arg, all_syms)
            if r is None:
                return None
            c, t = r
            coeff *= c
            terms.extend(t)
        return coeff, terms
    return None


def _eval_arrayop_vectorized(
    body: Expr,
    ctx: EvalContext,
    out_syms: list[str],
    reduce_syms: list[str],
    sym_0based: dict[str, list[int]],
    out_shape: tuple[int, ...],
    reducer: str,
) -> np.ndarray | None:
    """Vectorized fast path for arrayop evaluation.

    Handles bodies that are scalar multiples of products of ``index(var,
    sym, ...)`` with pure symbol subscripts.  For ``+`` reduction uses
    ``np.einsum``; for ``max``/``min``/``*`` builds a combined outer-product
    array and reduces along the contraction axes.  Returns ``None`` when the
    body does not match the supported pattern (falls back to scalar loop).
    """
    all_syms: frozenset = frozenset(out_syms) | frozenset(reduce_syms)
    decomp = _decompose_body_as_scaled_product(body, all_syms)
    if decomp is None:
        return None
    coeff, index_terms = decomp

    if not index_terms:
        # Pure scalar body — tile over output shape, fold reducer.
        n_red = 1
        for s in reduce_syms:
            n_red *= len(sym_0based[s])
        if reducer == "+":
            val = coeff * n_red
        elif reducer == "*":
            val = coeff**n_red
        else:
            val = coeff
        return np.full(out_shape, val, dtype=float) if out_shape else np.float64(val)

    # Assign einsum letter labels (output symbols first, then reduction).
    sym_order: list[str] = list(out_syms) + [s for s in reduce_syms if s not in out_syms]
    if len(sym_order) > _EINSUM_MAX_LABELS:
        return None
    sym_letter: dict[str, str] = {s: chr(ord("a") + i) for i, s in enumerate(sym_order)}

    # Build 0-based-sliced arrays for each index term.
    sliced: list[np.ndarray] = []
    term_specs: list[str] = []
    effective_coeff = coeff

    for var_name, var_syms in index_terms:
        if len(set(var_syms)) != len(var_syms):
            return None  # Diagonal access — fall back
        if var_name in ctx.state_layout:
            arr = _view_state_array(var_name, ctx)
        elif var_name in ctx.param_values:
            if var_syms:
                return None
            effective_coeff *= ctx.param_values[var_name]
            continue
        elif var_name in ctx.observed_values:
            if var_syms:
                return None
            effective_coeff *= ctx.observed_values[var_name]
            continue
        else:
            return None
        if arr.ndim == 0 and not var_syms:
            effective_coeff *= float(arr)
            continue
        if arr.ndim != len(var_syms):
            return None
        idx_cols = [np.asarray(sym_0based[s], dtype=int) for s in var_syms]
        arr_slice = arr[idx_cols[0]] if len(idx_cols) == 1 else arr[np.ix_(*idx_cols)]
        sliced.append(np.asarray(arr_slice, dtype=float))
        term_specs.append("".join(sym_letter[s] for s in var_syms))

    if not sliced:
        n_red = 1
        for s in reduce_syms:
            n_red *= len(sym_0based[s])
        if reducer == "+":
            return np.full(out_shape, effective_coeff * n_red, dtype=float)
        return None

    out_spec = "".join(sym_letter[s] for s in out_syms)

    try:
        if reducer == "+":
            einsum_str = ",".join(term_specs) + "->" + out_spec
            result = np.asarray(effective_coeff * np.einsum(einsum_str, *sliced), dtype=float)
            return result.reshape(out_shape) if out_shape else result

        # For */max/min: build outer product over all symbols in terms, then reduce.
        # Scalar coefficient must be 1 for non-additive reducers to distribute correctly.
        if effective_coeff != 1.0:
            return None
        all_syms_in_terms: list[str] = []
        for spec in term_specs:
            for c in spec:
                if c not in all_syms_in_terms:
                    all_syms_in_terms.append(c)
        combined_spec = "".join(all_syms_in_terms)
        outer_str = ",".join(term_specs) + "->" + combined_spec
        combined = np.einsum(outer_str, *sliced)
        red_axes = tuple(i for i, c in enumerate(combined_spec) if c not in out_spec)
        if not red_axes:
            return np.asarray(combined, dtype=float).reshape(out_shape)
        if reducer == "*":
            return np.asarray(np.prod(combined, axis=red_axes), dtype=float)
        if reducer == "max":
            return np.asarray(np.max(combined, axis=red_axes), dtype=float)
        if reducer == "min":
            return np.asarray(np.min(combined, axis=red_axes), dtype=float)
    except (NumpyInterpreterError, IndexError, ValueError, TypeError, KeyError):
        # Decline (→ None, fall back to the scalar loop) on the same narrow error
        # tuple every sibling fast path catches; an unexpected error propagates.
        return None

    return None


def _bind_broadcast_range(
    ctx: EvalContext, sym: str, values: np.ndarray, axis: int, ndim: int
) -> None:
    """Bind ``sym`` to ``values`` reshaped to broadcast on ``axis`` of an
    ``ndim``-D output box (so an N-D region body evaluates in one pass)."""
    shp = [1] * ndim
    shp[axis] = values.size
    ctx.locals[sym] = np.asarray(values, dtype=float).reshape(shp)


@contextmanager
def _bound_index_box(
    ctx: EvalContext, syms: list[str], ranges: list[list[int]]
) -> Iterator[None]:
    """Bind each index symbol to its 1-based ``range`` reshaped to broadcast on
    its own axis of the ``len(syms)``-D box (so a body evaluates over the whole
    box in one pass), restoring ``ctx.locals`` on exit. The shared save / bind /
    restore of the whole-box vectorized paths (:func:`_materialize_map`,
    :func:`_eval_arrayop_reduce_vectorized`)."""
    prev = dict(ctx.locals)
    try:
        ndim = len(syms)
        for axis, s in enumerate(syms):
            _bind_broadcast_range(ctx, s, np.asarray(ranges[axis], dtype=float), axis, ndim)
        yield
    finally:
        ctx.locals = prev


def _expand_reduce_ranges(
    resolved: dict[str, Any], reduce_syms: list[str]
) -> list[list[int]]:
    """Dense 1-based value list for each contracted range, in ``reduce_syms``
    order (``_expand_range`` of each resolved reduce spec) — the one line every
    scalar / vectorized reduction path repeats to expand its contracted box."""
    return [_expand_range(resolved[s]) for s in reduce_syms]


def _materialize_makearray_vectorized(
    ma: ExprNode,
    ctx: EvalContext,
    out_syms: list[str],
    out_shape: tuple[int, ...],
) -> np.ndarray:
    """Materialize a ``makearray`` in one pass per region (no per-cell loop).

    Each region's body is evaluated with the output index symbols bound to that
    region's 1-based ``arange`` (reshaped to broadcast over the region box), and
    the resulting sub-array is written into the output slice. Regions are applied
    in order with last-wins overwrite — identical semantics to the scalar
    :func:`_eval_makearray`, but vectorized via shifted-slice ``index`` gathers.
    """
    regions = ma.regions or []
    values = ma.values or []
    if not regions or len(regions) != len(values):
        raise NumpyInterpreterError("makearray: empty or mismatched regions/values")
    ndim = len(out_syms)
    out = np.zeros(out_shape, dtype=float)
    prev = dict(ctx.locals)
    try:
        for region, val_expr in zip(regions, values):
            if len(region) != ndim:
                raise NumpyInterpreterError("makearray region ndim mismatch")
            slicer: list[slice] = []
            for axis, (lo, hi) in enumerate(region):
                lo_i, hi_i = int(lo), int(hi)
                _bind_broadcast_range(
                    ctx, out_syms[axis], np.arange(lo_i, hi_i + 1, dtype=float), axis, ndim
                )
                slicer.append(slice(lo_i - 1, hi_i))
            # Compiled body: this region value is the per-step front stencil,
            # re-evaluated every implicit-solver step, so lower it once to a
            # closure and skip the eval_expr dispatch walk on each step.
            out[tuple(slicer)] = _compile_expr(val_expr)(ctx)
    finally:
        ctx.locals = prev
    return out


def _materialize_map(
    body: Expr,
    ctx: EvalContext,
    out_syms: list[str],
    out_ranges_exp: list[list[int]],
    out_shape: tuple[int, ...],
) -> np.ndarray | None:
    """Vectorized fast path for a pure (non-reducing) arrayop map — the shape
    finite-difference / level-set stencils take.

    Two patterns are handled, both by binding the output index symbols to
    ``arange`` vectors so the body evaluates over the whole index box in one
    pass (``index`` gathers become shifted slices, see :func:`_eval_index`):

    * ``index(makearray(...), x, y, ...)`` — an identity gather over a
      region-wise ``makearray`` (the discretized state RHS). Materialized
      region-by-region.
    * any other body — bound directly over the full box.

    Returns ``None`` (caller falls back to the scalar loop) if the body does not
    match or the vectorized evaluation does not produce the output shape.
    """
    if not out_syms or not out_shape:
        return None
    try:
        if (
            isinstance(body, ExprNode)
            and body.op == "index"
            and body.args
            and isinstance(body.args[0], ExprNode)
            and body.args[0].op == "makearray"
            and list(body.args[1:]) == list(out_syms)
        ):
            return _materialize_makearray_vectorized(body.args[0], ctx, out_syms, out_shape)

        with _bound_index_box(ctx, out_syms, out_ranges_exp):
            val = _compile_expr(body)(ctx)
        res = np.asarray(val, dtype=float)
        if res.shape == tuple(out_shape):
            return res
        return np.broadcast_to(res, tuple(out_shape)).astype(float)
    except (NumpyInterpreterError, IndexError, ValueError, TypeError):
        return None


def _batched_ring_gather(
    arg: Expr, out_syms: list[str], ctx: EvalContext
) -> tuple[np.ndarray, str] | None:
    """For a per-cell ring gather ``index(P, s)`` return ``(P_array, s)``.

    ``P_array`` is the full ``[N, V, 2]`` ring-per-cell array and ``s`` the single
    output index symbol it is gathered by; ``None`` if ``arg`` is not that shape
    (so the batched leaf path declines and the caller falls back)."""
    if not (isinstance(arg, ExprNode) and arg.op == "index" and len(arg.args) == 2):
        return None
    sym = arg.args[1]
    if not (isinstance(sym, str) and sym in out_syms):
        return None
    try:
        arr = np.asarray(eval_expr(arg.args[0], ctx), dtype=float)
    except (NumpyInterpreterError, KeyError, TypeError, ValueError):
        return None
    if arr.ndim != 3 or arr.shape[2] != 2:
        return None
    return arr, sym


def _join_admits_mask(
    gates: list[tuple[str, str, dict[int, int], dict[int, int]]],
    out_syms: list[str],
    out_ranges_exp: list[list[int]],
    out_shape: tuple[int, ...],
) -> np.ndarray | None:
    """Dense boolean ``out_shape`` mask of the index tuples the join gates admit.

    The vectorized form of :func:`_join_admits` over the whole output box: a cell
    is admitted iff every gate's two key columns are equal. Returns ``None`` if a
    gate references a range symbol that is not an output index (only a pure map's
    output-index joins can be expressed as a dense mask)."""
    mask = np.ones(out_shape, dtype=bool)
    if not gates:
        return mask
    axis_of = {s: k for k, s in enumerate(out_syms)}
    ndim = len(out_syms)
    for sym_l, sym_r, codes_l, codes_r in gates:
        if sym_l not in axis_of or sym_r not in axis_of:
            return None
        al, ar = axis_of[sym_l], axis_of[sym_r]
        col_l = np.array([codes_l[v] for v in out_ranges_exp[al]])
        col_r = np.array([codes_r[v] for v in out_ranges_exp[ar]])
        shp_l = [1] * ndim
        shp_l[al] = col_l.size
        shp_r = [1] * ndim
        shp_r[ar] = col_r.size
        mask = mask & (col_l.reshape(shp_l) == col_r.reshape(shp_r))
    return mask


def _eval_arrayop_batched_leaf(
    expr: ExprNode,
    ctx: EvalContext,
    out_syms: list[str],
    out_ranges_exp: list[list[int]],
    out_shape: tuple[int, ...],
    reduce_syms: list[str],
    raw_ranges: dict[str, Any],
    reducer: str,
    empty_zero: float,
    filter_expr: Expr | None,
) -> np.ndarray | None:
    """Batched fast path for a fused-geometry-leaf pure map (esm-spec §8.6.1).

    Recognizes the conservative-regrid narrow phase
    ``A[i,j] = polygon_intersection_area(index(P_a, i), index(P_b, j))`` — a
    ``sum_product`` aggregate whose output indices are its only ranges — and
    evaluates the leaf over every join-admitted ``(i, j)`` in ONE batched kernel
    call (:func:`geometry.intersect_polygon_area_batch`) instead of one scalar
    Sutherland–Hodgman clip per cell (the per-cell loop in
    :func:`_eval_arrayop_scalar`). Semantics are identical:
    an admitted cell gets the leaf value, a non-admitted cell the semiring
    identity ``empty_zero`` (0 for ``sum_product``).

    Returns ``None`` — caller falls back to the exact scalar path — for anything
    outside this shape: a contraction (``reduce_syms``), a ``filter``, a
    non-``sum_product`` ⊕, a non-planar manifold, operands that are not per-cell
    ``index`` gathers, or a batch the kernel declines. Generalizes to other
    control-flow leaves (interp / table lifts) by widening the leaf/kernel switch.
    """
    if reduce_syms or filter_expr is not None:
        return None
    if reducer != "+":  # sum_product ⊕; other semirings keep the scalar path
        return None
    body = expr.expr
    if not (isinstance(body, ExprNode) and body.op == "polygon_intersection_area"):
        return None
    if (
        getattr(body, "manifold", None) != "planar"
        or len(body.args) != 2
        or len(out_syms) != 2
    ):
        return None
    ga = _batched_ring_gather(body.args[0], out_syms, ctx)
    gb = _batched_ring_gather(body.args[1], out_syms, ctx)
    if ga is None or gb is None:
        return None
    arr_a, sym_a = ga
    arr_b, sym_b = gb
    axis_of = {s: k for k, s in enumerate(out_syms)}
    if sym_a == sym_b or sym_a not in axis_of or sym_b not in axis_of:
        return None

    try:
        sym_positions = {s: list(r) for s, r in zip(out_syms, out_ranges_exp)}
        gates = _resolve_join(expr, raw_ranges, sym_positions, ctx)
        mask = _join_admits_mask(gates, out_syms, out_ranges_exp, out_shape)
        if mask is None:
            return None
        out = np.full(out_shape, empty_zero, dtype=float)
        positions = np.nonzero(mask)
        if positions[0].size == 0:
            return out
        ax_a, ax_b = axis_of[sym_a], axis_of[sym_b]
        base_a = arr_a[np.asarray(out_ranges_exp[ax_a], dtype=np.intp) - 1]
        base_b = arr_b[np.asarray(out_ranges_exp[ax_b], dtype=np.intp) - 1]
        batch_a = base_a[positions[ax_a]]
        batch_b = base_b[positions[ax_b]]
    except (NumpyInterpreterError, IndexError, ValueError, TypeError):
        return None

    from . import geometry

    areas = geometry.intersect_polygon_area_batch(batch_a, batch_b, "planar")
    if areas is None:
        return None
    out[positions] = areas
    return out


def _eval_arrayop(expr: ExprNode, ctx: EvalContext) -> np.ndarray:
    """Evaluate an aggregate / arrayop body over its output index box.

    Returns an ndarray whose shape is the cartesian product of the ranges for
    each symbolic index in ``output_idx``. The reduction over contracted indices
    is parameterized by the node's ``semiring`` (RFC semiring-faq-unified-ir
    §5.1): the ⊕ operator and the empty-reduction identity 0̄ come from the closed
    registry. Range references of the form ``{"from": <name>}`` are resolved
    against the index-set registry (§5.2). A vectorized numpy fast path (einsum /
    outer-reduce) is used when the semiring's ⊗ is multiplication; the scalar
    loop covers every other case (``+``/``∧`` products, ragged bounds, affine
    subscripts, bare names).
    """
    if expr.expr is None:
        raise NumpyInterpreterError("aggregate / arrayop requires an 'expr' body")
    output_idx = list(expr.output_idx or [])
    raw_ranges = expr.ranges or {}

    out_syms: list[str] = [s for s in output_idx if isinstance(s, str)]
    for s in out_syms:
        if s not in raw_ranges:
            raise NumpyInterpreterError(
                f"aggregate / arrayop output index {s!r} has no declared range"
            )

    reducer, empty_zero, otimes = _resolve_semiring(expr)

    # Resolve {"from": ...} index-set references (RFC §5.2). Dense list ranges
    # pass through unchanged, so existing arrayop fixtures are byte-for-byte
    # identical; ragged sets become per-parent dynamic bounds.
    resolved: dict[str, Any] = {s: _resolve_range_spec(raw_ranges[s], ctx) for s in raw_ranges}

    out_ranges_exp: list[list[int]] = []
    for s in out_syms:
        rs = resolved[s]
        if isinstance(rs, _RaggedRange):
            raise NumpyInterpreterError(
                f"output index {s!r} cannot reference a ragged index set: ragged "
                f"sets are per-parent and have no dense output extent (RFC §5.2)"
            )
        out_ranges_exp.append(_expand_range(rs))
    out_shape = tuple(len(r) for r in out_ranges_exp)

    reduce_syms: list[str] = [s for s in raw_ranges if s not in out_syms]
    ragged_reduce = any(isinstance(resolved[s], _RaggedRange) for s in reduce_syms)

    # M2: a value-equality join (RFC §5.3) and/or a boolean filter predicate
    # gate which index combinations contribute a ⊗-term. They share one scalar
    # gated path; the vectorized einsum fast path cannot express the gate, so it
    # is bypassed whenever either is present. Nodes with neither flow through the
    # unchanged M1 fast / scalar paths below and stay byte-for-byte identical.
    join_clauses = getattr(expr, "join", None)
    filter_expr = getattr(expr, "filter", None)

    # Batched vectorized fast path for a fused geometry-leaf pure map — the planar
    # conservative-regrid narrow phase A_ij = polygon_intersection_area(src_i,
    # tgt_j). Evaluates the whole (join-admitted) candidate set in one kernel call
    # instead of a per-cell Sutherland–Hodgman clip; declines (→ None) to the
    # scalar join/fallback paths below for anything it does not recognize.
    if not ragged_reduce:
        batched = _eval_arrayop_batched_leaf(
            expr,
            ctx,
            out_syms,
            out_ranges_exp,
            out_shape,
            reduce_syms,
            raw_ranges,
            reducer,
            empty_zero,
            filter_expr,
        )
        if batched is not None:
            return batched

    if join_clauses or filter_expr is not None:
        if ragged_reduce:
            raise NumpyInterpreterError(
                "aggregate 'join'/'filter' with a ragged contracted range is not "
                "supported; equi-join keys are dense interval / categorical index "
                "sets (RFC semiring-faq-unified-ir §5.3)"
            )
        # Cached constant-geometry OPERATOR path (#3): a join-gated sum_product
        # shaped like the regrid APPLY factors into a reusable weight operator
        # W_op (built once, cached on ctx.op_cache) applied to the current field
        # by one einsum. Declines (→ None) to the dense reduce below for anything
        # outside that shape or when operator caching is off.
        op = _eval_arrayop_operator_cached(
            expr,
            ctx,
            out_syms,
            out_ranges_exp,
            out_shape,
            reduce_syms,
            resolved,
            raw_ranges,
            reducer,
            empty_zero,
            filter_expr,
        )
        if op is not None:
            return op
        # The whole (out × reduce) box + its filter and/or equi-join mask evaluate
        # in one vectorized pass, collapsing the dense per-(i,j) Python loop of the
        # conservative-regrid APPLY reductions (A_j row-sums, weighted field
        # regrids) to a handful of numpy ops. The equi-join is coded to a dense
        # combined-box mask (:func:`_join_admits_mask`) instead of the per-cell
        # ``_join_admits`` gate; the vectorized reduce declines (→ None) on
        # anything it cannot broadcast (or a key that is not a box axis), so the
        # scalar loop still covers those cases.
        vec = _eval_arrayop_reduce_vectorized(
            expr,
            ctx,
            out_syms,
            out_ranges_exp,
            out_shape,
            reduce_syms,
            resolved,
            reducer,
            empty_zero,
            filter_expr,
            raw_ranges,
        )
        if vec is not None:
            return vec
        return _eval_arrayop_scalar(
            expr,
            ctx,
            out_syms,
            out_ranges_exp,
            out_shape,
            reduce_syms,
            resolved,
            raw_ranges,
            reducer,
            empty_zero,
            filter_expr,
        )

    if ragged_reduce:
        return _eval_arrayop_ragged(
            expr,
            ctx,
            out_syms,
            out_ranges_exp,
            out_shape,
            reduce_syms,
            resolved,
            reducer,
            empty_zero,
        )

    red_ranges_exp = _expand_reduce_ranges(resolved, reduce_syms)

    # Pre-compute 0-based index lists for the fast path.
    sym_0based: dict[str, list[int]] = {}
    for s, r in zip(out_syms, out_ranges_exp):
        sym_0based[s] = [x - 1 for x in r]
    for s, r in zip(reduce_syms, red_ranges_exp):
        sym_0based[s] = [x - 1 for x in r]

    # The vectorized path multiplies factors, so it is valid only when the
    # semiring's ⊗ is × (sum_product, max_product, and the legacy no-semiring
    # case). For ⊗ = + (min_sum / max_sum) or ⊗ = ∧ (bool_and_or) the body is a
    # sum / conjunction and the scalar loop carries the correct semantics.
    if otimes == "*":
        fast = _eval_arrayop_vectorized(
            expr.expr, ctx, out_syms, reduce_syms, sym_0based, out_shape, reducer
        )
        if fast is not None:
            return fast

    # Pure-map (no contraction) vectorized fast path: stencils — affine
    # subscripts, sums, sqrt/max/min, makearray regions — that the einsum
    # decomposer above rejects. Binds the output indices to ranges and evaluates
    # the body over the whole box via shifted-slice gathers, one pass instead of
    # one Python interpreter pass per cell. Falls through on any mismatch.
    if not reduce_syms:
        mapped = _materialize_map(expr.expr, ctx, out_syms, out_ranges_exp, out_shape)
        if mapped is not None:
            return mapped

    # Scalar fallback: the general scalar evaluator with no join/filter gate — one
    # ⊗-term per contraction point, reduced with ⊕. Shares the output-cell walk
    # and the gated reduction with the join/filter path (a plain reduction is the
    # gate-free case), so both flow through one code path.
    return _eval_arrayop_scalar(
        expr,
        ctx,
        out_syms,
        out_ranges_exp,
        out_shape,
        reduce_syms,
        resolved,
        raw_ranges,
        reducer,
        empty_zero,
        filter_expr=None,
    )


def _iter_output_cells(
    out_syms: list[str],
    out_ranges_exp: list[list[int]],
    out_shape: tuple[int, ...],
) -> Iterator[tuple[tuple[int, ...], dict[str, int]]]:
    """Yield ``(multi_idx, local_binding)`` for every cell of the output box.

    ``local_binding`` maps each output index symbol to its 1-based range value at
    that cell. Shared by every scalar arrayop path (plain / ragged / join+filter)
    so the output-cell walk and the index-symbol binding live in one place."""
    it = np.ndindex(*out_shape) if out_shape else [()]
    for multi_idx in it:
        local_binding: dict[str, int] = {}
        for s, pos, r in zip(out_syms, multi_idx, out_ranges_exp):
            local_binding[s] = r[pos]
        yield multi_idx, local_binding


def _reduce_over(
    body: Expr,
    ctx: EvalContext,
    local_binding: dict[str, int],
    reduce_syms: list[str],
    cartesian_red: list[tuple[int, ...]],
    reducer: str,
    empty_zero: float,
) -> float:
    """Reduce ``body`` over the contracted-index cartesian product with ⊕.

    The ungated case of :func:`_reduce_over_gated` (no join / filter); returns the
    semiring's empty-reduction identity ``empty_zero`` (0̄) when the contracted
    ranges are empty (RFC §5.1)."""
    return _reduce_over_gated(
        body, ctx, local_binding, reduce_syms, cartesian_red, reducer, empty_zero,
        gates=[], filter_expr=None,
    )


def _eval_arrayop_ragged(
    expr: ExprNode,
    ctx: EvalContext,
    out_syms: list[str],
    out_ranges_exp: list[list[int]],
    out_shape: tuple[int, ...],
    reduce_syms: list[str],
    resolved: dict[str, Any],
    reducer: str,
    empty_zero: float,
) -> np.ndarray:
    """Scalar evaluation path for aggregates whose contracted bounds are ragged.

    A ragged reduce range depends on the enclosing (output) indices via its
    ``offsets`` factor, so the contracted ranges are recomputed for each output
    point — the named, first-class form of the per-parent dynamic bound (RFC
    §5.2). Non-ragged reduce ranges in the same node expand statically.
    """
    out = np.zeros(out_shape, dtype=float)
    for multi_idx, local_binding in _iter_output_cells(out_syms, out_ranges_exp, out_shape):
        parent_binding = dict(ctx.locals)
        parent_binding.update(local_binding)
        red_ranges: list[list[int]] = []
        for s in reduce_syms:
            rs = resolved[s]
            if isinstance(rs, _RaggedRange):
                red_ranges.append(_expand_ragged(rs, ctx, parent_binding))
            else:
                red_ranges.append(_expand_range(rs))
        cartesian_red = _cartesian(red_ranges)
        out[multi_idx] = _reduce_over(
            expr.expr,
            ctx,
            local_binding,
            reduce_syms,
            cartesian_red,
            reducer,
            empty_zero,
        )
    return out


def _cartesian(lists: list[list[int]]) -> list[tuple[int, ...]]:
    if not lists:
        return [()]
    result: list[tuple[int, ...]] = [()]
    for lst in lists:
        result = [prev + (x,) for prev in result for x in lst]
    return result


def _reduce_step(op: str, acc: float | None, val: float) -> float:
    if op == "or":
        # bool_and_or ⊕ (logical OR over 0.0/1.0-valued terms, RFC §5.1).
        if acc is None:
            return 1.0 if val != 0.0 else 0.0
        return 1.0 if (acc != 0.0 or val != 0.0) else 0.0
    if acc is None:
        return val
    if op == "+":
        return acc + val
    if op == "*":
        return acc * val
    if op == "max":
        return max(acc, val)
    if op == "min":
        return min(acc, val)
    raise NumpyInterpreterError(f"Unsupported reduce: {op}")


# ---------------------------------------------------------------------------
# M2 — value-equality joins (RFC semiring-faq-unified-ir §5.3) + filter
# predicates (§7.2). Resolved at build time into a gate over the contraction:
# an inner equi-join contributes a ⊗-product term only for index combinations
# whose key columns are equal on every listed pair, and a filter keeps only
# combinations for which its predicate holds. Unmatched / filtered-out
# combinations contribute nothing — i.e. the additive identity 0̄ once the
# whole reduction is empty (§5.1). Key matching follows the RFC Appendix A.6
# convention: bucket key values into one canonical sorted order (integers by
# value, strings by Unicode code point — §5.7 rule 1) and probe with
# ``np.searchsorted``. The dense output keeps declared index order, so a
# degenerate / positional join is byte-identical to the join-free node.
# ---------------------------------------------------------------------------


def _join_sym_for_key(key: str, raw_ranges: dict[str, Any], sym_to_set: dict[str, str]) -> str:
    """Resolve a join-key name to the range symbol it denotes.

    A key is either a declared range symbol directly, or the name of an index
    set bound by exactly one range symbol (``{"from": <name>}``) — the latter
    lets a clause name the dimension instead of the loop symbol. Anything else
    is a build-time error (RFC §5.3).
    """
    if key in raw_ranges:
        return key
    candidates = sorted(s for s, setn in sym_to_set.items() if setn == key)
    if len(candidates) == 1:
        return candidates[0]
    if not candidates:
        raise NumpyInterpreterError(
            f"join key {key!r} is neither a declared range symbol nor an index "
            f"set bound by a range of this aggregate (RFC semiring-faq-unified-ir §5.3)"
        )
    raise NumpyInterpreterError(
        f"join key {key!r} names an index set bound by multiple range symbols "
        f"{candidates}; reference the range symbol directly (RFC §5.3)"
    )


def _validated_key_member(m: Any, set_name: str) -> Any:
    """Validate one categorical member used as a join key (RFC §5.3 / §5.7).

    Keys must be exact-equality types: integer IDs or categorical members
    (strings). Floats are forbidden (equality is not portable across bindings),
    and a null member is a build-time error.
    """
    if m is None:
        raise NumpyInterpreterError(
            f"null member in join key index set {set_name!r}: emitting null into "
            f"a key column is a build-time error (RFC semiring-faq-unified-ir §5.3)"
        )
    if isinstance(m, bool):
        raise NumpyInterpreterError(
            f"boolean member {m!r} in join key index set {set_name!r} is not an "
            f"exact-equality key type (RFC §5.3)"
        )
    if isinstance(m, float):
        raise NumpyInterpreterError(
            f"floating-point member {m!r} in join key index set {set_name!r}: "
            f"float join keys are forbidden — equality is not portable across "
            f"bindings (RFC semiring-faq-unified-ir §5.3 / §5.7 rule 1)"
        )
    if not isinstance(m, (int, str)):
        raise NumpyInterpreterError(
            f"unsupported join key member type {type(m).__name__} in index set "
            f"{set_name!r}; keys must be integer IDs or categorical members "
            f"(RFC §5.3)"
        )
    return m


def _key_member_values(
    sym: str, raw_ranges: dict[str, Any], positions: list[int], ctx: EvalContext
) -> list[Any]:
    """Key-column values for ``sym`` at each 1-based ``positions`` entry.

    A categorical range yields its declared members (validated as exact-equality
    keys); an interval range or a dense integer tuple yields the integer index
    itself as the key (RFC §5.3).
    """
    spec = raw_ranges.get(sym)
    if isinstance(spec, dict) and "from" in spec:
        set_name = spec["from"]
        entry = ctx.index_sets.get(set_name) or {}
        kind = entry.get("kind")
        if kind == "categorical":
            members = entry.get("members") or []
            return [_validated_key_member(members[p - 1], set_name) for p in positions]
        if kind == "interval":
            return [int(p) for p in positions]
        raise NumpyInterpreterError(
            f"join key index set {set_name!r} has kind {kind!r}; only 'interval' "
            f"(integer IDs) and 'categorical' keys can be equi-joined (RFC §5.3)"
        )
    # Dense integer tuple range — the integer index value is the key.
    return [int(p) for p in positions]


def _encode_join_keys(vals_a: list[Any], vals_b: list[Any]) -> tuple[list[int], list[int]]:
    """Bucket two key columns into one canonical order; return equal-iff-equal codes.

    Builds the sorted union of distinct key values (integers by value, strings by
    Unicode code point — RFC §5.7 rule 1) and probes each column into it with
    ``np.searchsorted`` (the bucket-and-probe equi-join of RFC Appendix A.6).
    Equal values receive equal codes; a value present on only one side simply
    never matches (inner join → 0̄). Mixing integer and string keys in one pair
    is a key-type error (they can never compare equal — §5.3).
    """
    a_str = any(isinstance(v, str) for v in vals_a)
    b_str = any(isinstance(v, str) for v in vals_b)
    if a_str != b_str:
        raise NumpyInterpreterError(
            "join pair couples incompatible key types (integer IDs vs categorical "
            "string members); both sides must be the same exact-equality type "
            "(RFC semiring-faq-unified-ir §5.3)"
        )
    table = np.array(sorted(set(vals_a) | set(vals_b)), dtype=object)
    if table.size == 0:
        return [], []

    def codes(vals: list[Any]) -> list[int]:
        if not vals:
            return []
        return [int(c) for c in np.searchsorted(table, np.array(vals, dtype=object))]

    return codes(vals_a), codes(vals_b)


def _resolve_join(
    expr: ExprNode,
    raw_ranges: dict[str, Any],
    sym_positions: dict[str, list[int]],
    ctx: EvalContext,
) -> list[tuple[str, str, dict[int, int], dict[int, int]]]:
    """Resolve every join clause into coded key-pair gates (RFC §5.3).

    Returns a list of ``(symL, symR, codesL, codesR)`` where ``codesX`` maps a
    1-based position of the symbol to its bucket code. A contraction tuple
    contributes a ⊗-term iff ``codesL[posL] == codesR[posR]`` for every pair of
    every clause (all clauses' pairs are ANDed — multiple clauses compose).
    """
    clauses = getattr(expr, "join", None) or []
    sym_to_set = {
        s: spec["from"]
        for s, spec in raw_ranges.items()
        if isinstance(spec, dict) and "from" in spec
    }
    gates: list[tuple[str, str, dict[int, int], dict[int, int]]] = []
    for clause in clauses:
        on = (clause or {}).get("on") or []
        if not on:
            raise NumpyInterpreterError(
                "join clause requires at least one key-column pair in 'on' "
                "(RFC semiring-faq-unified-ir §5.3)"
            )
        for pair in on:
            if not (isinstance(pair, (list, tuple)) and len(pair) == 2):
                raise NumpyInterpreterError(
                    f"join 'on' entry {pair!r} must be a [left, right] key-column pair (RFC §5.3)"
                )
            sym_l, vals_l = _resolve_join_key_column(
                pair[0], raw_ranges, sym_to_set, sym_positions, ctx
            )
            sym_r, vals_r = _resolve_join_key_column(
                pair[1], raw_ranges, sym_to_set, sym_positions, ctx
            )
            codes_l, codes_r = _encode_join_keys(vals_l, vals_r)
            gates.append(
                (
                    sym_l,
                    sym_r,
                    dict(zip(sym_positions[sym_l], codes_l)),
                    dict(zip(sym_positions[sym_r], codes_r)),
                )
            )
    return gates


def _resolve_join_key_column(
    key: str,
    raw_ranges: dict[str, Any],
    sym_to_set: dict[str, str],
    sym_positions: dict[str, list[int]],
    ctx: EvalContext,
) -> tuple[str, list[Any]]:
    """Resolve one join key column to ``(range_symbol, key_values)`` (RFC §5.3).

    Two key kinds are supported:

    * A **materialized value-invention MAP buffer** (``rg_src_bin``): the key
      names a per-cell bin buffer in ``ctx.join_key_buffers``. The range symbol
      is the one whose ``{"from": <set>}`` matches the buffer's 1-D declared
      shape index set (``ctx.join_key_index_sets[key]``), and the key value at
      each 1-based position is the buffer's integer bin code — the broad-phase
      bin-skolem equi-join.
    * A **range symbol / index set** — the existing categorical / interval key
      column, resolved via :func:`_join_sym_for_key` / :func:`_key_member_values`.
    """
    # A join key may name a value-invention MAP buffer. Match it against the
    # materialized buffers by exact name OR namespaced suffix: flatten prefixes
    # the bin STATE with its model (``OceanDynamics.rg_src_bin``) but leaves the
    # ``join.on`` key column bare (``rg_src_bin``), so the two must be reconciled
    # here (the intra-model-reference namespacing gap, RFC §5.3).
    buf_key = None
    if key in ctx.join_key_buffers:
        buf_key = key
    else:
        _suffix = [b for b in ctx.join_key_buffers if b == key or b.endswith("." + key)]
        if len(_suffix) == 1:
            buf_key = _suffix[0]
    if buf_key is not None:
        key = buf_key
        set_name = ctx.join_key_index_sets.get(key)
        candidates = [
            s
            for s in sym_positions
            if isinstance(raw_ranges.get(s), dict) and raw_ranges[s].get("from") == set_name
        ]
        if len(candidates) != 1:
            raise NumpyInterpreterError(
                f"join key buffer {key!r} (over index set {set_name!r}) does not "
                f"map to exactly one range symbol of this aggregate (found "
                f"{sorted(candidates)}); RFC §5.3"
            )
        sym = candidates[0]
        buf = np.asarray(ctx.join_key_buffers[key], dtype=float).reshape(-1)
        vals = [int(round(float(buf[p - 1]))) for p in sym_positions[sym]]
        return sym, vals
    sym = _join_sym_for_key(key, raw_ranges, sym_to_set)
    if sym not in sym_positions:
        raise NumpyInterpreterError(
            f"join key symbol {sym!r} is not an output or contracted range of "
            f"this aggregate (RFC §5.3)"
        )
    return sym, _key_member_values(sym, raw_ranges, sym_positions[sym], ctx)


def _join_admits(
    gates: list[tuple[str, str, dict[int, int], dict[int, int]]], binding: dict[str, int]
) -> bool:
    """True iff every join pair's key columns are equal under ``binding``."""
    for sym_l, sym_r, codes_l, codes_r in gates:
        if codes_l[binding[sym_l]] != codes_r[binding[sym_r]]:
            return False
    return True


def _filter_admits(filter_expr: Expr, ctx: EvalContext) -> bool:
    """Evaluate a scalar boolean filter predicate for the current binding."""
    val = np.asarray(eval_expr(filter_expr, ctx))
    if val.size != 1:
        raise NumpyInterpreterError(
            "aggregate 'filter' predicate must evaluate to a scalar for each "
            "index combination (RFC semiring-faq-unified-ir §5.3)"
        )
    return bool(val.reshape(-1)[0])


#: ⊕ operators this vectorized reduction path can fold, and the numpy ufunc whose
#: ``.reduce`` carries the contraction. Every entry's semiring identity 0̄
#: (``empty_zero``) doubles as the ufunc ``initial`` AND the value a filtered-out
#: term is masked to — so a masked term is a genuine no-op under ⊕ (RFC §5.1),
#: giving an empty admitted set the identity exactly as the scalar path does.
_REDUCE_UFUNCS: dict[str, Any] = {
    "+": np.add,
    "*": np.multiply,
    "max": np.maximum,
    "min": np.minimum,
}


def _gather_operator_factor(
    var: str, syms: list[str], ctx: EvalContext, sym_0based: dict[str, list[int]]
) -> np.ndarray | None:
    """Gather + slice the array backing an ``index(var, *syms)`` factor for the
    operator path, or ``None`` if it is not a plain per-cell array gather.

    Resolves ``var`` the way :func:`_eval_arrayop_vectorized` does — a state
    array, a materialized ``derived_rings`` buffer, or a loader ``input_arrays``
    field — and slices each declared axis to the factor's 0-based index range.
    Diagonal / repeated subscripts and rank mismatches decline (→ ``None``) so
    the caller falls back to the dense reduce."""
    if len(set(syms)) != len(syms):
        return None
    if var in ctx.state_layout:
        arr = _view_state_array(var, ctx)
    elif var in ctx.derived_rings:
        arr = np.asarray(ctx.derived_rings[var], dtype=float)
    elif var in ctx.input_arrays:
        arr = np.asarray(ctx.input_arrays[var], dtype=float)
    else:
        return None
    if arr.ndim != len(syms):
        return None
    cols = [np.asarray(sym_0based[s], dtype=int) for s in syms]
    sl = arr[cols[0]] if len(cols) == 1 else arr[np.ix_(*cols)]
    return np.asarray(sl, dtype=float)


def _eval_arrayop_operator_cached(
    expr: ExprNode,
    ctx: EvalContext,
    out_syms: list[str],
    out_ranges_exp: list[list[int]],
    out_shape: tuple[int, ...],
    reduce_syms: list[str],
    resolved: dict[str, Any],
    raw_ranges: dict[str, Any],
    reducer: str,
    empty_zero: float,
    filter_expr: Expr | None,
) -> np.ndarray | None:
    """Cached constant-geometry OPERATOR fast path (perf idea #3).

    Recognizes the conservative-regrid APPLY — a ``sum_product`` (⊕ = ``+``,
    ⊗ = ``×``) reducing aggregate, join-gated, whose body is a product of
    per-cell ``index`` gathers that splits into loader-INVARIANT geometry factors
    (the weight ``W_ij``, ``ctx.invariant_names``) and a VARYING gathered field
    (the refreshed loader quantity). It precomputes the constant weight operator
    once — ``W_op[out…, red…] = coeff · Π(const factors) · join_admit_mask`` — and
    caches it on ``ctx.op_cache`` keyed by the node ``id``; each call then applies
    it to the current field with a single ``np.einsum`` that contracts the reduce
    axes (``"ji,i->j"`` — a BLAS matvec ``field_tgt = W_op · field_src``). A
    cadence-segmented rebuild reuses ``W_op`` across every hour instead of
    re-walking the weight and re-coding the join each segment.

    Declines (→ ``None``, caller falls to the dense
    :func:`_eval_arrayop_reduce_vectorized`, then the scalar loop) whenever the
    node is not this exact shape or any factor is not a plain invariant/varying
    array gather: a non-``+`` ⊕, a ``filter``, no contraction, an affine / summed
    body, a join key that is not a box axis, or a captured weight factor that is
    not known-invariant (so a reused operator can never freeze changing data).
    """
    op_cache = ctx.op_cache
    if op_cache is None or not ctx.invariant_names:
        return None
    if reducer != "+" or filter_expr is not None or not reduce_syms:
        return None

    all_syms = list(out_syms) + list(reduce_syms)
    if len(all_syms) > _EINSUM_MAX_LABELS:
        return None
    all_ranges_exp = list(out_ranges_exp) + _expand_reduce_ranges(resolved, reduce_syms)
    combined_shape = tuple(len(r) for r in all_ranges_exp)
    if 0 in out_shape:
        return np.zeros(out_shape, dtype=float)

    decomp = _decompose_body_as_scaled_product(expr.expr, frozenset(all_syms))
    if decomp is None:
        return None
    coeff, index_terms = decomp

    sym_0based: dict[str, list[int]] = {
        s: [v - 1 for v in r] for s, r in zip(all_syms, all_ranges_exp)
    }
    letters = {s: chr(ord("a") + k) for k, s in enumerate(all_syms)}
    combined_spec = "".join(letters[s] for s in all_syms)
    out_spec = "".join(letters[s] for s in out_syms)

    const_terms: list[tuple[str, list[str]]] = []
    vary_terms: list[tuple[str, list[str]]] = []
    for var, syms in index_terms:
        if not syms and var in ctx.param_values:
            coeff *= ctx.param_values[var]
            continue
        if var in ctx.invariant_names:
            const_terms.append((var, syms))
        else:
            vary_terms.append((var, syms))
    # The operator form needs a constant weight AND a varying field: a pure
    # geometry reduce (no varying factor) is already materialized once in the
    # const partition, and a purely-varying reduce has no reusable operator.
    if not const_terms or not vary_terms:
        return None

    node_id = id(expr)
    cached = op_cache.get(node_id)
    if cached is None:
        # Build the constant weight operator W_op over the combined box, folding in
        # the join-admit mask. Every captured factor must be a known-invariant
        # array gather, else this operator would not be safe to reuse.
        try:
            const_operands: list[np.ndarray] = []
            const_specs: list[str] = []
            for var, syms in const_terms:
                sl = _gather_operator_factor(var, syms, ctx, sym_0based)
                if sl is None:
                    return None
                const_operands.append(sl)
                const_specs.append("".join(letters[s] for s in syms))
            operands = list(const_operands)
            specs = list(const_specs)
            if getattr(expr, "join", None):
                sym_positions = {s: list(r) for s, r in zip(all_syms, all_ranges_exp)}
                gates = _resolve_join(expr, raw_ranges, sym_positions, ctx)
                mask = _join_admits_mask(gates, all_syms, all_ranges_exp, combined_shape)
                if mask is None:
                    return None
                operands.append(mask.astype(float))
                specs.append(combined_spec)
            if not operands:
                return None
            w_op = coeff * np.einsum(",".join(specs) + "->" + combined_spec, *operands)
        except (NumpyInterpreterError, IndexError, ValueError, TypeError, KeyError):
            return None
        vary_specs = ["".join(letters[s] for s in syms) for _, syms in vary_terms]
        cached = (np.ascontiguousarray(w_op), combined_spec, out_spec, vary_terms, vary_specs)
        op_cache[node_id] = cached

    w_op, combined_spec, out_spec, vary_terms, vary_specs = cached

    # Apply: contract the cached operator against the CURRENT varying field(s).
    try:
        vary_operands = []
        for var, syms in vary_terms:
            sl = _gather_operator_factor(var, syms, ctx, sym_0based)
            if sl is None:
                return None
            vary_operands.append(sl)
        einsum_str = combined_spec + "," + ",".join(vary_specs) + "->" + out_spec
        with np.errstate(divide="ignore", invalid="ignore"):
            out = np.einsum(einsum_str, w_op, *vary_operands)
    except (NumpyInterpreterError, IndexError, ValueError, TypeError, KeyError):
        return None
    return np.asarray(out, dtype=float).reshape(out_shape)


def _eval_arrayop_reduce_vectorized(
    expr: ExprNode,
    ctx: EvalContext,
    out_syms: list[str],
    out_ranges_exp: list[list[int]],
    out_shape: tuple[int, ...],
    reduce_syms: list[str],
    resolved: dict[str, Any],
    reducer: str,
    empty_zero: float,
    filter_expr: Expr | None,
    raw_ranges: dict[str, Any] | None = None,
) -> np.ndarray | None:
    """Vectorized fast path for a (possibly join- and/or filter-gated) reducing
    aggregate.

    The general counterpart of :func:`_materialize_map` (which only handles the
    non-reducing pure map): bind EVERY index symbol — output AND contracted — to
    its 1-based ``arange`` reshaped to broadcast on its own axis of the combined
    ``[out… , reduce…]`` box, evaluate the body ONCE over that whole box (so each
    ``index(var, i, j, …)`` factor becomes one vectorized gather via
    :func:`_eval_index`, resolving state / params / loader ``input_arrays`` /
    materialized ``derived_rings`` alike), then ⊕-reduce over the trailing
    contracted axes.

    Both gates collapse to a dense boolean mask over the SAME combined box, so a
    non-admitted cell is set to the semiring identity 0̄ (``empty_zero``) — a
    no-op under ⊕, identical to the scalar path skipping it (RFC
    semiring-faq-unified-ir §5.3 / §7.2):

    * a ``filter`` predicate is evaluated over the box to a boolean mask;
    * an equi-``join`` resolves to key-column codes (:func:`_resolve_join`) whose
      admitted tuples are the dense :func:`_join_admits_mask` over the combined
      box — the vectorized form of the per-cell :func:`_join_admits` gate. Every
      join key symbol (output OR contracted) is an axis of the box, so the mask
      that the scalar loop walks tuple-by-tuple is built in one broadcast compare.

    This is what lets the conservative-regrid APPLY reductions — the row-sums
    ``A_j[j] = Σ_{i:bin(i)=bin(j)} A_ij`` and the weighted regrids
    ``field_tgt[j] = Σ_i A_ij·field_i / A_j`` gated by a broad-phase bin
    equi-join — evaluate as a handful of numpy ops over the already-materialized
    ``A_ij`` matrix instead of a Python loop over every (source, target) pair (the
    dense ``_eval_arrayop_scalar`` → ``_reduce_over_gated`` walk).

    Per-cell values are computed by the SAME gather the scalar path uses, so only
    the contraction's summation order changes (numpy pairwise vs sequential), on a
    par with the existing einsum fast path (:func:`_eval_arrayop_vectorized`).
    Returns ``None`` — caller falls back to the scalar loop — for an unsupported
    ⊕, an empty index box, a join whose keys are not all box axes, or any body /
    filter that does not evaluate + broadcast cleanly over the box (e.g. a ragged
    bound or a non-array gather). ⊗ is folded by the body evaluation itself, so
    the semiring's ⊗ need not be ×.
    """
    ufunc = _REDUCE_UFUNCS.get(reducer)
    if ufunc is None or not reduce_syms:
        return None

    red_ranges_exp = _expand_reduce_ranges(resolved, reduce_syms)
    all_syms = list(out_syms) + list(reduce_syms)
    all_ranges_exp = list(out_ranges_exp) + red_ranges_exp
    ndim = len(all_syms)
    if ndim == 0:
        return None
    combined_shape = tuple(list(out_shape) + [len(r) for r in red_ranges_exp])
    if 0 in out_shape:
        # No output cells — nothing to compute; the scalar path returns the same
        # empty array. Cheap to hand back so the reduce logic below stays simple.
        return np.zeros(out_shape, dtype=float)

    # Resolve the equi-join gate (if any) to a dense mask over the combined box
    # BEFORE binding the index box — key coding reads only ctx registries + the
    # declared ranges, not the broadcast bindings. A key that is not an axis of
    # this box (``_join_admits_mask`` → None) or a malformed clause declines to
    # the scalar path, which re-resolves and raises the authoritative error.
    join_mask: np.ndarray | None = None
    if getattr(expr, "join", None):
        if raw_ranges is None:
            return None
        try:
            sym_positions = {s: list(r) for s, r in zip(all_syms, all_ranges_exp)}
            gates = _resolve_join(expr, raw_ranges, sym_positions, ctx)
            join_mask = _join_admits_mask(gates, all_syms, all_ranges_exp, combined_shape)
        except (NumpyInterpreterError, IndexError, ValueError, TypeError, KeyError):
            return None
        if join_mask is None:
            return None

    try:
        with _bound_index_box(ctx, all_syms, all_ranges_exp):
            # A filtered-out / masked term divides by A_j=0 in the regrid body; that
            # value is immediately discarded by the mask, so silence the transient
            # divide/invalid warnings (mirrors the batched-leaf kernel).
            with np.errstate(divide="ignore", invalid="ignore"):
                term = np.asarray(_compile_expr(expr.expr)(ctx), dtype=float)
                term = np.broadcast_to(term, combined_shape)
                if filter_expr is not None:
                    mask = np.asarray(_compile_expr(filter_expr)(ctx))
                    term = np.where(mask.astype(bool), term, empty_zero)
                if join_mask is not None:
                    term = np.where(join_mask, term, empty_zero)
    except (NumpyInterpreterError, IndexError, ValueError, TypeError, KeyError):
        return None

    red_axes = tuple(range(len(out_syms), ndim))
    with np.errstate(divide="ignore", invalid="ignore"):
        out = ufunc.reduce(np.ascontiguousarray(term), axis=red_axes, initial=empty_zero)
    return np.asarray(out, dtype=float).reshape(out_shape)


def _eval_arrayop_scalar(
    expr: ExprNode,
    ctx: EvalContext,
    out_syms: list[str],
    out_ranges_exp: list[list[int]],
    out_shape: tuple[int, ...],
    reduce_syms: list[str],
    resolved: dict[str, Any],
    raw_ranges: dict[str, Any],
    reducer: str,
    empty_zero: float,
    filter_expr: Expr | None,
) -> np.ndarray:
    """Scalar (per-output-cell) evaluation path for an aggregate.

    The one non-vectorized evaluator: it serves both a plain reduction and one
    carrying a join and/or filter (an ungated node just resolves to zero gates).
    The contraction iterates the dense reduce ranges in declared order; for each
    combination the join gate (value equality of key columns, §5.3) and the
    filter predicate (§7.2) decide whether it contributes a ⊗-term. An empty set
    of admitted terms reduces to the semiring identity 0̄ (§5.1).
    """
    red_ranges_exp = _expand_reduce_ranges(resolved, reduce_syms)
    sym_positions: dict[str, list[int]] = {}
    for s, r in zip(out_syms, out_ranges_exp):
        sym_positions[s] = list(r)
    for s, r in zip(reduce_syms, red_ranges_exp):
        sym_positions[s] = list(r)

    gates = _resolve_join(expr, raw_ranges, sym_positions, ctx)
    cartesian_red = _cartesian(red_ranges_exp) if reduce_syms else [()]

    out = np.zeros(out_shape, dtype=float)
    for multi_idx, local_binding in _iter_output_cells(out_syms, out_ranges_exp, out_shape):
        out[multi_idx] = _reduce_over_gated(
            expr.expr,
            ctx,
            local_binding,
            reduce_syms,
            cartesian_red,
            reducer,
            empty_zero,
            gates,
            filter_expr,
        )
    return out


def _reduce_over_gated(
    body: Expr,
    ctx: EvalContext,
    local_binding: dict[str, int],
    reduce_syms: list[str],
    cartesian_red: list[tuple[int, ...]],
    reducer: str,
    empty_zero: float,
    gates: list[tuple[str, str, dict[int, int], dict[int, int]]],
    filter_expr: Expr | None,
) -> float:
    """Reduce ``body`` over the contracted product, gated by join + filter.

    Mirrors :func:`_reduce_over` but skips any contraction combination that
    fails the inner equi-join (RFC §5.3) or the filter predicate (§7.2). Returns
    the semiring identity ``empty_zero`` (0̄) when no combination is admitted.
    """
    acc: float | None = None
    prev = dict(ctx.locals)
    try:
        ctx.locals.update(local_binding)
        for red_point in cartesian_red:
            binding = dict(local_binding)
            for s, v in zip(reduce_syms, red_point):
                binding[s] = v
            if gates and not _join_admits(gates, binding):
                continue
            for s, v in zip(reduce_syms, red_point):
                ctx.locals[s] = v
            if filter_expr is not None and not _filter_admits(filter_expr, ctx):
                continue
            val = float(eval_expr(body, ctx))
            acc = _reduce_step(reducer, acc, val)
    finally:
        ctx.locals = prev
    return acc if acc is not None else empty_zero


def _eval_makearray(expr: ExprNode, ctx: EvalContext) -> np.ndarray:
    """Build a dense array from a list of region/value pairs."""
    regions = expr.regions or []
    values = expr.values or []
    if len(regions) != len(values):
        raise NumpyInterpreterError(
            f"makearray: regions/values length mismatch ({len(regions)} vs {len(values)})"
        )
    if not regions:
        raise NumpyInterpreterError("makearray requires at least one region")

    # Infer output shape from the union of region bounding boxes.
    ndim = len(regions[0])
    shape = [0] * ndim
    for region in regions:
        if len(region) != ndim:
            raise NumpyInterpreterError("makearray regions have inconsistent ndim")
        for d, (_lo, hi) in enumerate(region):
            if hi > shape[d]:
                shape[d] = int(hi)

    # Stencil makearray carrying its own loop symbols (``output_idx``, set by the
    # pointwise lift, esm-spec §10.5). Each region's value expression indexes the
    # grid relative to those loop symbols (``index(sp, i+1, j)``), so it MUST be
    # evaluated with the symbols bound to that region's own arange — never to an
    # enclosing aggregate's scalar cell (which would read ``i+1`` out of bounds).
    # Delegate to the region-wise vectorized builder, which binds + restores per
    # region. Absent ``output_idx`` (every ESD-discretized / const makearray) this
    # is skipped, so behaviour is byte-for-byte unchanged there.
    if expr.output_idx:
        out_syms = [s for s in expr.output_idx if isinstance(s, str)]
        if len(out_syms) == ndim:
            return _materialize_makearray_vectorized(expr, ctx, out_syms, tuple(shape))

    out = np.zeros(tuple(shape), dtype=float)
    for region, value_expr in zip(regions, values):
        v = eval_expr(value_expr, ctx)
        slicer = tuple(slice(int(lo) - 1, int(hi)) for lo, hi in region)
        if isinstance(v, np.ndarray):
            out[slicer] = v
        else:
            out[slicer] = float(v)
    return out


def _eval_broadcast(expr: ExprNode, ctx: EvalContext) -> np.ndarray:
    """Element-wise combine operands under Julia-style broadcasting.

    Julia left-aligns shapes when broadcasting (trailing 1s are added to
    shorter shapes), whereas NumPy right-aligns. To match the Julia binding's
    semantics we pad every operand's shape with trailing 1s to the maximum
    rank, then combine via NumPy's own broadcasting. A ``(3,) .+ (1,3)``
    pair becomes ``(3,1) .+ (1,3) = (3,3)``.
    """
    fn_name = expr.fn or "+"
    fn = _broadcast_fn(fn_name)
    vals = [eval_expr(a, ctx) for a in expr.args]
    if not vals:
        raise NumpyInterpreterError("broadcast requires at least 1 arg")
    arrs = [_as_array(v) for v in vals]
    max_ndim = max(a.ndim for a in arrs) if arrs else 0
    aligned: list[np.ndarray] = []
    for a in arrs:
        if a.ndim < max_ndim:
            new_shape = list(a.shape) + [1] * (max_ndim - a.ndim)
            aligned.append(a.reshape(new_shape))
        else:
            aligned.append(a)
    result = aligned[0]
    for a in aligned[1:]:
        result = fn(result, a)
    return np.asarray(result, dtype=float)


def _eval_reshape(expr: ExprNode, ctx: EvalContext) -> np.ndarray:
    if not expr.args:
        raise NumpyInterpreterError("reshape requires at least 1 arg")
    v = eval_expr(expr.args[0], ctx)
    arr = _as_array(v)
    shape = expr.shape or []
    concrete_shape: list[int] = []
    for s in shape:
        if isinstance(s, int):
            concrete_shape.append(s)
        else:
            raise NumpyInterpreterError(
                f"reshape symbolic shape {s!r} not supported in NumPy interpreter"
            )
    # Julia uses column-major; NumPy is row-major by default. Use Fortran
    # ordering to match the Julia binding's reshape semantics.
    return np.asarray(arr, dtype=float).reshape(concrete_shape, order="F")


def _eval_transpose(expr: ExprNode, ctx: EvalContext) -> np.ndarray:
    if not expr.args:
        raise NumpyInterpreterError("transpose requires 1 arg")
    v = eval_expr(expr.args[0], ctx)
    arr = _as_array(v)
    if expr.perm is not None:
        return np.transpose(arr, axes=list(expr.perm))
    if arr.ndim <= 1:
        return arr.reshape(1, -1) if arr.ndim == 1 else arr
    return np.transpose(arr)


def _eval_concat(expr: ExprNode, ctx: EvalContext) -> np.ndarray:
    if not expr.args:
        raise NumpyInterpreterError("concat requires at least 1 arg")
    arrs = [np.atleast_1d(_as_array(eval_expr(a, ctx))) for a in expr.args]
    axis = expr.axis if expr.axis is not None else 0
    return np.concatenate(arrs, axis=axis)


def fold_constant_expr(expr: Expr, bindings: dict[str, float] | None = None) -> float:
    """Evaluate a scalar AST expression with optional named scalar bindings.

    Wraps :func:`eval_expr` with an empty-state ``EvalContext`` so callers can
    fold a closed AST (e.g. a unit-conversion constant) or evaluate a scalar
    AST against a tiny binding dict (e.g. one raw-value sample for a
    one-variable conversion expression). Bindings are exposed through the
    interpreter's symbol-resolution path; ``state_layout``/``state_shapes`` are
    empty so any array op or unbound symbol surfaces as
    :class:`NumpyInterpreterError`.

    The expression must reduce to a scalar; an array result raises.
    """
    ctx = EvalContext(
        state_layout={},
        state_shapes={},
        param_values=dict(bindings) if bindings else {},
        observed_values={},
        y=np.empty((0,), dtype=float),
        t=0.0,
    )
    result = eval_expr(expr, ctx)
    if isinstance(result, np.ndarray):
        if result.shape == ():
            return float(result)
        raise NumpyInterpreterError(
            f"fold_constant_expr expected a scalar result, got array of shape {result.shape}"
        )
    return float(result)


def build_partition(model: dict[str, Any]) -> Partition:
    """Run the build-time cadence-partition pass over a parsed model.

    This is the dependency-partition analysis (``CONFORMANCE_SPEC.md`` §5.7, the
    ESS ``structural_simplify`` analogue) the build phase runs *before* it
    compiles the per-step hot tree: it classifies every node by cadence
    (``const ⊏ discrete ⊏ continuous``, ``class(node) = max`` over inputs, the
    gather rule classing index expressions independently of the array), derives
    the two-threshold materialization frontier, and checks the three guards. It
    **generalises** the constant-fold :func:`fold_constant_expr` already
    performs — applied once at the ``const`` threshold and again at the
    ``discrete`` one — so topology FAQs fold via the relational engine in the
    ``const`` / ``discrete`` phase and never reach the hot path. The per-step
    recursive :func:`eval_expr` walk the rest of this module performs for existing
    (all-continuous) rules is **unchanged**: the partition only schedules which
    sub-DAGs are pre-evaluated into buffers the hot evaluator then reads as
    constants.

    Thin delegator to :func:`earthsci_ast.cadence.partition`; see that module
    for the full contract. Raises
    :class:`earthsci_ast.cadence.CadenceError` on a guard violation.
    """
    return _partition_model(model)


def evaluate(expr: Expr, bindings: dict[str, float]) -> float:
    """Evaluate a scalar AST expression against a dict of float variable bindings.

    This is the official ESS Python runner entry point (the public API
    imported as ``from earthsci_ast import evaluate``). It wraps
    :func:`eval_expr` with an empty-state :class:`EvalContext` so callers
    don't need to construct one themselves.

    ``bindings`` maps free-variable names to their numeric values. The
    special key ``"t"`` supplies the simulation time (defaults to ``0.0``
    if absent). Returns the scalar result as a Python ``float``.
    Raises :class:`NumpyInterpreterError` if any variable in ``expr`` is
    not in ``bindings``.
    """
    t = float(bindings.get("t", 0.0))
    param_values = {k: float(v) for k, v in bindings.items() if k != "t"}
    ctx = EvalContext(
        state_layout={},
        state_shapes={},
        param_values=param_values,
        observed_values={},
        y=np.empty((0,), dtype=float),
        t=t,
    )
    result = eval_expr(expr, ctx)
    if isinstance(result, np.ndarray):
        if result.shape == ():
            return float(result)
        raise NumpyInterpreterError(
            f"evaluate() expected a scalar result, got array of shape {result.shape}"
        )
    return float(result)


def expr_contains_array_op(expr: Expr) -> bool:
    """Return True if ``expr`` contains any array op node (esm_types.ARRAY_OPS)."""
    if isinstance(expr, ExprNode):
        if expr.op in ARRAY_OPS:
            return True
        return any_child(expr, expr_contains_array_op)
    return False
