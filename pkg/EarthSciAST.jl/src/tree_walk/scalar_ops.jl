# ========================================================================
# Scalar operator ladder and gather-subscript resolution
# ========================================================================
#
# The two pieces of the compiled scalar IR that every consumer of a build shares:
# the ladder that turns an `_NK_OP` node into a value, and the resolver that
# turns a gather subscript into a build-time integer. A compiled backend folds
# constant subtrees through the ladder at Float64, in the arm order
# test/scalar_ops_test.jl pins against the scalar walker, so a folded subtree
# matches what `f!` computes for it.

# ---- The shared op ladder ---------------------------------------------------
#
# The mechanical unary arms (`sin` … `ceil`), GENERATED from the op-registry table
# exactly as `_eval_acc_op`'s matching arms (access_kernel.jl) are, so a unary op added
# to the registry reaches every ladder (scalar / shared / access-kernel) at once.
# `nothing` ⇒ not a mechanical unary op ⇒ the caller's ladder falls through. The
# comparison / binary / min-max probes below follow the same protocol from their
# own registry tables.
let arms = :(return nothing)
    for row in reverse(_UNARY_ELEMENTWISE_OPS)
        arms = Core.Expr(:if, :(op === $(QuoteNode(row.sym))),
                         quote
                             _expect_arity_n(op, c, 1)
                             return $(row.sym).(c[1])
                         end,
                         arms)
    end
    @eval @inline function _unary_elementwise(op::Symbol, c::AbstractVector)
        $arms
    end
end

# The comparison arms (`<` … `!=` → 1/0 in the value type), GENERATED from
# `_COMPARISON_ELEMENTWISE_OPS` the same way. A comparison is piecewise
# constant, so `one(T)`/`zero(T)` carry the correct (zero) derivative under AD.
# `$(fnsym).(a, b)` is broadcast sugar for the hand-written infix `a .< b`, so
# the fused blend is unchanged.
let arms = :(return nothing)
    for row in reverse(_COMPARISON_ELEMENTWISE_OPS)
        arms = Core.Expr(:if, :(op === $(QuoteNode(row.sym))),
                         quote
                             _expect_arity_n(op, c, 2)
                             return ifelse.($(row.fnsym).(c[1], c[2]), one(T), zero(T))
                         end,
                         arms)
    end
    @eval @inline function _comparison(op::Symbol, c::AbstractVector,
                                           ::Type{T}) where {T}
        $arms
    end
end

# The fixed-2-ary elementwise arms (`/`, `^`, `pow`, `atan2`), GENERATED from
# `_BINARY_ELEMENTWISE_OPS`. NB the `^` arm here is only the FALLBACK for a
# malformed arity: a well-formed 2-ary `^`/`pow` is intercepted upstream by
# the walkers' literal-exponent arms (`_eval_node_op`, `_eval_acc_op`) and never
# reaches the shared ladder: a literal exponent must stay a host `Float64` so a
# Dual walk keeps the power rule.
let arms = :(return nothing)
    for row in reverse(_BINARY_ELEMENTWISE_OPS)
        arms = Core.Expr(:if, :(op === $(QuoteNode(row.sym))),
                         quote
                             _expect_arity_n(op, c, 2)
                             return $(row.fnsym).(c[1], c[2])
                         end,
                         arms)
    end
    @eval @inline function _binary_elementwise(op::Symbol, c::AbstractVector)
        $arms
    end
end

# The n-ary `min`/`max` folds (arity ≥ 2), GENERATED from `_NARY_MINMAX_OPS` —
# same guard and fold order as the in-place ladders.
let arms = :(return nothing)
    for row in reverse(_NARY_MINMAX_OPS)
        arms = Core.Expr(:if, :(op === $(QuoteNode(row.sym))),
                         quote
                             length(c) < 2 && throw(TreeWalkError("E_TREEWALK_ARITY",
                                 $(row.name * " needs ≥2 args")))
                             r = $(row.fnsym).(c[1], c[2])
                             for i in 3:length(c)
                                 r = $(row.fnsym).(r, c[i])
                             end
                             return r
                         end,
                         arms)
    end
    @eval @inline function _minmax(op::Symbol, c::AbstractVector)
        $arms
    end
end

