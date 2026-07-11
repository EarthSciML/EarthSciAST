using Test
using EarthSciAST
using BenchmarkTools

@testset "MTK/Catalyst Mock Conversion Tests" begin

    @testset "ESM Model → MockMTKSystem constructor preserves variable classification" begin
        # Simple harmonic oscillator
        variables = Dict{String,ModelVariable}(
            "x" => ModelVariable(StateVariable; default=1.0, description="Position"),
            "v" => ModelVariable(StateVariable; default=0.0, description="Velocity"),
            "omega" => ModelVariable(ParameterVariable; default=1.0, description="Angular frequency"),
            "energy" => ModelVariable(ObservedVariable;
                expression=OpExpr("+", EarthSciAST.ASTExpr[
                    OpExpr("/", EarthSciAST.ASTExpr[OpExpr("^", EarthSciAST.ASTExpr[VarExpr("v"), NumExpr(2.0)]), NumExpr(2.0)]),
                    OpExpr("/", EarthSciAST.ASTExpr[
                        OpExpr("*", EarthSciAST.ASTExpr[
                            OpExpr("^", EarthSciAST.ASTExpr[VarExpr("omega"), NumExpr(2.0)]),
                            OpExpr("^", EarthSciAST.ASTExpr[VarExpr("x"), NumExpr(2.0)])
                        ]),
                        NumExpr(2.0)
                    ])
                ]))
        )

        equations = [
            Equation(OpExpr("D", EarthSciAST.ASTExpr[VarExpr("x")], wrt="t"),
                     VarExpr("v")),
            Equation(OpExpr("D", EarthSciAST.ASTExpr[VarExpr("v")], wrt="t"),
                     OpExpr("*", EarthSciAST.ASTExpr[
                        OpExpr("-", EarthSciAST.ASTExpr[OpExpr("^", EarthSciAST.ASTExpr[VarExpr("omega"), NumExpr(2.0)])]),
                        VarExpr("x")]))
        ]

        model = Model(variables, equations)
        mtk_sys = MockMTKSystem(model; name=:HarmonicOscillator)

        @test mtk_sys isa MockMTKSystem
        @test mtk_sys.name == :HarmonicOscillator
        @test length(mtk_sys.state_variables) == 2  # x, v
        @test length(mtk_sys.parameters) == 1        # omega
        @test length(mtk_sys.observed_variables) == 1 # energy
        @test length(mtk_sys.equations) == 3          # dx/dt, dv/dt, energy ~ expr

        # After flatten, names are namespaced with the system name.
        @test "HarmonicOscillator.x" in mtk_sys.state_variables
        @test "HarmonicOscillator.v" in mtk_sys.state_variables
        @test "HarmonicOscillator.omega" in mtk_sys.parameters
        @test "HarmonicOscillator.energy" in mtk_sys.observed_variables
    end

    @testset "ESM ReactionSystem → MockCatalystSystem constructor preserves stoichiometry" begin
        species = [
            Species("O3", description="Ozone"),
            Species("NO", description="Nitric oxide"),
            Species("NO2", description="Nitrogen dioxide"),
        ]
        parameters = [
            Parameter("k1", 1.8e-12, description="NO + O3 rate", units="cm^3/molec/s"),
            Parameter("j1", 0.005, description="NO2 photolysis rate", units="1/s"),
            Parameter("M", 2.46e19, description="Air density", units="molec/cm^3"),
        ]
        reactions = [
            Reaction(Dict("NO" => 1, "O3" => 1), Dict("NO2" => 1),
                     OpExpr("*", EarthSciAST.ASTExpr[VarExpr("k1"), VarExpr("M")])),
            Reaction(Dict("NO2" => 1), Dict("NO" => 1, "O3" => 1),
                     VarExpr("j1")),
        ]

        rsys = ReactionSystem(species, reactions; parameters=parameters)
        cat_sys = MockCatalystSystem(rsys; name=:OzonePhotochemistry)

        @test cat_sys isa MockCatalystSystem
        @test cat_sys.name == :OzonePhotochemistry
        @test length(cat_sys.species) == 3
        @test length(cat_sys.parameters) == 3
        @test length(cat_sys.reactions) == 2
        @test "O3" in cat_sys.species
        @test "NO" in cat_sys.species
        @test "NO2" in cat_sys.species
        @test "k1" in cat_sys.parameters
    end

    @testset "MockMTKSystem(::Model) errors on PDE model with pointer to MockPDESystem" begin
        # The spatial dimension `x` is derived from the grad operators'
        # `dim="x"` (esm-spec v0.8.0 removed the Domain.spatial table).
        vars = Dict{String,ModelVariable}(
            "u" => ModelVariable(StateVariable; default=1.0),
            "D" => ModelVariable(ParameterVariable; default=0.1),
        )
        # PDE: du/dt = D * grad(grad(u, x), x)  (spatial derivatives present)
        eq = Equation(
            OpExpr("D", EarthSciAST.ASTExpr[VarExpr("u")], wrt="t"),
            OpExpr("*", EarthSciAST.ASTExpr[
                VarExpr("D"),
                OpExpr("grad", EarthSciAST.ASTExpr[
                    OpExpr("grad", EarthSciAST.ASTExpr[VarExpr("u")], dim="x"),
                ], dim="x"),
            ])
        )
        model = Model(vars, [eq])
        file = EsmFile("0.1.0", Metadata("Diffuse");
            models=Dict("Diffuse" => model))
        flat = flatten(file)
        @test :x in flat.independent_variables

        @test_throws ArgumentError MockMTKSystem(flat)
        pde = MockPDESystem(flat; name=:Diffuse)
        @test pde isa MockPDESystem
        @test :x in pde.independent_variables
    end

    @testset "MockPDESystem(::FlattenedSystem) errors on pure-ODE input" begin
        vars = Dict{String,ModelVariable}(
            "x" => ModelVariable(StateVariable; default=1.0),
            "k" => ModelVariable(ParameterVariable; default=0.5),
        )
        eq = Equation(
            OpExpr("D", EarthSciAST.ASTExpr[VarExpr("x")], wrt="t"),
            OpExpr("*", EarthSciAST.ASTExpr[OpExpr("-", EarthSciAST.ASTExpr[VarExpr("k")]), VarExpr("x")]),
        )
        flat = flatten(Model(vars, [eq]); name="OnlyODE")
        @test flat.independent_variables == [:t]
        @test_throws ArgumentError MockPDESystem(flat)
        ode_mock = MockMTKSystem(flat; name=:OnlyODE)
        @test ode_mock isa MockMTKSystem
    end

    @testset "Empty / edge cases" begin
        empty_model = Model(Dict{String,ModelVariable}(), Equation[])
        @test_nowarn MockMTKSystem(empty_model)
        empty_sys = MockMTKSystem(empty_model; name=:EmptyModel)
        @test empty_sys isa MockMTKSystem

        # Empty reaction system
        empty_rsys = ReactionSystem(Species[], Reaction[])
        @test_nowarn MockCatalystSystem(empty_rsys)
        empty_cat = MockCatalystSystem(empty_rsys; name=:EmptyReactions)
        @test empty_cat isa MockCatalystSystem
    end

    @testset "Performance: large reaction system mock conversion" begin
        n_species = 20
        n_reactions = 30
        large_species = [Species("S$i") for i in 1:n_species]
        large_params = [Parameter("k$i", rand()) for i in 1:n_reactions]
        large_reactions = Reaction[]
        for i in 1:n_reactions
            reactants = Dict{String,Int}("S$(rand(1:n_species))" => 1)
            products = Dict{String,Int}("S$(rand(1:n_species))" => 1)
            push!(large_reactions, Reaction(reactants, products, VarExpr("k$i")))
        end
        large_rsys = ReactionSystem(large_species, large_reactions; parameters=large_params)
        bench = @benchmark MockCatalystSystem($large_rsys; name=:Large)
        @test bench.times[1] > 0
        @test (median(bench.times) / 1e6) < 100
        sys = MockCatalystSystem(large_rsys; name=:Large)
        @test length(sys.species) == n_species
        @test length(sys.parameters) == n_reactions
        @test length(sys.reactions) == n_reactions
    end
end
