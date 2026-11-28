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

Return a new ASTExpr tree with every free VarExpr referencing a name in
`local_names` rewritten as `"<prefix>.<name>"`. For dotted names (e.g.
`Sub.var`), the first segment is treated as the local symbol: if it is in
`local_names` (a local subsystem), the whole dotted path is prefixed; otherwise
the reference is already external and is left unchanged. Numeric literals are
unchanged.

A bare name bound as a loop symbol by an enclosing node (an `output_idx` entry,
a `ranges` key, or an `integral`'s `int_var`) is not free: inside that node it
is the loop index and stays as written even when `local_names` holds a variable
of the same name (esm-spec §4.3, "Shadowing"). A dotted name is never a loop
index, so its first segment is still resolved against `local_names`.

Index-set references (`shape` entries, `ranges[*]` `{from}`, producer `id`s)
are NOT namespaced: as of esm-spec v0.8.0 index sets are a single
document-scoped registry with plain names shared by every component. (A former
`idx_names` parameter that could opt component-local index identifiers into
prefixing was dead — every caller passed it empty — and has been removed.)
"""
function namespace_expr(
        expr::NumExpr, prefix::String,
        local_names::Set{String}
    )::ASTExpr
    return expr
end

function namespace_expr(
        expr::IntExpr, prefix::String,
        local_names::Set{String}
    )::ASTExpr
    return expr
end

function namespace_expr(
        expr::VarExpr, prefix::String,
        local_names::Set{String},
        shadowed::Set{String} = _NO_SHADOW
    )::ASTExpr
    if occursin('.', expr.name)
        first_part = String(split(expr.name, '.')[1])
        if first_part in local_names
            return VarExpr("$(prefix).$(expr.name)")
        end
        return expr
    end
    if expr.name in local_names && !(expr.name in shadowed)
        return VarExpr("$(prefix).$(expr.name)")
    end
    return expr
end

# Identity-memoized recursion arms: prefixing is a pure function of the node
# and the names in scope, so a subtree shared under many parents — template
# expansion stores expanded ASTs as shared DAGs — is rewritten ONCE per scope
# and the shared result respliced. Without the memo a rewrite that touches
# every leaf (the common case here: every local reference gets the prefix)
# re-materializes a shared DAG as an exponential tree.
#
# The scope is not traversal-constant: a node that binds a loop symbol spelled
# like a local adds it to `shadowed` for its children (see
# `_namespace_expr(::OpExpr, …)`). One subtree can therefore be rewritten
# differently inside and outside such a node, so there is one memo per distinct
# `shadowed` set, kept in `memos` and passed down as `memo` for the current
# scope. `shadowed` holds only the colliding names, so keying on it stays cheap
# however many locals the component declares, and a document without that
# collision never leaves the root scope.
const _NO_SHADOW = Set{String}()
const _NsMemo = IdDict{OpExpr, ASTExpr}
const _NsMemos = Dict{Set{String}, _NsMemo}
# Template name → the loop symbols its body binds (`template_captures`).
const _TplCaptures = Dict{String, Set{String}}
const _NO_CAPTURES = _TplCaptures()
_namespace_expr(
    e::NumExpr, ::String, ::Set{String}, ::Set{String}, ::_NsMemo,
    ::_NsMemos, ::_TplCaptures
) = e
_namespace_expr(
    e::IntExpr, ::String, ::Set{String}, ::Set{String}, ::_NsMemo,
    ::_NsMemos, ::_TplCaptures
) = e
_namespace_expr(
    e::VarExpr, prefix::String, local_names::Set{String},
    shadowed::Set{String}, ::_NsMemo, ::_NsMemos, ::_TplCaptures
) =
    namespace_expr(e, prefix, local_names, shadowed)

"""
    template_captures(block) -> Dict{String, Set{String}}

For each template of a component's `expression_templates` block (raw JSON),
the loop symbols its body binds (`output_idx` entries, `ranges` keys,
`integral` variables). Template application is pure substitution, so a name in
a call's binding value that the body binds at the substitution site is that
loop index after expansion, not a reference to a component variable of the
same name (`lib/relational.esm`'s `argmin` relies on this: its candidate
binding reads the body's loop symbol).
"""
function template_captures(block)::_TplCaptures
    out = _TplCaptures()
    (block === nothing || !_is_object(block)) && return out
    for (tname, decl) in pairs(block)
        body_raw = _raw_get(decl, "body")
        body_raw === nothing && continue
        bound = Set{String}()
        visit(x) = (x isa OpExpr && union!(bound, _bound_symbols(x)); nothing)
        body = expression_from_json(body_raw)
        visit(body)
        foreach_subexpr(visit, body)
        isempty(bound) || (out[string(tname)] = bound)
    end
    return out
end

# The binder set is THIS node's own loop symbols: its `output_idx` entries and
# `ranges` keys. A join column is resolved against this node's `ranges`, so its
# own binders are the exact shadowing set — and a node-local set is what lets
# every binding implement one rule. `output_idx` may hold literal singleton
# dimensions (Int 1) alongside symbols; only the Strings are binders.
function _join_binders(expr::OpExpr)::Set{String}
    binders = Set{String}()
    if expr.output_idx !== nothing
        for s in expr.output_idx
            s isa AbstractString && push!(binders, String(s))
        end
    end
    expr.ranges === nothing || union!(binders, keys(expr.ranges))
    return binders
end

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
# enclosing `faq` and shadows any coincident variable name (esm-spec §4.3 —
# "a given string can be a variable reference in most contexts but serves as an
# index symbol inside `faq.output_idx`, `faq.expr`, and `faq.ranges` keys"), and an `on` key column is resolved against this
# node's own ranges (`_vi_join_index_sym`, `_join_sym_for_key`) — so prefixing a
# shadowed symbol makes it resolve to nothing. Without this the gate mis-fires on
# the legal case of a component declaring a variable named like a loop symbol.
function _namespace_join(
        join, binders::Set{String}, prefix::String,
        local_names::Set{String}
    )
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
    # A `join.overlap` clause namespaces its envelope FACTOR names the
    # same way (a component-local coord/rect buffer gets the prefix); `eps` is a
    # scalar and never rewrites. A bin-equality clause namespaces its key columns.
    nsclause(clause::_OverlapJoinSpec) = _OverlapJoinSpec(
        String[nsname(n) for n in clause.src_env],
        String[nsname(n) for n in clause.tgt_env], clause.eps, clause.eps_given
    )
    # Key COLUMNS are references and are namespaced; a clause's `syms` name
    # range symbols the node BINDS and must be carried through untouched.
    nsclause(clause) = _with_pairs(
        clause,
        Tuple{String, String}[(nsname(l), nsname(r)) for (l, r) in clause]
    )
    return Any[nsclause(clause) for clause in join]
end

function namespace_expr(
        expr::OpExpr, prefix::String,
        local_names::Set{String};
        captures::_TplCaptures = _NO_CAPTURES
    )::ASTExpr
    memo = _NsMemo()
    return _namespace_expr(
        expr, prefix, local_names, _NO_SHADOW, memo,
        _NsMemos(_NO_SHADOW => memo), captures
    )
end
namespace_expr(
    expr::Union{NumExpr, IntExpr, VarExpr}, prefix::String,
    local_names::Set{String}; captures::_TplCaptures = _NO_CAPTURES
) = namespace_expr(expr, prefix, local_names)

function _namespace_expr(
        expr::OpExpr, prefix::String,
        local_names::Set{String}, shadowed::Set{String},
        memo::_NsMemo, memos::_NsMemos, captures::_TplCaptures
    )::ASTExpr
    r = get(memo, expr, nothing)
    r === nothing || return r
    # A loop symbol is local to the node that binds it (an `output_idx` entry, a
    # `ranges` key, an `integral`'s `int_var` — `_bound_symbols`) and shadows
    # any variable of the same name throughout that node's children (esm-spec
    # §4.3, "Shadowing"; esm-libraries-spec §4.7.5 step 2). Inside
    # `faq(output_idx=[j], expr=index(u, j))` in a model that also declares a
    # parameter `j`, the `j` in the body is the loop index and must stay `j`;
    # prefixing it to `<prefix>.j` silently turns the loop into a constant
    # subscript read from the parameter. So the children see the colliding
    # binders in `shadowed`. A nested node that does not rebind a name sees the
    # outer binding; one that rebinds it shadows it again.
    child_shadowed, child_memo = shadowed, memo
    if expr.output_idx !== nothing || expr.ranges !== nothing ||
            expr.int_var !== nothing
        for b in _bound_symbols(expr)
            (b in local_names && !(b in child_shadowed)) || continue
            child_shadowed === shadowed && (child_shadowed = copy(shadowed))
            push!(child_shadowed, b)
        end
        child_shadowed === shadowed ||
            (child_memo = get!(_NsMemo, memos, child_shadowed))
    end
    # A template call's bindings are substituted into its body, so a binding
    # name the body binds as a loop symbol is that loop index (see
    # `template_captures`), not the component variable of the same name.
    if expr.op == "apply_operator" && expr.name !== nothing
        cap = get(captures, expr.name::String, nothing)
        if cap !== nothing
            for b in cap
                (b in local_names && !(b in child_shadowed)) || continue
                child_shadowed === shadowed && (child_shadowed = copy(shadowed))
                push!(child_shadowed, b)
            end
            child_shadowed === shadowed ||
                (child_memo = get!(_NsMemo, memos, child_shadowed))
        end
    end
    # Recurse into EVERY variable-bearing sub-expression via the shared
    # field-preserving rewrite so prefix rewrites reach faq / makearray
    # bodies, filter predicates (RFC §7.2), integral bounds (`lower`/`upper`),
    # makearray `values`, value-invention
    # `key`, expression-valued dense `ranges` bounds, AND expression-template
    # `bindings` values (esm-spec §9.6.4 rule 7 / §10.7: template `params` —
    # the map's KEYS — never namespace, they are the template's formal
    # parameters; the argument expressions bound TO them do, and `map_children`
    # rewrites exactly the values). `map_children`
    # routes through `reconstruct`, preserving all non-expression fields
    # (semiring, output_idx, int_var, join/join_gates, manifold, …).
    result = map_children(
        x -> _namespace_expr(
            x, prefix, local_names, child_shadowed, child_memo,
            memos, captures
        ),
        expr
    )::OpExpr
    # `map_children` recurses into expression-bearing fields only. One field
    # carries plain-name identifiers that also need namespacing: a `join.on` key
    # column may name a component-local bin buffer (see `_namespace_join`).
    # `join` is `nothing` for models without a value-equality join, which skip
    # the reconstruct copy. Index-set identifier fields (`id`, `ranges[*].from`)
    # are document-scoped and never prefixed.
    nj = expr.join === nothing ? nothing :
        _namespace_join(expr.join, _join_binders(expr), prefix, local_names)
    res = nj === expr.join ? result : reconstruct(result; join = nj)
    memo[expr] = res
    return res
end

# ========================================
# Per-system collection
# ========================================

# Namespace a component's events onto `st.continuous_events` and
# `st.discrete_events` (the flatten state, or any holder of the two vectors). Shared by
# `_collect_model!` and `_collect_reaction_system!` so a model and a reaction
# system carry their events into the flattened system by the SAME rule.
#
# `ns` namespaces an expression in the component's scope. An affect LHS is a
# NAME, not an expression, so it does not travel through `ns` and needs the
# placeholder carve-out spelled out here. esm-spec §6.4: `_var` is not a
# variable of this component (or of any component) — it stands for whichever
# state `operator_compose` expands it to — so it must survive namespacing
# untouched, exactly as `namespace_expr` already leaves it alone inside the
# CONDITION (it is in no component's `local_names`).
function _collect_events!(
        st,
        component_continuous::Vector{ContinuousEvent},
        component_discrete::Vector{DiscreteEvent},
        prefix::String, ns
    )
    # A dotted target is qualified by `ns` exactly as a read of the same name
    # is: prefixed when its head is one of this component's subsystem keys,
    # left alone when it is already qualified.
    ns_target(lhs) = is_placeholder(lhs) ? lhs :
        occursin('.', lhs) ? (ns(VarExpr(lhs))::VarExpr).name : "$(prefix).$(lhs)"
    for ev in component_continuous
        push!(st.continuous_events, _rename_affect_targets(ns_target, _map_event_exprs(ns, ev)))
    end
    for ev in component_discrete
        push!(st.discrete_events, _rename_affect_targets(ns_target, _map_event_exprs(ns, ev)))
    end
    return nothing
end
_collect_events!(cv::Vector{ContinuousEvent}, dv::Vector{DiscreteEvent}, ccv, cdv, prefix, ns) =
    _collect_events!((continuous_events = cv, discrete_events = dv), ccv, cdv, prefix, ns)

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
function _collect_model!(
        st, model::Model, prefix::String;
        tpl_added::Union{Nothing, AbstractDict{String, Vector{String}}} = nothing,
        tpl_rename::Union{Nothing, AbstractDict{String, String}} = nothing,
        tpl_captures::_TplCaptures = _NO_CAPTURES
    )
    local_names = Set{String}(keys(model.variables))
    # Also include subsystem-qualified names from this level's subsystems so
    # that references inside the model to subsystem variables get namespaced.
    for (sub_name, _) in model.subsystems
        push!(local_names, sub_name)
    end

    # A reference binds its template's explicit free names (`_tpl_explicit_free`)
    # to the same names here, in this (sub)system's scope: the namespacing below
    # scopes them as it scopes the rest of the expression, so a body's free
    # names read the names of the subsystem that owns the reference (esm-spec
    # §9.6.4 rules 1–2), whichever component's registry holds the body. Then
    # follow the registry rename (identity when there is none).
    added = tpl_added === nothing ? Dict{String, Vector{String}}() : tpl_added
    memo = IdDict{OpExpr, ASTExpr}()
    function _ns(e)
        r = namespace_expr(_tpl_bind_explicit(e, added, memo), prefix, local_names; captures = tpl_captures)
        return tpl_rename === nothing ? r : _rename_expr_apply_refs(r, tpl_rename)
    end

    # Index sets are a single document-scoped registry (seeded once by `flatten`
    # from the top-level object) with plain names shared by every component, never
    # namespaced. So index-set
    # references (an array variable's `shape` entries, `ranges[*]` `{from}`,
    # producer `id`s and their `from_faq` edges) stay as plain document-level
    # names and must NOT be rewritten to a `<prefix>.` form; only ordinary
    # variable references are namespaced.

    # Which bucket each variable lands in is DERIVED, not declared (esm-spec
    # §6.3.1), and the two unknown buckets are NOT a partition
    # (esm-libraries-spec §4.7.5 step 4): `observed_variables` is the
    # classification — every unknown an equation DEFINES, at either LHS
    # spelling — while `state_variables` is the solved-for vector. So an ODE
    # state and an algebraic unknown are states alone; an INLINEABLE observed
    # (the strict bare-variable LHS) is eliminated by substitution and is an
    # observed alone; and an ARRAYED definition (`y[i] ~ f(…)`) is BOTH,
    # because it materializes into a buffer the solver must allocate.
    # Every parameter — constant, sampled, or discrete-cadence — partitions with
    # the parameters, because a parameter is never differentiated. A
    # discrete-cadence one is the forcing buffer the update machinery writes;
    # its `update` block travels with it into the run file.
    _observed_here = Set(observed_unknowns(model))
    _inlineable_here = _inlineable_observed_unknowns(model)
    for (name, var) in model.variables
        namespaced = "$(prefix).$(name)"
        # A variable's update rules and bounds are namespaced exactly as an
        # equation's references are (esm-libraries-spec §4.7.5, "Bounds follow
        # the renaming"): they resolve in the declaring component's scope.
        v = _map_variable_sites(_ns, var)
        if v.type == ParameterVariable
            st.params[namespaced] = v
        elseif name in _observed_here
            name in _inlineable_here || (st.states[namespaced] = v)
            st.observeds[namespaced] = v
        else
            st.states[namespaced] = v
        end
    end

    # Per-term provenance (esm-libraries-spec §4.7.5): one contribution per
    # equation, authored by this component's full dotted path — a subsystem's
    # equation names the subsystem, not its parent.
    for eq in model.equations
        lhs = _ns(eq.lhs)
        rhs = _ns(eq.rhs)
        push!(
            st.equations, _FlatEq(
                Equation(lhs, rhs; _comment = eq._comment),
                _authored(rhs, _component_origin(prefix)), _component_root(prefix)
            )
        )
    end
    # A typed model's deprecated initialization equations (a `Model` built in
    # memory; a loaded document has none, esm-spec §11.4.4) read as the loader
    # reads them: `ic` equations of the model, resolved in the same scope and
    # taking the same renaming as its equations. Flatten files them with the
    # other initialization equations (`_extract_field_ics!`).
    # `guesses` (esm-spec §6.2), named as the variables are: the starting points
    # of the initialization system's unknowns (esm-spec §11.4.3).
    migrated, more_guesses = _migrate_typed_initialization(model)
    for (k, g) in Iterators.flatten((model.guesses, more_guesses))
        st.guesses["$(prefix).$(k)"] = g isa ASTExpr ? _ns(g) : g
    end
    for eq in migrated
        lhs = _ns(eq.lhs)
        rhs = _ns(eq.rhs)
        push!(
            st.equations, _FlatEq(
                Equation(lhs, rhs; _comment = eq._comment),
                _authored(rhs, _component_origin(prefix)), _component_root(prefix)
            )
        )
    end

    # An observed unknown's defining equation is an ORDINARY entry of
    # `model.equations`, already namespaced and pushed above (esm-spec §6.3).

    _collect_events!(st, model.continuous_events, model.discrete_events, prefix, _ns)

    for (sub_name, sub_model) in model.subsystems
        # A data source is a document-scoped registry entry, not a subsystem,
        # so there is no loader arm here. A model that reads
        # external data declares an ordinary PARAMETER whose `update` names the
        # source (esm-spec §8.5); it is collected into `params` above under its
        # own namespaced key, and the bound value reaches the RHS through the
        # const/refresh array registry keyed by that same name.
        sub_model isa Model || continue
        _collect_model!(
            st, sub_model, "$(prefix).$(sub_name)";
            tpl_added = tpl_added, tpl_rename = tpl_rename, tpl_captures = tpl_captures
        )
    end
    return
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
function _collect_reaction_system!(
        st, rsys::ReactionSystem, prefix::String;
        tpl_added::Union{Nothing, AbstractDict{String, Vector{String}}} = nothing,
        tpl_rename::Union{Nothing, AbstractDict{String, String}} = nothing,
        tpl_captures::_TplCaptures = _NO_CAPTURES
    )
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

    # A parameter's update rules resolve in this system's scope, so they are
    # namespaced like a rate.
    ns(e) = namespace_expr(e, prefix, local_names)
    for (name, v) in reaction_variables(rsys)
        target = v.type == ParameterVariable ? st.params : st.states
        target["$(prefix).$(name)"] = _map_variable_sites(ns, v)
    end

    # v0.8.0: every component shares the document's single `domain`; a system
    # is spatial iff its variables are shaped over index sets, 0-D otherwise.
    # A rate-law or event `apply_expression_template` reference SURVIVES
    # flatten, as a model's does (esm-spec §9.6.4). Its template's free names
    # (e.g. Arrhenius `P`/`T` in `arrh_per_molecule = A*P*exp(B/T)/(8314e3*T)`)
    # were made explicit parameters (`_tpl_explicit_free`), and the reference
    # binds them to the same names HERE, before namespacing: the same
    # `namespace_expr` pass that renames the rest of the rate renames those
    # bindings to the component scope (`SuperFast.P`/`SuperFast.T`), where a
    # later `param_to_var` coupling (`Transport3D.Pc -> SuperFast.P`) and the
    # pointwise lift reach them, exactly where expansion would have put them.
    added = tpl_added === nothing ? Dict{String, Vector{String}}() : tpl_added
    memo = IdDict{OpExpr, ASTExpr}()
    function _ns_site(e)
        r = namespace_expr(_tpl_bind_explicit(e, added, memo), prefix, local_names; captures = tpl_captures)
        return tpl_rename === nothing ? r : _rename_expr_apply_refs(r, tpl_rename)
    end
    raw_eqs = lower_reactions_to_equations(rsys.reactions, rsys.species)
    for eq in raw_eqs
        lhs = namespace_expr(eq.lhs, prefix, local_names)
        rhs = _ns_site(eq.rhs)
        push!(
            st.equations, _FlatEq(
                Equation(lhs, rhs; _comment = eq._comment),
                _authored(rhs, _component_origin(prefix)), _component_root(prefix)
            )
        )
    end

    # A reaction system's events are collected on the same footing as a model's
    # (esm-spec §6.4 permits both, and the schema gives `ReactionSystem` the same
    # `continuous_events` / `discrete_events` blocks). An event expression is a
    # component-scoped expression exactly like a rate, so its references bind
    # their explicit parameters the same way.
    _collect_events!(st, rsys.continuous_events, rsys.discrete_events, prefix, _ns_site)

    for (sub_name, sub_rsys) in rsys.subsystems
        _collect_reaction_system!(
            st, sub_rsys, "$(prefix).$(sub_name)";
            tpl_added = tpl_added, tpl_rename = tpl_rename, tpl_captures = tpl_captures
        )
    end
    return
end
