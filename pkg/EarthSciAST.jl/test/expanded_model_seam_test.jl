# The public template-expansion seam (`expanded_model`, esm-spec §9.6.4
# Option B): the typed model exactly as `build_evaluator` sees it after
# `apply_expression_template` expansion, WITHOUT compiling. Downstream
# analyzers (EarthSciASTDiff differentiates the tree) depend on this being
# (a) the same expansion the evaluator performs, (b) non-mutating, and
# (c) name-resolved exactly like `build_evaluator`.

using Test
using JSON3
using EarthSciAST
using EarthSciAST: coerce_esm_file, evaluate_expr, TreeWalkError

# Any `apply_expression_template` node left in the tree?
function _has_apply(e)
    e isa OpExpr || return false
    e.op == "apply_expression_template" && return true
    any(_has_apply, e.args) && return true
    return e.expr_body !== nothing && _has_apply(e.expr_body)
end

@testset "expanded_model public seam" begin
    doc = Dict(
        "esm" => "0.9.0",
        "metadata" => Dict("name" => "expanded_model_seam"),
        "models" => Dict("T" => Dict(
            "expression_templates" => Dict(
                "decay" => Dict(
                    "params" => ["x", "k"],
                    "body" => Dict("op" => "*",
                                   "args" => [Dict("op" => "-", "args" => ["k"]), "x"]))),
            "variables" => Dict(
                "a" => Dict("type" => "state", "units" => "1", "default" => 1.5),
                "k" => Dict("type" => "parameter", "units" => "1", "default" => 0.25)),
            "equations" => [Dict(
                "lhs" => Dict("op" => "D", "args" => ["a"], "wrt" => "t"),
                "rhs" => Dict("op" => "apply_expression_template", "args" => [],
                              "name" => "decay",
                              "bindings" => Dict("x" => "a", "k" => "k")))],
        )),
    )
    file = coerce_esm_file(JSON3.read(JSON3.write(doc)))

    @testset "expansion, equivalence, non-mutation" begin
        m = expanded_model(file)
        @test m isa Model
        rhs = m.equations[1].rhs
        @test !_has_apply(rhs)                       # reference is gone …
        # … and the expanded body computes what the template says: -k*a.
        @test evaluate_expr(rhs, Dict("a" => 1.5, "k" => 0.25)) ≈ -0.375
        # The seam matches the evaluator: build the ORIGINAL file (which
        # expands internally) and confirm the same RHS value.
        f!, u0, p, _, vm = build_evaluator(file)
        du = zeros(length(u0)); f!(du, u0, p, 0.0)
        @test du[vm["a"]] ≈ -0.375
        # Non-mutating: the file's own model still carries the reference.
        @test _has_apply(file.models["T"].equations[1].rhs)
        # A second call returns a fresh copy, not a cached alias.
        @test expanded_model(file) !== m
    end

    @testset "name resolution mirrors build_evaluator" begin
        @test !_has_apply(expanded_model(file, "T").equations[1].rhs)
        err = try; expanded_model(file, "Nope"); nothing; catch e; e; end
        @test err isa TreeWalkError && err.code == "E_TREEWALK_NO_MODEL"
    end

    @testset "no templates → plain copy" begin
        plain = Dict(
            "esm" => "0.9.0",
            "metadata" => Dict("name" => "plain"),
            "models" => Dict("P" => Dict(
                "variables" => Dict(
                    "a" => Dict("type" => "state", "units" => "1", "default" => 2.0)),
                "equations" => [Dict(
                    "lhs" => Dict("op" => "D", "args" => ["a"], "wrt" => "t"),
                    "rhs" => Dict("op" => "*", "args" => [-1, "a"]))],
            )),
        )
        pf = coerce_esm_file(JSON3.read(JSON3.write(plain)))
        m = expanded_model(pf)
        @test m isa Model
        @test m !== pf.models["P"]                   # a copy, original untouched
        @test evaluate_expr(m.equations[1].rhs, Dict("a" => 2.0)) ≈ -2.0
    end
end
