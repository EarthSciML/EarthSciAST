using Test
using EarthSciAST
import ModelingToolkit
import Symbolics

@testset "MTK description metadata" begin

    @testset "_build_description helper" begin
        ext = Base.get_extension(EarthSciAST, :EarthSciASTMTKExt)
        bd = ext._build_description
        @test bd(nothing, nothing) === nothing
        @test bd("sea level rise", nothing) == "sea level rise"
        @test bd(nothing, "K") == "(units=K)"
        @test bd("sea level rise", "m") == "sea level rise (units=m)"
    end

    @testset "State variable carries description + units" begin
        ext = Base.get_extension(EarthSciAST, :EarthSciASTMTKExt)

        vars = Dict(
            "sea_level_rise" => ModelVariable(StateVariable;
                default=0.0, description="sea level rise", units="m"),
            "k" => ModelVariable(ParameterVariable; default=0.1,
                description="decay rate", units="1/s"),
        )
        eq = Equation(
            OpExpr("D", EarthSciAST.ASTExpr[VarExpr("sea_level_rise")],
                wrt="t"),
            OpExpr("*", EarthSciAST.ASTExpr[
                VarExpr("k"), VarExpr("sea_level_rise"),
            ]),
        )
        model = Model(vars, [eq])
        sys = ModelingToolkit.System(model; name=:SLR)

        # Pull the unknowns/parameters off the real System and check their
        # description metadata survives the round-trip into MTK.
        u_descs = [ModelingToolkit.getdescription(u)
                   for u in ModelingToolkit.unknowns(sys)]
        p_descs = [ModelingToolkit.getdescription(p)
                   for p in ModelingToolkit.parameters(sys)]

        @test "sea level rise (units=m)" in u_descs
        @test "decay rate (units=1/s)" in p_descs
    end

    @testset "Only units" begin
        ext = Base.get_extension(EarthSciAST, :EarthSciASTMTKExt)
        vars = Dict(
            "T" => ModelVariable(StateVariable; default=300.0, units="K"),
            "k" => ModelVariable(ParameterVariable; default=0.1),
        )
        eq = Equation(
            OpExpr("D", EarthSciAST.ASTExpr[VarExpr("T")], wrt="t"),
            OpExpr("*", EarthSciAST.ASTExpr[
                VarExpr("k"), VarExpr("T"),
            ]),
        )
        sys = ModelingToolkit.System(Model(vars, [eq]); name=:Only_Units)
        descs = [ModelingToolkit.getdescription(u)
                 for u in ModelingToolkit.unknowns(sys)]
        @test "(units=K)" in descs
    end

    @testset "Only description" begin
        vars = Dict(
            "x" => ModelVariable(StateVariable; default=1.0,
                description="population count"),
            "k" => ModelVariable(ParameterVariable; default=0.1),
        )
        eq = Equation(
            OpExpr("D", EarthSciAST.ASTExpr[VarExpr("x")], wrt="t"),
            OpExpr("*", EarthSciAST.ASTExpr[
                VarExpr("k"), VarExpr("x"),
            ]),
        )
        sys = ModelingToolkit.System(Model(vars, [eq]); name=:Only_Desc)
        descs = [ModelingToolkit.getdescription(u)
                 for u in ModelingToolkit.unknowns(sys)]
        @test "population count" in descs
    end

    @testset "Neither description nor units: no metadata attached" begin
        vars = Dict(
            "x" => ModelVariable(StateVariable; default=1.0),
            "k" => ModelVariable(ParameterVariable; default=0.1),
        )
        eq = Equation(
            OpExpr("D", EarthSciAST.ASTExpr[VarExpr("x")], wrt="t"),
            OpExpr("*", EarthSciAST.ASTExpr[
                VarExpr("k"), VarExpr("x"),
            ]),
        )
        sys = ModelingToolkit.System(Model(vars, [eq]); name=:Bare)
        # MTK's getdescription returns "" when VariableDescription isn't set.
        for u in ModelingToolkit.unknowns(sys)
            @test ModelingToolkit.getdescription(u) == ""
        end
    end

    @testset "Description does not clobber default value" begin
        vars = Dict(
            "x" => ModelVariable(StateVariable; default=2.5,
                description="thing", units="m"),
            "k" => ModelVariable(ParameterVariable; default=0.1),
        )
        eq = Equation(
            OpExpr("D", EarthSciAST.ASTExpr[VarExpr("x")], wrt="t"),
            OpExpr("*", EarthSciAST.ASTExpr[
                VarExpr("k"), VarExpr("x"),
            ]),
        )
        sys = ModelingToolkit.System(Model(vars, [eq]); name=:Both)

        # Find the unknown x and verify both description and default survived.
        u = first(u for u in ModelingToolkit.unknowns(sys)
                  if occursin("x", string(ModelingToolkit.getname(u))))
        @test ModelingToolkit.getdescription(u) == "thing (units=m)"
        @test Symbolics.getdefaultval(u) == 2.5
    end
end
