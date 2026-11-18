# The cadence partition (CONFORMANCE_SPEC.md §5.7): the package's classifier
# (src/cadence.jl) and the conformance adapter's partition summary and
# CONST-fold kernels re-derive what the cross-binding golden
# (tests/conformance/cadence/manifest.json) pins: the class of every annotated
# node, the materialization-point set, the emptiness of the hot tree and the
# per-event handler, and the CONST-folded buffers byte for byte; plus the three
# checked guards (§5.7.6) and the negative controls that must refuse
# non-conforming input. It mirrors scripts/run-cadence-conformance.py --self-test.
using Test
using EarthSciAST
using EarthSciAST: CadenceConst, CadenceDiscrete, CadenceContinuous, cadence_class,
    cadence_seeds, check_expect_cadence, continuous_relational_nodes,
    derived_index_set_cycle, observed_definitions, expression_from_json, coerce_esm_file
import JSON3

include("testutils.jl")

# The partition summary and the CONST-fold kernels live in the conformance
# adapter; its `PROGRAM_FILE` guard keeps the command-line entry from running.
include(joinpath(@__DIR__, "..", "scripts", "cadence_adapter.jl"))
const Pass = CadenceConformanceAdapter

cadence_fixture(name) = joinpath(TESTUTILS_REPO_ROOT, "tests", "valid", "cadence", name)

# A typed document from a native `Dict`, without validation, for the
# hand-built negative controls.
typed(doc) = coerce_esm_file(doc)
seeds_of(file, name = "M") = cadence_seeds(file.models[name]; data_sources = file.data_sources)
jexpr(d) = expression_from_json(d)
# A `distinct` relational `faq` over `ranges`, with `key` and `id` when given.
function jproducer(ranges; key = nothing, id = nothing)
    d = jfaq(jop("true"), ["x"], ranges; semiring = "bool_and_or")
    d["distinct"] = true
    key === nothing || (d["key"] = key)
    id === nothing || (d["id"] = id)
    return d
end

