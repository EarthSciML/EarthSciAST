# Coupling preflight checks and coupling-rule application (spec §4.7.5 step 3):
# conflicting-derivative detection, variable-map unit checks, then
# operator_compose / couple / variable_map application, plus the human-readable
# coupling descriptions recorded in FlattenMetadata. Split from flatten.jl.

using OrderedCollections: OrderedDict

# ========================================
# Equation-LHS pattern helpers
# ========================================

"""
    lhs_dependent_variable(expr) -> Union{String, Nothing}

Extract the dependent variable name from an equation LHS. For `D(x, t)`, returns
`"x"`. For a bare `VarExpr("x")`, returns `"x"`. Otherwise returns `nothing`.

NOTE: this deliberately CONFLATES the differential (`D(x, t) = …`) and bare
algebraic (`x = …`) equation forms — the operator_compose merge keys equations
by dependent variable regardless of form. Use
[`differential_lhs_variable`](@ref) when only the differential form should
match (e.g. state-ODE detection).
"""
function lhs_dependent_variable(expr::ASTExpr)::Union{String, Nothing}
    if expr isa VarExpr
        return expr.name
    elseif expr isa OpExpr && expr.op == "D" && !isempty(expr.args) && expr.args[1] isa VarExpr
        return (expr.args[1]::VarExpr).name
    end
    return nothing
end

# The variable an `ic(x)` left-hand side pins, or `nothing` for any other form.
function _ic_lhs_variable(expr::ASTExpr)::Union{String, Nothing}
    expr isa OpExpr || return nothing
    expr.op == "ic" || return nothing
    (length(expr.args) == 1 && expr.args[1] isa VarExpr) || return nothing
    return (expr.args[1]::VarExpr).name
end

"""
    differential_lhs_variable(expr) -> Union{String, Nothing}

The dependent-variable name of a DIFFERENTIAL equation LHS: returns `"x"` for
`D(x, …)` (any `wrt` — the flatten pipeline's LHS derivatives are time
derivatives by construction, so `wrt` is not inspected) and `nothing` for
anything else, including a bare `VarExpr` — see
[`lhs_dependent_variable`](@ref) for the form-conflating variant.
"""
function differential_lhs_variable(expr::ASTExpr)::Union{String, Nothing}
    expr isa OpExpr || return nothing
    expr.op == "D" || return nothing
    (!isempty(expr.args) && expr.args[1] isa VarExpr) || return nothing
    return (expr.args[1]::VarExpr).name
end

# ========================================
# Conflicting-derivative detection (item E)
# ========================================

"""
    _find_conflicting_derivatives(file) -> Vector{String}

Return the sorted list of fully-qualified species names that appear both as
the LHS dependent variable of an explicit `D(X, t) = ...` equation in any
`models[*]` (including subsystems) AND as a substrate or product of a
reaction in any `reaction_systems[*]` (after namespacing).

Used by `flatten` to throw `ConflictingDerivativeError` before any lowering,
and by `validate_structural` to catch the same class of error at load time.
"""
function _find_conflicting_derivatives(file::EsmFile)::Vector{String}
    explicit_lhs = Set{String}()
    if file.models !== nothing
        for (name, model) in file.models
            _collect_explicit_derivative_lhs!(explicit_lhs, model, name)
        end
    end

    reaction_species = Set{String}()
    if file.reaction_systems !== nothing
        for (name, rsys) in file.reaction_systems
            _collect_reaction_species!(reaction_species, rsys, name)
        end
    end

    conflicting = sort!(collect(intersect(explicit_lhs, reaction_species)))

    # operator_compose is ADDITIVE-merge coupling: a model's explicit `D(X)` for a
    # reaction species X is an operator CONTRIBUTION that flatten SUMS with the
    # reaction ODE (per-species / non-generic transport), not an over-determining
    # redefinition. The generic `_var` operator already relies on this (it just
    # defers naming X); naming X explicitly is the same additive merge. So a
    # species whose reaction system participates in an operator_compose coupling is
    # not a conflict.
    if !isempty(conflicting) && !isempty(file.coupling)
        op_systems = Set{String}()
        for entry in file.coupling
            entry isa CouplingOperatorCompose || continue
            for s in entry.systems
                push!(op_systems, String(s))
            end
        end
        isempty(op_systems) ||
            filter!(c -> !(String(split(c, '.')[1]) in op_systems), conflicting)
    end
    return conflicting
end

function _collect_explicit_derivative_lhs!(acc::Set{String}, model::Model, prefix::String)
    for eq in model.equations
        raw = differential_lhs_variable(eq.lhs)
        raw === nothing && continue
        # A bare name refers to a variable in this model's scope.
        push!(acc, occursin('.', raw) ? raw : "$(prefix).$(raw)")
    end
    for (sub_name, sub) in model.subsystems
        # Only Model subsystems contribute explicit-derivative LHS names.
        sub isa Model || continue
        _collect_explicit_derivative_lhs!(acc, sub, "$(prefix).$(sub_name)")
    end
    return
end

function _collect_reaction_species!(acc::Set{String}, rsys::ReactionSystem, prefix::String)
    for rxn in rsys.reactions
        # Collection-only use of the shared signed-stoichiometry iteration —
        # the sign is irrelevant here, only the species names.
        for (species, _) in each_stoich_term(rxn)
            push!(acc, "$(prefix).$(species)")
        end
    end
    for (sub_name, sub) in rsys.subsystems
        _collect_reaction_species!(acc, sub, "$(prefix).$(sub_name)")
    end
    return
end

# ========================================
# Hybrid-flattening preflight checks (§4.7.6)
# ========================================

"""
Walk every `variable_map` coupling entry with `transform == "identity"` and
raise `DomainUnitMismatchError` when the source and target variables carry
non-empty, declared-different units. `param_to_var` and `conversion_factor`
transforms are exempt: `conversion_factor` declares the conversion explicitly;
`param_to_var` replaces a parameter with a variable and does not imply unit
equivalence at the mapping site (units are still validated elsewhere).
"""
function _check_variable_map_units(file::EsmFile)
    decls = _scoped_index(file)
    for entry in file.coupling
        conflict = _variable_map_unit_conflict(decls, entry)
        conflict === nothing || throw(DomainUnitMismatchError(entry.from, conflict...))
    end
    return
end

# The `(from_units, to_units)` of an `identity` `variable_map` entry whose two
# endpoints both declare non-empty units that differ, else `nothing`. The one
# statement of the esm-spec §4.7.6 rule, read by flatten and by `validate`.
# `decls` are the document's declarations (`_scoped_index`).
function _variable_map_unit_conflict(decls::_ScopedIndex, entry)
    (entry isa CouplingVariableMap && entry.transform == "identity") || return nothing
    src_units = _lookup_variable_units(decls, entry.from)
    tgt_units = _lookup_variable_units(decls, entry.to)
    (src_units === nothing || tgt_units === nothing) && return nothing
    (isempty(src_units) || isempty(tgt_units) || src_units == tgt_units) && return nothing
    return (src_units, tgt_units)
end

