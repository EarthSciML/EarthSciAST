# ── Pre-build rewrite-target gate (esm-spec §9.6.3 constraint 6) ──
#
# "Before a component is EVALUATED or COMPILED for simulation, its expression
# trees are walked; any node whose `op` is not in the evaluable-core set (§4.2)
# … is rejected with diagnostic `unlowered_operator`."
#
# `_compile`'s own gate (compile.jl) refuses an unlowered op in every tree it
# compiles, but the build discards some trees before compiling anything: a DEAD
# observed is never compiled, and `_fold_elementwise_array_observeds` folds an
# elementwise array observed into its readers and drops it. A rewrite-target op
# in one of those used to build silently. This walk runs over the model's
# equations at the build entry, ahead of every such pass, so the answer is a
# property of the document rather than of which trees the build kept.
#
# It gates rewrite-target OPS, not deadness: a dead observed whose body is fully
# lowered is untouched (CONFORMANCE_SPEC §5.27.3).

# The rewrite-target tier is `_op_in_T`, the same predicate `_compile`'s gate
# uses, less three members this walk cannot judge by name: `D` (core in its
# equation-LHS role, handled below), `table_lookup` (lowered further into the
# build), and `enum` (lowered at load; `_compile` reports a surviving one as
# `unevaluable_operator`).
_is_unlowered_op(op::String) =
    _op_in_T(op) && !(op in ("D", "table_lookup", "enum"))

# The first (pre-order) node of `e` outside the evaluable core, or `nothing`.
# `lhs` marks an equation left-hand side, the one position where a time `D` is
# core; it propagates to children, so a `D` under an LHS `faq` stays structural.
# `seen` is shared across calls for the same side: the build's trees are
# structurally shared DAGs, and a node already walked in that role is clean.
function _first_unlowered_node(e::ASTExpr, lhs::Bool, seen::IdDict{OpExpr,Nothing})
    e isa OpExpr || return nothing
    o = e::OpExpr
    haskey(seen, o) && return nothing
    seen[o] = nothing
    if o.op == "D"
        (lhs && (o.wrt === nothing || o.wrt == "t")) || return o
    elseif _is_unlowered_op(o.op)
        return o
    end
    found = nothing
    EarthSciAST.foreach_child(o) do c
        found === nothing && (found = _first_unlowered_node(c, lhs, seen))
    end
    return found
end

function _reject_unlowered_operators(model::Model,
                                     seen_lhs::IdDict{OpExpr,Nothing}=IdDict{OpExpr,Nothing}(),
                                     seen_rhs::IdDict{OpExpr,Nothing}=IdDict{OpExpr,Nothing}())
    for eq in model.equations
        node = _first_unlowered_node(eq.lhs, true, seen_lhs)
        node === nothing && (node = _first_unlowered_node(eq.rhs, false, seen_rhs))
        node === nothing && continue
        wrt = node.op == "D" && node.wrt !== nothing ? " (wrt=$(node.wrt))" : ""
        throw(TreeWalkError(ERROR_CODES.UNLOWERED_OPERATOR,
            "unlowered rewrite-target operator '$(node.op)'$wrt in the equation for " *
            "$(eq.lhs): no rewrite rule lowered it before evaluation (esm-spec §9.6.3 " *
            "constraint 6 / §9.6.8). The gate walks every equation, including an " *
            "observed nothing reads."))
    end
    for sub in values(model.subsystems)
        sub isa Model && _reject_unlowered_operators(sub, seen_lhs, seen_rhs)
    end
    return nothing
end
