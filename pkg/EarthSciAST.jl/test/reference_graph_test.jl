# Unit tests for src/reference_graph.jl — build-time reference resolution
# (semiring-FAQ node addressing, RFC semiring-faq-unified-ir §6.1).
#
# Covers the four acceptance criteria of the node-addressing bead:
#   1. a derived index set resolves its from_faq to a specific node;
#   2. a join factor resolves to its referenced factor;
#   3. references are edges queryable by the partition pass;
#   4. a reference cycle is detectable.

using Test
using EarthSciAST
const ESS = EarthSciAST

# minimal aggregate node dict (build explicitly; `merge` is ambiguous here
# because EarthSciAST also exports a `merge`).
function agg(; kw...)
    d = Dict{String,Any}("op" => "aggregate", "args" => Any[])
    for (k, v) in kw
        d[string(k)] = v
    end
    return d
end
eqn(lhs, rhs) = Dict{String,Any}("lhs" => lhs, "rhs" => rhs)

@testset "reference_graph" begin

    @testset "(1) from_faq resolves to a specific node" begin
        producer = agg(id = "edge_faq", output_idx = ["edge"],
                       ranges = Dict("f" => Dict("from" => "faces")))
        model = Dict{String,Any}(
            "index_sets" => Dict(
                "faces" => Dict("kind" => "interval", "size" => 8),
                "edges" => Dict("kind" => "derived", "from_faq" => "edge_faq")),
            "equations" => [eqn(producer, 0)])
        g = build_reference_graph(model, "M")

        ff = ESS.edges_of_kind(g, ESS.REF_EDGE_FROM_FAQ)
        @test length(ff) == 1
        @test ff[1].source == "index_set:edges"
        @test ff[1].target == "node:edge_faq"
        @test g.vertices["node:edge_faq"].node_id == "edge_faq"
        @test g.vertices["node:edge_faq"].op == "aggregate"
        # queryable: edges depends on the node.
        @test "node:edge_faq" in ESS.dependencies(g, "index_set:edges")
    end

    @testset "from_faq unknown node id errors" begin
        model = Dict{String,Any}(
            "index_sets" => Dict("edges" => Dict("kind" => "derived", "from_faq" => "missing")),
            "equations" => [eqn(agg(id = "present"), 0)])
        err = try
            build_reference_graph(model, "M")
            nothing
        catch e
            e
        end
        @test err isa ReferenceResolutionError
        @test err.code == ESS.E_REF_UNKNOWN_FAQ_NODE
    end

    @testset "duplicate node id errors" begin
        model = Dict{String,Any}("equations" => [eqn(agg(id = "dup"), 0), eqn(agg(id = "dup"), 0)])
        err = try
            build_reference_graph(model, "M")
            nothing
        catch e
            e
        end
        @test err isa ReferenceResolutionError
        @test err.code == ESS.E_REF_DUPLICATE_NODE_ID
    end

    @testset "ranges[*].from resolves to an index set" begin
        node = agg(output_idx = ["i"], ranges = Dict("i" => Dict("from" => "cells")))
        model = Dict{String,Any}(
            "index_sets" => Dict("cells" => Dict("kind" => "interval", "size" => 4)),
            "equations" => [eqn(node, 0)])
        g = build_reference_graph(model, "M")
        rf = ESS.edges_of_kind(g, ESS.REF_EDGE_RANGE_FROM)
        @test length(rf) == 1
        @test rf[1].target == "index_set:cells"
        @test "index_set:cells" in ESS.dependencies(g, rf[1].source)
    end

    @testset "ranges[*].from undeclared index set errors" begin
        node = agg(output_idx = ["i"], ranges = Dict("i" => Dict("from" => "nope")))
        model = Dict{String,Any}(
            "index_sets" => Dict("cells" => Dict("kind" => "interval", "size" => 4)),
            "equations" => [eqn(node, 0)])
        err = try
            build_reference_graph(model, "M")
            nothing
        catch e
            e
        end
        @test err isa ReferenceResolutionError
        @test err.code == ESS.E_REF_UNDECLARED_INDEX_SET
    end

    @testset "dense tuple ranges make no edge (back-compat)" begin
        node = agg(output_idx = ["i"], ranges = Dict("i" => [1, 64]))
        g = build_reference_graph(Dict{String,Any}("equations" => [eqn(node, 0)]), "M")
        @test isempty(g.edges)
    end

    @testset "(2) a join factor resolves to its referenced factor" begin
        node = agg(output_idx = ["county"],
                   ranges = Dict("county" => Dict("from" => "county"),
                                 "src" => Dict("from" => "sourceType")),
                   join = [Dict("on" => [["activity", "sourceType"]])],
                   args = ["activity", "base_rate"])
        model = Dict{String,Any}(
            "index_sets" => Dict(
                "county" => Dict("kind" => "categorical", "members" => ["A", "B"]),
                "sourceType" => Dict("kind" => "categorical", "members" => ["x"])),
            "equations" => [eqn(node, 0)])
        g = build_reference_graph(model, "M")
        jf = ESS.edges_of_kind(g, ESS.REF_EDGE_JOIN_FACTOR)
        @test length(jf) == 1
        @test jf[1].target == "factor:activity"
        @test g.vertices["factor:activity"].kind == ESS.REF_VERTEX_FACTOR
        @test "factor:activity" in ESS.dependencies(g, jf[1].source)
    end

    @testset "join factor resolves to a range key (RFC §7.2 spelling)" begin
        node = agg(output_idx = ["county"],
                   ranges = Dict("county" => Dict("from" => "county"),
                                 "src" => Dict("from" => "sourceType")),
                   join = [Dict("on" => [["src", "sourceType"]])],
                   args = ["activity"])
        model = Dict{String,Any}(
            "index_sets" => Dict(
                "county" => Dict("kind" => "categorical", "members" => ["A"]),
                "sourceType" => Dict("kind" => "categorical", "members" => ["x"])),
            "equations" => [eqn(node, 0)])
        g = build_reference_graph(model, "M")
        jf = ESS.edges_of_kind(g, ESS.REF_EDGE_JOIN_FACTOR)
        @test length(jf) == 1
        @test jf[1].target == "factor:src"
    end

    @testset "join factor unresolved errors" begin
        node = agg(output_idx = ["i"], ranges = Dict("i" => Dict("from" => "cells")),
                   join = [Dict("on" => [["ghost", "col"]])], args = ["activity"])
        model = Dict{String,Any}(
            "index_sets" => Dict("cells" => Dict("kind" => "interval", "size" => 2)),
            "equations" => [eqn(node, 0)])
        err = try
            build_reference_graph(model, "M")
            nothing
        catch e
            e
        end
        @test err isa ReferenceResolutionError
        @test err.code == ESS.E_REF_UNRESOLVED_JOIN_FACTOR
    end

    @testset "(3) edges are queryable by the partition pass" begin
        producer = agg(id = "edge_faq", output_idx = ["edge"],
                       ranges = Dict("f" => Dict("from" => "faces")))
        consumer = agg(output_idx = ["e"], ranges = Dict("e" => Dict("from" => "edges")))
        model = Dict{String,Any}(
            "index_sets" => Dict(
                "faces" => Dict("kind" => "interval", "size" => 8),
                "edges" => Dict("kind" => "derived", "from_faq" => "edge_faq")),
            "equations" => [eqn(producer, 0), eqn(consumer, 0)])
        g = build_reference_graph(model, "M")
        order = ESS.topological_order(g)        # raises on cycle; here acyclic
        @test length(order) == length(g.vertices)
        pos = Dict(k => i for (i, k) in enumerate(order))
        # a dependency is emitted before its dependent
        @test pos["node:edge_faq"] < pos["index_set:edges"]
        @test isempty(ESS.dependencies(g, "index_set:faces"))
    end

    @testset "(4) a reference cycle is detectable" begin
        producer = agg(id = "edge_faq", output_idx = ["edge"],
                       ranges = Dict("e" => Dict("from" => "edges")))
        model = Dict{String,Any}(
            "index_sets" => Dict("edges" => Dict("kind" => "derived", "from_faq" => "edge_faq")),
            "equations" => [eqn(producer, 0)])
        g = build_reference_graph(model, "M")
        cyc = ESS.detect_cycle(g)
        @test cyc !== nothing
        @test cyc[1] == cyc[end]                       # closed path
        @test "node:edge_faq" in cyc
        @test "index_set:edges" in cyc
        # resolve_references surfaces it eagerly as E_REF_CYCLE.
        err = try
            resolve_references(Dict{String,Any}("models" => Dict("M" => model)))
            nothing
        catch e
            e
        end
        @test err isa ReferenceResolutionError
        @test err.code == ESS.E_REF_CYCLE
    end

    @testset "additive: no references -> empty graph" begin
        model = Dict{String,Any}(
            "variables" => Dict("u" => Dict("type" => "state")),
            "equations" => [eqn(Dict{String,Any}("op" => "D", "args" => ["u"], "wrt" => "t"), -1)])
        g = build_reference_graph(model, "M")
        @test isempty(g.edges)
        @test ESS.detect_cycle(g) === nothing
    end

    @testset "resolve_references across models" begin
        m1 = Dict{String,Any}(
            "index_sets" => Dict("cells" => Dict("kind" => "interval", "size" => 4)),
            "equations" => [eqn(agg(output_idx = ["i"], ranges = Dict("i" => Dict("from" => "cells"))), 0)])
        m2 = Dict{String,Any}("equations" =>
            [eqn(Dict{String,Any}("op" => "D", "args" => ["u"], "wrt" => "t"), 0)])
        graphs = resolve_references(Dict{String,Any}("models" => Dict("A" => m1, "B" => m2)))
        @test Set(keys(graphs)) == Set(["A", "B"])
        @test length(ESS.edges_of_kind(graphs["A"], ESS.REF_EDGE_RANGE_FROM)) == 1
        @test isempty(graphs["B"].edges)
    end

end
