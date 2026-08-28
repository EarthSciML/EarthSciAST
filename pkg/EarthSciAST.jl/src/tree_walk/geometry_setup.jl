# ========================================================================
# tree_walk/geometry_setup.jl — part of the tree-walk evaluator (gt-e8yw).
# Included by src/tree_walk.jl; see that file for the full layout and
# include order. Section 2 (build-time geometry): the M4 intersect_polygon clip kernel,
# the fused polygon_intersection_area leaf, ranged clips, the setup-time
# geometry materializers (_GeoCtx; the body COMPILER lives in
# tree_walk/geometry_compile.jl), and binning-coordinate derivation.
# ========================================================================

# ============================================================
# 2. Build — entry points
# ============================================================
# The public `build_evaluator(model::Model; kwargs...)` method (and its full
# docstring) lives after `_build_evaluator_impl` below; this section starts
# with the build-time geometry helpers it depends on.

# ============================================================
# M4 geometry kernel — build-time intersect_polygon clip (RFC §8.1 / Appendix B)
# ============================================================
#
# The `intersect_polygon` leaf runs at SETUP time (RFC Appendix B.1): its polygon
# operands are build-time-known parameters supplied via `const_arrays`, so the clip
# is evaluated ONCE here into a closed vertex ring. The ring is registered as a 2D
# const_array (read by the `polygon_area` FAQ as `index(clip, v, c)`) and its
# distinct-vertex count feeds the `kind:"derived"` index set the FAQ ranges over —
# so `polygon_area` rides the existing M1 aggregate machinery unchanged.
#
# All of this is guarded behind "an equation uses intersect_polygon", so every
# non-geometry file compiles byte-identically.

# True iff any node in the subtree is an intersect_polygon op.
# INTENTIONAL field subset (behavior-pinned — do NOT widen to `child_exprs`
# coverage without a spec decision): walks args / expr_body only, NOT lower /
# upper / filter / key / values / table_axes / ranges bounds. A clip nested in
# e.g. a makearray region value would not seed the geometry-setup pass —
# flagged for Wave 3.
# Identity-deduped existence predicate (ESS-0hh): path-multiplicity-
# insensitive, so the visited set is exactly equivalent — and O(nodes) on the
# structurally-shared trees the fold/template passes produce.
_expr_has_intersect_polygon(e::OpExpr) =
    _expr_has_intersect_polygon(e, IdDict{OpExpr,Nothing}())
function _expr_has_intersect_polygon(e::OpExpr, seen::IdDict{OpExpr,Nothing})
    e.op == "intersect_polygon" && return true
    haskey(seen, e) && return false
    seen[e] = nothing
    for a in e.args
        a isa OpExpr && _expr_has_intersect_polygon(a, seen) && return true
    end
    return e.expr_body isa OpExpr &&
           _expr_has_intersect_polygon(e.expr_body::OpExpr, seen)
end
_expr_has_intersect_polygon(::ASTExpr) = false
_equations_have_intersect_polygon(eqs) =
    any(eq -> _expr_has_intersect_polygon(eq.lhs) || _expr_has_intersect_polygon(eq.rhs), eqs)

# From esm 1.0.0 an intersect_polygon lives in an equation LHS/RHS and nowhere
# else: an observed unknown's defining body IS its equation, so the shared
# geometry fixtures' clip rings are reached by the same walk as everything else.
_model_has_intersect_polygon(model::Model) =
    _equations_have_intersect_polygon(model.equations)

# Resolve an intersect_polygon polygon operand to its const-array matrix. The clip
# runs at setup, so each operand must be a variable name supplied in `const_arrays`.
function _geometry_operand(arg::ASTExpr, const_arrays_kw::AbstractDict, who::AbstractString)
    arg isa VarExpr || throw(TreeWalkError("E_TREEWALK_GEOMETRY_OPERAND",
        "intersect_polygon operand for '$who' must be a polygon variable name"))
    name = (arg::VarExpr).name
    haskey(const_arrays_kw, name) || throw(TreeWalkError("E_TREEWALK_GEOMETRY_OPERAND",
        "intersect_polygon operand '$name' for '$who' must be supplied in `const_arrays` " *
        "(the clip runs at setup time; RFC Appendix B.1)"))
    return const_arrays_kw[name]
end

# Run one setup-time polygon clip, translating the geometry kernel's
# `GeometryError` into the build-time diagnostic (`E_TREEWALK_GEOMETRY_CLIP`).
# Shared by the single-ring materializer and the fused
# `polygon_intersection_area` leaf. The RANGED clip
# (`_materialize_ranged_clip`) deliberately does NOT use this wrapper: there a
# failed / degenerate per-pair clip is a normal zero-area cell (RFC §5.8), not
# an error.
function _clip_or_treewalk_error(poly_a, poly_b, manifold::AbstractString)
    try
        return intersect_polygon(poly_a, poly_b, manifold)
    catch err
        err isa GeometryError &&
            throw(TreeWalkError("E_TREEWALK_GEOMETRY_CLIP", err.msg))
        rethrow()
    end
end

# Evaluate every intersect_polygon clip ring at setup. Returns
# `(rings, extents)`: observed-var-name → CLOSED ring matrix `[n+1, 2]`, and
# `from_faq` key (the clip node `id` AND the observed var name) → distinct vertex
# count `n`. `geom_ring_vars` are the observed vars whose RHS is intersect_polygon.
function _materialize_geometry_rings(equations, const_arrays_kw::AbstractDict,
                                     geom_ring_vars::Set{String})
    rings = Dict{String,Matrix{Float64}}()
    extents = Dict{String,Int}()
    for eq in equations
        eq.lhs isa VarExpr || continue
        vname = (eq.lhs::VarExpr).name
        vname in geom_ring_vars || continue
        rhs = eq.rhs
        (rhs isa OpExpr && (rhs::OpExpr).op == "intersect_polygon") || continue
        op = rhs::OpExpr
        manifold = op.manifold
        manifold === nothing && throw(TreeWalkError("E_TREEWALK_GEOMETRY_NO_MANIFOLD",
            "intersect_polygon observed '$vname' requires a `manifold` (planar / spherical / geodesic)"))
        length(op.args) == 2 || throw(TreeWalkError("E_TREEWALK_GEOMETRY_ARITY",
            "intersect_polygon is strictly binary; '$vname' has $(length(op.args)) operand(s)"))
        poly_a = _geometry_operand(op.args[1], const_arrays_kw, vname)
        poly_b = _geometry_operand(op.args[2], const_arrays_kw, vname)
        ring = _clip_or_treewalk_error(poly_a, poly_b, manifold)
        closed = close_ring(ring)
        rings[vname] = closed
        n = max(size(closed, 1) - 1, 0)   # closed ring has n+1 rows
        extents[vname] = n                # derived set may name the var…
        op.id === nothing || (extents[op.id] = n)   # …or the clip node id (from_faq)
    end
    return rings, extents
end

# ============================================================
# polygon_intersection_area — FUSED clip+area scalar leaf (esm-spec §4.2 / §8.6.1)
# ============================================================
#
# `polygon_intersection_area` returns the SCALAR overlap area of two polygon vertex
# rings under a declared `manifold`. It is DEFINED to equal
# `polygon_area(intersect_polygon(a, b))` at the same manifold — the FUSED form of
# the existing Sutherland–Hodgman clip and the shoelace / spherical-excess area FAQ.
# Unlike `intersect_polygon` (which surfaces a data-dependent clip ring as a
# `kind:"derived"` index set the `polygon_area` FAQ ranges over, RFC §8.1), the
# fused leaf exposes NO ring: it evaluates to an ordinary Float64 scalar, so it
# drops into any expression — an ODE RHS or an `aggregate` body — with no ragged
# intermediate. Both constituent kernels are reused verbatim: `intersect_polygon`
# (the clip, planar or S2) and `_polygon_area_via_faq` (the shoelace / Van
# Oosterom–Strackee area over the CLOSED ring, run through the generic aggregate
# machinery). This is the densely-evaluable narrow phase of a conservative regrid.

# True iff any node in the subtree is a polygon_intersection_area op.
# INTENTIONAL field subset — args / expr_body only, the exact mirror of
# `_expr_has_intersect_polygon` above (see the Wave-3 note there), including
# its identity-deduped visited set (ESS-0hh).
_expr_has_polygon_intersection_area(e::OpExpr) =
    _expr_has_polygon_intersection_area(e, IdDict{OpExpr,Nothing}())
function _expr_has_polygon_intersection_area(e::OpExpr, seen::IdDict{OpExpr,Nothing})
    e.op == "polygon_intersection_area" && return true
    haskey(seen, e) && return false
    seen[e] = nothing
    for a in e.args
        a isa OpExpr && _expr_has_polygon_intersection_area(a, seen) && return true
    end
    return e.expr_body isa OpExpr &&
           _expr_has_polygon_intersection_area(e.expr_body::OpExpr, seen)
end
_expr_has_polygon_intersection_area(::ASTExpr) = false

# An intersection-area leaf lives in an equation LHS/RHS — from esm 1.0.0 an
# observed unknown's defining body is its equation, so there is nowhere else to
# look.
function _model_has_polygon_intersection_area(model::Model, equations)
    for eq in equations
        (_expr_has_polygon_intersection_area(eq.lhs) ||
         _expr_has_polygon_intersection_area(eq.rhs)) && return true
    end
    return false
end

# Collect the variable names appearing as direct operands of any
# polygon_intersection_area node in `e` (the const polygon vertex rings).
function _collect_pia_operands!(e::OpExpr, acc::Set{String})
    if e.op == "polygon_intersection_area"
        for a in e.args
            a isa VarExpr && push!(acc, (a::VarExpr).name)
        end
    end
    for a in e.args
        _collect_pia_operands!(a, acc)
    end
    e.expr_body !== nothing && _collect_pia_operands!(e.expr_body, acc)
    return acc
end
_collect_pia_operands!(::ASTExpr, acc::Set{String}) = acc

# A `const`-op node's stored (nested-vector) value → a dense `[nrows, ncols]`
# Float64 vertex-ring matrix. The rank-2 wrapper over the general ND
# materializer `_const_op_to_array` (below); the empty-ring guard keeps the
# historical 0×2 shape for a vertex-free operand.
function _pia_const_matrix(val)::Matrix{Float64}
    isempty(val) && return Matrix{Float64}(undef, 0, 2)
    return Matrix{Float64}(_const_op_to_array(val))
end

# True iff `e` is a `const`-op node (build-time literal data — a polygon vertex
# ring array, a source field). Its value lives in `e.value`, not `e.args`.
_is_const_op(e) = e isa OpExpr && (e::OpExpr).op == "const"

# A `const`-op node's stored (nested-vector) value → a dense Float64 array whose
# rank is the nesting depth (`[[[...]]]` → 3-D): an in-file
# `src_poly[cell, vert, coord]` ring stack or a 1-D `F_src[cell]` field.
# `_pia_const_matrix` above is its rank-2 wrapper. Column-major fill matches
# Julia's native layout, so `index(src_poly, i)` slices out cell `i`'s ring
# matrix.
function _const_op_to_array(val)::Array{Float64}
    dims = Int[]
    node = val
    while !(node isa Number)
        n = length(node)
        push!(dims, n)
        n == 0 && break
        node = first(node)
    end
    A = Array{Float64}(undef, dims...)
    _fill_const_array!(A, val, ())
    return A
end

function _fill_const_array!(A, node, idx::Tuple)
    if node isa Number
        A[idx...] = Float64(node)
        return
    end
    for (k, sub) in enumerate(node)
        _fill_const_array!(A, sub, (idx..., k))
    end
    return
end

"""
    _polygon_intersection_area(poly_a, poly_b, manifold) -> Float64

The fused `polygon_intersection_area` leaf: clip the two operand rings under
`manifold` (`intersect_polygon`), then area the CLOSED overlap ring through the
generic `polygon_area` FAQ (`_polygon_area_via_faq`). Equals
`polygon_area(intersect_polygon(a, b))` at the same manifold. A degenerate /
non-overlapping clip (`< 3` distinct vertices) has zero overlap area.
"""
function _polygon_intersection_area(poly_a, poly_b, manifold::AbstractString)::Float64
    ring = _clip_or_treewalk_error(poly_a, poly_b, manifold)
    size(ring, 1) < 3 && return 0.0
    return _polygon_area_via_faq(close_ring(ring), manifold)
end

# Resolve a polygon_intersection_area operand to its const polygon-ring matrix. The
# fused leaf is build-time-evaluable, so each operand must be a const-array variable
# name (supplied via `const_arrays` or a materialized `const`-op observed).
function _pia_operand_ring(arg::ASTExpr, const_arrays::AbstractDict)
    arg isa VarExpr && haskey(const_arrays, (arg::VarExpr).name) &&
        return const_arrays[(arg::VarExpr).name]
    throw(TreeWalkError("E_TREEWALK_GEOMETRY_OPERAND",
        "polygon_intersection_area operand must be a build-time-known polygon ring " *
        "(a const-array variable name)"))
end

# ============================================================
# M4+ : intersect_polygon RANGED over a candidate-pair set (declarative A_ij).
# ============================================================
# The single-clip M4 kernel above materializes ONE intersect_polygon ring from
# whole-array const operands. A conservative-regrid `A_ij` instead needs the clip
# RANGED over a candidate-pair set: `clip[p,w,c] = intersect_polygon(src[p],
# tgt[p])[w,c]`, then `area[p] = polygon_area(clip[p])` (an aggregate), then the
# matrix scatter. These geometry-derived ARRAY observeds are pure functions of the
# const polygon inputs (no state, no time), so — exactly like the single clip
# (RFC §8.1) and the value-invention skolems (§6.1) — they are evaluated ONCE at
# setup into const_arrays and dropped from the ODE. `_geometry_setup_vars` finds
# them; `_materialize_geometry_setup` evaluates them.

