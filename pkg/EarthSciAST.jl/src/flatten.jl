"""
Coupled System Flattening for ESM Format.

Implements spec §4.7.5 (flattening algorithm) and §4.7.6 (dimension promotion).

`flatten(::EsmFile)` produces a `FlattenedSystem`: a single flat equation system
with dot-namespaced variables and real ASTExpr-tree equations. Reactions are lowered
to ODEs via `lower_reactions_to_equations`; coupling rules merge RHS terms;
`variable_map` substitutes parameters; `operator_apply`/`callback` are recorded
opaquely in metadata.

This file holds the `FlattenedSystem` type, the reaction→ODE lowering, and the
top-level `flatten` orchestrator. The pipeline's stages live in sibling files:
- `flatten_errors.jl` — the exported §4.7.5/§4.7.6 error taxonomy;
- `namespacing.jl` — dot-namespacing + per-system collection (steps 1+2);
- `coupling_apply.jl` — preflight checks + coupling-rule application (step 3);
- `pointwise_lift.jl` — the §10.5 pointwise spatial lift (step 3b);
- `array_shape_inference.jl` — the standalone `infer_array_shapes` pass.
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
  flattened (sorted for determinism).
- `coupling_rules_applied::Vector{String}`: human-readable summary of each
  coupling entry applied.
- `dimension_promotions_applied::Vector{NamedTuple}`: records of each dimension
  promotion — e.g. `(variable="Chem.O3", source_domain=nothing, target_domain="grid2d", kind=:broadcast)`.
- `opaque_coupling_refs::Vector{String}`: opaque runtime references recorded
  for `operator_apply` and `callback` couplings.
"""
struct FlattenMetadata
    source_systems::Vector{String}
    coupling_rules_applied::Vector{String}
    dimension_promotions_applied::Vector{NamedTuple}
    opaque_coupling_refs::Vector{String}
end

FlattenMetadata(source_systems::Vector{String}=String[],
                coupling_rules_applied::Vector{String}=String[];
                dimension_promotions_applied::Vector{<:NamedTuple}=NamedTuple[],
                opaque_coupling_refs::Vector{String}=String[]) =
    FlattenMetadata(source_systems, coupling_rules_applied,
                    NamedTuple[dp for dp in dimension_promotions_applied],
                    opaque_coupling_refs)

"""
    LoaderField

A data-fed PARAMETER lowered to a flattened array input (esm-spec §8.5), and one
entry of [`FlattenedSystem`](@ref)'s `loader_fields`.

From esm 1.0.0 a data source is NOT a component: there is no loader subsystem and
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
"""
struct LoaderField
    name::String
    owner::String
    subkey::String
    var::String
    cadence::String
    unit_conversion::Union{Float64, ASTExpr, Nothing}

    LoaderField(name::AbstractString, owner::AbstractString,
                subkey::AbstractString, var::AbstractString,
                cadence::AbstractString; unit_conversion=nothing) =
        new(String(name), String(owner), String(subkey), String(var),
            String(cadence), unit_conversion)
end

