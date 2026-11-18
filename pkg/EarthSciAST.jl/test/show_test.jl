# `show` of expressions, equations and the component types: the two-argument
# form is one line, the `text/plain` form a summary whose expressions are their
# Typst math (`print_math`), never the default struct printing.

using Test
using EarthSciAST

@testset "show" begin
    E = EarthSciAST.ASTExpr
    rhs = OpExpr("*", E[VarExpr("k"), VarExpr("x")])
    eq = Equation(OpExpr("D", E[VarExpr("x")], wrt = "t"), rhs)

    @testset "expressions and equations print their Typst math" begin
        @test sprint(show, rhs) == "k x"
        @test string(eq) == "(dif x)/(dif t) = k x"
    end

    @testset "Model" begin
        model = Model(
            Dict(
                "x" => ModelVariable(UnknownVariable, default = 1.0, units = "m"),
                "k" => ModelVariable(ParameterVariable, default = 0.5),
            ),
            [eq];
            subsystems = Dict{String, EarthSciAST.SubsystemNode}(
                "Inner" => Model(Dict{String, ModelVariable}(), Equation[])
            ),
        )
        @test sprint(show, model) == "Model(2 variables, 1 equations)"
        plain = sprint(show, MIME("text/plain"), model)
        @test startswith(plain, "Model:\n")
        @test occursin("Variables (2):", plain)
        @test occursin("x: unknown = 1.0 [m]", plain)
        @test occursin("Equations (1):\n    1. (dif x)/(dif t) = k x\n", plain)
        @test occursin("Subsystems (1): Inner", plain)
        # The summary, not the struct dump: no field names, no type names.
        @test !occursin("ModelVariable", plain)
        @test !occursin("OpExpr", plain)
        # The element type prints module-qualified unless EarthSciAST is loaded
        # in Main, as `string(Model)` does.
        @test sprint(show, [model]) == "$(Model)[Model(2 variables, 1 equations)]"
    end

    @testset "ReactionSystem" begin
        rs = ReactionSystem(
            [Species("A"), Species("B")],
            [
                Reaction(
                    "r1",
                    [EarthSciAST.StoichiometryEntry("A", 2)],
                    [EarthSciAST.StoichiometryEntry("B", 1)],
                    VarExpr("k")
                ),
            ];
            parameters = [Parameter("k", 0.1)],
        )
        @test sprint(show, rs) == "ReactionSystem(2 species, 1 reactions)"
        plain = sprint(show, MIME("text/plain"), rs)
        @test startswith(plain, "ReactionSystem:\n")
        @test occursin("Species (2):", plain)
        @test occursin("Parameters (1):\n    k = 0.1\n", plain)
        @test occursin("Reactions (1):\n    1. 2A → B  [rate: k]\n", plain)
        @test !occursin("StoichiometryEntry", plain)
    end

    @testset "EsmFile" begin
        model = Model(Dict("x" => ModelVariable(UnknownVariable)), Equation[])
        file = EsmFile(
            "2.3.0", Metadata("demo", description = "A demo", authors = ["A. B."]);
            models = Dict("M" => model),
        )
        @test sprint(show, file) == "EsmFile(v2.3.0, \"demo\")"
        plain = sprint(show, MIME("text/plain"), file)
        @test startswith(plain, "ESM v2.3.0: demo\n")
        @test occursin("Description: A demo", plain)
        @test occursin("Authors: A. B.", plain)
        @test occursin("Models (1): M", plain)
        @test !occursin("ModelVariable", plain)
    end
end
