# ========================================================================
# tree_walk/geometry_compile.jl — part of the tree-walk evaluator.
# Included by src/tree_walk.jl AFTER compile.jl (the spec structs below carry
# `_Node` fields, so they need the IR type at include time). Section 2c:
# the COMPILED setup-time geometry path.
#
# WHY A COMPILER. Geometry setup once had its own raw-AST interpreter — string
# -compared ops, per-node Dict lookups, a hand-mirrored scalar ladder — re-run
# once per output cell × contraction tuple, which made it the dominant build cost
# of a conservative regrid. `_geo_compile` instead lowers a geometry body ONCE per
# materialization sweep into the SAME `_Node` IR the runtime walkers evaluate, and
# the per-cell work is a single `_eval_node` walk over a small `Vector{Float64}`
# loop-index frame. The scalar vocabulary therefore evaluates through
# `_eval_node_op`'s registry-generated arms; there is no mirrored geometry ladder.
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
# ladder's unevaluable_operator).
const _GEO_STRUCTURAL_OPS = Set{String}(
    [
        "index", "intersect_polygon", "polygon_intersection_area", "skolem",
        "true", "false", "faq",
    ]
)
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
# order) and extents, the pre-resolved join gate, the compiled filter, the
# compiled body, and its fold: `op` (`:+`, `:*`, `:max`, `:min`, from the
# node's `reduce`/`semiring`) seeded with its identity `zero`, left to right
# over the admitted tuples. Seeding with the identity gives the bits of the
# right-hand side's unrolled `op(op(t1, t2), t3)` (`_combine_with_reducer`):
# `max(-Inf, t) = t`, `1.0 * t = t`. A tuple the gate or the filter rejects is
# skipped, which for `:*`/`:max`/`:min` is the same as folding the identity.
struct _GeoAggSpec
    slots::Vector{Int}
    exts::Vector{Int}
    gates::Union{Nothing, Vector{_GeoSlotGate}}
    filter::Union{Nothing, _Node}
    body::_Node
    op::Symbol
    zero::Float64
end

# ---- Compile context --------------------------------------------------------

# Per-sweep compile context: the invariant `_GeoCtx` (env / index sets /
# derived extents / declared shapes), the LEXICAL loop-var → frame-slot scope,
# the lexical loop-var → index-set map (join-column resolution), and the
# shared frame-size counter (nested aggregates allocate fresh slots from it,
# so the sweep sizes ONE frame for the whole tree).
struct _GeoCompileCtx
    ctx::_GeoCtx
    scope::Dict{String, Int}
    setof::Dict{String, String}
    nslots::Base.RefValue{Int}
    # Compiled node per (expression, lexical scope): an interned sub-tree
    # reached twice under one scope compiles to one node (`_geo_memoize!`).
    memo::IdDict{Any, _Node}
end
_GeoCompileCtx(ctx, scope, setof, nslots) =
    _GeoCompileCtx(ctx, scope, setof, nslots, IdDict{Any, _Node}())

_geo_newslot!(g::_GeoCompileCtx) = (g.nslots[] += 1)

# ---- The compiler -----------------------------------------------------------

# Lower a setup-time geometry expression to a `_Node` against the lexical
# `g.scope`/`g.setof`. Covers exactly the language the interpreter spoke;
# anything else throws the same E_TREEWALK_GEOMETRY_SETUP diagnostics it
# threw — just at compile (before the sweep) instead of at the first cell.
function _geo_compile(expr, g::_GeoCompileCtx)::_Node
    expr isa OpExpr || return _geo_compile_uncached(expr, g)
    key = (expr, g.scope)
    got = get(g.memo, key, nothing)
    got === nothing || return got
    return g.memo[key] = _geo_compile_uncached(expr, g)
end