"""
    FlattenedSystem

A coupled ESM file flattened into a single symbolic representation.

All variables, parameters, and species are dot-namespaced (e.g.
`"SimpleOzone.O3"`, `"Atmosphere.Chemistry.NO2"`). Equations are real
`Equation` objects whose ASTExpr trees reference namespaced names via `VarExpr`.
This is the canonical intermediate form consumed by MTK/PDESystem constructors
(in the Julia extension) and by cross-language code generators.

Fields:
- `independent_variables::Vector{Symbol}`: `[:t]` for pure-ODE systems, or
  `[:t, :x, :y, ...]` when spatial operators are present.
- `state_variables::OrderedDict{String, ModelVariable}`: namespaced state
  variables and (former-reaction) species.
- `parameters::OrderedDict{String, ModelVariable}`: namespaced parameters,
  minus any promoted to variables by `variable_map`.
- `observed_variables::OrderedDict{String, ModelVariable}`: namespaced
  observed variables.
- `equations::Vector{Equation}`: all equations after reaction lowering and
  coupling, with variable references rewritten to namespaced form.
- `continuous_events::Vector{ContinuousEvent}`: collected from every source
  model with references rewritten.
- `discrete_events::Vector{DiscreteEvent}`: ditto.
- `domain::Union{Domain, Nothing}`: the target domain after any dimension
  promotion (§4.7.6), or `nothing` for purely 0D systems.
- `metadata::FlattenMetadata`: provenance.
- `index_sets::OrderedDict{String, IndexSet}`: the merged document-scoped
  index-set registry (RFC semiring-faq-unified-ir §5.2), collected from every
  source model and namespaced per-component (`<prefix>.<setname>`) so the value-
  invention geometry of sibling components — e.g. five conservative regridders
  each declaring `src_cells` / `candidate_pairs` / `clip_ring` — does not
  collide after flattening. Empty when no source model declares any.
- `function_tables::Dict{String, FunctionTable}`: the file-scoped sampled
  function tables (esm-spec §9.5) referenced by `table_lookup` AST nodes. These
  are keyed by globally-unique table id, so they are merged without namespacing.
  Empty when the file declares none. Carrying both here is what lets a flattened
  system round-trip back into a runnable single-model `EsmFile` (`flattened_to_esm`)
  without dropping the geometry registry or the table data.
- `template_registry::OrderedDict{String, Any}`: the merged expression-template
  registry (esm-spec §9.6.4 rule 7 / §10.7).
- `algebraic_variables::OrderedDict{String, ModelVariable}`: unknowns constrained
  only by an expression-LHS equation (esm-spec §6.3.1). A **subset** of
  `state_variables`, not a sibling bucket — a DAE solves for them, so they occupy
  a slot of the `u` vector.
- `brownian_parameters::OrderedDict{String, ModelVariable}`: `update.kind ==
  "wiener"`. A **subset** of `parameters`. This bucket is what makes the flattened
  form self-describing: §6.3.1's `system_kind` derivation tests it FIRST, so a
  `FlattenedSystem` that dropped it could not report `"sde"` and a consumer would
  integrate a stochastic system as a deterministic one.
- `discrete_parameters::OrderedDict{String, ModelVariable}`: any other `update`.
  A **subset** of `parameters`.
- `field_ics::Vector{Pair{String, ASTExpr}}`: deferred `ic` equations (esm-spec
  §11.4.1), REMOVED from `equations`.
- `loader_fields::Vector{LoaderField}`: provider-served loaded fields the system
  consumes (esm-spec §8.5).
- `lifted_shapes::OrderedDict{String, Vector{Int}}`: post-lift grid extents for
  arrayed states (§10.5).

ORDERING (esm-libraries-spec §4.7.5 step 4, normative): every ordered map and
list above is in DOCUMENT ORDER — components in the order the file declares them,
variables in the order their component declares them, coupling-merged entries
keeping the position of their first occurrence. Ordering is observable, because a
parameter vector is positional; lexicographic sorting or a host map's iteration
order is non-conforming. The order therefore has to be preserved at the SOURCE:
`EsmFile.models` / `.reaction_systems` / `.index_sets` / `.function_tables` and
`Model.variables` / `.subsystems` are `OrderedDict`s populated by the parser in
document order, so the accumulators here inherit it.
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
    function_tables::OrderedDict{String, FunctionTable}
    # esm-spec §9.6.4 rule 7 / §10.7 / esm-libraries-spec §4.7.5 step 4 (Option B):
    # the MERGED template registry — the union of the component registries
    # (deep-equal dedup, deterministic `<ComponentPath>.<name>` collision rename).
    # Downstream consumers resolve surviving `apply_expression_template`
    # references against it (or `Expand` them; §9.6.4 rule 2). Empty when no
    # references survived (or `ESS_TEMPLATE_REF_DISABLE=1`).
    template_registry::OrderedDict{String, Any}
    # ── esm-libraries-spec §4.7.5 step 4, the canonical field set (esm 1.0.0) ──
    # The three §6.3.1 SUBSET maps. Each is a subset of the map above it and
    # NEVER removes its members from that map: `algebraic_variables` ⊆
    # `state_variables` (a DAE solves for an algebraic unknown, so it occupies a
    # slot of the `u` vector), `brownian_parameters` ⊆ `parameters` and
    # `discrete_parameters` ⊆ `parameters` (esm-spec §6.3.1 says the four
    # parameter sets PARTITION the parameters, so a wiener-updated entry is a
    # parameter that ALSO appears in `brownian_parameters` — dropping it would
    # make the parameter vector's LENGTH depend on whether the model happens to
    # be stochastic). Membership comes from the classification accessors run over
    # the FLATTENED form; only the ORDER is re-imposed here, by filtering the
    # already-document-ordered parent map.
    algebraic_variables::OrderedDict{String, ModelVariable}
    brownian_parameters::OrderedDict{String, ModelVariable}
    discrete_parameters::OrderedDict{String, ModelVariable}
    # Deferred `ic` equations (esm-spec §11.4.1) as ordered `state => rhs` pairs.
    # These entries are REMOVED from `equations` (§4.7.5 step 4, normative): an
    # initial condition is a datum, not an equation of motion, so leaving it in
    # `equations` makes that list unusable for building a right-hand side without
    # filtering and makes equation counts incomparable across bindings.
    field_ics::Vector{Pair{String, ASTExpr}}
    # Provider-served loaded fields the system consumes — one per data-fed
    # PARAMETER (`update.kind == "data"`, esm-spec §8.5).
    loader_fields::Vector{LoaderField}
    # Post-lift grid shapes for arrayed states: the §10.5 pointwise lift's
    # per-dimension CELL EXTENTS, keyed by the lifted state's namespaced name.
    lifted_shapes::OrderedDict{String, Vector{Int}}

    # The one entry path, and it COERCES. Every ordered map here is an
    # `OrderedDict`, and Julia's implicit conversion from a plain `Dict` is
    # (correctly) refused as order-losing. The flattener always passes ordered
    # maps; a HAND-BUILT caller — an MTK fixture, a downstream package splicing a
    # registry — may still pass a `Dict`, whose iteration order is the only order
    # it has. Coercing here keeps such a call working WITHOUT widening the field
    # types, which is what would let hash order back into a positional parameter
    # vector.
    FlattenedSystem(ivs, sv, p, obs, eqs, cev, dev, dom, meta, isets, ftabs, treg,
                    alg, brw, disc, ics, lfs, lshapes) =
        new(Symbol[iv for iv in ivs], _flat_od(ModelVariable, sv), _flat_od(ModelVariable, p),
            _flat_od(ModelVariable, obs), eqs, cev, dev, dom, meta,
            _flat_od(IndexSet, isets), _flat_od(FunctionTable, ftabs),
            _flat_od(Any, treg), _flat_od(ModelVariable, alg),
            _flat_od(ModelVariable, brw), _flat_od(ModelVariable, disc),
            Pair{String, ASTExpr}[Pair{String, ASTExpr}(String(k), v) for (k, v) in ics],
            LoaderField[lf for lf in lfs], _flat_od(Vector{Int}, lshapes))
end

# The map coercion the inner constructor above applies. An already-ordered map
# passes through untouched; anything else is rebuilt in ITS iteration order.
_flat_od(::Type{V}, d::OrderedDict{String, V}) where {V} = d
_flat_od(::Type{V}, d::AbstractDict) where {V} =
    OrderedDict{String, V}(String(k) => v for (k, v) in d)

# Backward-compatible constructors: callers that predate the index-set /
# function-table / template registries (e.g. hand-built MTK PDESystem fixtures)
# get empty registries, and callers that predate the esm-1.0.0 canonical field
# set (the §6.3.1 subset maps, `field_ics`, `loader_fields`, `lifted_shapes`)
# get empty ones. Adding a field must NOT silently drop a positional caller, so
# every historical arity is spelled out here rather than left to break at the
# call site; the full flattener always passes all fields, and every
# copy-with-changes goes through the keyword copy-constructor below.
_flat_empty_vars() = OrderedDict{String, ModelVariable}()
FlattenedSystem(ivs, sv, p, obs, eqs, cev, dev, dom, meta) =
    FlattenedSystem(ivs, sv, p, obs, eqs, cev, dev, dom, meta,
                    OrderedDict{String, IndexSet}(),
                    OrderedDict{String, FunctionTable}(),
                    OrderedDict{String, Any}())
FlattenedSystem(ivs, sv, p, obs, eqs, cev, dev, dom, meta, isets, ftabs) =
    FlattenedSystem(ivs, sv, p, obs, eqs, cev, dev, dom, meta, isets, ftabs,
                    OrderedDict{String, Any}())
FlattenedSystem(ivs, sv, p, obs, eqs, cev, dev, dom, meta, isets, ftabs, treg) =
    FlattenedSystem(ivs, sv, p, obs, eqs, cev, dev, dom, meta, isets, ftabs, treg,
                    _flat_empty_vars(), _flat_empty_vars(), _flat_empty_vars(),
                    Pair{String, ASTExpr}[], LoaderField[],
                    OrderedDict{String, Vector{Int}}())

"""
    FlattenedSystem(flat::FlattenedSystem; kwargs...) -> FlattenedSystem

