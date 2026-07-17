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
    function_tables::Dict{String, FunctionTable}
    # esm-spec §9.6.4 rule 7 / §10.7 / esm-libraries-spec §4.7.5 step 4 (Option B):
    # the MERGED template registry — the union of the component registries
    # (deep-equal dedup, deterministic `<ComponentPath>.<name>` collision rename).
    # Downstream consumers resolve surviving `apply_expression_template`
    # references against it (or `Expand` them; §9.6.4 rule 2). Empty when no
    # references survived (or `ESS_TEMPLATE_REF_DISABLE=1`).
    template_registry::Dict{String, Any}
end

# Backward-compatible constructors: callers that predate the index-set /
# function-table / template registries (e.g. hand-built MTK PDESystem fixtures)
# get empty registries. The full flattener always passes all fields.
FlattenedSystem(ivs, sv, p, obs, eqs, cev, dev, dom, meta) =
    FlattenedSystem(ivs, sv, p, obs, eqs, cev, dev, dom, meta,
                    OrderedDict{String, IndexSet}(), Dict{String, FunctionTable}(),
                    Dict{String, Any}())
FlattenedSystem(ivs, sv, p, obs, eqs, cev, dev, dom, meta, isets, ftabs) =
    FlattenedSystem(ivs, sv, p, obs, eqs, cev, dev, dom, meta, isets, ftabs,
                    Dict{String, Any}())

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
        template_registry = flat.template_registry) =
    FlattenedSystem(independent_variables, state_variables, parameters,
                    observed_variables, equations, continuous_events,
                    discrete_events, domain, metadata, index_sets,
                    function_tables, template_registry)

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
# Spatial-operator detection
# ========================================

# Op-class memberships used by the flatten pipeline's spatial detection,
# derived from the registry flags (src/op_registry.jl); memberships are
# pinned literal-for-literal by test/op_registry_test.jl.
#
# All spatial differential operators (plus `D` with a spatial `wrt`, which is
# checked separately since it depends on the `wrt` value).
const _SPATIAL_OPS = _ops_with(:spatial)
# The spatial operators that carry an explicit `dim` field (`laplacian` does
# not — it implies the domain's full spatial axes).
const _DIM_SPATIAL_OPS = _ops_with(:dim_spatial)

"""
    has_spatial_operator(expr) -> Bool

True if the expression contains any spatial operator (`grad`, `div`,
`laplacian`, or `D` with `wrt != "t"`).
"""
function has_spatial_operator(expr::ASTExpr)::Bool
    return _has_spatial_operator(expr, IdDict{OpExpr,Nothing}())
end

# `seen` visits each unique node once: a structurally-shared expression DAG
# (template expansion) hangs the same subtree under exponentially many paths,
# and this is a pure query of the node.
function _has_spatial_operator(expr::ASTExpr, seen::IdDict{OpExpr,Nothing})::Bool
    if expr isa NumExpr || expr isa IntExpr || expr isa VarExpr
        return false
    end
    if expr isa OpExpr
        haskey(seen, expr) && return false
        seen[expr] = nothing
        if expr.op in _SPATIAL_OPS
            return true
        end
        if expr.op == "D" && expr.wrt !== nothing && expr.wrt != "t"
            return true
        end
        for a in expr.args
            _has_spatial_operator(a, seen) && return true
        end
    end
    return false
end

"""
    spatial_dims_in_expr(expr) -> Set{Symbol}

Collect all spatial dimension names referenced by spatial operators in `expr`.
"""
function spatial_dims_in_expr(expr::ASTExpr)::Set{Symbol}
    dims = Set{Symbol}()
    _collect_spatial_dims!(dims, expr, IdDict{OpExpr,Nothing}())
    return dims
end

