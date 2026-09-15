# Exact unit scales and scale agreement (esm-spec §4.8.1, §4.8.3).
#
# A scale agreement — `m + km`, `m/s = mi/h` — is decided on an EXACT scale read
# off a Unitful unit's components, never on Unitful's float conversion factor,
# and operands that must agree have to agree in scale as well as dimension.

using Test
using EarthSciAST
using Unitful

@testset "exact unit scales (esm-spec §4.8.1)" begin
    @testset "every registry entry's exact scale equals Unitful's own factor" begin
        # A Unitful unit name missing from the exact table would read as exactly
        # 1 and fail here, so this is what keeps the table complete.
        for (sym, u) in EarthSciAST._UNIT_REGISTRY
            a = Unitful.absoluteunit(u)
            want = Float64(Unitful.ustrip(Unitful.upreferred(1.0 * a)))
            got = Float64(EarthSciAST._exact_scale(u))
            @test isapprox(got, want; rtol = 1e-12) || (@info "exact scale disagrees" sym got want; false)
        end
    end

    @testset "the reconciled entries render exactly" begin
        exact(s) = EarthSciAST.exact_ratio_string(EarthSciAST._exact_scale(EarthSciAST.parse_units(s)))
        @test exact("Torr") == "20265/152"
        @test exact("psi") == "8896443230521/1290320000"
        @test exact("degF") == "5/9"
        @test exact("deg") == "1/180*pi"
        @test exact("mi") == "201168/125"
        @test exact("hp") == "37284993579113511/50000000000000"
        @test exact("DU") == "268670000000000000000"
    end

    @testset "operands must agree in scale" begin
        units = Dict("x" => "m", "y" => "km", "z" => "m", "flag" => "1")
        @test !isempty(EarthSciAST.expression_unit_findings(_op("+", _v("x"), _v("y")), units))
        @test isempty(EarthSciAST.expression_unit_findings(_op("+", _v("x"), _v("z")), units))
        @test !isempty(EarthSciAST.expression_unit_findings(
            _op("ifelse", _v("flag"), _v("x"), _v("y")), units))
    end

    @testset "a conversion carried by a quantity's units cancels exactly" begin
        units = Dict("speed_mph" => "mi/h", "ms_per_mph" => "m*h/(mi*s)")
        got = EarthSciAST.get_expression_dimensions(_op("*", _v("speed_mph"), _v("ms_per_mph")), units)
        @test got !== nothing
        @test EarthSciAST._exact_scale(got) == EarthSciAST._exact_scale(EarthSciAST.parse_units("m/s"))
        bare = EarthSciAST.get_expression_dimensions(_v("speed_mph"), units)
        @test EarthSciAST._exact_scale(bare) != EarthSciAST._exact_scale(EarthSciAST.parse_units("m/s"))
    end
end
