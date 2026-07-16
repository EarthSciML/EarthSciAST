"""
Tests for qualified reference resolution functionality.

Tests the hierarchical dot notation system for resolving references like:
- "System.variable"
- "System.Subsystem.variable"
- "A.B.C.variable"
"""

using Test
using EarthSciAST

@testset "Qualified Reference Resolution" begin

    @testset "Reference Syntax Validation" begin
        # Valid references
        @test validate_reference_syntax("System.variable") == true
        @test validate_reference_syntax("System.Subsystem.variable") == true
        @test validate_reference_syntax("A.B.C.D.variable") == true
        @test validate_reference_syntax("variable") == true
        @test validate_reference_syntax("system_1.var_2") == true
        @test validate_reference_syntax("_private.hidden") == true

        # Invalid references
        @test validate_reference_syntax("") == false
        @test validate_reference_syntax(".variable") == false
        @test validate_reference_syntax("System.") == false
        @test validate_reference_syntax("System..variable") == false
        @test validate_reference_syntax("System.Sub..var") == false
        @test validate_reference_syntax("1System.variable") == false
        @test validate_reference_syntax("System.2variable") == false
        @test validate_reference_syntax("System.var-name") == false
    end

    @testset "Identifier Validation" begin
        # Valid identifiers
        @test is_valid_identifier("variable") == true
        @test is_valid_identifier("Variable") == true
        @test is_valid_identifier("var_2") == true
        @test is_valid_identifier("_private") == true
        @test is_valid_identifier("System123") == true

        # Invalid identifiers
        @test is_valid_identifier("") == false
        @test is_valid_identifier("1variable") == false
        @test is_valid_identifier("var-name") == false
        @test is_valid_identifier("var.name") == false
        @test is_valid_identifier("var name") == false
    end

    @testset "Reference Resolution - Simple Cases" begin
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
    end

    @testset "Reference Resolution - Hierarchical Subsystems" begin
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
    end

    @testset "Reference Resolution - ReactionSystem" begin
        # Create test reaction system with subsystems
        metadata = Metadata("ReactionSystemTest")

        # Create species and parameters
        species = [
            Species("O3", units="ppb", default=80.0, description="Ozone"),
            Species("NO", units="ppb", default=10.0, description="Nitric oxide")
        ]
        parameters = [
            Parameter("k1", 1.0e-3, description="Rate constant", units="1/s")
        ]
        reactions = [
            Reaction(Dict("O3" => 1, "NO" => 1), Dict("NO2" => 1, "O2" => 1), VarExpr("k1"))
        ]

        # Create subsystem
        sub_species = [Species("HO2", units="ppb", default=0.1, description="Hydroperoxy radical")]
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
    end

    @testset "Reference Resolution - Mixed System Types" begin
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

        # DataLoader (doesn't have variables, but should be findable)
        dl_source = DataLoaderSource("file:///path/to/data_{date:%Y%m%d}.nc")
        dl_vars = Dict("met_data" => DataLoaderVariable("met_data", "K"))
        data_loader = DataLoader("grid", dl_source, dl_vars)

        esm_file = EsmFile("0.1.0", metadata,
                          models=Dict("Meteorology" => model),
                          reaction_systems=Dict("Chemistry" => reaction_system),
                          data_loaders=Dict("MetData" => data_loader))

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

        # Test that data_loaders are found but don't have variables
        @test_throws QualifiedReferenceError resolve_qualified_reference(esm_file, "MetData.some_var")
    end

    @testset "DataLoader as a Model subsystem (loader+regridding-model split)" begin
        # The pure-io-data-loaders RFC splits a data component into a pure-I/O
        # DataLoader declared as a SUBSYSTEM of its regridding Model, with couplings
        # naming loader fields THROUGH the parent — `GEOSFP.GEOSFP_I3.PS`,
        # `ERA5.sl.t2m`. `Model.subsystems` is a `Dict{String,Any}` precisely so it
        # can hold one.
        #
        # Regression: `find_subsystem(::Model, ::String)` was annotated
        # `::Union{Model,Nothing}`, so traversing INTO a loader subsystem threw
        # `MethodError: Cannot convert DataLoader to Model` — from the conversion the
        # annotation itself forces. `validate()` CRASHED outright on every assembly
        # using the split, the wildlandfire.esm reference assembly included. The
        # top-level half of this defect was already fixed in
        # `variable_exists_in_system(::DataLoader, …)`; this is the traversal half.
        metadata = Metadata("LoaderSubsystemTest")

        dl_source = DataLoaderSource("file:///GEOSFP.{date:%Y%m%d}.I3.4x5.nc")
        dl_vars = Dict("PS" => DataLoaderVariable("PS", "Pa"))
        loader = DataLoader("grid", dl_source, dl_vars)

        # The regridding model: its own variable, plus the loader mounted as `I3`.
        parent = Model(Dict("w_time" => ModelVariable(StateVariable, units="1")),
                       Equation[])
        parent.subsystems["I3"] = loader

        esm_file = EsmFile("0.1.0", metadata, models=Dict("GEOSFP" => parent))

        # The reference that used to crash: traverse the model into its loader
        # subsystem and land on a loader-exposed field.
        result = resolve_qualified_reference(esm_file, "GEOSFP.I3.PS")
        @test result.variable_name == "PS"
        @test result.resolved_system === loader

        # The parent's own variables still resolve alongside it.
        result = resolve_qualified_reference(esm_file, "GEOSFP.w_time")
        @test result.variable_name == "w_time"

        # A field the loader does not expose stays a clean error, not a crash.
        @test_throws QualifiedReferenceError resolve_qualified_reference(esm_file, "GEOSFP.I3.NOPE")
        # Loaders have no subsystems, so traversing PAST one terminates cleanly.
        @test_throws QualifiedReferenceError resolve_qualified_reference(esm_file, "GEOSFP.I3.deeper.PS")
    end

    @testset "Error Handling and Edge Cases" begin
        # Empty ESM file
        metadata = Metadata("EmptyTest")
        empty_esm = EsmFile("0.1.0", metadata)

        @test_throws QualifiedReferenceError resolve_qualified_reference(empty_esm, "AnySystem.var")

        # ESM file with empty collections
        esm_with_empty = EsmFile("0.1.0", metadata,
                                models=Dict{String,Model}(),
                                reaction_systems=Dict{String,ReactionSystem}())

        @test_throws QualifiedReferenceError resolve_qualified_reference(esm_with_empty, "AnySystem.var")

        # Test malformed references
        valid_model = Model(Dict("var" => ModelVariable(StateVariable)), Equation[])
        valid_esm = EsmFile("0.1.0", metadata, models=Dict("System" => valid_model))

        @test_throws QualifiedReferenceError resolve_qualified_reference(valid_esm, "")
        @test_throws QualifiedReferenceError resolve_qualified_reference(valid_esm, "var")  # bare reference
    end

end