function _geo_compile_uncached(expr, g::_GeoCompileCtx)::_Node
    if expr isa NumExpr
        return _mknode(kind = _NK_LITERAL, literal = expr.value)
    elseif expr isa IntExpr
        return _mknode(kind = _NK_LITERAL, literal = Float64(expr.value))
    elseif expr isa VarExpr
        s = get(g.scope, expr.name, 0)
        s != 0 && return _mknode(kind = _NK_STATE, idx = s)   # loop index (Float64 in u)
        v = get(g.ctx.env, expr.name, nothing)
        # A scalar `env` entry folded to a literal is the setup-time geometry's
        # read of a model parameter (`atol`, `dx`, a projection constant) — the
        # value is baked into the materialized array, so the name is STRUCTURAL.
        # See `_PARAM_READS` (build.jl); the sink is `nothing` outside a
        # build-time evaluation scope.
        if v isa Real
            _PARAM_READS[] === nothing || _record_param_read(expr.name)
            return _mknode(kind = _NK_LITERAL, literal = Float64(v))
        end
        v === nothing && throw(
            TreeWalkError(
                "E_TREEWALK_GEOMETRY_SETUP",
                "unbound name '$(expr.name)' in setup-time geometry"
            )
        )
        # Array-valued names are legal only in SOURCE position (an `index`
        # base, a polygon operand) — those are compiled by `_geo_source`.
        throw(
            TreeWalkError(
                "E_TREEWALK_GEOMETRY_SETUP",
                "array-valued name '$(expr.name)' used in scalar position in setup-time geometry"
            )
        )
    elseif expr isa OpExpr
        op = expr.op
        if op == "index"
            src = _geo_source(expr.args[1], g)
            nidx = length(expr.args) - 1
            r = _geo_source_rank(src)
            nidx == r || throw(
                TreeWalkError(
                    "E_TREEWALK_GEOMETRY_SETUP",
                    "index of a non-array or partial index ($(nidx) of $(r) dims) " *
                        "in scalar position in setup-time geometry"
                )
            )
            children = _Node[_geo_compile(expr.args[k], g) for k in 2:length(expr.args)]
            return _mknode(kind = _NK_OP, op = :geo_gather, children = children, payload = src)
        elseif op == "polygon_intersection_area"
            expr.manifold === nothing && throw(
                TreeWalkError(
                    "E_TREEWALK_GEOMETRY_NO_MANIFOLD",
                    "polygon_intersection_area requires a manifold"
                )
            )
            return _mknode(
                kind = _NK_OP, op = :geo_pia,
                payload = _GeoPiaSpec(
                    _geo_source(expr.args[1], g),
                    _geo_source(expr.args[2], g),
                    expr.manifold
                )
            )
        elseif op == "skolem"
            # Deterministic per-arg-tuple id, only ever COMPARED within one
            # build (see `_SKOLEM_HASH_CAP`); args are scalar quantizations.
            children = _Node[_geo_compile(a, g) for a in expr.args]
            return _mknode(kind = _NK_OP, op = :geo_skolem, children = children)
        elseif op == "true"
            return _mknode(kind = _NK_LITERAL, literal = 1.0)
        elseif op == "false"
            return _mknode(kind = _NK_LITERAL, literal = 0.0)
        elseif op == "faq"
            return _geo_compile_agg(expr, g)
        elseif op == "-" && length(expr.args) >= 3
            # The interpreter's variadic `-`: left fold `((a-b)-c)…`, matching
            # its 3-ary arm exactly. The runtime ladder's `-` is 1-or-2-ary
            # (esm-spec), so the fold happens here at compile.
            node = _geo_compile(expr.args[1], g)
            for k in 2:length(expr.args)
                node = _mknode(
                    kind = _NK_OP, op = :-,
                    children = _Node[node, _geo_compile(expr.args[k], g)]
                )
            end
            return node
        elseif op in _GEO_SCALAR_OPS
            children = _Node[_geo_compile(a, g) for a in expr.args]
            return _mknode(kind = _NK_OP, op = Symbol(op), children = children)
        end
        throw(
            TreeWalkError(
                "E_TREEWALK_GEOMETRY_SETUP",
                "unsupported op '$(op)' in setup-time geometry"
            )
        )
    end
    throw(
        TreeWalkError(
            "E_TREEWALK_GEOMETRY_SETUP",
            "unsupported expression $(typeof(expr)) in setup-time geometry"
        )
    )
end

