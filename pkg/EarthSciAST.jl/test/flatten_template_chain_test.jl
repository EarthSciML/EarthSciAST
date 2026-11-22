# Flatten on a deep chain of expression templates, each referencing the one
# below twice (esm-spec §9.7.3 allows a chain of MAX_TEMPLATE_EXPANSION_DEPTH).
# Loaded, the chain's expansions share their subtrees: O(depth) distinct nodes,
# but as a tree the 64-deep chain below has about 2^73 nodes. Flatten's
# elementwise-application pass (esm-spec §9.6.11) walks every template
# application's expansion, visiting each shared subtree once; walked as a tree,
# flatten would never finish on this document.

using Test
using EarthSciAST

const _CHAIN_DEPTH = EarthSciAST.MAX_TEMPLATE_EXPANSION_DEPTH

_chain_ref(n) = Dict{String, Any}(
    "op" => "apply_expression_template", "args" => Any[], "name" => n,
    "bindings" => Dict{String, Any}()
)
_chain_plus(a, b) = Dict{String, Any}("op" => "+", "args" => Any[a, b])

# `shared_k = shared_{k+1} + shared_{k+1}`, the innermost an 8-level doubling
# tree of `chain` written in place. `D(chain) = shared_1 + shared_1`; with
# `observed`, also `y = shared_1 + shared_1`; with `shaped`, `chain` is declared
# over the index set `x`, so `y` applies the chain elementwise and is lifted.
function _chain_document(depth; observed = false, shaped = false)
    ts = Dict{String, Any}()
    for k in 1:(depth - 1)
        ts["shared_$k"] = Dict{String, Any}(
            "params" => Any[],
            "body" => _chain_plus(_chain_ref("shared_$(k + 1)"), _chain_ref("shared_$(k + 1)"))
        )
    end
    leaf = "chain"
    for _ in 1:8
        leaf = _chain_plus(leaf, leaf)
    end
    ts["shared_$depth"] = Dict{String, Any}("params" => Any[], "body" => leaf)
    vars = Dict{String, Any}("chain" => Dict{String, Any}("type" => "unknown", "default" => 0.0))
    top = _chain_plus(_chain_ref("shared_1"), _chain_ref("shared_1"))
    eqs = Any[Dict{String, Any}("lhs" => Dict{String, Any}("op" => "D", "args" => Any["chain"], "wrt" => "t"), "rhs" => top)]
    if observed || shaped
        vars["y"] = Dict{String, Any}("type" => "unknown")
        push!(eqs, Dict{String, Any}("lhs" => "y", "rhs" => top))
    end
    doc = Dict{String, Any}(
        "esm" => "1.0.0", "metadata" => Dict{String, Any}("name" => "template_chain"),
        "models" => Dict{String, Any}(
            "M" => Dict{String, Any}("variables" => vars, "expression_templates" => ts, "equations" => eqs)
        )
    )
    if shaped
        doc["index_sets"] = Dict{String, Any}("x" => Dict{String, Any}("kind" => "interval", "size" => 3))
        vars["chain"]["shape"] = Any["x"]
    end
    return doc
end

# The value of `e` with every read of `chain` (bare or gathered) equal to 1,
# computed once per shared node.
function _chain_value(e, memo = IdDict{Any, Float64}())
    e isa EarthSciAST.VarExpr && return e.name == "M.chain" ? 1.0 : error("unexpected read $(e.name)")
    e isa EarthSciAST.OpExpr || error("unexpected node $(e)")
    return get!(memo, e) do
        if e.op == "+"
            sum(a -> _chain_value(a, memo), e.args)
        elseif e.op == "index" && e.args[1] isa EarthSciAST.VarExpr && e.args[1].name == "M.chain"
            1.0
        else
            error("unexpected op $(e.op)")
        end
    end
end

# Distinct operator nodes reachable from `e`.
function _distinct_nodes(e, seen = IdDict{Any, Nothing}())
    e isa EarthSciAST.OpExpr || return seen
    haskey(seen, e) && return seen
    seen[e] = nothing
    EarthSciAST.foreach_child(c -> _distinct_nodes(c, seen), e)
    return seen
end

_equation(flat, name) = only(eq for eq in flat.equations if eq.lhs isa EarthSciAST.VarExpr && eq.lhs.name == name)

@testset "flatten of a deep doubly-referenced template chain" begin
    # Compile every path on a short chain first, so the bound below times only
    # the walk.
    for kw in ((;), (; observed = true), (; shaped = true))
        EarthSciAST.flatten(EarthSciAST.load_document(_chain_document(4; kw...)))
    end
    # As a tree, `shared_1 + shared_1` here is 2^(depth + 9) - 1 nodes.
    expected = 2.0^(_CHAIN_DEPTH + 8)

    @testset "an ODE right-hand side" begin
        doc = EarthSciAST.load_document(_chain_document(_CHAIN_DEPTH))
        t = @elapsed flat = EarthSciAST.flatten(doc)
        @test t < 10
        # The references survive flatten (esm-spec §9.6.4), with every template.
        eq = only(flat.equations)
        @test eq.rhs isa EarthSciAST.OpExpr && eq.rhs.op == "+"
        @test all(a -> a isa EarthSciAST.OpExpr && a.op == "apply_expression_template" && a.name == "shared_1", eq.rhs.args)
        @test length(flat.template_registry) == _CHAIN_DEPTH
    end

    @testset "an observed reading the chain" begin
        doc = EarthSciAST.load_document(_chain_document(_CHAIN_DEPTH; observed = true))
        t = @elapsed flat = EarthSciAST.flatten(doc)
        @test t < 10
        # A scalar chain applies nothing elementwise: `y` is left as written.
        rhs = _equation(flat, "M.y").rhs
        @test rhs.op == "+" && all(a -> a.op == "apply_expression_template", rhs.args)
    end

    @testset "an elementwise application, lifted" begin
        doc = EarthSciAST.load_document(_chain_document(_CHAIN_DEPTH; shaped = true))
        t = @elapsed flat = EarthSciAST.flatten(doc)
        @test t < 10
        # `y` is the per-cell `faq` over `x` of the chain's expansion, each
        # read of `chain` gathered at the cell: 2^40 of them as a tree, written
        # with the expansion's sharing.
        rhs = _equation(flat, "M.y").rhs
        @test rhs.op == "faq" && length(rhs.output_idx) == 1
        @test only(values(rhs.ranges)).from == "x"
        # The lift keeps the reference (esm-spec §9.6.11): the body is small.
        @test length(_distinct_nodes(rhs.expr_body)) < 20
        # What it denotes, read on the explicit expansion.
        rhs = _equation(EarthSciAST.expand_flattened_refs(flat), "M.y").rhs
        @test length(_distinct_nodes(rhs.expr_body)) < 100 * _CHAIN_DEPTH
        @test _chain_value(rhs.expr_body) == expected
        gathers = [n for n in keys(_distinct_nodes(rhs.expr_body)) if n.op == "index"]
        @test !isempty(gathers) && all(g -> g.args[2] == EarthSciAST.VarExpr(only(rhs.output_idx)), gathers)
    end
end
