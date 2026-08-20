# Dot-namespacing and per-system collection: flatten steps 1+2 (spec §4.7.5).
# Rewrites every component-local reference to `<prefix>.<name>` and collects
# each Model / ReactionSystem's variables, equations, and events into the
# flattener accumulators. Split from flatten.jl.

using OrderedCollections: OrderedDict

# ========================================
# Namespacing
# ========================================

"""
    namespace_expr(expr, prefix, local_names) -> ASTExpr

Return a new ASTExpr tree with every VarExpr referencing a name in `local_names`
rewritten as `"<prefix>.<name>"`. For dotted names (e.g. `Sub.var`), the first
segment is treated as the local symbol: if it is in `local_names` (a local
subsystem), the whole dotted path is prefixed; otherwise the reference is
already external and is left unchanged. Numeric literals are unchanged.

Index-set references (`shape` entries, `ranges[*]` `{from}`, producer `id`s)
are NOT namespaced: as of esm-spec v0.8.0 index sets are a single
document-scoped registry with plain names shared by every component. (A former
`idx_names` parameter that could opt component-local index identifiers into
prefixing was dead — every caller passed it empty — and has been removed.)
"""
function namespace_expr(expr::NumExpr, prefix::String,
                        local_names::Set{String})::ASTExpr
    return expr
end

function namespace_expr(expr::IntExpr, prefix::String,
                        local_names::Set{String})::ASTExpr
    return expr
end

function namespace_expr(expr::VarExpr, prefix::String,
                        local_names::Set{String})::ASTExpr
    if occursin('.', expr.name)
        first_part = String(split(expr.name, '.')[1])
        if first_part in local_names
            return VarExpr("$(prefix).$(expr.name)")
        end
        return expr
    end
    if expr.name in local_names
        return VarExpr("$(prefix).$(expr.name)")
    end
    return expr
end

# Identity-memoized recursion arms: prefixing is a pure function of the node
# (prefix and local_names are traversal-constant), so a subtree shared under
# many parents — template expansion stores expanded ASTs as shared DAGs — is
# rewritten ONCE and the shared result respliced. Without the memo a rewrite
# that touches every leaf (the common case here: every local reference gets
# the prefix) re-materializes a shared DAG as an exponential tree.
_namespace_expr(e::NumExpr, ::String, ::Set{String}, ::IdDict{OpExpr,ASTExpr}) = e
_namespace_expr(e::IntExpr, ::String, ::Set{String}, ::IdDict{OpExpr,ASTExpr}) = e
_namespace_expr(e::VarExpr, prefix::String, local_names::Set{String},
                ::IdDict{OpExpr,ASTExpr}) =
    namespace_expr(e, prefix, local_names)

# Namespace a value-equality `join`'s key-column names (RFC §5.3). A join column
# may name a value-invention MAP buffer that IS a component-local variable — the
# conservative regridder's `join.on [[rg_src_bin, rg_tgt_bin]]` gates on the
# per-cell bin buffers, which are ordinary local `state` variables. Like any
# other local reference these must be rewritten to `<prefix>.<name>` so they
# resolve against the namespaced buffer keys after merge (the join resolver and
# the value-invention front-door key their maps by the namespaced LHS). A column
# naming a range symbol / index-set member is not a local variable and passes
# through unchanged — the SAME rule `namespace_expr` applies to a `VarExpr`.
#
# `binders` are the loop symbols THIS node binds (`output_idx` entries and
# `ranges` keys) and they WIN over `local_names`: an index symbol is local to the
# enclosing `aggregate` and shadows any coincident variable name (esm-spec
# §4.3.1 — "a given string can be a variable reference in most contexts but
# serves as an index symbol inside `aggregate.output_idx`, `aggregate.expr`, and
# `aggregate.ranges` keys"), and an `on` key column is resolved against this
# node's own ranges (`_vi_join_index_sym`, `_join_sym_for_key`) — so prefixing a
# shadowed symbol makes it resolve to nothing. Without this the gate mis-fires on
# the legal case of a component declaring a variable named like a loop symbol.
function _namespace_join(join, binders::Set{String}, prefix::String,
                         local_names::Set{String})
    join === nothing && return nothing
    nsname(n) = begin
        s = String(n)
        if s in binders
            s
        elseif occursin('.', s)
            String(split(s, '.')[1]) in local_names ? "$(prefix).$(s)" : s
        elseif s in local_names
            "$(prefix).$(s)"
        else
            s
        end
    end
    # A `join.overlap` clause (Phase 2a) namespaces its envelope FACTOR names the
    # same way (a component-local coord/rect buffer gets the prefix); `eps` is a
    # scalar and never rewrites. A bin-equality clause namespaces its key columns.
    nsclause(clause::_OverlapJoinSpec) = _OverlapJoinSpec(
        String[nsname(n) for n in clause.src_env],
        String[nsname(n) for n in clause.tgt_env], clause.eps)
    nsclause(clause) = Tuple{String,String}[(nsname(l), nsname(r)) for (l, r) in clause]
    return Any[nsclause(clause) for clause in join]
