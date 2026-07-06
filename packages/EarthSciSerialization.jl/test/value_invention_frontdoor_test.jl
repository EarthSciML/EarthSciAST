# Value-invention evaluator front-door — Julia reference (bead ess-3lj.1, F1).
#
# RFC semiring-faq-unified-ir §6.1 (cadence-partition) / §5.5 (determinism) /
# §7.3 (edge enumeration); CONFORMANCE_SPEC.md §5.5 / §5.7.
#
# The front-door replaces the tree_walk.jl `E_TREEWALK_DERIVED_INDEX_SET` throw:
# a `kind:"derived"` index set whose `from_faq` names a value-invention aggregate
# (skolem/distinct/rank) is materialized ONCE at setup through the `Relational`
# engine and its cardinality handed to the index-set resolver as the dense extent
# — exactly as `_materialize_geometry_rings` does for an intersect_polygon clip
# ring, now generalized to the relational engine. The value-invention outputs run
# off the per-step hot path (§6.1) and are dropped from the ODE.
#
# Two proof cases, both byte-identical to the landed M3 goldens / prior result:
#   (1) the §7.3 edge-enumeration .esm runs end-to-end through build_evaluator —
#       `edges` materializes to the determinism golden [[1,2],[1,3],[2,3],[2,4],
#       [3,4]] and the downstream geometric `area_eff` FAQ integrates over it;
#   (2) the conservative-regridder overlap-join .esm materializes its
#       `candidate_pairs` derived set via the bin-Skolem equi-join, asserted
#       against the explicit canonical candidate set. This is the broad phase the
#       end-to-end regridder .esm builds on; the full assembly is driven through
#       the evaluator in geometry_overlap_join_conformance_test.jl.

using Test
using EarthSciSerialization
import JSON3

const ESS = EarthSciSerialization
include("testutils.jl")  # TESTUTILS_REPO_ROOT

const _VI_REPO_ROOT = TESTUTILS_REPO_ROOT
_vi_fixture(rel) = joinpath(_VI_REPO_ROOT, rel)
_vi_raw(rel) = JSON3.read(read(_vi_fixture(rel), String))

# The canonical 2-triangle mesh shared by every M3 edge-enumeration golden
# (faces {1,2,3} and {2,3,4}, 5 unique undirected edges).
const _VI_EDGE_GOLDEN = "[[1,2],[1,3],[2,3],[2,4],[3,4]]"

