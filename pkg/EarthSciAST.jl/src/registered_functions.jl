"""
Closed function registry — Julia reference implementation (esm-tzp / esm-4aw).

Implements the spec-defined closed function set from esm-spec §9.2:

* `datetime.year`, `month`, `day`, `hour`, `minute`, `second`,
  `day_of_year`, `julian_day`, `is_leap_year` — proleptic-Gregorian
  calendar decomposition of an IEEE-754 `binary64` UTC scalar
  (seconds since the Unix epoch, no leap-second consultation).
* `interp.searchsorted` — 1-based search-into-sorted-array (Julia's
  `searchsortedfirst` semantics with explicit out-of-range / NaN /
  duplicate behavior pinned by spec).
* `interp.linear` / `interp.bilinear` — 1-D / 2-D linear interpolation
  with extrapolate-flat boundaries. Pinned evaluation order
  (`a + w * (b - a)`) for cross-binding bit-equivalence on
  exactly-representable IEEE-754 inputs (esm-94w).

The set is **closed**: callers MUST reject any `fn`-op `name` outside this
list (diagnostic `unknown_closed_function`).

## TOTALITY CONTRACT (evaluator-facing)

Every closed function MUST be **total over real inputs**: given any finite
real argument in-shape, it returns a value and **NEVER throws** — an
out-of-domain input yields `NaN` (or the spec-pinned clamp), never an
exception. This is a hard requirement, not a nicety, because the array
evaluators evaluate a closed `fn` **eagerly for every lane** — including lanes
whose value a per-cell guard (`ifelse`/`and`/`or`) will discard. The
whole-array (`_oop`) and lane-tape (`_run_acc_plan!`) paths compute the `fn`
on all cells and then blend; a guard's false lanes get a garbage-but-finite
`fn` value that the select throws away. The scalar reference walk, by
contrast, still SHORT-CIRCUITS — it never evaluates a guarded `fn` on a lane
the guard excludes.

Consequence: a closed function that **throws** off its domain is observable
only as a *difference between evaluator paths* (the vectorized paths raise
where the scalar path silently skipped), and that divergence is a **contract
violation by the function author, not an evaluator bug**. The spec-defined
`datetime.*` / `interp.*` set honors this contract (the calendar functions are
total on finite `Float64`; the interpolators extrapolate flat rather than
raising). Any future closed primitive must too.

This module provides:

- [`closed_function_names`](@ref) — the public closed-set as a `Set{String}`.
- [`evaluate_closed_function`](@ref) — dispatch entry point used by both the
  expression-tree evaluator (`expression.jl`) and the tree-walk evaluator
  (`tree_walk.jl`).
- [`lower_enums!`](@ref) — load-time pass that resolves every `enum` op in an
  [`EsmFile`](@ref) to a `const` integer per esm-spec §9.3.
- [`ClosedFunctionError`](@ref) — error type carrying spec-defined diagnostic
  codes (`unknown_closed_function`, `closed_function_overflow`,
  `searchsorted_non_monotonic`, `closed_function_arity`).

Calendar arithmetic is a BRANCH-FREE closed form over the proleptic-Gregorian
calendar (Hinnant's `civil_from_days`), computed in the argument's own value
type rather than through `Dates` — see the calendar section below for why an
opaque host call is a wall for a traced or otherwise non-host evaluator. The
v0.3.0 spec contract forbids leap-second consultation, which this honors by
construction. `julian_day` is computed via the Fliegel–van Flandern (1968)
integer formula plus the fractional-day offset, giving ≤ 1 ulp agreement with
the spec reference. `Dates` remains the ORACLE: `test/datetime_arithmetic_
test.jl` pins every field against it exhaustively over 1600–2400.
"""

using Dates

# Strip an AD dual number down to its underlying real primal; identity on
# everything else.
#
# `datetime.*` decomposes a UTC scalar through the proleptic-Gregorian calendar.
# That is an inherently DISCRETE operation: `year`/`month`/`day_of_year`/… are
# piecewise-constant in their argument, so their derivative w.r.t. it is zero
# almost everywhere (the jumps sit on the measure-zero calendar boundaries).
# Taking the primal before the decomposition is therefore not an approximation —
# it is the exact a.e. derivative, and it is the ONLY thing that can be done:
# `Dates.unix2datetime` needs a real `Float64`.
#
# This matters even for models that never differentiate w.r.t. time, because the
# tree-walk evaluator is type-stable in its value type `T`: under ForwardDiff
# EVERY leaf is lifted to `T`, so `t` reaches `datetime.*` as a zero-partial
# `Dual` and the old `Float64(::Dual)` coercion raised a `MethodError`.
#
# Identity here; specialized for `ForwardDiff.Dual` in
# `ext/EarthSciASTForwardDiffExt.jl`. Kept as a weakdep seam rather than a hard
# dependency because nothing in the numeric core needs ForwardDiff, and a `Dual`
# cannot exist in a session that has not loaded ForwardDiff — so the identity
# method below is COMPLETE whenever the extension is not loaded, and the
# extension is guaranteed to be loaded before any `Dual` can be constructed.
@inline _value(x) = x

"""
    ClosedFunctionError(code::String, message::String)

Raised by the closed function registry when the spec contract is violated.
`code` is one of the stable diagnostic codes pinned by esm-spec §9.1–§9.2:

- `unknown_closed_function` — `fn`-op `name` is not in the v0.3.0 set.
- `closed_function_arity` — wrong number of arguments for the named function.
- `closed_function_overflow` — integer-typed result would overflow Int32.
- `searchsorted_non_monotonic` — `xs` is not non-decreasing.
- `searchsorted_nan_in_table` — `xs` contains a NaN entry.
- `interp_non_monotonic_axis` — `interp.linear` / `interp.bilinear` axis is
  not strictly increasing (esm-spec §9.2; equal-adjacent rejected because the
  blend denominator would be zero).
- `interp_axis_length_mismatch` — `interp.linear`: `len(table) != len(axis)`;
  `interp.bilinear`: `len(table) != len(axis_x)`, or any inner row length
  differs from `len(axis_y)`.
- `interp_nan_in_axis` — any `axis` (or `axis_x`, `axis_y`) contains a NaN.
- `interp_axis_too_short` — any axis has fewer than 2 entries.
- `interp_table_not_const` / `interp_axis_not_const` — table / axis argument
  is not a literal `const`-op array (e.g. a variable reference). Raised by
  the AST extraction site, not by `evaluate_closed_function` directly.
"""
struct ClosedFunctionError <: Exception
    code::String
    message::String
end

Base.showerror(io::IO, e::ClosedFunctionError) =
    print(io, "ClosedFunctionError(", e.code, "): ", e.message)

"""
    closed_function_names() -> Set{String}

Return the v0.3.0 closed function set. Bindings MUST reject any `fn`-op
`name` not in this set. The set is intentionally narrow; new entries
require a spec rev (esm-spec §9.1).
"""
function closed_function_names()::Set{String}
    return Set{String}([
        "datetime.year",
        "datetime.month",
        "datetime.day",
        "datetime.hour",
        "datetime.minute",
        "datetime.second",
        "datetime.day_of_year",
        "datetime.julian_day",
        "datetime.is_leap_year",
        "interp.searchsorted",
        "interp.linear",
        "interp.bilinear",
    ])
end

const _CLOSED_FUNCTION_NAMES = closed_function_names()

