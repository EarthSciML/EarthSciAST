# ========================================================================
# tree_walk/geometry_setup.jl — part of the tree-walk evaluator (gt-e8yw).
# Included by src/tree_walk.jl; see that file for the full layout and
# include order. Section 2 (build-time geometry): the M4 intersect_polygon clip kernel,
# the fused polygon_intersection_area leaf, ranged clips, the setup-time
# geometry evaluator (_GeoCtx/_geo_eval), and binning-coordinate derivation.
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
_expr_has_intersect_polygon(e::OpExpr) =
    e.op == "intersect_polygon" ||
    any(_expr_has_intersect_polygon, e.args) ||
    (e.expr_body !== nothing && _expr_has_intersect_polygon(e.expr_body))
_expr_has_intersect_polygon(::Expr) = false
_equations_have_intersect_polygon(eqs) =
    any(eq -> _expr_has_intersect_polygon(eq.lhs) || _expr_has_intersect_polygon(eq.rhs), eqs)

# An intersect_polygon may live in an equation RHS or in an observed variable's
# `expression` field (the shared geometry fixtures use the latter — the Python
# evaluator reads `variable.expression` directly).
function _model_has_intersect_polygon(model::Model)
    for (_, v) in model.variables
        v.expression isa Expr && _expr_has_intersect_polygon(v.expression) && return true
    end
    return _equations_have_intersect_polygon(model.equations)
end

# Resolve an intersect_polygon polygon operand to its const-array matrix. The clip
# runs at setup, so each operand must be a variable name supplied in `const_arrays`.
function _geometry_operand(arg::Expr, const_arrays_kw::AbstractDict, who::AbstractString)
    arg isa VarExpr || throw(TreeWalkError("E_TREEWALK_GEOMETRY_OPERAND",
        "intersect_polygon operand for '$who' must be a polygon variable name"))
    name = (arg::VarExpr).name
    haskey(const_arrays_kw, name) || throw(TreeWalkError("E_TREEWALK_GEOMETRY_OPERAND",
        "intersect_polygon operand '$name' for '$who' must be supplied in `const_arrays` " *
        "(the clip runs at setup time; RFC Appendix B.1)"))
    return const_arrays_kw[name]
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
        ring = try
            intersect_polygon(poly_a, poly_b, manifold)
        catch err
            err isa GeometryError &&
                throw(TreeWalkError("E_TREEWALK_GEOMETRY_CLIP", err.msg))
            rethrow()
        end
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
_expr_has_polygon_intersection_area(e::OpExpr) =
    e.op == "polygon_intersection_area" ||
    any(_expr_has_polygon_intersection_area, e.args) ||
    (e.expr_body !== nothing && _expr_has_polygon_intersection_area(e.expr_body))
_expr_has_polygon_intersection_area(::Expr) = false

# An intersection-area leaf may live in an equation LHS/RHS or in an observed
# variable's `expression` field (the shared fixtures use the latter).
function _model_has_polygon_intersection_area(model::Model, equations)
    for (_, v) in model.variables
        v.expression isa Expr && _expr_has_polygon_intersection_area(v.expression) && return true
    end
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
_collect_pia_operands!(::Expr, acc::Set{String}) = acc

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
    ring = try
        intersect_polygon(poly_a, poly_b, manifold)
    catch err
        err isa GeometryError &&
            throw(TreeWalkError("E_TREEWALK_GEOMETRY_CLIP", err.msg))
        rethrow()
    end
    size(ring, 1) < 3 && return 0.0
    return _polygon_area_via_faq(close_ring(ring), manifold)
end

# Resolve a polygon_intersection_area operand to its const polygon-ring matrix. The
# fused leaf is build-time-evaluable, so each operand must be a const-array variable
# name (supplied via `const_arrays` or a materialized `const`-op observed).
function _pia_operand_ring(arg::Expr, const_arrays::AbstractDict)
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
function _geo_index_extent(ref, index_sets, derived_extents)
    name = ref isa IndexSetRef ? ref.from : String(ref)
    haskey(derived_extents, name) && return derived_extents[name]
    s = index_sets === nothing ? nothing : get(index_sets, name, nothing)
    sz = s === nothing ? nothing :
         hasproperty(s, :size) ? getproperty(s, :size) :
         (s isa AbstractDict ? get(s, "size", get(s, :size, nothing)) : nothing)
    sz === nothing && throw(TreeWalkError("E_TREEWALK_GEOMETRY_SETUP",
        "cannot resolve extent of index set '$(name)' for setup-time geometry"))
    return Int(sz)