# `seen` visits each unique node once — see `_has_spatial_operator`.
function _collect_spatial_dims!(dims::Set{Symbol}, expr::ASTExpr,
                                seen::IdDict{OpExpr,Nothing})
    if expr isa OpExpr
        haskey(seen, expr) && return
        seen[expr] = nothing
        if expr.op in _DIM_SPATIAL_OPS && expr.dim !== nothing
            push!(dims, Symbol(expr.dim))
        elseif expr.op == "D" && expr.wrt !== nothing && expr.wrt != "t"
            push!(dims, Symbol(expr.wrt))
        elseif expr.op == "laplacian"
            # laplacian doesn't carry dim; caller assumes domain's full spatial
            # axes. We'll fill that in from the domain spec below.
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
            data_loaders=file.data_loaders,
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
"""
function flatten(file::EsmFile; base_path::AbstractString=".",
                 load_ref=nothing, expand_refs::Bool=true)::FlattenedSystem
    # esm-spec §9.6.4 Option B: when `apply_expression_template` references
    # survived load (`file.component_templates !== nothing`):
    #   * `expand_refs=true` (default) — Expand a COPY before flattening, so the
    #     equations are the Option-A image (MTK and every general caller build the
    #     expanded form). The caller's reference-preserving `EsmFile` is untouched,
    #     so `serialize_esm_file` still emits it verbatim (R1 / §9.6.4 rule 5).
    #   * `expand_refs=false` — CARRY the references into the FlattenedSystem
    #     (namespacing now scopes their `bindings`); the tree-walk build entry
    #     handles them via a sound per-node `Expand` fallback against the merged
    #     `template_registry`. This is the fast-path flatten used by `simulate`
    #     when `ESS_TEMPLATE_REF_DISABLE` is unset.
    # Under `ESS_TEMPLATE_REF_DISABLE=1` load already expanded, so
    # `component_templates` is `nothing` and this is a no-op either way.
    if expand_refs && file.component_templates !== nothing
        file = _expand_refs!(deepcopy(file))
    end

    # Step 0a: Expand `coupling_import` entries (esm-spec §10.10.3) into concrete
    # edges BEFORE any coupling-consuming step, so imported edges participate in
    # conflict detection, unit checks, the coupling-rule loop, and the pointwise
    # lift exactly as inline edges would. A file with no imports is unchanged.
    expanded = expand_coupling_imports(file; base_path=base_path, load_ref=load_ref)
    if expanded !== file.coupling
        file = _with_coupling(file, expanded)
    end

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

    file_domain = file.domain

    # Step 1+2: Collect models.
    if file.models !== nothing
        for (name, model) in file.models
            push!(source_systems, name)
            _collect_model!(states, params, observeds, equations,
                            continuous_events, discrete_events,
                            model, name)
        end
    end

    # Step 1+2: Lower reaction systems to ODEs and collect.
    if file.reaction_systems !== nothing
        for (name, rsys) in file.reaction_systems
            push!(source_systems, name)
            _collect_reaction_system!(states, params, equations,
                                      rsys, name)
        end
    end

    # Step 3: Apply coupling rules.
    coupling_rules_applied = String[]
    opaque_refs = String[]

    # Top-level data-loader names — used to recognize a `param_to_var` whose
    # producer is a LOADED field, so a grid-shaped binding keeps its shape.
    loader_names = file.data_loaders === nothing ? Set{String}() :
                   Set{String}(String(k) for k in keys(file.data_loaders))

    for entry in file.coupling
        push!(coupling_rules_applied, describe_coupling_entry(entry))
        if entry isa CouplingOperatorCompose
            _apply_operator_compose!(equations, entry)
        elseif entry isa CouplingCouple
            _apply_couple!(equations, entry, opaque_refs)
        elseif entry isa CouplingVariableMap
            _apply_variable_map!(equations, params, entry;
                                 loader_names=loader_names, observeds=observeds)
        elseif entry isa CouplingOperatorApply
            push!(opaque_refs, "operator_apply:$(entry.operator)")
        elseif entry isa CouplingCallback
            push!(opaque_refs, "callback:$(entry.callback_id)")
        elseif entry isa CouplingEvent
            push!(opaque_refs, "event:$(entry.event_type)")
        end
    end

    # Step 3b: Pointwise spatial lift (§10.5). operator_compose has merged each
    # reaction/model state ODE with the spatial operator's advection; array-ify
    # those merged equations (promote the species to the grid shape and wrap in an
    # `aggregate` over the grid) so the lifted reaction network runs pointwise.
    _apply_pointwise_lift!(equations, states, params, observeds, index_sets, file.coupling)

    # Step 4: Compute independent variables.
    ivs = _compute_independent_variables(equations)

    # Step 5: Assemble FlattenedSystem. v0.8.0: the document carries at most one
    # shared domain, used directly as the target.
    target_domain = file_domain

    metadata = FlattenMetadata(
        sort!(collect(source_systems)),
        coupling_rules_applied;
        dimension_promotions_applied=NamedTuple[],
        opaque_coupling_refs=opaque_refs,
    )

    # File-scoped function tables (esm-spec §9.5) are keyed by globally-unique id
    # and referenced by `table_lookup` nodes — carry them through unchanged so the
    # flattened system can round-trip into a runnable EsmFile (`flattened_to_esm`).
    function_tables = file.function_tables === nothing ?
        Dict{String, FunctionTable}() : copy(file.function_tables)

    # esm-spec §9.6.4 rule 7 / §10.7: the flattened representation carries the
    # MERGED template registry (union of the component registries, deep-equal
    # dedup + deterministic `<ComponentPath>.<name>` collision rename). Empty when
    # no references survived load (`file.component_templates === nothing`).
    template_registry = _merge_flat_registry(file.component_templates)

    return FlattenedSystem(
        ivs, states, params, observeds,
        equations, continuous_events, discrete_events,
        target_domain, metadata, index_sets, function_tables, template_registry,
    )
end

"""
    flatten(model::Model; name::String="anonymous") -> FlattenedSystem

