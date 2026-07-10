# Dot-namespacing and per-system collection: flatten steps 1+2 (spec §4.7.5).
# Rewrites every component-local reference to `<prefix>.<name>` and collects
# each Model / ReactionSystem's variables, equations, and events into the
# flattener accumulators. Split from flatten.jl.

using OrderedCollections: OrderedDict

# ========================================
# Namespacing
# ========================================

"""
    namespace_expr(expr, prefix, local_names) -> Expr

Return a new Expr tree with every VarExpr referencing a name in `local_names`
rewritten as `"<prefix>.<name>"`. For dotted names (e.g. `Sub.var`), the first
segment is treated as the local symbol: if it is in `local_names` (a local
subsystem), the whole dotted path is prefixed; otherwise the reference is
already external and is left unchanged. Numeric literals are unchanged.
"""
function namespace_expr(expr::NumExpr, prefix::String, local_names::Set{String},
                        idx_names::Set{String}=Set{String}())::Expr
    return expr
end

function namespace_expr(expr::IntExpr, prefix::String, local_names::Set{String},
                        idx_names::Set{String}=Set{String}())::Expr
    return expr
end

function namespace_expr(expr::VarExpr, prefix::String, local_names::Set{String},
                        idx_names::Set{String}=Set{String}())::Expr
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

# Namespace a `ranges` map: rewrite each `IndexSetRef`'s `from` set name when it
# is a component-local index identifier, and namespace any expression-valued
# dense bound. Index-VARIABLE names (the `of` parents, the range keys) are
# arrayop-local and are left untouched.
function _namespace_ranges(ranges, prefix::String, local_names::Set{String},
                           idx_names::Set{String})
    ranges === nothing && return nothing
    out = Dict{String,Any}()
    for (k, v) in ranges
        if v isa IndexSetRef
            newfrom = v.from in idx_names ? "$(prefix).$(v.from)" : v.from
            out[k] = IndexSetRef(newfrom; of=v.of)
        elseif v isa AbstractVector
            out[k] = Any[x isa Expr ?
                         namespace_expr(x, prefix, local_names, idx_names) : x for x in v]
        else
            out[k] = v
        end
    end
    return out
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
    return Any[Tuple{String,String}[(nsname(l), nsname(r)) for (l, r) in clause]
               for clause in join]
end

function namespace_expr(expr::OpExpr, prefix::String, local_names::Set{String},
                        idx_names::Set{String}=Set{String}())::Expr
    # Recurse into EVERY variable-bearing sub-expression via the shared
    # field-preserving rewrite so prefix rewrites reach arrayop / makearray
    # bodies, filter predicates (M2 §7.2), integral bounds (`lower`/`upper`),
    # table_lookup per-axis input expressions, makearray `values`, value-invention
    # `key`, and expression-valued dense `ranges` bounds. `map_children` routes
    # through `reconstruct`, preserving all other fields (semiring, output_idx,
    # table, output, int_var, join/join_gates, manifold, …) — earlier this rebuild
    # hand-listed keywords and silently dropped int_var/lower/upper/table/
    # table_axes/output.
    result = map_children(
        x -> namespace_expr(x, prefix, local_names, idx_names), expr)::OpExpr
    # `map_children` recurses into expression-bearing fields only. Three fields
    # carry index-set / column identifiers that also need namespacing so a
    # flattened component's private geometry/index names don't collide with a
    # sibling's after merge — override them on the recursed node:
    #  - `id`: the value-invention producer id matched by a derived set's `from_faq`,
    #    namespaced when it is a component-local index identifier.
    #  - `ranges`: each `IndexSetRef`'s `{from: <set>}` set name (`map_children`
    #    copies `IndexSetRef` entries verbatim). `_namespace_ranges` is the sole
    #    authority for `ranges`: it rewrites both the `from` references AND the
    #    expression-valued dense bounds — the latter identically to `map_children` —
    #    so overriding the whole field is behavior-preserving.
    #  - `join`: a `join.on` key column may name a component-local bin buffer.
    # `id`/`ranges` are gated on `idx_names` (empty for models that declare no
    # index sets) and `join` is `nothing` for models without a value-equality
    # join, so non-geometry models are byte-identical to before.
    new_id = (expr.id !== nothing && expr.id in idx_names) ? "$(prefix).$(expr.id)" : expr.id
    new_ranges = _namespace_ranges(expr.ranges, prefix, local_names, idx_names)
    new_join = _namespace_join(expr.join, prefix, local_names)
    return reconstruct(result; id=new_id, ranges=new_ranges, join=new_join)
end

# ========================================
# Variable-shape namespacing (RFC semiring-faq-unified-ir §5.2)
# ========================================

