# Branch-free proleptic-Gregorian calendar (ess-traced-datetime).
#
# `datetime.*` is computed by arithmetic — no `Dates.unix2datetime`, no
# `DateTime` object, no branch on the argument — so that it survives an XLA
# trace, where `Float64(::TracedRNumber)` has no answer and a data-dependent
# branch cannot be taken. See the calendar section of `registered_functions.jl`
# for why that shape is forced.
#
# THE POINT OF THIS FILE is that the rewrite is not an approximation. The
# registry has exactly ONE calendar implementation; `Dates` is the ORACLE it
# must reproduce EXACTLY, and "exactly" is checked over the whole domain the
# spec cares about rather than at a handful of sample dates:
#
#   * every day from 1600-01-01 to 2400-01-01 — 292,195 days × 8 fields,
#     which covers 800 years of leap rules including the 1700/1800/1900/2100
#     non-leap centuries and the 1600/2000/2400 leap centuries;
#   * every second of six chosen days (a leap day, a year end, a pre-epoch
#     day, a century-boundary day, and both Feb 28ths that precede a leap and
#     a non-leap March);
#   * the millisecond-truncation and sign boundaries, which are the ONLY place
#     a `trunc`-vs-`round` slip is visible — an exact-integer `t` truncates
#     and rounds alike, so a test built from whole seconds cannot see it. It
#     was a real bug during development, caught here.
#
# `julian_day` is pinned separately against the previous `Dates`-based
# Fliegel–van Flandern spelling, bitwise, because it is the one member of the
# family that is continuous in `t` and feeds a Rosenbrock ∂f/∂t.

using Test
using Dates
using EarthSciAST

const _DT_M = EarthSciAST

_dt_eval(name, t) = _DT_M.evaluate_closed_function(name, Any[t])

const _DT_FIELDS = ["datetime.year", "datetime.month", "datetime.day",
                    "datetime.hour", "datetime.minute", "datetime.second",
                    "datetime.day_of_year", "datetime.is_leap_year"]

# The oracle: Julia's `Dates`, reached exactly the way the registry used to.
function _dt_ref(name::String, t)
    dt = unix2datetime(t)
    name == "datetime.year"         && return Int32(year(dt))
    name == "datetime.month"        && return Int32(month(dt))
    name == "datetime.day"          && return Int32(day(dt))
    name == "datetime.hour"         && return Int32(hour(dt))
    name == "datetime.minute"       && return Int32(minute(dt))
    name == "datetime.second"       && return Int32(second(dt))
    name == "datetime.day_of_year"  && return Int32(dayofyear(dt))
    name == "datetime.is_leap_year" && return Int32(isleapyear(year(dt)))
    error("no oracle for $(name)")
end

# Count mismatches rather than asserting per sample: 2.3M `@test`s would drown
# the report, and a count of zero is the same claim.
function _dt_sweep(ts)
    bad = 0
    first_bad = nothing
    for t in ts, name in _DT_FIELDS
        got = _dt_eval(name, t)
        exp = _dt_ref(name, t)
        if got != exp
            bad += 1
            first_bad === nothing &&
                (first_bad = (name, t, got, exp, unix2datetime(t)))
        end
    end
    return bad, first_bad
end

# The previous implementation, verbatim: `Dates` for (y, m, d), then the
# Fliegel–van Flandern integer JDN and the pinned fractional-day offset.
function _dt_julian_ref(t)
    dt = unix2datetime(Float64(t))
    y = year(dt); m = month(dt); d = day(dt)
    jdn = (1461 * (y + 4800 + (m - 14) ÷ 12)) ÷ 4 +
          (367 * (m - 2 - 12 * ((m - 14) ÷ 12))) ÷ 12 -
          (3 * ((y + 4900 + (m - 14) ÷ 12) ÷ 100)) ÷ 4 +
          d - 32075
    return Float64(jdn) + (mod(t, 86400.0) - 43200.0) / 86400.0
end

