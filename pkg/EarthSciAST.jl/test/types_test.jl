# Type-constructor unit tests for the core src/types.jl surface
# (extracted from the inline testsets that used to live in runtests.jl).

using Test
using EarthSciAST

@testset "Type constructors (src/types.jl)" begin

    @testset "Expression Types" begin
        # Test NumExpr
        num_expr = NumExpr(3.14)
        @test num_expr.value == 3.14
        @test num_expr isa EarthSciAST.ASTExpr

        # Test VarExpr
        var_expr = VarExpr("x")
        @test var_expr.name == "x"
        @test var_expr isa EarthSciAST.ASTExpr

        # Test OpExpr
        op_expr = OpExpr("+", EarthSciAST.ASTExpr[NumExpr(1.0), VarExpr("x")])
        @test op_expr.op == "+"
        @test length(op_expr.args) == 2
        @test op_expr.wrt === nothing
        @test op_expr.dim === nothing
        @test op_expr isa EarthSciAST.ASTExpr

        # Test OpExpr with optional parameters
        diff_expr = OpExpr("D", EarthSciAST.ASTExpr[VarExpr("x")], wrt="t", dim="time")
        @test diff_expr.wrt == "t"
        @test diff_expr.dim == "time"
    end

    @testset "Equation Types" begin
        # Test Equation. Qualify ESM.Equation: under MTK 11 + Pkg.test
        # extras the test session has both ESS and MTK loaded into Main,
        # which makes the bare `Equation` reference ambiguous.
        lhs = OpExpr("D", EarthSciAST.ASTExpr[VarExpr("x")], wrt="t")
        rhs = OpExpr("*", EarthSciAST.ASTExpr[NumExpr(2.0), VarExpr("x")])
        eq = EarthSciAST.Equation(lhs, rhs)
        @test eq.lhs == lhs
        @test eq.rhs == rhs

        # Test AffectEquation
        affect_eq = AffectEquation("x", NumExpr(0.0))
        @test affect_eq.lhs == "x"
        @test affect_eq.rhs isa NumExpr
    end

    @testset "ModelVariable Types" begin
        # Test ModelVariableType enum
        @test StateVariable isa ModelVariableType
        @test ParameterVariable isa ModelVariableType
        @test ObservedVariable isa ModelVariableType

        # Test ModelVariable
        mv = ModelVariable(StateVariable, default=1.0, description="Test variable")
        @test mv.type == StateVariable
        @test mv.default == 1.0
        @test mv.description == "Test variable"
        @test mv.expression === nothing
    end

    @testset "Model Component Types" begin
        # Test Species
        species = Species("CO2", units="mol/m^3", default=1e-6)
        @test species.name == "CO2"
        @test species.units == "mol/m^3"
        @test species.default == 1e-6
        @test species.description === nothing

        # Test Parameter
        param = Parameter("k", 0.1, description="Rate constant", units="1/s")
        @test param.name == "k"
        @test param.default == 0.1
        @test param.description == "Rate constant"
        @test param.units == "1/s"

        # Test Reaction
        reactants = Dict("A" => 1, "B" => 1)
        products = Dict("C" => 1)
        rate = OpExpr("*", EarthSciAST.ASTExpr[VarExpr("k"), VarExpr("A"), VarExpr("B")])
        reaction = Reaction(reactants, products, rate)
        @test EarthSciAST.get_reactants_dict(reaction) == reactants
        @test EarthSciAST.get_products_dict(reaction) == products
        @test reaction.rate == rate
    end

    @testset "Event System Types" begin
        # Test DiscreteEventTrigger types
        cond_trigger = ConditionTrigger(VarExpr("x"))
        @test cond_trigger isa DiscreteEventTrigger
        @test cond_trigger.expression isa VarExpr

        periodic_trigger = PeriodicTrigger(10.0, phase=2.0)
        @test periodic_trigger isa DiscreteEventTrigger
        @test periodic_trigger.period == 10.0
        @test periodic_trigger.phase == 2.0

        preset_trigger = PresetTimesTrigger([1.0, 5.0, 10.0])
        @test preset_trigger isa DiscreteEventTrigger
        @test preset_trigger.times == [1.0, 5.0, 10.0]

        # Discrete events carry AffectEquation affects — the same {lhs, rhs}
        # shape continuous events use (FunctionalAffect was removed).
        affect = AffectEquation("x", NumExpr(1.0))
        @test affect.lhs == "x"
        @test affect.rhs isa NumExpr
        ev = DiscreteEvent(PeriodicTrigger(10.0), [affect])
        @test ev.affects == [affect]
    end

    @testset "System Configuration Types" begin
        # Test Reference
        ref = Reference(doi="10.1000/test", citation="Test paper")
        @test ref.doi == "10.1000/test"
        @test ref.citation == "Test paper"
        @test ref.url === nothing
        @test ref.notes === nothing

        # Test Metadata
        metadata = Metadata("test_model",
                          description="A test model",
                          authors=["Test Author"],
                          license="MIT")
        @test metadata.name == "test_model"
        @test metadata.description == "A test model"
        @test metadata.authors == ["Test Author"]
        @test metadata.license == "MIT"

        # Test Domain (esm-spec v0.8.0: temporal-only; the spatial table was removed)
        domain = Domain(temporal=Dict("t" => [0.0, 100.0]))
        @test domain.temporal isa Dict

        # Test EsmFile
        esm_file = EsmFile("0.1.0", metadata)
        @test esm_file.esm == "0.1.0"
        @test esm_file.metadata == metadata
        @test esm_file.models === nothing
        @test esm_file.coupling == []
    end

    @testset "Type Hierarchy" begin
        # Test that all expression types are subtypes of ASTExpr
        @test NumExpr <: EarthSciAST.ASTExpr
        @test VarExpr <: EarthSciAST.ASTExpr
        @test OpExpr <: EarthSciAST.ASTExpr

        # Test that trigger types are subtypes of DiscreteEventTrigger
        @test ConditionTrigger <: DiscreteEventTrigger
        @test PeriodicTrigger <: DiscreteEventTrigger
        @test PresetTimesTrigger <: DiscreteEventTrigger

        # Test that event types are subtypes of EventType
        @test ContinuousEvent <: EarthSciAST.EventType
        @test DiscreteEvent <: EarthSciAST.EventType
    end
end
