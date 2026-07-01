# Declarative conservative-regrid overlap matrix through the tree-walk evaluator.
#
# The single-clip M4 kernel materializes ONE intersect_polygon ring from whole-
# array const operands. This exercises the M4+ extension: intersect_polygon RANGED
# over the src × tgt candidate pairs, so the overlap-area matrix A_ij is computed
# DECLARATIVELY — `A_ij = polygon_area(intersect_polygon(src_i, tgt_j))` over all
# pairs, the shoelace `aggregate` FAQ — with NO host-supplied A_ij/dst_areas. The
# whole geometry chain (clip → A_ij → A_j → F_tgt apply) is build-once at setup
# from the const polygon inputs, then `build_evaluator` integrates the apply.
#
# 2×2 case (planar, unit squares):
#   src cells: [0,1]² and [1,2]×[0,1];  tgt cells: [0,1]² and [0.5,1.5]×[0,1]
#   overlaps  A_ij = [[1.0, 0.5], [0.0, 0.5]]      (1.0 = full, 0.5 = half, 0.0 = none)
#   A_j       = Σ_i A_ij = [1.0, 1.0]
#   F_src     = [10, 20]  ⇒  F_tgt = A_ijᵀ·F_src / A_j = [10.0, 15.0]

using Test
using EarthSciSerialization
const _ESS = EarthSciSerialization

# ---- compact AST builders ----
_ix(args...) = Dict{String,Any}("op" => "index", "args" => collect(Any, args))
_agg(lv, set, body) = Dict{String,Any}(
    "op" => "aggregate", "semiring" => "sum_product", "output_idx" => Any[],
    "ranges" => Dict{String,Any}(lv => Dict{String,Any}("from" => set)),
    "args" => Any[], "expr" => body)
_arrop(oidx, ranges, body) = Dict{String,Any}(
    "op" => "arrayop", "output_idx" => collect(Any, oidx),
    "ranges" => Dict{String,Any}(k => Dict{String,Any}("from" => v) for (k, v) in ranges),
    "args" => Any[], "expr" => body)
_D(s, rhs) = Dict{String,Any}(
    "lhs" => Dict{String,Any}("op" => "D", "args" => Any[s], "wrt" => "t"), "rhs" => rhs)

function _ranged_clip_regrid_esm()
    ip = Dict{String,Any}("op" => "intersect_polygon", "id" => "overlap_clip",
        "manifold" => "planar", "args" => Any[_ix("src_poly", "i"), _ix("tgt_poly", "j")])
    # clip[i,j,w,c] = intersect_polygon(src_poly[i], tgt_poly[j])[w,c]
    clip = _arrop(["i", "j", "w", "c"],
        ["i" => "src_cells", "j" => "tgt_cells", "w" => "clip_ring", "c" => "coord"],
        _ix(ip, "w", "c"))
    # A_ij[i,j] = shoelace polygon_area over clip[i,j]
    vp1 = Dict{String,Any}("op" => "+", "args" => Any["v", 1])
    shoe = Dict{String,Any}("op" => "*", "args" => Any[0.5,
        Dict{String,Any}("op" => "-", "args" => Any[
            Dict{String,Any}("op" => "*", "args" => Any[_ix("clip","i","j","v",1), _ix("clip","i","j",vp1,2)]),
            Dict{String,Any}("op" => "*", "args" => Any[_ix("clip","i","j",vp1,1), _ix("clip","i","j","v",2)])])])
    A_ij = _arrop(["i", "j"], ["i" => "src_cells", "j" => "tgt_cells"], _agg("v", "clip_ring", shoe))
    A_j  = _arrop(["j"], ["j" => "tgt_cells"], _agg("i", "src_cells", _ix("A_ij", "i", "j")))
    num  = _agg("i", "src_cells", Dict{String,Any}("op" => "*",
                "args" => Any[_ix("A_ij", "i", "j"), _ix("F_src", "i")]))
    F_tgt = _arrop(["j"], ["j" => "tgt_cells"], Dict{String,Any}("op" => "/", "args" => Any[num, _ix("A_j", "j")]))

    model = Dict{String,Any}(
        "variables" => Dict{String,Any}(
            "src_poly" => Dict{String,Any}("type" => "parameter", "shape" => Any["src_cells", "verts", "coord"]),
            "tgt_poly" => Dict{String,Any}("type" => "parameter", "shape" => Any["tgt_cells", "verts", "coord"]),
            "F_src"    => Dict{String,Any}("type" => "parameter", "shape" => Any["src_cells"]),
            "clip"  => Dict{String,Any}("type" => "observed", "shape" => Any["src_cells","tgt_cells","clip_ring","coord"], "expression" => clip),
            "A_ij"  => Dict{String,Any}("type" => "observed", "shape" => Any["src_cells","tgt_cells"], "expression" => A_ij),
            "A_j"   => Dict{String,Any}("type" => "observed", "shape" => Any["tgt_cells"], "expression" => A_j),
            "F_tgt" => Dict{String,Any}("type" => "observed", "shape" => Any["tgt_cells"], "expression" => F_tgt),
            "A11" => Dict{String,Any}("type" => "state", "shape" => Any[]),
            "A12" => Dict{String,Any}("type" => "state", "shape" => Any[]),
            "A21" => Dict{String,Any}("type" => "state", "shape" => Any[]),
            "A22" => Dict{String,Any}("type" => "state", "shape" => Any[]),
            "FT1" => Dict{String,Any}("type" => "state", "shape" => Any[]),
            "FT2" => Dict{String,Any}("type" => "state", "shape" => Any[])),
        "equations" => Any[
            _D("A11", _ix("A_ij", 1, 1)), _D("A12", _ix("A_ij", 1, 2)),
            _D("A21", _ix("A_ij", 2, 1)), _D("A22", _ix("A_ij", 2, 2)),
            _D("FT1", _ix("F_tgt", 1)),   _D("FT2", _ix("F_tgt", 2))])
    return Dict{String,Any}(
        "esm" => "0.6.0", "metadata" => Dict{String,Any}("name" => "ranged_clip_regrid_2x2"),
        # esm-spec v0.8.0: document-scoped index-set registry.
        "index_sets" => Dict{String,Any}(
            "coord" => Dict{String,Any}("kind" => "interval", "size" => 2),
            "verts" => Dict{String,Any}("kind" => "interval", "size" => 4),
            "src_cells" => Dict{String,Any}("kind" => "interval", "size" => 2),
            "tgt_cells" => Dict{String,Any}("kind" => "interval", "size" => 2),
            "clip_ring" => Dict{String,Any}("kind" => "derived", "from_faq" => "overlap_clip")),
        "models" => Dict{String,Any}("RangedClipRegrid2x2" => model))
