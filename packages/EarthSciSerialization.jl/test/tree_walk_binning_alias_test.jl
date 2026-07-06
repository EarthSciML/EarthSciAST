# Regression tests for two build-time tree-walk limitations the conservative-
# regridding broad phase hit (ess: julia-treewalk gaps 1 & 2).
#
#  GAP 1 — a TEMPLATE-CONSTRUCTED (aggregate-valued) binning coordinate is now an
#          admissible value-invention skolem index target. Previously only a
#          const-supplied / reduce-over-const coordinate was admitted, so a
#          coordinate derived from constructed cell rings (an aggregate over a grid
#          spec) threw E_TREEWALK_VI_INDEX. Determinism is preserved: only a
#          statically-determinable (state-free) build-time coordinate is admitted.
#
#  GAP 2 — a setup-geometry var (a fused-leaf `A_ij` aggregate) may reference a
#          BARE-ALIAS array observed (`src_poly := base_poly`, the MPAS keyed-factor
#          re-exposure). Previously the geometry-setup backward pass pulled the bare
#          alias into the setup vars and `_materialize_geom_array` crashed on the
#          `VarExpr` (`no field output_idx`).

using Test
using EarthSciSerialization
const _TWB = EarthSciSerialization

# ---- helpers --------------------------------------------------------------
function _twb_agg(oi, rng, args, ex, extra=Dict{String,Any}())
    d = Dict{String,Any}("op"=>"aggregate", "semiring"=>"sum_product",
        "output_idx"=>oi, "ranges"=>rng, "args"=>args, "expr"=>ex)
    for (k, v) in extra; d[k] = v; end
    d
end
_twb_ix(a...) = Dict{String,Any}("op"=>"index", "args"=>collect(Any, a))
_twb_floor(x) = Dict{String,Any}("op"=>"floor", "args"=>[x])
_twb_div(a, b) = Dict{String,Any}("op"=>"/", "args"=>[a, b])
_twb_eq(a, b) = Dict{String,Any}("op"=>"==", "args"=>[a, b])
_twb_mul(a...) = Dict{String,Any}("op"=>"*", "args"=>collect(Any, a))
# skolem("bin", floor(lon[sym]/bin_dx), floor(lat[sym]/bin_dy))
_twb_binkey(lon, lat, sym) = Dict{String,Any}("op"=>"skolem", "args"=>[
    "bin",
    _twb_floor(_twb_div(_twb_ix(lon, sym), "bin_dx")),
    _twb_floor(_twb_div(_twb_ix(lat, sym), "bin_dy"))])

