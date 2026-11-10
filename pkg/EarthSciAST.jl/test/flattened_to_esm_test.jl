# Tests for the lossless-flatten + FlattenedSystem→runnable-document path:
#   - `reconstruct` keeps every OpExpr field across structural rewrites (so
#     substitute / namespace_expr / simplify are no longer lossy);
#   - `flatten` carries the document-scoped index-set registry on the
#     FlattenedSystem;
#   - `flattened_to_esm` reconstitutes a single runnable document, and a deep
#     observed chain resolves through `build_evaluator` with no pre-inlining.
# MTK-free: runs under the package test env and the pde_sim_adapter env alike.
using Test
import EarthSciAST as ESS
const E = ESS

V(n) = E.VarExpr(n); N(x) = E.NumExpr(x)

@testset "Canonical reconstruct + lossless flatten + flattened_to_esm" begin
    @testset "reconstruct copies every OpExpr field; rewrites preserve them" begin
        tl = E.OpExpr(
            "integral", E.ASTExpr[V("fm")]; int_var = "z",
            lower = N(0.0), upper = V("H")
        )
        agg = E.OpExpr(
            "faq", E.ASTExpr[]; semiring = "sum_product", output_idx = Any[],
            ranges = Dict{String, Any}("i" => E.IndexSetRef("src_cells")),
            expr_body = E.OpExpr("*", E.ASTExpr[V("A"), V("F")]),
            join = Any[[("a", "b")]], filter = E.OpExpr(">", E.ASTExpr[V("A"), N(0.0)]),
            id = "prod"
        )
        # override-only semantics
        r = E.reconstruct(agg; semiring = "min_plus")
        @test r.semiring == "min_plus" && r.ranges === agg.ranges && r.join === agg.join
        # each rewrite keeps int_var/lower/upper and semiring/ranges/id
        for f in (
                ESS.substitute(tl, Dict{String, E.ASTExpr}("fm" => N(1.0))),
                ESS.namespace_expr(tl, "M", Set{String}(["fm"])),
                ESS.simplify(tl),
            )
            @test f.int_var == "z" && f.lower == N(0.0) && f.upper isa E.ASTExpr
        end
        for f in (
                ESS.substitute(agg, Dict{String, E.ASTExpr}("F" => N(2.0))),
                ESS.namespace_expr(agg, "M", Set{String}(["A", "F"])),
                ESS.simplify(agg),
            )
            @test f.semiring == "sum_product" && f.id == "prod" && f.expr_body !== nothing
        end
    end

    # A tiny system with an index set, so flatten must carry the index-set
    # registry, and the round-trip document must preserve it.
    function tiny_doc()
        op(o, a...) = Dict{String, Any}("op" => o, "args" => collect(Any, a))
        Dict{String, Any}(
            "esm" => "0.5.0", "metadata" => Dict("name" => "Tiny"),
            # esm-spec v0.8.0: index_sets is a single document-scoped registry.
            "index_sets" => Dict{String, Any}("cells" => Dict{String, Any}("kind" => "interval", "size" => 2)),
            "models" => Dict{String, Any}(
                "A" => Dict{String, Any}(
                    "variables" => Dict{String, Any}(
                        "code" => Dict{String, Any}("type" => "parameter", "default" => 2.0),
                        # esm 1.0.0 §6.3: an observed unknown is an `unknown`
                        # DEFINED by a bare-variable-LHS equation.
                        "h" => Dict{String, Any}("type" => "unknown"),
                        "y" => Dict{String, Any}("type" => "unknown")
                    ),
                    "equations" => Any[
                        Dict{String, Any}("lhs" => "h", "rhs" => op("*", "code", 10)),
                        Dict{String, Any}(
                            "lhs" => Dict{String, Any}("op" => "D", "args" => Any["y"], "wrt" => "t"),
                            "rhs" => "h"
                        ),
                    ]
                ),
            )
        )
    end

    # Parse via the schema-lenient coercion path build_evaluator itself uses
    # (`coerce_esm_file`), so the test exercises flatten/bridge, not full schema
    # validation of a hand-built fixture.
    parse_tiny() = E.flatten(ESS.coerce_esm_file(ESS.JSON3.read(ESS.JSON3.write(tiny_doc()))))

    @testset "flatten carries document-scoped index_sets" begin
        flat = parse_tiny()
        # esm-spec v0.8.0: document-scoped registry — plain (un-namespaced) names.
        @test haskey(flat.index_sets, "cells")
        @test !haskey(flat.index_sets, "A.cells")
    end

    @testset "flattened_to_esm reconstitutes a runnable document" begin
        flat = parse_tiny()
        doc = E.flattened_to_esm(flat)
        # index_sets is emitted at the document level (sibling of `models`).
        @test haskey(doc, "index_sets") && haskey(doc["index_sets"], "cells")
        # build + evaluate: h = code·10 = 20, so D(y) = 20.
        f!, u0, p, _t, vmap = E._build_evaluator(doc; initial_conditions = Dict("A.y" => 0.0))
        du = similar(u0); f!(du, u0, p, 0.0)
        @test du[vmap["A.y"]] ≈ 20.0
    end

    @testset "deep observed chain resolves through build_evaluator (no pre-inline)" begin
        # esm 1.0.0 §6.3: each link of the chain is an `unknown` whose DEFINING
        # equation is a bare-variable-LHS entry of the model's `equations`.
        U() = Dict{String, Any}("type" => "unknown")
        op(o, a...) = Dict{String, Any}("op" => o, "args" => collect(Any, a))
        def(n, e) = Dict{String, Any}("lhs" => n, "rhs" => e)
        vars = Dict{String, Any}(
            "x" => Dict{String, Any}("type" => "parameter", "default" => 3.0),
            "a" => U(), "b" => U(), "c" => U(), "d" => U(), "e" => U(),
            "y" => U()
        )
        eqs = Any[
            def("a", op("+", "x", 1)), def("b", op("*", 2, "a")), def("c", op("+", "b", "a")),
            def("d", op("*", "c", "c")), def("e", op("-", "d", 1)),
            Dict{String, Any}("lhs" => Dict{String, Any}("op" => "D", "args" => Any["y"], "wrt" => "t"), "rhs" => "e"),
        ]
        doc = Dict{String, Any}(
            "esm" => "0.5.0", "metadata" => Dict("name" => "Chain"),
            "models" => Dict{String, Any}("M" => Dict{String, Any}("variables" => vars, "equations" => eqs))
        )
        f!, u0, p, _t, vmap = E._build_evaluator(doc; initial_conditions = Dict("y" => 0.0))
        du = similar(u0); f!(du, u0, p, 0.0)
        @test du[vmap["y"]] ≈ 143.0   # x=3: a4 b8 c12 d144 e143
    end
end
