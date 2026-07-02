"""
Coupled System Flattening for ESM Format.

Implements spec §4.7.5 (flattening algorithm) and §4.7.6 (dimension promotion).

`flatten(::EsmFile)` produces a `FlattenedSystem`: a single flat equation system
with dot-namespaced variables and real Expr-tree equations. Reactions are lowered
to ODEs via `lower_reactions_to_equations`; coupling rules merge RHS terms;
`variable_map` substitutes parameters; `operator_apply`/`callback` are recorded
opaquely in metadata.
"""

using OrderedCollections: OrderedDict

# ========================================
# Error Types (§4.7.5 / §4.7.6 taxonomy)
# ========================================

"""
    ConflictingDerivativeError

Raised when a species appears both as the left-hand side of an explicit
differential equation (`D(X, t) = ...`) and as a substrate or product of any
reaction in the same flattened file. Such a system is over-determined: the
reaction contribution to `d[X]/dt` would silently shadow the user's equation.

Fields:
- `species::Vector{String}`: fully-qualified (dot-namespaced) names of every
  offending species.
"""
struct ConflictingDerivativeError <: Exception
    species::Vector{String}
end

function Base.showerror(io::IO, e::ConflictingDerivativeError)
    names = join(e.species, ", ")
    print(io, "ConflictingDerivativeError: species have both an explicit ",
          "derivative equation and a reaction contribution: ", names)
end

"""
    DimensionPromotionError

Raised during flatten when a variable or equation cannot be promoted from
its source domain to the target domain given the available `Interface` rules
(§4.7.6).
"""
struct DimensionPromotionError <: Exception
    details::String
end
Base.showerror(io::IO, e::DimensionPromotionError) =
    print(io, "DimensionPromotionError: ", e.details)

"""
    UnmappedDomainError

Raised when two systems on different domains are coupled without an `Interface`
that defines their dimension mapping (§4.7.6).
"""
struct UnmappedDomainError <: Exception
    source::String
    target::String
end
Base.showerror(io::IO, e::UnmappedDomainError) =
    print(io, "UnmappedDomainError: no Interface maps domain '", e.source,
          "' to domain '", e.target, "'")

"""
    UnsupportedMappingError

Raised when an `Interface` requests a `dimension_mapping` type or regridding
strategy that is not supported by the current library tier (§4.7.6). The
`mapping_type` field carries the offending type or strategy name (e.g.
`"slice"`, `"project"`, `"regrid"`, or a specific regridding method like
`"cubic_spline"`). Matches the Rust `FlattenError::UnsupportedMapping` variant
and the Python `UnsupportedMappingError` exception for cross-language
error-name parity.
"""
struct UnsupportedMappingError <: Exception
    mapping_type::String
end
Base.showerror(io::IO, e::UnsupportedMappingError) =
    print(io, "UnsupportedMappingError: mapping type '",
          e.mapping_type, "' is not supported by this library tier")

"""
    DomainUnitMismatchError

Raised when coupling across an `Interface` requires a unit conversion that
was not declared by the user (§4.7.6).
"""
struct DomainUnitMismatchError <: Exception
    variable::String
    source_units::String
    target_units::String
end
Base.showerror(io::IO, e::DomainUnitMismatchError) =
    print(io, "DomainUnitMismatchError: variable '", e.variable,
          "' has units '", e.source_units, "' on source and '",
          e.target_units, "' on target")

"""
    DomainExtentMismatchError

Defined for cross-language error-name parity with the Rust `FlattenError`
taxonomy and the Python `flatten()` exception set. Would be raised when an
`identity` mapping bridges two domains whose spatial extents on a shared
independent variable disagree. The Julia flatten pipeline does not currently
perform this check, so this type is reserved and never raised by the current
implementation — it exists so consumers can catch it by name.
"""
struct DomainExtentMismatchError <: Exception
    variable::String
end
Base.showerror(io::IO, e::DomainExtentMismatchError) =
    print(io, "DomainExtentMismatchError: domain extent mismatch on ",
          "independent variable '", e.variable, "' under identity mapping")

"""
    SliceOutOfDomainError

Defined for cross-language error-name parity; only raised if `slice` is ever
implemented at a higher tier in the Julia flatten pipeline. Would be raised
when a `slice` mapping's fixed coordinate lies outside the source variable's
declared domain extent.
"""
struct SliceOutOfDomainError <: Exception
    coordinate::String
    value::String
end
Base.showerror(io::IO, e::SliceOutOfDomainError) =
    print(io, "SliceOutOfDomainError: slice coordinate '", e.coordinate,
          "' = ", e.value, " lies outside the source domain extent")

"""
    CyclicPromotionError

Defined for cross-language error-name parity. Not raised by Core-tier Julia
because no promotion graph is built — reserved for a future tier upgrade that
does promotion-graph analysis. Would signal that the declared `Interface`
rules form a cycle (A promotes to B, B promotes back to A on a different
axis).
"""
struct CyclicPromotionError <: Exception
    variables::Vector{String}
end
Base.showerror(io::IO, e::CyclicPromotionError) =
    print(io, "CyclicPromotionError: cyclic promotion detected involving ",
          "variables ", e.variables)

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
`Equation` objects whose Expr trees reference namespaced names via `VarExpr`.
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
end

# Backward-compatible 9-arg constructor: callers that predate the index-set /
# function-table registry (e.g. hand-built MTK PDESystem fixtures) get empty
# registries. The full flattener always passes all 11.
FlattenedSystem(ivs, sv, p, obs, eqs, cev, dev, dom, meta) =
    FlattenedSystem(ivs, sv, p, obs, eqs, cev, dev, dom, meta,
                    OrderedDict{String, IndexSet}(), Dict{String, FunctionTable}())

# ========================================
# Reaction Lowering Helper (§4.6 + §4.7.6)
# ========================================