end

@testset "Declarative conservative-regrid A_ij via ranged intersect_polygon (M4+)" begin
    esm = _ranged_clip_regrid_esm()

    src_poly = zeros(2, 4, 2)
    tgt_poly = zeros(2, 4, 2)
    src_poly[1, :, :] = [0 0; 1 0; 1 1; 0 1]   # [0,1]²
    src_poly[2, :, :] = [1 0; 2 0; 2 1; 1 1]   # [1,2]×[0,1]
    tgt_poly[1, :, :] = [0 0; 1 0; 1 1; 0 1]   # [0,1]²
    tgt_poly[2, :, :] = [0.5 0; 1.5 0; 1.5 1; 0.5 1]   # [0.5,1.5]×[0,1]
    F_src = [10.0, 20.0]

    f!, u0, p, _tspan, vmap = build_evaluator(esm;
        const_arrays = Dict("src_poly" => src_poly, "tgt_poly" => tgt_poly, "F_src" => F_src),
        initial_conditions = Dict("A11" => 0.0, "A12" => 0.0, "A21" => 0.0,
                                  "A22" => 0.0, "FT1" => 0.0, "FT2" => 0.0))
    du = similar(u0)
    f!(du, u0, p, 0.0)

    # A_ij computed declaratively from the const polygons (no host A_ij).
    @test du[vmap["A11"]] ≈ 1.0 atol = 1e-12
    @test du[vmap["A12"]] ≈ 0.5 atol = 1e-12
    @test du[vmap["A21"]] ≈ 0.0 atol = 1e-12
    @test du[vmap["A22"]] ≈ 0.5 atol = 1e-12
    # F_tgt = the regridded field through the full declarative apply.
    @test du[vmap["FT1"]] ≈ 10.0 atol = 1e-12
    @test du[vmap["FT2"]] ≈ 15.0 atol = 1e-12
end

# ---------------------------------------------------------------------------
# ON-DISK / SCHEMA-VALID form: the array-producing FAQ op is `aggregate` with a
# non-empty `output_idx`, NOT the internal `arrayop` alias `shape_promotion.jl`
# emits (schema v0.8.0 dropped `arrayop` from the op enum — see
# tests/valid/geometry/conservative_regrid_overlap_join.esm, where `clip` is an
# `aggregate` node with output_idx [i,j,w,c] wrapping intersect_polygon). This is
# the byte-identical 2×2 regrid of the first testset with every array-producing
# node authored as `aggregate`, proving the ranged (fixed-extent) intersect_polygon
# clip is materialized through the SAME `_materialize_ranged_clip` path — i.e. the
# setup dispatch recognizes the on-disk `aggregate` clip, not only `arrayop`.
# ---------------------------------------------------------------------------

# Array-producing aggregate: `aggregate` op with a non-empty `output_idx` (the
# schema-valid on-disk spelling of the internal `arrayop`).
_arrop_agg(oidx, ranges, body) = Dict{String,Any}(
    "op" => "aggregate", "semiring" => "sum_product", "output_idx" => collect(Any, oidx),
    "ranges" => Dict{String,Any}(k => Dict{String,Any}("from" => v) for (k, v) in ranges),
    "args" => Any[], "expr" => body)