# Range-check an integer-typed closed-function result and box as Int32. The
# spec pins integer outputs to signed 32-bit; `Dates.year(t_utc)` could in
# principle exceed that for absurd inputs.
function _check_int32(name::String, v::Integer)::Int32
    if v < typemin(Int32) || v > typemax(Int32)
        throw(ClosedFunctionError("closed_function_overflow",
            "$(name): result $(v) overflows Int32"))
    end
    return Int32(v)
end

# The same range check for a calendar field arriving as an integer-VALUED real
# (the branch-free decomposition below works in the value's own type, so every
# field comes back as a float on the `Float64` path). Non-finite `t` is
# rejected here rather than raising a bare `InexactError` out of the
# conversion: the totality contract at the top of this file scopes the
# calendar functions to FINITE inputs, and the previous `Dates` path threw on
# NaN too — from inside `round(Int64, NaN)`, with no diagnostic code attached.
# Narrow a calendar field to `Int32` IF the value type can hold one, else hand
# it back untouched. This is what keeps the generic registry's contract
# unchanged for every caller that existed before tracing: the spec pins these
# fields to integers, a host real can be one, and only a value type that
# cannot reach `Float64` gets the widened form.
#
# `Real` is the discriminator because it is exactly the right question — "is
# this a host number?" — and a traced number answers no (Reactant's
# `TracedRNumber <: RNumber <: Number`, deliberately NOT `<: Real`, since
# `Real`'s interface promises host comparisons it cannot honor). Should some
# future backend put a symbolic type under `Real`, this narrows and
# `_cal_i32`'s `Float64(v)` raises a MethodError naming the type — loud, not
# a silently wrong number.
@inline _cal_narrow(name::String, v) = v isa Real ? _cal_i32(name, v) : v

function _cal_i32(name::String, v)::Int32
    fv = Float64(v)
    if !isfinite(fv) || fv < typemin(Int32) || fv > typemax(Int32)
        throw(ClosedFunctionError("closed_function_overflow",
            "$(name): result $(fv) is not a finite Int32"))
    end
    return Int32(fv)
end

"""
    evaluate_closed_function(name::String, args::Vector) -> Any

Dispatch a closed function call. `name` is the dotted-module spec name
(e.g. `"datetime.julian_day"`); `args` is a vector of evaluated argument
values. Integer-typed results are returned as `Int32` to make the integer
contract explicit to callers; float-typed results are `Float64`.

This entry point PINS its float-typed results to `Float64` (it infers as the
concrete `Union{Float64,Int32}`, which the tree-walk RHS depends on for its
zero-allocation property). Most of the registry tolerates an AD dual argument
anyway, because the answer does not depend on the dual part:

- `datetime.year` … `datetime.is_leap_year` — piecewise constant in their
  argument, so they take the dual's primal (see `_value`) and return `Int32`.
- `interp.searchsorted` — the query may be a dual; the result is a discrete
  `Int32` index that carries no derivative.

The three float-RETURNING functions (`interp.linear`, `interp.bilinear`,
`datetime.julian_day`) cannot honour the `Float64` pin on a dual, so they throw
here. Differentiating call sites use [`evaluate_closed_function_ad`](@ref)
instead, which is the same registry without the pin.

For `interp.searchsorted` the second argument must be the table (a
`Vector{<:Real}`) — the caller is responsible for extracting the array
from a `const`-op AST node before invoking this function.

Throws [`ClosedFunctionError`](@ref) on contract violations.
"""
function evaluate_closed_function(name::String, args::AbstractVector)
    if !(name in _CLOSED_FUNCTION_NAMES)
        throw(ClosedFunctionError("unknown_closed_function",
            "`fn` name `$(name)` is not in the v0.3.0 closed function registry " *
            "(esm-spec §9.2). Adding a primitive requires a spec rev."))
    end

    if name == "datetime.year"
        _expect_arity(name, args, 1)
        return _cal_i32(name, _cal_year(_value(args[1])))
    elseif name == "datetime.month"
        _expect_arity(name, args, 1)
        return _cal_i32(name, _cal_month(_value(args[1])))
    elseif name == "datetime.day"
        _expect_arity(name, args, 1)
        return _cal_i32(name, _cal_day(_value(args[1])))
    elseif name == "datetime.hour"
        _expect_arity(name, args, 1)
        return _cal_i32(name, _cal_hour(_value(args[1])))
    elseif name == "datetime.minute"
        _expect_arity(name, args, 1)
        return _cal_i32(name, _cal_minute(_value(args[1])))
    elseif name == "datetime.second"
        _expect_arity(name, args, 1)
        return _cal_i32(name, _cal_second(_value(args[1])))
    elseif name == "datetime.day_of_year"
        _expect_arity(name, args, 1)
        return _cal_i32(name, _cal_day_of_year(_value(args[1])))
    elseif name == "datetime.julian_day"
        _expect_arity(name, args, 1)
        return _datetime_julian_day(Float64(args[1]))::Float64
    elseif name == "datetime.is_leap_year"
        _expect_arity(name, args, 1)
        return _cal_i32(name, _cal_is_leap_year(_value(args[1])))
    elseif name == "interp.searchsorted"
        _expect_arity(name, args, 2)
        return _interp_searchsorted(name, args[1], args[2])
    elseif name == "interp.linear"
        _expect_arity(name, args, 3)
        return _interp_linear(name, args[1], args[2], Float64(args[3]))::Float64
    elseif name == "interp.bilinear"
        _expect_arity(name, args, 5)
        return _interp_bilinear(name, args[1], args[2], args[3],
                                Float64(args[4]), Float64(args[5]))::Float64
    end
    # Should be unreachable — `name in _CLOSED_FUNCTION_NAMES` covered above.
    throw(ClosedFunctionError("unknown_closed_function",
        "internal: `fn` name `$(name)` is in the registry but has no dispatch arm"))
end

