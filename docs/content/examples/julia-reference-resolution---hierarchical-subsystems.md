# Reference Resolution - Hierarchical Subsystems (Julia)

**Source:** `/home/ctessum/EarthSciAST/pkg/EarthSciAST.jl/test/reference_resolution_test.jl`

```julia
# Create nested model structure: Atmosphere -> Chemistry -> GasPhase
        metadata = Metadata("HierarchicalModel")

        # Inner-most subsystem (GasPhase)
        gas_phase_vars = Dict(
            "O3" => ModelVariable(StateVariable, default=0.0, description="Ozone", units="ppbv"),
            "NO2" => ModelVariable(StateVariable, default=0.0, description="Nitrogen dioxide", units="ppbv")
        )
        gas_phase_eqs = [
            Equation(VarExpr("D(O3, t)"), NumExpr(0.1)),
            Equation(VarExpr("D(NO2, t)"), NumExpr(-0.05))
        ]
        gas_phase = Model(gas_phase_vars, gas_phase_eqs)

        # Middle level (Chemistry) with GasPhase as subsystem
        chemistry_vars = Dict(
            "temperature" => ModelVariable(ParameterVariable, default=298.15, description="Temperature", units="K")
        )
        chemistry_eqs = Equation[]
        chemistry_subsystems = Dict("GasPhase" => gas_phase)
        chemistry = Model(chemistry_vars, chemistry_eqs, subsystems=chemistry_subsystems)

        # Top level (Atmosphere) with Chemistry as subsystem
        atmosphere_vars = Dict(
            "pressure" => ModelVariable(ParameterVariable, default=101325.0, description="Pressure", units="Pa")
        )
        atmosphere_eqs = Equation[]
        atmosphere_subsystems = Dict("Chemistry" => chemistry)
        atmosphere = Model(atmosphere_vars, atmosphere_eqs, subsystems=atmosphere_subsystems)

        models = Dict("Atmosphere" => atmosphere)
        esm_file = EsmFile("0.1.0", metadata, models=models)

        # Test resolution at different levels

        # Top level variable
        result = resolve_qualified_reference(esm_file, "Atmosphere.pressure")
        @test result.variable_name == "pressure"
        @test result.system_path == ["Atmosphere"]
        @test result.system_type == :model
        @test result.resolved_system == atmosphere

        # Second level variable
        result = resolve_qualified_reference(esm_file, "Atmosphere.Chemistry.temperature")
        @test result.variable_name == "temperature"
        @test result.system_path == ["Atmosphere", "Chemistry"]
        @test result.system_type == :model
        @test result.resolved_system == chemistry

        # Third level variables
        result = resolve_qualified_reference(esm_file, "Atmosphere.Chemistry.GasPhase.O3")
        @test result.variable_name == "O3"
        @test result.system_path == ["Atmosphere", "Chemistry", "GasPhase"]
        @test result.system_type == :model
        @test result.resolved_system == gas_phase

        result = resolve_qualified_reference(esm_file, "Atmosphere.Chemistry.GasPhase.NO2")
        @test result.variable_name == "NO2"
        @test result.system_path == ["Atmosphere", "Chemistry", "GasPhase"]
        @test result.system_type == :model
        @test result.resolved_system == gas_phase

        # Test non-existent paths
        @test_throws QualifiedReferenceError resolve_qualified_reference(esm_file, "Atmosphere.Physics.temperature")
        @test_throws QualifiedReferenceError resolve_qualified_reference(esm_file, "Atmosphere.Chemistry.AerosolPhase.SO4")
        @test_throws QualifiedReferenceError resolve_qualified_reference(esm_file, "Ocean.Chemistry.GasPhase.O3")
```

