# ========================================================================
# tree_walk/geometry_compile.jl — part of the tree-walk evaluator.
# Included by src/tree_walk.jl AFTER compile.jl (the spec structs below carry
# `_Node` fields, so they need the IR type at include time). Section 2c:
# the COMPILED setup-time geometry path.
#
# WHY. The setup-time geometry evaluator used to be a sixth, fully separate
# interpreter (`_geo_eval`, formerly in geometry_setup.jl): a raw-AST walker
# with string-compared ops, per-node Dict name lookups, and its own
# hand-mirrored scalar ladder (`_geo_apply_scalar/1/2/3`) — re-run once per
# output cell × contraction tuple, which made it the #1 build hotspot of a
# conservative regrid. It is now a COMPILER: `_geo_compile` lowers a geometry
# body ONCE per materialization sweep into the SAME `_Node` IR the runtime
# walkers evaluate, and the per-cell work is a single `_eval_node` walk over a
# small `Vector{Float64}` loop-index frame. The scalar vocabulary therefore
# evaluates through `_eval_node_op`'s (registry-generated) arms — the
# geometry op ladder is DELETED, not mirrored.
#
# HOW THE PIECES MAP (interpreter arm → compiled form):
#   * loop indices          → `_NK_STATE` slots in the per-sweep frame `u`
#                             (nested aggregates allocate FRESH slots, so
#                             lexical shadowing is by construction);
#   * env scalars           → `_NK_LITERAL` (the env is fixed for the sweep);
#   * `true`/`false`        → `_NK_LITERAL` 1.0/0.0;
#   * scalar `index` reads  → `:geo_gather` nodes (payload = the SOURCE:
#                             an env array or a ring reference; children =
#                             the index expressions, rounded per cell);
#   * ring-valued operands  → `_GeoRingRef` (partial index → `view`, no copy)
#                             / `_GeoClipRef` (a per-cell clip) payloads;
#   * polygon_intersection_area / skolem / nested scalar aggregates
#                           → `:geo_pia` / `:geo_skolem` / `:geo_agg` nodes,
#                             evaluated by `_eval_geo_op` — the cold tail arm
#                             of `_eval_node_op`;
#   * scalar ops            → plain `_NK_OP` nodes (the registry-generated
#                             `_eval_node_op` arms), gated at COMPILE time by
#                             `_GEO_SCALAR_OPS` so an op outside the geometry
#                             vocabulary still fails with the historical
#                             E_TREEWALK_GEOMETRY_SETUP code.
#
# Evaluation ORDER is replicated exactly — the same `Iterators.product`
# nesting, the same join-gate-then-filter gating, the same sequential `+=` /
# fold accumulation — so materialized arrays are bit-identical to the
# interpreted originals. Two knowing deviations, both strictly-lazier/safer:
# `ifelse` is lazy here (the interpreter's 3-ary apply evaluated all three
# arms before selecting — values identical, but a guarded domain error now
# cannot fire), and a ≥4-ary `-` folds left (`((a-b)-c)-d`) instead of the
# interpreter's `a - sum(rest)` (identical for the ≤3-ary forms actually
# emitted; differs only in FP rounding beyond that).
# ========================================================================

# The scalar-op vocabulary of the setup-time geometry language: exactly the
# arms the retired `_geo_apply_scalar/1/2/3` ladder carried — `_GEO_EVAL_OPS`
# (op_registry.jl, flag `:geo_eval`) minus the structurally-compiled ops.
# Compile-time membership gating preserves the interpreter's failure mode: an
# op outside this set throws E_TREEWALK_GEOMETRY_SETUP (not the runtime
# ladder's E_TREEWALK_UNSUPPORTED_OP).
const _GEO_STRUCTURAL_OPS = Set{String}([
    "index", "intersect_polygon", "polygon_intersection_area", "skolem",
    "true", "false", "aggregate", "arrayop",
])
const _GEO_SCALAR_OPS = setdiff(_GEO_EVAL_OPS, _GEO_STRUCTURAL_OPS)

# ---- Compiled payload specs -------------------------------------------------