# A ring/array SOURCE: an env array by name, a partial `index` slice of a
# source, or a nested `intersect_polygon` clip of two sources. Rank is static
# at compile (`_geo_source_rank`), which is what lets scalar `index` compile
# to a full-rank gather and partial `index` stay a view-producing reference.
function _geo_source(expr, g::_GeoCompileCtx)
    if expr isa VarExpr
        v = get(g.ctx.env, expr.name, nothing)
        v isa AbstractArray && return v
        throw(
            TreeWalkError(
                "E_TREEWALK_GEOMETRY_SETUP",
                v === nothing ? "unbound name '$(expr.name)' in setup-time geometry" :
                    "index of a non-array in setup-time geometry"
            )
        )
    elseif expr isa OpExpr && expr.op == "index"
        base = _geo_source(expr.args[1], g)
        nidx = length(expr.args) - 1
        nidx < _geo_source_rank(base) || throw(
            TreeWalkError(
                "E_TREEWALK_GEOMETRY_SETUP",
                "polygon operand must be an array (a full index yields a scalar) in setup-time geometry"
            )
        )
        return _GeoRingRef(
            base,
            _Node[_geo_compile(expr.args[k], g) for k in 2:length(expr.args)]
        )
    elseif expr isa OpExpr && expr.op == "intersect_polygon"
        expr.manifold === nothing && throw(
            TreeWalkError(
                "E_TREEWALK_GEOMETRY_NO_MANIFOLD",
                "intersect_polygon requires a manifold"
            )
        )
        return _GeoClipRef(
            _geo_source(expr.args[1], g),
            _geo_source(expr.args[2], g), expr.manifold
        )
    end
    throw(
        TreeWalkError(
            "E_TREEWALK_GEOMETRY_SETUP",
            "operand must be a build-time array (a const/setup array name, an index " *
                "slice of one, or an intersect_polygon clip) in setup-time geometry"
        )
    )
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
    exts = Int[
        _geo_index_extent(expr.ranges[v], g.ctx.index_sets, g.ctx.derived_extents)
            for v in loopvars
    ]
    scope = copy(g.scope)
    setof = copy(g.setof)
    slots = Vector{Int}(undef, length(loopvars))
    for (k, lv) in enumerate(loopvars)
        slots[k] = _geo_newslot!(g)
        scope[lv] = slots[k]
        r = expr.ranges[lv]
        r isa IndexSetRef && (setof[lv] = r.from)
    end
    inner = _GeoCompileCtx(g.ctx, scope, setof, g.nslots, g.memo)
    gates = _geo_slot_gates(expr, inner)
    filt = expr.filter === nothing ? nothing : _geo_compile(expr.filter, inner)
    body = _geo_compile(expr.expr_body, inner)
    oplus, zero = _aggregate_oplus_identity(expr.semiring, expr.reduce)
    oplus in ("+", "*", "max", "min") || throw(
        TreeWalkError(
            "E_TREEWALK_GEOMETRY_SETUP",
            "a nested `faq` reducing with '$(oplus)' has no setup-time geometry form"
        )
    )
    return _mknode(
        kind = _NK_OP, op = :geo_agg,
        payload = _GeoAggSpec(slots, exts, gates, filt, body, Symbol(oplus), zero)
    )
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
        (sA == 0 || sB == 0) && throw(
            TreeWalkError(
                "E_TREEWALK_GEOMETRY_SETUP",
                "join-gate loop var out of scope in setup-time geometry"
            )
        )
        push!(gates, _GeoSlotGate(jg.arrA, sA, jg.arrB, sB))
    end
    return gates
end

# ---- The evaluator arms (`_eval_node_op`'s cold tail) -----------------------

# Round an index expression to an integer subscript.
@inline _geo_ix_value(nd::_Node, u, p, t, ::Type{T}) where {T} =
    Int(round(_eval_node(nd, u, p, t, T)::Float64))

# Resolve a compiled ring/array source at the current frame. A partial index
# resolves to a `view` for the ranks the geometry FAQ uses (matching the
# interpreter's fast paths); the general fallback materializes a dense slice,
# as before. A clip source runs the Sutherland–Hodgman kernel per cell.
_geo_ring_value(a::AbstractArray, u, p, t, ::Type{T}) where {T} = a
function _geo_ring_value(r::_GeoClipRef, u, p, t, ::Type{T}) where {T}
    return close_ring(
        intersect_polygon(
            _geo_ring_value(r.a, u, p, t, T),
            _geo_ring_value(r.b, u, p, t, T),
            r.manifold
        )
    )