"""
    evaluate_closed_function_ad(name::String, args::AbstractVector) -> Any

The eltype-generic twin of [`evaluate_closed_function`](@ref), for callers whose
argument values may be AD dual numbers (`ForwardDiff.Dual`). Same registry, same
diagnostics, same values — it only drops the `Float64` pinning.

WHY THIS IS A SEPARATE FUNCTION, and not just a relaxed `evaluate_closed_function`:
`evaluate_closed_function` must infer as the CONCRETE `Union{Float64,Int32}`. It
is called from the `:fn` arm of the tree-walk's `_eval_node_op`, and Julia infers
that function's return type as the union over ALL of its arms — so if this
registry widened to `Any`, the `:fn` arm would drag `_eval_node_op` (and with it
the whole recursive RHS walk) down to `Any` and cost EVERY model — even ones with
no `fn` node at all — its zero-allocation property. Pinning the float-returning
arms to `::Float64` is what holds that line, and a dual cannot survive the pin.

So the split is deliberate: the `Float64` solve path keeps the pinned registry and
its inference, and the AD path — which is already boxing duals anyway — takes this
one. Callers select between them on the COMPILE-TIME value type (`T === Float64`),
so the branch folds away and the `Float64` path never even compiles this call.

Beyond the three float-returning functions, the CALENDAR fields are handled
here too — not because a `Dual` needs it (the pinned registry takes its primal
and returns `Int32` quite happily) but because a value type that cannot reach
`Float64` at all has no `Int32` to be given. A traced number is exactly that,
and returning the argument's own type is what keeps the decomposition inside
the traced program. `interp.searchsorted` still falls through: its `Int32`
index is a build-time table position, not a value the traced program computes.
"""
function evaluate_closed_function_ad(name::String, args::AbstractVector)
    if name == "datetime.julian_day"
        _expect_arity(name, args, 1)
        return _datetime_julian_day(args[1])
    elseif name == "interp.linear"
        _expect_arity(name, args, 3)
        return _interp_linear(name, args[1], args[2], args[3])
    elseif name == "interp.bilinear"
        _expect_arity(name, args, 5)
        return _interp_bilinear(name, args[1], args[2], args[3], args[4], args[5])
    # ---- Calendar fields ----
    # These used to fall through to the pinned registry, which was correct for
    # a `Dual` (whose primal `_value` recovers) and a wall for anything a host
    # `Float64` cannot represent — a traced value, where `Int32(...)` has no
    # answer to give. `_cal_narrow` keeps the OLD behavior wherever the old
    # behavior was possible and only widens where it was not, so a `Dual`
    # query still returns exactly the `Int32` the `Float64` path returns
    # (pinned by `closed_functions_autodiff_test.jl`) and a traced query
    # returns a traced number, keeping the decomposition inside the program.
    #
    # `_value` is the identity on a traced number and the primal of a `Dual`,
    # so a differentiating walk still gets the exact a.e. derivative (zero —
    # these are piecewise constant) rather than partials leaking through the
    # floor divisions.
    elseif name == "datetime.year"
        _expect_arity(name, args, 1); return _cal_narrow(name, _cal_year(_value(args[1])))
    elseif name == "datetime.month"
        _expect_arity(name, args, 1); return _cal_narrow(name, _cal_month(_value(args[1])))
    elseif name == "datetime.day"
        _expect_arity(name, args, 1); return _cal_narrow(name, _cal_day(_value(args[1])))
    elseif name == "datetime.hour"
        _expect_arity(name, args, 1); return _cal_narrow(name, _cal_hour(_value(args[1])))
    elseif name == "datetime.minute"
        _expect_arity(name, args, 1); return _cal_narrow(name, _cal_minute(_value(args[1])))
    elseif name == "datetime.second"
        _expect_arity(name, args, 1); return _cal_narrow(name, _cal_second(_value(args[1])))
    elseif name == "datetime.day_of_year"
        _expect_arity(name, args, 1); return _cal_narrow(name, _cal_day_of_year(_value(args[1])))
    elseif name == "datetime.is_leap_year"
        _expect_arity(name, args, 1); return _cal_narrow(name, _cal_is_leap_year(_value(args[1])))
    end
    # Discrete-valued or already-generic: the pinned registry handles duals.
    return evaluate_closed_function(name, args)
end

# Select the registry on the evaluator's COMPILE-TIME value type. At `T ===
# Float64` this folds to the pinned `evaluate_closed_function` and the AD arm is
# dead-code-eliminated, so the numeric RHS keeps main's inference and its
# zero-allocation property exactly; at a dual `T` it folds to the generic twin.
@inline function _eval_closed_fn(name::String, args::AbstractVector, ::Type{T}) where {T}
    return T === Float64 ? evaluate_closed_function(name, args) :
                           evaluate_closed_function_ad(name, args)
end

# ========================================================================
# Branch-free proleptic-Gregorian calendar  (ess-traced-datetime)
# ========================================================================
#
# WHY THIS EXISTS. The calendar used to be `unix2datetime(Float64(_value(t)))`
# followed by `Dates.year`/`month`/… — an OPAQUE HOST CALL, and a wall for any
# evaluator whose value type is not a host real:
#
#   1. `Float64(x)` demands a concrete bit pattern NOW. Under an XLA trace
#      (Reactant) `t` is a symbolic handle to a value that will not exist
#      until the compiled program runs, and there is no method — nor any
#      possible answer — for `Float64(::TracedRNumber{Float64})`.
#   2. `DateTime` is a host struct. A tracer records operations on tensors;
#      it cannot record "construct a Julia object".
#   3. `Dates.month` walks a cumulative-length table and `isleapyear` branches
#      on `y % 4 / % 100 / % 400`. A trace cannot TAKE a branch whose
#      condition is a traced value — the same wall `_oop_index_int` (oop.jl)
#      exists to keep subscript arithmetic away from.
#
# So the calendar is re-derived here as ARITHMETIC. Nothing about it is
# approximate: the proleptic-Gregorian calendar is a closed-form function of
# the day number, and Howard Hinnant's `civil_from_days` computes it with no
# branch and no table — the exact inverse of the Fliegel–van Flandern formula
# `_datetime_julian_day` already runs in the forward direction below. Every
# step is `+ - * /`, `floor`, a comparison and a `select`, all of which the
# `:oop` runners already lower (`ifelse` is a VALUE-level select — both arms
# are computed and the condition picks one — not control flow, which is
# precisely why `interp.searchsorted` traces today; see `_oop_interp_
# searchsorted`).
#
# THIS IS THE ONLY IMPLEMENTATION. It replaces the `Dates` path for EVERY
# value type rather than sitting beside it as a traced-only twin, because two
# implementations of one calendar is two calendars — they drift, and the drift
# surfaces as an `:oop`-vs-`:inplace` mismatch in a model, not as a test
# failure here. `test/datetime_arithmetic_test.jl` pins agreement with `Dates`
# EXHAUSTIVELY: every day from 1600-01-01 to 2400-01-01 (292,000 days), every
# second of four representative days, and the millisecond-rounding boundaries.
#
# MILLISECOND RESOLUTION IS PART OF THE CONTRACT, not an implementation
# detail. `Dates.unix2datetime(x)` is `DateTime(UTM(UNIXEPOCH + trunc(Int64,
# 1000x)))`, so the sub-millisecond remainder of `t` is DISCARDED, and working
# in whole milliseconds from the start is what reproduces that. Decomposing
# `t` directly in seconds disagrees at every sub-millisecond boundary — caught
# by the ms-boundary phase of the test, which is the only phase that can see
# it (an exact-integer `t` truncates and rounds alike).
#
# `trunc`, NOT `round`, and the distinction is load-bearing: at
# `t = …59.9995 s` rounding lands on the next second and truncation stays put,
# and `Dates` stays put. Note this makes the cut asymmetric about the epoch —
# truncation goes toward ZERO, so a sub-second time in 1969 moves forward
# while one in 1971 moves back. That is `Dates`' behavior, faithfully copied,
# not a choice made here.

# Floor division. PRECONDITION: `a` and `b` are exact integers in the value
# type and `b > 0` — true of every call in this section.
#
# The whole decomposition rests on `floor(a/b)` being the exact integer floor,
# so the argument is worth writing down. If `b` divides `a`, IEEE division
# returns the quotient exactly and `floor` is a no-op. Otherwise the true
# quotient is `k ± s/b` for integers `k`, `s ≥ 1`, so it misses an integer by
# at least `1/b`, while the division's own error is at most half an ulp of
# `q = a/b`, i.e. `q·2⁻⁵³`. Flooring is therefore safe whenever
# `q·2⁻⁵³ < 1/b` — that is, whenever `q·b = a` stays under `2⁵³`, which is the
# SAME condition as `a` being an exact integer in the first place. No separate
# magnitude bound to track: if the inputs are exact, the quotient is right.
@inline _cdiv(a, b) = floor(a / b)

# Truncation toward zero, spelled with the two primitives the traced backends
# already lower. `Base.trunc` would do on the host but is a third op to demand
# of a backend for no gain, and `floor` + a select is exactly the pair the rest
# of this section is built from.
@inline _ctrunc(x) = ifelse(x < 0, -floor(-x), floor(x))

