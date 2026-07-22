# Spatial OVERLAP join-gate — Julia evaluator conformance (projection-pushdown
# Phase 2a). The overlap gate replaces uniform-grid bin-EQUALITY (`join.on
# [[l,r]]`) with envelope CANDIDACY built on the Phase-3a broad-phase primitive:
# the gate admits a contracted tuple iff its two range positions are in a
# candidate `(src_pos, tgt_pos)` set computed ONCE from two envelope factor
# arrays. Two end-to-end cases exercise BOTH join wirings:
#
#   (a) POINT-IN-RECTANGLE — a VALUE-INVENTION producer (`_vi_join_ok`): points
#       [X,Y] × cells [W,S,E,N], a `join.overlap` broad phase + a rectangle
#       strict-containment `filter` narrow phase, whose materialised `distinct`
#       set is the EXACT set of cells containing ≥1 point. The broad-phase
#       candidate set is asserted to be a conservative SUPERSET of the true
#       containments.
#
#   (b) REGRID EQUIVALENCE — a MAIN-GRAPH assembly (`_join_admits`): the
#       conservative-regrid A_j / F_tgt aggregates, but gated by `join.overlap`
#       (envelopes from the cell rectangles) INSTEAD of the bin-Skolem
#       `join.on [[src_bin,tgt_bin]]`. After the SAME narrow phase (`filter
#       A_ij > atol`) the A_j / W_ij weights are tol-identical to the bin-gate
#       golden — overlap gate + narrow phase == bin gate + narrow phase.

using Test
using EarthSciAST
import JSON3
# GeometryOps + GeoInterface trigger EarthSciASTGeometryOpsExt (the STRtree fast
# path for the broad phase, and the spherical clip the regrid narrow phase uses).
import GeometryOps
import GeoInterface

const ESS = EarthSciAST

# ---- small JSON AST builders ----------------------------------------------
_ix(f, args...) = Dict("op" => "index", "args" => Any[f, args...])
_op(o, args...) = Dict("op" => o, "args" => Any[args...])