"""
Resolution preflight for every `variable_map` entry: each endpoint must name a
state, parameter or observed the COLLECTED system carries, under its FULL dot
path (esm-spec §4.6). Raises `VariableMapUnresolvedEndpointError` otherwise.

Until this existed both halves failed silently: `_substitute_variable_map!`
rewrites `to` -> `from` whether or not either name binds, and
`_promote_variable_map_param!` returns early on a `to` that is not a key of
`params`. An endpoint resolving to nothing therefore produced a flattened
system indistinguishable from one where the coupling had been applied and had
simply had no effect.

Runs on the PRE-coupling tables: an `operator_compose` `translate` merge (§10.2)
legitimately consumes one of two spellings of a quantity, so checking after it
ran would flag a well-formed endpoint.

No exemption for a `from` whose owner is a `data_sources` key: a data source
is not a coupling endpoint (esm-spec §8), so a field it serves is reached
through the data-fed parameter that names it in `update.from`.

Deliberately NOT checked: whether a promoting transform's `to` is a PARAMETER
rather than an unknown. `tests/valid/scoped_refs_coupling.esm` maps
`param_to_var` onto a declared unknown, and tightening that is a separate
question from whether the endpoint resolves at all.
"""
function _check_variable_map_endpoints(
        file::EsmFile,
        states::AbstractDict{String, ModelVariable},
        params::AbstractDict{String, ModelVariable},
        observeds::AbstractDict{String, ModelVariable}
    )
    isempty(file.coupling) && return
    declared = Set{String}()
    for tbl in (states, params, observeds)
        for name in keys(tbl)
            push!(declared, name)
        end
    end
    for entry in file.coupling
        entry isa CouplingVariableMap || continue
        for (side, endpoint) in (("from", entry.from), ("to", entry.to))
            (isempty(endpoint) || endpoint in declared) && continue
            throw(VariableMapUnresolvedEndpointError(entry.from, entry.to, side, endpoint))
        end
    end
    return
end

"""
The declared units of the member a top-level scoped name names in the
declarations `decls` (a model variable, a reaction-system species or parameter,
at any depth); `nothing` when the member is missing or declares no units.
"""
function _lookup_variable_units(decls::_ScopedIndex, qualified::String)::Union{String, Nothing}
    d = _resolve_declaration(decls, "", qualified)
    return d === nothing ? nothing : d.decl.units
end

# ========================================
# Coupling rule application (§4.7.5 step 3)
# ========================================

# The `_var` placeholder: an operator_compose template equation whose LHS
# dependent variable is `_var` (or a namespaced `<prefix>._var` after
# collection) does not name a concrete state — it is expanded once per state
# variable of the other coupled systems.
const PLACEHOLDER_VAR = "_var"

# True iff `name` is the bare `_var` placeholder or any namespaced
# `<prefix>._var` form of it.
is_placeholder(name::AbstractString)::Bool =
    name == PLACEHOLDER_VAR || endswith(name, "." * PLACEHOLDER_VAR)

"""
    _apply_operator_compose!(pool, entry, states, observeds; components, renames) -> renames_made

Apply a `CouplingOperatorCompose` entry (esm-libraries-spec §4.7.1): every
equation of the B systems (`systems[2:end]`) is merged into A's (`systems[1]`)
equation for the same quantity, `rhs_A + factor * rhs_B` (step 4).

1. Each B `_var` template is cloned once per state variable of A, in A's
   declaration order, where it stands (step 3; [`_expand_placeholders`](@ref)).
2. Each B equation is matched to an A equation, in precedence order: DIRECT
   (same dependent variable), then `translate` (keyed by A's names, valued by
   B's, each endpoint qualified against its system and retargeted through the
   names earlier merges deleted, `renames`), then the BARE-NAME fallback (A's
   equation for B's local name). [`_match_compose`](@ref) decides, and changes
   nothing. Direct before `translate` is §10.2's redundancy rule: a `translate`
   value of `"B._var"` must not redirect a clone placeholder expansion already
   named.
3. The merge is reported when it merged nothing or only part of what B
   authored ([`_report_operator_compose_merge`](@ref), step 5).
4. A match that renames the quantity deletes one spelling. The surviving one is
   A's, except for a bare-name match, where ownership decides
   ([`_bare_name_owner`](@ref)). Every reference to the deleted spelling, in
   every equation, is retargeted, and its declaration pruned: a declared unknown
   with no equation would be an algebraic unknown nobody defines.
5. The merged equation keeps A's position and takes B's `D` left-hand side when
   A's was a bare definition. It is owned by its dependent variable's component,
   so a later entry finds it there; one now owned by another component than A
   moves to the end of that component's equations
   ([`_insert_into_component_blocks!`](@ref), §4.7.5 step 4 document order).
   Unmatched B equations stay where they are.

`components` is the document's component order. Returns the renames this entry
made, for the caller's document-wide record.
"""
function _apply_operator_compose!(
        pool::Vector{_FlatEq},
        entry::CouplingOperatorCompose,
        states::OrderedDict{String, ModelVariable},
        observeds::OrderedDict{String, ModelVariable};
        renames::AbstractDict = OrderedDict{String, String}(),
        components::Vector{String}
    )
    length(entry.systems) >= 2 || return OrderedDict{String, String}()
    a_name = entry.systems[1]
    b_names = Set{String}(entry.systems[2:end])
    inv_translate = _retarget_translate(
        _inverse_translate(entry.translate, a_name, entry.systems[2]), renames
    )
    expanded = _expand_placeholders(
        pool, b_names, String[k for k in keys(states) if _component_root(k) == a_name]
    )
    matches, authored, unmatched = _match_compose(expanded, a_name, b_names, inv_translate)
    _report_operator_compose_merge(entry, a_name, entry.systems[2], authored, unmatched)
    renames_made, inverted = _compose_renames(matches, states, entry, a_name)
    merged = _merge_matches(expanded, matches, inverted, a_name, components)
    if !isempty(renames_made)
        for (i, fe) in enumerate(merged)
            renamed = _rewrite_flat_eq(e -> _rename_variables(e, renames_made), fe, false)
            merged[i] = _FlatEq(
                Equation(_rename_variables(fe.eq.lhs, renames_made), renamed.eq.rhs; _comment = fe.eq._comment),
                renamed.contribs, fe.owner
            )
        end
        for gone in keys(renames_made)
            delete!(states, gone)
            delete!(observeds, gone)
        end
    end
    append!(empty!(pool), merged)
    return renames_made
end

# One B equation matched to the A equation it merges into: their positions in
# the expanded pool, B's dependent variable and the A one it matched, the
# `translate` factor, and whether the bare-name fallback found it.
struct _ComposeMatch
    b::Int
    a::Int
    b_dep::String
    target::String
    factor::Float64
    bare::Bool
end

# esm-libraries-spec §4.7.1 step 3: each `_var` template a B system authored,
# cloned once per variable of `target_vars` where it stands, with its
# contributions; a template `ic(_var) ~ e` (a field initial condition) clones
# with it. Only a template owned by one of this entry's B systems is expanded:
# another `operator_compose` naming a different operator has its own.
function _expand_placeholders(pool::Vector{_FlatEq}, b_names::Set{String}, target_vars::Vector{String})
    out = _FlatEq[]
    for fe in pool
        dep = something(lhs_dependent_variable(fe.eq.lhs), _ic_lhs_variable(fe.eq.lhs), Some(nothing))
        if dep === nothing || !is_placeholder(dep) || !(fe.owner in b_names)
            push!(out, fe)
            continue
        end
        for var in target_vars
            cs = Contribution[
                Contribution(_substitute_placeholder(c.expr, dep, var), c.origins)
                    for c in fe.contribs
            ]
            push!(
                out, _FlatEq(
                    _equation_from(fe.eq, cs; lhs = _substitute_placeholder(fe.eq.lhs, dep, var)),
                    cs, fe.owner
                )
            )
        end
    end
    return out
