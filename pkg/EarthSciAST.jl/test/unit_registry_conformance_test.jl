# Manifest-driven adapter for `tests/conformance/unit_registry`.
#
# The Julia side of that directory's contract: esm-spec §4.8, asserted at the
# level a document actually meets it — a unit STRING at a time. Every other
# units fixture in the corpus is a `.esm` document and can only pin the verdict
# a whole FILE gets; this one pins whether each string resolves, the DIMENSION
# it resolves to, and its SCALE.
#
# Scale is not decoration: `short_ton` and `tonne` have the same dimension and
# differ only in scale, so a dimension-only check would pass a binding that
# defined the short ton as 1000 kg and mis-scaled every US emissions inventory
# by 10%.
#
# The Python mirror is
# `pkg/earthsci-ast-py/tests/test_unit_registry_conformance.py`, the Rust one
# `pkg/earthsci-ast-rs/tests/unit_registry_conformance.rs` — same golden.

using Test
using EarthSciAST
import JSON
using Unitful

const _UR_TESTS = normpath(joinpath(@__DIR__, "..", "..", "..", "tests"))
_ur_read(rel) = JSON.parsefile(joinpath(_UR_TESTS, rel))

@testset "unit registry conformance (esm-spec §4.8)" begin
    manifest = _ur_read("conformance/unit_registry/manifest.json")
    golden = _ur_read(String(manifest["golden"]))

    @testset "accept" begin
        @test !isempty(golden["accept"])
        for entry in golden["accept"]
            s, canon = String(entry["units"]), String(entry["canonical"])
            u = EarthSciAST.parse_units(s)
            c = EarthSciAST.parse_units(canon)
            @test u !== nothing
            @test c !== nothing
            u === nothing && continue
            c === nothing && continue
            @test Unitful.dimension(u) == Unitful.dimension(c)
            scale = entry["scale_to_canonical"]
            # `null` is exactly the affine units, whose offset §4.8.1
            # deliberately does not model — their pure multiplicative factor is
            # not a physically meaningful conversion.
            scale === nothing && continue
            got = Float64(Unitful.ustrip(Unitful.uconvert(c, 1.0 * u)))
            @test isapprox(got, Float64(scale); rtol = 1e-12)
        end
    end

    @testset "reject" begin
        @test !isempty(golden["reject"])
        for entry in golden["reject"]
            s = String(entry["units"])
            @test EarthSciAST.parse_units(s) === nothing
        end
    end

    # The one rejection whose REASON an author cannot guess from the string: it
    # LOOKS like a rational exponent and the grammar reads it as a division by a
    # number. The message is pinned here, and nowhere else, for that reason.
    @testset "reject: scaling factor, and the diagnostic says so" begin
        @test !isempty(golden["reject_scaling_factor"])
        for entry in golden["reject_scaling_factor"]
            s = String(entry["units"])
            @test EarthSciAST.parse_units(s) === nothing
            reason = EarthSciAST.parse_units_reason(s)
            @test reason !== nothing
            @test reason !== nothing && occursin("scaling factor", reason)
        end
    end
end
