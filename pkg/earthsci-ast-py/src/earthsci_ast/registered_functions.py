"""
Closed function registry — Python implementation (esm-tzp / esm-4ia).

Implements the spec-defined closed function set from esm-spec §9.2:

* ``datetime.year``, ``month``, ``day``, ``hour``, ``minute``, ``second``,
  ``day_of_year``, ``julian_day``, ``is_leap_year`` — proleptic-Gregorian
  calendar decomposition of an IEEE-754 ``binary64`` UTC scalar
  (seconds since the Unix epoch, no leap-second consultation).
* ``interp.searchsorted`` — 1-based search-into-sorted-array (Julia's
  ``searchsortedfirst`` semantics with explicit out-of-range / NaN /
  duplicate behavior pinned by spec).
* ``interp.linear`` — 1-D linear interpolation into a tabulated dataset with
  extrapolate-flat boundary handling (spec §9.2 ``interp.*`` subsection).
* ``interp.bilinear`` — 2-D linear interpolation (row-major table indexed by
  ``axis_x`` then ``axis_y``); pinned evaluation order is two 1-D x-blends
  followed by one 1-D y-blend so that bindings agree bit-exactly.

The set is **closed**: callers MUST reject any ``fn``-op ``name`` outside this
list (diagnostic ``unknown_closed_function``). This module provides:

- :func:`closed_function_names` — the public closed-set as a ``set[str]``.
- :func:`evaluate_closed_function` — dispatch entry point used by the
  expression evaluators (``expression.py``, ``numpy_interpreter.py``).
- :func:`lower_enums` — load-time pass that resolves every ``enum`` op in an
  :class:`EsmFile` to a ``const`` integer per esm-spec §9.3.
- :class:`ClosedFunctionError` — error type carrying spec-defined diagnostic
  codes (``unknown_closed_function``, ``closed_function_overflow``,
  ``searchsorted_non_monotonic``, ``closed_function_arity``,
  ``searchsorted_nan_in_table``, ``interp_non_monotonic_axis``,
  ``interp_axis_length_mismatch``, ``interp_nan_in_axis``,
  ``interp_axis_too_short``).

Calendar arithmetic uses Python's stdlib :mod:`datetime` with the
proleptic-Gregorian default; the v0.3.0 spec contract forbids leap-second
consultation, which :class:`datetime.datetime` already honors.
``datetime.julian_day`` is computed via the Fliegel–van Flandern (1968)
integer formula plus the fractional-day offset, giving ≤ 1 ulp agreement
with the spec reference computation.
"""

from __future__ import annotations

import math
from collections.abc import Sequence
from dataclasses import dataclass, replace
from datetime import datetime, timedelta, timezone
from typing import Any, Callable

from .diagnostics import (
    CLOSED_FUNCTION_ARITY,
    CLOSED_FUNCTION_OVERFLOW,
    INTERP_AXIS_LENGTH_MISMATCH,
    INTERP_AXIS_TOO_SHORT,
    INTERP_NAN_IN_AXIS,
    INTERP_NON_MONOTONIC_AXIS,
    SEARCHSORTED_NAN_IN_TABLE,
    SEARCHSORTED_NON_MONOTONIC,
    UNKNOWN_CLOSED_FUNCTION,
    UNKNOWN_ENUM,
    UNKNOWN_ENUM_SYMBOL,
)
from .errors import EarthSciAstError
from .esm_types import DataLoader, Equation, EsmFile, ExprNode, Model, ReactionSystem
from .expr_walk import iter_children, map_children

# ============================================================
# Errors
# ============================================================


