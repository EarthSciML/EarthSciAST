# ========================================================================
# Scalar operator ladder and gather-subscript resolution
# ========================================================================
#
# The two pieces of the compiled scalar IR that every consumer of a build shares:
# the ladder that turns an `_NK_OP` node over host values into a value, and the
# resolver that turns a gather subscript into a build-time integer.

# ---- The host op ladder ------------------------------------------------------
#
# Apply `op` to already-evaluated `Float64` operands: the generated ladder of
# `_eval_node_op` (`_op_ladder`, tree_walk/op_ladder.jl) with each operand read
# from `c`. A compiled backend folds a constant subtree through it, so the folded
# value is bit-identical to what `f!` computes for that subtree.
@eval function _scalar_op(op::Symbol, c::AbstractVector)::Float64
    $(
        _op_ladder(
            i -> :(c[$i]), :(length(c)),
            :(throw(_unevaluable_operator(op, "the host op ladder has no arm for it")))
        )
    )
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
# Reached whenever a runtime contraction loop puts a
# loop-var-dependent subscript on the traced RHS, which a mass-weighted column
# integral does as soon as the reduction is long enough to clear
# `ESS_CONTRACTION_LOOP_MIN`.
#
# Deliberately NARROW: exactly the kinds an index expression can contain. Anything
# else is a genuinely state-dependent subscript, which cannot be resolved at trace
# time at all, and says so rather than silently tracing into the same dead end.
# ---- Integer subscript operators -------------------------------------------
#
# A gather subscript is integer arithmetic over loop counters, literals and
# constant tables. Three evaluators compute one: `_eval_const_int` (the document
# tree, at build), `_ix_eval` (a subscript compiled once per box, stencil.jl) and
# `_index_int` (a `_Node` subscript on the out-of-place path). They share this
# table of operators with their arities and the integer meaning of each, so a
# subscript reads the same element on every route. A registry operator keeps its
# registry arity; `mod` has no registry row and is a subscript operator only
# (the run-time gather path, `_subscript_from_counters`, does not admit it).
#
# The rounding rules: `floor(a / b)` and `ceil(a / b)` round the EXACT quotient
# (`fld`/`cld`), as the walker's floating-point value rounds; over an integer
# operand `floor`/`ceil` is the identity. A bare quotient must be exact
# (`_subscript_quotient`): the walker carries a fractional quotient into the
# enclosing arithmetic, so no integer reading of an inexact one agrees with it.
const _SUBSCRIPT_OPS = Dict{String, UnitRange{Int}}(
    "+" => 1:typemax(Int), "*" => 1:typemax(Int), "-" => 1:2, "neg" => 1:1,
    "/" => 2:2, "floor" => 1:1, "ceil" => 1:1, "mod" => 2:2,
    "max" => 2:typemax(Int), "min" => 2:typemax(Int), "ifelse" => 3:3,
    "<" => 2:2, "<=" => 2:2, ">" => 2:2, ">=" => 2:2, "==" => 2:2, "!=" => 2:2,
)
for (_n, _ar) in _SUBSCRIPT_OPS
    _s = _op_spec(_n)
    (_s === nothing || _s.arity == _ar) ||
        error("scalar_ops: subscript operator '$_n' has arity $_ar, the registry $(_s.arity)")
end

# Refuse a subscript operator applied to a count its arity does not admit.
_check_subscript_arity(op::AbstractString, n::Int) =
    n in _SUBSCRIPT_OPS[op] || _throw_op_arity(Symbol(op), n)

@noinline _inexact_subscript_quotient(a::Int, b::Int) = throw(
    TreeWalkError(
        "E_TREEWALK_INEXACT_SUBSCRIPT",
        "a gather subscript divides $(a) by $(b), which is not an integer; an " *
            "integer subscript has no reading of it that agrees with the " *
            "floating-point walk. Round the quotient explicitly " *
            "(`floor(a / b)` or `ceil(a / b)`)."
    )
)

# A bare quotient in a subscript: exact, or refused.
@inline _subscript_quotient(a::Int, b::Int) =
    (b != 0 && rem(a, b) == 0) ? div(a, b) : _inexact_subscript_quotient(a, b)

