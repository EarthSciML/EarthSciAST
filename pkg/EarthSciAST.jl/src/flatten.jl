"""
Coupled System Flattening for ESM Format.

Implements spec §4.7.5 (flattening algorithm) and §4.7.6 (dimension promotion).

`flatten(::EsmFile)` produces a `FlattenedSystem`: a single flat equation system
with dot-namespaced variables and real ASTExpr-tree equations. Reactions are lowered
to ODEs via `lower_reactions_to_equations`; coupling rules merge RHS terms;
`variable_map` substitutes parameters; `operator_apply`/`callback` are recorded
opaquely in metadata.

This file holds the `FlattenedSystem` type, the `flatten` orchestrator and its
stages over `FlattenState`, the right-hand-side time-derivative resolution,
angle normalization and the document exporter `flattened_to_esm`. The other
pieces of the pipeline:
- `reactions.jl` — reaction → ODE lowering (`lower_reactions_to_equations`);
- `flatten_errors.jl` — the exported §4.7.5/§4.7.6 error taxonomy;
- `expr_axes.jl` — the one inference of an expression's index sets;
- `namespacing.jl` — dot-namespacing + per-system collection (steps 1+2);
- `coupling_apply.jl` — preflight checks + coupling-rule application (step 3);
- `term_provenance.jl` — per-term provenance and the equation record `_FlatEq`;
- `cell_read.jl` — reading an array expression at one cell, shared by the lifts;
- `pointwise_lift.jl` — the §10.5 pointwise spatial lift (step 3b);
- `shape_promotion.jl`, `elementwise_lift.jl` — shape promotion and the
  elementwise template lift;
- `array_shape_inference.jl` — numeric extents for ModelingToolkit
  (`infer_array_shapes`).
"""

using OrderedCollections: OrderedDict

# ========================================
# Types
# ========================================

"""
    FlattenMetadata

Provenance metadata for a flattened system.

Fields:
- `source_systems::Vector{String}`: names of the component systems that were
  flattened, in document order (models, then reaction systems).
- `coupling_rules_applied::Vector{String}`: human-readable summary of each
  coupling entry applied.
- `dimension_promotions_applied::Vector{NamedTuple}`: always empty; no flatten
  pass records into it.
- `opaque_coupling_refs::Vector{String}`: opaque runtime references recorded
  for `operator_apply` and `callback` couplings.
- `merged_variable_renames::OrderedDict{String,String}`: every state spelling an
  `operator_compose` renaming match DELETED, mapped onto the survivor it was
  folded into. The flattener's own retarget reaches equation ASTs;
  this is the map a CONSUMER that addresses a state by name needs — a
  `parameter_overrides` / `initial_conditions` key, an output selection — to
  resolve a spelling the merge moved out from under it. Empty for a document
  with no renaming merge, which is the overwhelming majority.
- `reserved_liftings::Vector{NTuple{3,String}}`: every `variable_map` whose
  `lifting` esm-spec §10.5 reserves (`mean`, `integral`), as
  `(from, to, lifting)` in coupling order after `coupling_import` expansion.
  Flatten leaves such an edge's source unreduced, so a build refuses the system
  (`_refuse_reserved_liftings`), from a flattened system as from a document.
"""
struct FlattenMetadata
    source_systems::Vector{String}
    coupling_rules_applied::Vector{String}
    dimension_promotions_applied::Vector{NamedTuple}
    opaque_coupling_refs::Vector{String}
    merged_variable_renames::OrderedDict{String, String}
    reserved_liftings::Vector{NTuple{3, String}}
end

FlattenMetadata(
    source_systems::Vector{String} = String[],
    coupling_rules_applied::Vector{String} = String[];
    dimension_promotions_applied::Vector{<:NamedTuple} = NamedTuple[],
    opaque_coupling_refs::Vector{String} = String[],
    merged_variable_renames::AbstractDict = OrderedDict{String, String}(),
    reserved_liftings::AbstractVector = NTuple{3, String}[]
) =
    FlattenMetadata(
    source_systems, coupling_rules_applied,
    NamedTuple[dp for dp in dimension_promotions_applied],
    opaque_coupling_refs,
    OrderedDict{String, String}(merged_variable_renames),
    NTuple{3, String}[r for r in reserved_liftings]
)

"""
    LoaderField

A data-fed PARAMETER lowered to a flattened array input (esm-spec §8.5), and one
entry of [`FlattenedSystem`](@ref)'s `loader_fields`.

A data source is NOT a component: there is no loader subsystem and
no coupling edge. A model consumes a source by declaring a parameter whose
`update` is `{kind: "data", source: <key>, from: {file_variable: ...}}` — the
parameter IS the loaded field and it owns the units. Flatten records one
descriptor per such parameter so a runner can execute the source at its cadence
and bind the resulting array into the RHS as a read-only input, keyed by the
parameter's namespaced name. A data-fed parameter carries no defining equation:
its value is injected, not computed.

Fields:
- `name`: the namespaced parameter symbol (`"Advection.u_wind"`).
- `owner`: the owning component's namespaced prefix (`"Advection"`).
- `subkey`: the `data_sources` key the parameter's `update` names.
- `var`: the source-file variable the binding names (`from.file_variable`).
- `cadence`: `"discrete"` when the source declares a `temporal` block (refreshed
  in a discrete solver callback at its cadence), `"const"` otherwise (read once
  before integration) — the source-seeded refinement of CONFORMANCE_SPEC §5.7.2.
- `unit_conversion`: the binding's declared `unit_conversion` (§8.5), `nothing`
  when the document declares none.
- `records_per_sample`: the number of records the parameter receives per query
  time (esm-spec §8.5.1), 1 or 2: 2 when its record shape (its declared
  `shape`, else its `param_to_var` targets' declared shapes) begins with a
  record axis (an `interval` index set with `"records": true`), else 1. With 2
  the field holds the record at or before the query time and its successor,
  stacked along that first axis. The (deprecated) written
  `records_per_sample` must agree with it and is never read here.
"""
struct LoaderField
    name::String
    owner::String
    subkey::String
    var::String
    cadence::String
    unit_conversion::Union{Float64, ASTExpr, Nothing}
    records_per_sample::Int

    LoaderField(
        name::AbstractString, owner::AbstractString,
        subkey::AbstractString, var::AbstractString,
        cadence::AbstractString; unit_conversion = nothing,
        records_per_sample::Integer = 1
    ) =
        new(
        String(name), String(owner), String(subkey), String(var),
        String(cadence), unit_conversion, Int(records_per_sample)
    )
end