class ClosedFunctionError(EarthSciAstError):
    """Raised when the closed function registry contract is violated.

    The ``code`` attribute carries one of the stable diagnostic codes pinned
    by esm-spec §9.1–§9.2:

    - ``unknown_closed_function`` — ``fn``-op ``name`` is not in the v0.3.0 set.
    - ``closed_function_arity`` — wrong number of arguments for the named function.
    - ``closed_function_overflow`` — integer-typed result would overflow Int32.
    - ``searchsorted_non_monotonic`` — ``xs`` is not non-decreasing.
    - ``searchsorted_nan_in_table`` — ``xs`` contains a NaN entry.

    The code constants themselves are defined in
    :mod:`earthsci_ast.diagnostics`; their string values are part of the
    cross-binding contract and must never change.
    """

    def __init__(self, code: str, message: str) -> None:
        super().__init__(f"ClosedFunctionError({code}): {message}")
        self.code = code
        self.message = message


# ============================================================
# Closed function set
# ============================================================


@dataclass(frozen=True)
class _ClosedFunction:
    """One entry in the closed-function registry (esm-spec §9.2).

    ``arity`` is the exact argument count (checked centrally before dispatch);
    ``handler`` receives ``(name, args)`` and returns the ``int``/``float``
    result; ``const_positions`` lists the argument slots that MUST be inline
    ``const`` arrays (table / axis data) — empty for all-dynamic functions.
    """

    arity: int
    handler: Callable[[str, Sequence[Any]], int | float]
    const_positions: tuple[int, ...] = ()


# Single source of truth for the v0.3.0 closed function set (esm-spec §9.2).
# ``_CLOSED_FUNCTION_NAMES`` and ``INTERP_CONST_ARG_POSITIONS`` are DERIVED from
# this map, and :func:`evaluate_closed_function` dispatches through it — so a new
# primitive is added in exactly one place. Handlers are lambdas that defer to the
# module-level helper functions defined further below; the deferred lookup means
# definition order does not matter (the helpers only need to exist at call time).
_CLOSED_FUNCTIONS: dict[str, _ClosedFunction] = {
    "datetime.year": _ClosedFunction(
        1, lambda name, args: _check_int32(name, _to_datetime(args[0]).year)
    ),
    "datetime.month": _ClosedFunction(1, lambda name, args: _to_datetime(args[0]).month),
    "datetime.day": _ClosedFunction(1, lambda name, args: _to_datetime(args[0]).day),
    "datetime.hour": _ClosedFunction(1, lambda name, args: _to_datetime(args[0]).hour),
    "datetime.minute": _ClosedFunction(1, lambda name, args: _to_datetime(args[0]).minute),
    "datetime.second": _ClosedFunction(1, lambda name, args: _to_datetime(args[0]).second),
    "datetime.day_of_year": _ClosedFunction(
        1, lambda name, args: _day_of_year(_to_datetime(args[0]))
    ),
    "datetime.julian_day": _ClosedFunction(
        1, lambda name, args: _datetime_julian_day(float(args[0]))
    ),
    "datetime.is_leap_year": _ClosedFunction(
        1, lambda name, args: 1 if _is_leap_year(_to_datetime(args[0]).year) else 0
    ),
    "interp.searchsorted": _ClosedFunction(
        2, lambda name, args: _interp_searchsorted(name, float(args[0]), args[1]), (1,)
    ),
    "interp.linear": _ClosedFunction(
        3, lambda name, args: _interp_linear(name, args[0], args[1], float(args[2])), (0, 1)
    ),
    "interp.bilinear": _ClosedFunction(
        5,
        lambda name, args: _interp_bilinear(
            name, args[0], args[1], args[2], float(args[3]), float(args[4])
        ),
        (0, 1, 2),
    ),
}


_CLOSED_FUNCTION_NAMES: frozenset = frozenset(_CLOSED_FUNCTIONS)


# Argument positions that MUST be inline `const` arrays (table / axis data) for
# each closed function. Per esm-spec §9.2 ``interp.*``, these slots accept only
# materialized constant data — they are not state-dependent expressions and the
# evaluators (``numpy_interpreter.eval_expr`` and the SymPy bridge) extract the
# raw Python list before calling :func:`evaluate_closed_function`. DERIVED from
# ``_CLOSED_FUNCTIONS`` (single source of truth); any closed function absent here
# has all-dynamic arguments (e.g. ``datetime.*`` takes a single scalar ``t_utc``).
INTERP_CONST_ARG_POSITIONS: dict[str, tuple] = {
    name: spec.const_positions
    for name, spec in _CLOSED_FUNCTIONS.items()
    if spec.const_positions
}


