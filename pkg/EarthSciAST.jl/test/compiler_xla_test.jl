# `esm_problem(…; compiler = :xla)` — the direct StableHLO emitter on the SOLVE
# path (API_SPEC §5.8, src/compiler_xla.jl, ext/reactant_direct/problem.jl).
#
# OPT-IN, like every reactant_*_test.jl: included only under
# `ESM_TEST_REACTANT=1`. Standalone, from an environment with Reactant:
#
#     ESM_TEST_REACTANT=1 julia --project=<env> \
#       -e 'cd("pkg/EarthSciAST.jl/test"); include("compiler_xla_test.jl")'
#
# reactant_direct_emit_test.jl gates the EMITTER — one right-hand side, at fixed
# probe states, against the interpreter's. This file gates the PROBLEM: that the
# keyword reaches the emitter at all, that what comes back is a Problem whose
# public surface is the one every other compiler produces, that a whole RUN
# through it agrees with the `interpreter` — the oracle §5.8 keeps for exactly
# this — and that the three things it refuses (a non-Float64 call, live
# forcing buffers, a construct the emitter cannot lower) are refused BY NAME
# rather than answered by another evaluator.
#
# THE TWO BANDS, and where each comes from
# (tests/conformance/compiler_agreement/manifest.json):
#
#   1e-12  the `transcendental` tolerance class, for a right-hand side compared
#          at a fixed state: no integration has happened, so nothing but the
#          arithmetic is being compared.
#   1e-8   that class plus §5.44.2's integration safety factor on the solve
#          tolerances used here (1e-12 + 100 × 1e-10). A solver's `reltol`
#          bounds its LOCAL error per step while a trajectory carries the
#          GLOBAL one, so without the factor the test would demand that two
#          correct integrations of the same program agree better than either
#          promises to be right.
#
# Agreement is NUMERICAL, never bitwise: `stablehlo.power` is not Julia's `^`,
# and XLA may reassociate a fold (see ext/reactant_direct/api.jl).

using Test
using EarthSciAST
using Reactant
using SciMLBase
using OrdinaryDiffEqTsit5
using OrdinaryDiffEqRosenbrock

const CX = EarthSciAST
const CX_EXT = Base.get_extension(EarthSciAST, :EarthSciASTReactantExt)
@assert CX_EXT !== nothing "the Reactant extension did not load"

const CX_ROOT = normpath(joinpath(@__DIR__, "..", "..", ".."))
_cx_fixture(parts...) = joinpath(CX_ROOT, "tests", parts...)

# Two documents of two different shapes, both already in the
# `compiler_agreement` tier: an ARRAY document whose equation is a stencil fold
# over a `makearray` region, and the smallest SCALAR ODE with a parameter.
const CX_ARRAY = _cx_fixture("fixtures", "faq", "15_discretized_1d_heat.esm")
const CX_SCALAR = _cx_fixture("valid", "solver_block.esm")

# ---- the live-forcing document -----------------------------------------------
#
# `D(c[i]) = -k*c[i] + wind[i]`, with `wind` a LIVE forcing buffer bound BY
# REFERENCE through the `param_arrays` seam — the discrete-cadence loader
# channel, and the one shape `:xla` refuses on this entry point. Built here
# rather than taken from the corpus because no corpus fixture binds one without
# a data provider to go with it.
_cx_Dt(v) = Dict{String,Any}("op" => "D", "args" => Any[v], "wrt" => "t")
_cx_ix(v, i...) = Dict{String,Any}("op" => "index", "args" => Any[v, i...])
_cx_o(o, a...) = Dict{String,Any}("op" => o, "args" => Any[a...])
_cx_ao(e) = Dict{String,Any}("op" => "faq", "output_idx" => Any["i"],
    "ranges" => Dict{String,Any}("i" => Dict{String,Any}("from" => "n")),
    "args" => Any[], "expr" => e)

