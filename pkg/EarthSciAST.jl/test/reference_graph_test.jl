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
using JSON3
const ESS = EarthSciAST
include("testutils.jl")  # TESTUTILS_REPO_ROOT

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

    # The four binder classes an `on` key column is polymorphic over
    # (esm-spec §4.9.5 / CONFORMANCE_SPEC §5.5.6), and the NEGATIVE guard on the
    # widening: consulting the variable and index-set registries must not
    # degrade into "accept any string".
    #
    # The document declares a variable (`bin`), an index set (`cells`), a bound
    # range (`i`) and a string factor arg (`w`), so every registry the check
    # consults is non-empty and the check is genuinely reached.
    @testset "join binder classes (esm-spec §4.9.5)" begin
        four_class = on -> Dict{String,Any}(
            "index_sets" => Dict("cells" => Dict("kind" => "interval", "size" => 4)),
            "variables" => Dict("bin" => Dict("type" => "parameter"),
                                "w" => Dict("type" => "parameter")),
            "equations" => [eqn(agg(id = "j", args = ["w"], output_idx = String[],
                                    ranges = Dict("i" => Dict("from" => "cells")),
                                    join = [Dict("on" => [on])]), 0)])

        # Each class resolves, on BOTH key columns.
        for on in (["i", "i"],          # 1. node-local binder (ranges key)
                   ["w", "w"],          # 2. node-local string factor arg
                   ["bin", "bin"],      # 3. declared model variable — defect #3
                   ["cells", "cells"])  # 4. document-scoped index set
            @test build_reference_graph(four_class(on), "M") isa ESS.ReferenceGraph
        end

        # A name in none of the four is STILL an error, on either column. The
        # right column was never validated before this fix.
        for on in (["no_such_name", "bin"], ["bin", "no_such_name"])
            err = try
                build_reference_graph(four_class(on), "M")
                nothing
            catch e
                e
            end
            @test err isa ReferenceResolutionError
            @test err.code == ESS.E_REF_UNRESOLVED_JOIN_FACTOR
            @test occursin("no_such_name", err.message)
        end
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
            "variables" => Dict("u" => Dict("type" => "unknown")),
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

    # ---------------------------------------------------------------------
    # API_SPEC.md §8 item 17 — the DOCUMENT-scoped `index_sets` registry.
    #
    # Every other test in this file writes `index_sets` INSIDE the model,
    # which is the pre-0.8.0 shape. esm 1.0.0 puts the registry at the top
    # level of the document (`esm-schema.json` declares `index_sets` at
    # `/properties/index_sets` and nowhere else), and this pass read only the
    # model key — so on a real 1.0.0 document every `ranges[*].from` target
    # looked undeclared and the pass THREW `undeclared_index_set` where
    # Python, Rust and Go all built the graph. The whole existing suite passed
    # throughout, because none of it used the 1.0.0 shape.
    # ---------------------------------------------------------------------
    @testset "index_sets at DOCUMENT scope (esm 1.0.0 flat shape)" begin
        # One model, no model-local `index_sets`; the registry is a sibling of
        # `models`, exactly as a 1.0.0 document writes it.
        producer = agg(id = "edge_faq", output_idx = ["edge"],
                       ranges = Dict("f" => Dict("from" => "faces")))
        consumer = agg(output_idx = ["e"], ranges = Dict("e" => Dict("from" => "edges")))
        model = Dict{String,Any}("equations" => [eqn(producer, 0), eqn(consumer, 1)])
        document = Dict{String,Any}(
            "esm" => "1.0.0",
            "index_sets" => Dict(
                "faces" => Dict("kind" => "interval", "size" => 8),
                "edges" => Dict("kind" => "derived", "from_faq" => "edge_faq")),
            "models" => Dict("M" => model))

        # (a) The pre-fix read: no registry threaded, no model-local key, so
        #     the FIRST `ranges[*].from` is undeclared and the build throws.
        #     This is exactly what `resolve_references` used to do.
        err = try
            build_reference_graph(model, "M")
            nothing
        catch e
            e
        end
        @test err isa ReferenceResolutionError
        @test err.code == ESS.E_REF_UNDECLARED_INDEX_SET

        # (b) With the document registry threaded — the fixed behaviour — the
        #     graph builds, both index sets are vertices, both `range_from`
        #     edges exist, and the derived set resolves its `from_faq`.
        g = build_reference_graph(model, "M", document["index_sets"])
        @test haskey(g.vertices, "index_set:faces")
        @test haskey(g.vertices, "index_set:edges")
        @test length(ESS.edges_of_kind(g, ESS.REF_EDGE_RANGE_FROM)) == 2
        ff = ESS.edges_of_kind(g, ESS.REF_EDGE_FROM_FAQ)
        @test length(ff) == 1
        @test ff[1].source == "index_set:edges"
        @test ff[1].target == "node:edge_faq"

        # (c) `resolve_references(document)` threads it for every model, so the
        #     document-level entry point agrees with (b) rather than with (a).
        graphs = resolve_references(document)
        @test Set(keys(graphs)) == Set(["M"])
        @test length(ESS.edges_of_kind(graphs["M"], ESS.REF_EDGE_RANGE_FROM)) == 2
        @test length(ESS.edges_of_kind(graphs["M"], ESS.REF_EDGE_FROM_FAQ)) == 1

        # (d) The registry is shared by EVERY model, not re-declared per model
        #     — the point of hoisting it to document scope.
        m2 = Dict{String,Any}("equations" =>
            [eqn(agg(output_idx = ["f"], ranges = Dict("f" => Dict("from" => "faces"))), 0)])
        doc2 = Dict{String,Any}(
            "esm" => "1.0.0",
            "index_sets" => Dict("faces" => Dict("kind" => "interval", "size" => 8)),
            "models" => Dict("A" => m2, "B" => deepcopy(m2)))
        graphs2 = resolve_references(doc2)
        @test length(ESS.edges_of_kind(graphs2["A"], ESS.REF_EDGE_RANGE_FROM)) == 1
        @test length(ESS.edges_of_kind(graphs2["B"], ESS.REF_EDGE_RANGE_FROM)) == 1
    end

    @testset "model-nested index_sets still resolve (pre-0.8.0 fallback)" begin
        # Omitting the trailing argument keeps the old behaviour for a caller
        # holding only a raw model dict — this is what every test above relies
        # on, and what Python's `index_sets=None` fallback does.
        model = Dict{String,Any}(
            "index_sets" => Dict("cells" => Dict("kind" => "interval", "size" => 4)),
            "equations" => [eqn(agg(output_idx = ["i"],
                                    ranges = Dict("i" => Dict("from" => "cells"))), 0)])
        g = build_reference_graph(model, "M")
        @test length(ESS.edges_of_kind(g, ESS.REF_EDGE_RANGE_FROM)) == 1

        # A model-local entry wins a key collision with the document registry
        # (the Rust/Go merge rule); no 1.0.0 document can produce this, since
        # the schema allows `index_sets` only at document scope.
        g2 = build_reference_graph(model, "M",
            Dict{String,Any}("cells" => Dict("kind" => "interval", "size" => 99),
                             "other" => Dict("kind" => "interval", "size" => 2)))
        @test haskey(g2.vertices, "index_set:cells")
        @test haskey(g2.vertices, "index_set:other")
        @test length(ESS.edges_of_kind(g2, ESS.REF_EDGE_RANGE_FROM)) == 1
    end


    # --- from_faq resolves at DOCUMENT scope (esm-spec.md §9.7.5) -----------
    #
    # `index_sets` is a document-scoped registry, so a `kind:"derived"` entry is
    # visible to every model and its producing node may live in ANY of them.
    # Every binding used to resolve `from_faq` against one model's nodes, which
    # made the cross-model shape unresolvable. The consequence: node ids are
    # unique per DOCUMENT, not per model.
    @testset "from_faq resolves at document scope" begin
        producer = Dict{String,Any}("equations" => [eqn(
            agg(id = "edge_faq", output_idx = ["edge"],
                ranges = Dict("f" => Dict("from" => "faces"))), 0)])
        consumer = Dict{String,Any}("equations" => [eqn(
            agg(output_idx = String[], ranges = Dict("e" => Dict("from" => "edges"))), 0)])
        doc = Dict{String,Any}(
            "index_sets" => Dict(
                "faces" => Dict("kind" => "interval", "size" => 8),
                "edges" => Dict("kind" => "derived", "from_faq" => "edge_faq")),
            "models" => Dict("Consumer" => consumer, "Producer" => producer))
        graphs = resolve_references(doc)

        # BOTH graphs carry the edge: the registry entry is document-scoped, so
        # every model sees the same derived set and the same producer.
        for name in ("Consumer", "Producer")
            ff = ESS.edges_of_kind(graphs[name], ESS.REF_EDGE_FROM_FAQ)
            @test length(ff) == 1
            @test ff[1].source == "index_set:edges"
            @test ff[1].target == "node:edge_faq"
        end
        # The consumer's graph gained a real vertex for the foreign producer, so
        # the partition pass can walk index_set -> node across the boundary.
        v = graphs["Consumer"].vertices["node:edge_faq"]
        @test v.node_id == "edge_faq"
        @test v.path == "models/Producer/equations/0/lhs"

        # Widening the scope does not weaken the error.
        bad = Dict{String,Any}(
            "index_sets" => Dict("edges" => Dict("kind" => "derived", "from_faq" => "nowhere")),
            "models" => Dict(
                "A" => Dict{String,Any}("equations" => [eqn(agg(id = "here"), 0)]),
                "B" => Dict{String,Any}("equations" => [eqn(agg(id = "there"), 0)])))
        err = try
            resolve_references(bad); nothing
        catch e
            e
        end
        @test err isa ESS.ReferenceResolutionError
        @test err.code == ESS.E_REF_UNKNOWN_FAQ_NODE
    end

    @testset "a node id duplicated across two models is an error" begin
        # Legal before the §9.7.5 ruling, a load-time error now: one
        # document-wide id namespace cannot hold two.
        doc = Dict{String,Any}("models" => Dict(
            "A" => Dict{String,Any}("equations" => [eqn(agg(id = "dup"), 0)]),
            "B" => Dict{String,Any}("equations" => [eqn(agg(id = "dup"), 0)])))
        err = try
            resolve_references(doc); nothing
        catch e
            e
        end
        @test err isa ESS.ReferenceResolutionError
        @test err.code == ESS.E_REF_DUPLICATE_NODE_ID
        # Model-qualified on both sides, so the cross-model clash is visible.
        @test occursin("models/A/", err.message)
        @test occursin("models/B/", err.message)
    end

    @testset "the shared cross-model corpus fixture resolves" begin
        path = joinpath(TESTUTILS_REPO_ROOT, "tests", "valid", "aggregate",
                        "cross_model_from_faq.esm")
        doc = JSON3.read(read(path, String), Dict{String,Any})
        graphs = resolve_references(doc)
        @test Set(keys(graphs)) == Set(["EdgeProducer", "FluxConsumer"])
        ff = ESS.edges_of_kind(graphs["FluxConsumer"], ESS.REF_EDGE_FROM_FAQ)
        @test length(ff) == 1
        @test ff[1].source == "index_set:edges"
        @test ff[1].target == "node:edge_enum"
    end

    # CORPUS_DEFECTS #2 AND #3 are both fixed on this fixture, which was the
    # SECOND instance of #3 — masked until #2 landed.
    #   * #2: `rg_candidate_pairs.from_faq` names `rg_candidate_set`, which lives
    #     in OceanDynamics while the registry entry is document-scoped.
    #   * #3: that producing node's `join.on == [["rg_src_bin","rg_tgt_bin"]]`
    #     names declared model VARIABLES — per-cell value-invention bin buffers
    #     written by equations 0 and 1 — rather than node-local binders. Both
    #     columns now resolve through the variable class of `_join_binder_class`.
    @testset "wildfire fixture resolves fully" begin
        path = joinpath(TESTUTILS_REPO_ROOT, "tests", "valid",
                        "wildfire_atmosphere_ocean.esm")
        doc = JSON3.read(read(path, String), Dict{String,Any})
        graphs = resolve_references(doc)
        ocean = graphs["OceanDynamics"]
        targets = Set(e.target for e in ESS.edges_of_kind(ocean, ESS.REF_EDGE_JOIN_FACTOR))
        @test "factor:rg_src_bin" in targets
    end

    # The other instance of CORPUS_DEFECTS #3: six aggregates in
    # ConservativeRegridAssembly join on [["src_bin","tgt_bin"]], both declared
    # model variables shaped over the join's range index sets.
    @testset "conservative_regrid_assembly resolves" begin
        path = joinpath(TESTUTILS_REPO_ROOT, "tests", "valid", "geometry",
                        "conservative_regrid_assembly.esm")
        doc = JSON3.read(read(path, String), Dict{String,Any})
        @test resolve_references(doc) isa AbstractDict
    end

    # The corpus-wide sweep: EVERY fixture under tests/valid resolves. This is
    # the acceptance test for corpus defect #3 and the Julia counterpart of the
    # Python / TypeScript / Go corpus sweeps.
    @testset "every shared valid fixture resolves" begin
        validdir = joinpath(TESTUTILS_REPO_ROOT, "tests", "valid")
        files = String[]
        for (root, _, fs) in walkdir(validdir), f in fs
            endswith(f, ".esm") && push!(files, joinpath(root, f))
        end
        sort!(files)
        @test length(files) > 50
        failures = String[]
        for f in files
            doc = JSON3.read(read(f, String), Dict{String,Any})
            try
                resolve_references(doc)
            catch e
                push!(failures, string(relpath(f, validdir), ": ",
                                       e isa ESS.ReferenceResolutionError ? e.code : string(typeof(e))))
            end
        end
        @test failures == String[]
    end

end