function _ranged_clip_regrid_esm_aggregate()
    ip = Dict{String,Any}("op" => "intersect_polygon", "id" => "overlap_clip",
        "manifold" => "planar", "args" => Any[_ix("src_poly", "i"), _ix("tgt_poly", "j")])
    clip = _arrop_agg(["i", "j", "w", "c"],
        ["i" => "src_cells", "j" => "tgt_cells", "w" => "clip_ring", "c" => "coord"],
        _ix(ip, "w", "c"))
    vp1 = Dict{String,Any}("op" => "+", "args" => Any["v", 1])
    shoe = Dict{String,Any}("op" => "*", "args" => Any[0.5,
        Dict{String,Any}("op" => "-", "args" => Any[
            Dict{String,Any}("op" => "*", "args" => Any[_ix("clip","i","j","v",1), _ix("clip","i","j",vp1,2)]),
            Dict{String,Any}("op" => "*", "args" => Any[_ix("clip","i","j",vp1,1), _ix("clip","i","j","v",2)])])])
    A_ij = _arrop_agg(["i", "j"], ["i" => "src_cells", "j" => "tgt_cells"], _agg("v", "clip_ring", shoe))
    A_j  = _arrop_agg(["j"], ["j" => "tgt_cells"], _agg("i", "src_cells", _ix("A_ij", "i", "j")))
    num  = _agg("i", "src_cells", Dict{String,Any}("op" => "*",
                "args" => Any[_ix("A_ij", "i", "j"), _ix("F_src", "i")]))
    F_tgt = _arrop_agg(["j"], ["j" => "tgt_cells"], Dict{String,Any}("op" => "/", "args" => Any[num, _ix("A_j", "j")]))

    model = Dict{String,Any}(
        "variables" => Dict{String,Any}(
            "src_poly" => Dict{String,Any}("type" => "parameter", "shape" => Any["src_cells", "verts", "coord"]),
            "tgt_poly" => Dict{String,Any}("type" => "parameter", "shape" => Any["tgt_cells", "verts", "coord"]),
            "F_src"    => Dict{String,Any}("type" => "parameter", "shape" => Any["src_cells"]),
            "clip"  => Dict{String,Any}("type" => "observed", "shape" => Any["src_cells","tgt_cells","clip_ring","coord"], "expression" => clip),
            "A_ij"  => Dict{String,Any}("type" => "observed", "shape" => Any["src_cells","tgt_cells"], "expression" => A_ij),
            "A_j"   => Dict{String,Any}("type" => "observed", "shape" => Any["tgt_cells"], "expression" => A_j),
            "F_tgt" => Dict{String,Any}("type" => "observed", "shape" => Any["tgt_cells"], "expression" => F_tgt),
            "A11" => Dict{String,Any}("type" => "state", "shape" => Any[]),
            "A12" => Dict{String,Any}("type" => "state", "shape" => Any[]),
            "A21" => Dict{String,Any}("type" => "state", "shape" => Any[]),
            "A22" => Dict{String,Any}("type" => "state", "shape" => Any[]),
            "FT1" => Dict{String,Any}("type" => "state", "shape" => Any[]),
            "FT2" => Dict{String,Any}("type" => "state", "shape" => Any[])),
        "equations" => Any[
            _D("A11", _ix("A_ij", 1, 1)), _D("A12", _ix("A_ij", 1, 2)),
            _D("A21", _ix("A_ij", 2, 1)), _D("A22", _ix("A_ij", 2, 2)),
            _D("FT1", _ix("F_tgt", 1)),   _D("FT2", _ix("F_tgt", 2))])
    return Dict{String,Any}(
        "esm" => "0.6.0", "metadata" => Dict{String,Any}("name" => "ranged_clip_regrid_2x2_aggregate"),
        "index_sets" => Dict{String,Any}(
            "coord" => Dict{String,Any}("kind" => "interval", "size" => 2),
            "verts" => Dict{String,Any}("kind" => "interval", "size" => 4),
            "src_cells" => Dict{String,Any}("kind" => "interval", "size" => 2),
            "tgt_cells" => Dict{String,Any}("kind" => "interval", "size" => 2),
            "clip_ring" => Dict{String,Any}("kind" => "derived", "from_faq" => "overlap_clip")),
        "models" => Dict{String,Any}("RangedClipRegrid2x2Agg" => model))
end