"""
    FlattenedSystem

A coupled ESM file flattened into a single symbolic representation.

All variables, parameters, and species are dot-namespaced (e.g.
`"SimpleOzone.O3"`, `"Atmosphere.Chemistry.NO2"`). Equations are real
`Equation` objects whose ASTExpr trees reference namespaced names via `VarExpr`.
This is the canonical intermediate form consumed by the build, the
ModelingToolkit `System` constructor (in the Julia extension) and by cross-language code generators.

Fields:
- `independent_variables::Vector{Symbol}`: `[:t]` for pure-ODE systems, or
  `[:t, :x, :y, ...]` when spatial operators are present.
- `state_variables::OrderedDict{String, ModelVariable}`: the SOLVED-FOR VECTOR —
  namespaced state variables and species (from lowered reactions), PLUS
  `algebraic_variables`, PLUS any arrayed observed that materializes into a
  buffer (esm-libraries-spec §4.7.5 step 4).
- `parameters::OrderedDict{String, ModelVariable}`: namespaced parameters,
  minus any promoted to variables by `variable_map`.
- `observed_variables::OrderedDict{String, ModelVariable}`: the namespaced
  unknowns an equation DEFINES, at either LHS spelling (esm-spec §6.3.1). NOT
  disjoint from `state_variables`: a scalar observed is eliminated by
  substitution and is in this map alone, while an arrayed one materializes into
  a buffer and is in both.
- `equations::Vector{Equation}`: all equations after reaction lowering and
  coupling, with variable references rewritten to namespaced form.
- `continuous_events::Vector{ContinuousEvent}`: collected from every source
  model with references rewritten.
- `discrete_events::Vector{DiscreteEvent}`: ditto.
- `domain::Union{Domain, Nothing}`: the target domain after any dimension
  promotion (§4.7.6), or `nothing` for purely 0D systems.
- `metadata::FlattenMetadata`: provenance.
- `index_sets::OrderedDict{String, IndexSet}`: the merged index-set registry,
  collected from every source model and namespaced per component
  (`<prefix>.<setname>`) so sibling components' sets do not collide. Empty when
  no source model declares any.
- `template_registry::OrderedDict{String, Any}`: the merged expression-template
  registry (esm-spec §9.6.4 rule 7 / §10.7).
- `algebraic_variables::OrderedDict{String, ModelVariable}`: unknowns constrained
  only by an expression-LHS equation (esm-spec §6.3.1). A **subset** of
  `state_variables`, not a sibling bucket — a DAE solves for them, so they occupy
  a slot of the `u` vector.
- `brownian_parameters::OrderedDict{String, ModelVariable}`: `update.kind ==
  "wiener"`. A **subset** of `parameters`; §6.3.1's `system_kind` derivation
  reads it to report `"sde"`.
- `discrete_parameters::OrderedDict{String, ModelVariable}`: any other `update`.
  A **subset** of `parameters`.
- `field_ics::Vector{Pair{String, ASTExpr}}`: deferred `ic` equations (esm-spec
  §11.4.1), REMOVED from `equations`.
- `loader_fields::Vector{LoaderField}`: provider-served loaded fields the system
  consumes (esm-spec §8.5).
- `lifted_shapes::OrderedDict{String, Vector{Int}}`: post-lift grid extents for
  arrayed states (§10.5).
- `equation_contributions::Vector{Vector{Contribution}}`: per-term provenance
  (esm-libraries-spec §4.7.5), parallel to `equations`. Entry `i` lists the
  [`Contribution`](@ref)s whose left-fold sum is equation `i`'s right-hand side
  (its `faq` body when the pointwise lift wrapped it), each with the
  [`TermOrigin`](@ref)s that authored it. Read it with
  [`equation_contributions`](@ref).
- `initialization_equations::Vector{Equation}`: every component's
  `initialization_equations` (esm-spec §6.2), named as `equations` are: each
  namespaced in its component's scope, then rewritten by the same template
  rename, `operator_compose` merged-away rename and `variable_map`
  substitution the equations take.

The three subset maps are views: the struct stores their member names and
`flat.algebraic_variables` (and the other two) is read off the parent map, so a
subset always holds the parent's current `ModelVariable`s, in the parent's order.

Build one with the keyword constructor `FlattenedSystem(; kwargs...)` (every
field a keyword, each defaulting to empty; a subset map may be given as a map or
as a list of names) or copy one with changes, `FlattenedSystem(flat; kwargs...)`.

ORDERING (esm-libraries-spec §4.7.5 step 4, normative): every ordered map and
list above is in DOCUMENT ORDER — components in the order the file declares them,
variables in the order their component declares them, coupling-merged entries
keeping the position of their first occurrence. A parameter vector is
positional, so the order is observable. It is inherited from the parser:
`EsmFile.models` / `.reaction_systems` / `.index_sets` and `Model.variables` /
`.subsystems` are `OrderedDict`s in document order.
"""
struct FlattenedSystem
    independent_variables::Vector{Symbol}
    state_variables::OrderedDict{String, ModelVariable}
    parameters::OrderedDict{String, ModelVariable}
    observed_variables::OrderedDict{String, ModelVariable}
    equations::Vector{Equation}
    continuous_events::Vector{ContinuousEvent}
    discrete_events::Vector{DiscreteEvent}
    domain::Union{Domain, Nothing}
    metadata::FlattenMetadata
    index_sets::OrderedDict{String, IndexSet}
    # esm-spec §9.6.4 rule 7 / §10.7 / esm-libraries-spec §4.7.5 step 4: the
    # merged template registry, against which surviving
    # `apply_expression_template` references resolve. Empty when none survived.
    template_registry::OrderedDict{String, Any}
    # The members of the three §6.3.1 subset maps (esm-libraries-spec §4.7.5
    # step 4): `algebraic_variables` ⊆ `state_variables` ∪ `observed_variables`,
    # `brownian_parameters` and `discrete_parameters` ⊆ `parameters`. A subset
    # never removes its members from its parent (esm-spec §6.3.1 partitions the
    # parameters, so the parameter vector's length does not depend on whether
    # the model is stochastic). Read through `getproperty` below.
    algebraic_names::Vector{String}
    brownian_names::Vector{String}
    discrete_names::Vector{String}
    # Deferred `ic` equations (esm-spec §11.4.1) as ordered `state => rhs` pairs,
    # removed from `equations` (§4.7.5 step 4).
    field_ics::Vector{Pair{String, ASTExpr}}
    # One per data-fed parameter (`update.kind == "data"`, esm-spec §8.5).
    loader_fields::Vector{LoaderField}
    # The §10.5 pointwise lift's per-dimension cell extents, by lifted state.
    lifted_shapes::OrderedDict{String, Vector{Int}}
    # Per-term provenance, parallel to `equations` (see `term_provenance.jl`).
    equation_contributions::Vector{Vector{Contribution}}
    initialization_equations::Vector{Equation}

    function FlattenedSystem(
            ivs, sv, p, obs, eqs, cev, dev, dom, meta, isets, treg,
            alg, brw, disc, ics, lfs, lshapes, contribs, ieqs
        )
        length(contribs) == length(eqs) || throw(
            ArgumentError(
                "equation_contributions has $(length(contribs)) entries for " *
                    "$(length(eqs)) equations; the two are parallel"
            )
        )
        any(isempty, contribs) && throw(
            ArgumentError(
                "every flattened equation has at least one contribution"
            )
        )
        return new(
            Symbol[iv for iv in ivs], _flat_od(ModelVariable, sv), _flat_od(ModelVariable, p),
            _flat_od(ModelVariable, obs), eqs, cev, dev, dom, meta,
            _flat_od(IndexSet, isets), _flat_od(Any, treg),
            _subset_names(alg), _subset_names(brw), _subset_names(disc),
            Pair{String, ASTExpr}[Pair{String, ASTExpr}(String(k), v) for (k, v) in ics],
            LoaderField[lf for lf in lfs], _flat_od(Vector{Int}, lshapes),
            Vector{Contribution}[Contribution[c for c in cs] for cs in contribs],
            Equation[eq for eq in ieqs]
        )
    end
end

# The flattened system's independent (time) variable, as its expressions spell it.
_indep_var(flat::FlattenedSystem)::String = _indep_var(flat.domain)

# The ordered maps are `OrderedDict`s, and Julia's implicit conversion from a
# plain `Dict` is refused as order-losing. A hand-built caller may still pass a
# `Dict`, whose iteration order is the only order it has; an ordered map passes
# through untouched.
_flat_od(::Type{V}, d::OrderedDict{String, V}) where {V} = d
_flat_od(::Type{V}, d::AbstractDict) where {V} =
    OrderedDict{String, V}(String(k) => v for (k, v) in d)

# A subset map's member names, from a map (its keys) or a list of names.
_subset_names(d::AbstractDict) = String[String(k) for k in keys(d)]
_subset_names(names) = String[String(n) for n in names]

const _FLAT_SUBSETS = (
    algebraic_variables = (:algebraic_names, (:state_variables, :observed_variables)),
    brownian_parameters = (:brownian_names, (:parameters,)),
    discrete_parameters = (:discrete_names, (:parameters,)),
)

function Base.getproperty(flat::FlattenedSystem, s::Symbol)
    if haskey(_FLAT_SUBSETS, s)
        names_field, parents = _FLAT_SUBSETS[s]
        return _in_document_order(
            Set{String}(getfield(flat, names_field)),
            (getfield(flat, p) for p in parents)...
        )
    end
    return getfield(flat, s)
end

const _FLAT_PROPERTIES = (
    :independent_variables, :state_variables, :parameters, :observed_variables,
    :equations, :continuous_events, :discrete_events, :domain, :metadata,
    :index_sets, :template_registry, :algebraic_variables, :brownian_parameters,
    :discrete_parameters, :field_ics, :loader_fields, :lifted_shapes,
    :equation_contributions, :initialization_equations,
)
Base.propertynames(::FlattenedSystem, private::Bool = false) =
    private ? (_FLAT_PROPERTIES..., :algebraic_names, :brownian_names, :discrete_names) :
    _FLAT_PROPERTIES

equation_contributions(flat::FlattenedSystem) = flat.equation_contributions

"""
    FlattenedSystem(; independent_variables = [:t], state_variables, parameters,
                    observed_variables, equations, continuous_events,
                    discrete_events, domain = nothing, metadata, index_sets,
                    template_registry, algebraic_variables, brownian_parameters,
                    discrete_parameters, field_ics, loader_fields, lifted_shapes,
                    equation_contributions = nothing, initialization_equations)

Build a `FlattenedSystem` from keywords, every one defaulting to empty. A subset
map (`algebraic_variables`, `brownian_parameters`, `discrete_parameters`) may be
a map or a list of names; only its names are kept. `equation_contributions`
defaults to one contribution per equation, its whole right-hand side, with no
origins ("author unknown", esm-libraries-spec §4.7.5).
"""
function FlattenedSystem(;
        independent_variables = Symbol[:t],
        state_variables = OrderedDict{String, ModelVariable}(),
        parameters = OrderedDict{String, ModelVariable}(),
        observed_variables = OrderedDict{String, ModelVariable}(),
        equations = Equation[],
        continuous_events = ContinuousEvent[],
        discrete_events = DiscreteEvent[],
        domain = nothing,
        metadata = FlattenMetadata(),
        index_sets = OrderedDict{String, IndexSet}(),
        template_registry = OrderedDict{String, Any}(),
        algebraic_variables = String[],
        brownian_parameters = String[],
        discrete_parameters = String[],
        field_ics = Pair{String, ASTExpr}[],
        loader_fields = LoaderField[],
        lifted_shapes = OrderedDict{String, Vector{Int}}(),
        equation_contributions = nothing,
        initialization_equations = Equation[]
    )
    contribs = equation_contributions === nothing ?
        _unattributed_contributions(equations, lifted_shapes) : equation_contributions
    return FlattenedSystem(
        independent_variables, state_variables, parameters, observed_variables,
        equations, continuous_events, discrete_events, domain, metadata, index_sets,
        template_registry, algebraic_variables, brownian_parameters,
        discrete_parameters, field_ics, loader_fields, lifted_shapes, contribs,
        initialization_equations
    )
end

