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
        "index_sets" => Dict{String,Any}(
            "coord" => Dict{String,Any}("kind" => "interval", "size" => 2),
            "verts" => Dict{String,Any}("kind" => "interval", "size" => 4),
            "src_cells" => Dict{String,Any}("kind" => "interval", "size" => 2),
            "tgt_cells" => Dict{String,Any}("kind" => "interval", "size" => 2),
            "clip_ring" => Dict{String,Any}("kind" => "derived", "from_faq" => "overlap_clip")),
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
        "index_sets" => Dict{String,Any}(
            "coord" => Dict{String,Any}("kind" => "interval", "size" => 2),
            "verts" => Dict{String,Any}("kind" => "interval", "size" => 4),
            "src_cells" => Dict{String,Any}("kind" => "interval", "size" => 3),
            "tgt_cells" => Dict{String,Any}("kind" => "interval", "size" => 2),
            "clip_ring" => Dict{String,Any}("kind" => "derived", "from_faq" => "overlap_clip")),
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
        "index_sets" => Dict{String,Any}(
            "coord" => Dict{String,Any}("kind"=>"interval","size"=>2), "verts" => Dict{String,Any}("kind"=>"interval","size"=>4),
            "src_cells" => Dict{String,Any}("kind"=>"interval","size"=>4), "tgt_cells" => Dict{String,Any}("kind"=>"interval","size"=>2),
            "clip_ring" => Dict{String,Any}("kind"=>"derived","from_faq"=>"overlap_clip")),
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