"""
    lower_reactions_to_equations(reactions, species, domain=nothing) -> Vector{Equation}

Produce the ODE equations induced by a set of reactions using standard
mass-action kinetics: `d[X]/dt = Σ (stoich_ij * rate_j)`.

Shared by `derive_odes` (reaction → Model) and `flatten` (EsmFile → FlattenedSystem)
so there is exactly one place that turns stoichiometry into equations.

On a 0D domain (`domain === nothing`), the LHS is `D(X, t)`. On a PDE domain,
the LHS is still `D(X, t)` symbolically — dimension promotion (§4.7.6) is
applied by `flatten`, not here. The resulting equation lives on the caller's
domain; spatial operators are added downstream when coupling adds them.
"""
function lower_reactions_to_equations(reactions::Vector{Reaction},
                                      species::Vector{Species},
                                      domain::Union{Domain, Nothing}=nothing)::Vector{Equation}
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
        substrates = getfield(rxn, :substrates)
        if substrates !== nothing
            for entry in substrates
                if haskey(species_idx, entry.species)
                    S[species_idx[entry.species], j] -= entry.stoichiometry
                end
            end
        end
        products = getfield(rxn, :products)
        if products !== nothing
            for entry in products
                if haskey(species_idx, entry.species)
                    S[species_idx[entry.species], j] += entry.stoichiometry
                end
            end
        end
    end

    for (i, name) in enumerate(species_names)
        lhs = OpExpr("D", EarthSciSerialization.Expr[VarExpr(name)], wrt="t")
        terms = EarthSciSerialization.Expr[]
        for (j, rxn) in enumerate(reactions)
            stoich = S[i, j]
            stoich == 0 && continue
            rate_expr = mass_action_rate(rxn, species)
            if stoich == 1
                push!(terms, rate_expr)
            elseif stoich == -1
                push!(terms, OpExpr("-", EarthSciSerialization.Expr[rate_expr]))
            else
                push!(terms, OpExpr("*",
                    EarthSciSerialization.Expr[NumExpr(Float64(stoich)), rate_expr]))
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
                        idx_names::Set{String}=Set{String}())::EarthSciSerialization.Expr
    return expr
end

function namespace_expr(expr::IntExpr, prefix::String, local_names::Set{String},
                        idx_names::Set{String}=Set{String}())::EarthSciSerialization.Expr
    return expr
end

function namespace_expr(expr::VarExpr, prefix::String, local_names::Set{String},
                        idx_names::Set{String}=Set{String}())::EarthSciSerialization.Expr
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
            out[k] = Any[x isa EarthSciSerialization.Expr ?
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
                        idx_names::Set{String}=Set{String}())::EarthSciSerialization.Expr
    ns(x) = x === nothing ? nothing : namespace_expr(x, prefix, local_names, idx_names)
    new_args = EarthSciSerialization.Expr[namespace_expr(a, prefix, local_names, idx_names) for a in expr.args]
    # Recurse into EVERY variable-bearing sub-expression so prefix rewrites reach
    # arrayop / makearray bodies, filter predicates (M2 §7.2), integral bounds
    # (`lower`/`upper`), and table_lookup per-axis input expressions. `reconstruct`
    # preserves all other fields (semiring, output_idx, table, output, int_var,
    # join/join_gates, manifold, …) — earlier this rebuild hand-listed keywords
    # and silently dropped int_var/lower/upper/table/table_axes/output. `join`/
    # `join_gates` carry only index-symbol / position data, so they pass through.
    new_values = expr.values === nothing ? nothing :
        EarthSciSerialization.Expr[namespace_expr(v, prefix, local_names, idx_names) for v in expr.values]
    new_table_axes = expr.table_axes === nothing ? nothing :
        Dict{String,EarthSciSerialization.Expr}(
            k => namespace_expr(v, prefix, local_names, idx_names) for (k, v) in expr.table_axes)
    # Namespace index-set references so a flattened component's private
    # geometry/index names don't collide with a sibling's after merge: the `id`
    # naming a value-invention producer (matched by a derived set's `from_faq`)
    # and every `ranges[*]` `{from: <set>}` reference. Gated on `idx_names`, which
    # is empty for models that declare no index sets — so non-geometry models are
    # byte-identical to before.
    new_id = (expr.id !== nothing && expr.id in idx_names) ? "$(prefix).$(expr.id)" : expr.id
    new_ranges = _namespace_ranges(expr.ranges, prefix, local_names, idx_names)
    # A `join.on` key column may name a component-local variable (the regridder's
    # bin buffers), so namespace it alongside the other variable-bearing fields.
    new_join = _namespace_join(expr.join, prefix, local_names)
    return reconstruct(expr;
        args=new_args,
        expr_body=ns(expr.expr_body),
        filter=ns(expr.filter),
        lower=ns(expr.lower),
        upper=ns(expr.upper),
        values=new_values,
        table_axes=new_table_axes,
        id=new_id,
        ranges=new_ranges,
        join=new_join,
        key=ns(expr.key))
end

"""
    lhs_dependent_variable(expr) -> Union{String, Nothing}

Extract the dependent variable name from an equation LHS. For `D(x, t)`, returns
`"x"`. For a bare `VarExpr("x")`, returns `"x"`. Otherwise returns `nothing`.
"""
function lhs_dependent_variable(expr::EarthSciSerialization.Expr)::Union{String, Nothing}
    if expr isa VarExpr
        return expr.name
    elseif expr isa OpExpr && expr.op == "D" && !isempty(expr.args) && expr.args[1] isa VarExpr
        return (expr.args[1]::VarExpr).name
    end
    return nothing
end

"""
    has_spatial_operator(expr) -> Bool

True if the expression contains any spatial operator (`grad`, `div`,
`laplacian`, or `D` with `wrt != "t"`).
"""
function has_spatial_operator(expr::EarthSciSerialization.Expr)::Bool
    if expr isa NumExpr || expr isa IntExpr || expr isa VarExpr
        return false
    end
    if expr isa OpExpr
        if expr.op in ("grad", "div", "laplacian")
            return true
        end
        if expr.op == "D" && expr.wrt !== nothing && expr.wrt != "t"
            return true
        end
        for a in expr.args
            has_spatial_operator(a) && return true
        end
    end
    return false
end

"""
    spatial_dims_in_expr(expr) -> Set{Symbol}

Collect all spatial dimension names referenced by spatial operators in `expr`.
"""
function spatial_dims_in_expr(expr::EarthSciSerialization.Expr)::Set{Symbol}
    dims = Set{Symbol}()
    _collect_spatial_dims!(dims, expr)
    return dims
end

function _collect_spatial_dims!(dims::Set{Symbol}, expr::EarthSciSerialization.Expr)
    if expr isa OpExpr
        if expr.op in ("grad", "div") && expr.dim !== nothing
            push!(dims, Symbol(expr.dim))
        elseif expr.op == "D" && expr.wrt !== nothing && expr.wrt != "t"
            push!(dims, Symbol(expr.wrt))
        elseif expr.op == "laplacian"
            # laplacian doesn't carry dim; caller assumes domain's full spatial
            # axes. We'll fill that in from the domain spec below.
        end
        for a in expr.args
            _collect_spatial_dims!(dims, a)
        end
    end
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
    return ModelVariable(var.type; default=var.default, units=var.units,
        default_units=var.default_units, description=var.description,
        expression=var.expression, shape=new_shape, location=var.location,
        noise_kind=var.noise_kind, correlation_group=var.correlation_group)
end

# ========================================
# Per-system collection
# ========================================