# Days since 1970-01-01 and milliseconds-of-day, from a UTC second count.
#
# `ms` is an exact integer — the precondition `_cdiv` needs — for every
# `|t| < 9e12 s`, about ±285,000 years around the epoch. Past that the ms
# count leaves Float64's exact-integer range and the fields stop being
# meaningful; on the `Float64` path `_cal_i32` then rejects them as
# non-Int32. That is the same place the old `Dates` path gave up (an
# `InexactError` from inside `trunc(Int64, ·)`), so the domain has not
# narrowed — but note it IS a throw, and the TOTALITY CONTRACT at the top of
# this file scopes the calendar to finite in-range inputs for that reason.
@inline function _cal_split(t_utc)
    ms = _ctrunc(1000 * t_utc)
    days = _cdiv(ms, 86400000)
    return days, ms - days * 86400000
end

# (year, month, day) from days since the Unix epoch — Hinnant's
# `civil_from_days`, shifted to an era beginning 0000-03-01 so that the leap
# day lands at the END of a 400-year era and needs no special case.
@inline function _civil_from_days(days)
    z = days + 719468
    era = _cdiv(z, 146097)                       # 400-year era
    doe = z - era * 146097                       # day-of-era, 0..146096
    yoe = _cdiv(doe - _cdiv(doe, 1460) + _cdiv(doe, 36524) -
                _cdiv(doe, 146096), 365)         # year-of-era, 0..399
    doy = doe - (365 * yoe + _cdiv(yoe, 4) - _cdiv(yoe, 100))  # days since Mar 1
    mp = _cdiv(5 * doy + 2, 153)                 # month index, Mar = 0 .. Feb = 11
    d = doy - _cdiv(153 * mp + 2, 5) + 1
    m = mp + ifelse(mp < 10, oftype(mp, 3), oftype(mp, -9))    # shift Mar-based → Jan-based
    y = yoe + era * 400 + ifelse(m <= 2, oftype(mp, 1), oftype(mp, 0))
    return y, m, d
end

# Days since the Unix epoch from a civil date — the exact inverse of
# `_civil_from_days`, used only to locate Jan 1 for `day_of_year`.
@inline function _days_from_civil(y, m, d)
    yy = y - ifelse(m <= 2, oftype(y, 1), oftype(y, 0))
    era = _cdiv(yy, 400)
    yoe = yy - era * 400
    mp = m + ifelse(m > 2, oftype(m, -3), oftype(m, 9))
    doy = _cdiv(153 * mp + 2, 5) + d - 1
    doe = yoe * 365 + _cdiv(yoe, 4) - _cdiv(yoe, 100) + doy
    return era * 146097 + doe - 719468
end

# The nine `datetime.*` fields, each on the value's own type. Callers take one
# field; the unused arithmetic is dead code that LLVM drops on the host path
# and XLA's DCE drops in the traced program, so computing (y, m, d) together
# costs nothing at either end.
@inline _cal_year(t)   = _civil_from_days(_cal_split(t)[1])[1]
@inline _cal_month(t)  = _civil_from_days(_cal_split(t)[1])[2]
@inline _cal_day(t)    = _civil_from_days(_cal_split(t)[1])[3]

@inline function _cal_day_of_year(t)
    days = _cal_split(t)[1]
    y, _, _ = _civil_from_days(days)
    return days - _days_from_civil(y, oftype(y, 1), oftype(y, 1)) + 1
end

@inline function _cal_is_leap_year(t)
    y = _cal_year(t)
    # (y%4 == 0) && (y%100 != 0 || y%400 == 0), spelled as selects.
    r4 = y - 4 * _cdiv(y, 4)
    r100 = y - 100 * _cdiv(y, 100)
    r400 = y - 400 * _cdiv(y, 400)
    one_ = oftype(y, 1)
    zero_ = oftype(y, 0)
    century_ok = ifelse(r100 == 0, ifelse(r400 == 0, one_, zero_), one_)
    return ifelse(r4 == 0, century_ok, zero_)
end

@inline function _cal_hour(t)
    msod = _cal_split(t)[2]
    return _cdiv(msod, 3600000)
end

@inline function _cal_minute(t)
    msod = _cal_split(t)[2]
    return _cdiv(msod - _cdiv(msod, 3600000) * 3600000, 60000)
end

@inline function _cal_second(t)
    msod = _cal_split(t)[2]
    rem_min = msod - _cdiv(msod, 60000) * 60000
    return _cdiv(rem_min, 1000)
end

# Fliegel–van Flandern (1968) integer JDN, plus fractional-day offset from
# noon-UTC. Returns Float64 with ≤ 1 ulp agreement to the spec reference
# computation — the only floating-point operation is the final divide by
# 86400 (one rounded operation).
#
# UNLIKE the rest of `datetime.*`, this one is genuinely CONTINUOUS in `t_utc`
# (d(julian_day)/d(t_utc) = 1/86400 a.e.), so the query is `Real` and the
# fractional-day arithmetic stays eltype-generic: hand it a `Dual` and the real
# derivative comes back out. This is load-bearing for stiff solvers — a
# Rosenbrock method needs ∂f/∂t, and in models whose photolysis rates are driven
# by solar geometry that path runs through `julian_day`. Only the DISCRETE
# integer JDN is taken off the primal (`_value`), which is exactly right: the
# day-number is piecewise constant, so it contributes no derivative.
#
# `mod(t_utc, 86400.0)` is left generic rather than split into
# `t - 86400*floor(t/86400)`: ForwardDiff differentiates `mod` directly, and on a
# `Float64` query this is bit-for-bit the same call as before (`_value` is the
# identity), preserving the spec's pinned ≤1 ulp / cross-binding contract.
#
# The (y, m, d) decomposition comes from the branch-free calendar above rather
# than from `Dates`, so this traces like everything else — which matters more
# here than for the discrete fields, because a Rosenbrock ∂f/∂t through solar
# geometry runs straight down this path.
#
# `÷` BECAME `_cdiv` ONLY WHERE THAT IS THE SAME OPERATION. Julia's integer `÷`
# truncates toward zero; `_cdiv` floors. The two agree exactly when the
# numerator is non-negative, which holds for all three of the divisions kept
# below (the `1461·(…)`, `367·(…)` and `3·(…)/100` terms are positive for every
# year > -4800, the same implicit domain the Fliegel–van Flandern form always
# carried). The ONE place they differ is `(m - 14) ÷ 12`, whose numerator runs
# -13..-2: truncation gives -1 for every month, flooring would give -2 at
# January. That term is written as the select it actually is.
function _datetime_julian_day(t_utc)
    y, m, d = _civil_from_days(_cal_split(_value(t_utc))[1])
    a = ifelse(m <= 2, oftype(m, -1), oftype(m, 0))   # == (m - 14) ÷ 12, truncated
    jdn = _cdiv(1461 * (y + 4800 + a), 4) +
          _cdiv(367 * (m - 2 - 12 * a), 12) -
          _cdiv(3 * _cdiv(y + 4900 + a, 100), 4) +
          d - 32075
    # JDN counts noon-to-noon; convert time-of-day seconds (since 00:00 UTC)
    # to a fractional offset relative to noon. The spec pins this offset as
    # `(time_of_day_seconds − 43200) / 86400` (esm-spec §9.2.1).
    seconds_in_day = mod(t_utc, 86400.0)
    # `jdn` is already a value of the argument's own type — the branch-free
    # decomposition never leaves it. The `Float64(jdn)` that stood here was
    # narrowing an `Int` returned by `Dates`, and on a traced value it is the
    # same wall as `_to_datetime`'s.
    return jdn + (seconds_in_day - 43200.0) / 86400.0
end