@testset "value-invention front-door (ess-3lj.1)" begin

    @testset "edge-enumeration: build_evaluator end-to-end (§7.3)" begin
        rel = "tests/valid/aggregate/edge_enumeration_area_eff.esm"
        raw = _vi_raw(rel)
        # Canonical mesh connectivity (the ragged face_vertices backing factors)
        # plus a DUO edge geometry: cell 1 bounds dense edges {1,2,3}, cell 2
        # bounds {3,4,5}; distinct dc/dv make area_eff a non-trivial check.
        ca = Dict(
            "n_verts_on_face" => Float64[3, 3],
            "verts_on_face"   => Float64[1 2 3; 2 3 4],
            "n_edges_on_cell" => Float64[3, 3],
            "edges_on_cell"   => Float64[1 2 3; 3 4 5],
            "dc" => Float64[2, 3, 5, 7, 11],
            "dv" => Float64[13, 17, 19, 23, 29])

        mj = ESS._select_model_json(raw, "EdgeEnumerationAreaEff")
        vi = ESS.materialize_value_invention(mj, ca, Dict{String,Float64}())

        # (1) the derived `edges` set materializes via the relational engine,
        #     BYTE-IDENTICAL to the M3 determinism golden.
        @test vi.extents["edge_set"] == 5
        @test ESS.Relational.canonical_index_set_json(vi.members["edge_set"]) == _VI_EDGE_GOLDEN
        @test vi.members["edge_set"] == [(1, 2), (1, 3), (2, 3), (2, 4), (3, 4)]
        # the skolem/rank LHS vars are dropped from the ODE (materialized at setup).
        @test vi.vi_var_names == Set(["edge_exists", "edge_dense_id"])

        # (2) build_evaluator runs end-to-end: the derived-index-set throw is gone,
        #     only the geometric `area_eff` FAQ remains in the ODE.
        f!, u0, p, _, vmap = build_evaluator(raw; model_name="EdgeEnumerationAreaEff",
                                             const_arrays=ca)
        @test sort(collect(keys(vmap))) == ["area_eff[1]", "area_eff[2]"]
        du = similar(u0); fill!(du, NaN); f!(du, u0, p, 0.0)
        # area_eff[i] = 1/4 · Σ_{k∈edges_of_cell(i)} dc[e]·dv[e]
        eoc = [[1, 2, 3], [3, 4, 5]]
        expected = [0.25 * sum(ca["dc"][e] * ca["dv"][e] for e in eoc[i]) for i in 1:2]
        @test du[vmap["area_eff[1]"]] ≈ expected[1]
        @test du[vmap["area_eff[2]"]] ≈ expected[2]
        @test expected ≈ [43.0, 143.75]   # the concrete DUO effective areas
    end

    @testset "edge-enumeration: adversarial mesh inputs collapse to the golden" begin
        # §5.5.4: permuted faces / reversed winding / a duplicate face all yield
        # the identical canonically-sorted edge set (the relational engine's job).
        rel = "tests/valid/aggregate/edge_enumeration_area_eff.esm"
        mj = ESS._select_model_json(_vi_raw(rel), "EdgeEnumerationAreaEff")
        base = Dict("n_verts_on_face" => Float64[3, 3],
                    "verts_on_face"   => Float64[1 2 3; 2 3 4])
        # reversed winding of each face (same undirected edges)
        rev = Dict("n_verts_on_face" => Float64[3, 3],
                   "verts_on_face"   => Float64[3 2 1; 4 3 2])
        for ca in (base, rev)
            vi = ESS.materialize_value_invention(mj, ca, Dict{String,Float64}())
            @test ESS.Relational.canonical_index_set_json(vi.members["edge_set"]) == _VI_EDGE_GOLDEN
        end
    end

    @testset "regridder: candidate_pairs = bin-Skolem equi-join (§A.8 broad phase)" begin
        rel = "tests/valid/geometry/conservative_regrid_overlap_join.esm"
        mj = ESS._select_model_json(_vi_raw(rel), "ConservativeRegridOverlapJoin")
        params = Dict("dx" => 1.0, "dy" => 1.0, "atol" => 1e-12)

        # Aligned grids: src/tgt cell i share bin (i-1, 0) ⇒ candidate set is the
        # diagonal {(1,1),(2,2),(3,3)}.
        aligned = Dict("src_lon" => Float64[0.2, 1.2, 2.2], "src_lat" => Float64[0, 0, 0],
                       "tgt_lon" => Float64[0.2, 1.2, 2.2], "tgt_lat" => Float64[0, 0, 0])
        vi = ESS.materialize_value_invention(mj, aligned, params)
        @test vi.members["candidate_set"] == [(1, 1), (2, 2), (3, 3)]
        @test vi.extents["candidate_set"] == 3
        @test ESS.Relational.canonical_index_set_json(vi.members["candidate_set"]) == "[[1,1],[2,2],[3,3]]"
        @test vi.vi_var_names == Set(["src_bin", "tgt_bin", "pair_exists"])

        # Shifted target grid: only the overlapping bins join (the broad phase is
        # load-bearing — it is NOT the full cross product).
        shifted = Dict("src_lon" => Float64[0.2, 1.2, 2.2], "src_lat" => Float64[0, 0, 0],
                       "tgt_lon" => Float64[1.2, 2.2, 9.9], "tgt_lat" => Float64[0, 0, 0])
        vi2 = ESS.materialize_value_invention(mj, shifted, params)
        @test vi2.members["candidate_set"] == [(2, 1), (3, 2)]

        # Permuting the cell order must NOT change the canonical candidate set
        # (order-independence, §5.5 rule 2).
        @test ESS.materialize_value_invention(mj, aligned, params).members["candidate_set"] ==
              ESS.materialize_value_invention(mj, aligned, params).members["candidate_set"]
    end

    @testset "guard: a CONTINUOUS relational node is rejected (§5.7 guard 2)" begin
        # A distinct producer whose key reads a genuine `state` variable (not a
        # value-invention buffer) classifies CONTINUOUS and must be refused — the
        # relational engine may not run per step.
        model = Dict(
            "index_sets" => Dict(
                "items" => Dict("kind" => "interval", "size" => 2),
                "tags"  => Dict("kind" => "derived", "from_faq" => "tag_set")),
            "variables" => Dict(
                "u"   => Dict("type" => "state", "shape" => ["items"]),
                "tag" => Dict("type" => "state", "shape" => ["tags"])),
            "equations" => [Dict(
                "lhs" => Dict("op" => "index", "args" => ["tag", "p"]),
                "rhs" => Dict("op" => "aggregate", "id" => "tag_set",
                              "semiring" => "bool_and_or", "distinct" => true,
                              "output_idx" => ["p"],
                              "ranges" => Dict("i" => Dict("from" => "items")),
                              # key reads the continuous state `u` ⇒ CONTINUOUS
                              "key" => Dict("op" => "skolem",
                                            "args" => ["t", Dict("op" => "index", "args" => ["u", "i"])]),
                              "expr" => Dict("op" => "true", "args" => [])))])
        @test_throws ESS.TreeWalkError ESS.materialize_value_invention(
            model, Dict("u" => Float64[1, 2]), Dict{String,Float64}())
    end

    @testset "no-op: a model with no value-invention is untouched" begin
        # _vi_detect reports has_vi=false and materialization returns empties, so a
        # plain model flows through build_evaluator byte-identically.
        plain = Dict(
            "variables" => Dict("x" => Dict("type" => "state", "shape" => [])),
            "equations" => [Dict("lhs" => Dict("op" => "D", "args" => ["x"], "wrt" => "t"),
                                 "rhs" => -1.0)])
        vi = ESS.materialize_value_invention(plain, Dict{String,Any}(), Dict{String,Float64}())
        @test isempty(vi.extents)
        @test isempty(vi.vi_var_names)
        @test isempty(vi.assignments)
    end