end

function namespace_expr(expr::OpExpr, prefix::String,
                        local_names::Set{String})::ASTExpr
    return _namespace_expr(expr, prefix, local_names, IdDict{OpExpr,ASTExpr}())
end

function _namespace_expr(expr::OpExpr, prefix::String,
                         local_names::Set{String},
                         memo::IdDict{OpExpr,ASTExpr})::ASTExpr
    r = get(memo, expr, nothing)
    r === nothing || return r
    # Recurse into EVERY variable-bearing sub-expression via the shared
    # field-preserving rewrite so prefix rewrites reach arrayop / makearray
    # bodies, filter predicates (M2 §7.2), integral bounds (`lower`/`upper`),
    # table_lookup per-axis input expressions, makearray `values`, value-invention
    # `key`, expression-valued dense `ranges` bounds, AND expression-template
    # `bindings` values (esm-spec §9.6.4 rule 7 / §10.7: template `params` —
    # the map's KEYS — never namespace, they are the template's formal
    # parameters; the argument expressions bound TO them do, and `map_children`
    # rewrites exactly the values). An explicit `bindings` carve-out used to
    # live here because `map_children` skipped that field. `map_children`
    # routes through `reconstruct`, preserving all non-expression fields
    # (semiring, output_idx, table, output, int_var, join/join_gates,
    # manifold, …) — earlier this rebuild hand-listed keywords and silently
    # dropped int_var/lower/upper/table/table_axes/output.
    result = map_children(
        x -> _namespace_expr(x, prefix, local_names, memo), expr)::OpExpr
    # `map_children` recurses into expression-bearing fields only. One field
    # carries plain-name identifiers that also need namespacing: a `join.on` key
    # column may name a component-local bin buffer (see `_namespace_join`).
    # `join` is `nothing` for models without a value-equality join, so those are
    # byte-identical to before (and skip the reconstruct copy). Index-set
    # identifier fields (`id`, `ranges[*].from`) are document-scoped (v0.8.0)
    # and never prefixed.
    # The binder set is THIS node's own loop symbols. A join column is resolved
    # against this node's `ranges`, so its own binders are the exact shadowing
    # set — and a node-local set is what lets every binding implement one rule.
    # `output_idx` may hold literal singleton dimensions (Int 1) alongside
    # symbols; only the Strings are binders.
    binders = Set{String}()
    if expr.output_idx !== nothing
        for s in expr.output_idx
            s isa AbstractString && push!(binders, String(s))
        end
    end
    expr.ranges === nothing || union!(binders, keys(expr.ranges))
    nj = _namespace_join(expr.join, binders, prefix, local_names)
    res = nj === expr.join ? result : reconstruct(result; join=nj)
    memo[expr] = res
    return res
end

# ========================================
# Per-system collection
# ========================================

"""
    _namespace_variable_update(var, _ns) -> ModelVariable

Rewrite the expression-bearing fields of a parameter's `update` rules (§5.4)
through the namespacing map `_ns`, returning `var` unchanged when it declares
no update. `when` and `expression` are ordinary expression positions whose free
names resolve in the DECLARING component's scope, so they must follow the same
renaming every equation does — otherwise a condition-triggered parameter stops
seeing the state it watches once its model is flattened under a prefix.
"""
function _namespace_variable_update(var::ModelVariable, _ns)::ModelVariable
    var.update === nothing && return var
    rules = ParameterUpdate[]
    changed = false
    for r in var.update
        nw = r.when === nothing ? nothing : _ns(r.when)
        ne = r.expression === nothing ? nothing : _ns(r.expression)
        (nw !== r.when || ne !== r.expression) && (changed = true)
        push!(rules, ParameterUpdate(r.kind; times=r.times, interval=r.interval,
            initial_offset=r.initial_offset, when=nw, direction=r.direction,
            source=r.source, hook=r.hook, expression=ne, from=r.from,
            handler=r.handler))
    end
    return changed ? reconstruct(var; update=rules) : var
end

