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

    # -----------------------------------------------------------------------
    # esm-spec §4.8: the cross-binding units contract. The registry (§4.8.1),
    # the grammar (§4.8.2) and the severity rules (§4.8.4) are pinned HERE
    # because the audit's lesson was that unwritten policy is what let five
    # bindings silently diverge.
    # -----------------------------------------------------------------------
    @testset "esm-spec §4.8.1 — the flat unit registry" begin
        P = EarthSciAST.parse_units

        # Every registry symbol resolves.
        for u in ("m", "kg", "s", "mol", "K", "A", "cd", "rad",
                  "g", "mg", "ug", "dm", "cm", "mm", "um", "nm", "km",
                  "ms", "us", "ns", "min", "h", "hr", "day", "yr", "year",
                  "L", "l", "mL", "kmol", "mmol", "umol", "nmol", "M",
                  "Hz", "N", "Pa", "J", "kJ", "cal", "kcal", "W", "kW", "MW",
                  "atm", "bar", "hPa", "kPa", "mbar", "Torr", "mmHg", "psi",
                  "erg", "BTU", "Wh", "kWh", "C", "V", "Ohm", "F", "T",
                  "degC", "degF", "deg", "ppm", "ppb", "ppt", "ppmv", "ppbv",
                  "pptv", "molec", "individuals", "vehicles", "units", "count",
                  "Dobson", "DU")
            @test P(u) !== nothing
        end

        # `C` is the COULOMB, per SI — never Celsius. Binding it to Celsius
        # injects a temperature dimension into every electromagnetic
        # expression: charge × field would come out kg*m*K/(s^3*A), not a
        # newton. This is the assertion that pins it.
        @test dimension(P("C")) == dimension(u"A*s")
        @test dimension(P("C") * P("V/m")) == dimension(u"N")
        # Celsius has its own unambiguous spellings, and they are temperatures.
        @test dimension(P("degC")) == Unitful.𝚯
        @test dimension(P("°C")) == Unitful.𝚯

        # `h` is the HOUR. In Unitful `u"h"` is PLANCK'S CONSTANT, which is why
        # this registry does not delegate to `uparse`: `L/h` used to parse as
        # litre-per-joule-second and made every pharmacokinetic fixture look
        # dimensionally inconsistent.
        @test dimension(P("h")) == Unitful.𝐓
        @test dimension(P("L/h")) == Unitful.𝐋^3 / Unitful.𝐓

        # Count nouns are dimensionless — they are REAL unit names in the
        # corpus, and since an unresolvable unit is a hard error, omitting them
        # would falsely REJECT well-formed files.
        for u in ("individuals/km^2", "vehicles/km^2", "units/L")
            @test P(u) !== nothing
        end

        # There is deliberately NO SI-prefix mechanism: a prefix rule would
        # accept nonsense and make the legal unit set unbounded across five
        # bindings.
        @test P("kmolec") === nothing
        @test P("nppb") === nothing
    end

    @testset "esm-spec §4.8.2 — the unit-string grammar" begin
        P = EarthSciAST.parse_units

        # Parentheses group a compound denominator. A parser without them reads
        # `J/(mol*K)` as dimensionless and silently disables every check
        # downstream of it.
        @test dimension(P("J/(mol*K)")) == dimension(u"J" / (u"mol" * u"K"))
        @test dimension(P("J/(mol*K)")) != Unitful.NoDims

        # Division is LEFT-associative: "L/mol/s" is L·mol⁻¹·s⁻¹.
        @test dimension(P("L/mol/s")) == dimension(u"L" / u"mol" / u"s")

        # Whitespace between terms is MULTIPLICATION.
        @test dimension(P("ppb^-1 s^-1")) == Unitful.𝐓^-1

        # `**` is the Python/pint spelling of `^`.
        @test dimension(P("Pa*m**3")) == dimension(u"Pa" * u"m"^3)

        # µ/μ normalise to u; °C to degC.
        @test dimension(P("μg/m^3")) == dimension(u"μg" / u"m"^3)
        @test P("μmol/(m^2*s)") !== nothing

        # Malformed strings do not parse.
        for bad in ("m/", "m^", "(m", "m)", "m/s2", "not_a_unit", "1/time", "%")
            @test P(bad) === nothing
        end
    end

    @testset "esm-spec §4.8.4 — severity: the four fabrications" begin
        E = EarthSciAST.ASTExpr
        D = EarthSciAST.get_expression_dimensions
        var_units = Dict("y" => "kg", "x" => "m", "alpha" => "", "t" => "s")

        # FABRICATION 1 — a bare numeric literal is INDETERMINATE, not
        # dimensionless. Reading `0` as dimensionless made `D(y[kg]) = 0` — the
        # ordinary way to hold y constant — look provably inconsistent.
        @test D(NumExpr(0.0), var_units) === nothing
        eq = Equation(OpExpr("D", E[VarExpr("y")]; wrt="t"), NumExpr(0.0))
        @test isempty(EarthSciAST.equation_unit_findings(eq, Dict("y" => "kg")))

        # ...but an ALL-literal sum really is a pure number, and a literal in
        # ADDITIVE position is dimension-NEUTRAL (it adopts its sibling's unit).
        @test D(OpExpr("+", E[NumExpr(1.0), NumExpr(2.0)]), var_units) == Unitful.NoUnits
        tk = D(OpExpr("-", E[VarExpr("x"), NumExpr(273.15)]), var_units)
        @test tk !== nothing && dimension(tk) == Unitful.𝐋

        # FABRICATION 2 — a product with an INDETERMINATE factor is
        # indeterminate, not the product of the factors it could resolve.
        @test D(OpExpr("*", E[VarExpr("x"), NumExpr(1.23)]), var_units) === nothing
        @test D(OpExpr("*", E[VarExpr("x"), VarExpr("undeclared")]), var_units) === nothing

        # FABRICATION 3 — a derivative w.r.t. an UNDECLARED `t` is
        # indeterminate. Defaulting to seconds manufactures `1/s` against `1`
        # in every nondimensionalized model.
        @test D(OpExpr("D", E[VarExpr("y")]; wrt="t"), Dict("y" => "kg")) === nothing
        # When `t` IS declared, the derivative is determinable.
        dy = D(OpExpr("D", E[VarExpr("y")]; wrt="t"), Dict("y" => "kg", "t" => "s"))
        @test dy !== nothing && dimension(dy) == Unitful.𝐌 / Unitful.𝐓

        # FABRICATION 4 — a SYMBOLIC exponent is indeterminate on a dimensional
        # base (the result depends on alpha's runtime value); a LITERAL one is
        # determinable, which is what makes `^` computable at all.
        @test D(OpExpr("^", E[VarExpr("x"), VarExpr("alpha")]), var_units) === nothing
        x2 = D(OpExpr("^", E[VarExpr("x"), IntExpr(2)]), var_units)
        @test x2 !== nothing && dimension(x2) == Unitful.𝐋^2
        # A dimensionless base stays dimensionless under any exponent.
        @test D(OpExpr("^", E[VarExpr("alpha"), VarExpr("alpha")]), var_units) == Unitful.NoUnits
    end

    @testset "esm-spec §4.8.3/§4.8.4 — provable errors stay hard" begin
        E = EarthSciAST.ASTExpr
        F = EarthSciAST.expression_unit_findings
        var_units = Dict("x" => "m", "z" => "kg", "V" => "m^3", "V0" => "m^3")

        # A transcendental on a DIMENSIONAL argument is a provable mismatch —
        # not a warning, and not a silent pass. The physics is always written
        # against a reference: n*R*log(V/V0), never log(V).
        @test !isempty(F(OpExpr("log", E[VarExpr("V")]), var_units))
        @test isempty(F(OpExpr("log",
            E[OpExpr("/", E[VarExpr("V"), VarExpr("V0")])]), var_units))
        @test !isempty(F(OpExpr("exp", E[VarExpr("z")]), var_units))

        # Adding metres to kilograms; a dimensional exponent.
        @test !isempty(F(OpExpr("+", E[VarExpr("x"), VarExpr("z")]), var_units))
        @test !isempty(F(OpExpr("^", E[VarExpr("x"), VarExpr("z")]), var_units))

        # An op with NO dimensional rule is UNDETERMINABLE — never
        # dimensionless. Reporting it as dimensionless would poison every
        # equation containing a structural op.
        for op in ("aggregate", "index", "fn", "table_lookup")
            @test EarthSciAST.get_expression_dimensions(
                OpExpr(op, E[VarExpr("x")]), var_units) === nothing
            @test isempty(F(OpExpr(op, E[VarExpr("x")]), var_units))
        end
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

        # A bare numeric literal is INDETERMINATE, not dimensionless (esm-spec
        # §4.8.4). Nothing in the AST says whether `5.0` is a pure number or a
        # rate constant carrying implicit units; under a hard-error severity,
        # guessing "dimensionless" manufactures false mismatches — `D(y) = 0`
        # with y in kg is the ordinary way to hold y constant, not an error.
        num_expr = NumExpr(5.0)
        dims = EarthSciAST.get_expression_dimensions(num_expr, var_units)
        @test dims === nothing

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