"""
grids_test.jl — Round-trip coverage for RFC §6 top-level `grids` (gt-5kq3).

These tests load the canonical grids fixtures (cartesian_uniform,
unstructured_mpas), re-serialize them, reload, and assert the grids tree
survives intact. Comparison is done against the raw JSON tree (via
JSON3 -> plain Dict) so key-ordering does not matter.
"""

using Test
using EarthSciSerialization
using JSON3

const _GRIDS_FIXTURES_DIR = joinpath(@__DIR__, "..", "..", "..", "tests", "grids")

# Convert a JSON3 tree (or anything mixing Dicts/Vectors) into plain Julia
# containers so `==` comparison works regardless of key ordering.
_plainify(x::JSON3.Array)  = Any[_plainify(v) for v in x]
_plainify(x::JSON3.Object) = Dict{String,Any}(string(k) => _plainify(v) for (k, v) in pairs(x))
_plainify(x::AbstractDict) = Dict{String,Any}(string(k) => _plainify(v) for (k, v) in pairs(x))
_plainify(x::AbstractVector) = Any[_plainify(v) for v in x]
_plainify(x) = x

# Read a fixture as a plain Dict for shape comparison.
function _read_plain(path::String)
    raw = JSON3.read(read(path, String))
    return _plainify(raw)
end

@testset "RFC §6 grids round-trip" begin
    @test isdir(_GRIDS_FIXTURES_DIR)

    fixtures = ["cartesian_uniform.esm",
                "unstructured_mpas.esm"]

    for fname in fixtures
        @testset "Round-trip $(fname)" begin
            path = joinpath(_GRIDS_FIXTURES_DIR, fname)
            @test isfile(path)

            # 1. Load the original fixture
            original = EarthSciSerialization.load(path)
            @test original isa EsmFile
            @test original.grids !== nothing
            @test length(original.grids) >= 1

            # 2. Save and reload
            tmp = tempname() * ".esm"
            try
                EarthSciSerialization.save(original, tmp)
                reloaded = EarthSciSerialization.load(tmp)

                # Grid dict keys preserved
                @test Set(keys(original.grids)) == Set(keys(reloaded.grids))

                # Deep equality of each Grid's opaque dict
                for gname in keys(original.grids)
                    @test original.grids[gname].data == reloaded.grids[gname].data
                end

                # Compare against the on-disk fixture at the raw-JSON level
                # to guarantee nothing was dropped or re-shaped.
                fixture_plain = _read_plain(path)
                reloaded_plain = _read_plain(tmp)
                @test fixture_plain["grids"] == reloaded_plain["grids"]
            finally
                isfile(tmp) && rm(tmp)
            end
        end
    end
end

@testset "RFC §6 grids semantic validation" begin
    # Loader-backed metric array with an unknown loader -> E_UNKNOWN_LOADER
    @testset "E_UNKNOWN_LOADER" begin
        bad = Dict(
            "esm" => "0.2.0",
            "metadata" => Dict("name" => "bad"),
            "models" => Dict("M" => Dict(
                "variables" => Dict("T" => Dict("type" => "state", "default" => 0.0)),
                "equations" => Any[Dict("lhs" => "D(T)", "rhs" => "0")],
            )),
            "grids" => Dict("g" => Dict(
                "family" => "cartesian",
                "dimensions" => Any["x"],
                "extents" => Dict("x" => Dict("n" => 8, "spacing" => "uniform")),
                "metric_arrays" => Dict("dx" => Dict(
                    "rank" => 0,
                    "generator" => Dict("kind" => "loader",
                                        "loader" => "nope",
                                        "field" => "dx"),
                )),
            )),
        )
        buf = IOBuffer()
        JSON3.write(buf, bad)
        seekstart(buf)
        @test_throws EarthSciSerialization.ParseError EarthSciSerialization.load(buf)
    end

    # Unknown builtin name -> E_UNKNOWN_BUILTIN.
    # Schema allows kind="builtin" but the semantic check rejects names
    # outside the canonical closed set (RFC §6.4.1; the set is currently empty,
    # so every builtin name is rejected).
    @testset "E_UNKNOWN_BUILTIN" begin
        bad = Dict(
            "esm" => "0.2.0",
            "metadata" => Dict("name" => "bad"),
            "models" => Dict("M" => Dict(
                "variables" => Dict("T" => Dict("type" => "state", "default" => 0.0)),
                "equations" => Any[Dict("lhs" => "D(T)", "rhs" => "0")],
            )),
            "grids" => Dict("g" => Dict(
                "family" => "cartesian",
                "dimensions" => Any["x"],
                "extents" => Dict("x" => Dict("n" => 8, "spacing" => "uniform")),
                "metric_arrays" => Dict("dx" => Dict(
                    "rank" => 0,
                    "generator" => Dict("kind" => "builtin",
                                        "name" => "not_a_real_builtin"),
                )),
            )),
        )
        buf = IOBuffer()
        JSON3.write(buf, bad)
        seekstart(buf)
        @test_throws EarthSciSerialization.ParseError EarthSciSerialization.load(buf)
    end
end