# Validate an `interp.searchsorted` table `xs`: must be a vector, non-decreasing,
# with no NaN entries (esm-spec §9.2.2). Factored out of the per-call kernel so
# the vectorized array path can validate ONCE at build time instead of re-walking
# the build-time-constant table every lane (ess-wrh).
function _validate_searchsorted_table(name::String, xs)::Nothing
    if !(xs isa AbstractVector)
        throw(ClosedFunctionError("closed_function_arity",
            "$(name): xs argument must be an array (got $(typeof(xs)))"))
    end
    prev = NaN
    for (i, raw) in enumerate(xs)
        v = Float64(raw)
        if isnan(v)
            throw(ClosedFunctionError("searchsorted_nan_in_table",
                "$(name): xs[$(i)] is NaN; NaN entries in xs are forbidden"))
        end
        if i > 1 && v < prev
            throw(ClosedFunctionError("searchsorted_non_monotonic",
                "$(name): xs is not non-decreasing (xs[$(i)]=$(v) < xs[$(i-1)]=$(prev))"))
        end
        prev = v
    end
    return nothing
end

# Validation-free `interp.searchsorted` kernel: 1-based, left-side bias (smallest
# `i` with `xs[i] ≥ x`), out-of-range below → 1, above → N+1, NaN x → N+1, empty
# table → 1. Precondition: `xs` is a validated non-decreasing NaN-free vector (see
# `_validate_searchsorted_table`). Shared verbatim by the scalar
# `evaluate_closed_function` path and the vectorized array kernel
# (`_eval_vec_interp_searchsorted`), so the two are bit-identical by construction
# (ess-wrh).
@inline function _interp_searchsorted_core(name::String, x::Real, xs)::Int32
    n = length(xs)
    # An empty table has no valid index; return 1 per the "above-range → N+1"
    # rule extended to N=0 (the only consistent extension that composes with
    # `index`).
    n == 0 && return Int32(1)
    # NaN x → N+1 (treated as "greater than every finite element").
    isnan(x) && return _check_int32(name, n + 1)
    # Linear scan for the smallest 1-based index with xs[i] ≥ x. The spec
    # mandates left-side bias on duplicates; binary search would also work
    # but linear is O(N) on table sizes that the §9.2 inline-cap pins
    # to ≤ 1024 entries.
    @inbounds for i in 1:n
        if Float64(xs[i]) >= x
            return _check_int32(name, i)
        end
    end
    return _check_int32(name, n + 1)
end

# `interp.searchsorted` per esm-spec §9.2.2 — validate the table, then run the
# kernel. Behaviour is byte-identical to the pre-`ess-wrh` monolithic form.
#
# The query is `Real` so an AD dual flows in unchanged: the kernel only ever
# COMPARES it (`isnan`, `>=`), which `Dual` supports, and the result is a
# discrete `Int32` index that carries no derivative — so nothing needs stripping
# here and the search runs on the dual directly.
function _interp_searchsorted(name::String, x::Real, xs)::Int32
    _validate_searchsorted_table(name, xs)
    return _interp_searchsorted_core(name, x, xs)
end

# Validate a 1-D axis used by `interp.linear` / `interp.bilinear`. Per
# esm-spec §9.2: strictly increasing, no NaN, length ≥ 2. Returns the axis
# coerced to `Vector{Float64}` for downstream blending. `axis_label` names
# the failing axis ("axis", "axis_x", "axis_y") for the diagnostic.
function _validate_interp_axis(name::String, axis_raw, axis_label::String)::Vector{Float64}
    if !(axis_raw isa AbstractVector)
        throw(ClosedFunctionError("closed_function_arity",
            "$(name): `$(axis_label)` must be an array (got $(typeof(axis_raw)))"))
    end
    n = length(axis_raw)
    if n < 2
        throw(ClosedFunctionError("interp_axis_too_short",
            "$(name): `$(axis_label)` has $(n) entries; need ≥ 2 to define a blend interval."))
    end
    out = Vector{Float64}(undef, n)
    @inbounds for i in 1:n
        v = Float64(axis_raw[i])
        if isnan(v)
            throw(ClosedFunctionError("interp_nan_in_axis",
                "$(name): `$(axis_label)`[$(i)] is NaN; axis arrays must be all-finite."))
        end
        if i > 1 && !(v > out[i-1])
            throw(ClosedFunctionError("interp_non_monotonic_axis",
                "$(name): `$(axis_label)` is not strictly increasing " *
                "(`$(axis_label)`[$(i)] = $(v) is not > `$(axis_label)`[$(i-1)] = $(out[i-1]))."))
        end
        out[i] = v
    end
    return out
end

# Validation-free `interp.linear` kernel: extrapolate-flat clamps + pinned
# evaluation order `t[i] + w * (t[i+1] - t[i])` for endpoint exactness. `axis`
# must be a validated strictly-increasing `Vector{Float64}` (≥ 2 entries) and
# `len(table) == len(axis)`. `table` is read with an inline `Float64(...)` so the
# scalar path may pass the raw const array while the vectorized path passes a
# build-time-coerced `Vector{Float64}` (the coercion is then a no-op). Shared by
# the scalar `:fn` arm and `_eval_vec_interp_linear` → bit-identical (ess-wrh).
#
# The query is `Real`, not `Float64`, so a ForwardDiff `Dual` flows through: the
# out-of-place RHS (tree_walk/oop.jl) differentiates models whose rate/emission
# tables are interpolated on a state or on `t`. The flat-extrapolation clamps
# return the `Float64` table entry, which is exactly right — outside the table the
# derivative w.r.t. the query IS zero. The `table`/`axis` reads stay `Float64`
# (they are data, never differentiated), so a `Float64` query specializes to the
# identical code the annotated form compiled to.
@inline function _interp_linear_core(table, axis, x::Real)
    n = length(axis)
    @inbounds begin
        # Extrapolate-flat clamps. NaN x bypasses both clamps (IEEE-754 ≤/≥ on
        # NaN are false) and falls through to the in-cell blend, where
        # (x - axis[i]) is NaN and propagates through the result — per the spec.
        if x <= axis[1]
            return Float64(table[1])
        elseif x >= axis[n]
            return Float64(table[n])
        end
        # In-range: locate i with axis[i] ≤ x < axis[i+1]. n ≥ 2 guaranteed by
        # `_validate_interp_axis`. Linear scan; tables are §9.2-capped at the
        # const-op inline limit, so this is O(N) on small N.
        i = 1
        for k in 1:(n - 1)
            if axis[k] <= x < axis[k + 1]
                i = k
                break
            end
        end
        ai   = axis[i];     ai1   = axis[i + 1]
        ti   = Float64(table[i]);    ti1 = Float64(table[i + 1])
        # The blend weight carries the query's partials — this is where the
        # derivative of a piecewise-linear table comes from, and it is exact:
        # d/dx [ti + w*(ti1 - ti)] = (ti1 - ti)/(ai1 - ai), the cell's slope.
        w    = (x - ai) / (ai1 - ai)
        return ti + w * (ti1 - ti)
    end
end

# `interp.linear` per esm-spec §9.2 — validate the axis/table, then run the
# kernel. Behaviour is byte-identical to the pre-`ess-wrh` monolithic form.
function _interp_linear(name::String, table_raw, axis_raw, x::Real)
    if !(table_raw isa AbstractVector)
        throw(ClosedFunctionError("closed_function_arity",
            "$(name): `table` must be an array (got $(typeof(table_raw)))"))
    end
    axis = _validate_interp_axis(name, axis_raw, "axis")
    if length(table_raw) != length(axis)
        throw(ClosedFunctionError("interp_axis_length_mismatch",
            "$(name): `len(table)` = $(length(table_raw)) but `len(axis)` = $(length(axis))."))
    end
    return _interp_linear_core(table_raw, axis, x)