"""
Collect a Model's variables and equations into the flattener accumulators,
recursing through subsystems. All names are rewritten to `prefix.local_name`.
Index sets (RFC §5.2) are document-scoped as of esm-spec v0.8.0 — a single
shared registry seeded once by `flatten` — so their references inside
equations (`shape`, `ranges` `from`, producer `id` / `from_faq`) keep their
plain document-level names and are NOT namespaced here.

`tpl_rename` is this component's slice of the flatten-time template-registry
collision rename (esm-spec §9.6.4 rule 7 / §10.7; `_merge_flat_registry`): when
a template name resolves to a different body per component, the merged registry
keys that entry `<ComponentPath>.<name>` and every `apply_expression_template`
reference the component authored must follow, or it resolves against nothing.
The rewrite rides alongside namespacing because this is the one pass that still
knows which component an expression came from — the "same renaming map …
applies identically to … references" §10.7 mandates — and is threaded unchanged
into subsystems, whose templates merged into their owner's registry at load.
`nothing` (the common case: no collision) skips the rewrite entirely.
"""
function _collect_model!(states::OrderedDict{String, ModelVariable},
                         params::OrderedDict{String, ModelVariable},
                         observeds::OrderedDict{String, ModelVariable},
                         equations::Vector{Equation},
                         continuous_events::Vector{ContinuousEvent},
                         discrete_events::Vector{DiscreteEvent},
                         model::Model, prefix::String;
                         tpl_rename::Union{Nothing,AbstractDict{String,String}}=nothing)
    local_names = Set{String}(keys(model.variables))
    # Also include subsystem-qualified names from this level's subsystems so
    # that references inside the model to subsystem variables get namespaced.
    for (sub_name, _) in model.subsystems
        push!(local_names, sub_name)
    end

    # Namespace, then follow the registry rename (identity when there is none).
    _ns(e) = tpl_rename === nothing ? namespace_expr(e, prefix, local_names) :
             _rename_expr_apply_refs(namespace_expr(e, prefix, local_names), tpl_rename)

    # esm-spec v0.8.0: index sets are a single document-scoped registry (seeded
    # once by `flatten` from the top-level object) with plain names shared by every
    # component — no longer per-`Model` and no longer namespaced. So index-set
    # references (an array variable's `shape` entries, `ranges[*]` `{from}`,
    # producer `id`s and their `from_faq` edges) stay as plain document-level
    # names and must NOT be rewritten to a `<prefix>.` form; only ordinary
    # variable references are namespaced.

    # Which bucket each variable lands in is DERIVED, not declared (esm-spec
    # §6.3.1): an unknown defined by a bare-variable LHS is observed and
    # everything else the solver solves for is a state, while every parameter —
    # constant, sampled, or discrete-cadence — partitions with the parameters,
    # because a parameter is never differentiated. A discrete-cadence one is the
    # forcing buffer the update machinery writes; its `update` block travels
    # with it, so `flattened_to_esm` re-emits it losslessly.
    _observed_here = Set(observed_unknowns(model))
    for (name, var) in model.variables
        namespaced = "$(prefix).$(name)"
        v = _namespace_variable_update(var, _ns)
        if v.type == ParameterVariable
            params[namespaced] = v
        elseif name in _observed_here
            observeds[namespaced] = v
        else
            states[namespaced] = v
        end
    end

    for eq in model.equations
        lhs = _ns(eq.lhs)
        rhs = _ns(eq.rhs)
        push!(equations, Equation(lhs, rhs; _comment=eq._comment))
    end

    # esm 1.0.0: an observed unknown's defining equation is an ORDINARY entry of
    # `model.equations`, already namespaced and pushed above. There is nothing
    # left to synthesize from a variable-level `expression`, which no longer
    # exists (esm-spec §6.3).

    for ev in model.continuous_events
        new_conds = ASTExpr[_ns(c) for c in ev.conditions]
        new_affects = AffectEquation[
            AffectEquation(startswith(a.lhs, prefix * ".") || occursin('.', a.lhs) ? a.lhs : "$(prefix).$(a.lhs)",
                           _ns(a.rhs))
            for a in ev.affects
        ]
        push!(continuous_events,
              ContinuousEvent(new_conds, new_affects; description=ev.description))
    end

    for ev in model.discrete_events
        new_affects = AffectEquation[
            AffectEquation(
                occursin('.', a.lhs) ? a.lhs : "$(prefix).$(a.lhs)",
                _ns(a.rhs))
            for a in ev.affects
        ]
        new_trigger = if ev.trigger isa ConditionTrigger
            ConditionTrigger(_ns(ev.trigger.expression))
        else
            ev.trigger
        end
        push!(discrete_events,
              DiscreteEvent(new_trigger, new_affects; description=ev.description))
    end

    for (sub_name, sub_model) in model.subsystems
        # esm 1.0.0: a data source is a document-scoped registry entry, not a
        # subsystem, so there is no loader arm here any more. A model that reads
        # external data declares an ordinary PARAMETER whose `update` names the
        # source (esm-spec §8.5); it is collected into `params` above under its
        # own namespaced key, and the bound value reaches the RHS through the
        # const/refresh array registry keyed by that same name.
        sub_model isa Model || continue
        _collect_model!(states, params, observeds, equations,
                        continuous_events, discrete_events,
                        sub_model, "$(prefix).$(sub_name)";
                        tpl_rename=tpl_rename)
    end
