"""
discretizations_roundtrip_test.jl — Round-trip coverage for the §7
`discretizations` top-level schema, including the §7.4
`CrossMetricStencilRule` composite variant (esm-vwo).

These tests load the canonical discretization fixtures, re-serialize,
reload, and assert the discretizations tree survives intact at the JSON
level. The Julia binding holds discretization entries opaquely as
`Dict{String,Any}` because stencil coefficients and applies_to patterns
carry pattern-variable strings (\$u, \$x, \$target) that don't map onto
the Expression coercion pipeline; the round-trip contract is structural
equivalence of the top-level `discretizations` subtree.
"""

using Test
using EarthSciSerialization
using JSON3

const _DISC_FIXTURES_DIR = joinpath(@__DIR__, "..", "..", "..", "tests", "discretizations")

_plainify(x::JSON3.Array)  = Any[_plainify(v) for v in x]
_plainify(x::JSON3.Object) = Dict{String,Any}(string(k) => _plainify(v) for (k, v) in pairs(x))
_plainify(x::AbstractDict) = Dict{String,Any}(string(k) => _plainify(v) for (k, v) in pairs(x))
_plainify(x::AbstractVector) = Any[_plainify(v) for v in x]
_plainify(x) = x

function _read_plain(path::String)
    raw = JSON3.read(read(path, String))
    return _plainify(raw)
end

@testset "RFC §7 discretizations round-trip" begin
    @test isdir(_DISC_FIXTURES_DIR)

    fixtures = ["centered_2nd_uniform.esm",
                "upwind_1st_advection.esm",
                "periodic_bc.esm",
                "mpas_cell_div.esm",
                "cross_metric_cartesian.esm",
                "grid_dispatch_ppm.esm",
                "multi_output_ppm_reconstruction.esm"]

    for fname in fixtures
        @testset "Round-trip $(fname)" begin
            path = joinpath(_DISC_FIXTURES_DIR, fname)
            @test isfile(path)

            original_raw = _read_plain(path)

            esm = EarthSciSerialization.load(path)
            @test esm isa EsmFile
            @test esm.discretizations !== nothing
            @test length(esm.discretizations) >= 1

            tmp = tempname() * ".esm"
            try
                EarthSciSerialization.save(esm, tmp)
                reloaded = EarthSciSerialization.load(tmp)

                reloaded_raw = _read_plain(tmp)

                @test haskey(reloaded_raw, "discretizations")
                @test reloaded_raw["discretizations"] == original_raw["discretizations"]

                # Key sets preserved at the Julia struct level too.
                @test Set(keys(esm.discretizations)) == Set(keys(reloaded.discretizations))
            finally
                rm(tmp, force=true)
            end
        end
    end
end

@testset "RFC §7.4 cross-metric composite structure" begin
    path = joinpath(_DISC_FIXTURES_DIR, "cross_metric_cartesian.esm")
    esm = EarthSciSerialization.load(path)

    @test haskey(esm.discretizations, "laplacian_full_covariant_toy")
    composite = esm.discretizations["laplacian_full_covariant_toy"]

    @test composite["kind"] == "cross_metric"
    @test composite["axes"] == ["xi", "eta"]
    @test composite["terms"] isa AbstractVector
    @test length(composite["terms"]) == 2
    # Composite entries do NOT carry a stencil key.
    @test !haskey(composite, "stencil")

    # Per-axis stencils should still be present and carry a stencil key.
    @test haskey(esm.discretizations["d2_dxi2_uniform"], "stencil")
    @test haskey(esm.discretizations["d2_deta2_uniform"], "stencil")
end

@testset "RFC §7.8 grid_dispatch structure" begin
    path = joinpath(_DISC_FIXTURES_DIR, "grid_dispatch_ppm.esm")
    esm = EarthSciSerialization.load(path)

    @test haskey(esm.discretizations, "ppm_advection")
    scheme = esm.discretizations["ppm_advection"]

    # Parent-level grid_family / stencil are absent; the body lives in
    # grid_dispatch variants (RFC §7.8 mutual-exclusion contract).
    @test !haskey(scheme, "grid_family")
    @test !haskey(scheme, "stencil")
    @test scheme["grid_dispatch"] isa AbstractVector
    @test length(scheme["grid_dispatch"]) == 1

    families = [v["grid_family"] for v in scheme["grid_dispatch"]]
    @test families == ["cartesian"]

    # Each variant carries its own stencil body.
    @test length(scheme["grid_dispatch"][1]["stencil"]) == 4
end