end

# Validation-free `interp.bilinear` kernel: per-axis extrapolate-flat clamps,
# cell-location convention "largest i with x_i ≤ x_q", pinned evaluation order
# (two x-blends, one y-blend, each in `a + w*(b-a)` form). `axis_x`/`axis_y` must
# be validated strictly-increasing `Vector{Float64}`s and `table` an `Nx × Ny`
# nested vector (outer length Nx, each row length Ny). `table[i][j]` is read with
# an inline `Float64(...)`, so the scalar path may pass the raw nested const array
# while the vectorized path passes a build-time-coerced `Vector{Vector{Float64}}`
# (no-op coercion). Shared by the scalar `:fn` arm and `_eval_vec_interp_bilinear`
# → bit-identical (ess-wrh).
@inline function _interp_bilinear_core(table, axis_x, axis_y,
                                       x::Real, y::Real)
    Nx = length(axis_x)
    Ny = length(axis_y)
    # Per-axis extrapolate-flat clamp. NaN x or y propagates through (IEEE-754
    # ≤/≥ on NaN are false → x_q stays NaN → wx is NaN → result is NaN).
    # A clamped arm yields the bare `Float64` axis endpoint even at a dual query
    # — correct, and NOT a lost derivative: flat extrapolation has zero slope out
    # there, which is exactly what a `Float64` contributes downstream.
    x_q = x <= axis_x[1] ? axis_x[1] :
          x >= axis_x[Nx] ? axis_x[Nx] : x
    y_q = y <= axis_y[1] ? axis_y[1] :
          y >= axis_y[Ny] ? axis_y[Ny] : y
    # Cell location: largest i in [1, Nx-1] with axis_x[i] ≤ x_q (analog j).
    # Default to last cell so the corner-at-max case (wx = 1) lands correctly
    # in the pinned-form blend. NaN x_q falls through with i = Nx-1 (irrelevant
    # because the blend will be NaN anyway).
    i = Nx - 1
    @inbounds for k in (Nx - 1):-1:1
        if axis_x[k] <= x_q
            i = k
            break
        end
    end
    j = Ny - 1
    @inbounds for k in (Ny - 1):-1:1
        if axis_y[k] <= y_q
            j = k
            break
        end
    end
    @inbounds begin
        xi   = axis_x[i];   xip1 = axis_x[i + 1]
        yj   = axis_y[j];   yjp1 = axis_y[j + 1]
        wx = (x_q - xi) / (xip1 - xi)
        wy = (y_q - yj) / (yjp1 - yj)
        # Two 1-D x-blends, then one y-blend. Pinned form `a + w*(b - a)`
        # required for cross-binding bit-equivalence (esm-spec §9.2).
        t_ij     = Float64(table[i][j])
        t_i1j    = Float64(table[i + 1][j])
        t_ijp1   = Float64(table[i][j + 1])
        t_i1jp1  = Float64(table[i + 1][j + 1])
        row_j   = t_ij    + wx * (t_i1j   - t_ij)
        row_jp1 = t_ijp1  + wx * (t_i1jp1 - t_ijp1)
        return row_j + wy * (row_jp1 - row_j)
    end
end

# `interp.bilinear` per esm-spec §9.2 — validate the axes/table, then run the
# kernel. Behaviour is byte-identical to the pre-`ess-wrh` monolithic form.
function _interp_bilinear(name::String, table_raw, axis_x_raw, axis_y_raw,
                          x::Real, y::Real)
    if !(table_raw isa AbstractVector)
        throw(ClosedFunctionError("closed_function_arity",
            "$(name): `table` must be an array (got $(typeof(table_raw)))"))
    end
    axis_x = _validate_interp_axis(name, axis_x_raw, "axis_x")
    axis_y = _validate_interp_axis(name, axis_y_raw, "axis_y")
    Nx = length(axis_x)
    Ny = length(axis_y)
    if length(table_raw) != Nx
        throw(ClosedFunctionError("interp_axis_length_mismatch",
            "$(name): outer `len(table)` = $(length(table_raw)) but `len(axis_x)` = $(Nx)."))
    end
    # Validate every inner row length matches Ny (rejects ragged tables).
    @inbounds for i in 1:Nx
        row = table_raw[i]
        if !(row isa AbstractVector)
            throw(ClosedFunctionError("closed_function_arity",
                "$(name): `table[$(i)]` must be an array (got $(typeof(row)))"))
        end
        if length(row) != Ny
            throw(ClosedFunctionError("interp_axis_length_mismatch",
                "$(name): `len(table[$(i)])` = $(length(row)) but `len(axis_y)` = $(Ny)."))
        end
    end
    return _interp_bilinear_core(table_raw, axis_x, axis_y, x, y)
end

# ============================================================
# Build-time-validated typed carriers for the vectorized array path (ess-wrh)
# ============================================================
#
# A vectorized `arrayop` whose body contains an `interp.*` leaf evaluates that
# leaf once per cell (lane). Re-validating the build-time-constant table/axis and
# re-coercing them to `Vector{Float64}` on every lane — and boxing the scalar
# query into the `AbstractVector{Any}` that `evaluate_closed_function` consumes —
# is pure overhead. These specs do that work ONCE at build time: validate (reusing
# the same checks, hence the same diagnostic codes, as the scalar path) and coerce
# to concrete `Vector{Float64}` storage. `_eval_vec_fn` then calls the
# validation-free `_interp_*_core` kernels per lane with a typed `Float64` query —
# no per-lane box, no per-lane validation, bit-identical to the scalar `:fn` arm
# (same callee). The validation throw simply moves to build time (fail-fast); the
# conformance error fixtures call `evaluate_closed_function` directly and are
# unaffected.
struct _InterpLinearSpec
    table::Vector{Float64}
    axis::Vector{Float64}
end
struct _InterpBilinearSpec
    table::Vector{Vector{Float64}}
    axis_x::Vector{Float64}
    axis_y::Vector{Float64}
end
struct _InterpSearchsortedSpec
    xs::Vector{Float64}
end

# Coerce a const-op array (statically `Any`-typed) to a concrete `Vector{Float64}`
# for build-time storage. `Float64∘Float64` is idempotent and `Int→Float64→Float64`
# equals the direct conversion, so this is bit-identical to the per-lane
# `Float64(raw[i])` the scalar kernel would do.
function _coerce_f64_vec(name::String, v, label::String)::Vector{Float64}
    if !(v isa AbstractVector)
        throw(ClosedFunctionError("closed_function_arity",
            "$(name): `$(label)` must be an array (got $(typeof(v)))"))
    end
    out = Vector{Float64}(undef, length(v))
    @inbounds for i in eachindex(v)
        out[i] = Float64(v[i])
    end
    return out
end

function _build_interp_linear_spec(name::String, table_raw, axis_raw)::_InterpLinearSpec
    table = _coerce_f64_vec(name, table_raw, "table")
    axis  = _validate_interp_axis(name, axis_raw, "axis")
    if length(table) != length(axis)
        throw(ClosedFunctionError("interp_axis_length_mismatch",
            "$(name): `len(table)` = $(length(table)) but `len(axis)` = $(length(axis))."))
    end
    return _InterpLinearSpec(table, axis)
end

