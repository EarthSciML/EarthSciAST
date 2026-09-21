# Choosing the compiler (API_SPEC §5.8, esm-libraries-spec §2.5.10).
#
# Four things are pinned here, and nothing else in the suite pins any of them:
#
#   * the closed VOCABULARY and its three failures — `compiler_unknown` outside
#     it, `compiler_unavailable` for a member this binding cannot provide, and
#     never an answer that quietly builds with a different compiler;
#   * the strict `native` REFUSAL — a document whose equation the whole-array
#     contraction tier accepts refuses at construction with the rule named, and
#     the SAME document builds under `:interpreter`;
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
# size the test can afford; the refusal it produces is the same one a
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
        build_evaluator(doc; initial_conditions = ics, compiler = compiler)
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

        # In the vocabulary, not provided by this binding / this phase. Each one
        # names what would have to be loaded or which binding has it — and none
        # of them silently builds with another compiler.
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

    @testset "an explicit :native refuses to run beside an oracle kill switch" begin
        # §2.5.10: "oracle selection is an argument, not an environment
        # variable". While the switches survive (they retire a phase later), a
        # caller who NAMED `:native` and has one set would get a build that is
        # not the compiler they named, so the two ways of saying it are refused
        # together rather than silently resolved one way.
        doc = _CSEL_AGREE[1]
        e = withenv("ESS_CODEGEN_DISABLE" => "1") do
            try
                esm_problem(doc, (0.0, 1.0); compiler = :native)
                nothing
            catch err
                err
            end
        end
        @test e isa SimulateError
        @test e.code == CSEL.ERROR_CODES.COMPILER_UNAVAILABLE
        @test occursin("ESS_CODEGEN_DISABLE", e.msg)
        # An UNNAMED compiler beside a switch is a NON-STRICT native: the
        # switch is a request for the reference path, so refusing the rule it
        # just forced would make the switch unusable, and the differential
        # tests built on the switches keep working until they are retired.
        @test withenv("ESS_CODEGEN_DISABLE" => "1") do
            compiler(esm_problem(doc, (0.0, 1.0)))
        end === :native
        # …and the strictness is back the moment the switch is not set.
        @test_throws TreeWalkError withenv("ESS_ARRAY_CONTRACTION_MIN" => "8") do
            d, i = _csel_contraction_doc()
            build_evaluator(d; initial_conditions = i)
        end
        # …and `:interpreter` is unaffected, since it turns the tier off anyway.
        @test withenv("ESS_CODEGEN_DISABLE" => "1") do
            compiler(esm_problem(doc, (0.0, 1.0); compiler = :interpreter))
        end === :interpreter
    end

    @testset "strict :native refuses the whole-array contraction tier" begin
        doc, ics = _csel_contraction_doc()
        e = try
            _csel_contraction_build(doc, ics; compiler = :native)
            nothing
        catch err
            err
        end
        @test e isa TreeWalkError
        @test e.code == CSEL.ERROR_CODES.COMPILER_REFUSED_RULE
        # The message names the compiler, the rule and the reason — the three
        # things §2.5.10 fixes.
        @test occursin("compiler=:native", e.detail)
        @test occursin("D(conc)", e.detail)          # the rule, by its target
        @test occursin("per output cell", e.detail)  # the reason

        # The SAME document under `:interpreter`, which promises nothing about
        # speed and therefore refuses nothing.
        f!, u0, p, _t, vm = _csel_contraction_build(doc, ics; compiler = :interpreter)
        du = zeros(Float64, length(u0))
        f!(du, u0, p, 0.0)
        exact = [sum(Float64((3s + 7r) % 11) * Float64(s % 5) for s in 1:16)
                 for r in 1:16]
        @test [du[vm["conc[$r]"]] for r in 1:16] == exact
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
        # …and it is filled even when the build REFUSED, which is the case a
        # caller most wants the partial record for.
        doc, ics = _csel_contraction_doc()
        insp2 = BuildInspection()
        @test_throws TreeWalkError withenv("ESS_ARRAY_CONTRACTION_MIN" => "8") do
            build_evaluator(doc; initial_conditions = ics, inspect = insp2,
                            compiler = :native)
        end
        @test insp2.compiler_report.compiler === :native
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
