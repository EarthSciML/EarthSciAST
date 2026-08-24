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
    isempty(file.coupling) && return
    for entry in file.coupling
        entry isa CouplingVariableMap || continue
        entry.transform == "identity" || continue
        src_units = _lookup_variable_units(file, entry.from)
        tgt_units = _lookup_variable_units(file, entry.to)
        (src_units === nothing || tgt_units === nothing) && continue
        if src_units != tgt_units
            throw(DomainUnitMismatchError(entry.from, src_units, tgt_units))
        end
    end
    return
end

"""
Look up a dot-qualified variable's declared units across models, subsystems,
and reaction systems (species + parameters). Returns `nothing` when the
variable is missing or carries no declared units.
"""
function _lookup_variable_units(file::EsmFile, qualified::String)::Union{String, Nothing}
    parts = split(qualified, ".")
    length(parts) >= 2 || return nothing
    root = String(parts[1])
    tail = String(join(parts[2:end], "."))

    if file.models !== nothing && haskey(file.models, root)
        return _lookup_model_units(file.models[root], tail)
    end
    if file.reaction_systems !== nothing && haskey(file.reaction_systems, root)
        return _lookup_rsys_units(file.reaction_systems[root], tail)
    end
    return nothing
end

function _lookup_model_units(model::Model, name::String)::Union{String, Nothing}
    if haskey(model.variables, name)
        return model.variables[name].units
    end
    # Recurse into subsystems for nested names like "Inner.T".
    dot = findfirst('.', name)
    if dot !== nothing
        head = String(SubString(name, 1, dot - 1))
        rest = String(SubString(name, dot + 1))
        if haskey(model.subsystems, head)
            return _lookup_model_units(model.subsystems[head], rest)
        end
    end
    return nothing
end

function _lookup_rsys_units(rsys::ReactionSystem, name::String)::Union{String, Nothing}
    for sp in rsys.species
        sp.name == name && return sp.units
    end
    for p in rsys.parameters
        p.name == name && return p.units
    end
    dot = findfirst('.', name)
    if dot !== nothing
        head = String(SubString(name, 1, dot - 1))
        rest = String(SubString(name, dot + 1))
        if haskey(rsys.subsystems, head)
            return _lookup_rsys_units(rsys.subsystems[head], rest)
        end
    end
    return nothing
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
    _apply_operator_compose!(equations, entry, states, observeds, owners)

Apply a `CouplingOperatorCompose` entry (esm-libraries-spec §4.7.1). For
`"systems": [A, B, …]` every B system's equations are merged INTO A's: B's
`_var` placeholder equations are expanded once per state variable of A
(step 3), each B equation is then matched to A's equation for the same
dependent variable — directly, through the `translate` map (step 2), or by the
bare-name fallback — and a matched pair is summed as `rhs_A + factor * rhs_B`
(step 4). A B equation that matches nothing survives unchanged (step 5).

