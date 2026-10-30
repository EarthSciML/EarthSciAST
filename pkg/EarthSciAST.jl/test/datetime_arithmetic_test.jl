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
#   * fractional seconds on both sides of the epoch, which are the ONLY place
#     a floor-vs-trunc-vs-round slip is visible — an exact-integer `t`
#     floors, truncates and rounds alike, so a test built from whole seconds
#     cannot see it. esm-spec §9.2 floors toward −∞ (ruling Q-3), which
#     `Dates.unix2datetime` does NOT do (it truncates `1000t` toward zero), so
#     the oracle is `Dates` applied to `floor(t)`.
#
# `julian_day` is pinned separately against the previous `Dates`-based
# Fliegel–van Flandern spelling, bitwise over 1600–2400 (where FvF equals the
# linear day number §9.2 now pins), because it is the one member of the
# family that is continuous in `t` and feeds a Rosenbrock ∂f/∂t. Before
# -4800-03-01 FvF is not the Julian Date; the shared fixtures pin that range.

using Test
using Dates
using EarthSciAST

const _DT_M = EarthSciAST

_dt_eval(name, t) = _DT_M.evaluate_closed_function(name, Any[t])

const _DT_FIELDS = ["datetime.year", "datetime.month", "datetime.day",
                    "datetime.hour", "datetime.minute", "datetime.second",
                    "datetime.day_of_year", "datetime.is_leap_year"]

# The oracle: Julia's `Dates` on the whole second `t` falls in.
function _dt_ref(name::String, t)
    dt = unix2datetime(floor(t))
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

    # Fractions are floored toward −∞, not truncated or rounded. These
    # straddle every millisecond/microsecond place where `round` or `trunc`
    # would disagree, and the negative ones straddle the epoch, where
    # truncation toward zero would move a 1969 time forward into 1970.
    @testset "fractional-second floor and sign boundaries" begin
        bases = (datetime2unix(DateTime(2016, 6, 15, 3, 59, 59)),
                 datetime2unix(DateTime(2015, 12, 31, 23, 59, 59)),
                 datetime2unix(DateTime(1969, 12, 31, 23, 59, 59)),
                 datetime2unix(DateTime(1965, 3, 10, 7, 0, 0)),
                 datetime2unix(DateTime(2016, 2, 28, 23, 59, 59)))
        fracs = (-0.9999, -0.5, -0.001, -1e-7, 0.0, 0.0004, 0.0005, 0.4,
                 0.4994, 0.4995, 0.4996, 0.5, 0.9,
                 0.9994, 0.9995, 0.9996, 0.999999, 0.9999999999)
        bad, first_bad = _dt_sweep(b + f for b in bases for f in fracs)
        @test bad == 0
        bad == 0 || @info "first mismatch" first_bad
        # The ruling's worked examples, and the subnormal just below the epoch
        # (where `86400 - 5e-324` rounds to 86400 in binary64).
        for (t, fields) in ((59.9999999, (1970, 1, 1, 0, 0, 59)),
                            (86399.9999999, (1970, 1, 1, 23, 59, 59)),
                            (-1e-7, (1969, 12, 31, 23, 59, 59)),
                            (-5e-324, (1969, 12, 31, 23, 59, 59)))
            @test Tuple(_dt_eval(n, t) for n in _DT_FIELDS[1:6]) == fields
        end
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

    # esm-spec §9.2: a NaN or ±Inf `t`, and one whose year is outside Int32,
    # raise `closed_function_overflow` in EVERY entry (rulings Q-100, Q-101) —
    # through the pinned registry, its AD twin and the typed scalar cores.
    @testset "non-finite t and Int32-overflowing years raise overflow, every entry" begin
        coded(f) = try
            f()
            nothing
        catch e
            e isa EarthSciAST.ClosedFunctionError ? e.code : e
        end
        hi = 6.77679762335328e16            # first instant of year 2^31
        lo = prevfloat(-6.77681005679712e16) # last double of year -2^31 - 1
        names = vcat(_DT_FIELDS, ["datetime.julian_day"])
        for name in names, bad_t in (NaN, Inf, -Inf, hi, lo)
            @test coded(() -> _dt_eval(name, bad_t)) == "closed_function_overflow"
            @test coded(() -> _DT_M.evaluate_closed_function_ad(name, Any[bad_t])) ==
                  "closed_function_overflow"
            spec = _DT_M._fn_typed_core_spec(name)
            @test coded(() -> _DT_M._fn_typed_core_call(spec.id, bad_t)) ==
                  "closed_function_overflow"
        end
        # One step inside each edge every entry still answers.
        for name in names, ok_t in (prevfloat(hi), -6.77681005679712e16)
            @test coded(() -> _dt_eval(name, ok_t)) === nothing
        end
    end
end
