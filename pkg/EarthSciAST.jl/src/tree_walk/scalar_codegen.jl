# ========================================================================
# tree_walk/scalar_codegen.jl — the Julia CODEGEN tier for the scalar
# equation list and the cached prelude.
#
# The in-place `f!` (`_make_rhs`, acc_merge.jl) evaluates the scalar equations
# (`rhs_list`) and the three cadence tiers of the shared-subexpression prelude
# (const_tier.jl) by walking each `_Node` tree with `_eval_node`, once per
# equation or slot, on every call. This tier emits them as Julia code instead,
# compiled once through RuntimeGeneratedFunctions, as the access-kernel tier
# (codegen_kernel.jl) does for array kernels.
#
# A scalar document can carry an equation per state — a gridded mechanism
# written out one ODE per species per box — so straight-line code, one
# statement per equation, would make the generated code and its compile grow
# with N. The tier emits by STRUCTURE instead:
#
#   * The dynamic prelude slots and the equations are cut into UNITS: the
#     connected components of "reads the dynamic slot". A unit is
#     self-contained — it reads no other unit's dynamic slot — so units run in
#     any order, and in parallel. In a box model each box is one unit.
#   * Each unit gets a SIGNATURE: its statements in order (slots ascending, then
#     equations in list order) with every node's kind, operator and payload
#     identity, and with the values that say WHERE it reads and writes (state
#     slots, cache slots, output slots, forcing offsets) and its literals lifted
#     out as HOLES. Units with one signature form a CLASS.
#   * A class is emitted once, as a loop over its members. A hole that has one
#     value across the class is baked in as a literal; the others become
#     columns of a per-member integer (or Float64) table, and two holes whose
#     columns agree share one. A box model's boxes are one class, so the code
#     is one box's mechanism however many boxes there are.
#
# Inside a unit the dynamic slots are LOCALS, converted to the value type as
# the interpreter's cache store converts them, and stored to the cache as well
# only when something outside the scalar list reads them (an array kernel's
# shared-prelude read, xcse.jl). A class whose unit is larger than the
# per-function node cap (`_codegen_fn_node_cap`) keeps every slot in the cache
# instead, so its statements can be split across functions.
#
# The const and time tiers are emitted the same way, one slot per unit, in
# dependency LEVELS (a slot reads only lower slots of its tier), each level's
# classes after the previous level's.
#
# BIT-EXACTNESS IS THE CONTRACT, as in codegen_kernel.jl: every node is emitted
# through the same arms `_cg_emit_op` / `_cg_emit_fn` give the array kernels,
# which mirror `_eval_node_op` operation for operation (same child order, the
# same left-nested folds, lazy `ifelse`/`and`/`or`, no `@simd`, no
# `@fastmath`, no `muladd`). Moving a statement between units, or a slot from
# the cache into a local, moves no arithmetic: each slot and each equation is
# the same expression over the same values.
#
# A unit the emitter cannot model (a node kind it has no arm for, a foreign
# cache) keeps the walker for that unit, and its equations keep their
# `:scalar` / `:scalar_loop` row in the compiler report; an emitted equation's
# row says `:scalar_codegen` / `:scalar_loop_codegen`. A const or time tier
# with any slot the emitter cannot model keeps the walker for that whole tier.
# `compiler = :interpreter` turns the tier off (plan field `scalar_codegen`),
# and every equation and slot is walked: that is the differential oracle.
# ========================================================================

_scalar_codegen_disabled() =
    _codegen_disabled() || !_compiler_plan_now().scalar_codegen

# ---- Units --------------------------------------------------------------
# A unit: the prelude slots it computes (ascending, which is topological) and
# the `rhs_list` positions of its equations (ascending).
struct _ScUnit
    slots::Vector{Int}
    outs::Vector{Int}
end

# The direct reads of the build's cache in a tree: the slot of every
# `_NK_CACHED` node whose payload is `cache`. A cached read of any OTHER
# scratch makes the tree unemittable here (`false`).
function _sc_cache_reads!(acc::Vector{Int}, nd::_Node, cache::_CSECache)
    if nd.kind === _NK_CACHED
        nd.payload === cache || return false
        push!(acc, nd.idx)
        return true
    end
    for c in nd.children
        _sc_cache_reads!(acc, c, cache) || return false
    end
    return true
end

# Every slot of `cache` an array kernel reads (spine, both recipe tiers,
# sub-kernels): those slots must be in the cache when the kernel section runs.
function _sc_kernel_reads!(acc::Set{Int}, K::_AccKernel, cache::_CSECache, seen::IdDict{Any,Nothing})
    haskey(seen, K) && return acc
    seen[K] = nothing
    nodes = _Node[K.spine]
    append!(nodes, K.cse.recipes)
    append!(nodes, K.cse.inv_recipes)
    while !isempty(nodes)
        nd = pop!(nodes)
        if nd.kind === _NK_CACHED && nd.payload === cache
            push!(acc, nd.idx)
        elseif nd.kind === _NK_SUBCALL && nd.payload isa _AccKernel
            _sc_kernel_reads!(acc, nd.payload::_AccKernel, cache, seen)
        end
        append!(nodes, nd.children)
    end
    for S in K.subs
        _sc_kernel_reads!(acc, S, cache, seen)
    end
    return acc
end