end

# esm-libraries-spec §4.7.1 step 3: match each B equation of `pool` to an A
# equation, DIRECT, then `translate`, then BARE-NAME, without changing
# anything. A's equation for a quantity is its first one. Returns the matches,
# the number of B equations with a dependent variable (`authored`), and the
# dependent variables of those that matched nothing.
function _match_compose(pool::Vector{_FlatEq}, a_name::String, b_names::Set{String}, inv_translate)
    a_index = Dict{String, Int}()
    for (i, fe) in enumerate(pool)
        fe.owner == a_name || continue
        dep = lhs_dependent_variable(fe.eq.lhs)
        dep === nothing || haskey(a_index, dep) || (a_index[dep] = i)
    end
    matches = _ComposeMatch[]
    authored = 0
    unmatched = String[]
    for (i, fe) in enumerate(pool)
        fe.owner in b_names || continue
        b_dep = lhs_dependent_variable(fe.eq.lhs)
        b_dep === nothing && continue
        authored += 1
        target, factor, bare = b_dep, 1.0, false
        if haskey(a_index, b_dep)
        elseif haskey(inv_translate, b_dep)
            target, factor = inv_translate[b_dep]
        else
            short = _strip_component_root(b_dep)
            for a_fe in pool
                a_fe.owner == a_name || continue
                a_dep = lhs_dependent_variable(a_fe.eq.lhs)
                if a_dep !== nothing && endswith(a_dep, "." * short)
                    target, bare = a_dep, true
                    break
                end
            end
        end
        if haskey(a_index, target)
            push!(matches, _ComposeMatch(i, a_index[target], b_dep, target, factor, bare))
        else
            push!(unmatched, b_dep)
        end
    end
    return matches, authored, unmatched
end

# esm-libraries-spec §4.7.1 step 4: the spelling each renaming match deletes,
# decided before anything is rewritten. B's dependent variable gives way to
# A's, except where a bare-name match's owner is B's spelling
# (`_bare_name_owner`); those are returned again as `inverted`, A's spelling
# => B's. Returns the whole map (renames to A first, in match order, then the
# inverted ones) and `inverted`.
function _compose_renames(matches::Vector{_ComposeMatch}, states, entry, a_name::String)
    to_a = OrderedDict{String, String}()
    bare = OrderedDict{String, String}()
    for m in matches
        m.target == m.b_dep && continue
        to_a[m.b_dep] = m.target
        m.bare && (bare[m.b_dep] = m.target)
    end
    inverted = OrderedDict{String, String}()
    for (b_dep, target) in bare
        _bare_name_owner(states, entry, a_name, entry.systems[2], b_dep, target) == b_dep || continue
        inverted[target] = b_dep
        delete!(to_a, b_dep)
    end
    made = isempty(inverted) ? to_a : OrderedDict{String, String}(merge(to_a, inverted))
    return made, inverted
end

# esm-libraries-spec §4.7.1 step 4: each matched B equation's contributions
# appended to its A equation's (one `factor * (b1 + b2 + …)` contribution, its
# origins their union, when `translate` scales them), its `D` left-hand side
# taken when A's equation is a bare definition, and the merged equation owned by
# its dependent variable's component (B's spelling under `inverted`); the
# matched B equations dropped; a merged equation now owned by a component other
# than A moved to the end of that component's equations.
function _merge_matches(
        pool::Vector{_FlatEq}, matches::Vector{_ComposeMatch}, inverted::AbstractDict,
        a_name::String, components::Vector{String}
    )
    extra = OrderedDict{Int, Vector{Contribution}}()
    d_lhs = Dict{Int, ASTExpr}()
    consumed = falses(length(pool))
    for m in matches
        b = pool[m.b]
        cs = b.contribs
        if m.factor != 1.0
            cs = Contribution[
                Contribution(
                    OpExpr("*", ASTExpr[NumExpr(m.factor), _fold_contributions(cs)]),
                    _union_origins(cs)
                ),
            ]
        end
        append!(get!(extra, m.a, Contribution[]), cs)
        a_lhs = pool[m.a].eq.lhs
        if !(a_lhs isa OpExpr && a_lhs.op == "D") && b.eq.lhs isa OpExpr && b.eq.lhs.op == "D"
            d_lhs[m.a] = b.eq.lhs
        end
        consumed[m.b] = true
    end
    out = copy(pool)
    moving = falses(length(pool))
    for (j, cs) in extra
        fe = pool[j]
        contribs = Contribution[fe.contribs; cs]
        dep = lhs_dependent_variable(fe.eq.lhs)
        owner = dep === nothing ? fe.owner : _component_root(get(inverted, dep, dep))
        out[j] = _FlatEq(_equation_from(fe.eq, contribs; lhs = get(d_lhs, j, fe.eq.lhs)), contribs, owner)
        moving[j] = owner != a_name && owner in components
    end
    keep = findall(i -> !consumed[i] && !moving[i], eachindex(out))
    any(moving) || return out[keep]
    stay = out[keep]
    _insert_into_component_blocks!(stay, out[findall(moving)], components)
    return stay
end

"""
    _compose_renames!(acc, made) -> acc

Fold a merge's fresh rename map into the running document-wide one.

Renames CHAIN: if an earlier `operator_compose` merged `B.x` onto `A.x` and a
later one merges `A.x` onto `C.x`, a document that still names `B.x` must land
on `C.x` — so the accumulated map's VALUES are retargeted through the new map
before the new pairs are added.
"""
function _compose_renames!(acc::OrderedDict{String, String}, made::AbstractDict)
    isempty(made) && return acc
    for (gone, survivor) in acc
        acc[gone] = get(made, survivor, survivor)
    end
    for (gone, survivor) in made
        acc[gone] = survivor
    end
    return acc
end

"""
    _retarget_translate(inv_translate, renames) -> Dict

Rewrite a built (inverted, namespaced) `translate` map off names an earlier
merge deleted. Both endpoints move, because either side's spelling may be the
one an earlier entry consumed.
"""
function _retarget_translate(inv_translate::AbstractDict, renames::AbstractDict)
    (isempty(renames) || isempty(inv_translate)) && return inv_translate
    out = Dict{String, Tuple{String, Float64}}()
    for (b_name, (a_name, factor)) in inv_translate
        out[get(renames, b_name, b_name)] = (get(renames, a_name, a_name), factor)
    end
    return out
end

