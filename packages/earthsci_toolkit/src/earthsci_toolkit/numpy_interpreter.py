"""
NumPy AST interpreter for array/tensor expression nodes.

This module provides a recursive evaluator for the ESM expression AST that
returns NumPy scalars or ndarrays. It is the Python counterpart of the Rust
``ndarray`` runtime and the Julia ``SymbolicUtils.ArrayOp`` path, and is used
by :mod:`earthsci_toolkit.simulation` when the flattened system contains any
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
  ``j``, ``k`` implicit / reduced) we fall through to the generic nested loop.
  An ``np.einsum`` fast path could be added later — the public API stays the
  same either way.
- Shapes are 1-based to match the schema's Julia heritage. When reading an
  element ``u[i]`` we subtract 1 from the declared integer index.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Callable, Dict, List, Optional, Tuple, Union

import numpy as np

from .esm_types import Expr, ExprNode
from .registered_functions import (
    INTERP_CONST_ARG_POSITIONS as _INTERP_CONST_ARG_POSITIONS,
)


Shape = Tuple[int, ...]


@dataclass
class EvalContext:
    """Runtime data passed to each recursive evaluation step."""

    state_layout: Dict[str, slice]
    state_shapes: Dict[str, Shape]
    param_values: Dict[str, float]
    observed_values: Dict[str, float]
    y: np.ndarray
    t: float
    locals: Dict[str, int] = field(default_factory=dict)
    # Document-scoped index-set registry (RFC semiring-faq-unified-ir §5.2),
    # keyed by name. Used to resolve arrayop / aggregate range references of the
    # form {"from": <name>}. Empty ⇒ no named sets are declared.
    index_sets: Dict[str, Any] = field(default_factory=dict)


class NumpyInterpreterError(Exception):
    """Raised when an expression cannot be evaluated by the NumPy interpreter."""


class UnreachableSpatialOperatorError(NumpyInterpreterError):
    """Raised when a spatial differential operator (`grad`, `div`,
    `laplacian`) reaches the simulator's RHS evaluator.

    Per the canonical pipeline contract, ESD discretization rules MUST
    rewrite these into ``arrayop`` AST before any binding's simulator
    evaluates the equations. Encountering one here means ``discretize``
    was skipped or did not rewrite the node — silently substituting zero
    (the previous behaviour) would mask the broken pipeline. (esm-i7b)
    """

    def __init__(self, op: str) -> None:
        self.op = op
        super().__init__(
            f"UnreachableSpatialOperatorError: encountered '{op}' node in "
            f"simulation evaluation. Spatial operators must be rewritten by "
            f"ESD discretization rules before reaching the simulator. "
            f"Pipeline contract violated."
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


def _resolve_symbol(name: str, ctx: EvalContext) -> Union[float, np.ndarray]:
    """Resolve a bare name reference."""
    if name in ctx.locals:
        return float(ctx.locals[name])
    if name == "t":
        return float(ctx.t)
    if name in ctx.state_layout:
        return _view_state_array(name, ctx)
    if name in ctx.param_values:
        return float(ctx.param_values[name])
    if name in ctx.observed_values:
        return float(ctx.observed_values[name])
    try:
        return float(name)
    except Exception:
        raise NumpyInterpreterError(f"Unresolved symbol: {name!r}")


_SCALAR_FUNCS: Dict[str, Callable] = {
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
    "floor": np.floor,
    "ceil": np.ceil,
    "sign": np.sign,
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
_SEMIRINGS: Dict[str, Dict[str, Any]] = {
    "sum_product": {"oplus": "+",   "zero": 0.0,      "otimes": "*",   "one": 1.0},
    "max_product": {"oplus": "max", "zero": -np.inf,  "otimes": "*",   "one": 1.0},
    "min_sum":     {"oplus": "min", "zero": np.inf,   "otimes": "+",   "one": 0.0},
    "max_sum":     {"oplus": "max", "zero": -np.inf,  "otimes": "+",   "one": 0.0},
    "bool_and_or": {"oplus": "or",  "zero": 0.0,      "otimes": "and", "one": 1.0},
}


def _resolve_semiring(expr: ExprNode) -> Tuple[str, float, str]:
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
    of: List[str]
    offsets: str
    values: Optional[str]


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
            name=name, of=of,
            offsets=entry["offsets"], values=entry.get("values"),
        )
    if kind == "derived":
        raise NumpyInterpreterError(
            f"index set {name!r} is kind 'derived'; data-derived index-set "
            f"materialization (RFC §5.5) is not part of M1"
        )
    raise NumpyInterpreterError(
        f"index set {name!r} has unknown kind {kind!r}"
    )


def _expand_ragged(rr: _RaggedRange, ctx: EvalContext, binding: Dict[str, int]) -> List[int]:
    """Expand a ragged inner set to ``[1 .. offsets[parent]]`` for one parent tuple.

    ``binding`` supplies the (1-based) parent index values named in ``rr.of``.
    The per-parent length is read from the ``offsets`` keyed factor.
    """
    off = _resolve_symbol(rr.offsets, ctx)
    if isinstance(off, np.ndarray) and off.ndim > 0:
        try:
            parent_idx = tuple(int(binding[p]) - 1 for p in rr.of)
        except KeyError as exc:
            raise NumpyInterpreterError(
                f"ragged index set {rr.name!r} parent index {exc.args[0]!r} is "
                f"not bound; declare it in 'of' and an enclosing range"
            )
        n = int(round(float(off[parent_idx])))
    else:
        n = int(round(float(off)))
    return list(range(1, n + 1))


def eval_expr(expr: Expr, ctx: EvalContext) -> Union[float, np.ndarray]:
    """Recursively evaluate an ESM expression against ``ctx``.

    Returns a Python float for scalar results or a numpy ndarray for
    array-valued sub-expressions.
    """
    if isinstance(expr, (int, float)) and not isinstance(expr, bool):
        return float(expr)
    if isinstance(expr, bool):
        return float(expr)
    if isinstance(expr, str):
        return _resolve_symbol(expr, ctx)
    if not isinstance(expr, ExprNode):
        raise NumpyInterpreterError(f"Cannot evaluate expression of type {type(expr).__name__}")

    op = expr.op
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
        from .registered_functions import evaluate_closed_function, extract_const_array
        if expr.name is None:
            raise NumpyInterpreterError("`fn` op requires a `name` field")
        evaluated_args = []
        const_arg_positions = _INTERP_CONST_ARG_POSITIONS.get(expr.name, ())
        for i, a in enumerate(expr.args):
            if (
                i in const_arg_positions
                and isinstance(a, ExprNode)
                and a.op == "const"
            ):
                evaluated_args.append(extract_const_array(a))
            else:
                evaluated_args.append(eval_expr(a, ctx))
        return float(evaluate_closed_function(expr.name, evaluated_args))
    if op == "enum":
        raise NumpyInterpreterError(
            "`enum` op encountered at evaluate time — `lower_enums(file)` should "
            "have run during load (esm-spec §9.3)"
        )

    # --- scalar arithmetic / elementwise ---
    if op == "+":
        if not expr.args:
            return 0.0
        vals = [eval_expr(a, ctx) for a in expr.args]
        acc = vals[0]
        for v in vals[1:]:
            acc = acc + v
        return acc
    if op == "-":
        vals = [eval_expr(a, ctx) for a in expr.args]
        if len(vals) == 1:
            return -vals[0]
        acc = vals[0]
        for v in vals[1:]:
            acc = acc - v
        return acc
    if op == "*":
        if not expr.args:
            return 1.0
        vals = [eval_expr(a, ctx) for a in expr.args]
        acc = vals[0]
        for v in vals[1:]:
            acc = acc * v
        return acc
    if op == "/":
        if len(expr.args) != 2:
            raise NumpyInterpreterError("/ expects 2 args")
        a = eval_expr(expr.args[0], ctx)
        b = eval_expr(expr.args[1], ctx)
        return a / b
    if op in ("^", "**", "pow"):
        if len(expr.args) != 2:
            raise NumpyInterpreterError(f"{op} expects 2 args")
        a = eval_expr(expr.args[0], ctx)
        b = eval_expr(expr.args[1], ctx)
        return a ** b
    if op == "atan2":
        if len(expr.args) != 2:
            raise NumpyInterpreterError("atan2 expects 2 args")
        a = eval_expr(expr.args[0], ctx)
        b = eval_expr(expr.args[1], ctx)
        return np.arctan2(a, b)
    if op in ("and", "or"):
        if len(expr.args) < 2:
            raise NumpyInterpreterError(f"{op} expects at least 2 args")
        vals = [eval_expr(a, ctx) for a in expr.args]
        if op == "and":
            r = vals[0]
            for v in vals[1:]:
                r = np.logical_and(r, v)
        else:
            r = vals[0]
            for v in vals[1:]:
                r = np.logical_or(r, v)
        return r.astype(float)
    if op == "not":
        if len(expr.args) != 1:
            raise NumpyInterpreterError("not expects 1 arg")
        v = eval_expr(expr.args[0], ctx)
        return np.logical_not(v).astype(float)
    if op in _SCALAR_FUNCS:
        if len(expr.args) != 1:
            raise NumpyInterpreterError(f"{op} expects 1 arg")
        v = eval_expr(expr.args[0], ctx)
        return _SCALAR_FUNCS[op](v)
    if op == "min":
        vals = [eval_expr(a, ctx) for a in expr.args]
        return np.minimum.reduce(vals) if len(vals) > 1 else vals[0]
    if op == "max":
        vals = [eval_expr(a, ctx) for a in expr.args]
        return np.maximum.reduce(vals) if len(vals) > 1 else vals[0]
    if op == "ifelse":
        if len(expr.args) != 3:
            raise NumpyInterpreterError("ifelse expects 3 args")
        cond = eval_expr(expr.args[0], ctx)
        a = eval_expr(expr.args[1], ctx)
        b = eval_expr(expr.args[2], ctx)
        return np.where(cond, a, b)
    if op in (">", "<", ">=", "<=", "==", "!="):
        if len(expr.args) != 2:
            raise NumpyInterpreterError(f"{op} expects 2 args")
        a = eval_expr(expr.args[0], ctx)
        b = eval_expr(expr.args[1], ctx)
        ops = {
            ">": np.greater,
            "<": np.less,
            ">=": np.greater_equal,
            "<=": np.less_equal,
            "==": np.equal,
            "!=": np.not_equal,
        }
        return ops[op](a, b).astype(float)
    if op == "D":
        # D() should have been routed out at the equation level. If we see it
        # here (e.g. inside an expression), treat it as evaluating the inner
        # expression — this is only reachable when the LHS contains D(...) and
        # simulation extracts what it's differentiating.
        if expr.args:
            return eval_expr(expr.args[0], ctx)
        return 0.0
    if op in ("grad", "div", "laplacian"):
        # Spatial differential operators must be rewritten by ESD
        # discretization rules into `arrayop` AST before reaching the
        # simulator. Encountering one here means the canonical pipeline
        # broke; silently substituting zero would mask that. (esm-i7b)
        raise UnreachableSpatialOperatorError(op)

    # --- array ops ---
    if op == "index":
        return _eval_index(expr, ctx)
    # "aggregate" is the canonical op tag; "arrayop" is its deprecated alias
    # (RFC semiring-faq-unified-ir §5.6). Both dispatch identically.
    if op in ("aggregate", "arrayop"):
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

    raise NumpyInterpreterError(f"Unsupported op in NumPy interpreter: {op!r}")


def _eval_index(expr: ExprNode, ctx: EvalContext) -> Union[float, np.ndarray]:
    if not expr.args:
        raise NumpyInterpreterError("index requires at least 1 arg (the array)")
    arr_val = eval_expr(expr.args[0], ctx)
    idxs = [eval_expr(a, ctx) for a in expr.args[1:]]
    if not isinstance(arr_val, np.ndarray):
        # Scalar passed through: if no indices, return it; otherwise that's an error.
        if not idxs:
            return float(arr_val)
        raise NumpyInterpreterError("index applied to scalar value")
    # 1-based -> 0-based.
    zero_idx = tuple(int(round(float(i))) - 1 for i in idxs)
    if len(zero_idx) != arr_val.ndim:
        # Allow row-level access on a 2D array with a single index (returns a row).
        # Otherwise treat as error.
        raise NumpyInterpreterError(
            f"index got {len(zero_idx)} indices for array of shape {arr_val.shape}"
        )
    return float(arr_val[zero_idx])


def _decompose_body_as_scaled_product(
    body: Expr, all_syms: frozenset,
) -> Optional[Tuple[float, List[Tuple[str, List[str]]]]]:
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
        subscripts: List[str] = []
        for s in body.args[1:]:
            if isinstance(s, str) and s in all_syms:
                subscripts.append(s)
            else:
                return None
        return 1.0, [(var, subscripts)]
    if body.op == "*":
        coeff = 1.0
        terms: List[Tuple[str, List[str]]] = []
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
    out_syms: List[str],
    reduce_syms: List[str],
    sym_0based: Dict[str, List[int]],
    out_shape: Tuple[int, ...],
    reducer: str,
) -> Optional[np.ndarray]:
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
            val = coeff ** n_red
        else:
            val = coeff
        return np.full(out_shape, val, dtype=float) if out_shape else np.float64(val)

    # Assign einsum letter labels (output symbols first, then reduction).
    sym_order: List[str] = list(out_syms) + [s for s in reduce_syms if s not in out_syms]
    if len(sym_order) > 26:
        return None
    sym_letter: Dict[str, str] = {s: chr(ord("a") + i) for i, s in enumerate(sym_order)}

    # Build 0-based-sliced arrays for each index term.
    sliced: List[np.ndarray] = []
    term_specs: List[str] = []
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
        arr_slice = (arr[idx_cols[0]] if len(idx_cols) == 1
                     else arr[np.ix_(*idx_cols)])
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
        all_syms_in_terms: List[str] = []
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
    except Exception:
        return None

    return None


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

    out_syms: List[str] = [s for s in output_idx if isinstance(s, str)]
    for s in out_syms:
        if s not in raw_ranges:
            raise NumpyInterpreterError(
                f"aggregate / arrayop output index {s!r} has no declared range"
            )

    reducer, empty_zero, otimes = _resolve_semiring(expr)

    # Resolve {"from": ...} index-set references (RFC §5.2). Dense list ranges
    # pass through unchanged, so existing arrayop fixtures are byte-for-byte
    # identical; ragged sets become per-parent dynamic bounds.
    resolved: Dict[str, Any] = {
        s: _resolve_range_spec(raw_ranges[s], ctx) for s in raw_ranges
    }

    from .flatten import _expand_range  # local import to avoid cycle

    out_ranges_exp: List[List[int]] = []
    for s in out_syms:
        rs = resolved[s]
        if isinstance(rs, _RaggedRange):
            raise NumpyInterpreterError(
                f"output index {s!r} cannot reference a ragged index set: ragged "
                f"sets are per-parent and have no dense output extent (RFC §5.2)"
            )
        out_ranges_exp.append(_expand_range(rs))
    out_shape = tuple(len(r) for r in out_ranges_exp)

    reduce_syms: List[str] = [s for s in raw_ranges if s not in out_syms]
    ragged_reduce = any(isinstance(resolved[s], _RaggedRange) for s in reduce_syms)

    if ragged_reduce:
        return _eval_arrayop_ragged(
            expr, ctx, out_syms, out_ranges_exp, out_shape,
            reduce_syms, resolved, reducer, empty_zero,
        )

    red_ranges_exp = [_expand_range(resolved[s]) for s in reduce_syms]

    # Pre-compute 0-based index lists for the fast path.
    sym_0based: Dict[str, List[int]] = {}
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

    # Scalar fallback: hoist the cartesian reduction product outside the output loop.
    out = np.zeros(out_shape, dtype=float)
    cartesian_red = _cartesian(red_ranges_exp) if reduce_syms else []
    it = np.ndindex(*out_shape) if out_shape else [()]
    for multi_idx in it:
        local_binding: Dict[str, int] = {}
        for s, pos, r in zip(out_syms, multi_idx, out_ranges_exp):
            local_binding[s] = r[pos]
        if not reduce_syms:
            prev = dict(ctx.locals)
            ctx.locals.update(local_binding)
            try:
                out[multi_idx] = float(eval_expr(expr.expr, ctx))
            finally:
                ctx.locals = prev
        else:
            out[multi_idx] = _reduce_over(
                expr.expr, ctx, local_binding, reduce_syms, cartesian_red,
                reducer, empty_zero,
            )
    return out


def _reduce_over(
    body: Expr,
    ctx: EvalContext,
    local_binding: Dict[str, int],
    reduce_syms: List[str],
    cartesian_red: List[Tuple[int, ...]],
    reducer: str,
    empty_zero: float,
) -> float:
    """Reduce ``body`` over the contracted-index cartesian product with ⊕.

    Returns the semiring's empty-reduction identity ``empty_zero`` (0̄) when the
    contracted ranges are empty (RFC §5.1).
    """
    acc: Optional[float] = None
    prev = dict(ctx.locals)
    try:
        ctx.locals.update(local_binding)
        for red_point in cartesian_red:
            for s, v in zip(reduce_syms, red_point):
                ctx.locals[s] = v
            val = float(eval_expr(body, ctx))
            acc = _reduce_step(reducer, acc, val)
    finally:
        ctx.locals = prev
    return acc if acc is not None else empty_zero


def _eval_arrayop_ragged(
    expr: ExprNode,
    ctx: EvalContext,
    out_syms: List[str],
    out_ranges_exp: List[List[int]],
    out_shape: Tuple[int, ...],
    reduce_syms: List[str],
    resolved: Dict[str, Any],
    reducer: str,
    empty_zero: float,
) -> np.ndarray:
    """Scalar evaluation path for aggregates whose contracted bounds are ragged.

    A ragged reduce range depends on the enclosing (output) indices via its
    ``offsets`` factor, so the contracted ranges are recomputed for each output
    point — the named, first-class form of the per-parent dynamic bound (RFC
    §5.2). Non-ragged reduce ranges in the same node expand statically.
    """
    from .flatten import _expand_range  # local import to avoid cycle

    out = np.zeros(out_shape, dtype=float)
    it = np.ndindex(*out_shape) if out_shape else [()]
    for multi_idx in it:
        local_binding: Dict[str, int] = {}
        for s, pos, r in zip(out_syms, multi_idx, out_ranges_exp):
            local_binding[s] = r[pos]
        parent_binding = dict(ctx.locals)
        parent_binding.update(local_binding)
        red_ranges: List[List[int]] = []
        for s in reduce_syms:
            rs = resolved[s]
            if isinstance(rs, _RaggedRange):
                red_ranges.append(_expand_ragged(rs, ctx, parent_binding))
            else:
                red_ranges.append(_expand_range(rs))
        cartesian_red = _cartesian(red_ranges)
        out[multi_idx] = _reduce_over(
            expr.expr, ctx, local_binding, reduce_syms, cartesian_red,
            reducer, empty_zero,
        )
    return out


def _cartesian(lists: List[List[int]]) -> List[Tuple[int, ...]]:
    if not lists:
        return [()]
    result: List[Tuple[int, ...]] = [()]
    for lst in lists:
        result = [prev + (x,) for prev in result for x in lst]
    return result


def _reduce_step(op: str, acc: Optional[float], val: float) -> float:
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
        for d, (lo, hi) in enumerate(region):
            if hi > shape[d]:
                shape[d] = int(hi)
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
    aligned: List[np.ndarray] = []
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
    concrete_shape: List[int] = []
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


def fold_constant_expr(
    expr: Expr, bindings: Optional[Dict[str, float]] = None
) -> float:
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


def evaluate(expr: Expr, bindings: Dict[str, float]) -> float:
    """Evaluate a scalar AST expression against a dict of float variable bindings.

    This is the official ESS Python runner entry point (the public API
    imported as ``from earthsci_toolkit import evaluate``). It wraps
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
    """Return True if ``expr`` contains any array op node."""
    if expr is None or isinstance(expr, (int, float, str)):
        return False
    if isinstance(expr, ExprNode):
        if expr.op in {
            "aggregate", "arrayop", "makearray", "index", "broadcast",
            "reshape", "transpose", "concat",
        }:
            return True
        for a in expr.args:
            if expr_contains_array_op(a):
                return True
        if expr.expr is not None and expr_contains_array_op(expr.expr):
            return True
        if expr.values is not None:
            for v in expr.values:
                if expr_contains_array_op(v):
                    return True
    return False