end
function _geo_ring_value(r::_GeoRingRef, u, p, t, ::Type{T}) where {T}
    # `r.src` is typed `Any` (an array, another `_GeoRingRef`, or a
    # `_GeoClipRef`), so resolving and slicing it IN THIS FRAME would leave `base`
    # — and every `ndims`/`view`/`getindex` of the slice — inferred as `Any`: a
    # dynamic dispatch per subscript, per cell, for the whole sweep. The slice
    # moves to a barrier method (`_geo_ring_slice`) taking the base as an
    # ARGUMENT, so it compiles against a known type. Same slices, same values.
    #
    # Two `isa` ladders keep even the barrier call static: the first for a source
    # that already IS the dense ring stack (where `_geo_ring_value` is the
    # identity, so the match skips a dispatch and a call), the second for one that
    # had to be resolved. Anything else takes the same generic call as before.
    src = r.src
    ix = r.idx
    if src isa Array{Float64, 3}
        return _geo_ring_slice(src, ix, u, p, t, T)
    elseif src isa Array{Float64, 2}
        return _geo_ring_slice(src, ix, u, p, t, T)
    end
    base = _geo_ring_value(src, u, p, t, T)
    if base isa Array{Float64, 3}
        return _geo_ring_slice(base, ix, u, p, t, T)
    elseif base isa Array{Float64, 2}
        return _geo_ring_slice(base, ix, u, p, t, T)
    end
    return _geo_ring_slice(base, ix, u, p, t, T)
end

function _geo_ring_slice(base, ix::Vector{_Node}, u, p, t, ::Type{T}) where {T}
    nd = ndims(base)
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
    # `_Node.payload` is `Any` (one struct serves every node kind), so reading the
    # source array THROUGH IT costs two dynamic dispatches per gather — one to
    # `_geo_ring_value`, one to the `getindex` on its `Any`-typed result — plus a
    # boxed `Float64` conversion, paid once per subscripted read per cell. Passing
    # the payload as an ARGUMENT to a barrier method lands the one remaining
    # dispatch on a specialization where the source type, and hence `arr`'s, is
    # known, so the reads in `_geo_gather_from` are ordinary typed array indexing.
    # Same order, same reads, same values; bounds stay CHECKED as before.
    #
    # A concrete `isa` then narrows `pl` to the shapes a geometry sweep actually
    # reads — a dense `Array{Float64,1..3}`, which is what every const/materialized
    # `env` entry is — making the barrier call static. Anything else (a
    # bounded-const wrapper, a `_GeoRingRef`, a `_GeoClipRef`, a non-Float64 or
    # higher-rank array) falls to the same generic call as before.
    pl = n.payload
    if pl isa Array{Float64, 1}
        return _geo_gather_from(pl, n.children, u, p, t, T)
    elseif pl isa Array{Float64, 2}
        return _geo_gather_from(pl, n.children, u, p, t, T)
    elseif pl isa Array{Float64, 3}
        return _geo_gather_from(pl, n.children, u, p, t, T)
    end
    return _geo_gather_from(pl, n.children, u, p, t, T)
end

function _geo_gather_from(src, c::Vector{_Node}, u, p, t, ::Type{T})::Float64 where {T}
    arr = _geo_ring_value(src, u, p, t, T)
    k = length(c)
    if k == 1
        return Float64(arr[_geo_ix_value(c[1], u, p, t, T)])
    elseif k == 2
        return Float64(
            arr[
                _geo_ix_value(c[1], u, p, t, T),
                _geo_ix_value(c[2], u, p, t, T),
            ]
        )
    elseif k == 3
        return Float64(
            arr[
                _geo_ix_value(c[1], u, p, t, T),
                _geo_ix_value(c[2], u, p, t, T),
                _geo_ix_value(c[3], u, p, t, T),
            ]
        )
    end
    idxs = Int[_geo_ix_value(c[i], u, p, t, T) for i in eachindex(c)]
    return Float64(arr[idxs...])
end

# Nested scalar aggregate (`:geo_agg`): the interpreter's product loop,
# verbatim — write the loop slots, join-gate then filter, sum the body.
function _geo_eval_agg(spec::_GeoAggSpec, u, p, t, ::Type{T})::Float64 where {T}
    acc = spec.zero
    op = spec.op
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
        v = _eval_node(body, u, p, t, T)
        acc = op === :+ ? acc + v : op === :max ? max(acc, v) : op === :min ? min(acc, v) : acc * v
    end
    return acc
end

