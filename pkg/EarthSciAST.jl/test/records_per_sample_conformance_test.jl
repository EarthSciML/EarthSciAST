# Cross-language conformance for `from.records_per_sample` (esm-spec §8.5.1).
#
# Drives the shared manifest at `tests/conformance/records_per_sample/`. A valid
# case must validate, round-trip the field, and flatten with each data-fed
# parameter's `LoaderField` reporting the EFFECTIVE value (the binding's own,
# else the source's `temporal.records_per_sample`, else 1) and the flattened
# parameter's `update.from` carrying the field as written. An `invalid` case must
# be refused by validation with exactly one `records_per_sample_invalid` at the
# pinned pointer; a `flatten_invalid` case validates clean of that code and is
# refused by `flatten` with it, the message naming the pointer; a `refused` case
# is refused by whichever of the two first sees the record shape.

using Test
using EarthSciAST
using JSON3

include("testutils.jl")  # TESTUTILS_REPO_ROOT

const _RPS_DIR = joinpath(TESTUTILS_REPO_ROOT, "tests", "conformance", "records_per_sample")
const _RPS_MANIFEST = JSON3.read(read(joinpath(_RPS_DIR, "manifest.json"), String))

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

@testset "conformance: records_per_sample (esm-spec §8.5.1)" begin
    @test "records_per_sample_invalid" in EarthSciAST.error_code_names()
    for case in _RPS_MANIFEST.cases
        path = joinpath(_RPS_DIR, String(case.path))
        @testset "$(case.id)" begin
            file = EarthSciAST.load_path(path)
            result = EarthSciAST.validate(file)
            found = [e for e in result.structural_errors if e.error_type == "records_per_sample_invalid"]
            if case.expect == "valid"
                @test isempty(found)
                @test isempty(result.schema_errors)
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
                # The field survives emit -> load unchanged.
                again = EarthSciAST.load_string(EarthSciAST.to_json(file))
                for (mname, model) in file.models, (vname, v) in model.variables
                    from = _rps_from(v)
                    from === nothing && continue
                    @test _rps_from(again.models[mname].variables[vname]).records_per_sample ==
                        from.records_per_sample
                end
            elseif case.expect == "invalid"
                @test [e.path for e in found] == [String(case.pointer)]
            elseif case.expect == "flatten_invalid"
                @test isempty(found)
                _rps_test_flatten_refuses(file, case)
            elseif case.expect == "refused"
                # Whichever stage first sees the record shape refuses it.
                if isempty(found)
                    _rps_test_flatten_refuses(file, case)
                else
                    @test [e.path for e in found] == [String(case.pointer)]
                end
            else
                error("unknown expectation '$(case.expect)' in case $(case.id)")
            end
        end
    end
end