# Union-find over the dynamic slots and the equations: an equation or a slot
# joins every dynamic slot it reads. Returns the units, plus the positions
# (slots and equations) that cannot be emitted because a tree reads a foreign
# scratch — those components stay on the walker whole.
function _sc_dynamic_units(rhs_list, n_rhs::Int, prelude::AbstractVector{_Node},
                           cache::_CSECache, dyn_slots::AbstractVector{Int})
    nd_ = length(dyn_slots)
    pos = Dict{Int,Int}()                     # dynamic slot -> union-find node
    for (i, s) in enumerate(dyn_slots)
        pos[s] = i
    end
    parent = collect(1:(nd_ + n_rhs))
    find(x) = (while parent[x] != x; parent[x] = parent[parent[x]]; x = parent[x]; end; x)
    unite(a, b) = (ra = find(a); rb = find(b); ra == rb || (parent[max(ra, rb)] = min(ra, rb)); nothing)
    bad = falses(nd_ + n_rhs)
    reads = Int[]
    for (i, s) in enumerate(dyn_slots)
        empty!(reads)
        _sc_cache_reads!(reads, prelude[s], cache) || (bad[i] = true)
        for r in reads
            j = get(pos, r, 0)
            j == 0 || unite(i, j)
        end
    end
    for k in 1:n_rhs
        empty!(reads)
        _sc_cache_reads!(reads, rhs_list[k][2], cache) || (bad[nd_ + k] = true)
        for r in reads
            j = get(pos, r, 0)
            j == 0 || unite(nd_ + k, j)
        end
    end
    roots = Dict{Int,Int}()
    units = _ScUnit[]
    badroot = Set{Int}()
    for x in 1:(nd_ + n_rhs)
        bad[x] && push!(badroot, find(x))
    end
    for x in 1:(nd_ + n_rhs)
        r = find(x)
        u = get(roots, r, 0)
        if u == 0
            push!(units, _ScUnit(Int[], Int[]))
            u = roots[r] = length(units)
        end
        x <= nd_ ? push!(units[u].slots, dyn_slots[x]) : push!(units[u].outs, x - nd_)
    end
    good = _ScUnit[]
    resid = _ScUnit[]
    for (r, u) in roots
        U = units[u]
        sort!(U.slots); sort!(U.outs)
        push!(r in badroot ? resid : good, U)
    end
    # Deterministic order: by the unit's first equation, then its first slot.
    key(U) = (isempty(U.outs) ? typemax(Int) : U.outs[1],
              isempty(U.slots) ? typemax(Int) : U.slots[1])
    sort!(good; by = key); sort!(resid; by = key)
    return good, resid
end

# ---- Signatures ---------------------------------------------------------
# Hole kinds of the integer holes.
const _SCH_STATE = UInt8(1)   # a state slot read
const _SCH_OUT   = UInt8(2)   # an equation's output slot
const _SCH_STORE = UInt8(3)   # a prelude slot's own cache index
const _SCH_CREAD = UInt8(4)   # a cache read of a slot outside the unit
const _SCH_PGIDX = UInt8(5)   # a live forcing buffer's offset

mutable struct _ScSigCtx
    cache::_CSECache
    syms::Dict{Symbol,Int}
    objs::IdDict{Any,Int}
    sig::Vector{Int}
    ih::Vector{Int}
    ikind::Vector{UInt8}
    fh::Vector{Float64}
    memo::IdDict{_Node,Int}          # node -> visit number (DAG sharing)
    nvisit::Int
    loops::Vector{Any}               # enclosing contraction-loop refs
    localpos::Dict{Int,Int}          # slot -> its statement position in the unit
    # Recording (the class representative only): node -> its hole number,
    # negative for a Float64 hole.
    rec::Union{Nothing,IdDict{_Node,Int}}
end
_ScSigCtx(cache::_CSECache, syms, objs) =
    _ScSigCtx(cache, syms, objs, Int[], Int[], UInt8[], Float64[],
              IdDict{_Node,Int}(), 0, Any[], Dict{Int,Int}(), nothing)

function _sc_reset!(S::_ScSigCtx)
    empty!(S.sig); empty!(S.ih); empty!(S.ikind); empty!(S.fh)
    empty!(S.memo); S.nvisit = 0; empty!(S.loops); empty!(S.localpos)
    return S
end

_sc_sym(S::_ScSigCtx, s::Symbol) = get!(S.syms, s, length(S.syms) + 1)
_sc_obj(S::_ScSigCtx, o) = get!(S.objs, o, length(S.objs) + 1)

function _sc_ihole!(S::_ScSigCtx, v::Int, kind::UInt8, nd)
    push!(S.ih, v); push!(S.ikind, kind)
    S.rec === nothing || nd === nothing || (S.rec[nd] = length(S.ih))
    return nothing
end