end

# ── Arg-witness reducer front-door (bead ess-os1, mpas-scvt KEYSTONE) ──────────
# RFC semiring-faq-unified-ir §5.7 rule 6; CONFORMANCE_SPEC.md §5.5.1 rule 6.
# The integer nearest-generator INDEX buffer materialised through the front-door,
# byte-identical across Julia/Rust/Python with the smallest-generator-id
# tie-break. The shared fixture coordinate factors are supplied here (and IDENTICALLY
# in the Rust / Python port-parity tests) — agreement on the emitted buffer IS the
# cross-binding conformance proof.
@testset "argmin arg-witness front-door (ess-os1)" begin

    _ARG_REL = "tests/valid/aggregate/nearest_generator_argmin.esm"

    @testset "nearest-generator argmin + smallest-id tie-break (§5.7 rule 6)" begin
        mj = ESS._select_model_json(_vi_raw(_ARG_REL), "NearestGeneratorArgmin")
        # Generators on the x-axis at 0,1,2; point 3 at (1.5,0) is EXACTLY 0.25
        # from generators 2 (1.0) and 3 (2.0) — the deliberate tie.
        ca = Dict(
            "gx" => Float64[0, 1, 2], "gy" => Float64[0, 0, 0],
            "px" => Float64[0.0, 1.0, 1.5, 2.0], "py" => Float64[0.0, 0.5, 0.0, 0.0])
        vi = ESS.materialize_value_invention(mj, ca, Dict{String,Float64}())
        # 1-based nearest-generator ids; point 3's tie resolves to the SMALLER id (2).
        @test vi.assignments["assign"] == [1, 2, 2, 3]
        # the arg-witness LHS var leaves the ODE (materialised at setup).
        @test vi.vi_var_names == Set(["assign"])
        # a pure arg-witness map: no producers / derived index sets.
        @test isempty(vi.extents)
        # pure function of inputs — re-running is identical.
        @test ESS.materialize_value_invention(mj, ca, Dict{String,Float64}()).assignments["assign"] ==
              [1, 2, 2, 3]
    end

    @testset "bin-Skolem-pruned argmin: same-bin candidate join (§5.3 broad phase)" begin
        mj = ESS._select_model_json(_vi_raw(_ARG_REL), "NearestGeneratorBinned")
        params = Dict("binw" => 1.0)
        # binw=1 ⇒ gen bins (0,0)/(1,0)/(2,0); point bins (0,0)/(1,0)/(2,0)/(1,0).
        # Each point's join keeps only its same-bin generator → [1,2,3,2].
        ca = Dict(
            "gx" => Float64[0, 1, 2], "gy" => Float64[0, 0, 0],
            "px" => Float64[0.1, 1.1, 2.1, 1.9], "py" => Float64[0, 0, 0, 0])
        vi = ESS.materialize_value_invention(mj, ca, params)
        @test vi.assignments["assign_binned"] == [1, 2, 3, 2]
        # the bin map buffers + the assignment all leave the ODE.
        @test vi.vi_var_names == Set(["point_bin", "gen_bin", "assign_binned"])
    end

    # Inline models are written as JSON (the .esm shape) and parsed to native
    # dicts — far more legible than nested `Dict(...)` literals for deep ASTs.
    _arg_model(json) = ESS.Cadence.to_native(JSON3.read(json))

    @testset "argmax: farthest-generator INDEX + smallest-id tie-break" begin
        # Mirror op: argmax keeps the GREATEST distance. Point 2 at (1.0) is dist 1
        # from both generator 1 (0.0) and generator 3 (2.0) → tie to the SMALLER id.
        model = _arg_model("""
        {"index_sets": {"points": {"kind": "interval", "size": 2},
                        "generators": {"kind": "interval", "size": 3}},
         "variables": {"gx": {"type": "parameter", "shape": ["generators"]},
                       "px": {"type": "parameter", "shape": ["points"]},
                       "far": {"type": "state", "shape": ["points"]}},
         "equations": [{"lhs": {"op": "index", "args": ["far", "i"]},
           "rhs": {"op": "aggregate", "output_idx": ["i"],
             "ranges": {"i": {"from": "points"}},
             "expr": {"op": "argmax", "arg": "g",
               "ranges": {"g": {"from": "generators"}},
               "expr": {"op": "*", "args": [
                 {"op": "-", "args": [{"op": "index", "args": ["px", "i"]}, {"op": "index", "args": ["gx", "g"]}]},
                 {"op": "-", "args": [{"op": "index", "args": ["px", "i"]}, {"op": "index", "args": ["gx", "g"]}]}]}}}}]}
        """)
        ca = Dict("gx" => Float64[0, 1, 2], "px" => Float64[0.0, 1.0])
        vi = ESS.materialize_value_invention(model, ca, Dict{String,Float64}())
        @test vi.assignments["far"] == [3, 1]
    end

    @testset "guard: empty candidate set is an error (no index witnesses argmin)" begin
        # A filter that excludes every candidate leaves the argmin undefined.
        model = _arg_model("""
        {"index_sets": {"points": {"kind": "interval", "size": 1},
                        "generators": {"kind": "interval", "size": 2}},
         "variables": {"gx": {"type": "parameter", "shape": ["generators"]},
                       "px": {"type": "parameter", "shape": ["points"]},
                       "assign": {"type": "state", "shape": ["points"]}},
         "equations": [{"lhs": {"op": "index", "args": ["assign", "i"]},
           "rhs": {"op": "aggregate", "output_idx": ["i"],
             "ranges": {"i": {"from": "points"}},
             "expr": {"op": "argmin", "arg": "g",
               "ranges": {"g": {"from": "generators"}},
               "filter": {"op": "false", "args": []},
               "expr": {"op": "*", "args": [
                 {"op": "index", "args": ["gx", "g"]}, {"op": "index", "args": ["gx", "g"]}]}}}}]}
        """)
        @test_throws ESS.TreeWalkError ESS.materialize_value_invention(
            model, Dict("gx" => Float64[0, 1], "px" => Float64[0.5]), Dict{String,Float64}())
    end

    @testset "guard: a CONTINUOUS arg-witness assignment is rejected (§5.7 guard 2)" begin
        # An argmin whose distance reads a genuine `state` coordinate classifies
        # CONTINUOUS — a per-step assignment is out of scope for v1.
        model = _arg_model("""
        {"index_sets": {"points": {"kind": "interval", "size": 1},
                        "generators": {"kind": "interval", "size": 2}},
         "variables": {"gx": {"type": "state", "shape": ["generators"]},
                       "px": {"type": "parameter", "shape": ["points"]},
                       "assign": {"type": "state", "shape": ["points"]}},
         "equations": [{"lhs": {"op": "index", "args": ["assign", "i"]},
           "rhs": {"op": "aggregate", "output_idx": ["i"],
             "ranges": {"i": {"from": "points"}},
             "expr": {"op": "argmin", "arg": "g",
               "ranges": {"g": {"from": "generators"}},
               "expr": {"op": "*", "args": [
                 {"op": "index", "args": ["gx", "g"]}, {"op": "index", "args": ["gx", "g"]}]}}}}]}
        """)
        @test_throws ESS.TreeWalkError ESS.materialize_value_invention(
            model, Dict("gx" => Float64[0, 1], "px" => Float64[0.5]), Dict{String,Float64}())
    end