end

# Apply a scalar op at setup time (the polygon-area / overlap FAQ vocabulary).
function _geo_apply_scalar(op::AbstractString, a::Vector{Float64})
    op == "+"     && return sum(a)
    op == "*"     && return prod(a)
    op == "-"     && return length(a) == 1 ? -a[1] : a[1] - sum(@view a[2:end])
    op == "/"     && return a[1] / a[2]
    op == "^"     && return a[1] ^ a[2]
    op == "max"   && return maximum(a)
    op == "min"   && return minimum(a)
    op == "sqrt"  && return sqrt(a[1])
    op == "abs"   && return abs(a[1])
    op == "cos"   && return cos(a[1])
    op == "sin"   && return sin(a[1])
    op == "atan2" && return atan(a[1], a[2])
    op == "ifelse" && return a[1] != 0.0 ? a[2] : a[3]
    op == "floor" && return floor(a[1])
    op == "ceil"  && return ceil(a[1])
    op == ">"  && return a[1] >  a[2] ? 1.0 : 0.0
    op == "<"  && return a[1] <  a[2] ? 1.0 : 0.0
    op == ">=" && return a[1] >= a[2] ? 1.0 : 0.0
    op == "<=" && return a[1] <= a[2] ? 1.0 : 0.0
    op == "==" && return a[1] == a[2] ? 1.0 : 0.0
    op == "!=" && return a[1] != a[2] ? 1.0 : 0.0
    throw(TreeWalkError("E_TREEWALK_GEOMETRY_SETUP",
        "unsupported op '$(op)' in setup-time geometry"))
end

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

# Loop-invariant context for the setup-time geometry evaluator (`_geo_eval` /
# `_geo_agg_gate`): the value environment (name → const arrays + scalar params +
# materialized geometry), the document index-set registry, the derived-extent
# map, and the declared per-variable shapes (for join-column resolution). These
# four were previously threaded as positional args repeated verbatim at every
# recursive call site; only the loop-index environment (`idx_env`) and the
# loop-var → index-set map (`setof`) vary during a walk, so those stay
# positional. Build-time-only path — one small struct per materialization is
# fine. `derived_extents` is read-only inside the walk (it is grown by the
# materializers before evaluation).
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

# Aggregate gate: honor a `join` (key-equality across the joined columns — the
# bin-skolem BROAD PHASE) and a `filter` predicate (sliver removal). A tuple that
# fails either contributes the additive identity (RFC §5.3 / §5.8); ignoring the
# join is numerically equivalent (non-candidate pairs have zero overlap) but the
# gate makes the setup loop O(candidates) and faithful to the component structure.
function _geo_agg_gate(expr, ie, ctx::_GeoCtx, setof)
    if expr.join !== nothing
        for clause in expr.join, pair in clause
            colA, colB = String(pair[1]), String(pair[2])
            lvA = _geo_loopvar_for(colA, setof, ctx.var_shapes)
            lvB = _geo_loopvar_for(colB, setof, ctx.var_shapes)
            (lvA === nothing || lvB === nothing) && continue
            (haskey(ctx.env, colA) && haskey(ctx.env, colB)) || continue
            ctx.env[colA][ie[lvA]] == ctx.env[colB][ie[lvB]] || return false
        end
    end
    if expr.filter !== nothing
        _geo_eval(expr.filter, ctx, ie, setof) != 0.0 || return false
    end
    return true
end