# Apply `op` to already-evaluated children. Every arm broadcasts, so `c` may hold
# scalars (the scalar walker), arrays (the access-kernel lane walker), or a mix — and the
# fold ORDER matches `_eval_node_op` / `_eval_acc_op` arm for arm, which is what
# keeps a Float64 run of this emitter bit-identical to `f!`.
function _scalar_op(op::Symbol, c::AbstractVector, ::Type{T}) where {T}
    if op === :+
        length(c) == 1 && return c[1]
        r = c[1] .+ c[2]
        for i in 3:length(c)
            r = r .+ c[i]
        end
        return r
    elseif op === :*
        length(c) == 1 && return c[1]
        r = c[1] .* c[2]
        for i in 3:length(c)
            r = r .* c[i]
        end
        return r
    elseif op === :-
        length(c) == 1 && return .-c[1]
        length(c) == 2 && return c[1] .- c[2]
        throw(TreeWalkError("E_TREEWALK_ARITY", "- expects 1 or 2 args"))
    elseif op === :neg
        _expect_arity_n(op, c, 1)
        return .-c[1]
    # Fixed-2-ary elementwise (`/`, `^`, `pow`, `atan2`) — GENERATED from the
    # registry (`_binary_elementwise` above). The probe sits where `/` sat.
    elseif (bin = _binary_elementwise(op, c)) !== nothing
        return bin

    # Comparisons → 1/0 in the value type — GENERATED from the registry
    # (`_comparison` above, where the piecewise-constant AD note lives).
    elseif (cmp = _comparison(op, c, T)) !== nothing
        return cmp

    # Logical — folded (not short-circuited), matching `_eval_acc_op`; every child
    # is evaluated either way, so the values agree with the scalar arm too.
    elseif op === :and
        r = one(T)
        for a in eachindex(c)
            r = ifelse.((r .!= 0) .& (c[a] .!= 0), one(T), zero(T))
        end
        return r
    elseif op === :or
        r = zero(T)
        for a in eachindex(c)
            r = ifelse.((r .!= 0) .| (c[a] .!= 0), one(T), zero(T))
        end
        return r
    elseif op === :not
        _expect_arity_n(op, c, 1)
        return ifelse.(c[1] .== 0, one(T), zero(T))
    elseif op === :ifelse
        _expect_arity_n(op, c, 3)
        return ifelse.(c[1] .!= 0, c[2], c[3])

    elseif (unary = _unary_elementwise(op, c)) !== nothing
        return unary
    elseif op === :atan
        length(c) == 1 && return atan.(c[1])
        length(c) == 2 && return atan.(c[1], c[2])
        throw(TreeWalkError("E_TREEWALK_ARITY", "atan expects 1 or 2 args"))
    # n-ary min/max (arity ≥ 2) — GENERATED from the registry (`_minmax`
    # above). (`atan2` is handled by the binary probe near the ladder top.)
    elseif (mm = _minmax(op, c)) !== nothing
        return mm

    elseif op === :pi || op === :π
        return T(pi)
    elseif op === :e
        return T(ℯ)
    elseif op === :Pre
        _expect_arity_n(op, c, 1)
        return c[1]
    else
        throw(_unevaluable_operator(op, "the shared op ladder has no arm for it"))
    end
end

# Evaluate an INDEX subtree to a concrete `Int`.
#
# WHY THIS IS NOT THE VALUE LADDER. A gather's subscripts are integer index
# arithmetic over enclosing loop counters and literals — they never read the
# state. Evaluating them through the value ladder would return the RHS's value
# type, so under a trace a loop counter comes back as a `TracedRNumber` holding
# a constant and everything downstream inherits it: `round(Int, ·)` stays traced,
# and the ghost-bounds test `lo <= sub <= hi` then throws "non-boolean
# (TracedRNumber{Bool}) used in boolean context" — a control decision XLA cannot
# make, on a quantity that was concrete all along.
#
# Reached whenever a runtime contraction loop (ess-runtime-contraction) puts a
# loop-var-dependent subscript on the traced RHS, which a mass-weighted column
# integral does as soon as the reduction is long enough to clear
# `ESS_CONTRACTION_LOOP_MIN`.
#
# Deliberately NARROW: exactly the kinds an index expression can contain. Anything
# else is a genuinely state-dependent subscript, which cannot be resolved at trace
# time at all, and says so rather than silently tracing into the same dead end.
function _index_int(n::_Node)::Int
    k = n.kind
    if k === _NK_LOOPVAR
        return (n.payload::Base.RefValue{Int})[]
    elseif k === _NK_LITERAL
        return round(Int, n.literal)
    elseif k === _NK_CONST_GATHER
        # Each subscript is resolved on its OWN axis (`_const_gather_sub`,
        # compile.jl): checking only the linearized offset lets an overflow on a
        # non-final axis land inside the array and read a neighbouring element.
        cg = n.payload::_ConstGatherArray
        off = 1
        @inbounds for d in eachindex(n.children)
            sub = _const_gather_sub(cg, d, _index_int(n.children[d]))
            off += (sub - 1) * cg.strides[d]
        end
        return round(Int, @inbounds cg.flat[off])
    elseif k === _NK_OP
        op = n.op
        c = n.children
        if op === :+
            s = 0
            @inbounds for d in eachindex(c)
                s += _index_int(c[d])
            end
            return s
        elseif op === :-
            length(c) == 1 && return -_index_int(c[1])
            return _index_int(c[1]) -
                   _index_int(c[2])
        elseif op === :*
            s = 1
            @inbounds for d in eachindex(c)
                s *= _index_int(c[d])
            end
            return s
        elseif op === :/
            return div(_index_int(c[1]),
                       _index_int(c[2]))
        end
    end
    throw(TreeWalkError("E_TREEWALK_TRACED_SUBSCRIPT",
        "an out-of-place gather subscript must resolve to a build-time / " *
        "loop-counter integer, but this one is node kind $(k)" *
        (k === _NK_OP ? " (op $(n.op))" : "") *
        ". A subscript computed from the STATE cannot be resolved while tracing " *
        "— XLA would need the value to pick a slot. Run the interpreted " *
        "evaluator (`form = :inplace`), which resolves it per call."))
end
