# Reference Resolution - Mixed System Types (Julia)

**Source:** `/home/ctessum/EarthSciAST/pkg/EarthSciAST.jl/test/reference_resolution_test.jl`

```julia
# Test with models, reaction_systems, data_loaders, and operators
        metadata = Metadata("MixedSystemTest")

        # Model
        model_vars = Dict("temperature" => ModelVariable(StateVariable, default=298.15, units="K"))
        model_eqs = [Equation(VarExpr("D(temperature, t)"), NumExpr(0.0))]
        model = Model(model_vars, model_eqs)

        # ReactionSystem
        species = [Species("O3", description="Ozone")]
        reactions = [Reaction(Dict("O3" => 1), Dict{String,Int}(), VarExpr("k_loss"))]
        params = [Parameter("k_loss", 1.0e-5, units="1/s")]
        reaction_system = ReactionSystem(species, reactions, parameters=params)

        # DataLoader and Operator (don't have variables, but should be findable)
        data_loader = DataLoader("file", "/path/to/data.nc", description="Meteorological data")
        operator = Operator("spatial", "advection", description="Wind transport")

        esm_file = EsmFile("0.1.0", metadata,
                          models=Dict("Meteorology" => model),
                          reaction_systems=Dict("Chemistry" => reaction_system),
                          data_loaders=Dict("MetData" => data_loader),
                          operators=Dict("Transport" => operator))

        # Test model variable
        result = resolve_qualified_reference(esm_file, "Meteorology.temperature")
        @test result.system_type == :model
        @test result.variable_name == "temperature"

        # Test reaction system species
        result = resolve_qualified_reference(esm_file, "Chemistry.O3")
        @test result.system_type == :reaction_system
        @test result.variable_name == "O3"

        # Test reaction system parameter
        result = resolve_qualified_reference(esm_file, "Chemistry.k_loss")
        @test result.system_type == :reaction_system
        @test result.variable_name == "k_loss"

        # Test that data_loaders and operators are found but don't have variables
        @test_throws QualifiedReferenceError resolve_qualified_reference(esm_file, "MetData.some_var")
        @test_throws QualifiedReferenceError resolve_qualified_reference(esm_file, "Transport.some_var")
```

