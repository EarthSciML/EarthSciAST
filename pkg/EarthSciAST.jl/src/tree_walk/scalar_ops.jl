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
# Reached whenever a runtime contraction loop (ess-runtime-contraction) puts a
# loop-var-dependent subscript on the traced RHS, which a mass-weighted column
# integral does as soon as the reduction is long enough to clear
# `ESS_CONTRACTION_LOOP_MIN`.
#
# Deliberately NARROW: exactly the kinds an index expression can contain. Anything
# else is a genuinely state-dependent subscript, which cannot be resolved at trace
# time at all, and says so rather than silently tracing into the same dead end.
@noinline _inexact_subscript_quotient(a::Int, b::Int) = throw(
    TreeWalkError(
        "E_TREEWALK_TRACED_SUBSCRIPT",
        "a gather subscript divides $(a) by $(b), which is not an integer; the " *
            "out-of-place evaluator works in integers and would read a different " *
            "element than the interpreted one. Round the quotient explicitly " *
            "(`floor(a / b)` or `ceil(a / b)`)."
    )
)

function _index_int(n::_Node)::Int
    k = n.kind
    if k === _NK_LOOPVAR
        return (n.payload::Base.RefValue{Int})[]
    elseif k === _NK_LITERAL
        return round(Int, n.literal)
    elseif k === _NK_CONST_GATHER || k === _NK_LIVE_GATHER
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
            # `-` is unary or binary (esm-spec §4.2), as in every other ladder.
            length(c) == 1 && return -_index_int(c[1])
            length(c) == 2 ||
                throw(TreeWalkError("E_TREEWALK_ARITY", "- expects 1 or 2 args"))
            return _index_int(c[1]) - _index_int(c[2])
        elseif op === :*
            s = 1
            @inbounds for d in eachindex(c)
                s *= _index_int(c[d])
            end
            return s
        elseif (op === :floor || op === :ceil) && length(c) == 1
            # A rounded quotient (`floor((c - 1) / NX)`), rounded the way the
            # in-place walk rounds its floating-point value.
            q = c[1]
            if q.kind === _NK_OP && q.op === :/ && length(q.children) == 2
                a, b = _index_int(q.children[1]), _index_int(q.children[2])
                return op === :floor ? fld(a, b) : cld(a, b)
            end
            return _index_int(q)
        elseif op === :/ && length(c) == 2
            # A quotient not under `floor`/`ceil` (a const gather's subscript;
            # a live gather's never has one, `_subscript_from_counters`). The
            # walk carries its floating-point value into the enclosing
            # arithmetic and rounds once at the end, so an integer quotient here
            # can only agree with it when the division is exact.
            a, b = _index_int(c[1]), _index_int(c[2])
            (b != 0 && rem(a, b) == 0) && return div(a, b)
            _inexact_subscript_quotient(a, b)
        end
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
