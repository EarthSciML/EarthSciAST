# ── Pre-build rewrite-target gate (esm-spec §9.6.3 constraint 6) ──
#
# "Before a component is EVALUATED or COMPILED for simulation, its expression
# trees are walked; any node whose `op` is not in the evaluable-core set (§4.2)
# … is rejected with diagnostic `unlowered_operator`."
#
# `_compile`'s own gate (compile.jl) refuses an unlowered op in every tree it
# compiles, but the build discards some trees before compiling anything: a DEAD
# observed is never compiled, and `_fold_elementwise_array_observeds` folds an
# elementwise array observed into its readers and drops it. This walk runs over the model's
# equations at the build entry, ahead of every such pass, so the answer is a
# property of the document rather than of which trees the build kept.
#
# It gates rewrite-target OPS, not deadness: a dead observed whose body is fully
# lowered is untouched (CONFORMANCE_SPEC §5.27.3).

# The rewrite-target tier is `_op_in_T`, the same predicate `_compile`'s gate
# uses, less two members this walk cannot judge by name: `D` (core in its
# equation-LHS role, handled below) and `enum` (lowered at load; `_compile`
# reports a surviving one as `unevaluable_operator`).
_is_unlowered_op(op::String) =
    _op_in_T(op) && !(op in ("D", "enum"))

# The first (pre-order) node of `e` outside the evaluable core, or `nothing`.
# `lhs` marks an equation left-hand side, the one position where a time `D` is
# core; it propagates to children, so a `D` under an LHS `faq` stays structural.
# `seen` is shared across calls for the same side: the build's trees are
# structurally shared DAGs, and a node already walked in that role is clean.
function _first_unlowered_node(e::ASTExpr, lhs::Bool, seen::IdDict{OpExpr, Nothing})
    e isa OpExpr || return nothing
    o = e::OpExpr
    haskey(seen, o) && return nothing
    seen[o] = nothing
    if o.op == "D"
        (lhs && (o.wrt === nothing || o.wrt == "t")) || return o
    elseif _is_unlowered_op(o.op)
        return o
    elseif _tpl_is_call(o) && _call_table() !== nothing &&
            _call_body_any_op(op -> op == "D" || _is_unlowered_op(op), o)
        # A template call evaluates its body, where no `D` is an equation's
        # left-hand side (call.jl `_call_body_any_op`, each template once).
        return o
    end
    found = nothing
    EarthSciAST.foreach_child(o) do c
        found === nothing && (found = _first_unlowered_node(c, lhs, seen))
    end
    return found
end

function _reject_unlowered_operators(
        model::Model,
        seen_lhs::IdDict{OpExpr, Nothing} = IdDict{OpExpr, Nothing}(),
        seen_rhs::IdDict{OpExpr, Nothing} = IdDict{OpExpr, Nothing}()
    )
    for eq in model.equations
        node = _first_unlowered_node(eq.lhs, true, seen_lhs)
        node === nothing && (node = _first_unlowered_node(eq.rhs, false, seen_rhs))
        node === nothing && continue
        wrt = node.op == "D" && node.wrt !== nothing ? " (wrt=$(node.wrt))" : ""
        what = "'$(node.op)'$wrt"
        if _tpl_is_call(node)
            # Name the op the body holds and the template the reference names
            # (esm-spec §9.6.3 constraint 6).
            ct = _call_table()
            ops = ct === nothing ? String[] : sort!(
                collect(
                    _call_body_ops!(
                        _tpl_memo(ct.tt, nothing, :body_ops, () -> Dict{String, Set{String}}()),
                        ct.tt, String(node.name)
                    )
                )
            )
            i = findfirst(op -> op == "D" || _is_unlowered_op(op), ops)
            what = "'$(i === nothing ? node.op : ops[i])' in the body of template " *
                "'$(node.name)' (or one it references), reached from a reference"
        end
        throw(
            TreeWalkError(
                ERROR_CODES.UNLOWERED_OPERATOR,
                "unlowered rewrite-target operator $what in the equation for " *
                    "$(eq.lhs): no rewrite rule lowered it before evaluation (esm-spec §9.6.3 " *
                    "constraint 6 / §9.6.8). The gate walks every equation, including an " *
                    "observed nothing reads."
            )
        )
    end
    for sub in values(model.subsystems)
        sub isa Model && _reject_unlowered_operators(sub, seen_lhs, seen_rhs)
    end
    return nothing
end