@testset "Ranged intersect_polygon clip authored as on-disk `aggregate` (schema v0.8.0)" begin
    esm = _ranged_clip_regrid_esm_aggregate()

    src_poly = zeros(2, 4, 2)
    tgt_poly = zeros(2, 4, 2)
    src_poly[1, :, :] = [0 0; 1 0; 1 1; 0 1]   # [0,1]²
    src_poly[2, :, :] = [1 0; 2 0; 2 1; 1 1]   # [1,2]×[0,1]
    tgt_poly[1, :, :] = [0 0; 1 0; 1 1; 0 1]   # [0,1]²
    tgt_poly[2, :, :] = [0.5 0; 1.5 0; 1.5 1; 0.5 1]   # [0.5,1.5]×[0,1]
    F_src = [10.0, 20.0]

    f!, u0, p, _tspan, vmap = build_evaluator(esm;
        const_arrays = Dict("src_poly" => src_poly, "tgt_poly" => tgt_poly, "F_src" => F_src),
        initial_conditions = Dict("A11" => 0.0, "A12" => 0.0, "A21" => 0.0,
                                  "A22" => 0.0, "FT1" => 0.0, "FT2" => 0.0))
    du = similar(u0)
    f!(du, u0, p, 0.0)

    # Identical results to the `arrayop`-authored chain — proves the on-disk
    # `aggregate` ranged clip reaches the dense ranged-clip evaluator.
    @test du[vmap["A11"]] ≈ 1.0 atol = 1e-12
    @test du[vmap["A12"]] ≈ 0.5 atol = 1e-12
    @test du[vmap["A21"]] ≈ 0.0 atol = 1e-12
    @test du[vmap["A22"]] ≈ 0.5 atol = 1e-12
    @test du[vmap["FT1"]] ≈ 10.0 atol = 1e-12
    @test du[vmap["FT2"]] ≈ 15.0 atol = 1e-12
end

# ---------------------------------------------------------------------------
# Broad-phase: the A_j / F_tgt apply aggregates carry a `join` on the bin
# buffers (the bin-skolem spatial join — only candidate pairs sharing a bin
# contribute) and a sliver `filter`. The setup evaluator honors both, including
# a join key column (`tgt_bin`) indexed by the OUTER F_tgt loop var. To make the
# gate OBSERVABLE we bin so it excludes an overlapping pair: with the join,
# F_tgt[2]=20; the ungated full product would give 15.
# ---------------------------------------------------------------------------

_aggjf(lv, set, body, args) = Dict{String,Any}(
    "op" => "aggregate", "semiring" => "sum_product", "output_idx" => Any[],
    "ranges" => Dict{String,Any}(lv => Dict{String,Any}("from" => set)),
    "join" => Any[Dict{String,Any}("on" => Any[Any["src_bin", "tgt_bin"]])],
    "filter" => Dict{String,Any}("op" => ">", "args" => Any[_ix("A_ij", "i", "j"), "atol"]),
    "args" => args, "expr" => body)