"""
Collect a Model's variables and equations into the flattener accumulators,
recursing through subsystems. All names are rewritten to `prefix.local_name`.
Index sets (RFC §5.2) are document-scoped as of esm-spec v0.8.0 — a single shared
registry seeded once by `flatten` into `index_sets_acc` — so their references
inside equations (`shape`, `ranges` `from`, producer `id` / `from_faq`) keep
their plain document-level names and are NOT namespaced here.
"""
function _collect_model!(states::OrderedDict{String, ModelVariable},
                         params::OrderedDict{String, ModelVariable},
                         observeds::OrderedDict{String, ModelVariable},
                         equations::Vector{Equation},
                         continuous_events::Vector{ContinuousEvent},
                         discrete_events::Vector{DiscreteEvent},
                         model::Model, prefix::String,
                         index_sets_acc::OrderedDict{String, IndexSet}=
                             OrderedDict{String, IndexSet}())
    local_names = Set{String}(keys(model.variables))
    # Also include subsystem-qualified names from this level's subsystems so
    # that references inside the model to subsystem variables get namespaced.
    for (sub_name, _) in model.subsystems
        push!(local_names, sub_name)
    end

    # esm-spec v0.8.0: index sets are a single document-scoped registry (seeded
    # into `index_sets_acc` once, in `flatten`) with plain names shared by every
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
            v = ModelVariable(v.type; default=v.default, units=v.units,
                default_units=v.default_units, description=v.description,
                expression=namespace_expr(v.expression, prefix, local_names, idx_names),
                shape=v.shape, location=v.location,
                noise_kind=v.noise_kind, correlation_group=v.correlation_group)
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
        new_conds = EarthSciSerialization.Expr[namespace_expr(c, prefix, local_names, idx_names) for c in ev.conditions]
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
              DiscreteEvent(new_trigger, new_affects; description=ev.description))
    end

    for (sub_name, sub_model) in model.subsystems
        # A DataLoader subsystem (RFC pure-io-data-loaders §4.3) exposes its
        # variables to the owning model's equations; lowering that consumption
        # (reprojection / regridding) is a downstream model concern, not part of
        # plain flattening. Skip non-Model subsystems here.
        sub_model isa Model || continue
        _collect_model!(states, params, observeds, equations,
                        continuous_events, discrete_events,
                        sub_model, "$(prefix).$(sub_name)", index_sets_acc)
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
                                   rsys::ReactionSystem, prefix::String,
                                   file_domain::Union{Domain, Nothing})
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
    raw_eqs = lower_reactions_to_equations(rsys.reactions, rsys.species, file_domain)
    for eq in raw_eqs
        lhs = namespace_expr(eq.lhs, prefix, local_names)
        rhs = namespace_expr(eq.rhs, prefix, local_names)
        push!(equations, Equation(lhs, rhs; _comment=eq._comment))
    end

    for (sub_name, sub_rsys) in rsys.subsystems
        _collect_reaction_system!(states, params, equations,
                                  sub_rsys, "$(prefix).$(sub_name)", file_domain)
    end
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
        if eq.lhs isa OpExpr && eq.lhs.op == "D" && !isempty(eq.lhs.args) &&
           eq.lhs.args[1] isa VarExpr
            raw = (eq.lhs.args[1]::VarExpr).name
            # A bare name refers to a variable in this model's scope.
            push!(acc, occursin('.', raw) ? raw : "$(prefix).$(raw)")
        end
    end
    for (sub_name, sub) in model.subsystems
        # Only Model subsystems contribute explicit-derivative LHS names.
        sub isa Model || continue
        _collect_explicit_derivative_lhs!(acc, sub, "$(prefix).$(sub_name)")
    end
end

function _collect_reaction_species!(acc::Set{String}, rsys::ReactionSystem, prefix::String)
    for rxn in rsys.reactions
        substrates = getfield(rxn, :substrates)
        if substrates !== nothing
            for entry in substrates
                push!(acc, "$(prefix).$(entry.species)")
            end
        end
        products = getfield(rxn, :products)
        if products !== nothing
            for entry in products
                push!(acc, "$(prefix).$(entry.species)")
            end
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
function _check_variable_map_units!(file::EsmFile)
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

"""
Apply a `CouplingOperatorCompose` entry: for each equation LHS dependent
variable (with `translate` and `_var` placeholder expansion), find matching
equations across the listed systems and sum their RHS terms. In the flattened
representation, "matching" means "has the same namespaced dependent variable".
"""
function _apply_operator_compose!(equations::Vector{Equation},
                                  entry::CouplingOperatorCompose,
                                  file::EsmFile)
    translate = entry.translate === nothing ? Dict{String, Any}() : entry.translate

    # Build placeholder targets: if any equation's LHS uses VarExpr("_var"),
    # that equation is a template to be expanded for every state variable
    # in the other systems referenced by this compose entry.
    placeholder_indices = Int[]
    normal_indices = Int[]
    for (i, eq) in enumerate(equations)
        dep = lhs_dependent_variable(eq.lhs)
        if dep !== nothing && (dep == "_var" || endswith(dep, "._var"))
            push!(placeholder_indices, i)
        else
            push!(normal_indices, i)
        end
    end

    # Expand placeholder equations into concrete ones, one per state variable
    # that belongs to any of the other systems in `entry.systems`.
    if !isempty(placeholder_indices)
        target_vars = _collect_target_state_vars(equations, normal_indices, entry.systems)
        new_equations = Equation[]
        delete_indices = Set{Int}()
        for i in placeholder_indices
            tmpl = equations[i]
            push!(delete_indices, i)
            placeholder_lhs_dep = lhs_dependent_variable(tmpl.lhs)
            for var in target_vars
                new_lhs = _substitute_placeholder(tmpl.lhs, placeholder_lhs_dep, var)
                new_rhs = _substitute_placeholder(tmpl.rhs, placeholder_lhs_dep, var)
                push!(new_equations, Equation(new_lhs, new_rhs; _comment=tmpl._comment))
            end
        end
        # Remove originals and append the expansions.
        kept = Equation[]
        for (i, eq) in enumerate(equations)
            if !(i in delete_indices)
                push!(kept, eq)
            end
        end
        append!(kept, new_equations)
        empty!(equations)
        append!(equations, kept)
    end

    # Now merge equations with identical dependent variables.
    by_dep = OrderedDict{String, Vector{Int}}()
    for (i, eq) in enumerate(equations)
        dep = lhs_dependent_variable(eq.lhs)
        dep === nothing && continue
        # Apply translation to land on a canonical name.
        canonical = get(translate, dep, dep)
        canonical = canonical isa String ? canonical : dep
        push!(get!(by_dep, canonical, Int[]), i)
    end

    merged = Equation[]
    merged_indices = Set{Int}()
    for (dep, indices) in by_dep
        if length(indices) < 2
            continue
        end
        # Sum all RHS terms into a single equation; keep the first equation's LHS.
        first_idx = indices[1]
        lhs = equations[first_idx].lhs
        terms = EarthSciSerialization.Expr[equations[i].rhs for i in indices]
        new_rhs = length(terms) == 1 ? terms[1] : OpExpr("+", terms)
        push!(merged, Equation(lhs, new_rhs))
        for i in indices
            push!(merged_indices, i)
        end
    end

    if isempty(merged)
        return
    end

    kept = Equation[]
    for (i, eq) in enumerate(equations)
        if !(i in merged_indices)
            push!(kept, eq)
        end
    end
    append!(kept, merged)
    empty!(equations)
    append!(equations, kept)
    return
