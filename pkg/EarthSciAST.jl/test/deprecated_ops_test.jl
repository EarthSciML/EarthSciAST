# The deprecated op spellings `neg` and `pow` (esm-spec §4.2 "Deprecated ops").
#
# A loader rewrites `neg(x)` to unary `-(x)`, `pow(x, n)` to `^(x, n)` and a
# `broadcast` `fn` of `neg` to `-`, at the wire boundary, keeping every other
# field, and warns `deprecated_op` once per document naming every rewritten
# node. A use with the wrong operand count is left as written.

using Test
using Logging
using EarthSciAST
using JSON3

include("testutils.jl")  # TESTUTILS_REPO_ROOT

const ESM = EarthSciAST

function _dep_load_logged(path)
    logger = Test.TestLogger(; min_level = Logging.Warn)
    file = with_logger(() -> EarthSciAST.load_path(path), logger)
    deprecations = [
        r for r in logger.logs
            if r.level == Logging.Warn && startswith(string(r.message), "deprecated_op:")
    ]
    return file, deprecations
end

_dep_rhs(model, lhs) = only(e.rhs for e in model.equations if e.lhs isa VarExpr && e.lhs.name == lhs)

# Every op and broadcast `fn` spelled anywhere in an expression tree.
function _dep_spellings!(out, e)
    e isa OpExpr || return out
    push!(out, e.op)
    e.fn === nothing || push!(out, "fn:" * e.fn)
    for a in e.args
        _dep_spellings!(out, a)
    end
    return out
end

