# Shared arms of the reverse (Symbolics → ESM Expr) walks.
#
# Included by BOTH EarthSciASTMTKExt (`_symbolic_to_esm_export`) and
# EarthSciASTCatalystExt (`_catalyst_rate_to_esm`). The walks themselves stay
# per-extension because their coverage deliberately differs — the Catalyst
# rate walk has no derivative branch, no `known_vars` disambiguation, and a
# smaller operator table matched by `==` rather than by a nameof-tolerant
# predicate. Only the arms that were character-identical in both copies live
# here.

"""
    _number_to_esm_literal(x) -> Union{EsmExpr,Nothing}

The scalar fast-path shared by both reverse walks: plain Julia numbers map
to ESM literals (`Bool`/`Integer` → `IntExpr`, floats and other `Real`s →
`NumExpr`); anything non-numeric returns `nothing` for the caller to keep
walking.
"""
function _number_to_esm_literal(x)
    if x isa Bool
        return IntExpr(Int64(x))
    elseif x isa Integer
        return IntExpr(Int64(x))
    elseif x isa AbstractFloat
        return NumExpr(Float64(x))
    elseif x isa Real
        return NumExpr(Float64(x))
    end
    return nothing
end

"""
    _symbolic_const_to_esm(raw) -> Union{EsmExpr,Nothing}

Const-node branch shared by both reverse walks: numeric values (including
those introduced by MTK Constants substitution, e.g. the `-1` produced by
SymbolicUtils' multiplication simplification `-k*x`) appear in the symbolic
tree as BasicSymbolic Const nodes for which `issym`/`iscall` are both false.
`Symbolics.value` extracts the underlying Julia number without touching
variable paths; a non-numeric extraction returns `nothing`.
"""
_symbolic_const_to_esm(raw) = _number_to_esm_literal(Symbolics.value(raw))

"""
    _call_op_to_esm_name(op, table, matches) -> Union{String,Nothing}

Map a symbolic call operation to its ESM op-name string via the ordered
`table` of `(function, name)` pairs, using the extension's `matches(op, fn)`
predicate (`==` for the Catalyst walk; the nameof-tolerant `_op_matches` for
the MTK walk). Returns `nothing` when the operation is outside the table —
callers fall back to their `nameof`-based `OpExpr` arm.
"""
function _call_op_to_esm_name(op, table, matches::Function)
    for (fn, name) in table
        matches(op, fn) && return name
    end
    return nothing
end
