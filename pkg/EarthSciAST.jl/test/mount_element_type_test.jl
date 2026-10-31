# esm-spec §4.7 "Working precision crosses a mount" (CONFORMANCE_SPEC §5.18.2b):
# a mounted document's `domain.element_type` does not merge, so the mount edge
# writes it onto the variables of the component it splices in whenever it
# differs from the mounting document's effective precision. The fixtures are
# shared with the other four bindings (`tests/conformance/mount_element_type/`).
# This binding does not evaluate per-variable precision, so it asserts the
# loader contract (`loads`, `load_errors`) only.

using Test
using JSON3
using EarthSciAST

@testset "mount_element_type: a mounted leaf's element_type crosses the mount (§4.7)" begin
    dir = joinpath(@__DIR__, "..", "..", "..", "tests", "conformance", "mount_element_type")
    expected = JSON3.read(read(joinpath(dir, "expected.json"), String), Dict{String, Any})

    # Every variable (subsystems as `Model.Sub.var`) of an EMITTED document ->
    # its `element_type`, or `nothing`.
    function carried(doc)
        out = Dict{String, Any}()
        function walk(prefix, system)
            for (name, decl) in get(system, "variables", Dict())
                out["$(prefix).$(name)"] = get(decl, "element_type", nothing)
            end
            for (key, sub) in get(system, "subsystems", Dict())
                walk("$(prefix).$(key)", sub)
            end
        end
        for (name, model) in get(doc, "models", Dict())
            walk(String(name), model)
        end
        return out
    end
    emitted(file) = JSON3.read(JSON3.write(EarthSciAST.serialize_esm_file(file)), Dict{String, Any})

    for (fixture, want) in expected["loads"]
        @testset "$(fixture)" begin
            doc = emitted(EarthSciAST.load_path(joinpath(dir, fixture)))
            domain = get(get(doc, "domain", Dict()), "element_type", nothing)
            @test domain == want["domain_element_type"]
            @test carried(doc) == Dict{String, Any}(want["element_types"])
            # load -> emit -> load is a fixed point on the written fields.
            again = emitted(EarthSciAST.load_string(JSON3.write(doc)))
            @test carried(again) == carried(doc)
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
