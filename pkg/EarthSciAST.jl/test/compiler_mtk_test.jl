# `compiler = :mtk` — the ModelingToolkit compiler behind `esm_problem`
# (API_SPEC §5.8, esm-libraries-spec §2.5.2/§2.5.10, CONFORMANCE_SPEC §5.39).
#
# Four things are pinned here, and nothing else in the suite pins any of them:
#
#   * `:mtk` RUNS THE THREE CONSTRUCTS §5.39 has every other evaluator refuse —
#     a continuous event, a discrete event and an implicit equation — on the
#     very fixtures that category owns, to the values those fixtures' inline
#     tests name. Each is also asserted to REFUSE under `:native` in the same
#     session, so what is measured is the compiler and not the document.
#   * what it REFUSES BY NAME, which is the other half of "works only for some
#     documents": data fed in at the call, the projection-pushdown rewrite, a
#     continuous spatial dimension, and a time derivative of an expression.
#     Every one is `compiler_refused_rule` with the rule in the message — never
#     a silent partial build and never a fallback.
#   * AGREEMENT with `:interpreter`, the oracle that exists to check the other
#     compilers, on documents both run, inside the compiler-agreement tier's
#     own band.
#   * the PROBLEM SURFACE: `compiler`, `compiler_report` (whose tiers name what
#     `mtkcompile` DID — integrated, residual, or eliminated into an observed),
#     `var_map`, `observed_field`, `remake`, and `show`.
#
# Needs ModelingToolkit loaded, which the test target carries. The `:mtk`
# UNAVAILABLE arm — `compiler_unavailable` naming what to load — cannot be
# asserted from here for the same reason: this session has MTK, so `:mtk` is
# available in it. It is stated in `compiler_selection_test.jl`, where the
# vocabulary lives, as the arm an MTK-free session takes.
using Test
using EarthSciAST
using JSON3
using SciMLBase
using OrdinaryDiffEqTsit5
using OrdinaryDiffEqRosenbrock
# The DAE initialization an implicit equation compiles to is a nonlinear solve,
# and OrdinaryDiffEq only carries one when this is loaded. Without it the
# implicit fixtures raise "requires a DAE initialization … no nonlinear solve
# has been loaded" instead of running.
import OrdinaryDiffEqNonlinearSolve
import ModelingToolkit

const _MTKC = EarthSciAST
const _MTKC_ROOT = normpath(joinpath(@__DIR__, "..", "..", ".."))
_mtkc_fixture(parts...) = joinpath(_MTKC_ROOT, "tests", parts...)
_mtkc_uc(name) = _mtkc_fixture("conformance", "unsupported_construct",
                               "fixtures", name)

# The compiler-agreement tier's own band for a transcendental scalar fixture
# (tests/conformance/compiler_agreement/manifest.json), used here for the
# `:mtk` vs `:interpreter` comparison so the two places agree on what "the same
# trajectory" means.
const _MTKC_RTOL = 1e-6
const _MTKC_ATOL = 1e-9

# A document with a CONTINUOUS spatial dimension: `dim = "z"` on the operator
# nodes is what makes `z` an independent variable (esm-spec §4.9.1(ii)), which
# is the ODE-vs-PDE split this compiler refuses on.
_mtkc_pde_doc() = Dict{String,Any}(
    "esm" => "1.1.0",
    "metadata" => Dict{String,Any}("name" => "MtkPde"),
    "models" => Dict{String,Any}("Diffuse" => Dict{String,Any}(
        "variables" => Dict{String,Any}(
            "u"  => Dict{String,Any}("type" => "unknown", "default" => 1.0),
            "Dc" => Dict{String,Any}("type" => "parameter", "default" => 0.1)),
        "equations" => Any[Dict{String,Any}(
            "lhs" => Dict{String,Any}("op" => "D", "args" => Any["u"], "wrt" => "t"),
            "rhs" => Dict{String,Any}("op" => "*", "args" => Any[
                "Dc",
                Dict{String,Any}("op" => "grad", "dim" => "z", "args" => Any[
                    Dict{String,Any}("op" => "grad", "dim" => "z",
                                     "args" => Any["u"])])]))])))

