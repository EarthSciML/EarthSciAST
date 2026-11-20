"""
Tests for code generation functionality (Julia and Python)
"""

using Test
using EarthSciAST
using JSON3

const _CG = EarthSciAST

@testset "Code Generation" begin
    @testset "to_julia_code" begin
        @testset "should generate basic Julia script structure" begin
            file = EsmFile(
                "0.1.0",
                Metadata(
                    "Test Model";
                    description = "A test model for code generation"
                );
                models = Dict{String, Model}(),
                reaction_systems = Dict{String, ReactionSystem}()
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
                                UnknownVariable;
                                default = 50.0,
                                units = "ppb"
                            ),
                            "k1" => ModelVariable(
                                ParameterVariable;
                                default = 1.0e-3
                            )
                        ),
                        [
                            Equation(
                                OpExpr("D", EarthSciAST.ASTExpr[VarExpr("O3")]),
                                OpExpr("*", EarthSciAST.ASTExpr[VarExpr("k1"), VarExpr("O3")])
                            ),
                        ]
                    )
                ),
                reaction_systems = Dict{String, ReactionSystem}()
            )

            code = to_julia_code(file)

            @test occursin("@variables t O3(50.0, u\"ppb\")", code)
            @test occursin("@parameters k1(0.001)", code)
            @test occursin("D(O3) ~ k1 * O3", code)
            @test occursin("@named atmospheric_system = ODESystem(eqs, t)", code)
        end
    end

    @testset "precedence-aware expression formatting" begin
        a = VarExpr("a")
        b = VarExpr("b")
        c = VarExpr("c")
        E = EarthSciAST.ASTExpr
        plus = OpExpr("+", E[a, b])
        prod_ab = OpExpr("*", E[a, b])

        @testset "Julia emitter" begin
            fmt = _CG.format_julia_expression
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

        @testset "nested expression flows through to_julia_code" begin
            file = EsmFile(
                "0.1.0",
                Metadata("Nested");
                models = Dict(
                    "m" => Model(
                        Dict(
                            "x" => ModelVariable(UnknownVariable; default = 1.0),
                            "p" => ModelVariable(ParameterVariable; default = 2.0),
                            "q" => ModelVariable(ParameterVariable; default = 3.0),
                        ),
                        [
                            Equation(
                                OpExpr("D", E[VarExpr("x")]),
                                OpExpr("*", E[OpExpr("+", E[VarExpr("p"), VarExpr("q")]), VarExpr("x")])
                            ),
                        ]
                    )
                )
            )
            code = to_julia_code(file)
            @test occursin("D(x) ~ (p + q) * x", code)
        end
    end

    @testset "reaction emission" begin
        SE = EarthSciAST.StoichiometryEntry

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
            rate = OpExpr("*", EarthSciAST.ASTExpr[VarExpr("k_fast"), VarExpr("A")])
            rxn = Reaction("r1", [SE("A", 1)], nothing, rate)
            sys = ReactionSystem(species, [rxn]; parameters = [Parameter("k_fast", 1.0)])

            lines = _CG.generate_reaction_system_code("S", sys)
            joined = join(lines, "\n")
            @test occursin("@species A", joined)
            @test occursin("@parameters k_fast", joined)
            @test !occursin(r"@parameters.*\bA\b", joined)
        end
    end

    @testset "to_julia_code prints template references as calls (§9.6.4)" begin
        # A referenced template is printed once, as a function of its
        # parameters and then its implicit parameters (the names its body reads
        # from its caller); each reference is a call to it. Nothing is expanded.
        doc = Dict{String, Any}(
            "esm" => "0.9.0",
            "metadata" => Dict{String, Any}("name" => "codegen_tpl"),
            "models" => Dict{String, Any}(
                "M" => Dict{String, Any}(
                    "expression_templates" => Dict{String, Any}(
                        "scale" => Dict{String, Any}(
                            "params" => Any["x"],
                            "body" => Dict{String, Any}("op" => "*", "args" => Any["k", "x"])
                        )
                    ),
                    "variables" => Dict{String, Any}(
                        "k" => Dict{String, Any}("type" => "parameter", "default" => 0.5),
                        "y" => Dict{String, Any}("type" => "unknown", "default" => 1.0),
                        "z" => Dict{String, Any}("type" => "unknown", "default" => 2.0)
                    ),
                    "equations" => Any[
                        Dict{String, Any}(
                            "lhs" => Dict{String, Any}("op" => "D", "args" => Any["y"], "wrt" => "t"),
                            "rhs" => Dict{String, Any}(
                                "op" => "apply_expression_template",
                                "args" => Any[], "name" => "scale",
                                "bindings" => Dict{String, Any}("x" => "z")
                            )
                        ),
                        Dict{String, Any}(
                            "lhs" => Dict{String, Any}("op" => "D", "args" => Any["z"], "wrt" => "t"),
                            "rhs" => Dict{String, Any}("op" => "-", "args" => Any["z"])
                        ),
                    ]
                )
            )
        )
        file = _CG.load_string(IOBuffer(JSON3.write(doc)))
        @test file.component_templates !== nothing       # the reference survived load
        code = to_julia_code(file)
        @test occursin("M_scale(x, k) = k * x", code)     # the template, once
        @test occursin("D(y) ~ M_scale(z, k)", code)      # the reference, a call
        @test !occursin("k * z", code)                    # not expanded
        @test !occursin("apply_expression_template", code)
        @test file.component_templates !== nothing
        # The printed function and call evaluate to what the reference denotes
        # (k * z with k = 0.5, z = 2.0).
        fn = only(filter(l -> startswith(l, "M_scale("), split(code, '\n')))
        mod = Module()
        Core.eval(mod, Meta.parse(fn))
        Core.eval(mod, :(k = 0.5; z = 2.0))
        @test Core.eval(mod, Meta.parse("M_scale(z, k)")) == 0.5 * 2.0
    end

    @testset "to_julia_code: nested references and an implicit parameter named like a parameter" begin
        # `outer(x)` calls `inner(y = x)`, and `inner` reads `x` from its caller:
        # the model's own `x`, not `outer`'s parameter. The printed `outer`
        # takes that name as a separate argument.
        doc = Dict{String, Any}(
            "esm" => "0.9.0",
            "metadata" => Dict{String, Any}("name" => "codegen_tpl_nested"),
            "models" => Dict{String, Any}(
                "M" => Dict{String, Any}(
                    "expression_templates" => Dict{String, Any}(
                        "inner" => Dict{String, Any}(
                            "params" => Any["y"],
                            "body" => Dict{String, Any}("op" => "+", "args" => Any["y", "x"])
                        ),
                        "outer" => Dict{String, Any}(
                            "params" => Any["x"],
                            "body" => Dict{String, Any}(
                                "op" => "*", "args" => Any[
                                    2.0,
                                    Dict{String, Any}(
                                        "op" => "apply_expression_template", "args" => Any[],
                                        "name" => "inner", "bindings" => Dict{String, Any}("y" => "x")
                                    ),
                                ]
                            )
                        )
                    ),
                    "variables" => Dict{String, Any}(
                        "x" => Dict{String, Any}("type" => "parameter", "default" => 3.0),
                        "z" => Dict{String, Any}("type" => "unknown", "default" => 2.0)
                    ),
                    "equations" => Any[
                        Dict{String, Any}(
                            "lhs" => Dict{String, Any}("op" => "D", "args" => Any["z"], "wrt" => "t"),
                            "rhs" => Dict{String, Any}(
                                "op" => "apply_expression_template", "args" => Any[],
                                "name" => "outer", "bindings" => Dict{String, Any}("x" => "z")
                            )
                        ),
                    ]
                )
            )
        )
        file = _CG.load_string(IOBuffer(JSON3.write(doc)))
        code = to_julia_code(file)
        @test occursin("M_inner(y, x) = y + x", code)
        @test occursin(r"M_outer\(x, x_\) = 2(\.0)? \* M_inner\(x, x_\)", code)
        @test occursin("D(z) ~ M_outer(z, x)", code)
        @test !occursin("apply_expression_template", code)
        # Expanded, the right-hand side is 2 * (z + x).
        mod = Module()
        for l in split(code, '\n')
            startswith(l, "M_") && Core.eval(mod, Meta.parse(l))
        end
        Core.eval(mod, :(x = 3.0; z = 2.0))
        @test Core.eval(mod, Meta.parse("M_outer(z, x)")) == 2.0 * (2.0 + 3.0)
    end
end