"""
    _retarget_pending_entry(entry, renames) -> CouplingEntry

Rewrite a not-yet-applied coupling entry's BY-NAME endpoints.

§4.7 applies every `operator_compose` before any `couple` or `variable_map`, and
a renaming match DELETES the spelling it consumed. The document-wide retarget in
[`_apply_operator_compose!`](@ref) rewrites the equation ASTs — but a connector's
`from`/`to` and a `variable_map`'s `from`/`to` are plain scoped-reference STRINGS
carried on the entry, which no AST walk reaches. An entry that has not run yet
can therefore still name a state that has moved: the connector then matches
nothing and is dropped in SILENCE, and a `variable_map` `from` substitutes a DEAD
name into every equation referencing the mapped parameter.

Returns a COPY; the source document keeps what its author wrote, so the
round-trip is unaffected.
"""
_retarget_pending_entry(entry::CouplingEntry, renames::AbstractDict) = entry

function _retarget_pending_entry(entry::CouplingCouple, renames::AbstractDict)
    isempty(renames) && return entry
    raw = get(entry.connector, "equations", nothing)
    raw isa AbstractVector || return entry
    rewritten = Any[_retarget_connector_equation(item, renames) for item in raw]
    connector = Dict{String, Any}(entry.connector)
    connector["equations"] = rewritten
    return CouplingCouple(
        entry.systems, connector;
        description = entry.description, lifting = entry.lifting
    )
end

function _retarget_connector_equation(item, renames::AbstractDict)
    item isa AbstractDict || return item
    out = Dict{String, Any}(String(k) => v for (k, v) in item)
    for side in ("from", "to")
        name = get(out, side, nothing)
        name isa AbstractString || continue
        out[side] = get(renames, String(name), String(name))
    end
    expr = get(out, "expression", nothing)
    expr isa ASTExpr && (out["expression"] = _rename_variables(expr, renames))
    return out
end

function _retarget_pending_entry(entry::CouplingVariableMap, renames::AbstractDict)
    isempty(renames) && return entry
    transform = entry.transform isa ASTExpr ?
        _rename_variables(entry.transform, renames) : entry.transform
    return CouplingVariableMap(
        get(renames, entry.from, entry.from),
        get(renames, entry.to, entry.to),
        transform;
        factor = entry.factor,
        description = entry.description,
        lifting = entry.lifting
    )
end

"""
    _bare_name_owner(states, entry, a_name, b_name, b_dep, target) -> String

Which spelling owns the quantity a bare-name match unified (esm-libraries-spec
§4.7.1 step 3)?

A DIRECT match needs no decision (the two names are equal) and a `translate`
match is the author naming the surviving spelling explicitly. The BARE-NAME
fallback is the one that has to choose, and choosing `systems[1]` would make an
`operator_compose` entry mean different things in its two argument orders:
which state name, and which INITIAL CONDITION, comes out the far side.

Ownership follows the variable's own namespace, the direction step 4's
merged-equation reattribution (`_component_root`) already reaches in. The merge
deletes one of the two names, so the question is which of them survives:

  * **Both are STATES** — each carries its own initial condition, and nothing in
    the document says which one the merged tendency should integrate from.
    Refused ([`OperatorComposeAmbiguousBareNameError`](@ref)), because deciding
    it here would be a silent choice. The author says
    what they mean with `translate`, which names the surviving spelling
    outright, or with `require_match`.
  * **Exactly one is a state** — the other carries no initial condition, so
    there is nothing to lose by renaming onto the state. That one is the owner,
    in either argument order.
  * **Neither is** — no initial condition is at stake either way; the incumbent
    (`systems[1]`'s spelling) stands.
"""
function _bare_name_owner(
        states::OrderedDict{String, ModelVariable},
        entry::CouplingOperatorCompose,
        a_name::AbstractString,
        b_name::AbstractString,
        b_dep::AbstractString,
        target::AbstractString
    )::String
    b_state = haskey(states, b_dep)
    a_state = haskey(states, target)
    if b_state && a_state
        throw(
            OperatorComposeAmbiguousBareNameError(
                "operator_compose_ambiguous_bare_name: operator_compose($(a_name) + " *
                    "$(b_name)) matched '$(b_dep)' to '$(target)' on their shared local " *
                    "name alone, but BOTH are state variables and the merge keeps only " *
                    "one. Each carries its own initial condition, so the choice decides " *
                    "which the flattened system integrates from, and the document does " *
                    "not express it. Name the surviving spelling with a `translate` " *
                    "entry ({'$(target)': '$(b_dep)'}), or rename one of them."
            )
        )
    end
    return b_state ? String(b_dep) : String(target)
end

"""
    _report_operator_compose_merge(entry, a_name, b_name, authored, unmatched)

Report an `operator_compose` entry that merged nothing, or only some of what the
operator side authored (esm-libraries-spec §4.7.1 step 5).

Step 5 preserves an unmatched equation, and preserving it SILENTLY is what left
"merged everything" and "merged nothing" indistinguishable — both wrong outcomes
reachable from a document that is spec-valid and loads clean.

`require_match` is TRI-STATE, and the three states are three different things an
author can mean:

| `require_match` | zero merged                        | some but not all      |
|:----------------|:-----------------------------------|:----------------------|
| absent          | `operator_compose_no_merge` ERROR  | partial-merge warning |
| `true`          | `operator_compose_require_match_unmatched` ERROR (both cases) ||
| `false`         | permitted, silently                | permitted, silently   |

ZERO merged is an error by default because such an entry is indistinguishable
from an entry that is not there: the operator integrates a private decoupled
system from its own defaults and the mechanism gets nothing. PARTIAL stays a
warning because an operator may legitimately contribute states of its own
alongside the ones it does merge, and the format cannot tell the two apart.

`require_match: false` is the explicit opt-out — the author declaring a
standalone-contributing operator. It is a DECLARATION, not a default: an absent
flag means "I have not said", which is why it is the case that errors.
"""
function _report_operator_compose_merge(
        entry::CouplingOperatorCompose,
        a_name::AbstractString,
        b_name::AbstractString,
        authored::Int,
        unmatched::Vector{String}
    )
    (authored == 0 || isempty(unmatched)) && return
    # The author has declared a standalone-contributing operator. Nothing to
    # report: an unmatched equation is what they said to expect.
    entry.require_match === false && return
    merged = authored - length(unmatched)
    where = "operator_compose($(a_name) + $(b_name))"
    names = join(unmatched, ", ")
    if entry.require_match === true
        throw(
            OperatorComposeRequireMatchError(
                "operator_compose_require_match_unmatched: $(where) declares " *
                    "`require_match` and merged $(merged) of $(authored) equations " *
                    "'$(b_name)' authored; no equation of '$(a_name)' matches: $(names)"
            )
        )
    end
    if merged == 0
        throw(
            OperatorComposeNoMergeError(
                "operator_compose_no_merge: $(where) merged NONE of the $(authored) " *
                    "equations '$(b_name)' authored; no equation of '$(a_name)' matches: " *
                    "$(names). The entry is indistinguishable from one that is not there " *
                    "— '$(b_name)' would integrate decoupled from its own defaults and " *
                    "'$(a_name)' would receive no contribution. If '$(b_name)' really does " *
                    "contribute only states of its own, declare it with " *
                    "`require_match: false` on this entry."
            )
        )
    end
    _flatten_warn(
        "operator_compose_partial_merge",
        "$(where) merged $(merged) of $(authored) " *
            "equations '$(b_name)' authored; unmatched dependent variable(s): $(names). " *
            "The unmatched equations are preserved unchanged (esm-libraries-spec " *
            "§4.7.1 step 5), so they integrate DECOUPLED from '$(a_name)'. Set " *
            "`require_match: true` if they were meant to be contributions, or " *
            "`require_match: false` if they were not."
    )
    return