function _sc_sig!(S::_ScSigCtx, nd::_Node)
    sig = S.sig
    got = get(S.memo, nd, 0)
    if got != 0
        push!(sig, -1, got)              # the same node object again
        return nothing
    end
    S.memo[nd] = (S.nvisit += 1)
    k = nd.kind
    if k === _NK_LITERAL
        push!(sig, 1)
        push!(S.fh, nd.literal)
        S.rec === nothing || (S.rec[nd] = -length(S.fh))
    elseif k === _NK_STATE
        push!(sig, 2)
        _sc_ihole!(S, nd.idx, _SCH_STATE, nd)
    elseif k === _NK_PARAM
        push!(sig, 3, _sc_sym(S, nd.sym), nd.idx)
    elseif k === _NK_TIME
        push!(sig, 4)
    elseif k === _NK_OP
        push!(sig, 5, _sc_sym(S, nd.op), length(nd.children),
              nd.op === :fn ? _sc_obj(S, nd.payload) : 0)
        for c in nd.children
            _sc_sig!(S, c)
        end
    elseif k === _NK_CONTRACTION
        push!(sig, 6, _sc_sym(S, nd.op), reinterpret(Int, nd.literal), length(nd.children))
        for c in nd.children
            _sc_sig!(S, c)
        end
    elseif k === _NK_CACHED
        nd.payload === S.cache || throw(_CodegenDecline(:foreign_scratch))
        lp = get(S.localpos, nd.idx, 0)
        if lp != 0
            push!(sig, 7, lp)
        else
            push!(sig, 7, 0)
            _sc_ihole!(S, nd.idx, _SCH_CREAD, nd)
        end
    elseif k === _NK_PARAM_GATHER
        push!(sig, 8, _sc_obj(S, nd.payload))
        _sc_ihole!(S, nd.idx, _SCH_PGIDX, nd)
    elseif k === _NK_CONST_GATHER || k === _NK_STATE_GATHER
        # The payload carries the strides and bounds the emitted read bakes in,
        # so it is part of the signature by identity.
        push!(sig, Int(k), _sc_obj(S, nd.payload), length(nd.children))
        for c in nd.children
            _sc_sig!(S, c)
        end
    elseif k === _NK_LOOPVAR
        d = findfirst(r -> r === nd.payload, S.loops)
        d === nothing && throw(_CodegenDecline(:loopvar_out_of_scope))
        push!(sig, 10, d)
    elseif k === _NK_CONTRACTION_LOOP
        spec = nd.payload::_ContractLoop
        push!(sig, 11, _sc_sym(S, nd.op), reinterpret(Int, nd.literal),
              spec.lo, spec.step, spec.hi)
        push!(S.loops, spec.ref)
        _sc_sig!(S, nd.children[1])
        pop!(S.loops)
    else
        throw(_CodegenDecline(:unknown_kind))
    end
    return nothing
end

# Signature of one unit. `ext[s]` says whether slot `s` must also be stored to
# the cache in local mode (it is part of the signature, so a class agrees on it).
function _sc_unit_sig!(S::_ScSigCtx, U::_ScUnit, rhs_list, prelude, ext::Set{Int})
    _sc_reset!(S)
    for (i, s) in enumerate(U.slots)
        push!(S.sig, 100, s in ext ? 1 : 0)
        _sc_ihole!(S, s, _SCH_STORE, nothing)
        _sc_sig!(S, prelude[s])
        S.localpos[s] = i
    end
    for k in U.outs
        push!(S.sig, 101)
        _sc_ihole!(S, rhs_list[k][1], _SCH_OUT, nothing)
        _sc_sig!(S, rhs_list[k][2])
    end
    return S
end

# ---- Classes ------------------------------------------------------------
mutable struct _ScClass
    rep::Int                     # the representative unit
    members::Vector{Int}
    ih::Vector{Int}              # members' int holes, member-major
    fh::Vector{Float64}          # members' Float64 holes, member-major
    nih::Int
    nfh::Int
    ikind::Vector{UInt8}         # the int holes' kinds (one signature, one list)
    nodes::Int                   # emitted-node estimate of one member
end

_sc_unit_nodes(U::_ScUnit, rhs_list, prelude) =
    sum(s -> _cg_node_tree_size(prelude[s]), U.slots; init = 0) +
    sum(k -> _cg_node_tree_size(rhs_list[k][2]), U.outs; init = 0)

# Group units into classes, in first-seen order. A unit whose signature walk
# declines is returned in `declined`.
function _sc_classes(units::Vector{_ScUnit}, rhs_list, prelude, cache::_CSECache,
                     ext::Set{Int}, level::Vector{Int})
    S = _ScSigCtx(cache, Dict{Symbol,Int}(), IdDict{Any,Int}())
    byclass = Dict{Tuple{Int,Vector{Int}},Int}()
    classes = _ScClass[]
    declined = Int[]
    for (ui, U) in enumerate(units)
        try
            _sc_unit_sig!(S, U, rhs_list, prelude, ext)
        catch err
            err isa _CodegenDecline || rethrow()
            push!(declined, ui)
            continue
        end
        key = (level[ui], S.sig)
        ci = get(byclass, key, 0)
        if ci == 0
            push!(classes, _ScClass(ui, Int[], Int[], Float64[], length(S.ih),
                                    length(S.fh), copy(S.ikind),
                                    _sc_unit_nodes(U, rhs_list, prelude)))
            ci = byclass[(level[ui], copy(S.sig))] = length(classes)
        end
        C = classes[ci]
        push!(C.members, ui)
        append!(C.ih, S.ih)
        append!(C.fh, S.fh)
    end
    return classes, declined
end

# ---- Emission -----------------------------------------------------------
# Emission context of one class: what each node of the representative
# becomes. `holes` maps a node to the expression its hole emits (a baked
# literal, a table read, a prefetched state local); `locals[pos]` is the
# expression a read of the unit's `pos`-th slot emits.
struct _CGUnitCtx
    holes::IdDict{_Node,Any}
    locals::Dict{Int,Any}            # slot -> expression of its value
    loops::IdDict{Any,Symbol}
end

_cg_boxaddr(::_CGCtx, ::_CGUnitCtx, ::Int, ::Int, ::Int, ::Int, ::Vector{Int}, key) =
    throw(_CodegenDecline(:lane_spec_on_scalar_spine))

