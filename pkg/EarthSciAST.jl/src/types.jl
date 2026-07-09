"""
Type definitions for EarthSciML Serialization Format.

This module defines the complete type hierarchy for the ESM format,
matching the JSON schema definitions for language-agnostic model interchange.
"""

# Apply `f` to `x`, propagating `nothing` (the standard absent-optional-field
# guard: `_maybe(string, get(data, key, nothing))`).
_maybe(f, x) = x === nothing ? nothing : f(x)

"""
    ESM_FORMAT_VERSION

The ESM format version (semver string) this implementation targets — the value
written into the `esm` field of freshly constructed files. Files loaded from
disk keep whatever version they declare; this constant is only the default for
documents the library itself creates (flatten wrappers, MTK/Catalyst export).
Must track the version on the first line of `esm-spec.md`.
"""
const ESM_FORMAT_VERSION = "0.8.0"

# ========================================
# 1. Expression Type Hierarchy
# ========================================

"""
    abstract type Expr end

Abstract base type for all mathematical expressions in the ESM format.
Expressions can be numeric literals, variable references, or operator nodes.
"""
abstract type Expr end

"""
    NumExpr(value::Float64)

Floating-point numeric literal expression. Represents a JSON number whose
mathematical value is **non-integral** (or integral but not `Int64`-
representable): literal type is decided by *value*, not by the token's source
spelling (CONFORMANCE_SPEC §5.5.3.1 rules 1/3). A JSON number whose value is
integral and `Int64`-representable — however it was spelled (`1`, `1.0`,
`2.5e1`) — parses as an `IntExpr`, so `parse_expression` never produces
`NumExpr(1.0)`; such a node can only be built directly in Julia code.
"""
struct NumExpr <: Expr
    value::Float64
end

"""
    IntExpr(value::Int64)

Integer numeric literal expression. Represents a JSON number whose
mathematical value is integral and `Int64`-representable, **regardless of how
the source document spelled the token** (`0.0` → `IntExpr(0)`, `2.5e1` →
`IntExpr(25)`; CONFORMANCE_SPEC §5.5.3.1 rules 1/3). The AST distinguishes
integer and float nodes: `IntExpr(1)` and `NumExpr(1.0)` are different values,
and canonicalization never auto-promotes one to the other (RFC §5.4.1); on the
wire an `IntExpr` serializes as an integer literal (no `.`/`e`).
"""
struct IntExpr <: Expr
    value::Int64
end

"""
    VarExpr(name::String)

Variable or parameter reference expression containing a name string.
"""
struct VarExpr <: Expr
    name::String
end