def closed_function_names() -> frozenset:
    """Return the v0.3.0 closed function set.

    Bindings MUST reject any ``fn``-op ``name`` not in this set. The set is
    intentionally narrow; new entries require a spec rev (esm-spec §9.1).
    """
    return _CLOSED_FUNCTION_NAMES


# Int32 boundaries — the spec pins integer outputs to signed 32-bit.
_INT32_MIN = -(1 << 31)
_INT32_MAX = (1 << 31) - 1


def _check_int32(name: str, v: int) -> int:
    if v < _INT32_MIN or v > _INT32_MAX:
        raise ClosedFunctionError(
            CLOSED_FUNCTION_OVERFLOW,
            f"{name}: result {v} overflows Int32",
        )
    return v


def _expect_arity(name: str, args: Sequence[Any], n: int) -> None:
    if len(args) != n:
        raise ClosedFunctionError(
            CLOSED_FUNCTION_ARITY,
            f"{name} expects {n} argument(s), got {len(args)}",
        )


def _to_datetime(t_utc: Any) -> datetime:
    """Convert a UTC scalar (seconds since Unix epoch) to a tz-aware datetime.

    Uses ``datetime.fromtimestamp(..., tz=timezone.utc)`` which honors the
    proleptic-Gregorian calendar and (per the spec contract) does not consult
    leap seconds.
    """
    seconds = float(t_utc)
    if not math.isfinite(seconds):
        raise ClosedFunctionError(
            CLOSED_FUNCTION_ARITY,
            f"datetime.*: t_utc must be finite, got {seconds}",
        )
    # `datetime.fromtimestamp(..., tz=utc)` accepts negative values for
    # pre-epoch times on all supported platforms (CPython implements its own
    # proleptic-Gregorian arithmetic and does not delegate to libc gmtime).
    return datetime(1970, 1, 1, tzinfo=timezone.utc) + timedelta(seconds=seconds)


def _trunc_div(a: int, b: int) -> int:
    """Truncated integer division (rounds toward zero), C/Julia ÷ semantics.

    Python's ``//`` is floor division — it disagrees with the C-style
    semantics the Fliegel–van Flandern (1968) formula assumes whenever the
    dividend is negative (e.g. ``(M − 14)`` for ``M ∈ [1, 12]``). Misusing
    ``//`` here produces JDN values that drift by 1–2 days from the spec.
    """
    q, r = divmod(a, b)
    if r != 0 and (a < 0) != (b < 0):
        q += 1
    return q


def _datetime_julian_day(t_utc: float) -> float:
    """Fliegel–van Flandern (1968) integer JDN + fractional-day offset.

    Returns a Float64 with ≤ 1 ulp agreement to the spec reference
    computation. The only floating-point operation in the inner formula is
    the final divide by 86400 (one rounded operation).
    """
    dt = _to_datetime(t_utc)
    y, m, d = dt.year, dt.month, dt.day
    a = _trunc_div(m - 14, 12)
    jdn = (
        _trunc_div(1461 * (y + 4800 + a), 4)
        + _trunc_div(367 * (m - 2 - 12 * a), 12)
        - _trunc_div(3 * _trunc_div(y + 4900 + a, 100), 4)
        + d
        - 32075
    )
    # JDN counts noon-to-noon; convert time-of-day seconds (since 00:00 UTC)
    # to a fractional offset relative to noon. The spec pins this offset as
    # `(time_of_day_seconds − 43200) / 86400` (esm-spec §9.2.1).
    seconds_in_day = math.fmod(float(t_utc), 86400.0)
    if seconds_in_day < 0:
        seconds_in_day += 86400.0
    return float(jdn) + (seconds_in_day - 43200.0) / 86400.0


