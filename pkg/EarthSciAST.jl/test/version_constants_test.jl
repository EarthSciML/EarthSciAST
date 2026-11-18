# The two public version constants, and the fact that they are two.
#
# `SCHEMA_VERSION` is the `.esm` FORMAT version; `LIBRARY_VERSION` is this
# package's own version. Every binding exposes exactly `SCHEMA_VERSION` and
# `LIBRARY_VERSION`, both strings, so neither is mistaken for the other.

using Test
using EarthSciAST
using JSON3

@testset "Version constants" begin

    @testset "SCHEMA_VERSION tracks the bundled schema \$id" begin
        # The schema's `$id` is
        # https://earthsciml.org/schemas/esm/<version>/esm.schema.json — the
        # single source of truth TypeScript, Go and Rust all pin to. Julia's
        # constant is a literal (it is needed before src/validation/ is included),
        # so this test is what keeps it from hand-drifting.
        schema_path = joinpath(pkgdir(EarthSciAST), "data", "esm-schema.json")
        @test isfile(schema_path)
        schema = JSON3.read(read(schema_path, String))
        id = String(schema["\$id"])
        @test occursin("/esm/$(EarthSciAST.SCHEMA_VERSION)/", id)
    end

    @testset "SCHEMA_VERSION is a semver string" begin
        @test EarthSciAST.SCHEMA_VERSION isa String
        @test occursin(r"^\d+\.\d+\.\d+$", EarthSciAST.SCHEMA_VERSION)
    end

    @testset "LIBRARY_VERSION is this package's own version" begin
        @test EarthSciAST.LIBRARY_VERSION isa String
        @test occursin(r"^\d+\.\d+\.\d+", EarthSciAST.LIBRARY_VERSION)
        # Derived from Project.toml, not a second hand-maintained copy.
        @test EarthSciAST.LIBRARY_VERSION == string(pkgversion(EarthSciAST))
    end

    @testset "the two are separate concepts, not an alias pair" begin
        # Nothing requires them to differ — but nothing may make one the other's
        # alias, which is exactly what `SCHEMA_VERSION as VERSION` did in
        # TypeScript: it made the package version unobservable.
        @test EarthSciAST.SCHEMA_VERSION isa String
        @test EarthSciAST.LIBRARY_VERSION isa String
        @test !isdefined(EarthSciAST, :ESM_FORMAT_VERSION)
    end
end