# A scalar decay with a state-free observed (`twice_k ~ 2*k`) and a
# state-DEPENDENT one (`scaled ~ 3*x`) — the two sides of `observed_field`'s
# build-time contract.
_mtkc_obs_doc() = Dict{String,Any}(
    "esm" => "1.1.0",
    "metadata" => Dict{String,Any}("name" => "MtkObs"),
    "models" => Dict{String,Any}("M" => Dict{String,Any}(
        "variables" => Dict{String,Any}(
            "x"       => Dict{String,Any}("type" => "unknown", "default" => 2.0),
            "k"       => Dict{String,Any}("type" => "parameter", "default" => 0.5),
            "twice_k" => Dict{String,Any}("type" => "unknown"),
            "scaled"  => Dict{String,Any}("type" => "unknown")),
        "equations" => Any[
            Dict{String,Any}(
                "lhs" => Dict{String,Any}("op" => "D", "args" => Any["x"], "wrt" => "t"),
                "rhs" => Dict{String,Any}("op" => "neg", "args" => Any[
                    Dict{String,Any}("op" => "*", "args" => Any["k", "x"])])),
            Dict{String,Any}("lhs" => "twice_k",
                             "rhs" => Dict{String,Any}("op" => "*",
                                                       "args" => Any[2.0, "k"])),
            Dict{String,Any}("lhs" => "scaled",
                             "rhs" => Dict{String,Any}("op" => "*",
                                                       "args" => Any[3.0, "x"]))])))

# The smallest sink that satisfies the producer protocol: it records `(t, state)`
# at every output tick and tracks the lifecycle calls.
mutable struct _MtkcSink
    rows::Vector{Tuple{Float64,Vector{Float64}}}
    opened::Bool
    closed::Bool
end
_MtkcSink() = _MtkcSink(Tuple{Float64,Vector{Float64}}[], false, false)
EarthSciAST.sink_output_times(::_MtkcSink) = Float64[0.0, 1.5, 2.5]
EarthSciAST.sink_open!(s::_MtkcSink) = (s.opened = true; nothing)
EarthSciAST.sink_write!(s::_MtkcSink, snap::StateSnapshot; selection = nothing) =
    (push!(s.rows, (snap.t, Vector{Float64}(snap.state[1][1]))); nothing)
EarthSciAST.sink_flush!(::_MtkcSink) = nothing
EarthSciAST.sink_close!(s::_MtkcSink) = (s.closed = true; nothing)

# The refusal an `esm_problem` call raised, or `nothing` when it built.
function _mtkc_raise(f, args...; kwargs...)
    try
        f(args...; kwargs...)
        return nothing
    catch err
        return err
    end
end

