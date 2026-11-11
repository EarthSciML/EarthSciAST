# Cross-language conformance for record axes and the deprecated
# `records_per_sample` (esm-spec §8.5.1).
#
# Drives the shared manifest at `tests/conformance/records_per_sample/`. Every
# diagnostic is filtered by the manifest's `record_codes`. A valid case must
# validate with none of them, flatten with each data-fed parameter's
# `LoaderField` reporting the number of records its record shape gives it, keep
# the deprecated field on the flattened parameter's `update.from` exactly as
# written, round-trip both that field and every index set's `records` flag
# through emit -> load, and report exactly `deprecated_fields` from
# `deprecated_records_per_sample_sites` — loading warning once when that list is
# non-empty and not at all when it is empty. An `invalid` case must be refused
# by validation with exactly one finding from `record_codes`, `code` at
# `pointer`; a `flatten_invalid` case validates clean of them and is refused by
# `flatten` with `code`, the message naming the pointer; a `refused` case is
# refused by whichever of the two first sees the record shape.

using Test
using Logging
using EarthSciAST
using JSON3

include("testutils.jl")  # TESTUTILS_REPO_ROOT

const _RPS_DIR = joinpath(TESTUTILS_REPO_ROOT, "tests", "conformance", "records_per_sample")
const _RPS_MANIFEST = JSON3.read(read(joinpath(_RPS_DIR, "manifest.json"), String))
const _RPS_CODES = Set(String.(_RPS_MANIFEST.record_codes))

_rps_from(v) = v.update === nothing ? nothing : only(v.update).from

function _rps_test_flatten_refuses(file, case)
    err = try
        flatten(file)
        nothing
    catch e
        e
    end
    @test err isa EarthSciAST.ExpressionTemplateError
    err isa EarthSciAST.ExpressionTemplateError || return
    @test err.code == String(case.code)
    return @test occursin(String(case.pointer), err.message)
end

# Load `path`, capturing the `deprecated_records_per_sample` warnings the load
# emits.
function _rps_load_logged(path)
    logger = Test.TestLogger(; min_level = Logging.Warn)
    file = with_logger(() -> EarthSciAST.load_path(path), logger)
    deprecations = [
        r for r in logger.logs
            if r.level == Logging.Warn &&
                startswith(string(r.message), "deprecated_records_per_sample:")
    ]
    return file, deprecations
end

# Every top-level model variable's `update.from`, as `(model, variable, from)`.
_rps_froms(file) = [
    (mname, vname, _rps_from(v)) for (mname, model) in file.models
        for (vname, v) in model.variables if _rps_from(v) !== nothing
]

@testset "conformance: record axes / records_per_sample (esm-spec §8.5.1)" begin
    for code in _RPS_CODES
        @test code in EarthSciAST.error_code_names()
    end
    for case in _RPS_MANIFEST.cases
        path = joinpath(_RPS_DIR, String(case.path))
        @testset "$(case.id)" begin
            file, deprecations = _rps_load_logged(path)
            result = EarthSciAST.validate(file)
            found = [e for e in result.structural_errors if e.error_type in _RPS_CODES]
            if case.expect == "valid"
                @test isempty(found)
                @test isempty(result.schema_errors)
                # Where the deprecated field is written, and the one warning
                # that names exactly those places.
                want_sites = String.(case.deprecated_fields)
                @test deprecated_records_per_sample_sites(file) == want_sites
                @test length(deprecations) == (isempty(want_sites) ? 0 : 1)
                if !isempty(deprecations)
                    msg = string(only(deprecations).message)
                    @test endswith(msg, "Written at: " * join(want_sites, ", ") * ".")
                end
                flat = flatten(file)
                got = Dict(lf.name => lf for lf in flat.loader_fields)
                for want in case.loader_fields
                    lf = get(got, String(want.name), nothing)
                    @test lf !== nothing
                    lf === nothing && continue
                    @test lf.subkey == want.source
                    @test lf.var == want.file_variable
                    @test lf.cadence == want.cadence
                    @test lf.records_per_sample == want.records_per_sample
                end
                if haskey(case, :flattened_from_records_per_sample)
                    for (name, written) in pairs(case.flattened_from_records_per_sample)
                        from = _rps_from(flat.parameters[String(name)])
                        @test from !== nothing
                        @test from.records_per_sample == written
                    end
                end
                # The deprecated field and each index set's `records` flag
                # survive emit -> load unchanged.
                again = with_logger(NullLogger()) do
                    EarthSciAST.load_string(EarthSciAST.to_json(file))
                end
                for (mname, vname, from) in _rps_froms(file)
                    @test _rps_from(again.models[mname].variables[vname]).records_per_sample ==
                        from.records_per_sample
                end
                @test Set(keys(again.index_sets)) == Set(keys(file.index_sets))
                for (name, iset) in file.index_sets
                    @test again.index_sets[name].records === iset.records
                end
                @test deprecated_records_per_sample_sites(again) == want_sites
            elseif case.expect == "invalid"
                @test [(e.error_type, e.path) for e in found] ==
                    [(String(case.code), String(case.pointer))]
            elseif case.expect == "flatten_invalid"
                @test isempty(found)
                _rps_test_flatten_refuses(file, case)
            elseif case.expect == "refused"
                # Whichever stage first sees the record shape refuses it.
                if isempty(found)
                    _rps_test_flatten_refuses(file, case)
                else
                    @test [(e.error_type, e.path) for e in found] ==
                        [(String(case.code), String(case.pointer))]
                end
            else
                error("unknown expectation '$(case.expect)' in case $(case.id)")
            end
        end
    end

    # Outside deciding how many records a data-fed parameter receives, a record
    # axis is an ordinary interval of size 2, carried by `flatten` with its flag
    # (esm-spec §8.5.1).
    @testset "the records flag survives flatten" begin
        file = EarthSciAST.load_path(joinpath(_RPS_DIR, "fixtures", "record_axis.esm"))
        flat = flatten(file)
        @test flat.index_sets["rec"].records === true
        @test flat.index_sets["pair2"].records === nothing
    end
end