"""
    FlattenedSystem(flat::FlattenedSystem; kwargs...) -> FlattenedSystem

Copy `flat`, replacing only the fields passed as keywords (the keywords of
`FlattenedSystem(; ...)`).

`equation_contributions` is parallel to `equations`, so when `equations` is
replaced alone it resets to one contribution per equation with no origins
(esm-libraries-spec §4.7.5): a stale list must not survive a caller's edit. A
pass that keeps provenance passes both.
"""
function FlattenedSystem(flat::FlattenedSystem; kwargs...)
    for k in keys(kwargs)
        k in _FLAT_PROPERTIES ||
            throw(ArgumentError("FlattenedSystem has no field `$k`"))
    end
    pick(k, default) = haskey(kwargs, k) ? kwargs[k] : default
    equations = pick(:equations, flat.equations)
    contribs = pick(
        :equation_contributions,
        equations === flat.equations ? flat.equation_contributions : nothing
    )
    return FlattenedSystem(;
        independent_variables = pick(:independent_variables, flat.independent_variables),
        state_variables = pick(:state_variables, flat.state_variables),
        parameters = pick(:parameters, flat.parameters),
        observed_variables = pick(:observed_variables, flat.observed_variables),
        equations = equations,
        continuous_events = pick(:continuous_events, flat.continuous_events),
        discrete_events = pick(:discrete_events, flat.discrete_events),
        domain = pick(:domain, flat.domain),
        metadata = pick(:metadata, flat.metadata),
        index_sets = pick(:index_sets, flat.index_sets),
        template_registry = pick(:template_registry, flat.template_registry),
        algebraic_variables = pick(:algebraic_variables, getfield(flat, :algebraic_names)),
        brownian_parameters = pick(:brownian_parameters, getfield(flat, :brownian_names)),
        discrete_parameters = pick(:discrete_parameters, getfield(flat, :discrete_names)),
        field_ics = pick(:field_ics, flat.field_ics),
        loader_fields = pick(:loader_fields, flat.loader_fields),
        lifted_shapes = pick(:lifted_shapes, flat.lifted_shapes),
        equation_contributions = contribs,
        initialization_equations = pick(:initialization_equations, flat.initialization_equations),
    )
end

# ========================================
# Spatial-axis detection (structural, esm-spec §4.2 / §4.9.1(ii) / §11.2)
# ========================================

# Spatial axes are harvested STRUCTURALLY from the `dim`/`wrt` scalar FIELDS
# of any node — never from a hand-maintained op-name list — so a user
# rewrite-target op carrying a `dim` contributes its axis. (A fully shape-derived rederivation over `index_sets`, §11.2, is the
# other admissible structural signal; the by-field `dim`/`wrt` harvest is the
# smaller one and is what §4.9.1(ii) pins for coordinate-name resolution.)

"""
    spatial_dims_in_expr(expr) -> Vector{Symbol}

Collect every spatial-axis name referenced in `expr`, resolved STRUCTURALLY by
field (esm-spec §4.9.1(ii)): the value of a `dim` field on ANY Expression node
(a user rewrite-target op's `dim` names an axis), plus
a spatial `wrt` (a `wrt` naming an axis other than the independent variable) on
a `D` node. No op name is privileged.

Returned in FIRST-ENCOUNTER order, deduplicated: it feeds
`independent_variables`, which §4.7.5 step 4 requires in document order and
which consumers read positionally as the system's axes.
"""
function spatial_dims_in_expr(expr::ASTExpr)::Vector{Symbol}
    dims = Symbol[]
    # Each unique node once: template expansion hangs one subtree under many
    # paths. A `dim` field names a spatial axis whatever op carries it; a `D`
    # names its axis by `wrt`, and `t` is temporal, not spatial.
    foreach_subexpr_once(expr) do x
        x isa OpExpr || return
        if x.dim !== nothing
            d = Symbol(x.dim)
            (d in dims) || push!(dims, d)
        end
        if x.op == "D" && x.wrt !== nothing && x.wrt != "t"
            d = Symbol(x.wrt)
            (d in dims) || push!(dims, d)
        end
    end
    return dims
end

# ========================================
# Right-hand-side time derivatives (esm-spec §4.2)
# ========================================

"""
    _is_structural_time_derivative(e) -> Bool

True iff `e` is the STRUCTURAL time derivative — a `D` with `wrt == "t"` or no
`wrt` at all (esm-spec §4.2: an absent `wrt` MEANS `t`) — applied to a single
operand. The strict-unary check is the §4.2 arity contract for this tier; a
SPATIAL `D` (a `wrt` naming an axis) is the rewrite-target tier, may carry
trailing auxiliary operands, and is deliberately not matched here.
"""
_is_structural_time_derivative(e::ASTExpr)::Bool =
    e isa OpExpr && e.op == "D" && length(e.args) == 1 &&
    (e.wrt === nothing || e.wrt == "t")

"""
    _rhs_derivative_target(e) -> Union{String,Nothing}

The name a structural `D` differentiates, when `args[1]` is a bare variable
reference; `nothing` otherwise (including for a `D` of a compound expression,
which names no variable and so cannot be looked up).
"""
function _rhs_derivative_target(e::ASTExpr)::Union{String, Nothing}
    _is_structural_time_derivative(e) || return nothing
    a = e.args[1]
    return a isa VarExpr ? (a::VarExpr).name : nothing
end

"""
    _resolve_rhs_time_derivatives!(pool, time_invariant, lifted_shapes)

Step 3c of [`flatten`]: rewrite every right-hand-side STRUCTURAL time derivative
into the tendency this system already defines for it (esm-spec §4.2).

`D` on an equation's LEFT-hand side is structural: it makes the equation
differential, and system assembly consumes it. On a RIGHT-hand side,
`D(x, t)` over a STATE is `x`'s own tendency, and `D(y, t)` over an OBSERVED is
the total derivative of `y`'s defining right-hand side, by the same rule one
level down: the one recursive walk [`_deriv`](@ref). It runs here, after
coupling and reaction lowering, so no evaluator meets a right-hand-side `D` and
a sibling model's `D(Chem.O3, t)` resolves to the mechanism's tendency (§7.4).

What `_deriv` covers, and nothing else: a STATE (its tendency, with any `D`
inside that tendency resolved in turn, so a chained
`D(lai)/dt ~ sla · D(biomass)/dt` terminates in states; a pointwise-lifted
state's tendency is its lifted `faq`, and one cell `index(x, ℓ…)` of it is that
cell of the `faq`); an OBSERVED (the chain
rule, by substituting its definition and differentiating it); a TIME-INVARIANT
name or a literal (`0`); and `+`, unary and binary `-`, `neg`, n-ary `*` and
binary `/`, distributed by the sum, product and quotient rules. Every other
shape — `^`, a call, a reduction, a nested `D`, a name in no table — and every
cyclic chain resolves to NOTHING and is left exactly as authored, to be refused
with `unlowered_operator`: §4.2 forbids inventing a value there, in particular
`0`. A SPATIAL `D` is untouched (§9.6.8 owns it) and left-hand sides are never
rewritten.

The tendency and definition tables are built straight from the equations' LHS
FORMS, never from a classification set: §6.3.1 derives an unknown's role from the
equations.

The resolved expression replaces the `D` node INSIDE the referencing
contribution, which keeps its origins; `x`'s own contributions are not spliced
in (esm-libraries-spec §4.7.5).

Mirrors the Rust `flatten::resolve_rhs_time_derivatives` and the Python
`_resolve_rhs_time_derivatives` exactly.
"""
function _resolve_rhs_time_derivatives!(
        pool::Vector{_FlatEq}, time_invariant::Set{String}, lifted_shapes::AbstractDict
    )
    tendency = Dict{String, ASTExpr}()
    definition = Dict{String, ASTExpr}()
    for fe in pool
        eq = fe.eq
        t = _rhs_derivative_target(eq.lhs)
        t === nothing && (t = _lifted_target(eq, lifted_shapes))
        if t !== nothing
            # A lifted state's tendency is its lifted right-hand side, the `faq`
            # over its index sets (esm-libraries-spec §4.7.5 step 3a).
            tendency[t] = eq.rhs
        elseif eq.lhs isa VarExpr
            # A bare-variable LHS is a DEFINING equation (§6.3.1's observed /
            # algebraic form); its right-hand side is what the chain rule
            # differentiates.
            definition[(eq.lhs::VarExpr).name] = eq.rhs
        end
    end
    (isempty(tendency) && isempty(definition)) && return pool
    for (i, fe) in enumerate(pool)
        eq = fe.eq
        _has_time_derivative(eq.rhs) || continue
        # The quantity this equation DEFINES is not available to substitute into
        # its own right-hand side; seeding `active` with it is what makes
        # `D(x)/dt ~ k·D(x, t)` and `y ~ D(y, t)` terminate as unresolved rather
        # than expand forever.
        own = _rhs_derivative_target(eq.lhs)
        own === nothing && (own = _lifted_target(eq, lifted_shapes))
        if own === nothing && eq.lhs isa VarExpr
            own = (eq.lhs::VarExpr).name
        end
        active = own === nothing ? String[] : String[own]
        resolve(e) = _substitute_time_derivatives(
            e, tendency, definition,
            time_invariant, active
        )
        resolved = _rewrite_flat_eq(resolve, fe, _is_lifted(eq, lifted_shapes))
        resolved === fe ||
            (pool[i] = _FlatEq(Equation(eq.lhs, resolved.eq.rhs), resolved.contribs, fe.owner))
    end
    return pool
end

"""
    _lifted_target(eq, lifted_shapes) -> Union{String,Nothing}

The state a pointwise-lifted equation defines: `x` of its left-hand side
`faq(D(index(x, ℓ…)))`, else `nothing`.
"""
function _lifted_target(eq::Equation, lifted_shapes::AbstractDict)::Union{String, Nothing}
    _is_lifted(eq, lifted_shapes) || return nothing
    d = (eq.lhs::OpExpr).expr_body::OpExpr
    _is_structural_time_derivative(d) || return nothing
    return ((d.args[1]::OpExpr).args[1]::VarExpr).name