function _broadphase_regrid_esm()
    ip = Dict{String,Any}("op" => "intersect_polygon", "id" => "overlap_clip",
        "manifold" => "planar", "args" => Any[_ix("src_poly", "i"), _ix("tgt_poly", "j")])
    clip = _arrop(["i", "j", "w", "c"],
        ["i" => "src_cells", "j" => "tgt_cells", "w" => "clip_ring", "c" => "coord"], _ix(ip, "w", "c"))
    vp1 = Dict{String,Any}("op" => "+", "args" => Any["v", 1])
    shoe = Dict{String,Any}("op" => "*", "args" => Any[0.5,
        Dict{String,Any}("op" => "-", "args" => Any[
            Dict{String,Any}("op" => "*", "args" => Any[_ix("clip","i","j","v",1), _ix("clip","i","j",vp1,2)]),
            Dict{String,Any}("op" => "*", "args" => Any[_ix("clip","i","j",vp1,1), _ix("clip","i","j","v",2)])])])
    A_ij = _arrop(["i", "j"], ["i" => "src_cells", "j" => "tgt_cells"], _agg("v", "clip_ring", shoe))
    flr(x) = Dict{String,Any}("op" => "floor", "args" => Any[Dict{String,Any}("op" => "/", "args" => Any[x, "dx_bin"])])
    src_bin = _arrop(["i"], ["i" => "src_cells"], flr(_ix("src_cx", "i")))
    tgt_bin = _arrop(["j"], ["j" => "tgt_cells"], flr(_ix("tgt_cx", "j")))
    A_j = _arrop(["j"], ["j" => "tgt_cells"], _aggjf("i", "src_cells", _ix("A_ij", "i", "j"),
                                                     Any["A_ij", "src_bin", "tgt_bin"]))
    num = _aggjf("i", "src_cells",
        Dict{String,Any}("op" => "*", "args" => Any[_ix("A_ij", "i", "j"), _ix("F_src", "i")]),
        Any["A_ij", "F_src", "src_bin", "tgt_bin"])
    F_tgt = _arrop(["j"], ["j" => "tgt_cells"], Dict{String,Any}("op" => "/", "args" => Any[num, _ix("A_j", "j")]))
    P(shape...) = Dict{String,Any}("type" => "parameter", "shape" => collect(Any, shape))
    O(expr, shape...) = Dict{String,Any}("type" => "observed", "shape" => collect(Any, shape), "expression" => expr)
    model = Dict{String,Any}(
        "variables" => Dict{String,Any}(
            "src_poly" => P("src_cells", "verts", "coord"), "tgt_poly" => P("tgt_cells", "verts", "coord"),
            "src_cx" => P("src_cells"), "tgt_cx" => P("tgt_cells"), "F_src" => P("src_cells"),
            "dx_bin" => Dict{String,Any}("type" => "parameter", "default" => 1.0),
            "atol"   => Dict{String,Any}("type" => "parameter", "default" => 1.0e-9),
            "src_bin" => O(src_bin, "src_cells"), "tgt_bin" => O(tgt_bin, "tgt_cells"),
            "clip" => O(clip, "src_cells", "tgt_cells", "clip_ring", "coord"),
            "A_ij" => O(A_ij, "src_cells", "tgt_cells"), "A_j" => O(A_j, "tgt_cells"),
            "F_tgt" => O(F_tgt, "tgt_cells"),
            "AJ1" => Dict{String,Any}("type"=>"state","shape"=>Any[]), "AJ2" => Dict{String,Any}("type"=>"state","shape"=>Any[]),
            "FT1" => Dict{String,Any}("type"=>"state","shape"=>Any[]), "FT2" => Dict{String,Any}("type"=>"state","shape"=>Any[])),
        "equations" => Any[_D("AJ1", _ix("A_j", 1)), _D("AJ2", _ix("A_j", 2)),
                           _D("FT1", _ix("F_tgt", 1)), _D("FT2", _ix("F_tgt", 2))])
    return Dict{String,Any}("esm" => "0.6.0", "metadata" => Dict{String,Any}("name" => "broadphase_regrid"),
        "index_sets" => Dict{String,Any}(
            "coord" => Dict{String,Any}("kind" => "interval", "size" => 2),
            "verts" => Dict{String,Any}("kind" => "interval", "size" => 4),
            "src_cells" => Dict{String,Any}("kind" => "interval", "size" => 3),
            "tgt_cells" => Dict{String,Any}("kind" => "interval", "size" => 2),
            "clip_ring" => Dict{String,Any}("kind" => "derived", "from_faq" => "overlap_clip")),
        "models" => Dict{String,Any}("BroadphaseRegrid" => model))
end

@testset "Broad-phase join + sliver filter on a declarative conservative regrid (M4+)" begin
    esm = _broadphase_regrid_esm()
    sp = zeros(3, 4, 2); tp = zeros(2, 4, 2)
    sp[1, :, :] = [0 0; 1 0; 1 1; 0 1]; sp[2, :, :] = [1 0; 2 0; 2 1; 1 1]; sp[3, :, :] = [10 0; 11 0; 11 1; 10 1]
    tp[1, :, :] = [0 0; 1 0; 1 1; 0 1]; tp[2, :, :] = [0.5 0; 1.5 0; 1.5 1; 0.5 1]
    f!, u0, p, _t, vmap = build_evaluator(esm;
        const_arrays = Dict("src_poly" => sp, "tgt_poly" => tp,
                            "src_cx" => [0.5, 1.5, 10.5], "tgt_cx" => [0.5, 1.0], "F_src" => [10.0, 20.0, 99.0]),
        initial_conditions = Dict("AJ1" => 0.0, "AJ2" => 0.0, "FT1" => 0.0, "FT2" => 0.0))
    du = similar(u0); f!(du, u0, p, 0.0)
    # bins src=[0,1,10], tgt=[0,1] ⇒ candidates {(1,1),(2,2)}; the join excludes the
    # overlapping but cross-bin (1,2)/(2,1) pairs, so A_j and F_tgt see only candidates.
    @test du[vmap["AJ1"]] ≈ 1.0 atol = 1e-12
    @test du[vmap["AJ2"]] ≈ 0.5 atol = 1e-12      # full-product would be 1.0
    @test du[vmap["FT1"]] ≈ 10.0 atol = 1e-12
    @test du[vmap["FT2"]] ≈ 20.0 atol = 1e-12     # full-product would be 15.0 — proves the gate fires
end

# ---------------------------------------------------------------------------
# Geometry CONSTRUCTED from grid params + LIVE F_src field. The cell polygons are
# built from a grid origin/spacing (a cartesian cell-corner construction — the LCC
# construction is the same pattern with trig), so NOTHING is injected but the grid
# params and the field. The regrid weights (A_ij/A_j) build once at setup; F_tgt is
# an ODE state computed from a LIVE `param_arrays` F_src buffer, so mutating the
# buffer updates the output with no rebuild (the loader-refresh path).
# 4→2 coarsening: F_tgt[j] = mean of the two src cells under tgt cell j.
# ---------------------------------------------------------------------------

