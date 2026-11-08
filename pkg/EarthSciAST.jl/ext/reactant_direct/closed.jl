# ========================================================================
# ext/reactant_direct/closed.jl — the two shapes the closed-AST standard
# library (`lib/*.esm`) leaves in the compiled IR that the generic walk
# either cannot lower or lowers one term at a time: a const-array read at a
# COMPUTED subscript, and the comparison COUNT.
# ========================================================================
#
# COMPUTED-SUBSCRIPT CONST READ. `index(table, i)` with `i` computed from the
# state (the `lib/interp.esm` templates read `table[searchsorted(x)]`) is an
# `_NK_CONST_GATHER` whose subscripts are not host data. In a merged access
# kernel the kernel-class merge (`_acc_merge_nodes`) carries it as an `_NK_OP`
# node with an empty operator and the `_ConstGatherArray` payload intact, so it
# is recognised here by that payload. The interpreter reads it as
# `flat[Σ (_const_gather_sub(round(Int, s_d)) - 1) * stride_d + 1]`, and
# `round(Int, …)` THROWS on a NaN or out-of-range subscript, as the `error`
# boundary policy does on an out-of-range one. A compiled program has no channel
# for either, so the read is lowered only when every subscript is PROVEN finite
# and, under `error`, inside the array — by the interval walk `_de_subrange`
# below, which knows the shapes these templates build their subscripts from
# (literals, counters, comparisons, `ifelse`, `+ - *`, `min`/`max`, the count
# itself) and nothing else. Anything it cannot bound is refused by name.
#
# THE COUNT. A `+` fold seeded from `+0.0` of `ifelse(a REL x, 1, 0)` (or the
# swapped-branch `ifelse(a REL x, 0, 1)`), REL one of `<= < >= >`, every key `a`
# host data and every query `x` the same expression. Every term is exactly 0 or
# 1 and every partial sum an integer far below 2^53, so the fold is the count
# of keys satisfying the comparison, exactly, whatever the association — and
# any algorithm computing that count gives the fold's bits. It is lowered
# through the interp lane's knot count (`_knot_count`, ext/reactant_interp.jl:
# the compare ladder for short key lists, the verified affine guess on a
# uniform axis, else one compare against a constant key row and one reduce),
# over the keys with the NaNs set aside (a NaN key satisfies nothing) and
# sorted (which a count cannot see, and which lets the affine tier apply). The
# fold appears in three spellings: a counted loop (`_NK_CONTRACTION_LOOP`), a
# runtime contraction (`_NK_CONTRACTION`) and, unrolled at build, an n-ary `+`
# whose first operand is the `+0.0` seed. A fold of any other shape — another
# seed, ⊕, body, branch literal or comparison, a key that is not host data, a
# query that differs between terms — is not this shape and lowers as before.

# ---- interval walk -----------------------------------------------------------

# `(lo, hi)` with every value the node can take inside `[lo, hi]`, finite and
# never NaN, or `nothing`. `cached(nd)` resolves an `_NK_CACHED` leaf to the
# node it stands for (or `nothing`).
const _DE_SUB_LIMIT = 2.0^52

function _de_subrange(nd::_E._Node, cached::F)::Union{Nothing, NTuple{2, Float64}} where {F}
    r = _de_subrange_raw(nd, cached)
    r === nothing && return nothing
    lo, hi = r
    (isfinite(lo) && isfinite(hi) && -_DE_SUB_LIMIT <= lo <= hi <= _DE_SUB_LIMIT) ||
        return nothing
    return r
end

