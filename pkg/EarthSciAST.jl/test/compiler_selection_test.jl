# Choosing the compiler (API_SPEC §5.8, esm-libraries-spec §2.5.10).
#
# Four things are pinned here, and nothing else in the suite pins any of them:
#
#   * the closed VOCABULARY and its three failures — `compiler_unknown` outside
#     it, `compiler_unavailable` for a member this binding cannot provide, and
#     never an answer that quietly builds with a different compiler;
#   * the strict `native` TIER REPORT on the hardest document the cascade has —
#     one whose equation the whole-array contraction tier accepts, which `native`
#     takes only because that tier now emits its nest (a walked nest is what
#     §2.5.10 refuses), and which the `:interpreter` builds a different way and
#     agrees with bit for bit;
#   * AGREEMENT — `:native` and `:interpreter` produce bit-identical right-hand
#     sides and seeds on corpus fixtures that both run. This is the property the
#     interpreter exists for, so it is measured on documents of three different
#     shapes rather than on one;
#   * the REPORT — every rule of a build names a tier, and `show` says which
#     compiler ran.
using Test
using EarthSciAST
using OrdinaryDiffEqTsit5
const CSEL = EarthSciAST

const _CSEL_ROOT = normpath(joinpath(@__DIR__, "..", "..", ".."))
_csel_fixture(parts...) = joinpath(_CSEL_ROOT, "tests", parts...)

# A scalar ODE, a PDE-simulation diffusion fixture and a `faq` reduction: three
# shapes that route through three different arms of the cascade.
const _CSEL_AGREE = [
    _csel_fixture("fixtures", "faq", "01_pure_ode_analytical.esm"),
    _csel_fixture("conformance", "pde_simulation", "fixtures",
                  "diffusion_1d_periodic_n8.esm"),
    _csel_fixture("valid", "faq", "min_sum_tropical.esm"),
    _csel_fixture("valid", "faq", "join_on_self_join.esm"),
    # A document the affine tier DECLINES, so its equation is scalarized one
    # output cell at a time. That is a per-cell BUILD and `native` allows it:
    # the cell entries go on to the codegen tier and the right-hand side
    # carries no tree walk.
    _csel_fixture("valid", "faq", "join_moves_running_exhaust.esm"),
]

# ── A document the whole-array contraction tier ACCEPTS ──────────────────────
# `out[rcv] = Σ_s SR[s,rcv]·E[s]` from zero initial conditions, the
# source-receptor shape that tier exists for. `ESS_ARRAY_CONTRACTION_MIN` is a
# TUNING THRESHOLD (§2.5.10 keeps those), lowered here so the tier engages at a
# size the test can afford; the routing it produces is the same one a
# production-sized document gets at the default floor.
_csel_lhs(v, idx, n) = Dict("op" => "faq", "args" => Any[], "output_idx" => Any[idx],
    "ranges" => Dict(idx => Any[1, n]),
    "expr" => Dict("op" => "D", "args" => Any[
        Dict("op" => "index", "args" => Any[v, idx])], "wrt" => "t"))
_csel_zero(idx, n) = Dict("op" => "faq", "args" => Any[], "output_idx" => Any[idx],
    "ranges" => Dict(idx => Any[1, n]), "expr" => 0.0)

function _csel_contraction_doc(NS::Int = 16, NR::Int = 16)
    SR = [[Float64((3s + 7r) % 11) for r in 1:NR] for s in 1:NS]
    agg = Dict{String,Any}("op" => "faq", "args" => Any[],
        "output_idx" => Any["rcv"],
        "ranges" => Dict("rcv" => Any[1, NR], "s" => Any[1, NS]),
        "semiring" => "sum_product",
        "expr" => Dict("op" => "*", "args" => Any[
            Dict("op" => "index", "args" => Any[
                Dict("op" => "const", "args" => Any[], "value" => SR), "s", "rcv"]),
            Dict("op" => "index", "args" => Any["E", "s"])]))
    doc = Dict{String,Any}("esm" => "1.1.0",
        "metadata" => Dict("name" => "csel_sr"),
        "models" => Dict("R" => Dict{String,Any}(
            "variables" => Dict(
                "E"    => Dict("type" => "unknown", "shape" => Any["s"]),
                "conc" => Dict("type" => "unknown", "shape" => Any["rcv"])),
            "equations" => Any[
                Dict("lhs" => _csel_lhs("E", "s", NS), "rhs" => _csel_zero("s", NS)),
                Dict("lhs" => _csel_lhs("conc", "rcv", NR), "rhs" => agg)])))
    ics = merge(Dict{String,Any}("E[$s]" => Float64(s % 5) for s in 1:NS),
                Dict{String,Any}("conc[$r]" => 0.0 for r in 1:NR))
    return doc, ics