function _cg_emit(ctx::_CGCtx, kc::_CGUnitCtx, nd::_Node)
    _cg_budget!(ctx)
    k = nd.kind
    if k === _NK_LITERAL
        return kc.holes[nd]
    elseif k === _NK_STATE
        return kc.holes[nd]
    elseif k === _NK_PARAM
        return :(_read_param(p, $(QuoteNode(nd.sym)), $(nd.idx)))
    elseif k === _NK_TIME
        return :t
    elseif k === _NK_OP
        return _cg_emit_op(ctx, kc, nd)
    elseif k === _NK_CONTRACTION
        # `_eval_contraction`: seeded from the node's `Float64` 0̄, children in
        # order, left-nested.
        ch = nd.children
        isempty(ch) && return nd.literal
        exprs = Any[nd.literal]
        for c in ch
            push!(exprs, _cg_emit(ctx, kc, c))
        end
        return _cg_foldl(_cg_oplus_fn(nd.op), exprs)
    elseif k === _NK_CACHED
        v = get(kc.locals, nd.idx, nothing)
        v === nothing || return v
        return :(_cgcache[$(kc.holes[nd])])
    elseif k === _NK_PARAM_GATHER
        buf = _cg_tab!(ctx, nd.payload::Vector{Float64})
        return :($buf[$(kc.holes[nd])])
    elseif k === _NK_CONST_GATHER
        return _cg_const_gather(ctx, kc, nd)
    elseif k === _NK_STATE_GATHER
        return _cg_state_gather(ctx, kc, nd)
    elseif k === _NK_LOOPVAR
        s = get(kc.loops, nd.payload, nothing)
        s === nothing && throw(_CodegenDecline(:loopvar_out_of_scope))
        return :(_cgT($s))
    elseif k === _NK_CONTRACTION_LOOP
        # `_eval_contraction_loop`: the accumulator starts at `T(0̄)`, and each
        # step is `s ⊕= body` with the counter bound for the body's loop-var
        # leaves.
        spec = nd.payload::_ContractLoop
        op = nd.op
        fnsym = op === :+ ? :+ : op === :* ? :* : op === :max ? :max : :min
        acc = _cg_name(ctx, "la")
        kv = _cg_name(ctx, "lk")
        kc.loops[spec.ref] = kv
        body = _cg_emit(ctx, kc, nd.children[1])
        delete!(kc.loops, spec.ref)
        return quote
            local $acc = _cgT($(nd.literal))
            for $kv in $(spec.lo):$(spec.step):$(spec.hi)
                $acc = $fnsym($acc, $body)
            end
            $acc
        end
    end
    throw(_CodegenDecline(:unknown_kind))
end

# One emitted item: a loop over a class's members running some of its
# statements. Built per class (local mode: one item; cache mode: as many as the
# node cap needs).
struct _ScItem
    class::Int
    stmts::UnitRange{Int}        # statement positions (slots first, then outs)
    cost::Int
end

# Statement `i` of unit `U`: `(is_slot, slot_or_rhs_position, tree)`.
@inline function _sc_stmt(U::_ScUnit, i::Int, rhs_list, prelude)
    ns = length(U.slots)
    if i <= ns
        s = U.slots[i]
        return (true, s, prelude[s])
    end
    k = U.outs[i - ns]
    return (false, k, rhs_list[k][2])
end

# Plan the items of every class: local mode (one item) when a member fits the
# cap, otherwise statements packed into items of at most `cap` nodes each.
function _sc_items(classes::Vector{_ScClass}, units::Vector{_ScUnit}, rhs_list, prelude, cap::Int)
    items = _ScItem[]
    cachemode = falses(length(classes))
    for (ci, C) in enumerate(classes)
        U = units[C.rep]
        nst = length(U.slots) + length(U.outs)
        if cap <= 0 || C.nodes <= cap
            push!(items, _ScItem(ci, 1:nst, C.nodes))
            continue
        end
        cachemode[ci] = true
        a = 1; cost = 0
        for i in 1:nst
            c = _cg_node_tree_size(_sc_stmt(U, i, rhs_list, prelude)[3])
            if i > a && cost + c > cap
                push!(items, _ScItem(ci, a:(i - 1), cost))
                a = i; cost = 0
            end
            cost += c
        end
        push!(items, _ScItem(ci, a:nst, cost))
    end
    return items, cachemode
end

# Per-class hole layout: which holes are baked, which table column each
# varying hole reads, and the tables themselves.
struct _ScLayout
    ibake::Vector{Bool}
    icol::Vector{Int}            # varying int hole -> table column
    nicol::Int
    itab::Vector{Int}            # member-major, `nicol` per member
    fbake::Vector{Bool}
    fcol::Vector{Int}
    nfcol::Int
    ftab::Vector{Float64}
end