# A build-time ring reference: a source array partially indexed by per-cell
# leading subscripts; the tail dims stay whole. Resolved per cell to a `view`
# (no data copy — the const source outlives every walk and is never mutated;
# read-only consumers only), exactly the interpreter's partial-index behavior.
# `src` is an `AbstractArray`, another `_GeoRingRef`, or a `_GeoClipRef`.
struct _GeoRingRef
    src::Any
    idx::Vector{_Node}
end

# A per-cell clip: `close_ring(intersect_polygon(a, b, manifold))` of two ring
# sources — the compiled form of the interpreter's general (non-ranged)
# `intersect_polygon` arm.
struct _GeoClipRef
    a::Any
    b::Any
    manifold::String
end

# `polygon_intersection_area` payload (`:geo_pia`): two ring sources + the
# declared manifold (validated non-nothing at compile).
struct _GeoPiaSpec
    a::Any
    b::Any
    manifold::String
end

# One slot-addressed join-key equality — `_resolve_geo_join_gates`'
# name-addressed `_GeoJoinGate` with the loop-var names resolved to frame
# slots at compile time.
struct _GeoSlotGate
    arrA::Any
    slotA::Int
    arrB::Any
    slotB::Int
end

# A nested scalar aggregate (`:geo_agg`): its loop slots (in `ranges`-key
# order) and extents, the pre-resolved join gate, the compiled filter, and the
# compiled body. ALWAYS the additive fold: the interpreter's nested-aggregate
# arm summed unconditionally — `reduce`/`semiring` are honored only at the TOP
# level (`_materialize_geom_array`'s contraction), as before.
struct _GeoAggSpec
    slots::Vector{Int}
    exts::Vector{Int}
    gates::Union{Nothing,Vector{_GeoSlotGate}}
    filter::Union{Nothing,_Node}
    body::_Node
end

# ---- Compile context --------------------------------------------------------

# Per-sweep compile context: the invariant `_GeoCtx` (env / index sets /
# derived extents / declared shapes), the LEXICAL loop-var → frame-slot scope,
# the lexical loop-var → index-set map (join-column resolution), and the
# shared frame-size counter (nested aggregates allocate fresh slots from it,
# so the sweep sizes ONE frame for the whole tree).
struct _GeoCompileCtx
    ctx::_GeoCtx
    scope::Dict{String,Int}
    setof::Dict{String,String}
    nslots::Base.RefValue{Int}
end

_geo_newslot!(g::_GeoCompileCtx) = (g.nslots[] += 1)

# ---- The compiler -----------------------------------------------------------

