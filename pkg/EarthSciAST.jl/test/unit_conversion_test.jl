# esm-spec §8.5 `unit_conversion`, at the unit level: the parse (`number |
# Expression`) and the apply (a factor multiplies; a closed Expression folds to
# one; an open Expression is evaluated per element with the raw value bound to
# its single free variable). The end-to-end cross-binding contract on the ESIO
# provider path is `loader_unit_conversion_conformance_test.jl`.

using Test
using EarthSciAST

@testset "data-loader unit_conversion (esm-spec §8.5)" begin
    @testset "an absent conversion is nothing, and applying it is a no-op" begin
        @test parse_unit_conversion(nothing; variable_name = "x") === nothing
        v = [1.0, 2.0]
        @test apply_unit_conversion(v, nothing; variable_name = "x") === v
    end

    @testset "a numeric factor scales" begin
        c = parse_unit_conversion(0.3048; variable_name = "stkhgt")
        @test c == 0.3048
        @test apply_unit_conversion([707.0, 0.0], c; variable_name = "stkhgt") ==
              [707.0 * 0.3048, 0.0]
        # An integer factor is a factor.
        @test parse_unit_conversion(2; variable_name = "x") == 2.0
    end

    @testset "a factor of one leaves the bits alone" begin
        c = parse_unit_conversion(1; variable_name = "x")
        v = [0.1 + 0.2, 1e308]
        out = apply_unit_conversion(v, c; variable_name = "x")
        @test reinterpret(UInt64, out[1]) == reinterpret(UInt64, v[1])
        @test reinterpret(UInt64, out[2]) == reinterpret(UInt64, v[2])
    end

    # The affine case §4.8.1 says MUST be an expression: °F → K.
    @testset "an open expression binds the raw value" begin
        c = parse_unit_conversion(
            Dict("op" => "*",
                 "args" => [Dict("op" => "+", "args" => ["stktemp", 459.67]),
                            0.5555555555555556]);
            variable_name = "stktemp")
        out = apply_unit_conversion([32.0, 1116.0], c; variable_name = "stktemp")
        @test out == [(32.0 + 459.67) * 0.5555555555555556,
                      (1116.0 + 459.67) * 0.5555555555555556]
    end

    @testset "a closed expression folds to a factor" begin
        c = parse_unit_conversion(Dict("op" => "*", "args" => [0.3048, 2.0]);
                                  variable_name = "x")
        @test apply_unit_conversion([1.0], c; variable_name = "x") == [0.3048 * 2.0]
    end

    @testset "what is not a conversion is refused" begin
        @test_throws UnitConversionError parse_unit_conversion(true; variable_name = "x")
        @test_throws UnitConversionError parse_unit_conversion("0.3048"; variable_name = "x")
        two = parse_unit_conversion(Dict("op" => "*", "args" => ["a", "b"]);
                                    variable_name = "x")
        @test_throws UnitConversionError apply_unit_conversion([1.0], two;
                                                               variable_name = "x")
    end
end
