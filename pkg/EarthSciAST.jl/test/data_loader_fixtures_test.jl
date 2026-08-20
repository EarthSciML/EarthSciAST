using Test
using EarthSciAST
using JSON3

# Verifies that the STAC-like DataSource schema can express every
# EarthSciData.jl data source. For each fixture we:
#   1. Parse it.
#   2. Schema-validate against data/esm-schema.json.
#   3. Round-trip parse -> serialize -> parse and compare key fields.
#
# These fixtures are the concrete acceptance test for the gt-q4k schema
# redesign — if any EarthSciData loader cannot be expressed, this test
# suite fails and the gap should be escalated, not worked around.
@testset "DataSource EarthSciData coverage fixtures" begin
    fixtures_dir = joinpath(@__DIR__, "fixtures", "data_sources")
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
            @test original.data_sources !== nothing
            @test !isempty(original.data_sources)

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
                @test length(reloaded.data_sources) == length(original.data_sources)
                for (name, orig_source) in original.data_sources
                    @test haskey(reloaded.data_sources, name)
                    reloaded_source = reloaded.data_sources[name]
                    @test reloaded_source.kind == orig_source.kind
                    @test reloaded_source.source.url_template ==
                          orig_source.source.url_template
                    @test reloaded_source.source.mirrors == orig_source.source.mirrors
                end

                # esm 1.0.0 (§8): a data source is a REGISTRY ENTRY, not a
                # component — it exposes no `variables` of its own. The
                # file-variable binding and its units now live on the CONSUMING
                # model's parameter (`update.kind == "data"`, `update.source`,
                # `update.from.file_variable`), so that is what the round trip
                # has to preserve. This assertion replaces the 0.x
                # `loader.variables[v].file_variable/.units` walk.
                @test length(reloaded.models) == length(original.models)
                bound_any = false
                for (mname, orig_model) in original.models
                    @test haskey(reloaded.models, mname)
                    reloaded_model = reloaded.models[mname]
                    @test keys(reloaded_model.variables) == keys(orig_model.variables)
                    for (vname, orig_var) in orig_model.variables
                        orig_var.update === nothing && continue
                        reloaded_var = reloaded_model.variables[vname]
                        @test reloaded_var.type == orig_var.type
                        @test reloaded_var.type == EarthSciAST.ParameterVariable
                        @test reloaded_var.units == orig_var.units
                        @test reloaded_var.shape == orig_var.shape
                        @test reloaded_var.update !== nothing
                        @test length(reloaded_var.update) == length(orig_var.update)
                        for (ru, ou) in zip(reloaded_var.update, orig_var.update)
                            @test ru.kind == ou.kind
                            @test ru.source == ou.source
                            @test (ru.from === nothing) == (ou.from === nothing)
                            if ou.from !== nothing
                                bound_any = true
                                @test ru.from.file_variable == ou.from.file_variable
                                @test haskey(original.data_sources, ou.source)
                            end
                        end
                    end
                end
                # Every fixture must actually consume its source, or the
                # coverage claim above is vacuous.
                @test bound_any
            finally
                isfile(tmp) && rm(tmp)
            end
        end
    end
end