"""
    OpExpr(op::String, args::Vector{Expr}; wrt, dim, int_var, lower, upper, output_idx, expr_body, reduce, ranges, regions, values, shape, perm, axis, fn)

Operator expression node containing:
- `op`: operator name (e.g., "+", "*", "log", "D", "arrayop")
- `args`: vector of argument expressions
- `wrt`: variable name for differentiation (optional; for `D`)
- `dim`: dimension for spatial operators (optional; for `grad`, `div`)
- `int_var`: integration variable name (optional; for `integral`, matches JSON field "var")
- `lower`: lower integration bound expression (optional; for `integral`)
- `upper`: upper integration bound expression (optional; for `integral`)
- `output_idx`: for `arrayop`, list of result index symbols (String) or literal
  singleton dimensions (Int 1). Mirrors SymbolicUtils.ArrayOp.output_idx.
- `expr_body`: for `arrayop`, the scalar body evaluated at each index point
  (a nested `Expr` tree). Named `expr_body` — not `expr` — to avoid shadowing
  the `EarthSciAST.Expr` abstract type.
- `reduce`: for `arrayop`/`aggregate`, the reduction operator applied to
  contracted indices (one of "+", "*", "max", "min"; default "+"). Names the
  semiring ⊕ only; it is the shorthand retained for files that omit `semiring`
  (RFC semiring-faq-unified-ir §5.1).
- `semiring`: for `arrayop`/`aggregate`, the named semiring `(⊕, ⊗)` with
  normative identity elements that parameterizes the reduction (closed registry:
  "sum_product", "max_product", "min_sum", "max_sum", "bool_and_or"). Absent ⇒
  "sum_product", reproducing today's einsum semantics. When present it supersedes
  `reduce`; the ⊕/⊗ operators and BOTH identities come from the registry table,
  never the file (RFC §5.1).
- `ranges`: for `arrayop`, map from index symbol name to iteration range
  (vector of 2 or 3 ints `[start, stop]` / `[start, step, stop]`).
- `regions`: for `makearray`, list of sub-region boxes, each a list of
  `[start, stop]` pairs per output dimension.
- `values`: for `makearray`, one sub-expression per entry in `regions`.
- `shape`: for `reshape`, target shape; entries are `Int` (concrete length)
  or `String` (symbolic dimension).
- `perm`: for `transpose`, optional 0-based axis permutation.
- `axis`: for `concat`, 0-based axis to concatenate along.
- `fn`: for `broadcast`, the scalar operator to apply element-wise.
- `name`: for the `fn` op, the dotted module path of a function in the closed
  function registry (esm-spec §9.2). The set of valid `name` values is fixed by
  the spec version; bindings MUST reject unknown names with diagnostic
  `unknown_closed_function`.
- `value`: for the `const` op, the inline literal value carried by this node.
  Any JSON value (number, integer, or nested array thereof); `args` MUST be
  empty for a const node.
"""
# `mutable struct` (not `struct`) is a deliberate PERFORMANCE choice, not a
# licence to mutate: the build path treats `OpExpr` as an immutable value and only
# ever copies-with-changes through `reconstruct` (fields are never assigned after
# construction). Mutability buys true POINTER-IDENTITY for the build-time
# memoization `IdDict{OpExpr,…}` caches (`_BuildMemo` in tree_walk/compile.jl and
# the `_stencil_var_set` cache in tree_walk/stencil.jl). With an *immutable*
# `OpExpr`, `IdDict` falls back to `objectid`/`===`, which for an immutable struct
# are STRUCTURAL — every memo probe re-hashes the `op` String and walks all ~35
# fields (measured ~17× slower per probe than pointer identity), and those probes
# dominate the `build_evaluator` profile. A mutable struct makes `objectid`/`===`
# (hence `IdDict` and the `r !== args[i]` "did this subtree change" identity checks
# throughout the tree walk) pointer-based, so the memos become the O(1) identity
# caches they were always meant to be. No custom `==`/`hash` is defined: `OpExpr`
# is never a *value*-keyed `Dict`/`Set` key anywhere (only ever an `IdDict` key),
# and default `==` was already non-structural for trees — two distinct-but-equal
# `OpExpr`s compared `false` because their `args` `Vector`s differ by identity — so
# pointer `==` matches the pre-existing de-facto behaviour.
mutable struct OpExpr <: Expr
    op::String
    args::Vector{Expr}
    wrt::Union{String,Nothing}
    dim::Union{String,Nothing}
    int_var::Union{String,Nothing}
    lower::Union{Expr,Nothing}
    upper::Union{Expr,Nothing}
    output_idx::Union{Vector{Any},Nothing}
    expr_body::Union{Expr,Nothing}
    reduce::Union{String,Nothing}
    semiring::Union{String,Nothing}
    ranges::Union{Dict{String,Any},Nothing}
    regions::Union{Vector{Vector{Vector{Int}}},Nothing}
    values::Union{Vector{Expr},Nothing}
    shape::Union{Vector{Any},Nothing}
    perm::Union{Vector{Int},Nothing}
    axis::Union{Int,Nothing}
    fn::Union{String,Nothing}
    name::Union{String,Nothing}
    value::Any
    # table_lookup (esm-spec §9.5, v0.4.0): the function_tables entry id this
    # node references. ``args`` MUST be empty for a table_lookup node — the
    # per-axis input expressions live in ``table_axes``.
    table::Union{String,Nothing}
    # Per-axis input-coordinate expression map for a table_lookup node.
    # Stored under the JSON key ``axes`` on the wire.
    table_axes::Union{Dict{String,Expr},Nothing}
    # Output selector for a multi-output table_lookup. Either a non-negative
    # integer (0-based index) or a string (entry of the table's outputs).
    output::Any

    # ── M2: value-equality joins + filter predicates on aggregate/arrayop ──
    # (RFC semiring-faq-unified-ir §5.3 / §7.2; schema bead ess-my4.2.1).
    #
    # `join`   — the parsed join clauses, an inner equi-join of factors by key
    #            columns. Each clause is a `Vector{Tuple{String,String}}` of
    #            `[left, right]` key-column pairs that must all compare equal for
    #            a ⊗-product term to contribute. This is the wire form (parsed /
    #            serialized); the build path resolves it into `join_gates`.
    # `filter` — an optional boolean predicate Expression restricting which index
    #            combinations contribute a term (§7.2). A combination for which it
    #            is false contributes the additive identity 0̄ — compiled into a
    #            runtime `ifelse(pred, term, 0̄)` guard (it may reference factors
    #            whose values are only known at run time, so it is NOT folded).
    # `join_gates` — INTERNAL: the build-time-resolved join, a `Vector` of
    #            `_JoinGate` mapping each key symbol's range position to a bucket
    #            code (equal codes ⇔ equal key values). Populated by
    #            `_resolve_join_gates` against the document index-set registry;
    #            never parsed or serialized (the wire form is `join`).
    join::Union{Vector{Any},Nothing}
    filter::Union{Expr,Nothing}
    join_gates::Union{Vector{Any},Nothing}

    # ── M4 geometry kernel (RFC semiring-faq-unified-ir §8.1 / Appendix B;
    #    schema bead ess-my4.4.2; Julia kernel ess-my4.4.3) ──
    #
    # `id`       — node-local identifier (RFC §6.1) by which a `kind:"derived"`
    #              index set names its producer via `from_faq`. Carried on an
    #              `intersect_polygon` leaf so its data-dependent clip ring is
    #              exposed as the derived index set a `polygon_area` FAQ ranges
    #              over (§8.1). Emitted only when present (byte-identical round-trip
    #              for non-geometry nodes).
    # `manifold` — geometry interpretation for the `intersect_polygon` leaf:
    #              "planar" | "spherical" | "geodesic" (CONFORMANCE_SPEC.md §5.8.4).
    #              REQUIRED on every `intersect_polygon` node, no default; matched
    #              EXACTLY across bindings. Meaningful only for `intersect_polygon`.
    id::Union{String,Nothing}
    manifold::Union{String,Nothing}

    # ── Value-invention aggregate vocabulary (RFC §5.5 / §6.1) ──
    # `distinct` — an index-set-PRODUCING aggregate (a `distinct:true` relational
    #              set former); its emitted `key`s are deduplicated in §5.5.1 sorted
    #              order to materialise a derived index set (matched by `from_faq`).
    # `key`       — the skolem/tuple KEY expression the producer emits per surviving
    #              index combination (`{op:skolem, args:[…]}`). Both live ONLY in the
    #              raw value-invention front-door (they are read off the raw JSON),
    #              but MUST survive the typed-IR round-trip so a flattened multi-model
    #              document's producer is still recognised (else the derived set is
    #              never sized and the producer's ODE equation is not dropped).
    distinct::Union{Bool,Nothing}
    key::Union{Expr,Nothing}

    # ── Arg-witness / expression-template display fields ──
    # `arg`      — for `argmin`/`argmax`, the witnessing index symbol name whose
    #              value at the optimum is returned (RENDERING_CONTRACT.md §argmin/
    #              argmax: `{op, arg, expr, ranges?}`). Carried on the typed node so
    #              the pretty-printer can render `argmin[arg] (expr)`.
    # `bindings` — for `apply_expression_template`, the parameter→argument-expression
    #              map (esm-spec §9.6). Templates are normally lowered before typed
    #              parsing, but the node is renderable directly so the pretty-printer
    #              can emit `name⟨p=e, …⟩` byte-identically to the other bindings.
    arg::Union{String,Nothing}
    bindings::Union{Dict{String,Expr},Nothing}

    OpExpr(op::String, args::Vector{Expr};
           wrt=nothing, dim=nothing,
           int_var=nothing, lower=nothing, upper=nothing,
           output_idx=nothing, expr_body=nothing, reduce=nothing,
           semiring=nothing,
           ranges=nothing, regions=nothing, values=nothing,
           shape=nothing, perm=nothing, axis=nothing, fn=nothing,
           name=nothing, value=nothing,
           table=nothing, table_axes=nothing, output=nothing,
           join=nothing, filter=nothing, join_gates=nothing,
           id=nothing, manifold=nothing,
           distinct=nothing, key=nothing,
           arg=nothing, bindings=nothing,
           # `handler_id` was the v0.2.x field for the now-removed `call`
           # op (esm-spec §9.2 closure). Accept and ignore on construction
           # so internal helpers that still pass it through don't break
           # mid-migration; the field is no longer stored or serialized.
           handler_id=nothing) =
        new(op, args, wrt, dim, int_var, lower, upper, output_idx, expr_body, reduce,
            semiring, ranges,
            regions, values, shape, perm, axis, fn, name, value,
            table, table_axes, output, join, filter, join_gates,
            id, manifold, distinct, key, arg, bindings)

    # Fully-positional inner constructor — the ALLOCATION-FREE reconstruction
    # path. The keyword constructor above builds a ~30-entry `NamedTuple` for its
    # kwargs on every call, and `reconstruct` (the one canonical copy-with-changes
    # site, invoked once per rewritten node in `_sub_preserving`/`_resolve_*`)
    # would pay that on every substitution. Routing `reconstruct` through this
    # positional form drops the per-node NamedTuple allocation entirely. The 32
    # arguments MUST stay in exact struct-field order; there is no other 32-arg
    # `OpExpr` method, so the positional call is unambiguous.
    global _reconstruct_opexpr(op::String, args::Vector{Expr}, wrt, dim, int_var,
            lower, upper, output_idx, expr_body, reduce, semiring, ranges, regions,
            values, shape, perm, axis, fn, name, value, table, table_axes, output,
            join, filter, join_gates, id, manifold, distinct, key, arg, bindings) =
        new(op, args, wrt, dim, int_var, lower, upper, output_idx, expr_body, reduce,
            semiring, ranges,
            regions, values, shape, perm, axis, fn, name, value,
            table, table_axes, output, join, filter, join_gates,
            id, manifold, distinct, key, arg, bindings)
end

# Accept any AbstractVector of Expr-subtypes (e.g. Vector{VarExpr},
# Vector{OpExpr}, mixed Any arrays) and widen to Vector{Expr}. This keeps
# call sites terse — callers don't need to annotate `Expr[...]` when they
# construct a homogeneous argument list.
function OpExpr(op::String, args::AbstractVector; kwargs...)
    widened = Vector{Expr}(undef, length(args))
    for (i, a) in enumerate(args)
        widened[i] = a
    end
    return OpExpr(op, widened; kwargs...)
end

"""
    reconstruct(e::OpExpr; op=…, args=…, <any OpExpr field>=…) -> OpExpr

Rebuild an `OpExpr`, copying EVERY field from `e` by default and overriding only
the keywords explicitly passed. This is the ONE canonical, field-preserving way
to reconstruct a node after a structural rewrite (substitution, namespacing,
simplification, canonicalization, …).

It exists because `OpExpr` carries ~26 optional fields (geometry `manifold`/`id`,
`table`/`table_axes`/`output`, aggregate `semiring`/`ranges`/`output_idx`/
`expr_body`/`reduce`, relational `join`/`filter`/`join_gates`, `int_var`/`lower`/
`upper`, …) and the historical reconstruction sites each hand-listed a different
subset of keywords — silently dropping whatever they forgot. That made
`flatten`/`substitute`/`namespace_expr` LOSSY: e.g. a coupling `substitute`
erased an `intersect_polygon`'s `manifold`, and `namespace_expr` erased a
`table_lookup`'s `table`. Routing every rewrite through `reconstruct` makes
field preservation the default and a drop an explicit, visible choice.

Callers that transform sub-expressions should pass the already-transformed
result for the relevant field, e.g. `reconstruct(e; args=new_args)` or
`reconstruct(e; expr_body=new_body, filter=new_filter)`.
"""
function reconstruct(e::OpExpr;
        op::String = e.op,
        args = e.args,
        wrt = e.wrt, dim = e.dim, int_var = e.int_var,
        lower = e.lower, upper = e.upper,
        output_idx = e.output_idx, expr_body = e.expr_body,
        reduce = e.reduce, semiring = e.semiring, ranges = e.ranges,
        regions = e.regions, values = e.values, shape = e.shape,
        perm = e.perm, axis = e.axis, fn = e.fn, name = e.name, value = e.value,
        table = e.table, table_axes = e.table_axes, output = e.output,
        join = e.join, filter = e.filter, join_gates = e.join_gates,
        id = e.id, manifold = e.manifold,
        distinct = e.distinct, key = e.key,
        arg = e.arg, bindings = e.bindings)
    # Positional (NamedTuple-free) construction on the hot path. `args` defaults to
    # the `Vector{Expr}` field and callers overwrite it with `Vector{Expr}`s, so the
    # `isa` fast path is the norm; the widening branch preserves the historical
    # acceptance of any `AbstractVector` of `Expr` (matching the keyword ctor's
    # `OpExpr(op, args::AbstractVector)` widening overload).
    argv = args isa Vector{Expr} ? args : Vector{Expr}(args)
    return _reconstruct_opexpr(op, argv, wrt, dim, int_var, lower, upper,
        output_idx, expr_body, reduce, semiring, ranges, regions, values, shape,
        perm, axis, fn, name, value, table, table_axes, output, join, filter,
        join_gates, id, manifold, distinct, key, arg, bindings)