@testset "RFC §7.9 multi_output_stencil structure" begin
    path = joinpath(_DISC_FIXTURES_DIR, "multi_output_ppm_reconstruction.esm")
    esm = EarthSciSerialization.load(path)

    # Provider: ppm_reconstruction
    @test haskey(esm.discretizations, "ppm_reconstruction")
    provider = esm.discretizations["ppm_reconstruction"]
    @test provider["kind"] == "multi_output_stencil"
    @test provider["outputs"] == ["q_left_edge", "q_right_edge"]
    # stencil is an object (Dict), not a flat array
    @test provider["stencil"] isa AbstractDict
    @test haskey(provider["stencil"], "q_left_edge")
    @test haskey(provider["stencil"], "q_right_edge")
    @test length(provider["stencil"]["q_left_edge"]) == 2
    @test length(provider["stencil"]["q_right_edge"]) == 2
    @test provider["emits_location"] == "face"
    # primary is explicitly null
    @test isnothing(get(provider, "primary", :missing)) || provider["primary"] === nothing

    # Consumer: ppm_flux
    @test haskey(esm.discretizations, "ppm_flux")
    consumer = esm.discretizations["ppm_flux"]
    @test consumer["kind"] == "stencil"
    @test haskey(consumer, "requires")
    @test consumer["requires"]["q_left_edge"] == "ppm_reconstruction#q_left_edge"
    @test consumer["requires"]["q_right_edge"] == "ppm_reconstruction#q_right_edge"
end

@testset "§4.7.1 discretizations {ref} resolution" begin
    ref_path    = joinpath(_DISC_FIXTURES_DIR, "disc_ref_resolve.esm")
    inline_path = joinpath(_DISC_FIXTURES_DIR, "disc_ref_resolve_inline.esm")

    @testset "load resolves {ref} to inline scheme" begin
        esm = EarthSciSerialization.load(ref_path)
        @test esm isa EsmFile
        @test esm.discretizations !== nothing
        @test haskey(esm.discretizations, "centered_grad")

        # After resolution the entry must be a scheme dict, not a {ref} dict.
        scheme = esm.discretizations["centered_grad"]
        @test scheme isa Dict
        @test !haskey(scheme, "ref")
        @test haskey(scheme, "applies_to")
        @test haskey(scheme, "stencil")
        @test scheme["grid_family"] == "cartesian"
        @test length(scheme["stencil"]) == 2
    end

    @testset "{ref} and inline produce identical scheme dicts" begin
        ref_esm    = EarthSciSerialization.load(ref_path)
        inline_esm = EarthSciSerialization.load(inline_path)
        @test ref_esm.discretizations["centered_grad"] ==
              inline_esm.discretizations["centered_grad"]
    end

    @testset "dangling {ref} raises SubsystemRefError" begin
        mktempdir() do dir
            bad_esm = """
            {
              "esm": "0.2.0",
              "metadata": { "name": "bad_ref" },
              "models": {
                "E": {
                  "variables": { "x": { "type": "state", "default": 0.0, "units": "1" } },
                  "equations": [{ "lhs": { "op": "D", "args": ["x"], "wrt": "t" }, "rhs": 0.0 }]
                }
              },
              "discretizations": { "s": { "ref": "does_not_exist.esm" } }
            }
            """
            p = joinpath(dir, "bad.esm")
            write(p, bad_esm)
            @test_throws EarthSciSerialization.SubsystemRefError EarthSciSerialization.load(p)
        end
    end

    @testset "URL {ref} triggers remote-load error path (mocked)" begin
        mktempdir() do dir
            url_esm = """
            {
              "esm": "0.2.0",
              "metadata": { "name": "url_ref" },
              "models": {
                "E": {
                  "variables": { "x": { "type": "state", "default": 0.0, "units": "1" } },
                  "equations": [{ "lhs": { "op": "D", "args": ["x"], "wrt": "t" }, "rhs": 0.0 }]
                }
              },
              "discretizations": {
                "s": { "ref": "https://unreachable.invalid/rules/scheme.json" }
              }
            }
            """
            p = joinpath(dir, "url_ref.esm")
            write(p, url_esm)
            # URL loading fails with SubsystemRefError (wrapped download error).
            @test_throws EarthSciSerialization.SubsystemRefError EarthSciSerialization.load(p)
        end
    end

    @testset "empty disc ref file raises SubsystemRefError" begin
        mktempdir() do dir
            # Rule file with no discretizations block.
            rule_file = """
            {
              "esm": "0.2.0",
              "metadata": { "name": "empty_rule" },
              "models": {
                "E": {
                  "variables": { "x": { "type": "state", "default": 0.0, "units": "1" } },
                  "equations": [{ "lhs": { "op": "D", "args": ["x"], "wrt": "t" }, "rhs": 0.0 }]
                }
              }
            }
            """
            rule_path = joinpath(dir, "empty_rule.esm")
            write(rule_path, rule_file)

            host_esm = """
            {
              "esm": "0.2.0",
              "metadata": { "name": "host" },
              "models": {
                "E": {
                  "variables": { "x": { "type": "state", "default": 0.0, "units": "1" } },
                  "equations": [{ "lhs": { "op": "D", "args": ["x"], "wrt": "t" }, "rhs": 0.0 }]
                }
              },
              "discretizations": { "s": { "ref": "empty_rule.esm" } }
            }
            """
            host_path = joinpath(dir, "host.esm")
            write(host_path, host_esm)
            err = @test_throws EarthSciSerialization.SubsystemRefError EarthSciSerialization.load(host_path)
            @test occursin("no discretizations", err.value.message)
        end
    end
end
