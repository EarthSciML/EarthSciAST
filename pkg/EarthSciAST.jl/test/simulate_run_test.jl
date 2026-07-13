using Test
using EarthSciAST
import OrdinaryDiffEqTsit5: Tsit5
using JSON3
const ESM_S = EarthSciAST

# `simulate` — the one-call run entry: coerce → build_evaluator → seed → solve,
# with the solve in the SciMLBase extension (active here: the test target loads
# SciMLBase + OrdinaryDiffEqTsit5).
@testset "simulate run entry" begin
    _D(v) = Dict{String,Any}("op" => "D", "args" => Any[v], "wrt" => "t")
    _idx(v, i) = Dict{String,Any}("op" => "index", "args" => Any[v, i])
    scalar_esm(rhs) = Dict{String,Any}(
        "esm" => "0.5.0", "metadata" => Dict{String,Any}("name" => "S"),
        "models" => Dict{String,Any}("M" => Dict{String,Any}(
            "variables" => Dict{String,Any}("y" => Dict{String,Any}("type" => "state")),
            "equations" => Any[Dict{String,Any}("lhs" => _D("y"), "rhs" => rhs)])))

    @testset "scalar ODE D(y)=1 over [0,2] → 2" begin
        r = ESM_S.simulate(scalar_esm(1.0), (0.0, 2.0); alg = Tsit5(),
                           initial_conditions = Dict("y" => 0.0))
        @test r isa SimulationResult
        @test r.success && r.retcode == :Success
        @test isapprox(r["y"][end], 2.0; atol = 1e-6)
        @test length(r.t) == length(r.u)
    end

    @testset "parameter override D(y)=k, k=2.5, [0,3] → 7.5" begin
        esm = scalar_esm("k")
        esm["models"]["M"]["variables"]["k"] = Dict{String,Any}("type" => "parameter", "default" => 1.0)
        r = ESM_S.simulate(esm, (0.0, 3.0); alg = Tsit5(),
                           parameters = Dict("k" => 2.5), initial_conditions = Dict("y" => 0.0))
        @test isapprox(r["y"][end], 7.5; atol = 1e-5)
    end

    @testset "array state with seed_ic! + element IC override" begin
        esm = Dict{String,Any}(
            "esm" => "0.5.0", "metadata" => Dict{String,Any}("name" => "A"),
            "index_sets" => Dict{String,Any}("n" => Dict{String,Any}("kind" => "interval", "size" => 3)),
            "models" => Dict{String,Any}("M" => Dict{String,Any}(
                "variables" => Dict{String,Any}("u" => Dict{String,Any}("type" => "state", "shape" => Any["n"])),
                "equations" => Any[Dict{String,Any}(
                    "lhs" => Dict{String,Any}("op" => "arrayop", "output_idx" => Any["i"],
                        "ranges" => Dict{String,Any}("i" => Dict{String,Any}("from" => "n")), "args" => Any[], "expr" => _D(_idx("u", "i"))),
                    "rhs" => Dict{String,Any}("op" => "arrayop", "output_idx" => Any["i"],
                        "ranges" => Dict{String,Any}("i" => Dict{String,Any}("from" => "n")), "args" => Any[], "expr" => _idx("u", "i")))])))
        seed! = (u0, vm) -> (u0[vm["u[2]"]] = 2.0; u0[vm["u[3]"]] = 3.0)
        r = ESM_S.simulate(esm, (0.0, 1.0); alg = Tsit5(),
                           initial_conditions = Dict("u[1]" => 1.0), seed_ic! = seed!)
        got = [r["u[1]"][end], r["u[2]"][end], r["u[3]"][end]]
        @test all(isapprox.(got, [1.0, 2.0, 3.0] .* exp(1); rtol = 1e-3))
    end

    @testset "seed_expression_ic! over a grid" begin
        # u[i] state on a 4-cell axis; seed u(x) = x^2 at coords [10,20,30,40].
        esm = Dict{String,Any}(
            "esm" => "0.5.0", "metadata" => Dict{String,Any}("name" => "G"),
            "index_sets" => Dict{String,Any}("n" => Dict{String,Any}("kind" => "interval", "size" => 4)),
            "models" => Dict{String,Any}("M" => Dict{String,Any}(
                "variables" => Dict{String,Any}("u" => Dict{String,Any}("type" => "state", "shape" => Any["n"])),
                "equations" => Any[Dict{String,Any}(
                    "lhs" => Dict{String,Any}("op" => "arrayop", "output_idx" => Any["i"],
                        "ranges" => Dict{String,Any}("i" => Dict{String,Any}("from" => "n")), "args" => Any[], "expr" => _D(_idx("u", "i"))),
                    "rhs" => Dict{String,Any}("op" => "arrayop", "output_idx" => Any["i"],
                        "ranges" => Dict{String,Any}("i" => Dict{String,Any}("from" => "n")), "args" => Any[], "expr" => 0.0))])))
        expr = parse_expression(Dict{String,Any}("op" => "*", "args" => Any["x", "x"]))
        seed! = (u0, vm) -> seed_expression_ic!(u0, vm, "u", expr, ["x" => [10.0, 20.0, 30.0, 40.0]])
        r = ESM_S.simulate(esm, (0.0, 1.0); alg = Tsit5(), seed_ic! = seed!)   # D(u)=0 → IC preserved
        @test [r["u[$i]"][end] for i in 1:4] == [100.0, 400.0, 900.0, 1600.0]
    end

    @testset "missing alg → clear error" begin
        @test_throws ESM_S.SimulateError ESM_S.simulate(scalar_esm(1.0), (0.0, 1.0))
    end

    @testset "additive couple connector adds -k*A to a species ODE (esm-spec §10.3)" begin
        # Chemistry alone gives A a first-order loss: A --k1--> B, so D(Chem.A) = -k1*A.
        # A `Sink` model exposes parameter k, and an additive `couple` edge
        # Sink.k → Chem.A folds (-Sink.k)*Chem.A ONTO that tendency, so
        #   D(Chem.A) ~ -k1*A - k*A   and   A(t) = A0*exp(-(k1+k)*t).
        #
        # The chemistry term is what makes this test discriminating. `additive` must ADD to
        # the existing RHS: exp(-(k1+k)t) separates it from a dropped edge (exp(-k1*t), the
        # pre-fix behaviour) AND from `replacement` semantics (exp(-k*t)). An empty
        # `reactions` list would leave the RHS at 0 and make those three indistinguishable —
        # and is schema-invalid besides (`reactions` has minItems: 1), which is why this
        # fixture is schema-checked below.
        k1 = 0.3      # chemistry rate constant
        k  = 0.1      # Sink coupling rate
        A0 = 2.0
        neg_k = Dict{String,Any}("op" => "-", "args" => Any["Sink.k"])
        esm = Dict{String,Any}(
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
                    "rate" => k1)])),
            "models" => Dict{String,Any}("Sink" => Dict{String,Any}(
                "variables" => Dict{String,Any}("k" =>
                    Dict{String,Any}("type" => "parameter", "default" => k)),
                "equations" => Any[])),
            "coupling" => Any[Dict{String,Any}(
                "type" => "couple", "systems" => Any["Chem", "Sink"],
                "connector" => Dict{String,Any}("equations" => Any[Dict{String,Any}(
                    "from" => "Sink.k", "to" => "Chem.A", "transform" => "additive",
                    "expression" => Dict{String,Any}("op" => "*",
                        "args" => Any[neg_k, "Chem.A"]))]))])

        # Schema-check the fixture explicitly: `simulate` does not do it for a raw document,
        # and an invalid one lowers to a system with no state variables at all.
        @test isempty(ESM_S.validate_schema(esm))

        # Go through load → flatten. `simulate(::AbstractDict)` passes the dict straight to
        # build_evaluator (`_prepare_run_doc`, simulate.jl:99) — it expects an ALREADY
        # FLATTENED document. Both the reaction-system lowering and the `couple` edge are
        # applied BY flatten, so handing it a raw authored document would silently drop both
        # and "succeed" with an empty state vector — which is exactly what this test must not
        # do, since the additive connector is the thing under test.
        file = ESM_S.load(IOBuffer(JSON3.write(esm)))
        sys = ESM_S.flatten(file)
        @test Set(keys(sys.state_variables)) == Set(["Chem.A", "Chem.B"])

        r = ESM_S.simulate(sys, (0.0, 1.0); alg = Tsit5())
        @test r isa SimulationResult && r.success

        A_end = r["Chem.A"][end]
        @test isapprox(A_end, A0 * exp(-(k1 + k) * 1.0); rtol = 1e-4)
        # The coupling term was ADDED, not dropped: strictly faster decay than chemistry alone.
        @test A_end < A0 * exp(-k1 * 1.0) - 1e-3
        # ...and the chemistry term survived: this is not `replacement` semantics.
        @test !isapprox(A_end, A0 * exp(-k * 1.0); rtol = 1e-2)
        # The reaction really ran (B is fed by chemistry only; the couple never touches it).
        @test r["Chem.B"][end] > 1e-3
    end
end