function _de_subrange_raw(nd::_E._Node, cached::F) where {F}
    k = nd.kind
    if k === _E._NK_LITERAL
        v = nd.literal
        return isnan(v) ? nothing : (v, v)
    elseif k === _E._NK_LOOPVAR
        v = Float64((nd.payload::Base.RefValue{Int})[])
        return (v, v)
    elseif k === _E._NK_CACHED
        c = cached(nd)
        return c === nothing ? nothing : _de_subrange(c, cached)
    elseif k === _E._NK_CONTRACTION
        nd.op === :+ || return nothing
        s = (nd.literal, nd.literal)
        for ch in nd.children
            r = _de_subrange(ch, cached)
            r === nothing && return nothing
            s = (s[1] + r[1], s[2] + r[2])
        end
        return s
    elseif k === _E._NK_CONTRACTION_LOOP
        nd.op === :+ || return nothing
        spec = nd.payload::_E._ContractLoop
        s = (nd.literal, nd.literal)
        for kk in spec.lo:spec.step:spec.hi
            spec.ref[] = kk
            r = _de_subrange(nd.children[1], cached)
            r === nothing && return nothing
            s = (s[1] + r[1], s[2] + r[2])
        end
        return s
    elseif k === _E._NK_OP
        op = nd.op
        c = nd.children
        if haskey(_DE_COMPARE, op) || op === :not || op === :and || op === :or
            return (0.0, 1.0)
        elseif op === :ifelse && length(c) == 3
            a = _de_subrange(c[2], cached)
            b = _de_subrange(c[3], cached)
            (a === nothing || b === nothing) && return nothing
            return (min(a[1], b[1]), max(a[2], b[2]))
        end
        rs = NTuple{2, Float64}[]
        for ch in c
            r = _de_subrange(ch, cached)
            r === nothing && return nothing
            push!(rs, r)
        end
        isempty(rs) && return nothing
        if op === :+
            return (sum(first, rs), sum(last, rs))
        elseif (op === :- || op === :neg) && length(rs) == 1
            return (-rs[1][2], -rs[1][1])
        elseif op === :- && length(rs) == 2
            return (rs[1][1] - rs[2][2], rs[1][2] - rs[2][1])
        elseif op === :* && length(rs) == 2
            ps = (
                rs[1][1] * rs[2][1], rs[1][1] * rs[2][2],
                rs[1][2] * rs[2][1], rs[1][2] * rs[2][2],
            )
            return (minimum(ps), maximum(ps))
        elseif op === :min
            return (minimum(first, rs), minimum(last, rs))
        elseif op === :max
            return (maximum(first, rs), maximum(last, rs))
        elseif (op === :floor || op === :ceil) && length(rs) == 1
            f = op === :floor ? floor : ceil
            return (f(rs[1][1]), f(rs[1][2]))
        end
    end
    return nothing
end

# ---- computed-subscript const read -------------------------------------------

_de_is_cgather(nd::_E._Node) =
    nd.payload isa _E._ConstGatherArray &&
    (nd.kind === _E._NK_CONST_GATHER || (nd.kind === _E._NK_OP && nd.op === Symbol("")))

# `ev(child)` emits a subscript; `cached` as for `_de_subrange`.
function _de_cgather(ctx::_DECtx, nd::_E._Node, ev::F, cached::G)::_DEVal where {F, G}
    cg = nd.payload::_E._ConstGatherArray
    nm = isempty(cg.name) ? "a const array" : "the const array `$(cg.name)`"
    off = nothing
    for d in eachindex(nd.children)
        ch = nd.children[d]
        r = _de_subrange(ch, cached)
        r === nothing && _de_refuse(
            "a read of $nm at a computed subscript",
            "the subscript on dimension $d is not provably a finite number, and the " *
                "interpreter's `round(Int, …)` of a NaN or an infinite subscript " *
                "raises at run time, which a compiled program has no channel to report."
        )
        n = cg.dims[d]
        pol = cg.boundary[d]
        # The extremes as the interpreter rounds them (ties to even).
        rlo, rhi = round(r[1]), round(r[2])
        inside = 1 <= rlo && rhi <= n
        wraps = n >= 1 && (pol === :periodic || pol === :clamp)
        (inside || wraps) || _de_refuse(
            "a read of $nm at a computed subscript",
            "the subscript on dimension $d can take values in [$(r[1]), $(r[2])], " *
                "outside 1..$n, where the `$(pol)` boundary policy raises at run time; " *
                "a compiled program has no channel to report it."
        )
        s = _de_un(ctx, _hlo.round_nearest_even, _de_bcast_any(ev(ch)))
        if !inside && pol === :periodic
            # mod1(s, n) = rem(s - 1, n) taken non-negative, plus 1: exact on
            # integer-valued Float64s of this size.
            one = _de_const(ctx, 1.0); nn = _de_const(ctx, Float64(n))
            m = _de_bin(ctx, _hlo.remainder, _de_bin(ctx, _hlo.subtract, s, one), nn)
            pred, L = _de_pred(ctx, "LT", m, _de_const(ctx, 0.0))
            m = _de_select(ctx, pred, L, _de_bin(ctx, _hlo.add, m, nn), m)
            s = _de_bin(ctx, _hlo.add, m, one)
        elseif !inside
            s = _de_bin(
                ctx, _hlo.minimum,
                _de_bin(ctx, _hlo.maximum, s, _de_const(ctx, 1.0)),
                _de_const(ctx, Float64(n))
            )
        end
        term = _de_bin(
            ctx, _hlo.multiply,
            _de_bin(ctx, _hlo.subtract, s, _de_const(ctx, 1.0)),
            _de_const(ctx, Float64(cg.strides[d]))
        )
        off = off === nothing ? term : _de_bin(ctx, _hlo.add, off, term)
    end
    off === nothing && return _de_const(ctx, cg.flat[1])
    lin = _de_bin(ctx, _hlo.add, off, _de_const(ctx, 1.0))
    _de_tally!(ctx, :const_gather_computed)
    return _de_untraced(
        Reactant.call_with_reactant(_de_cg_take, cg.flat, _de_traced(lin))
    )