end

"""Whether a tendency is a lifted right-hand side: a `faq` with output indices."""
_is_lifted_tendency(e)::Bool =
    e isa OpExpr && e.op == "faq" && e.output_idx !== nothing && !isempty(e.output_idx)

"""
    _has_time_derivative(e) -> Bool

Does `e` carry a structural `D` anywhere?
"""
function _has_time_derivative(e::ASTExpr)::Bool
    e isa OpExpr || return false
    _is_structural_time_derivative(e) && return true
    found = false
    foreach_child(x -> (found |= _has_time_derivative(x)), e)
    return found
end

"""
    _substitute_time_derivatives(e, tendency, definition, time_invariant, active)

Rewrite every structural `D` inside `e`, leaving the ones [`_deriv`](@ref)
cannot answer exactly as authored for the gate to report. `map_children` is
identity-preserving, so an expression carrying no `D` is returned unchanged
rather than rebuilt.
"""
function _substitute_time_derivatives(
        e::ASTExpr, tendency::Dict{String, ASTExpr},
        definition::Dict{String, ASTExpr},
        time_invariant::Set{String},
        active::Vector{String}
    )::ASTExpr
    e isa OpExpr || return e
    if _is_structural_time_derivative(e)
        out = _deriv(e.args[1], tendency, definition, time_invariant, active)
        return out === nothing ? e : out
    end
    return map_children(
        x -> _substitute_time_derivatives(x, tendency, definition, time_invariant, active), e
    )
end

"""
    _deriv(e, tendency, definition, time_invariant, active) -> Union{ASTExpr,Nothing}

d/dt of `e`, or `nothing` when this format does not define it.
"""
function _deriv(
        e::ASTExpr, tendency::Dict{String, ASTExpr},
        definition::Dict{String, ASTExpr}, time_invariant::Set{String},
        active::Vector{String}
    )::Union{ASTExpr, Nothing}
    if e isa VarExpr
        name = (e::VarExpr).name
        # A cycle: stop here and let the gate name it.
        name in active && return nothing
        if haskey(tendency, name)
            push!(active, name)
            try
                return _substitute_time_derivatives(
                    tendency[name], tendency, definition,
                    time_invariant, active
                )
            finally
                pop!(active)
            end
        elseif haskey(definition, name)
            # CHAIN RULE: an observed's total time derivative is its defining
            # right-hand side differentiated by this same rule, one level down.
            push!(active, name)
            try
                return _deriv(definition[name], tendency, definition, time_invariant, active)
            finally
                pop!(active)
            end
        elseif name in time_invariant
            return _zero_expr()
        end
        # A name in none of the three. Answering `0` for a name this pass does
        # not recognise is exactly the invention §4.2 forbids.
        return nothing
    end
    (e isa NumExpr || e isa IntExpr) && return _zero_expr()
    e isa OpExpr || return nothing

    d(a) = _deriv(a, tendency, definition, time_invariant, active)
    op = (e::OpExpr).op
    args = (e::OpExpr).args
    if op == "index" && !isempty(args) && args[1] isa VarExpr &&
            _is_lifted_tendency(get(tendency, (args[1]::VarExpr).name, nothing))
        # One cell of a lifted state: that cell of its lifted tendency.
        whole = d(args[1])
        whole === nothing && return nothing
        return OpExpr("index", ASTExpr[whole, args[2:end]...])
    end
    if op == "+"
        terms = ASTExpr[]
        for a in args
            da = d(a)
            da === nothing && return nothing
            push!(terms, da)
        end
        return _sum_expr(terms)
    elseif op == "-" && length(args) == 1
        da = d(args[1]); da === nothing && return nothing
        return _negate_expr(da)
    elseif op == "-" && length(args) == 2
        da = d(args[1]); da === nothing && return nothing
        db = d(args[2]); db === nothing && return nothing
        return _difference_expr(da, db)
    elseif op == "neg" && length(args) == 1
        da = d(args[1]); da === nothing && return nothing
        return _negate_expr(da)
    elseif op == "*"
        # Product rule over an n-ary `*`: one term per factor, that factor
        # differentiated and the others left alone.
        terms = ASTExpr[]
        for (i, a) in enumerate(args)
            da = d(a)
            da === nothing && return nothing
            _is_zero_expr(da) && continue
            factors = ASTExpr[da]
            for (j, b) in enumerate(args)
                i == j || push!(factors, b)
            end
            push!(terms, _product_expr(factors))
        end
        return _sum_expr(terms)
    elseif op == "/" && length(args) == 2
        u, v = args[1], args[2]
        du = d(u); du === nothing && return nothing
        dv = d(v); dv === nothing && return nothing
        # `v` constant in t: (u/v)' = u'/v, which keeps the common `D(x, t)/c`
        # shape small.
        _is_zero_expr(dv) && return _quotient_expr(du, v)
        num = _difference_expr(_product_expr(ASTExpr[du, v]), _product_expr(ASTExpr[u, dv]))
        return _quotient_expr(num, _product_expr(ASTExpr[v, v]))
    end
    return nothing
end

# ---------------------------------------------------------------------------
# Small folding constructors for the derivative expressions.
#
# Folding is not cosmetic. A parameter and a literal both differentiate to `0`,
# so an unfolded product rule would emit `0*x` shapes throughout and `D(k, t)`
# would be a sum of zeros rather than the literal `0` a downstream classifier
# can read as constant.
# ---------------------------------------------------------------------------

_zero_expr() = NumExpr(0.0)

_is_zero_expr(e::ASTExpr) = (e isa NumExpr && (e::NumExpr).value == 0.0) ||
    (e isa IntExpr && (e::IntExpr).value == 0)

_is_one_expr(e::ASTExpr) = (e isa NumExpr && (e::NumExpr).value == 1.0) ||
    (e isa IntExpr && (e::IntExpr).value == 1)

function _sum_expr(terms::Vector{ASTExpr})::ASTExpr
    kept = ASTExpr[t for t in terms if !_is_zero_expr(t)]
    isempty(kept) && return _zero_expr()
    length(kept) == 1 && return kept[1]
    return OpExpr("+", kept)
end

function _negate_expr(a::ASTExpr)::ASTExpr
    _is_zero_expr(a) && return _zero_expr()
    a isa NumExpr && return NumExpr(-(a::NumExpr).value)
    a isa IntExpr && return IntExpr(-(a::IntExpr).value)
    # Unary `-`, not `neg`: both spell negation, and `-` is the spelling every
    # binding's evaluator has a rule for.
    return OpExpr("-", ASTExpr[a])
end

function _difference_expr(a::ASTExpr, b::ASTExpr)::ASTExpr
    _is_zero_expr(b) && return a
    _is_zero_expr(a) && return _negate_expr(b)
    return OpExpr("-", ASTExpr[a, b])
end

function _product_expr(factors::Vector{ASTExpr})::ASTExpr
    any(_is_zero_expr, factors) && return _zero_expr()
    kept = ASTExpr[f for f in factors if !_is_one_expr(f)]
    isempty(kept) && return NumExpr(1.0)
    length(kept) == 1 && return kept[1]
    return OpExpr("*", kept)
end

function _quotient_expr(a::ASTExpr, b::ASTExpr)::ASTExpr
    _is_zero_expr(a) && return _zero_expr()
    return OpExpr("/", ASTExpr[a, b])
end

# ========================================
# Independent-variable detection
# ========================================

function _compute_independent_variables(equations::Vector{Equation})::Vector{Symbol}
    ivs = Symbol[:t]
    seen = Set{Symbol}([:t])

    for eq in equations
        for expr in (eq.lhs, eq.rhs)
            for sym in spatial_dims_in_expr(expr)
                if !(sym in seen)
                    push!(ivs, sym)
                    push!(seen, sym)
                end
            end
        end
    end

    return ivs
end

# ========================================
# The esm-1.0.0 canonical field set (§4.7.5 step 4)
# ========================================

"""
    _classification_model(states, params, observeds, equations) -> Model

A `Model`-shaped view of the FLATTENED accumulators, so the esm-spec §6.3.1
classification accessors — [`algebraic_unknowns`](@ref),
[`brownian_parameters`](@ref), [`discrete_parameters`](@ref) — can be run over
the flattened form with no second implementation of their rules.

Classification is re-run over the flattened system rather than reused per
component because flattening moves the ground under it: `operator_compose`
merges two RHSs into one equation, `variable_map` deletes a parameter and
promotes a variable in its place, and the §10.5 pointwise lift rewrites a scalar
state ODE into a `faq`. A per-component answer namespaced after the fact
would describe the document, not the system produced from it.
"""
function _classification_model(
        states::OrderedDict{String, ModelVariable},
        params::OrderedDict{String, ModelVariable},
        observeds::OrderedDict{String, ModelVariable},
        equations::Vector{Equation}
    )::Model
    variables = OrderedDict{String, ModelVariable}()
    for m in (states, observeds, params)
        for (name, var) in m
            haskey(variables, name) || (variables[name] = var)
        end
    end
    return Model(variables, equations)
end

