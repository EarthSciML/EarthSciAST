# Reference Resolution - Simple Cases (Julia)

**Source:** `/home/ctessum/EarthSciAST/pkg/EarthSciAST.jl/test/reference_resolution_test.jl`

```julia
# Create test ESM file with simple model
        metadata = Metadata("TestModel")

        # Create a simple model with one variable
        variables = Dict(
            "O3" => ModelVariable(StateVariable, default=0.0, description="Ozone concentration", units="ppbv")
        )
        equations = [Equation(VarExpr("D(O3, t)"), NumExpr(0.0))]
        simple_model = Model(variables, equations)

        models = Dict("AtmosphereChemistry" => simple_model)
        esm_file = EsmFile("0.1.0", metadata, models=models)

        # Test successful resolution
        result = resolve_qualified_reference(esm_file, "AtmosphereChemistry.O3")
        @test result.variable_name == "O3"
        @test result.system_path == ["AtmosphereChemistry"]
        @test result.system_type == :model
        @test result.resolved_system == simple_model

        # Test reference to non-existent system
        @test_throws QualifiedReferenceError resolve_qualified_reference(esm_file, "NonExistent.O3")

        # Test reference to non-existent variable
        @test_throws QualifiedReferenceError resolve_qualified_reference(esm_file, "AtmosphereChemistry.NO2")

        # Test bare reference (should fail - no system context)
        @test_throws QualifiedReferenceError resolve_qualified_reference(esm_file, "O3")

        # Test empty reference
        @test_throws QualifiedReferenceError resolve_qualified_reference(esm_file, "")
```