# Extent of an IndexSetRef range against the model's index sets + derived extents.
#
# A `kind:"derived"` set resolves through its `from_faq`, exactly as
# `_resolve_index_set_ranges` (tree_walk/resolve.jl) does for the ODE stream:
# `derived_extents` is keyed by the PRODUCER id, not by the set name. Setup-time
# geometry can range over one because the projection pushdown re-points a binning
# aggregate onto `pd_support__<C>` — and when that aggregate's weight is an
# intersection area, its body IS setup-time geometry.
function _geo_index_extent(ref, index_sets, derived_extents)
    name = ref isa IndexSetRef ? ref.from : String(ref)
    haskey(derived_extents, name) && return derived_extents[name]
    s = index_sets === nothing ? nothing : get(index_sets, name, nothing)
    if s isa IndexSet && s.kind == "derived" && s.from_faq !== nothing
        e = get(derived_extents, String(s.from_faq), nothing)
        e === nothing || return Int(e)
    end
    sz = s === nothing ? nothing :
         hasproperty(s, :size) ? getproperty(s, :size) :
         (s isa AbstractDict ? get(s, "size", get(s, :size, nothing)) : nothing)
    sz === nothing && throw(TreeWalkError("E_TREEWALK_GEOMETRY_SETUP",
        "cannot resolve extent of index set '$(name)' for setup-time geometry"))
    return Int(sz)
end

# (The setup-time geometry SCALAR LADDER — `_geo_apply_scalar` and its
# arity-specialized 1/2/3-arg twins — is gone: the geometry body is now
# COMPILED ONCE per sweep into the shared `_Node` IR, so the scalar vocabulary
# evaluates through `_eval_node_op`'s registry-generated arms. See
# tree_walk/geometry_compile.jl.)

# Map a join key column to the aggregate loop var that indexes it (via its
# declared 1-D shape's index set).
function _geo_loopvar_for(col, setof, var_shapes)
    sets = get(var_shapes, col, String[])
    isempty(sets) && return nothing
    for (lv, st) in setof
        st == sets[1] && return lv
    end
    return nothing
end

# Loop-invariant context for the setup-time geometry COMPILER (`_geo_compile`,
# tree_walk/geometry_compile.jl) and the join-gate resolution: the value
# environment (name → const arrays + scalar params + materialized geometry),
# the document index-set registry, the derived-extent map, and the declared
# per-variable shapes (for join-column resolution). Build-time-only path — one
# small struct per materialization is fine. `derived_extents` is read-only
# inside a compile/sweep (it is grown by the materializers before evaluation).
struct _GeoCtx
    env::AbstractDict
    index_sets::Any
    derived_extents::AbstractDict
    var_shapes::AbstractDict
end

# The skolem hash cap: keys are folded into Float64s, and 2^52 is a safe window
# of exactly-representable integers within the Float64 mantissa (53 bits), so
# two distinct capped hashes never collapse to one float. `hash` is
# SESSION-LOCAL (Julia's hash is not stable across versions or processes) —
# safe here because skolem keys are only ever COMPARED against each other
# within a single build, never persisted or matched cross-binding.
const _SKOLEM_HASH_CAP = 1 << 52

# A node's `join` resolves ONCE per sweep through `_resolve_geo_join_gates` below
# and then compiles to slot-addressed `_GeoSlotGate`s; the `filter` predicate
# compiles to a `_Node` evaluated per cell. Key-equality broad phase per RFC §5.3 /
# §5.8, gate then filter — see `_geo_gate_ok` and `_geo_eval_agg` in
# tree_walk/geometry_compile.jl.

# One resolved join-key equality: the two participating column arrays and the
# loop-var names that index them. Everything here is INVARIANT across the output ×
# candidate product `_materialize_geom_array` sweeps — only `ie[lvA]`/`ie[lvB]`
# vary per cell — so it is resolved ONCE (`_resolve_geo_join_gates`) instead of
# re-deriving `String(pair[…])`, `_geo_loopvar_for`, and two `env` Dict lookups on
# every candidate pair (the dominant cost of the conservative-regrid broad phase).
struct _GeoJoinGate
    arrA::Any
    lvA::String
    arrB::Any
    lvB::String
end

# Pre-resolve `expr.join` (once per sweep), faithfully replaying the historical
# per-tuple join arm: a pair whose loop vars don't resolve, or whose
# columns aren't both in `env`, is SKIPPED here exactly as the original `continue`
# skipped it — so an omitted pair never gates, byte-for-byte as before. Returns
# `nothing` when the node has no join (lets the compiled gate skip the whole
# arm). Consumed by `_geo_slot_gates` (tree_walk/geometry_compile.jl), which
# maps the loop-var names to frame slots.
function _resolve_geo_join_gates(expr, ctx::_GeoCtx, setof)
    expr.join === nothing && return nothing
    gates = _GeoJoinGate[]
    for clause in expr.join
        # Only bin-equality (key-column-pair) clauses resolve HERE. A Phase-2a
        # `overlap` clause is a `_OverlapJoinSpec` (not a pair vector) and is
        # handled separately, at the TOP-LEVEL sweep, by `_geo_overlap_gate` /
        # `_geo_overlap_drive` below — because its candidate set does not just
        # gate, it DRIVES enumeration, which this per-tuple gate cannot express.
        # (A nested `:geo_agg` therefore still ignores an overlap clause; no
        # shipped template puts one there. See the block above.)
        clause isa AbstractVector || continue
        for pair in clause
            colA, colB = String(pair[1]), String(pair[2])
            lvA = _geo_loopvar_for(colA, setof, ctx.var_shapes)
            lvB = _geo_loopvar_for(colB, setof, ctx.var_shapes)
            (lvA === nothing || lvB === nothing) && continue
            (haskey(ctx.env, colA) && haskey(ctx.env, colB)) || continue
            push!(gates, _GeoJoinGate(ctx.env[colA], lvA, ctx.env[colB], lvB))
        end
    end
    return gates
end

# The geometry chain COMPILES ONCE per materialization sweep into the shared
# `_Node` IR and evaluates per cell through `_eval_node`: see
# tree_walk/geometry_compile.jl for the compiler (`_geo_compile` / `_geo_source`),
# the compiled gate (`_geo_gate_ok`), and the
# `:geo_gather`/`:geo_pia`/`:geo_skolem`/`:geo_agg` evaluator arms.

# A clip ranged over an outer index set: an array-producing aggregate whose body
# is `index(intersect_polygon(src[outer], tgt[outer]), ring, coord)`. The
# array-producing form is the on-disk `aggregate` op with a non-empty `output_idx`
# (schema v0.8.0; the op enum dropped `arrayop`), OR the internal `arrayop` alias
# `shape_promotion.jl` still emits — `_is_aggregate_op` accepts both, and the
# non-empty `output_idx` guard keeps a SCALAR reduction (empty `output_idx`) out.
_is_ranged_clip(rhs) =
    rhs isa OpExpr && _is_aggregate_op(rhs.op) &&
    rhs.output_idx !== nothing && !isempty(rhs.output_idx) &&
    rhs.expr_body isa OpExpr &&
    (rhs.expr_body::OpExpr).op == "index" &&
    length((rhs.expr_body::OpExpr).args) >= 1 &&
    (rhs.expr_body::OpExpr).args[1] isa OpExpr &&
    ((rhs.expr_body::OpExpr).args[1]::OpExpr).op == "intersect_polygon"

# Materialize a per-outer-cell family of clip rings, padded to the max distinct-
# vertex count (the pad repeats the closing vertex so the shoelace pad-edges add
# zero area), into one dense const array `[outer…, maxn+1, coord]`; record the
# clip_ring extent so the polygon_area FAQ ranges `[1, maxn]` over it.
function _materialize_ranged_clip(arrayop, env, index_sets, derived_extents,
                                  var_shapes=Dict{String,Vector{String}}())
    body  = arrayop.expr_body::OpExpr          # index(intersect_polygon(...), w, c)
    ipoly = body.args[1]::OpExpr
    ringvar  = (body.args[2]::VarExpr).name
    coordvar = (body.args[3]::VarExpr).name
    outer = String[v for v in arrayop.output_idx if v != ringvar && v != coordvar]
    outer_ext = Int[_geo_index_extent(arrayop.ranges[v], index_sets, derived_extents)
                    for v in outer]
    coord_ext = _geo_index_extent(arrayop.ranges[coordvar], index_sets, derived_extents)
    manifold = ipoly.manifold
    manifold === nothing && throw(TreeWalkError("E_TREEWALK_GEOMETRY_NO_MANIFOLD",
        "ranged intersect_polygon requires a manifold"))
    ctx = _GeoCtx(env, index_sets, derived_extents, var_shapes)
    # Compile the two polygon operands ONCE (ring sources over the outer loop
    # slots); each pair then resolves them against the frame — a `view`, no
    # copy, exactly as before (see tree_walk/geometry_compile.jl).
    nslots = Ref(0)
    scope = Dict{String,Int}()
    for lv in outer
        nslots[] += 1
        scope[lv] = nslots[]
    end
    g = _GeoCompileCtx(ctx, scope, Dict{String,String}(), nslots)
    srcA = _geo_source(ipoly.args[1], g)
    srcB = _geo_source(ipoly.args[2], g)
    u = zeros(Float64, nslots[])
    rings = Dict{Tuple,Matrix{Float64}}()
    maxn = 0
    for tup in Iterators.product((1:e for e in outer_ext)...)
        @inbounds for k in eachindex(outer); u[k] = Float64(tup[k]); end
        A = _geo_ring_value(srcA, u, nothing, 0.0, Float64)
        B = _geo_ring_value(srcB, u, nothing, 0.0, Float64)
        # A non-overlapping pair yields a degenerate (< 3 vertex) clip → a zero-area
        # cell; the matrix is sparse over non-candidate pairs and that is normal,
        # not an error (RFC §5.8: unmatched rows add the additive identity).
        ring = try
            r = intersect_polygon(A, B, manifold)
            size(r, 1) >= 3 ? close_ring(r) : zeros(Float64, 0, coord_ext)
        catch err
            err isa GeometryError ? zeros(Float64, 0, coord_ext) : rethrow()
        end
        rings[Tuple(tup)] = ring
        maxn = max(maxn, size(ring, 1) - 1)
    end
    maxn = max(maxn, 0)
    clip = zeros(Float64, (outer_ext..., maxn + 1, coord_ext)...)
    for (tup, ring) in rings
        nrows = size(ring, 1)
        nrows == 0 && continue          # empty overlap → cell stays zero (area 0)
        for w in 1:(maxn + 1)
            sr = w <= nrows ? w : 1     # pad rows repeat the closing vertex (row 1)
            for c in 1:coord_ext
                clip[tup..., w, c] = ring[sr, c]
            end
        end
    end
    ringset = arrayop.ranges[ringvar] isa IndexSetRef ?
              (arrayop.ranges[ringvar]::IndexSetRef).from : ringvar
    derived_extents[ringset] = maxn
    ipoly.id === nothing || (derived_extents[ipoly.id] = maxn)
    return clip
end

# The (init, ⊕) fold for a setup-time array reduction, keyed by the aggregate's
# `reduce` / `semiring`. Defaults to SUM (the `sum_product` FAQ additive identity),
# so every existing geometry materialization (`A_j` row-sum, `A_ij` map) is
# byte-identical; `min` / `max` / `prod` support a build-time BINNING-COORDINATE
# projection over an in-file geometry array (e.g. `src_lon[i] = min_v src_poly[i,v,1]`,
# RFC §8.6.1 broad phase) so the coordinate need not be supplied by the host.
#
# The identity VALUES are shared vocabulary with the runtime aggregate resolver:
# sourced from `_OPLUS_IDENTITY` (tree_walk/semiring.jl) so the 0̄ constants live
# in one table. Two behaviors DELIBERATELY diverge from `_aggregate_oplus_identity`
# (geometry-specific, behavior-pinned — do not "unify" silently):
#   * precedence: here `reduce` wins over `semiring`; the runtime resolver
#     treats `semiring` as authoritative (§5.1);
#   * spelling:  here the projection kinds `"sum"`/`"prod"` are accepted
#     (`_REDUCE_PROJECTION_KINDS`); the runtime resolver speaks only ⊕
#     spellings (`+`, `*`, `max`, `min`, `or`).
# Failure handling, however, now MATCHES the runtime: an unrecognized reduce
# spelling or semiring name FAILS CLOSED with the same E_TREEWALK codes rather
# than silently degrading to the additive fold (which previously also made a
# non-additive semiring name such as `max_product` silently SUM).
function _geo_reduce_fold(reduce_spec, semiring_spec)
    oplus = if reduce_spec !== nothing
        # `reduce` shorthand, plus the geometry-only projection spellings.
        reduce_spec == "sum" ? "+" : reduce_spec == "prod" ? "*" : reduce_spec
    elseif semiring_spec !== nothing
        # A `semiring` name resolves ⊕ through the same closed registry as the
        # runtime — unknown names fail closed here too.
        sr = get(_SEMIRING_REGISTRY, semiring_spec, nothing)
        sr === nothing && throw(TreeWalkError("E_TREEWALK_UNKNOWN_SEMIRING",
            "unknown semiring '$semiring_spec'; the closed registry is " *
            join(sort(collect(keys(_SEMIRING_REGISTRY))), ", ")))
        sr.oplus
    else
        "+"   # unspecified → additive fold (§5.1 note 1)
    end
    oplus == "+"   && return (_OPLUS_IDENTITY["+"], +)
    oplus == "min" && return (_OPLUS_IDENTITY["min"], min)
    oplus == "max" && return (_OPLUS_IDENTITY["max"], max)
    oplus == "*"   && return (_OPLUS_IDENTITY["*"], *)
    throw(TreeWalkError("E_TREEWALK_ARRAYOP_UNKNOWN_REDUCE",
        "unsupported geometry reduce=$(repr(reduce_spec)) / semiring=$(repr(semiring_spec)); " *
        "expected reduce ∈ (+, sum, *, prod, max, min) or a numeric registry semiring"))
end