"""
    _in_document_order(names, maps...) -> OrderedDict{String, ModelVariable}

Select `names` out of `maps`, keeping each map's own insertion order.

The §6.3.1 accessors return SORTED name vectors — a set-valued answer spelled as
a vector. §4.7.5 step 4 requires DOCUMENT order of every map on the
`FlattenedSystem`, so membership comes from the accessor and POSITION comes from
the already-document-ordered map being filtered. Sorting here instead would be
observable: a parameter vector is positional.
"""
function _in_document_order(
        names::AbstractSet{String},
        maps::OrderedDict{String, ModelVariable}...
    )
    out = OrderedDict{String, ModelVariable}()
    for m in maps
        for (name, var) in m
            (name in names && !haskey(out, name)) && (out[name] = var)
        end
    end
    return out
end

"""
    _extract_field_ics!(pool) -> Vector{Pair{String, ASTExpr}}

Classify the deferred `ic` equations (esm-spec §11.4.1) OUT of `equations`,
returning them as ordered `state => rhs` pairs.

§4.7.5 step 4 is normative that these entries are removed: an initial condition
is a datum, not an equation of motion, so leaving it in `equations` makes that
list unusable for building a right-hand side without first filtering it and makes
equation counts incomparable across bindings. The LHS must be `ic(<bare
variable>)` with exactly one argument — the same shape Rust's `extract_ic_target`
and Python's `_collect_field_ics` match.

Runs LAST, after the pointwise lift and the independent-variable derivation, so
every intermediate pass still sees the equation list it always did and only the
FINAL, observable `equations` differs.
"""
function _extract_field_ics!(pool::Vector{_FlatEq})
    ics = Pair{String, ASTExpr}[]
    remaining = _FlatEq[]
    for fe in pool
        eq = fe.eq
        target = _ic_lhs_variable(eq.lhs)
        if target === nothing
            push!(remaining, fe)
        else
            # The entry leaves `equations` and its contributions together;
            # `field_ics` carries none.
            push!(ics, target => eq.rhs)
        end
    end
    # One initial condition per state (esm-libraries-spec §4.7.5 step 4
    # `field_ics`). Two leave nothing to say which one holds, so the document is
    # refused rather than one silently winning.
    seen = Set{String}()
    duplicated = String[]
    for (target, _) in ics
        target in seen && !(target in duplicated) && push!(duplicated, target)
        push!(seen, target)
    end
    isempty(duplicated) || throw(
        ConflictingDerivativeError(
            duplicated,
            "states have more than one initial condition `ic(x)` (an authored " *
                "one and an operator's `ic(_var)` expanded onto it, or two such templates)"
        )
    )
    length(remaining) == length(pool) || append!(empty!(pool), remaining)
    return ics
end

"""
    _loader_fields(file, params, records) -> Vector{LoaderField}

One [`LoaderField`](@ref) per data-fed parameter in `params`, the collected
(namespaced, not yet coupled) parameter table, in its order: a model's
parameters and a reaction system's alike, at any depth (esm-libraries-spec
§4.7.5 step 4, `loader_fields`).

A parameter is data-fed when some `update` rule has `kind == "data"` and carries
a `from` binding (esm-spec §8.5). Its owner is its name without the last
segment. Its cadence follows the SOURCE, not its own declaration
(CONFORMANCE_SPEC §5.7.2): a source WITH a `temporal` block refreshes per record
(`"discrete"`), one without is read once (`"const"`). A parameter naming a
source the document does not declare is skipped — `data_source_undefined` is the
validator's finding, not flatten's. Its record count is `records[name]`, which
[`_check_flattened_record_shapes`](@ref) judged from its record shape on `file`
(refs mounted, `coupling` expanded); 1 when absent.
"""
function _loader_fields(
        file::EsmFile, params::OrderedDict{String, ModelVariable},
        records::AbstractDict{String, Int}
    )
    out = LoaderField[]
    data_sources = file.data_sources
    data_sources === nothing && return out
    for (name, var) in params
        var.update === nothing && continue
        for rule in var.update
            (_is_data_fed(rule) && rule.source !== nothing) || continue
            src = get(data_sources, rule.source, nothing)
            src === nothing && continue
            owner = String(first(rsplit(name, '.'; limit = 2)))
            push!(
                out, LoaderField(
                    name, owner, rule.source, rule.from.file_variable,
                    src.temporal === nothing ? "const" : "discrete";
                    unit_conversion = rule.from.unit_conversion,
                    records_per_sample = get(records, name, 1)
                )
            )
        end
    end
    return out
end

"""
    system_kind(flat::FlattenedSystem) -> String

Derive what a flattened system's `system_kind` field would declare (esm-spec
§6.3.1), over the FLATTENED form rather than a component.

Row 1 of the derivation tests `brownian_parameters` FIRST, and it reads the
bucket the `FlattenedSystem` carries. That is precisely what the bucket is for: a
flattened representation that dropped it could not report `"sde"`, and a consumer
would integrate a stochastic system as a deterministic one.
"""
function system_kind(flat::FlattenedSystem)::String
    isempty(flat.brownian_parameters) || return "sde"
    view = _classification_model(
        flat.state_variables, flat.parameters,
        flat.observed_variables, flat.equations
    )
    has_time_derivative(view) || return "nonlinear"
    return "ode"
end

# ========================================
# Top-level flatten (§4.7.5)
# ========================================

"""
    _check_flattened_record_shapes(file::EsmFile) -> Dict{String, Int}

esm-spec §8.5.1 "When rules 2 and 3 are checked", at `flatten`, on the document
with refs mounted and `file.coupling` already the expanded coupling sequence:
every `data` rule of a parameter, of a model or a reaction system at any depth,
is checked against the record shapes of that sequence
([`_record_shape_findings`](@ref)), a shapeless one with no `param_to_var`
target now read as the empty record shape. Throws `ExpressionTemplateError` with
the first finding's code (`record_axis_misplaced`,
`record_axis_time_invariant_source` or `records_per_sample_invalid`), the
message naming the rule's pointer. Returns the number of records each data-fed
parameter receives, by scoped name, for its `LoaderField`.
"""
function _check_flattened_record_shapes(file::EsmFile)
    records = Dict{String, Int}()
    file.data_sources === nothing && return records
    targets = _param_to_var_target_map(file.coupling)
    decls = _scoped_index(file)
    _for_each_data_param(file) do scope, name, var, declpath
        rules = var.update
        rules === nothing && return
        for (ri, rule) in enumerate(rules)
            (_is_data_fed(rule) && rule.source !== nothing) || continue
            src = get(file.data_sources, rule.source, nothing)
            src === nothing && continue
            at = _update_rule_path(_pointer(declpath, name), rules, ri)
            findings, n = _record_shape_findings(
                file, decls, targets, scope, name, var, rule, src, at; defer_empty = false
            )
            if !isempty(findings)
                code, msg, _ = first(findings)
                throw(ExpressionTemplateError(code, msg))
            end
            n === nothing || (records["$scope.$name"] = n)
        end
        return
    end
    return records
end

"""
    flatten(file::EsmFile; base_path=".", load_ref=nothing) -> FlattenedSystem

Flatten the coupled systems in `file` into a single symbolic representation
per spec §4.7.5 (+ §4.7.6 for hybrid dimension-promoted cases).

`coupling_import` entries (esm-spec §10.10) are expanded first; `base_path`
anchors their `ref`s and `load_ref` optionally overrides the resolver (see
[`expand_coupling_imports`](@ref)).

Throws `ConflictingDerivativeError` if any species is both the LHS of an
explicit `D(X, t) = ...` equation and a reactant/product of a reaction — such
a system is over-determined.

INVARIANT (esm-spec §9.6.4 Option B): `flatten` ALWAYS carries surviving
`apply_expression_template` references — MODEL-equation references ride into
the `FlattenedSystem` (namespacing scopes their `bindings`), resolvable against
the merged `template_registry` it also carries. Reaction-system RATE references
never survive: they are expanded eagerly at collect (`_collect_reaction_system!`),
before namespacing. Consumers that need the Option-A expanded image call
[`expand_flattened_refs`](@ref) at their own boundary (RFC
out-of-line-expression-templates §7.7); the tree-walk build expands at its entry
with site recording (the compile-once tier).
"""
function flatten(
        file::EsmFile; base_path::AbstractString = ".",
        load_ref = nothing
    )::FlattenedSystem
    file, records = _flatten_preflight(file; base_path = base_path, load_ref = load_ref)
    st = _collect_components(file, records)
    _apply_coupling!(st)
    pointwise = _apply_pointwise_lift!(st)
    # esm-libraries-spec §4.7.5 step 3a: a right-hand-side time derivative of an
    # ODE unknown resolves to the tendency this system defines for it (esm-spec
    # §4.2). After the lift, so it sees the lifted equations; after collection,
    # so a reaction network's mass-action tendency (§7.4) is available to a
    # sibling model's scoped `D(Chem.O3, t)`.
    _resolve_rhs_time_derivatives!(
        st.equations, Set{String}(keys(st.params)), st.lifted_shapes
    )
    return _finish_flatten(st, pointwise)
end

"""
    FlattenState

`flatten`'s working state between its stages: the document (coupling imports
expanded) and the accumulators the stages read and write. `equations` is the
equation pool, each equation with its contributions and its owner
([`_FlatEq`](@ref)).
"""
mutable struct FlattenState
    file::EsmFile
    components::Vector{String}
    states::OrderedDict{String, ModelVariable}
    params::OrderedDict{String, ModelVariable}
    observeds::OrderedDict{String, ModelVariable}
    equations::Vector{_FlatEq}
    init_equations::Vector{Equation}
    field_ics::Vector{Pair{String, ASTExpr}}
    continuous_events::Vector{ContinuousEvent}
    discrete_events::Vector{DiscreteEvent}
    index_sets::OrderedDict{String, IndexSet}
    template_registry::OrderedDict{String, Any}
    loader_fields::Vector{LoaderField}
    lifted_shapes::OrderedDict{String, Vector{Int}}
    merged_renames::OrderedDict{String, String}
    coupling_rules_applied::Vector{String}
    opaque_refs::Vector{String}
