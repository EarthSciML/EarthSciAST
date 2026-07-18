using Test
using EarthSciAST
using OrderedCollections: OrderedDict
# Qualify ModelingToolkit and Symbolics so they don't collide with
# EarthSciAST exports (e.g. `Equation`) in the shared Main scope
# used by runtests.jl.
import ModelingToolkit
import Symbolics

@testset "Real MTK Extension Integration Tests" begin

    @testset "Extension loads and registers System constructor" begin
        ext = Base.get_extension(EarthSciAST, :EarthSciASTMTKExt)
        @test ext !== nothing
        @test hasmethod(ModelingToolkit.System,
                        Tuple{EarthSciAST.Model})
        @test hasmethod(ModelingToolkit.System,
                        Tuple{EarthSciAST.FlattenedSystem})
        @test hasmethod(ModelingToolkit.PDESystem,
                        Tuple{EarthSciAST.FlattenedSystem})
    end

    @testset "ModelingToolkit.System(::Model) builds a real System" begin
        vars = Dict(
            "x" => ModelVariable(StateVariable; default=1.0),
            "k" => ModelVariable(ParameterVariable; default=0.5),
        )
        eq = Equation(
            OpExpr("D", EarthSciAST.ASTExpr[VarExpr("x")], wrt="t"),
            OpExpr("*", EarthSciAST.ASTExpr[
                OpExpr("-", EarthSciAST.ASTExpr[VarExpr("k")]),
                VarExpr("x"),
            ]),
        )
        model = Model(vars, [eq])
        sys = ModelingToolkit.System(model; name=:RealTest)

        type_str = string(typeof(sys))
        @test occursin("System", type_str) || occursin("ODE", type_str)

        # After flatten+extension, variables are namespaced as `RealTest.x`
        # and sanitized to `RealTest_x` for symbol construction.
        un_names = Set(string(ModelingToolkit.getname(u))
                       for u in ModelingToolkit.unknowns(sys))
        @test any(occursin("x", n) for n in un_names)

        pn_names = Set(string(ModelingToolkit.getname(p))
                       for p in ModelingToolkit.parameters(sys))
        @test any(occursin("k", n) for n in pn_names)
    end

    @testset "ModelingToolkit.System(::Model) errors on PDE model with pointer to PDESystem" begin
        # The spatial dimension `z` is derived from the grad operators'
        # `dim="z"` (esm-spec v0.8.0 removed the Domain.spatial table).
        vars = Dict{String,ModelVariable}(
            "u" => ModelVariable(StateVariable; default=1.0),
            "D" => ModelVariable(ParameterVariable; default=0.1),
        )
        eq = Equation(
            OpExpr("D", EarthSciAST.ASTExpr[VarExpr("u")], wrt="t"),
            OpExpr("*", EarthSciAST.ASTExpr[
                VarExpr("D"),
                OpExpr("grad", EarthSciAST.ASTExpr[
                    OpExpr("grad", EarthSciAST.ASTExpr[VarExpr("u")], dim="z"),
                ], dim="z"),
            ]),
        )
        model = Model(vars, [eq])
        file = EsmFile("0.1.0", Metadata("Diffuse");
            models=Dict("Diffuse" => model))
        flat = flatten(file)
        @test :z in flat.independent_variables
        @test_throws ArgumentError ModelingToolkit.System(flat; name=:Diffuse)
    end

    @testset "ModelingToolkit.PDESystem(::FlattenedSystem) errors on pure-ODE input" begin
        vars = Dict(
            "x" => ModelVariable(StateVariable; default=1.0),
            "k" => ModelVariable(ParameterVariable; default=0.5),
        )
        eq = Equation(
            OpExpr("D", EarthSciAST.ASTExpr[VarExpr("x")], wrt="t"),
            OpExpr("*", EarthSciAST.ASTExpr[
                OpExpr("-", EarthSciAST.ASTExpr[VarExpr("k")]),
                VarExpr("x"),
            ]),
        )
        flat = flatten(Model(vars, [eq]); name="OnlyODE")
        @test_throws ArgumentError ModelingToolkit.PDESystem(flat; name=:OnlyODE)
    end

    @testset "Round-trip: Model → System → Model" begin
        vars = Dict(
            "x" => ModelVariable(StateVariable; default=2.0),
            "k" => ModelVariable(ParameterVariable; default=0.3),
        )
        eq = Equation(
            OpExpr("D", EarthSciAST.ASTExpr[VarExpr("x")], wrt="t"),
            OpExpr("*", EarthSciAST.ASTExpr[
                OpExpr("-", EarthSciAST.ASTExpr[VarExpr("k")]),
                VarExpr("x"),
            ]),
        )
        original = Model(vars, [eq])
        sys = ModelingToolkit.System(original; name=:RT)
        recovered = EarthSciAST.Model(sys)
        @test recovered isa Model
        # After round-trip, the variables carry the namespaced name from
        # flatten (e.g. `RT_x`, `RT_k` after sanitization for symbol use).
        state_vars = [v for (n, v) in recovered.variables
                      if v.type == StateVariable]
        param_vars = [v for (n, v) in recovered.variables
                      if v.type == ParameterVariable]
        @test length(state_vars) == 1
        @test length(param_vars) == 1
    end

    @testset "Slice-derived surface source lowers to flux BC" begin
        # Spec §4.7.6.13 Example B: 1D vertical diffusion + 0D surface
        # deposition coupled via a slice interface at z=0. The Julia
        # extension is required to lower the slice-ODE to a flux BC on the
        # diffusive PDE at z=0.
        ivs = Symbol[:t, :z]
        svars = OrderedDict{String, ModelVariable}(
            "VertDiff.C" => ModelVariable(StateVariable; default=1.0),
            "VertDiff.C.at_z" => ModelVariable(StateVariable; default=1.0),
        )
        ps = OrderedDict{String, ModelVariable}(
            "VertDiff.D" => ModelVariable(ParameterVariable; default=0.1),
            "SurfaceDep.v_dep" => ModelVariable(ParameterVariable; default=0.01),
        )
        obs = OrderedDict{String, ModelVariable}()

        # dC/dt = D * grad(grad(C, z), z)
        diff_eq = Equation(
            OpExpr("D", EarthSciAST.ASTExpr[VarExpr("VertDiff.C")], wrt="t"),
            OpExpr("*", EarthSciAST.ASTExpr[
                VarExpr("VertDiff.D"),
                OpExpr("grad", EarthSciAST.ASTExpr[
                    OpExpr("grad", EarthSciAST.ASTExpr[VarExpr("VertDiff.C")], dim="z"),
                ], dim="z"),
            ]),
        )
        # dC.at_z/dt = -v_dep * C.at_z   (slice-ODE — surface deposition)
        slice_eq = Equation(
            OpExpr("D", EarthSciAST.ASTExpr[VarExpr("VertDiff.C.at_z")], wrt="t"),
            OpExpr("*", EarthSciAST.ASTExpr[
                OpExpr("-", EarthSciAST.ASTExpr[VarExpr("SurfaceDep.v_dep")]),
                VarExpr("VertDiff.C.at_z"),
            ]),
        )

        flat = FlattenedSystem(ivs, svars, ps, obs, [diff_eq, slice_eq],
            ContinuousEvent[], DiscreteEvent[],
            nothing,
            FlattenMetadata())

        pde = ModelingToolkit.PDESystem(flat; name=:VertDep)
        @test occursin("PDESystem", string(typeof(pde)))
        @test length(pde.bcs) >= 1
        # The BC string should contain a z-derivative and reference the
        # deposition velocity — i.e. the slice-ODE rewritten as a flux BC
        # with the slice variable substituted by the base variable.
        bc_strs = [string(bc) for bc in pde.bcs]
        # Derivative w.r.t. z must appear. Symbolics renders it as either
        # "Differential(z)" or "Differential(z, 1)" depending on version.
        @test any(s -> occursin(r"Differential\(z\b", s), bc_strs)
        @test any(s -> occursin("v_dep", s), bc_strs)
        # The diffusion coefficient name must appear.
        @test any(s -> occursin("VertDiff", s) && occursin("_D", s), bc_strs)
        # And the slice-ODE must NOT appear as a standalone equation in the
        # PDE's equation list — it should have been replaced by the BC.
        eq_strs = [string(eq) for eq in pde.eqs]
        @test !any(s -> occursin(r"Differential\(t\b", s) && occursin("at_z", s),
                   eq_strs)
    end

    @testset "Extension-gated: removed exports are gone" begin
        # These names were removed as part of the extension refactor. They
        # must not exist as exported symbols of the main package.
        @test !isdefined(EarthSciAST, :to_mtk_system)
        @test !isdefined(EarthSciAST, :to_catalyst_system)
        @test !isdefined(EarthSciAST, :from_mtk_system)
        @test !isdefined(EarthSciAST, :from_catalyst_system)
        @test !isdefined(EarthSciAST, :check_mtk_availability)
        @test !isdefined(EarthSciAST, :check_catalyst_availability)
        # The vestigial Mock* fallbacks were deleted too (the MTK-free path
        # is flatten/FlattenedSystem + build_evaluator/simulate).
        @test !isdefined(EarthSciAST, :MockMTKSystem)
        @test !isdefined(EarthSciAST, :MockPDESystem)
        @test !isdefined(EarthSciAST, :MockCatalystSystem)
    end
end