end

"""
The component a namespaced flattened name belongs to: `"A.B.x"` → `"A"`, and a
name with no dot → itself. Ownership is what tells A's equations from B's, and
after placeholder expansion it is the only thing that still can.
"""
_component_root(name::AbstractString)::String =
    (i = findfirst('.', name); i === nothing ? String(name) : String(SubString(name, 1, prevind(name, i))))

"""
A namespaced flattened name with its leading component segment removed:
`"A.x"` → `"x"`, `"A.B.x"` → `"B.x"`, and a name with no dot → itself. This is
the "short name" the bare-name fallback in [`_apply_operator_compose!`](@ref)
searches A for.
"""
_strip_component_root(name::AbstractString)::String =
    (i = findfirst('.', name); i === nothing ? String(name) : String(SubString(name, i + 1)))

"""
    _qualify_translate_endpoint(name, system) -> String

One `translate` endpoint put into the NAMESPACED form the matcher compares
against (esm-spec §10.2, esm-libraries-spec §4.7.1 step 2).

An endpoint is authored either bare (`"O3"`) or fully scoped
(`"ChemistrySystem.O3"`) — §10.10.2 lists both key and value as scoped-reference
sites — but matching runs against the namespaced dependent variable of a
flattened equation, so a bare endpoint can never match as written. It is
qualified with the system it belongs to under the direction rule: a KEY with
`systems[1]`, a VALUE with `systems[2]`.

An endpoint that ALREADY carries a dot is left exactly as written: it is either
already namespaced or names a subsystem path, and re-prefixing it would break a
map that was spelled correctly.

`_var` is exempt in either position. It is a GLOBAL sentinel (esm-spec §6.4),
never namespaced; a value of `"B._var"` is the redundant spelling §10.2 requires
to stay harmless, and it stays harmless because placeholder expansion has by
then made that equation a DIRECT match, which takes precedence over this map.
"""
function _qualify_translate_endpoint(
        name::AbstractString,
        system::AbstractString
    )::String
    isempty(name) && return String(name)
    is_placeholder(name) && return String(name)
    (occursin('.', name) || isempty(system)) && return String(name)
    return string(system, ".", name)
end

"""
    _inverse_translate(translate, a_system, b_system) -> Dict{String, Tuple{String, Float64}}

The `operator_compose` `translate` map INVERTED for matching and NAMESPACED:
`B's scoped name => (A's scoped name, factor)`.

The authored direction is normative and is NOT symmetric (esm-spec §10.2,
esm-libraries-spec §4.7.1 step 2): for `"systems": [A, B]` every KEY names a
variable of A and every VALUE names a variable of B. The matching loop walks
B's equations, so it needs the inverse; building it here is what keeps the
lookup from being done backwards, which would make a correct map match nothing.

A value is either a plain scoped-reference string or a `{"var": …, "factor": …}`
object (§10.2 shows both spellings). A value of neither shape is a malformed
payload — the `translate` dict is deliberately untyped at coercion time — and is
dropped, leaving the entry to fall back on direct matching.

Both endpoints are put into namespaced form on the way in; see
[`_qualify_translate_endpoint`](@ref) for why a bare one otherwise matches
nothing.
"""
function _inverse_translate(
        translate, a_system::AbstractString = "",
        b_system::AbstractString = ""
    )::Dict{String, Tuple{String, Float64}}
    out = Dict{String, Tuple{String, Float64}}()
    translate === nothing && return out
    for (a_var, v) in translate
        a_q = _qualify_translate_endpoint(String(a_var), a_system)
        if v isa AbstractString
            out[_qualify_translate_endpoint(String(v), b_system)] = (a_q, 1.0)
        elseif v isa AbstractDict
            b_var = get(v, "var", get(v, "to", get(v, "target", nothing)))
            b_var isa AbstractString || continue
            f = get(v, "factor", 1.0)
            out[_qualify_translate_endpoint(String(b_var), b_system)] =
                (a_q, f isa Real ? Float64(f) : 1.0)
        end
    end
    return out
end

"""
    _rename_variables(expr, renames) -> ASTExpr

Every `VarExpr` named by a key of `renames` rewritten to its value, in ONE pass
so a rename can never chain into another entry's target.

This is §4.7.1 step 4's document-wide retarget of the names an
`operator_compose` merged away. Unlike the step-4 rewrite of B's own `rhs_B`,
which touches only the dependent variable of the pair being merged, this runs
over every equation in the flattened pool: a system that is neither A nor B may
still reference `B.x` by its scoped name, and that reference has to follow the
quantity to A's spelling before B's declaration is pruned.
"""
function _rename_variables(
        expr::ASTExpr,
        renames::AbstractDict{String, String}
    )::ASTExpr
    isempty(renames) && return expr
    # A relational `join` names its key columns and overlap envelope factors as
    # bare strings, not `VarExpr` children, so each rebuilt node renames them
    # too (§4.7.5 step 2 namespaces them like any reference; CONFORMANCE_SPEC
    # §5.5.6, §5.35).
    return _rewrite_expr(
        (x, _) -> x isa VarExpr ? (t = get(renames, x.name, nothing); t === nothing ? x : VarExpr(t)) : x,
        (n, _) -> _rename_join_clauses(n, renames), expr
    )
end

function _substitute_placeholder(
        expr::ASTExpr,
        placeholder::Union{String, Nothing},
        target::String
    )::ASTExpr
    placeholder === nothing && return expr
    # `placeholder` and `target` are namespaced dependent-variable names, never
    # node-local binders, so every child field is rewritten.
    return _rewrite_expr(
        (x, _) -> (x isa VarExpr && (is_placeholder(x.name) || x.name == placeholder)) ?
            VarExpr(target) : x,
        (n, _) -> n, expr
    )
end

"""
Apply a `CouplingCouple` entry: attach the connector equations to the
flattened equation list. Connector equations come in two shapes:

  * a plain `{lhs, rhs}` equation (a raw `Equation`, or a dict whose `lhs`/`rhs`
    are already-parsed `ASTExpr`s) — appended verbatim; and

  * a `{from, to, transform, expression}` connector-transform equation
    (esm-spec §10.3), where `transform` selects how `expression` modifies the
    `to` variable's flattened ODE — see [`_apply_connector_transform!`](@ref).

A dict-shaped connector equation that is neither (no `transform`, and no parsed
`ASTExpr` `lhs`/`rhs`) is NOT silently degraded into a bogus placeholder
equation; it is recorded in `opaque_refs` (the `metadata.opaque_coupling_refs`
channel used for the other couplings the flattener cannot lower) so callers can
see the entry was skipped. The flatten error taxonomy (esm-libraries-spec
§4.7.6) has no typed error for this case; the opaque-refs channel is the
designated fallback.
"""
function _apply_couple!(
        pool::Vector{_FlatEq},
        entry::CouplingCouple,
        opaque_refs::Vector{String};
        index::Int,
        states::AbstractDict,
        components::Vector{String}
    )
    raw = get(entry.connector, "equations", nothing)
    raw isa AbstractVector || return
    # The expression a connector writes is authored by this ENTRY: its
    # contribution carries `{"coupling": index}` (esm-libraries-spec §4.7.5).
    origin = _coupling_origin(index)
    for item in raw
        if item isa Equation
            push!(pool, _FlatEq(item, _authored(item.rhs, origin)))
            continue
        end
        item isa AbstractDict || continue
        # A `{from, to, transform, expression}` connector-transform equation
        # (esm-spec §10.3) is discriminated by its `transform` key, which the
        # plain `{lhs, rhs}` form never carries.
        if _raw_haskey(item, "transform")
            _apply_connector_transform!(
                pool, item, entry, opaque_refs;
                origin = origin, states = states, components = components
            )
            continue
        end
        lhs = get(item, "lhs", nothing)
        rhs = get(item, "rhs", nothing)
        if lhs isa ASTExpr && rhs isa ASTExpr
            push!(pool, _FlatEq(Equation(lhs, rhs; _comment = "couple"), _authored(rhs, origin)))
        else
            push!(
                opaque_refs, string(
                    "couple:unparsed_connector_equation:",
                    join(entry.systems, "<->")
                )
            )
        end
    end
    return
