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

# An intersect_polygon may live in an equation RHS or in an observed variable's
# `expression` field (the shared geometry fixtures use the latter — the Python
# evaluator reads `variable.expression` directly).
function _model_has_intersect_polygon(model::Model)
    for (_, v) in model.variables
        v.expression isa ASTExpr && _expr_has_intersect_polygon(v.expression) && return true
    end
    return _equations_have_intersect_polygon(model.equations)
end

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

# An intersection-area leaf may live in an equation LHS/RHS or in an observed
# variable's `expression` field (the shared fixtures use the latter).
function _model_has_polygon_intersection_area(model::Model, equations)
    for (_, v) in model.variables
        v.expression isa ASTExpr && _expr_has_polygon_intersection_area(v.expression) && return true
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

# (The per-tuple aggregate gate — `_geo_agg_gate` and its pre-resolved twin
# `_geo_agg_gate_resolved` — is gone with the interpreter: a node's `join`
# resolves ONCE per sweep through `_resolve_geo_join_gates` below and then
# compiles to slot-addressed `_GeoSlotGate`s; the `filter` predicate compiles
# to a `_Node` evaluated per cell. Same key-equality broad phase (RFC §5.3 /
# §5.8), same gate-then-filter order — see `_geo_gate_ok` and `_geo_eval_agg`
# in tree_walk/geometry_compile.jl.)

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
    for clause in expr.join, pair in clause
        colA, colB = String(pair[1]), String(pair[2])
        lvA = _geo_loopvar_for(colA, setof, ctx.var_shapes)
        lvB = _geo_loopvar_for(colB, setof, ctx.var_shapes)
        (lvA === nothing || lvB === nothing) && continue
        (haskey(ctx.env, colA) && haskey(ctx.env, colB)) || continue
        push!(gates, _GeoJoinGate(ctx.env[colA], lvA, ctx.env[colB], lvB))
    end
    return gates
end

# (The setup-time geometry INTERPRETER — `_geo_eval`, a raw-AST walker re-run
# once per output cell × contraction tuple, the #1 build hotspot of a
# conservative regrid — is retired. The geometry chain now COMPILES ONCE per
# materialization sweep into the shared `_Node` IR and evaluates per cell
# through `_eval_node`: see tree_walk/geometry_compile.jl for the compiler
# (`_geo_compile` / `_geo_source`), the compiled gate (`_geo_gate_ok`), and
# the `:geo_gather`/`:geo_pia`/`:geo_skolem`/`:geo_agg` evaluator arms.)

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
    if isempty(contract)
        for tup in Iterators.product((1:e for e in exts)...)
            @inbounds for k in 1:nout; u[k] = Float64(tup[k]); end
            # A no-contraction map still honors an output-cell join/filter gate: a
            # rejected cell keeps the zero-initialized 0̄ (a cross-bin W_ij, a
            # sub-atol sliver). Degenerate (no join/filter) ⇒ gate is always true.
            _geo_gate_ok(gates, filt, u) || continue
            arr[tup...] = _eval_node(body, u, nothing, 0.0, Float64)
        end
    else
        init, fold = _geo_reduce_fold(arrayop.reduce, arrayop.semiring)
        cexts = Int[_geo_index_extent(arrayop.ranges[c], index_sets, derived_extents)
                    for c in contract]
        ncon = length(contract)
        for tup in Iterators.product((1:e for e in exts)...)
            @inbounds for k in 1:nout; u[k] = Float64(tup[k]); end
            acc = init
            for ct in Iterators.product((1:e for e in cexts)...)
                @inbounds for k in 1:ncon; u[nout + k] = Float64(ct[k]); end
                _geo_gate_ok(gates, filt, u) || continue
                acc = fold(acc, _eval_node(body, u, nothing, 0.0, Float64))
            end
            arr[tup...] = acc
        end
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
# carries no join/filter gate, and whose body reaches an op OUTSIDE the `_geo_eval`
# vocabulary (`and`/`fn`/`const`/`exp`/`log`/…). This is exactly a promoted per-cell
# physics lookup (FuelModelLookup/EMC/Rothermel/MidflameWind over the fire grid).
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
    arr = zeros(Float64, exts...)
    for I in CartesianIndices(Tuple(exts))
        arr[I] = _eval_cellwise(rhs, Int[Tuple(I)...]; const_arrays=ca,
                                registered_functions=registered_functions,
                                params=params)
    end
    return arr
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
        regions = rhs.regions === nothing ? Vector{Vector{Vector{Int}}}() : rhs.regions
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
        haskey(model.variables, f) &&
        model.variables[f].type == ObservedVariable &&
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
    for (n, v) in model.variables
        (v.type == ObservedVariable && _is_array_shape(v.shape) && _is_const_op(v.expression)) || continue
        haskey(env, n) && continue
        env[n] = _const_op_to_array((v.expression::OpExpr).value)
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
            _materialize_geom_array(rhs, env, index_sets, derived_extents, var_shapes)
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
# pass, which is what actually gates evaluation. (A stricter up-front
# `_is_reduce_projection_agg` predicate once duplicated those checks here; it
# was dead — the seed test is the behavior — and has been removed.)
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
    # The shared setup env (see `_build_setup_env` for the precedence proof that
    # this equals the assembly formerly inlined here): in-file `const`-op ring
    # stacks the projection gathers per cell via `index(src_poly, i)`, the
    # kwarg const arrays, and the scalar params/overrides.
    env = _build_setup_env(model, const_arrays_kw; param_overrides=param_overrides)
    state_names = Set{String}(n for (n, v) in model.variables if v.type == StateVariable)
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
            env[n] = _materialize_geom_array(e, env, index_sets, derived_extents, var_shapes)
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