end

FlattenState(file::EsmFile, template_registry) = FlattenState(
    file, String[],
    OrderedDict{String, ModelVariable}(), OrderedDict{String, ModelVariable}(),
    OrderedDict{String, ModelVariable}(),
    _FlatEq[], Equation[],
    Pair{String, ASTExpr}[], ContinuousEvent[], DiscreteEvent[],
    # esm-spec §2: one document-scoped index-set registry, plain names.
    OrderedDict{String, IndexSet}(file.index_sets),
    template_registry, LoaderField[], OrderedDict{String, Vector{Int}}(),
    OrderedDict{String, String}(), String[], String[],
)

"""
    _map_flat_sites!(f, st::FlattenState; equations = false, targets = nothing)

Rewrite every expression site of the flattened system under construction
through `f`: the initialization equations, the field initial conditions, every
event's conditions, trigger and affect right-hand sides, and every variable's
update rules and bounds (the variable and event walks of `expression_sites.jl`).
With `equations = true` the equation pool too, inside each contribution
(`_rewrite_contributions`), so no term crosses a contribution boundary. A pass
over the pool that keeps its own contribution rule (a coupling merge) leaves
`equations` false. `targets`, when given, renames each event affect target
(a variable name, not an expression).
"""
function _map_flat_sites!(f::F, st::FlattenState; equations::Bool = false, targets = nothing) where {F}
    if equations
        for (i, fe) in enumerate(st.equations)
            st.equations[i] = _rewrite_flat_eq(f, fe, _is_lifted(fe.eq, st.lifted_shapes))
        end
    end
    st.init_equations = _map_equation_sides(f, st.init_equations)
    st.field_ics = Pair{String, ASTExpr}[name => f(rhs)::ASTExpr for (name, rhs) in st.field_ics]
    st.continuous_events = _map_event_exprs(f, st.continuous_events)
    st.discrete_events = _map_event_exprs(f, st.discrete_events)
    if targets !== nothing
        st.continuous_events = ContinuousEvent[_rename_affect_targets(targets, ev) for ev in st.continuous_events]
        st.discrete_events = DiscreteEvent[_rename_affect_targets(targets, ev) for ev in st.discrete_events]
    end
    st.states = _map_variable_sites(f, st.states)
    st.params = _map_variable_sites(f, st.params)
    st.observeds = _map_variable_sites(f, st.observeds)
    return st
end

# Both sides of each equation through `f`; the same vector when nothing changed.
function _map_equation_sides(f::F, eqs::Vector{Equation}) where {F}
    out = nothing
    for (i, eq) in enumerate(eqs)
        l = f(eq.lhs)::ASTExpr
        r = f(eq.rhs)::ASTExpr
        (l === eq.lhs && r === eq.rhs) && continue
        out === nothing && (out = copy(eqs))
        out[i] = Equation(l, r; _comment = eq._comment)
    end
    return out === nothing ? eqs : out
end

# Stage 0: expand `coupling_import` entries (esm-spec §10.10.3), so imported
# edges take part in every later step as inline ones do; re-check the record
# shapes against the expanded `param_to_var` edges (esm-spec §8.5.1, "When rules
# 2 and 3 are checked"); refuse a document with nothing to flatten, a species
# with two derivations (§4.7.5 item E), or a `variable_map` whose units do not
# agree. Returns the expanded file and each data-fed parameter's record count.
function _flatten_preflight(file::EsmFile; base_path, load_ref)
    expanded = expand_coupling_imports(file; base_path = base_path, load_ref = load_ref)
    expanded === file.coupling || (file = reconstruct(file; coupling = expanded))
    records = _check_flattened_record_shapes(file)
    # A document whose only payload is an `expression_templates` registry is a
    # template library (esm-spec §9.7): its metaparameters bind per import edge,
    # so there is no system to produce.
    n_components = (file.models === nothing ? 0 : length(file.models)) +
        (file.reaction_systems === nothing ? 0 : length(file.reaction_systems))
    n_components == 0 && throw(
        FlattenRefusal(
            ERROR_CODES.NOTHING_TO_FLATTEN,
            "nothing to flatten: '$(file.metadata.name)' declares no `models` and no " *
                "`reaction_systems`. A file carrying only `expression_templates` is a " *
                "template LIBRARY (esm-spec §9.7); import it from a document that " *
                "declares components rather than flattening it directly."
        )
    )
    conflicting = _find_conflicting_derivatives(file)
    isempty(conflicting) || throw(ConflictingDerivativeError(conflicting))
    _check_variable_map_units(file)
    return file, records
end

# Steps 1 and 2: namespace and collect every model, then every reaction system
# (lowered to ODEs), in document order; check the `variable_map` endpoints
# against the collected tables, before any coupling consumes a spelling; record
# the data-fed parameters.
function _collect_components(file::EsmFile, records::AbstractDict{String, Int})
    # The merged template registry (esm-spec §9.6.4 rule 7, §10.7), its bodies
    # component-scoped first (`_scope_component_templates`). Computed before
    # collection because its collision rename must reach each component's
    # reference sites while they are still attributable to their owner.
    template_registry, template_rename =
        _merge_flat_registry(_scope_component_templates(file))
    st = FlattenState(file, template_registry)
    ct = file.component_templates
    if file.models !== nothing
        for (name, model) in file.models
            push!(st.components, name)
            _collect_model!(
                st, model, name;
                tpl_rename = get(template_rename, name, nothing),
                tpl_captures = template_captures(
                    ct === nothing ? nothing : get(ct, "models.$(name)", nothing)
                )
            )
        end
    end
    if file.reaction_systems !== nothing
        for (name, rsys) in file.reaction_systems
            push!(st.components, name)
            _collect_reaction_system!(
                st, rsys, name;
                templates = ct === nothing ? nothing :
                    get(ct, "reaction_systems.$(name)", nothing)
            )
        end
    end
    _check_variable_map_endpoints(file, st.states, st.params, st.observeds)
    st.loader_fields = _loader_fields(file, st.params, records)
    return st
end

# Step 3: apply the coupling entries, by kind in the order §4.7 fixes
# ("Resolution order", normative): every `operator_compose`, then every
# `couple`, then every `variable_map`, keeping the array's order within each
# kind. The order is what makes the result independent of the order the entries
# were typed in: a multiplicative `couple` and an `operator_compose` on the same
# variable do not commute. `variable_map` runs last so its substitution cannot
# rename a dependent variable out from under a merge that has not run.
# `callback`, `operator_apply` and `event` entries apply nothing; they and the
# entry descriptions are recorded in declaration order.
function _apply_coupling!(st::FlattenState)
    file = st.file
    for entry in file.coupling
        push!(st.coupling_rules_applied, describe_coupling_entry(entry))
        if entry isa CouplingOperatorApply
            push!(st.opaque_refs, "operator_apply:$(entry.operator)")
        elseif entry isa CouplingCallback
            push!(st.opaque_refs, "callback:$(entry.callback_id)")
        elseif entry isa CouplingEvent
            push!(st.opaque_refs, "event:$(entry.event_type)")
        end
    end

    for entry in file.coupling
        entry isa CouplingOperatorCompose || continue
        _compose_renames!(
            st.merged_renames,
            _apply_operator_compose!(
                st.equations, entry, st.states, st.observeds;
                renames = st.merged_renames, components = st.components
            )
        )
    end
    # The merge retargets the equation pool itself; every other site still
    # names a merged-away spelling it was namespaced to at collection
    # (CONFORMANCE_SPEC §5.35).
    if !isempty(st.merged_renames)
        renames = st.merged_renames
        _map_flat_sites!(
            e -> _rename_variables(e, renames), st; targets = n -> get(renames, n, n)
        )
    end

    # A coupling entry's origin index is its 0-based position in the expanded
    # coupling sequence, whatever its kind.
    for (k, entry) in enumerate(file.coupling)
        entry isa CouplingCouple || continue
        _apply_couple!(
            st.equations, _retarget_pending_entry(entry, st.merged_renames),
            st.opaque_refs; index = k - 1, states = st.states,
            components = st.components
        )
    end

    # Names a `variable_map` substitution replaced in the equations (an
    # expression `transform` keeps its `to` references, so it is exempt).
    rewritten = Set{String}()
    shapeless = _data_fed_without_shape(file)
    for (k, entry) in enumerate(file.coupling)
        entry isa CouplingVariableMap || continue
        resolved = _retarget_pending_entry(entry, st.merged_renames)
        _apply_variable_map!(
            st.equations, st.params, resolved;
            observeds = st.observeds, index = k - 1, shapeless = shapeless
        )
        resolved.transform isa ASTExpr && continue
        push!(rewritten, resolved.to)
        # Every other site naming the replaced parameter follows the
        # replacement the equations took (esm-libraries-spec §4.7.5).
        _map_flat_sites!(_variable_map_rewrite(resolved), st)
    end
    # A surviving template-registry body is authored source no rewrite above
    # reaches: one that still names a replaced or merged-away variable would
    # expand at the build boundary into a name the system no longer declares.
    # Refused, not rewritten, so the result cannot diverge from the
    # expand-at-load image.
    union!(rewritten, keys(st.merged_renames))
    _check_registry_coupling_rewrites(st.template_registry, rewritten)
    return st
