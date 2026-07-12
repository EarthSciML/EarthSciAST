using Test
using EarthSciAST
import JSON3

include("testutils.jl")  # TESTUTILS_REPO_ROOT

# Collision-safe alias for the Cadence submodule (an unprefixed `const C`
# would pollute the shared Main namespace under runtests.jl).
const _Cadence = EarthSciAST.Cadence

# The dependency-partition (cadence) pass — CONFORMANCE_SPEC.md §5.7, the
# normative form of RFC `semiring-faq-unified-ir` §6.1 (bead ess-my4.3.7).
# These tests assert the Julia pass independently re-derives the same contract
# the cross-binding golden (tests/conformance/cadence/manifest.json) pins:
# the class of every annotated node, the materialization-point set, the
# emptiness of the hot tree / per-event handler, and the byte-identical
# CONST-folded buffers — plus the three checked guards (§5.7.6) and the
# negative controls that must REJECT non-conforming input. It mirrors the
# checks in scripts/run-cadence-conformance.py --self-test.

const CADENCE_MANIFEST = joinpath(TESTUTILS_REPO_ROOT, "tests", "conformance", "cadence", "manifest.json")

@testset "Cadence-partition pass (CONFORMANCE_SPEC §5.7 / RFC §6.1)" begin

    manifest = _Cadence.to_native(JSON3.read(read(CADENCE_MANIFEST, String)))

    @testset "golden agreement — $(fx["id"])" for fx in manifest["fixtures"]
        model = _Cadence.load_model_json(joinpath(TESTUTILS_REPO_ROOT, fx["fixture"]), fx["model"])
        r = _Cadence.partition_model(model)

        # (a) class summary — annotated nodes by DERIVED class == golden.
        for (cls, n) in fx["class_summary"]
            @test r.class_summary[cls] == n
        end
        # no expect_cadence disagreement (guard 3) on a valid fixture
        @test isempty(r.problems)

        # (b) materialization-point threshold multiset == golden (all points).
        got_thr = sort([p["threshold"] for p in r.materialization_points])
        want_thr = sort([m["threshold"] for m in fx["materialization_points"]])
        @test got_thr == want_thr

        # hot-tree / per-event-handler emptiness == golden.
        @test r.hot_tree_empty == fx["hot_tree_empty"]
        @test r.event_handler_empty == fx["event_handler_empty"]

        # (c) CONST-folded buffers serialize byte-for-byte to the golden.
        cf = get(fx, "const_fold", Dict{String,Any}())
        inputs = get(cf, "inputs", Dict{String,Any}())
        for (label, spec) in get(cf, "expected", Dict{String,Any}())
            bytes = _Cadence.canonical_serialize(_Cadence.compute_fold(label, spec, inputs))
            @test bytes == spec["serialized"]
        end

        # (d) guards hold on a valid fixture (no false positives).
        @test (_Cadence.run_guards(model); true)
    end

    @testset "gather rule splits the stencil (§5.7.3)" begin
        model = _Cadence.load_model_json(
            joinpath(TESTUTILS_REPO_ROOT, "tests", "valid", "cadence", "mixed_stencil.esm"),
            "MixedStencilDiffusion")
        # index(u, index(nbr,i,k)): outer value load is CONTINUOUS, while the
        # inner topology selection index(nbr,i,k) is CONST — classed
        # independently of the array.
        inner = Dict{String,Any}("op" => "index", "args" => Any["nbr", "i", "k"])
        outer = Dict{String,Any}("op" => "index", "args" => Any["u", inner])
        @test _Cadence.classify(inner, model) == "const"
        @test _Cadence.classify(outer, model) == "continuous"
        # Kdiff (discrete variable) gather is DISCRETE; a state load is CONTINUOUS.
        @test _Cadence.classify(Dict{String,Any}("op" => "index", "args" => Any["Kdiff", "i"]), model) == "discrete"
        @test _Cadence.classify(Dict{String,Any}("op" => "index", "args" => Any["u", "i"]), model) == "continuous"
        # the analytic continuous-t forcing stays CONTINUOUS, not DISCRETE.
        @test _Cadence.classify(Dict{String,Any}("op" => "*", "args" => Any["omega", "t"]),
            Dict{String,Any}("variables" => Dict{String,Any}("omega" => Dict{String,Any}("type" => "parameter")))) == "continuous"
    end

    @testset "loader-seeded cadence: temporal -> discrete, no temporal -> const (§5.7.2)" begin
        # A discrete variable fed by a `data_ingest` refresh resolves through its
        # source loader's `temporal` block (RFC pure-io-data-loaders §4.6): the
        # SAME declaration seeds DISCRETE under a temporal loader and CONST (folds
        # at bind) under a non-temporal one.
        variables = Dict{String,Any}(
            "c" => Dict{String,Any}("type" => "state", "shape" => Any["cells"]),
            "bc" => Dict{String,Any}("type" => "discrete", "shape" => Any["cells"],
                "refresh" => Dict{String,Any}("kind" => "data_ingest", "source" => "bc_loader")))
        bc = Dict{String,Any}("op" => "index", "args" => Any["bc", "i"])

        # Loader WITH temporal -> DISCRETE (refreshes on each ingest).
        with_temporal = Dict{String,Any}("variables" => variables,
            "data_loaders" => Dict{String,Any}("bc_loader" =>
                Dict{String,Any}("kind" => "grid", "temporal" => Dict{String,Any}("frequency" => "PT6H"))))
        @test _Cadence.classify(bc, with_temporal) == "discrete"

        # Loader WITHOUT temporal -> CONST (non-time-varying, folds at bind).
        no_temporal = Dict{String,Any}("variables" => variables,
            "data_loaders" => Dict{String,Any}("bc_loader" => Dict{String,Any}("kind" => "static")))
        @test _Cadence.classify(bc, no_temporal) == "const"

        # No loaders attached / unresolvable source -> keeps the declared discrete seed.
        @test _Cadence.classify(bc, Dict{String,Any}("variables" => variables)) == "discrete"

        # load_model_json attaches the document's top-level data_loaders so the
        # refinement can resolve the source loader.
        m = _Cadence.load_model_json(
            joinpath(TESTUTILS_REPO_ROOT, "tests", "valid", "cadence", "loader_temporal_seed.esm"),
            "LoaderTemporalSeed")
        @test haskey(m, "data_loaders") && haskey(m["data_loaders"], "bc_loader")
    end

    # --- Negative controls: the guards must REJECT non-conforming input. ------

    @testset "neg: wrong expect_cadence is flagged (guard 3)" begin
        # A CONST gather mis-annotated as CONTINUOUS must be caught.
        model = Dict{String,Any}("variables" => Dict{String,Any}("p" => Dict{String,Any}("type" => "parameter")))
        bad = Dict{String,Any}("op" => "index", "args" => Any["p", "i"],
            "expect_cadence" => "continuous")
        problems = String[]
        _Cadence.check_expect_cadence!(bad, model, problems)
        @test !isempty(problems)
    end

    @testset "neg: continuous relational rejected (guard 2)" begin
        # A distinct aggregate whose key reads state u classifies CONTINUOUS.
        model = Dict{String,Any}(
            "variables" => Dict{String,Any}("u" => Dict{String,Any}("type" => "state")),
            "index_sets" => Dict{String,Any}("faces" => Dict{String,Any}("kind" => "interval", "size" => 4)))
        rhs = Dict{String,Any}(
            "op" => "aggregate", "distinct" => true, "semiring" => "bool_and_or",
            "output_idx" => Any["e"], "ranges" => Dict{String,Any}("f" => Dict{String,Any}("from" => "faces")),
            "key" => Dict{String,Any}("op" => "skolem", "label" => "edge",
                "args" => Any[Dict{String,Any}("op" => "index", "args" => Any["u", "f"])]),
            "expr" => Dict{String,Any}("op" => "true", "args" => Any[]))
        @test _Cadence.classify(rhs, model) == "continuous"
        @test_throws _Cadence.CadenceError _Cadence.assert_no_continuous_relational(rhs, model)
    end

    @testset "neg: continuous relational FIXTURE rejected (guard 2)" begin
        # The shared invalid fixture tests/invalid/aggregate/continuous_relational_node.esm
        # — SCHEMA-VALID (Go/TS accept it, marked resolver_only) but rejected by the
        # partition guard. The same fixture is rejected by the Rust and Python
        # siblings, so all three evaluators agree (bead ess-my4.3.11). In Julia the
        # guard lives in run_guards (not partition_model).
        fixture = joinpath(TESTUTILS_REPO_ROOT, "tests", "invalid", "aggregate", "continuous_relational_node.esm")
        model = _Cadence.load_model_json(fixture, "ContinuousRelationalNode")
        @test_throws _Cadence.CadenceError _Cadence.run_guards(model)
    end

    @testset "neg: from_faq cycle rejected (guard 1)" begin
        cyclic = Dict{String,Any}(
            "variables" => Dict{String,Any}(),
            "index_sets" => Dict{String,Any}(
                "setA" => Dict{String,Any}("kind" => "derived", "from_faq" => "nodeA"),
                "setB" => Dict{String,Any}("kind" => "derived", "from_faq" => "nodeB")),
            "equations" => Any[
                Dict{String,Any}("lhs" => Dict{String,Any}("op" => "index", "args" => Any["a", "x"]),
                    "rhs" => Dict{String,Any}("op" => "aggregate", "id" => "nodeA", "distinct" => true,
                        "semiring" => "bool_and_or", "output_idx" => Any["x"],
                        "ranges" => Dict{String,Any}("y" => Dict{String,Any}("from" => "setB")),
                        "expr" => Dict{String,Any}("op" => "true", "args" => Any[]))),
                Dict{String,Any}("lhs" => Dict{String,Any}("op" => "index", "args" => Any["b", "x"]),
                    "rhs" => Dict{String,Any}("op" => "aggregate", "id" => "nodeB", "distinct" => true,
                        "semiring" => "bool_and_or", "output_idx" => Any["x"],
                        "ranges" => Dict{String,Any}("y" => Dict{String,Any}("from" => "setA")),
                        "expr" => Dict{String,Any}("op" => "true", "args" => Any[])))])
        @test_throws _Cadence.CadenceError _Cadence.assert_acyclic_index_sets(cyclic)
    end

    @testset "neg: float topology key rejected (§5.5 rule 1)" begin
        @test_throws _Cadence.CadenceError _Cadence.fold_edge_enumeration(Any[Any[1.5]], Any[Any[2]], "undirected")
    end
end