@testset "tree-walk build gaps: constructed binning coord + bare-alias setup geometry" begin

    # ===================================================================
    # GAP 1 — gated conservative-regridding broad phase whose target rings AND
    # binning coordinate are TEMPLATE-CONSTRUCTED (an affine aggregate over a grid
    # spec), not const-supplied. Two DISJOINT clusters make the bbox-min bin
    # admissible AND pruning real: src1/tgt1 at the origin, src2/tgt2 far at x≈10.
    # ===================================================================
    @testset "GAP 1: aggregate-constructed coordinate is an admissible skolem-bin index target" begin
        src_rings = [
            [[0.0, 0.0], [1.0, 0.0], [1.0, 1.0], [0.0, 1.0]],         # src1 @ origin
            [[10.0, 0.0], [11.0, 0.0], [11.0, 1.0], [10.0, 1.0]],     # src2 @ x≈10
        ]
        # tgt_poly[j,v,k] CONSTRUCTED: cell j origin (10*(j-1), 0), size 1, CCW quad.
        tgt_body = Dict{String,Any}("op"=>"ifelse", "args"=>[
            _twb_eq("k", 1),
            Dict{String,Any}("op"=>"+", "args"=>[
                _twb_mul(10.0, Dict{String,Any}("op"=>"-", "args"=>["j", 1])),
                _twb_mul(1.0, Dict{String,Any}("op"=>"+", "args"=>[_twb_eq("v", 2), _twb_eq("v", 3)]))]),
            _twb_mul(1.0, Dict{String,Any}("op"=>"+", "args"=>[_twb_eq("v", 3), _twb_eq("v", 4)]))])

        rng_ij = Dict{String,Any}("i"=>Dict("from"=>"src_cells"), "j"=>Dict("from"=>"tgt_cells"))
        joinbin = Any[Dict{String,Any}("on"=>Any[Any["src_bin", "tgt_bin"]])]
        filt = Dict{String,Any}("op"=>">", "args"=>[_twb_ix("A_ij_gated", "i", "j"), "atol"])

        vars = Dict{String,Any}(
            "atol"=>Dict{String,Any}("type"=>"parameter", "default"=>1e-12),
            "bin_dx"=>Dict{String,Any}("type"=>"parameter", "default"=>5.0),
            "bin_dy"=>Dict{String,Any}("type"=>"parameter", "default"=>5.0),
            "F_src"=>Dict{String,Any}("type"=>"observed", "shape"=>["src_cells"],
                "expression"=>Dict{String,Any}("op"=>"const", "value"=>[10.0, 20.0], "args"=>[])),
            "unit_src"=>Dict{String,Any}("type"=>"observed", "shape"=>["src_cells"],
                "expression"=>Dict{String,Any}("op"=>"const", "value"=>[1.0, 1.0], "args"=>[])),
            "src_poly"=>Dict{String,Any}("type"=>"observed", "shape"=>["src_cells", "cell_verts", "coord"],
                "expression"=>Dict{String,Any}("op"=>"const", "value"=>src_rings, "args"=>[])),
            # CONSTRUCTED target rings (aggregate over the grid spec).
            "tgt_poly"=>Dict{String,Any}("type"=>"observed", "shape"=>["tgt_cells", "cell_verts", "coord"],
                "expression"=>_twb_agg(["j", "v", "k"],
                    Dict{String,Any}("j"=>Dict("from"=>"tgt_cells"), "v"=>Dict("from"=>"cell_verts"),
                        "k"=>Dict("from"=>"coord")), [], tgt_body)),
            # binning coords: src from const rings, tgt from CONSTRUCTED rings (reduce-min).
            "src_lon"=>Dict{String,Any}("type"=>"observed", "shape"=>["src_cells"],
                "expression"=>_twb_agg(["i"], Dict{String,Any}("i"=>Dict("from"=>"src_cells"), "v"=>Dict("from"=>"cell_verts")),
                    ["src_poly"], _twb_ix("src_poly", "i", "v", 1), Dict("reduce"=>"min"))),
            "src_lat"=>Dict{String,Any}("type"=>"observed", "shape"=>["src_cells"],
                "expression"=>_twb_agg(["i"], Dict{String,Any}("i"=>Dict("from"=>"src_cells"), "v"=>Dict("from"=>"cell_verts")),
                    ["src_poly"], _twb_ix("src_poly", "i", "v", 2), Dict("reduce"=>"min"))),
            "tgt_lon"=>Dict{String,Any}("type"=>"observed", "shape"=>["tgt_cells"],
                "expression"=>_twb_agg(["j"], Dict{String,Any}("j"=>Dict("from"=>"tgt_cells"), "v"=>Dict("from"=>"cell_verts")),
                    ["tgt_poly"], _twb_ix("tgt_poly", "j", "v", 1), Dict("reduce"=>"min"))),
            "tgt_lat"=>Dict{String,Any}("type"=>"observed", "shape"=>["tgt_cells"],
                "expression"=>_twb_agg(["j"], Dict{String,Any}("j"=>Dict("from"=>"tgt_cells"), "v"=>Dict("from"=>"cell_verts")),
                    ["tgt_poly"], _twb_ix("tgt_poly", "j", "v", 2), Dict("reduce"=>"min"))),
            # bin keys: skolem over the CONSTRUCTED coordinate (the gap-1 admission).
            "src_bin"=>Dict{String,Any}("type"=>"state", "shape"=>["src_cells"],
                "expression"=>_twb_agg(["i"], Dict{String,Any}("i"=>Dict("from"=>"src_cells")),
                    ["src_lon", "src_lat"], _twb_binkey("src_lon", "src_lat", "i"))),
            "tgt_bin"=>Dict{String,Any}("type"=>"state", "shape"=>["tgt_cells"],
                "expression"=>_twb_agg(["j"], Dict{String,Any}("j"=>Dict("from"=>"tgt_cells")),
                    ["tgt_lon", "tgt_lat"], _twb_binkey("tgt_lon", "tgt_lat", "j"))),
            # DENSE narrow phase (oracle).
            "A_ij"=>Dict{String,Any}("type"=>"observed", "shape"=>["src_cells", "tgt_cells"],
                "expression"=>_twb_agg(["i", "j"], rng_ij, ["src_poly", "tgt_poly"],
                    Dict{String,Any}("op"=>"polygon_intersection_area", "manifold"=>"planar",
                        "args"=>[_twb_ix("src_poly", "i"), _twb_ix("tgt_poly", "j")]))),
            # GATED narrow phase (join on the constructed-coordinate bins).
            "A_ij_gated"=>Dict{String,Any}("type"=>"observed", "shape"=>["src_cells", "tgt_cells"],
                "expression"=>_twb_agg(["i", "j"], rng_ij, ["src_poly", "tgt_poly", "src_bin", "tgt_bin"],
                    Dict{String,Any}("op"=>"polygon_intersection_area", "manifold"=>"planar",
                        "args"=>[_twb_ix("src_poly", "i"), _twb_ix("tgt_poly", "j")]),
                    Dict("join"=>joinbin))),
            "A_j_gated"=>Dict{String,Any}("type"=>"observed", "shape"=>["tgt_cells"],
                "expression"=>_twb_agg(["j"], rng_ij, ["A_ij_gated", "src_bin", "tgt_bin"],
                    _twb_ix("A_ij_gated", "i", "j"), Dict("join"=>joinbin, "filter"=>filt))),
            "F_tgt_gated"=>Dict{String,Any}("type"=>"observed", "shape"=>["tgt_cells"],
                "expression"=>_twb_agg(["j"], rng_ij, ["A_ij_gated", "A_j_gated", "F_src", "src_bin", "tgt_bin"],
                    _twb_div(_twb_mul(_twb_ix("A_ij_gated", "i", "j"), _twb_ix("F_src", "i")),
                        _twb_ix("A_j_gated", "j")), Dict("join"=>joinbin, "filter"=>filt))),
            "F_unit_gated"=>Dict{String,Any}("type"=>"observed", "shape"=>["tgt_cells"],
                "expression"=>_twb_agg(["j"], rng_ij, ["A_ij_gated", "A_j_gated", "unit_src", "src_bin", "tgt_bin"],
                    _twb_div(_twb_mul(_twb_ix("A_ij_gated", "i", "j"), _twb_ix("unit_src", "i")),
                        _twb_ix("A_j_gated", "j")), Dict("join"=>joinbin, "filter"=>filt))),
            "regrid_state"=>Dict{String,Any}("type"=>"state", "shape"=>["tgt_cells"], "default"=>0.0),
            "pou_state"=>Dict{String,Any}("type"=>"state", "shape"=>["tgt_cells"], "default"=>0.0),
        )
        doc = Dict{String,Any}("esm"=>"0.8.0", "metadata"=>Dict{String,Any}("name"=>"gated_constructed"),
            "index_sets"=>Dict{String,Any}(
                "src_cells"=>Dict{String,Any}("kind"=>"interval", "size"=>2),
                "tgt_cells"=>Dict{String,Any}("kind"=>"interval", "size"=>2),
                "cell_verts"=>Dict{String,Any}("kind"=>"interval", "size"=>4),
                "coord"=>Dict{String,Any}("kind"=>"interval", "size"=>2)),
            "models"=>Dict{String,Any}("M"=>Dict{String,Any}("variables"=>vars, "equations"=>Any[
                Dict{String,Any}("lhs"=>Dict{String,Any}("op"=>"ic", "args"=>["regrid_state"]), "rhs"=>0.0),
                Dict{String,Any}("lhs"=>Dict{String,Any}("op"=>"ic", "args"=>["pou_state"]), "rhs"=>0.0),
                Dict{String,Any}("lhs"=>Dict{String,Any}("op"=>"D", "args"=>["regrid_state"], "wrt"=>"t"), "rhs"=>"F_tgt_gated"),
                Dict{String,Any}("lhs"=>Dict{String,Any}("op"=>"D", "args"=>["pou_state"], "wrt"=>"t"), "rhs"=>"F_unit_gated"),
            ])))

        insp = _TWB.BuildInspection()
        f!, u0, p, tspan, vmap = build_evaluator(doc; model_name="M", inspect=insp)
        du = similar(u0); f!(du, u0, p, 0.0)
        F_tgt = [du[vmap["regrid_state[$j]"]] for j in 1:2]
        pou   = [du[vmap["pou_state[$j]"]] for j in 1:2]

        # The CONSTRUCTED binning coordinate folded to concrete build-time values and
        # was derived into the value-invention const_arrays (the gap-1 admission).
        @test insp.const_arrays["tgt_lon"] ≈ [0.0, 10.0]
        @test insp.const_arrays["tgt_lat"] ≈ [0.0, 0.0]
        # Gated == dense on the constructed geometry (value identity, admissible bin).
        @test insp.setup_arrays["A_ij_gated"] == insp.setup_arrays["A_ij"]
        @test insp.setup_arrays["A_ij_gated"] ≈ [1.0 0.0; 0.0 1.0]
        # End-to-end regrid + the two exact invariants.
        @test F_tgt ≈ [10.0, 20.0]                                   # apply
        @test pou ≈ [1.0, 1.0]                                       # partition of unity
        @test sum(insp.setup_arrays["A_j_gated"] .* F_tgt) ≈ 30.0    # conservation (== mass_src)
    end

    # ===================================================================
    # GAP 2 — a setup-geometry var (the fused-leaf A_ij) references a BARE-ALIAS
    # array observed. The build must resolve the alias to its const-backed rings in
    # the setup env instead of crashing in _materialize_geom_array.
    # ===================================================================
    @testset "GAP 2: setup-geometry var references a bare-alias const (no VarExpr crash)" begin
        base = [[[0.0, 0.0], [1.0, 0.0], [1.0, 1.0], [0.0, 1.0]]]   # 1 unit cell
        vars = Dict{String,Any}(
            "atol"=>Dict{String,Any}("type"=>"parameter", "default"=>1e-12),
            "base_poly"=>Dict{String,Any}("type"=>"observed", "shape"=>["src_cells", "cell_verts", "coord"],
                "expression"=>Dict{String,Any}("op"=>"const", "value"=>base, "args"=>[])),
            "tgt_poly"=>Dict{String,Any}("type"=>"observed", "shape"=>["tgt_cells", "cell_verts", "coord"],
                "expression"=>Dict{String,Any}("op"=>"const", "value"=>base, "args"=>[])),
            # BARE ALIAS (the MPAS mesh.* re-exposure pattern).
            "src_poly"=>Dict{String,Any}("type"=>"observed", "shape"=>["src_cells", "cell_verts", "coord"],
                "expression"=>"base_poly"),
            "A_ij"=>Dict{String,Any}("type"=>"observed", "shape"=>["src_cells", "tgt_cells"],
                "expression"=>_twb_agg(["i", "j"],
                    Dict{String,Any}("i"=>Dict("from"=>"src_cells"), "j"=>Dict("from"=>"tgt_cells")),
                    ["src_poly", "tgt_poly"],
                    Dict{String,Any}("op"=>"polygon_intersection_area", "manifold"=>"planar",
                        "args"=>[_twb_ix("src_poly", "i"), _twb_ix("tgt_poly", "j")]))),
            "s"=>Dict{String,Any}("type"=>"state", "shape"=>["tgt_cells"], "default"=>0.0),
        )
        doc = Dict{String,Any}("esm"=>"0.8.0", "metadata"=>Dict{String,Any}("name"=>"alias_setup"),
            "index_sets"=>Dict{String,Any}(
                "src_cells"=>Dict{String,Any}("kind"=>"interval", "size"=>1),
                "tgt_cells"=>Dict{String,Any}("kind"=>"interval", "size"=>1),
                "cell_verts"=>Dict{String,Any}("kind"=>"interval", "size"=>4),
                "coord"=>Dict{String,Any}("kind"=>"interval", "size"=>2)),
            "models"=>Dict{String,Any}("M"=>Dict{String,Any}("variables"=>vars, "equations"=>Any[
                Dict{String,Any}("lhs"=>Dict{String,Any}("op"=>"ic", "args"=>["s"]), "rhs"=>0.0),
                Dict{String,Any}("lhs"=>Dict{String,Any}("op"=>"D", "args"=>["s"], "wrt"=>"t"),
                    "rhs"=>_twb_agg(["j"],
                        Dict{String,Any}("i"=>Dict("from"=>"src_cells"), "j"=>Dict("from"=>"tgt_cells")),
                        ["A_ij"], _twb_ix("A_ij", "i", "j"))),
            ])))

        insp = _TWB.BuildInspection()
        f!, u0, p, tspan, vmap = build_evaluator(doc; model_name="M", inspect=insp)
        du = similar(u0); f!(du, u0, p, 0.0)
        # The alias resolved: A_ij over the aliased rings is the full unit overlap.
        @test du[vmap["s[1]"]] ≈ 1.0
        @test insp.setup_arrays["A_ij"] ≈ reshape([1.0], 1, 1)
    end
end