end

# ========================================
# 2. Equation Types
# ========================================

"""
    Equation(lhs::Expr, rhs::Expr; _comment=nothing)

Mathematical equation with left-hand side and right-hand side expressions.
Used for differential equations and algebraic constraints.
Optional `_comment` provides a human-readable description.
"""
struct Equation
    lhs::Expr
    rhs::Expr
    _comment::Union{String,Nothing}

    Equation(lhs::Expr, rhs::Expr; _comment=nothing) =
        new(lhs, rhs, _comment)
end

"""
    AffectEquation(lhs::String, rhs::Expr)

Assignment equation for discrete events.
- `lhs`: target variable name (string)
- `rhs`: expression for the new value
"""
struct AffectEquation
    lhs::String
    rhs::Expr
end

# ========================================
# 3. Event System Base Types
# ========================================

"""
    abstract type EventType end

Abstract base type for all event types in the ESM format.
"""
abstract type EventType end

"""
    abstract type DiscreteEventTrigger end

Abstract base type for discrete event triggers.
"""
abstract type DiscreteEventTrigger end

"""
    ConditionTrigger(expression::Expr)

Trigger based on boolean condition expression.
"""
struct ConditionTrigger <: DiscreteEventTrigger
    expression::Expr
end

"""
    PeriodicTrigger(period::Float64, phase::Float64)

Trigger that fires periodically.
- `period`: time interval between triggers
- `phase`: time offset for first trigger
"""
struct PeriodicTrigger <: DiscreteEventTrigger
    period::Float64
    phase::Float64

    # Constructor with optional phase
    PeriodicTrigger(period::Float64; phase=0.0) = new(period, phase)
end

"""
    PresetTimesTrigger(times::Vector{Float64})

Trigger that fires at preset times.
"""
struct PresetTimesTrigger <: DiscreteEventTrigger
    times::Vector{Float64}
end

"""
    FunctionalAffect

Functional affect for discrete events.
"""
struct FunctionalAffect
    target::String
    expression::Expr
    operation::String  # "set", "add", "multiply", etc.

    # Constructor with default operation
    FunctionalAffect(target::String, expression::Expr; operation="set") =
        new(target, expression, operation)
end

# ========================================
# 4. Event Types
# ========================================

"""
    ContinuousEvent <: EventType

Event triggered by zero-crossing of condition expressions.
"""
struct ContinuousEvent <: EventType
    conditions::Vector{Expr}
    affects::Vector{AffectEquation}
    description::Union{String,Nothing}

    # Constructor with optional description
    ContinuousEvent(conditions::Vector{Expr}, affects::Vector{AffectEquation}; description=nothing) =
        new(conditions, affects, description)
end

"""
    DiscreteEvent <: EventType

Event triggered by discrete triggers with functional affects.

`functional_affect` carries the raw schema `functional_affect` handler
descriptor (`handler_id`, `read_vars`, `read_params`, optional
`modified_params` / `config`) verbatim, so a handler-based event survives a
parse → serialize round trip instead of degrading into a bogus `{lhs, rhs}`
affect equation. The schema (`DiscreteEvent` oneOf) requires exactly one of
symbolic `affects` or a `functional_affect` descriptor.
"""
struct DiscreteEvent <: EventType
    trigger::DiscreteEventTrigger
    affects::Vector{FunctionalAffect}
    description::Union{String,Nothing}
    functional_affect::Union{Dict{String,Any},Nothing}

    # Constructor with optional description / handler descriptor
    DiscreteEvent(trigger::DiscreteEventTrigger, affects::Vector{FunctionalAffect};
                  description=nothing, functional_affect=nothing) =
        new(trigger, affects, description, functional_affect)
end

# ========================================
# 5. Model Component Types
# ========================================

"""
    @enum ModelVariableType

Type enumeration for model variables:
- StateVariable: differential state variables
- ParameterVariable: constant parameters
- ObservedVariable: derived/computed variables
- BrownianVariable: stochastic noise sources (Wiener processes). The presence
  of any brownian variable promotes the enclosing model from an ODE system to
  an SDE system. Maps to MTK `@brownians` and an `SDESystem`.
"""
@enum ModelVariableType begin
    StateVariable
    ParameterVariable
    ObservedVariable
    BrownianVariable
end

"""
    ModelVariable

Structure defining a model variable with its type, default value, and optional expression.

Brownian-only fields:
- `noise_kind`: stochastic process kind (currently only `"wiener"`).
- `correlation_group`: opaque tag grouping correlated noise sources.
"""
struct ModelVariable
    type::ModelVariableType
    default::Union{Float64,Nothing}
    description::Union{String,Nothing}
    expression::Union{Expr,Nothing}
    units::Union{String,Nothing}
    default_units::Union{String,Nothing}
    # Arrayed-variable shape: ordered dimension names drawn from the
    # enclosing model's domain.spatial. `nothing` means scalar.
    # See discretization RFC §10.2.
    shape::Union{Vector{String},Nothing}
    # Staggered-grid location tag (e.g. "cell_center", "edge_normal",
    # "vertex"). `nothing` means no explicit staggering. See RFC §10.2.
    location::Union{String,Nothing}
    noise_kind::Union{String,Nothing}
    correlation_group::Union{String,Nothing}

    # Constructor with optional parameters
    ModelVariable(type::ModelVariableType;
                  default=nothing,
                  description=nothing,
                  expression=nothing,
                  units=nothing,
                  default_units=nothing,
                  shape=nothing,
                  location=nothing,
                  noise_kind=nothing,
                  correlation_group=nothing) =
        new(type, default, description, expression, units, default_units,
            shape, location, noise_kind, correlation_group)
end

"""
    reconstruct(v::ModelVariable; <any ModelVariable field>=…) -> ModelVariable

Rebuild a `ModelVariable`, copying every field from `v` by default and
overriding only the keywords explicitly passed. The `ModelVariable` analogue of
[`reconstruct(::OpExpr)`](@ref): route all copy-with-changes sites through this
helper so a newly added field is preserved by default instead of silently
dropped by a hand-listed subset.
"""
function reconstruct(v::ModelVariable;
        type::ModelVariableType = v.type,
        default = v.default,
        description = v.description,
        expression = v.expression,
        units = v.units,
        default_units = v.default_units,
        shape = v.shape,
        location = v.location,
        noise_kind = v.noise_kind,
        correlation_group = v.correlation_group)
    return ModelVariable(type;
        default=default, description=description, expression=expression,
        units=units, default_units=default_units, shape=shape,
        location=location, noise_kind=noise_kind,
        correlation_group=correlation_group)
end

"""
    TimeSpan(start::Float64, stop::Float64)

Simulation time interval for inline model tests and examples (§gt-cc1).
"""
struct TimeSpan
    start::Float64
    stop::Float64
end

"""
    Tolerance(abs::Union{Float64,Nothing}, rel::Union{Float64,Nothing})

Numerical comparison tolerance. Either or both of `abs` / `rel` may be
set; an assertion passes when any set bound is satisfied.
"""
struct Tolerance
    abs::Union{Float64,Nothing}
    rel::Union{Float64,Nothing}

    Tolerance(; abs=nothing, rel=nothing) = new(abs, rel)
end