# Lower a setup-time geometry expression to a `_Node` against the lexical
# `g.scope`/`g.setof`. Covers exactly the language the interpreter spoke;
# anything else throws the same E_TREEWALK_GEOMETRY_SETUP diagnostics it
# threw — just at compile (before the sweep) instead of at the first cell.
function _geo_compile(expr, g::_GeoCompileCtx)::_Node
    if expr isa NumExpr
        return _mknode(kind=_NK_LITERAL, literal=expr.value)
    elseif expr isa IntExpr
        return _mknode(kind=_NK_LITERAL, literal=Float64(expr.value))
    elseif expr isa VarExpr
        s = get(g.scope, expr.name, 0)
        s != 0 && return _mknode(kind=_NK_STATE, idx=s)   # loop index (Float64 in u)
        v = get(g.ctx.env, expr.name, nothing)
        v isa Real && return _mknode(kind=_NK_LITERAL, literal=Float64(v))
        v === nothing && throw(TreeWalkError("E_TREEWALK_GEOMETRY_SETUP",
            "unbound name '$(expr.name)' in setup-time geometry"))
        # Array-valued names are legal only in SOURCE position (an `index`
        # base, a polygon operand) — those are compiled by `_geo_source`.
        throw(TreeWalkError("E_TREEWALK_GEOMETRY_SETUP",
            "array-valued name '$(expr.name)' used in scalar position in setup-time geometry"))
    elseif expr isa OpExpr
        op = expr.op
        if op == "index"
            src = _geo_source(expr.args[1], g)
            nidx = length(expr.args) - 1
            r = _geo_source_rank(src)
            nidx == r || throw(TreeWalkError("E_TREEWALK_GEOMETRY_SETUP",
                "index of a non-array or partial index ($(nidx) of $(r) dims) " *
                "in scalar position in setup-time geometry"))
            children = _Node[_geo_compile(expr.args[k], g) for k in 2:length(expr.args)]
            return _mknode(kind=_NK_OP, op=:geo_gather, children=children, payload=src)
        elseif op == "polygon_intersection_area"
            expr.manifold === nothing && throw(TreeWalkError("E_TREEWALK_GEOMETRY_NO_MANIFOLD",
                "polygon_intersection_area requires a manifold"))
            return _mknode(kind=_NK_OP, op=:geo_pia,
                           payload=_GeoPiaSpec(_geo_source(expr.args[1], g),
                                               _geo_source(expr.args[2], g),
                                               expr.manifold))
        elseif op == "skolem"
            # Deterministic per-arg-tuple id, only ever COMPARED within one
            # build (see `_SKOLEM_HASH_CAP`); args are scalar quantizations.
            children = _Node[_geo_compile(a, g) for a in expr.args]
            return _mknode(kind=_NK_OP, op=:geo_skolem, children=children)
        elseif op == "true"
            return _mknode(kind=_NK_LITERAL, literal=1.0)
        elseif op == "false"
            return _mknode(kind=_NK_LITERAL, literal=0.0)
        elseif op == "aggregate" || (op == "arrayop" && isempty(expr.output_idx))
            return _geo_compile_agg(expr, g)
        elseif op == "-" && length(expr.args) >= 3
            # The interpreter's variadic `-`: left fold `((a-b)-c)…`, matching
            # its 3-ary arm exactly. The runtime ladder's `-` is 1-or-2-ary
            # (esm-spec), so the fold happens here at compile.
            node = _geo_compile(expr.args[1], g)
            for k in 2:length(expr.args)
                node = _mknode(kind=_NK_OP, op=:-,
                               children=_Node[node, _geo_compile(expr.args[k], g)])
            end
            return node
        elseif op in _GEO_SCALAR_OPS
            children = _Node[_geo_compile(a, g) for a in expr.args]
            return _mknode(kind=_NK_OP, op=Symbol(op), children=children)
        end
        throw(TreeWalkError("E_TREEWALK_GEOMETRY_SETUP",
            "unsupported op '$(op)' in setup-time geometry"))
    end
    throw(TreeWalkError("E_TREEWALK_GEOMETRY_SETUP",
        "unsupported expression $(typeof(expr)) in setup-time geometry"))
end

# A ring/array SOURCE: an env array by name, a partial `index` slice of a
# source, or a nested `intersect_polygon` clip of two sources. Rank is static
# at compile (`_geo_source_rank`), which is what lets scalar `index` compile
# to a full-rank gather and partial `index` stay a view-producing reference.
function _geo_source(expr, g::_GeoCompileCtx)
    if expr isa VarExpr
        v = get(g.ctx.env, expr.name, nothing)
        v isa AbstractArray && return v
        throw(TreeWalkError("E_TREEWALK_GEOMETRY_SETUP",
            v === nothing ? "unbound name '$(expr.name)' in setup-time geometry" :
                "index of a non-array in setup-time geometry"))
    elseif expr isa OpExpr && expr.op == "index"
        base = _geo_source(expr.args[1], g)
        nidx = length(expr.args) - 1
        nidx < _geo_source_rank(base) || throw(TreeWalkError("E_TREEWALK_GEOMETRY_SETUP",
            "polygon operand must be an array (a full index yields a scalar) in setup-time geometry"))
        return _GeoRingRef(base,
            _Node[_geo_compile(expr.args[k], g) for k in 2:length(expr.args)])
    elseif expr isa OpExpr && expr.op == "intersect_polygon"
        expr.manifold === nothing && throw(TreeWalkError("E_TREEWALK_GEOMETRY_NO_MANIFOLD",
            "intersect_polygon requires a manifold"))
        return _GeoClipRef(_geo_source(expr.args[1], g),
                           _geo_source(expr.args[2], g), expr.manifold)
    end
    throw(TreeWalkError("E_TREEWALK_GEOMETRY_SETUP",
        "operand must be a build-time array (a const/setup array name, an index " *
        "slice of one, or an intersect_polygon clip) in setup-time geometry"))
end

