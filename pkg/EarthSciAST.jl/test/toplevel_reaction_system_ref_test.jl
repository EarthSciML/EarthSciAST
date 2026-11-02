# esm-spec §4.7 "Two mount forms, one mechanism": a top-level
# `reaction_systems.<k>` `{ref}` mounts the referenced leaf's reaction system
# under the key `<k>`. The fixtures are shared with the other bindings
# (`tests/conformance/toplevel_reaction_system_ref/`); Julia and Rust mount the
# form, Python, TypeScript and Go refuse it with `mount_form_unsupported`.

using Test
using JSON3
using EarthSciAST

@testset "toplevel_reaction_system_ref: a top-level reaction_systems.<k> {ref} mounts (§4.7)" begin
    dir = joinpath(@__DIR__, "..", "..", "..", "tests", "conformance", "toplevel_reaction_system_ref")
    expected = JSON3.read(read(joinpath(dir, "expected.json"), String), Dict{String, Any})
    @test "julia" in expected["implemented_by"]

    function components(fixture)
        file = EarthSciAST.load_path(joinpath(dir, fixture))
        doc = JSON3.read(JSON3.write(EarthSciAST.serialize_esm_file(file)), Dict{String, Any})
        return (get(doc, "models", nothing), get(doc, "reaction_systems", nothing))
    end

    for (fixture, inline) in expected["loads"]
        @testset "$(fixture) loads as $(inline)" begin
            got_models, got_rs = components(fixture)
            want_models, want_rs = components(inline)
            @test got_rs == want_rs
            @test got_models == want_models
        end
    end

    # `load_errors` maps a fixture to {code: [bindings]}; a binding listed under
    # none must still refuse it.
    for (fixture, want) in expected["load_errors"]
        code = findfirst(bs -> "julia" in bs, want)
        @testset "$(fixture) is refused$(code === nothing ? "" : " with $(code)")" begin
            err = try
                EarthSciAST.load_path(joinpath(dir, fixture))
                nothing
            catch e
                e
            end
            @test err !== nothing
            code === nothing ||
                @test hasproperty(err, :code) && err.code == code
        end
    end
end
