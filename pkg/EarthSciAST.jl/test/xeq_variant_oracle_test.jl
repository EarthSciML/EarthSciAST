# Differential oracle for cross-equation variant memoization (perf plan A3,
# tree_walk/stencil.jl `_XEqStore`): build the SAME model under
# `compiler=:native` (the per-build variant/bound-body/obs-memo hoist, with the
# rest of the cascade) and under `compiler=:interpreter` (none of it) and
# require
#   * identical state maps (var_map) and initial states (u0/p),
#   * BIT-identical du at several (u, t) probes,
# on the fixtures the hoist actually touches: the compile-once template
# fixture (tests/bench/transport_3axis_7cubed_fullrank.esm), a synthesized
# TWO-EQUATION version of it whose second equation reuses the first's D()
# roots (the transport m/mq/dev shape — this is where the cross-equation cache
# hits), a multi-equation observed-chain faq model (the shared obs-inline
# memo path with no templates at all), and the proxy27 bench fixture. Also
# pins the sharing itself: the two-equation fixture compiles the SAME number of
# body variants as the one-equation fixture, which is what "the second equation
# reused the first's" means, and the interpreter agrees bit-for-bit.

using Test
using JSON3
using EarthSciAST
using EarthSciAST: _BENCH_ON, _BENCH_BODY_VARIANTS, _BENCH_COMPILE_CALLS,
    _bench_reset!

include("testutils.jl")
const ESM = EarthSciAST

# Deterministic probe states.
_xeq_probe_states(n) = (
    Float64[sin(0.1 * i) + 1.5 for i in 1:n],
    Float64[0.5 + 0.01 * i + cos(0.3 * i)^2 for i in 1:n],
    Float64[1.5 + 0.25 * sin(0.7 * i) * cos(0.05 * i) for i in 1:n],
)

# Build under `compiler` and return (du probes, u0, p, var_map, counters).
function _xeq_probe(build; compiler=:native)
    _BENCH_ON[] = true
    _bench_reset!()
    f, u0, p, _, vmap = build(compiler)
    counters = (variants=_BENCH_BODY_VARIANTS[], compiles=_BENCH_COMPILE_CALLS[])
    _BENCH_ON[] = false
    dus = Vector{Float64}[]
    for (ti, u) in zip((0.0, 0.7, 3.25), _xeq_probe_states(length(u0)))
        du = similar(u0)
        f(du, u, p, ti)
        push!(dus, copy(du))
    end
    return (dus, u0, p, vmap, counters)
end

# The native/interpreter differential for one builder; returns both for extra pins.
function _xeq_oracle(build)
    on = _xeq_probe(build; compiler=:native)
    off = _xeq_probe(build; compiler=:interpreter)
    @test on[4] == off[4]                    # identical state map
    @test on[2] == off[2]                    # identical u0 (bitwise: Float64 ==)
    @test on[3] === off[3] || isequal(on[3], off[3])   # identical params
    for k in eachindex(on[1])
        @test on[1][k] == off[1][k]          # bit-identical du
    end
    @test any(du -> sum(abs, du) > 0, on[1]) # and not trivially zero
    return on, off
end

# Synthesize the TWO-EQUATION compile-once fixture: a second state `r` whose
# equation reuses the first equation's advection expression (so, after A1
# interning, both equations instantiate the SAME template expansion roots —
# the D(m,t)/D(mq,t)/D(dev,t) sharing shape in miniature).
function _xeq_two_eq_fixture(fix::AbstractString)
    raw = JSON3.read(read(fix, String), Dict{String,Any})
    m = raw["models"]["Transport"]
    m["variables"]["r"] = Dict("type" => "unknown", "units" => "1",
                               "shape" => ["x", "y", "z"], "default" => 0.25)
    adv = m["equations"][1]["rhs"]
    m["equations"] = Any[m["equations"][1],
        Dict("lhs" => Dict("op" => "D", "args" => Any["r"], "wrt" => "t"),
             "rhs" => Dict("op" => "*", "args" => Any[0.5, adv]))]
    out = joinpath(mktempdir(), "transport_two_eq.esm")
    open(out, "w") do io
        JSON3.write(io, raw)
    end
    return out
end