# ---- The RANK-SPECIALIZED sweep (the geometry materializer's inner loops) ----
#
# The sweeps below were once written inline in `_materialize_geom_array` as
#
#     for tup in Iterators.product((1:e for e in exts)...)
#         ...; arr[tup...] = _eval_node(body, u, nothing, 0.0, Float64)
#
# with `exts::Vector{Int}`. Splatting a generator of statically-unknown length
# leaves the product iterator's type — and so `tup`'s — unknown to inference, and
# `zeros(Float64, exts...)` is rank-abstract. So every iteration paid a dynamic
# `iterate`, a boxed heterogeneous `tup`, and a dynamically dispatched `setindex!`
# through the splat: per-cell interpreter overhead that scales with the grid.
#
# The values are unchanged. `CartesianIndices` visits a column-major product in
# EXACTLY the order `Iterators.product` does (first index fastest), so both the
# assignment order and — what matters for bit-identity — the CONTRACTION FOLD
# ORDER are the same term sequence as before. Passing the rank-abstract `arr` to a
# method typed `Array{Float64,N}` costs one dynamic dispatch PER SWEEP and hands
# the loop body a statically known rank.
#
# `_eval_node`/`_geo_gate_ok` calls stay OUTSIDE any `@inbounds` region: a geometry
# gather's bounds check is load-bearing (a mis-derived extent must raise, not read
# a neighbouring cell), and `@inbounds` propagates into inlined callees. Only the
# frame writes — whose indices come from `CartesianIndices` over the array being
# written — are elided.
#
# That is half the fix. The other half is the `Any`-typed source payload each
# `:geo_gather` / `:geo_pia` node carries, which costs a dynamic dispatch per array
# read per cell; it lives in the evaluator arms (`_geo_gather_value`,
# `_geo_ring_value`, the `:geo_pia` arm — tree_walk/geometry_compile.jl) and is
# pure dispatch narrowing: the SAME method with the SAME arguments, reached through
# a concrete `isa` instead of a generic call. It has no kill switch because there
# is no alternative code path to switch to; the value oracle below covers the loop
# rewrite, and `geom_sweep_specialize_test.jl` compares the narrowed and generic
# arms directly by feeding a source type that misses the narrowed ones.

# `ESS_GEOM_SWEEP_SPECIALIZE_DISABLE=1` forces the original rank-abstract
# loops, keeping them available as the differential oracle (mirroring
# `ESS_SETUP_MAP_COMPILE_ONCE_DISABLE` / `ESS_STENCIL_DISABLE`).
_geom_sweep_specialize_disabled() =
    get(ENV, "ESS_GEOM_SWEEP_SPECIALIZE_DISABLE", "") == "1"

# `ESS_GEOM_SWEEP_VERIFY=1` runs BOTH sweeps on every materialization and
# throws unless the two arrays are `isequal` cell for cell (`isequal`, not `==`
# or `≈`: `-0.0`/`+0.0` must not be conflated and `NaN` must match `NaN`). One
# run over a real model then checks every geometry array in it. Costs a full
# second sweep, so it is opt-in.
_geom_sweep_verify() = get(ENV, "ESS_GEOM_SWEEP_VERIFY", "") == "1"

# ENGAGEMENT DIAGNOSTICS. FAST counts sweeps run rank-specialized, REF those
# run on the rank-abstract reference (only the kill switch and verify mode
# produce those). Purely observational — reset (`[] = 0`) around a build to
# attribute counts to one run.
const _GEOM_SWEEP_FAST = Ref{Int}(0)
const _GEOM_SWEEP_REF  = Ref{Int}(0)

# MAP sweep (no contracted indices), specialized on the output rank `N`.
function _geom_sweep_map!(arr::Array{Float64,N}, body, gates, filt,
                          u::Vector{Float64}, ov=nothing) where {N}
    for I in CartesianIndices(arr)
        @inbounds for k in 1:N
            u[k] = Float64(I[k])
        end
        # A no-contraction map still honors an output-cell join/filter gate: a
        # rejected cell keeps the zero-initialized 0̄ (a cross-bin W_ij, a
        # sub-atol sliver). Degenerate (no join/filter) ⇒ gate is always true.
        # `ov` is the OVERLAP membership test for a gate `_overlap_drive_plan`
        # declined to drive; `nothing` (the usual case) compiles away.
        _geo_ov_ok(ov, u) || continue
        _geo_gate_ok(gates, filt, u) || continue
        v = _eval_node(body, u, nothing, 0.0, Float64)
        @inbounds arr[I] = v
    end
    return arr
end

# CONTRACTING sweep, specialized on the output rank `N`, the contracted rank
# `M` and the fold `F`. The contracted slots follow the output slots in the
# frame (`_materialize_geom_array` allocates them in that order).
function _geom_sweep_contract!(arr::Array{Float64,N}, body, gates, filt,
                               u::Vector{Float64}, cidx::CartesianIndices{M},
                               init::Float64, fold::F, ov=nothing) where {N,M,F}
    for I in CartesianIndices(arr)
        @inbounds for k in 1:N
            u[k] = Float64(I[k])
        end
        acc = init
        for C in cidx
            @inbounds for k in 1:M
                u[N + k] = Float64(C[k])
            end
            _geo_ov_ok(ov, u) || continue
            _geo_gate_ok(gates, filt, u) || continue
            acc = fold(acc, _eval_node(body, u, nothing, 0.0, Float64))
        end
        @inbounds arr[I] = acc
    end
    return arr
end

# The REFERENCE sweeps — the original loops, verbatim, hoisted into functions.
# They are what `ESS_GEOM_SWEEP_SPECIALIZE_DISABLE=1` runs and what verify mode
# compares against. Note what they are and are not: a VALUE oracle, not a
# perf baseline. Hoisting the loops into a method lets Julia specialize on the
# concrete `arr` it is handed, so these do not reproduce the old cost exactly —
# they keep the `Iterators.product((1:e for e in exts)...)` splat (which is
# where most of it lived) but not the rank-abstract `setindex!`. What matters
# for their job is that the term sequence is the ORIGINAL one.
function _geom_sweep_map_ref!(arr, exts::Vector{Int}, body, gates, filt,
                              u::Vector{Float64}, nout::Int, ov=nothing)
    for tup in Iterators.product((1:e for e in exts)...)
        @inbounds for k in 1:nout; u[k] = Float64(tup[k]); end
        _geo_ov_ok(ov, u) || continue
        _geo_gate_ok(gates, filt, u) || continue
        arr[tup...] = _eval_node(body, u, nothing, 0.0, Float64)
    end
    return arr
end

function _geom_sweep_contract_ref!(arr, exts::Vector{Int}, cexts::Vector{Int},
                                   body, gates, filt, u::Vector{Float64},
                                   nout::Int, ncon::Int, init, fold, ov=nothing)
    for tup in Iterators.product((1:e for e in exts)...)
        @inbounds for k in 1:nout; u[k] = Float64(tup[k]); end
        acc = init
        for ct in Iterators.product((1:e for e in cexts)...)
            @inbounds for k in 1:ncon; u[nout + k] = Float64(ct[k]); end
            _geo_ov_ok(ov, u) || continue
            _geo_gate_ok(gates, filt, u) || continue
            acc = fold(acc, _eval_node(body, u, nothing, 0.0, Float64))
        end
        arr[tup...] = acc
    end
    return arr
end

# Overlap verify-mode assertion: the gated/driven array against the historic
# UNGATED dense sweep, `isequal` per cell. A failure here is not a bug in the
# drive — it is the honest report that this document's overlap clause CHANGES
# values, i.e. that a pruned pair would have contributed something other than
# the fold identity.
function _assert_geom_overlap_bit_identical(got, ref, out::Vector{String})
    size(got) == size(ref) || throw(TreeWalkError("E_TREEWALK_GEOMETRY_SETUP",
        "overlap-gate verify: shape $(size(got)) ≠ ungated reference $(size(ref))"))
    for I in CartesianIndices(ref)
        isequal(got[I], ref[I]) && continue
        throw(TreeWalkError("E_TREEWALK_GEOMETRY_SETUP",
            "overlap-gate verify: cell $(Tuple(I)) of an array over $(out) gave " *
            "$(got[I]) with the broad phase applied but $(ref[I]) without it — " *
            "a non-candidate tuple contributes something other than the fold identity"))
    end
    return nothing
end

# Verify-mode assertion: bitwise agreement, `isequal` per cell.
function _assert_geom_sweep_bit_identical(fast, ref, out::Vector{String})
    size(fast) == size(ref) || throw(TreeWalkError("E_TREEWALK_GEOMETRY_SETUP",
        "geometry sweep verify: shape $(size(fast)) ≠ reference $(size(ref))"))
    for I in CartesianIndices(ref)
        isequal(fast[I], ref[I]) && continue
        throw(TreeWalkError("E_TREEWALK_GEOMETRY_SETUP",
            "geometry sweep verify: cell $(Tuple(I)) of an array over $(out) " *
            "gave $(fast[I]) but the rank-abstract reference gave $(ref[I])"))
    end
    return nothing
end

# ---- The OVERLAP broad phase at SETUP (RFC §5.3 / projection-pushdown 2a) ----
#
# `_resolve_geo_join_gates` above resolves only bin-EQUALITY clauses; a Phase-2a
# `overlap` clause was once skipped here entirely, on the reasoning that "the
# semiring / VI join resolvers handle it". For an array that MATERIALIZES AT SETUP
# there is no other resolver — this sweep is the only evaluation the aggregate ever
# gets — so the gate was simply not applied, and a gated conservative-regrid weight
# matrix ran the full `#src × #tgt` product instead of the candidate set its
# contract promises.
#
# The gate is now honored, and — the point — it DRIVES enumeration rather than
# merely filtering it. WHICH symbol(s) the candidate set drives is not re-derived
# here: `_overlap_drive_plan` (src/broad_phase.jl) is the one implementation of
# that policy, already used by the value-invention producer (`_vi_enumerate_join`)
# and the dense aggregate expansion (`_foreach_aggregate_term`). This is its third
# consumer, and the candidate set comes from the same Phase-3a primitive the other
# two use (`_overlap_candidate_set` → STRtree when the GeometryOps extension is
# loaded, else the brute-force reference).
#
# WHAT THIS CHANGES. Applying a gate that was previously ignored is a SEMANTIC
# change, not a pure optimization: a tuple outside the candidate set no longer
# contributes its body, it contributes the fold identity 0̄ (§5.3). That is the
# specified meaning of the clause and what every other resolver already does. For
# the conservative-regrid shapes it is also value-NEUTRAL: disjoint envelopes ⇒
# disjoint polygons ⇒ `_polygon_intersection_area` returns exactly `+0.0`, which is
# what the `zeros` init already holds, and the applies' `A_ij > atol` filter drops
# those terms anyway. `ESS_GEOM_OVERLAP_GATE_VERIFY=1` checks that on a real model
# rather than arguing it. A document where a pruned tuple WOULD have contributed (a
# `min`/`prod` fold with no sliver filter) is a genuine behavior change — see
# `geom_overlap_drive_test.jl`, which pins exactly that case so the change is
# visible rather than silent. Under `reduce: min` the ungated sweep folds in the
# exact `0.0` a DISJOINT pair computes and drives the reduction to zero, while 0̄
# for `min` is `+Inf` — so the gated answer is the §5.3 one.
#
# SCOPE: the TOP-LEVEL materialization sweep only. A nested `:geo_agg` in the body
# keeps its ungated behaviour (`_geo_compile_agg` still routes through
# `_resolve_geo_join_gates`); no shipped template puts an overlap clause on a
# nested aggregate, and gating one would need its own drive plan.

# `ESS_GEOM_OVERLAP_GATE_DISABLE=1` skips resolution entirely, restoring the
# historic ungated dense sweep. It is the differential oracle for this change
# (mirroring `ESS_GEOM_SWEEP_SPECIALIZE_DISABLE` / `ESS_STENCIL_DISABLE`).
_geom_overlap_gate_disabled() =
    get(ENV, "ESS_GEOM_OVERLAP_GATE_DISABLE", "") == "1"

# `ESS_GEOM_OVERLAP_GATE_VERIFY=1` materializes every overlap-gated array BOTH
# ways — driven/gated, and the historic UNGATED dense sweep — and throws unless
# they are `isequal` cell for cell (`isequal`, not `==` or `≈`: `-0.0` must not
# pass for `+0.0` and `NaN` must match `NaN`). One run over a real model then
# checks every gated array in it. It costs a full dense sweep, which is the cost
# the gate exists to avoid, so it is opt-in.
_geom_overlap_gate_verify() =
    get(ENV, "ESS_GEOM_OVERLAP_GATE_VERIFY", "") == "1"

# ENGAGEMENT DIAGNOSTICS. DRIVE counts sweeps whose enumeration was driven from
# the candidate set (the O(#candidates) path); GATE_ONLY those where a gate
# resolved but `_overlap_drive_plan` declined to drive it, so the sweep stayed
# dense with a per-tuple membership test; NONE those with no usable overlap
# clause. Purely observational — reset (`[] = 0`) around a build to attribute
# counts to one run. A silently-declining drive shows up as DRIVE=0.
const _GEOM_OVERLAP_DRIVE     = Ref{Int}(0)
const _GEOM_OVERLAP_GATE_ONLY = Ref{Int}(0)
const _GEOM_OVERLAP_NONE      = Ref{Int}(0)

# A resolved setup-time OVERLAP gate: the shared `_JoinGate` (so it can be
# handed straight to `_overlap_drive_plan`) plus the frame slots its two range
# symbols occupy in this sweep's `u`.
struct _GeoOverlapGate
    gate::_JoinGate
    slot_l::Int
    slot_r::Int
end

# Membership test for the DENSE fallback (`_overlap_drive_plan` said `:none`):
# the tuple's two gated positions must be a candidate pair. `nothing` ⇒ no
# overlap gate, which admits everything and compiles away.
@inline _geo_ov_ok(::Nothing, u) = true
@inline function _geo_ov_ok(ov::_GeoOverlapGate, u)
    @inbounds return (Int(u[ov.slot_l]), Int(u[ov.slot_r])) in
        (ov.gate.candidates::_OverlapIndex)
end

# Build (or reuse) the candidate index for one overlap clause. ReSEACT resolves
# the SAME `(src_poly, tgt_poly, eps)` clause six times — once for `A_ij` and
# once per applied species — so the index is memoized per setup pass. The cache
# is scoped to one `_materialize_geometry_setup` call, where a name→array
# binding in `env` is written once and never replaced, which is what makes the
# name-keyed identity sound. Memoizing the `_OverlapIndex` (not the raw pair
# set) also shares its lazily built sorted-pair and adjacency views across the
# six sweeps.
function _geo_overlap_index(clause::_OverlapJoinSpec, env::AbstractDict, cache)
    key = (clause.src_env, clause.tgt_env, clause.eps)
    if cache !== nothing
        hit = get(cache, key, nothing)
        hit === nothing || return hit::_OverlapIndex
    end
    oi = _OverlapIndex(_overlap_candidate_set(clause.src_env, clause.tgt_env, env;
                                              eps=clause.eps))
    cache === nothing || (cache[key] = oi)
    return oi
end