# A slot's own cache index is read only when the slot is stored: in cache mode,
# in a cadence tier, or when an array kernel reads it. Otherwise its hole is
# never emitted, and it takes no table column.
function _sc_layout(C::_ScClass, cachemode::Bool, alwaysstore::Bool, ext::Set{Int})
    M = length(C.members)
    ni, nf = C.nih, C.nfh
    ibake = fill(true, ni); icol = zeros(Int, ni)
    cols = Dict{Vector{Int},Int}()
    for h in 1:ni
        v1 = C.ih[h]
        C.ikind[h] === _SCH_STORE && !(cachemode || alwaysstore || v1 in ext) && continue
        col = Vector{Int}(undef, M)
        same = true
        for m in 1:M
            v = C.ih[(m - 1) * ni + h]
            col[m] = v
            same &= v == v1
        end
        same && continue
        ibake[h] = false
        icol[h] = get!(cols, col, length(cols) + 1)
    end
    nicol = length(cols)
    itab = Vector{Int}(undef, M * nicol)
    for (col, c) in cols, m in 1:M
        itab[(m - 1) * nicol + c] = col[m]
    end
    fbake = fill(true, nf); fcol = zeros(Int, nf)
    fcols = Dict{Vector{UInt64},Int}()
    fvals = Dict{Int,Vector{Float64}}()
    for h in 1:nf
        b1 = reinterpret(UInt64, C.fh[h])
        col = Vector{UInt64}(undef, M)
        same = true
        for m in 1:M
            b = reinterpret(UInt64, C.fh[(m - 1) * nf + h])
            col[m] = b
            same &= b == b1
        end
        same && continue
        fbake[h] = false
        c = get!(fcols, col, length(fcols) + 1)
        fcol[h] = c
        fvals[c] = reinterpret(Float64, col)
    end
    nfcol = length(fcols)
    ftab = Vector{Float64}(undef, M * nfcol)
    for (c, col) in fvals, m in 1:M
        ftab[(m - 1) * nfcol + c] = col[m]
    end
    return _ScLayout(ibake, icol, nicol, itab, fbake, fcol, nfcol, ftab)
end

# Emit one item: a `let` block looping over this chunk's share of the class's
# members. `stored[s]` (local mode) says a slot must also be stored to the cache.
function _sc_emit_item!(ctx::_CGCtx, it::_ScItem, C::_ScClass, L::_ScLayout,
                        U::_ScUnit, cachemode::Bool, S::_ScSigCtx, rhs_list, prelude,
                        ext::Set{Int}, alwaysstore::Bool)
    # Re-walk the representative to number its holes by node.
    S.rec = IdDict{_Node,Int}()
    _sc_unit_sig!(S, U, rhs_list, prelude, ext)
    rec = S.rec
    S.rec = nothing
    M = length(C.members)
    itv = _cg_name(ctx, "it")
    ftv = _cg_name(ctx, "ft")
    bv = _cg_name(ctx, "b")
    bfv = _cg_name(ctx, "bf")
    jv = _cg_name(ctx, "j")
    # The int holes of the representative in walk order are `1:C.nih`: the
    # store/out holes of the statements interleave with the tree holes. Their
    # emitted expressions:
    iexpr = Vector{Any}(undef, C.nih)
    prefetch = Dict{Int,Symbol}()            # state table column -> local
    preorder = Int[]
    for h in 1:C.nih
        if L.ibake[h]
            v = C.ih[h]
            iexpr[h] = S.ikind[h] === _SCH_STATE ? :(u[$v]) : v
        else
            c = L.icol[h]
            if S.ikind[h] === _SCH_STATE
                sym = get!(prefetch, c) do
                    push!(preorder, c)
                    _cg_name(ctx, "u")
                end
                iexpr[h] = sym
            else
                iexpr[h] = :($itv[$bv + $c])
            end
        end
    end
    fexpr = Vector{Any}(undef, C.nfh)
    for h in 1:C.nfh
        fexpr[h] = L.fbake[h] ? C.fh[h] : :($ftv[$bfv + $(L.fcol[h])])
    end
    holes = IdDict{_Node,Any}()
    for (nd, h) in rec
        holes[nd] = h > 0 ? iexpr[h] : fexpr[-h]
    end
    # Each statement's own store/out hole, in statement order: they are the
    # holes the tree walk did not record (`nothing` node).
    recorded = Set(values(rec))
    stmt_hole = Int[h for h in 1:C.nih if !(h in recorded)]
    ns = length(U.slots)
    kc = _CGUnitCtx(holes, Dict{Int,Any}(), IdDict{Any,Symbol}())
    for i in 1:ns
        s = U.slots[i]
        h = stmt_hole[i]
        kc.locals[s] = cachemode ? :(_cgcache[$(iexpr[h])]) : nothing
    end
    cachemode && filter!(kv -> kv[2] !== nothing, kc.locals)
    body = Any[]
    for i in it.stmts
        is_slot, sk, tree = _sc_stmt(U, i, rhs_list, prelude)
        h = stmt_hole[i]
        ex = _cg_emit(ctx, kc, tree)
        if cachemode
            ex = _cg_bound_body!(ctx, ex)
            push!(body, is_slot ? :(_cgcache[$(iexpr[h])] = $ex) :
                                  :(du[$(iexpr[h])] = $ex))
        elseif is_slot
            lv = _cg_name(ctx, "s")
            push!(body, :(local $lv = convert(_cgT, $ex)))
            kc.locals[sk] = lv
            (alwaysstore || sk in ext) && push!(body, :(_cgcache[$(iexpr[h])] = $lv))
        else
            push!(body, :(du[$(iexpr[h])] = $ex))
        end
    end
    # Prefetch only the state columns this item's statements read.
    used = _cg_collect_syms!(Set{Symbol}(), Expr(:block, body...))
    pre = Any[:(local $(prefetch[c]) = u[$itv[$bv + $c]]) for c in preorder
              if prefetch[c] in used]
    hdr = Any[]
    L.nicol > 0 && push!(hdr, :(local $bv = ($jv - 1) * $(L.nicol)))
    L.nfcol > 0 && push!(hdr, :(local $bfv = ($jv - 1) * $(L.nfcol)))
    av = _cg_name(ctx, "a"); ev = _cg_name(ctx, "e"); abv = _cg_name(ctx, "ab")
    binds = Any[]
    L.nicol > 0 && push!(binds, :(local $itv = $(_cg_tab!(ctx, L.itab))))
    L.nfcol > 0 && push!(binds, :(local $ftv = $(_cg_tab!(ctx, L.ftab))))
    mexpr = M == 1 ? 1 : _cg_geo!(ctx, M)
    return quote
        let
            $(binds...)
            local $abv = _chunk_ordinals($mexpr, _cgci, _cgnc)
            local $av = $abv[1]
            local $ev = $abv[2]
            for $jv in ($av + 1):$ev
                $(hdr...)
                $(pre...)
                $(body...)
            end
        end
    end
