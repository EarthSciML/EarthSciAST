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
        @test occursin("E_REMOVED_OP", sprint(showerror, err))
    end
end