# Setup-time evaluator for the geometry chain. Walks an expression to a Float64
# (or, for `index` of a multi-dim array with FEWER indices, a slice array)
# against the invariant `ctx` (see `_GeoCtx`) and the varying `idx_env` (loop
# var → Int) / `outer_setof` (loop var → index-set name). Covers exactly the
# ops the polygon-area / overlap-join FAQ uses; anything else is an explicit
# setup-geometry error.
function _geo_eval(expr, ctx::_GeoCtx, idx_env,
                   outer_setof=Dict{String,String}())
    if expr isa NumExpr
        return expr.value
    elseif expr isa IntExpr
        return Float64(expr.value)
    elseif expr isa VarExpr
        haskey(idx_env, expr.name) && return Float64(idx_env[expr.name])
        haskey(ctx.env, expr.name) && return ctx.env[expr.name]
        throw(TreeWalkError("E_TREEWALK_GEOMETRY_SETUP",
            "unbound name '$(expr.name)' in setup-time geometry"))
    elseif expr isa OpExpr
        op = expr.op
        if op == "index"
            arr = _geo_eval(expr.args[1], ctx, idx_env, outer_setof)
            arr isa AbstractArray || throw(TreeWalkError("E_TREEWALK_GEOMETRY_SETUP",
                "index of a non-array in setup-time geometry"))
            idxs = Int[Int(round(_geo_eval(a, ctx, idx_env, outer_setof)))
                       for a in expr.args[2:end]]
            if length(idxs) == ndims(arr)
                return arr[idxs...]
            else
                colons = ntuple(_ -> Colon(), ndims(arr) - length(idxs))
                return Array(arr[idxs..., colons...])   # partial index → slice
            end
        elseif op == "intersect_polygon"
            a = _geo_eval(expr.args[1], ctx, idx_env, outer_setof)
            b = _geo_eval(expr.args[2], ctx, idx_env, outer_setof)
            expr.manifold === nothing && throw(TreeWalkError("E_TREEWALK_GEOMETRY_NO_MANIFOLD",
                "intersect_polygon requires a manifold"))
            return close_ring(intersect_polygon(a, b, expr.manifold))
        elseif op == "polygon_intersection_area"
            # FUSED scalar leaf (esm-spec §8.6.1): the overlap AREA of the two rings,
            # with no exposed clip ring — so it evaluates as an ordinary scalar even
            # inside a setup-time aggregate body (dense narrow phase, no ragged extent).
            a = _geo_eval(expr.args[1], ctx, idx_env, outer_setof)
            b = _geo_eval(expr.args[2], ctx, idx_env, outer_setof)
            expr.manifold === nothing && throw(TreeWalkError("E_TREEWALK_GEOMETRY_NO_MANIFOLD",
                "polygon_intersection_area requires a manifold"))
            return _polygon_intersection_area(a, b, expr.manifold)
        elseif op == "skolem"
            # A skolem key is a deterministic id for its arg tuple; at setup it is
            # only ever COMPARED (the bin equi-join), so a stable, session-local
            # hash capped to the Float64-exact window suffices (_SKOLEM_HASH_CAP).
            vals = Any[_geo_eval(a, ctx, idx_env, outer_setof)
                       for a in expr.args]
            return Float64(hash(Tuple(vals)) % _SKOLEM_HASH_CAP)
        elseif op == "true"
            return 1.0
        elseif op == "false"
            return 0.0
        elseif op == "aggregate" || (op == "arrayop" && isempty(expr.output_idx))
            # Scalar reduction over the declared ranges, honoring join/filter gates.
            # `setof` accumulates loop-var → index-set across nesting so a join can
            # resolve a key column indexed by an OUTER loop var (per-cell F_tgt).
            loopvars = collect(keys(expr.ranges))
            exts = Int[_geo_index_extent(expr.ranges[v], ctx.index_sets, ctx.derived_extents)
                       for v in loopvars]
            setof = copy(outer_setof)
            for lv in loopvars
                r = expr.ranges[lv]
                r isa IndexSetRef && (setof[lv] = r.from)
            end
            acc = 0.0
            for tup in Iterators.product((1:e for e in exts)...)
                ie = copy(idx_env)
                for (lv, iv) in zip(loopvars, tup); ie[lv] = iv; end
                _geo_agg_gate(expr, ie, ctx, setof) || continue
                acc += _geo_eval(expr.expr_body, ctx, ie, setof)
            end
            return acc
        else
            vals = Float64[_geo_eval(x, ctx, idx_env, outer_setof)
                           for x in expr.args]
            return _geo_apply_scalar(op, vals)
        end
    else
        throw(TreeWalkError("E_TREEWALK_GEOMETRY_SETUP",
            "unsupported expression $(typeof(expr)) in setup-time geometry"))
    end