def _is_leap_year(year: int) -> bool:
    return year % 4 == 0 and (year % 100 != 0 or year % 400 == 0)


# Cumulative day-of-year for the start of each month (1-based; index 0 = Jan).
_DOY_CUMULATIVE_NORMAL = (0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334)
_DOY_CUMULATIVE_LEAP = (0, 31, 60, 91, 121, 152, 182, 213, 244, 274, 305, 335)


def _day_of_year(dt: datetime) -> int:
    table = _DOY_CUMULATIVE_LEAP if _is_leap_year(dt.year) else _DOY_CUMULATIVE_NORMAL
    return table[dt.month - 1] + dt.day


def _interp_searchsorted(name: str, x: float, xs: Any) -> int:
    """``interp.searchsorted`` per esm-spec §9.2.2.

    1-based, left-side bias (smallest ``i`` with ``xs[i] ≥ x``); out-of-range
    below → 1, above → ``N+1``; NaN ``x`` → ``N+1``; NaN entries in ``xs``
    raise; non-monotonic ``xs`` raises.
    """
    if not isinstance(xs, (list, tuple)):
        raise ClosedFunctionError(
            CLOSED_FUNCTION_ARITY,
            f"{name}: xs argument must be an array (got {type(xs).__name__})",
        )
    n = len(xs)
    if n == 0:
        # Empty table — extends "above-range → N+1" to N=0; the only consistent
        # extension that composes with `index`.
        return 1
    # Validate monotonicity + NaN-in-table once per call.
    prev = float("nan")
    for i, raw in enumerate(xs):
        v = float(raw)
        if math.isnan(v):
            raise ClosedFunctionError(
                SEARCHSORTED_NAN_IN_TABLE,
                f"{name}: xs[{i + 1}] is NaN; NaN entries in xs are forbidden",
            )
        if i > 0 and v < prev:
            raise ClosedFunctionError(
                SEARCHSORTED_NON_MONOTONIC,
                f"{name}: xs is not non-decreasing (xs[{i + 1}]={v} < xs[{i}]={prev})",
            )
        prev = v
    # NaN x → N+1 (treated as "greater than every finite element").
    if math.isnan(x):
        return _check_int32(name, n + 1)
    # Linear scan for the smallest 1-based index with xs[i] ≥ x. The spec
    # mandates left-side bias on duplicates.
    for i in range(n):
        if float(xs[i]) >= x:
            return _check_int32(name, i + 1)
    return _check_int32(name, n + 1)


def _validate_interp_axis(name: str, axis: Sequence[Any], axis_label: str) -> list[float]:
    """Validate a 1-D interpolation axis and return it as a list of floats.

    Spec §9.2 ``interp.*`` subsection requires axes be strictly increasing
    (no equal-adjacent), contain no NaN, and have at least two entries —
    otherwise there is no interval to blend across.
    """
    if not isinstance(axis, (list, tuple)):
        raise ClosedFunctionError(
            CLOSED_FUNCTION_ARITY,
            f"{name}: {axis_label} must be an inline `const` array (got {type(axis).__name__})",
        )
    n = len(axis)
    if n < 2:
        raise ClosedFunctionError(
            INTERP_AXIS_TOO_SHORT,
            f"{name}: {axis_label} has {n} entries; need ≥ 2 to define a cell",
        )
    out: list[float] = []
    prev = float("-inf")
    for i, raw in enumerate(axis):
        v = float(raw)
        if math.isnan(v):
            raise ClosedFunctionError(
                INTERP_NAN_IN_AXIS,
                f"{name}: {axis_label}[{i + 1}] is NaN; NaN entries in axes are forbidden",
            )
        if i > 0 and v <= prev:
            raise ClosedFunctionError(
                INTERP_NON_MONOTONIC_AXIS,
                f"{name}: {axis_label} is not strictly increasing "
                f"({axis_label}[{i + 1}]={v} ≤ {axis_label}[{i}]={prev})",
            )
        out.append(v)
        prev = v
    return out