# ---- Memo of shared sub-trees over the loop frame ----
# With `_geo_compile`'s memo a body is a DAG: a node with several parents (an
# edge or half-plane quantity the overlap-area templates write out at each of
# its uses) is walked once per parent. `_geo_memoize!` wraps each such node in a
# `:geomemo` node keyed by the frame slots its sub-tree reads, evaluated before
# the sub-tree runs: while those slots hold the values it last saw, the walk
# returns the value it computed then. The sub-tree's value is a function of
# those slots alone (the env is fixed for the sweep), so the result is the
# walk's own, bit for bit. A sub-tree holding a geometry leaf, a ring
# reference or a skolem is left alone.
mutable struct _GeoMemo
    slots::Vector{Int}
    last::Vector{Float64}
    val::Float64
    valid::Bool
end

function _geo_memoize!(roots::Vector{_Node})
    refs = IdDict{_Node, Int}()
    reads = IdDict{_Node, Union{Nothing, Set{Int}}}()   # `nothing`: not memoizable
    kids(n) = n.op === :geo_agg ? begin
            sp = n.payload::_GeoAggSpec
            sp.filter === nothing ? _Node[sp.body] : _Node[sp.filter, sp.body]
        end : n.children
    function visit(n::_Node)
        c = get(refs, n, 0)
        refs[n] = c + 1
        c == 0 || return reads[n]
        r = if n.kind == _NK_STATE
            Set{Int}(n.idx)
        elseif n.kind == _NK_LITERAL
            Set{Int}()
        elseif n.kind == _NK_OP && !(n.op in (:geo_pia, :geo_skolem, :geomemo)) &&
                !(n.op === :geo_agg && (n.payload::_GeoAggSpec).gates !== nothing) &&
                !(n.op === :geo_gather && !(n.payload isa AbstractArray))
            acc = Set{Int}()
            n.op === :geo_agg && union!(acc, (n.payload::_GeoAggSpec).slots)
            for ch in kids(n)
                rc = visit(ch)
                rc === nothing && (acc = nothing; break)
                union!(acc, rc)
            end
            acc
        else
            for ch in kids(n)
                visit(ch)
            end
            nothing
        end
        return reads[n] = r
    end
    foreach(visit, roots)
    wrap = IdDict{_Node, _Node}()
    for (n, c) in refs
        r = reads[n]
        (c >= 2 && r !== nothing && n.kind == _NK_OP) || continue
        sl = sort!(collect(r))
        wrap[n] = _mknode(
            kind = _NK_OP, op = :geomemo, children = _Node[n],
            payload = _GeoMemo(sl, zeros(Float64, length(sl)), 0.0, false)
        )
    end
    isempty(wrap) && return roots
    seen = IdDict{_Node, Nothing}()
    function rewire(n::_Node)
        haskey(seen, n) && return
        seen[n] = nothing
        for ch in kids(n)
            rewire(ch)
        end
        for k in eachindex(n.children)
            w = get(wrap, n.children[k], nothing)
            w === nothing || (n.children[k] = w)
        end
        return
    end
    foreach(rewire, roots)
    return _Node[get(wrap, r, r) for r in roots]
end

function _eval_geomemo(n::_Node, u, p, t, ::Type{T})::Float64 where {T}
    m = n.payload::_GeoMemo
    sl = m.slots
    if m.valid
        hit = true
        @inbounds for k in eachindex(sl)
            u[sl[k]] === m.last[k] || (hit = false; break)
        end
        hit && return m.val
    end
    @inbounds for k in eachindex(sl)
        m.last[k] = u[sl[k]]
    end
    v = Float64(_eval_node(n.children[1], u, p, t, T))
    m.val = v
    m.valid = true
    return v
end

# The join-then-filter gate for the TOP-level materialization sweeps:
# slot-addressed array equalities, then the compiled filter predicate against
# the frame.
@inline function _geo_gate_ok(gates, filt, u)
    if gates !== nothing
        @inbounds for gt in gates
            _geo_slot_eq(gt.arrA, gt.arrB, Int(u[gt.slotA]), Int(u[gt.slotB])) || return false
        end
    end
    if filt !== nothing
        _eval_node(filt, u, nothing, 0.0, Float64) != 0.0 || return false
    end
    return true
end

# One equality gate's test, behind a barrier so the two key columns (`Any`
# fields) are compared at their concrete types.
_geo_slot_eq(a, b, i::Int, j::Int) = a[i] == b[j]

