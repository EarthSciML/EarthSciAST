# The OVERLAP broad phase at SETUP — candidate-DRIVEN enumeration, and the
# behaviour change it does and does not make.
#
# `_resolve_geo_join_gates` used to skip every Phase-2a `overlap` clause, so a
# setup-materialized aggregate — which has no other resolver — never applied its
# broad phase. `conservative_overlap_A_ij_gated`, whose contract is "one polygon
# clip per CANDIDATE pair … O(#candidates) build cost", ran the full
# `#src × #tgt` product instead. `_materialize_geom_array` now resolves the
# clause and hands it to the SHARED planner (`_overlap_drive_plan`,
# src/broad_phase.jl — the same one `_vi_enumerate_join` and
# `_foreach_aggregate_term` use), which drives enumeration from the candidate
# set rather than filtering the full product.
#
# TWO THINGS ARE PINNED HERE, and they pull in opposite directions:
#
#   1. For the shapes the conservative-regrid templates actually use — a
#      `sum_product` weight matrix and a `sum_product` apply — the change is
#      value-NEUTRAL, bit for bit. A pruned pair has disjoint envelopes, hence
#      disjoint polygons, hence `_polygon_intersection_area` returns exactly
#      `+0.0`, which is the additive identity the gate says it contributes.
#      Every case below compares against `ESS_GEOM_OVERLAP_GATE_DISABLE=1` (the
#      historic ungated dense sweep) with `isequal` — never `≈`, never `==`, so
#      `-0.0` cannot pass for `+0.0` and `NaN` must match `NaN`.
#
#   2. For a NON-ADDITIVE fold it is NOT neutral, and that is pinned too. Under
#      `reduce: min` the identity 0̄ is `+Inf`, so a pruned pair contributes
#      nothing — while the ungated sweep folds in the exact `0.0` it computed
#      for that disjoint pair and drives the whole reduction to zero. The gated
#      answer is the one RFC §5.3 specifies (a rejected tuple contributes 0̄);
#      the ungated one was letting non-candidates contribute their body. The
#      `min`/`prod` testset below records the divergence explicitly rather than
#      leaving it to be discovered.
#
# That testset doubles as the NEGATIVE CONTROL: it asserts that
# `ESS_GEOM_OVERLAP_GATE_VERIFY=1` THROWS there. An oracle that never fires
# proves nothing, and the neutrality claim in (1) rests on this same oracle
# staying silent.
#
# Engagement counters keep every comparison non-vacuous: a case that silently
# stopped driving would compare the dense path against itself and pass, so each
# case asserts which path it took.

module GeomOverlapDriveTests

using Test
using EarthSciAST
const EA = EarthSciAST

# The GeometryOps extension supplies the fast STRtree broad phase; without it
# `_overlap_candidate_set` falls back to the brute-force reference, which is
# specified to return an identical pair set. Load it when available so the
# shipped path is the one under test.
try
    @eval import GeometryOps, GeoInterface, SortTileRecursiveTree, Extents
catch
end

# ---- small JSON AST builders ----
_op(o, args...) = Dict{String,Any}("op" => o, "args" => Any[args...])
_ix(f, args...) = Dict{String,Any}("op" => "index", "args" => Any[f, args...])
function _agg(output_idx, ranges, expr; kw...)
    d = Dict{String,Any}("op" => "aggregate", "output_idx" => collect(output_idx),
                         "ranges" => Dict{String,Any}(
                             k => (v isa AbstractString ? Dict{String,Any}("from" => v) : v)
                             for (k, v) in ranges),
                         "args" => Any[], "expr" => expr)
    for (k, v) in kw
        d[String(k)] = v
    end
    return d
end
_ovj(src, tgt; eps = 1e-9) = Any[Dict{String,Any}("overlap" => Dict{String,Any}(
    "src_env" => Any[src...], "tgt_env" => Any[tgt...], "eps" => eps))]
