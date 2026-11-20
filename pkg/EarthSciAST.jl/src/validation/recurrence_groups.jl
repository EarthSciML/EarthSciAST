# Recurrence candidates and groups of a model (esm-spec §4.3.1.1).

# The model's recurrence CANDIDATES among `defs`: array-shaped variables whose
# own defining RHS reads them back through at least one `index` (esm-spec
# §4.3.1.1), well founded or NOT.
#
# CANDIDACY is the gate CONFORMANCE_SPEC §5.19.5 mandates, and both ways of
# getting it wrong lose a diagnosis:
#
#   * Gating on the WELL-FOUNDEDNESS VERDICT is the intuitive choice and is
#     backwards. An ill-founded self-read is by definition not well founded, so
#     the exemption would not apply, so THIS check would fire first and collapse
#     the document to one cycle error — and the `recurrence_not_wellfounded` /
#     `recurrence_unsupported_form` diagnosis the construct exists to produce is
#     never reached. `tests/conformance/recurrence/rejections.json` pins exactly
#     that, across bindings.
#   * Gating on "is this a self-edge at all" is WIDER than candidacy and is the
#     mirror-image mistake: it swallows a scalar `x ~ x + 1` and a bare
#     `s ~ s + 1` over an array, neither of which has an axis to fold along, so
#     neither can ever be a recurrence — they are cycles of length one and MUST
#     keep the cycle diagnosis they have always had.
#
# The predicate is character-for-character the one `_decline_unmaterialized_recurrences`
# (tree_walk/build.jl) uses, which is the point: §5.19.5 asks that the two sites
# agree, not that either be clever.
#
# `templates` is the model's template table: a template reference is read as its
# expansion, through its frame (`recurrence_self_reference_kind`).
function _recurrence_candidate_names(
        model::Model,
        defs::Dict{String, ASTExpr}; templates = nothing
    )::Set{String}
    out = Set{String}()
    for (name, rhs) in defs
        v = get(model.variables, name, nothing)
        (v !== nothing && _recurrence_is_array_shape(v.shape)) || continue
        recurrence_self_reference_kind(name, rhs; templates) === :indexed && push!(out, name)
    end
    return out
end

"""
    recurrence_groups(model::Model; templates = nothing) -> Vector{Set{String}}

The recurrence GROUP candidates of `model` (esm-spec §4.3.1.2): each strongly
connected component of two or more observeds — in the §4.9.6 dependency graph with
every recurrence candidate's self-edge already dropped — whose members are all
array-shaped and whose every internal edge is carried by at least one `index`
read.

This is the predicate the cycle exemption is gated on, never the well-foundedness
verdict (CONFORMANCE_SPEC §5.19.5): a group with an ill-founded read is still a
candidate, so it reaches the named `recurrence_*` diagnosis rather than collapsing
to `observed_cycle`. A component with a scalar member, or one held together by a
bare read, is no candidate and stays a cycle. Shared with the evaluator, which
sweeps each group as its stacked single recurrence (tree_walk/recurrence_group.jl).
With the model's template table `templates`, a template reference is read as
its expansion, its body through its frame, never expanded.
"""
function recurrence_groups(model::Model; templates = nothing)::Vector{Set{String}}
    defs = observed_definitions(model)
    length(defs) < 2 && return Set{String}[]
    observed = Set{String}(keys(defs))
    candidates = _recurrence_candidate_names(model, defs; templates)
    adj = Dict{String, Set{String}}()
    for (name, rhs) in defs
        deps = intersect(_observed_dependency_names(rhs; templates), observed)
        name in candidates && delete!(deps, name)
        adj[String(name)] = deps
    end
    out = Set{String}[]
    for comp in _strongly_connected(adj)
        length(comp) < 2 && continue
        # At least one read inside the component must be OFFSET — not a plain
        # gather whose every index is a bare name. A cycle closed by same-cell
        # gathers alone has no axis to fold along and stays an observed_cycle.
        any(u -> any(v -> _reads_offset(defs[u], v; templates), comp), comp) || continue
        all(
            m -> (
                v = get(model.variables, m, nothing); v !== nothing &&
                    _recurrence_is_array_shape(v.shape)
            ), comp
        ) || continue
        ok = all(comp) do u
            all(v -> v == u || !(v in comp) || _reads_through_index(defs[u], v; templates), adj[u])
        end
        ok && push!(out, comp)
    end
    sort!(out; by = c -> sort!(collect(c)))
    return out
end

# Does `rhs` gather `name` through an `index` with an argument that is not a bare
# name — a read that could be offset along an axis?
_reads_offset(rhs::ASTExpr, name::AbstractString; templates = nothing)::Bool =
    _reads_through_index(rhs, name; templates, offset = true)

# Does `rhs` gather `name` through at least one `index` node (with `offset`, one
# with a subscript that is not a bare name)? A template reference is read as
# its expansion, its body through its frame (`_tpl_step`), a parameter where
# the body reads it.
function _reads_through_index(
        rhs::ASTExpr, name::AbstractString; templates = nothing, offset::Bool = false
    )::Bool
    found = Ref(false)
    seen = Set{Tuple{UInt, UInt}}()
    function walk(e, fr)
        found[] && return
        _tpl_step(walk, templates, e, fr) && return
        e isa OpExpr || return
        k = (objectid(e), fr === nothing ? UInt(0) : objectid(fr))
        k in seen && return
        push!(seen, k)
        if e.op == "index" && !isempty(e.args)
            h, hf = _tpl_leaf(e.args[1], fr)
            if h isa VarExpr && hf === nothing && h.name == name &&
                    (!offset || any(a -> !(first(_tpl_leaf(a, fr)) isa VarExpr), e.args[2:end]))
                found[] = true
                return
            end
        end
        foreach_child(c -> walk(c, fr), e)
        return
    end
    walk(rhs, nothing)
    return found[]
end
