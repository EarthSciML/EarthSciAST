# The `tests/closed_functions` scenarios through the standard-library templates.
#
# Every scenario of tests/closed_functions/{interp,datetime}/*/expected.json is
# applied to its template of `esm:std/interp.esm` or `esm:std/calendar.esm`,
# loaded and expanded by the normal load path, and evaluated under the
# interpreter and under strict `native`. The oracle is the template contract of
# esm-spec §9.8:
#
#   * interp: each success scenario's `expected`, bit for bit (`isequal`: NaN
#     matches NaN). The `error_scenarios` are invalid tables (non-monotonic
#     axis, NaN in an axis, length mismatch); the templates have no contract
#     for them, so they are not run.
#   * datetime: each `scenarios` and `error_scenarios` instant `t` gives NaN
#     when `t` is NaN, infinite or |t| >= 2^52 s, and the scenario's `expected`
#     otherwise (within the file's tolerance). The domain edges ±(2^52 - 1) and
#     ±(2^52 - 0.5) are checked against an exact integer proleptic-Gregorian
#     computation (§9.8.2), and ±2^52 against NaN.

using Test
include("testutils.jl")

const _TS_ROOT = joinpath(TESTUTILS_REPO_ROOT, "tests", "closed_functions")
const _TS_DOMAIN = 2.0^52
const _TS_COMPILERS = (:interpreter, :native)

function _ts_decode(v)
    v isa AbstractString && return v == "NaN" ? NaN : v == "Inf" ? Inf : v == "-Inf" ? -Inf :
        throw(ArgumentError("unrecognized string value: $(v)"))
    v isa AbstractVector && return [_ts_decode(x) for x in v]
    return Float64(v)
end

function _ts_agrees(actual, expected, tol)
    a_tol = Float64(get(tol, :abs, 0)); r_tol = Float64(get(tol, :rel, 0))
    (a_tol == 0 && r_tol == 0) && return isequal(actual, expected)
    (isnan(actual) || isnan(expected)) && return isnan(actual) && isnan(expected)
    d = abs(actual - expected)
    return d <= a_tol || d <= r_tol * max(1.0, abs(expected))
end

_ts_const(a) = Dict{String, Any}("op" => "const", "args" => Any[], "value" => a)

# A model importing `ref` with one state per call, `D(s_i) = <name>(bindings_i)`,
# and each query a parameter; built once per compiler. The returned closure
# takes the parameter values to set and returns `du` by state name.
function _ts_build(ref, name, calls, params; compiler)
    vars = Dict{String, Any}(
        q => Dict{String, Any}("type" => "parameter", "units" => u, "default" => 0.0)
            for (q, u) in params
    )
    eqs = Any[]
    for (i, bindings) in enumerate(calls)
        vars["s_$i"] = Dict{String, Any}("type" => "unknown", "units" => "1", "default" => 0.0)
        push!(
            eqs, Dict{String, Any}(
                "lhs" => Dict{String, Any}("op" => "D", "args" => Any["s_$i"], "wrt" => "t"),
                "rhs" => Dict{String, Any}(
                    "op" => "apply_expression_template", "args" => Any[],
                    "name" => name, "bindings" => bindings
                )
            )
        )
    end
    doc = Dict{String, Any}(
        "esm" => "2.0.0",
        "metadata" => Dict{String, Any}("name" => "template_scenarios", "authors" => Any["t"]),
        "models" => Dict{String, Any}(
            "M" => Dict{String, Any}(
                "expression_template_imports" => Any[Dict{String, Any}("ref" => ref, "only" => Any[name])],
                "variables" => vars,
                "equations" => eqs,
            )
        )
    )
    f!, u0, p, _, vm = EarthSciAST._build_evaluator(load_string(JSON3.write(doc)); compiler = compiler)
    du = similar(u0)
    return function (vals::NamedTuple)
        fill!(du, NaN)
        f!(du, u0, merge(p, vals), 0.0)
        return [du[vm["s_$i"]] for i in eachindex(calls)]
    end
end

# The bindings of one interp scenario and its query values; the queries are
# parameters `qx_<tag>`, `qy_<tag>` (a NaN query is not a JSON literal).
function _ts_interp_call(name, inputs, tag)
    qx, qy = "qx_$tag", "qy_$tag"
    if name == "searchsorted"
        x, xs = inputs
        return Dict{String, Any}("x" => qx, "xs" => _ts_const(xs), "n" => length(xs)), Dict(qx => x)
    elseif name == "linear"
        table, axis, x = inputs
        b = Dict{String, Any}("table" => _ts_const(table), "axis" => _ts_const(axis), "x" => qx, "n" => length(axis))
        return b, Dict(qx => x)
    end
    table, ax, ay, x, y = inputs
    b = Dict{String, Any}(
        "table" => _ts_const(table), "axis_x" => _ts_const(ax), "axis_y" => _ts_const(ay),
        "x" => qx, "y" => qy, "nx" => length(ax), "ny" => length(ay)
    )
    return b, Dict(qx => x, qy => y)
end