end

function _collect_target_state_vars(equations::Vector{Equation},
                                    normal_indices::Vector{Int},
                                    system_names::Vector{String})::Vector{String}
    vars = String[]
    seen = Set{String}()
    for i in normal_indices
        dep = lhs_dependent_variable(equations[i].lhs)
        dep === nothing && continue
        parts = split(dep, ".")
        length(parts) >= 2 || continue
        root = String(parts[1])
        if root in system_names && !(dep in seen)
            push!(vars, dep)
            push!(seen, dep)
        end
    end
    return vars
end

function _substitute_placeholder(expr::EarthSciSerialization.Expr,
                                 placeholder::Union{String, Nothing},
                                 target::String)::EarthSciSerialization.Expr
    placeholder === nothing && return expr
    if expr isa NumExpr || expr isa IntExpr
        return expr
    elseif expr isa VarExpr
        if expr.name == "_var" || expr.name == placeholder ||
           endswith(expr.name, "._var")
            return VarExpr(target)
        end
        return expr
    elseif expr isa OpExpr
        new_args = EarthSciSerialization.Expr[_substitute_placeholder(a, placeholder, target) for a in expr.args]
        new_expr_body = expr.expr_body === nothing ? nothing :
            _substitute_placeholder(expr.expr_body, placeholder, target)
        new_values = expr.values === nothing ? nothing :
            EarthSciSerialization.Expr[_substitute_placeholder(v, placeholder, target) for v in expr.values]
        return OpExpr(expr.op, new_args;
            wrt=expr.wrt, dim=expr.dim,
            output_idx=expr.output_idx,
            expr_body=new_expr_body,
            reduce=expr.reduce,
            ranges=expr.ranges,
            regions=expr.regions,
            values=new_values,
            shape=expr.shape,
            perm=expr.perm,
            axis=expr.axis,
            fn=expr.fn)
    end
    return expr
end

"""
Apply a `CouplingCouple` entry: attach the connector equations to the
flattened equation list. The connector.equations field may contain full
equation structures; we accept both raw Equation objects and dict-shaped
connector entries.
"""
function _apply_couple!(equations::Vector{Equation},
                        entry::CouplingCouple,
                        file::EsmFile)
    connector = entry.connector
    if haskey(connector, "equations")
        raw = connector["equations"]
        if raw isa AbstractVector
            for item in raw
                if item isa Equation
                    push!(equations, item)
                elseif item isa AbstractDict
                    # If the connector equation is a dict-shaped entry (spec
                    # form) record it as a comment equation placeholder — we
                    # cannot parse expressions here without the full parser.
                    # The typical call path constructs full Equation objects.
                    push!(equations, _coerce_connector_equation(item))
                end
            end
        end
    end
    return
end

function _coerce_connector_equation(entry::AbstractDict)::Equation
    # Minimal coercion: accept already-parsed Expr fields if present; otherwise
    # emit a placeholder that carries the raw dict as a comment so downstream
    # code can still see it was applied.
    lhs = get(entry, "lhs", nothing)
    rhs = get(entry, "rhs", nothing)
    if lhs isa EarthSciSerialization.Expr && rhs isa EarthSciSerialization.Expr
        return Equation(lhs, rhs; _comment="couple")
    end
    return Equation(VarExpr("__coupling_placeholder__"), NumExpr(0.0);
                    _comment=string("couple: ", entry))
end

"""
Apply a `CouplingVariableMap` entry: substitute the `to` parameter/variable
with the `from` variable in every flattened equation. For `param_to_var` and
`conversion_factor`, also promote `to` out of the parameters map.

When `transform` is an `Expr` (esm-spec §10.4 expression transform), the target
parameter instead becomes an observed defined by the transform expression —
see the expression arm below.

`loader_names` is the set of top-level `data_loaders` keys. When a
`param_to_var` binds a **loaded** field (`from`'s owning system is a data
loader) onto a GRID-SHAPED consumer parameter (`to` carries a non-scalar
`shape`), the shape is transferred to the loader-qualified `from` name so the
downstream pointwise lift (§10.5) still recognizes it as an array-shaped operand
to index per grid cell. Without this, deleting the shaped `to` param would strip
the field's grid shape and the lift would leave a bare (scalar) reference to the
loader variable — e.g. `-Meteorology.u_wind * grad(...)` would not be lifted to
`-index(Meteorology.u_wind, i, j) * …`. (esm-spec §11.5 "BCs from data" +
§10.4 `param_to_var`.)
"""
# Does `expr` reference the variable `name` anywhere — including inside
# aggregate bodies, filter predicates, integral bounds, makearray values, and
# table-lookup axis inputs? (The traversal mirrors `substitute`'s field set;
# `Base.contains`-style helpers in expression.jl only walk `args`/`wrt`.)
_expr_references_variable(expr::NumExpr, name::String)::Bool = false
_expr_references_variable(expr::IntExpr, name::String)::Bool = false
_expr_references_variable(expr::VarExpr, name::String)::Bool = expr.name == name
function _expr_references_variable(expr::OpExpr, name::String)::Bool
    any(_expr_references_variable(a, name) for a in expr.args) && return true
    for sub in (expr.lower, expr.upper, expr.expr_body, expr.filter)
        sub !== nothing && _expr_references_variable(sub, name) && return true
    end
    if expr.values !== nothing
        any(_expr_references_variable(v, name) for v in expr.values) && return true
    end
    if expr.table_axes !== nothing
        any(_expr_references_variable(v, name) for (_, v) in expr.table_axes) && return true
    end
    return false
end