end

"""
    _apply_connector_transform!(pool, item, entry, opaque_refs; origin, states, components)

Apply one `{from, to, transform, expression}` connector-transform equation
(esm-spec §10.3). The `transform` string selects how `expression` (parsed to an
`ASTExpr`) modifies the equation that defines `to` — the LAST equation whose
left-hand side's dependent variable is `to`, its `D(to)` tendency or a bare
definition:

  * `additive`       — append `expression` to that equation's contributions,
                       `D(to) ~ <existing rhs> + expression`, exactly as
                       [`_apply_operator_compose!`](@ref) appends B's terms. If
                       `to` is an UNKNOWN that no equation defines, the term
                       BECOMES its tendency (§4.7.2): a new `D(to, t) ~
                       expression`, placed with the equations of the top-level
                       component `to`'s first path segment names. A parameter,
                       or a name no component owns, takes no tendency and the
                       term is skipped.
  * `multiplicative` — multiply `to`'s existing tendency by `expression`:
                       `D(to) ~ (<existing rhs>) * expression`, collapsing the
                       contribution list into one whose origins are the union.
  * `replacement`    — NOT IMPLEMENTED. "Replace the variable value entirely"
                       (§10.3) is ambiguous between replacing the tendency and
                       turning `to` into an algebraic variable; rather than
                       guess, this raises a clear error.

`expression` may already be an `ASTExpr` (in-memory construction) or raw JSON
(the usual load path), in which case it is parsed. A malformed item (missing
`to`/`expression`, or a non-string `transform`) is recorded on `opaque_refs`
rather than misapplied — the same fallback the plain-equation arm uses.
"""
function _apply_connector_transform!(
        pool::Vector{_FlatEq},
        item::AbstractDict,
        entry::CouplingCouple,
        opaque_refs::Vector{String};
        origin::TermOrigin,
        states::AbstractDict,
        components::Vector{String}
    )
    transform_raw = _raw_get(item, "transform", nothing)
    to_raw = _raw_get(item, "to", nothing)
    expr_raw = _raw_get(item, "expression", nothing)

    if !(transform_raw isa AbstractString) || to_raw === nothing || expr_raw === nothing
        push!(
            opaque_refs, string(
                "couple:unparsed_connector_equation:",
                join(entry.systems, "<->")
            )
        )
        return
    end
    transform = String(transform_raw)
    to = String(to_raw)
    expression = expr_raw isa ASTExpr ? expr_raw : expression_from_json(expr_raw)

    if transform == "additive"
        _combine_tendency_term!(
            pool, to, expression, "+", origin; states = states, components = components
        )
    elseif transform == "multiplicative"
        _combine_tendency_term!(
            pool, to, expression, "*", origin; states = states, components = components
        )
    elseif transform == "replacement"
        throw(
            FlattenRefusal(
                ERROR_CODES.UNSUPPORTED_CONSTRUCT,
                "couple connector transform 'replacement' (esm-spec §10.3) is not " *
                    "implemented: its \"replace the variable value entirely\" semantics is " *
                    "ambiguous between replacing '$(to)'s tendency and making it algebraic. " *
                    "Use 'additive'/'multiplicative', or an explicit {lhs, rhs} connector " *
                    "equation."
            )
        )
    else
        throw(
            FlattenRefusal(
                ERROR_CODES.UNSUPPORTED_CONSTRUCT,
                "invalid couple connector transform '$(transform)': must be one of " *
                    "additive, multiplicative, replacement (esm-spec §10.3)."
            )
        )
    end
    return
end

"""
    _insert_into_component_blocks!(pool, items, components)

Insert each equation of `items` at the end of its owner's block of `pool`:
after the last equation owned by the owner or by any component declared before
it in `components` (document order). Items for one owner keep their order in
`items`; items landing at the same slot come out in component order. An owner
that is not a component (`""`) belongs to no block. Every item's owner must be
in `components`.

This is the one placement rule for an equation that joins a component after
collection: a `couple` term that becomes a tendency (§4.7.2) and an
`operator_compose` merge reattributed to another component (§4.7.1 step 4).
It is one pass over the list, however many items there are.
"""
function _insert_into_component_blocks!(
        pool::Vector{_FlatEq}, items::AbstractVector{_FlatEq}, components::Vector{String}
    )
    isempty(items) && return
    rank = Dict{String, Int}(c => k for (k, c) in enumerate(components))
    # `upto[k]`: the last position owned by one of components[1:k], or 0.
    upto = zeros(Int, length(components))
    for (i, fe) in enumerate(pool)
        k = get(rank, fe.owner, 0)
        k == 0 || (upto[k] = i)
    end
    for k in 2:length(upto)
        upto[k] = max(upto[k], upto[k - 1])
    end
    # Stable by component rank, which also sorts by slot: `upto` is monotone.
    order = sortperm([rank[it.owner] for it in items])
    out = sizehint!(_FlatEq[], length(pool) + length(items))
    cursor = 1
    for j in order
        last = upto[rank[items[j].owner]]
        append!(out, view(pool, cursor:last))
        cursor = max(cursor, last + 1)
        push!(out, items[j])
    end
    append!(out, view(pool, cursor:length(pool)))
    append!(empty!(pool), out)
    return
end