_eq(o, args...) = Dict{String,Any}("op" => o, "args" => collect(Any, args))
function _cell_corners(x0, dx, nset)
    # x = x0 + (i-1)*dx + dx*((v==2)+(v==3));  y = (v==3)+(v==4);  c: 1=x, 2=y
    xstep = _eq("*", dx, _eq("+", _eq("==", "v", 2), _eq("==", "v", 3)))
    x = _eq("+", x0, _eq("*", _eq("-", "i", 1), dx), xstep)
    y = _eq("+", _eq("==", "v", 3), _eq("==", "v", 4))
    _arrop(["i", "v", "c"], ["i" => nset, "v" => "verts", "c" => "coord"],
           _eq("ifelse", _eq("==", "c", 1), x, y))
end

function _constructed_live_regrid_esm()
    ip = Dict{String,Any}("op" => "intersect_polygon", "id" => "overlap_clip",
        "manifold" => "planar", "args" => Any[_ix("src_poly", "i"), _ix("tgt_poly", "j")])
    clip = _arrop(["i", "j", "w", "c"],
        ["i" => "src_cells", "j" => "tgt_cells", "w" => "clip_ring", "c" => "coord"], _ix(ip, "w", "c"))
    vp1 = _eq("+", "v", 1)
    shoe = _eq("*", 0.5, _eq("-",
        _eq("*", _ix("clip","i","j","v",1), _ix("clip","i","j",vp1,2)),
        _eq("*", _ix("clip","i","j",vp1,1), _ix("clip","i","j","v",2))))
    A_ij = _arrop(["i", "j"], ["i" => "src_cells", "j" => "tgt_cells"], _agg("v", "clip_ring", shoe))
    A_j  = _arrop(["j"], ["j" => "tgt_cells"], _agg("i", "src_cells", _ix("A_ij", "i", "j")))
    num  = _agg("i", "src_cells", _eq("*", _ix("A_ij", "i", "j"), _ix("F_src", "i")))
    rhs  = _arrop(["j"], ["j" => "tgt_cells"], _eq("/", num, _ix("A_j", "j")))
    lhs  = Dict{String,Any}("op" => "aggregate", "output_idx" => Any["j"],
        "ranges" => Dict{String,Any}("j" => Dict{String,Any}("from" => "tgt_cells")),
        "expr" => Dict{String,Any}("op" => "D", "args" => Any[_ix("F_tgt", "j")], "wrt" => "t"))
    Pd(d) = Dict{String,Any}("type" => "parameter", "default" => d)
    O(e, shape...) = Dict{String,Any}("type" => "observed", "shape" => collect(Any, shape), "expression" => e)
    model = Dict{String,Any}(
        "variables" => Dict{String,Any}(
            "x0" => Pd(0.0), "dx_src" => Pd(0.5), "dx_tgt" => Pd(1.0),
            "F_src" => Dict{String,Any}("type" => "parameter", "shape" => Any["src_cells"]),
            "src_poly" => O(_cell_corners("x0", "dx_src", "src_cells"), "src_cells", "verts", "coord"),
            "tgt_poly" => O(_cell_corners("x0", "dx_tgt", "tgt_cells"), "tgt_cells", "verts", "coord"),
            "clip" => O(clip, "src_cells", "tgt_cells", "clip_ring", "coord"),
            "A_ij" => O(A_ij, "src_cells", "tgt_cells"), "A_j" => O(A_j, "tgt_cells"),
            "F_tgt" => Dict{String,Any}("type" => "state", "shape" => Any["tgt_cells"])),
        "equations" => Any[Dict{String,Any}("lhs" => lhs, "rhs" => rhs)])
    return Dict{String,Any}("esm" => "0.6.0", "metadata" => Dict{String,Any}("name" => "constructed_live_regrid"),
        "index_sets" => Dict{String,Any}(
            "coord" => Dict{String,Any}("kind"=>"interval","size"=>2), "verts" => Dict{String,Any}("kind"=>"interval","size"=>4),
            "src_cells" => Dict{String,Any}("kind"=>"interval","size"=>4), "tgt_cells" => Dict{String,Any}("kind"=>"interval","size"=>2),
            "clip_ring" => Dict{String,Any}("kind"=>"derived","from_faq"=>"overlap_clip")),
        "models" => Dict{String,Any}("ConstructedLiveRegrid" => model))
end

