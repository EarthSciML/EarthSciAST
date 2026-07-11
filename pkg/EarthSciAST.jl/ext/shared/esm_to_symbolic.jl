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
number / variable leaves; n-ary `+`/`-`/`*` and binary `/`/`^`; the
mechanical unary elementwise ops in `unary_ops`; n-ary `min`/`max` — and
recurse through children via `recurse(child)`. Every other `OpExpr` is
delegated to `extended_op(op, expr)`.

Hooks (see the file header for why each is a policy point):
- `number_value(v)`: NumExpr-literal policy.
- `resolve_var(name)`: VarExpr resolution policy (throw vs auto-create).
- `unary_ops`: op names lowered as `getfield(Base, Symbol(op))(arg)`.
- `extended_op(op, expr)`: all remaining `OpExpr` arms.
"""
function _esm_to_symbolic_core(expr::EsmExpr, recurse::Function;
                               number_value::Function,
                               resolve_var::Function,
                               unary_ops,
                               extended_op::Function)
    if expr isa IntExpr
        return expr.value
    elseif expr isa NumExpr
        return number_value(expr.value)
    elseif expr isa VarExpr
        return resolve_var(expr.name)
    elseif expr isa OpExpr
        op = expr.op
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
            l = recurse(expr.args[1])
            r = recurse(expr.args[2])
            return l / r
        elseif op == "^"
            l = recurse(expr.args[1])
            r = recurse(expr.args[2])
            return l^r
        elseif op in unary_ops
            arg = recurse(expr.args[1])
            fn = getfield(Base, Symbol(op))
            return fn(arg)
        elseif op == "min" || op == "max"
            length(expr.args) < 2 && throw(ArgumentError(
                "$op requires at least 2 arguments (esm-spec §4.2)"))
            args = [recurse(a) for a in expr.args]
            fn = op == "min" ? min : max
            # Left fold, matching both pre-dedup copies (`foldl` in the MTK
            # arm; `reduce` in the Catalyst arm — identical for a Vector).
            return foldl(fn, args)
        else
            return extended_op(op, expr)
        end
    end
    error("Unknown expression type: $(typeof(expr))")
end