"""
    Assertion(variable::String, time::Float64, expected::Float64, tolerance, coords, reduce, reference)

A scalar `(variable, time, expected)` check used inside a `Test`.

PDE-aware variants (gt-vzwk):
- `coords`: pin a spatial point as `dim => coordinate` (mutually exclusive with `reduce`).
- `reduce`: collapse the spatial field to a scalar — one of `integral`, `mean`,
  `max`, `min`, `L2_error`, `Linf_error`. Mutually exclusive with `coords`.
- `reference`: required for error-norm reductions; either an `Expr` AST evaluated
  over the domain coordinates, or a `Dict` representing the `{type: from_file,
  path, format?}` shape.
"""
struct Assertion
    variable::String
    time::Float64
    expected::Float64
    tolerance::Union{Tolerance,Nothing}
    coords::Union{Dict{String,Float64},Nothing}
    reduce::Union{String,Nothing}
    reference::Any

    function Assertion(variable::AbstractString, time::Real, expected::Real;
                       tolerance=nothing,
                       coords=nothing,
                       reduce=nothing,
                       reference=nothing)
        if coords !== nothing && reduce !== nothing
            throw(ArgumentError("Assertion: `coords` and `reduce` are mutually exclusive"))
        end
        if reduce !== nothing && (reduce == "L2_error" || reduce == "Linf_error") &&
                reference === nothing
            throw(ArgumentError("Assertion: `reduce=$(reduce)` requires `reference`"))
        end
        if reference !== nothing && reduce !== nothing &&
                !(reduce in ("L2_error", "Linf_error"))
            throw(ArgumentError("Assertion: `reference` is only meaningful for error-norm reductions"))
        end
        coords_typed = coords === nothing ? nothing :
            Dict{String,Float64}(string(k) => Float64(v) for (k, v) in coords)
        reduce_typed = _maybe(String, reduce)
        return new(String(variable), Float64(time), Float64(expected),
                   tolerance, coords_typed, reduce_typed, reference)
    end
end

"""
    Test(id, time_span, assertions; description, initial_conditions, parameter_overrides, tolerance)

Inline validation test for a Model (schema gt-cc1). Defines the run
configuration — initial conditions, parameter overrides, simulation time
span — and a list of scalar assertions that must hold.
"""
struct Test
    id::String
    description::Union{String,Nothing}
    initial_conditions::Dict{String,Float64}
    parameter_overrides::Dict{String,Float64}
    time_span::TimeSpan
    tolerance::Union{Tolerance,Nothing}
    assertions::Vector{Assertion}
    # Raw §9.7.2 import entries injected into the ENCLOSING component's scope
    # for THIS test's run only (esm-spec §9.7.10 form C / §6.6.6): the
    # discretization a discretization-agnostic PDE leaf is lowered under in the
    # per-test ephemeral build. Authored per-run config — a peer of
    # `parameter_overrides` — so unlike a component's own imports it DOES
    # survive `parse → emit`. Empty for a non-PDE / agnostic-free test.
    expression_template_imports::Vector{Any}

    function Test(id::AbstractString, time_span::TimeSpan, assertions::Vector{Assertion};
                  description=nothing,
                  initial_conditions=Dict{String,Float64}(),
                  parameter_overrides=Dict{String,Float64}(),
                  tolerance=nothing,
                  expression_template_imports=Any[])
        return new(String(id), description,
                   Dict{String,Float64}(string(k) => Float64(v) for (k, v) in initial_conditions),
                   Dict{String,Float64}(string(k) => Float64(v) for (k, v) in parameter_overrides),
                   time_span, tolerance, assertions,
                   Vector{Any}(expression_template_imports))
    end
end

"""
    IndexSet(kind; size, members, of, offsets, values, from_faq)

A declared index set in the document-scoped `index_sets` registry
(RFC semiring-faq-unified-ir §5.2). Unifies ESM grid dims and ESI categorical
dims under one shape. `kind` is one of:

- `"interval"`   — dense integer axis; `size` gives its length.
- `"categorical"`— enumerated members; `members` is the ordered member list.
- `"ragged"`     — data-dependent inner set (e.g. the edges of a cell); `of`
  names the parent index set(s), `offsets` the length/CSR-offset backing factor,
  and `values` the member-id backing factor (both keyed factors, §5.4).
- `"derived"`    — materialized from another FAQ (§5.5); `from_faq` is its node
  id. Not evaluated by the tree-walk evaluator in M1.
"""
struct IndexSet
    kind::String
    size::Union{Int,Nothing}
    members::Union{Vector{String},Nothing}
    of::Union{Vector{String},Nothing}
    offsets::Union{String,Nothing}
    values::Union{String,Nothing}
    from_faq::Union{String,Nothing}
    # The original, un-stringified categorical members, retained ONLY when at
    # least one member is non-string (float / null / boolean / integer). Lets the
    # join-key validator (RFC §5.3) reject keys whose equality is not portable
    # across bindings — float and null members — which `members` (always coerced
    # to `String`) can no longer distinguish. `nothing` for ordinary string-only
    # sets, so they stay byte-identical to before.
    members_raw::Union{Vector{Any},Nothing}

    IndexSet(kind::AbstractString; size=nothing, members=nothing, of=nothing,
             offsets=nothing, values=nothing, from_faq=nothing, members_raw=nothing) =
        new(String(kind), size, members, of, offsets, values, from_faq, members_raw)
end

"""
    IndexSetRef(from; of)

A reference to a declared `IndexSet`, used as a `ranges[*]` value in place of a
dense `[lo, hi]` / `[lo, step, hi]` integer tuple (RFC §5.2). `from` is the
registry key; `of` lists the parent index *variable* names for a ragged /
dependent inner set (e.g. `of=["i"]` for the edges of cell `i`).
"""
struct IndexSetRef
    from::String
    of::Vector{String}

    IndexSetRef(from::AbstractString; of::AbstractVector=String[]) =
        new(String(from), String[String(x) for x in of])
end

"""
    SubsystemRef(ref::String)
    SubsystemRef(ref::String, bindings::Dict{String,Int})

Unresolved reference to an external ESM file used as a subsystem (esm-spec §4.7).
Produced by `coerce_model` for a `{"ref": "..."}` subsystem entry and replaced
in place by `resolve_subsystem_refs!` with the loaded `Model` or `DataLoader`.
A `SubsystemRef` only survives parsing when references are not resolved (e.g.
`load(::IO)` without a base path); `load(::String)` always resolves them.
`bindings` closes the referenced document's open metaparameters at this edge
(esm-spec §9.7.6 binding site 3 — e.g. a convergence wrapper instantiating a
problem file at a given size). `expression_template_imports` are the raw
§9.7.2 import entries injected into the REFERENCED component's own template
scope (esm-spec §9.7.10 form A — assembler-chosen discretization for a mounted
PDE leaf); they are threaded into the referenced document's load and consumed by
the §9.6.3 fixpoint, so a resolved subsystem round-trips as the lowered inline
component and the field does not survive `parse → emit`.
"""
struct SubsystemRef
    ref::String
    bindings::Dict{String,Int}
    expression_template_imports::Vector{Any}
end

SubsystemRef(ref::AbstractString, bindings::AbstractDict) =
    SubsystemRef(String(ref),
                 Dict{String,Int}(string(k) => Int(v) for (k, v) in bindings), Any[])
SubsystemRef(ref::AbstractString) =
    SubsystemRef(String(ref), Dict{String,Int}(), Any[])

"""
    Model

ODE-based model component containing variables, equations, and optional subsystems.
Supports hierarchical composition through subsystems. A subsystem value is a
child `Model`, a pure-I/O `DataLoader` (RFC pure-io-data-loaders §4.3), or — only
until references are resolved — a `SubsystemRef`; the field is therefore typed
`Dict{String,Any}` (DataLoader is declared later in this file, so a concrete
`Union` field type is not available at this point).
"""
struct Model
    variables::Dict{String,ModelVariable}
    equations::Vector{Equation}
    discrete_events::Vector{DiscreteEvent}
    continuous_events::Vector{ContinuousEvent}
    subsystems::Dict{String,Any}
    tolerance::Union{Tolerance,Nothing}
    tests::Vector{Test}
    initialization_equations::Vector{Equation}
    guesses::Dict{String,Union{Float64,Expr}}
    system_kind::Union{String,Nothing}

    # Primary constructor with separate event arrays
    Model(variables::AbstractDict{String,ModelVariable}, equations::Vector{Equation},
          discrete_events::Vector{DiscreteEvent}, continuous_events::Vector{ContinuousEvent},
          subsystems::AbstractDict{String};
          tolerance=nothing, tests=Test[],
          initialization_equations=Equation[],
          guesses=Dict{String,Union{Float64,Expr}}(),
          system_kind=nothing) =
        new(Dict{String,ModelVariable}(variables), equations,
            discrete_events, continuous_events, Dict{String,Any}(subsystems),
            tolerance, tests,
            initialization_equations, guesses, system_kind)

    # Convenience constructor with optional events and subsystems.
    # Accepts legacy `events=` kwarg as a mixed Vector{EventType} and splits
    # it into discrete/continuous. `events` takes precedence over the typed
    # `discrete_events`/`continuous_events` kwargs if both are supplied.
    function Model(variables::AbstractDict{String,ModelVariable}, equations::Vector{Equation};
                   discrete_events=DiscreteEvent[],
                   continuous_events=ContinuousEvent[],
                   events=nothing,
                   subsystems=Dict{String,Any}(),
                   tolerance=nothing,
                   tests=Test[],
                   initialization_equations=Equation[],
                   guesses=Dict{String,Union{Float64,Expr}}(),
                   system_kind=nothing)
        if events !== nothing
            discrete_events = DiscreteEvent[]
            continuous_events = ContinuousEvent[]
            for event in events
                if event isa DiscreteEvent
                    push!(discrete_events, event)
                elseif event isa ContinuousEvent
                    push!(continuous_events, event)
                else
                    throw(ArgumentError("Unknown event type: $(typeof(event))"))
                end
            end
        end
        return new(Dict{String,ModelVariable}(variables), equations,
                   discrete_events, continuous_events, Dict{String,Any}(subsystems),
                   tolerance, tests,
                   initialization_equations, guesses, system_kind)
    end
