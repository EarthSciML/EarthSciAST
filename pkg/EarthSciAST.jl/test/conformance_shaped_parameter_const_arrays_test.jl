# Conformance harness adapter — shaped_parameter_const_arrays category.
#
# A caller's `const_arrays` entry for a SHAPED parameter is the same binding as
# an inline-array `parameter_overrides` entry for it, so its key resolves by the
# esm-spec §6.6.2 override rules (CONFORMANCE_SPEC §5.32.5): the model-local
# spelling `k` designates the flattened `Column.k`. Julia matched the flattened
# name only, so the local spelling left the parameter backed by nothing — a
# document with no `default` was refused with `E_TREEWALK_UNSUPPORTED_SHAPE`,
# and one with a default silently used it instead of the caller's array.
#
# See tests/conformance/shaped_parameter_const_arrays/.

using Test
using JSON3
using EarthSciAST

include("testutils.jl")  # TESTUTILS_REPO_ROOT

const _SPCA_CAT_DIR  = joinpath(TESTUTILS_REPO_ROOT, "tests", "conformance",
                                "shaped_parameter_const_arrays")
const _SPCA_MANIFEST = joinpath(_SPCA_CAT_DIR, "manifest.json")

@testset "Conformance: shaped_parameter_const_arrays (manifest-driven)" begin
    manifest = JSON3.read(read(_SPCA_MANIFEST, String))
    @test manifest.category == "shaped_parameter_const_arrays"
    @test Set(String.(manifest.bindings_required)) == Set(["julia", "python", "rust"])
    @test !isempty(manifest.cases)
    for case in manifest.cases, compiler in manifest.compilers
        @testset "$(case.id) [$(compiler)]" begin
            arrays = Dict{String,Any}(String(k) => Float64.(collect(v))
                                      for (k, v) in pairs(case.const_arrays))
            prob = esm_problem(joinpath(_SPCA_CAT_DIR, String(case.fixture)), (0.0, 1.0);
                               compiler = Symbol(compiler), const_arrays = arrays)
            got = observed_field(prob, String(case.observed))
            @test vec(collect(Float64, got)) == Float64.(collect(case.expected))
        end
    end
end

# The same key rules as `parameter_overrides`, on the cases the shared manifest
# does not carry: an ambiguous local name and two keys for one parameter are
# rejected, and a key that designates no shaped parameter is left alone.
@testset "const_arrays keys: the §6.6.2 rejections" begin
    two = EarthSciAST.Model(Dict(
        "A.k" => EarthSciAST.ModelVariable(EarthSciAST.ParameterVariable; shape = ["x"]),
        "B.k" => EarthSciAST.ModelVariable(EarthSciAST.ParameterVariable; shape = ["x"])),
        EarthSciAST.Equation[])
    @test_throws ArgumentError EarthSciAST._normalize_const_array_keys(
        two, Dict{String,Any}("k" => [1.0]))
    one = EarthSciAST.Model(Dict(
        "P.sub.k" => EarthSciAST.ModelVariable(EarthSciAST.ParameterVariable; shape = ["x"])),
        EarthSciAST.Equation[])
    @test_throws ArgumentError EarthSciAST._normalize_const_array_keys(
        one, Dict{String,Any}("k" => [1.0], "sub.k" => [2.0]))
    # An exact key wins over a local one, and data that is no parameter's value
    # stays under its own key.
    got = EarthSciAST._normalize_const_array_keys(
        one, Dict{String,Any}("k" => [1.0], "P.sub.k" => [2.0], "coord_x" => [3.0]))
    @test got["P.sub.k"] == [2.0]
    @test got["coord_x"] == [3.0]
    got2 = EarthSciAST._normalize_const_array_keys(one, Dict{String,Any}("sub.k" => [4.0]))
    @test got2["P.sub.k"] == [4.0] && got2["sub.k"] == [4.0]
end