Keyword copy-constructor: rebuild a `FlattenedSystem`, copying every field from
`flat` by default and overriding only the keywords explicitly passed. Route all
copy-with-changes transforms (e.g. the shape-promotion passes) through this so
a newly added field is preserved by default instead of silently dropped by an
11-positional-argument re-listing.
"""
FlattenedSystem(flat::FlattenedSystem;
        independent_variables = flat.independent_variables,
        state_variables = flat.state_variables,
        parameters = flat.parameters,
        observed_variables = flat.observed_variables,
        equations = flat.equations,
        continuous_events = flat.continuous_events,
        discrete_events = flat.discrete_events,
        domain = flat.domain,
        metadata = flat.metadata,
        index_sets = flat.index_sets,
        function_tables = flat.function_tables,
        template_registry = flat.template_registry,
        algebraic_variables = flat.algebraic_variables,
        brownian_parameters = flat.brownian_parameters,
        discrete_parameters = flat.discrete_parameters,
        field_ics = flat.field_ics,
        loader_fields = flat.loader_fields,
        lifted_shapes = flat.lifted_shapes) =
    FlattenedSystem(independent_variables, state_variables, parameters,
                    observed_variables, equations, continuous_events,
                    discrete_events, domain, metadata, index_sets,
                    function_tables, template_registry,
                    algebraic_variables, brownian_parameters, discrete_parameters,
                    field_ics, loader_fields, lifted_shapes)

# ========================================
# ODE-vs-PDE split predicate + redirect messages
# ========================================

"""
    _has_spatial_ivs(flat::FlattenedSystem) -> Bool

Return true when the flattened system has spatial independent variables
(i.e. needs a PDESystem rather than an ODESystem). A FlattenedSystem with
`[:t]` only is a pure ODE; anything else is a PDE.
"""
function _has_spatial_ivs(flat::FlattenedSystem)
    return !(length(flat.independent_variables) == 1 &&
             flat.independent_variables[1] == :t)
end

"""
    _use_pde_ctor_msg(flat, pde_ctor, ode_ctor) -> String

Error text for calling an ODE-only constructor (`ode_ctor`, e.g.
`"ModelingToolkit.System"`) on a flattened system with spatial independent
variables. Used by the MTK extension so the redirect wording stays
consistent everywhere the split is enforced.
"""
_use_pde_ctor_msg(flat::FlattenedSystem, pde_ctor::String, ode_ctor::String) =
    "Flattened system has independent variables $(flat.independent_variables), " *
    "which indicates a PDE. Use $(pde_ctor)(...) instead of $(ode_ctor)(...)."

"""
    _use_ode_ctor_msg(ode_ctor, pde_ctor) -> String