# `polygon_intersection_area` of two resolved ring sources. Split out of the
# `:geo_pia` arm so the operand types can be narrowed at the call site.
function _geo_pia_value(a, b, manifold::String, u, p, t, ::Type{T})::Float64 where {T}
    return _polygon_intersection_area(
        _geo_ring_value(a, u, p, t, T),
        _geo_ring_value(b, u, p, t, T), manifold
    )
end

# The `:geo_*` dispatch — the cold tail arm of `_eval_node_op` (compile.jl).
# Only setup-time compiled trees carry these ops, so the RHS hot path never
# reaches here; `::Float64` keeps the ladder's inferred union small.
function _eval_geo_op(n::_Node, u, p, t, ::Type{T})::Float64 where {T}
    op = n.op
    if op === :geo_gather
        return _geo_gather_value(n, u, p, t, T)
    elseif op === :geo_pia
        # Both operands are `Any` on the spec, so resolving them here costs two
        # dynamic dispatches per PAIR — and a dense `A_ij[i,j] =
        # polygon_intersection_area(src[i], tgt[j])` evaluates this once per
        # (source, target) pair. Narrow the near-universal `_GeoRingRef` operands
        # with a concrete `isa` and resolve them in a specialization. Operand
        # evaluation order (a, then b) is unchanged.
        spec = n.payload::_GeoPiaSpec
        a = spec.a
        b = spec.b
        if a isa _GeoRingRef && b isa _GeoRingRef
            return _geo_pia_value(a, b, spec.manifold, u, p, t, T)
        end
        return _geo_pia_value(a, b, spec.manifold, u, p, t, T)
    elseif op === :geo_skolem
        c = n.children
        vals = Any[_eval_node(c[k], u, p, t, T) for k in eachindex(c)]
        return Float64(hash(Tuple(vals)) % _SKOLEM_HASH_CAP)
    elseif op === :geo_agg
        return _geo_eval_agg(n.payload::_GeoAggSpec, u, p, t, T)
    elseif op === :cellmemo
        return _eval_cellmemo(n, u, p, t, T)
    elseif op === :geomemo
        return _eval_geomemo(n, u, p, t, T)
    end
    throw(_unevaluable_operator(op, "the setup-geometry ladder has no arm for it"))
end

# ---- Native code for a setup body ----
# The sweeps above walk the compiled body once per cell (or candidate pair)
# with `_eval_node`. `_geo_kernel` emits the same body as Julia code instead,
# compiled once through RuntimeGeneratedFunctions, and the sweeps call it in
# place of the walk (`_geo_body_eval`). Every arm mirrors the walker's
# (`_eval_node_op`, `_geo_eval_agg`, `_geo_gather_from`): the same operations
# in the same order, left-nested folds, lazy `ifelse`/`and`/`or`, a nested
# reduction's tuples in `Iterators.product` order with its loop slots written
# to the frame, subscripts rounded to `Int` with bounds checked. A node with
# several parents is computed once per binding of the frame slots it reads: a
# local memo, reset where the innermost of those slots is set, and filled at
# its first use — so a value only an untaken branch reads is never computed.
# Bit-exactness is the contract, as in codegen_kernel.jl: no `@fastmath`, no
# `muladd`, no reassociation. A body the emitter has no arm for (a geometry
# leaf, a ring reference, a skolem, a gated nested reduction) keeps the walker.
struct _GeoKernel{F, S}
    f::F
    srcs::S
end
@inline _geo_body_eval(n::_Node, u) = _eval_node(n, u, nothing, 0.0, Float64)
@inline _geo_body_eval(k::_GeoKernel, u) = k.f(u, k.srcs)

const _GEO_CG_UNARY = Dict{Symbol, Function}(r.sym => r.fn for r in _UNARY_ELEMENTWISE_OPS)
const _GEO_CG_BINARY = Dict{Symbol, Symbol}(r.sym => r.fnsym for r in _BINARY_ELEMENTWISE_OPS)
const _GEO_CG_CMP = Dict{Symbol, Symbol}(r.sym => r.fnsym for r in _COMPARISON_ELEMENTWISE_OPS)
const _GEO_CG_MINMAX = Dict{Symbol, Symbol}(r.sym => r.fnsym for r in _NARY_MINMAX_OPS)

struct _GeoCGDecline <: EarthSciASTError end

