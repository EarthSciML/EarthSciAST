# ============================================================
# Recurrence groups (esm-spec §4.3.1.2) — the stacked reduction
# ============================================================
#
# A recurrence GROUP is several array observeds, each defined by a `faq` over one
# shared cell frame, that read one another — and themselves — only at strictly
# earlier positions along one shared axis. §4.3.1.2 defines its value by a
# reduction: the group is the single §4.3.1.1 recurrence of the members STACKED on
# a trailing member axis `m ∈ 1…M` (members in within-cell order), whose cell body at
# `m = p` is member `p`'s cell body with every `index(V_q, i…)` read of a member
# rewritten to `index(S, i…, q)`; then `V_p[k…] = S[k…, p]`.
#
# `_stack_recurrence_groups` performs that rewrite on the MODEL before anything is
# built, so every route that fills an observed buffer — the per-call fill levels
# and the observed program behind `observed_field` and the inline-test runner —
# sweeps a group through the ONE recurrence implementation they already share
# (recurrence_sweep.jl; CONFORMANCE_SPEC §5.19.3b). Nothing downstream knows a
# group exists, except that `_recurrence_axis` admits a constant index on the
# member axis (`RECURRENCE_MEMBER_SYM`) and nowhere else.
#
# A member's cell body is its `faq` restricted to one cell (§4.3.1.1 point 2):
# the body itself, or — when the member contracts, filters or joins — a scalar
# `faq` over what is left, which the sweep's term resolves like any nested scalar
# reduction. The stacked `faq` and the slices therefore range over the frame axes
# alone; a member's contracted ranges stay inside its own body.

# The stacked model, or `nothing` when `model` has no recurrence group (every
# document that does not use the construct pays one classification pass).
function _stack_recurrence_groups(model::Model, index_sets::AbstractDict)
    groups = recurrence_groups(model)
    isempty(groups) && return nothing
    variables = OrderedDict{String, ModelVariable}(model.variables)
    equations = Equation[eq for eq in model.equations]
    isets = Dict{String, IndexSet}(String(k) => v for (k, v) in index_sets)
    for g in groups
        _stack_one_group!(variables, equations, isets, g)
    end
    stacked = Model(
        variables, equations, model.discrete_events, model.continuous_events,
        model.subsystems;
        tolerance = model.tolerance, tests = model.tests, analyses = model.analyses,
        initialization_equations = model.initialization_equations,
        guesses = model.guesses, system_kind = model.system_kind,
        reference = model.reference
    )
    return stacked, isets
end

_group_refuse(msg) = throw(TreeWalkError("E_TREEWALK_UNSUPPORTED_RECURRENCE", msg))

