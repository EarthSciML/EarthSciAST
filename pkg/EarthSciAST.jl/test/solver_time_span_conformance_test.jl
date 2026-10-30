using Test
using EarthSciAST
using JSON3
include("testutils.jl")   # TESTUTILS_REPO_ROOT

# esm-spec §2.2.7 `solver.time_span`, against the SHARED pin.
#
# Reads `tests/conformance/solver_time_span/manifest.json` and asserts this
# binding against it: what the accessor returns, what `emit` writes back, and
# which documents a load refuses. Every binding's own suite reads the same file.
@testset "esm-spec §2.2.7 solver.time_span" begin
    suite = joinpath(TESTUTILS_REPO_ROOT, "tests", "conformance", "solver_time_span")
    manifest = JSON3.read(read(joinpath(suite, "manifest.json"), String))
    _load(id) = EarthSciAST.load_path(joinpath(suite, "fixtures", "$(id).esm"))
    _emitted_solver(file) =
        get(JSON3.read(EarthSciAST.to_json(file), Dict{String,Any}), "solver", nothing)
    _pinned(::Nothing) = nothing
    _pinned(s) = JSON3.read(JSON3.write(s), Dict{String,Any})
    _seconds(::Nothing) = nothing
    _seconds(p) = (Float64(p[1]), Float64(p[2]))

    @test "julia" in manifest.bindings_required

    @testset "accepted: $(f.id)" for f in manifest.fixtures
        f.expect == "accepted" || continue
        file = EarthSciAST.load_path(joinpath(suite, String(f.path)))
        got = EarthSciAST.resolve_time_span(file)
        want = _seconds(f.seconds)
        @test got === want   # binary64 equality: every pinned value is exact
        @test _emitted_solver(file) == _pinned(f.solver)
    end

    @testset "refused: $(f.id)" for f in manifest.fixtures
        f.expect == "refused" || continue
        e = try
            EarthSciAST.load_path(joinpath(suite, String(f.path)))
            nothing
        catch err
            err
        end
        @test e isa EarthSciAST.ExpressionTemplateError
        e isa EarthSciAST.ExpressionTemplateError || continue
        @test e.code == String(f.error_code)
        for needle in f.message_contains
            @test occursin(String(needle), e.message)
        end
    end

    @testset "the call site wins: $(c.fixture)" for c in manifest.call_site.cases
        file = _load(c.fixture)
        @test EarthSciAST.resolve_time_span(file; tspan=(c.call_site[1], c.call_site[2])) ==
              (c.resolved[1], c.resolved[2])
    end

    @testset "the authored bounds are what the type holds" begin
        file = _load("mixed")
        @test file.solver.time_span == EarthSciAST.SolverTimeSpan(0, "2019-07-01T01:00:00Z")
        # A rebuild through migrate keeps it.
        @test EarthSciAST.migrate(file, file.esm).solver == file.solver
    end

    @testset "a document built in memory is checked by the accessor" begin
        mem(span) = EarthSciAST.EsmFile("1.3.0", EarthSciAST.Metadata("m");
                                        solver=EarthSciAST.Solver(time_span=span))
        @test EarthSciAST.resolve_time_span(mem(EarthSciAST.SolverTimeSpan(1.0, 2.5))) ==
              (1.0, 2.5)
        @test EarthSciAST.resolve_time_span(mem(EarthSciAST.SolverTimeSpan(
            "1970-01-02T00:00:00Z", "1970-01-02T00:00:01.5Z"))) == (86400.0, 86401.5)
        e = try
            EarthSciAST.resolve_time_span(mem(EarthSciAST.SolverTimeSpan(2.0, 1.0)))
            nothing
        catch err
            err
        end
        @test e isa EarthSciAST.ExpressionTemplateError &&
              e.code == EarthSciAST.ERROR_CODES.SOLVER_TIME_SPAN_INVALID
        @test EarthSciAST.resolve_time_span(EarthSciAST.EsmFile("1.3.0",
            EarthSciAST.Metadata("m"))) === nothing
        refusal(span) = try
            EarthSciAST.resolve_time_span(mem(span))
            nothing
        catch err
            err
        end
        # A bound not in the timestamp form is named as such, not as a bad day.
        e = refusal(EarthSciAST.SolverTimeSpan("2019-07-01", "2019-07-02T00:00:00Z"))
        @test e isa EarthSciAST.ExpressionTemplateError &&
              e.code == EarthSciAST.ERROR_CODES.SOLVER_TIME_SPAN_INVALID &&
              occursin("not an RFC 3339 UTC timestamp", e.message)
        e = refusal(EarthSciAST.SolverTimeSpan(0.0, Inf))
        @test e isa EarthSciAST.ExpressionTemplateError &&
              e.code == EarthSciAST.ERROR_CODES.SOLVER_TIME_SPAN_INVALID &&
              occursin("not a finite number", e.message)
    end

    @testset "an integer bound emits as the integer written" begin
        span = JSON3.read(EarthSciAST.to_json(_load("numbers")), Dict{String,Any})["solver"]["time_span"]
        @test span["start"] isa Integer && span["end"] isa Integer
        @test _load("numbers").solver.time_span == EarthSciAST.SolverTimeSpan(0, 3600)
    end

    # JSON3 refuses such a literal while parsing (as Rust's reader does); the
    # §2.2.7 check is the backstop for a reader that yields an infinite value.
    @testset "a bound past binary64 is refused at load" begin
        mktempdir() do dir
            doc = JSON3.read(read(joinpath(suite, "fixtures", "numbers.esm"), String),
                             Dict{String,Any})
            for literal in ("1e400", "1" * "0"^400)
                path = joinpath(dir, "big.esm")
                text = replace(JSON3.write(doc), "\"end\":3600" => "\"end\":" * literal)
                @test occursin(literal, text)
                write(path, text)
                e = try
                    EarthSciAST.load_path(path)
                    nothing
                catch err
                    err
                end
                @test e isa EarthSciAST.ParseError ||
                      (e isa EarthSciAST.ExpressionTemplateError &&
                       e.code == EarthSciAST.ERROR_CODES.SOLVER_TIME_SPAN_INVALID)
            end
        end
    end

    @testset "the time-span calendar does not capture datetime.day_of_year's kernel" begin
        # registered_functions.jl's traceable `_days_from_civil` keeps its own
        # dispatch for `Int` arguments (it returns the `_cdiv` float).
        @test EarthSciAST._days_from_civil(2019, 1, 1) === 17897.0
        @test EarthSciAST._epoch_days(2019, 1, 1) === 17897
    end

    @testset "the calendar, without a date library" begin
        # A negative offset moves the origin later in UTC; years far from the
        # epoch and centuries that are, and are not, leap years.
        parts(s) = EarthSciAST._datetime_parts(s, EarthSciAST._RFC3339_DATETIME_RE)
        @test parts("1970-01-01T00:00:00Z") == (0, 0.0)
        @test parts("1969-12-31T19:00:00-05:00") == (0, 0.0)
        @test parts("0000-03-01T00:00:00Z") == (-62162035200, 0.0)
        @test parts("2000-02-29T12:00:00.125Z") == (951825600, 0.125)
        @test parts("1900-02-29T00:00:00Z") === nothing
        @test parts("2019-07-01T24:00:00Z") === nothing
        @test parts("2019-07-01T23:59:60Z") === nothing
        @test parts("2019-07-01 00:00:00Z") === nothing
        # The pattern ends at the end of the string: no trailing newline.
        @test parts("1970-01-01T00:00:00Z\n") === nothing
        @test !occursin(EarthSciAST._TIME_SPAN_TIMESTAMP_RE, "2019-07-01T00:00:00Z\n")
    end

    @testset "the §2.2.7 accessors: time_origin / timestamp_to_seconds" begin
        # The origin, in POSIX seconds: reference_time, else temporal.start,
        # else the epoch (a document declaring no `domain.temporal` at all).
        @test EarthSciAST.time_origin(_load("timestamps_posix")) === 0.0
        @test EarthSciAST.time_origin(_load("timestamps_reference_time")) === 1561939200.0
        @test EarthSciAST.time_origin(_load("timestamps_temporal_start")) === 1561852800.0
        @test EarthSciAST.time_origin(_load("origin_with_offset")) === 1561939200.0
        @test EarthSciAST.time_origin(_load("fractional_seconds")) === 1561939200.25
        @test EarthSciAST.time_origin(_load("numbers")) === 0.0

        # The converter is `resolve_time_span`'s own arithmetic on a bare
        # timestamp: it agrees with the span on every timestamp bound.
        for f in manifest.fixtures
            f.expect == "accepted" || continue
            file = _load(String(f.id))
            span = file.solver === nothing ? nothing : file.solver.time_span
            span === nothing && continue
            got = EarthSciAST.resolve_time_span(file)
            got === nothing && continue
            span.start isa AbstractString &&
                @test EarthSciAST.timestamp_to_seconds(file, span.start) == got[1]
            span.stop isa AbstractString &&
                @test EarthSciAST.timestamp_to_seconds(file, span.stop) == got[2]
        end

        ref = _load("timestamps_reference_time")
        @test EarthSciAST.timestamp_to_seconds(ref, "2019-07-01T00:00:00Z") === 0.0
        @test EarthSciAST.timestamp_to_seconds(ref, "2019-07-03T00:00:00Z") === 172800.0
        frac = _load("fractional_seconds")
        @test EarthSciAST.timestamp_to_seconds(frac, "2019-07-01T00:00:00.5Z") === 0.25
        @test EarthSciAST.timestamp_to_seconds(frac, "2019-07-01T00:00:01.25Z") === 1.0

        # Refusals carry §2.2.7's code and name the offending input, not
        # `/solver/time_span` (there is none).
        bad_origin = EarthSciAST.EsmFile("1.3.0", EarthSciAST.Metadata("m");
            domain=EarthSciAST.Domain(temporal=Dict{String,Any}(
                "reference_time" => "not-a-date")))
        e = try
            EarthSciAST.time_origin(bad_origin)
            nothing
        catch err
            err
        end
        @test e isa EarthSciAST.ExpressionTemplateError &&
              e.code == EarthSciAST.ERROR_CODES.SOLVER_TIME_SPAN_INVALID &&
              occursin("/domain/temporal/reference_time", e.message)
        e = try
            EarthSciAST.timestamp_to_seconds(bad_origin, "2019-07-01T00:00:00Z")
            nothing
        catch err
            err
        end
        @test e isa EarthSciAST.ExpressionTemplateError &&
              occursin("/domain/temporal/reference_time", e.message)
        e = try
            EarthSciAST.timestamp_to_seconds(ref, "2019-07-01")
            nothing
        catch err
            err
        end
        @test e isa EarthSciAST.ExpressionTemplateError &&
              e.code == EarthSciAST.ERROR_CODES.SOLVER_TIME_SPAN_INVALID &&
              occursin("not an RFC 3339 UTC timestamp", e.message)
        e = try
            EarthSciAST.timestamp_to_seconds(ref, "2019-02-30T00:00:00Z")
            nothing
        catch err
            err
        end
        @test e isa EarthSciAST.ExpressionTemplateError &&
              occursin("names no calendar day", e.message)

        # A bad timestamp is reported BEFORE a bad origin: the two share a code,
        # so the order must match Python and Rust.
        e = try
            EarthSciAST.timestamp_to_seconds(bad_origin, "2019-07-01")
            nothing
        catch err
            err
        end
        @test e isa EarthSciAST.ExpressionTemplateError &&
              occursin("not an RFC 3339 UTC timestamp", e.message) &&
              !occursin("/domain/temporal/reference_time", e.message)

        # A non-string timestamp is the same structured error, not a MethodError.
        for bad in (0, nothing, :t)
            e = try
                EarthSciAST.timestamp_to_seconds(ref, bad)
                nothing
            catch err
                err
            end
            @test e isa EarthSciAST.ExpressionTemplateError &&
                  e.code == EarthSciAST.ERROR_CODES.SOLVER_TIME_SPAN_INVALID &&
                  occursin("not an RFC 3339 UTC timestamp", e.message)
        end

        # Reconstructing a timestamp's POSIX time from the pair is correct only
        # to within rounding: `time_origin` and `timestamp_to_seconds` round
        # `W₀ + f₀` and `(W − W₀) + (f − f₀)` separately. With an exactly
        # representable fraction they agree; with origin `.2` and timestamp
        # `.1` the sum is one ulp high.
        rounding = EarthSciAST.EsmFile("1.3.0", EarthSciAST.Metadata("m");
            domain=EarthSciAST.Domain(temporal=Dict{String,Any}(
                "reference_time" => "2019-07-01T00:00:00.2Z")))
        @test EarthSciAST.time_origin(rounding) === 1561939200.2
        @test EarthSciAST.timestamp_to_seconds(rounding, "2019-07-01T00:00:00.1Z") === -0.1
        @test EarthSciAST.time_origin(rounding) +
              EarthSciAST.timestamp_to_seconds(rounding, "2019-07-01T00:00:00.1Z") ===
              nextfloat(1561939200.1)
    end
end
