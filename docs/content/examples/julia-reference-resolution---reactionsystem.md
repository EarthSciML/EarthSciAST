# Reference Resolution - ReactionSystem (Julia)

**Source:** `/home/ctessum/EarthSciAST/pkg/EarthSciAST.jl/test/reference_resolution_test.jl`

```julia
# Create test reaction system with subsystems
        metadata = Metadata("ReactionSystemTest")

        # Create species and parameters
        species = [
            Species("O3", molecular_weight=48.0, description="Ozone"),
            Species("NO", molecular_weight=30.0, description="Nitric oxide")
        ]
        parameters = [
            Parameter("k1", 1.0e-3, description="Rate constant", units="1/s")
        ]
        reactions = [
            Reaction(Dict("O3" => 1, "NO" => 1), Dict("NO2" => 1, "O2" => 1), VarExpr("k1"))
        ]

        # Create subsystem
        sub_species = [Species("HO2", molecular_weight=33.0, description="Hydroperoxy radical")]
        sub_params = [Parameter("k2", 2.0e-4, description="HO2 rate", units="1/s")]
        sub_reactions = [Reaction(Dict("HO2" => 2), Dict("H2O2" => 1, "O2" => 1), VarExpr("k2"))]
        subsystem = ReactionSystem(sub_species, sub_reactions, parameters=sub_params)

        main_system = ReactionSystem(species, reactions, parameters=parameters, subsystems=Dict("HO2Chemistry" => subsystem))

        reaction_systems = Dict("FastChemistry" => main_system)
        esm_file = EsmFile("0.1.0", metadata, reaction_systems=reaction_systems)

        # Test species resolution
        result = resolve_qualified_reference(esm_file, "FastChemistry.O3")
        @test result.variable_name == "O3"
        @test result.system_path == ["FastChemistry"]
        @test result.system_type == :reaction_system
        @test result.resolved_system == main_system

        # Test parameter resolution
        result = resolve_qualified_reference(esm_file, "FastChemistry.k1")
        @test result.variable_name == "k1"
        @test result.system_path == ["FastChemistry"]
        @test result.system_type == :reaction_system
        @test result.resolved_system == main_system

        # Test subsystem species resolution
        result = resolve_qualified_reference(esm_file, "FastChemistry.HO2Chemistry.HO2")
        @test result.variable_name == "HO2"
        @test result.system_path == ["FastChemistry", "HO2Chemistry"]
        @test result.system_type == :reaction_system
        @test result.resolved_system == subsystem

        # Test subsystem parameter resolution
        result = resolve_qualified_reference(esm_file, "FastChemistry.HO2Chemistry.k2")
        @test result.variable_name == "k2"
        @test result.system_path == ["FastChemistry", "HO2Chemistry"]
        @test result.system_type == :reaction_system
        @test result.resolved_system == subsystem
```

