# Conformance: an `ic` right-hand side is evaluated once, at the start of the
# run t0 = tspan[1], in the start-of-run scope (esm-spec §11.4.2;
# tests/conformance/ic_at_start/manifest.json). Each case builds its fixture
# with the case's tspan, p, providers and sample_time and checks the state a
# solve starts from, element by element by flattened name; a refusal case
# checks that construction raises the case's error code.

using Test
using JSON3
using EarthSciAST
using DiffEqCallbacks            # the refresh callback of a discrete provider
using SciMLBase
using OrdinaryDiffEqTsit5

const ICS = EarthSciAST

const _ICS_DIR = joinpath(
    @__DIR__, "..", "..", "..", "tests", "conformance", "ic_at_start"
)

# One field, `base + slope * t` elementwise; the provider format of
# tests/conformance/provider_forcing.
struct _ICSProvider
    key::String
    times::Vector{Float64}
    shape::Vector{Int}
    base::Any
    slope::Float64
end

function _ics_value(p::_ICSProvider, t::Real)
    isempty(p.shape) && return [Float64(p.base) + p.slope * t]
    a = Array{Float64}(undef, p.shape...)
    for I in CartesianIndices(a)
        v = p.base
        for i in Tuple(I)
            v = v[i]
        end
        a[I] = Float64(v) + p.slope * t
    end
    return a
end

ICS.provider_refresh_times(p::_ICSProvider) = p.times
ICS.provider_sample(p::_ICSProvider, t::Real; selection = nothing) =
    Dict{String, Any}(p.key => _ics_value(p, t))

function _ics_problem(c; tspan = (Float64(c.tspan[1]), Float64(c.tspan[2])))
    provs = Dict{String, Any}(
        String(p.key) => _ICSProvider(
            String(p.key), Float64[x for x in p.refresh_times],
            Int[x for x in p.shape], copy(p.base), Float64(p.slope)
        ) for p in c.providers
    )
    kw = Dict{Symbol, Any}(:compiler => :native)
    isempty(provs) || (kw[:providers] = provs)
    pv = get(c, :p, nothing)
    (pv === nothing || isempty(pv)) ||
        (kw[:p] = Dict{String, Any}(String(k) => v for (k, v) in pairs(pv)))
    get(c, :sample_time, nothing) === nothing || (kw[:sample_time] = Float64(c.sample_time))
    return ICS.esm_problem(joinpath(_ICS_DIR, String(c.fixture)), tspan; kw...)
end

# Every element of `u` against the case's expected map, and the map covers the
# whole state.
function _ics_check_state(u, var_map, expected, rtol, atol)
    @test Set(String(k) for k in keys(expected)) == Set(String(k) for k in keys(var_map))
    for (k, v) in pairs(expected)
        i = var_map[String(k)]
        @test isapprox(u[i], Float64(v); rtol = rtol, atol = atol)
    end
    return nothing
end

@testset "ic_at_start conformance" begin
    M = JSON3.read(read(joinpath(_ICS_DIR, "manifest.json"), String))
    rtol, atol = Float64(M.tolerances.rtol), Float64(M.tolerances.atol)
    for c in M.cases
        @testset "$(c.id)" begin
            if get(c, :error_code, nothing) !== nothing
                err = try
                    _ics_problem(c)
                    nothing
                catch e
                    e
                end
                @test err !== nothing
                err === nothing || @test occursin(String(c.error_code), sprint(showerror, err))
                continue
            end
            prob = _ics_problem(c)
            tspan = (Float64(c.tspan[1]), Float64(c.tspan[2]))
            @test prob.tspan == tspan
            _ics_check_state(prob.u0, prob.var_map, c.expected, rtol, atol)
            # The state a solve starts from, saved at tspan[1].
            sol = SciMLBase.solve(
                prob, Tsit5(); saveat = [tspan[1]], abstol = 1.0e-12, reltol = 1.0e-12
            )
            @test SciMLBase.successful_retcode(sol)
            j = findfirst(==(tspan[1]), sol.t)
            @test j !== nothing
            j === nothing || _ics_check_state(sol.u[j], prob.var_map, c.expected, rtol, atol)
        end
    end
end

# `remake` with a new `tspan` moves the start of the run, so the `ic`
# right-hand sides are evaluated at the new start (esm-libraries-spec §2.5.5).
@testset "ic_at_start: remake with a new tspan" begin
    M = JSON3.read(read(joinpath(_ICS_DIR, "manifest.json"), String))
    byid = Dict(String(c.id) => c for c in M.cases)
    rtol, atol = Float64(M.tolerances.rtol), Float64(M.tolerances.atol)
    # Built at one start, remade to another case's start: the remade problem
    # starts from that case's expected state.
    for (from, to) in (
            ("t_at_zero_start", "t_at_nonzero_start"),
            ("t_at_nonzero_start", "t_at_zero_start"),
            ("data_fed_discrete_zero_start", "data_fed_discrete_at_start"),
        )
        a, b = byid[from], byid[to]
        prob = _ics_problem(a; tspan = (Float64(a.tspan[1]), Float64(a.tspan[2])))
        tb = (Float64(b.tspan[1]), Float64(b.tspan[2]))
        # The data-fed case's providers refresh at 2.0 in `from`, at 8.0 in
        # `to`; the values at a start are the same function of t either way.
        prob2 = ICS.remake(prob; tspan = tb)
        @test prob2.tspan == tb
        _ics_check_state(prob2.u0, prob2.var_map, b.expected, rtol, atol)
        # The original is untouched.
        _ics_check_state(prob.u0, prob.var_map, a.expected, rtol, atol)
        sol = SciMLBase.solve(prob2, Tsit5(); saveat = [tb[1]], abstol = 1.0e-12, reltol = 1.0e-12)
        j = findfirst(==(tb[1]), sol.t)
        @test j !== nothing
        j === nothing || _ics_check_state(sol.u[j], prob2.var_map, b.expected, rtol, atol)
        # A caller's `u0` on the remake still wins over the re-evaluated `ic`.
        k = first(sort!(collect(String(x) for x in keys(b.expected))))
        prob3 = ICS.remake(prob; tspan = tb, u0 = Dict(k => 123.0))
        @test prob3.u0[prob3.var_map[k]] == 123.0
    end
    # A remake that keeps the start keeps the initial state.
    c = byid["t_at_nonzero_start"]
    prob = _ics_problem(c)
    prob2 = ICS.remake(prob; tspan = (Float64(c.tspan[1]), 20.0))
    @test prob2.u0 == prob.u0
end