@testset "interp scenarios through esm:std/interp.esm" begin
    for name in ("searchsorted", "linear", "bilinear")
        spec = JSON3.read(read(joinpath(_TS_ROOT, "interp", name, "expected.json"), String))
        scenarios = collect(spec.scenarios)
        calls = [_ts_interp_call(name, sc.inputs, i) for (i, sc) in enumerate(scenarios)]
        queries = Dict{String, Float64}()
        for (_, q) in calls, (k, v) in q
            queries[k] = _ts_decode(v)
        end
        vals = NamedTuple{Tuple(Symbol.(keys(queries)))}(Tuple(values(queries)))
        for compiler in _TS_COMPILERS
            @testset "$(name) ($(compiler))" begin
                eval_at = _ts_build(
                    "esm:std/interp.esm", name, first.(calls),
                    [(q, "1") for q in keys(queries)]; compiler = compiler
                )
                got = eval_at(vals)
                for (sc, actual) in zip(scenarios, got)
                    want = _ts_decode(sc.expected)
                    ok = _ts_agrees(actual, want, spec.tolerance)
                    ok || @info "interp template mismatch" name compiler sc.name actual want
                    @test ok
                end
            end
        end
    end
end

# Howard Hinnant's `civil_from_days` on Int64.
function _ts_civil_from_days(z::Int64)
    z += 719468
    era = fld(z, 146097)
    doe = z - era * 146097
    yoe = div(doe - div(doe, 1460) + div(doe, 36524) - div(doe, 146096), 365)
    doy = doe - (365 * yoe + div(yoe, 4) - div(yoe, 100))
    mp = div(5 * doy + 2, 153)
    d = doy - div(153 * mp + 2, 5) + 1
    m = mp < 10 ? mp + 3 : mp - 9
    return yoe + era * 400 + (m <= 2 ? 1 : 0), m, d
end

_ts_is_leap(y) = y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)

# The §9.8.2 value of `field` at an in-domain instant `t`, from integer
# arithmetic (and, for julian_day, the clause's binary64 formula).
function _ts_exact_field(field, t::Float64)
    ft = floor(t)
    days, sod = fldmod(Int64(ft), Int64(86400))
    y, m, d = _ts_civil_from_days(days)
    if field == "julian_day"
        return (Float64(days) + 2440588.0) + ((Float64(sod) - 43200.0) + (t - ft)) / 86400.0
    end
    cumulative = (0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334)
    field == "year" && return Float64(y)
    field == "month" && return Float64(m)
    field == "day" && return Float64(d)
    field == "hour" && return Float64(div(sod, 3600))
    field == "minute" && return Float64(div(sod, 60) % 60)
    field == "second" && return Float64(sod % 60)
    field == "day_of_year" && return Float64(cumulative[m] + d + (m > 2 && _ts_is_leap(y) ? 1 : 0))
    field == "is_leap_year" && return _ts_is_leap(y) ? 1.0 : 0.0
    throw(ArgumentError(field))
end

@testset "exact calendar reference" begin
    fields = ("year", "month", "day", "hour", "minute", "second", "day_of_year", "julian_day", "is_leap_year")
    @test [_ts_exact_field(f, 951825600.0) for f in fields] == [2000, 2, 29, 12, 0, 0, 60, 2451604, 1]
    @test [_ts_exact_field(f, -1.0) for f in fields[1:7]] == [1969, 12, 31, 23, 59, 59, 365]
end

_ts_in_domain(t) = isfinite(t) && abs(t) < _TS_DOMAIN
const _TS_EDGES = (
    _TS_DOMAIN - 1.0, -(_TS_DOMAIN - 1.0), _TS_DOMAIN - 0.5, -(_TS_DOMAIN - 0.5), _TS_DOMAIN, -_TS_DOMAIN,
)

@testset "datetime scenarios through esm:std/calendar.esm" begin
    for fdir in sort(readdir(joinpath(_TS_ROOT, "datetime")))
        spec = JSON3.read(read(joinpath(_TS_ROOT, "datetime", fdir, "expected.json"), String))
        field = String(split(String(spec.function), '.')[2])
        exact = (abs = 0, rel = 0)
        cases = Tuple{String, Float64, Float64, Any}[]
        for sc in spec.scenarios
            t = _ts_decode(sc.inputs[1])
            push!(cases, (String(sc.name), t, _ts_in_domain(t) ? _ts_decode(sc.expected) : NaN, spec.tolerance))
        end
        for sc in spec.error_scenarios
            t = _ts_decode(sc.inputs[1])
            @test !_ts_in_domain(t)
            push!(cases, (String(sc.name), t, NaN, spec.tolerance))
        end
        for t in _TS_EDGES
            push!(cases, ("domain_edge_$(t)", t, _ts_in_domain(t) ? _ts_exact_field(field, t) : NaN, exact))
        end
        for compiler in _TS_COMPILERS
            @testset "$(fdir) ($(compiler))" begin
                eval_at = _ts_build(
                    "esm:std/calendar.esm", field, [Dict{String, Any}("t" => "tu")], [("tu", "s")];
                    compiler = compiler
                )
                for (sname, t, want, tol) in cases
                    actual = only(eval_at((tu = t,)))
                    ok = _ts_agrees(actual, want, tol)
                    ok || @info "calendar template mismatch" fdir compiler sname t actual want
                    @test ok
                end
            end
        end
    end
end