# Namespace a variable's `shape` index-set references (gated on `idx_names`).
# As of esm-spec v0.8.0 index sets are document-scoped with plain, shared names,
# so the flattener passes an empty `idx_names` and this is a no-op — a shape's
# entries (index-set names / domain dims) are global and never prefixed. The
# gate is retained so a future component-local shape identifier could opt in.
function _namespace_var_shape(var::ModelVariable, prefix::String, idx_names::Set{String})::ModelVariable
    var.shape === nothing && return var
    any(s -> s in idx_names, var.shape) || return var
    new_shape = String[s in idx_names ? "$(prefix).$(s)" : s for s in var.shape]
    return reconstruct(var; shape=new_shape)
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
    # references (`shape` entries, `ranges[*]` `{from}`, producer `id`s and their
    # `from_faq` edges) stay as plain document-level names and must NOT be
    # rewritten to a `<prefix>.` form. Passing an empty `idx_names` leaves them
    # untouched while ordinary variable references are still namespaced.
    idx_names = Set{String}()

    for (name, var) in model.variables
        namespaced = "$(prefix).$(name)"
        # An array variable's `shape` names index sets, which are document-scoped
        # (v0.8.0): their plain names are shared across components, so the shape
        # passes through unchanged (empty `idx_names` → no-op).
        v = _namespace_var_shape(var, prefix, idx_names)
        # Namespace the defining `expression` body too, consistent with the
        # namespaced key/shape and the synthesized observed equation below.
        # `_namespace_var_shape` copies `expression` verbatim, so an observed's
        # array-aggregate / const body otherwise keeps UNQUALIFIED intra-model
        # references (e.g. an aggregate body `index(rg_src_poly, …)`) even though
        # its own key became `<prefix>.rg_src_lon`. The geometry / value-invention
        # front-door (RFC §6.1 / §8.6.1) reads this `expression` DIRECTLY (see
        # `flattened_to_esm`), so an unqualified ref can no longer resolve against
        # the prefixed variable keys — rewrite it here so the flattened observed
        # is self-consistent with its key, shape, and equation form.
        if v.expression !== nothing
            v = reconstruct(v;
                expression=namespace_expr(v.expression, prefix, local_names, idx_names))
        end
        if v.type == StateVariable
            states[namespaced] = v
        elseif v.type == ParameterVariable
            params[namespaced] = v
        elseif v.type == ObservedVariable
            observeds[namespaced] = v
        end
    end

    explicit_lhs_names = Set{String}()
    for eq in model.equations
        lhs = namespace_expr(eq.lhs, prefix, local_names, idx_names)
        rhs = namespace_expr(eq.rhs, prefix, local_names, idx_names)
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
        rhs = namespace_expr(var.expression, prefix, local_names, idx_names)
        push!(equations, Equation(lhs, rhs))
    end

    for ev in model.continuous_events
        new_conds = Expr[namespace_expr(c, prefix, local_names, idx_names) for c in ev.conditions]
        new_affects = AffectEquation[
            AffectEquation(startswith(a.lhs, prefix * ".") || occursin('.', a.lhs) ? a.lhs : "$(prefix).$(a.lhs)",
                           namespace_expr(a.rhs, prefix, local_names, idx_names))
            for a in ev.affects
        ]
        push!(continuous_events,
              ContinuousEvent(new_conds, new_affects; description=ev.description))
    end

    for ev in model.discrete_events
        new_affects = FunctionalAffect[
            FunctionalAffect(
                occursin('.', a.target) ? a.target : "$(prefix).$(a.target)",
                namespace_expr(a.expression, prefix, local_names, idx_names);
                operation=a.operation)
            for a in ev.affects
        ]
        new_trigger = if ev.trigger isa ConditionTrigger
            ConditionTrigger(namespace_expr(ev.trigger.expression, prefix, local_names, idx_names))
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
"""
function _collect_reaction_system!(states::OrderedDict{String, ModelVariable},
                                   params::OrderedDict{String, ModelVariable},
                                   equations::Vector{Equation},
                                   rsys::ReactionSystem, prefix::String)
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
        states[namespaced] = ModelVariable(StateVariable;
            default=sp.default, description=sp.description, units=sp.units)
    end
    for p in rsys.parameters
        namespaced = "$(prefix).$(p.name)"
        params[namespaced] = ModelVariable(ParameterVariable;
            default=p.default, description=p.description, units=p.units)
    end

    # v0.8.0: every component shares the document's single `domain`; a system
    # is spatial iff its variables are shaped over index sets, 0-D otherwise.
    raw_eqs = lower_reactions_to_equations(rsys.reactions, rsys.species)
    for eq in raw_eqs
        lhs = namespace_expr(eq.lhs, prefix, local_names)
        rhs = namespace_expr(eq.rhs, prefix, local_names)
        push!(equations, Equation(lhs, rhs; _comment=eq._comment))
    end

    for (sub_name, sub_rsys) in rsys.subsystems
        _collect_reaction_system!(states, params, equations,
                                  sub_rsys, "$(prefix).$(sub_name)")
    end
end
