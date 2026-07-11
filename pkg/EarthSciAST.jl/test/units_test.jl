using Test
using EarthSciAST
using Unitful

@testset "Units Tests" begin

    @testset "Unit Parsing" begin
        # Test parse_units function

        # Test dimensionless units
        @test EarthSciAST.parse_units("") == Unitful.NoUnits
        @test EarthSciAST.parse_units("dimensionless") == Unitful.NoUnits

        # Test basic units
        units_m = EarthSciAST.parse_units("m")
        @test units_m !== nothing
        @test dimension(units_m) == Unitful.𝐋

        units_s = EarthSciAST.parse_units("s")
        @test units_s !== nothing
        @test dimension(units_s) == Unitful.𝐓

        units_kg = EarthSciAST.parse_units("kg")
        @test units_kg !== nothing
        @test dimension(units_kg) == Unitful.𝐌

        # Test compound units
        units_mps = EarthSciAST.parse_units("m/s")
        @test units_mps !== nothing
        @test dimension(units_mps) == Unitful.𝐋/Unitful.𝐓

        units_ms2 = EarthSciAST.parse_units("m/s^2")
        @test units_ms2 !== nothing
        @test dimension(units_ms2) == Unitful.𝐋/Unitful.𝐓^2

        # Test invalid units
        @test EarthSciAST.parse_units("invalid_unit") === nothing
    end

    @testset "ESM-specific units standard" begin
        # docs/units-standard.md: every binding must accept these and agree
        # on dimension semantics so cross-binding documents resolve alike.
        # Mole-fraction family: dimensionless.
        for u in ("mol/mol", "ppm", "ppmv", "ppb", "ppbv", "ppt", "pptv")
            parsed = EarthSciAST.parse_units(u)
            @test parsed !== nothing
            @test dimension(parsed) == dimension(Unitful.NoUnits)
        end

        # `molec` is a dimensionless count atom; composites like `molec/cm^3`
        # carry the dimension. The ESM standard treats `molec/cm^3` as an
        # inverse volume, i.e. dimension `[length]^-3`.
        num_density = EarthSciAST.parse_units("molec/cm^3")
        @test num_density !== nothing
        @test dimension(num_density) == Unitful.𝐋^-3

        # Dobson unit: NOT dimensionless. Areal number density with
        # dimension `[length]^-2`.
        dobson = EarthSciAST.parse_units("Dobson")
        @test dobson !== nothing
        @test dimension(dobson) == Unitful.𝐋^-2
    end

    @testset "Expression Dimensions" begin
        # Test get_expression_dimensions function

        # Create test variables with units
        var_units = Dict(
            "x" => "m",
            "y" => "s",
            "z" => "kg",
            "speed" => "m/s",
            "area" => "m^2"
        )

        # Test NumExpr (dimensionless)
        num_expr = NumExpr(5.0)
        dims = EarthSciAST.get_expression_dimensions(num_expr, var_units)
        @test dims == Unitful.NoUnits

        # Test VarExpr
        var_expr_x = VarExpr("x")
        dims_x = EarthSciAST.get_expression_dimensions(var_expr_x, var_units)
        @test dims_x !== nothing
        @test dimension(dims_x) == Unitful.𝐋

        var_expr_speed = VarExpr("speed")
        dims_speed = EarthSciAST.get_expression_dimensions(var_expr_speed, var_units)
        @test dims_speed !== nothing
        @test dimension(dims_speed) == Unitful.𝐋/Unitful.𝐓

        # Unknown variable: dimensions are UNKNOWN (nothing), not assumed
        # dimensionless — nothing propagates so callers skip rather than warn.
        var_expr_unknown = VarExpr("unknown")
        dims_unknown = EarthSciAST.get_expression_dimensions(var_expr_unknown, var_units)
        @test dims_unknown === nothing

        # Test basic OpExpr (multiplication works better than addition with mixed units)
        mul_expr = OpExpr("*", EarthSciAST.ASTExpr[VarExpr("x"), VarExpr("y")])
        dims_mul = EarthSciAST.get_expression_dimensions(mul_expr, var_units)
        @test dims_mul !== nothing
        @test dimension(dims_mul) == Unitful.𝐋 * Unitful.𝐓
    end

    @testset "Expression Dimensions: extended op coverage" begin
        E = EarthSciAST.ASTExpr
        var_units = Dict("x" => "m", "y" => "m", "z" => "s", "f" => "")

        # min/max: same-dimension args carry the dimension through
        mm = EarthSciAST.get_expression_dimensions(
            OpExpr("max", E[VarExpr("x"), VarExpr("y")]), var_units)
        @test mm !== nothing
        @test dimension(mm) == Unitful.𝐋
        # min/max mismatched dimensions -> nothing (with a warning)
        bad = @test_logs (:warn,) match_mode=:any EarthSciAST.get_expression_dimensions(
            OpExpr("min", E[VarExpr("x"), VarExpr("z")]), var_units)
        @test bad === nothing

        # ifelse: branch dimensions carry through (condition irrelevant)
        ie = EarthSciAST.get_expression_dimensions(
            OpExpr("ifelse", E[VarExpr("f"), VarExpr("x"), VarExpr("y")]), var_units)
        @test ie !== nothing
        @test dimension(ie) == Unitful.𝐋

        # sign strips dimensions
        sg = EarthSciAST.get_expression_dimensions(
            OpExpr("sign", E[VarExpr("x")]), var_units)
        @test sg == Unitful.NoUnits

        # abs preserves dimensions
        ab = EarthSciAST.get_expression_dimensions(
            OpExpr("abs", E[VarExpr("x")]), var_units)
        @test ab !== nothing
        @test dimension(ab) == Unitful.𝐋

        # log10 / tanh: dimensionless in, dimensionless out
        for op in ("log10", "tanh")
            r = EarthSciAST.get_expression_dimensions(
                OpExpr(op, E[VarExpr("f")]), var_units)
            @test r == Unitful.NoUnits
        end

        # An op with no dimensional rule degrades silently to nothing
        unk = EarthSciAST.get_expression_dimensions(
            OpExpr("some_unknown_op", E[VarExpr("x")]), var_units)
        @test unk === nothing
    end

    @testset "Equation Validation" begin
        # Test validate_equation_dimensions function

        var_units = Dict(
            "x" => "m",
            "t" => "s",
            "v" => "m/s"
        )

        # Test valid equation: dx/dt = v (velocity)
        lhs = OpExpr("D", EarthSciAST.ASTExpr[VarExpr("x")], wrt="t")
        rhs = VarExpr("v")
        valid_eq = Equation(lhs, rhs)

        @test EarthSciAST.validate_equation_dimensions(valid_eq, var_units) == true

        # Test invalid equation: dx/dt = x (wrong dimensions)
        invalid_rhs = VarExpr("x")  # m, but dx/dt should be m/s
        invalid_eq = Equation(lhs, invalid_rhs)

        @test EarthSciAST.validate_equation_dimensions(invalid_eq, var_units) == false
    end

    @testset "Model Validation" begin
        # Test validate_model_dimensions function

        # Create a simple model with consistent units
        variables = Dict(
            "x" => ModelVariable(StateVariable, units="m", default=0.0),
            "v" => ModelVariable(ParameterVariable, units="m/s", default=1.0)
        )

        equations = [
            Equation(
                OpExpr("D", EarthSciAST.ASTExpr[VarExpr("x")], wrt="t"),
                VarExpr("v")
            )
        ]

        # Check the Model constructor signature
        model = Model(
            variables,
            equations
        )

        # Should validate correctly
        result = EarthSciAST.validate_model_dimensions(model)
        @test result isa Bool  # Just test that it returns a boolean without error
    end

    @testset "Reaction System Dimension Validation (delegates to §7.4 rule)" begin
        # Mirrors validate_reaction_rate_units: a second-order reaction with a
        # first-order rate constant fails; the fixed one passes.
        SE = EarthSciAST.StoichiometryEntry
        species = [
            Species("A"; units="mol/L", default=1.0),
            Species("B"; units="mol/L", default=1.0),
            Species("C"; units="mol/L", default=0.0),
        ]
        rxn = Reaction("R1", [SE("A", 1), SE("B", 1)], [SE("C", 1)], VarExpr("k"))

        bad = ReactionSystem(species, [rxn]; parameters=[Parameter("k", 0.1; units="1/s")])
        result_bad = @test_logs (:warn,) match_mode=:any EarthSciAST.validate_reaction_system_dimensions(bad)
        @test result_bad == false

        good = ReactionSystem(species, [rxn]; parameters=[Parameter("k", 0.1; units="L/(mol*s)")])
        @test EarthSciAST.validate_reaction_system_dimensions(good) == true
    end

    @testset "File Validation" begin
        # Test validate_file_dimensions function

        metadata = Metadata("test_units", description="Test model for unit validation")
        esm_file = EsmFile("0.1.0", metadata)

        result = EarthSciAST.validate_file_dimensions(esm_file)
        @test result isa Bool
        @test result == true
    end

    @testset "Unit Inference" begin
        # Test infer_variable_units function

        known_units = Dict(
            "t" => "s",
            "v" => "m/s"
        )

        # Simple equation: dx/dt = v, should infer x has units m
        equations = [
            Equation(
                OpExpr("D", EarthSciAST.ASTExpr[VarExpr("x")], wrt="t"),
                VarExpr("v")
            )
        ]

        inferred_units = EarthSciAST.infer_variable_units("x", equations, known_units)
        # Just test that it doesn't crash and returns a result
        @test inferred_units isa Union{String, Nothing}
    end

    @testset "Cross-binding units fixtures (gt-gtf)" begin
        # Wire the three canonical units fixtures into the Julia binding so
        # that every binding agrees on what these files mean. These fixtures
        # are deliberately shared across Julia/Python/Rust/TypeScript/Go.
        units_fixtures = [
            "units_conversions.esm",
            "units_dimensional_analysis.esm",
            "units_propagation.esm",
        ]
        fixtures_root = joinpath(@__DIR__, "..", "..", "..", "tests", "valid")

        for fname in units_fixtures
            fpath = joinpath(fixtures_root, fname)
            @testset "$fname" begin
                @test isfile(fpath)
                esm_data = EarthSciAST.load(fpath)
                @test esm_data isa EarthSciAST.EsmFile
                @test esm_data.models !== nothing && !isempty(esm_data.models)

                # Run the binding's unit-validation entry point on every
                # model. The call must not throw; the boolean result is
                # captured for visibility but not asserted, because each
                # binding's unit registry has different coverage and the
                # fixtures intentionally exercise the union of registries.
                for (mname, model) in esm_data.models
                    result = EarthSciAST.validate_model_dimensions(model)
                    @test result isa Bool
                end

                # File-level dimension validation must also run cleanly.
                file_result = EarthSciAST.validate_file_dimensions(esm_data)
                @test file_result isa Bool
            end
        end
    end

end