_geo_source_rank(a::AbstractArray) = ndims(a)
_geo_source_rank(r::_GeoRingRef) = _geo_source_rank(r.src) - length(r.idx)
_geo_source_rank(::_GeoClipRef) = 2

# Nested scalar aggregate → `:geo_agg`. Loop vars come from `ranges` in key
# order (the interpreter's `collect(keys(...))` order — it fixes the product
# nesting and therefore the accumulation order, so keep it); each gets a fresh
# frame slot in an EXTENDED lexical scope, under which the gate/filter/body
# compile.
function _geo_compile_agg(expr::OpExpr, g::_GeoCompileCtx)::_Node
    loopvars = collect(keys(expr.ranges))
    exts = Int[_geo_index_extent(expr.ranges[v], g.ctx.index_sets, g.ctx.derived_extents)
               for v in loopvars]
    scope = copy(g.scope)
    setof = copy(g.setof)
    slots = Vector{Int}(undef, length(loopvars))
    for (k, lv) in enumerate(loopvars)
        slots[k] = _geo_newslot!(g)
        scope[lv] = slots[k]
        r = expr.ranges[lv]
        r isa IndexSetRef && (setof[lv] = r.from)
    end
    inner = _GeoCompileCtx(g.ctx, scope, setof, g.nslots)
    gates = _geo_slot_gates(expr, inner)
    filt = expr.filter === nothing ? nothing : _geo_compile(expr.filter, inner)
    body = _geo_compile(expr.expr_body, inner)
    return _mknode(kind=_NK_OP, op=:geo_agg,
                   payload=_GeoAggSpec(slots, exts, gates, filt, body))
end

# Resolve a node's `join` to slot-addressed gates: `_resolve_geo_join_gates`
# does the name-level work (faithfully replaying the interpreter's skip
# semantics — an unresolvable pair never gates), then the loop-var names map
# through the lexical scope. `nothing` ⇒ the node has no join arm.
function _geo_slot_gates(expr, g::_GeoCompileCtx)
    rg = _resolve_geo_join_gates(expr, g.ctx, g.setof)
    rg === nothing && return nothing
    gates = _GeoSlotGate[]
    for jg in rg
        sA = get(g.scope, jg.lvA, 0)
        sB = get(g.scope, jg.lvB, 0)
        # `_geo_loopvar_for` only returns vars present in `setof`, which is
        # built from in-scope loop vars — so this cannot fire; fail closed
        # anyway rather than emit a gate that reads slot 0.
        (sA == 0 || sB == 0) && throw(TreeWalkError("E_TREEWALK_GEOMETRY_SETUP",
            "join-gate loop var out of scope in setup-time geometry"))
        push!(gates, _GeoSlotGate(jg.arrA, sA, jg.arrB, sB))
    end
    return gates
end

# ---- The evaluator arms (`_eval_node_op`'s cold tail) -----------------------

# Round an index expression to an integer subscript (the interpreter's
# `Int(round(_geo_eval(...)))`, verbatim).
@inline _geo_ix_value(nd::_Node, u, p, t, ::Type{T}) where {T} =
    Int(round(_eval_node(nd, u, p, t, T)::Float64))

# Resolve a compiled ring/array source at the current frame. A partial index
# resolves to a `view` for the ranks the geometry FAQ uses (matching the
# interpreter's fast paths); the general fallback materializes a dense slice,
# as before. A clip source runs the Sutherland–Hodgman kernel per cell.
_geo_ring_value(a::AbstractArray, u, p, t, ::Type{T}) where {T} = a
function _geo_ring_value(r::_GeoClipRef, u, p, t, ::Type{T}) where {T}
    return close_ring(intersect_polygon(_geo_ring_value(r.a, u, p, t, T),
                                        _geo_ring_value(r.b, u, p, t, T),
                                        r.manifold))
end
function _geo_ring_value(r::_GeoRingRef, u, p, t, ::Type{T}) where {T}
    base = _geo_ring_value(r.src, u, p, t, T)
    nd = ndims(base)
    ix = r.idx
    k = length(ix)
    if k == 1
        i1 = _geo_ix_value(ix[1], u, p, t, T)
        nd == 2 && return view(base, i1, :)
        nd == 3 && return view(base, i1, :, :)
    elseif k == 2 && nd == 3
        i1 = _geo_ix_value(ix[1], u, p, t, T)
        i2 = _geo_ix_value(ix[2], u, p, t, T)
        return view(base, i1, i2, :)
    end
    idxs = Int[_geo_ix_value(ix[j], u, p, t, T) for j in eachindex(ix)]
    colons = ntuple(_ -> Colon(), nd - k)
    return Array(base[idxs..., colons...])   # general fallback (unusual ranks)