end

# Step 3b: the §10.5 pointwise lift over the state's tables
# (esm-libraries-spec §4.7.5).
_apply_pointwise_lift!(st::FlattenState) = _apply_pointwise_lift!(
    st.equations, st.states, st.params, st.observeds, st.index_sets,
    st.file.coupling;
    template_registry = isempty(st.template_registry) ? nothing : st.template_registry,
    lifted_shapes = st.lifted_shapes, iv = _indep_var(st.file)
)

# Steps 4 to 9: independent variables, metadata, the §6.3.1 subsets, the
# deferred `ic` equations, angle normalization and the elementwise template
# lift; then the `FlattenedSystem`.
function _finish_flatten(st::FlattenState, pointwise)
    ivs = _compute_independent_variables(_pool_equations(st.equations))
    # Components in the order the file declares them (§4.7.5 step 4).
    metadata = FlattenMetadata(
        collect(st.components), st.coupling_rules_applied;
        opaque_coupling_refs = st.opaque_refs,
        merged_variable_renames = st.merged_renames,
        reserved_liftings = _reserved_liftings(st.file.coupling),
    )
    # The §6.3.1 subsets, every membership decided by the classification
    # accessors run over the flattened form (esm-spec §6.3.1: "the ONLY
    # sanctioned way to ask these questions"); the order is the parents'.
    view = _classification_model(
        st.states, st.params, st.observeds, _pool_equations(st.equations)
    )
    algebraic = algebraic_unknowns(view)
    brownian = brownian_parameters(view)
    discrete = discrete_parameters(view)
    # The deferred `ic` equations leave `equations` (§4.7.5 step 4, normative);
    # last, so every pass above saw the list it always did.
    st.field_ics = _extract_field_ics!(st.equations)
    # A scaled angle argument of `sin`/`cos`/`tan` to radians (esm-spec §4.8.3).
    _normalize_angle_arguments!(st)
    # Each elementwise template application (esm-spec §9.6.11) as its per-cell
    # `faq`, reusing the shapes the pointwise lift inferred.
    st.field_ics = _lift_elementwise_applications_flat!(
        st.equations, st.field_ics, st.states, st.params, st.observeds,
        st.template_registry;
        seed = pointwise === nothing ? nothing : pointwise.shapes,
        stale = pointwise === nothing ? () : pointwise.stale
    )
    return FlattenedSystem(;
        independent_variables = ivs,
        state_variables = st.states, parameters = st.params,
        observed_variables = st.observeds, equations = _pool_equations(st.equations),
        continuous_events = st.continuous_events, discrete_events = st.discrete_events,
        domain = st.file.domain, metadata = metadata, index_sets = st.index_sets,
        template_registry = st.template_registry,
        algebraic_variables = algebraic, brownian_parameters = brownian,
        discrete_parameters = discrete, field_ics = st.field_ics,
        loader_fields = st.loader_fields, lifted_shapes = st.lifted_shapes,
        equation_contributions = Vector{Contribution}[f.contribs for f in st.equations],
        initialization_equations = st.init_equations,
    )
end

"""
    _normalize_angle_arguments!(st::FlattenState)

Fold the declared angle scale into every circular-trig argument, so the
evaluator receives RADIANS (esm-spec §4.8.3, "Angles are the ONE exception"):
`sin(theta)` with `theta` in `deg` becomes `sin(theta * π/180)`. The conversion
is exact and has one reading.

`flatten` is the funnel every consumer draws from, so converting here converts
for all of them. It is not on the validation path (`validate` never flattens):
the checker keeps the authored spelling, whose bare literal would otherwise
make the product's unit undeterminable (§4.8.4). Every expression site is
rewritten; the other bindings run the same phase at the same point.
"""
function _normalize_angle_arguments!(st::FlattenState)
    var_units = Dict{String, String}()
    for table in (st.states, st.params, st.observeds), (name, var) in table
        haskey(var_units, name) && continue
        var.units !== nothing && !isempty(var.units) &&
            parse_units(var.units) !== nothing && (var_units[name] = var.units)
    end
    # Nothing declared at an angle scale other than 1: nothing to rewrite.
    any(
        angle_normalization_factor(parse_units(u)) !== nothing
            for u in values(var_units)
    ) || return st
    # An array operator carries its element's unit (the checker's rule too), so
    # `cos(index(lat, i))` with `lat` in `deg` converts like `cos(lat)`.
    _map_flat_sites!(e -> _normalize_angle_expr(e, var_units), st; equations = true)
    return st
end

# Rewrite every `sin`/`cos`/`tan` in `expr` whose argument is an angle at a scale
# other than 1 so the argument is in RADIANS, inner calls first. Returns `expr`
# itself when nothing applies.
_normalize_angle_expr(expr::ASTExpr, var_units::AbstractDict)::ASTExpr =
    _rewrite_expr((x, _) -> x, (n, _) -> _angle_to_radians(n, var_units), expr)

function _angle_to_radians(out::OpExpr, var_units::AbstractDict)::ASTExpr
    (out.op in ("sin", "cos", "tan") && length(out.args) == 1) || return out
    arg_unit = _expr_dimensions!(String[], out.args[1], var_units)
    arg_unit === nothing && return out
    factor = angle_normalization_factor(arg_unit)
    factor === nothing && return out
    scaled = OpExpr("*", ASTExpr[out.args[1], NumExpr(factor)])
    return reconstruct(out; args = ASTExpr[scaled])
end

"""
    flatten(model::Model; name::String="anonymous") -> FlattenedSystem

Convenience: wrap a single Model in a synthetic EsmFile (with a default system
name) and run the full flattener. `ModelingToolkit.System(::Model)` in the
MTK extension calls it.
"""
function flatten(model::Model; name::String = "anonymous")::FlattenedSystem
    file = EsmFile(
        SCHEMA_VERSION, Metadata(name);
        models = Dict{String, Model}(name => model)
    )
    return flatten(file)
end

"""
    flatten(rsys::ReactionSystem; name::String="anonymous") -> FlattenedSystem

Convenience: wrap a ReactionSystem in a synthetic EsmFile and flatten.
"""
function flatten(rsys::ReactionSystem; name::String = "anonymous")::FlattenedSystem
    file = EsmFile(
        SCHEMA_VERSION, Metadata(name);
        reaction_systems = Dict{String, ReactionSystem}(name => rsys)
    )
    return flatten(file)
end

# ========================================
# FlattenedSystem → runnable single-model ESM document
# ========================================

# esm-spec §9.6.4 rule 7 / §10.7: registry bodies are COMPONENT-SCOPED source —
# their free variable references resolve in the owning component's namespace,
# exactly as the expand-at-load image does (load-time expansion splices the body
# into the component's equations BEFORE flatten renames them). The flattened
# registry must therefore carry bodies whose free variables are renamed with the
# SAME (prefix, local-name) map `_collect_model!` applies to the component's
# equations — otherwise a body spliced at the BUILD boundary (the
# reference-preserving fast path, or `expand_flattened_refs`) references bare
# names the flat var_map does not contain. Template formal params are EXCLUDED
# from the rename set: they are the template's own scope, substituted at
# expansion, never component variables. Nested reference BINDINGS inside a body
# are scoped by `namespace_expr`'s apply arm; body-local aggregate loop names
# are not component variables, so the map never touches them. The caller's
# `EsmFile` registry is untouched (emit still produces the authored bodies) —
# this scopes a COPY for the flat registry only. Reaction-system blocks pass
# through unscoped BY POLICY (the flatten invariant): references survive
# flatten only in MODEL equations; reaction-RATE references are always expanded
# eagerly at collect (`_collect_reaction_system!`, before namespacing), so a
# reaction-system registry entry is never resolved against post-flatten — it
# rides along solely so the reconstituted document round-trips.
function _scope_component_templates(file::EsmFile)
    ct = file.component_templates
    ct === nothing && return nothing
    # OrderedDict, iterated in the order the parser recorded the components:
    # `_merge_flat_registry` consumes this map positionally now that §4.7.5
    # step 4 makes the merged registry document-ordered.
    out = OrderedDict{String, Any}()
    for (compkey, block) in ct
        parts = split(String(compkey), "."; limit = 2)
        model = length(parts) == 2 && parts[1] == "models" && file.models !== nothing ?
            get(file.models, String(parts[2]), nothing) : nothing
        if !(model isa Model) || !_is_object(block)
            out[String(compkey)] = block
            continue
        end
        cname = String(parts[2])
        local_names = Set{String}(keys(model.variables))
        for (sub_name, _) in model.subsystems
            push!(local_names, sub_name)
        end
        newblock = OrderedDict{String, Any}()
        for (tname, decl) in pairs(block)
            body_raw = _raw_get(decl, "body")
            if body_raw === nothing
                newblock[string(tname)] = decl
                continue
            end
            pnames = Set{String}()
            params_raw = _raw_get(decl, "params")
            if params_raw isa AbstractVector
                for p in params_raw
                    p isa AbstractString && push!(pnames, String(p))
                end
            end
            scoped = namespace_expr(
                expression_from_json(body_raw), cname,
                setdiff(local_names, pnames)
            )
            nd = OrderedDict{String, Any}(string(k) => v for (k, v) in pairs(decl))
            nd["body"] = serialize_expression(scoped)
            newblock[string(tname)] = nd
        end
        out[String(compkey)] = newblock
    end
    return out
end