@testset "Constructed geometry + live F_src field through the regrid (M4+)" begin
    esm = _constructed_live_regrid_esm()
    F_src = [10.0, 20.0, 30.0, 40.0]               # a LIVE buffer
    f!, u0, p, _t, vmap = build_evaluator(esm; param_arrays = Dict("F_src" => F_src),
        initial_conditions = Dict("F_tgt[1]" => 0.0, "F_tgt[2]" => 0.0))
    du = similar(u0); f!(du, u0, p, 0.0)
    # nothing injected but grid params + the field — polygons are CONSTRUCTED.
    @test du[vmap["F_tgt[1]"]] ≈ 15.0 atol = 1e-12   # mean(10,20)
    @test du[vmap["F_tgt[2]"]] ≈ 35.0 atol = 1e-12   # mean(30,40)
    # Mutate the SAME live buffer (no rebuild) — F_tgt tracks F_src.
    F_src .= [100.0, 0.0, 0.0, 0.0]
    f!(du, u0, p, 0.0)
    @test du[vmap["F_tgt[1]"]] ≈ 50.0 atol = 1e-12   # mean(100,0)
    @test du[vmap["F_tgt[2]"]] ≈ 0.0  atol = 1e-12   # mean(0,0)
end

# ---------------------------------------------------------------------------
# COUPLED-ARRAY BRIDGE (the met→fire edge). A SEPARATE consumer per-cell ODE
# reads the regrid output `F_tgt[j]` as an array observed indexed by its OWN loop
# var — the level-set RHS reading a regridded coupling field per cell, NOT the
# regrid extracting elements into scalar states. `F_tgt = A_ij ⊗ F_src / A_j` is
# a LIVE-FIELD observed (F_src is a `param_arrays` buffer): A_ij/A_j build once at
# setup, but F_tgt is INLINED into the consumer, so `index(F_tgt, j)` beta-reduces
# to the proven array-state aggregate kernel (const weights + live field). The
# whole chain — construct grids → clip → A_ij → regrid a live field → drive a
# per-cell ODE — runs through one `build_evaluator`, no host-supplied geometry.
#   D(u[j],t) = k * F_tgt[j];  F_src=[10,20,30,40] ⇒ F_tgt=[15,35], k=2 ⇒ [30,70].
# ---------------------------------------------------------------------------

function _coupled_bridge_esm()
    ip = Dict{String,Any}("op" => "intersect_polygon", "id" => "overlap_clip",
        "manifold" => "planar", "args" => Any[_ix("src_poly", "i"), _ix("tgt_poly", "j")])
    clip = _arrop(["i", "j", "w", "c"],
        ["i" => "src_cells", "j" => "tgt_cells", "w" => "clip_ring", "c" => "coord"], _ix(ip, "w", "c"))
    vp1 = _eq("+", "v", 1)
    shoe = _eq("*", 0.5, _eq("-",
        _eq("*", _ix("clip","i","j","v",1), _ix("clip","i","j",vp1,2)),
        _eq("*", _ix("clip","i","j",vp1,1), _ix("clip","i","j","v",2))))
    A_ij = _arrop(["i", "j"], ["i" => "src_cells", "j" => "tgt_cells"], _agg("v", "clip_ring", shoe))
    A_j  = _arrop(["j"], ["j" => "tgt_cells"], _agg("i", "src_cells", _ix("A_ij", "i", "j")))
    num  = _agg("i", "src_cells", _eq("*", _ix("A_ij", "i", "j"), _ix("F_src", "i")))
    F_tgt = _arrop(["j"], ["j" => "tgt_cells"], _eq("/", num, _ix("A_j", "j")))
    # consumer: D(u[j],t) = k * F_tgt[j] — a DIFFERENT state reads the regrid output
    cons_rhs = _arrop(["j"], ["j" => "tgt_cells"], _eq("*", "k", _ix("F_tgt", "j")))
    cons_lhs = Dict{String,Any}("op" => "aggregate", "output_idx" => Any["j"],
        "ranges" => Dict{String,Any}("j" => Dict{String,Any}("from" => "tgt_cells")),
        "expr" => Dict{String,Any}("op" => "D", "args" => Any[_ix("u", "j")], "wrt" => "t"))
    Pd(d) = Dict{String,Any}("type" => "parameter", "default" => d)
    O(e, shape...) = Dict{String,Any}("type" => "observed", "shape" => collect(Any, shape), "expression" => e)
    model = Dict{String,Any}(
        "variables" => Dict{String,Any}(
            "x0" => Pd(0.0), "dx_src" => Pd(0.5), "dx_tgt" => Pd(1.0), "k" => Pd(2.0),
            "F_src" => Dict{String,Any}("type" => "parameter", "shape" => Any["src_cells"]),
            "src_poly" => O(_cell_corners("x0", "dx_src", "src_cells"), "src_cells", "verts", "coord"),
            "tgt_poly" => O(_cell_corners("x0", "dx_tgt", "tgt_cells"), "tgt_cells", "verts", "coord"),
            "clip" => O(clip, "src_cells", "tgt_cells", "clip_ring", "coord"),
            "A_ij" => O(A_ij, "src_cells", "tgt_cells"), "A_j" => O(A_j, "tgt_cells"),
            "F_tgt" => O(F_tgt, "tgt_cells"),
            "u" => Dict{String,Any}("type" => "state", "shape" => Any["tgt_cells"])),
        "equations" => Any[Dict{String,Any}("lhs" => cons_lhs, "rhs" => cons_rhs)])
    return Dict{String,Any}("esm" => "0.6.0", "metadata" => Dict{String,Any}("name" => "coupled_bridge"),
        "index_sets" => Dict{String,Any}(
            "coord" => Dict{String,Any}("kind"=>"interval","size"=>2), "verts" => Dict{String,Any}("kind"=>"interval","size"=>4),
            "src_cells" => Dict{String,Any}("kind"=>"interval","size"=>4), "tgt_cells" => Dict{String,Any}("kind"=>"interval","size"=>2),
            "clip_ring" => Dict{String,Any}("kind"=>"derived","from_faq"=>"overlap_clip")),
        "models" => Dict{String,Any}("CoupledBridge" => model))