end

# Full-rank scalar gather (`:geo_gather`): resolve the source, round each
# subscript, read. Ranks 1–3 are unrolled (no splat) exactly as the
# interpreter's fast paths were; bounds stay CHECKED, as before.
function _geo_gather_value(n::_Node, u, p, t, ::Type{T})::Float64 where {T}
    arr = _geo_ring_value(n.payload, u, p, t, T)
    c = n.children
    k = length(c)
    if k == 1
        return Float64(arr[_geo_ix_value(c[1], u, p, t, T)])
    elseif k == 2
        return Float64(arr[_geo_ix_value(c[1], u, p, t, T),
                           _geo_ix_value(c[2], u, p, t, T)])
    elseif k == 3
        return Float64(arr[_geo_ix_value(c[1], u, p, t, T),
                           _geo_ix_value(c[2], u, p, t, T),
                           _geo_ix_value(c[3], u, p, t, T)])
    end
    idxs = Int[_geo_ix_value(c[i], u, p, t, T) for i in eachindex(c)]
    return Float64(arr[idxs...])
end

# Nested scalar aggregate (`:geo_agg`): the interpreter's product loop,
# verbatim — write the loop slots, join-gate then filter, sum the body.
function _geo_eval_agg(spec::_GeoAggSpec, u, p, t, ::Type{T})::Float64 where {T}
    acc = 0.0
    slots = spec.slots
    gates = spec.gates
    filt = spec.filter
    body = spec.body
    for tup in Iterators.product((1:e for e in spec.exts)...)
        @inbounds for k in eachindex(slots)
            u[slots[k]] = Float64(tup[k])
        end
        if gates !== nothing
            ok = true
            for gt in gates
                if gt.arrA[Int(u[gt.slotA])] != gt.arrB[Int(u[gt.slotB])]
                    ok = false
                    break
                end
            end
            ok || continue
        end
        if filt !== nothing
            _eval_node(filt, u, p, t, T) != 0.0 || continue
        end
        acc += _eval_node(body, u, p, t, T)
    end
    return acc
end

# The join-then-filter gate for the TOP-level materialization sweeps (the
# compiled twin of the retired `_geo_agg_gate_resolved`): slot-addressed
# array equalities, then the compiled filter predicate against the frame.
@inline function _geo_gate_ok(gates, filt, u)
    if gates !== nothing
        @inbounds for gt in gates
            gt.arrA[Int(u[gt.slotA])] == gt.arrB[Int(u[gt.slotB])] || return false
        end
    end
    if filt !== nothing
        _eval_node(filt, u, nothing, 0.0, Float64) != 0.0 || return false
    end
    return true
end

# The `:geo_*` dispatch — the cold tail arm of `_eval_node_op` (compile.jl).
# Only setup-time compiled trees carry these ops, so the RHS hot path never
# reaches here; `::Float64` keeps the ladder's inferred union small.
function _eval_geo_op(n::_Node, u, p, t, ::Type{T})::Float64 where {T}
    op = n.op
    if op === :geo_gather
        return _geo_gather_value(n, u, p, t, T)
    elseif op === :geo_pia
        spec = n.payload::_GeoPiaSpec
        return _polygon_intersection_area(_geo_ring_value(spec.a, u, p, t, T),
                                          _geo_ring_value(spec.b, u, p, t, T),
                                          spec.manifold)
    elseif op === :geo_skolem
        c = n.children
        vals = Any[_eval_node(c[k], u, p, t, T) for k in eachindex(c)]
        return Float64(hash(Tuple(vals)) % _SKOLEM_HASH_CAP)
    elseif op === :geo_agg
        return _geo_eval_agg(n.payload::_GeoAggSpec, u, p, t, T)
    end
    throw(TreeWalkError("E_TREEWALK_UNSUPPORTED_OP", String(op)))
end