@testset "datetime.* branch-free calendar == Dates (ess-traced-datetime)" begin

    @testset "every day, 1600-01-01 .. 2400-01-01" begin
        t0 = datetime2unix(DateTime(1600, 1, 1, 12, 34, 56))
        ndays = Dates.value(Date(2400, 1, 1) - Date(1600, 1, 1))
        bad, first_bad = _dt_sweep(t0 + 86400.0 * k for k in 0:ndays)
        @test ndays + 1 == 292195           # the sweep really is 800 years wide
        @test bad == 0
        bad == 0 || @info "first mismatch" first_bad
    end

    @testset "every second of six representative days" begin
        days = (DateTime(2016, 2, 29),   # leap day
                DateTime(2015, 12, 31),  # year end
                DateTime(1969, 7, 20),   # pre-epoch (negative t)
                DateTime(2100, 3, 1),    # day after a NON-leap century's Feb
                DateTime(2000, 2, 28),   # Feb 28 of a leap century
                DateTime(1900, 2, 28))   # Feb 28 of a non-leap century
        for d0 in days
            t0 = datetime2unix(d0)
            bad, first_bad = _dt_sweep(t0 + s for s in 0:86399)
            @test bad == 0
            bad == 0 || @info "first mismatch on $(d0)" first_bad
        end
    end

    # The millisecond cut is `trunc` toward ZERO (Dates' own `unix2datetime`),
    # not `round`. These fractions straddle every place the two disagree, and
    # the negative ones straddle the epoch, where truncation is asymmetric.
    @testset "millisecond truncation and sign boundaries" begin
        bases = (datetime2unix(DateTime(2016, 6, 15, 3, 59, 59)),
                 datetime2unix(DateTime(2015, 12, 31, 23, 59, 59)),
                 datetime2unix(DateTime(1969, 12, 31, 23, 59, 59)),
                 datetime2unix(DateTime(1965, 3, 10, 7, 0, 0)),
                 datetime2unix(DateTime(2016, 2, 28, 23, 59, 59)))
        fracs = (-0.9999, -0.5, -0.001, 0.0, 0.0004, 0.0005, 0.4,
                 0.4994, 0.4995, 0.4996, 0.5, 0.9,
                 0.9994, 0.9995, 0.9996, 0.999999, 0.9999999999)
        bad, first_bad = _dt_sweep(b + f for b in bases for f in fracs)
        @test bad == 0
        bad == 0 || @info "first mismatch" first_bad
    end

    @testset "julian_day is bitwise the previous Dates-based value" begin
        t0 = datetime2unix(DateTime(1600, 1, 1, 12, 34, 56))
        ndays = Dates.value(Date(2400, 1, 1) - Date(1600, 1, 1))
        bad = 0
        for k in 0:ndays
            t = t0 + 86400.0 * k
            _dt_eval("datetime.julian_day", t) === _dt_julian_ref(t) || (bad += 1)
        end
        @test bad == 0
        # ...and within a day, where the continuous fractional term moves.
        subbad = 0
        for d0 in (DateTime(2016, 2, 29), DateTime(1969, 7, 20), DateTime(2016, 1, 1))
            tt = datetime2unix(d0)
            for s in 0:97:86399
                t = tt + s + 0.25
                _dt_eval("datetime.julian_day", t) === _dt_julian_ref(t) ||
                    (subbad += 1)
            end
        end
        @test subbad == 0
    end

    # The decomposition runs in the VALUE's type, but the registry still hands
    # back the spec's `Int32` whenever the value type can hold one — so every
    # caller that predates tracing sees no change at all. Widening happens ONLY
    # for a value type that cannot reach `Float64`, which is what the traced
    # path needs and what `closed_functions_autodiff_test.jl` would otherwise
    # trip over.
    @testset "host values still narrow to Int32" begin
        t = datetime2unix(DateTime(2016, 6, 15, 5, 2, 3))
        for name in _DT_FIELDS
            v = _DT_M.evaluate_closed_function_ad(name, Any[t])
            @test v === _dt_ref(name, t)     # same value AND same Int32 box
        end
    end

    # The widening seam itself, without needing a backend loaded. A traced
    # number is `<: Number` but deliberately NOT `<: Real` (it cannot honor
    # `Real`'s host-comparison interface), and that is precisely the test
    # `_cal_narrow` makes.
    @testset "non-Real value types pass through un-narrowed" begin
        @test _DT_M._cal_narrow("datetime.year", 2016.0) === Int32(2016)
        @test _DT_M._cal_narrow("datetime.year", Int32(2016)) === Int32(2016)
        # Stands in for `Reactant.TracedRNumber`: a Number that is not a Real.
        v = 2016.0 + 0im
        @test !(v isa Real) && v isa Number
        @test _DT_M._cal_narrow("datetime.year", v) === v
    end

    # Non-finite `t` is out of the calendar's domain. The old path threw from
    # inside `round(Int64, NaN)` with no diagnostic code; this one carries one.
    @testset "non-finite t raises a coded error" begin
        for bad_t in (NaN, Inf, -Inf)
            err = try
                _dt_eval("datetime.year", bad_t)
                nothing
            catch e
                e
            end
            @test err isa EarthSciAST.ClosedFunctionError
            @test err.code == "closed_function_overflow"
        end
    end
end