Mirror of [`_use_pde_ctor_msg`](@ref): error text for calling a PDE-only
constructor (`pde_ctor`) on a pure-ODE flattened system.
"""
_use_ode_ctor_msg(ode_ctor::String, pde_ctor::String) =
    "Flattened system has independent variables [t] only — this is a " *
    "pure ODE system. Use $(ode_ctor)(...) instead of $(pde_ctor)(...)."

# ========================================
# Reaction Lowering Helper (§4.6 + §4.7.6)
# ========================================

"""
    lower_reactions_to_equations(reactions, species) -> Vector{Equation}

Produce the ODE equations induced by a set of reactions using standard
mass-action kinetics: `d[X]/dt = Σ (stoich_ij * rate_j)`.

Shared by `derive_odes` (reaction → Model) and `flatten` (EsmFile → FlattenedSystem)
so there is exactly one place that turns stoichiometry into equations.

The LHS is always `D(X, t)` symbolically, regardless of the document's
domain — dimension promotion (§4.7.6) is applied by `flatten`, not here.
Spatial operators are added downstream when coupling adds them.

A species with `constant: true` is a RESERVOIR (§7.4): it is held fixed, so no
`D(X, t)` equation is emitted for it, while it still contributes its
concentration to every rate law it appears in. It is therefore skipped as an
equation TARGET only — it stays in `species` so `mass_action_rate` keeps
reading it as a substrate/product factor.
"""
function lower_reactions_to_equations(reactions::Vector{Reaction},
                                      species::Vector{Species})::Vector{Equation}
    equations = Equation[]
    if isempty(species)
        return equations
    end

    species_names = [sp.name for sp in species]
    species_idx = Dict{String, Int}(name => i for (i, name) in enumerate(species_names))

    n_species = length(species_names)
    n_rxns = length(reactions)
    S = zeros(Float64, n_species, n_rxns)

    for (j, rxn) in enumerate(reactions)
        for (sp, signed_stoich) in each_stoich_term(rxn)
            if haskey(species_idx, sp)
                S[species_idx[sp], j] += signed_stoich
            end
        end
    end

    for (i, name) in enumerate(species_names)
        # Reservoir species (§7.4): held fixed, so it gets no ODE. Its
        # mass-action contribution to the OTHER species' rates is untouched —
        # `mass_action_rate` reads it from `species` either way.
        species[i].constant === true && continue
        lhs = OpExpr("D", ASTExpr[VarExpr(name)], wrt="t")
        terms = ASTExpr[]
        for (j, rxn) in enumerate(reactions)
            stoich = S[i, j]
            stoich == 0 && continue
            rate_expr = mass_action_rate(rxn, species)
            if stoich == 1
                push!(terms, rate_expr)
            elseif stoich == -1
                push!(terms, OpExpr("-", ASTExpr[rate_expr]))
            else
                push!(terms, OpExpr("*",
                    ASTExpr[NumExpr(Float64(stoich)), rate_expr]))
            end
        end
        rhs = if isempty(terms)
            NumExpr(0.0)
        elseif length(terms) == 1
            terms[1]
        else
            OpExpr("+", terms)
        end
        push!(equations, Equation(lhs, rhs))
    end

    return equations
end

# ========================================
# Spatial-axis detection (structural, esm-spec §4.2 / §4.9.1(ii) / §11.2)
# ========================================

# The spatial-calculus sugar `grad`/`div`/`laplacian` carry NO privilege: they
# are ordinary open-tier rewrite-target ops (op_registry.jl leaves them
# unregistered). Spatial axes are harvested STRUCTURALLY from the `dim`/`wrt`
# scalar FIELDS of any node — never from a hand-maintained op-name list — so
# there is no `_SPATIAL_OPS` / `_DIM_SPATIAL_OPS` set anymore, and a user
# rewrite-target op carrying a `dim` contributes its axis exactly as `grad`
# does. (A fully shape-derived rederivation over `index_sets`, §11.2, is the
# other admissible structural signal; the by-field `dim`/`wrt` harvest is the
# smaller one and is what §4.9.1(ii) pins for coordinate-name resolution.)

"""
    spatial_dims_in_expr(expr) -> Vector{Symbol}

Collect every spatial-axis name referenced in `expr`, resolved STRUCTURALLY by
field (esm-spec §4.9.1(ii)): the value of a `dim` field on ANY Expression node
(a user rewrite-target op's `dim` names an axis exactly as `grad`'s does), plus
a spatial `wrt` (a `wrt` naming an axis other than the independent variable) on
a `D` node. No op name is privileged.