end

@testset "Coupled-array bridge: consumer ODE reads a live regrid F_tgt observed (met→fire)" begin
    esm = _coupled_bridge_esm()
    F_src = [10.0, 20.0, 30.0, 40.0]               # a LIVE buffer
    f!, u0, p, _t, vmap = build_evaluator(esm; param_arrays = Dict("F_src" => F_src),
        initial_conditions = Dict("u[1]" => 0.0, "u[2]" => 0.0))
    du = similar(u0); f!(du, u0, p, 0.0)
    # F_tgt = [15,35] (the regrid of the live field); k=2 ⇒ the consumer RHS reads it.
    @test du[vmap["u[1]"]] ≈ 30.0 atol = 1e-12
    @test du[vmap["u[2]"]] ≈ 70.0 atol = 1e-12
    # Refresh the live buffer (no rebuild) — the consumer's RHS tracks it.
    F_src .= [100.0, 0.0, 0.0, 0.0]                # F_tgt = [50,0]
    f!(du, u0, p, 0.0)
    @test du[vmap["u[1]"]] ≈ 100.0 atol = 1e-12    # 2*50
    @test du[vmap["u[2]"]] ≈ 0.0   atol = 1e-12    # 2*0
end

# ---------------------------------------------------------------------------
# Multi-hop chain (the level-set coupling shape). The consumer does NOT read the
# regrid output directly — it reads a DERIVED field one hop further on:
#   F_tgt[j] = regrid(F_src)           (live-field observed)
#   S_n[j]   = 1 + F_tgt[j]            (derived per-cell field — R_0·(1+φ) stand-in)
#   D(u[j],t)= S_n[j]                  (the front RHS reads the derived field)
# Both F_tgt and S_n are live-field array observeds; the chain S_n→F_tgt must
# collapse transitively (the `_resolve_observed` fix that reads THROUGH arrayop
# bodies), then `index(S_n, j)` nested-beta-reduces to the regrid kernel.
#   F_src=[10,20,30,40] ⇒ F_tgt=[15,35] ⇒ S_n=[16,36] ⇒ du=[16,36].
# ---------------------------------------------------------------------------

function _chain_bridge_esm()
    base = _coupled_bridge_esm()
    model = base["models"]["CoupledBridge"]
    O(e, shape...) = Dict{String,Any}("type" => "observed", "shape" => collect(Any, shape), "expression" => e)
    # S_n[j] = 1 + F_tgt[j]
    S_n = _arrop(["j"], ["j" => "tgt_cells"], _eq("+", 1.0, _ix("F_tgt", "j")))
    model["variables"]["S_n"] = O(S_n, "tgt_cells")
    # Retarget the consumer to read S_n (one hop past the regrid output).
    model["equations"][1]["rhs"] =
        _arrop(["j"], ["j" => "tgt_cells"], _ix("S_n", "j"))
    base["metadata"]["name"] = "chain_bridge"
    base["models"]["ChainBridge"] = model
    delete!(base["models"], "CoupledBridge")
    return base
end

@testset "Multi-hop chain: consumer reads a DERIVED field over a live regrid (level-set shape)" begin
    esm = _chain_bridge_esm()
    F_src = [10.0, 20.0, 30.0, 40.0]
    f!, u0, p, _t, vmap = build_evaluator(esm; param_arrays = Dict("F_src" => F_src),
        initial_conditions = Dict("u[1]" => 0.0, "u[2]" => 0.0))
    du = similar(u0); f!(du, u0, p, 0.0)
    @test du[vmap["u[1]"]] ≈ 16.0 atol = 1e-12     # 1 + mean(10,20)
    @test du[vmap["u[2]"]] ≈ 36.0 atol = 1e-12     # 1 + mean(30,40)
    F_src .= [100.0, 0.0, 0.0, 0.0]
    f!(du, u0, p, 0.0)
    @test du[vmap["u[1]"]] ≈ 51.0 atol = 1e-12     # 1 + mean(100,0)
    @test du[vmap["u[2]"]] ≈ 1.0  atol = 1e-12     # 1 + mean(0,0)
end