end

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
    rings = Dict{Tuple,Matrix{Float64}}()
    maxn = 0
    for tup in Iterators.product((1:e for e in outer_ext)...)
        ie = Dict{String,Any}(zip(outer, tup))
        A = _geo_eval(ipoly.args[1], ctx, ie)
        B = _geo_eval(ipoly.args[2], ctx, ie)
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
function _geo_reduce_fold(reduce_spec, semiring_spec)
    r = reduce_spec !== nothing ? reduce_spec : semiring_spec
    r == "min" && return (Inf, min)
    r == "max" && return (-Inf, max)
    (r == "prod" || r == "*") && return (1.0, *)
    return (0.0, +)   # "+", "sum", "sum_product", or unspecified → additive fold
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
# honor the aggregate's `join` / `filter` gate (`_geo_agg_gate`): a rejected
# contraction tuple contributes the additive identity 0̄ (RFC §5.3 / §5.8). This is
# the setup-time twin of the ODE arrayop einsum path.
function _materialize_geom_array(arrayop, env, index_sets, derived_extents,
                                 var_shapes=Dict{String,Vector{String}}())
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
    arr  = zeros(Float64, exts...)
    if isempty(contract)
        for tup in Iterators.product((1:e for e in exts)...)
            ie = Dict{String,Any}(zip(out, tup))
            # A no-contraction map still honors an output-cell join/filter gate: a
            # rejected cell keeps the zero-initialized 0̄ (a cross-bin W_ij, a
            # sub-atol sliver). Degenerate (no join/filter) ⇒ gate is always true.
            _geo_agg_gate(arrayop, ie, ctx, setof) || continue
            arr[tup...] = _geo_eval(arrayop.expr_body, ctx, ie, setof)
        end
    else
        init, fold = _geo_reduce_fold(arrayop.reduce, arrayop.semiring)
        cexts = Int[_geo_index_extent(arrayop.ranges[c], index_sets, derived_extents)
                    for c in contract]
        for tup in Iterators.product((1:e for e in exts)...)
            acc = init
            for ct in Iterators.product((1:e for e in cexts)...)
                ie = Dict{String,Any}(zip(out, tup))
                for (lv, cv) in zip(contract, ct)
                    ie[lv] = cv
                end
                _geo_agg_gate(arrayop, ie, ctx, setof) || continue
                acc = fold(acc, _geo_eval(arrayop.expr_body, ctx, ie, setof))
            end
            arr[tup...] = acc
        end
    end
    return arr
end

# Geometry-derived ARRAY observeds to materialize at setup: those whose defining
# RHS contains an intersect_polygon (ranged clips), plus the closure of array
# observeds that depend on them WITHOUT touching a state variable. Single direct
# clips (in `geom_ring_vars`) keep the existing 2-D ring path. Returns the set and
# the name → RHS map.
# Every VarExpr name appearing anywhere in `expr` (args / arrayop-aggregate body /
# bounds / makearray values). Unlike `free_variables`, this does NOT treat an
# arrayop/aggregate as binding its references away — we need the array vars an
# expression READS (intersected with declared variable names by the caller, which
# drops bound loop indices). Used for the setup-geometry dependency closure.
function _referenced_var_names(expr, acc::Set{String}=Set{String}())
    if expr isa VarExpr
        push!(acc, expr.name)
    elseif expr isa OpExpr
        for a in expr.args
            _referenced_var_names(a, acc)
        end
        expr.expr_body !== nothing && _referenced_var_names(expr.expr_body, acc)
        expr.lower !== nothing && _referenced_var_names(expr.lower, acc)
        expr.upper !== nothing && _referenced_var_names(expr.upper, acc)
        if expr.values !== nothing
            for v in expr.values
                _referenced_var_names(v, acc)
            end
        end
    end
    return acc
end

