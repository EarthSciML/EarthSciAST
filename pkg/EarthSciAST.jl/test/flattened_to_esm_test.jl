# Tests for the lossless-flatten + FlattenedSystem→runnable-document path:
#   - `reconstruct` keeps every OpExpr field across structural rewrites (so
#     substitute / namespace_expr / simplify are no longer lossy);
#   - `flatten` carries a namespaced index-set registry + the file's function
#     tables on the FlattenedSystem;
#   - `flattened_to_esm` reconstitutes a single runnable document, and a deep
#     observed chain resolves through `build_evaluator` with no pre-inlining.
# MTK-free: runs under the package test env and the pde_sim_adapter env alike.
using Test
import EarthSciAST as ESS
const E = ESS

V(n) = E.VarExpr(n); N(x) = E.NumExpr(x)

@testset "Canonical reconstruct + lossless flatten + flattened_to_esm" begin
    @testset "reconstruct copies every OpExpr field; rewrites preserve them" begin
        tl = E.OpExpr("table_lookup", E.Expr[]; table="fuel", output=2,
                      table_axes=Dict{String,E.Expr}("code" => V("fm")))
        agg = E.OpExpr("aggregate", E.Expr[]; semiring="sum_product", output_idx=Any[],
                       ranges=Dict{String,Any}("i" => E.IndexSetRef("src_cells")),
                       expr_body=E.OpExpr("*", E.Expr[V("A"), V("F")]),
                       join=Any[[("a","b")]], filter=E.OpExpr(">", E.Expr[V("A"), N(0.0)]),
                       id="prod", manifold=nothing)
        # override-only semantics
        r = E.reconstruct(agg; semiring="min_plus")
        @test r.semiring == "min_plus" && r.ranges === agg.ranges && r.join === agg.join
        # each rewrite keeps table/axes/output and semiring/ranges/id
        for f in (ESS.substitute(tl, Dict{String,E.Expr}("fm"=>N(1.0))),
                  ESS.namespace_expr(tl, "M", Set{String}(["fm"])),
                  ESS.simplify(tl))
            @test f.table == "fuel" && f.output == 2 && haskey(f.table_axes, "code")
        end
        for f in (ESS.substitute(agg, Dict{String,E.Expr}("F"=>N(2.0))),
                  ESS.namespace_expr(agg, "M", Set{String}(["A","F"])),
                  ESS.simplify(agg))
            @test f.semiring == "sum_product" && f.id == "prod" && f.expr_body !== nothing
        end
    end

    # A tiny two-component coupled system: a table_lookup + an index-set range, so
    # flatten must carry both a function table and a namespaced index set, and the
    # round-trip document must preserve them.
    function tiny_doc()
        op(o, a...) = Dict{String,Any}("op"=>o, "args"=>collect(Any, a))
        Dict{String,Any}(
            "esm" => "0.5.0", "metadata" => Dict("name"=>"Tiny"),
            "function_tables" => Dict{String,Any}("fuel" => Dict{String,Any}(
                "axes" => Any[Dict{String,Any}("name"=>"code","values"=>Any[1.0,2.0])],
                "data" => Any[10.0, 20.0])),
            # esm-spec v0.8.0: index_sets is a single document-scoped registry.
            "index_sets" => Dict{String,Any}("cells"=>Dict{String,Any}("kind"=>"interval","size"=>2)),
            "models" => Dict{String,Any}(
                "A" => Dict{String,Any}(
                    "variables" => Dict{String,Any}(
                        "code" => Dict{String,Any}("type"=>"parameter","default"=>2.0),
                        # `h` is plain arithmetic so the tree-walk eval needs no
                        # table_lookup lowering (covered separately); the `fuel`
                        # table is still carried through flatten + the bridge.
                        "h" => Dict{String,Any}("type"=>"observed", "expression"=>op("*","code",10)),
                        "y" => Dict{String,Any}("type"=>"state")),
                    "equations" => Any[Dict{String,Any}(
                        "lhs"=>Dict{String,Any}("op"=>"D","args"=>Any["y"],"wrt"=>"t"),
                        "rhs"=>"h")]),
            ))
    end

    # Parse via the schema-lenient coercion path build_evaluator itself uses
    # (`coerce_esm_file`), so the test exercises flatten/bridge, not full schema
    # validation of a hand-built fixture.
    parse_tiny() = E.flatten(ESS.coerce_esm_file(ESS.JSON3.read(ESS.JSON3.write(tiny_doc()))))

    @testset "flatten carries document-scoped index_sets + function_tables" begin
        flat = parse_tiny()
        # esm-spec v0.8.0: document-scoped registry — plain (un-namespaced) names.
        @test haskey(flat.index_sets, "cells")
        @test !haskey(flat.index_sets, "A.cells")
        @test haskey(flat.function_tables, "fuel")        # carried through
    end

    @testset "flattened_to_esm reconstitutes a runnable document" begin
        flat = parse_tiny()
        doc = E.flattened_to_esm(flat)
        # index_sets is emitted at the document level (sibling of `models`).
        @test haskey(doc, "index_sets") && haskey(doc["index_sets"], "cells")
        @test haskey(doc, "function_tables") && haskey(doc["function_tables"], "fuel")
        # build + evaluate: table_lookup(code=2) -> 20, so D(y) = 20.
        f!, u0, p, _t, vmap = E.build_evaluator(doc; initial_conditions=Dict("A.y"=>0.0))
        du = similar(u0); f!(du, u0, p, 0.0)
        @test du[vmap["A.y"]] ≈ 20.0
    end

    @testset "deep observed chain resolves through build_evaluator (no pre-inline)" begin
        O(e) = Dict{String,Any}("type"=>"observed","expression"=>e)
        op(o,a...) = Dict{String,Any}("op"=>o,"args"=>collect(Any,a))
        vars = Dict{String,Any}(
            "x"=>Dict{String,Any}("type"=>"parameter","default"=>3.0),
            "a"=>O(op("+","x",1)), "b"=>O(op("*",2,"a")), "c"=>O(op("+","b","a")),
            "d"=>O(op("*","c","c")), "e"=>O(op("-","d",1)),
            "y"=>Dict{String,Any}("type"=>"state"))
        eq = Dict{String,Any}("lhs"=>Dict{String,Any}("op"=>"D","args"=>Any["y"],"wrt"=>"t"),"rhs"=>"e")
        doc = Dict{String,Any}("esm"=>"0.5.0","metadata"=>Dict("name"=>"Chain"),
            "models"=>Dict{String,Any}("M"=>Dict{String,Any}("variables"=>vars,"equations"=>Any[eq])))
        f!, u0, p, _t, vmap = E.build_evaluator(doc; initial_conditions=Dict("y"=>0.0))
        du = similar(u0); f!(du, u0, p, 0.0)
        @test du[vmap["y"]] ≈ 143.0   # x=3: a4 b8 c12 d144 e143
    end
end
