using Test
using EarthSciSerialization
const ESM_GR = EarthSciSerialization

# gdd_to_rules — convert an ESD discretization catalog ({discretizations: {name:
# {applies_to, replacement}}}) into rule-engine {name, pattern, replacement} rules.
@testset "gdd_to_rules" begin
    catalog = Dict{String,Any}("discretizations" => Dict{String,Any}(
        "grad_x" => Dict{String,Any}(
            "applies_to" => Dict{String,Any}("op" => "grad", "args" => Any["\$u"], "dim" => "x"),
            "grid_family" => "cartesian",
            "replacement" => Dict{String,Any}("op" => "/", "args" => Any[
                Dict{String,Any}("op" => "-", "args" => Any[
                    Dict{String,Any}("op" => "index", "args" => Any["\$u", Dict{String,Any}("op" => "+", "args" => Any["i", 1]), "j"]),
                    Dict{String,Any}("op" => "index", "args" => Any["\$u", Dict{String,Any}("op" => "-", "args" => Any["i", 1]), "j"])]),
                Dict{String,Any}("op" => "*", "args" => Any[2, "dx"])])),
        # a `use:`-style scheme entry (no applies_to/replacement) must be skipped.
        "fv_scheme" => Dict{String,Any}("use" => "some_scheme", "grid_family" => "cartesian")))

    @testset "applies_to → pattern; use-schemes skipped" begin
        rules = ESM_GR.gdd_to_rules(catalog)
        @test length(rules) == 1
        r = rules[1]
        @test r["name"] == "grad_x"
        @test r["pattern"] == catalog["discretizations"]["grad_x"]["applies_to"]
        @test r["pattern"]["op"] == "grad"
        @test haskey(r, "replacement")
    end

    @testset "spacing rename dx → namespaced param" begin
        rules = ESM_GR.gdd_to_rules(catalog; spacing = "LevelSetFireSpread.dx")
        # the literal `dx` token in the replacement denominator is renamed; nothing else is.
        denom = rules[1]["replacement"]["args"][2]   # {op:*, args:[2, <spacing>]}
        @test denom["args"][2] == "LevelSetFireSpread.dx"
        # the template var `$u` and loop index `i`/`j` are untouched.
        @test rules[1]["replacement"]["args"][1]["args"][1]["args"][1] == "\$u"
        # default spacing leaves `dx` as-is.
        @test ESM_GR.gdd_to_rules(catalog)[1]["replacement"]["args"][2]["args"][2] == "dx"
    end

    @testset "names selects a subset, in order" begin
        cat2 = Dict{String,Any}("discretizations" => Dict{String,Any}(
            "a" => Dict{String,Any}("applies_to" => Dict{String,Any}("op" => "grad", "args" => Any["\$u"], "dim" => "x"),
                                    "replacement" => Dict{String,Any}("op" => "index", "args" => Any["\$u", "i"])),
            "b" => Dict{String,Any}("applies_to" => Dict{String,Any}("op" => "grad", "args" => Any["\$u"], "dim" => "y"),
                                    "replacement" => Dict{String,Any}("op" => "index", "args" => Any["\$u", "j"]))))
        rules = ESM_GR.gdd_to_rules(cat2; names = ["b", "a"])
        @test [r["name"] for r in rules] == ["b", "a"]
        @test_throws ArgumentError ESM_GR.gdd_to_rules(cat2; names = ["nonexistent"])
    end

    @testset "errors" begin
        @test_throws ArgumentError ESM_GR.gdd_to_rules(Dict{String,Any}("foo" => 1))   # no discretizations
        @test_throws ArgumentError ESM_GR.gdd_to_rules("/no/such/catalog/file.json")
    end
end
