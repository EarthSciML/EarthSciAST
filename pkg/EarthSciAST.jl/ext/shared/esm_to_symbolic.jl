# Shared ESM ASTExpr → Symbolics scalar-interpreter core.
#
# This file is `include`d by BOTH EarthSciASTMTKExt and EarthSciASTCatalystExt
# (each extension module compiles its own copy), so it may only reference
# names both modules have in scope: the ESM expression types (via the
# `EsmExpr` alias each module defines) and Base.
#
# The two extensions deliberately DIVERGE in policy and coverage, and those
# divergences are live behavior — do not unify them here:
# - unknown-variable policy: the MTK lowering THROWS on a variable missing
#   from its dictionaries, while the Catalyst rate lowering AUTO-CREATES a
#   fresh symbol and caches it; hence the `resolve_var` hook.
# - numeric-literal policy: the MTK lowering promotes whole-number NumExpr
#   values to Int (so arrayop index expressions stay integer-typed), the
#   Catalyst one passes them through untouched; hence the `number_value` hook.
# - operator coverage: the Catalyst rate interpreter speaks only the scalar
#   arithmetic/elementary vocabulary; everything else (calculus, arrays,
#   comparisons, `ifelse`, `fn`, …) is routed to `extended_op`, which either
#   lowers it (MTK) or throws that extension's error message (Catalyst).

"""
    _esm_to_symbolic_core(expr, recurse; number_value, resolve_var,
                          unary_ops, extended_op)

Lower the extension-independent scalar arms of an ESM `ASTExpr` — integer /
number / variable leaves; n-ary `+`/`*`, unary or binary `-`, binary `/`/`^`;
the elementwise functions in `unary_ops` (each applied to all of its operands,
so the two-operand `atan(y, x)` keeps both); n-ary `min`/`max` — and recurse
through children via `recurse(child)`. Every other `OpExpr` is delegated to
`extended_op(op, expr)`.

Every `OpExpr` is first checked against the operator registry's arity
(`src/op_registry.jl`): an operand count outside it raises `E_TREEWALK_ARITY`,
the code the tree walk raises for the same node, instead of lowering a
truncated expression.

Hooks (see the file header for why each is a policy point):
- `number_value(v)`: NumExpr-literal policy.
- `resolve_var(name)`: VarExpr resolution policy (throw vs auto-create).
- `unary_ops`: op names lowered as `getfield(Base, Symbol(op))(args...)`.
- `extended_op(op, expr)`: all remaining `OpExpr` arms.
"""
function _esm_to_symbolic_core(
        expr::EsmExpr, recurse::Function;
        number_value::Function,
        resolve_var::Function,
        unary_ops,
        extended_op::Function
    )
    if expr isa IntExpr
        return expr.value
    elseif expr isa NumExpr
        return number_value(expr.value)
    elseif expr isa VarExpr
        return resolve_var(expr.name)
    elseif expr isa OpExpr
        op = expr.op
        _check_registry_arity(op, length(expr.args))
        if op == "+"
            args = [recurse(a) for a in expr.args]
            return length(args) == 1 ? args[1] : sum(args)
        elseif op == "-"
            args = [recurse(a) for a in expr.args]
            return length(args) == 1 ? -args[1] : args[1] - args[2]
        elseif op == "*"
            args = [recurse(a) for a in expr.args]
            return length(args) == 1 ? args[1] : prod(args)
        elseif op == "/"
            return recurse(expr.args[1]) / recurse(expr.args[2])
        elseif op == "^"
            return recurse(expr.args[1])^recurse(expr.args[2])
        elseif op in unary_ops
            fn = getfield(Base, Symbol(op))
            return fn((recurse(a) for a in expr.args)...)
        elseif op == "min" || op == "max"
            fn = op == "min" ? min : max
            return foldl(fn, [recurse(a) for a in expr.args])
        else
            return extended_op(op, expr)
        end
    end
    error("Unknown expression type: $(typeof(expr))")
end

# Raise `E_TREEWALK_ARITY` when `nargs` is outside the registry arity of `op`.
# Operators with no registry row, or whose row records no arity (the
# structural ops), are left to the arm that lowers them.
function _check_registry_arity(op::AbstractString, nargs::Int)
    spec = EarthSciAST._op_spec(op)
    (spec === nothing || spec.arity === nothing) && return nothing
    r = spec.arity
    nargs in r && return nothing
    want = first(r) == last(r) ? string(first(r)) :
        last(r) == typemax(Int) ? "at least $(first(r))" :
        "$(first(r)) to $(last(r))"
    throw(
        EarthSciAST.TreeWalkError(
            "E_TREEWALK_ARITY",
            "$op expects $want operands, got $nargs"
        )
    )
end