# Multi-equation faq model over a shared observed chain (no templates):
# exercises the SHARED obs-inline `_SubMemo` — both equations splice the same
# `resolved_obs` bodies, and the hoist must not change a bit.
function _xeq_observed_faq_model(N)
    kuv = _op("*", _v("k0"), _op("+", _idx("u", _v("i")), _idx("v", _v("i"))))
    # esm 1.0.0 (esm-spec §6.3.1): `w` is a plain unknown; its `makearray` body
    # is the bare-variable-LHS equation spliced in below.
    wdef = ESM.OpExpr("makearray", ESM.ASTExpr[];
        regions=[[[1, N]]], values=ESM.ASTExpr[kuv])
    vars = Dict(
        "u" => ESM.ModelVariable(ESM.UnknownVariable),
        "v" => ESM.ModelVariable(ESM.UnknownVariable),
        "k0" => ESM.ModelVariable(ESM.ParameterVariable; default=2.0),
        "w" => ESM.ModelVariable(ESM.UnknownVariable))
    lap(x) = _op("+", _idx(x, _op("-", _v("i"), _i(1))),
                 _op("*", _n(-2.0), _idx(x, _v("i"))),
                 _idx(x, _op("+", _v("i"), _i(1))))
    wref = _op("index", _v("w"), _v("i"))
    eqs = [ESM.Equation(_v("w"), wdef),
           ESM.Equation(_ao1(_Didx("u", _v("i")), "i", 1, N),
                        _ao1(_op("+", lap("u"), wref), "i", 1, N)),
           ESM.Equation(_ao1(_Didx("v", _v("i")), "i", 1, N),
                        _ao1(_op("-", lap("v"), wref), "i", 1, N))]
    ESM.Model(vars, eqs)
end

# The one-equation fixture's compiled-variant count, so the two-equation
# testset can say "the same, not twice as many" without re-deriving it.
const ONE_EQ_VARIANTS = Ref(0)

@testset "cross-equation variant memo oracle (A3)" begin
    bench(parts...) = joinpath(TESTUTILS_REPO_ROOT, "tests", "bench", parts...)
    FIX = bench("transport_3axis_7cubed_fullrank.esm")

    @testset "compile-once fixture (7³, one equation)" begin
        # Single equation: no cross-equation sharing possible — the hoist must
        # be a pure no-op (same variant count, same bits).
        build(compiler) = ESM.build_evaluator(ESM.flatten(ESM.load_path(FIX));
                                              compiler=compiler)
        on, _off = _xeq_oracle(build)
        @test length(on[2]) == 343
        @test on[5].variants == 15
        ONE_EQ_VARIANTS[] = on[5].variants
    end

    @testset "two equations sharing template roots" begin
        FIX2 = _xeq_two_eq_fixture(FIX)
        build(compiler) = ESM.build_evaluator(ESM.flatten(ESM.load_path(FIX2));
                                              compiler=compiler)
        on, off = _xeq_oracle(build)
        @test length(on[2]) == 2 * 343
        # THE A3 property, stated without an oracle switch: two equations over
        # the same template roots compile the SAME body variants as ONE of them
        # does. Per-equation caches would compile each root twice, so this
        # number doubling is exactly the regression to catch.
        @test on[5].variants == 15
        @test on[5].variants == ONE_EQ_VARIANTS[]
        # And the interpreter agrees bit-for-bit with the shared build.
        for k in eachindex(on[1])
            @test on[1][k] == off[1][k]
        end
    end

    @testset "multi-equation observed chain (shared obs memo, no templates)" begin
        N = 16
        model = _xeq_observed_faq_model(N)
        ics = Dict{String,Float64}()
        for k in 1:N
            ics["u[$k]"] = sin(0.3k) + 0.1k
            ics["v[$k]"] = cos(0.2k) + 0.05k
        end
        build(compiler) = ESM.build_evaluator(model; initial_conditions=ics,
                                              compiler=compiler)
        # `:native` is what the shared obs memo runs on, and its du must be
        # non-trivial or the memo was never reached. There is no interpreter
        # oracle for this one: `:interpreter` inlines every array observed, and
        # inlining a `makearray` whose region value names the outer loop index
        # leaves that index unbound. That is a gap in the inlining path rather
        # than in the memo, and it is older than the `compiler` keyword — pinned
        # here so it is visible, and so closing it fails this line instead of
        # passing silently.
        on = _xeq_probe(build; compiler=:native)
        @test any(du -> sum(abs, du) > 0, on[1])
        @test_throws ESM.TreeWalkError build(:interpreter)
    end

    @testset "proxy27 bench fixture" begin
        P27 = joinpath(TESTUTILS_REPO_ROOT, "scripts", "bench", "fixtures",
                       "proxy27.esm")
        if isfile(P27)
            build(compiler) = ESM.build_evaluator(ESM.load_path(P27);
                                                  compiler=compiler)
            _xeq_oracle(build)
        else
            @info "proxy27.esm not found; skipping" P27
        end
    end
end