Returned in FIRST-ENCOUNTER order, deduplicated. This used to return a
`Set{Symbol}`, whose iteration order is the host hash's — and it feeds
`independent_variables`, which §4.7.5 step 4 requires to be in document order and
which downstream constructors read POSITIONALLY to decide a PDESystem's axes. A
set there made `[t, y, x]` out of a document that writes `x` before `y`.
"""
function spatial_dims_in_expr(expr::ASTExpr)::Vector{Symbol}
    dims = Symbol[]
    _collect_spatial_dims!(dims, expr, IdDict{OpExpr,Nothing}())
    return dims
end

# `seen` visits each unique node once: a structurally-shared expression DAG
# (template expansion) hangs the same subtree under exponentially many paths,
# and this is a pure query of the node.
function _collect_spatial_dims!(dims::Vector{Symbol}, expr::ASTExpr,
                                seen::IdDict{OpExpr,Nothing})
    if expr isa OpExpr
        haskey(seen, expr) && return
        seen[expr] = nothing
        # A `dim` scalar field names a spatial axis regardless of the op
        # carrying it (grad/div sugar or any user rewrite-target op). A spatial
        # `D` names its axis via `wrt` — the independent variable `t` is
        # temporal, not spatial, and `D`'s structural time-derivative handling
        # is untouched; only a spatial `wrt` contributes an axis here.
        if expr.dim !== nothing
            d = Symbol(expr.dim)
            (d in dims) || push!(dims, d)
        end
        if expr.op == "D" && expr.wrt !== nothing && expr.wrt != "t"
            d = Symbol(expr.wrt)
            (d in dims) || push!(dims, d)
        end
        for a in expr.args
            _collect_spatial_dims!(dims, a, seen)
        end
    end
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
state ODE into an `aggregate`. A per-component answer namespaced after the fact
would describe the document, not the system produced from it.
"""
function _classification_model(states::OrderedDict{String, ModelVariable},
                               params::OrderedDict{String, ModelVariable},
                               observeds::OrderedDict{String, ModelVariable},
                               equations::Vector{Equation})::Model
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
function _in_document_order(names::AbstractSet{String},
                            maps::OrderedDict{String, ModelVariable}...)
    out = OrderedDict{String, ModelVariable}()
    for m in maps
        for (name, var) in m
            (name in names && !haskey(out, name)) && (out[name] = var)
        end
    end
    return out
end

"""
    _extract_field_ics!(equations) -> Vector{Pair{String, ASTExpr}}

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
function _extract_field_ics!(equations::Vector{Equation})
    ics = Pair{String, ASTExpr}[]
    remaining = Equation[]
    for eq in equations
        lhs = eq.lhs
        target = (lhs isa OpExpr && lhs.op == "ic" && length(lhs.args) == 1 &&
                  lhs.args[1] isa VarExpr) ? (lhs.args[1]::VarExpr).name : nothing
        if target === nothing
            push!(remaining, eq)
        else
            push!(ics, target => eq.rhs)
        end
    end
    if length(remaining) != length(equations)
        empty!(equations)
        append!(equations, remaining)
    end
    return ics
end

"""
    _collect_loader_fields!(out, model, prefix, data_sources)

Append one [`LoaderField`](@ref) per data-fed parameter of `model` (and, by
recursion, of its subsystems), in the order the component declares them.

A parameter is data-fed when some `update` rule has `kind == "data"` and carries
a `from` binding (esm-spec §8.5). Its cadence follows the SOURCE, not its own
declaration (CONFORMANCE_SPEC §5.7.2): a source WITH a `temporal` block refreshes
per record (`"discrete"`), one without is read once (`"const"`). A parameter
naming a source the document does not declare is skipped — `data_source_undefined`
is the validator's finding, not flatten's.
"""
function _collect_loader_fields!(out::Vector{LoaderField}, model::Model,
                                 prefix::String, data_sources)
    for (var_name, var) in model.variables
        var.type == ParameterVariable || continue
        var.update === nothing && continue
        for rule in var.update
            (rule.kind == "data" && rule.from !== nothing && rule.source !== nothing) || continue
            src = data_sources === nothing ? nothing : get(data_sources, rule.source, nothing)
            src === nothing && continue
            push!(out, LoaderField("$(prefix).$(var_name)", prefix, rule.source,
                                   rule.from.file_variable,
                                   src.temporal === nothing ? "const" : "discrete";
                                   unit_conversion=rule.from.unit_conversion))
        end
    end
    for (sub_name, sub) in model.subsystems
        sub isa Model || continue
        _collect_loader_fields!(out, sub, "$(prefix).$(sub_name)", data_sources)
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
    view = _classification_model(flat.state_variables, flat.parameters,
                                 flat.observed_variables, flat.equations)
    has_spatial_derivative(view) && return "pde"
    has_time_derivative(view) || return "nonlinear"
    return "ode"
end

# ========================================
# Top-level flatten (§4.7.5)
# ========================================

"""
    _with_coupling(file::EsmFile, coupling::Vector{CouplingEntry}) -> EsmFile