end

"""
    create_model_with_mixed_events(variables, equations, events, subsystems) -> Model

Helper function to create Model from mixed events vector for backwards compatibility.
"""
function create_model_with_mixed_events(variables::Dict{String,ModelVariable},
                                      equations::Vector{Equation},
                                      events::Vector{EventType},
                                      subsystems::Dict{String,Model}=Dict{String,Model}())
    # Split mixed events vector into separate types
    discrete = DiscreteEvent[]
    continuous = ContinuousEvent[]

    for event in events
        if isa(event, DiscreteEvent)
            push!(discrete, event)
        elseif isa(event, ContinuousEvent)
            push!(continuous, event)
        else
            throw(ArgumentError("Unknown event type: $(typeof(event))"))
        end
    end

    return Model(variables, equations, discrete, continuous, subsystems)
end

"""
    Species

Chemical species definition with name and optional properties.
"""
struct Species
    name::String
    units::Union{String,Nothing}
    default::Union{Float64,Nothing}
    description::Union{String,Nothing}
    default_units::Union{String,Nothing}
    constant::Union{Bool,Nothing}

    # Constructor with optional parameters
    Species(name::String; units=nothing, default=nothing, description=nothing, default_units=nothing, constant=nothing) =
        new(name, units, default, description, default_units, constant)
end

"""
    Parameter

Model parameter with name, default value, and optional metadata.
"""
struct Parameter
    name::String
    default::Float64
    description::Union{String,Nothing}
    units::Union{String,Nothing}
    default_units::Union{String,Nothing}

    # Constructor with optional parameters
    Parameter(name::String, default::Float64; description=nothing, units=nothing, default_units=nothing) =
        new(name, default, description, units, default_units)
end



# ========================================
# 6. Data and Operator Types
# ========================================

"""
    Reference

Academic citation or data source reference.
"""
struct Reference
    doi::Union{String,Nothing}
    citation::Union{String,Nothing}
    url::Union{String,Nothing}
    notes::Union{String,Nothing}

    # Constructor with all optional parameters
    Reference(; doi=nothing, citation=nothing, url=nothing, notes=nothing) =
        new(doi, citation, url, notes)
end

"""
    abstract type CouplingEntry end

Abstract base type for coupling entries that connect model components.
"""
abstract type CouplingEntry end

"""
    CouplingOperatorCompose <: CouplingEntry

Match LHS time derivatives and add RHS terms together.
"""
struct CouplingOperatorCompose <: CouplingEntry
    systems::Vector{String}
    translate::Union{Dict{String,Any},Nothing}
    description::Union{String,Nothing}
    lifting::Union{String,Nothing}

    CouplingOperatorCompose(systems::Vector{String}; translate=nothing, description=nothing, lifting=nothing) =
        new(systems, translate, description, lifting)
end

"""
    CouplingCouple <: CouplingEntry

Bi-directional coupling via connector equations.
"""
struct CouplingCouple <: CouplingEntry
    systems::Vector{String}
    connector::Dict{String,Any}
    description::Union{String,Nothing}
    lifting::Union{String,Nothing}

    CouplingCouple(systems::Vector{String}, connector::Dict{String,Any}; description=nothing, lifting=nothing) =
        new(systems, connector, description, lifting)
end

"""
    CouplingVariableMap <: CouplingEntry

Replace a parameter in one system with a variable from another, or — when
`transform` is an `Expr` operator node rather than one of the named transform
strings — with a derived value computed from it (esm-spec §10.4: the target
parameter becomes an observed whose defining expression is the transform,
evaluated in the flattened coupled system's scope; §8.6/§10.5 regridding form).
An `Expr` transform takes no `factor` (fold scaling into the expression).
"""
struct CouplingVariableMap <: CouplingEntry
    from::String
    to::String
    transform::Union{String,Expr}
    factor::Union{Float64,Nothing}
    description::Union{String,Nothing}
    lifting::Union{String,Nothing}

    function CouplingVariableMap(from::String, to::String, transform::Union{String,Expr};
                                 factor=nothing, description=nothing, lifting=nothing)
        if transform isa Expr && factor !== nothing
            throw(ArgumentError("variable_map: an expression `transform` takes no `factor` (fold the scaling into the expression)"))
        end
        new(from, to, transform, factor, description, lifting)
    end
end

"""
    CouplingOperatorApply <: CouplingEntry

Register an Operator to run during simulation.
"""
struct CouplingOperatorApply <: CouplingEntry
    operator::String
    description::Union{String,Nothing}

    CouplingOperatorApply(operator::String; description=nothing) =
        new(operator, description)
end

"""
    CouplingCallback <: CouplingEntry

Register a callback for simulation events.
"""
struct CouplingCallback <: CouplingEntry
    callback_id::String
    config::Union{Dict{String,Any},Nothing}
    description::Union{String,Nothing}

    CouplingCallback(callback_id::String; config=nothing, description=nothing) =
        new(callback_id, config, description)
end

"""
    CouplingEvent <: CouplingEntry

Cross-system event involving variables from multiple coupled systems.
"""
struct CouplingEvent <: CouplingEntry
    event_type::String
    conditions::Union{Vector{Expr},Nothing}
    trigger::Union{DiscreteEventTrigger,Nothing}
    affects::Vector{AffectEquation}
    affect_neg::Union{Vector{AffectEquation},Nothing}
    discrete_parameters::Union{Vector{String},Nothing}
    root_find::Union{String,Nothing}
    reinitialize::Union{Bool,Nothing}
    description::Union{String,Nothing}

    CouplingEvent(event_type::String, affects::Vector{AffectEquation};
                  conditions=nothing, trigger=nothing, affect_neg=nothing,
                  discrete_parameters=nothing, root_find=nothing, reinitialize=nothing, description=nothing) =
        new(event_type, conditions, trigger, affects, affect_neg, discrete_parameters, root_find, reinitialize, description)
end

"""
    CouplingImport <: CouplingEntry

Reuse of a coupling-library file (esm-spec §10.9, §10.10). Names a library by
`ref` and binds each of the library's declared roles to a component in the
assembly via `bind` (role name → a top-level `models`/`reaction_systems`/
`data_loaders` key, or a dotted `Parent.Child` subsystem path). At flatten the
import expands into concrete `variable_map`/`couple`/`operator_compose`/`event`
edges by substituting the bound actual for every role-named top-level segment
(`expand_coupling_imports`); the entry itself round-trips intact.
"""
struct CouplingImport <: CouplingEntry
    ref::String
    bind::Dict{String,String}
    description::Union{String,Nothing}

    CouplingImport(ref::String, bind::AbstractDict=Dict{String,String}(); description=nothing) =
        new(ref, Dict{String,String}(string(k) => string(v) for (k, v) in pairs(bind)), description)
end

"""
    DataLoaderSource

File discovery configuration for a DataLoader. Describes how to locate data
files at runtime via a URL template with `{date:<strftime>}`, `{var}`,
`{sector}`, `{species}`, and custom substitutions. Optional `mirrors` list
gives ordered fallback templates.
"""
struct DataLoaderSource
    url_template::String
    mirrors::Union{Vector{String},Nothing}

    DataLoaderSource(url_template::String; mirrors=nothing) =
        new(url_template, mirrors)