def _interp_linear(name: str, table: Any, axis: Any, x: float) -> float:
    """``interp.linear`` per esm-spec §9.2 ``interp.*`` subsection.

    Extrapolate-flat boundary, pinned blend ``t[i] + w*(t[i+1] - t[i])``.
    """
    if not isinstance(table, (list, tuple)):
        raise ClosedFunctionError(
            CLOSED_FUNCTION_ARITY,
            f"{name}: table must be an inline `const` array (got {type(table).__name__})",
        )
    axis_vals = _validate_interp_axis(name, axis, "axis")
    n = len(axis_vals)
    if len(table) != n:
        raise ClosedFunctionError(
            INTERP_AXIS_LENGTH_MISMATCH,
            f"{name}: len(table)={len(table)} != len(axis)={n}",
        )
    table_vals = [float(t) for t in table]
    if math.isnan(x):
        # Spec step 4: the clamps in steps 1–2 use IEEE `≤` / `≥` which return
        # false for NaN, so we fall through to the blend, where the NaN weight
        # propagates. Implement directly as NaN.
        return float("nan")
    if x <= axis_vals[0]:
        return table_vals[0]
    if x >= axis_vals[-1]:
        return table_vals[-1]
    # Find i in 0-based [0, n-2] s.t. axis[i] <= x < axis[i+1]. Linear scan
    # matches the spec's exposition; the conformance tables are tiny.
    for i in range(n - 1):
        if axis_vals[i] <= x < axis_vals[i + 1]:
            w = (x - axis_vals[i]) / (axis_vals[i + 1] - axis_vals[i])
            return table_vals[i] + w * (table_vals[i + 1] - table_vals[i])
    # Unreachable: strict monotonicity + clamps cover every finite x.
    raise ClosedFunctionError(
        CLOSED_FUNCTION_ARITY,
        f"{name}: failed to locate cell for x={x} (internal error)",
    )


def _interp_bilinear(
    name: str,
    table: Any,
    axis_x: Any,
    axis_y: Any,
    x: float,
    y: float,
) -> float:
    """``interp.bilinear`` per esm-spec §9.2 ``interp.*`` subsection.

    Two pinned 1-D x-blends followed by one 1-D y-blend; per-axis
    extrapolate-flat clamp; row-major ``table[i][j]`` at ``(axis_x[i], axis_y[j])``.
    """
    if not isinstance(table, (list, tuple)):
        raise ClosedFunctionError(
            CLOSED_FUNCTION_ARITY,
            f"{name}: table must be an inline `const` 2-D array (got {type(table).__name__})",
        )
    ax = _validate_interp_axis(name, axis_x, "axis_x")
    ay = _validate_interp_axis(name, axis_y, "axis_y")
    nx, ny = len(ax), len(ay)
    if len(table) != nx:
        raise ClosedFunctionError(
            INTERP_AXIS_LENGTH_MISMATCH,
            f"{name}: outer len(table)={len(table)} != len(axis_x)={nx}",
        )
    table_rows: list[list[float]] = []
    for i, row in enumerate(table):
        if not isinstance(row, (list, tuple)):
            raise ClosedFunctionError(
                INTERP_AXIS_LENGTH_MISMATCH,
                f"{name}: table row {i + 1} is not an array (got {type(row).__name__})",
            )
        if len(row) != ny:
            raise ClosedFunctionError(
                INTERP_AXIS_LENGTH_MISMATCH,
                f"{name}: table row {i + 1} has length {len(row)} != len(axis_y)={ny}",
            )
        table_rows.append([float(v) for v in row])
    if math.isnan(x) or math.isnan(y):
        # Spec step 5: NaN inputs propagate through the corresponding axis
        # weight. Short-circuit to NaN.
        return float("nan")
    # Per-axis extrapolate-flat clamp (spec step 1).
    x_q = ax[0] if x <= ax[0] else (ax[-1] if x >= ax[-1] else x)
    y_q = ay[0] if y <= ay[0] else (ay[-1] if y >= ay[-1] else y)
    # Cell location: largest 0-based index in [0, n-2] with axis[i] <= q.
    # Linear scan (small fixtures); matches the spec's "largest i" convention
    # so that an interior-knot query lands on i = k (wx = 0).
    i = 0
    for k in range(nx - 1):
        if ax[k] <= x_q:
            i = k
    j = 0
    for k in range(ny - 1):
        if ay[k] <= y_q:
            j = k
    wx = (x_q - ax[i]) / (ax[i + 1] - ax[i])
    wy = (y_q - ay[j]) / (ay[j + 1] - ay[j])
    # Pinned evaluation order: two x-blends, then one y-blend.
    row_j = table_rows[i][j] + wx * (table_rows[i + 1][j] - table_rows[i][j])
    row_jp1 = table_rows[i][j + 1] + wx * (table_rows[i + 1][j + 1] - table_rows[i][j + 1])
    return row_j + wy * (row_jp1 - row_j)