@testset "Cadence partition (CONFORMANCE_SPEC §5.7)" begin

    manifest = Pass.to_native(
        JSON3.read(read(joinpath(TESTUTILS_REPO_ROOT, "tests", "conformance", "cadence", "manifest.json"), String))
    )

    @testset "golden agreement — $(fx["id"])" for fx in manifest["fixtures"]
        p = Pass.load_partition(joinpath(TESTUTILS_REPO_ROOT, fx["fixture"]), fx["model"])
        r = Pass.partition_model(p)

        # (a) class summary: annotated nodes by derived class.
        for (cls, n) in fx["class_summary"]
            @test r.class_summary[cls] == n
        end
        # no expect_cadence disagreement (guard 3) on a valid fixture
        @test isempty(r.problems)

        # (b) the materialization-point threshold multiset (all points).
        got_thr = sort([x["threshold"] for x in r.materialization_points])
        want_thr = sort([m["threshold"] for m in fx["materialization_points"]])
        @test got_thr == want_thr

        # hot-tree / per-event-handler emptiness.
        @test r.hot_tree_empty == fx["hot_tree_empty"]
        @test r.event_handler_empty == fx["event_handler_empty"]

        # (c) CONST-folded buffers serialize byte for byte to the golden.
        cf = get(fx, "const_fold", Dict{String, Any}())
        inputs = get(cf, "inputs", Dict{String, Any}())
        for (label, spec) in get(cf, "expected", Dict{String, Any}())
            bytes = Pass.canonical_serialize(Pass.compute_fold(label, spec, inputs))
            @test bytes == spec["serialized"]
        end

        # (d) the guards hold on a valid fixture (no false positives).
        @test (Pass.run_guards(p); true)
    end

    @testset "gather rule splits the stencil (§5.7.3)" begin
        p = Pass.load_partition(cadence_fixture("mixed_stencil.esm"), "MixedStencilDiffusion")
        # index(u, index(nbr,i,k)): the outer value load is continuous, the inner
        # topology selection index(nbr,i,k) const, classed independently of the
        # array.
        @test cadence_class(jexpr(jidx("nbr", "i", "k")), p.seeds) === CadenceConst
        @test cadence_class(jexpr(jidx("u", jidx("nbr", "i", "k"))), p.seeds) === CadenceContinuous
        # A discrete parameter's gather is discrete; a state load continuous.
        @test cadence_class(jexpr(jidx("Kdiff", "i")), p.seeds) === CadenceDiscrete
        @test cadence_class(jexpr(jidx("u", "i")), p.seeds) === CadenceContinuous
        # An analytic forcing in `t` is continuous, not discrete.
        omega = typed(jdoc(Dict("omega" => Dict("type" => "parameter")), Any[]))
        @test cadence_class(jexpr(jop("*", "omega", "t")), seeds_of(omega)) === CadenceContinuous
        # A renamed independent variable is the continuous one; `t` is then an
        # ordinary name.
        renamed = cadence_seeds(omega.models["M"]; independent_variable = "s")
        @test cadence_class(jexpr(jop("*", "omega", "s")), renamed) === CadenceContinuous
        @test cadence_class(jexpr(jop("*", "omega", "t")), renamed) === CadenceConst
    end

    @testset "source-seeded cadence: temporal -> discrete, no temporal -> const (§5.7.2)" begin
        # A parameter fed by a `data` update resolves through its source's
        # `temporal` block: the same declaration seeds discrete under a temporal
        # source and const (folds at bind) under a non-temporal one.
        path = cadence_fixture("loader_temporal_seed.esm")
        bc = jexpr(jidx("bc", "i"))

        with_temporal = load_path(path)
        @test haskey(with_temporal.data_sources, "bc_loader")
        @test cadence_class(bc, seeds_of(with_temporal, "LoaderTemporalSeed")) === CadenceDiscrete

        doc = JSON3.read(read(path, String), Dict{String, Any})
        delete!(doc["data_sources"]["bc_loader"], "temporal")
        @test cadence_class(bc, seeds_of(typed(doc), "LoaderTemporalSeed")) === CadenceConst

        # No source table to resolve against keeps the discrete seed.
        @test cadence_class(bc, cadence_seeds(with_temporal.models["LoaderTemporalSeed"])) ===
            CadenceDiscrete
    end

    @testset "observed leaf seeds from its defining equation's RHS (§5.7.2)" begin
        # A state-free observed folds (seeding every unknown continuous would
        # stop it), one reading the state does not (seeding an observed const
        # would fold a per-step value), one reading a discrete parameter is
        # discrete, and the resolution is transitive.
        s = Pass.load_partition(cadence_fixture("observed_leaf_seeds.esm"), "ObservedLeafSeeds").seeds
        @test s["geom"] === CadenceConst
        @test s["geom_chain"] === CadenceConst
        @test s["k_scaled"] === CadenceDiscrete
        @test s["u_scaled"] === CadenceContinuous
        @test s["u"] === CadenceContinuous     # the ODE state itself
        @test s["dx"] === CadenceConst
        @test s["Kdiff"] === CadenceDiscrete

        # An arrayed observed is recognised through its LHS's base name at any
        # rank (esm-spec §6.3.1), so a state-free one folds too: the `faq` shell
        # `faq{i}(wf[i]) ~ …` and the bare-index `wb[i] ~ …` both define an
        # observed, while `faq{i}(D(u[i]))` stays a tendency of the state.
        a = Pass.load_partition(cadence_fixture("arrayed_observed_seeds.esm"), "ArrayedObservedSeeds")
        @test a.seeds["wf"] === CadenceConst
        @test a.seeds["wb"] === CadenceConst
        @test a.seeds["ws"] === CadenceContinuous
        @test a.seeds["u"] === CadenceContinuous
        @test sort!(collect(keys(observed_definitions(a.model)))) == ["wb", "wf", "ws"]

        # A definition cycle is refused, not silently seeded.
        cyc = typed(
            jdoc(
                Dict("a" => Dict("type" => "unknown"), "b" => Dict("type" => "unknown")),
                [
                    Dict("lhs" => "a", "rhs" => jop("*", "b", 2.0)),
                    Dict("lhs" => "b", "rhs" => jop("*", "a", 2.0)),
                ]
            )
        )
        err = caught(() -> seeds_of(cyc))
        @test err isa EarthSciAST.TreeWalkError
        @test err.code == "observed_cycle"
    end

    # --- Negative controls: the guards must refuse non-conforming input. --------

    @testset "neg: wrong expect_cadence is flagged (guard 3)" begin
        # A const gather annotated continuous must be caught.
        s = seeds_of(typed(jdoc(Dict("p" => Dict("type" => "parameter")), Any[])))
        @test !isempty(check_expect_cadence(jexpr(jop("index", "p", "i"; expect_cadence = "continuous")), s))
        @test isempty(check_expect_cadence(jexpr(jop("index", "p", "i"; expect_cadence = "const")), s))
    end

    @testset "neg: continuous relational refused (guard 2)" begin
        # A distinct aggregate whose key reads the state u classifies continuous.
        file = typed(
            jdoc(
                Dict("u" => Dict("type" => "unknown")), [Dict("lhs" => jD("u"), "rhs" => 0.0)];
                index_sets = Dict("faces" => Dict("kind" => "interval", "size" => 4))
            )
        )
        s = seeds_of(file)
        rhs = jexpr(jproducer(Dict("f" => Dict("from" => "faces")); key = jidx("u", "f")))
        @test cadence_class(rhs, s) === CadenceContinuous
        @test only(continuous_relational_nodes(rhs, s)) === rhs
    end

    @testset "neg: continuous relational fixture refused (guard 2)" begin
        # tests/invalid/faq/continuous_relational_node.esm is schema-valid and
        # refused by the partition guard, in Rust and Python as here.
        fixture = joinpath(TESTUTILS_REPO_ROOT, "tests", "invalid", "faq", "continuous_relational_node.esm")
        p = Pass.load_partition(fixture, "ContinuousRelationalNode")
        @test_throws ErrorException Pass.run_guards(p)
    end

    @testset "neg: from_faq cycle refused (guard 1)" begin
        file = typed(
            jdoc(
                Dict("a" => Dict("type" => "unknown"), "b" => Dict("type" => "unknown")),
                [
                    Dict("lhs" => jidx("a", "x"), "rhs" => jproducer(Dict("y" => Dict("from" => "setB")); id = "nodeA")),
                    Dict("lhs" => jidx("b", "x"), "rhs" => jproducer(Dict("y" => Dict("from" => "setA")); id = "nodeB")),
                ];
                index_sets = Dict(
                    "setA" => Dict("kind" => "derived", "from_faq" => "nodeA"),
                    "setB" => Dict("kind" => "derived", "from_faq" => "nodeB")
                )
            )
        )
        cycle = derived_index_set_cycle(values(file.models), file.index_sets)
        @test cycle !== nothing
        @test Set(cycle) ⊇ Set(["setA", "setB"])
    end

    @testset "neg: float topology key refused (§5.5 rule 1)" begin
        @test_throws EarthSciAST.Relational.FloatKeyError Pass.fold_edge_enumeration(Any[Any[1.5]], Any[Any[2]], "undirected")
    end
end