function _apply_variable_map!(equations::Vector{Equation},
                              params::OrderedDict{String, ModelVariable},
                              entry::CouplingVariableMap,
                              loader_names::Set{String}=Set{String}(),
                              observeds::Union{OrderedDict{String, ModelVariable},Nothing}=nothing)
    from = entry.from
    to = entry.to
    transform = entry.transform

    # Expression transform (esm-spec §10.4): the entry binds the target to a
    # DERIVED value. Remove the `to` parameter and introduce in its place an
    # observed variable — same name, units, shape, description — whose defining
    # expression is the transform, evaluated in the flattened coupled system's
    # scope. References to `to` in the equations are left intact: they now
    # resolve to the observed, exactly as if the author had declared it. Every
    # variable reference inside the transform is (by contract) a fully-scoped
    # reference, so no namespacing is applied; the expression MUST reference
    # the entry's `from` variable — it is the data-flow edge the entry declares.
    if transform isa EarthSciSerialization.Expr
        if !_expr_references_variable(transform, from)
            throw(ArgumentError(
                "variable_map($(from) -> $(to)): expression transform does not " *
                "reference the entry's 'from' variable '$(from)' (esm-spec §10.4)"))
        end
        to_var = get(params, to, nothing)
        if to_var !== nothing
            delete!(params, to)
        end
        if observeds !== nothing
            observeds[to] = ModelVariable(ObservedVariable;
                units=to_var === nothing ? nothing : to_var.units,
                description=to_var === nothing ? nothing : to_var.description,
                expression=transform,
                shape=to_var === nothing ? nothing : to_var.shape)
        end
        # Synthesize the observed's defining equation (`to ~ transform`) so the
        # flattened system stays well-determined — mirroring _collect_model!'s
        # observed-equation synthesis for authored observeds.
        push!(equations, Equation(VarExpr(to), transform))
        return
    end

    # Build replacement Expr. `factor` is a scaling coefficient (schema restricts
    # it to the scaling transforms — additive / multiplicative / conversion_factor;
    # a bare param_to_var / identity may not carry one). Apply it uniformly here
    # so all three bindings agree — Julia/Rust previously scaled only for
    # `conversion_factor`, silently dropping it for additive/multiplicative while
    # Python applied it. A factor of 1.0 is a no-op and left unwrapped.
    replacement::EarthSciSerialization.Expr = VarExpr(from)
    if entry.factor !== nothing && entry.factor != 1.0
        replacement = OpExpr("*",
            EarthSciSerialization.Expr[NumExpr(entry.factor::Float64), VarExpr(from)])
    end

    bindings = Dict{String, EarthSciSerialization.Expr}(to => replacement)
    for (i, eq) in enumerate(equations)
        equations[i] = Equation(
            substitute(eq.lhs, bindings),
            substitute(eq.rhs, bindings);
            _comment=eq._comment,
        )
    end

    # For param_to_var / conversion_factor, remove target param from parameter list.
    if (transform == "param_to_var" || transform == "conversion_factor") &&
       haskey(params, to)
        to_var = params[to]
        delete!(params, to)
        # Carry a grid shape from the (deleted) consumer parameter onto the
        # loader-qualified producer name, so the pointwise lift indexes the
        # loaded field per cell. Only when `from` is a data-loader variable
        # (guards against binding a model STATE, which already lives in `states`).
        if to_var.shape !== nothing && !isempty(to_var.shape) && !haskey(params, from)
            from_owner = first(split(from, "."; limit=2))
            if from_owner in loader_names
                params[from] = ModelVariable(ParameterVariable;
                    shape=to_var.shape, units=to_var.units,
                    description=to_var.description)
            end
        end
    end
    return
end

# ========================================
# Independent-variable detection
# ========================================

function _compute_independent_variables(equations::Vector{Equation},
                                        file_domain::Union{Domain, Nothing})::Vector{Symbol}
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

# ========================================
# Pointwise spatial lift of merged state ODEs (§10.5)
# ========================================
#
# Reaction ODE-gen and coupling both run at the AST level and IN THAT ORDER
# (reactions → generic `D(sp)=Σ terms` equations, then `operator_compose` merges
# each species' reaction ODE with the spatial operator's advection contribution).
# What operator_compose does NOT do is array-ify the result: the merged
# `D(sp) = <reaction> + <-u·makearray(grad(sp))>` still has a SCALAR `sp` while
# its advection `makearray` indexes `sp` per grid cell. This step performs the
# `lifting:"pointwise"` promotion — it reuses the same arrayop lowering a spatial
# MODEL uses — by wrapping each such merged state ODE in an `aggregate` over the
# grid, indexing the bare reaction species per cell and each operator makearray
# per cell, and giving the species a grid shape. The reaction network then runs
# pointwise on the grid through the existing arrayop evaluator.

# Collect every `makearray` OpExpr node reachable from `expr`.
function _collect_makearrays!(acc::Vector{OpExpr}, expr::EarthSciSerialization.Expr)
    expr isa OpExpr || return acc
    expr.op == "makearray" && push!(acc, expr)
    for a in expr.args
        _collect_makearrays!(acc, a)
    end
    expr.expr_body === nothing || _collect_makearrays!(acc, expr.expr_body)
    if expr.values !== nothing
        for v in expr.values
            _collect_makearrays!(acc, v)
        end
    end
    return acc
end

# First VarExpr leaf name in an index-argument expression (the loop variable of
# that index position), or `nothing` for a constant position.
function _index_arg_loop(expr::EarthSciSerialization.Expr)::Union{String,Nothing}
    if expr isa VarExpr
        return expr.name
    elseif expr isa OpExpr
        for a in expr.args
            v = _index_arg_loop(a)
            v === nothing || return v
        end
    end
    return nothing
end

# Determine the ordered spatial loop variables of a lowered spatial operator by
# reading an `index(<lifted species>, a1, …, aRank)` gather inside `ma` whose
# every position carries a loop variable (the interior stencil). Returns the loop
# names in index-position (dim) order, or `nothing` if none is found.
function _detect_lift_loops(ma::OpExpr, lifted::Set{String}, rank::Int)
    result = Union{Vector{String},Nothing}[nothing]
    function walk(e)
        result[1] === nothing || return
        e isa OpExpr || return
        if e.op == "index" && !isempty(e.args) && e.args[1] isa VarExpr &&
           ((e.args[1]::VarExpr).name in lifted) && length(e.args) - 1 == rank
            loops = String[]
            ok = true
            for k in 2:length(e.args)
                lv = _index_arg_loop(e.args[k])
                lv === nothing && (ok = false; break)
                push!(loops, lv)
            end
            ok && (result[1] = loops; return)
        end
        for a in e.args; walk(a); end
        e.expr_body === nothing || walk(e.expr_body)
        if e.values !== nothing
            for v in e.values; walk(v); end
        end
    end
    walk(ma)
    return result[1]
end

