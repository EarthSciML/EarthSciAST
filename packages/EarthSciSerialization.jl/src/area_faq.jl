# `polygon_area` as a `sum_product` FAQ over the clipped ring (RFC
# `semiring-faq-unified-ir` §8.1; `CONFORMANCE_SPEC.md` §5.8; bead ess-d4g.1).
#
# `polygon_area` is NOT a new op: the area of a clipped vertex ring is an ordinary
# `sum_product` FAQ over the ring (RFC §8.1). The builders below assemble that FAQ
# as an `OpExpr` and `_polygon_area_via_faq` evaluates it through the SAME generic
# aggregate machinery the tree-walk evaluator uses (`_resolve_indices` →
# `_resolve_scalar_arrayop` → `evaluate_expr`) — so the production polygon area is
# the FAQ, and the imperative `geometry.polygon_area` / `_spherical_signed_area`
# loops are only the cross-check oracle. Coordinate columns are 1-based (1 = lon,
# 2 = lat) over the CLOSED ring, so the wrap edge `v→1` is the ordinary `v+1`
# lookup `close_ring` provides.
#
# This is the Julia sibling of `packages/earthsci-toolkit-rs/src/area_faq.rs`
# (`polygon_area_faq`) and `earthsci_toolkit.area_faq`; the planar shoelace and the
# spherical Van Oosterom–Strackee fan are tolerance-identical across the
# Julia / Python / Rust bindings.

# Degrees→radians factor — identical to `deg2rad(x) = x·(π/180)`, so the FAQ's
# lon-lat→sphere map matches the imperative oracle (`_lonlat_to_unit`) bit-for-bit.
const _AREA_DEG2RAD = π / 180

# `index(overlap_clip, idx, col)` — read coordinate `col` (1 = lon, 2 = lat) of
# clip-ring vertex `idx` (an `Expr`: a range symbol, an affine `v+1`, or a literal).
_clip_col(idx::Expr, col::Int) =
    OpExpr("index", Expr[VarExpr("overlap_clip"), idx, IntExpr(col)])

"""
    _shoelace_area_faq(n) -> OpExpr

The planar `polygon_area` FAQ over the closed clip ring: the Gauss–Green shoelace
`0.5·Σ_v (x_v·y_{v+1} − x_{v+1}·y_v)` — an ordinary `sum_product` aggregate (§8.1),
the same AST as `tests/valid/geometry/intersect_polygon_planar_area.esm`.
"""
function _shoelace_area_faq(n::Int)::OpExpr
    v = VarExpr("v")
    vnext = OpExpr("+", Expr[VarExpr("v"), IntExpr(1)])
    cross = OpExpr("-", Expr[
        OpExpr("*", Expr[_clip_col(v, 1), _clip_col(vnext, 2)]),
        OpExpr("*", Expr[_clip_col(vnext, 1), _clip_col(v, 2)]),
    ])
    return OpExpr("aggregate", Expr[VarExpr("overlap_clip")];
                  semiring="sum_product", output_idx=Any[],
                  ranges=Dict{String,Any}("v" => [1, n]),
                  expr_body=OpExpr("*", Expr[NumExpr(0.5), cross]))
end

# Unit 3-vector AST `(cosφ·cosλ, cosφ·sinλ, sinφ)` of clip-ring vertex `idx`.
function _clip_unit_vec(idx::Expr)
    lon = OpExpr("*", Expr[_clip_col(idx, 1), NumExpr(_AREA_DEG2RAD)])
    lat = OpExpr("*", Expr[_clip_col(idx, 2), NumExpr(_AREA_DEG2RAD)])
    cos_lat = OpExpr("cos", Expr[lat])
    return (OpExpr("*", Expr[cos_lat, OpExpr("cos", Expr[lon])]),
            OpExpr("*", Expr[cos_lat, OpExpr("sin", Expr[lon])]),
            OpExpr("sin", Expr[lat]))
end