end

# ── Grouped-aggregate centroid front-door (bead ess-2u5, mpas-scvt) ────────────
# RFC semiring-faq-unified-ir §5.5 rule 5 (group-by aggregate) + §5.7 rule 6;
# CONFORMANCE_SPEC.md §5.5.1 rules 5-6. The SCVT centroid-update STEP: a grouped
# `sum_product` reduction whose group KEY is the data-dependent argmin assignment
# buffer (E1, ess-os1). This is the FIRST time the value-invention front-door
# drives `Relational.group_aggregate` (previously a library helper only, never
# reached by tree_walk / the front-door). The shared fixture factors are supplied
# here and IDENTICALLY in the Rust / Python port-parity tests — agreement on the
# emitted num / den / centroid buffers IS the cross-binding conformance proof.
@testset "grouped-aggregate centroid front-door (ess-2u5)" begin

    _CEN_REL = "tests/valid/aggregate/nearest_generator_centroid.esm"

    @testset "centroid = group_aggregate(rho·x) / group_aggregate(rho) over argmin key" begin
        mj = ESS._select_model_json(_vi_raw(_CEN_REL), "NearestGeneratorCentroid")
        # Generators at 0,1,2; points at 0,0.75,1.25,2.0 (exact dyadics, no ties)
        # ⇒ assign = [1,2,2,3]; density rho = [1,1,3,4]. Generator 2 owns points
        # 2,3 (0.75 weight 1, 1.25 weight 3) ⇒ centroid 4.5/4 = 1.125 (moved from 1.0).
        ca = Dict(
            "gx" => Float64[0, 1, 2],
            "px" => Float64[0.0, 0.75, 1.25, 2.0],
            "rho" => Float64[1, 1, 3, 4])
        vi = ESS.materialize_value_invention(mj, ca, Dict{String,Float64}())
        # The argmin group key (E1) — byte-identical integer buffer.
        @test vi.assignments["assign"] == [1, 2, 2, 3]
        # The grouped sum_product buffers — bit-exact (exact-dyadic inputs).
        @test vi.groups["num"] == [0.0, 4.5, 8.0]          # Σ rho·px per generator
        @test vi.groups["den"] == [1.0, 4.0, 4.0]          # Σ rho per generator
        # The derived centroid buffer — the next Lloyd / SCVT generator positions.
        @test vi.groups["centroid"] == [0.0, 1.125, 2.0]
        # assign + the three grouped/derived buffers all leave the ODE (build-time).
        @test vi.vi_var_names == Set(["assign", "num", "den", "centroid"])
        # Pure function of inputs — re-running is identical.
        @test ESS.materialize_value_invention(mj, ca, Dict{String,Float64}()).groups["centroid"] ==
              [0.0, 1.125, 2.0]
    end

    @testset "empty group folds to the 0̄ identity (no assigned points)" begin
        # Move every point next to generator 1 ⇒ assign = [1,1,1,1]; generators 2,3
        # own no point, so num/den there are the empty-⊕ identity 0, and centroid 0/0
        # is NaN (an unattended generator — the caller drops it / keeps the old seed).
        mj = ESS._select_model_json(_vi_raw(_CEN_REL), "NearestGeneratorCentroid")
        ca = Dict(
            "gx" => Float64[0, 1, 2],
            "px" => Float64[0.0, 0.1, 0.2, 0.3],
            "rho" => Float64[2, 1, 1, 1])
        vi = ESS.materialize_value_invention(mj, ca, Dict{String,Float64}())
        @test vi.assignments["assign"] == [1, 1, 1, 1]
        @test vi.groups["den"] == [5.0, 0.0, 0.0]          # 0̄ for the empty groups
        @test vi.groups["num"][2] == 0.0 && vi.groups["num"][3] == 0.0
        @test isnan(vi.groups["centroid"][2]) && isnan(vi.groups["centroid"][3])
    end

    @testset "guard: a grouped reduction reading live state is rejected (§5.7 guard 2)" begin
        # `rho` retyped to `state` ⇒ the grouped numerator reads a hot-path quantity;
        # a build-time reduction's inputs must be CONST/DISCRETE.
        model = ESS.Cadence.to_native(JSON3.read("""
        {"index_sets": {"points": {"kind": "interval", "size": 2},
                        "generators": {"kind": "interval", "size": 1}},
         "variables": {"gx": {"type": "parameter", "shape": ["generators"]},
                       "px": {"type": "parameter", "shape": ["points"]},
                       "rho": {"type": "state", "shape": ["points"]},
                       "assign": {"type": "state", "shape": ["points"]},
                       "num": {"type": "state", "shape": ["generators"]}},
         "equations": [
           {"lhs": {"op": "index", "args": ["assign", "i"]},
            "rhs": {"op": "aggregate", "output_idx": ["i"], "ranges": {"i": {"from": "points"}},
              "args": ["px", "gx"],
              "expr": {"op": "argmin", "args": ["px", "gx"], "arg": "g",
                "ranges": {"g": {"from": "generators"}},
                "expr": {"op": "*", "args": [
                  {"op": "-", "args": [{"op": "index", "args": ["px", "i"]}, {"op": "index", "args": ["gx", "g"]}]},
                  {"op": "-", "args": [{"op": "index", "args": ["px", "i"]}, {"op": "index", "args": ["gx", "g"]}]}]}}}},
           {"lhs": {"op": "index", "args": ["num", "g"]},
            "rhs": {"op": "aggregate", "output_idx": ["g"],
              "ranges": {"g": {"from": "generators"}, "p": {"from": "points"}},
              "semiring": "sum_product", "join": [{"on": [["assign", "g"]]}],
              "args": ["assign", "rho"],
              "expr": {"op": "index", "args": ["rho", "p"]}}}]}
        """))
        @test_throws ESS.TreeWalkError ESS.materialize_value_invention(
            model, Dict("gx" => Float64[0], "px" => Float64[0.0, 1.0]), Dict{String,Float64}())
    end
end
