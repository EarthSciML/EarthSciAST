# Causal self-reference (recurrence) — EVALUATION (esm-spec §4.3.1.1,
# CONFORMANCE_SPEC §5.19; src/tree_walk/recurrence_sweep.jl).
#
# The static half (rejections, candidacy) is recurrence_validation_test.jl. This
# file pins what the sweep computes, under both compilers and on every route:
#
#   * the shared fixtures (tests/fixtures/recurrence, tests/valid) pass their own
#     zero-tolerance assertions under `native` and `interpreter`;
#   * `native` and `interpreter` agree bit for bit, and the per-call fill level
#     of the right-hand side agrees with the output-time route (§5.19.3b);
#   * an unpublished or out-of-frame self-read is a fault on every route, never a
#     number (§5.19.4);
#   * `native`'s sweep is ONE generated function whatever the number of cells;
#   * what this binding cannot honour is refused by name (a binary32 recurrence,
#     the out-of-place product `:xla` lowers).

using Test
using EarthSciAST
using JSON3
using ForwardDiff
using OrdinaryDiffEqTsit5

include("testutils.jl")

const _RS = EarthSciAST
const _RS_FIXTURES = vcat(
    [joinpath(TESTUTILS_REPO_ROOT, "tests", "fixtures", "recurrence", f)
     for f in sort(readdir(joinpath(TESTUTILS_REPO_ROOT, "tests", "fixtures", "recurrence")))
     if endswith(f, ".esm")],
    [joinpath(TESTUTILS_REPO_ROOT, "tests", "valid", "recurrence_causal_self_reference.esm")])

_rs_bits(x) = reinterpret(UInt64, collect(Float64, x))

_rs_faq(sym, set, body; kw...) =
    Dict{String,Any}("op" => "faq", "args" => Any[], "output_idx" => [sym],
                     "ranges" => Dict{String,Any}(sym => Dict("from" => set)),
                     "expr" => body, kw...)
_rs_idx(a, i...) = Dict{String,Any}("op" => "index", "args" => Any[a, i...])
_rs_o(op, a...) = Dict{String,Any}("op" => op, "args" => Any[a...])

# A dynamic document: state `u` over `cells`, a recurrence `R` over the state
# (a two-lag body with a clamp, and a banded fold `Q` over `R`), and `D(u)`
# reading both, so the per-call fill level is the route the solver sees.
function _rs_dynamic(n::Int)
    R = _rs_faq("k", "cells", _rs_o("ifelse", _rs_o("<=", "k", 2), _rs_idx("u", "k"),
        _rs_o("+", _rs_o("*", "b", _rs_o("max", _rs_idx("R", _rs_o("-", "k", 1)), 0.0)),
                   _rs_o("sin", _rs_idx("u", "k")),
                   _rs_o("*", -0.25, _rs_idx("R", _rs_o("-", "k", 2))))))
    Q = Dict{String,Any}("op" => "faq", "args" => Any[], "output_idx" => ["k"],
        "reduce" => "+",
        "ranges" => Dict{String,Any}("k" => Dict("from" => "cells"), "a" => [0, 3]),
        "filter" => _rs_o("<=", "a", _rs_o("-", "k", 1)),
        "expr" => _rs_o("ifelse", _rs_o("==", "a", 0), _rs_idx("R", "k"),
            _rs_o("*", -0.5, _rs_o("*", _rs_idx("Q", _rs_o("-", "k", "a")),
                                    _rs_o("/", 1.0, _rs_o("+", "a", 1.0))))))
    lhs = Dict{String,Any}("op" => "faq", "args" => Any[], "output_idx" => ["i"],
        "ranges" => Dict{String,Any}("i" => Dict("from" => "cells")),
        "expr" => Dict{String,Any}("op" => "D", "args" => Any[_rs_idx("u", "i")],
                                   "wrt" => "t"))
    rhs = _rs_faq("i", "cells", _rs_o("-", _rs_o("*", -0.1, _rs_idx("Q", "i")),
                                     _rs_idx("u", "i")))
    return Dict{String,Any}("esm" => "1.1.0", "metadata" => Dict("name" => "RecurDyn"),
        "index_sets" => Dict("cells" => Dict("kind" => "interval", "size" => n)),
        "models" => Dict("M" => Dict(
            "variables" => Dict(
                "u" => Dict("type" => "unknown", "shape" => ["cells"], "units" => "1",
                            "default" => 0.5),
                "R" => Dict("type" => "unknown", "shape" => ["cells"], "units" => "1"),
                "Q" => Dict("type" => "unknown", "shape" => ["cells"], "units" => "1"),
                "b" => Dict("type" => "parameter", "units" => "1", "default" => 0.6)),
            "equations" => Any[Dict("lhs" => "R", "rhs" => R), Dict("lhs" => "Q", "rhs" => Q),
                               Dict("lhs" => lhs, "rhs" => rhs)])))
end

