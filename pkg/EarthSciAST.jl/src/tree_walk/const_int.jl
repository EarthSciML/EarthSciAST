# tree_walk/const_int.jl — `_eval_const_int`, the build-time integer subscript evaluator.

# Evaluate a purely-arithmetic expression (literals + idx_env bindings + const_array
# lookups) to a concrete Int. Used to resolve index(u, i+1) after loop-var
# substitution, and for indirect gather: u[index(conn, c, k)] where conn is a
# 2D const_array holding neighbor indices.
function _eval_const_int(
        expr::NumExpr, idx_env::AbstractDict{String, Int},
        const_arrays::AbstractDict = _EMPTY_CONST_ARRAYS
    )
    return Int(expr.value)
end
function _eval_const_int(
        expr::IntExpr, idx_env::AbstractDict{String, Int},
        const_arrays::AbstractDict = _EMPTY_CONST_ARRAYS
    )
    return expr.value
end
function _eval_const_int(
        expr::VarExpr, idx_env::AbstractDict{String, Int},
        const_arrays::AbstractDict = _EMPTY_CONST_ARRAYS
    )
    haskey(idx_env, expr.name) ||
        throw(TreeWalkError("E_TREEWALK_UNBOUND_LOOP_VAR", expr.name))
    return idx_env[expr.name]
end
function _eval_const_int(
        expr::OpExpr, idx_env::AbstractDict{String, Int},
        const_arrays::AbstractDict = _EMPTY_CONST_ARRAYS
    )
    # A template call: its body in its frame (call.jl).
    _tpl_is_call(expr) && return _eval_through_call(
        (e, env) -> _eval_const_int(e, env, const_arrays), expr, idx_env
    )
    op = expr.op
    c = expr.args
    # The arithmetic, rounding, clamp (`max`/`min`: a loader reindex clamps a
    # computed cell subscript into the source-grid bounds) and comparison
    # operators: the integer meaning every subscript evaluator shares
    # (`_subscript_eval_op`, scalar_ops.jl).
    v = _subscript_eval_op(
        Symbol(op), c, a -> _eval_const_int(a, idx_env, const_arrays),
        q -> (q isa OpExpr && q.op == "/" && length(q.args) == 2) ? q.args : nothing
    )
    v === nothing || return v
    if op == "const"
        # A scalar `const` literal — what a lowered `enum` op becomes
        # (`_lower_expr_enums`), so a categorical lookup `index(T, enum(…), …)`
        # subscripts with one. It is the `NumExpr` arm above.
        v = expr.value
        (v isa Real && !(v isa Bool)) ||
            throw(
            TreeWalkError(
                "E_TREEWALK_INDEX_NOT_CONST",
                "a non-scalar `const` is not an integer index"
            )
        )
        return Int(v)
    elseif op == "index"
        # Indirect gather: index(const_array_name, i1, i2, ...) → Int
        # Used for mesh connectivity: u[index(cells_on_cell, c, k)] resolves the
        # neighbor index from a pre-computed connectivity array. The table may
        # also be an inline `const` literal, `index({op:const, value:[…]}, i)`,
        # read through the interning the expression-position gather uses
        # (`_intern_inline_const`), so both spellings share one boundary policy.
        isempty(c) && throw(
            TreeWalkError(
                "E_TREEWALK_INDEX_EMPTY",
                "index op in index position requires at least one arg"
            )
        )
        first = c[1]
        if first isa OpExpr && first.op == "const" && first.value isa AbstractVector
            arr, name = _intern_inline_const(first, const_arrays)
        else
            first isa VarExpr ||
                throw(
                TreeWalkError(
                    "E_TREEWALK_INDEX_NOT_CONST",
                    "index op in index position: first arg must be a variable name " *
                        "or an inline `const` array"
                )
            )
            haskey(const_arrays, first.name) ||
                throw(
                TreeWalkError(
                    "E_TREEWALK_INDEX_NOT_CONST",
                    "non-const array '$(first.name)' used in index position; " *
                        "add it to const_arrays or use a state-variable index"
                )
            )
            arr, name = const_arrays[first.name], first.name
        end
        idx_args = c[2:end]
        length(idx_args) == ndims(arr) ||
            throw(
            TreeWalkError(
                "E_TREEWALK_INDEX_NOT_CONST",
                "const array '$(name)' is $(ndims(arr))D but got $(length(idx_args)) indices"
            )
        )
        int_indices = [_eval_const_int(a, idx_env, const_arrays) for a in idx_args]
        for d in 1:ndims(arr)
            int_indices[d] = _resolve_const_index(arr, name, d, int_indices[d], size(arr, d))
        end
        return Int(round(arr[int_indices...]))
    end
    throw(
        TreeWalkError(
            "E_TREEWALK_INDEX_NOT_CONST",
            "cannot evaluate '$(op)' as a constant integer index"
        )
    )
end