# Resolve this aggregate's FIRST usable `overlap` clause against the sweep's
# lexical scope. Declines (⇒ `nothing`, i.e. the historic ungated sweep) when
# the kill switch is set, when either env-factor list does not map to a loop var
# in scope, or when a named envelope factor is not a materialized array in
# `env`. Every decline is a decline to a path that still produces the OLD
# values, never a silent wrong answer.
#
# The env-factor → loop-var rule is the setup path's own `_geo_loopvar_for`
# (the same one the bin-equality `on` keys use): the FIRST factor's FIRST shape
# axis names the range. That is deliberately rank-agnostic, matching
# `_envelope_vectors_from_cols`, which reads a single 1-name env factor as a
# `[pos, verts, coord]` RING stack — i.e. a 3-D array whose first axis is the
# position axis. (`_overlap_env_sym` in tree_walk/semiring.jl insists on a 1-D
# factor and so cannot resolve that ring form; the two disagree, and the ring
# form is the one every shipped `conservative_overlap_*_gated` template uses.)
function _geo_overlap_gate(arrayop, ctx::_GeoCtx, setof, scope, cache)
    arrayop.join === nothing && return nothing
    _geom_overlap_gate_disabled() && return nothing
    for clause in arrayop.join
        clause isa _OverlapJoinSpec || continue
        isempty(clause.src_env) && continue
        isempty(clause.tgt_env) && continue
        sym_l = _geo_loopvar_for(String(clause.src_env[1]), setof, ctx.var_shapes)
        sym_r = _geo_loopvar_for(String(clause.tgt_env[1]), setof, ctx.var_shapes)
        (sym_l === nothing || sym_r === nothing) && continue
        sym_l == sym_r && continue                # a self-join cannot drive
        sl = get(scope, sym_l, 0)
        sr = get(scope, sym_r, 0)
        (sl == 0 || sr == 0) && continue
        # Every envelope factor must be a materialized array of the rank
        # `_envelope_vectors_from_cols` expects for that list length: 1 name is a
        # `[pos, verts, coord]` RING stack (3-D), 2 or 4 names are per-position
        # columns (1-D). Checking here means a document that would have made the
        # Phase-3a primitive throw DECLINES to the historic ungated sweep
        # instead of failing a build that used to succeed.
        _geo_env_ok(names) = begin
            n = length(names)
            (n == 1 || n == 2 || n == 4) || return false
            want = n == 1 ? 3 : 1
            for f in names
                a = get(ctx.env, String(f), nothing)
                (a isa AbstractArray && ndims(a) == want) || return false
            end
            true
        end
        (_geo_env_ok(clause.src_env) && _geo_env_ok(clause.tgt_env)) || continue
        oi = _geo_overlap_index(clause, ctx.env, cache)
        return _GeoOverlapGate(_JoinGate(sym_l, sym_r, Dict{Int,Int}(),
                                         Dict{Int,Int}(), oi), sl, sr)
    end
    return nothing
end

# What the shared planner decided for THIS sweep. `pos_*` are 1-based positions,
# which double as frame slots: `_materialize_geom_array` allocates slot k to the
# k-th output index and slot `nout + k` to the k-th contracted index.
#
#   :pairs    — both gated symbols are OUTPUT indices; `pos_l`/`pos_r` are their
#               output positions and `restpos` the remaining output positions,
#               which product around each candidate pair.
#   :restrict — one gated symbol is an OUTPUT index (`pos_l`, bound per output
#               cell, living on side `side` of the pair) and the other is
#               CONTRACTED (`pos_r`, its position among the contracted indices).
struct _GeoOverlapDrive
    kind::Symbol
    pos_l::Int
    pos_r::Int
    restpos::Vector{Int}
    side::Symbol
end

# Ask `_overlap_drive_plan` (src/broad_phase.jl — the ONE implementation of the
# drive policy, shared with `_vi_enumerate_join` and `_foreach_aggregate_term`)
# how this sweep should be driven, and translate its answer into frame
# positions. Returns `nothing` for any shape it declines, or that this sweep
# cannot express — the caller then sweeps densely with the membership test, so
# a decline costs speed, never correctness.
function _geo_overlap_drive(ov::_GeoOverlapGate, out::Vector{String},
                            contract::Vector{String}, exts::Vector{Int},
                            index_sets, derived_extents, arrayop)
    g = ov.gate
    nout = length(out)
    if isempty(contract)
        # A pure MAP: both gated symbols are free, so the planner returns the
        # candidate PAIRS and they enumerate the output cells directly.
        plan = _overlap_drive_plan(g, out, Dict{String,Int}(),
            s -> (k = findfirst(==(s), out); k === nothing ? (1:0) : (1:exts[k])))
        plan[1] === :pairs || return nothing
        pl = findfirst(==(g.sym_l), out)
        pr = findfirst(==(g.sym_r), out)
        (pl === nothing || pr === nothing) && return nothing
        # Positions must BE the frame slots (they are, by construction); refuse
        # to drive rather than write the wrong slot if that ever stops holding.
        (ov.slot_l == pl && ov.slot_r == pr) || return nothing
        rest = Int[k for k in 1:nout if k != pl && k != pr]
        return _GeoOverlapDrive(:pairs, pl, pr, rest, :l)
    end
    # A CONTRACTION: bind the output indices (the planner only needs to know
    # WHICH are bound, so the probe cell's positions are immaterial) and ask
    # what the still-free contracted symbols may be restricted to.
    cexts = Int[_geo_index_extent(arrayop.ranges[c], index_sets, derived_extents)
                for c in contract]
    probe = Dict{String,Int}(o => 1 for o in out)
    plan = _overlap_drive_plan(g, contract, probe,
        s -> (k = findfirst(==(s), contract); k === nothing ? (1:0) : (1:cexts[k])))
    plan[1] === :restrict || return nothing
    free = String(plan[2])
    gc = findfirst(==(free), contract)
    gc === nothing && return nothing
    fixed = free == g.sym_l ? g.sym_r : g.sym_l
    po = findfirst(==(fixed), out)
    po === nothing && return nothing
    side = fixed == g.sym_l ? :l : :r
    # Same slot check as above, for both ends of the pair.
    slot_fixed = fixed == g.sym_l ? ov.slot_l : ov.slot_r
    slot_free  = free  == g.sym_l ? ov.slot_l : ov.slot_r
    (slot_fixed == po && slot_free == nout + gc) || return nothing
    return _GeoOverlapDrive(:restrict, po, gc, Int[], side)
end

# PAIRS-driven MAP sweep: `_overlap_drive_plan` bound BOTH gated symbols, and
# both are OUTPUT indices, so the candidate pairs enumerate the output cells
# directly and every remaining output index products around them. Output cells
# no pair reaches keep the zero-initialized 0̄ — exactly what the dense sweep's
# `_geo_gate_ok || continue` leaves behind for a rejected cell.
#
# `pairs` is `_overlap_sorted_pairs`, ascending by `(pos_l, pos_r)`; a MAP
# writes each cell independently, so the visit order cannot affect the result.
# An out-of-range position (an envelope factor longer than the declared range)
# is skipped rather than trusted.
function _geom_sweep_pairs_map!(arr::Array{Float64,N}, body, gates, filt,
                                u::Vector{Float64},
                                pairs::Vector{Tuple{Int,Int}},
                                pos_l::Int, pos_r::Int,
                                restpos::NTuple{K,Int},
                                restidx::CartesianIndices{K}) where {N,K}
    ix = zeros(Int, N)
    eL = size(arr, pos_l)
    eR = size(arr, pos_r)
    for (pl, pr) in pairs
        (1 <= pl <= eL && 1 <= pr <= eR) || continue
        @inbounds begin
            ix[pos_l] = pl; ix[pos_r] = pr
            u[pos_l] = Float64(pl); u[pos_r] = Float64(pr)
        end
        for R in restidx
            @inbounds for d in 1:K
                ix[restpos[d]] = R[d]
                u[restpos[d]] = Float64(R[d])
            end
            _geo_gate_ok(gates, filt, u) || continue
            v = _eval_node(body, u, nothing, 0.0, Float64)
            @inbounds arr[CartesianIndex(ntuple(d -> ix[d], Val(N)))] = v
        end
    end
    return arr
end

# RESTRICT-driven CONTRACTING sweep: one gated symbol is an output index (bound
# per output cell) and the other is contracted, so the contracted loop visits
# only that cell's candidate partners.
#
# The FOLD TERM SEQUENCE is preserved, which is what keeps a `+` reduction
# bit-identical to the gated dense sweep: `_overlap_partners` returns partners
# ASCENDING and `_overlap_restrict` proves the restriction is an order-preserving
# SUBSEQUENCE of the full range, and the surrounding contracted dimensions keep
# their nesting — so the visited tuples are exactly the dense column-major
# sequence with the gate-rejected ones removed, in the same relative order.
# Every removed term would have contributed 0̄, by the gate's definition.
function _geom_sweep_restrict_contract!(arr::Array{Float64,N}, body, gates, filt,
                                        u::Vector{Float64}, oi::_OverlapIndex,
                                        side::Symbol, pos_o::Int,
                                        cexts::NTuple{M,Int}, gc::Int, nout::Int,
                                        init::Float64, fold::F) where {N,M,F}
    for I in CartesianIndices(arr)
        @inbounds for k in 1:N
            u[k] = Float64(I[k])
        end
        acc = init
        parts = _overlap_partners(oi, side, I[pos_o])
        # `1:cexts[gc]` is an ascending contiguous `UnitRange`, the one shape
        # `_overlap_restrict` can always prove order-preserving, so it never
        # declines here. The assert is fail-closed insurance: a future caller
        # handing this a permuted range would raise rather than quietly fold a
        # different term set.
        vals = _overlap_restrict(1:cexts[gc], parts)::Vector{Int}
        if !isempty(vals)
            dims = ntuple(d -> d == gc ? length(vals) : cexts[d], Val(M))
            for C in CartesianIndices(dims)
                @inbounds for k in 1:M
                    u[nout + k] = Float64(k == gc ? vals[C[k]] : C[k])
                end
                _geo_gate_ok(gates, filt, u) || continue
                acc = fold(acc, _eval_node(body, u, nothing, 0.0, Float64))
            end
        end
        @inbounds arr[I] = acc
    end
    return arr
end

# Materialize a geometry-derived array observed (e.g. `area[p]`, `A_ij[i,j]`) by
# evaluating its `arrayop` body once per output cell against the (already
# materialized) geometry in `env`.
#
# Two shapes are handled uniformly. A pure MAP (`output_idx == ranges` keys, e.g.
# `A_ij[i,j] = polygon_intersection_area(src[i], tgt[j])`) evaluates the body once
# per output cell. A CONTRACTING aggregate — the on-disk einsum form where some
# `ranges` keys are NOT in `output_idx` (e.g. `A_j[j] = Σ_i A_ij[i,j]`, the
# row-sum) — sums the body over the contracted indices for each output cell. Both
# honor the aggregate's `join` / `filter` gate (`_geo_gate_ok`): a rejected
# contraction tuple contributes the additive identity 0̄ (RFC §5.3 / §5.8). This is
# the setup-time twin of the ODE arrayop einsum path.
function _materialize_geom_array(arrayop, env, index_sets, derived_extents,
                                 var_shapes=Dict{String,Vector{String}}();
                                 ov_cache=nothing)
    out  = String[v for v in arrayop.output_idx]
    exts = Int[_geo_index_extent(arrayop.ranges[v], index_sets, derived_extents) for v in out]
    # Contracted indices: `ranges` keys not among the output indices (§5.1). Their
    # extents are reduced (⊕ = + for the sum_product FAQ) per output cell.
    contract = String[k for k in keys(arrayop.ranges) if !(k in out)]
    # Seed the loop-var → index-set map with this arrayop's output AND contracted
    # indices, so a join can resolve a key column indexed by either (per-cell F_tgt
    # keys on an outer output var; the row-sum keys on the contracted `i`).
    setof = Dict{String,String}()
    for v in Iterators.flatten((out, contract))
        r = arrayop.ranges[v]
        r isa IndexSetRef && (setof[v] = r.from)
    end
    ctx = _GeoCtx(env, index_sets, derived_extents, var_shapes)
    # COMPILE ONCE per sweep (tree_walk/geometry_compile.jl): the loop vars
    # become frame slots (outputs first, then the contracted vars, in
    # declaration order), the body and filter lower to `_Node` trees, and the
    # join gate resolves to slot-addressed array equalities. The per-cell work
    # below is then one `_eval_node` walk over the Float64 frame — no string
    # dispatch, no per-node Dict lookups, no raw-AST re-walk (this sweep was
    # the #1 build hotspot).
    nslots = Ref(0)
    scope = Dict{String,Int}()
    for v in Iterators.flatten((out, contract))
        nslots[] += 1
        scope[v] = nslots[]
    end
    g = _GeoCompileCtx(ctx, scope, setof, nslots)
    gates = _geo_slot_gates(arrayop, g)
    filt = arrayop.filter === nothing ? nothing : _geo_compile(arrayop.filter, g)
    body = _geo_compile(arrayop.expr_body, g)
    u = zeros(Float64, nslots[])
    nout = length(out)
    arr  = zeros(Float64, exts...)
    # ---- The OVERLAP broad phase (see `_geo_overlap_gate` above) ----
    # Resolve the gate, then ask the SHARED planner (`_overlap_drive_plan`,
    # src/broad_phase.jl) which symbol(s) its candidate set drives. Only the two
    # shapes the conservative-regrid templates produce are driven here; anything
    # else keeps the dense sweep with the membership test applied per tuple
    # (`ov`), which is the same admitted set at the full product's cost.
    ov = _geo_overlap_gate(arrayop, ctx, setof, scope, ov_cache)
    drive = ov === nothing ? nothing :
            _geo_overlap_drive(ov, out, contract, exts, index_sets, derived_extents,
                               arrayop)
    ovdense = drive === nothing ? ov : nothing     # gate per tuple only if not driven
    if ov === nothing
        _GEOM_OVERLAP_NONE[] += 1
    elseif drive === nothing
        _GEOM_OVERLAP_GATE_ONLY[] += 1
    else
        _GEOM_OVERLAP_DRIVE[] += 1
    end
    # ---- The sweep (see `_geom_sweep_map!` / `_geom_sweep_contract!`) ----
    # The sweep counters describe the DENSE sweeps only; a candidate-driven
    # sweep runs neither of them and is counted by `_GEOM_OVERLAP_DRIVE`.
    # `ESS_GEOM_SWEEP_SPECIALIZE_DISABLE` therefore selects the loop SHAPE of a
    # dense sweep; `ESS_GEOM_OVERLAP_GATE_DISABLE` is what returns an
    # overlap-gated array to the historic ungated dense path (setting both gives
    # exactly the pre-change code).
    fast = !_geom_sweep_specialize_disabled()
    bump() = fast ? (_GEOM_SWEEP_FAST[] += 1) : (_GEOM_SWEEP_REF[] += 1)
    if isempty(contract)
        if drive !== nothing
            rp = Tuple(drive.restpos)
            _geom_sweep_pairs_map!(arr, body, gates, filt, u,
                                   _overlap_sorted_pairs(ov.gate.candidates::_OverlapIndex),
                                   drive.pos_l, drive.pos_r, rp,
                                   CartesianIndices(map(k -> exts[k], rp)))
        elseif fast
            bump()
            _geom_sweep_map!(arr, body, gates, filt, u, ovdense)
            if _geom_sweep_verify()
                ref = zeros(Float64, exts...)
                _geom_sweep_map_ref!(ref, exts, body, gates, filt, zero(u), nout, ovdense)
                _assert_geom_sweep_bit_identical(arr, ref, out)
            end
        else
            bump()
            _geom_sweep_map_ref!(arr, exts, body, gates, filt, u, nout, ovdense)
        end
    else
        init, fold = _geo_reduce_fold(arrayop.reduce, arrayop.semiring)
        cexts = Int[_geo_index_extent(arrayop.ranges[c], index_sets, derived_extents)
                    for c in contract]
        ncon = length(contract)
        if drive !== nothing
            _geom_sweep_restrict_contract!(arr, body, gates, filt, u,
                                           ov.gate.candidates::_OverlapIndex,
                                           drive.side, drive.pos_l,
                                           Tuple(cexts), drive.pos_r, nout,
                                           Float64(init), fold)
        elseif fast
            bump()
            _geom_sweep_contract!(arr, body, gates, filt, u,
                                  CartesianIndices(Tuple(cexts)), Float64(init), fold,
                                  ovdense)
            if _geom_sweep_verify()
                ref = zeros(Float64, exts...)
                _geom_sweep_contract_ref!(ref, exts, cexts, body, gates, filt,
                                          zero(u), nout, ncon, init, fold, ovdense)
                _assert_geom_sweep_bit_identical(arr, ref, out)
            end
        else
            bump()
            _geom_sweep_contract_ref!(arr, exts, cexts, body, gates, filt, u,
                                      nout, ncon, init, fold, ovdense)
        end
    end
    # ---- The overlap differential oracle (`ESS_GEOM_OVERLAP_GATE_VERIFY=1`) ----
    # Re-materialize the SAME array with no gate at all — the historic dense
    # sweep — and demand bitwise agreement. This is what turns "a pruned pair
    # contributes exactly 0̄ here" from an argument into a measurement.
    if ov !== nothing && _geom_overlap_gate_verify()
        ref = zeros(Float64, exts...)
        if isempty(contract)
            _geom_sweep_map_ref!(ref, exts, body, gates, filt, zero(u), nout, nothing)
        else
            init2, fold2 = _geo_reduce_fold(arrayop.reduce, arrayop.semiring)
            cexts2 = Int[_geo_index_extent(arrayop.ranges[c], index_sets, derived_extents)
                         for c in contract]
            _geom_sweep_contract_ref!(ref, exts, cexts2, body, gates, filt, zero(u),
                                      nout, length(contract), init2, fold2, nothing)
        end
        _assert_geom_overlap_bit_identical(arr, ref, out)
    end
    return arr