@testset "spatial OVERLAP join-gate (Phase 2a)" begin

    # =======================================================================
    # (a) POINT-IN-RECTANGLE micro fixture — VALUE-INVENTION producer path.
    #
    # cells (rects [W,S,E,N]):  c1=[0,0,2,2] c2=[2,2,4,4] c3=[4,4,6,6] c4=[6,6,8,8]
    # points (coords [X,Y]):    p1=(1,1) p2=(3,3) p3=(2,2) p4=(10,10) p5=(6,6)
    #
    # p1 strictly inside c1, p2 strictly inside c2; p3 sits on the shared c1/c2
    # corner, p5 on the shared c3/c4 corner (both broad candidates for two cells
    # but on the boundary), p4 is outside every cell. Hand-computed:
    #   • strict containments (true set): {(p1,c1),(p2,c2)}  → cells {1,2}
    #   • closed-envelope broad candidates ⊋ that, adding the boundary pairs
    #     (p3,c1),(p3,c2),(p5,c3),(p5,c4).
    # The narrow `filter` (X-W)(E-X)(Y-S)(N-Y) > 0 is >0 ONLY at the strict
    # interior for a broad candidate (each factor ≥ 0 there; a boundary hit zeros
    # the product), so it drops the boundary pairs — LOAD-BEARING: without it the
    # distinct set would spuriously include c3,c4 from p5.
    # =======================================================================
    _PX = [1.0, 3.0, 2.0, 10.0, 6.0]
    _PY = [1.0, 3.0, 2.0, 10.0, 6.0]
    _CW = [0.0, 2.0, 4.0, 6.0]; _CS = [0.0, 2.0, 4.0, 6.0]
    _CE = [2.0, 4.0, 6.0, 8.0]; _CN = [2.0, 4.0, 6.0, 8.0]
    _pir_const = Dict{String,Any}(
        "X" => _PX, "Y" => _PY, "W" => _CW, "S" => _CS, "E" => _CE, "N" => _CN)

    # (X-W)(E-X)(Y-S)(N-Y) > 0 : strict rectangle interior narrow phase.
    _pir_filter = _op(">",
        _op("*",
            _op("*", _op("-", _ix("X", "i"), _ix("W", "j")),
                     _op("-", _ix("E", "j"), _ix("X", "i"))),
            _op("*", _op("-", _ix("Y", "i"), _ix("S", "j")),
                     _op("-", _ix("N", "j"), _ix("Y", "i")))),
        0.0)

    _pir_doc = Dict(
        "esm" => "0.6.0",
        "metadata" => Dict("name" => "overlap_gate_point_in_rect"),
        "index_sets" => Dict(
            "points" => Dict("kind" => "interval", "size" => 5),
            "cells"  => Dict("kind" => "interval", "size" => 4),
            "present_cells" => Dict("kind" => "derived", "from_faq" => "cells_with_points")),
        "models" => Dict("PointInRect" => Dict(
            "variables" => Dict(
                "X" => Dict("type" => "parameter", "shape" => ["points"]),
                "Y" => Dict("type" => "parameter", "shape" => ["points"]),
                "W" => Dict("type" => "parameter", "shape" => ["cells"]),
                "S" => Dict("type" => "parameter", "shape" => ["cells"]),
                "E" => Dict("type" => "parameter", "shape" => ["cells"]),
                "N" => Dict("type" => "parameter", "shape" => ["cells"]),
                "cell_present" => Dict("type" => "state", "shape" => ["present_cells"])),
            "equations" => [Dict(
                "lhs" => _ix("cell_present", "m"),
                "rhs" => Dict(
                    "op" => "aggregate",
                    "id" => "cells_with_points",
                    "semiring" => "bool_and_or",
                    "distinct" => true,
                    "output_idx" => ["m"],
                    "ranges" => Dict("i" => Dict("from" => "points"),
                                     "j" => Dict("from" => "cells")),
                    "join" => [Dict("overlap" => Dict(
                        "src_env" => ["X", "Y"],
                        "tgt_env" => ["W", "S", "E", "N"],
                        "eps" => 0.0))],
                    "filter" => _pir_filter,
                    "args" => ["X", "Y", "W", "S", "E", "N"],
                    "key" => Dict("op" => "skolem", "label" => "cell", "args" => ["j"]),
                    "expr" => Dict("op" => "true", "args" => [])))])))

    @testset "broad-phase candidate set ⊇ true containments (conservative)" begin
        cs = ESS._overlap_candidate_set(["X", "Y"], ["W", "S", "E", "N"], _pir_const; eps=0.0)
        # closed-envelope point-in-rect candidates (see header):
        @test cs == Set([(1, 1), (2, 2), (3, 1), (3, 2), (5, 3), (5, 4)])
        # conservative superset of the true strict containments
        true_containments = Set([(1, 1), (2, 2)])
        @test true_containments ⊆ cs
        # STRtree fast path == brute-force core (Phase-3a byte-identity)
        srcv = ESS._envelope_vectors(["X", "Y"], _pir_const)
        tgtv = ESS._envelope_vectors(["W", "S", "E", "N"], _pir_const)
        @test Set(ESS.broad_phase_candidates(srcv, tgtv; eps=0.0)) == cs
    end

    @testset "materialised distinct set == cells containing ≥1 point (narrow phase)" begin
        file = ESS.coerce_esm_file(JSON3.read(JSON3.write(_pir_doc)))
        model = ESS._select_model(file, "PointInRect")
        vi = ESS.materialize_value_invention(model, file.index_sets, _pir_const,
                                             Dict{String,Any}())
        # skolem("cell", j) → single-component key = the integer cell index; the
        # distinct set is the exact hand-computed {1,2}.
        @test sort(collect(vi.members["cells_with_points"])) == [1, 2]
        @test vi.extents["cells_with_points"] == 2
    end

    # =======================================================================
    # (b) REGRID EQUIVALENCE — MAIN-GRAPH assembly gated by join.overlap.
    #
    # Same grids / A_ij as geometry_overlap_join_conformance_test.jl, but the A_j
    # and F_tgt aggregates gate on join.overlap over the CELL RECTANGLES instead
    # of join.on [[src_bin,tgt_bin]]. After the shared `filter A_ij > atol` the
    # surviving set is the true positive-area overlaps, so A_j == dst_areas and
    # F_tgt == the golden — for ANY eps ≥ 0 (the filter removes the extra broad
    # candidates), overlap gate + narrow phase == bin gate + narrow phase.
    # =======================================================================
    _rect(x0, x1, y0, y1) = [x0 y0; x1 y0; x1 y1; x0 y1]
    _SRC = [_rect(0, 1, 0, 1), _rect(1, 2, 0, 1), _rect(2, 3, 0, 1)]
    _TGT = [_rect(0, 1.5, 0, 1), _rect(1.5, 2, 0, 1), _rect(2, 3, 0, 1)]
    _F_SRC = [10.0, 20.0, 30.0]
    # cell-rectangle envelope factors [W,S,E,N]
    _SRC_W = [0.0, 1.0, 2.0]; _SRC_S = [0.0, 0.0, 0.0]
    _SRC_E = [1.0, 2.0, 3.0]; _SRC_N = [1.0, 1.0, 1.0]
    _TGT_W = [0.0, 1.5, 2.0]; _TGT_S = [0.0, 0.0, 0.0]
    _TGT_E = [1.5, 2.0, 3.0]; _TGT_N = [1.0, 1.0, 1.0]
    # the bin-Skolem CANDIDATE pairs the original fixture's join.on produces
    # (floor(repr_lon/2)): cells {1,2} share lon-bin 0, cell 3 is lon-bin 1.
    _BIN_PAIRS = Set([(1, 1), (1, 2), (2, 1), (2, 2), (3, 3)])

    # build-once A_ij = spherical overlap area (the same VOS clip the sibling test
    # uses); dst_areas = column sums (= A_j golden).
    _Aij = zeros(Float64, 3, 3)
    for i in 1:3, j in 1:3
        ring = ESS.intersect_polygon(_SRC[i], _TGT[j], "spherical")
        size(ring, 1) < 3 && continue
        _Aij[i, j] = ESS.polygon_area(ring, "spherical")
    end
    _dst_areas = vec(sum(_Aij; dims=1))
    _survive = Set((i, j) for i in 1:3, j in 1:3 if _Aij[i, j] > 1e-15)

    # A_j[j] = Σ_i A_ij[i,j] and F_tgt[j] = Σ_i A_ij[i,j]·F_src[i] / dst_areas[j],
    # both gated by join.overlap(src rect ~ tgt rect) + filter A_ij > atol.
    _ovl(eps) = [Dict("overlap" => Dict(
        "src_env" => ["src_W", "src_S", "src_E", "src_N"],
        "tgt_env" => ["tgt_W", "tgt_S", "tgt_E", "tgt_N"],
        "eps" => eps))]
    _filt = _op(">", _ix("A_ij", "i", "j"), "atol")

    _regrid_doc(eps) = Dict(
        "esm" => "0.6.0",
        "metadata" => Dict("name" => "overlap_gate_regrid"),
        "index_sets" => Dict(
            "src_cells" => Dict("kind" => "interval", "size" => 3),
            "tgt_cells" => Dict("kind" => "interval", "size" => 3)),
        "models" => Dict("RegridOverlap" => Dict(
            "variables" => Dict(
                "A_ij" => Dict("type" => "parameter", "shape" => ["src_cells", "tgt_cells"]),
                "F_src" => Dict("type" => "parameter", "shape" => ["src_cells"]),
                "dst_areas" => Dict("type" => "parameter", "shape" => ["tgt_cells"]),
                "atol" => Dict("type" => "parameter", "shape" => []),
                "src_W" => Dict("type" => "parameter", "shape" => ["src_cells"]),
                "src_S" => Dict("type" => "parameter", "shape" => ["src_cells"]),
                "src_E" => Dict("type" => "parameter", "shape" => ["src_cells"]),
                "src_N" => Dict("type" => "parameter", "shape" => ["src_cells"]),
                "tgt_W" => Dict("type" => "parameter", "shape" => ["tgt_cells"]),
                "tgt_S" => Dict("type" => "parameter", "shape" => ["tgt_cells"]),
                "tgt_E" => Dict("type" => "parameter", "shape" => ["tgt_cells"]),
                "tgt_N" => Dict("type" => "parameter", "shape" => ["tgt_cells"]),
                "A_j" => Dict("type" => "state", "shape" => ["tgt_cells"]),
                "F_tgt" => Dict("type" => "state", "shape" => ["tgt_cells"])),
            "equations" => [
                Dict(
                    "lhs" => Dict("op" => "aggregate", "args" => [], "output_idx" => ["j"],
                        "expr" => Dict("op" => "D", "args" => [_ix("A_j", "j")], "wrt" => "t"),
                        "ranges" => Dict("j" => [1, 3])),
                    "rhs" => Dict("op" => "aggregate", "semiring" => "sum_product",
                        "output_idx" => ["j"],
                        "ranges" => Dict("i" => Dict("from" => "src_cells"),
                                         "j" => Dict("from" => "tgt_cells")),
                        "join" => _ovl(eps), "filter" => _filt,
                        "args" => ["A_ij", "src_W", "src_S", "src_E", "src_N",
                                   "tgt_W", "tgt_S", "tgt_E", "tgt_N"],
                        "expr" => _ix("A_ij", "i", "j"))),
                Dict(
                    "lhs" => Dict("op" => "aggregate", "args" => [], "output_idx" => ["j"],
                        "expr" => Dict("op" => "D", "args" => [_ix("F_tgt", "j")], "wrt" => "t"),
                        "ranges" => Dict("j" => [1, 3])),
                    "rhs" => Dict("op" => "aggregate", "semiring" => "sum_product",
                        "output_idx" => ["j"],
                        "ranges" => Dict("i" => Dict("from" => "src_cells"),
                                         "j" => Dict("from" => "tgt_cells")),
                        "join" => _ovl(eps), "filter" => _filt,
                        "args" => ["A_ij", "F_src", "dst_areas", "src_W", "src_S", "src_E",
                                   "src_N", "tgt_W", "tgt_S", "tgt_E", "tgt_N"],
                        "expr" => _op("/", _op("*", _ix("A_ij", "i", "j"), _ix("F_src", "i")),
                                      _ix("dst_areas", "j"))))])))

    _regrid_const = Dict{String,Any}(
        "A_ij" => _Aij, "F_src" => _F_SRC, "dst_areas" => _dst_areas,
        "src_W" => _SRC_W, "src_S" => _SRC_S, "src_E" => _SRC_E, "src_N" => _SRC_N,
        "tgt_W" => _TGT_W, "tgt_S" => _TGT_S, "tgt_E" => _TGT_E, "tgt_N" => _TGT_N)

    function _regrid_eval(eps; atol=1e-15)
        raw = JSON3.read(JSON3.write(_regrid_doc(eps)))
        ics = Dict("A_j[1]" => 0.0, "A_j[2]" => 0.0, "A_j[3]" => 0.0,
                   "F_tgt[1]" => 0.0, "F_tgt[2]" => 0.0, "F_tgt[3]" => 0.0)
        f!, u0, p, _, vmap = build_evaluator(
            raw; model_name="RegridOverlap", initial_conditions=ics,
            const_arrays=_regrid_const, parameter_overrides=Dict("atol" => atol))
        du = similar(u0); f!(du, u0, p, 0.0)
        A_j = [du[vmap["A_j[$j]"]] for j in 1:3]
        F_tgt = [du[vmap["F_tgt[$j]"]] for j in 1:3]
        return A_j, F_tgt
    end

    @testset "overlap candidate set is a conservative superset (eps=0)" begin
        cs = ESS._overlap_candidate_set(
            ["src_W", "src_S", "src_E", "src_N"], ["tgt_W", "tgt_S", "tgt_E", "tgt_N"],
            _regrid_const; eps=0.0)
        # every true positive-area overlap is a candidate (never missed)
        @test _survive ⊆ cs
    end

    @testset "inflated overlap gate (eps>0) ⊇ the bin-gate candidate pairs" begin
        # an eps that bridges the widest bin gap makes the envelope candidacy a
        # conservative SUPERSET of the coarser bin-equality candidate set.
        cs = ESS._overlap_candidate_set(
            ["src_W", "src_S", "src_E", "src_N"], ["tgt_W", "tgt_S", "tgt_E", "tgt_N"],
            _regrid_const; eps=0.5)
        @test _BIN_PAIRS ⊆ cs
    end

    @testset "A_j == dst_areas (overlap gate + narrow phase == bin gate golden)" begin
        for eps in (0.0, 0.5)
            A_j, _ = _regrid_eval(eps)
            @test A_j ≈ _dst_areas
        end
    end

    @testset "F_tgt == golden apply+normalize (tol-identical to bin gate)" begin
        F_expected = [sum(_Aij[i, j] * _F_SRC[i] for i in 1:3) / _dst_areas[j] for j in 1:3]
        for eps in (0.0, 0.5)
            _, F_tgt = _regrid_eval(eps)
            @test F_tgt ≈ F_expected
        end
    end

    @testset "PARTITION-OF-UNITY over the overlap-gated weights" begin
        A_j, _ = _regrid_eval(0.0)
        for j in 1:3
            @test isapprox(sum(_Aij[i, j] for i in 1:3) / A_j[j], 1.0; rtol=1e-12, atol=1e-12)
        end
    end
end