# Fold `expression` into the equation that defines `to`. Additive targets the
# LAST equation whose left-hand side's dependent variable is `to` (its `D(to)`
# tendency or a bare definition); multiplicative targets the LAST `D(to)`
# tendency only, never a bare `to ~ …`. `combine == "+"` (additive) appends one contribution authored by
# the coupling entry; `"*"` (multiplicative) collapses the list into ONE
# contribution, `(<left fold>) * expression`, whose origins are the union then
# the entry — the product is indivisible. When `to` has no defining equation:
#   * additive       — an UNKNOWN takes `expression` as its whole tendency, a new
#                      `D(to) ~ expression` placed after the equations of the
#                      components up to and including the one `to`'s first path
#                      segment names (where that component's equation list ends);
#                      a parameter, or a name no component owns, is skipped;
#   * multiplicative — there is no existing tendency to scale, which is an error.
function _combine_tendency_term!(
        pool::Vector{_FlatEq},
        to::String, expression::ASTExpr, combine::String,
        origin::TermOrigin;
        states::AbstractDict,
        components::Vector{String}
    )
    if combine == "*"
        idx = findlast(fe -> differential_lhs_variable(fe.eq.lhs) == to, pool)
        idx === nothing && throw(CoupleMultiplicativeNoTendencyError(to))
    else
        idx = findlast(fe -> lhs_dependent_variable(fe.eq.lhs) == to, pool)
    end
    if idx === nothing
        root = _component_root(to)
        pos = findfirst(==(root), components)
        (pos === nothing || !haskey(states, to)) && return
        eq = Equation(
            OpExpr("D", ASTExpr[VarExpr(to)], wrt = "t"), expression;
            _comment = "couple:additive"
        )
        _insert_into_component_blocks!(
            pool, [_FlatEq(eq, _authored(expression, origin), root)], components
        )
        return
    end
    existing = pool[idx]
    merged = if combine == "*"
        Contribution[
            Contribution(
                OpExpr("*", ASTExpr[_fold_contributions(existing.contribs), expression]),
                _union_origins(existing.contribs, origin)
            ),
        ]
    else
        Contribution[existing.contribs; Contribution(expression, TermOrigin[origin])]
    end
    pool[idx] = _with_contribs(existing, merged)
    return
end

"""
Apply a `CouplingVariableMap` entry: substitute the `to` parameter/variable
with the `from` variable in every flattened equation. For `param_to_var` and
`conversion_factor`, also promote `to` out of the parameters map.

When `transform` is an `ASTExpr` (esm-spec §10.4 expression transform), the target
parameter instead becomes an observed defined by the transform expression —
see the expression arm below.

From esm 1.0.0 a data source is not a coupling endpoint (esm-spec §8), so there
is no loader-producer arm here any more: a loaded field IS a parameter of the
consuming model, declared with its own `shape` and its own `update`, and needs
no shape transfer from a `param_to_var` edge.
"""
function _apply_variable_map!(
        pool::Vector{_FlatEq},
        params::OrderedDict{String, ModelVariable},
        entry::CouplingVariableMap;
        observeds::Union{OrderedDict{String, ModelVariable}, Nothing} = nothing,
        index::Int,
        shapeless::AbstractSet{String} = Set{String}()
    )
    if entry.transform isa ASTExpr
        _apply_expression_transform!(pool, params, observeds, entry, index)
        return
    end
    _substitute_variable_map!(pool, entry)
    _promote_variable_map_param!(params, entry, shapeless)
    return
end

# Expression transform (esm-spec §10.4): the entry binds the target to a
# DERIVED value. Remove the `to` parameter and introduce in its place an
# observed variable — same name, units, shape, description — whose defining
# expression is the transform, evaluated in the flattened coupled system's
# scope. References to `to` in the equations are left intact: they now
# resolve to the observed, exactly as if the author had declared it. Every
# variable reference inside the transform is (by contract) a fully-scoped
# reference, so no namespacing is applied; the expression MUST reference
# the entry's `from` variable — it is the data-flow edge the entry declares.
function _apply_expression_transform!(
        pool::Vector{_FlatEq},
        params::OrderedDict{String, ModelVariable},
        observeds::Union{OrderedDict{String, ModelVariable}, Nothing},
        entry::CouplingVariableMap,
        index::Int
    )
    from = entry.from
    to = entry.to
    transform = entry.transform::ASTExpr
    # `contains` (expression.jl) walks EVERY expression-bearing field —
    # aggregate bodies, filter predicates, bounds — so
    # the reference check is not blind to nested aggregate transforms.
    if !contains(transform, from)
        throw(
            FlattenRefusal(
                ERROR_CODES.VARIABLE_MAP_TRANSFORM_MISSING_FROM,
                "variable_map($(from) -> $(to)): expression transform does not " *
                    "reference the entry's 'from' variable '$(from)' (esm-spec §10.4)"
            )
        )
    end
    to_var = get(params, to, nothing)
    if to_var !== nothing
        delete!(params, to)
    end
    if observeds !== nothing
        observeds[to] = ModelVariable(
            UnknownVariable;
            units = to_var === nothing ? nothing : to_var.units,
            description = to_var === nothing ? nothing : to_var.description,
            shape = to_var === nothing ? nothing : to_var.shape,
            element_type = to_var === nothing ? nothing : to_var.element_type,
            # The target stays in the flattened system under its own name, so
            # its bounds stay with it (esm-spec §6.3.2).
            lb = to_var === nothing ? nothing : to_var.lb,
            ub = to_var === nothing ? nothing : to_var.ub
        )
    end
    # The defining equation (`to ~ transform`) is what MAKES `to` an observed
    # unknown from esm 1.0.0 — the declaration carries no expression, so this
    # push is the whole definition rather than a duplicate of one. The coupling
    # entry wrote that expression, so it is the definition's only author.
    push!(pool, _FlatEq(Equation(VarExpr(to), transform), _authored(transform, _coupling_origin(index))))
    return
end

# Substitute the `to` reference with `from` (optionally factor-scaled) in every
# flattened equation. Every named transform is a replacement (§4.7.3), so the
# substitution applies inside each contribution and adds no origin: it changes
# an input of a term, not who wrote it.
function _substitute_variable_map!(pool::Vector{_FlatEq}, entry::CouplingVariableMap)
    bindings = Dict{String, ASTExpr}(entry.to => _variable_map_replacement(entry))
    rewrite = _variable_map_rewrite(entry)
    for (i, fe) in enumerate(pool)
        rewritten = _rewrite_flat_eq(rewrite, fe, false)
        pool[i] = _FlatEq(
            Equation(substitute(fe.eq.lhs, bindings), rewritten.eq.rhs; _comment = fe.eq._comment),
            rewritten.contribs, fe.owner
        )
    end
    return
end

# The expression replacing a reference to a named-transform `variable_map`'s
# `to`: its `from`, scaled by `factor` when one is given.
function _variable_map_replacement(entry::CouplingVariableMap)::ASTExpr
    # `factor` is a scaling coefficient (the schema allows it on additive,
    # multiplicative and conversion_factor), applied whatever the transform. A
    # factor of 1.0 is left unwrapped.
    replacement::ASTExpr = VarExpr(entry.from)
    if entry.factor !== nothing && entry.factor != 1.0
        replacement = OpExpr(
            "*",
            ASTExpr[NumExpr(entry.factor::Float64), VarExpr(entry.from)]
        )
    end
    return replacement
end

# The rewrite a named-transform `variable_map` applies to a right-hand side in
# the flattened system — and to a variable's bound reference, which follows the
# same replacement (esm-libraries-spec §4.7.5).
function _variable_map_rewrite(entry::CouplingVariableMap)
    bindings = Dict{String, ASTExpr}(entry.to => _variable_map_replacement(entry))
    join_renames = Dict{String, String}(entry.to => entry.from)
    return e -> _rename_join_names(substitute(e, bindings), join_renames)
end