end

# ============================================================
# Build-once PROMOTED-PHYSICS MAP aggregates (fuel/moisture/wind lookups)
# ============================================================
# A build-once array observed need not be geometry. When a per-cell field (e.g.
# `FuelModelLookup.code`, temperature, wind) is produced by an in-model regridder,
# the behavior stack that consumed the formerly-scalar params (FuelModelLookup /
# EquilibriumMoistureContent / OneHourFuelMoisture / MidflameWind /
# RothermelFireSpread) is promoted to a build-once MAP over the fire `[x,y]` grid.
# Its body is PURE PHYSICS — `and`/`or`/`ifelse`, comparisons, `fn:interp.linear`,
# `const`, `exp`/`log` — ops the limited setup-time geometry LANGUAGE does
# NOT speak. Such a MAP must materialize through the GENERAL build-time cell
# evaluator (`_eval_cellwise`), the same one `_materialize_setup_wholearray` uses.

# The exact op vocabulary of the setup-time geometry language (compiled by
# `_geo_compile`, tree_walk/geometry_compile.jl): the scalar arithmetic /
# comparison / rounding ops, the geometry leaves, and the nested
# aggregate/index gathers. A build-once MAP whose body uses ONLY these needs
# no help — the geometry materializer already handles it (a loader-field
# reindex `F[c] = F_raw[floor((c-1)/GX)+1, …]`, a constructed cell ring
# `tgt_poly[j,v,k] = ifelse(k==1, …, …)`, a geometry weight over a derived set).
# A body that reaches for an op OUTSIDE this set — `and`/`or`/`not`, `fn`
# (`interp.linear`), `const`, `exp`/`log`/`tan`/… — is a PROMOTED PHYSICS lookup that
# only the general evaluator speaks; those, and only those, route to `_eval_cellwise`.
# Membership is declared per-op in src/op_registry.jl (flag `:geo_eval`) and
# pinned by op_registry_test.jl.
const _GEO_EVAL_OPS = _ops_with(:geo_eval)

# True iff any op node in the subtree is OUTSIDE the `_GEO_EVAL_OPS` vocabulary
# — i.e. the body cannot be materialized by the setup-time geometry path and
# needs the general build-time cell evaluator instead.
function _body_needs_general_eval(e::OpExpr)
    e.op in _GEO_EVAL_OPS || return true
    any(a -> a isa OpExpr && _body_needs_general_eval(a), e.args) && return true
    e.expr_body isa OpExpr && _body_needs_general_eval(e.expr_body::OpExpr) && return true
    e.filter isa OpExpr && _body_needs_general_eval(e.filter::OpExpr) && return true
    if e.values !== nothing
        any(v -> v isa OpExpr && _body_needs_general_eval(v), e.values) && return true
    end
    return false
end

# True iff `rhs` is a build-once NON-GEOMETRY MAP aggregate that NEEDS the general
# evaluator: an array-producing `aggregate`/`arrayop` (non-empty `output_idx`) that
# is a pure MAP — every range key is an output index, so no top-level CONTRACTION —
# carries no join/filter gate, and whose body reaches an op OUTSIDE the geometry
# vocabulary `_GEO_EVAL_OPS` (`and`/`fn`/`const`/`exp`/`log`/…) — i.e. a promoted
# per-cell physics lookup.
# Every genuine geometry aggregate — a `polygon_intersection_area` weight, a
# `A_j[j] = Σ_i A_ij[i,j]` row-sum, a constructed cell ring, a binning coordinate, a
# skolem-bin producer, a loader-field reindex — uses ONLY `_GEO_EVAL_OPS` and so
# stays on the compiled geometry path (`_materialize_geom_array`), byte-identical.
function _is_setup_general_map(rhs)
    (rhs isa OpExpr && _is_aggregate_op(rhs.op)) || return false
    (rhs.output_idx !== nothing && any(s -> s isa AbstractString, rhs.output_idx)) || return false
    rhs.expr_body === nothing && return false
    (rhs.join === nothing && rhs.join_gates === nothing && rhs.filter === nothing) || return false
    out = Set{String}(String(s) for s in rhs.output_idx if s isa AbstractString)
    ranges = rhs.ranges === nothing ? Dict{String,Any}() : rhs.ranges
    all(k -> String(k) in out, keys(ranges)) || return false   # pure MAP: no contraction
    return _body_needs_general_eval(rhs::OpExpr)
end

# ------------------------------------------------------------
# Compile-once materialization of a promoted-physics MAP
# ------------------------------------------------------------
# The per-cell loop below re-ran the WHOLE build-time pipeline (`_index_at_cell` →
# `_resolve_indices` → `_compile` → `_eval_node`) once per output cell, so a
# promoted per-cell physics lookup over an N-cell grid paid N FULL AST LOWERINGS
# and made build cost scale with the grid.
#
# The cure already exists in this package: the compile-once cell evaluator
# (`_cellwise_compile_once`, tree_walk/helpers.jl), which resolves + compiles ONCE
# with the output indices kept SYMBOLIC and bound as reserved parameters. A const
# read carrying an output index does not constant-fold; it lowers to a runtime
# `_NK_CONST_GATHER` that recomputes its column-major offset at eval time — exactly
# the "gather compiled once, evaluated per cell" shape a per-cell physics lookup
# needs. `_is_setup_general_map` has already established the preconditions
# (aggregate op, all-String `output_idx`, non-nothing `expr_body`, no
# join/join_gates/filter, pure MAP), so `_resolve_index_of_arrayop` takes its
# no-contraction early return and the body is a single substituted tree.
#
# BIT-EXACTNESS. The fast path engages only where the compiled tree is provably
# value-identical to the folded per-cell tree, so the materialized array is
# `isequal`-identical (signed zeros and NaNs included), not merely close:
#
#  1. Same numbers, same order. Substituting the output index as a SYMBOL instead
#     of a literal changes nothing else — same body, same term order, same
#     `_eval_node`, every leaf in `Float64`. A loop index bound as a `Float64`
#     param equals that index folded to a `Float64` literal.
#  2. Index arithmetic (`_subscripts_int_exact`). A gather subscript that stays
#     symbolic is evaluated in `Float64` and `round(Int, …)`-ed by the
#     `_NK_CONST_GATHER` arm, whereas a folded one goes through `_eval_const_int`
#     in INTEGER arithmetic. Those agree on every op in the index vocabulary
#     except `/`, which is TRUNCATING `div` for `_eval_const_int` and true division
#     in `Float64`. So any `/` under an `index` subscript declines the fast path.
#  3. Boundary policy (`_ca_boundaries_all_error`). An out-of-range subscript is
#     resolved by `_resolve_const_index` per the array's declared policy when it
#     folds, but the runtime gather linearizes unconditionally. For a plain
#     (`:error`) array the two cannot disagree on a model that builds at all — an
#     OOB fold THROWS, so a successful build has no OOB gather — but a
#     `:periodic`/`:clamp` `BoundedConstArray` makes OOB legal and the two would
#     then differ. Any non-`:error` const array declines the fast path.
#
# RESIDUAL, stated precisely: (3) argues from "the model builds today". On a model
# that does NOT — one whose promoted MAP gathers a plain const array out of range —
# the per-cell path raises `E_TREEWALK_CONSTARRAY_OOB`, while the compiled gather
# raises `BoundsError` only if the LINEARIZED offset also leaves the array; an
# overflow confined to a non-final dimension reads a neighbouring element instead.
# So a model that today fails LOUDLY could now build with a wrong cell. This is the
# same property the shipped `evaluate_cellwise` path has, and fixing it belongs in
# the `_NK_CONST_GATHER` eval arm (a per-dimension bounds check) rather than here,
# where it would also cost the runtime stencil kernels that share that arm.
# `ESS_SETUP_MAP_COMPILE_ONCE_VERIFY=1` detects it in one run over a real model.

# `ESS_SETUP_MAP_COMPILE_ONCE_DISABLE=1` forces the per-cell loop, keeping it
# available as the differential oracle (mirroring `ESS_STENCIL_DISABLE` /
# `ESS_LANE_INTERN_DISABLE`).
_setup_map_compile_once_disabled() =
    get(ENV, "ESS_SETUP_MAP_COMPILE_ONCE_DISABLE", "") == "1"

# `ESS_SETUP_MAP_COMPILE_ONCE_VERIFY=1` runs BOTH paths on every engaged MAP and
# throws unless the two arrays are `isequal` cell for cell (`isequal`, not `==`
# or `≈`: `-0.0`/`+0.0` must not be conflated and `NaN` must match `NaN`). It is
# the differential oracle in ASSERTING form — one run over a real model checks
# every promoted-physics MAP in it instead of only what a fixture reproduces.
# Costs a full per-cell materialization on top, so it is opt-in.
_setup_map_compile_once_verify() =
    get(ENV, "ESS_SETUP_MAP_COMPILE_ONCE_VERIFY", "") == "1"

# ENGAGEMENT DIAGNOSTICS. HITS counts MAPs materialized by the compile-once
# path, MISS those that fell back to the per-cell loop (a decline, or an
# eval-time error). Purely observational — reset (`[] = 0`) around a build to
# attribute counts to one run.
const _SETUP_MAP_FASTPATH_HITS = Ref{Int}(0)
const _SETUP_MAP_FASTPATH_MISS = Ref{Int}(0)

# The ops on which `_eval_const_int` (integer) and `_eval_node` (Float64 +
# `round(Int, …)`) can disagree for exact-integer operands. Only `/` qualifies:
# `_eval_const_int` maps it to truncating `div`, `_compile` to true division.
# (`floor` is a pass-through there, so `floor(a/b)` is rejected by the same walk.)
const _INDEX_INEXACT_OPS = Set{String}(["/"])

# True iff no `index` subscript anywhere in `e` uses an op whose integer and
# Float64 readings can differ (guard 2 above). Both walks go through
# `foreach_subexpr_once`, the ONE generated `OPEXPR_FIELD_TABLE` traversal, so a
# subscript hidden in a nested body / filter / value / bound / table axis is seen
# — a hand-rolled `args`-and-a-few-fields walk would silently miss those. (A
# predicate scan is exactly what its identity memo is safe for.)
function _subscripts_int_exact(e::ASTExpr)::Bool
    ok = true
    foreach_subexpr_once(e) do n
        (ok && n isa OpExpr && (n::OpExpr).op == "index") || return
        args = (n::OpExpr).args
        for k in 2:length(args)
            _subtree_free_of(args[k], _INDEX_INEXACT_OPS) && continue
            ok = false
            return
        end
    end
    return ok
end

# True iff no op in the subtree is named in `banned`.
function _subtree_free_of(e::ASTExpr, banned::Set{String})::Bool
    ok = true
    foreach_subexpr_once(e) do n
        (n isa OpExpr && (n::OpExpr).op in banned) && (ok = false)
    end
    return ok