mutable struct _GeoCG
    refs::IdDict{_Node, Int}
    level::IdDict{_Node, Int}          # the agg nest level that owns the node's innermost slot
    levels::IdDict{_Node, UInt64}      # bit k: the node's sub-tree reads a slot of level k
    slot_level::Dict{Int, Int}
    memo::IdDict{_Node, Symbol}        # shared node => its memo local
    resets::Dict{Int, Vector{Symbol}}  # level => memo locals reset at its iteration
    srcs::Vector{Any}
    src_ix::IdDict{Any, Int}
    nvar::Int
end

_geo_cg_var!(g::_GeoCG, p::String) = Symbol("_gk_", p, g.nvar += 1)

_geo_cg_kids(n::_Node) = n.op === :geo_agg ? begin
        sp = n.payload::_GeoAggSpec
        sp.filter === nothing ? _Node[sp.body] : _Node[sp.filter, sp.body]
    end : n.children

# Reference counts, and each node's level: the deepest nest level among the
# slots its sub-tree reads (0: only the sweep's own slots). The scan returns
# the set of levels read, as bits.
function _geo_cg_scan!(g::_GeoCG, n::_Node, depth::Int)
    c = get(g.refs, n, 0)
    g.refs[n] = c + 1
    c == 0 || return g.levels[n]
    bits = UInt64(0)
    if n.kind == _NK_STATE
        bits = UInt64(1) << get(g.slot_level, n.idx, 0)
    elseif n.kind == _NK_OP && n.op === :geo_agg
        sp = n.payload::_GeoAggSpec
        (sp.gates === nothing && depth + 1 < 64) || throw(_GeoCGDecline())
        for s in sp.slots
            g.slot_level[s] = depth + 1
        end
        for ch in _geo_cg_kids(n)
            bits |= _geo_cg_scan!(g, ch, depth + 1)
        end
        # The reduction's value does not depend on its own slots or deeper
        # ones; a body reading an enclosing nest's slot ties it to that nest.
        bits &= (UInt64(1) << (depth + 1)) - 1
    else
        for ch in n.children
            bits |= _geo_cg_scan!(g, ch, depth)
        end
    end
    g.level[n] = bits == 0 ? 0 : 63 - leading_zeros(bits)
    return g.levels[n] = bits
end

function _geo_cg(g::_GeoCG, n::_Node)
    if get(g.refs, n, 0) >= 2 && n.kind == _NK_OP
        m = get(g.memo, n, nothing)
        if m === nothing
            m = _geo_cg_var!(g, "m")
            g.memo[n] = m
            push!(get!(() -> Symbol[], g.resets, g.level[n]), m)
        end
        f = Symbol(m, :_set)
        return :(
            $f ? $m : begin
                    $m = $(_geo_cg_raw(g, n))::Float64
                    $f = true
                    $m
                end
        )
    end
    return _geo_cg_raw(g, n)
end

function _geo_cg_raw(g::_GeoCG, n::_Node)
    n.kind == _NK_LITERAL && return n.literal
    n.kind == _NK_STATE && return :(u[$(n.idx)])
    n.kind == _NK_OP || throw(_GeoCGDecline())
    op = n.op
    c = n.children
    em(x) = _geo_cg(g, x)
    if op === :geomemo
        return em(c[1])
    elseif op === :+ || op === :*
        acc = em(c[1])
        for i in 2:length(c)
            acc = Expr(:call, op, acc, em(c[i]))
        end
        return acc
    elseif op === :- || op === :neg
        length(c) == 1 && return :(-$(em(c[1])))
        length(c) == 2 || throw(_GeoCGDecline())
        return :($(em(c[1])) - $(em(c[2])))
    elseif haskey(_GEO_CG_BINARY, op)
        length(c) == 2 || throw(_GeoCGDecline())
        return Expr(:call, _GEO_CG_BINARY[op], em(c[1]), em(c[2]))
    elseif haskey(_GEO_CG_CMP, op)
        length(c) == 2 || throw(_GeoCGDecline())
        return :($(Expr(:call, _GEO_CG_CMP[op], em(c[1]), em(c[2]))) ? 1.0 : 0.0)
    elseif op === :and || op === :or
        acc = op === :and ? 1.0 : 0.0
        for i in length(c):-1:1
            acc = op === :and ? :($(em(c[i])) == 0 ? 0.0 : $acc) : :($(em(c[i])) != 0 ? 1.0 : $acc)
        end
        return acc
    elseif op === :not
        length(c) == 1 || throw(_GeoCGDecline())
        return :($(em(c[1])) == 0 ? 1.0 : 0.0)
    elseif op === :ifelse
        length(c) == 3 || throw(_GeoCGDecline())
        return :($(em(c[1])) != 0 ? $(em(c[2])) : $(em(c[3])))
    elseif haskey(_GEO_CG_UNARY, op)
        length(c) == 1 || throw(_GeoCGDecline())
        return Expr(:call, _GEO_CG_UNARY[op], em(c[1]))
    elseif haskey(_GEO_CG_MINMAX, op)
        length(c) >= 2 || throw(_GeoCGDecline())
        acc = em(c[1])
        for i in 2:length(c)
            acc = Expr(:call, _GEO_CG_MINMAX[op], acc, em(c[i]))
        end
        return acc
    elseif op === :geo_gather
        src = n.payload
        (src isa Array{Float64} && 1 <= ndims(src) <= 3 && ndims(src) == length(c)) ||
            throw(_GeoCGDecline())
        k = get!(g.src_ix, src) do
            push!(g.srcs, src)
            length(g.srcs)
        end
        ixs = [:(Int(round($(em(x))::Float64))) for x in c]
        return :(Float64(srcs[$k][$(ixs...)]))
    elseif op === :geo_agg
        return _geo_cg_agg(g, n)
    end
    throw(_GeoCGDecline())
