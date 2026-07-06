"""
Tests for code generation functionality (Julia and Python)
"""

using Test
using EarthSciSerialization

@testset "Code Generation" begin
    @testset "to_julia_code" begin
        @testset "should generate basic Julia script structure" begin
            file = EsmFile(
                "0.1.0",
                Metadata(
                    "Test Model";
                    description = "A test model for code generation"
                );
                models = Dict{String,Model}(),
                reaction_systems = Dict{String,ReactionSystem}()
            )

            code = to_julia_code(file)

            @test occursin("using ModelingToolkit", code)
            @test occursin("using Catalyst", code)
            @test occursin("using EarthSciMLBase", code)
            @test occursin("using OrdinaryDiffEq", code)
            @test occursin("using Unitful", code)
            @test occursin("# Title: Test Model", code)
            @test occursin("# Description: A test model for code generation", code)
        end

        @testset "should generate model code with variables and equations" begin
            file = EsmFile(
                "0.1.0",
                Metadata("Test Model with Equations");
                models = Dict(
                    "atmospheric" => Model(
                        Dict(
                            "O3" => ModelVariable(
                                StateVariable;
                                default = 50.0,
                                units = "ppb"
                            ),
                            "k1" => ModelVariable(
                                ParameterVariable;
                                default = 1e-3
                            )
                        ),
                        [
                            Equation(
                                OpExpr("D", EarthSciSerialization.Expr[VarExpr("O3")]),
                                OpExpr("*", EarthSciSerialization.Expr[VarExpr("k1"), VarExpr("O3")])
                            )
                        ]
                    )
                ),
                reaction_systems = Dict{String,ReactionSystem}()
            )

            code = to_julia_code(file)

            @test occursin("@variables t O3(50.0, u\"ppb\")", code)
            @test occursin("@parameters k1(0.001)", code)
            @test occursin("D(O3) ~ k1 * O3", code)
            @test occursin("@named atmospheric_system = ODESystem(eqs)", code)
        end
    end

    @testset "to_python_code" begin
        @testset "should generate basic Python script structure" begin
            file = EsmFile(
                "0.1.0",
                Metadata(
                    "Test Model";
                    description = "A test model for Python code generation"
                );
                models = Dict{String,Model}(),
                reaction_systems = Dict{String,ReactionSystem}()
            )

            code = to_python_code(file)

            @test occursin("import sympy as sp", code)
            @test occursin("import earthsci_toolkit as esm", code)
            @test occursin("import scipy", code)
            @test occursin("# Title: Test Model", code)
            @test occursin("# Description: A test model for Python code generation", code)
            @test occursin("tspan = (0, 10)", code)
            @test occursin("parameters = {}", code)
            @test occursin("initial_conditions = {}", code)
        end

        @testset "should generate model code with variables and equations" begin
            file = EsmFile(
                "0.1.0",
                Metadata("Test Model for Python");
                models = Dict(
                    "atmospheric" => Model(
                        Dict(
                            "O3" => ModelVariable(
                                StateVariable;
                                default = 50.0,
                                units = "ppb"
                            ),
                            "k1" => ModelVariable(
                                ParameterVariable;
                                default = 1e-3
                            )
                        ),
                        [
                            Equation(
                                OpExpr("D", EarthSciSerialization.Expr[VarExpr("O3")]),
                                OpExpr("*", EarthSciSerialization.Expr[VarExpr("k1"), VarExpr("O3")])
                            )
                        ]
                    )
                ),
                reaction_systems = Dict{String,ReactionSystem}()
            )

            code = to_python_code(file)

            @test occursin("t = sp.Symbol('t')", code)
            @test occursin("O3 = sp.Function('O3')  # ppb", code)
            @test occursin("k1 = sp.Symbol('k1')", code)
            @test occursin("eq1 = sp.Eq(sp.Derivative(O3(t), t), k1 * O3)", code)
        end
    end
end