function _geometry_setup_vars(model, equations, geom_ring_vars, state_var_names,
                              live_params)
    defs = Dict{String,Expr}()
    for eq in equations
        eq.lhs isa VarExpr || continue
        defs[(eq.lhs::VarExpr).name] = eq.rhs
    end
    is_arr_obs(n) = haskey(model.variables, n) &&
        model.variables[n].type == ObservedVariable &&
        _is_array_shape(model.variables[n].shape)
    # Live taint (ess-14f.4): a var whose defining expression (transitively)
    # reads a `param_arrays` buffer is a LIVE-FIELD observed — its value changes
    # each refresh, so it CANNOT be a build-once setup const. `F_tgt = A_ij ⊗
    # F_src / A_j` mixes setup-const weights (A_ij/A_j) with a live field (F_src):
    # the weights materialize at setup, but F_tgt itself must stay a runtime
    # observed (inlined into its readers below), never pulled into setup where
    # F_src is unbound. Seed from the live param names, propagate through `defs`.
    tainted = Set{String}()
    changed = true
    while changed
        changed = false
        for (n, rhs) in defs
            n in tainted && continue
            refs = _referenced_var_names(rhs)
            if any(r -> (r in live_params) || (r in tainted), refs)
                push!(tainted, n); changed = true
            end
        end
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
    changed = true
    while changed
        changed = false
        for (n, rhs) in defs
            (is_arr_obs(n) && !(n in setup) && !(n in geom_ring_vars) && !(n in tainted)) || continue
            refs = intersect(_referenced_var_names(rhs), mvars)
            if any(f -> (f in setup) || (f in geom_ring_vars), refs) &&
               !any(f -> f in state_var_names, refs)
                push!(setup, n); changed = true
            end
        end
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
    changed = true
    while changed
        changed = false
        for n in collect(setup)
            for r in intersect(_referenced_var_names(defs[n]), mvars)
                (is_arr_obs(r) && !(r in setup) && !(r in geom_ring_vars) &&
                 !(r in tainted) && haskey(defs, r) && !_is_const_op(defs[r]) &&
                 !(defs[r] isa VarExpr)) || continue
                rrefs = intersect(_referenced_var_names(defs[r]), mvars)
                any(f -> f in state_var_names, rrefs) && continue
                push!(setup, r); changed = true
            end
        end
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

# Evaluate the geometry-setup vars in dependency order into const arrays.
# `vi_maps` carries any materialized value-invention bin buffers a setup-time
# broad-phase `join` gates on (RFC §5.3); `param_overrides` carries scalar
# parameter values (e.g. a sliver-filter `atol`, the bin width `dx`/`dy`) so a
# setup-time `filter`/quantization that references them resolves.
function _materialize_geometry_setup(setup, defs, model, const_arrays_kw,
                                     index_sets, derived_extents;
                                     vi_maps=Dict{String,Any}(),
                                     param_overrides=Dict{String,Float64}(),
                                     const_obs_arrays=Dict{String,Array{Float64}}())
    out = Dict{String,AbstractArray{Float64}}()
    isempty(setup) && return out
    env = Dict{String,Any}()
    for (k, v) in const_arrays_kw
        env[String(k)] = v isa AbstractArray ? Array{Float64}(v) : v
    end
    # `const`-op array observeds (in-file polygon ring stacks / fields) are
    # build-time literal data: seed env with their materialized values so a fused
    # `polygon_intersection_area` aggregate can gather a per-cell ring via
    # `index(src_poly, i)` at setup. A const_arrays kwarg entry (if any) wins.
    for (n, v) in model.variables
        (v.type == ObservedVariable && _is_array_shape(v.shape) && _is_const_op(v.expression)) || continue
        haskey(env, n) && continue
        env[n] = _const_op_to_array((v.expression::OpExpr).value)
    end
    # Resolved BARE-ALIAS const arrays (`src_poly := mesh.src_poly`) and other
    # already-materialized const-op array observeds: a setup var (an MPAS
    # `polygon_intersection_area` over aliased mesh rings) reads the alias's value
    # from `env`, since the alias is registered as a const array, not materialized
    # as an aggregate. A `const`-op / kwarg entry already present wins.
    for (n, v) in const_obs_arrays
        haskey(env, n) && continue
        env[n] = v
    end
    for (n, v) in model.variables
        v.type == ParameterVariable && !_is_array_shape(v.shape) && v.default !== nothing &&
            (env[n] = Float64(v.default))
    end
    # Scalar parameter OVERRIDES win over declared defaults: a setup-time geometry
    # node may reference `atol`/`dx`/`dy` (the sliver floor / bin quantization),
    # which are build-time constants known here but often have no `default`.
    for (k, v) in param_overrides
        env[String(k)] = Float64(v)
    end
    # Materialized value-invention bin buffers (`src_bin`/`tgt_bin`): a setup-time
    # broad-phase `join` gate reads the per-cell bin key from these so the
    # denominator row-sum (`A_j_w = Σ_i A_ij`) contracts over exactly the same
    # candidate set as the numerator — without the gate it sums DENSELY and picks up
    # the spurious sub-grid slivers a spherical clip emits for edge-adjacent cells,
    # breaking the partition of unity (RFC §5.3 / §5.8).
    for (name, buf) in vi_maps
        env[String(name)] = _vi_buf_vector(buf)
    end
    # Declared shapes (index-set names per dim) — used to resolve join key columns.
    var_shapes = Dict{String,Vector{String}}()
    for (n, v) in model.variables
        v.shape === nothing && continue
        var_shapes[n] = String[String(s) for s in v.shape if s isa AbstractString]
    end
    for n in _geom_setup_order(setup, defs)
        rhs = defs[n]
        arr = _is_ranged_clip(rhs) ?
              _materialize_ranged_clip(rhs, env, index_sets, derived_extents, var_shapes) :
              _materialize_geom_array(rhs, env, index_sets, derived_extents, var_shapes)
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

