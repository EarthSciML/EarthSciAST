# esm-spec §9.3: an `enum` op in a mounted file resolves against THAT file's
# `enums` block, at either §4.7 mount form, and `enums` do not merge across the
# mount.
#
# Issue #260: two leaves declaring the same enum symbol with different values
# were merged into one registry, first declaration winning, so the second leaf
# silently computed with the first leaf's constant. The fixtures are shared with
# the other four bindings (`tests/conformance/mount_enums/`).

using Test
using JSON3
using EarthSciAST

@testset "mount_enums: a mounted file's enum ops resolve in its own block (§9.3, #260)" begin
    dir = joinpath(@__DIR__, "..", "..", "..", "tests", "conformance", "mount_enums")
    expected = JSON3.read(read(joinpath(dir, "expected.json"), String))

    function defining_rhs(file, dotted::AbstractString)
        parts = split(dotted, ".")
        node = file.models[String(parts[1])]
        for sub in parts[2:end-1]
            node = node.subsystems[String(sub)]
        end
        var = String(parts[end])
        eq = only(filter(e -> e.lhs isa EarthSciAST.VarExpr && e.lhs.name == var,
                         node.equations))
        return eq.rhs
    end

    lowered_constant(rhs) =
        rhs isa EarthSciAST.OpExpr && rhs.op == "const" ? rhs.value :
        rhs isa EarthSciAST.IntExpr ? rhs.value : rhs

    for (fixture, values) in pairs(expected.loads)
        @testset "$(fixture)" begin
            file = EarthSciAST.load_path(joinpath(dir, String(fixture)))
            for (dotted, want) in pairs(values)
                @test lowered_constant(defining_rhs(file, String(dotted))) == want
            end
        end
    end

    for (fixture, code) in pairs(expected.errors)
        @testset "$(fixture) is refused with $(code)" begin
            err = try
                EarthSciAST.load_path(joinpath(dir, String(fixture)))
                nothing
            catch e
                e
            end
            @test err !== nothing && hasproperty(err, :code) && err.code == String(code)
        end
    end
end