@testset "compiler = :mtk (§5.8)" begin

    # ── The three constructs §5.39 has every other evaluator refuse ─────────
    #
    # Each fixture's inline test states the value the document DESCRIBES, and
    # the category exists because an evaluator that drops the construct reports
    # a different one. So the assertion is that number, not merely that the
    # build succeeded.
    @testset "a continuous event: the sawtooth resets" begin
        f = _mtkc_uc("continuous_event_on_the_scalar_path.esm")
        # `:native` refuses it by name — which is what makes the run below a
        # statement about the compiler.
        err = _mtkc_raise(esm_problem, f, (0.0, 2.5))
        @test err isa TreeWalkError && err.code == "unsupported_construct"

        prob = esm_problem(f, (0.0, 2.5); compiler = :mtk)
        @test compiler(prob) === :mtk
        sol = solve(prob, Tsit5(); reltol = 1e-10, abstol = 1e-12)
        @test SciMLBase.successful_retcode(sol)
        # x climbs at rate 1 from 0 and is reset to 0 each time it reaches 1,
        # so x(2.5) = 0.5. WITHOUT the event it would be 2.5.
        @test only(EarthSciAST.final_state(sol)) ≈ 0.5 atol = 1e-6
        rep = compiler_report(prob)
        @test any(r -> r.kind === :event && r.tier === :mtk_continuous_event,
                  rep.rules)
        @test any(r -> occursin("reset", r.rule), rep.rules)
    end

    @testset "a discrete event: the periodic fold" begin
        f = _mtkc_uc("discrete_event_on_the_scalar_path.esm")
        err = _mtkc_raise(esm_problem, f, (0.0, 3.5))
        @test err isa TreeWalkError && err.code == "unsupported_construct"

        prob = esm_problem(f, (0.0, 3.5); compiler = :mtk)
        sol = solve(prob, Tsit5(); reltol = 1e-10, abstol = 1e-12)
        @test SciMLBase.successful_retcode(sol)
        # s := 2*Pre(s) once per unit of time, from 1 — so s(3.5) = 8.
        @test only(EarthSciAST.final_state(sol)) ≈ 8.0 rtol = 1e-12
        @test any(r -> r.tier === :mtk_discrete_event, compiler_report(prob).rules)
    end

    @testset "an implicit equation: the residual is solved" begin
        f = _mtkc_uc("implicit_equation_on_the_scalar_path.esm")
        err = _mtkc_raise(esm_problem, f, (0.0, 1.0))
        @test err isa TreeWalkError && err.code == "unsupported_construct"

        prob = esm_problem(f, (0.0, 1.0); compiler = :mtk)
        # `2*s - 4 = 0` determines s = 2, so `mtkcompile` solves it away
        # entirely: the compiled system has NO unknown to integrate, and the
        # value is an observed equation. That is the report's `:mtk_eliminated`
        # tier — a decision no other compiler in any binding makes, and none of
        # them can report.
        @test isempty(prob.u0)
        @test any(r -> r.tier === :mtk_eliminated, compiler_report(prob).rules)
        # The document's `ic(s) ~ 1` is a GUESS for the algebraic solve, not a
        # constraint on its answer; the answer is 2.
        @test only(observed_field(prob, "s")) ≈ 2.0 rtol = 1e-10
        @test only(observed_field(prob, "ImplicitEquationOnTheScalarPath.s")) ≈ 2.0 rtol = 1e-10
        # A run over a system with nothing to integrate still returns a
        # solution rather than `nothing` (OrdinaryDiffEq's null integrator
        # would); it is empty, because every value lives in an observed.
        sol = solve(prob, Rodas5P(); reltol = 1e-10, abstol = 1e-12)
        @test sol !== nothing
        @test isempty(EarthSciAST.final_state(sol))
    end

    @testset "an implicit equation on the ARRAY path: the recurrence" begin
        f = _mtkc_uc("implicit_equation_on_the_array_path.esm")
        err = _mtkc_raise(esm_problem, f, (0.0, 1.0))
        @test err isa TreeWalkError && err.code == "unsupported_construct"

        prob = esm_problem(f, (0.0, 1.0); compiler = :mtk)
        # `s[k] = 1` at k = 1 and `2*s[k-1]` after, solved as a residual over
        # the whole shaped unknown: [1, 2, 4, 8]. The name of the whole field
        # reads its CELLS in row-major order, not the one array-typed value its
        # defining equation's left-hand side carries.
        @test observed_field(prob, "ImplicitEquationOnTheArrayPath.s") ≈
              [1.0, 2.0, 4.0, 8.0] rtol = 1e-10
        @test only(observed_field(prob, "ImplicitEquationOnTheArrayPath.s[4]")) ≈
              8.0 rtol = 1e-10
    end

    # ── The WHOLE §5.39 category, driven from its own manifest ─────────────
    #
    # The three testsets above assert the VALUES on three documents. This one
    # asserts the COVERAGE on all fifteen: every document that category says the
    # tree-walk evaluator must refuse either RUNS under `:mtk` or is refused BY
    # NAME, and nothing errors. It is data-driven off the shared manifest, so a
    # case added there is covered here the day it lands rather than the day
    # someone remembers this file.
    #
    # One case refuses, and it is named: `D(a + b) ~ 3` is a time derivative of
    # an EXPRESSION, which credits no state — an implicit equation spelled
    # wrong, and one no compiler in any binding runs.
    @testset "every §5.39 fixture runs or refuses by name" begin
        uc_dir = _mtkc_fixture("conformance", "unsupported_construct")
        manifest = JSON3.read(read(joinpath(uc_dir, "manifest.json"), String))
        refused = String[]
        for case in manifest.cases
            id = String(case.id)
            path = joinpath(uc_dir, String(case.path))
            @testset "$id" begin
                # The document's own inline test gives the interval; the values
                # are asserted above, on the three representative documents.
                doc = JSON3.read(read(path, String))
                models = get(doc, :models, nothing)
                tests = models === nothing || isempty(models) ? () :
                        get(first(values(models)), :tests, ())
                span = isempty(tests) ? (0.0, 3.5) :
                       (Float64(first(tests).time_span.start),
                        Float64(first(tests).time_span[Symbol("end")]))
                err = _mtkc_raise(esm_problem, path, span; compiler = :mtk)
                if err === nothing
                    prob = esm_problem(path, span; compiler = :mtk)
                    sol = solve(prob, Rodas5P(); reltol = 1e-10, abstol = 1e-12)
                    @test SciMLBase.successful_retcode(sol)
                else
                    # A refusal, never an error: the message names the compiler,
                    # the rule and the reason.
                    @test err isa TreeWalkError
                    @test err.code == _MTKC.ERROR_CODES.COMPILER_REFUSED_RULE
                    @test occursin(r"^compiler=:mtk refuses '.+': ", err.detail)
                    push!(refused, id)
                end
            end
        end
        # Exactly one case refuses, and it is the one that is not really an
        # event or a solvable residual.
        @test refused == ["implicit_equation_as_the_derivative_of_an_expression"]
    end

    # ── What it refuses, by name ────────────────────────────────────────────
    @testset "refusals name the rule and never fall back" begin
        decay = _mtkc_fixture("valid", "solver_block.esm")
        # The last element says whether the message POINTS AT ANOTHER COMPILER.
        # Four of these are documents `:native` runs, so the refusal says so.
        # `D(<expression>)` is not: no compiler in any binding runs it — the
        # tree walk raises `unsupported_construct` on the same document — so
        # naming one would be wrong advice, and the message says how to REWRITE
        # the equation instead.
        cases = [
            ("data handed in at the call",
             () -> esm_problem(decay, (0.0, 1.0); compiler = :mtk,
                               const_arrays = Dict("tbl" => [1.0, 2.0])),
             "const_arrays", true),
            ("a provider",
             () -> esm_problem(decay, (0.0, 1.0); compiler = :mtk,
                               providers = Dict("Loader.v" => nothing)),
             "DATA-FED", true),
            ("the pushdown rewrite",
             () -> esm_problem(decay, (0.0, 1.0); compiler = :mtk,
                               pushdown_rewrite = true),
             "pushdown", true),
            ("a continuous spatial dimension",
             () -> esm_problem(_mtkc_pde_doc(), (0.0, 1.0); compiler = :mtk),
             "PDE", true),
            ("a time derivative of an expression",
             () -> esm_problem(
                 _mtkc_uc("implicit_equation_as_the_derivative_of_an_expression.esm"),
                 (0.0, 1.0); compiler = :mtk),
             "credits no state", false),
        ]
        for (what, build, needle, points_elsewhere) in cases
            @testset "$what" begin
                err = _mtkc_raise(build)
                @test err isa TreeWalkError
                @test err !== nothing &&
                      err.code == _MTKC.ERROR_CODES.COMPILER_REFUSED_RULE
                # The shape esm-libraries-spec §2.5.10 fixes and the
                # compiler-agreement tier reads back: the compiler, the rule in
                # quotes, then the reason.
                @test err !== nothing &&
                      occursin(r"^compiler=:mtk refuses '.+': ", err.detail)
                @test err !== nothing && occursin(needle, err.detail)
                # Never a fallback — the refusal is the whole answer. Where
                # another compiler DOES run the document the message says so;
                # where none does it says how to rewrite it.
                @test err !== nothing &&
                      occursin("compiler=:native", err.detail) == points_elsewhere
            end
        end
        # …and the same document `:mtk` refuses for `D(a + b)` is one the tree
        # walk refuses too, which is why that message points at no compiler.
        walk = _mtkc_raise(esm_problem,
            _mtkc_uc("implicit_equation_as_the_derivative_of_an_expression.esm"),
            (0.0, 1.0))
        @test walk isa TreeWalkError && walk.code == "unsupported_construct"
    end

    # ── Agreement with the oracle ───────────────────────────────────────────
    @testset "agrees with :interpreter: $(basename(f))" for f in (
            _mtkc_fixture("valid", "solver_block.esm"),
            _mtkc_fixture("valid", "tests_analyses_comprehensive.esm"))
        pm = esm_problem(f, (0.0, 1.0); compiler = :mtk)
        pi = esm_problem(f, (0.0, 1.0); compiler = :interpreter)
        @test compiler(pm) === :mtk
        # Both compilers name the same states. The ORDER is each compiler's own
        # — `mtkcompile` chooses the compiled system's unknown order — which is
        # exactly why the comparison goes through `var_map` and not through the
        # position in the vector.
        @test Set(keys(pm.var_map)) == Set(keys(pi.var_map))
        sm = solve(pm, Rodas5P(); reltol = 1e-10, abstol = 1e-12, saveat = [1.0])
        si = solve(pi, Rodas5P(); reltol = 1e-10, abstol = 1e-12, saveat = [1.0])
        @test SciMLBase.successful_retcode(sm)
        for (nm, i) in pi.var_map
            got = sm.u[end][pm.var_map[nm]]
            want = si.u[end][i]
            @test isapprox(got, want; rtol = _MTKC_RTOL, atol = _MTKC_ATOL)
        end
    end

    # ── The problem surface ─────────────────────────────────────────────────
    @testset "the report, the readbacks and remake" begin
        prob = esm_problem(_mtkc_fixture("valid", "solver_block.esm"), (0.0, 1.0);
                           compiler = :mtk)
        rep = compiler_report(prob)
        @test rep isa _MTKC.CompilerReport
        @test rep.compiler === :mtk
        @test !isempty(rep.rules)
        for rec in rep.rules
            @test !isempty(rec.rule)
            @test rec.kind in (:equation, :observed, :event)
            @test startswith(String(rec.tier), "mtk_")
        end
        @test sum(n for (_, n) in _MTKC.tier_histogram(rep)) == length(rep.rules)
        @test occursin("compiler :mtk", sprint(show, prob))
        # `remake` swaps run knobs, not the build.
        @test compiler(remake(prob; tspan = (0.0, 2.0))) === :mtk
        # Every parameter of an `:mtk` build is `:structural`: its value is read
        # at BUILD and baked into the compiled problem, so changing one is an
        # explicit rebuild rather than a `p` swap.
        @test !isempty(parameter_classes(prob))
        @test all(v === :structural for v in values(parameter_classes(prob)))
        @test_throws SimulateError remake(prob; p = Dict("Decay.k" => 2.0))
    end

    # A sink's output callback is a SOLVE-TIME callback, and the compiled
    # system's events live on the problem it is solved against. DiffEq composes
    # the two; it does not let one replace the other. The witness is the value:
    # if the event callback had been dropped the sawtooth would read 2.5.
    @testset "a sink composes with the compiled system's events" begin
        sink = _MtkcSink()
        prob = esm_problem(_mtkc_uc("continuous_event_on_the_scalar_path.esm"),
                           (0.0, 2.5); compiler = :mtk, sinks = (sink,))
        @test callbacks(prob) !== nothing
        sol = solve(prob, Tsit5(); reltol = 1e-10, abstol = 1e-12)
        @test SciMLBase.successful_retcode(sol)
        @test sink.opened && sink.closed
        @test !isempty(sink.rows)
        @test last(sink.rows)[1] ≈ 2.5 atol = 1e-9
        @test only(last(sink.rows)[2]) ≈ 0.5 atol = 1e-6
    end

    @testset "observed_field reads the compiled system's observed equations" begin
        prob = esm_problem(_mtkc_obs_doc(), (0.0, 1.0); compiler = :mtk)
        @test only(observed_field(prob, "M.twice_k")) ≈ 1.0 rtol = 1e-12
        @test only(observed_field(prob, "twice_k")) ≈ 1.0 rtol = 1e-12
        # An override binds the build, so it is what the observed reports.
        prob2 = esm_problem(_mtkc_obs_doc(), (0.0, 1.0); compiler = :mtk,
                            p = Dict("k" => 1.25))
        @test only(observed_field(prob2, "M.twice_k")) ≈ 2.5 rtol = 1e-12
        # …and the same override is what the right-hand side integrates.
        sol = solve(prob2, Tsit5(); reltol = 1e-10, abstol = 1e-12)
        @test only(EarthSciAST.final_state(sol)) ≈ 2.0 * exp(-1.25) rtol = 1e-6
        # A STATE-DEPENDENT observed is not a build-time field, under this
        # compiler exactly as under `:native`.
        err = _mtkc_raise(observed_field, prob, "M.scaled")
        @test err isa SimulateError
        @test err !== nothing && occursin("state", err.msg)
        # A name that is not an observed at all.
        @test_throws SimulateError observed_field(prob, "M.nope")
    end
end
