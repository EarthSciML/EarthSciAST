# Value-invention evaluator front-door — Julia reference (bead ess-3lj.1, F1).
#
# RFC semiring-faq-unified-ir §6.1 (cadence-partition) / §5.5 (determinism) /
# §7.3 (edge enumeration); CONFORMANCE_SPEC.md §5.5 / §5.7.
#
# The front-door sizes what the resolver would otherwise refuse with
# `derived_index_set_unmaterialized` (tree_walk/resolve.jl):
# a `kind:"derived"` index set whose `from_faq` names a `distinct` producer is
# materialized ONCE at setup through the `Relational` engine and its cardinality
# handed to the index-set resolver as the dense extent. The value-invention
# outputs run off the per-step hot path (§6.1) and are dropped from the ODE.
#
# The pass runs on the TYPED IR: `materialize_value_invention(model::Model,
# index_sets, const_arrays, params)` — the document is read once (loaded when
# it imports templates) and the model selected typed, its template references
# expanded; there is no raw-JSON walk.
#
# The proof case: the §7.3 edge-enumeration .esm runs end-to-end through
# build_evaluator — `edges` materializes to the five edges of the two-triangle
# mesh and the downstream geometric `area_eff` FAQ integrates over it.

using Test
using EarthSciAST
import JSON3

const ESS = EarthSciAST
include("testutils.jl")  # TESTUTILS_REPO_ROOT

const _VI_REPO_ROOT = TESTUTILS_REPO_ROOT
_vi_fixture(rel) = joinpath(_VI_REPO_ROOT, rel)
_vi_raw(rel) = JSON3.read(read(_vi_fixture(rel), String))

# Read a raw document (through the loader when it imports templates) and select
# one TYPED model, its template references expanded, plus the document-scoped
# index-set registry — the `materialize_value_invention` signature.
function _vi_typed(raw, name)
    file = ESS._coerce_or_load(raw)
    return ESS.expanded_model(file, name), file.index_sets
end
_vi_typed_fixture(rel, name) = _vi_typed(_vi_raw(rel), name)

# Inline models are written as JSON (the .esm model shape, far more legible
# than nested `Dict(...)` literals for deep ASTs) and coerced to the typed IR:
# the model-level `index_sets` block is hoisted to the document scope
# (esm-spec v0.8.0) and the model mounted as `models.M`.
function _vi_inline_model(json)
    m = ESS.Cadence.to_native(JSON3.read(json))
    doc = Dict{String, Any}(
        "esm" => "0.9.0",
        "metadata" => Dict{String, Any}("name" => "inline"),
        "index_sets" => get(m, "index_sets", Dict{String, Any}()),
        "models" => Dict{String, Any}("M" => m),
    )
    return _vi_typed(doc, "M")
end