# ============================================================
# Dispatch
# ============================================================


def evaluate_closed_function(name: str, args: Sequence[Any]) -> int | float:
    """Dispatch a closed function call.

    ``name`` is the dotted-module spec name (e.g. ``"datetime.julian_day"``);
    ``args`` is a sequence of evaluated argument values. Integer-typed
    results are returned as :class:`int` (range-checked to Int32);
    float-typed results are :class:`float`.

    For ``interp.searchsorted`` the second argument MUST be the table (a
    list/tuple of numeric values) — the caller is responsible for extracting
    the array from a ``const``-op AST node before invoking this function.

    Raises :class:`ClosedFunctionError` on contract violations.
    """
    spec = _CLOSED_FUNCTIONS.get(name)
    if spec is None:
        raise ClosedFunctionError(
            UNKNOWN_CLOSED_FUNCTION,
            f"`fn` name `{name}` is not in the v0.3.0 closed function "
            f"registry (esm-spec §9.2). Adding a primitive requires a spec rev.",
        )
    _expect_arity(name, args, spec.arity)
    return spec.handler(name, args)


# ============================================================
# `const` argument extraction
# ============================================================


def extract_const_array(node: Any) -> list[Any]:
    """Extract a const-op array argument as a (possibly nested) Python list.

    The ``interp.*`` closed functions take inline ``const`` arrays for their
    table and axis arguments (see esm-spec §9.2 ``interp.*`` subsection):
    ``interp.searchsorted`` for ``xs``; ``interp.linear`` for ``table`` and
    ``axis``; ``interp.bilinear`` for ``table`` (2-D), ``axis_x``, and
    ``axis_y``. Evaluators must pass the raw array — not a per-element-
    evaluated value — to the closed function dispatch. This helper unwraps
    ``{op: "const", value: [...]}``.
    """
    if isinstance(node, ExprNode) and node.op == "const":
        return list(node.value or [])
    if isinstance(node, (list, tuple)):
        return list(node)
    raise ClosedFunctionError(
        CLOSED_FUNCTION_ARITY,
        "interp.*: table / axis argument must be an inline `const` array",
    )


# ============================================================
# Enum lowering — esm-spec §9.3
# ============================================================


class EnumLoweringError(EarthSciAstError, ValueError):
    """Raised when enum lowering (esm-spec §9.3) fails.

    Carries the stable diagnostic ``code`` (``unknown_enum`` /
    ``unknown_enum_symbol``) as a structured attribute — like
    :class:`ClosedFunctionError` — instead of interpolating it into the message
    text. Also subclasses :class:`ValueError` so callers that historically
    caught the bare ``ValueError`` this path raised remain compatible.
    """

    def __init__(self, code: str, message: str) -> None:
        super().__init__(f"{code}: {message}")
        self.code = code
        self.message = message