_dot3(u, v) = OpExpr("+", Expr[
    OpExpr("*", Expr[u[1], v[1]]),
    OpExpr("*", Expr[u[2], v[2]]),
    OpExpr("*", Expr[u[3], v[3]])])

_cross3(u, v) = (
    OpExpr("-", Expr[OpExpr("*", Expr[u[2], v[3]]), OpExpr("*", Expr[u[3], v[2]])]),
    OpExpr("-", Expr[OpExpr("*", Expr[u[3], v[1]]), OpExpr("*", Expr[u[1], v[3]])]),
    OpExpr("-", Expr[OpExpr("*", Expr[u[1], v[2]]), OpExpr("*", Expr[u[2], v[1]])]))

# Van Oosterom–Strackee signed solid angle of triangle a,b,c:
# 2·atan2(a·(b×c), 1 + a·b + b·c + c·a).
function _spherical_excess(a, b, c)
    triple = _dot3(a, _cross3(b, c))
    denom = OpExpr("+", Expr[NumExpr(1.0), _dot3(a, b), _dot3(b, c), _dot3(c, a)])
    return OpExpr("*", Expr[NumExpr(2.0), OpExpr("atan2", Expr[triple, denom])])
end

"""
    _spherical_area_faq(n) -> OpExpr

The spherical `polygon_area` FAQ over the closed clip ring: the great-circle fan
triangulation `Σ_v E(v_1, v_v, v_{v+1})` of Van Oosterom–Strackee spherical
excesses — an ordinary `sum_product` aggregate (§8.1), the spherical sibling of
[`_shoelace_area_faq`](@ref). Ranging the *full* closed ring is exact: the two
degenerate fan endpoints (`v=1` ⇒ `E(v_1,v_1,v_2)`, `v=n` ⇒ `E(v_1,v_n,v_1)`)
carry zero excess, so the sum collapses to the `Σ_{i=2}^{n-1}` fan the oracle
`_spherical_signed_area` computes. Unit sphere (radius 1).
"""
function _spherical_area_faq(n::Int)::OpExpr
    apex = _clip_unit_vec(IntExpr(1))
    here = _clip_unit_vec(VarExpr("v"))
    nxt  = _clip_unit_vec(OpExpr("+", Expr[VarExpr("v"), IntExpr(1)]))
    return OpExpr("aggregate", Expr[VarExpr("overlap_clip")];
                  semiring="sum_product", output_idx=Any[],
                  ranges=Dict{String,Any}("v" => [1, n]),
                  expr_body=_spherical_excess(apex, here, nxt))
end

"""
    _polygon_area_via_faq(closed_ring, manifold) -> Float64

Evaluate the (unsigned) `polygon_area` FAQ for a CLOSED clip ring (`n+1` rows)
through the generic aggregate machinery: register the ring as the `overlap_clip`
const-array, build the planar shoelace / spherical-excess `sum_product` FAQ, and
run it through `_resolve_indices` (→ `_resolve_scalar_arrayop`) + `evaluate_expr`
— the same tree-walk path `build_evaluator` uses. Returns `0.0` for a degenerate
(`< 3` distinct vertex) ring.
"""
function _polygon_area_via_faq(closed_ring::AbstractMatrix, manifold::AbstractString)::Float64
    n = max(size(closed_ring, 1) - 1, 0)   # closed ring has n+1 rows
    n < 3 && return 0.0
    faq = manifold == "planar" ? _shoelace_area_faq(n) : _spherical_area_faq(n)
    const_arrays = Dict{String,AbstractArray{Float64}}("overlap_clip" => Matrix{Float64}(closed_ring))
    array_var_info = Dict{String,Tuple{Vector{Int},Vector{Int}}}()
    var_map = Dict{String,Int}()
    resolved = _resolve_indices(faq, array_var_info, var_map, const_arrays)
    return abs(evaluate_expr(resolved, Dict{String,Float64}()))
end