end

"""
    DataLoaderTemporal

Temporal coverage and record layout for a DataLoader.
"""
struct DataLoaderTemporal
    start::Union{String,Nothing}
    stop::Union{String,Nothing}           # field name "end" in JSON (reserved word in Julia)
    file_period::Union{String,Nothing}
    frequency::Union{String,Nothing}
    records_per_file::Union{Int,String,Nothing}  # integer or "auto"
    time_variable::Union{String,Nothing}

    DataLoaderTemporal(; start=nothing, stop=nothing, file_period=nothing,
                       frequency=nothing, records_per_file=nothing,
                       time_variable=nothing) =
        new(start, stop, file_period, frequency, records_per_file, time_variable)
end

"""
    DataLoaderVariable

A variable exposed by a DataLoader, mapped from a source-file variable.
`unit_conversion` may be a numeric factor or an Expression AST.
"""
struct DataLoaderVariable
    file_variable::String
    units::String
    unit_conversion::Union{Float64,Expr,Nothing}
    description::Union{String,Nothing}
    reference::Union{Reference,Nothing}

    DataLoaderVariable(file_variable::String, units::String;
                       unit_conversion=nothing,
                       description=nothing,
                       reference=nothing) =
        new(file_variable, units, unit_conversion, description, reference)
end

"""
    DataLoaderDeterminism

Reproducibility contract a loader advertises to bindings (esm-spec §8.9.2).
A binding that cannot honor the declared endian / float_format / integer_width
MUST reject the file at load.

Fields (all optional):
- `endian`: "little" | "big"
- `float_format`: "ieee754_single" | "ieee754_double"
- `integer_width`: 32 | 64
"""
struct DataLoaderDeterminism
    endian::Union{String,Nothing}
    float_format::Union{String,Nothing}
    integer_width::Union{Int,Nothing}

    DataLoaderDeterminism(; endian=nothing, float_format=nothing, integer_width=nothing) =
        new(endian, float_format, integer_width)
end

"""
    DataLoader

Generic, runtime-agnostic description of an external data source. Pure I/O:
carries enough structural information to locate files, map timestamps to
files, and describe the data's native grid and variable semantics — rather
than pointing at a runtime handler or performing any regridding.
Authentication and algorithm-specific tuning are runtime-only and not part
of the schema.

Fields:
- `kind`: "grid" | "points" | "static" (structural kind; scientific role goes in `metadata.tags`)
- `source`: `DataLoaderSource` with url_template + optional mirrors
- `temporal`: optional `DataLoaderTemporal`
- `determinism`: optional `DataLoaderDeterminism` (esm-spec §8.9.2)
- `variables`: schema-level variable name → `DataLoaderVariable` (minimum one)
- `reference`: optional academic/data-source citation
- `metadata`: optional free-form map (conventionally carries a `tags` array)
"""
struct DataLoader
    kind::String
    source::DataLoaderSource
    temporal::Union{DataLoaderTemporal,Nothing}
    determinism::Union{DataLoaderDeterminism,Nothing}
    variables::Dict{String,DataLoaderVariable}
    reference::Union{Reference,Nothing}
    metadata::Union{Dict{String,Any},Nothing}

    DataLoader(kind::String, source::DataLoaderSource,
               variables::Dict{String,DataLoaderVariable};
               temporal=nothing,
               determinism=nothing,
               reference=nothing,
               metadata=nothing) =
        new(kind, source, temporal, determinism,
            variables, reference, metadata)
end

"""
    Operator

Registered runtime operator (by reference).
Platform-specific computational kernels and operations.
"""
struct Operator
    operator_id::String
    reference::Union{Reference,Nothing}
    config::Union{Dict{String,Any},Nothing}
    needed_vars::Vector{String}
    modifies::Union{Vector{String},Nothing}
    description::Union{String,Nothing}

    # Constructor with optional parameters
    Operator(operator_id::String, needed_vars::Vector{String};
             reference=nothing,
             config=nothing,
             modifies=nothing,
             description=nothing) =
        new(operator_id, reference, config, needed_vars, modifies, description)
end

# ========================================
# 7. System Configuration Types
# ========================================

"""
    RegisteredFunctionSignature

Calling convention for a [`RegisteredFunction`](@ref). See esm-spec §9.2.
"""
struct RegisteredFunctionSignature
    arg_count::Int
    arg_types::Union{Vector{String},Nothing}
    return_type::Union{String,Nothing}

    RegisteredFunctionSignature(arg_count::Int;
                                arg_types=nothing,
                                return_type=nothing) =
        new(arg_count, arg_types, return_type)
end

"""
    RegisteredFunction

A named pure function that may be invoked inside expressions via the `call`
op (see esm-spec §4.4 / §9.2). The serialized entry declares the calling
contract only; the concrete implementation is supplied by the runtime through
a handler registry (in Julia, via `@register_symbolic`).
"""
struct RegisteredFunction
    id::String
    signature::RegisteredFunctionSignature
    units::Union{String,Nothing}
    arg_units::Union{Vector{Union{String,Nothing}},Nothing}
    description::Union{String,Nothing}
    references::Vector{Reference}
    config::Union{Dict{String,Any},Nothing}

    RegisteredFunction(id::String, signature::RegisteredFunctionSignature;
                       units=nothing,
                       arg_units=nothing,
                       description=nothing,
                       references=Reference[],
                       config=nothing) =
        new(id, signature, units, arg_units, description, references, config)
end

"""
    Domain

Spatial and temporal domain specification.
"""
struct Domain
    temporal::Union{Dict{String,Any},Nothing}

    # Constructor with optional parameters
    Domain(; temporal=nothing) = new(temporal)
end

"""
    StoichiometryEntry

A species with its stoichiometric coefficient in a reaction.
"""
struct StoichiometryEntry
    species::String
    stoichiometry::Float64

    function StoichiometryEntry(species::String, stoichiometry::Real)
        if !isfinite(stoichiometry)
            throw(ArgumentError(
                "StoichiometryEntry: stoichiometry must be finite (got $(stoichiometry)) for species '$(species)'"
            ))
        end
        if stoichiometry <= 0
            throw(ArgumentError(
                "StoichiometryEntry: stoichiometry must be positive (got $(stoichiometry)) for species '$(species)'"
            ))
        end
        return new(species, Float64(stoichiometry))
    end
end

"""
    Reaction

Chemical reaction with substrates, products, and rate expression.
"""
struct Reaction
    id::String
    name::Union{String,Nothing}
    substrates::Union{Vector{StoichiometryEntry},Nothing}  # null for source reactions (∅ → X)
    products::Union{Vector{StoichiometryEntry},Nothing}    # null for sink reactions (X → ∅)
    rate::Expr
    reference::Union{Reference,Nothing}

    # Constructor with optional parameters
    Reaction(id::String, substrates::Union{Vector{StoichiometryEntry},Nothing},
             products::Union{Vector{StoichiometryEntry},Nothing}, rate::Expr;
             name=nothing, reference=nothing) =
        new(id, name, substrates, products, rate, reference)
end

"""
    ReactionSystem

Collection of chemical reactions with associated species, supporting hierarchical composition.
"""
struct ReactionSystem
    species::Vector{Species}
    reactions::Vector{Reaction}
    parameters::Vector{Parameter}
    subsystems::Dict{String,ReactionSystem}
    tolerance::Union{Tolerance,Nothing}
    tests::Vector{Test}

    # Constructor with optional parameters and subsystems
    ReactionSystem(species::Vector{Species}, reactions::Vector{Reaction};
                   parameters=Parameter[], subsystems=Dict{String,ReactionSystem}(),
                   tolerance=nothing, tests=Test[]) =
        new(species, reactions, parameters, subsystems, tolerance, tests)
end

"""
    Metadata

Authorship, provenance, and description metadata.
"""
struct Metadata
    name::String
    description::Union{String,Nothing}
    authors::Vector{String}
    license::Union{String,Nothing}
    created::Union{String,Nothing}  # ISO 8601 timestamp
    modified::Union{String,Nothing} # ISO 8601 timestamp
    tags::Vector{String}
    references::Vector{Reference}

    # Constructor with optional parameters
    Metadata(name::String;
             description=nothing,
             authors=String[],
             license=nothing,
             created=nothing,
             modified=nothing,
             tags=String[],
             references=Reference[]) =
        new(name, description, authors, license, created, modified, tags, references)
end

