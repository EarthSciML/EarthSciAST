# Conformance: the equality-scatter fixtures
# (tests/conformance/faq_equality_scatter/, esm-spec §4.3.1 "One-pass scatter
# for an equality filter").
#
# Every fixture is built under `:interpreter` and `:native`; the right-hand side
# at the document's initial state, default parameters and t = 0 must equal the
# committed golden BIT FOR BIT under both. The goldens come from the tier's
# generate.py, a plain Python loop outside every binding.

using Test
using JSON3
using EarthSciAST

const _FES_DIR = joinpath(
    @__DIR__, "..", "..", "..", "tests", "conformance", "faq_equality_scatter"
)

function _fes_golden_value(v)
    v isa AbstractString || return Float64(v)
    v == "NaN" && return NaN
    v == "Infinity" && return Inf
    v == "-Infinity" && return -Inf
    error("unknown golden string $v")
end

_fes_same(a::Float64, b::Float64) = isnan(b) ? isnan(a) : reinterpret(UInt64, a) == reinterpret(UInt64, b)

@testset "faq equality scatter conformance (esm-spec §4.3.1)" begin
    manifest = JSON3.read(read(joinpath(_FES_DIR, "manifest.json"), String))
    model = String(manifest.model)
    @test !isempty(manifest.fixtures)
    for fx in manifest.fixtures
        golden = JSON3.read(read(joinpath(_FES_DIR, String(fx.golden)), String))
        want = Dict(String(k) => _fes_golden_value(v) for (k, v) in pairs(golden.du))
        excluded = haskey(fx.excluded, :julia)
        for compiler in (:interpreter, :native)
            @testset "$(fx.id) ($compiler)" begin
                bad = String[]
                try
                    prob = EarthSciAST.esm_problem(
                        joinpath(_FES_DIR, String(fx.path)), (0.0, 1.0); compiler = compiler
                    )
                    du = fill(NaN, length(prob.u0))
                    prob.f!(du, prob.u0, prob.p, 0.0)
                    prefix = model * "."
                    got = Dict(
                        (startswith(k, prefix) ? k[(length(prefix) + 1):end] : k) => du[slot]
                            for (k, slot) in prob.var_map
                    )
                    Set(keys(got)) == Set(keys(want)) ||
                        push!(bad, "element names differ: $(symdiff(Set(keys(got)), Set(keys(want))))")
                    for (name, w) in want
                        haskey(got, name) || continue
                        _fes_same(got[name], w) || push!(bad, "$name = $(got[name]), golden $w")
                    end
                catch err
                    err isa InterruptException && rethrow()
                    push!(bad, "raised: " * first(sprint(showerror, err), 300))
                end
                if excluded
                    # The manifest says Julia fails this fixture; a pass means the
                    # exclusion is stale and must be removed from generate.py.
                    @test !isempty(bad)
                else
                    isempty(bad) || @info "faq_equality_scatter mismatch" fixture = fx.id compiler bad
                    @test isempty(bad)
                end
            end
        end
    end
end