end

# One generated function over a run of items.
struct _ScGen{F,TB}
    f::F
    tabs::TB
end

function _sc_build_gen(items::AbstractVector{_ScItem}, classes, layouts, units, cachemode,
                       S::_ScSigCtx, rhs_list, prelude, ext::Set{Int}, alwaysstore::Bool)
    ctx = _CGCtx(typemax(Int), nothing)
    loops = Any[]
    for it in items
        C = classes[it.class]
        push!(loops, _sc_emit_item!(ctx, it, C, layouts[it.class], units[C.rep],
                                    cachemode[it.class], S, rhs_list, prelude, ext,
                                    alwaysstore))
    end
    ln = LineNumberNode(0, Symbol("ess-scalar-codegen"))
    ngrp = length(ctx.tab_types)
    grpstmts = Any[:(local $(_cg_grp_sym(g)) = tabs[$g]) for g in 1:ngrp]
    byval = _cg_split_by_value()
    fnstmts = byval && !isempty(ctx.helpers) ?
              Any[:(local $(_CG_FNS) = tabs[$(ngrp + 1)])] : Any[]
    helperdefs = byval ? Any[] : ctx.helpers
    # `u` is read-only in an alias scope, as in the kernel section: the scalar
    # section writes only `du` and the cache, never `u`.
    run = Expr(:macrocall, GlobalRef(Base.Experimental, Symbol("@aliasscope")), ln,
               Expr(:let, Expr(:block, :(u = _cg_readonly(u))),
                    Expr(:block,
                         Expr(:macrocall, Symbol("@inbounds"), ln,
                              Expr(:block, loops...)))))
    body = Expr(:block, grpstmts..., fnstmts...,
                :(local _cgT = _rhs_value_type(u, p, t)),
                ctx.geosink...,
                helperdefs...,
                run,
                :(return nothing))
    ex = Expr(:function,
              Expr(:tuple, :du, :u, :p, :t, :_cgcache, :tabs, :_cgci, :_cgnc), body)
    f = RuntimeGeneratedFunctions.RuntimeGeneratedFunction(@__MODULE__, @__MODULE__, ex)
    tabpack = ntuple(g -> Vector{ctx.tab_types[g]}(ctx.tab_objs[g]), ngrp)
    if byval && !isempty(ctx.helpers)
        tabpack = (tabpack...,
                   Tuple(RuntimeGeneratedFunctions.RuntimeGeneratedFunction(
                             @__MODULE__, @__MODULE__, h) for h in ctx.helpers))
    end
    return _ScGen(f, tabpack)
end

# ---- A compiled scalar program ------------------------------------------
# The generated functions of one section, run in order. They ride a TUPLE,
# walked by tail recursion, so each is called at its concrete type and nothing
# boxes (the reason `_ContractionSection` gives).
struct _ScalarProgram{G}
    gens::G
    threaded::Bool               # its classes are independent units (the dynamic section)
    tcache::_SecTCache
end

Base.isempty(sp::_ScalarProgram) = isempty(sp.gens)

@inline _run_scgens!(::Tuple{}, du, u, p, t, cache, ci::Int, nc::Int) = nothing
@inline function _run_scgens!(gs::Tuple, du, u, p, t, cache, ci::Int, nc::Int)
    g = gs[1]
    g.f(du, u, p, t, cache, g.tabs, ci, nc)
    return _run_scgens!(Base.tail(gs), du, u, p, t, cache, ci, nc)
end

# Chunked across threads when the program's units are independent: chunk `c`
# runs its share of every class's members in every generated function, in
# order. A member's statements run in one chunk, in order, and two members
# share nothing but the cache slots they read (filled before) and write
# (distinct per member), so a chunked call is bit-identical to the serial one,
# at every value type.
struct _ScChunk{G,C}
    gens::G
    cache::C
end
@inline (b::_ScChunk)(args, c::Int, nc::Int) =
    _run_scgens!(b.gens, args[1], args[2], args[3], args[4], b.cache, c, nc)

@inline function (sp::_ScalarProgram)(du, u, p, t, cache, ::Type{T}) where {T}
    if sp.threaded && _threads_available() &&
       _sec_prep_threads!(sp.tcache).state == 1
        _run_chunked!(sp.tcache, _ScChunk(sp.gens, cache), (du, u, p, t))
    else
        _run_scgens!(sp.gens, du, u, p, t, cache, 1, 1)
    end
    return nothing
end