"""
    FunctionTableAxis

A single named axis inside a [`FunctionTable`](@ref) (esm-spec §9.5).
`values` MUST be strictly-increasing finite floats with at least 2 entries
(mirrors the §9.2 interp.linear / interp.bilinear axis contract). `units`
is advisory only in v0.4.0.
"""
struct FunctionTableAxis
    name::String
    values::Vector{Float64}
    units::Union{String,Nothing}
    FunctionTableAxis(name::AbstractString, values::AbstractVector;
                      units=nothing) =
        new(String(name), Vector{Float64}(values), units)
end

"""
    FunctionTable

A sampled function table referenced by `table_lookup` AST op nodes
(esm-spec §9.5, v0.4.0). Tables are syntactic sugar over §9.2's
`interp.linear` / `interp.bilinear` / `index` — a `table_lookup` query
MUST be bit-equivalent to the equivalent inline-`const` lookup. Shape of
`data` is `[len(outputs), len(axes[0].values), len(axes[1].values), ...]`
when `outputs` is non-`nothing`; `[len(axes[0].values), ...]` otherwise.
"""
struct FunctionTable
    axes::Vector{FunctionTableAxis}
    data::Any  # Nested-array literal of finite numbers
    description::Union{String,Nothing}
    interpolation::Union{String,Nothing}  # "linear" | "bilinear" | "nearest"
    out_of_bounds::Union{String,Nothing}  # "clamp" | "error"
    outputs::Union{Vector{String},Nothing}
    shape::Union{Vector{Int},Nothing}
    schema_version::Union{String,Nothing}
    FunctionTable(axes::AbstractVector{FunctionTableAxis}, data;
                  description=nothing, interpolation=nothing,
                  out_of_bounds=nothing, outputs=nothing,
                  shape=nothing, schema_version=nothing) =
        new(Vector{FunctionTableAxis}(axes), data, description,
            interpolation, out_of_bounds, outputs, shape, schema_version)
end

"""
    EsmFile

Main ESM file structure containing all components.
"""
struct EsmFile
    esm::String  # Version string
    metadata::Metadata
    models::Union{Dict{String,Model},Nothing}
    reaction_systems::Union{Dict{String,ReactionSystem},Nothing}
    data_loaders::Union{Dict{String,DataLoader},Nothing}
    operators::Union{Dict{String,Operator},Nothing}
    registered_functions::Union{Dict{String,RegisteredFunction},Nothing}
    coupling::Vector{CouplingEntry}
    # The single temporal domain shared by every component in the document
    # (esm-spec v0.8.0: top-level `domain`, not a map of named domains). A
    # document has at most one Domain; 0-D models simply have scalar-shaped
    # variables and spatial models are shaped over index sets.
    domain::Union{Domain,Nothing}
    # File-local enum mappings used by the `enum` AST op (esm-spec §9.3).
    # Keys are enum names; each value maps a symbol → positive integer.
    # `enum`-op nodes are lowered to `const`-int nodes at load time, so the
    # in-memory expression tree never carries enum strings.
    enums::Union{Dict{String,Dict{String,Int}},Nothing}
    # Component-scoped sampled function tables (esm-spec §9.5, v0.4.0).
    # Keys are table ids; values are FunctionTable entries referenced by
    # table_lookup AST nodes.
    function_tables::Union{Dict{String,FunctionTable},Nothing}
    # Document-scoped index-set registry (RFC semiring-faq-unified-ir §5.2;
    # esm-spec v0.8.0). A single registry, sibling of `models`/`domain`, shared
    # by every component: `ranges[*]` `{from: <name>}` references, array-variable
    # `shape`s, and derived-set `from_faq` edges resolve against it. Empty when
    # the document declares none.
    index_sets::Dict{String,IndexSet}

    # Constructor with optional parameters
    EsmFile(esm::String, metadata::Metadata;
            models=nothing,
            reaction_systems=nothing,
            data_loaders=nothing,
            operators=nothing,
            registered_functions=nothing,
            coupling=CouplingEntry[],
            domain=nothing,
            enums=nothing,
            function_tables=nothing,
            index_sets=Dict{String,IndexSet}()) =
        new(esm, metadata, models, reaction_systems, data_loaders,
            operators, registered_functions,
            coupling, domain, enums, function_tables,
            Dict{String,IndexSet}(index_sets))
end

# ========================================
# 8. Reference Resolution System
# ========================================

"""
    QualifiedReferenceError

Exception thrown when qualified reference resolution fails.
Contains detailed error information.
"""
struct QualifiedReferenceError <: Exception
    message::String
    reference::String
    path::Vector{String}
end

"""
    ReferenceResolution

Result of qualified reference resolution containing the resolved variable
and its location information.
"""
struct ReferenceResolution
    variable_name::String
    system_path::Vector{String}
    system_type::Symbol  # :model, :reaction_system, :data_loader, :operator
    resolved_system::Union{Model,ReactionSystem,DataLoader,Operator}
end

"""
    resolve_qualified_reference(esm_file::EsmFile, reference::String) -> ReferenceResolution

Resolve a qualified reference string using hierarchical dot notation.

The reference string is split on dots to produce segments [s₁, s₂, …, sₙ].
The final segment sₙ is the variable name. The preceding segments [s₁, …, sₙ₋₁]
form a path through the subsystem hierarchy.

## Algorithm
1. Split reference on "." to get segments
2. First segment must match a top-level system (models, reaction_systems, data_loaders, operators)
3. Each subsequent segment must match a key in the parent system's subsystems map
4. Final segment is the variable name to resolve

## Examples
- `"SuperFast.O3"` → Variable `O3` in top-level model `SuperFast`
- `"SuperFast.GasPhase.O3"` → Variable `O3` in subsystem `GasPhase` of model `SuperFast`
- `"Atmosphere.Chemistry.FastChem.NO2"` → Variable `NO2` in nested subsystems

## Throws
- `QualifiedReferenceError` if reference cannot be resolved
"""
function resolve_qualified_reference(esm_file::EsmFile, reference::String)::ReferenceResolution
    if isempty(reference)
        throw(QualifiedReferenceError("Empty reference string", reference, String[]))
    end

    segments = split(reference, ".")
    if length(segments) < 1
        throw(QualifiedReferenceError("Invalid reference format", reference, String[]))
    end

    # Extract variable name (last segment) and system path
    variable_name = String(segments[end])
    system_path = String.(segments[1:end-1])

    # Handle bare references (no dot)
    if length(system_path) == 0
        throw(QualifiedReferenceError("Bare references not supported without system context", reference, String[]))
    end

    # Resolve the system path
    top_level_name = system_path[1]
    remaining_path = system_path[2:end]

    # Find top-level system
    system, system_type = find_top_level_system(esm_file, top_level_name)
    if system === nothing
        throw(QualifiedReferenceError("Top-level system '$(top_level_name)' not found", reference, system_path[1:1]))
    end

    # Traverse subsystem hierarchy
    current_system = system
    traversed_path = [top_level_name]

    for segment in remaining_path
        push!(traversed_path, segment)
        current_system = find_subsystem(current_system, segment)
        if current_system === nothing
            throw(QualifiedReferenceError("Subsystem '$(segment)' not found in path", reference, traversed_path))
        end
    end

    # Validate that the variable exists in the final system
    if !variable_exists_in_system(current_system, variable_name)
        throw(QualifiedReferenceError("Variable '$(variable_name)' not found in system", reference, system_path))
    end

    return ReferenceResolution(variable_name, system_path, system_type, current_system)
end

"""
    find_top_level_system(esm_file::EsmFile, name::String) -> (Union{Model,ReactionSystem,DataLoader,Operator,Nothing}, Symbol)

Find a top-level system by name in models, reaction_systems, data_loaders, or operators.
Returns the system and its type, or (nothing, :none) if not found.
"""
function find_top_level_system(esm_file::EsmFile, name::String)
    # Check models
    if esm_file.models !== nothing && haskey(esm_file.models, name)
        return (esm_file.models[name], :model)
    end

    # Check reaction_systems
    if esm_file.reaction_systems !== nothing && haskey(esm_file.reaction_systems, name)
        return (esm_file.reaction_systems[name], :reaction_system)
    end

    # Check data_loaders
    if esm_file.data_loaders !== nothing && haskey(esm_file.data_loaders, name)
        return (esm_file.data_loaders[name], :data_loader)
    end

    # Check operators
    if esm_file.operators !== nothing && haskey(esm_file.operators, name)
        return (esm_file.operators[name], :operator)
    end

    return (nothing, :none)
end

