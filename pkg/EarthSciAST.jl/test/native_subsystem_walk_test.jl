# The esm-spec §4.7 `subsystems.<k>` mount form on the native dictionary
# (`_inline_mounts!`), checked against what a load reports.
#
# DIAGNOSTIC POINTERS FIRST, and deliberately. `tests/invalid/expected_errors.json`
# pins the exact path, code, message and details of an unresolvable and an
# ambiguous subsystem mount for ALL FIVE bindings, and Julia produces the path
# from the mount site the pipeline stamps (`_with_mount_site`, rendered by
# `load_failure_structural_error`).

using Test
using JSON3
using EarthSciAST

include("testutils.jl")  # TESTUTILS_REPO_ROOT

const _NSW_TESTS = joinpath(TESTUTILS_REPO_ROOT, "tests")
const _NSW_EXPECTED = JSON3.read(read(joinpath(_NSW_TESTS, "invalid", "expected_errors.json"), String))

# The native walk's failure, rendered the way the conformance producer renders it.
function _native_walk_failure(path::AbstractString)
    raw = EarthSciAST._to_ordered(EarthSciAST._read_json_document(read(path, String)))
    ctx = EarthSciAST._root_mount_context(raw, Dict{String, Int}(), EarthSciAST._DocumentSource())
    try
        EarthSciAST._inline_mounts!(raw, EarthSciAST._DirBase(dirname(path)), ctx)
    catch e
        return EarthSciAST.load_failure_structural_error(e)
    end
    return nothing
end

@testset "native subsystem walk: pinned diagnostic pointers" begin
    for fixture in ("subsystem_ref_not_found.esm", "subsystem_ref_ambiguous.esm")
        path = joinpath(_NSW_TESTS, "invalid", fixture)
        want = _NSW_EXPECTED[Symbol(fixture)][:structural_errors][1]
        got = _native_walk_failure(path)
        @test got !== nothing
        got === nothing && continue
        @test got.path == String(want[:path])
        @test got.error_type == String(want[:code])
        @test got.message == String(want[:message])
        for (k, v) in pairs(want[:details])
            @test get(got.details, String(k), nothing) == String(v)
        end

        # And identical to what a whole load renders for the same document.
        typed = try
            load_path(path); nothing
        catch e
            EarthSciAST.load_failure_structural_error(e)
        end
        @test typed !== nothing
        typed === nothing && continue
        @test (got.path, got.error_type, got.message) == (typed.path, typed.error_type, typed.message)
        @test got.details == typed.details
    end
end