# A relational `join` names its envelope factors / key columns as bare STRINGS,
# not as `VarExpr` children — so `substitute` (which walks expressions) cannot
# see them, and `reconstruct` preserves them verbatim. But `namespace_expr`
# DOES namespace them (`_namespace_join`), which makes them references in the
# same scope as everything else: a `variable_map` that deletes the consumer
# parameter must therefore rename them too, or the join keeps pointing at a
# variable that no longer exists.
#
# This is exactly what an overlap-gated value-invention producer over a
# COUPLED rectangle buffer hits: `tgt_env = [ISRM.src_W, …]` while the
# document's `ISRM_SR.src_W -> ISRM.src_W` map has already removed
# `ISRM.src_W`, and materialisation dies on `join references unknown variable`.
#
# Taken as a MAP rather than a single pair, because the same hazard reaches the
# join from two directions: a `variable_map` deleting its consumer parameter
# (one pair, below) and an `operator_compose` renaming match deleting a
# dependent variable (a whole map, §4.7.1 step 4 / CONFORMANCE_SPEC §5.35).
_rename_join_names(expr::ASTExpr, ::AbstractDict{String, String}) = expr
function _rename_join_names(expr::OpExpr, renames::AbstractDict{String, String})
    isempty(renames) && return expr
    return _rename_join_clauses(
        map_children(x -> _rename_join_names(x, renames), expr),
        renames
    )
end

# ONE node's join clauses, without recursing — the recursion belongs to the
# caller, so a walk that already descends (`_rename_variables`) does not pay for
# a second full traversal.
_rename_join_clauses(expr::ASTExpr, ::AbstractDict{String, String}) = expr
function _rename_join_clauses(expr::OpExpr, renames::AbstractDict{String, String})
    (expr.join === nothing || isempty(renames)) && return expr
    ren(n) = get(renames, String(n), String(n))
    renclause(c::_OverlapJoinSpec) = _OverlapJoinSpec(
        String[ren(n) for n in c.src_env],
        String[ren(n) for n in c.tgt_env], c.eps,
        c.eps_given
    )
    # As in `namespacing.jl`: rename the key COLUMNS, never the clause's `syms`,
    # which are binders of the node rather than variable references.
    renclause(c) = _with_pairs(c, Tuple{String, String}[(ren(l), ren(r)) for (l, r) in c])
    return reconstruct(expr; join = Any[renclause(c) for c in expr.join])
end

# For param_to_var / conversion_factor, remove the target param from the
# parameter list — it is now driven by `from`. The source survives as its own
# declaration — units, default, `update` (esm-libraries-spec §4.7.3). When the
# removed target is shaped and the source is a data-fed parameter, the
# rewritten equations index the source with the target's indices:
#
# * a source that DECLARES NO `shape` (`shapeless` holds its scoped name, see
#   `_data_fed_without_shape`) takes the target's. Every further edge from it
#   must name a target of that same shape, so one shapeless source feeding two
#   targets of different shapes is refused whichever entry comes first;
# * a source that declares a `shape` — `[]`, a scalar buffer, included — keeps
#   it, and it must equal the target's.
#
# Either mismatch is a `VariableMapShapeConflictError`.
function _promote_variable_map_param!(
        params::OrderedDict{String, ModelVariable},
        entry::CouplingVariableMap,
        shapeless::AbstractSet{String} = Set{String}()
    )
    (entry.transform == "param_to_var" || entry.transform == "conversion_factor") ||
        return
    haskey(params, entry.to) || return
    target = params[entry.to]
    delete!(params, entry.to)
    target_shape = target.shape === nothing ? String[] : target.shape
    isempty(target_shape) && return
    source = get(params, entry.from, nothing)
    (source === nothing || !_is_data_fed(source)) && return
    source_shape = source.shape === nothing ? String[] : source.shape
    took_shape = entry.from in shapeless
    if took_shape && isempty(source_shape)
        params[entry.from] = _with_shape(source, copy(target_shape))
        return
    end
    source_shape == target_shape && return
    throw(
        VariableMapShapeConflictError(
            entry.from, entry.to, copy(source_shape), copy(target_shape), took_shape
        )
    )
end

"""
    _data_fed_without_shape(file::EsmFile) -> Set{String}

The scoped names of every data-fed parameter ([`_is_data_fed`](@ref)) that
declares no `shape`, in models and reaction systems at any subsystem depth.

Absent and `[]` differ here, and only here: `[]` declares a scalar buffer,
while an absent `shape` takes that of the `param_to_var` target the parameter
replaces (esm-libraries-spec §4.7.3, esm-spec §8.5.1). The difference is read
off the declarations rather than the collected tables, which other passes are
free to reshape.
"""
function _data_fed_without_shape(file::EsmFile)
    names = Set{String}()
    _for_each_data_param(file) do scope, name, var, _
        var isa ModelVariable && var.type != ParameterVariable && return
        (var.shape === nothing && _is_data_fed(var)) && push!(names, "$scope.$name")
        return
    end
    return names
end

"""
    _is_data_fed(rule::ParameterUpdate) -> Bool
    _is_data_fed(param) -> Bool

A `kind: "data"` update rule with a `from` binding (esm-spec §5.4/§8.5); a
parameter (a model variable or a reaction-system parameter) with such a rule.
Whether the named source is declared is a separate question:
`data_source_undefined` is the validator's finding, and the callers that need
a declared source (`_loader_fields`) test `rule.source` themselves.
"""
_is_data_fed(rule::ParameterUpdate) = rule.kind == "data" && rule.from !== nothing
_is_data_fed(v::Union{ModelVariable, Parameter}) =
    v.update !== nothing && any(_is_data_fed, v.update)

# ========================================
# Coupling entry descriptions
# ========================================

"""
    describe_coupling_entry(entry::CouplingEntry) -> String

Produce a human-readable description of a coupling entry for the flattened
system's metadata. One method per concrete coupling type; the
`CouplingEntry` fallback covers any future/unknown subtype.
"""
describe_coupling_entry(entry::CouplingEntry)::String =
    "unknown_coupling($(typeof(entry)))"

# Append the optional free-text description shared by every coupling type.
_with_coupling_description(desc::String, description) =
    description === nothing ? desc : desc * " -- $(description)"

describe_coupling_entry(entry::CouplingOperatorCompose)::String =
    _with_coupling_description(
    "operator_compose($(join(entry.systems, " + ")))", entry.description
)

describe_coupling_entry(entry::CouplingCouple)::String =
    _with_coupling_description(
    "couple($(join(entry.systems, " <-> ")))", entry.description
)

function describe_coupling_entry(entry::CouplingVariableMap)::String
    transform_str = entry.transform isa ASTExpr ?
        "expression" : entry.transform
    desc = "variable_map($(entry.from) -> $(entry.to), transform=$(transform_str))"
    if entry.factor !== nothing
        desc *= " [factor=$(entry.factor)]"
    end
    return _with_coupling_description(desc, entry.description)
end

describe_coupling_entry(entry::CouplingOperatorApply)::String =
    _with_coupling_description("operator_apply($(entry.operator))", entry.description)

describe_coupling_entry(entry::CouplingCallback)::String =
    _with_coupling_description("callback($(entry.callback_id))", entry.description)

describe_coupling_entry(entry::CouplingEvent)::String =
    _with_coupling_description("event($(entry.event_type))", entry.description)