@testset "deprecated ops neg and pow (esm-spec §4.2)" begin
    sos = joinpath(TESTUTILS_REPO_ROOT, "tests", "conformance", "scalar_operator_semantics", "fixtures")

    @testset "registry keeps both, mapped to their replacements" begin
        @test ESM._DEPRECATED_OPS == Dict("neg" => "-", "pow" => "^")
        @test ESM._op_spec("neg") !== nothing
        @test ESM._op_spec("pow") !== nothing
        @test ESM.ERROR_CODES.DEPRECATED_OP == "deprecated_op"
    end

    @testset "pow_alias.esm: pow loads as ^, one warning" begin
        file, deps = _dep_load_logged(joinpath(sos, "pow_alias.esm"))
        rhs = _dep_rhs(file.models["PowAlias"], "pow_power")
        @test rhs isa OpExpr && rhs.op == "^"
        @test length(rhs.args) == 2
        @test length(deps) == 1
        @test occursin("/models/PowAlias/equations/0/rhs (pow)", string(only(deps).message))
    end

    @testset "scalar_operator_semantics.esm: neg loads as unary -" begin
        file, deps = _dep_load_logged(joinpath(sos, "scalar_operator_semantics.esm"))
        rhs = _dep_rhs(file.models["Ops"], "negated")
        @test rhs isa OpExpr && rhs.op == "-"
        @test length(rhs.args) == 1 && rhs.args[1] isa VarExpr && rhs.args[1].name == "four"
        @test length(deps) == 1
        msg = string(only(deps).message)
        @test count("/models/Ops/equations/", msg) == 1
    end

    @testset "27_broadcast_unary.esm: broadcast fn neg loads as -" begin
        path = joinpath(TESTUTILS_REPO_ROOT, "tests", "fixtures", "faq", "27_broadcast_unary.esm")
        file, deps = _dep_load_logged(path)
        seen = String[]
        for (_, m) in file.models, e in m.equations
            _dep_spellings!(seen, e.rhs)
        end
        @test "fn:-" in seen
        @test !("fn:neg" in seen)
        @test !("neg" in seen)
        @test length(deps) == 1
        @test endswith(rstrip(string(only(deps).message), '.'), "/models/BroadcastUnary/equations/3/rhs/args/0 (broadcast fn neg)")
    end

    @testset "a migrated document loads with no warning" begin
        path = joinpath(TESTUTILS_REPO_ROOT, "tests", "valid", "solver_block.esm")
        _, deps = _dep_load_logged(path)
        @test isempty(deps)
    end

    @testset "raw rewrite: fields kept, wrong arity left alone, idempotent" begin
        doc = Dict{String, Any}(
            "a" => Dict{String, Any}("op" => "neg", "args" => Any["x"], "id" => "keep"),
            "b" => Dict{String, Any}("op" => "neg", "args" => Any["x", "y"]),
            "c" => Dict{String, Any}("op" => "pow", "args" => Any["x"]),
            "d" => Any[Dict{String, Any}("op" => "pow", "args" => Any["x", 2])],
            "e" => Dict{String, Any}("op" => "broadcast", "fn" => "neg", "args" => Any["v"]),
            "f" => Dict{String, Any}("op" => "broadcast", "fn" => "pow", "args" => Any["v", 2]),
            "g" => Dict{String, Any}("op" => "broadcast", "fn" => "neg", "args" => Any["v", "w"]),
            "h/i~" => Dict{String, Any}("op" => "neg", "args" => Any["x"]),
        )
        sites = @test_logs (:warn, r"^deprecated_op: ") ESM._rewrite_deprecated_ops!(doc)
        # One shared site format across the bindings: the node's RFC 6901
        # pointer, then the spelling it had.
        @test sort(sites) == ["/a (neg)", "/d/0 (pow)", "/e (broadcast fn neg)", "/h~1i~0 (neg)"]
        @test doc["a"] == Dict{String, Any}("op" => "-", "args" => Any["x"], "id" => "keep")
        @test doc["b"]["op"] == "neg"
        @test doc["c"]["op"] == "pow"
        @test doc["d"][1]["op"] == "^"
        @test doc["e"]["fn"] == "-"
        @test doc["f"]["fn"] == "pow"
        @test doc["g"]["fn"] == "neg"  # a two-operand broadcast of neg keeps its arity error
        again = @test_logs ESM._rewrite_deprecated_ops!(doc)
        @test isempty(again)
    end

    @testset "a two-operand broadcast of neg is refused for its arity" begin
        doc = Dict{String, Any}(
            "esm" => "2.0.0",
            "metadata" => Dict{String, Any}("name" => "B"),
            "models" => Dict{String, Any}(
                "M" => Dict{String, Any}(
                    "variables" => Dict{String, Any}(
                        "a" => Dict{String, Any}("type" => "unknown", "units" => "1", "default" => 0.0),
                    ),
                    "equations" => Any[
                        Dict{String, Any}(
                            "lhs" => Dict{String, Any}("op" => "D", "args" => Any["a"], "wrt" => "t"),
                            "rhs" => Dict{String, Any}("op" => "broadcast", "fn" => "neg", "args" => Any["a", "a"]),
                        ),
                    ],
                ),
            ),
        )
        refused = try
            file = EarthSciAST.load_document(doc)
            join(string.(EarthSciAST.validate(file).structural_errors), "; ")
        catch e
            sprint(showerror, e)
        end
        @test occursin("'neg'", refused) || occursin("\"neg\"", refused)
    end

    @testset "the reference-preserving emit path rewrites them too" begin
        path = joinpath(sos, "pow_alias.esm")
        raw = JSON3.read(read(path, String))
        out = @test_logs (:warn, r"^deprecated_op: ") match_mode = :any EarthSciAST.emit_document(raw, sos)
        text = EarthSciAST.emit_esm_string(out)
        @test !occursin("\"pow\"", text)
        @test occursin("\"^\"", text)
    end

    @testset "a leaf mounted through the typed walk warns once" begin
        leaf = Dict{String, Any}(
            "esm" => "1.0.0", "metadata" => Dict{String, Any}("name" => "leaf"),
            "models" => Dict{String, Any}(
                "L" => Dict{String, Any}(
                    "variables" => Dict{String, Any}(
                        "x" => Dict{String, Any}("type" => "unknown", "default" => 1.0)
                    ),
                    "equations" => Any[
                        Dict{String, Any}(
                            "lhs" => Dict{String, Any}("op" => "D", "args" => Any["x"], "wrt" => "t"),
                            "rhs" => Dict{String, Any}("op" => "neg", "args" => Any["x"]),
                        ),
                    ],
                )
            ),
        )
        parent = Dict{String, Any}(
            "esm" => "1.0.0", "metadata" => Dict{String, Any}("name" => "parent"),
            "models" => Dict{String, Any}(
                "P" => Dict{String, Any}(
                    "variables" => Dict{String, Any}(),
                    "equations" => Any[],
                    "subsystems" => Dict{String, Any}("S" => Dict{String, Any}("ref" => "./leaf.esm")),
                )
            ),
        )
        mktempdir() do dir
            write(joinpath(dir, "leaf.esm"), JSON3.write(leaf))
            # Coerced without the loader's inlining, so the subsystem stays a
            # `SubsystemRef` for the typed walk to load.
            file = EarthSciAST.coerce_esm_file(parent)
            logger = Test.TestLogger(; min_level = Logging.Warn)
            with_logger(() -> EarthSciAST.resolve_subsystem_refs!(file, dir), logger)
            deps = [
                r for r in logger.logs
                    if startswith(string(r.message), "deprecated_op:")
            ]
            @test length(deps) == 1
            sub = file.models["P"].subsystems["S"]
            @test sub isa Model
            @test only(sub.equations).rhs.op == "-"
        end
    end
end
