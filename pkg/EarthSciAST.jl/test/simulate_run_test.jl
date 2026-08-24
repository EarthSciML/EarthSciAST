using Test
using EarthSciAST
import SciMLBase
import SciMLBase: solve, remake, ReturnCode, successful_retcode
import OrdinaryDiffEqTsit5: Tsit5
using JSON3
const ESM_S = EarthSciAST

include("testutils.jl")  # TESTUTILS_REPO_ROOT (idempotent; standalone runs too)

# `esm_problem` + `solve` — the two-step run surface (esm-libraries-spec §2.5):
# construction coerces → build_evaluator → seeds → composes callbacks, and the
# verb is SciML's own `solve`, specialized on `ESMProblem` in the SciMLBase
# extension (active here: the test target loads SciMLBase + OrdinaryDiffEqTsit5).
#
# An authored document is FLATTENED whichever carrier it arrives in (path, Dict,
# EsmFile), so every name below is the flattener's namespaced one — `"M.y"`, not
# `"y"`. Only a `FlattenedSystem` skips the flattener.
@testset "esm_problem + solve run entry" begin
    _D(v) = Dict{String,Any}("op" => "D", "args" => Any[v], "wrt" => "t")
    _idx(v, i) = Dict{String,Any}("op" => "index", "args" => Any[v, i])
    scalar_esm(rhs) = Dict{String,Any}(
        "esm" => "0.5.0", "metadata" => Dict{String,Any}("name" => "S"),
        "models" => Dict{String,Any}("M" => Dict{String,Any}(
            "variables" => Dict{String,Any}("y" => Dict{String,Any}("type" => "unknown")),
            "equations" => Any[Dict{String,Any}("lhs" => _D("y"), "rhs" => rhs)])))

    # Chemistry `A --k1--> B` plus an additive `couple` edge Sink.k → Chem.A folding
    # `(-k)*A` ONTO that tendency, so D(Chem.A) ~ -k1*A - k*A and A(t) = A0*exp(-(k1+k)t).
    # Exercises BOTH constructs that only `flatten` applies (reaction lowering and the
    # coupling block), so it is the fixture for the carrier test and the connector test.
    #
    # The chemistry term is what makes it discriminating: exp(-(k1+k)t) separates
    # `additive` from a DROPPED edge (exp(-k1*t)) and from `replacement` (exp(-k*t)).
    # An empty `reactions` list would leave the RHS at 0 and make all three identical —
    # and is schema-invalid besides (`reactions` has minItems: 1).
    K1, KSINK, A0 = 0.3, 0.1, 2.0
    additive_couple_esm() = Dict{String,Any}(
        "esm" => "0.8.0", "metadata" => Dict{String,Any}("name" => "AdditiveCouple"),
        "reaction_systems" => Dict{String,Any}("Chem" => Dict{String,Any}(
            "species" => Dict{String,Any}(
                "A" => Dict{String,Any}("default" => A0, "units" => "mol/mol"),
                "B" => Dict{String,Any}("default" => 0.0, "units" => "mol/mol")),
            "parameters" => Dict{String,Any}(),
            "reactions" => Any[Dict{String,Any}(
                "id" => "R1",
                "substrates" => Any[Dict{String,Any}("stoichiometry" => 1, "species" => "A")],
                "products" => Any[Dict{String,Any}("stoichiometry" => 1, "species" => "B")],
                "rate" => K1)])),
        "models" => Dict{String,Any}("Sink" => Dict{String,Any}(
            "variables" => Dict{String,Any}("k" =>
                Dict{String,Any}("type" => "parameter", "default" => KSINK)),
            "equations" => Any[])),
        "coupling" => Any[Dict{String,Any}(
            "type" => "couple", "systems" => Any["Chem", "Sink"],
            "connector" => Dict{String,Any}("equations" => Any[Dict{String,Any}(
                "from" => "Sink.k", "to" => "Chem.A", "transform" => "additive",
                "expression" => Dict{String,Any}("op" => "*", "args" => Any[
                    Dict{String,Any}("op" => "-", "args" => Any["Sink.k"]),
                    "Chem.A"]))]))])

    @testset "scalar ODE D(y)=1 over [0,2] → 2" begin
        r = solve(ESM_S.esm_problem(scalar_esm(1.0), (0.0, 2.0);
                           u0 = Dict("M.y" => 0.0)), Tsit5())
        @test r.retcode == ReturnCode.Success && successful_retcode(r)
        @test isapprox(r[Symbol("M.y")][end], 2.0; atol = 1e-6)
        @test length(r.t) == length(r.u)
    end

    @testset "parameter override D(y)=k, k=2.5, [0,3] → 7.5" begin
        esm = scalar_esm("k")
        esm["models"]["M"]["variables"]["k"] = Dict{String,Any}("type" => "parameter", "default" => 1.0)
        r = solve(ESM_S.esm_problem(esm, (0.0, 3.0);
                           p = Dict("M.k" => 2.5), u0 = Dict("M.y" => 0.0)), Tsit5())
        @test isapprox(r[Symbol("M.y")][end], 7.5; atol = 1e-5)
    end

    # The bug this guards: `build_evaluator` runs ONE model and never reads
    # `reaction_systems` / `coupling` (both are applied BY `flatten`). `simulate`
    # used to hand a Dict straight to it, so an authored document ran as its lone
    # `Sink` model — reaction network and coupling edge dropped — and still
    # reported a Success retcode, with an EMPTY state vector.
    @testset "an authored Dict is flattened, not run as one model" begin
        esm = additive_couple_esm()

        prob = ESM_S.esm_problem(esm, (0.0, 1.0))
        r = solve(prob, Tsit5())
        @test successful_retcode(r)
        # The reaction system was lowered (it carries BOTH species) — the old path
        # selected the `Sink` model alone and produced no states whatsoever.
        @test Set(keys(prob.var_map)) == Set(["Chem.A", "Chem.B"])
        # …and §2.5.7: the solution is indexed by NAME, through
        # SymbolicIndexingInterface, not by position in the state vector.
        @test Set(SciMLBase.SymbolicIndexingInterface.variable_symbols(r)) ==
              Set([Symbol("Chem.A"), Symbol("Chem.B")])
        # ...and the coupling edge was applied: A decays at K1 + KSINK, not K1 alone.
        @test isapprox(r[Symbol("Chem.A")][end], A0 * exp(-(K1 + KSINK)); rtol = 1e-4)
        @test !isapprox(r[Symbol("Chem.A")][end], A0 * exp(-K1); rtol = 1e-2)

        # Same document, every carrier: a Dict, a file, and an EsmFile are one
        # document and must give one system.
        mktempdir() do dir
            path = joinpath(dir, "authored.esm")
            write(path, JSON3.write(esm))
            rp = solve(ESM_S.esm_problem(path, (0.0, 1.0)), Tsit5())
            rf = solve(ESM_S.esm_problem(ESM_S.load_path(path), (0.0, 1.0)), Tsit5())
            @test rp[Symbol("Chem.A")][end] == r[Symbol("Chem.A")][end]
            @test rf[Symbol("Chem.A")][end] == r[Symbol("Chem.A")][end]
        end
    end

    # A raw Dict now gets the schema validation a path input always had — the
    # gate that a `reactions: []` fixture (schema `minItems: 1`) must not pass.
    @testset "a schema-invalid Dict is rejected, not silently run" begin
        bad = scalar_esm(1.0)
        bad["models"]["M"]["variables"]["y"] = Dict{String,Any}("type" => "not_a_type")
        @test_throws ESM_S.SchemaValidationError solve(ESM_S.esm_problem(bad, (0.0, 1.0)), Tsit5())
    end

    @testset "array state with seed_ic! + element IC override" begin
        esm = Dict{String,Any}(
            "esm" => "0.5.0", "metadata" => Dict{String,Any}("name" => "A"),
            "index_sets" => Dict{String,Any}("n" => Dict{String,Any}("kind" => "interval", "size" => 3)),
            "models" => Dict{String,Any}("M" => Dict{String,Any}(
                "variables" => Dict{String,Any}("u" => Dict{String,Any}("type" => "unknown", "shape" => Any["n"])),
                "equations" => Any[Dict{String,Any}(
                    "lhs" => Dict{String,Any}("op" => "arrayop", "output_idx" => Any["i"],
                        "ranges" => Dict{String,Any}("i" => Dict{String,Any}("from" => "n")), "args" => Any[], "expr" => _D(_idx("u", "i"))),
                    "rhs" => Dict{String,Any}("op" => "arrayop", "output_idx" => Any["i"],
                        "ranges" => Dict{String,Any}("i" => Dict{String,Any}("from" => "n")), "args" => Any[], "expr" => _idx("u", "i")))])))
        seed! = (u0, vm) -> (u0[vm["M.u[2]"]] = 2.0; u0[vm["M.u[3]"]] = 3.0)
        r = solve(ESM_S.esm_problem(esm, (0.0, 1.0);
                           u0 = Dict("M.u[1]" => 1.0), seed_ic! = seed!), Tsit5())
        got = [r[Symbol("M.u[1]")][end], r[Symbol("M.u[2]")][end], r[Symbol("M.u[3]")][end]]
        @test all(isapprox.(got, [1.0, 2.0, 3.0] .* exp(1); rtol = 1e-3))
    end

    @testset "seed_expression_ic! over a grid" begin
        # u[i] state on a 4-cell axis; seed u(x) = x^2 at coords [10,20,30,40].
        esm = Dict{String,Any}(
            "esm" => "0.5.0", "metadata" => Dict{String,Any}("name" => "G"),
            "index_sets" => Dict{String,Any}("n" => Dict{String,Any}("kind" => "interval", "size" => 4)),
            "models" => Dict{String,Any}("M" => Dict{String,Any}(
                "variables" => Dict{String,Any}("u" => Dict{String,Any}("type" => "unknown", "shape" => Any["n"])),
                "equations" => Any[Dict{String,Any}(
                    "lhs" => Dict{String,Any}("op" => "arrayop", "output_idx" => Any["i"],
                        "ranges" => Dict{String,Any}("i" => Dict{String,Any}("from" => "n")), "args" => Any[], "expr" => _D(_idx("u", "i"))),
                    "rhs" => Dict{String,Any}("op" => "arrayop", "output_idx" => Any["i"],
                        "ranges" => Dict{String,Any}("i" => Dict{String,Any}("from" => "n")), "args" => Any[], "expr" => 0.0))])))
        expr = expression_from_json(Dict{String,Any}("op" => "*", "args" => Any["x", "x"]))
        seed! = (u0, vm) -> seed_expression_ic!(u0, vm, "M.u", expr, ["x" => [10.0, 20.0, 30.0, 40.0]])
        r = solve(ESM_S.esm_problem(esm, (0.0, 1.0); seed_ic! = seed!), Tsit5())   # D(u)=0 → IC preserved
        @test [r[Symbol("M.u[$i]")][end] for i in 1:4] == [100.0, 400.0, 900.0, 1600.0]
    end

    @testset "missing alg → clear error" begin
        @test_throws ESM_S.SimulateError solve(ESM_S.esm_problem(scalar_esm(1.0), (0.0, 1.0)), nothing)
    end

    @testset "additive couple connector adds -k*A to a species ODE (esm-spec §10.3)" begin
        # The connector SEMANTICS, driven through the explicit FlattenedSystem carrier
        # (the testset above covers the Dict/path/EsmFile carriers). Chemistry alone
        # gives A a first-order loss D(Chem.A) = -K1*A; the additive edge must fold
        # (-KSINK)*A ONTO it, giving A(t) = A0*exp(-(K1+KSINK)t).
        esm = additive_couple_esm()
        @test isempty(ESM_S.validate_schema(esm))

        sys = ESM_S.flatten(ESM_S.load_string(IOBuffer(JSON3.write(esm))))
        @test Set(keys(sys.state_variables)) == Set(["Chem.A", "Chem.B"])

        r = solve(ESM_S.esm_problem(sys, (0.0, 1.0)), Tsit5())
        @test successful_retcode(r)

        A_end = r[Symbol("Chem.A")][end]
        @test isapprox(A_end, A0 * exp(-(K1 + KSINK) * 1.0); rtol = 1e-4)
        # The coupling term was ADDED, not dropped: strictly faster decay than chemistry alone.
        @test A_end < A0 * exp(-K1 * 1.0) - 1e-3
        # ...and the chemistry term survived: this is not `replacement` semantics.
        @test !isapprox(A_end, A0 * exp(-KSINK * 1.0); rtol = 1e-2)
        # The reaction really ran (B is fed by chemistry only; the couple never touches it).
        @test r[Symbol("Chem.B")][end] > 1e-3
    end

    @testset "default (compile-once tier) == ESS_TEMPLATE_REF_DISABLE solve, bit-identical" begin
        # THE default path: surviving `apply_expression_template` references are
        # carried by `flatten` to the build boundary, where the affine compile-once
        # tier factors each body once (RFC out-of-line-templates step c). The
        # SOLVED state must be bit-identical to a solve of the same fixture loaded
        # under `ESS_TEMPLATE_REF_DISABLE=1` (Expand-at-load, the Option-A image —
        # the ONE differential escape hatch): RFC §12 gate 3 through the full
        # `simulate` pipeline (provider-free, self-contained bench fixture). This is
        # the reseact.esm Stage-C build path: 321 PPM references survive, the doc is
        # ~277x smaller, and the tier build replaces a ~200M-node-lowering fused build.
        fix = joinpath(TESTUTILS_REPO_ROOT, "tests", "bench",
                       "transport_3axis_7cubed_fullrank.esm")
        # The env hatch acts at LOAD, so it wraps the load call.
        fatload = withenv("ESS_TEMPLATE_REF_DISABLE" => "1") do
            ESM_S.load_path(fix)
        end
        rf = solve(ESM_S.esm_problem(fatload, (0.0, 0.5)), Tsit5(); saveat = [0.0, 0.5])
        rt = solve(ESM_S.esm_problem(ESM_S.load_path(fix), (0.0, 0.5)), Tsit5();
                            saveat = [0.0, 0.5])
        @test successful_retcode(rf) && successful_retcode(rt)
        @test length(rf.u[end]) == 343
        @test rf.u[end] == rt.u[end]        # exact ==, no tolerance
    end
end