_pia(a, b) = Dict{String,Any}("op" => "polygon_intersection_area",
                              "manifold" => "planar", "args" => Any[a, b])

# One axis-aligned square ring at `(x, y)` with side `w`, CCW from the SW corner.
function sq!(R, p, x, y, w)
    R[p, 1, 1] = x;     R[p, 1, 2] = y
    R[p, 2, 1] = x + w; R[p, 2, 2] = y
    R[p, 3, 1] = x + w; R[p, 3, 2] = y + w
    R[p, 4, 1] = x;     R[p, 4, 2] = y + w
    return R
end

# A SEPARATING fixture: two target cells far apart, each strictly containing two
# small sources. Every candidate pair has POSITIVE area; every non-candidate
# pair is fully disjoint, so the dense sweep computes an exact `0.0` there. That
# is what makes the additive cases neutral and the `min`/`prod` cases diverge.
const SRC = let R = zeros(Float64, 4, 4, 2)
    sq!(R, 1, 0.2, 0.2, 0.2); sq!(R, 2, 0.6, 0.6, 0.2)
    sq!(R, 3, 2.2, 0.2, 0.2); sq!(R, 4, 2.6, 0.6, 0.2)
    R
end
const TGT = let R = zeros(Float64, 2, 4, 2)
    sq!(R, 1, 0.0, 0.0, 1.0); sq!(R, 2, 2.0, 0.0, 1.0)
    R
end
const IDX = Dict{String,Int}("S" => 4, "T" => 2, "K" => 3)
const SHAPES = Dict{String,Vector{String}}(
    "src_poly" => ["S", "V", "C"], "tgt_poly" => ["T", "V", "C"],
    "F_src" => ["S"], "A_j" => ["T"], "kk" => ["K"])
const ENV0 = Dict{String,Any}(
    "src_poly" => SRC, "tgt_poly" => TGT, "atol" => 1e-12,
    "F_src" => Float64[1.0, -2.0, 3.5, -0.0],
    "A_j"   => Float64[1.0, 1.0],
    "kk"    => Float64[1.0, 2.0, 3.0])

# Materialize `json` with the broad phase applied and, separately, with
# `ESS_GEOM_OVERLAP_GATE_DISABLE=1` forcing the historic ungated dense sweep.
# Returns (gated, ungated, Δdrive, Δgate_only, Δnone).
function both_ways(json, env = ENV0, idx = IDX)
    rhs = EA.expression_from_json(json)
    d0, g0, n0 = EA._GEOM_OVERLAP_DRIVE[], EA._GEOM_OVERLAP_GATE_ONLY[],
                 EA._GEOM_OVERLAP_NONE[]
    got = EA._materialize_geom_array(rhs, copy(env), nothing, idx, SHAPES)
    dd = EA._GEOM_OVERLAP_DRIVE[] - d0
    dg = EA._GEOM_OVERLAP_GATE_ONLY[] - g0
    dn = EA._GEOM_OVERLAP_NONE[] - n0
    ref = withenv("ESS_GEOM_OVERLAP_GATE_DISABLE" => "1") do
        EA._materialize_geom_array(rhs, copy(env), nothing, idx, SHAPES)
    end
    return got, ref, dd, dg, dn
end

# Bitwise array agreement — the correctness bar.
function bitsame(a, b)
    size(a) == size(b) || return false
    for i in eachindex(a)
        isequal(a[i], b[i]) || return false
    end
    return true
end

# Does verify mode throw on this document?
function verify_throws(json, env = ENV0, idx = IDX)
    rhs = EA.expression_from_json(json)
    try
        withenv("ESS_GEOM_OVERLAP_GATE_VERIFY" => "1") do
            EA._materialize_geom_array(rhs, copy(env), nothing, idx, SHAPES)
        end
        return false
    catch e
        e isa EarthSciAST.TreeWalkError || rethrow()
        return true
    end
end