end

"""
Lower a ReactionSystem into the flattener accumulators. Species become state
variables, rate constants become parameters, and reactions are converted to
ODE equations via `lower_reactions_to_equations`. Both species and equation
variables are then namespaced by `prefix`.

EXCEPT a reservoir species (`constant: true`, §7.4), which becomes a
PARAMETER: the spec holds its concentration fixed and emits no ODE for it, so
it is not a state — exactly the treatment `codegen.jl` already gives it on the
Catalyst path (`[isconstantspecies=true]`). Its `default` carries over as the
parameter's fixed value, so it still reads as a concentration in every rate
law. Were it left a state with no equation instead, it would sit in `u` with a
permanently-zero derivative — a zero row in the chemistry Jacobian block.
"""
function _collect_reaction_system!(states::OrderedDict{String, ModelVariable},
                                   params::OrderedDict{String, ModelVariable},
                                   equations::Vector{Equation},
                                   rsys::ReactionSystem, prefix::String;
                                   templates=nothing)
    local_names = Set{String}()
    for sp in rsys.species
        push!(local_names, sp.name)
    end
    for p in rsys.parameters
        push!(local_names, p.name)
    end
    for (sub_name, _) in rsys.subsystems
        push!(local_names, sub_name)
    end

    for sp in rsys.species
        namespaced = "$(prefix).$(sp.name)"
        target = sp.constant === true ? params : states
        target[namespaced] = ModelVariable(
            sp.constant === true ? ParameterVariable : UnknownVariable;
            default=sp.default, description=sp.description, units=sp.units)
    end
    for p in rsys.parameters
        namespaced = "$(prefix).$(p.name)"
        params[namespaced] = ModelVariable(ParameterVariable;
            default=p.default, description=p.description, units=p.units)
    end

    # v0.8.0: every component shares the document's single `domain`; a system
    # is spatial iff its variables are shaped over index sets, 0-D otherwise.
    # POLICY (the flatten invariant, esm-spec §9.6.4): references survive
    # flatten only in MODEL equations; reaction-RATE references are ALWAYS
    # expanded here at collect. A rate-law `apply_expression_template` reference is expanded
    # EAGERLY here — BEFORE namespacing — so a template body's free variables that
    # name the reaction system's own scalar parameters (e.g. Arrhenius `P`/`T` in
    # `arrh_per_molecule = A*P*exp(B/T)/(8314e3*T)`) are renamed to the component
    # scope (`SuperFast.P`/`SuperFast.T`) by the same `namespace_expr` pass that
    # renames the rest of the rate. That renaming is what makes them reachable by a
    # later `param_to_var` coupling (`Transport3D.Pc -> SuperFast.P`) and the
    # pointwise lift: if the reference instead SURVIVED to the build boundary, the
    # coupling would have already run over the equations while the body's `P`/`T`
    # were still hidden in the registry, and expansion there would surface bare,
    # unbound `P`/`T` (`E_TREEWALK_UNBOUND_VARIABLE`). Model/import (discretization)
    # templates do NOT take this path — they are component-scoped in the flat
    # registry and legitimately survive to the compile-once tier. A no-op when the
    # reaction system carries no template registry or its rates hold no references.
    raw_eqs = lower_reactions_to_equations(rsys.reactions, rsys.species)
    for eq in raw_eqs
        rhs0 = templates === nothing ? eq.rhs : _expand_expr_refs(eq.rhs, templates)
        lhs = namespace_expr(eq.lhs, prefix, local_names)
        rhs = namespace_expr(rhs0, prefix, local_names)
        push!(equations, Equation(lhs, rhs; _comment=eq._comment))
    end

    for (sub_name, sub_rsys) in rsys.subsystems
        _collect_reaction_system!(states, params, equations,
                                  sub_rsys, "$(prefix).$(sub_name)"; templates=templates)
    end
end
