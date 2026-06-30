using Test
using EarthSciSerialization
import OrdinaryDiffEqTsit5: Tsit5
const ESM_S = EarthSciSerialization

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
            "models" => Dict{String,Any}("M" => Dict{String,Any}(
                "index_sets" => Dict{String,Any}("n" => Dict{String,Any}("kind" => "interval", "size" => 3)),
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
            "models" => Dict{String,Any}("M" => Dict{String,Any}(
                "index_sets" => Dict{String,Any}("n" => Dict{String,Any}("kind" => "interval", "size" => 4)),
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
end