@testset "value-invention front-door (ess-3lj.1)" begin

    @testset "edge-enumeration: build_evaluator end-to-end (§7.3)" begin
        rel = "tests/valid/faq/edge_enumeration_area_eff.esm"
        raw = _vi_raw(rel)
        # Canonical mesh connectivity (the ragged face_vertices backing factors)
        # plus a DUO edge geometry: cell 1 bounds dense edges {1,2,3}, cell 2
        # bounds {3,4,5}; distinct dc/dv make area_eff a non-trivial check.
        ca = Dict(
            "n_verts_on_face" => Float64[3, 3],
            "verts_on_face" => Float64[1 2 3; 2 3 4],
            "n_edges_on_cell" => Float64[3, 3],
            "edges_on_cell" => Float64[1 2 3; 3 4 5],
            "dc" => Float64[2, 3, 5, 7, 11],
            "dv" => Float64[13, 17, 19, 23, 29]
        )

        m, isets = _vi_typed(raw, "EdgeEnumerationAreaEff")
        vi = ESS.materialize_value_invention(m, isets, ca, Dict{String, Float64}())

        # (1) the derived `edges` set materializes via the relational engine:
        #     the five undirected edges of the two-triangle mesh, distinct keys.
        @test vi.extents["edge_set"] == 5
        @test vi.members["edge_set"] == sort(unique(vi.members["edge_set"]))
        @test "edge_exists" in vi.vi_var_names

        # (2) build_evaluator runs end-to-end: the derived-index-set throw is gone,
        #     only the geometric `area_eff` FAQ remains in the ODE.
        f!, u0, p, _, vmap = EarthSciAST._build_evaluator(
            raw; model_name = "EdgeEnumerationAreaEff",
            const_arrays = ca
        )
        @test sort(collect(keys(vmap))) == ["area_eff[1]", "area_eff[2]"]
        du = similar(u0); fill!(du, NaN); f!(du, u0, p, 0.0)
        # area_eff[i] = 1/4 · Σ_{k∈edges_of_cell(i)} dc[e]·dv[e]
        eoc = [[1, 2, 3], [3, 4, 5]]
        expected = [0.25 * sum(ca["dc"][e] * ca["dv"][e] for e in eoc[i]) for i in 1:2]
        @test du[vmap["area_eff[1]"]] ≈ expected[1]
        @test du[vmap["area_eff[2]"]] ≈ expected[2]
        @test expected ≈ [43.0, 143.75]   # the concrete DUO effective areas
    end

    @testset "edge-enumeration: a missing ragged factor is refused by name" begin
        # With no connectivity the producer cannot run: the derived set is
        # refused under its own name, never a KeyError from the engine.
        m, isets = _vi_typed_fixture(
            "tests/valid/faq/edge_enumeration_area_eff.esm",
            "EdgeEnumerationAreaEff"
        )
        err = try
            ESS.materialize_value_invention(m, isets, Dict{String, Any}(), Dict{String, Float64}())
            nothing
        catch e
            e
        end
        @test err isa ESS.TreeWalkError
        @test err.code == "derived_index_set_unmaterialized"
        @test occursin("n_verts_on_face", err.detail)
    end

    @testset "edge-enumeration: const-defined ragged factors are constant factors" begin
        # tests/conformance/value_invention_geometry: every key column is an
        # unknown defined by a `const` node, registered under its flattened
        # name, while the ragged set names its factors by bare name.
        path = _vi_fixture("tests/conformance/value_invention_geometry/fixtures/edge_enumeration_ode.esm")
        dus = Dict{Symbol, Vector{Float64}}()
        for c in (:interpreter, :native)
            prob = ESS.esm_problem(path, (0.0, 1.0); compiler = c)
            du = fill(NaN, length(prob.u0))
            prob.f!(du, ones(length(prob.u0)), prob.p, 0.0)
            dus[c] = du
            @test sort(du) == [5.0, 43.0, 143.75]
        end
        @test reinterpret(UInt64, dus[:native]) == reinterpret(UInt64, dus[:interpreter])
    end

    @testset "shaped edge endpoints build with data" begin
        # edge_lo / edge_hi are shaped [faces, local_edges]; with their data the
        # derived edge set is sized and the ODE builds under both compilers.
        path = _vi_fixture("tests/valid/faq/skolem_distinct_rank.esm")
        lo = Float64[mod1(f + l, 5) for f in 1:12, l in 1:3]
        ca = Dict{String, Any}("edge_lo" => lo, "edge_hi" => lo .+ 1)
        dus = Dict{Symbol, Vector{Float64}}()
        for c in (:interpreter, :native)
            prob = ESS.esm_problem(
                path, (0.0, 1.0); compiler = c, const_arrays = ca,
                u0 = harness_u0(path)
            )
            du = fill(NaN, length(prob.u0))
            prob.f!(du, ones(length(prob.u0)), prob.p, 0.0)
            dus[c] = du
            @test du == [-1.0]
        end
        @test reinterpret(UInt64, dus[:native]) == reinterpret(UInt64, dus[:interpreter])
    end

    @testset "a right-hand side gathers through the nearest-generator assignment" begin
        path = _vi_fixture("tests/conformance/value_invention_geometry/fixtures/nearest_generator_ode.esm")
        dus = Dict{Symbol, Vector{Float64}}()
        for c in (:interpreter, :native)
            prob = ESS.esm_problem(path, (0.0, 1.0); compiler = c)
            du = fill(NaN, length(prob.u0))
            prob.f!(du, zeros(length(prob.u0)), prob.p, 0.0)
            dus[c] = du
            w = [
                du[prob.var_map[only(k for k in keys(prob.var_map) if endswith(k, "w[$i]"))]]
                    for i in 1:4
            ]
            @test w == [0.0, 1.0, 1.0, 2.0]    # gx[assign], assign = [1, 2, 2, 3]
        end
        @test reinterpret(UInt64, dus[:native]) == reinterpret(UInt64, dus[:interpreter])
    end

    @testset "edge-enumeration: adversarial mesh inputs collapse to one edge set" begin
        # §5.5.4: permuted faces / reversed winding / a duplicate face all yield
        # the identical canonically-sorted edge set (the relational engine's job).
        rel = "tests/valid/faq/edge_enumeration_area_eff.esm"
        m, isets = _vi_typed_fixture(rel, "EdgeEnumerationAreaEff")
        base = Dict(
            "n_verts_on_face" => Float64[3, 3],
            "verts_on_face" => Float64[1 2 3; 2 3 4]
        )
        # reversed winding of each face (same undirected edges)
        rev = Dict(
            "n_verts_on_face" => Float64[3, 3],
            "verts_on_face" => Float64[3 2 1; 4 3 2]
        )
        members = map((base, rev)) do ca
            ESS.materialize_value_invention(m, isets, ca, Dict{String, Float64}()).members["edge_set"]
        end
        @test length(members[1]) == 5
        @test members[1] == members[2]
    end

    @testset "guard: a CONTINUOUS relational node is rejected (§5.7 guard 2)" begin
        # A distinct producer whose key reads a genuine `state` variable (not a
        # value-invention buffer) classifies CONTINUOUS and must be refused — the
        # relational engine may not run per step.
        m, isets = _vi_inline_model(
            """
            {"index_sets": {"items": {"kind": "interval", "size": 2},
                            "tags":  {"kind": "derived", "from_faq": "tag_set"}},
             "variables": {"u":   {"type": "unknown", "shape": ["items"]},
                           "tag": {"type": "unknown", "shape": ["tags"]}},
             "equations": [{"lhs": {"op": "index", "args": ["tag", "p"]},
               "rhs": {"op": "faq", "id": "tag_set",
                       "semiring": "bool_and_or", "distinct": true,
                       "output_idx": ["p"],
                       "ranges": {"i": {"from": "items"}},
                       "key": {"op": "index", "args": ["u", "i"]},
                       "expr": {"op": "true", "args": []}}}]}
            """
        )
        @test_throws ESS.TreeWalkError ESS.materialize_value_invention(
            m, isets, Dict("u" => Float64[1, 2]), Dict{String, Float64}()
        )
    end

    @testset "no-op: a model with no value-invention is untouched" begin
        # _vi_detect reports has_vi=false and materialization returns empties, so a
        # plain model flows through build_evaluator byte-identically.
        m, isets = _vi_inline_model(
            """
            {"variables": {"x": {"type": "unknown", "shape": []}},
             "equations": [{"lhs": {"op": "D", "args": ["x"], "wrt": "t"},
                            "rhs": -1.0}]}
            """
        )
        vi = ESS.materialize_value_invention(m, isets, Dict{String, Any}(), Dict{String, Float64}())
        @test isempty(vi.extents)
        @test isempty(vi.vi_var_names)
    end
end