end

_de_bcast_any(v::_DEVal) = v
_de_cg_take(flat::Vector{Float64}, lin::TracedRArray{Float64, 1}) =
    _rx_take(flat, _rx_int(lin))

# ---- the count ---------------------------------------------------------------

const _DE_COUNT_MIRROR = Dict{Symbol, Symbol}(:<= => :>=, :< => :>, :>= => :<=, :> => :<)

# One recognised count: the keys (host values, one per term, in term order),
# the relation with the key on the left (`key REL x`), whether the branches are
# swapped (count where the comparison FAILS), and the query subtree.
struct _DECount{N}
    keys::Vector{Float64}
    rel::Symbol
    neg::Bool
    query::N
end

# Match one term `ifelse(l OP r, b1, b2)`. `keyval(node)` is the node's host
# value or `nothing`; `resolve` as for `_de_count_unrolled`, applied to every
# operand. Returns `(key, rel, neg, query)` or `nothing`.
function _de_count_term(t, keyval::F, resolve::R = identity) where {F, R}
    (t.kind === _E._NK_OP && t.op === :ifelse && length(t.children) == 3) || return nothing
    cond, yes, no = map(resolve, t.children)
    (yes.kind === _E._NK_LITERAL && no.kind === _E._NK_LITERAL) || return nothing
    _de_lanes_uniform(yes) && _de_lanes_uniform(no) || return nothing
    neg = if yes.literal === 1.0 && no.literal === 0.0
        false
    elseif yes.literal === 0.0 && no.literal === 1.0
        true
    else
        return nothing
    end
    (cond.kind === _E._NK_OP && length(cond.children) == 2) || return nothing
    haskey(_DE_COUNT_MIRROR, cond.op) || return nothing
    l, r = map(resolve, cond.children)
    kl, kr = keyval(l), keyval(r)
    if kl !== nothing && kr === nothing
        return (kl, cond.op, neg, r)
    elseif kr !== nothing && kl === nothing
        return (kr, _DE_COUNT_MIRROR[cond.op], neg, l)
    end
    return nothing
end

_de_lanes_uniform(::_E._Node) = true
_de_lanes_uniform(b::_E._OopBatchNode) = isempty(b.lanes_f)