function _build_interp_bilinear_spec(name::String, table_raw, axis_x_raw,
                                     axis_y_raw)::_InterpBilinearSpec
    if !(table_raw isa AbstractVector)
        throw(ClosedFunctionError("closed_function_arity",
            "$(name): `table` must be an array (got $(typeof(table_raw)))"))
    end
    axis_x = _validate_interp_axis(name, axis_x_raw, "axis_x")
    axis_y = _validate_interp_axis(name, axis_y_raw, "axis_y")
    Nx = length(axis_x)
    Ny = length(axis_y)
    if length(table_raw) != Nx
        throw(ClosedFunctionError("interp_axis_length_mismatch",
            "$(name): outer `len(table)` = $(length(table_raw)) but `len(axis_x)` = $(Nx)."))
    end
    table = Vector{Vector{Float64}}(undef, Nx)
    @inbounds for i in 1:Nx
        row = table_raw[i]
        if !(row isa AbstractVector)
            throw(ClosedFunctionError("closed_function_arity",
                "$(name): `table[$(i)]` must be an array (got $(typeof(row)))"))
        end
        if length(row) != Ny
            throw(ClosedFunctionError("interp_axis_length_mismatch",
                "$(name): `len(table[$(i)])` = $(length(row)) but `len(axis_y)` = $(Ny)."))
        end
        col = Vector{Float64}(undef, Ny)
        for j in 1:Ny
            col[j] = Float64(row[j])
        end
        table[i] = col
    end
    return _InterpBilinearSpec(table, axis_x, axis_y)
end

function _build_interp_searchsorted_spec(name::String, xs_raw)::_InterpSearchsortedSpec
    _validate_searchsorted_table(name, xs_raw)
    return _InterpSearchsortedSpec(_coerce_f64_vec(name, xs_raw, "xs"))
end

# ---- Per-LANE interp specs (kernel-class merge; tree_walk/oop_merge.jl) -----
#
# A merged kernel CLASS whose member kernels call the same `interp.*` function
# with DIFFERENT (but same-shape) build-time const tables cannot carry ONE
# scalar spec — evaluating every lane against the representative's table would
# be the silent wrong numbers `_check_fn_group_specs` exists to prevent. The
# class merge instead tables the SPECS per lane, exactly as it tables varying
# state slots / consts / forcing indices (`_AccStateTblBox` / `_AccConstBox`):
#   * `specs[lane]` is the member's ORIGINAL spec object for that lane. The
#     scalar walker and the lane tape evaluate lane `l` by calling the SAME
#     `_interp_*_core` kernel on `specs[lane]`'s own table/axis, so per-lane
#     results are bit-identical to the unmerged kernels by construction.
#   * `*_cols` is the knot-major transpose (`col[k][lane] == specs[lane].…[k]`)
#     the :oop lane evaluator broadcasts over: `_oop_interp_*_lanes` runs the
#     IDENTICAL locate/select/blend op sequence with each scalar knot replaced
#     by its length-L lane column, so lane `l` sees exactly its own knots.
#   * `s1..off` mirror the `_AccStateTblBox` box lane addressing
#     (lane = off + (midx₁-1)s1 + (midx₂-1)s2 + (midx₃-1)s3; the merge mints
#     `(1,0,0,1)` with `_outs_cells`, i.e. lane == the merged cell ordinal).
# Every member spec of one node shares one shape (knot count): the merge
# signature keys the shape and `_oop_merge_fn_payload` re-verifies it loudly.
struct _InterpLinearLaneSpec
    specs::Vector{_InterpLinearSpec}
    table_cols::Vector{Vector{Float64}}
    axis_cols::Vector{Vector{Float64}}
    s1::Int; s2::Int; s3::Int; off::Int
end
function _InterpLinearLaneSpec(specs::Vector{_InterpLinearSpec},
                               s1::Int, s2::Int, s3::Int, off::Int)
    L = length(specs); n = length(specs[1].axis)
    table_cols = Vector{Vector{Float64}}(undef, n)
    axis_cols  = Vector{Vector{Float64}}(undef, n)
    for k in 1:n
        table_cols[k] = Float64[specs[l].table[k] for l in 1:L]
        axis_cols[k]  = Float64[specs[l].axis[k]  for l in 1:L]
    end
    return _InterpLinearLaneSpec(specs, table_cols, axis_cols, s1, s2, s3, off)
end

struct _InterpBilinearLaneSpec
    specs::Vector{_InterpBilinearSpec}
    table_cols::Matrix{Vector{Float64}}    # Nx×Ny; table_cols[i,j][lane]
    axis_x_cols::Vector{Vector{Float64}}
    axis_y_cols::Vector{Vector{Float64}}
    s1::Int; s2::Int; s3::Int; off::Int
end
function _InterpBilinearLaneSpec(specs::Vector{_InterpBilinearSpec},
                                 s1::Int, s2::Int, s3::Int, off::Int)
    L = length(specs)
    Nx = length(specs[1].axis_x); Ny = length(specs[1].axis_y)
    table_cols = Matrix{Vector{Float64}}(undef, Nx, Ny)
    for i in 1:Nx, j in 1:Ny
        table_cols[i, j] = Float64[specs[l].table[i][j] for l in 1:L]
    end
    axis_x_cols = Vector{Vector{Float64}}(undef, Nx)
    for k in 1:Nx
        axis_x_cols[k] = Float64[specs[l].axis_x[k] for l in 1:L]
    end
    axis_y_cols = Vector{Vector{Float64}}(undef, Ny)
    for k in 1:Ny
        axis_y_cols[k] = Float64[specs[l].axis_y[k] for l in 1:L]
    end
    return _InterpBilinearLaneSpec(specs, table_cols, axis_x_cols, axis_y_cols,
                                   s1, s2, s3, off)
end

struct _InterpSearchsortedLaneSpec
    specs::Vector{_InterpSearchsortedSpec}
    xs_cols::Vector{Vector{Float64}}
    s1::Int; s2::Int; s3::Int; off::Int
end
function _InterpSearchsortedLaneSpec(specs::Vector{_InterpSearchsortedSpec},
                                     s1::Int, s2::Int, s3::Int, off::Int)
    L = length(specs); n = length(specs[1].xs)
    xs_cols = Vector{Vector{Float64}}(undef, n)
    for k in 1:n
        xs_cols[k] = Float64[specs[l].xs[k] for l in 1:L]
    end
    return _InterpSearchsortedLaneSpec(specs, xs_cols, s1, s2, s3, off)
end

# The lane a per-lane spec serves at cell multi-index `midx` — byte-for-byte
# the `_AccStateTblBox`/`_AccConstBox` box addressing in `_fetch`.
@inline _interp_lane(h, midx::NTuple{3,Int}) =
    h.off + (midx[1]-1)*h.s1 + (midx[2]-1)*h.s2 + (midx[3]-1)*h.s3

@inline function _expect_arity(name::String, args::AbstractVector, n::Int)
    length(args) == n ||
        throw(ClosedFunctionError("closed_function_arity",
            "$(name) expects $(n) argument(s), got $(length(args))"))
    return nothing
end

# ============================================================
# Enum lowering — esm-spec §9.3
# ============================================================