# The integer meaning of a two-operand subscript operator (`-`, `/`, `mod`, the
# comparisons) and of one step of an n-ary one (`+`, `*`, `max`, `min`).
function _subscript_binop(op::Symbol, x::Int, y::Int)::Int
    op === :+ && return x + y
    op === :* && return x * y
    op === :- && return x - y
    op === :/ && return _subscript_quotient(x, y)
    op === :mod && return mod(x, y)
    op === :max && return max(x, y)
    op === :min && return min(x, y)
    op === :< && return Int(x < y)
    op === :<= && return Int(x <= y)
    op === :> && return Int(x > y)
    op === :>= && return Int(x >= y)
    op === :(==) && return Int(x == y)
    op === :!= && return Int(x != y)
    throw(TreeWalkError("E_TREEWALK_INDEX_NOT_CONST", "'$op' is not an integer subscript operator"))
end

# `floor`/`ceil` of the exact quotient `a / b`.
@inline _subscript_rounded_quotient(op::Symbol, a::Int, b::Int) =
    op === :floor ? fld(a, b) : cld(a, b)

const _SUBSCRIPT_OP_ARITY = Dict{Symbol, UnitRange{Int}}(Symbol(k) => v for (k, v) in _SUBSCRIPT_OPS)

"""
    _subscript_eval_op(op::Symbol, c, ev, quotient) -> Union{Int,Nothing}

Evaluate the subscript operator `op` over the operand list `c`, the one
definition the integer evaluators share: `ev(x)::Int` evaluates an operand, and
`quotient(x)` returns the operand pair of `x` when `x` is a two-operand `/`
(for `floor`/`ceil`), else `nothing`. `ifelse` evaluates only the taken branch.
`nothing` when `op` is not a subscript operator.
"""
function _subscript_eval_op(op::Symbol, c, ev::E, quotient::Q) where {E, Q}
    ar = get(_SUBSCRIPT_OP_ARITY, op, nothing)
    ar === nothing && return nothing
    length(c) in ar || _throw_op_arity(op, length(c))
    if op === :ifelse
        return ev(c[1]) != 0 ? ev(c[2]) : ev(c[3])
    elseif op === :floor || op === :ceil
        q = quotient(c[1])
        q === nothing && return ev(c[1])
        return _subscript_rounded_quotient(op, ev(q[1]), ev(q[2]))
    elseif op === :neg || (op === :- && length(c) == 1)
        return -ev(c[1])
    end
    acc = ev(c[1])
    for i in 2:length(c)
        acc = _subscript_binop(op, acc, ev(c[i]))
    end
    return acc
end

function _index_int(n::_Node, counter = getindex)::Int
    k = n.kind
    if k === _NK_LOOPVAR
        return counter(n.payload::Base.RefValue{Int})
    elseif k === _NK_LITERAL
        return round(Int, n.literal)
    elseif k === _NK_CONST_GATHER || k === _NK_LIVE_GATHER
        # Each subscript is resolved on its OWN axis (`_const_gather_sub`,
        # node.jl): checking only the linearized offset lets an overflow on a
        # non-final axis land inside the array and read a neighbouring element.
        cg = n.payload::_ConstGatherArray
        off = 1
        @inbounds for d in eachindex(n.children)
            sub = _const_gather_sub(cg, d, _index_int(n.children[d], counter))
            off += (sub - 1) * cg.strides[d]
        end
        return round(Int, @inbounds cg.flat[off])
    elseif k === _NK_OP
        v = _subscript_eval_op(
            n.op, n.children, x -> _index_int(x, counter),
            q -> (q.kind === _NK_OP && q.op === :/ && length(q.children) == 2) ? q.children : nothing
        )
        v === nothing || return v
    end
    throw(
        TreeWalkError(
            "E_TREEWALK_TRACED_SUBSCRIPT",
            "an out-of-place gather subscript must resolve to a build-time / " *
                "loop-counter integer, but this one is node kind $(k)" *
                (k === _NK_OP ? " (op $(n.op))" : "") *
                ". A subscript computed from the STATE cannot be resolved while tracing " *
                "— XLA would need the value to pick a slot. Run the interpreted " *
                "evaluator (`form = :inplace`), which resolves it per call."
        )
    )
end
