# Conformance harness adapter — round-trip category (gt-tvz Phase 1).
#
# Contract: load → save → load → save; the second and third serialized
# JSON payloads must be equal after parsing. See tests/conformance/README.md
# for the full adapter contract.

using Test
using JSON3
using EarthSciAST

include("testutils.jl")  # TESTUTILS_REPO_ROOT + _require_fixture

const _TESTS_DIR       = joinpath(TESTUTILS_REPO_ROOT, "tests")
const _MANIFEST_PATH   = joinpath(_TESTS_DIR, "conformance", "round_trip", "manifest.json")

"""
    _idempotent_roundtrip(path::String) -> Tuple{Any, Any}

Load `path`, save to a temp file, reload, save again. Return the two
re-saved JSON values (parsed) for equality comparison. If the binding's
serializer is deterministic, these must be equal.
"""
function _idempotent_roundtrip(path::String)
    original = EarthSciAST.load(path)

    first_path = tempname() * ".esm"
    second_path = tempname() * ".esm"
    try
        EarthSciAST.save(original, first_path)
        reloaded = EarthSciAST.load(first_path)
        EarthSciAST.save(reloaded, second_path)

        first_json  = JSON3.read(read(first_path, String))
        second_json = JSON3.read(read(second_path, String))
        return first_json, second_json
    finally
        isfile(first_path)  && rm(first_path)
        isfile(second_path) && rm(second_path)
    end
end

@testset "Conformance: round-trip (manifest-driven)" begin
    @test isfile(_MANIFEST_PATH)

    manifest = JSON3.read(read(_MANIFEST_PATH, String))
    @test manifest.category == "round_trip"
    @test !isempty(manifest.fixtures)

    for fixture in manifest.fixtures
        id = String(fixture.id)
        fixture_path = joinpath(_TESTS_DIR, String(fixture.path))

        @testset "$(id)" begin
            # Several manifest entries reference fixtures that do not exist on
            # disk yet (the discretizations/ set and regrid_point_missing_value)
            # — recorded as standardized skips, never silently green.
            if _require_fixture(fixture_path)
                first_json, second_json = _idempotent_roundtrip(fixture_path)
                @test first_json == second_json
            end
        end
    end
end