# Per-dimension grid extent of a lowered spatial operator: the largest cell index
# addressed in each `regions` dimension (the regions partition the grid).
function _makearray_extents(ma::OpExpr)::Vector{Int}
    regions = ma.regions
    (regions === nothing || isempty(regions)) && return Int[]
    rank = length(regions[1])
    ext = zeros(Int, rank)
    for region in regions
        length(region) == rank || continue
        for d in 1:rank
            ext[d] = max(ext[d], region[d][2])
        end
    end
    return ext
end

# Rewrite a scalar (merged reaction + operator) RHS into its per-cell form over
# the spatial `loops`: a bare reference to an array variable becomes
# `index(var, loops…)`, and each spatial-operator `makearray` becomes
# `index(makearray, loops…)` (its region values already index per cell).
# Self-contained nodes (index / aggregate / arrayop) are left untouched;
# elementwise ops recurse.
function _lift_rhs_to_cell(expr::EarthSciSerialization.Expr, arrayvars::Set{String},
                           loops::Vector{String})::EarthSciSerialization.Expr
    if expr isa VarExpr
        if expr.name in arrayvars
            return OpExpr("index", EarthSciSerialization.Expr[VarExpr(expr.name),
                          (VarExpr(l) for l in loops)...])
        end
        return expr
    elseif expr isa OpExpr
        if expr.op == "makearray"
            return OpExpr("index", EarthSciSerialization.Expr[expr,
                          (VarExpr(l) for l in loops)...])
        elseif expr.op == "index" || expr.op == "aggregate" || expr.op == "arrayop"
            return expr
        end
        new_args = EarthSciSerialization.Expr[_lift_rhs_to_cell(a, arrayvars, loops)
                                              for a in expr.args]
        return reconstruct(expr; args=new_args)
    end
    return expr
end

"""
    _apply_pointwise_lift!(equations, states, params, observeds, index_sets, coupling)

Pointwise spatial lift (§10.5) for `operator_compose` couplings that declare
`lifting: "pointwise"`. Promotes every state ODE that `operator_compose` merged
with a spatial operator (its merged RHS carries an operator `makearray`) from a
0-D scalar to the operator's grid shape, and rewrites the equation into an
`aggregate` over the grid. No-op when no coupling requests pointwise lifting, or
no merged equation carries a spatial-operator makearray.
"""
function _apply_pointwise_lift!(equations::Vector{Equation},
                                states::OrderedDict{String,ModelVariable},
                                params::OrderedDict{String,ModelVariable},
                                observeds::OrderedDict{String,ModelVariable},
                                index_sets::OrderedDict{String,IndexSet},
                                coupling)
    any(c -> c isa CouplingOperatorCompose &&
             (c.lifting !== nothing && c.lifting == "pointwise"), coupling) || return

    # A species is lifted iff its state ODE's merged RHS carries a spatial-operator
    # makearray (the advection contribution operator_compose added).
    lifted = Set{String}()
    for eq in equations
        (eq.lhs isa OpExpr && (eq.lhs::OpExpr).op == "D" &&
         !isempty((eq.lhs::OpExpr).args) && (eq.lhs::OpExpr).args[1] isa VarExpr) || continue
        isempty(_collect_makearrays!(OpExpr[], eq.rhs)) && continue
        push!(lifted, ((eq.lhs::OpExpr).args[1]::VarExpr).name)
    end
    isempty(lifted) && return

    # Operands to index per cell: the lifted species plus any already array-shaped
    # parameter/observed (e.g. a grid-shaped wind field bound from a loader).
    arrayvars = Set{String}(lifted)
    for d in (params, observeds, states)
        for (k, v) in d
            (v.shape !== nothing && !isempty(v.shape)) && push!(arrayvars, k)
        end
    end

    # Grid axis for a makearray dimension is the declared index set whose size
    # matches that dimension's extent (the `index_sets` map is unordered, so this
    # matches by size rather than key order).
    size_to_names = Dict{Int,Vector{String}}()
    for (name, iset) in index_sets
        iset.size === nothing && continue
        push!(get!(size_to_names, iset.size, String[]), name)
    end

    for (n, eq) in enumerate(equations)
        (eq.lhs isa OpExpr && (eq.lhs::OpExpr).op == "D") || continue
        lop = eq.lhs::OpExpr
        (!isempty(lop.args) && lop.args[1] isa VarExpr) || continue
        species = (lop.args[1]::VarExpr).name
        species in lifted || continue

        mas = _collect_makearrays!(OpExpr[], eq.rhs)
        (isempty(mas) || mas[1].regions === nothing || isempty(mas[1].regions)) && continue
        rank = length(mas[1].regions[1])
        loops = nothing
        for ma in mas
            loops = _detect_lift_loops(ma, lifted, rank)
            loops === nothing || break
        end
        loops === nothing && throw(DimensionPromotionError(
            "pointwise lift: could not determine the spatial loop variables for " *
            "species '$(species)' from its operator makearray"))

        # Map each grid dimension to a declared index set by matching extents.
        extents = _makearray_extents(mas[1])
        gaxes = String[]
        ranges = Dict{String,Any}()
        for d in 1:rank
            cands = get(size_to_names, extents[d], String[])
            if length(cands) == 1
                push!(gaxes, cands[1])
                ranges[loops[d]] = IndexSetRef(cands[1])
            else
                # No unique index set of this size — fall back to a dense range and
                # a synthetic shape axis (still a valid non-scalar shape).
                axname = "_liftdim$(d)_$(extents[d])"
                push!(gaxes, axname)
                ranges[loops[d]] = Any[1, extents[d]]
            end
        end

        # Promote the species to the grid shape so the scoped-ic fold, array-cell
        # discovery, and evaluator all see an array state.
        haskey(states, species) && (states[species] = _with_shape(states[species], gaxes))
        oidx = Any[l for l in loops]
        idx_species = OpExpr("index", EarthSciSerialization.Expr[VarExpr(species),
                             (VarExpr(l) for l in loops)...])
        new_lhs = OpExpr("aggregate", EarthSciSerialization.Expr[];
                         output_idx=oidx, ranges=ranges,
                         expr_body=OpExpr("D", EarthSciSerialization.Expr[idx_species], wrt="t"))
        new_rhs = OpExpr("aggregate", EarthSciSerialization.Expr[];
                         output_idx=oidx, ranges=ranges,
                         expr_body=_lift_rhs_to_cell(eq.rhs, arrayvars, loops))
        equations[n] = Equation(new_lhs, new_rhs; _comment=eq._comment)
    end
    return
end

