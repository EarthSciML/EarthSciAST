# Conformance: run-time providers and the forcing they give a Problem and its
# `rhs_program` (tests/conformance/provider_forcing/README.md; API_SPEC §5.8,
# "Forcing sets"). Consumes manifest.json case by case; every comparison is
# bitwise against the values the manifest records.

using Test
using JSON3
using EarthSciAST
using DiffEqCallbacks            # the refresh callback of a discrete provider
using SciMLBase

const PFC = EarthSciAST

const _PFC_DIR = joinpath(
    @__DIR__, "..", "..", "..", "tests", "conformance", "provider_forcing"
)

_pfc_bits(x) = reinterpret(UInt64, Float64[v for v in x])

# One field, `base + slope * t` elementwise (README "Providers").
struct _PFCProvider
    key::String
    times::Vector{Float64}
    shape::Vector{Int}
    base::Any
    slope::Float64
end

function _pfc_value(p::_PFCProvider, t::Real)
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

PFC.provider_refresh_times(p::_PFCProvider) = p.times
PFC.provider_sample(p::_PFCProvider, t::Real; selection = nothing) =
    Dict{String, Any}(p.key => _pfc_value(p, t))

function _pfc_problem(M, c)
    provs = Dict{String, Any}(
        String(p.key) => _PFCProvider(
            String(p.key), Float64[x for x in p.refresh_times],
            Int[x for x in p.shape], copy(p.base), Float64(p.slope)
        ) for p in c.providers
    )
    kw = Dict{Symbol, Any}(:compiler => :native)
    isempty(provs) || (kw[:providers] = provs)
    get(c, :sample_time, nothing) === nothing || (kw[:sample_time] = Float64(c.sample_time))
    tspan = (Float64(M.tspan[1]), Float64(M.tspan[2]))
    return PFC.esm_problem(joinpath(_PFC_DIR, M.document), tspan; kw...), tspan
end

@testset "provider_forcing conformance" begin
    M = JSON3.read(read(joinpath(_PFC_DIR, "manifest.json"), String))
    for c in M.cases
        @testset "$(c.id)" begin
            prob, tspan = _pfc_problem(M, c)
            prog = PFC.rhs_program(prob)
            slots = PFC.forcing_slots(prog)
            @test slots == [
                PFC.ForcingSlot(String(s.name), Int[x for x in s.shape], Symbol(s.kind))
                    for s in c.forcing_slots
            ]
            D = PFC.default_forcing_set(prog)
            for (i, s) in enumerate(slots)
                @test _pfc_bits(D.bufs[i]) == _pfc_bits(c.default_forcing[Symbol(s.name)])
            end
            # The document's only state is `Fed.u`, default 1.0 everywhere.
            u = ones(PFC.n_states(prog))
            p = PFC.parameter_vector(prog, Dict{String, Float64}())
            du = fill(NaN, PFC.n_states(prog))
            PFC.rhs!(du, prog, PFC.rhs_workspace(prog), u, Float64[], p, tspan[1], D)
            @test _pfc_bits(du) == _pfc_bits(c.du_default)
            dp = fill(NaN, length(prob.u0))
            prob.f!(dp, prob.u0, prob.p, tspan[1])
            if "julia" in get(c, :problem_du_broken, String[])
                @test_broken _pfc_bits(dp) == _pfc_bits(c.du_default)
            else
                @test _pfc_bits(dp) == _pfc_bits(c.du_default)
            end
        end
    end
end