"""
    find_subsystem(system::Union{Model,ReactionSystem}, name::String) -> Union{Model,ReactionSystem,Nothing}

Find a subsystem by name within a Model or ReactionSystem.
Returns the subsystem or nothing if not found.
"""
function find_subsystem(system::Model, name::String)::Union{Model,Nothing}
    return get(system.subsystems, name, nothing)
end

function find_subsystem(system::ReactionSystem, name::String)::Union{ReactionSystem,Nothing}
    return get(system.subsystems, name, nothing)
end

function find_subsystem(system::Union{DataLoader,Operator}, name::String)
    # Data loaders and operators don't have subsystems
    return nothing
end

"""
    variable_exists_in_system(system, variable_name::String) -> Bool

Check if a variable exists in the given system.
"""
function variable_exists_in_system(system::Model, variable_name::String)::Bool
    return haskey(system.variables, variable_name)
end

function variable_exists_in_system(system::ReactionSystem, variable_name::String)::Bool
    # Check species
    for species in system.species
        if species.name == variable_name
            return true
        end
    end

    # Check parameters
    for param in system.parameters
        if param.name == variable_name
            return true
        end
    end

    return false
end

function variable_exists_in_system(system::Union{DataLoader,Operator}, variable_name::String)::Bool
    # Data loaders and operators are referenced by type/name, not variables
    return false
end

"""
    validate_reference_syntax(reference::String) -> Bool

Validate that a reference string follows proper dot notation syntax.
"""
function validate_reference_syntax(reference::String)::Bool
    if isempty(reference)
        return false
    end

    # No leading or trailing dots
    if startswith(reference, ".") || endswith(reference, ".")
        return false
    end

    # No consecutive dots
    if occursin("..", reference)
        return false
    end

    # All segments should be valid identifiers
    segments = split(reference, ".")
    for segment in segments
        if isempty(segment) || !is_valid_identifier(String(segment))
            return false
        end
    end

    return true
end

"""
    is_valid_identifier(name::String) -> Bool

Check if a string is a valid identifier (letters, numbers, underscores, no leading digit).
"""
function is_valid_identifier(name::String)::Bool
    if isempty(name)
        return false
    end

    # Must start with letter or underscore. Iterate by character (not byte
    # index): `name[2:end]` byte-indexes and throws `StringIndexError` when the
    # identifier starts with a multi-byte (non-ASCII) letter.
    first_char = first(name)
    if !isletter(first_char) && first_char != '_'
        return false
    end

    # Rest can be letters, digits, or underscores
    for c in Iterators.drop(name, 1)
        if !isletter(c) && !isdigit(c) && c != '_'
            return false
        end
    end

    return true
end

# ========================================
# 9. Backward Compatibility Helpers
# ========================================

"""
    dict_to_stoichiometry_entries(dict::AbstractDict{String,<:Real}) -> Vector{StoichiometryEntry}

Convert old-style species→coefficient dict format to new StoichiometryEntry vector format.
Accepts any numeric coefficient type (`Int`, `Float64`, …) — fractional stoichiometries
are supported by the v0.2.x schema.
"""
function dict_to_stoichiometry_entries(dict::AbstractDict{String,<:Real})::Vector{StoichiometryEntry}
    return [StoichiometryEntry(species, stoichiometry) for (species, stoichiometry) in dict]
end

"""
    stoichiometry_entries_to_dict(entries::Vector{StoichiometryEntry}) -> Dict{String,Float64}

Convert new StoichiometryEntry vector format to species→coefficient dict.
"""
function stoichiometry_entries_to_dict(entries::Vector{StoichiometryEntry})::Dict{String,Float64}
    return Dict(entry.species => entry.stoichiometry for entry in entries)
end

# Deterministic 64-bit FNV-1a hash. Used for content-derived ids; unlike
# `Base.hash`, its value is stable across Julia versions and sessions.
function _fnv1a64(s::AbstractString)::UInt64
    h = 0xcbf29ce484222325
    for b in codeunits(s)
        h = (h ⊻ UInt64(b)) * 0x00000100000001b3
    end
    return h
end

# Render a JSON-compatible value (as produced by `serialize_expression`) to a
# deterministic string: object keys are emitted in sorted order, so the result
# depends only on content, never on Dict iteration order.
_stable_json(x::AbstractDict) =
    "{" * join(sort!([string(repr(String(string(k))), ":", _stable_json(v))
                      for (k, v) in pairs(x)]), ",") * "}"
_stable_json(x::AbstractVector) = "[" * join([_stable_json(v) for v in x], ",") * "]"
_stable_json(x::AbstractString) = repr(String(x))
_stable_json(x) = string(x)

"""
    Reaction(reactants::AbstractDict{String,<:Real}, products::AbstractDict{String,<:Real}, rate::Expr; reversible=false) -> Reaction

Legacy constructor for backward compatibility. Creates a reaction with an
auto-generated, content-derived id: the same reactants, products, and rate
always produce the same id (deterministic across sessions and Julia versions,
unlike `Base.hash`).
"""
function Reaction(reactants::AbstractDict{String,<:Real}, products::AbstractDict{String,<:Real}, rate::Expr; reversible=false)
    # Content-derived id: sorted species:stoichiometry lists plus a
    # deterministic rendering of the rate AST, digested with FNV-1a.
    fmt(d) = join(sort!(["$(k):$(Float64(v))" for (k, v) in d]), ",")
    content = fmt(reactants) * "=>" * fmt(products) * "|" *
              _stable_json(serialize_expression(rate))
    id = "reaction_" * string(_fnv1a64(content), base=16, pad=16)

    substrates = isempty(reactants) ? nothing : dict_to_stoichiometry_entries(reactants)
    products_vec = isempty(products) ? nothing : dict_to_stoichiometry_entries(products)

    return Reaction(id, substrates, products_vec, rate)
end

"""
    get_reactants_dict(reaction::Reaction) -> Dict{String,Float64}

Get reactants as dictionary for backward compatibility.
"""
function get_reactants_dict(reaction::Reaction)::Dict{String,Float64}
    # Use getfield to avoid infinite recursion
    substrates_field = getfield(reaction, :substrates)
    if substrates_field === nothing
        return Dict{String,Float64}()
    else
        return stoichiometry_entries_to_dict(substrates_field)
    end
end

"""
    get_products_dict(reaction::Reaction) -> Dict{String,Float64}

Get products as dictionary for backward compatibility.
"""
function get_products_dict(reaction::Reaction)::Dict{String,Float64}
    # Use getfield to avoid infinite recursion
    products_field = getfield(reaction, :products)
    if products_field === nothing
        return Dict{String,Float64}()
    else
        return stoichiometry_entries_to_dict(products_field)
    end
end

# Backward-compatibility property shim. `.reactants` / `.products` return the
# legacy Dict{String,Float64} view (NOT the ordered Vector{StoichiometryEntry}
# stored in the `substrates` / `products` fields — use
# `getfield(reaction, :products)` or `get_products_dict` explicitly for the
# raw field). The shim CANNOT be retired yet: Dict-style `.reactants` /
# `.products` access remains throughout src/codegen.jl, src/graph.jl,
# src/edit.jl, src/mock_systems.jl, and ext/EarthSciASTCatalystExt.jl
# (their migration to getfield-based ordered access is tracked separately).
Base.getproperty(reaction::Reaction, name::Symbol) = begin
    if name == :reactants
        return get_reactants_dict(reaction)
    elseif name == :products
        return get_products_dict(reaction)
    elseif name == :reversible
        return false  # Not supported in new schema
    else
        return getfield(reaction, name)
    end
end

# Advertise the compat properties. Defined on the INSTANCE (not the type
# object) so `propertynames(reaction)` actually reflects the getproperty
# override above. `:products` is already a field name, so only the two extra
# names are appended.
Base.propertynames(::Reaction, private::Bool=false) = begin
    names = fieldnames(Reaction)
    if private
        return (names..., :reactants, :reversible)
    else
        return names
    end
end

# Add backwards compatibility property access for Model.events
Base.getproperty(model::Model, name::Symbol) = begin
    if name == :events
        # Return combined events vector for backwards compatibility
        return vcat(Vector{EventType}(model.discrete_events), Vector{EventType}(model.continuous_events))
    else
        return getfield(model, name)
    end
end

# Defined on the INSTANCE (not the type object) so `propertynames(model)`
# reflects the getproperty override above.
Base.propertynames(::Model, private::Bool=false) = begin
    names = fieldnames(Model)
    if private
        return (names..., :events)
    else
        return names
    end
end