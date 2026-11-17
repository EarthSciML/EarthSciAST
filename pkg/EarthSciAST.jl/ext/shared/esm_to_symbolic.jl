# Shared ESM ASTExpr → Symbolics scalar-interpreter core.
#
# This file is `include`d by BOTH EarthSciASTMTKExt and EarthSciASTCatalystExt
# (each extension module compiles its own copy), so it may only reference
# names both modules have in scope: the ESM expression types (via the
# `EsmExpr` alias each module defines), Symbolics' `ifelse` (Base) and Base.
#
# The scalar operator vocabulary is the operator registry's
# (`EarthSciAST._SHAPED_OPS`, src/op_registry.jl): every shaped row whose meaning
# on Symbolics values is its registry function lowers here, for both
# extensions, after the registry arity check. The two extensions differ only
# in policy, through the hooks:
# - unknown-variable policy: the MTK lowering THROWS on a variable missing
#   from its dictionaries, while the Catalyst rate lowering AUTO-CREATES a
#   fresh symbol and caches it; hence the `resolve_var` hook.
# - numeric-literal policy: the MTK lowering promotes whole-number NumExpr
#   values to Int (so arrayop index expressions stay integer-typed), the
#   Catalyst one passes them through untouched; hence the `number_value` hook.
# - everything outside the scalar vocabulary (calculus, `Pre`, the array
#   vocabulary, `const`) goes to `extended_op`, which lowers it (MTK) or throws
#   that extension's error (Catalyst).

# The registry shapes this core lowers. `and`/`or`/`not` are not among them: the
# registry gives them the 1.0/0.0 truth-value convention, while a Symbolics
# comparison is a symbolic Boolean, so no faithful lowering mixes the two.
# `Pre` is the ModelingToolkit previous-value marker (its `extended_op`).
const _SYMBOLIC_SHAPES = (
    :fold, :minus, :negate, :binary, :unary, :atan, :minmax, :constant,
    :compare, :select,
)

# Every operator name this core lowers.
const _SYMBOLIC_SCALAR_OPS = Set{String}(
    r.name for r in EarthSciAST._SHAPED_OPS if r.spec.shape in _SYMBOLIC_SHAPES
)

"""
    _esm_to_symbolic_core(expr, recurse; number_value, resolve_var, extended_op)

Lower an ESM `ASTExpr` to Symbolics: integer / number / variable leaves, and
every registry operator of a shape in `_SYMBOLIC_SHAPES`, applying the row's
scalar function (an n-ary `+`/`*`/`min`/`max` folds every operand; `atan(y, x)`
keeps both). Children are lowered through `recurse(child)`; every other
`OpExpr` is delegated to `extended_op(op, expr)`.

Every `OpExpr` is first checked against the operator registry's arity
(`EarthSciAST._check_op_arity`): an operand count outside it raises
`E_TREEWALK_ARITY`, the error the tree walk raises for the same node.
"""
function _esm_to_symbolic_core(
        expr::EsmExpr, recurse::Function;
        number_value::Function,
        resolve_var::Function,
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
        n = length(expr.args)
        EarthSciAST._check_op_arity(Symbol(op), n)
        op in _SYMBOLIC_SCALAR_OPS || return extended_op(op, expr)
        s = EarthSciAST._op_spec(op)
        sh = s.shape
        sh === :constant && return s.value
        args = [recurse(a) for a in expr.args]
        if sh === :fold || sh === :minmax
            return n == 1 ? args[1] : foldl(s.scalar_fn, args)
        elseif sh === :minus
            return n == 1 ? -args[1] : args[1] - args[2]
        elseif sh === :negate
            return -args[1]
        elseif sh === :select
            return ifelse(args[1], args[2], args[3])
        elseif sh === :atan
            return atan(args...)
        end
        # :binary, :unary, :compare — the registry function on every operand.
        return s.scalar_fn(args...)
    end
    error("Unknown expression type: $(typeof(expr))")
end