# A static one-variable recurrence with the given body over `steps`.
function _rs_static(body; n::Int=4, extra=Dict{String,Any}())
    return Dict{String,Any}("esm" => "1.1.0", "metadata" => Dict("name" => "RecurProbe"),
        "index_sets" => Dict("steps" => Dict("kind" => "interval", "size" => n)),
        "models" => Dict("M" => Dict(
            "variables" => Dict("s" => merge(Dict{String,Any}("type" => "unknown",
                "shape" => ["steps"], "units" => "1"), extra)),
            "equations" => Any[Dict("lhs" => "s", "rhs" => body)])))
end

_rs_tier(prob, name) = only(r.tier for r in _RS.compiler_report(prob).rules
                             if r.rule == name && r.kind === :observed &&
                                !(r.tier in _RS._OUTPUT_TIERS))

function _rs_steady_allocs(prob, u)
    du = similar(u)
    prob.f!(du, u, prob.p, 0.0)
    prob.f!(du, u, prob.p, 0.0)
    return @allocated prob.f!(du, u, prob.p, 0.0)
end

@testset "Causal self-reference: the ordered sweep (§4.3.1.1)" begin
    @testset "shared fixture $(basename(path)) under $(c)" for path in _RS_FIXTURES,
                                                               c in (:native, :interpreter)
        results = _require_fixture(path) ? run_inline_tests(path; compiler=c) : nothing
        results === nothing || @test !isempty(results)
        if results === nothing
        elseif occursin("float32", basename(path))
            # §5.19.3a: a binary32 fold is refused, never carried in binary64.
            @test all(r -> !r.passed, results)
            @test all(r -> occursin("E_TREEWALK_UNSUPPORTED_RECURRENCE", r.message) &&
                           occursin("Float32", r.message), results)
        else
            for r in results
                @test r.passed
            end
        end
    end

    @testset "native and interpreter agree bit for bit on every fixture field" begin
        for path in _RS_FIXTURES
            occursin("float32", basename(path)) && continue
            file = load_path(path)
            name, model = only(file.models)
            shaped = [k for (k, v) in model.variables
                      if v.shape !== nothing && !isempty(v.shape)]
            fields = Dict{Symbol,Vector{Vector{Float64}}}()
            for c in (:native, :interpreter)
                prob = esm_problem(path, (0.0, 1.0); compiler=c)
                fields[c] = [observed_field(prob, k) for k in shaped]
                for k in shaped
                    @test _rs_tier(prob, "$name.$k") ===
                          (c === :native ? :recurrence_sweep : :interpreter)
                end
            end
            @test map(_rs_bits, fields[:native]) == map(_rs_bits, fields[:interpreter])
        end
    end

    @testset "every route and both compilers agree on a state-dependent recurrence" begin
        doc = _rs_dynamic(48)
        u = [0.3 + 0.9 * sin(0.37 * i) for i in 1:48]
        got = Dict{Symbol,Any}()
        for c in (:native, :interpreter)
            prob = esm_problem(doc, (0.0, 1.0); compiler=c)
            @test _rs_tier(prob, "M.R") === (c === :native ? :recurrence_sweep : :interpreter)
            @test _rs_tier(prob, "M.Q") === (c === :native ? :recurrence_sweep : :interpreter)
            du = similar(u)
            prob.f!(du, u, prob.p, 0.0)
            # The output-time route, at the same state.
            R = observed_field(prob, "R"; u=u, t=0.0)
            Q = observed_field(prob, "Q"; u=u, t=0.0)
            # The per-call fill level is what `du` read (§5.19.3b): cross-route
            # agreement is asserted on VALUES, to the bit.
            @test _rs_bits(du) == _rs_bits((-0.1 .* Q) .- u)
            # And the sweep is the ascending fold, recomputed here by hand.
            Rref = zeros(48)
            for k in 1:48
                Rref[k] = k <= 2 ? u[k] :
                    0.6 * max(Rref[k-1], 0.0) + sin(u[k]) + -0.25 * Rref[k-2]
            end
            @test _rs_bits(R) == _rs_bits(Rref)
            got[c] = (du, R, Q)
        end
        @test _rs_bits(got[:native][1]) == _rs_bits(got[:interpreter][1])
        @test _rs_bits(got[:native][3]) == _rs_bits(got[:interpreter][3])
    end

    @testset "derivatives flow through the sweep" begin
        doc = _rs_dynamic(12)
        u = [0.2 + 0.1 * i for i in 1:12]
        Js = Dict{Symbol,Matrix{Float64}}()
        for c in (:native, :interpreter)
            prob = esm_problem(doc, (0.0, 1.0); compiler=c)
            Js[c] = ForwardDiff.jacobian((y, x) -> prob.f!(y, x, prob.p, 0.0),
                                         zeros(12), copy(u))
        end
        @test _rs_bits(vec(Js[:native])) == _rs_bits(vec(Js[:interpreter]))
        # A later cell depends on an earlier state through the recurrence.
        @test Js[:native][6, 1] != 0.0
        @test Js[:native][1, 6] == 0.0
    end

    if VERSION >= v"1.12"
        @testset "a steady right-hand-side call allocates nothing" begin
            doc = _rs_dynamic(64)
            u = [0.3 + 0.01 * i for i in 1:64]
            for c in (:native, :interpreter)
                prob = esm_problem(doc, (0.0, 1.0); compiler=c)
                @test _rs_steady_allocs(prob, u) == 0
            end
        end
    end

    @testset "native's sweep is one generated function at every size" begin
        # Every extent, base and stride is run-time data, so two sizes of one
        # document emit the same expression and compile it once.
        gens = Any[]
        for n in (16, 4096)
            insp = _RS.BuildInspection()
            prob = esm_problem(_rs_dynamic(n), (0.0, 1.0); compiler=:native, inspect=insp)
            ctx = _RS._obs_ctx(prob)
            prog = _RS._observed_program!(ctx, "M.R")
            sws = [sw for lv in prog.levels for sw in lv[5]]
            @test length(sws) == 1
            push!(gens, typeof(only(sws).gen))
        end
        @test gens[1] !== Nothing
        @test gens[1] === gens[2]
    end

    @testset "an unpublished or out-of-frame self-read is a fault, never a number" begin
        # `max(·, 0)` in the body would launder a NaN sentinel into a plausible
        # number (§5.19.4), so the unguarded read must raise.
        unguarded = _rs_static(_rs_faq("k", "steps",
            _rs_o("+", _rs_o("max", _rs_idx("s", _rs_o("-", "k", 1)), 0.0), 1.0)))
        # A straddling lag (§4.3.1.1 "Admitted lag") whose `a = 0` term is NOT
        # guarded away: it reads the cell being written.
        straddle = _rs_static(Dict{String,Any}("op" => "faq", "args" => Any[],
            "output_idx" => ["k"], "reduce" => "+",
            "ranges" => Dict{String,Any}("k" => Dict("from" => "steps"), "a" => [0, 1]),
            "expr" => _rs_o("ifelse", _rs_o("<=", "k", 1), 1.0,
                            _rs_idx("s", _rs_o("-", "k", "a")))))
        for (doc, what) in ((unguarded, "outside the recurrence's frame"),
                            (straddle, "has not been published"))
            for c in (:native, :interpreter)
                prob = esm_problem(doc, (0.0, 1.0); compiler=c)
                err = try
                    du = similar(prob.u0)
                    prob.f!(du, prob.u0, prob.p, 0.0)
                    nothing
                catch e
                    e
                end
                @test err isa _RS.TreeWalkError
                @test err.code == "E_TREEWALK_RECUR_UNAVAILABLE"
                @test occursin(what, err.detail)
                err2 = try
                    observed_field(prob, "s")
                    nothing
                catch e
                    e
                end
                @test err2 isa _RS.TreeWalkError
                @test err2.code == "E_TREEWALK_RECUR_UNAVAILABLE"
            end
            results = run_inline_tests(load_string(JSON3.write(merge(doc,
                Dict("models" => Dict("M" => merge(doc["models"]["M"],
                    Dict("tests" => Any[Dict("id" => "t",
                        "time_span" => Dict("start" => 0.0, "end" => 0.0),
                        "assertions" => Any[Dict("variable" => "s", "time" => 0.0,
                            "expected" => 1.0, "coords" => Dict("steps" => 2))])]))))))))
            @test length(results) == 1
            @test !results[1].passed
            @test occursin("E_TREEWALK_RECUR_UNAVAILABLE", results[1].message)
        end
    end

    @testset "a binary32 recurrence is refused by name under both compilers" begin
        doc = _rs_static(_rs_faq("k", "steps", _rs_o("ifelse", _rs_o("<=", "k", 1), 0.1,
            _rs_o("+", _rs_idx("s", _rs_o("-", "k", 1)), 0.1)));
            extra=Dict{String,Any}("element_type" => "Float32"))
        file = load_string(JSON3.write(doc))
        @test file.models["M"].variables["s"].element_type == "Float32"
        # The declaration survives a round trip.
        @test occursin("\"element_type\"", JSON3.write(_RS.serialize_esm_file(file)))
        for c in (:native, :interpreter)
            err = try
                esm_problem(doc, (0.0, 1.0); compiler=c)
                nothing
            catch e
                e
            end
            @test err isa _RS.TreeWalkError
            @test err.code == "E_TREEWALK_UNSUPPORTED_RECURRENCE"
            @test occursin("Float32", err.detail)
        end
    end

    @testset "the out-of-place product refuses a recurrence by name" begin
        path = joinpath(TESTUTILS_REPO_ROOT, "tests", "fixtures", "recurrence",
                        "01_recurrence_doubling.esm")
        err = try
            _RS._build_evaluator(load_path(path); form=:oop)
            nothing
        catch e
            e
        end
        @test err isa _RS.TreeWalkError
        @test err.code == _RS.ERROR_CODES.COMPILER_REFUSED_RULE
        @test occursin("refuses 's'", err.detail)
        @test occursin("out-of-place", err.detail)
    end
end