end

# True iff every const array carries the default `:error` boundary policy, so a
# folded OOB gather would THROW rather than silently wrap/clamp (guard 3 above).
function _ca_boundaries_all_error(ca::AbstractDict)::Bool
    for (_, v) in ca
        v isa BoundedConstArray || continue
        all(b -> b === :error, v.boundary) || return false
    end
    return true
end

# The compile-once cell evaluator for a promoted-physics MAP, or `nothing` to
# keep the per-cell loop. Every decline is silent and lossless — the caller falls
# back to the byte-identical reference path.
function _setup_map_compile_once(rhs::OpExpr, nd::Int, ca::AbstractDict,
                                 registered_functions::AbstractDict,
                                 params::AbstractDict)
    nd >= 1 || return nothing
    _setup_map_compile_once_disabled() && return nothing
    _ca_boundaries_all_error(ca) || return nothing
    _subscripts_int_exact(rhs) || return nothing
    return _cellwise_compile_once(rhs, nd, ca, registered_functions, params)
end

# Materialize a build-once NON-GEOMETRY MAP aggregate by evaluating its body once
# per output cell through the GENERAL build-time cell pipeline: `_eval_cellwise`
# wraps the MAP as `index(agg, cell…)`, `_resolve_index_of_arrayop` substitutes the
# output indices, then `_compile`/`_eval_node` run the full scalar language against
# the materialized `env` (its array entries become gatherable const arrays, its
# scalar params bind by name). Byte-identical to the ODE RHS resolver — the twin of
# `_materialize_setup_wholearray`, just ranging over the aggregate's declared
# `output_idx`/`ranges` extents instead of a makearray's regions.
function _materialize_setup_general_map(rhs::OpExpr, env::AbstractDict,
                                        index_sets, derived_extents,
                                        registered_functions::AbstractDict)
    out  = String[String(s) for s in rhs.output_idx if s isa AbstractString]
    exts = Int[_geo_index_extent(rhs.ranges[v], index_sets, derived_extents) for v in out]
    ca, params = _setup_env_split(env)
    nd = length(out)
    # ---- Compile-once fast path (see `_setup_map_compile_once` above) ----
    # Resolve+compile the MAP body ONCE with the output indices bound as
    # parameters, then walk the cells rebinding only those. Any decline (⇒
    # `nothing`) or ANY eval-time error keeps the untouched per-cell loop below,
    # so both the values and the error behaviour stay exactly as before.
    ce = _setup_map_compile_once(rhs, nd, ca, registered_functions, params)
    if ce !== nothing
        fast = try
            _fill_map_fast(ce, exts, nd)
        catch err
            # Anything the compiled tree cannot evaluate (a gather the guards did
            # not anticipate, an unsupported leaf) → the per-cell reference below,
            # which reproduces the original values or the original error. A
            # user interrupt is NOT a fallback trigger: this sweep can be long,
            # and silently restarting it on the slower path is the opposite of
            # what Ctrl-C asked for.
            err isa InterruptException && rethrow()
            nothing
        end
        if fast !== nothing
            _SETUP_MAP_FASTPATH_HITS[] += 1
            _setup_map_compile_once_verify() || return fast
            ref = _fill_map_percell(rhs, exts, ca, registered_functions, params)
            _assert_map_bit_identical(rhs, fast, ref)
            return fast
        end
    end
    _SETUP_MAP_FASTPATH_MISS[] += 1
    return _fill_map_percell(rhs, exts, ca, registered_functions, params)
end

# Compile-once cell sweep: one preallocated `cell` buffer, rebound per cell.
function _fill_map_fast(ce, exts::Vector{Int}, nd::Int)
    arr = zeros(Float64, exts...)
    cell = Vector{Int}(undef, nd)
    for I in CartesianIndices(Tuple(exts))
        @inbounds for d in 1:nd
            cell[d] = I[d]
        end
        arr[I] = ce(cell)
    end
    return arr
end

# The REFERENCE cell sweep — the original per-cell loop, unchanged. It is both
# the fallback for anything the fast path declines and the oracle the verify
# mode (and `ESS_SETUP_MAP_COMPILE_ONCE_DISABLE=1`) compares against.
function _fill_map_percell(rhs::OpExpr, exts::Vector{Int}, ca::AbstractDict,
                           registered_functions::AbstractDict, params::AbstractDict)
    arr = zeros(Float64, exts...)
    for I in CartesianIndices(Tuple(exts))
        arr[I] = _eval_cellwise(rhs, Int[Tuple(I)...]; const_arrays=ca,
                                registered_functions=registered_functions,
                                params=params)
    end
    return arr
end

# Verify-mode assertion: bitwise agreement, `isequal` per cell.
function _assert_map_bit_identical(rhs::OpExpr, fast::Array{Float64},
                                   ref::Array{Float64})
    size(fast) == size(ref) || throw(TreeWalkError("E_TREEWALK_GEOMETRY_SETUP",
        "setup-map compile-once verify: shape $(size(fast)) ≠ reference $(size(ref))"))
    for I in CartesianIndices(ref)
        isequal(fast[I], ref[I]) && continue
        throw(TreeWalkError("E_TREEWALK_GEOMETRY_SETUP",
            "setup-map compile-once verify: cell $(Tuple(I)) of a MAP over " *
            "$(rhs.output_idx) gave $(fast[I]) but the per-cell reference gave " *
            "$(ref[I])"))
    end
    return nothing
end

# ============================================================
# Build-once NON-aggregate whole-array observeds (makearray / reshape)
# ============================================================
# A build-once array observed need not be an `aggregate` MAP. A discretization
# rule lowers `D(field)` to a `makearray` STENCIL (the `central_D1x/D1y_periodic`
# rules' interior + periodic-boundary regions, each region a nested
# central-difference aggregate over the regridded field), and a shape rewrite may
# emit a `reshape`. Neither carries `output_idx`/`ranges`, so `_materialize_geom_array`
# (which ranges over `output_idx`) cannot evaluate them. Materialize them here
# against the already-materialized `env` (the const arrays + scalar params the
# aggregate path also reads): a `makearray` is evaluated once per output cell
# through the SAME build-time array pipeline the ODE RHS runs for
# `index(makearray,…)` — `_eval_cellwise` (`_index_at_cell` → `_resolve_indices`
# → `_compile` → `_eval_node`) — so its stencil semantics (region selection,
# nested central-difference, periodic wrap) stay byte-identical to the RHS
# resolver; a `reshape` (not an ODE-RHS-evaluable op) materializes its source
# array and reshapes it column-major.

# True iff `rhs` is a whole-array op with no `output_idx`/`ranges` to range over
# — a `makearray` stencil or a `reshape`.
_is_setup_wholearray_op(rhs) =
    rhs isa OpExpr && ((rhs::OpExpr).op == "makearray" || (rhs::OpExpr).op == "reshape")

# Output extents of a build-once makearray/reshape observed. The observed's
# declared shape (index-set names per dim, in `shape_sets`) drives the extents —
# resolved against the document index sets + derived extents, exactly like the
# aggregate path. Fallbacks keep a shapeless op materializable: a makearray's
# per-dimension region maximum (the regions partition the whole output), or a
# reshape's own integer/symbolic target `shape`.
function _setup_wholearray_extents(rhs::OpExpr, shape_sets::Vector{String},
                                   index_sets, derived_extents)
    isempty(shape_sets) ||
        return Int[_geo_index_extent(s, index_sets, derived_extents) for s in shape_sets]
    if rhs.op == "makearray"
        regions = rhs.regions === nothing ? Vector{Vector{Vector{Any}}}() : rhs.regions
        isempty(regions) && throw(TreeWalkError("E_TREEWALK_GEOMETRY_SETUP",
            "cannot determine makearray output shape at setup (no declared shape, no regions)"))
        nd = length(regions[1])
        return Int[maximum(r[d][2] for r in regions) for d in 1:nd]
    end
    shp = rhs.shape
    shp === nothing && throw(TreeWalkError("E_TREEWALK_GEOMETRY_SETUP",
        "reshape at setup requires a target `shape`"))
    return Int[s isa Integer ? Int(s) :
               _geo_index_extent(String(s), index_sets, derived_extents) for s in shp]
end

# Split `env` into the (frozen) const-array registry (its array-valued entries —
# e.g. the regridded `elev_xy`) and the scalar-parameter scope (its Real entries —
# the grid spacing `dx`/`dy`, offsets, …) the build-time cell pipeline reads.
function _setup_env_split(env::AbstractDict)
    ca = Dict{String,AbstractArray{Float64}}()
    params = Dict{String,Float64}()
    for (k, v) in env
        ks = String(k)
        if v isa AbstractArray{Float64}
            ca[ks] = v
        elseif v isa AbstractArray && eltype(v) <: Real
            ca[ks] = Array{Float64}(v)
        elseif v isa Real
            params[ks] = Float64(v)
        end
        # A non-numeric array in `env` — e.g. the tuple-valued skolem bin-key
        # buffers that a broad-phase equi-join reads directly from `env` (a
        # value-invention `distinct`/`skolem` map materializes integer key tuples,
        # kept byte-identical across bindings) — is neither a gatherable Float64
        # const array nor a scalar param for the physics cell pipeline, so skip it.
        # (Previously this forced `Array{Float64}(v)` and crashed on the tuples the
        # moment a gated regrid and a promoted-physics MAP coexisted in one model.)
    end
    return ca, params
end

# Materialize a build-once `makearray` / `reshape` observed into a dense array
# against the already-materialized `env`.
#
#  * `makearray` — the stencil form a discretization rule lowers `D(field)` to.
#    Evaluate it once per output cell through `_eval_cellwise` (`_index_at_cell`
#    → `_resolve_indices` → `_compile` → `_eval_node`), the SAME build-time array
#    pipeline the ODE RHS runs for `index(makearray, …)`, so the region selection,
#    nested central-difference and periodic wrap stay byte-identical to the RHS
#    resolver.
#  * `reshape` — NOT an ODE-RHS-evaluable op, so materialize its SOURCE array
#    (`args[1]`, itself a setup array / aggregate / makearray) to a dense array and
#    reshape column-major (matching the numpy reference `reshape([1..6],[2,3])`
#    with `M[1,2]==3`) to the declared target shape.
function _materialize_setup_wholearray(rhs::OpExpr, env::AbstractDict,
                                       index_sets, derived_extents,
                                       shape_sets::Vector{String},
                                       registered_functions::AbstractDict)
    exts = _setup_wholearray_extents(rhs, shape_sets, index_sets, derived_extents)
    if rhs.op == "reshape"
        isempty(rhs.args) && throw(TreeWalkError("E_TREEWALK_GEOMETRY_SETUP",
            "reshape at setup requires a source array operand"))
        src = _setup_source_array(rhs.args[1], env, index_sets, derived_extents,
                                  registered_functions)
        length(src) == prod(exts) || throw(TreeWalkError("E_TREEWALK_GEOMETRY_SETUP",
            "reshape source has $(length(src)) elements but target shape needs $(prod(exts))"))
        return reshape(Array{Float64}(src), exts...)   # column-major, numpy-parity
    end
    ca, params = _setup_env_split(env)
    arr = zeros(Float64, exts...)
    for I in CartesianIndices(Tuple(exts))
        arr[I] = _eval_cellwise(rhs, Int[Tuple(I)...]; const_arrays=ca,
                                registered_functions=registered_functions,
                                params=params)
    end
    return arr
end

# The dense source array of a setup-time `reshape`: a bare reference to an
# already-materialized setup / const array in `env`, or an inline array producer
# (an aggregate map / a nested makearray) materialized in place.
function _setup_source_array(src, env, index_sets, derived_extents,
                             registered_functions)
    if src isa VarExpr && haskey(env, src.name) && env[src.name] isa AbstractArray
        return env[src.name]
    elseif src isa OpExpr && _is_aggregate_op(src.op) &&
           src.output_idx !== nothing && !isempty(src.output_idx)
        return _materialize_geom_array(src, env, index_sets, derived_extents)
    elseif src isa OpExpr && _is_setup_wholearray_op(src)
        return _materialize_setup_wholearray(src, env, index_sets, derived_extents,
                                             String[], registered_functions)
    end
    throw(TreeWalkError("E_TREEWALK_GEOMETRY_SETUP",
        "reshape source must be a build-once array (a setup/const array reference " *
        "or an inline array producer) at setup"))
end

# Geometry-derived ARRAY observeds to materialize at setup: those whose defining
# RHS contains an intersect_polygon (ranged clips), plus the closure of array
# observeds that depend on them WITHOUT touching a state variable. Single direct
# clips (in `geom_ring_vars`) keep the existing 2-D ring path. Returns the set and
# the name → RHS map.
# Every VarExpr name appearing anywhere in `expr` — the NON-BINDING twin of
# `free_variables`: it enumerates children through the ONE shared
# `child_exprs`/`foreach_subexpr` traversal (so it sees EVERY expression-bearing
# `OpExpr` field: args, aggregate/arrayop `expr_body`, integral `lower`/`upper`,
# makearray `values`, aggregate `filter` predicates, value-invention `key`s,
# table-lookup `table_axes`, and expression-valued dense `ranges` bounds), plus
# the `wrt` differentiation target, exactly as `free_variables` does. Unlike
# `free_variables` it does NOT subtract an arrayop/aggregate's bound loop
# symbols — we need the vars an expression READS, and every caller intersects
# the result with declared variable names (which drops the bound indices).
#
# Do NOT re-hand-roll the field list here. This walker feeds the setup-geometry
# dependency closure, the live-taint pass, `_resolve_observed`'s inlining
# trigger AND the cadence materialization split (`_discrete_materialize_split`),
# where a MISSED reference is a silent wrong answer: a def whose only state read
# sits in an aggregate `filter` used to classify as state-free and get frozen
# into a discrete-cadence cache at `u = 0` (ess-5d1). Routing through
# `child_exprs` is what keeps this walker from drifting out of sync with the
# rest of the IR again; `_build_discrete_materializer!` additionally CHECKS the
# result on the compiled fill nodes, so a future divergence fails loudly.
#
# IDENTITY-MEMOIZED (`foreach_subexpr_once`, expression.jl — the same generated
# field walk, deduplicated by `OpExpr` identity): the inputs here are routinely
# DAGs — `_resolve_observed` bodies keep sharing via `_sub_preserving`'s
# identity memo, and this walker runs INSIDE that resolver's fixed-point loop —
# so the plain path-walk (`foreach_subexpr`) was exponential on an observed
# chain whose levels each reference their predecessor ≥2× (ESS-1p5). A name set
# is dedup-insensitive, so the result is identical to the un-memoized walk.
function _referenced_var_names(expr, acc::Set{String}=Set{String}())
    expr isa ASTExpr || return acc
    foreach_subexpr_once(expr) do e
        if e isa VarExpr
            push!(acc, e.name)
        elseif e isa OpExpr && e.wrt !== nothing
            push!(acc, e.wrt::String)
        end
    end
    return acc