"""
    flatten(file::EsmFile) -> FlattenedSystem

Flatten the coupled systems in `file` into a single symbolic representation
per spec §4.7.5 (+ §4.7.6 for hybrid dimension-promoted cases).

Throws `ConflictingDerivativeError` if any species is both the LHS of an
explicit `D(X, t) = ...` equation and a reactant/product of a reaction — such
a system is over-determined.
"""
function flatten(file::EsmFile)::FlattenedSystem
    # Step 0: Pre-flight conflict detection. Spec §4.7.5 item E.
    conflicting = _find_conflicting_derivatives(file)
    if !isempty(conflicting)
        throw(ConflictingDerivativeError(conflicting))
    end

    # Step 0b: coupling preflight checks. v0.8.0 retired the interface /
    # cross-domain-coverage checks (a document has one shared domain and
    # cross-grid coupling is an ordinary regridding `transform`); the
    # variable-map unit check remains.
    _check_variable_map_units!(file)

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
                            model, name, index_sets)
        end
    end

    # Step 1+2: Lower reaction systems to ODEs and collect.
    if file.reaction_systems !== nothing
        for (name, rsys) in file.reaction_systems
            push!(source_systems, name)
            _collect_reaction_system!(states, params, equations,
                                      rsys, name, file_domain)
        end
    end

    # Step 3: Apply coupling rules.
    coupling_rules_applied = String[]
    opaque_refs = String[]
    dimension_promotions = NamedTuple[]

    # Top-level data-loader names — used to recognize a `param_to_var` whose
    # producer is a LOADED field, so a grid-shaped binding keeps its shape.
    loader_names = file.data_loaders === nothing ? Set{String}() :
                   Set{String}(String(k) for k in keys(file.data_loaders))

    for entry in file.coupling
        push!(coupling_rules_applied, describe_coupling_entry(entry))
        if entry isa CouplingOperatorCompose
            _apply_operator_compose!(equations, entry, file)
        elseif entry isa CouplingCouple
            _apply_couple!(equations, entry, file)
        elseif entry isa CouplingVariableMap
            _apply_variable_map!(equations, params, entry, loader_names, observeds)
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
    ivs = _compute_independent_variables(equations, file_domain)

    # Step 5: Assemble FlattenedSystem. v0.8.0: the document carries at most one
    # shared domain, used directly as the target.
    target_domain = file_domain

    metadata = FlattenMetadata(
        sort!(collect(source_systems)),
        coupling_rules_applied;
        dimension_promotions_applied=dimension_promotions,
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
        target_domain, metadata, index_sets, function_tables,
    )
end

"""
    flatten(model::Model; name::String="anonymous") -> FlattenedSystem

Convenience: wrap a single Model in a synthetic EsmFile (with a default system
name) and run the full flattener. This is the call path used by
`ModelingToolkit.System(::Model)` in the Julia extension (see gt-fpw).
"""
function flatten(model::Model; name::String="anonymous")::FlattenedSystem
    file = EsmFile("0.1.0", Metadata(name);
                   models=Dict{String, Model}(name => model))
    return flatten(file)
end

"""
    flatten(rsys::ReactionSystem; name::String="anonymous") -> FlattenedSystem

Convenience: wrap a ReactionSystem in a synthetic EsmFile and flatten.
"""
function flatten(rsys::ReactionSystem; name::String="anonymous")::FlattenedSystem
    file = EsmFile("0.1.0", Metadata(name);
                   reaction_systems=Dict{String, ReactionSystem}(name => rsys))
    return flatten(file)
end

# ========================================
# FlattenedSystem → runnable single-model ESM document
# ========================================

"""
    flattened_to_esm(flat::FlattenedSystem; name="Flattened", esm_version="0.5.0") -> Dict{String,Any}

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
                          esm_version::AbstractString="0.5.0")::Dict{String,Any}
    sname = String(name)

    variables = Dict{String,Any}()
    # Order: states, parameters, observeds. A later partition never re-keys an
    # earlier one (flatten guarantees disjoint names), so merge is unambiguous.
    for partition in (flat.state_variables, flat.parameters, flat.observed_variables)
        for (k, v) in partition
            vv = v.expression === nothing ? v :
                ModelVariable(v.type; default=v.default, units=v.units,
                    default_units=v.default_units, description=v.description,
                    expression=v.expression,
                    shape=v.shape, location=v.location,
                    noise_kind=v.noise_kind, correlation_group=v.correlation_group)
            variables[k] = serialize_model_variable(vv)
        end
    end

    model = Dict{String,Any}(
        "variables" => variables,
        "equations" => Any[serialize_equation(Equation(eq.lhs, eq.rhs;
                            _comment=eq._comment))
                           for eq in flat.equations],
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

# ========================================
# Coupling entry descriptions (unchanged from prior implementation)
# ========================================

"""
    describe_coupling_entry(entry::CouplingEntry) -> String

Produce a human-readable description of a coupling entry for the flattened
system's metadata.
"""
function describe_coupling_entry(entry::CouplingEntry)::String
    if entry isa CouplingOperatorCompose
        systems_str = join(entry.systems, " + ")
        desc = "operator_compose($(systems_str))"
        if entry.description !== nothing
            desc *= " -- $(entry.description)"
        end
        return desc
    elseif entry isa CouplingCouple
        systems_str = join(entry.systems, " <-> ")
        desc = "couple($(systems_str))"
        if entry.description !== nothing
            desc *= " -- $(entry.description)"
        end
        return desc
    elseif entry isa CouplingVariableMap
        transform_str = entry.transform isa EarthSciSerialization.Expr ?
            "expression" : entry.transform
        desc = "variable_map($(entry.from) -> $(entry.to), transform=$(transform_str))"
        if entry.factor !== nothing
            desc *= " [factor=$(entry.factor)]"
        end
        if entry.description !== nothing
            desc *= " -- $(entry.description)"
        end
        return desc
    elseif entry isa CouplingOperatorApply
        desc = "operator_apply($(entry.operator))"
        if entry.description !== nothing
            desc *= " -- $(entry.description)"
        end
        return desc
    elseif entry isa CouplingCallback
        desc = "callback($(entry.callback_id))"
        if entry.description !== nothing
            desc *= " -- $(entry.description)"
        end
        return desc
    elseif entry isa CouplingEvent
        desc = "event($(entry.event_type))"
        if entry.description !== nothing
            desc *= " -- $(entry.description)"
        end
        return desc
    else
        return "unknown_coupling($(typeof(entry)))"
    end
end

# ========================================
# Array-variable shape inference (gt-vt3)
# ========================================

"""
    infer_array_shapes(equations::Vector{Equation}) -> Dict{String, Vector{UnitRange{Int}}}

Walk every `arrayop`, `makearray`, and `index` node in the equation set and
compute, for each array-shaped variable, the union of ranges observed across
all references. The result maps variable name → per-axis `UnitRange{Int}`
vector (empty for scalar variables; one entry per dimension for array
variables). Only variables that actually appear inside an array operator get
a shape — scalar variables are absent from the result dict.