Return a copy of `file` with its `coupling` vector replaced (every other field
shared by reference). Used to splice `coupling_import`-expanded edges into the
document the rest of `flatten` consumes.
"""
_with_coupling(file::EsmFile, coupling::Vector{CouplingEntry})::EsmFile =
    EsmFile(file.esm, file.metadata;
            models=file.models,
            reaction_systems=file.reaction_systems,
            data_sources=file.data_sources,
            coupling=coupling,
            domain=file.domain,
            enums=file.enums,
            function_tables=file.function_tables,
            index_sets=file.index_sets)

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
with site recording (the compile-once tier). Under `ESS_TEMPLATE_REF_DISABLE=1`
load already expanded, so no references reach `flatten` at all.
"""
function flatten(file::EsmFile; base_path::AbstractString=".",
                 load_ref=nothing)::FlattenedSystem
    # Step 0a: Expand `coupling_import` entries (esm-spec §10.10.3) into concrete
    # edges BEFORE any coupling-consuming step, so imported edges participate in
    # conflict detection, unit checks, the coupling-rule loop, and the pointwise
    # lift exactly as inline edges would. A file with no imports is unchanged.
    expanded = expand_coupling_imports(file; base_path=base_path, load_ref=load_ref)
    if expanded !== file.coupling
        file = _with_coupling(file, expanded)
    end

    # Step 0-: there must be something to flatten. A document whose only payload
    # is an `expression_templates` registry is a template LIBRARY, not a system:
    # its metaparameters bind per import edge, so instantiating it at its own
    # defaults would produce a system nobody asked for. Refusing keeps the
    # library/system distinction observable instead of returning an empty
    # `FlattenedSystem` a caller then has to notice is empty.
    _n_components = (file.models === nothing ? 0 : length(file.models)) +
                    (file.reaction_systems === nothing ? 0 : length(file.reaction_systems))
    _n_components == 0 && throw(ArgumentError(
        "nothing to flatten: '$(file.metadata.name)' declares no `models` and no " *
        "`reaction_systems`. A file carrying only `expression_templates` is a " *
        "template LIBRARY (esm-spec §9.7); import it from a document that " *
        "declares components rather than flattening it directly."))

    # Step 0: Pre-flight conflict detection. Spec §4.7.5 item E.
    conflicting = _find_conflicting_derivatives(file)
    if !isempty(conflicting)
        throw(ConflictingDerivativeError(conflicting))
    end

    # Step 0b: coupling preflight checks. v0.8.0 retired the interface /
    # cross-domain-coverage checks (a document has one shared domain and
    # cross-grid coupling is an ordinary regridding `transform`); the
    # variable-map unit check remains.
    _check_variable_map_units(file)

    states = OrderedDict{String, ModelVariable}()
    params = OrderedDict{String, ModelVariable}()
    observeds = OrderedDict{String, ModelVariable}()
    equations = Equation[]
    continuous_events = ContinuousEvent[]
    discrete_events = DiscreteEvent[]
    # esm-spec v0.8.0: index sets are a single document-scoped registry, seeded
    # directly from the top-level `index_sets` object (plain names, un-namespaced)
    # and shared by every collected component.
    index_sets = OrderedDict{String, IndexSet}(file.index_sets)
    source_systems = String[]
    loader_fields = LoaderField[]
    lifted_shapes = OrderedDict{String, Vector{Int}}()

    file_domain = file.domain

    # esm-spec §9.6.4 rule 7 / §10.7: the MERGED template registry (union of the
    # component registries, deep-equal dedup + deterministic collision rename),
    # with each body's free variable references COMPONENT-SCOPED first (see
    # `_scope_component_templates`) so a body spliced after flatten resolves the
    # same names the expand-at-load image does. Empty when no references survived
    # load. Computed HERE, ahead of collection, because the collision rename it
    # returns has to reach each component's reference sites while they are still
    # attributable to their owner — `_collect_model!` applies it in lockstep with
    # namespacing, which is the same per-component rewrite §10.7 describes.
    template_registry, template_rename =
        _merge_flat_registry(_scope_component_templates(file))

    # Step 1+2: Collect models.
    if file.models !== nothing
        for (name, model) in file.models
            push!(source_systems, name)
            _collect_model!(states, params, observeds, equations,
                            continuous_events, discrete_events,
                            model, name;
                            tpl_rename=get(template_rename, name, nothing))
            _collect_loader_fields!(loader_fields, model, name, file.data_sources)
        end
    end

    # Step 1+2: Lower reaction systems to ODEs and collect. Any rate-law expression-
    # template references are expanded eagerly against the reaction system's own
    # `expression_templates` block (captured on `EsmFile.component_templates` under
    # the `reaction_systems.<name>` key) — see `_collect_reaction_system!`.
    if file.reaction_systems !== nothing
        for (name, rsys) in file.reaction_systems
            push!(source_systems, name)
            rs_templates = file.component_templates === nothing ? nothing :
                get(file.component_templates, "reaction_systems.$(name)", nothing)
            _collect_reaction_system!(states, params, equations,
                                      rsys, name; templates=rs_templates)
        end
    end

    # Step 3: Apply coupling rules.
    coupling_rules_applied = String[]
    opaque_refs = String[]

    # Names a `variable_map` SUBSTITUTED in the visible equation ASTs
    # (`_substitute_variable_map!`; the expression-transform arm leaves `to`
    # references intact, so it is exempt). A surviving template-registry body
    # is NOT rewritten by that substitution — a body still referencing such a
    # name would expand at the build boundary into a stale (possibly deleted)
    # variable, silently diverging from the Expand-at-load image. Checked
    # loudly against the merged registry below.
    map_rewritten_names = Set{String}()

    for entry in file.coupling
        push!(coupling_rules_applied, describe_coupling_entry(entry))
        if entry isa CouplingOperatorCompose
            _apply_operator_compose!(equations, entry)
        elseif entry isa CouplingCouple
            _apply_couple!(equations, entry, opaque_refs)
        elseif entry isa CouplingVariableMap
            _apply_variable_map!(equations, params, entry;
                                 observeds=observeds)
            entry.transform isa ASTExpr || push!(map_rewritten_names, entry.to)
        elseif entry isa CouplingOperatorApply
            push!(opaque_refs, "operator_apply:$(entry.operator)")
        elseif entry isa CouplingCallback
            push!(opaque_refs, "callback:$(entry.callback_id)")
        elseif entry isa CouplingEvent
            push!(opaque_refs, "event:$(entry.event_type)")
        end
    end

    # (`template_registry` was computed before collection — see above — so its
    # collision rename could reach the per-component reference sites. It is
    # available here, ahead of the pointwise lift, so the lift's loop-variable
    # detection can peek through surviving references (analysis only), and is
    # carried on the FlattenedSystem below.)

    # Shadow-registry guard (the root cause behind the eager reaction-rate
    # expansion): `_apply_variable_map!` rewrote the VISIBLE equation ASTs, but
    # registry bodies are a shadow copy of authored source the substitution
    # never sees. Fail loudly at flatten time rather than let the build
    # boundary expand a stale name.
    _check_registry_coupling_rewrites(template_registry, map_rewritten_names)

    # Step 3b: Pointwise spatial lift (§10.5). operator_compose has merged each
    # reaction/model state ODE with the spatial operator's advection; array-ify
    # those merged equations (promote the species to the grid shape and wrap in an
    # `aggregate` over the grid) so the lifted reaction network runs pointwise.
    _apply_pointwise_lift!(equations, states, params, observeds, index_sets, file.coupling;
                           template_registry=(isempty(template_registry) ? nothing :
                                              template_registry),
                           lifted_shapes=lifted_shapes)

    # Step 4: Compute independent variables.
    ivs = _compute_independent_variables(equations)

    # Step 5: Assemble FlattenedSystem. v0.8.0: the document carries at most one
    # shared domain, used directly as the target.
    target_domain = file_domain

    # §4.7.5 step 4 (Ordering, normative): components in the order the FILE
    # declares them. This list was previously sorted "for determinism" — but
    # document order is equally deterministic and is the order the spec fixes,
    # and a sorted list silently disagrees with `parameters` / `state_variables`
    # about which component came first.
    metadata = FlattenMetadata(
        collect(source_systems),
        coupling_rules_applied;
        dimension_promotions_applied=NamedTuple[],
        opaque_coupling_refs=opaque_refs,
    )

    # File-scoped function tables (esm-spec §9.5) are keyed by globally-unique id
    # and referenced by `table_lookup` nodes — carry them through unchanged so the
    # flattened system can round-trip into a runnable EsmFile (`flattened_to_esm`).
    function_tables = file.function_tables === nothing ?
        OrderedDict{String, FunctionTable}() :
        OrderedDict{String, FunctionTable}(file.function_tables)

    # Step 6: the §6.3.1 SUBSET maps, every membership decision delegated to the
    # classification accessors (esm-spec §6.3.1 calls them "the ONLY sanctioned
    # way to ask these questions"), run over the FLATTENED form and re-ordered
    # into document order. No local `update.kind == "wiener"` test lives here.
    view = _classification_model(states, params, observeds, equations)
    algebraic_variables = _in_document_order(Set(algebraic_unknowns(view)),
                                             states, observeds)
    brownian = _in_document_order(Set(brownian_parameters(view)), params)
    discrete_params = _in_document_order(Set(discrete_parameters(view)), params)

    # Step 7: classify the deferred `ic` equations OUT of `equations` (§4.7.5
    # step 4, normative). Last, so every pass above saw the list it always did.
    field_ics = _extract_field_ics!(equations)

    return FlattenedSystem(
        ivs, states, params, observeds,
        equations, continuous_events, discrete_events,
        target_domain, metadata, index_sets, function_tables, template_registry,
        algebraic_variables, brownian, discrete_params,
        field_ics, loader_fields, lifted_shapes,
    )