end

# Run `sweep` — a `() -> Bool` "did this pass change anything" closure — until a
# pass reports no change. The shared shape of the monotone set-propagation
# passes in `_geometry_setup_vars` (live taint, scalar-observed block,
# setup-forward, setup-backward) and the closure-materialization pass in
# `_derive_binning_coords`: each caller owns its seed set(s) and grows them
# inside `sweep`; saturation of a monotone pass over a finite universe always
# terminates.
function _saturate!(sweep::Function)
    while sweep()
    end
    return nothing
end

function _geometry_setup_vars(model, equations, geom_ring_vars, state_var_names,
                              live_params)
    defs = Dict{String,ASTExpr}()
    for eq in equations
        eq.lhs isa VarExpr || continue
        defs[(eq.lhs::VarExpr).name] = eq.rhs
    end
    observed_here = Set{String}(observed_unknowns(model))
    is_arr_obs(n) = haskey(model.variables, n) && n in observed_here &&
        _is_array_shape(model.variables[n].shape)
    # Live taint (ess-14f.4): a var whose defining expression (transitively)
    # reads a `param_arrays` buffer is a LIVE-FIELD observed — its value changes
    # each refresh, so it CANNOT be a build-once setup const. `F_tgt = A_ij ⊗
    # F_src / A_j` mixes setup-const weights (A_ij/A_j) with a live field (F_src):
    # the weights materialize at setup, but F_tgt itself must stay a runtime
    # observed (inlined into its readers below), never pulled into setup where
    # F_src is unbound. Seed from the live param names, propagate through `defs`.
    tainted = Set{String}()
    _saturate!() do   # LIVE-TAINT pass: propagate live-param reads through `defs`
        changed = false
        for (n, rhs) in defs
            n in tainted && continue
            refs = _referenced_var_names(rhs)
            if any(r -> (r in live_params) || (r in tainted), refs)
                push!(tainted, n); changed = true
            end
        end
        changed
    end
    setup = Set{String}()
    for (n, _) in defs
        (is_arr_obs(n) && !(n in geom_ring_vars) && !(n in tainted) && haskey(defs, n)) || continue
        # Seed on EITHER geometry leaf. `intersect_polygon` surfaces a ragged clip
        # ring (§8.1); the FUSED `polygon_intersection_area` returns the scalar
        # overlap area with no exposed ring (§8.6.1) — so an `A_ij[i,j] =
        # polygon_intersection_area(src[i], tgt[j])` aggregate is a build-once setup
        # const exactly like a ranged clip, just dense (no derived clip_ring set).
        (_expr_has_intersect_polygon(defs[n]) ||
         _expr_has_polygon_intersection_area(defs[n])) && push!(setup, n)
    end
    mvars = Set{String}(keys(model.variables))
    # An array observed is build-once-SETUP-materializable only if it does NOT read a
    # COMPUTED SCALAR OBSERVED — a scalar-shaped observed carrying a defining equation
    # (in `defs`). The setup-time evaluator resolves const arrays, parameters,
    # const-op / loader-field / bin-buffer observeds (all seeded into the setup env)
    # and other setup arrays, but it cannot evaluate an arbitrary scalar-observed
    # equation. So an observed that mixes a build-once spatial field with such a
    # scalar — the Rothermel slope factor `phi_s = phi_s_coeff · tan_phi²` reads the
    # computed scalar `phi_s_coeff` — must stay in the ODE RHS, where it GATHERS the
    # build-once const array (`index(TerrainRegrid.dzdx, …)`, registered by the
    # geometry setup) per cell and reads the scalar through the normal
    # observed-substitution path. A reference to an ARRAY observed (e.g. the
    # value-invention bin buffers `src_bin`/`tgt_bin` a broad-phase `join` gates on,
    # pulled into setup by the backward pass below) does NOT block, so pure-geometry
    # regrid chains are unaffected — byte-identical.
    _is_scalar_computed_obs(f) =
        haskey(model.variables, f) && f in observed_here &&
        !_is_array_shape(model.variables[f].shape) && haskey(defs, f)
    # The exclusion is TRANSITIVE. An array observed that reads a computed scalar
    # observed is setup-ineligible (above); so is one that GATHERS an ineligible
    # array observed — `R0 = f(index(IR,…))` cannot materialize at setup when `IR`
    # (which reads the scalar Rothermel constant `eta_s`) is itself rejected, since
    # `IR` is never in the setup env. A DIRECT-refs-only check lets `R0` slip in (its
    # own refs carry no scalar observed) and materialize with a dangling `IR` gather.
    # Propagate the block through the array-observed graph so the whole tainted cone
    # (IR, R0, R, …) stays together in the ODE-RHS array-inline path — never a split.
    # A no-op (byte-identical) for a pure-geometry regrid: nothing there reads a
    # computed scalar observed, so the block set is empty and setup is unchanged.
    blocked = Set{String}()
    _saturate!() do   # SCALAR-OBSERVED BLOCK pass: transitive setup-ineligibility
        changed = false
        for (n, rhs) in defs
            (is_arr_obs(n) && !(n in blocked)) || continue
            refs = intersect(_referenced_var_names(rhs), mvars)
            if any(_is_scalar_computed_obs, refs) || any(f -> f in blocked, refs)
                push!(blocked, n); changed = true
            end
        end
        changed
    end
    _saturate!() do   # SETUP-FORWARD pass: state-free dependents of setup vars
        changed = false
        for (n, rhs) in defs
            (is_arr_obs(n) && !(n in setup) && !(n in geom_ring_vars) &&
             !(n in tainted) && !(n in blocked)) || continue
            refs = intersect(_referenced_var_names(rhs), mvars)
            if any(f -> (f in setup) || (f in geom_ring_vars), refs) &&
               !any(f -> f in state_var_names, refs)
                push!(setup, n); changed = true
            end
        end
        changed
    end
    # Backward pass: also materialize state-free array observeds REFERENCED BY a
    # setup var — the bin buffers a broad-phase `join` gates on (src_bin/tgt_bin),
    # which a setup aggregate reads but which are not themselves geometry-derived.
    # A `const`-op operand (an in-file `src_poly` / `tgt_poly` ring stack the fused
    # leaf gathers per cell) is NOT pulled in here: it is build-time literal data
    # seeded into the setup env directly (and registered as a const_array for the
    # ODE), so it needs no `_materialize_geom_array` pass. A BARE-ALIAS observed
    # (`src_poly := mesh.src_poly`, a `VarExpr` def — the MPAS keyed-factor
    # re-exposure, esm-spec §4.6) is likewise NOT pulled in: it resolves to
    # build-time literal data under a second name, is registered as a const array by
    # the bare-alias pass, and is seeded into the setup env directly. Pulling it in
    # would hand `_materialize_geom_array` a bare `VarExpr` (no `output_idx` field)
    # and crash — a setup var reads the alias's value from `env`, it is not itself a
    # materialised aggregate.
    _saturate!() do   # SETUP-BACKWARD pass: state-free array observeds READ BY setup vars
        changed = false
        for n in collect(setup)
            for r in intersect(_referenced_var_names(defs[n]), mvars)
                (is_arr_obs(r) && !(r in setup) && !(r in geom_ring_vars) &&
                 !(r in tainted) && !(r in blocked) && haskey(defs, r) &&
                 !_is_const_op(defs[r]) && !(defs[r] isa VarExpr)) || continue
                rrefs = intersect(_referenced_var_names(defs[r]), mvars)
                any(f -> f in state_var_names, rrefs) && continue
                push!(setup, r); changed = true
            end
        end
        changed
    end
    return setup, defs, tainted
end

# Dependency order over the setup vars (clip before area before A_ij).
function _geom_setup_order(setup, defs)
    order = String[]; done = Set{String}()
    while length(order) < length(setup)
        progressed = false
        for n in setup
            n in done && continue
            if all(d -> d in done, intersect(_referenced_var_names(defs[n]), setup))
                push!(order, n); push!(done, n); progressed = true
            end
        end
        progressed || throw(TreeWalkError("E_TREEWALK_GEOMETRY_SETUP",
            "cyclic setup-time geometry dependency"))
    end
    return order
end

# A materialized value-invention map buffer (`Dict(position => bin key)`, the
# `src_bin`/`tgt_bin` broad-phase bins) as a dense vector the setup-time join gate
# indexes by loop position. Keys are 1-based positions over the buffer's 1-D index
# set (`_vi_materialize_map!`); the values are the bin keys (a tuple/int from
# `_vi_skolem`), compared only for equality by the gate.
function _vi_buf_vector(buf)
    isempty(buf) && return Any[]
    n = maximum(Int(k) for k in keys(buf))
    v = Vector{Any}(undef, n)
    for (k, val) in buf
        v[Int(k)] = val
    end
    return v
end

# The shared setup-time value environment (name → const array / scalar / bin
# buffer) both build-time materializers read. Effective precedence, HIGHEST
# first:
#   vi_maps  >  param_overrides  >  scalar-param defaults  >  const_arrays_kw
#            >  in-file `const`-op array observeds  >  const_obs_arrays
# This one assembly serves both former copies because their outcomes were
# already identical: `_materialize_geometry_setup` seeded kwarg-first and
# guarded the `const`-op pass with `haskey` (kwarg wins); `_derive_binning_coords`
# seeded `const`-op-first and let the kwarg pass overwrite (kwarg wins) — the
# same final map for every key, differing only in Dict insertion order, which
# nothing reads (every consumer does keyed lookups). The sources the binning
# derivation never passes (`const_obs_arrays`, `vi_maps`) default to `nothing`
# = skipped.
#
# Source notes (hoisted from the two call sites):
#  * `const`-op array observeds (in-file polygon ring stacks / fields) are
#    build-time literal data, seeded so a fused `polygon_intersection_area`
#    aggregate can gather a per-cell ring via `index(src_poly, i)` at setup.
#  * `const_obs_arrays` — resolved BARE-ALIAS const arrays
#    (`src_poly := mesh.src_poly`) and other already-materialized const-op
#    array observeds: a setup var reads the alias's VALUE from `env` (the alias
#    is registered as a const array, never materialized as an aggregate).
#  * scalar parameter OVERRIDES win over declared defaults: a setup-time node
#    may reference `atol`/`dx`/`dy` (sliver floor / bin quantization) — known
#    build-time constants that often have no `default`.
#  * `vi_maps` — materialized value-invention bin buffers (`src_bin`/`tgt_bin`)
#    a setup-time broad-phase `join` gates on; without the gate the denominator
#    row-sum contracts DENSELY and picks up spurious sub-grid slivers, breaking
#    the partition of unity (RFC §5.3 / §5.8).
function _build_setup_env(model, const_arrays_kw;
                          param_overrides=Dict{String,Float64}(),
                          const_obs_arrays=nothing, vi_maps=nothing)
    env = Dict{String,Any}()
    for (k, v) in const_arrays_kw
        env[String(k)] = v isa AbstractArray ? Array{Float64}(v) : v
    end
    for (n, defn) in observed_definitions(model)
        v = model.variables[n]
        (_is_array_shape(v.shape) && _is_const_op(defn)) || continue
        haskey(env, n) && continue
        env[n] = _const_op_to_array((defn::OpExpr).value)
    end
    if const_obs_arrays !== nothing
        for (n, v) in const_obs_arrays
            haskey(env, n) && continue
            env[n] = v
        end
    end
    for (n, v) in model.variables
        v.type == ParameterVariable && !_is_array_shape(v.shape) && v.default !== nothing &&
            (env[n] = Float64(v.default))
    end
    for (k, v) in param_overrides
        env[String(k)] = Float64(v)
    end
    if vi_maps !== nothing
        for (name, buf) in vi_maps
            env[String(name)] = _vi_buf_vector(buf)
        end
    end
    return env
end

# Declared shapes (index-set names per dim) — used to resolve join key columns.
function _declared_var_shapes(model)
    var_shapes = Dict{String,Vector{String}}()
    for (n, v) in model.variables
        v.shape === nothing && continue
        var_shapes[n] = String[String(s) for s in v.shape if s isa AbstractString]
    end
    return var_shapes
end

# Evaluate the geometry-setup vars in dependency order into const arrays.
# `vi_maps` carries any materialized value-invention bin buffers a setup-time
# broad-phase `join` gates on (RFC §5.3); `param_overrides` carries scalar
# parameter values (e.g. a sliver-filter `atol`, the bin width `dx`/`dy`) so a
# setup-time `filter`/quantization that references them resolves.
function _materialize_geometry_setup(setup, defs, model, const_arrays_kw,
                                     index_sets, derived_extents;
                                     vi_maps=Dict{String,Any}(),
                                     param_overrides=Dict{String,Float64}(),
                                     const_obs_arrays=Dict{String,Array{Float64}}(),
                                     registered_functions=Dict{String,Function}())
    out = Dict{String,AbstractArray{Float64}}()
    isempty(setup) && return out
    env = _build_setup_env(model, const_arrays_kw;
                           param_overrides=param_overrides,
                           const_obs_arrays=const_obs_arrays, vi_maps=vi_maps)
    var_shapes = _declared_var_shapes(model)
    # One broad-phase candidate index per distinct `overlap` clause, shared
    # across this pass (`_geo_overlap_index`). A conservative regrid resolves the
    # same `(src_poly, tgt_poly, eps)` clause once for the weight matrix and once
    # per applied species; building the STRtree six times, and its adjacency
    # views six times, is pure waste. Scoped to this call, where a name→array
    # binding in `env` is written once and never replaced.
    ov_cache = Dict{Tuple{Vector{String},Vector{String},Float64},_OverlapIndex}()
    for n in _geom_setup_order(setup, defs)
        rhs = defs[n]
        arr = if _is_ranged_clip(rhs)
            _materialize_ranged_clip(rhs, env, index_sets, derived_extents, var_shapes)
        elseif _is_setup_wholearray_op(rhs)
            # A `makearray` stencil (a `D(field)` lowering) or `reshape` — no
            # `output_idx`/`ranges` to range over. Evaluate per output cell via the
            # general build-time array pipeline against the materialized `env`.
            _materialize_setup_wholearray(rhs, env, index_sets, derived_extents,
                                          get(var_shapes, n, String[]), registered_functions)
        elseif _is_setup_general_map(rhs)
            # A promoted PER-CELL PHYSICS lookup (fuel/moisture/wind over the fire
            # grid): a pure MAP aggregate whose body reaches an op OUTSIDE the
            # geometry-FAQ vocabulary (`and`/`ifelse`/`interp.linear`/`const`/`exp`/
            # `log`). Materialize it through the general build-time cell evaluator (as
            # the makearray path does), byte-identical to the ODE RHS resolver. Every
            # geometry aggregate (a geometry weight, a contraction, a constructed ring,
            # a reindex — all `_GEO_EVAL_OPS`) fails `_is_setup_general_map` and falls
            # through to the compiled geometry materializer below.
            _materialize_setup_general_map(rhs, env, index_sets, derived_extents,
                                           registered_functions)
        else
            _materialize_geom_array(rhs, env, index_sets, derived_extents, var_shapes;
                                    ov_cache=ov_cache)
        end
        env[n] = arr
        out[n] = arr
    end
    return out