Six properties here are load-bearing, and each of them has a way of failing
SILENTLY — which is the one outcome a coupling mis-specification must not have:

  * **`translate` direction.** The map is keyed by A's names and valued by B's
    (§4.7.1 step 2, esm-spec §10.2). This loop walks B's equations, so it needs
    the map the other way round; [`_inverse_translate`](@ref) builds it.
    Indexing the authored map by B's dependent variable makes a correctly
    spelled map match nothing at all and turns the whole entry into a no-op.

  * **`translate` endpoints are matched NAMESPACED.** An endpoint is authored
    either bare (`"O3"`) or fully scoped (`"ChemistrySystem.O3"`; esm-spec §10.2
    admits both), but this loop matches against the NAMESPACED dependent
    variable of a flattened equation. A bare endpoint therefore has to be
    qualified first — a key against `systems[1]`, a value against `systems[2]`;
    see [`_qualify_translate_endpoint`](@ref). This is the second half of the
    direction rule and fails the same way: before it, every `translate` map in
    the shared fixture tree was authored bare, missed, fell through to the
    bare-name fallback (which searches A for B's SHORT name and misses too), and
    silently no-op'd — so the direction fix above was necessary and not
    sufficient, and step 4's rewrite below had never once run.

  * **The merged-away name does not survive.** A match that RENAMES the
    dependent variable — a translation match, or the bare-name fallback, which
    is a name-based translation — has just consumed B's defining equation, so
    B's declaration of that name constrains nothing: an unknown with no equation
    is an ALGEBRAIC unknown (§6.3.1), i.e. a structurally singular system the
    solver rejects instead of the coupling that caused it. The declaration is
    dropped, and every surviving reference to it is retargeted at A's spelling
    FIRST. The retarget is DOCUMENT-WIDE, not B-local — a third system may
    reference `B.x` by its scoped name, and pruning the declaration while
    leaving that reference dangling trades one broken system for another.

  * **Direct match BEFORE translation match.** §10.2's redundancy invariant: a
    `translate` value of `"B._var"` asks for something placeholder expansion
    already does, and writing it MUST NOT change the result. Expansion has by
    then rewritten `_var` to A's OWN variable name, so a map consulted on that
    post-expansion name hits spuriously and redirects every composed species to
    the same target — collapsing three transported species into one equation
    and leaving the other two as unconstrained algebraic unknowns. That is
    exactly what `tests/scoping/bare_reference_resolution.esm` used to produce.

  * **The placeholder ranges over A's STATE VARIABLES**, not over "everything
    with a defining equation". An observed unknown defined algebraically
    (`Chemistry.deposition_flux ~ Chemistry.O3 * 1e-3`) is not transported and
    must not collect an advection term.

  * **The merged equation keeps A's POSITION.** §4.7.5 step 4 makes document
    order normative and says a coupling-merged entry keeps the position of its
    first occurrence; appending the merge to the end of the list instead
    reorders the flattened equation vector against every other binding.
"""
function _apply_operator_compose!(equations::Vector{Equation},
                                  entry::CouplingOperatorCompose,
                                  states::OrderedDict{String, ModelVariable},
                                  observeds::OrderedDict{String, ModelVariable},
                                  owners::Vector{String})
    length(entry.systems) >= 2 || return
    a_name = entry.systems[1]
    b_names = Set{String}(entry.systems[2:end])
    # `owners` is parallel to `equations` and records the COMPONENT THAT
    # AUTHORED each one (see `_attribute_equations!`). It cannot be recovered
    # from the equation itself: `tests/valid/advection_reaction_loaded_ic_bc.esm`
    # has the operator component `Advection` write `D(Chemistry.O3, t) = …`
    # directly — B's equation, A's variable name — and placeholder expansion
    # produces exactly the same shape. Reading ownership off the dependent
    # variable's prefix therefore mistakes B's equations for A's, silently
    # dropping the merge (two equations for one state) or, where it does merge,
    # summing `rhs_B + rhs_A` where §4.7.1 step 4 says `rhs_A + factor * rhs_B`.
    while length(owners) < length(equations)
        push!(owners, "")
    end

    # §4.7.1 step 3: A's state variables, in DECLARATION order — the order the
    # placeholder clones are emitted in, and therefore the order any unmatched
    # clone lands in the equation vector.
    target_vars = String[k for k in keys(states) if _component_root(k) == a_name]

    # Step 2, in the normative direction AND in namespaced form (see the
    # docstring). `systems[2]` is the system a bare VALUE belongs to; §10.2
    # spells the map over a two-system entry, so a further B system's variables
    # have to be written scoped to be nameable at all.
    inv_translate = _inverse_translate(entry.translate, a_name, entry.systems[2])

    # Step 3: expand each `_var` template where it stands, so that a clone which
    # matches nothing keeps B's document position (step 5). Only a template
    # owned by one of THIS entry's operator systems is expanded — a second
    # `operator_compose` naming a different operator has its own template, and
    # the first entry must not consume it. Ownership travels with the clones,
    # which is the only way it survives: after substitution they carry A's
    # variable names and are textually A's own equations.
    expanded = Equation[]
    new_owners = String[]
    for (i, eq) in enumerate(equations)
        owner = owners[i]
        dep = lhs_dependent_variable(eq.lhs)
        if dep !== nothing && is_placeholder(dep) && owner in b_names
            for var in target_vars
                push!(expanded, Equation(_substitute_placeholder(eq.lhs, dep, var),
                                         _substitute_placeholder(eq.rhs, dep, var);
                                         _comment=eq._comment))
                push!(new_owners, owner)
            end
        else
            push!(expanded, eq)
            push!(new_owners, owner)
        end
    end

    # A's equations, indexed by dependent variable → position. First occurrence
    # wins, which is the position §4.7.5 step 4 says the merge keeps.
    a_index = Dict{String, Int}()
    for (i, eq) in enumerate(expanded)
        new_owners[i] == a_name || continue
        dep = lhs_dependent_variable(eq.lhs)
        dep === nothing && continue
        haskey(a_index, dep) || (a_index[dep] = i)
    end

    # Step 3 (matching) + step 4 (summing). Terms are accumulated per target and
    # summed into ONE flat `+` node at the end, so `rhs_A + rhs_B1 + rhs_B2`
    # renders the way it did before this became a position-preserving merge.
    extra = Dict{Int, Vector{ASTExpr}}()
    consumed = falses(length(expanded))
    # B's dependent variable ⇒ A's, for every match that RENAMED it. Ordered so
    # the retarget/prune below is deterministic.
    merged_away = OrderedDict{String, String}()
    for (i, eq) in enumerate(expanded)
        new_owners[i] in b_names || continue
        b_dep = lhs_dependent_variable(eq.lhs)
        b_dep === nothing && continue

        # §4.7.1 step 3 lists the match kinds in PRECEDENCE order and the order
        # is load-bearing (see the docstring): DIRECT, then TRANSLATION, then
        # the bare-name fallback.
        target = b_dep
        factor = 1.0
        if haskey(a_index, b_dep)
            # DIRECT match — tried first; `target` is already right.
        elseif haskey(inv_translate, b_dep)
            target, factor = inv_translate[b_dep]   # TRANSLATION match
        else
            # Bare-name fallback: A's equation for B's SHORT name, if any. This
            # is a name-based translation, so a hit renames like one.
            short = _strip_component_root(b_dep)
            for (k, a_eq) in enumerate(expanded)
                new_owners[k] == a_name || continue
                a_dep = lhs_dependent_variable(a_eq.lhs)
                a_dep === nothing && continue
                if endswith(a_dep, "." * short)
                    target = a_dep
                    break
                end
            end
        end
        haskey(a_index, target) || continue

        rhs_b = eq.rhs
        if target != b_dep
            # §4.7.1 step 4: on a translation match the pair names ONE physical
            # quantity in two spellings, and B's spelling is about to lose its
            # defining equation to the merge. Rewriting B's dependent variable —
            # and ONLY it; B's parameters and observeds keep their names — is
            # what keeps the merged system from carrying an unknown that nothing
            # defines. On a direct or placeholder match this rewrite is the
            # identity, which is why it is guarded rather than unconditional.
            rhs_b = _rename_variable(rhs_b, b_dep, target)
            merged_away[b_dep] = target
        end
        if factor != 1.0
            rhs_b = OpExpr("*", ASTExpr[NumExpr(factor), rhs_b])
        end
        push!(get!(extra, a_index[target], ASTExpr[]), rhs_b)
        consumed[i] = true
    end

    if !isempty(extra)
        for (j, terms) in extra
            eq = expanded[j]
            expanded[j] = Equation(eq.lhs,
                                   OpExpr("+", ASTExpr[eq.rhs; terms...]);
                                   _comment=eq._comment)
        end
    end

    # Step 5: everything not consumed by a merge survives, in document order.
    if any(consumed)
        keep = findall(!, consumed)
        kept_eqs = Equation[expanded[i] for i in keep]
        kept_owners = String[new_owners[i] for i in keep]
        expanded, new_owners = kept_eqs, kept_owners
    end

    # §4.7.1 step 4, the merged-away name (see the docstring). Retarget FIRST,
    # then prune: a reference rewritten after its declaration is gone is a
    # reference to nothing, and the retarget is what makes the prune safe.
    if !isempty(merged_away)
        for (i, eq) in enumerate(expanded)
            expanded[i] = Equation(_rename_variables(eq.lhs, merged_away),
                                   _rename_variables(eq.rhs, merged_away);
                                   _comment=eq._comment)
        end
        for gone in keys(merged_away)
            delete!(states, gone)
            delete!(observeds, gone)
        end
    end

    empty!(equations); append!(equations, expanded)
    empty!(owners);    append!(owners, new_owners)
    return
end

"""
    _attribute_equations!(owners, equations, name)

Extend `owners` so it is parallel to `equations` again, attributing every newly
appended equation to component `name` (`""` for one no component authored — an
equation a coupling rule itself introduced).

Provenance is recorded here rather than derived later because it is genuinely
NOT derivable: the flattener keeps one flat equation pool, and after namespacing
an operator component's equation for a chemistry species is textually
indistinguishable from the chemistry component's own. §4.7.1 step 4's
`rhs_A + factor * rhs_B` needs to know which is which. Every mutation between
collection and the compose either APPENDS (a `couple` connector equation, a
`variable_map`'s derived-value definition) or replaces in place, so padding at
the end is always the correct resync.
"""
function _attribute_equations!(owners::Vector{String},
                               equations::Vector{Equation},
                               name::AbstractString)
    while length(owners) < length(equations)
        push!(owners, String(name))
    end
    return owners
end

"""
The component a namespaced flattened name belongs to: `"A.B.x"` → `"A"`, and a
name with no dot → itself. Ownership is what tells A's equations from B's, and
after placeholder expansion it is the only thing that still can.
"""
_component_root(name::AbstractString)::String =
    (i = findfirst('.', name); i === nothing ? String(name) : String(SubString(name, 1, i - 1)))

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
function _qualify_translate_endpoint(name::AbstractString,
                                     system::AbstractString)::String
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
function _inverse_translate(translate, a_system::AbstractString="",
                            b_system::AbstractString="")::Dict{String, Tuple{String, Float64}}
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
    _rename_variable(expr, from, to) -> ASTExpr

Every `VarExpr` named exactly `from` rewritten to `to`; everything else — other
variables, operators, every non-expression field — untouched. This is §4.7.1
step 4's dependent-variable rewrite, which is deliberately NOT a general
substitution: B's parameters and observeds keep their own names.
"""
function _rename_variable(expr::ASTExpr, from::AbstractString,
                          to::AbstractString)::ASTExpr
    if expr isa VarExpr
        return expr.name == from ? VarExpr(String(to)) : expr
    elseif expr isa OpExpr
        return map_children(x -> _rename_variable(x, from, to), expr)
    end
    return expr
end

"""
    _rename_variables(expr, renames) -> ASTExpr

[`_rename_variable`](@ref) over a whole map at once, applied to every `VarExpr`
in ONE pass so a rename can never chain into another entry's target.

This is §4.7.1 step 4's document-wide retarget of the names an
`operator_compose` merged away. Unlike the step-4 rewrite of B's own `rhs_B`,
which touches only the dependent variable of the pair being merged, this runs
over every equation in the flattened pool: a system that is neither A nor B may
still reference `B.x` by its scoped name, and that reference has to follow the
quantity to A's spelling before B's declaration is pruned.
"""
function _rename_variables(expr::ASTExpr,
                           renames::AbstractDict{String, String})::ASTExpr
    isempty(renames) && return expr
    if expr isa VarExpr
        to = get(renames, expr.name, nothing)
        return to === nothing ? expr : VarExpr(to)
    elseif expr isa OpExpr
        return map_children(x -> _rename_variables(x, renames), expr)
    end
    return expr
end

function _substitute_placeholder(expr::ASTExpr,
                                 placeholder::Union{String, Nothing},
                                 target::String)::ASTExpr
    placeholder === nothing && return expr
    if expr isa NumExpr || expr isa IntExpr
        return expr
    elseif expr isa VarExpr
        if is_placeholder(expr.name) || expr.name == placeholder
            return VarExpr(target)
        end
        return expr
    elseif expr isa OpExpr
        # Recurse into EVERY expression-bearing field via the shared field-preserving
        # rewrite and rebuild via `reconstruct`, which preserves all other fields
        # (table/table_axes, int_var, join, id, manifold, key, …) that a hand-listed
        # keyword subset used to drop. `placeholder`/`target` are namespaced
        # dependent-variable names, never node-local binders, so recursing into
        # every field cannot capture a bound index or `int_var`.
        return map_children(x -> _substitute_placeholder(x, placeholder, target), expr)
    end
    return expr
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
see the entry was skipped. The spec taxonomy (§4.7.6, 8 error types for
cross-language parity) has no matching typed error, and adding a ninth is
forbidden — the opaque-refs channel is the designated fallback.
"""
function _apply_couple!(equations::Vector{Equation},
                        entry::CouplingCouple,
                        opaque_refs::Vector{String})
    raw = get(entry.connector, "equations", nothing)
    raw isa AbstractVector || return
    for item in raw
        if item isa Equation
            push!(equations, item)
            continue
        end
        item isa AbstractDict || continue
        # A `{from, to, transform, expression}` connector-transform equation
        # (esm-spec §10.3) is discriminated by its `transform` key, which the
        # plain `{lhs, rhs}` form never carries.
        if _has_field(item, :transform)
            _apply_connector_transform!(equations, item, entry, opaque_refs)
            continue
        end
        lhs = get(item, "lhs", nothing)
        rhs = get(item, "rhs", nothing)
        if lhs isa ASTExpr && rhs isa ASTExpr
            push!(equations, Equation(lhs, rhs; _comment="couple"))
        else
            push!(opaque_refs, string(
                "couple:unparsed_connector_equation:",
                join(entry.systems, "<->")))
        end
    end
    return
end

"""
    _apply_connector_transform!(equations, item, entry, opaque_refs)

Apply one `{from, to, transform, expression}` connector-transform equation
(esm-spec §10.3). The `transform` string selects how `expression` (parsed to an
`ASTExpr`) modifies the `to` variable's flattened ODE:

  * `additive`       — add `expression` as a source/sink term to `to`'s
                       tendency: `D(to) ~ <existing rhs> + expression`. The term
                       is folded onto the existing `D(to)` equation exactly as
                       [`_apply_operator_compose!`](@ref) sums equations that
                       share a dependent variable. If `to` has no tendency yet,
                       `expression` becomes it.
  * `multiplicative` — multiply `to`'s existing tendency by `expression`:
                       `D(to) ~ (<existing rhs>) * expression`.
  * `replacement`    — NOT IMPLEMENTED. "Replace the variable value entirely"
                       (§10.3) is ambiguous between replacing the tendency and
                       turning `to` into an algebraic variable; rather than
                       guess, this raises a clear error.

`expression` may already be an `ASTExpr` (in-memory construction) or raw JSON
(the usual load path), in which case it is parsed. A malformed item (missing
`to`/`expression`, or a non-string `transform`) is recorded on `opaque_refs`
rather than misapplied — the same fallback the plain-equation arm uses.
"""
function _apply_connector_transform!(equations::Vector{Equation},
                                     item::AbstractDict,
                                     entry::CouplingCouple,
                                     opaque_refs::Vector{String})
    transform_raw = _get_field(item, :transform, nothing)
    to_raw = _get_field(item, :to, nothing)
    expr_raw = _get_field(item, :expression, nothing)

    if !(transform_raw isa AbstractString) || to_raw === nothing || expr_raw === nothing
        push!(opaque_refs, string(
            "couple:unparsed_connector_equation:",
            join(entry.systems, "<->")))
        return
    end
    transform = String(transform_raw)
    to = String(to_raw)
    expression = expr_raw isa ASTExpr ? expr_raw : expression_from_json(expr_raw)

    if transform == "additive"
        _combine_tendency_term!(equations, to, expression, "+")
    elseif transform == "multiplicative"
        _combine_tendency_term!(equations, to, expression, "*")
    elseif transform == "replacement"
        throw(ArgumentError(
            "couple connector transform 'replacement' (esm-spec §10.3) is not " *
            "implemented: its \"replace the variable value entirely\" semantics is " *
            "ambiguous between replacing '$(to)'s tendency and making it algebraic. " *
            "Use 'additive'/'multiplicative', or an explicit {lhs, rhs} connector " *
            "equation."))
    else
        throw(ArgumentError(
            "invalid couple connector transform '$(transform)': must be one of " *
            "additive, multiplicative, replacement (esm-spec §10.3)."))
    end
    return
end

# Fold `expression` into the `to` state's tendency in place: rewrite the RHS of
# the existing `D(to) ~ …` equation to `combine(<existing rhs>, expression)`
# (`combine == "+"` for additive, `"*"` for multiplicative). This mirrors the
# shared-dependent-variable RHS merge in `_apply_operator_compose!`. When no
# `D(to)` equation exists yet:
#   * additive       — `expression` becomes the whole tendency (`D(to) ~ expression`);
#   * multiplicative — there is no existing tendency to scale, which is an error.
function _combine_tendency_term!(equations::Vector{Equation},
                                 to::String, expression::ASTExpr, combine::String)
    idx = findfirst(eq -> differential_lhs_variable(eq.lhs) == to, equations)
    if idx === nothing
        if combine == "*"
            throw(ArgumentError(
                "couple connector 'multiplicative' transform targets '$(to)', which " *
                "has no tendency (`D($(to))`) to multiply (esm-spec §10.3)."))
        end
        push!(equations, Equation(
            OpExpr("D", ASTExpr[VarExpr(to)], wrt="t"), expression;
            _comment="couple:additive"))
        return
    end
    existing = equations[idx]
    new_rhs = OpExpr(combine, ASTExpr[existing.rhs, expression])
    equations[idx] = Equation(existing.lhs, new_rhs; _comment=existing._comment)
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
function _apply_variable_map!(equations::Vector{Equation},
                              params::OrderedDict{String, ModelVariable},
                              entry::CouplingVariableMap;
                              observeds::Union{OrderedDict{String, ModelVariable},Nothing}=nothing)
    if entry.transform isa ASTExpr
        _apply_expression_transform!(equations, params, observeds, entry)
        return
    end
    _substitute_variable_map!(equations, entry)
    _promote_variable_map_param!(params, entry)
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
function _apply_expression_transform!(equations::Vector{Equation},
                                      params::OrderedDict{String, ModelVariable},
                                      observeds::Union{OrderedDict{String, ModelVariable},Nothing},
                                      entry::CouplingVariableMap)
    from = entry.from
    to = entry.to
    transform = entry.transform::ASTExpr
    # `contains` (expression.jl) walks EVERY expression-bearing field —
    # aggregate bodies, filter predicates, bounds, table-lookup axes — so
    # the reference check is not blind to nested aggregate transforms.
    if !contains(transform, from)
        throw(ArgumentError(
            "variable_map($(from) -> $(to)): expression transform does not " *
            "reference the entry's 'from' variable '$(from)' (esm-spec §10.4)"))
    end
    to_var = get(params, to, nothing)
    if to_var !== nothing
        delete!(params, to)
    end
    if observeds !== nothing
        observeds[to] = ModelVariable(UnknownVariable;
            units=to_var === nothing ? nothing : to_var.units,
            description=to_var === nothing ? nothing : to_var.description,
            shape=to_var === nothing ? nothing : to_var.shape)
    end
    # The defining equation (`to ~ transform`) is what MAKES `to` an observed
    # unknown from esm 1.0.0 — the declaration carries no expression, so this
    # push is the whole definition rather than a duplicate of one.
    push!(equations, Equation(VarExpr(to), transform))
    return
end

# Substitute the `to` reference with `from` (optionally factor-scaled) in every
# flattened equation.
function _substitute_variable_map!(equations::Vector{Equation},
                                   entry::CouplingVariableMap)
    # Build replacement ASTExpr. `factor` is a scaling coefficient (schema restricts
    # it to the scaling transforms — additive / multiplicative / conversion_factor;
    # a bare param_to_var / identity may not carry one). Apply it uniformly here
    # so all three bindings agree — Julia/Rust previously scaled only for
    # `conversion_factor`, silently dropping it for additive/multiplicative while
    # Python applied it. A factor of 1.0 is a no-op and left unwrapped.
    replacement::ASTExpr = VarExpr(entry.from)
    if entry.factor !== nothing && entry.factor != 1.0
        replacement = OpExpr("*",
            ASTExpr[NumExpr(entry.factor::Float64), VarExpr(entry.from)])
    end

    bindings = Dict{String, ASTExpr}(entry.to => replacement)
    for (i, eq) in enumerate(equations)
        equations[i] = Equation(
            substitute(eq.lhs, bindings),
            _rename_join_names(substitute(eq.rhs, bindings), entry.to, entry.from);
            _comment=eq._comment,
        )
    end
    return
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
_rename_join_names(expr::ASTExpr, ::AbstractString, ::AbstractString) = expr
function _rename_join_names(expr::OpExpr, to::AbstractString, from::AbstractString)
    out = map_children(x -> _rename_join_names(x, to, from), expr)
    (out isa OpExpr && out.join !== nothing) || return out
    ren(n) = String(n) == String(to) ? String(from) : String(n)
    renclause(c::_OverlapJoinSpec) = _OverlapJoinSpec(String[ren(n) for n in c.src_env],
                                                      String[ren(n) for n in c.tgt_env], c.eps)
    renclause(c) = Tuple{String,String}[(ren(l), ren(r)) for (l, r) in c]
    return reconstruct(out; join=Any[renclause(c) for c in out.join])
end

# For param_to_var / conversion_factor, remove the target param from the
# parameter list — it is now driven by `from`.
function _promote_variable_map_param!(params::OrderedDict{String, ModelVariable},
                                      entry::CouplingVariableMap)
    (entry.transform == "param_to_var" || entry.transform == "conversion_factor") ||
        return
    haskey(params, entry.to) || return
    delete!(params, entry.to)
    return
end

# ========================================
# Coupling entry descriptions (unchanged from prior implementation)
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
        "operator_compose($(join(entry.systems, " + ")))", entry.description)

describe_coupling_entry(entry::CouplingCouple)::String =
    _with_coupling_description(
        "couple($(join(entry.systems, " <-> ")))", entry.description)

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