end

function _geo_cg_agg(g::_GeoCG, n::_Node)
    sp = n.payload::_GeoAggSpec
    acc = _geo_cg_var!(g, "acc")
    ks = [_geo_cg_var!(g, "k") for _ in sp.slots]
    lv = maximum(g.slot_level[s] for s in sp.slots)
    body = em_body = _geo_cg(g, sp.body)
    filt = sp.filter === nothing ? nothing : _geo_cg(g, sp.filter)
    resets = Any[]
    for m in get(g.resets, lv, Symbol[])
        push!(resets, :($(Symbol(m, :_set)) = false))
    end
    sets = Any[:(u[$(sp.slots[i])] = Float64($(ks[i]))) for i in eachindex(ks)]
    fold = sp.op === :+ ? :($acc = $acc + _v) : sp.op === :max ? :($acc = max($acc, _v)) :
        sp.op === :min ? :($acc = min($acc, _v)) : :($acc = $acc * _v)
    inner = quote
        $(sets...)
        $(resets...)
        $(filt === nothing ? nothing : :($filt != 0 || continue))
        _v = $body
        $fold
    end
    # `Iterators.product` runs the first slot fastest: it is the innermost loop.
    loop = inner
    for i in eachindex(ks)
        loop = Expr(:for, :($(ks[i]) = 1:$(sp.exts[i])), loop)
    end
    # The memo locals of this nest's level are declared here, outside its loops.
    decls = Any[]
    for m in get(g.resets, lv, Symbol[])
        push!(decls, :(local $m::Float64 = 0.0), :(local $(Symbol(m, :_set))::Bool = false))
    end
    return quote
        let $acc = $(sp.zero)
            $(decls...)
            $loop
            $acc
        end
    end
end

# The native kernel of a setup body, or `nothing` (keep the walker). Only under
# the share_subtrees plan flag, so the interpreter oracle walks.
function _geo_kernel(body::_Node)
    _compiler_plan_now().share_subtrees || return nothing
    g = _GeoCG(
        IdDict{_Node, Int}(), IdDict{_Node, Int}(), IdDict{_Node, UInt64}(), Dict{Int, Int}(),
        IdDict{_Node, Symbol}(),
        Dict{Int, Vector{Symbol}}(), Any[], IdDict{Any, Int}(), 0
    )
    try
        _geo_cg_scan!(g, body, 0)
        e = _geo_cg(g, body)
        top = Any[]
        for m in get(g.resets, 0, Symbol[])
            push!(top, :(local $m::Float64 = 0.0), :(local $(Symbol(m, :_set))::Bool = false))
        end
        ex = Expr(:function, Expr(:tuple, :u, :srcs), Expr(:block, top..., :(return Float64($e))))
        f = RuntimeGeneratedFunctions.RuntimeGeneratedFunction(@__MODULE__, @__MODULE__, ex)
        _tally_cascade!(:geo_kernel)
        return _GeoKernel(f, Tuple(g.srcs))
    catch err
        err isa _GeoCGDecline && return nothing
        _is_resource_error(err) && rethrow()
        return nothing
    end
end