function _stack_one_group!(
        variables::OrderedDict{String, ModelVariable},
        equations::Vector{Equation},
        isets::Dict{String, IndexSet},
        group::Set{String}
    )
    # Members in equation order first; the within-cell order below then puts
    # them in the order §4.3.1.2 fixes for the member axis. A member is defined
    # either bare, `V ~ faq{output_idx: k…, …}`, or in the indexed-`faq` LHS form
    # `faq{expr: index(V, k…)} ~ body`.
    members = String[]
    eq_idx = Int[]
    for (i, eq) in enumerate(equations)
        t = _recurrence_lhs_target(eq.lhs)
        t === nothing && continue
        name = t[1]
        (name in group && !(name in members)) || continue
        push!(members, name)
        push!(eq_idx, i)
    end
    length(members) == length(group) || _group_refuse(
        "the recurrence group $(sort!(collect(group))) has a member with no defining " *
            "`faq` equation (esm-spec §4.3.1.2)"
    )
    frames = map(zip(members, eq_idx)) do (m, i)
        eq = equations[i]
        unsupported() = _group_refuse(
            "'$m' is a member of a recurrence group but its definition is not one `faq` " *
                "over its cell frame (esm-spec §4.3.1.2)"
        )
        if eq.lhs isa VarExpr
            rhs = eq.rhs
            (
                rhs isa OpExpr && rhs.op == "faq" && rhs.output_idx !== nothing &&
                    !isempty(rhs.output_idx) && rhs.expr_body !== nothing
            ) || unsupported()
            idx = String[string(s) for s in rhs.output_idx]
            ranges = rhs.ranges === nothing ? Dict{String, Any}() : rhs.ranges
            (idx, ranges, _cell_restricted_body(rhs, idx))
        else
            lhs = eq.lhs::OpExpr
            (lhs.output_idx !== nothing && !isempty(lhs.output_idx)) || unsupported()
            idx = String[string(s) for s in lhs.output_idx]
            ranges = lhs.ranges === nothing ? Dict{String, Any}() : lhs.ranges
            # The RHS is the body itself, or — as the indexed-LHS form is usually
            # written — a `faq` over the same frame, restricted to the cell.
            rhs = eq.rhs
            body = if rhs isa OpExpr && rhs.op == "faq" && rhs.output_idx !== nothing &&
                    String[string(s) for s in rhs.output_idx] == idx && rhs.expr_body !== nothing
                _cell_restricted_body(rhs, idx)
            else
                rhs
            end
            (idx, ranges, body)
        end
    end
    # The order §4.3.1.2 fixes for the member axis: a member another reads at
    # the cell being written comes before it (rule 1), ties in equation order.
    idx0 = frames[1][1]
    same_cell(i, j) = _reads_same_cell(frames[i][3], members[j], idx0)
    n = length(members)
    order = Int[]
    while length(order) < n
        nxt = findfirst(
            i -> !(i in order) &&
                all(j -> j == i || !same_cell(i, j) || j in order, 1:n), 1:n
        )
        nxt === nothing && throw(
            TreeWalkError(
                ERROR_CODES.RECURRENCE_NOT_WELLFOUNDED,
                "the members of the recurrence group $(members) read one another at the cell " *
                    "being written in a cycle (esm-spec §4.3.1.2 rule 1)"
            )
        )
        push!(order, nxt)
    end
    first_eq = minimum(eq_idx)
    members = members[order]
    eq_idx = eq_idx[order]
    frames = frames[order]
    idx_names, ranges, _ = frames[1]
    # Each frame axis's range as the validator resolves it (recurrence.jl,
    # `_recurrence_symbol_bounds`), so `{from: lev}` and `[1, 4]` over a 4-element
    # `lev` are one frame here exactly as at validation.
    frame_sig(idx, rng) = Any[_group_frame_range(get(rng, s, nothing), isets) for s in idx]
    sig1 = frame_sig(idx_names, ranges)
    for (m, (idx, rng, _)) in zip(members[2:end], frames[2:end])
        (idx == idx_names && frame_sig(idx, rng) == sig1) ||
            throw(
            TreeWalkError(
                ERROR_CODES.RECURRENCE_GROUP_AXIS_MISMATCH,
                "'$m' and '$(members[1])' form a recurrence group but do not sweep the same " *
                    "cell frame (esm-spec §4.3.1.2)"
            )
        )
    end
    RECURRENCE_MEMBER_SYM in idx_names && _group_refuse(
        "'$RECURRENCE_MEMBER_SYM' is reserved for the member axis of a recurrence group"
    )
    decl = variables[members[1]]
    for m in members[2:end]
        variables[m].shape == decl.shape || throw(
            TreeWalkError(
                ERROR_CODES.RECURRENCE_GROUP_AXIS_MISMATCH,
                "'$m' and '$(members[1])' form a recurrence group but are declared over " *
                    "different shapes (esm-spec §4.3.1.2)"
            )
        )
        variables[m].element_type == decl.element_type || _group_refuse(
            "the members '$m' and '$(members[1])' of a recurrence group declare different " *
                "`element_type`s; this binding sweeps a group at one working precision"
        )
    end

    stacked = "__esm_recurrence_group__" * join(members, "__")
    while haskey(variables, stacked) || haskey(isets, stacked * "__members")
        stacked *= "_"
    end
    member_set = stacked * "__members"
    M = length(members)

    function stack_reads(e::ASTExpr)
        if e isa VarExpr && e.name in members
            throw(
                TreeWalkError(
                    ERROR_CODES.RECURRENCE_NOT_WELLFOUNDED,
                    "'$(e.name)' is read bare inside its recurrence group (esm-spec §4.3.1.2)"
                )
            )
        end
        e isa OpExpr || return e
        if e.op == "index" && !isempty(e.args) && e.args[1] isa VarExpr &&
                (e.args[1]::VarExpr).name in members
            q = findfirst(==((e.args[1]::VarExpr).name), members)
            return OpExpr(
                "index",
                ASTExpr[VarExpr(stacked), (stack_reads(a) for a in e.args[2:end])..., IntExpr(q)]
            )
        end
        return map_children(stack_reads, e)
    end

    # `ifelse(m == 1, body_1, ifelse(m == 2, body_2, … body_M))`: a scalar-
    # conditioned `ifelse`, so only the selected member's body is evaluated.
    body::ASTExpr = stack_reads(frames[M][3])
    for p in (M - 1):-1:1
        body = OpExpr(
            "ifelse",
            ASTExpr[
                OpExpr("==", ASTExpr[VarExpr(RECURRENCE_MEMBER_SYM), IntExpr(p)]),
                stack_reads(frames[p][3]), body,
            ]
        )
    end
    frame_ranges = Dict{String, Any}(s => ranges[s] for s in idx_names if haskey(ranges, s))
    stacked_ranges = Dict{String, Any}(frame_ranges)
    stacked_ranges[RECURRENCE_MEMBER_SYM] = Any[1, M]
    stacked_rhs = OpExpr(
        "faq", ASTExpr[];
        output_idx = Any[idx_names..., RECURRENCE_MEMBER_SYM],
        ranges = stacked_ranges, expr_body = body
    )
    for (p, (m, i)) in enumerate(zip(members, eq_idx))
        slice = OpExpr(
            "faq", ASTExpr[];
            output_idx = Any[idx_names...],
            ranges = Dict{String, Any}(frame_ranges),
            expr_body = OpExpr(
                "index",
                ASTExpr[VarExpr(stacked), (VarExpr(n) for n in idx_names)..., IntExpr(p)]
            )
        )
        equations[i] = Equation(VarExpr(m), slice)
    end
    isets[member_set] = IndexSet("interval"; size = M)
    variables[stacked] = ModelVariable(
        UnknownVariable;
        shape = String[something(decl.shape, String[])..., member_set],
        element_type = decl.element_type,
        description = "the stacked recurrence group $(members) (esm-spec §4.3.1.2), " *
            "introduced by the build"
    )
    insert!(equations, first_eq, Equation(VarExpr(stacked), stacked_rhs))
    return nothing