function _cx_forced(N)
    body = _cx_o("+", _cx_o("*", -1.0, _cx_o("*", "k", _cx_ix("c", "i"))),
                 _cx_ix("wind", "i"))
    Dict{String,Any}(
        "esm" => "1.1.0", "metadata" => Dict{String,Any}("name" => "Forced"),
        "index_sets" => Dict{String,Any}(
            "n" => Dict{String,Any}("kind" => "interval", "size" => N)),
        "models" => Dict{String,Any}("M" => Dict{String,Any}(
            "variables" => Dict{String,Any}(
                "c" => Dict{String,Any}("type" => "unknown", "shape" => Any["n"]),
                "k" => Dict{String,Any}("type" => "parameter", "default" => 0.5)),
            "equations" => Any[Dict{String,Any}(
                "lhs" => _cx_ao(_cx_Dt(_cx_ix("c", "i"))),
                "rhs" => _cx_ao(body))])))
end

# `D(y) = -(y / 2 / 3)` with the division spelled as ONE three-argument `/`:
# a document `native` builds and the direct emitter has no lowering for, so it
# is the emitter's own refusal, not the build's, that `:xla` has to name.
function _cx_unsupported()
    Dict{String,Any}(
        "esm" => "1.1.0", "metadata" => Dict{String,Any}("name" => "U"),
        "models" => Dict{String,Any}("U" => Dict{String,Any}(
            "variables" => Dict{String,Any}(
                "y" => Dict{String,Any}("type" => "unknown", "default" => 2.0)),
            "equations" => Any[Dict{String,Any}(
                "lhs" => _cx_Dt("y"),
                "rhs" => _cx_o("neg", _cx_o("/", "y", 2.0, 3.0)))])))
end

_cx_catch(f) = try
    f(); nothing
catch e
    e
end

_cx_has_gpu() = try
    Reactant.XLA.client("gpu"); true
catch
    false
end

# A deterministic, non-trivial state: a document seeded to zeros would let a
# right-hand side that answered zero for every input pass.
_cx_state(n) = Float64[0.4 + 0.3 * sin(0.7 * i) for i in 1:n]

_cx_du(prob, u, t) = (du = zeros(Float64, length(u));
                      prob.f!(du, u, prob.p, t); du)