# Emit `units` (already in run order, `level[u]` nondecreasing) into a program.
function _sc_program(units::Vector{_ScUnit}, level::Vector{Int}, rhs_list, prelude,
                     cache::_CSECache, ext::Set{Int}; alwaysstore::Bool, threaded::Bool)
    classes, declined = _sc_classes(units, rhs_list, prelude, cache, ext, level)
    cap = _codegen_fn_node_cap()
    # The build's emitted-node budget (`ESS_CODEGEN_NODE_BUDGET`, the backstop
    # the kernel emission has): a class past what is left keeps the walker.
    budget = _codegen_node_budget()
    ok = trues(length(classes))
    for (ci, C) in enumerate(classes)
        if C.nodes > budget
            ok[ci] = false
        else
            budget -= C.nodes
        end
    end
    items, cachemode = _sc_items(classes, units, rhs_list, prelude, cap)
    layouts = _ScLayout[_sc_layout(C, cachemode[ci], alwaysstore, ext)
                        for (ci, C) in enumerate(classes)]
    S = _ScSigCtx(cache, Dict{Symbol,Int}(), IdDict{Any,Int}())
    # Pack items into generated functions of at most `cap` nodes (items keep
    # their order, which is the level order).
    gens = Any[]
    a = 1; cost = 0
    emit_run(b) = begin
        if b >= a
            # A class that declines while emitting declines every member.
            run = _ScItem[]
            for it in items[a:b]
                ok[it.class] && push!(run, it)
            end
            while !isempty(run)
                try
                    push!(gens, _sc_build_gen(run, classes, layouts, units, cachemode, S,
                                              rhs_list, prelude, ext, alwaysstore))
                    break
                catch err
                    err isa _CodegenDecline || rethrow()
                    # Find the declining class by emitting each alone.
                    bad = findfirst(run) do it
                        try
                            _sc_emit_item!(_CGCtx(typemax(Int), nothing), it,
                                           classes[it.class], layouts[it.class],
                                           units[classes[it.class].rep],
                                           cachemode[it.class], S, rhs_list, prelude,
                                           ext, alwaysstore)
                            false
                        catch e2
                            e2 isa _CodegenDecline || rethrow()
                            true
                        end
                    end
                    bad === nothing && rethrow()
                    ok[run[bad].class] = false
                    filter!(it -> ok[it.class], run)
                end
            end
        end
    end
    filter!(it -> ok[it.class], items)
    for (i, it) in enumerate(items)
        if i > a && cap > 0 && cost + it.cost > cap
            emit_run(i - 1)
            a = i; cost = 0
        end
        cost += it.cost
    end
    emit_run(length(items))
    emitted = Int[]
    resid = copy(declined)
    for (ci, C) in enumerate(classes)
        append!(ok[ci] ? emitted : resid, C.members)
    end
    # The work a chunked call can share out: the statements of every class with
    # more than one member (a one-member class runs whole in one chunk).
    nsplit = 0
    for (ci, C) in enumerate(classes)
        (ok[ci] && length(C.members) > 1) || continue
        U = units[C.rep]
        nsplit += length(C.members) * (length(U.slots) + length(U.outs))
    end
    return _ScalarProgram(Tuple(gens), threaded, _SecTCache(nsplit, true)), emitted, resid
end

# Dependency levels of a cadence tier's slots: 1 + the deepest level among the
# slots of the same tier a slot reads.
function _sc_tier_levels(slots::AbstractVector{Int}, prelude, cache::_CSECache)
    lvl = Dict{Int,Int}()
    reads = Int[]
    out = Vector{Int}(undef, length(slots))
    for (i, s) in enumerate(sort(collect(slots)))
        empty!(reads)
        _sc_cache_reads!(reads, prelude[s], cache)
        l = 1
        for r in reads
            l = max(l, get(lvl, r, 0) + 1)
        end
        lvl[s] = l
    end
    for (i, s) in enumerate(slots)
        out[i] = lvl[s]
    end
    return out
end

# ---- The scalar section of a build --------------------------------------
# Everything `_make_rhs` needs: a program per cadence tier (or `nothing`,
# leaving that tier on the walker), the dynamic program, and what the walker
# still has to do (`resid_dyn` slots, `resid_rhs` equations).
struct _ScalarSection{CP,TP,DP}
    constp::CP
    timep::TP
    dynp::DP
    resid_dyn::Vector{Int}
    resid_rhs::Vector{Tuple{Int,_Node}}
    emitted_outs::Vector{Int}        # `rhs_list` positions now compiled
end

# A cadence tier: emitted whole, or not at all.
function _sc_tier_program(slots::AbstractVector{Int}, prelude, cache::_CSECache)
    isempty(slots) && return nothing
    lv = _sc_tier_levels(slots, prelude, cache)
    order = sortperm(collect(zip(lv, slots)))
    units = _ScUnit[_ScUnit([slots[i]], Int[]) for i in order]
    level = lv[order]
    prog, _, resid = _sc_program(units, level, Tuple{Int,_Node}[], prelude, cache,
                                 Set{Int}(); alwaysstore = true, threaded = false)
    isempty(resid) || return nothing
    return prog
end