def lower_enums(file: EsmFile) -> EsmFile:
    """Walk every expression tree in ``file`` and replace each ``enum`` op
    with a ``const`` integer per the file's ``enums`` block.

    After this pass runs, no ``enum``-op nodes remain in the in-memory
    representation.

    Validation (esm-spec §9.3):

    - An ``enum`` op naming an undeclared enum raises
      :class:`EnumLoweringError` with ``code == "unknown_enum"``.
    - An ``enum`` op naming a symbol not declared under that enum raises
      :class:`EnumLoweringError` with ``code == "unknown_enum_symbol"``.

    :class:`EnumLoweringError` subclasses :class:`ValueError`, so existing
    ``except ValueError`` callers continue to catch these.

    Mutates ``file`` in place; returns the file for convenience.
    """
    enums: dict[str, dict[str, int]] = file.enums or {}
    for model in file.models.values():
        _lower_model(model, enums)
    for rs in file.reaction_systems.values():
        _lower_reaction_system(rs, enums)
    return file


def _lower_model(model: Model, enums: dict[str, dict[str, int]]) -> None:
    for vname, var in list(model.variables.items()):
        if var.expression is not None:
            new_expr = _lower_expr(var.expression, enums)
            if new_expr is not var.expression:
                model.variables[vname] = replace(var, expression=new_expr)
    new_eqs: list[Equation] = []
    for eq in model.equations:
        new_eqs.append(
            Equation(
                lhs=_lower_expr(eq.lhs, enums),
                rhs=_lower_expr(eq.rhs, enums),
                _comment=eq._comment,
            )
        )
    model.equations[:] = new_eqs
    new_init: list[Equation] = []
    for eq in model.initialization_equations:
        new_init.append(
            Equation(
                lhs=_lower_expr(eq.lhs, enums),
                rhs=_lower_expr(eq.rhs, enums),
                _comment=eq._comment,
            )
        )
    model.initialization_equations[:] = new_init
    for sub in model.subsystems.values():
        # Data-loader subsystems carry no equations/enums to lower.
        if isinstance(sub, DataLoader):
            continue
        _lower_model(sub, enums)


def _lower_reaction_system(rs: ReactionSystem, enums: dict[str, dict[str, int]]) -> None:
    for r in rs.reactions:
        if r.rate_constant is not None:
            r.rate_constant = _lower_expr(r.rate_constant, enums)
    for sub in rs.subsystems.values():
        _lower_reaction_system(sub, enums)


def _lower_expr(node: Any, enums: dict[str, dict[str, int]]) -> Any:
    if not isinstance(node, ExprNode):
        return node
    if node.op == "enum":
        if len(node.args) != 2 or not all(isinstance(a, str) for a in node.args):
            raise ValueError(
                f"`enum` op expects exactly 2 string args (enum_name, symbol_name); "
                f"got {len(node.args)}: {node.args}"
            )
        enum_name, symbol_name = node.args[0], node.args[1]
        if enum_name not in enums:
            raise EnumLoweringError(
                UNKNOWN_ENUM,
                f"enum `{enum_name}` is not declared in the file's `enums` block",
            )
        mapping = enums[enum_name]
        if symbol_name not in mapping:
            raise EnumLoweringError(
                UNKNOWN_ENUM_SYMBOL,
                f"symbol `{symbol_name}` is not declared under enum `{enum_name}`",
            )
        return ExprNode(op="const", args=[], value=mapping[symbol_name])
    # Recurse through the FULL canonical child set (args, lower, upper, expr,
    # filter, key, values, table_axes) via expr_walk.map_children so this can
    # never again drift from the canonical child slots and silently skip an
    # `enum` hidden in an integral bound, aggregate filter, or skolem key.
    # Rebuild only when a child actually changed, preserving node identity.
    rebuilt = map_children(node, lambda c: _lower_expr(c, enums))
    if all(a is b for a, b in zip(iter_children(node), iter_children(rebuilt))):
        return node
    return rebuilt
