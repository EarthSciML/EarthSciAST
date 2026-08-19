# Manifest-driven adapter for `tests/conformance/loader_unit_conversion`.
#
# The Julia side of the cross-binding contract in that directory's README:
# esm-spec §8.5 says the runtime applies a loader variable's `unit_conversion`
# when producing values in the declared `units`, and the ESIO provider path is
# where a loader-fed model actually gets its numbers.
#
# Driven entirely by `manifest.json` + each fixture's golden: adding a fixture
# needs no change here. The Python mirror is
# `pkg/earthsci-ast-py/tests/test_loader_unit_conversion_conformance.py`, the
# Rust one `pkg/earthsci-ast-rs/tests/loader_unit_conversion_conformance.rs` —
# same manifest, same golden, same bits.

using Test
using EarthSciAST
using EarthSciIO
import JSON

const _LUC = EarthSciAST
const _LUC_TESTS = normpath(joinpath(@__DIR__, "..", "..", "..", "tests"))

# f64 bit patterns — the comparison the manifest asks for, so 0.0/-0.0 and any
# last-ulp disagreement are visible rather than rounded away.
_luc_bits(v) = UInt64[reinterpret(UInt64, Float64(x)) for x in v]

_luc_read(rel) = JSON.parsefile(joinpath(_LUC_TESTS, rel))

@testset "loader unit_conversion conformance (esm-spec §8.5)" begin
    manifest = _luc_read("conformance/loader_unit_conversion/manifest.json")
    fixtures = manifest["fixtures"]
    @test !isempty(fixtures)

    for fixture in fixtures
        id = String(fixture["id"])
        @testset "$id" begin
            mktempdir() do dir
                doc = _luc_read(String(fixture["document"]))
                golden = _luc_read(String(fixture["golden"]))
                overrides = Dict{String,String}()
                for (loader, rel) in get(fixture, "url_overrides", Dict())
                    p = abspath(joinpath(_LUC_TESTS, String(rel)))
                    @test isfile(p)
                    overrides[String(loader)] = "file://" * p
                end
                loaders = haskey(fixture, "loaders") ?
                          String[String(l) for l in fixture["loaders"]] : nothing
                provs = _LUC.providers_from_document(doc;
                    cache_root = joinpath(dir, "cache"),
                    loaders = loaders, url_overrides = overrides)

                deliver(key) = Float64.(_LUC.provider_sample(provs[key], 0.0))
                records = Int(golden["records"])
                raws = golden["raw_columns"]
                skip = String[String(k) for k in golden["no_conversion_declared"]]

                # §8.5: the delivered array is the golden's, on the f64 bits.
                for (key, want) in golden["delivered"]
                    @test haskey(provs, key)
                    got = deliver(key)
                    @test length(got) == records
                    @test _luc_bits(got) == _luc_bits(want)
                end

                # The NO-OP property: adding §8.5 support must change nothing for
                # a document that declares no conversion.
                for key in skip
                    @test _luc_bits(deliver(key)) == _luc_bits(raws[key])
                end

                # The fixture is load-bearing: an implementation that applies
                # nothing cannot pass it.
                for key in keys(golden["delivered"])
                    key in skip && continue
                    @test _luc_bits(deliver(key)) != _luc_bits(raws[key])
                end
            end
        end
    end
end