# The terms of an unrolled count: `+(seed, t1, …, tn)` with the seed `+0.0`,
# or a runtime contraction seeded from `+0.0`. `resolve` maps a term that the
# common-subexpression pass replaced by a cache read back to the term it reads.
function _de_count_unrolled(nd, keyval::F, same::G, resolve::H = identity) where {F, G, H}
    kids = if nd.kind === _E._NK_OP && nd.op === :+
        (
            length(nd.children) >= 3 && nd.children[1].kind === _E._NK_LITERAL &&
                _de_lanes_uniform(nd.children[1]) && nd.children[1].literal === 0.0
        ) ||
            return nothing
        @view nd.children[2:end]
    elseif nd.kind === _E._NK_CONTRACTION
        (nd.op === :+ && nd.literal === 0.0 && length(nd.children) >= 2) || return nothing
        nd.children
    else
        return nothing
    end
    first_t = _de_count_term(resolve(kids[1]), keyval, resolve)
    first_t === nothing && return nothing
    _, rel, neg, q = first_t
    keys = Float64[first_t[1]]
    for t in @view kids[2:end]
        m = _de_count_term(resolve(t), keyval, resolve)
        m === nothing && return nothing
        (m[2] === rel && m[3] == neg && same(m[4], q)) || return nothing
        push!(keys, m[1])
    end
    return _DECount(keys, rel, neg, q)
end

# A counted loop over the scalar spine: the query must not read the counter,
# and the key side must be host data at every counter value.
function _de_count_loop(ctx::_DECtx, nd::_E._Node)
    (nd.kind === _E._NK_CONTRACTION_LOOP && nd.op === :+ && nd.literal === 0.0) ||
        return nothing
    spec = nd.payload::_E._ContractLoop
    rng = spec.lo:spec.step:spec.hi
    length(rng) >= 2 || return nothing
    body = nd.children[1]
    (body.kind === _E._NK_OP && body.op === :ifelse && length(body.children) == 3) ||
        return nothing
    cond = body.children[1]
    (cond.kind === _E._NK_OP && length(cond.children) == 2) || return nothing
    l, r = cond.children
    lk, rk = _E._reads_counter(l, spec.ref), _E._reads_counter(r, spec.ref)
    lk == rk && return nothing
    a = lk ? l : r
    _de_static(ctx, a) || return nothing
    keyval(x) = x === a ? _de_hostval(ctx, a) : nothing
    keys = Float64[]
    rel = :none; neg = false; q = nothing
    for kk in rng
        spec.ref[] = kk
        m = _de_count_term(body, keyval)
        m === nothing && return nothing
        push!(keys, m[1]); rel = m[2]; neg = m[3]; q = m[4]
    end
    return _DECount(keys, rel, neg, q)
end

# Emit a recognised count over the query value `qv`.
function _de_emit_count(ctx::_DECtx, c::_DECount, qv::_DEVal)::_DEVal
    n = length(c.keys)
    ks = sort!(filter(!isnan, c.keys))
    m = length(ks)
    cnt = if m == 0
        _de_const(ctx, 0.0)
    else
        prefix = c.rel === :<= || c.rel === :<
        cmp = (c.rel === :<= || c.rel === :>) ? (<=) : (<)
        k = _de_untraced(
            Reactant.call_with_reactant(_de_knot_count, ks, _de_traced(qv), cmp)
        )
        if prefix
            k
        else
            # `#{a >= x}` = m - `#{a < x}` and `#{a > x}` = m - `#{a <= x}` over
            # the non-NaN keys, except that a NaN query satisfies neither.
            rest = _de_bin(ctx, _hlo.subtract, _de_const(ctx, Float64(m)), k)
            pred, L = _de_pred(ctx, "EQ", qv, qv)
            _de_select(ctx, pred, L, rest, _de_const(ctx, 0.0))
        end
    end
    _de_tally!(ctx, :count_fold)
    c.neg || return cnt
    return _de_bin(ctx, _hlo.subtract, _de_const(ctx, Float64(n)), cnt)
end

_de_knot_count(ks::Vector{Float64}, q::TracedRArray{Float64, 1}, cmp::F) where {F} =
    _knot_count(ks, q, cmp)

