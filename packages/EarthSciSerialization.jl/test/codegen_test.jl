"""
Tests for code generation functionality (Julia and Python)
"""

using Test
using EarthSciSerialization

const _CG = EarthSciSerialization

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
            @test occursin("@named atmospheric_system = ODESystem(eqs, t)", code)
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

    @testset "precedence-aware expression formatting" begin
        a = VarExpr("a")
        b = VarExpr("b")
        c = VarExpr("c")
        E = EarthSciSerialization.Expr
        plus = OpExpr("+", E[a, b])
        prod_ab = OpExpr("*", E[a, b])

        @testset "Julia emitter" begin
            fmt = _CG.format_expression
            # (a + b) * c must not degrade to a + b * c
            @test fmt(OpExpr("*", E[plus, c])) == "(a + b) * c"
            # sum of products stays unparenthesized
            @test fmt(OpExpr("+", E[prod_ab, c])) == "a * b + c"
            # subtraction / division: right operand of same precedence wraps
            @test fmt(OpExpr("-", E[a, OpExpr("-", E[b, c])])) == "a - (b - c)"
            @test fmt(OpExpr("/", E[a, OpExpr("*", E[b, c])])) == "a / (b * c)"
            @test fmt(OpExpr("*", E[OpExpr("/", E[a, b]), c])) == "a / b * c"
            # power is right-associative: left same-precedence operand wraps
            @test fmt(OpExpr("^", E[OpExpr("^", E[a, b]), c])) == "(a ^ b) ^ c"
            @test fmt(OpExpr("^", E[a, OpExpr("^", E[b, c])])) == "a ^ b ^ c"
            @test fmt(OpExpr("^", E[plus, c])) == "(a + b) ^ c"
            # unary minus over a sum
            @test fmt(OpExpr("-", E[plus])) == "-(a + b)"
            @test fmt(OpExpr("-", E[prod_ab])) == "-a * b"
            # comparisons bind tighter than && in Julia — no parens needed
            lt1 = OpExpr("<", E[a, b])
            lt2 = OpExpr("<", E[b, c])
            @test fmt(OpExpr("and", E[lt1, lt2])) == "a < b && b < c"
            # or under and wraps
            @test fmt(OpExpr("and", E[OpExpr("or", E[a, b]), c])) == "(a || b) && c"
            # function-call args never get extra parens
            @test fmt(OpExpr("exp", E[plus])) == "exp(a + b)"
        end

        @testset "Python emitter" begin
            fmt = _CG.format_python_expression
            @test fmt(OpExpr("*", E[plus, c])) == "(a + b) * c"
            @test fmt(OpExpr("-", E[a, OpExpr("-", E[b, c])])) == "a - (b - c)"
            # ** is right-associative
            @test fmt(OpExpr("^", E[OpExpr("^", E[a, b]), c])) == "(a ** b) ** c"
            @test fmt(OpExpr("^", E[a, OpExpr("^", E[b, c])])) == "a ** b ** c"
            @test fmt(OpExpr("-", E[plus])) == "-(a + b)"
            # In Python, & binds tighter than comparisons: comparison operands
            # of and/or MUST be parenthesized.
            lt1 = OpExpr("<", E[a, b])
            lt2 = OpExpr("<", E[b, c])
            @test fmt(OpExpr("and", E[lt1, lt2])) == "(a < b) & (b < c)"
            @test fmt(OpExpr("or", E[lt1, lt2])) == "(a < b) | (b < c)"
            # | under & wraps
            @test fmt(OpExpr("and", E[OpExpr("or", E[a, b]), c])) == "(a | b) & c"
        end

        @testset "nested expression flows through to_julia_code" begin
            file = EsmFile(
                "0.1.0",
                Metadata("Nested");
                models = Dict(
                    "m" => Model(
                        Dict(
                            "x" => ModelVariable(StateVariable; default = 1.0),
                            "p" => ModelVariable(ParameterVariable; default = 2.0),
                            "q" => ModelVariable(ParameterVariable; default = 3.0),
                        ),
                        [
                            Equation(
                                OpExpr("D", E[VarExpr("x")]),
                                OpExpr("*", E[OpExpr("+", E[VarExpr("p"), VarExpr("q")]), VarExpr("x")])
                            )
                        ]
                    )
                )
            )
            code = to_julia_code(file)
            @test occursin("D(x) ~ (p + q) * x", code)
        end
    end

    @testset "reaction emission" begin
        SE = EarthSciSerialization.StoichiometryEntry

        @testset "ordered substrate/product vectors drive output" begin
            rxn = Reaction("r1", [SE("B", 1), SE("A", 2)], [SE("C", 1)], VarExpr("k"))
            # Order follows the entry vectors, not Dict iteration order.
            @test _CG.format_reaction(rxn) == "Reaction(k, [B + 2.0*A], [C])"
        end

        @testset "source/sink reactions render the empty set" begin
            rxn = Reaction("r2", nothing, [SE("A", 1)], NumExpr(0.5))
            @test _CG.format_reaction(rxn) == "Reaction(0.5, [∅], [A])"
        end

        @testset "parameters resolved against declared species" begin
            # Single-letter species "A" must NOT be re-declared as a parameter;
            # the non-species rate symbol must be.
            species = [Species("A")]
            rate = OpExpr("*", EarthSciSerialization.Expr[VarExpr("k_fast"), VarExpr("A")])
            rxn = Reaction("r1", [SE("A", 1)], nothing, rate)
            sys = ReactionSystem(species, [rxn]; parameters=[Parameter("k_fast", 1.0)])

            lines = _CG.generate_reaction_system_code("S", sys)
            joined = join(lines, "\n")
            @test occursin("@species A", joined)
            @test occursin("@parameters k_fast", joined)
            @test !occursin(r"@parameters.*\bA\b", joined)
        end
    end
end
