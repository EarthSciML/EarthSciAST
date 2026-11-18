# ========================================================================
# The scalar operator ladder, generated from the operator registry
# ========================================================================
#
# Every evaluator that applies an `_NK_OP` node to numbers (the scalar walker
# `_eval_node_op`, the access-kernel walker `_eval_acc_op`, the host constant
# folder `_scalar_op`) is ONE generated compare-and-branch chain over
# `n.op::Symbol`, built at include time by `_op_ladder` from the registry's
# `shape`, `arity`, `scalar_fn` and `value` columns (`_SHAPED_OPS`,
# src/op_registry.jl). The ladders differ only in how an operand is reached
# (the `operand` callback) and in their last arm (`tail`), so arity, laziness and
# fold order are the same in every one by construction.
#
# Why a generated chain and not a table lookup: a `Dict{Symbol, Function}` lookup
# at run time is a dynamic call whose result boxes, and `Val(op)` dispatch on a
# run-time symbol is dynamic dispatch. The generated chain is the same machine
# code a hand-written `if op === :+ … elseif …` ladder compiles to, so the
# right-hand side stays type-stable and allocation-free (pinned by
# test/tree_walk_allocation_test.jl).
#
# The `^` arm is mechanical only because the walkers' leaves return their native
# `Float64`: a literal exponent stays `Float64` at every value type, so a `Dual`
# walk lands on `Dual^Float64`, the power rule, and never on `Dual^Dual`, whose
# derivative w.r.t. the exponent evaluates `log` of the base and poisons the
# gradient with NaN at a negative base.

# The guard `nargs` in `ar`, as the cheapest comparison that states it.
function _op_arity_guard(op::Symbol, ar::UnitRange{Int}, nargs)
    cond = first(ar) == last(ar) ? :($nargs == $(first(ar))) :
        last(ar) == typemax(Int) ? :($nargs >= $(first(ar))) :
        :($(first(ar)) <= $nargs <= $(last(ar)))
    return :($cond || _throw_op_arity($(QuoteNode(op)), $nargs))
end

# The module-scope function a generated arm calls for a row with a scalar
# function. Splicing the name reproduces the infix form exactly (`a < b` IS
# `(<)(a, b)`); the check below makes a shadowed name a load-time error.
_op_fnsym(s::_OpSpec) = nameof(s.scalar_fn::Function)

for _r in _SHAPED_OPS
    _r.spec.scalar_fn === nothing && continue
    getfield(@__MODULE__, _op_fnsym(_r.spec)) === _r.spec.scalar_fn || error(
        "op_ladder: op '$(_r.name)' does not resolve to its recorded scalar " *
            "function in module scope"
    )
end

# One arm's body: `x(i)` evaluates operand `i` (an `Int` or the loop symbol `:i`),
# `nargs` is the operand count expression.
function _op_arm_body(s::_OpSpec, x, nargs)
    sh = s.shape
    if sh === :fold || sh === :minmax
        f = _op_fnsym(s)
        first_arm = sh === :fold ? :($nargs == 1 && return $(x(1))) : nothing
        return quote
            $first_arm
            acc = $(x(1))
            @inbounds for i in 2:$nargs
                acc = $f(acc, $(x(:i)))
            end
            return acc
        end
    elseif sh === :minus
        return quote
            $nargs == 1 && return -$(x(1))
            return $(x(1)) - $(x(2))
        end
    elseif sh === :negate
        return :(return -$(x(1)))
    elseif sh === :binary
        return :(return $(_op_fnsym(s))($(x(1)), $(x(2))))
    elseif sh === :compare
        return :(return $(_op_fnsym(s))($(x(1)), $(x(2))) ? 1.0 : 0.0)
    elseif sh === :and
        return quote
            for i in 1:$nargs
                $(x(:i)) == 0 && return 0.0
            end
            return 1.0
        end
    elseif sh === :or
        return quote
            for i in 1:$nargs
                $(x(:i)) != 0 && return 1.0
            end
            return 0.0
        end
    elseif sh === :not
        return :(return $(x(1)) == 0 ? 1.0 : 0.0)
    elseif sh === :select
        return :(return $(x(1)) != 0 ? $(x(2)) : $(x(3)))
    elseif sh === :unary
        return :(return $(_op_fnsym(s))($(x(1))))
    elseif sh === :atan
        return quote
            $nargs == 1 && return atan($(x(1)))
            return atan($(x(1)), $(x(2)))
        end
    elseif sh === :constant
        return :(return $(s.value::Float64))
    elseif sh === :passthrough
        return :(return $(x(1)))
    end
    error("op_ladder: no arm template for shape $sh")
end

"""
    _op_ladder(operand, nargs, tail) -> Expr

The operator ladder over the variable `op::Symbol`: one `if op === :name`
arm per shaped registry row, in [`_OP_SHAPES`](@ref) order, each checking the
registry arity (`_throw_op_arity`) and then applying the row's shape. `operand(i)`
returns the expression for operand `i` (an `Int`, or the loop symbol `:i`);
`nargs` is the operand-count expression; `tail` is the last arm, reached for an
op no row matches.

Lazy shapes stay lazy: `ifelse` evaluates only the taken branch and `and`/`or`
stop at the first decisive operand, so an operand from the row's `lazy_from` on
is evaluated only when needed.
"""
function _op_ladder(operand, nargs, tail)
    chain = tail
    for r in reverse(_SHAPED_OPS)
        s = r.spec
        body = quote
            $(_op_arity_guard(r.sym, s.arity::UnitRange{Int}, nargs))
            $(_op_arm_body(s, operand, nargs))
        end
        chain = Expr(:if, :(op === $(QuoteNode(r.sym))), body, chain)
    end
    return chain
end
