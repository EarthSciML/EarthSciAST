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
    spatial_dims_in_expr(expr) -> Set{Symbol}

Collect every spatial-axis name referenced in `expr`, resolved STRUCTURALLY by
field (esm-spec §4.9.1(ii)): the value of a `dim` field on ANY Expression node
(a user rewrite-target op's `dim` names an axis exactly as `grad`'s does), plus
a spatial `wrt` (a `wrt` naming an axis other than the independent variable) on
a `D` node. No op name is privileged.
"""
function spatial_dims_in_expr(expr::ASTExpr)::Set{Symbol}
    dims = Set{Symbol}()
    _collect_spatial_dims!(dims, expr, IdDict{OpExpr,Nothing}())
    return dims
end

# `seen` visits each unique node once: a structurally-shared expression DAG
# (template expansion) hangs the same subtree under exponentially many paths,
# and this is a pure query of the node.
function _collect_spatial_dims!(dims::Set{Symbol}, expr::ASTExpr,
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
            push!(dims, Symbol(expr.dim))
        end
        if expr.op == "D" && expr.wrt !== nothing && expr.wrt != "t"
            push!(dims, Symbol(expr.wrt))
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

    # Top-level data-loader names — used to recognize a `param_to_var` whose
    # producer is a LOADED field, so a grid-shaped binding keeps its shape.
    loader_names = file.data_loaders === nothing ? Set{String}() :
                   Set{String}(String(k) for k in keys(file.data_loaders))

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
                                 loader_names=loader_names, observeds=observeds)
            entry.transform isa ASTExpr || push!(map_rewritten_names, entry.to)
        elseif entry isa CouplingOperatorApply
            push!(opaque_refs, "operator_apply:$(entry.operator)")
        elseif entry isa CouplingCallback
            push!(opaque_refs, "callback:$(entry.callback_id)")
        elseif entry isa CouplingEvent
            push!(opaque_refs, "event:$(entry.event_type)")
        end
    end

    # esm-spec §9.6.4 rule 7 / §10.7: the MERGED template registry (union of the
    # component registries, deep-equal dedup + deterministic collision rename),
    # with each body's free variable references COMPONENT-SCOPED first (see
    # `_scope_component_templates`) so a body spliced after flatten resolves the
    # same names the expand-at-load image does. Computed BEFORE the pointwise
    # lift so the lift's loop-variable detection can peek through surviving
    # references (analysis only); carried on the FlattenedSystem below. Empty
    # when no references survived load.
    template_registry = _merge_flat_registry(_scope_component_templates(file))

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
                                              template_registry))

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
    out = Dict{String,Any}()
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
        newblock = Dict{String,Any}()
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
            scoped = namespace_expr(parse_expression(body_raw), cname,
                                    setdiff(local_names, pnames))
            nd = Dict{String,Any}(string(k) => v for (k, v) in pairs(decl))
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
        foreach_subexpr(parse_expression(body_raw)) do x
            x isa VarExpr && push!(names, x.name)
            nothing
        end
        hits = sort!(collect(intersect(setdiff(names, pnames), rewritten)))
        isempty(hits) || throw(ExpressionTemplateError(
            "template_body_references_coupling_rewritten_variable",
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
    # esm-spec §9.6.4 Option B: surviving `apply_expression_template` references
    # in the equations resolve against the merged registry — emit it as the
    # model's `expression_templates` block so the reconstituted document is
    # self-contained (the tree-walk front-door re-parses it into
    # `EsmFile.component_templates` and the impl entry expands with site
    # recording). Absent for every reference-free system.
    if !isempty(flat.template_registry)
        model["expression_templates"] =
            Dict{String,Any}(String(k) => v for (k, v) in flat.template_registry)
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