# Build the scalar section. The first `n_rhs` entries of `rhs_list` are the
# scalar equations; any after them (the forced per-cell reference) stay walked.
# Returns `nothing` when the tier is off.
function _build_scalar_section(rhs_list::AbstractVector{Tuple{Int,_Node}}, n_rhs::Int,
                               prelude::AbstractVector{_Node}, cache::_CSECache,
                               const_slots::AbstractVector{Int},
                               time_slots::AbstractVector{Int},
                               dyn_slots::AbstractVector{Int},
                               acc_kernels::AbstractVector{_AccKernel})
    _scalar_codegen_disabled() && return nothing
    constp = _sc_tier_program(const_slots, prelude, cache)
    timep = _sc_tier_program(time_slots, prelude, cache)
    ext = Set{Int}()
    seen = IdDict{Any,Nothing}()
    for K in acc_kernels
        _sc_kernel_reads!(ext, K, cache, seen)
    end
    good, bad = _sc_dynamic_units(rhs_list, n_rhs, prelude, cache, dyn_slots)
    dynp, emitted, resid = _sc_program(good, ones(Int, length(good)), rhs_list, prelude,
                                       cache, ext; alwaysstore = false, threaded = true)
    resid_units = vcat(bad, good[resid])
    resid_dyn = sort!(reduce(vcat, (U.slots for U in resid_units); init = Int[]))
    resid_pos = sort!(reduce(vcat, (U.outs for U in resid_units); init = Int[]))
    append!(resid_pos, (n_rhs + 1):length(rhs_list))
    resid_rhs = Tuple{Int,_Node}[rhs_list[k] for k in resid_pos]
    emitted_outs = sort!(reduce(vcat, (good[u].outs for u in emitted); init = Int[]))
    isempty(emitted) || _tally_cascade!(:scalar_codegen)
    isempty(resid_units) || _tally_cascade!(:scalar_codegen_decline)
    return _ScalarSection(constp, timep, dynp, resid_dyn, resid_rhs, emitted_outs)
end

# Re-tier the report rows of the scalar equations the section compiled. A
# scalar equation's row is filed (by state name) when it is resolved, before
# anything is emitted; this moves `:scalar` → `:scalar_codegen` and
# `:scalar_loop` → `:scalar_loop_codegen` for the rows whose output slot is now
# in generated code.
function _retier_scalar_rules!(var_map, rhs_list, sec::_ScalarSection)
    rec = _build_record()
    rec === nothing && return nothing
    outs = Set{Int}(rhs_list[k][1] for k in sec.emitted_outs)
    isempty(outs) && return nothing
    for (i, r) in enumerate(rec.rules)
        r.kind === :equation || continue
        newtier = r.tier === :scalar ? :scalar_codegen :
                  r.tier === :scalar_loop ? :scalar_loop_codegen : nothing
        newtier === nothing && continue
        get(var_map, r.rule, 0) in outs || continue
        rec.rules[i] = CompilerRuleRecord(r.rule, r.kind, newtier, r.declines)
    end
    return nothing
end

# ---- The right-hand side with a scalar section ---------------------------
# `_make_rhs`'s `f!` (acc_merge.jl) with the scalar walk replaced by the
# section's programs. Same order of sections, same cadence stamps: the const
# tier refills only when `p` moved, the time tier when `(p, t, forcing epoch)`
# moved, the dynamic units every call; then whatever the section left on the
# walker; then the kernels, the scan folds and the contractions. The walked
# prelude is captured only when something is still walked, so a fully emitted
# build carries no tree.
function _make_rhs_scalar_cg(sec::_ScalarSection, full_prelude::AbstractVector{_Node},
                             cse_cache::_CSECache,
                             acc_kernels::AbstractVector{_AccKernel},
                             const_slots::AbstractVector{Int},
                             time_slots::AbstractVector{Int},
                             scan_section::_ScanSection,
                             array_contractions)
    kernel_section = _make_kernel_section(acc_kernels; shared_cache=cse_cache)
    constp = sec.constp
    timep = sec.timep
    dynp = sec.dynp
    resid_dyn = sec.resid_dyn
    resid_rhs = sec.resid_rhs
    walks_prelude = (constp === nothing && !isempty(const_slots)) ||
                    (timep === nothing && !isempty(time_slots)) || !isempty(resid_dyn)
    # Named as `_make_rhs`'s capture is, so the walked prelude is introspectable
    # the same way whichever builder made `f!`.
    cse_prelude = walks_prelude ? collect(_Node, full_prelude) : _Node[]
    const_walk = constp === nothing ? collect(Int, const_slots) : Int[]
    time_walk = timep === nothing ? collect(Int, time_slots) : Int[]
    has_const = !isempty(const_slots)
    has_time = !isempty(time_slots)
    function f!(du, u, p, t)
        _reject_float32_state(u)
        T = _rhs_value_type(u, p, t)
        cache = _cse_buf(cse_cache, T)
        if has_const && _cse_const_stale(cse_cache, T, p)
            if constp === nothing
                @inbounds for i in eachindex(const_walk)
                    s = const_walk[i]
                    cache[s] = _eval_node(cse_prelude[s], u, p, t, T)
                end
            else
                constp(du, u, p, t, cache, T)
            end
            _cse_mark_const!(cse_cache, T, p)
        end
        if has_time && _cse_t_stale(cse_cache, T, p, t)
            if timep === nothing
                @inbounds for i in eachindex(time_walk)
                    s = time_walk[i]
                    cache[s] = _eval_node(cse_prelude[s], u, p, t, T)
                end
            else
                timep(du, u, p, t, cache, T)
            end
            _cse_mark_t!(cse_cache, T, p, t)
        end
        dynp(du, u, p, t, cache, T)
        @inbounds for i in eachindex(resid_dyn)
            s = resid_dyn[i]
            cache[s] = _eval_node(cse_prelude[s], u, p, t, T)
        end
        @inbounds for k in 1:length(resid_rhs)
            idx_and_node = resid_rhs[k]
            du[idx_and_node[1]] = _eval_node(idx_and_node[2], u, p, t, T)
        end
        kernel_section(du, u, p, t, T)
        isempty(scan_section) || _apply_scan_folds!(du, u, p, t, scan_section)
        isempty(array_contractions) ||
            _apply_array_contractions!(du, u, p, t, array_contractions, T)
        return nothing
    end
    return f!
end