Semantics:
- For a `VarExpr` appearing as the first argument of an `index` node, each
  subsequent argument is an index expression (literal int, symbolic index
  name, or affine offset like `i+1`). The range of that index determines the
  variable's length on that axis. Affine offsets widen the required range
  (e.g. `u[i-1]` and `u[i+1]` in `i in 2:9` force `u` to span `1:10`).
- For an `arrayop`, its `output_idx` and `ranges` combined define the
  iteration space. Index names with no explicit range are left for
  inference from their usages inside the body.
- Conflicts: if a variable is referenced with inconsistent dimensionality
  across equations, this function raises an `ArgumentError`.

This pass is deliberately standalone — it does not mutate `FlattenedSystem`.
It is called at MTK build time from `ext/EarthSciSerializationMTKExt.jl` so
scalar-only callers pay no cost.
"""
function infer_array_shapes(equations::Vector{Equation})
    shapes = Dict{String,Vector{UnitRange{Int}}}()
    for eq in equations
        _scan_shape!(shapes, eq.lhs, Dict{String,UnitRange{Int}}())
        _scan_shape!(shapes, eq.rhs, Dict{String,UnitRange{Int}}())
    end
    return shapes
end

# Walk an expression tree recording per-variable axis extents. `idx_env`
# maps index-symbol name (`"i"`, `"j"`) to the UnitRange it iterates over
# in the enclosing `arrayop`, so `index(u, i-1, j+1)` inside `i in 2:9` can
# be resolved to a concrete range on each axis.
function _scan_shape!(shapes::Dict{String,Vector{UnitRange{Int}}},
                      expr::Expr,
                      idx_env::Dict{String,UnitRange{Int}})
    if expr isa NumExpr || expr isa IntExpr || expr isa VarExpr
        return
    end
    expr isa OpExpr || return

    if expr.op == "index"
        _record_index!(shapes, expr, idx_env)
        for a in expr.args[2:end]
            _scan_shape!(shapes, a, idx_env)
        end
        return
    end

    if expr.op == "arrayop" || expr.op == "aggregate"
        # Extend idx_env with any explicit ranges declared on this node.
        new_env = copy(idx_env)
        if expr.ranges !== nothing
            for (name, r) in expr.ranges
                lo, hi = _range_bounds(r)
                lo === nothing && continue  # expression-valued / index-set bounds — skip for static shape analysis
                new_env[name] = lo:hi
            end
        end
        if expr.expr_body !== nothing
            _scan_shape!(shapes, expr.expr_body, new_env)
        end
        for a in expr.args
            _scan_shape!(shapes, a, new_env)
        end
        return
    end

    if expr.op == "makearray"
        if expr.values !== nothing
            for v in expr.values
                _scan_shape!(shapes, v, idx_env)
            end
        end
        for a in expr.args
            _scan_shape!(shapes, a, idx_env)
        end
        return
    end

    # Generic recursion for other operators (+, -, *, /, ^, elementary
    # functions, D, grad, etc.). The optional `expr_body` field is scanned
    # only for array ops above, so we skip it here.
    for a in expr.args
        _scan_shape!(shapes, a, idx_env)
    end
end

# An index-set reference (RFC §5.2) carries no statically-known bound here
# (interval size / categorical members / ragged length live in the registry,
# resolved by the evaluator) — skip it for static shape analysis.
_range_bounds(::IndexSetRef) = (nothing, nothing)
function _range_bounds(r::AbstractVector)
    all(x -> x isa Integer, r) || return nothing, nothing  # expression-valued stop — skip for static analysis
    if length(r) == 2
        return Int(r[1]), Int(r[2])
    elseif length(r) == 3
        return Int(r[1]), Int(r[3])  # [start, step, stop]
    end
    throw(ArgumentError("range must have 2 or 3 entries, got $(length(r))"))
end

# Record a shape entry for `u` from `index(u, i1, i2, ...)`. Each index
# expression is evaluated against `idx_env` to determine the range it
# sweeps over on that axis. Returns nothing on a miss (scalar access).
function _record_index!(shapes::Dict{String,Vector{UnitRange{Int}}},
                        idx_node::OpExpr,
                        idx_env::Dict{String,UnitRange{Int}})
    isempty(idx_node.args) && return
    first_arg = idx_node.args[1]
    first_arg isa VarExpr || return
    vname = first_arg.name
    axis_ranges = UnitRange{Int}[]
    for idx_expr in idx_node.args[2:end]
        r = _eval_index_range(idx_expr, idx_env)
        r === nothing && return  # opaque — can't infer this axis
        push!(axis_ranges, r)
    end

    if haskey(shapes, vname)
        existing = shapes[vname]
        if length(existing) != length(axis_ranges)
            throw(ArgumentError(
                "Inconsistent dimensionality for variable '$vname': " *
                "saw $(length(existing))-D and $(length(axis_ranges))-D references"))
        end
        for (i, r) in enumerate(axis_ranges)
            existing[i] = min(first(existing[i]), first(r)):max(last(existing[i]), last(r))
        end
    else
        shapes[vname] = axis_ranges
    end
end

# Evaluate an index expression against the index-symbol environment.
# Supports: integer literals, bare index symbols (VarExpr in idx_env), and
# affine offsets `op("+", [idx, NumExpr(k)])` / `op("-", ...)` with either
# operand order. Returns a UnitRange representing the range that expression
# sweeps, or `nothing` if the shape cannot be inferred from this node alone.
function _eval_index_range(idx_expr::Expr, idx_env::Dict{String,UnitRange{Int}})
    if idx_expr isa IntExpr
        v = Int(idx_expr.value)
        return v:v
    elseif idx_expr isa NumExpr
        v = Int(idx_expr.value)
        return v:v
    elseif idx_expr isa VarExpr
        if haskey(idx_env, idx_expr.name)
            return idx_env[idx_expr.name]
        end
        return nothing
    elseif idx_expr isa OpExpr && idx_expr.op in ("+", "-") && length(idx_expr.args) == 2
        a, b = idx_expr.args
        base, offset = _split_affine(a, b)
        base === nothing && return nothing
        haskey(idx_env, base) || return nothing
        env_r = idx_env[base]
        shift = idx_expr.op == "+" ? offset : -offset
        return (first(env_r) + shift):(last(env_r) + shift)
    end
    return nothing
end

function _split_affine(a::Expr, b::Expr)
    if a isa VarExpr && b isa IntExpr
        return a.name, Int(b.value)
    elseif a isa IntExpr && b isa VarExpr
        return b.name, Int(a.value)
    elseif a isa VarExpr && b isa NumExpr
        return a.name, Int(b.value)
    elseif a isa NumExpr && b isa VarExpr
        return b.name, Int(a.value)
    end
    return nothing, 0
end
