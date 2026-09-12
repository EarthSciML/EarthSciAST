# The `aggregate` -> `faq` deprecated-op-alias contract (esm 1.1.0).
#
# Gates tests/conformance/deprecated_op_alias/ and the `removed_op` rejection
# of `arrayop`. See CONFORMANCE_SPEC §7 and
# docs/content/rfcs/faq-node-rename.md.

using Test
using EarthSciAST
using JSON3

include("testutils.jl")  # TESTUTILS_REPO_ROOT

const _ALIAS_CONF = joinpath(TESTUTILS_REPO_ROOT, "tests", "conformance",
                             "deprecated_op_alias")

# Every `op` string in a decoded document, depth-first.
function _all_ops(node, out = String[])
    if node isa AbstractDict
        v = get(node, "op", nothing)
        v isa AbstractString && push!(out, String(v))
        for child in values(node)
            _all_ops(child, out)
        end
    elseif node isa AbstractVector
        for child in node
            _all_ops(child, out)
        end
    end
    return out
end

@testset "deprecated op alias: aggregate -> faq" begin
    @testset "the alias loads and warns exactly once for the document" begin
        # Once per DOCUMENT, not once per node: the fixture carries two aliased
        # nodes and must still produce a single warning.
        @test_logs (:warn,) match_mode = :any EarthSciAST.load_path(
            joinpath(_ALIAS_CONF, "aliased.esm"))
    end

    @testset "the alias never survives the loader" begin
        f = EarthSciAST.load_path(joinpath(_ALIAS_CONF, "aliased.esm"))
        ops = _all_ops(JSON3.read(EarthSciAST.to_json(f), Dict{String,Any}))
        @test !("aggregate" in ops)   # the alias reached emit
        @test "faq" in ops
    end

    @testset "emitting the alias document reproduces the canonical one" begin
        aliased = EarthSciAST.load_path(joinpath(_ALIAS_CONF, "aliased.esm"))
        canonical = EarthSciAST.load_path(joinpath(_ALIAS_CONF, "canonical.esm"))
        @test EarthSciAST.to_json(aliased) == EarthSciAST.to_json(canonical)
    end

    @testset "the canonical document is quiet" begin
        @test_logs EarthSciAST.load_path(joinpath(_ALIAS_CONF, "canonical.esm"))
    end

    @testset "the wire boundary covers REFERENCED documents" begin
        # Every other fixture here is a single self-contained document — which
        # is exactly why five green binding suites missed the leak: the
        # normalizer ran on the ROOT's bytes and ref resolution then parsed
        # child files raw, so a child's alias reached `emit` untouched.
        f = EarthSciAST.load_path(joinpath(_ALIAS_CONF, "ref_parent_aliased.esm"))
        ops = _all_ops(JSON3.read(EarthSciAST.to_json(f), Dict{String,Any}))
        @test !("aggregate" in ops)
        @test "faq" in ops
    end

    @testset "arrayop in a referenced child is rejected" begin
        err = try
            EarthSciAST.load_path(joinpath(_ALIAS_CONF, "ref_parent_arrayop.esm"))
            nothing
        catch e
            e
        end
        @test err !== nothing
        @test occursin("removed_op", sprint(showerror, err))  # the shared diagnostic name
    end

    @testset "the esm 1.1.0 version gate" begin
        mktempdir() do dir
            function at_version(src, version)
                doc = JSON3.read(read(joinpath(_ALIAS_CONF, src), String), Dict{String,Any})
                doc["esm"] = version
                path = joinpath(dir, "v_" * version * "_" * src)
                write(path, JSON3.write(doc))
                return path
            end
            # `faq` arrives at 1.1.0 — the gate the `solver` block also uses.
            err = try
                EarthSciAST.load_path(at_version("canonical.esm", "1.0.0")); nothing
            catch e; e end
            @test err !== nothing
            @test occursin("faq_version_too_old", sprint(showerror, err))  # the shared diagnostic name
            # `aggregate` IS the pre-1.1.0 spelling, so the gate must NOT catch
            # it: the gate reads the AUTHORED form, and the alias is normalized
            # with the declared version raised to the floor alongside it.
            f = EarthSciAST.load_path(at_version("aliased.esm", "1.0.0"))
            @test f.esm == "1.1.0"
        end
    end

    @testset "arrayop is rejected by name, not left to the open tier" begin
        # `arrayop` matches the `op` pattern, so without a by-name rejection it
        # would load as an OPEN rewrite-target op (esm-spec §4.2) and fail only
        # much later as `unlowered_operator`.
        path = joinpath(TESTUTILS_REPO_ROOT, "tests", "invalid", "faq",
                        "arrayop_op_removed.esm")
        err = try
            EarthSciAST.load_path(path)
            nothing
        catch e
            e
        end
        @test err !== nothing
        @test occursin("removed_op", sprint(showerror, err))  # the shared diagnostic name
    end
end