Convenience: wrap a single Model in a synthetic EsmFile (with a default system
name) and run the full flattener. This is the call path used by
`ModelingToolkit.System(::Model)` in the Julia extension (see gt-fpw).
"""
function flatten(model::Model; name::String="anonymous")::FlattenedSystem
    file = EsmFile(ESM_FORMAT_VERSION, Metadata(name);
                   models=Dict{String, Model}(name => model))
    return flatten(file)
end

"""
    flatten(rsys::ReactionSystem; name::String="anonymous") -> FlattenedSystem

Convenience: wrap a ReactionSystem in a synthetic EsmFile and flatten.
"""
function flatten(rsys::ReactionSystem; name::String="anonymous")::FlattenedSystem
    file = EsmFile(ESM_FORMAT_VERSION, Metadata(name);
                   reaction_systems=Dict{String, ReactionSystem}(name => rsys))
    return flatten(file)
end

# ========================================
# FlattenedSystem → runnable single-model ESM document
# ========================================

"""
    flattened_to_esm(flat::FlattenedSystem; name="Flattened", esm_version=ESM_FORMAT_VERSION) -> Dict{String,Any}

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
function flattened_to_esm(flat::FlattenedSystem;
                          name::AbstractString="Flattened",
                          esm_version::AbstractString=ESM_FORMAT_VERSION)::Dict{String,Any}
    sname = String(name)

    variables = Dict{String,Any}()
    # Order: states, parameters, observeds. A later partition never re-keys an
    # earlier one (flatten guarantees disjoint names), so merge is unambiguous.
    for partition in (flat.state_variables, flat.parameters, flat.observed_variables)
        for (k, v) in partition
            variables[k] = serialize_model_variable(v)
        end
    end

    model = Dict{String,Any}(
        "variables" => variables,
        "equations" => Any[serialize_equation(eq) for eq in flat.equations],
    )

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