# A reduce-aggregate whose body reads only const-array factors already in `env`
# (never a state / live field), contracting at least one non-output index — i.e. a
# build-time coordinate projection eligible for the derivation above.
_REDUCE_PROJECTION_KINDS = ("min", "max", "sum", "prod")

function _is_reduce_projection_agg(e, env, state_names)
    (e isa OpExpr && _is_aggregate_op(e.op)) || return false
    (e.reduce !== nothing && e.reduce in _REDUCE_PROJECTION_KINDS) || return false
    (e.output_idx !== nothing && !isempty(e.output_idx)) || return false
    (e.ranges !== nothing && !isempty(e.ranges)) || return false
    e.expr_body === nothing && return false
    any(k -> !(k in e.output_idx), keys(e.ranges)) || return false   # genuine reduction
    # Bound loop indices (the aggregate's own `ranges` / `output_idx` symbols) are
    # not data references — only the FACTOR names the body gathers from must be
    # build-time const arrays already in `env`.
    bound = Set{String}(String(k) for k in keys(e.ranges))
    for k in e.output_idx
        push!(bound, String(k))
    end
    for r in _referenced_var_names(e)
        r in bound && continue
        r in state_names && return false        # must be build-time, not live state
        haskey(env, r) || return false          # every referenced factor is a const array
    end
    return true
end

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
    for (n, v) in model.variables
        (v.type == ObservedVariable && _is_array_shape(v.shape)) || continue
        haskey(env, n) && continue
        e = v.expression
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
                                vi_index_targets=Set{String}())
    out = Dict{String,Vector{Float64}}()
    env = Dict{String,Any}()
    # In-file `const`-op array observeds (the `src_poly` / `tgt_poly` ring stacks) are
    # build-time literal data the projection gathers per cell via `index(src_poly,i)`.
    for (n, v) in model.variables
        (v.type == ObservedVariable && _is_array_shape(v.shape) && _is_const_op(v.expression)) || continue
        env[n] = _const_op_to_array((v.expression::OpExpr).value)
    end
    for (k, v) in const_arrays_kw
        env[String(k)] = v isa AbstractArray ? Array{Float64}(v) : v
    end
    for (n, v) in model.variables
        v.type == ParameterVariable && !_is_array_shape(v.shape) && v.default !== nothing &&
            (env[n] = Float64(v.default))
    end
    for (k, v) in param_overrides
        env[String(k)] = Float64(v)
    end
    state_names = Set{String}(n for (n, v) in model.variables if v.type == StateVariable)
    var_shapes = Dict{String,Vector{String}}()
    for (n, v) in model.variables
        v.shape === nothing && continue
        var_shapes[n] = String[String(s) for s in v.shape if s isa AbstractString]
    end

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
    changed = true
    while changed
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
            env[n] = _materialize_geom_array(e, env, index_sets, derived_extents, var_shapes)
            push!(accepted, n); changed = true
        end
    end

    # Return the 1-D coordinate seeds that materialised to a build-time constant.
    for n in seeds
        haskey(env, n) || continue
        (env[n] isa AbstractArray && ndims(env[n]) == 1) || continue
        out[n] = vec(Array{Float64}(env[n]))
    end
    return out
end