end

# The `faq` `rhs` restricted to one cell of its frame `idx` (esm-spec §4.3.1.1
# point 2): its body, or — when ranges other than the frame's are left to
# contract, or a filter or join gates the terms — a scalar `faq` over those, with
# its reduction, filter and join intact.
function _cell_restricted_body(rhs::OpExpr, idx::Vector{String})
    ranges = rhs.ranges === nothing ? Dict{String, Any}() : rhs.ranges
    remaining = Dict{String, Any}(k => v for (k, v) in ranges if !(String(k) in idx))
    gated = rhs.filter !== nothing || rhs.join !== nothing || rhs.key !== nothing ||
        rhs.distinct === true
    (isempty(remaining) && !gated) && return rhs.expr_body::ASTExpr
    return reconstruct(rhs; output_idx = Any[], ranges = remaining)
end

# One frame axis's range for the group frame comparison: its bounds when an
# interval or a dense index set proves them, the authored spec otherwise.
function _group_frame_range(spec, isets::AbstractDict)
    spec === nothing && return nothing
    b = _recurrence_symbol_bounds(spec, isets)
    return b === nothing ? repr(spec) : b
end

# Does `e` read member `peer` at the cell being written — `index(peer, k…)` with
# every index the bare frame symbol of its axis?
function _reads_same_cell(e::ASTExpr, peer::String, idx_names::Vector{String})::Bool
    found = Ref(false)
    foreach_subexpr_once(e) do x
        found[] && return nothing
        if x isa OpExpr && x.op == "index" && length(x.args) == length(idx_names) + 1 &&
                x.args[1] isa VarExpr && (x.args[1]::VarExpr).name == peer &&
                all(
                d -> x.args[d + 1] isa VarExpr && (x.args[d + 1]::VarExpr).name == idx_names[d],
                1:length(idx_names)
            )
            found[] = true
        end
        return nothing
    end
    return found[]
end
