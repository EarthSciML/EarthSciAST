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
function _namespace_join(join, prefix::String, local_names::Set{String})
    join === nothing && return nothing
    nsname(n) = begin
        s = String(n)
        if occursin('.', s)
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
    nj = _namespace_join(expr.join, prefix, local_names)
    res = nj === expr.join ? result : reconstruct(result; join=nj)
    memo[expr] = res
    return res
end

# ========================================
# Per-system collection
# ========================================

"""
Collect a Model's variables and equations into the flattener accumulators,
recursing through subsystems. All names are rewritten to `prefix.local_name`.
Index sets (RFC §5.2) are document-scoped as of esm-spec v0.8.0 — a single
shared registry seeded once by `flatten` — so their references inside
equations (`shape`, `ranges` `from`, producer `id` / `from_faq`) keep their
plain document-level names and are NOT namespaced here.
"""
function _collect_model!(states::OrderedDict{String, ModelVariable},
                         params::OrderedDict{String, ModelVariable},
                         observeds::OrderedDict{String, ModelVariable},
                         equations::Vector{Equation},
                         continuous_events::Vector{ContinuousEvent},
                         discrete_events::Vector{DiscreteEvent},
                         model::Model, prefix::String)
    local_names = Set{String}(keys(model.variables))
    # Also include subsystem-qualified names from this level's subsystems so
    # that references inside the model to subsystem variables get namespaced.
    for (sub_name, _) in model.subsystems
        push!(local_names, sub_name)
    end

    # esm-spec v0.8.0: index sets are a single document-scoped registry (seeded
    # once by `flatten` from the top-level object) with plain names shared by every
    # component — no longer per-`Model` and no longer namespaced. So index-set
    # references (an array variable's `shape` entries, `ranges[*]` `{from}`,
    # producer `id`s and their `from_faq` edges) stay as plain document-level
    # names and must NOT be rewritten to a `<prefix>.` form; only ordinary
    # variable references are namespaced.

    for (name, var) in model.variables
        namespaced = "$(prefix).$(name)"
        v = var
        # Namespace the defining `expression` body, consistent with the
        # namespaced key and the synthesized observed equation below.
        # An observed's array-aggregate / const body otherwise keeps UNQUALIFIED
        # intra-model references (e.g. an aggregate body `index(rg_src_poly, …)`)
        # even though
        # its own key became `<prefix>.rg_src_lon`. The geometry / value-invention
        # front-door (RFC §6.1 / §8.6.1) reads this `expression` DIRECTLY (see
        # `flattened_to_esm`), so an unqualified ref can no longer resolve against
        # the prefixed variable keys — rewrite it here so the flattened observed
        # is self-consistent with its key, shape, and equation form.
        if v.expression !== nothing
            v = reconstruct(v;
                expression=namespace_expr(v.expression, prefix, local_names))
        end
        if v.type == StateVariable
            states[namespaced] = v
        elseif v.type == ParameterVariable || v.type == DiscreteVariable
            # A DISCRETE variable is piecewise-constant between refreshes — the
            # solver never differentiates it — so it partitions with the
            # parameters (it is the loader/forcing buffer the refresh machinery
            # writes; see `ModelVariableType`). The bucket is only a partition:
            # `v` keeps `type == DiscreteVariable`, so `flattened_to_esm`
            # re-emits it as `"discrete"` and the round-trip is lossless. Routing
            # it nowhere (the pre-`DiscreteVariable` behaviour) silently DROPPED
            # the declaration from the flattened model, degrading a declared
            # forcing back into a bare undeclared name.
            params[namespaced] = v
        elseif v.type == ObservedVariable
            observeds[namespaced] = v
        end
    end

    explicit_lhs_names = Set{String}()
    for eq in model.equations
        lhs = namespace_expr(eq.lhs, prefix, local_names)
        rhs = namespace_expr(eq.rhs, prefix, local_names)
        push!(equations, Equation(lhs, rhs; _comment=eq._comment))
        if lhs isa VarExpr
            push!(explicit_lhs_names, lhs.name)
        end
    end

    # Observed variables carry their defining expression in `expression`
    # (per esm-spec §6.2: "must include an `expression` field"). Emit
    # `obs ~ expression` as a flattened equation so the enclosing System
    # is well-determined (one equation per observed var). Skip when an
    # explicit `equations` entry already provides the definition — some
    # fixtures use a sentinel `expression: 0.0` plus an explicit equation.
    for (name, var) in model.variables
        var.type == ObservedVariable || continue
        var.expression === nothing && continue
        namespaced = "$(prefix).$(name)"
        namespaced in explicit_lhs_names && continue
        lhs = VarExpr(namespaced)
        rhs = namespace_expr(var.expression, prefix, local_names)
        push!(equations, Equation(lhs, rhs))
    end

    for ev in model.continuous_events
        new_conds = ASTExpr[namespace_expr(c, prefix, local_names) for c in ev.conditions]
        new_affects = AffectEquation[
            AffectEquation(startswith(a.lhs, prefix * ".") || occursin('.', a.lhs) ? a.lhs : "$(prefix).$(a.lhs)",
                           namespace_expr(a.rhs, prefix, local_names))
            for a in ev.affects
        ]
        push!(continuous_events,
              ContinuousEvent(new_conds, new_affects; description=ev.description))
    end

    for ev in model.discrete_events
        new_affects = AffectEquation[
            AffectEquation(
                occursin('.', a.lhs) ? a.lhs : "$(prefix).$(a.lhs)",
                namespace_expr(a.rhs, prefix, local_names))
            for a in ev.affects
        ]
        new_trigger = if ev.trigger isa ConditionTrigger
            ConditionTrigger(namespace_expr(ev.trigger.expression, prefix, local_names))
        else
            ev.trigger
        end
        push!(discrete_events,
              DiscreteEvent(new_trigger, new_affects; description=ev.description,
                            functional_affect=ev.functional_affect))
    end

    for (sub_name, sub_model) in model.subsystems
        # A DataLoader subsystem (RFC pure-io-data-loaders §4.3) exposes its
        # variables to the owning model under the dot-path `<owner>.<subkey>.<var>`.
        # Lower each loader variable to an observed of that name — with NO defining
        # equation (its value is a pure-I/O external input injected at the RHS
        # boundary by the provider seam, not computed) — so the flattened system is
        # structurally complete and its name is materialized, exactly as the Python
        # binding does (earthsci_ast `flatten.py` §4.3: a `FlattenedVariable`
        # of type "observed" named `<owner>.<subkey>.<var>` + a LoaderField). The
        # bound value reaches the RHS through `const_arrays` keyed by this same name
        # (a CONST provider materialised at build time by `simulate`, or a discrete
        # refresh buffer): a gather `index(<owner>.<subkey>.<var>, …)` resolves it
        # via `_resolve_indices`, and a bare scalar reference const-folds against
        # the same registry (`_resolve_indices(::VarExpr)`). Julia carries no
        # separate `loader_fields` descriptor (unlike Python) — the const-array key
        # is the whole contract — so no equation is synthesized here.
        if sub_model isa DataLoader
            for (var_name, loader_var) in sub_model.variables
                namespaced = "$(prefix).$(sub_name).$(var_name)"
                observeds[namespaced] = ModelVariable(ObservedVariable;
                    units=loader_var.units, description=loader_var.description)
            end
            continue
        end
        sub_model isa Model || continue
        _collect_model!(states, params, observeds, equations,
                        continuous_events, discrete_events,
                        sub_model, "$(prefix).$(sub_name)")
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
            sp.constant === true ? ParameterVariable : StateVariable;
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