end

"""
    flatten(model::Model; name::String="anonymous") -> FlattenedSystem

Convenience: wrap a single Model in a synthetic EsmFile (with a default system
name) and run the full flattener. This is the call path used by
`ModelingToolkit.System(::Model)` in the Julia extension (see gt-fpw).
"""
function flatten(model::Model; name::String="anonymous")::FlattenedSystem
    file = EsmFile(SCHEMA_VERSION, Metadata(name);
                   models=Dict{String, Model}(name => model))
    return flatten(file)
end

"""
    flatten(rsys::ReactionSystem; name::String="anonymous") -> FlattenedSystem

Convenience: wrap a ReactionSystem in a synthetic EsmFile and flatten.
"""
function flatten(rsys::ReactionSystem; name::String="anonymous")::FlattenedSystem
    file = EsmFile(SCHEMA_VERSION, Metadata(name);
                   reaction_systems=Dict{String, ReactionSystem}(name => rsys))
    return flatten(file)
end

# ========================================
# FlattenedSystem → runnable single-model ESM document
# ========================================

"""
    flattened_to_esm(flat::FlattenedSystem; name="Flattened", esm_version=SCHEMA_VERSION) -> Dict{String,Any}

Reconstitute a `FlattenedSystem` into a single-model native ESM **document**
(`Dict{String,Any}`) that can be run directly: `build_evaluator(doc)` for a 0-D /
array system, or `discretize(doc)` first when it carries a spatial PDE.

A native dict — not a typed `EsmFile` — is the target on purpose: the value-
invention front-door (RFC §6.1, geometry / derived index sets) and the
`discretize` entry both dispatch on `AbstractDict`, and only the raw document
carries the index-set / `table_lookup` vocabulary the typed IR doesn't surface.

The single model collects:
- all three variable partitions (states, parameters, observeds) — observeds keep
  their defining `expression`, which the geometry materializer reads directly;
- every flattened equation (state ODEs + the synthesized observed definitions),
  so the evaluator's own observed-equation synthesis is a no-op (it skips any
  observed already defined by an equation — no double definition);
- the document-scoped `index_sets` registry (esm-spec v0.8.0), emitted at the
  top level so the regridders' `ranges.from` / `from_faq` / producer `id`
  references resolve;
- the file-scoped `function_tables` (the fuel `table_lookup` data).

This is the monolithic path the staged camp-fire run previously could not take,
because a lossy `flatten` dropped the geometry `manifold` / `table` data and the
index-set registry. With those preserved (canonical `reconstruct` + the registry
fields on `FlattenedSystem`), the whole flattened document lowers in one shot.
"""
# esm-spec §9.6.4 rule 7 / §10.7: registry bodies are COMPONENT-SCOPED source —
# their free variable references resolve in the owning component's namespace,
# exactly as the expand-at-load image does (load-time expansion splices the body
# into the component's equations BEFORE flatten renames them). The flattened
# registry must therefore carry bodies whose free variables are renamed with the
# SAME (prefix, local-name) map `_collect_model!` applies to the component's
# equations — otherwise a body spliced at the BUILD boundary (the
# reference-preserving fast path, or `expand_flattened_refs`) references bare
# names the flat var_map no longer contains (an ESD grid parameter like
# `dphi_lat` was the motivating failure). Template formal params are EXCLUDED
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
    out = OrderedDict{String,Any}()
    for (compkey, block) in ct
        parts = split(String(compkey), "."; limit=2)
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
        newblock = OrderedDict{String,Any}()
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
            scoped = namespace_expr(expression_from_json(body_raw), cname,
                                    setdiff(local_names, pnames))
            nd = OrderedDict{String,Any}(string(k) => v for (k, v) in pairs(decl))
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
        isempty(hits) || throw(ExpressionTemplateError(
            ERROR_CODES.TEMPLATE_BODY_REFERENCES_COUPLING_REWRITTEN_VARIABLE,
            "expression template '$(String(tname))' body references " *
            "'$(join(hits, "', '"))', which a coupling variable_map rewrote in " *
            "the flattened equations; the registry body would expand to a stale " *
            "name at the build boundary. Bind the value through the template's " *
            "params, or expand the reference before coupling (esm-spec §9.6.4)."))
    end
    return nothing