@testset "compiler = :xla — the Problem (§5.8)" begin

    @testset "a Problem whose right-hand side is the compiled program: $(basename(f))" for f in
            (CX_ARRAY, CX_SCALAR)
        span = (0.0, 0.05)
        pi_ = esm_problem(f, span; compiler = :interpreter)
        px = esm_problem(f, span; compiler = :xla)

        # The SURFACE is the one every compiler produces: same layout, same
        # seed, same parameters. A compiler chooses how the derivative is
        # computed and nothing else.
        @test compiler(px) === :xla
        @test px.var_map == pi_.var_map
        @test isequal(px.u0, pi_.u0)
        @test px.tspan == pi_.tspan
        @test keys(px.p === nothing ? NamedTuple() : px.p) ==
              keys(pi_.p === nothing ? NamedTuple() : pi_.p)

        # The right-hand side itself, at three states and three times, against
        # the oracle. This is what the keyword bought.
        u = _cx_state(length(px.u0))
        for (uu, t) in ((px.u0, 0.0), (u, 0.0), (u, 0.03))
            dx = _cx_du(px, copy(uu), t)
            di = _cx_du(pi_, copy(uu), t)
            @test length(dx) == length(di)
            @test all(isapprox(dx[k], di[k]; rtol = 1e-12, atol = 1e-300)
                      for k in eachindex(dx))
        end

        # A whole RUN, which is the tier's question: one compile serves every
        # step, every stage and every save.
        saveat = [0.025, 0.05]
        sx = SciMLBase.solve(remake(px; u0 = copy(u)), Tsit5();
                             reltol = 1e-10, abstol = 1e-12, saveat = saveat)
        si = SciMLBase.solve(remake(pi_; u0 = copy(u)), Tsit5();
                             reltol = 1e-10, abstol = 1e-12, saveat = saveat)
        @test SciMLBase.successful_retcode(sx)
        @test sx.t == si.t
        for k in eachindex(sx.u)
            @test all(isapprox(sx.u[k][j], si.u[k][j]; rtol = 1e-8, atol = 1e-12)
                      for j in eachindex(sx.u[k]))
        end
    end

    @testset "the report names the emitter and the device" begin
        px = esm_problem(CX_SCALAR, (0.0, 1.0); compiler = :xla)
        rep = compiler_report(px)
        @test rep.compiler === :xla
        # The per-rule cascade rows are `native`'s — under `:xla` they say how
        # each rule was lowered INTO the representation the emitter walked —
        # plus exactly one row for the assembled program.
        prog = [r for r in rep.rules if r.kind === :rhs_program]
        @test length(prog) == 1
        @test prog[1].rule == "the right-hand side"
        @test prog[1].tier === :xla_direct_cpu   # ESM_TEST_REACTANT runs on the host client
        @test any(r -> r.kind === :equation, rep.rules)
        # The emitter's op census rides in the tally, so a caller can see that a
        # program was emitted rather than take the row's word for it.
        @test any(k -> startswith(String(k), "xla_"), keys(rep.tally))
        @test occursin("compiler :xla", sprint(show, px))
    end

    @testset "remake(prob; p) re-parameterizes without recompiling" begin
        px = esm_problem(CX_SCALAR, (0.0, 1.0); compiler = :xla)
        pi_ = esm_problem(CX_SCALAR, (0.0, 1.0); compiler = :interpreter)
        numeric = sort!([k for (k, c) in parameter_classes(px) if c === :numeric])
        @test !isempty(numeric)
        name = first(numeric)
        base = getfield(px.p, Symbol(name))
        px2 = remake(px; p = Dict(name => 1.7 * base))
        pi2 = remake(pi_; p = Dict(name => 1.7 * base))
        # The SAME compiled program — `p` is a program INPUT, so a swap is seen
        # without a retrace.
        @test px2.f! === px.f!
        u = _cx_state(length(px.u0))
        @test all(isapprox(a, b; rtol = 1e-12, atol = 1e-300)
                  for (a, b) in zip(_cx_du(px2, copy(u), 0.0),
                                    _cx_du(pi2, copy(u), 0.0)))
        # …and it really moved: the new parameter answers differently from the
        # old one, so the test above is not comparing two stale programs.
        @test _cx_du(px2, copy(u), 0.0) != _cx_du(px, copy(u), 0.0)
    end

    @testset "what :xla refuses, it refuses BY NAME" begin
        # A NON-Float64 call. This is what a stiff algorithm's
        # forward-differentiated Jacobian does to a compiled device program, and
        # the refusal has to name the way out rather than widen a `Dual` into a
        # Float64 and answer a wrong derivative.
        px = esm_problem(CX_SCALAR, (0.0, 1.0); compiler = :xla)
        err = try
            px.f!(zeros(Float32, length(px.u0)), Float32.(px.u0), px.p, 0.0f0)
            nothing
        catch e
            e
        end
        @test err isa TreeWalkError
        @test err.code == CX.ERROR_CODES.COMPILER_REFUSED_RULE
        @test occursin("compiler=:xla refuses", err.detail)
        @test occursin("Float64", err.detail)

        # A model binding LIVE FORCING BUFFERS. The compiled program takes them
        # as arguments and needs them re-synced to the device at each cadence
        # boundary; this entry point does not wire that refresh, and the
        # buffer-free form would bake the build-time forcing in as a constant.
        # So it is a named refusal, never a silently stale answer.
        err2 = try
            esm_problem(_cx_forced(6), (0.0, 1.0); compiler = :xla,
                        param_arrays = Dict("wind" => collect(1.0:6.0)))
            nothing
        catch e
            e
        end
        @test err2 isa TreeWalkError
        @test err2.code == CX.ERROR_CODES.COMPILER_REFUSED_RULE
        @test occursin("compiler=:xla refuses 'live forcing buffers", err2.detail)
        @test occursin("wind", err2.detail)
        # The same document builds under `:native`, so the refusal is the
        # compiler's statement about itself and not a broken document.
        @test compiler(esm_problem(_cx_forced(6), (0.0, 1.0);
                                   param_arrays = Dict("wind" => collect(1.0:6.0)))) ===
              :native
        # …and it is refused BEFORE the build: the build files its report on
        # the inspection sink even when it throws, so a sink still carrying the
        # empty default proves no build ran. At continental scale that build is
        # the expensive part.
        insp = BuildInspection()
        err3 = _cx_catch(() -> esm_problem(_cx_forced(6), (0.0, 1.0);
                                           compiler = :xla, inspect = insp,
                                           param_arrays = Dict("wind" => collect(1.0:6.0))))
        @test err3 isa TreeWalkError
        @test err3.code == CX.ERROR_CODES.COMPILER_REFUSED_RULE
        @test isempty(insp.compiler_report.rules)
        @test insp.compiler_report.compiler === :native   # the untouched default

        # A construct the EMITTER cannot lower. `Reactant.@compile` may hand the
        # emitter's `DirectEmitError` back wrapped; either way it has to come
        # out as the named refusal, never as an anonymous failure.
        err4 = _cx_catch(() -> esm_problem(_cx_unsupported(), (0.0, 1.0);
                                           compiler = :xla))
        @test err4 isa TreeWalkError
        @test err4.code == CX.ERROR_CODES.COMPILER_REFUSED_RULE
        @test occursin("compiler=:xla refuses '", err4.detail)
        @test occursin("state equation", err4.detail)
        @test occursin("cannot lower", err4.detail)
        @test occursin("`/`", err4.detail)
        # `native` builds the same document, so this is the emitter's refusal.
        @test compiler(esm_problem(_cx_unsupported(), (0.0, 1.0))) === :native
    end

    @testset "the device: a typo is a configuration error, a missing GPU is unavailable" begin
        # A misspelled device is NOT `compiler_unavailable`: a conformance run
        # reads that as an optional binding to skip, and would pass without
        # running anything. Refused before the document is loaded.
        err = withenv(CX.XLA_DEVICE_ENV => "cuda") do
            _cx_catch(() -> esm_problem("no/such/file.esm", (0.0, 1.0);
                                        compiler = :xla))
        end
        @test err isa ArgumentError
        @test occursin(CX.XLA_DEVICE_ENV, err.msg)
        @test occursin("'cuda'", err.msg)

        # A well-formed request this process cannot serve IS unavailable, and
        # is answered before the load too.
        if !_cx_has_gpu()
            err2 = withenv(CX.XLA_DEVICE_ENV => "gpu") do
                _cx_catch(() -> esm_problem("no/such/file.esm", (0.0, 1.0);
                                            compiler = :xla))
            end
            @test err2 isa SimulateError
            @test err2.code == CX.ERROR_CODES.COMPILER_UNAVAILABLE
            @test occursin("'gpu'", err2.msg)
        end
    end

    @testset "the build: :xla is the out-of-place product, never the in-place evaluator" begin
        # The in-place evaluator is `native`'s; handing it back under an `:xla`
        # report would be a fallback in everything but name.
        err = _cx_catch(() -> CX._build_evaluator(load_path(CX_SCALAR);
                                                  compiler = :xla))
        @test err isa ArgumentError
        @test occursin("form = :oop", err.msg)
        insp = BuildInspection()
        fo, _, _, _, _ = CX._build_evaluator(load_path(CX_SCALAR); compiler = :xla,
                                             form = :oop, inspect = insp)
        @test fo isa CX._OopRHS
        @test insp.compiler_report.compiler === :xla
    end

    @testset "a stiff algorithm runs on the compiled program, with no setting" begin
        # A stiff algorithm forward-differentiates the right-hand side for its
        # Jacobian unless the `ODEFunction` carries one. The Problem carries a
        # finite-difference one, so `Rosenbrock23()` with its DEFAULTS runs —
        # which is what `run_inline_tests`' own stiff pick hands it.
        px = esm_problem(CX_SCALAR, (0.0, 1.0); compiler = :xla)
        pi_ = esm_problem(CX_SCALAR, (0.0, 1.0); compiler = :interpreter)
        sx = SciMLBase.solve(px, Rosenbrock23(); reltol = 1e-8, abstol = 1e-10,
                             saveat = [0.5, 1.0])
        si = SciMLBase.solve(pi_, Rosenbrock23(); reltol = 1e-8, abstol = 1e-10,
                             saveat = [0.5, 1.0])
        @test SciMLBase.successful_retcode(sx)
        # A finite-difference Jacobian changes the step sequence, not the
        # solution: agreement at the integration tolerance, not bitwise.
        for k in eachindex(sx.u)
            @test all(isapprox(sx.u[k][j], si.u[k][j]; rtol = 1e-6, atol = 1e-9)
                      for j in eachindex(sx.u[k]))
        end
        # The document declares `solver.stiffness: "high"`, so the inline-test
        # runner picks the stiff algorithm itself.
        rs = run_inline_tests(CX_SCALAR; compiler = :xla)
        @test !isempty(rs)
        @test all(r -> r.passed, rs)
    end
end