end

# ---- Build-time binning-COORDINATE derivation (RFC §8.6.1 broad phase) ----
# A broad-phase binning coordinate may be declared INLINE as an aggregate over the
# in-file cell geometry — a `reduce` projection (a bbox-min corner
# `src_lon[i] = min_v src_poly[i, v, 1]`) OR a plain affine MAP over a grid spec
# (the cartesian `lon[c] = x0 + ((c-1) mod GX)*dx + dx/2`) — instead of being
# supplied as a `const` vector. Such an observed reads only build-time data (scalar
# parameters and other build-time-constant arrays; never a state variable or a live
# loader field), so its value is a build-time constant: it is evaluated ONCE here
# and fed into the value-invention `const_arrays` so `skolem("bin",
# floor(index(src_lon,i)/dx), …)` resolves at setup, and to the typed build as a
# derived const array (excluded from the ODE like any `const`-op array observed).
# This keeps the fixture PURE — the coordinate is derived from geometry, not
# hand-supplied — and admits a TEMPLATE-CONSTRUCTED coordinate whose inputs (the
# cell rings) are themselves an aggregate over a grid spec. Determinism is
# preserved: the STATE-DEPENDENCE guard (`state_names`) and the requirement that
# every referenced factor fold to a build-time constant (a scalar param, a const
# array, or another statically-determinable aggregate) still REJECT a genuinely
# runtime coordinate — only §9.6.3-static build-time data becomes an index target.

# The `reduce` spellings that mark a 1-D aggregate observed as a build-time
# coordinate-PROJECTION seed in `_derive_binning_coords` below (RFC §8.6.1).
# The seed test there is deliberately the light check — reduce kind + declared
# 1-D shape (or a value-invention index target); the heavier per-reference
# state-freedom / build-time-constant checks run in the closure-materialization
# pass, which is what actually gates evaluation.
const _REDUCE_PROJECTION_KINDS = ("min", "max", "sum", "prod")

# The loop-bound symbols of an aggregate (its `ranges` keys + `output_idx`) — index
# names, not data references.
function _agg_bound_syms(e::OpExpr)
    bound = Set{String}()
    e.ranges !== nothing && for k in keys(e.ranges); push!(bound, String(k)); end
    e.output_idx !== nothing && for k in e.output_idx; push!(bound, String(k)); end
    return bound
end

# Materializable NON-const-op aggregate array observeds: name → expression. A
# build-time coordinate derivation can fold only these (an aggregate/arrayop over
# build-time data); a `const`-op / kwarg-supplied array observed is already seeded
# into `env` and is not a materialization candidate.
function _agg_array_obs_defs(model, env)
    d = Dict{String,OpExpr}()
    for (n, e) in observed_definitions(model)
        _is_array_shape(model.variables[n].shape) || continue
        haskey(env, n) && continue
        (e isa OpExpr && _is_aggregate_op(e.op)) || continue
        d[n] = e
    end
    return d
end

# Evaluate the inline binning-COORDINATE observeds into dense `Vector{Float64}`s,
# reusing the reduce-aware setup-time array materializer (`_materialize_geom_array`).
# The COORDINATE SEEDS are the 1-D array observeds that are a `reduce`-projection
# (the original const-geometry derivation) OR a value-invention skolem INDEX TARGET
# (`vi_index_targets` — this admits a TEMPLATE-CONSTRUCTED, aggregate-valued
# coordinate like the cartesian cell-centre map, or a reduce over constructed rings,
# as a skolem-bin index target). ONLY the seeds and their build-time-constant array
# dependencies are materialised — a model without a broad-phase coordinate is
# untouched (byte-identical), and no unrelated array observed is force-evaluated.
# Determinism is preserved: a coordinate whose closure reaches a live STATE variable
# (or any name absent from the build-time env) is NOT build-time-constant, so it is
# never materialised and never becomes an index target. Returns name → values.
function _derive_binning_coords(model, index_sets, const_arrays_kw, param_overrides,
                                vi_index_targets=Set{String}(),
                                registered_functions::AbstractDict=Dict{String,Function}())
    out = Dict{String,Vector{Float64}}()
    # The shared setup env (see `_build_setup_env` for the precedence proof that
    # this equals the assembly formerly inlined here): in-file `const`-op ring
    # stacks the projection gathers per cell via `index(src_poly, i)`, the
    # kwarg const arrays, and the scalar params/overrides.
    env = _build_setup_env(model, const_arrays_kw; param_overrides=param_overrides)
    # The LIVE names a build-time derivation may never read: the ODE states plus
    # the algebraic unknowns (esm-spec §6.3.1). An observed is not live by
    # declaration — whether it resolves is decided by whether its own factors
    # are in `env`, which is the test the loop below already makes.
    state_names = Set{String}(solver_unknowns(model))
    var_shapes = _declared_var_shapes(model)

    cand = _agg_array_obs_defs(model, env)   # materializable aggregate array observeds
    # Coordinate SEEDS: 1-D materializable coordinate buffers to derive.
    seeds = String[]
    for (n, e) in cand
        length(get(var_shapes, n, String[])) == 1 || continue
        (n in vi_index_targets ||
         (e.reduce !== nothing && e.reduce in _REDUCE_PROJECTION_KINDS)) || continue
        push!(seeds, n)
    end
    isempty(seeds) && return out             # byte-identical for a coordinate-free model

    # Transitive array-observed dependency closure of the seeds (reachability over
    # `cand`; a `const`-op / kwarg dep is already in `env`).
    want = Set{String}()
    stack = copy(seeds)
    while !isempty(stack)
        n = pop!(stack)
        (haskey(cand, n) && !(n in want)) || continue
        push!(want, n)
        for r in _referenced_var_names(cand[n])
            (haskey(cand, r) && !(r in want)) && push!(stack, r)
        end
    end

    # Materialise the reachable build-time-constant closure in dependency order. A
    # member referencing a live STATE variable — or any name absent from the
    # build-time env / not yet accepted — is skipped; its dependents then fail to
    # materialise and are simply not returned (the coordinate falls back to the
    # existing error). The fixpoint yields a valid topological order.
    derived_extents = Dict{String,Int}()
    accepted = Set{String}()
    _saturate!() do   # CLOSURE-MATERIALIZATION pass: accept once every dep resolves
        changed = false
        for n in want
            n in accepted && continue
            e = cand[n]; bound = _agg_bound_syms(e); ok = true
            for r in _referenced_var_names(e)
                r in bound && continue
                r in state_names && (ok = false; break)      # never a live state
                (haskey(env, r) || r in accepted) && continue
                ok = false; break                            # unresolved dep — retry / drop
            end
            ok || continue
            # A coordinate whose body reaches an op OUTSIDE the setup-time geometry
            # vocabulary (`_GEO_EVAL_OPS`) — a Lambert-conformal PROJECTION (`X[e] =
            # lambert_conformal_forward_x(lon[e],lat[e])`, trig/`^`/`fn`, an
            # `apply_expression_template` expansion) — cannot be compiled by
            # `_materialize_geom_array` (whose `_geo_compile` speaks only that
            # vocabulary). Route it to the GENERAL build-time cell pipeline
            # (`_eval_cellwise`, the full scalar + `fn` op set the ODE RHS resolver
            # uses), exactly as a promoted-physics MAP is materialised in
            # `_materialize_geometry_setup`. Because this runs BEFORE
            # `materialize_value_invention` (the seeds feed `const_arrays`), a
            # projected coordinate becomes visible to value-invention's `_vi_eval`
            # (which has no trig): the CALLER supplies only raw `lon`/`lat`, never
            # pre-projected `X`/`Y`. The geometry-vocabulary reduce-projection path
            # is unchanged (`_body_needs_general_eval` is false there).
            env[n] = if _body_needs_general_eval(e)
                _materialize_setup_general_map(e, env, index_sets, derived_extents,
                                               registered_functions)
            else
                _materialize_geom_array(e, env, index_sets, derived_extents, var_shapes)
            end
            push!(accepted, n); changed = true
        end
        changed
    end

    # Return the 1-D coordinate seeds that materialised to a build-time constant.
    for n in seeds
        haskey(env, n) || continue
        (env[n] isa AbstractArray && ndims(env[n]) == 1) || continue
        out[n] = vec(Array{Float64}(env[n]))
    end
    return out
end

# ---- Build-time OVERLAP-gate ENVELOPE-FACTOR derivation (§5.5.6) -----------
# An `join.overlap` gate names CONST-ARRAY envelope factors: its broad phase is
# computed ONCE at build time, so every factor it names must be build-time data
# by the time `_resolve_join_gates_for` runs. That is automatic for a plain
# parameter (`src_W[c]`) or a derived coordinate (`X[r]`, above) — but NOT for a
# factor living on a value-invented DERIVED axis.
#
# The projection-pushdown rewrite emits exactly such a factor: it re-points a
# binning aggregate onto the compact `pd_support__*` axis and gates it on the
# generated `pd_cell__*` gathers, `cell_F[c] = index(F, index(member_factor, c))`.
# Those cannot exist before value invention has sized the derived axis and fed
# the member factor back (Hook 1), so they are derived HERE, one hook later.
#
# Deliberately NARROW. A name is materialised only when it (a) is named by an
# overlap gate, (b) is not already const-array data, (c) is a 1-D array OBSERVED
# defined by an aggregate, and (d) reads nothing but build-time-constant names
# (never a live state) — exactly the determinism guard `_derive_binning_coords`
# applies. Anything else is left alone and the existing missing-factor error
# still surfaces. Evaluation goes through the GENERAL build-time cell pipeline
# (`_eval_cellwise` via `_materialize_setup_general_map`), which is the one that
# speaks indirect gathers (`index(F, index(M, c))`).
#
# `vi_extents` is the value-invention extent map, keyed by PRODUCER id; the
# setup materializer resolves a range by its index-set NAME, so derived sets are
# re-keyed through `from_faq` here. Returns name → dense values (empty, hence
# byte-identical, for a document with no overlap gate).

# Every `src_env` / `tgt_env` factor name of every OVERLAP join clause reachable
# from `model`'s variable expressions and equations.
function _overlap_env_factor_names(model)
    names = Set{String}()
    seen = IdDict{OpExpr,Nothing}()
    function visit(e)
        e isa OpExpr || return
        haskey(seen, e) && return
        seen[e] = nothing
        if e.join !== nothing
            for clause in e.join
                clause isa _OverlapJoinSpec || continue
                for f in clause.src_env; push!(names, String(f)); end
                for f in clause.tgt_env; push!(names, String(f)); end
            end
        end
        for a in e.args; visit(a); end
        visit(e.expr_body); visit(e.filter); visit(e.lower); visit(e.upper)
        e.values === nothing || for v in e.values; visit(v); end
    end
    for eqs in (model.equations, model.initialization_equations)
        eqs === nothing && continue
        for eq in eqs
            visit(eq.lhs); visit(eq.rhs)
        end
    end
    return names
end

function _derive_overlap_env_factors(model, index_sets, const_arrays_kw, param_overrides,
                                     vi_extents,
                                     registered_functions::AbstractDict=Dict{String,Function}())
    out = Dict{String,Vector{Float64}}()
    want = _overlap_env_factor_names(model)
    isempty(want) && return out                  # byte-identical: no overlap gate
    env = _build_setup_env(model, const_arrays_kw; param_overrides=param_overrides)
    todo = sort!(String[n for n in want if !haskey(env, n)])
    isempty(todo) && return out                  # every factor is already const data
    # Derived-set extents keyed by SET NAME (value invention keys them by producer id).
    derived_extents = Dict{String,Int}()
    for (sname, iset) in index_sets
        (iset isa IndexSet && iset.kind == "derived" && iset.from_faq !== nothing) || continue
        e = get(vi_extents, String(iset.from_faq), nothing)
        e === nothing || (derived_extents[String(sname)] = Int(e))
    end
    var_shapes = _declared_var_shapes(model)
    state_names = Set{String}(solver_unknowns(model))
    obs_defs = observed_definitions(model)
    # One SATURATING pass so a factor that gathers through another derived factor
    # resolves regardless of name order (the same fixpoint `_derive_binning_coords`
    # uses; monotone over a finite set, so it terminates).
    _saturate!() do
        changed = false
        for n in todo
            haskey(out, n) && continue
            e = get(obs_defs, n, nothing)
            e === nothing && continue
            length(get(var_shapes, n, String[])) == 1 || continue
            (e isa OpExpr && _is_aggregate_op(e.op)) || continue
            bound = _agg_bound_syms(e); ok = true
            for r in _referenced_var_names(e)
                r in bound && continue
                r in state_names && (ok = false; break)     # never a live state
                haskey(env, r) && continue
                ok = false; break                            # unresolved dep — retry / drop
            end
            ok || continue
            arr = _materialize_setup_general_map(e, env, index_sets, derived_extents,
                                                 registered_functions)
            env[n] = arr
            out[n] = vec(Array{Float64}(arr))
            changed = true
        end
        changed
    end
    return out
end
