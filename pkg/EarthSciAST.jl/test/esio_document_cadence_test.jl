# providers_from_document over a time-varying esm source (EarthSciIO
# spec/esm-sources.md): esm URL templates, a bound custom substitution, a
# mirror, and a calendar-month cadence. Mirrors the Python
# tests/test_esio_document_cadence.py.

using Test
using Dates
using EarthSciAST
using EarthSciIO
import EarthSciIO: NCDatasets

const _ESIO_HAS_ESM = isdefined(EarthSciIO, :provider_from_esm)

function _cadence_doc(dir)
    mirror = joinpath(dir, "mirror")
    mkpath(mirror)
    for m in 1:3
        NCDatasets.NCDataset(joinpath(mirror, "nei_agr_0$m.ncf"), "c") do ds
            NCDatasets.defDim(ds, "ROW", 2)
            NCDatasets.defDim(ds, "TSTEP", Inf)
            v = NCDatasets.defVar(ds, "NOX", Float32, ("ROW", "TSTEP"))
            v[:, 1] = Float32[m * 10, m * 10 + 1]
        end
    end
    return Dict{String, Any}(
        "esm" => "1.0.0",
        "data_sources" => Dict{String, Any}(
            "NEI" => Dict{String, Any}(
                "kind" => "grid",
                "source" => Dict{String, Any}(
                    "url_template" => "file://$dir/primary/nei_{sector}_{date:%m}.ncf",
                    "mirrors" => ["file://$mirror/nei_{sector}_{date:%m}.ncf"],
                ),
                "temporal" => Dict{String, Any}(
                    "start" => "2016-01-01T00:00:00Z", "end" => "2016-12-31T23:59:59Z",
                    "file_period" => "P1M", "frequency" => "P1M",
                    "records_per_file" => 1, "time_variable" => "TSTEP",
                ),
                "metadata" => Dict{String, Any}("esio_format" => "netcdf"),
            )
        ),
        "models" => Dict{String, Any}(
            "Emis" => Dict{String, Any}(
                "variables" => Dict{String, Any}(
                    "nox" => Dict{String, Any}(
                        "type" => "parameter", "units" => "mol/s", "shape" => ["row"],
                        "update" => Dict{String, Any}(
                            "kind" => "data", "source" => "NEI",
                            "from" => Dict{String, Any}(
                                "file_variable" => "NOX", "unit_conversion" => 2.0
                            ),
                        ),
                    )
                )
            )
        ),
    )
end

@testset "providers_from_document — a monthly source with a bound sector" begin
    if !_ESIO_HAS_ESM
        @info "skipped: this EarthSciIO predates provider_from_esm"
    else
        mktempdir() do dir
            doc = _cadence_doc(dir)
            u(y, m, d = 1, h = 0) = datetime2unix(DateTime(y, m, d, h))
            window = (u(2016, 1), u(2016, 4))
            provs = providers_from_document(
                doc; cache_root = joinpath(dir, "cache"),
                substitutions = Dict("NEI" => Dict("sector" => "agr")), window = window
            )
            p = provs["Emis.nox"]
            @test !EarthSciAST.provider_is_const(p)
            # calendar months, not a mean month of 30.436875 days
            @test EarthSciAST.provider_refresh_times(p) == [u(2016, 1), u(2016, 2), u(2016, 3)]
            # the primary location is missing: each month comes from its mirror,
            # converted by the declared unit_conversion
            @test vec(EarthSciAST.provider_sample(p, u(2016, 2, 29, 23))) == [40.0, 42.0]
            @test vec(EarthSciAST.provider_sample(p, u(2016, 3))) == [60.0, 62.0]

            @test_throws EarthSciIO.EsmTemplateError providers_from_document(
                doc; cache_root = joinpath(dir, "cache2"), window = window
            )

            two = providers_from_document(
                doc; cache_root = joinpath(dir, "cache3"),
                substitutions = Dict("NEI" => Dict("sector" => "agr")), window = window,
                records_per_sample = Dict("Emis.nox" => 2)
            )
            got = EarthSciAST.provider_sample(two["Emis.nox"], u(2016, 2, 15))
            # the record axis first, in the file's dimension order
            @test got == [40.0 42.0; 60.0 62.0]
        end
    end
end
