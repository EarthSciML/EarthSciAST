using Test
using EarthSciAST
using JSON3

# Verifies that the STAC-like DataLoader schema can express every
# EarthSciData.jl data source. For each fixture we:
#   1. Parse it.
#   2. Schema-validate against data/esm-schema.json.
#   3. Round-trip parse -> serialize -> parse and compare key fields.
#
# These fixtures are the concrete acceptance test for the gt-q4k schema
# redesign — if any EarthSciData loader cannot be expressed, this test
# suite fails and the gap should be escalated, not worked around.
@testset "DataLoader EarthSciData coverage fixtures" begin
    fixtures_dir = joinpath(@__DIR__, "fixtures", "data_loaders")
    @test isdir(fixtures_dir)

    fixture_files = sort(filter(f -> endswith(f, ".esm"),
                                 readdir(fixtures_dir)))
    @test !isempty(fixture_files)

    expected_loaders = [
        "geosfp.esm",
        "era5.esm",
        "wrf.esm",
        "nei2016monthly.esm",
        "ceds.esm",
        "edgar_v81.esm",
        "usgs3dep.esm",
    ]
    for name in expected_loaders
        @test name in fixture_files
    end

    for fname in fixture_files
        fpath = joinpath(fixtures_dir, fname)
        @testset "fixture $fname" begin
            # 1. Parse.
            original = EarthSciAST.load(fpath)
            @test original isa EarthSciAST.EsmFile
            @test original.data_loaders !== nothing
            @test !isempty(original.data_loaders)

            # 2. Schema-validate.
            result = EarthSciAST.validate(original)
            if !result.is_valid
                @info "Validation errors for $fname" errors=result.schema_errors structural=result.structural_errors
            end
            @test isempty(result.schema_errors)

            # 3. Round-trip.
            tmp = tempname() * ".esm"
            try
                EarthSciAST.save(original, tmp)
                reloaded = EarthSciAST.load(tmp)
                @test length(reloaded.data_loaders) == length(original.data_loaders)
                for (name, orig_loader) in original.data_loaders
                    @test haskey(reloaded.data_loaders, name)
                    reloaded_loader = reloaded.data_loaders[name]
                    @test reloaded_loader.kind == orig_loader.kind
                    @test reloaded_loader.source.url_template ==
                          orig_loader.source.url_template
                    @test keys(reloaded_loader.variables) ==
                          keys(orig_loader.variables)
                    for (var_name, orig_var) in orig_loader.variables
                        reloaded_var = reloaded_loader.variables[var_name]
                        @test reloaded_var.file_variable == orig_var.file_variable
                        @test reloaded_var.units == orig_var.units
                    end
                end
            finally
                isfile(tmp) && rm(tmp)
            end
        end
    end
end