const A_IJ = _agg(["i", "j"], ["i" => "S", "j" => "T"],
                  _pia(_ix("src_poly", "i"), _ix("tgt_poly", "j"));
                  join = _ovj(["src_poly"], ["tgt_poly"]))

@testset "setup-time overlap broad phase" begin

    @testset "A_ij weight matrix: PAIRS-driven, bit-identical" begin
        got, ref, dd, dg, dn = both_ways(A_IJ)
        @test (dd, dg, dn) == (1, 0, 0)        # really driven from the candidates
        @test bitsame(got, ref)
        @test length(unique(got)) > 1          # not a vacuous all-zeros pass
        # The matrix is genuinely sparse: 4 positive cells out of 8, and every
        # pruned cell is EXACTLY +0.0 (a `-0.0` there would fail `isequal`).
        @test count(!iszero, got) == 4
        @test any(iszero, got)
        @test all(x -> !(x === -0.0), got)
        @test !verify_throws(A_IJ)             # ... and the oracle agrees
    end

    @testset "apply contraction: RESTRICT-driven, bit-identical" begin
        # The `conservative_overlap_apply_gated` shape: contract over the source
        # index, gated by the same overlap clause, with the sliver filter on top.
        # `F_src` carries a negative and a `-0.0` so the fold is not sign-trivial.
        env = merge(copy(ENV0), Dict{String,Any}(
            "A_ij" => EA._materialize_geom_array(EA.expression_from_json(A_IJ),
                                                 copy(ENV0), nothing, IDX, SHAPES)))
        body = _op("/", _op("*", _ix("A_ij", "i", "j"), _ix("F_src", "i")),
                        _ix("A_j", "j"))
        for (nm, extra) in ("filtered" => Dict{String,Any}(
                                "filter" => _op(">", _ix("A_ij", "i", "j"), "atol")),
                            "unfiltered" => Dict{String,Any}())
            j = _agg(["j"], ["i" => "S", "j" => "T"], body;
                     join = _ovj(["src_poly"], ["tgt_poly"]))
            merge!(j, extra)
            got, ref, dd, dg, dn = both_ways(j, env)
            @test (nm, dd, dg, dn) == (nm, 1, 0, 0)
            @test (nm, bitsame(got, ref)) == (nm, true)
            @test (nm, length(unique(got)) > 1) == (nm, true)
            @test (nm, verify_throws(j, env)) == (nm, false)
        end
    end

    @testset "additive folds stay neutral; sum_product too" begin
        for (nm, extra) in ("plus" => Dict{String,Any}("reduce" => "+"),
                            "sum" => Dict{String,Any}("reduce" => "sum"),
                            "semiring" => Dict{String,Any}("semiring" => "sum_product"),
                            "max" => Dict{String,Any}("reduce" => "max"))
            j = _agg(["j"], ["i" => "S", "j" => "T"],
                     _pia(_ix("src_poly", "i"), _ix("tgt_poly", "j"));
                     join = _ovj(["src_poly"], ["tgt_poly"]))
            merge!(j, extra)
            got, ref, dd, _, _ = both_ways(j)
            @test (nm, dd) == (nm, 1)
            @test (nm, bitsame(got, ref)) == (nm, true)
            @test (nm, verify_throws(j)) == (nm, false)
        end
    end

    # ---- the documented behaviour CHANGE, and the oracle that catches it ----

    @testset "min/prod folds DIVERGE — and verify mode fires" begin
        # 0̄ is `+Inf` for `min` and `1.0` for `prod`, so a pruned pair
        # contributes nothing. The ungated sweep instead folds in the exact
        # `0.0` it computed for that disjoint pair, zeroing the reduction. The
        # gated value is the one RFC §5.3 specifies. This is a REAL behaviour
        # change for such a document and is recorded, not smoothed over.
        for (nm, red) in ("min" => "min", "prod" => "prod")
            j = _agg(["j"], ["i" => "S", "j" => "T"],
                     _pia(_ix("src_poly", "i"), _ix("tgt_poly", "j"));
                     join = _ovj(["src_poly"], ["tgt_poly"]))
            j["reduce"] = red
            got, ref, dd, _, _ = both_ways(j)
            @test (nm, dd) == (nm, 1)
            @test (nm, bitsame(got, ref)) == (nm, false)   # they DIFFER
            @test (nm, all(iszero, ref)) == (nm, true)     # ungated: a 0.0 leaked in
            @test (nm, all(x -> x > 0, got)) == (nm, true) # gated: candidates only
            # The differential oracle FIRES here. Without this the neutrality
            # asserted above would be unfalsifiable.
            @test (nm, verify_throws(j)) == (nm, true)
        end
    end

    # ---- switches, declines and counters ----

    @testset "kill switch restores the ungated dense sweep" begin
        rhs = EA.expression_from_json(A_IJ)
        d0, g0, n0 = EA._GEOM_OVERLAP_DRIVE[], EA._GEOM_OVERLAP_GATE_ONLY[],
                     EA._GEOM_OVERLAP_NONE[]
        withenv("ESS_GEOM_OVERLAP_GATE_DISABLE" => "1") do
            EA._materialize_geom_array(rhs, copy(ENV0), nothing, IDX, SHAPES)
        end
        @test EA._GEOM_OVERLAP_DRIVE[] - d0 == 0
        @test EA._GEOM_OVERLAP_GATE_ONLY[] - g0 == 0
        @test EA._GEOM_OVERLAP_NONE[] - n0 == 1        # resolution skipped entirely
    end

    @testset "a shape the planner declines is GATED, not driven" begin
        # Both gated symbols contracted, with an unrelated output index: the
        # planner offers `:pairs`, which the contracting sweep cannot express,
        # so the gate falls back to a per-tuple membership test. Same admitted
        # set, full-product cost — and the values must still match the gated
        # meaning, so compare against the DRIVEN A_ij row-sum rather than the
        # ungated sweep.
        j = _agg(["k"], ["i" => "S", "j" => "T", "k" => "K"],
                 _op("*", _pia(_ix("src_poly", "i"), _ix("tgt_poly", "j")),
                          _ix("kk", "k"));
                 join = _ovj(["src_poly"], ["tgt_poly"]))
        rhs = EA.expression_from_json(j)
        d0, g0 = EA._GEOM_OVERLAP_DRIVE[], EA._GEOM_OVERLAP_GATE_ONLY[]
        got = EA._materialize_geom_array(rhs, copy(ENV0), nothing, IDX, SHAPES)
        @test EA._GEOM_OVERLAP_DRIVE[] - d0 == 0
        @test EA._GEOM_OVERLAP_GATE_ONLY[] - g0 == 1
        # Total overlap area is 4 × 0.04; scaled by kk = [1,2,3].
        total = sum(EA._materialize_geom_array(EA.expression_from_json(A_IJ),
                                               copy(ENV0), nothing, IDX, SHAPES))
        @test all(k -> isapprox(got[k], total * ENV0["kk"][k]; atol = 1e-12), 1:3)
        @test length(unique(got)) > 1
    end

    @testset "an unresolvable clause declines to the ungated sweep" begin
        # Envelope factor not in `env` ⇒ no gate at all, and the historic values.
        j = _agg(["i", "j"], ["i" => "S", "j" => "T"],
                 _pia(_ix("src_poly", "i"), _ix("tgt_poly", "j"));
                 join = _ovj(["not_a_factor"], ["tgt_poly"]))
        got, ref, dd, dg, dn = both_ways(j)
        @test (dd, dg, dn) == (0, 0, 1)
        @test bitsame(got, ref)
        # ... and so does a factor whose shape names no loop var of this sweep.
        j2 = _agg(["i", "j"], ["i" => "S", "j" => "T"],
                  _pia(_ix("src_poly", "i"), _ix("tgt_poly", "j"));
                  join = _ovj(["kk"], ["tgt_poly"]))
        got2, ref2, dd2, dg2, dn2 = both_ways(j2)
        @test (dd2, dg2, dn2) == (0, 0, 1)
        @test bitsame(got2, ref2)
        # ... and so does a single env factor of the WRONG RANK. A 1-name env is
        # a `[pos, verts, coord]` ring stack; handing the Phase-3a primitive a
        # 1-D array there would throw, so the gate declines instead and a
        # document that used to build still builds.
        env3 = merge(copy(ENV0), Dict{String,Any}("flat_src" => Float64[1, 2, 3, 4]))
        sh3 = copy(SHAPES); sh3["flat_src"] = ["S"]
        j3 = _agg(["i", "j"], ["i" => "S", "j" => "T"],
                  _pia(_ix("src_poly", "i"), _ix("tgt_poly", "j"));
                  join = _ovj(["flat_src"], ["tgt_poly"]))
        rhs3 = EA.expression_from_json(j3)
        d3, g3, n3 = EA._GEOM_OVERLAP_DRIVE[], EA._GEOM_OVERLAP_GATE_ONLY[],
                     EA._GEOM_OVERLAP_NONE[]
        got3 = EA._materialize_geom_array(rhs3, env3, nothing, IDX, sh3)
        @test (EA._GEOM_OVERLAP_DRIVE[] - d3, EA._GEOM_OVERLAP_GATE_ONLY[] - g3,
               EA._GEOM_OVERLAP_NONE[] - n3) == (0, 0, 1)
        ref3 = withenv("ESS_GEOM_OVERLAP_GATE_DISABLE" => "1") do
            EA._materialize_geom_array(rhs3, env3, nothing, IDX, sh3)
        end
        @test bitsame(got3, ref3)
    end

    @testset "a document with no overlap clause is untouched" begin
        j = _agg(["i", "j"], ["i" => "S", "j" => "T"],
                 _pia(_ix("src_poly", "i"), _ix("tgt_poly", "j")))
        got, ref, dd, dg, dn = both_ways(j)
        @test (dd, dg, dn) == (0, 0, 1)   # resolution declines before it starts
        @test bitsame(got, ref)
        @test length(unique(got)) > 1
    end

    @testset "the candidate index is memoized per setup pass" begin
        # `_geo_overlap_index` must hand the SAME `_OverlapIndex` back for a
        # repeated clause — that is what stops a six-species regrid from
        # rebuilding the STRtree (and its adjacency views) six times.
        clause = EA.expression_from_json(A_IJ).join[1]
        cache = Dict{Tuple{Vector{String},Vector{String},Float64},EA._OverlapIndex}()
        a = EA._geo_overlap_index(clause, ENV0, cache)
        b = EA._geo_overlap_index(clause, ENV0, cache)
        @test a === b
        @test length(cache) == 1
        @test length(a) == 4                     # exactly the 4 containing pairs
        # ... and with no cache it still resolves, just freshly each time.
        c = EA._geo_overlap_index(clause, ENV0, nothing)
        @test !(c === a)
        @test c.pairs == a.pairs
    end

    @testset "verify-mode assertion catches what `==` would miss" begin
        a = Float64[0.0 1.0; NaN 3.0]
        b = Float64[-0.0 1.0; NaN 3.0]
        @test_throws EarthSciAST.TreeWalkError EA._assert_geom_overlap_bit_identical(
            a, b, ["i", "j"])
        c = Float64[0.0 1.0; 2.0 3.0]
        @test_throws EarthSciAST.TreeWalkError EA._assert_geom_overlap_bit_identical(
            a, c, ["i", "j"])
        @test EA._assert_geom_overlap_bit_identical(a, copy(a), ["i", "j"]) === nothing
    end

end

end # module