"""
    lower_enums!(file::EsmFile)

Walk every expression tree in `file` and replace each `enum` op with a
`const` integer per the file's `enums` block. After this pass runs, no
`enum`-op nodes remain in the in-memory representation.

Validation (esm-spec §9.3):
- An `enum` op naming an undeclared enum raises `ParseError("unknown_enum: ...")`.
- An `enum` op naming a symbol not declared under that enum raises
  `ParseError("unknown_enum_symbol: ...")`.
- A file with no `enums` block raises if any `enum` op is encountered.

Mutates `file` in place; returns the file for convenience.
"""
function lower_enums!(file::EsmFile)::EsmFile
    enums = file.enums === nothing ? Dict{String,Dict{String,Int}}() : file.enums
    if file.models !== nothing
        for (_, m) in file.models
            _lower_model_enums!(m, enums)
        end
    end
    if file.reaction_systems !== nothing
        for (_, rs) in file.reaction_systems
            _lower_reaction_system_enums!(rs, enums)
        end
    end
    if file.coupling !== nothing
        for ce in file.coupling
            _lower_coupling_entry_enums!(ce, enums)
        end
    end
    return file
end

function _lower_model_enums!(model::Model, enums::Dict{String,Dict{String,Int}})
    for (name, var) in model.variables
        if var.expression !== nothing
            # ModelVariable.expression is read-only after construction, so we
            # rebuild the dict entry with the lowered expression.
            lowered = _lower_expr_enums(var.expression, enums)
            if lowered !== var.expression
                _replace_var_expression!(model.variables, name, var, lowered)
            end
        end
    end
    new_eqs = Equation[]
    for eq in model.equations
        push!(new_eqs, Equation(_lower_expr_enums(eq.lhs, enums),
                                _lower_expr_enums(eq.rhs, enums);
                                _comment=eq._comment))
    end
    empty!(model.equations)
    append!(model.equations, new_eqs)

    new_init_eqs = Equation[]
    for eq in model.initialization_equations
        push!(new_init_eqs, Equation(_lower_expr_enums(eq.lhs, enums),
                                     _lower_expr_enums(eq.rhs, enums);
                                     _comment=eq._comment))
    end
    empty!(model.initialization_equations)
    append!(model.initialization_equations, new_init_eqs)

    for (_, sub) in model.subsystems
        # DataLoader / SubsystemRef subsystems carry no enums to lower.
        sub isa Model || continue
        _lower_model_enums!(sub, enums)
    end
end

function _replace_var_expression!(vars::Dict{String,ModelVariable}, name::String,
                                  var::ModelVariable, new_expr::ASTExpr)
    # ModelVariable is immutable; rebuild it with the new expression and
    # update the dictionary entry (`name` is the caller's iteration key;
    # assigning an existing key during iteration is safe — no rehash).
    vars[name] = ModelVariable(var.type;
        default=var.default, description=var.description,
        expression=new_expr, units=var.units, default_units=var.default_units,
        shape=var.shape, location=var.location,
        noise_kind=var.noise_kind, correlation_group=var.correlation_group)
end

function _lower_reaction_system_enums!(rs::ReactionSystem,
                                       enums::Dict{String,Dict{String,Int}})
    new_reactions = Reaction[]
    for r in rs.reactions
        # `raw_substrates`/`raw_products`: the ordered StoichiometryEntry
        # fields (`get_reactants_dict`/`get_products_dict` give the unordered
        # `Dict{String,Float64}` view instead).
        push!(new_reactions, Reaction(r.id,
            raw_substrates(r),
            raw_products(r),
            _lower_expr_enums(r.rate, enums);
            name=r.name,
            reference=r.reference))
    end
    empty!(rs.reactions)
    append!(rs.reactions, new_reactions)
    for (_, sub) in rs.subsystems
        _lower_reaction_system_enums!(sub, enums)
    end
end

function _lower_coupling_entry_enums!(ce::CouplingEntry,
                                      enums::Dict{String,Dict{String,Int}})
    if ce isa CouplingCouple && haskey(ce.connector, "equations")
        eqs = ce.connector["equations"]
        if eqs isa AbstractVector
            for (i, e) in enumerate(eqs)
                if e isa AbstractDict && haskey(e, "expression")
                    expr_obj = e["expression"]
                    if expr_obj isa ASTExpr
                        e["expression"] = _lower_expr_enums(expr_obj, enums)
                    end
                end
            end
        end
    end
end

# Recursive enum-op lowering. Returns a new tree only if a substitution
# occurred; otherwise returns the input unchanged so identity-based caching
# upstream still works.
function _lower_expr_enums(e::NumExpr, _) ; return e end
function _lower_expr_enums(e::IntExpr, _) ; return e end
function _lower_expr_enums(e::VarExpr, _) ; return e end

# Identity-memoized entry: enum lowering is a pure, context-free function of
# the node, so a subtree shared under many parents (template expansion stores
# the expanded AST as a shared DAG) is lowered ONCE and the shared result
# respliced — keeping this pass linear in UNIQUE nodes instead of exponential
# in paths, and preserving the sharing for downstream consumers (the
# build-time `IdDict` memo caches in tree_walk/compile.jl key on it).
function _lower_expr_enums(e::OpExpr,
                           enums::Dict{String,Dict{String,Int}})::ASTExpr
    return _lower_expr_enums(e, enums, IdDict{OpExpr,ASTExpr}())
end

_lower_expr_enums(e::ASTExpr, _, ::IdDict{OpExpr,ASTExpr}) = e

function _lower_expr_enums(e::OpExpr,
                           enums::Dict{String,Dict{String,Int}},
                           memo::IdDict{OpExpr,ASTExpr})::ASTExpr
    r = get(memo, e, nothing)
    r === nothing || return r
    res = _lower_expr_enums_uncached(e, enums, memo)
    memo[e] = res
    return res
end

function _lower_expr_enums_uncached(e::OpExpr,
                                    enums::Dict{String,Dict{String,Int}},
                                    memo::IdDict{OpExpr,ASTExpr})::ASTExpr
    if e.op == "enum"
        # esm-spec §4.5: args are exactly two strings — the enum name and the
        # symbolic key. Strings come through `parse_expression` as `VarExpr`,
        # so we read `.name` to recover them.
        if length(e.args) != 2
            throw(ParseError("`enum` op expects 2 args (enum_name, symbol_name), got $(length(e.args))"))
        end
        a1, a2 = e.args[1], e.args[2]
        enum_name = a1 isa VarExpr ? a1.name :
                    a1 isa OpExpr && a1.op == "const" && a1.value isa AbstractString ? String(a1.value) :
                    throw(ParseError("`enum` op: first arg must be a string"))
        symbol_name = a2 isa VarExpr ? a2.name :
                      a2 isa OpExpr && a2.op == "const" && a2.value isa AbstractString ? String(a2.value) :
                      throw(ParseError("`enum` op: second arg must be a string"))
        if !haskey(enums, enum_name)
            throw(ParseError("unknown_enum: enum `$(enum_name)` is not declared in the file's `enums` block"))
        end
        mapping = enums[enum_name]
        if !haskey(mapping, symbol_name)
            throw(ParseError("unknown_enum_symbol: symbol `$(symbol_name)` is not declared under enum `$(enum_name)`"))
        end
        return OpExpr("const", ASTExpr[]; value=mapping[symbol_name])
    end
    # Recurse into EVERY expression-bearing field via the shared field-preserving
    # rewrite (`map_children`), so an `enum` nested in an integral bound, a
    # filter/key predicate, a makearray value, a table axis, or a dense `ranges`
    # bound is also lowered — and no `OpExpr` field is silently dropped on the
    # rebuild (the previous hand-listed ~17-keyword `OpExpr(...)` reconstruction
    # dropped `int_var`/`semiring`/`join`/`filter`/`id`/… whenever any child
    # changed, and never recursed `lower`/`upper`/`filter`/`key`/`ranges`).
    return map_children(x -> _lower_expr_enums(x, enums, memo), e)
end
