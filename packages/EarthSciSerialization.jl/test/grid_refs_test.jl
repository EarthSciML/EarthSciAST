# Tests for GDD loading and grid_refs resolution (ess-adm).
# Covers esm-spec.md §4.7.1, §6.6.2.

using Test
using EarthSciSerialization
import JSON3

const _GDD_FIXTURE_DIR = joinpath(@__DIR__, "fixtures", "gdd")

# ---------------------------------------------------------------------------
# Minimal 1-D advection PDE ESM used throughout these tests.
# Grid "gx" has a single periodic dimension "i" of size 4 by default;
# the GDD fixtures replace it with N=8 and N=16 respectively.
# ---------------------------------------------------------------------------
function _make_advection_esm(; n = 4)
    Dict{String,Any}(
        "esm"      => "0.5.0",
        "metadata" => Dict{String,Any}("name" => "advection_1d"),
        "grids" => Dict{String,Any}(
            "gx" => Dict{String,Any}(
                "family"     => "cartesian",
                "dimensions" => Any[
                    Dict{String,Any}(
                        "name"     => "i",
                        "size"     => n,
                        "periodic" => true,
                        "spacing"  => "uniform",
                    ),
                ],
            ),
        ),
        "discretizations" => Dict{String,Any}(
            "centered_grad" => Dict{String,Any}(
                "applies_to" => Dict{String,Any}(
                    "op"   => "grad",
                    "args" => Any["\$u"],
                    "dim"  => "\$x",
                ),
                "grid_family" => "cartesian",
                "combine"     => "+",
                "stencil"     => Any[
                    Dict{String,Any}(
                        "selector" => Dict{String,Any}(
                            "kind" => "cartesian", "axis" => "\$x", "offset" => -1),
                        "coeff" => Dict{String,Any}(
                            "op" => "/",
                            "args" => Any[-1, Dict{String,Any}(
                                "op" => "*", "args" => Any[2, "dx"])]),
                    ),
                    Dict{String,Any}(
                        "selector" => Dict{String,Any}(
                            "kind" => "cartesian", "axis" => "\$x", "offset" => 1),
                        "coeff" => Dict{String,Any}(
                            "op" => "/",
                            "args" => Any[1, Dict{String,Any}(
                                "op" => "*", "args" => Any[2, "dx"])]),
                    ),
                ],
            ),
        ),
        "models" => Dict{String,Any}(
            "adv" => Dict{String,Any}(
                "grid" => "gx",
                "variables" => Dict{String,Any}(
                    "u" => Dict{String,Any}(
                        "type" => "state", "default" => 0.0,
                        "shape" => Any["i"],
                    ),
                    "c" => Dict{String,Any}(
                        "type" => "parameter", "default" => 1.0,
                    ),
                ),
                "equations" => Any[
                    Dict{String,Any}(
                        "lhs" => Dict{String,Any}(
                            "op" => "D",
                            "args" => Any[Dict{String,Any}(
                                "op" => "index", "args" => Any["u", "i"])],
                            "wrt" => "t",
                        ),
                        "rhs" => Dict{String,Any}(
                            "op" => "*",
                            "args" => Any[
                                Dict{String,Any}("op" => "-", "args" => Any["c"]),
                                Dict{String,Any}(
                                    "op"  => "grad",
                                    "args" => Any[Dict{String,Any}(
                                        "op" => "index", "args" => Any["u", "i"])],
                                    "dim" => "i",
                                ),
                            ],
                        ),
                    ),
                ],
            ),
        ),
    )
end

@testset "Test.grid_refs — parse from coerce_test" begin
    # Verify that grid_refs in a schema test block are stored in Test.grid_refs.
    esm = Dict(
        "esm" => "0.5.0",
        "metadata" => Dict("name" => "t"),
        "models" => Dict(
            "M" => Dict(
                "variables" => Dict("x" => Dict("type" => "state", "default" => 0.0)),
                "equations" => [Dict("lhs" => Dict("op" => "D", "args" => ["x"], "wrt" => "t"), "rhs" => 0.0)],
                "tests" => [
                    Dict(
                        "id" => "sweep",
                        "time_span" => Dict("start" => 0.0, "end" => 1.0),
                        "grid_refs" => [
                            Dict("ref" => "a.gdd.json"),
                            Dict("ref" => "b.gdd.json"),
                        ],
                        "assertions" => [
                            Dict("variable" => "x", "time" => 1.0, "expected" => 0.0),
                        ],
                    ),
                ],
            ),
        ),
    )
    file = EarthSciSerialization.coerce_esm_file(JSON3.read(JSON3.write(esm)))
    model = file.models["M"]
    @test length(model.tests) == 1
    t = model.tests[1]
    @test t.grid_refs == ["a.gdd.json", "b.gdd.json"]