end

function flattened_to_esm(flat::FlattenedSystem;
                          name::AbstractString="Flattened",
                          esm_version::AbstractString=SCHEMA_VERSION)::Dict{String,Any}
    sname = String(name)

    variables = Dict{String,Any}()
    # Order: states, parameters, observeds. A later partition never re-keys an
    # earlier one (flatten guarantees disjoint names), so merge is unambiguous.
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
    # `_fold_ic_equations` reads `ic` out of the document's `equations`, and
    # without this every field-IC'd state silently seeds to its bare `default`.
    equations = Any[serialize_equation(eq) for eq in flat.equations]
    for (state, rhs) in flat.field_ics
        push!(equations, serialize_equation(
            Equation(OpExpr("ic", ASTExpr[VarExpr(state)]), rhs)))
    end

    model = Dict{String,Any}(
        "variables" => variables,
        "equations" => equations,
    )
    # esm-spec §9.6.4 Option B: surviving `apply_expression_template` references
    # in the equations resolve against the merged registry — emit it as the
    # model's `expression_templates` block so the reconstituted document is
    # self-contained (the tree-walk front-door re-parses it into
    # `EsmFile.component_templates` and the impl entry expands with site
    # recording). Absent for every reference-free system.
    if !isempty(flat.template_registry)
        model["expression_templates"] =
            OrderedDict{String,Any}(String(k) => v for (k, v) in flat.template_registry)
    end

    doc = Dict{String,Any}(
        "esm" => String(esm_version),
        "metadata" => Dict{String,Any}("name" => sname),
        "models" => Dict{String,Any}(sname => model),
    )
    # esm-spec v0.8.0: the index-set registry is document-scoped — emit it as a
    # sibling of `models` so the reconstituted document validates and both the
    # typed (`coerce_esm_file`) and value-invention front-doors resolve it.
    if !isempty(flat.index_sets)
        doc["index_sets"] = Dict{String,Any}(
            k => serialize_index_set(v) for (k, v) in flat.index_sets)
    end
    if !isempty(flat.function_tables)
        doc["function_tables"] = Dict{String,Any}(
            k => serialize_function_table(v) for (k, v) in flat.function_tables)
    end
    if flat.domain !== nothing
        # v0.8.0: single top-level `domain` object shared by the document; a
        # model is spatial via its variable shapes, not a `domain` reference.
        doc["domain"] = serialize_domain(flat.domain)
    end
    return doc
end