# Structural sameness of two scalar-spine query subtrees.
function _de_same_node(a::_E._Node, b::_E._Node)::Bool
    a === b && return true
    (a.kind === b.kind && a.op === b.op && length(a.children) == length(b.children)) ||
        return false
    k = a.kind
    if k === _E._NK_LITERAL
        isequal(a.literal, b.literal) || return false
    elseif k === _E._NK_STATE || k === _E._NK_CACHED
        (a.idx == b.idx && a.payload === b.payload) || return false
    elseif k === _E._NK_PARAM
        a.sym === b.sym || return false
    elseif k === _E._NK_TIME
    elseif k === _E._NK_OP
        a.payload === b.payload || return false
    else
        return false
    end
    return all(i -> _de_same_node(a.children[i], b.children[i]), eachindex(a.children))
end

# ---- access-kernel views of the two shapes ------------------------------------

# A key's host value inside an access kernel: a literal, an invariant scalar
# descriptor, a frozen lane table holding one value in every lane, or an
# operator over those.
function _de_acck_keyval(nd::_E._Node, K::_E._AccKernel, plan::_E._OopAccPlan)
    k = nd.kind
    if k === _E._NK_LITERAL
        return nd.literal
    elseif k === _E._NK_ACCESS
        a = K.acc[nd.idx]
        a.kind === _E._AK_SCALAR && return a.v
        vals = plan.consts[nd.idx]
        isempty(vals) && return nothing
        v1 = vals[1]
        all(v -> isequal(v, v1), vals) || return nothing
        return v1
    elseif k === _E._NK_OP && nd.op !== :fn && nd.op !== Symbol("")
        c = Any[]
        for ch in nd.children
            v = _de_acck_keyval(ch, K, plan)
            v === nothing && return nothing
            push!(c, v)
        end
        return Float64(_E._scalar_op(nd.op, c, Float64))
    end
    return nothing
end

# Structural sameness of two access-kernel query subtrees: descriptors compare
# by what they read in every lane, and a cache read by the subtree it caches.
function _de_acck_same(a::_E._Node, b::_E._Node, K::_E._AccKernel, plan::_E._OopAccPlan)
    a === b && return true
    a, b = _de_acck_term(a, K), _de_acck_term(b, K)
    a === b && return true
    (a.kind === b.kind && a.op === b.op && length(a.children) == length(b.children)) ||
        return false
    k = a.kind
    if k === _E._NK_LITERAL
        isequal(a.literal, b.literal) || return false
    elseif k === _E._NK_ACCESS
        if a.idx != b.idx
            da, db = K.acc[a.idx], K.acc[b.idx]
            da.kind === db.kind || return false
            ak = da.kind
            if ak === _E._AK_STATE_FIXED
                da.idx == db.idx || return false
            elseif ak === _E._AK_SCALAR
                isequal(da.v, db.v) || return false
            elseif !isempty(plan.gathers[a.idx]) || !isempty(plan.gathers[b.idx])
                (
                    plan.gathers[a.idx] == plan.gathers[b.idx] &&
                        plan.ghost[a.idx] == plan.ghost[b.idx]
                ) || return false
            elseif !isempty(plan.consts[a.idx]) || !isempty(plan.consts[b.idx])
                isequal(plan.consts[a.idx], plan.consts[b.idx]) || return false
            else
                return false
            end
        end
    elseif k === _E._NK_CACHED
        (a.idx == b.idx && a.payload === b.payload) || return false
    elseif k === _E._NK_PARAM
        a.sym === b.sym || return false
    elseif k === _E._NK_TIME
    elseif k === _E._NK_OP
        a.payload === b.payload || return false
    else
        return false
    end
    return all(
        i -> _de_acck_same(a.children[i], b.children[i], K, plan),
        eachindex(a.children)
    )
end

_de_acck_term(nd::_E._Node, K::_E._AccKernel) =
    nd.kind === _E._NK_CACHED ? something(_de_acck_cached(nd, K), nd) : nd

_de_acck_cached(nd::_E._Node, K::_E._AccKernel) =
    nd.payload === K.cse.scratch ? K.cse.recipes[nd.idx] :
    nd.payload === K.cse.inv_scratch ? K.cse.inv_recipes[nd.idx] : nothing

# A key's host value on the scalar spine.
_de_scalar_keyval(ctx::_DECtx, nd::_E._Node) =
    _de_static(ctx, nd) ? _de_hostval(ctx, nd) : nothing