end

@testset "resolve_grid_refs — single GDD, replaces grid N=4→N=8" begin
    esm = _make_advection_esm(n = 4)
    gdd_path = joinpath(_GDD_FIXTURE_DIR, "cartesian_1d_n8_periodic.gdd.json")
    results = resolve_grid_refs(esm, [gdd_path], _GDD_FIXTURE_DIR;
                                strict_unrewritten = false,
                                lift_1d_arrayop = true)
    @test length(results) == 1
    disc = results[1]
    @test disc isa Dict{String,Any}
    # After GDD application, grid "gx" should have N=8 (not N=4)
    gx = disc["grids"]["gx"]
    dim_i = first(d for d in gx["dimensions"] if d["name"] == "i")
    @test dim_i["size"] == 8
end

@testset "resolve_grid_refs — two GDDs produce two systems (resolution sweep)" begin
    esm = _make_advection_esm(n = 4)
    gdd_n8  = joinpath(_GDD_FIXTURE_DIR, "cartesian_1d_n8_periodic.gdd.json")
    gdd_n16 = joinpath(_GDD_FIXTURE_DIR, "cartesian_1d_n16_periodic.gdd.json")
    results = resolve_grid_refs(esm, [gdd_n8, gdd_n16], _GDD_FIXTURE_DIR;
                                strict_unrewritten = false,
                                lift_1d_arrayop = true)
    @test length(results) == 2

    # First run: N=8
    dim_i_8 = first(d for d in results[1]["grids"]["gx"]["dimensions"]
                       if d["name"] == "i")
    @test dim_i_8["size"] == 8

    # Second run: N=16
    dim_i_16 = first(d for d in results[2]["grids"]["gx"]["dimensions"]
                        if d["name"] == "i")
    @test dim_i_16["size"] == 16
end

@testset "resolve_grid_refs — empty grid_refs returns empty vector" begin
    esm = _make_advection_esm()
    @test resolve_grid_refs(esm, String[], ".") == Dict{String,Any}[]
end

@testset "resolve_grid_refs — missing GDD file raises SubsystemRefError" begin
    esm = _make_advection_esm()
    @test_throws EarthSciSerialization.SubsystemRefError begin
        resolve_grid_refs(esm, ["nonexistent.gdd.json"], ".")
    end
end

@testset "resolve_grid_refs — wrong kind raises SubsystemRefError" begin
    # A regular ESM file (no kind field) should be rejected.
    esm = _make_advection_esm()
    bad_gdd = tempname() * ".gdd.json"
    try
        write(bad_gdd, """{"esm":"0.5.0","kind":"not_a_gdd","metadata":{"name":"bad"},
                          "models":{"M":{"variables":{"x":{"type":"state","default":0.0}},
                          "equations":[{"lhs":{"op":"D","args":["x"],"wrt":"t"},"rhs":0.0}]}}}""")
        @test_throws EarthSciSerialization.SubsystemRefError begin
            resolve_grid_refs(esm, [bad_gdd], dirname(bad_gdd))
        end
    finally
        isfile(bad_gdd) && rm(bad_gdd)
    end
end

@testset "schema — top-level schema admits GDD kind value" begin
    # A minimal GDD file with string-array dimensions (schema-valid format)
    # passes the updated anyOf that accepts kind="grid_discretization_descriptor".
    gdd_minimal = JSON3.read("""
    {
      "esm": "0.5.0",
      "kind": "grid_discretization_descriptor",
      "metadata": {"name": "minimal_gdd_test"},
      "grids": {
        "g": {
          "family": "cartesian",
          "dimensions": ["i"],
          "extents": {"i": {"n": 8, "spacing": "uniform"}}
        }
      }
    }
    """)
    errs = validate_schema(gdd_minimal)
    @test isempty(errs)
end