"""
    _check_registry_coupling_rewrites(registry, rewritten)

Shadow-registry validation (flatten-time, cheap): `_substitute_variable_map!`
rewrites a coupling `variable_map`'s `to` name in every VISIBLE equation AST,
but a surviving template-registry body is authored source the substitution
never touches. If such a body still references a rewritten name, its expansion
at the build boundary would surface a STALE reference (for `param_to_var` /
`conversion_factor`, a deleted parameter → `E_TREEWALK_UNBOUND_VARIABLE` deep
in the build; for the scaling transforms, a silent semantic divergence from the
Expand-at-load image). Throw a clear error naming the template and the variable
instead. Free names are collected with the generated walkers
(`foreach_subexpr` descends `bindings` and `ranges`); the template's own formal
`params` are its private scope and excluded.
"""
function _check_registry_coupling_rewrites(registry, rewritten::Set{String})
    (isempty(registry) || isempty(rewritten)) && return nothing
    for tname in sort!(collect(keys(registry)))
        decl = registry[tname]
        _is_object(decl) || continue
        body_raw = _raw_get(decl, "body")
        body_raw === nothing && continue
        pnames = Set{String}()
        params_raw = _raw_get(decl, "params")
        if params_raw isa AbstractVector
            for p in params_raw
                p isa AbstractString && push!(pnames, String(p))
            end
        end
        names = Set{String}()
        foreach_subexpr(expression_from_json(body_raw)) do x
            x isa VarExpr && push!(names, x.name)
            nothing
        end
        hits = sort!(collect(intersect(setdiff(names, pnames), rewritten)))
        isempty(hits) || throw(
            ExpressionTemplateError(
                ERROR_CODES.TEMPLATE_BODY_REFERENCES_COUPLING_REWRITTEN_VARIABLE,
                "expression template '$(String(tname))' body references " *
                    "'$(join(hits, "', '"))', which a coupling rule rewrote in " *
                    "the flattened equations; the registry body would expand to a stale " *
                    "name at the build boundary. Bind the value through the template's " *
                    "params, or expand the reference before coupling (esm-spec §9.6.4)."
            )
        )
    end
    return nothing
end

"""
    flattened_to_esm(flat::FlattenedSystem; name="Flattened", esm_version=SCHEMA_VERSION) -> Dict{String,Any}

Reconstitute a `FlattenedSystem` into a single-model native ESM **document**
(`Dict{String,Any}`): the exporter for a caller that wants the flattened system
as a document. The build does not read it; it compiles a typed run file made
from the flattened system directly.

The single model collects:
- all three variable partitions (states, parameters, observeds) — observeds keep
  their defining `expression`, which the geometry materializer reads directly;
- every flattened equation (state ODEs + the synthesized observed definitions),
  so the evaluator's own observed-equation synthesis is a no-op (it skips any
  observed already defined by an equation — no double definition);
- the namespaced initialization equations;
- the document-scoped `index_sets` registry (esm-spec v0.8.0), emitted at the
  top level so the regridders' `ranges.from` / `from_faq` / producer `id`
  references resolve.

`equation_contributions` is NOT carried: the `.esm` format has no slot for
per-term provenance (esm-libraries-spec §4.7.5), so it is a documented loss.
"""
function flattened_to_esm(
        flat::FlattenedSystem;
        name::AbstractString = "Flattened",
        esm_version::AbstractString = SCHEMA_VERSION
    )::Dict{String, Any}
    sname = String(name)

    variables = Dict{String, Any}()
    # Order: states, parameters, observeds. `state_variables` and
    # `observed_variables` are NOT disjoint — esm-libraries-spec §4.7.5 step 4
    # files a materialized arrayed observed in both — but the two maps hold the
    # SAME `ModelVariable` for such a name, so the second write reproduces the
    # first and the merge stays unambiguous. `parameters` is disjoint from both.
    for partition in (flat.state_variables, flat.parameters, flat.observed_variables)
        for (k, v) in partition
            variables[k] = serialize_model_variable(v)
        end
    end

    # `field_ics` are REMOVED from `flat.equations` (esm-libraries-spec §4.7.5
    # step 4) because an initial condition is not an equation of motion — but a
    # DOCUMENT spells an initial condition as exactly an `ic(state) ~ rhs`
    # equation (esm-spec §11.4.1), so they are re-emitted here. Dropping them
    # would make the reconstituted document lose its `u0`: the tree-walk build's
    # `_split_ic_equations` reads `ic` out of the document's `equations`, and
    # without this every field-IC'd state silently seeds to its bare `default`.
    equations = Any[serialize_equation(eq) for eq in flat.equations]
    for (state, rhs) in flat.field_ics
        push!(
            equations, serialize_equation(
                Equation(OpExpr("ic", ASTExpr[VarExpr(state)]), rhs)
            )
        )
    end

    model = Dict{String, Any}(
        "variables" => variables,
        "equations" => equations,
    )
    # The namespaced initialization equations (esm-spec §6.2), which a
    # document carries on its model.
    isempty(flat.initialization_equations) || (
        model["initialization_equations"] =
            Any[serialize_equation(eq) for eq in flat.initialization_equations]
    )
    # esm-spec §9.6.4 Option B: surviving `apply_expression_template` references
    # in the equations resolve against the merged registry — emit it as the
    # model's `expression_templates` block so the reconstituted document is
    # self-contained (the tree-walk front-door re-parses it into
    # `EsmFile.component_templates` and the impl entry expands with site
    # recording). Absent for every reference-free system.
    if !isempty(flat.template_registry)
        model["expression_templates"] =
            OrderedDict{String, Any}(String(k) => v for (k, v) in flat.template_registry)
    end

    doc = Dict{String, Any}(
        "esm" => String(esm_version),
        "metadata" => Dict{String, Any}("name" => sname),
        "models" => Dict{String, Any}(sname => model),
    )
    # esm-spec v0.8.0: the index-set registry is document-scoped — emit it as a
    # sibling of `models` so the reconstituted document validates and both the
    # typed (`coerce_esm_file`) and value-invention front-doors resolve it.
    if !isempty(flat.index_sets)
        doc["index_sets"] = Dict{String, Any}(
            k => serialize_index_set(v) for (k, v) in flat.index_sets
        )
    end
    if flat.domain !== nothing
        # v0.8.0: single top-level `domain` object shared by the document; a
        # model is spatial via its variable shapes, not a `domain` reference.
        doc["domain"] = serialize_domain(flat.domain)
    end
    return doc
end

"""
    expand_flattened_refs(flat::FlattenedSystem) -> FlattenedSystem

The shared "Expand at your boundary" utility for `FlattenedSystem` consumers
(esm-spec §9.6.4 rule 2, RFC out-of-line-expression-templates §7.7): expand
every surviving `apply_expression_template` reference against the merged
`template_registry`, returning an Expanded copy, bit-identical to the
Expand-at-load image. A no-op when the registry is empty (no references
survived). `flatten` ALWAYS carries references, so a consumer with no template
handling calls this at its entry — the ModelingToolkit `System` constructor does; the
tree-walk build does NOT (it expands at its own entry with site recording).

Expanded positions: the equations, the field initial conditions, every event
expression (conditions, condition triggers, affect right-hand sides), and each
variable's sites (update rules and expression bounds, `_map_variable_sites`)
in all three variable buckets; a bucket with no reference is kept as it is.
The three subset maps (`algebraic_variables`, `brownian_parameters`,
`discrete_parameters`) are re-read from the expanded buckets, so they hold the
same expanded variables.

`memo` is the shared expansion memo (`_expand_model_refs!`'s default):
structurally identical apply sites expand once and share the result. Pass `nothing` for the
per-site re-expansion. Sharing is safe here for the same reason it is in
`_expand_model_refs!` — the expanded set becomes a DAG, which is what interning
would produce one pass later anyway.
"""
function expand_flattened_refs(
        flat::FlattenedSystem;
        memo::Union{_ExpandMemo, Dict{Tuple{String, String}, OpExpr}} = _ExpandCache()
    )::FlattenedSystem
    memo = _expand_cache(memo)
    reg = flat.template_registry
    isempty(reg) && return flat
    # Expansion rewrites inside each contribution (esm-libraries-spec §4.7.5): a
    # reference whose body is a sum expands into terms that all inherit the
    # contribution's origins.
    expand = e -> _expand_expr_refs(e, reg, nothing, memo)
    neweqs, newcontribs = _rewrite_flat_equations(expand, flat)
    states = _map_variable_sites(expand, flat.state_variables)
    params = _map_variable_sites(expand, flat.parameters)
    observeds = _map_variable_sites(expand, flat.observed_variables)
    return FlattenedSystem(
        flat; equations = neweqs, equation_contributions = newcontribs,
        state_variables = states, parameters = params, observed_variables = observeds,
        algebraic_variables = _resubset(flat.algebraic_variables, states, observeds),
        brownian_parameters = _resubset(flat.brownian_parameters, params),
        discrete_parameters = _resubset(flat.discrete_parameters, params),
        field_ics = Pair{String, ASTExpr}[name => expand(e) for (name, e) in flat.field_ics],
        continuous_events = _map_event_exprs(expand, flat.continuous_events),
        discrete_events = _map_event_exprs(expand, flat.discrete_events)
    )
end

# The §6.3.1 subset maps re-read from their parents after a pass rewrote the
# parents' variables, so a subset never holds a stale copy.
_resubset(subset::OrderedDict{String, ModelVariable}, parents::OrderedDict{String, ModelVariable}...) =
    _in_document_order(Set{String}(keys(subset)), parents...)
