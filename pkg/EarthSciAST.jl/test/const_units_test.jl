# Declared units on a `const` node (esm-spec §4.8.5): a `const` that declares its
# units has that unit, a `const` without units stays undeterminable, an
# unresolvable declared unit is listed for the structural layer, and the field is
# gated at esm 1.2.0.

using Test
using EarthSciAST
using Unitful

include("testutils.jl")

@testset "declared units on a const node (esm-spec §4.8.5)" begin
    konst(units) = EarthSciAST.OpExpr("const", EarthSciAST.ASTExpr[]; value = 0.44704, units = units)
    units = Dict("speed_mph" => "mi/h")

    @testset "a const with declared units has that unit" begin
        got = EarthSciAST.get_expression_dimensions(_op("*", _v("speed_mph"), konst("m*h/(mi*s)")), units)
        @test got !== nothing
        @test EarthSciAST._exact_scale(got) == EarthSciAST._exact_scale(EarthSciAST.parse_units("m/s"))
    end

    @testset "a const without units stays undeterminable" begin
        @test EarthSciAST.get_expression_dimensions(_op("*", _v("speed_mph"), konst(nothing)), units) === nothing
    end

    @testset "unresolvable const units are listed" begin
        @test EarthSciAST.unresolvable_const_units(_op("*", _v("speed_mph"), konst("mph"))) == ["mph"]
        @test isempty(EarthSciAST.unresolvable_const_units(_op("*", _v("speed_mph"), konst("m*h/(mi*s)"))))
    end

    @testset "const units are gated at esm 1.2.0" begin
        doc(esm) = Dict{String,Any}("esm" => esm, "models" => Dict{String,Any}("M" => Dict{String,Any}(
            "equations" => Any[Dict{String,Any}("lhs" => "x", "rhs" => Dict{String,Any}(
                "op" => "const", "args" => Any[], "value" => 1.0, "units" => "m"))])))
        err = try
            EarthSciAST.reject_const_units_pre_v12(doc("1.1.0"))
            nothing
        catch e
            e
        end
        @test err !== nothing
        @test occursin("/models/M/equations/0/rhs", sprint(showerror, err))
        @test EarthSciAST.reject_const_units_pre_v12(doc("1.2.0")) === nothing
    end
end