end

_csel_contraction_build(doc, ics; compiler) =
    withenv("ESS_ARRAY_CONTRACTION_MIN" => "8") do
        EarthSciAST._build_evaluator(doc; initial_conditions = ics, compiler = compiler)
    end

# `du` at the seeded state, so two builds can be compared element for element.
function _csel_du(prob)
    du = zeros(Float64, length(prob.u0))
    prob.f!(du, prob.u0, prob.p, prob.tspan[1])
    return du
end

@testset "choosing the compiler (§5.8)" begin

    @testset "the vocabulary is closed" begin
        @test CSEL.COMPILER_VOCABULARY ===
              (:interpreter, :native, :xla, :mtk, :sympy)
        doc = _CSEL_AGREE[1]

        # Outside the vocabulary.
        for bad in (:nope, :Native, :numpy, Symbol(""))
            e = try
                esm_problem(doc, (0.0, 1.0); compiler = bad)
                nothing
            catch err
                err
            end
            @test e isa SimulateError
            @test e.code == CSEL.ERROR_CODES.COMPILER_UNKNOWN
            # The message says what the vocabulary IS, so a caller who
            # misspelled one does not have to go and look it up.
            @test occursin(":interpreter", e.msg) && occursin(":native", e.msg)
        end

        # In the vocabulary, not provided by this binding / this SESSION. Each
        # one names what would have to be loaded or which binding has it — and
        # none of them silently builds with another compiler.
        #
        # `:xla` is in this list because of what is NOT loaded here, not because
        # of what is not implemented: it is the specialty compiler that needs a
        # heavy external dependency, so the answer is `compiler_unavailable`
        # naming Reactant in a session without it, and a BUILD in a session with
        # it (test/compiler_xla_test.jl gates that arm, under
        # `ESM_TEST_REACTANT=1`). The two arms must never trade places — an
        # unavailable compiler that quietly became `compiler_unknown` would tell
        # a caller the vocabulary had shrunk.
        @test Base.get_extension(EarthSciAST, :EarthSciASTReactantExt) === nothing
        for (v, needle) in ((:xla, "Reactant"), (:mtk, "ModelingToolkit"),
                            (:sympy, "Python"))
            e = try
                esm_problem(doc, (0.0, 1.0); compiler = v)
                nothing
            catch err
                err
            end
            @test e isa SimulateError
            @test e.code == CSEL.ERROR_CODES.COMPILER_UNAVAILABLE
            @test occursin(needle, e.msg)
        end
    end

    @testset "the default and a named :native are the same strict build" begin
        # §2.5.10: "oracle selection is an argument, not an environment
        # variable". No environment variable selects an evaluation strategy any
        # more, so there is no second way of saying which compiler runs — and
        # therefore nothing for the keyword to disagree with. Naming `:native`
        # and naming nothing must be the same build, tier for tier and bit for
        # bit, on the hardest document this file has.
        doc, ics = _csel_contraction_doc()
        runs = map(((), (; compiler = :native))) do kw
            insp = BuildInspection()
            f!, u0, p, _t, vm = withenv("ESS_ARRAY_CONTRACTION_MIN" => "8") do
                EarthSciAST._build_evaluator(doc; initial_conditions = ics, inspect = insp,
                                kw...)
            end
            du = zeros(Float64, length(u0))
            f!(du, u0, p, 0.0)
            (insp.compiler_report, [du[vm["conc[$r]"]] for r in 1:16])
        end
        for (rep, _) in runs
            @test rep.compiler === :native
            @test any(r -> r.tier === :array_contraction_codegen, rep.rules)
        end
        @test tier_histogram(runs[1][1]) == tier_histogram(runs[2][1])
        @test all(runs[1][2][r] === runs[2][2][r] for r in 1:16)
        # …and `:interpreter` runs the same document, since it turns the tier
        # off rather than taking what the tier accepts.
        @test withenv("ESS_ARRAY_CONTRACTION_MIN" => "8") do
            compiler(esm_problem(_CSEL_AGREE[1], (0.0, 1.0); compiler = :interpreter))
        end === :interpreter
    end

    @testset "strict :native compiles the whole-array contraction tier" begin
        doc, ics = _csel_contraction_doc()
        exact = [sum(Float64((3s + 7r) % 11) * Float64(s % 5) for s in 1:16)
                 for r in 1:16]
        insp = BuildInspection()
        f!, u0, p, _t, vm = withenv("ESS_ARRAY_CONTRACTION_MIN" => "8") do
            EarthSciAST._build_evaluator(doc; initial_conditions = ics, compiler = :native,
                            inspect = insp)
        end
        du = zeros(Float64, length(u0))
        f!(du, u0, p, 0.0)
        @test [du[vm["conc[$r]"]] for r in 1:16] == exact
        # The tier is named in the report, in its GENERATED form — the walked
        # one is what §2.5.10 refuses, so its absence is half the claim.
        rows = [r for r in insp.compiler_report.rules
                if r.tier === :array_contraction_codegen]
        @test length(rows) == 1
        @test occursin("conc", rows[1].rule)
        @test !any(r -> r.tier === :array_contraction,
                   insp.compiler_report.rules)

        # The SAME document under `:interpreter`, which turns the tier off and
        # reaches the answer through the per-cell path instead. `===` per
        # element: the two compilers agree bit for bit on the shape the tier
        # exists for, which is the property the interpreter exists to witness.
        fi!, ui, pi_, _ti, vmi = _csel_contraction_build(doc, ics;
                                                         compiler = :interpreter)
        dui = zeros(Float64, length(ui))
        fi!(dui, ui, pi_, 0.0)
        @test [dui[vmi["conc[$r]"]] for r in 1:16] == exact
        @test all(du[vm["conc[$r]"]] === dui[vmi["conc[$r]"]] for r in 1:16)
    end

    @testset "native and interpreter agree bit for bit: $(basename(f))" for f in _CSEL_AGREE
        pn = esm_problem(f, (0.0, 1.0))
        pi = esm_problem(f, (0.0, 1.0); compiler = :interpreter)
        @test compiler(pn) === :native
        @test compiler(pi) === :interpreter
        # `isequal`, not `==`: two evaluators that differ only in producing NaN
        # or -0.0 where the other does not are NOT in agreement.
        @test isequal(pn.u0, pi.u0)
        @test isequal(_csel_du(pn), _csel_du(pi))
        @test pn.var_map == pi.var_map
    end

    @testset "the report names every rule and a tier" begin
        for f in _CSEL_AGREE
            rep = compiler_report(esm_problem(f, (0.0, 1.0)))
            @test rep isa CSEL.CompilerReport
            @test rep.compiler === :native
            @test !isempty(rep.rules)
            for rec in rep.rules
                @test !isempty(rec.rule)
                @test rec.kind in (:equation, :observed, :setup_array)
                # Every landing is a NAMED tier; `:none` or an empty symbol
                # would make the record unreadable.
                @test rec.tier !== Symbol("")
            end
            # The histogram accounts for every rule exactly once.
            @test sum(n for (_, n) in CSEL.tier_histogram(rep)) == length(rep.rules)
        end
        # A scalar ODE's one equation lands on a tier that is named after the
        # cascade arm that took it, not after the compiler.
        rep = compiler_report(esm_problem(_CSEL_AGREE[1], (0.0, 1.0)))
        @test any(r -> occursin("PureODE.u", r.rule), rep.rules)
    end

    @testset "show says which compiler ran" begin
        pn = esm_problem(_CSEL_AGREE[1], (0.0, 1.0))
        pi = esm_problem(_CSEL_AGREE[1], (0.0, 1.0); compiler = :interpreter)
        @test occursin("compiler :native", sprint(show, pn))
        @test occursin("compiler :interpreter", sprint(show, pi))
        # The tier histogram rides along, so the printed problem says where the
        # work went and not only what asked for it.
        @test occursin("[", sprint(show, pn))
        # `remake` carries the record: it swaps `p`/`u0`/`tspan`, not the build.
        @test compiler(remake(pn; tspan = (0.0, 2.0))) === :native
    end

    @testset "BuildInspection carries the report" begin
        insp = BuildInspection()
        esm_problem(_CSEL_AGREE[1], (0.0, 1.0); inspect = insp)
        @test insp.compiler_report.compiler === :native
        @test !isempty(insp.compiler_report.rules)
        # …and it is filled even when the build THREW, which is the case a
        # caller most wants the partial record for. The document below files one
        # rule on the contraction tier and then hands the tier the SAME output
        # cells a second time, which `covered` refuses.
        doc, ics = _csel_contraction_doc()
        eqs = doc["models"]["R"]["equations"]
        push!(eqs, eqs[2])
        insp2 = BuildInspection()
        @test_throws TreeWalkError withenv("ESS_ARRAY_CONTRACTION_MIN" => "8") do
            EarthSciAST._build_evaluator(doc; initial_conditions = ics, inspect = insp2,
                            compiler = :native)
        end
        @test insp2.compiler_report.compiler === :native
        @test any(r -> r.tier === :array_contraction_codegen,
                  insp2.compiler_report.rules)
    end

    @testset "build_evaluator has left the public surface" begin
        # API_SPEC §8 item 23: the extension seam under the runners is retired.
        # It is not EXPORTED any more — `esm_problem` is the way in — and the
        # name that remains is a deprecated alias kept for one minor version so
        # a downstream package keeps running while it migrates.
        @test !(:build_evaluator in names(EarthSciAST))
        @test :esm_problem in names(EarthSciAST)
        # The alias still builds, and builds the same thing the private entry
        # point does: a deprecation that changed the answer would be a second
        # break hiding inside the first.
        file = load_path(_CSEL_AGREE[1])
        dep = @test_logs (:warn,) match_mode = :any CSEL.build_evaluator(file)
        priv = CSEL._build_evaluator(load_path(_CSEL_AGREE[1]))
        @test isequal(dep[2], priv[2])          # u0
        @test dep[5] == priv[5]                 # var_map
        du_dep = zeros(length(dep[2])); dep[1](du_dep, dep[2], dep[3], 0.0)
        du_priv = zeros(length(priv[2])); priv[1](du_priv, priv[2], priv[3], 0.0)
        @test isequal(du_dep, du_priv)

        # What the seam used to publish now hangs on the Problem, for every
        # compiler rather than only for the out-of-place build form.
        prob = esm_problem(_CSEL_AGREE[1], (0.0, 1.0))
        @test forcing_buffers(prob) isa NamedTuple
        @test forcing_buffer_index(prob) isa Dict{String,Int}
        @test length(forcing_buffers(prob)) == length(forcing_buffer_index(prob))
        insp = BuildInspection()
        esm_problem(_CSEL_AGREE[1], (0.0, 1.0); inspect = insp)
        @test compiler_report(insp) === insp.compiler_report
        @test compiler_report(insp).compiler === :native
    end

    @testset "run_inline_tests takes a compiler" begin
        f = _CSEL_AGREE[1]
        native = run_inline_tests(f)
        interp = run_inline_tests(f; compiler = :interpreter)
        @test !isempty(native)
        @test length(native) == length(interp)
        @test all(r -> r.passed, native)
        @test all(r -> r.passed, interp)
        # The per-document option wins over the keyword, the same precedence
        # every other `InlineTestOptions` field has.
        viaopts = run_inline_tests(f;
            options_for = _ -> InlineTestOptions(compiler = :interpreter))
        @test length(viaopts) == length(native)
        @test all(r -> r.passed, viaopts)
    end
end
