# Rule engine per discretization RFC §5.2.
#
# Pattern-match rewriting over the expression AST with typed pattern
# variables, guards, non-linear matching (via canonical equality), and a
# top-down fixed-point loop with per-pass sealing of rewritten subtrees.
#
# This module implements the core infrastructure required by RFC §13.1
# Step 1: load rules, apply them to expressions, produce canonicalized
# output. Scheme expansion (the `use:` rule form, §7.2.1) is NOT
# implemented here — only the `replacement` form is — and is tracked as
# follow-up work for Step 1b.

"""
    RuleEngineError(code::String, message::String)

Error raised by the rule engine. The `code` field carries one of the
RFC §5.2 / §11 stable error codes:

- `E_RULES_NOT_CONVERGED` — fixed-point loop exceeded `max_passes`.
- `E_UNREWRITTEN_PDE_OP` — a PDE op (`grad`, `div`, `laplacian`, `D`, `bc`)
  remained after rewriting on an equation not annotated `passthrough: true`.
- `E_SCHEME_MISMATCH` — rule/scheme `applies_to` disagreement (reserved for
  the `use:` rule form; not emitted in the MVP).
"""
struct RuleEngineError <: Exception
    code::String
    message::String
end

Base.showerror(io::IO, e::RuleEngineError) =
    print(io, "RuleEngineError(", e.code, "): ", e.message)

"""
    Guard(name::String, params::Dict{String,Any})

A single constraint on pattern-variable bindings. `name` is one of the
§5.2.4 closed-set guard names; `params` carries the fields from the JSON
guard object (`pvar`, `grid`, `location`, `rank`, …).
"""
struct Guard
    name::String
    params::Dict{String,Any}
end

"""
    RuleRegion

Spatial scope of a rule (RFC §5.2.7). Abstract type with four concrete
variants:

- [`RegionBoundary`](@ref) — `{kind:"boundary", side}`
- [`RegionMaskField`](@ref) — `{kind:"mask_field", field}`
- [`RegionIndexRange`](@ref) — `{kind:"index_range", axis, lo, hi}`

The legacy advisory string form is stored as a plain `String` on the
enclosing [`Rule`](@ref) and does not use this type.
"""
abstract type RuleRegion end

"""
    RegionBoundary(side::String)

`{kind:"boundary", side}` scope (RFC §5.2.7).
"""
struct RegionBoundary <: RuleRegion
    side::String
end

"""
    RegionMaskField(field::String)

`{kind:"mask_field", field}` scope. `field` names a boolean-valued mask
resolved at rewrite time against [`RuleContext.mask_fields`](@ref
RuleContext). The scope fires at a given query point iff
`ctx.mask_fields[field]` contains a truthy entry for that point.
"""
struct RegionMaskField <: RuleRegion
    field::String
end

"""
    RegionIndexRange(axis::String, lo::Int, hi::Int)

`{kind:"index_range", axis, lo, hi}` scope (inclusive bounds).
"""
struct RegionIndexRange <: RuleRegion
    axis::String
    lo::Int
    hi::Int
end

"""
    RuleBinding(kind::String, default::Union{Expr,Nothing}, description::Union{String,Nothing})

A single rule binding declaration (RFC §5.2.8). `kind` is one of
`"static"`, `"per_step"`, `"per_cell"`; `default` is an optional default
ExpressionNode; `description` is an optional authorial note. Loaders
preserve `RuleBinding` entries across parse/serialize roundtrips; the
rule engine itself does not consult them during pattern matching or
expansion.
"""
struct RuleBinding
    kind::String
    default::Union{Expr,Nothing}
    description::Union{String,Nothing}
end

RuleBinding(kind::AbstractString;
            default::Union{Expr,Nothing}=nothing,
            description::Union{Nothing,AbstractString}=nothing) =
    RuleBinding(String(kind), default, description === nothing ? nothing : String(description))

"""
    BoundaryPolicySpec(kind, degree, description)

A single per-axis boundary-policy entry (RFC §5.2.8 / §7). `kind` is one of
the closed-set tags listed in [`_BOUNDARY_POLICY_KIND_VALUES`](@ref); the
remaining fields are kind-specific:

- `degree::Union{Int,Nothing}` — `one_sided_extrapolation` / `extrapolate`:
  extrapolation order (0..3). `nothing` means default (linear).
- `description::Union{String,Nothing}` — free-form authorial note.

Stored verbatim; the rule engine does not branch on the policy.
"""
struct BoundaryPolicySpec
    kind::String
    degree::Union{Int,Nothing}
    description::Union{String,Nothing}
end

BoundaryPolicySpec(kind::AbstractString;
                   degree::Union{Int,Nothing}=nothing,
                   description::Union{Nothing,AbstractString}=nothing) =
    BoundaryPolicySpec(String(kind), degree,
                       description === nothing ? nothing : String(description))

"""
    BoundaryPolicy

Type alias for a rule's `boundary_policy` field (RFC §5.2.8 / §7). One of:

- `Nothing` — omitted; equivalent to `"periodic"`.
- `String` — uniform string form; one of the closed-set tags.
- `Dict{String,BoundaryPolicySpec}` — per-axis form; keys are axis names,
  values are [`BoundaryPolicySpec`](@ref) entries.
"""
const BoundaryPolicy = Union{String, Dict{String,BoundaryPolicySpec}, Nothing}

"""
    GhostWidth

Type alias for a rule's `ghost_width` field (RFC §5.2.8 / §7). One of:

- `Nothing` — omitted; equivalent to `0`.
- `Int` — uniform width across all axes.
- `Dict{String,Int}` — per-axis form; keys are axis names, values are
  non-negative integers.
"""
const GhostWidth = Union{Int, Dict{String,Int}, Nothing}

"""
    Rule(name, pattern, where, replacement, region, where_expr,
         boundary_policy, ghost_width, bindings)

A rewrite rule. `pattern` is an AST with `\$`-prefixed pattern variables;
`where` is a vector of [`Guard`](@ref) constraints applied at rule-
selection time; `replacement` is an AST over the pattern variables. The
MVP supports only the inline `replacement` form; `use:<scheme>` is
reserved for Step 1b.

`region` is the rule's spatial scope (RFC §5.2.7). It may be
`nothing`, a `String` (legacy advisory tag — no runtime effect), or a
concrete [`RuleRegion`](@ref) object (normative per-point scope).

`where_expr` is an optional per-query-point boolean predicate AST
(RFC §5.2.7). Mutually exclusive at the author level with guard-list
`where`; structurally distinguished by JSON shape at parse time.

`boundary_policy` declares behavior at domain edges (RFC §5.2.8 / §7). It is
one of: `nothing` (default — equivalent to `"periodic"`), a `String` from
the closed set (uniform across all axes), or a
`Dict{String,BoundaryPolicySpec}` (per-axis form, for axis-heterogeneous
policies). Stored verbatim; the rule engine does not branch on it.

`ghost_width` declares per-axis ghost-cell padding the rule's stencil
reaches (RFC §5.2.8 / §7). It is one of: `nothing` (default — 0), an
`Int` (uniform across all axes), or a `Dict{String,Int}` (per-axis form).
Stored verbatim.

`bindings` is an optional `Dict{String,RuleBinding}` declaring the
non-pattern-variable, non-canonical-index symbols the replacement may
reference and the rate at which the host runtime updates each
(RFC §5.2.8). Stored verbatim.
"""
struct Rule
    name::String
    pattern::Expr
    where::Vector{Guard}
    replacement::Union{Expr,Nothing}
    region::Union{String,RuleRegion,Nothing}
    where_expr::Union{Expr,Nothing}
    boundary_policy::BoundaryPolicy
    ghost_width::GhostWidth
    bindings::Union{Dict{String,RuleBinding},Nothing}
    # esm-j1u: when set, the rule's replacement is a §7 scheme name
    # (`use: <scheme>` form, RFC §5.2 / §7.2.1). `replacement` is then
    # `nothing` and the rule engine dispatches to `expand_scheme` at
    # rewrite time.
    replacement_scheme::Union{String,Nothing}
end

Rule(name::String, pattern::Expr, replacement::Expr;
     where::Vector{Guard}=Guard[],
     region::Union{String,RuleRegion,Nothing}=nothing,
     where_expr::Union{Expr,Nothing}=nothing,
     boundary_policy::BoundaryPolicy=nothing,
     ghost_width::GhostWidth=nothing,
     bindings::Union{Dict{String,RuleBinding},Nothing}=nothing,
     replacement_scheme::Union{String,Nothing}=nothing) =
    Rule(name, pattern, where, replacement, region, where_expr,
         boundary_policy, ghost_width, bindings, replacement_scheme)

# Backward-compatible 5-arg positional constructor (pre-§5.2.7 callers).
Rule(name::String, pattern::Expr, where::Vector{Guard}, replacement::Expr,
     region::Union{String,RuleRegion,Nothing}) =
    Rule(name, pattern, where, replacement, region, nothing, nothing, nothing, nothing, nothing)

# Backward-compatible 6-arg positional constructor (pre-§5.2.8 callers).
Rule(name::String, pattern::Expr, where::Vector{Guard}, replacement::Expr,
     region::Union{String,RuleRegion,Nothing},
     where_expr::Union{Expr,Nothing}) =
    Rule(name, pattern, where, replacement, region, where_expr, nothing, nothing, nothing, nothing)

# Backward-compatible 8-arg positional constructor (pre-esm-bet ghost_width callers).
Rule(name::String, pattern::Expr, where::Vector{Guard}, replacement::Expr,
     region::Union{String,RuleRegion,Nothing},
     where_expr::Union{Expr,Nothing},
     boundary_policy::BoundaryPolicy,
     bindings::Union{Dict{String,RuleBinding},Nothing}) =
    Rule(name, pattern, where, replacement, region, where_expr,
         boundary_policy, nothing, bindings, nothing)

# Backward-compatible 9-arg positional constructor (pre-esm-j1u use:-rule callers).
Rule(name::String, pattern::Expr, where::Vector{Guard},
     replacement::Union{Expr,Nothing},
     region::Union{String,RuleRegion,Nothing},
     where_expr::Union{Expr,Nothing},
     boundary_policy::BoundaryPolicy,
     ghost_width::GhostWidth,
     bindings::Union{Dict{String,RuleBinding},Nothing}) =
    Rule(name, pattern, where, replacement, region, where_expr,
         boundary_policy, ghost_width, bindings, nothing)

# ============================================================================
# Pattern variable detection
# ============================================================================

_is_pvar_string(s::AbstractString) = length(s) >= 2 && first(s) == '$'
_is_pvar_string(::Any) = false

_is_pvar(e::VarExpr) = _is_pvar_string(e.name)
_is_pvar(::Any) = false

# ============================================================================
# Match — returns Dict of bindings or nothing
# ============================================================================

"""
    match_pattern(pattern::Expr, expr::Expr) -> Union{Dict{String,Expr}, Nothing}

Attempt to match `pattern` against `expr`. On success, returns a
substitution mapping each pattern-variable name (including the leading
`\$`) to the AST or bare name it binds. Bare-name bindings (for sibling
fields like `wrt`, `dim`) are wrapped as [`VarExpr`](@ref) so the
substitution has a uniform type. On failure, returns `nothing`.

Non-linear patterns (§5.2.2): a pattern variable that appears in
multiple positions must bind to canonically-equal values at every
occurrence.
"""
function match_pattern(pattern::Expr, expr::Expr)::Union{Dict{String,Expr},Nothing}
    return _match(pattern, expr, Dict{String,Expr}())
end

function _match(pat::Expr, expr::Expr, b::Dict{String,Expr})
    # Pattern variable in an Expression position (subtree class).
    if pat isa VarExpr && _is_pvar(pat)
        return _unify(pat.name, expr, b)
    end
    if pat isa IntExpr
        return (expr isa IntExpr && expr.value == pat.value) ? b : nothing
    end
    if pat isa NumExpr
        return (expr isa NumExpr && expr.value == pat.value) ? b : nothing
    end
    if pat isa VarExpr
        return (expr isa VarExpr && expr.name == pat.name) ? b : nothing
    end
    if pat isa OpExpr
        expr isa OpExpr || return nothing
        pat.op == expr.op || return nothing
        length(pat.args) == length(expr.args) || return nothing
        b = _match_sibling_name(pat.wrt, expr.wrt, b)
        b === nothing && return nothing
        b = _match_sibling_name(pat.dim, expr.dim, b)
        b === nothing && return nothing
        b = _match_sibling_name(pat.fn, expr.fn, b)
        b === nothing && return nothing
        for (pa, ea) in zip(pat.args, expr.args)
            b = _match(pa, ea, b)
            b === nothing && return nothing
        end
        return b
    end
    return nothing
end

function _match_sibling_name(pat::Union{String,Nothing}, val::Union{String,Nothing},
                             b::Dict{String,Expr})
    if pat === nothing
        return val === nothing ? b : nothing
    end
    if _is_pvar_string(pat)
        val === nothing && return nothing
        return _unify(pat, VarExpr(val::String), b)
    end
    return (val !== nothing && val == pat) ? b : nothing
end

function _unify(pname::AbstractString, candidate::Expr, b::Dict{String,Expr})
    name = String(pname)
    if haskey(b, name)
        # Non-linear: existing binding must match candidate (AST-equal after
        # canonicalization).
        try
            prev_json = canonical_json(b[name])
            new_json = canonical_json(candidate)
            return prev_json == new_json ? b : nothing
        catch
            # Canonicalization failure (e.g. NaN) aborts the match.
            return nothing
        end
    end
    nb = copy(b)
    nb[name] = candidate
    return nb
end

# ============================================================================
# Apply bindings — build the replacement AST
# ============================================================================

"""
    apply_bindings(template::Expr, bindings::Dict{String,Expr}) -> Expr

Substitute pattern variables in `template` with their bound values.
Throws [`RuleEngineError`](@ref) if `template` references a pattern
variable that is not in `bindings`.
"""
function apply_bindings(template::Expr, b::Dict{String,Expr})::Expr
    if template isa VarExpr && _is_pvar(template)
        haskey(b, template.name) || throw(RuleEngineError(
            "E_PATTERN_VAR_UNBOUND",
            "pattern variable $(template.name) is not bound"))
        return b[template.name]
    end
    if template isa OpExpr
        new_args = Expr[apply_bindings(a, b) for a in template.args]
        new_wrt = _apply_name_field(template.wrt, b)
        new_dim = _apply_name_field(template.dim, b)
        # Recurse pattern-variable substitution into the structural sub-trees
        # and name-class fields of compound ops (arrayop / integral / select).
        # The previous version copied expr_body / output_idx / ranges / values /
        # lower / upper verbatim, so pattern variables ($u, $x, …) inside an
        # arrayop replacement's body and loop-index fields were never
        # substituted — they leaked through as literal "$x"/"$u" and crashed the
        # downstream evaluator (esd-3d7).
        new_body = template.expr_body === nothing ? nothing :
                   apply_bindings(template.expr_body, b)
        new_values = template.values === nothing ? nothing :
                     Expr[apply_bindings(v, b) for v in template.values]
        new_lower = template.lower === nothing ? nothing :
                    apply_bindings(template.lower, b)
        new_upper = template.upper === nothing ? nothing :
                    apply_bindings(template.upper, b)
        new_int_var = _apply_name_field(template.int_var, b)
        new_output_idx = _apply_idx_names(template.output_idx, b)
        new_ranges = _apply_ranges_names(template.ranges, b)
        return OpExpr(template.op, new_args;
                      wrt=new_wrt, dim=new_dim,
                      int_var=new_int_var, lower=new_lower, upper=new_upper,
                      output_idx=new_output_idx,
                      expr_body=new_body,
                      reduce=template.reduce, ranges=new_ranges,
                      regions=template.regions, values=new_values,
                      shape=template.shape, perm=template.perm,
                      axis=template.axis, fn=template.fn,
                      name=template.name, value=template.value)
    end
    return template
end

# Substitute a pattern variable used as a bare loop-index NAME (e.g. "$x" in an
# arrayop's `output_idx` or as a `ranges` key). Bindings map "$x" → VarExpr("x");
# the bare name "x" is what a name-class field needs. Non-pvar names pass through.
function _apply_idx_name(name::AbstractString, b::Dict{String,Expr})::String
    s = String(name)
    _is_pvar_string(s) || return s
    haskey(b, s) || throw(RuleEngineError(
        "E_PATTERN_VAR_UNBOUND",
        "pattern variable $s (loop index) is not bound"))
    v = b[s]
    v isa VarExpr || throw(RuleEngineError(
        "E_PATTERN_VAR_TYPE",
        "pattern variable $s used as a loop index must bind a bare name"))
    return v.name
end

_apply_idx_names(::Nothing, ::Dict{String,Expr}) = nothing
function _apply_idx_names(idxs, b::Dict{String,Expr})
    return Any[_apply_idx_name(String(x), b) for x in idxs]
end

_apply_ranges_names(::Nothing, ::Dict{String,Expr}) = nothing
function _apply_ranges_names(ranges, b::Dict{String,Expr})
    out = Dict{String,Any}()
    for (k, v) in ranges
        out[_apply_idx_name(String(k), b)] = v
    end
    return out
end

function _apply_name_field(field::Union{String,Nothing}, b::Dict{String,Expr})
    field === nothing && return nothing
    if _is_pvar_string(field)
        haskey(b, field) || throw(RuleEngineError(
            "E_PATTERN_VAR_UNBOUND",
            "pattern variable $field is not bound"))
        v = b[field]
        v isa VarExpr || throw(RuleEngineError(
            "E_PATTERN_VAR_TYPE",
            "pattern variable $field used in name-class field must bind a bare name"))
        return v.name
    end
    return field
end

# ============================================================================
# Guards (§5.2.4)
# ============================================================================

"""
    RuleContext(grids, variables)

Context supplied to [`rewrite`](@ref) and guard evaluation. Holds the
grid metadata and variable table needed by the closed-set guards in
§5.2.4. Callers build this by projecting the relevant pieces of an
`EsmFile` model.

- `grids::Dict{String, Dict{String,Any}}`: per-grid metadata. Each entry
  may carry `"spatial_dims"` (Vector{String}), `"periodic_dims"`
  (Vector{String}), `"nonuniform_dims"` (Vector{String}).
- `variables::Dict{String, Dict{String,Any}}`: per-variable metadata.
  Each entry may carry `"grid"` (String), `"location"` (String),
  `"shape"` (Vector or Vector{String}).
- `mask_fields::Dict{String, Vector{Dict{String,Int}}}`: per-point
  boolean masks resolving [`RegionMaskField`](@ref) scope (RFC §5.2.7).
  Each entry is the list of query points at which the mask is truthy;
  the evaluator fires the rule iff `ctx.query_point` matches one of
  the listed points on all keys the mask entry declares. Production
  callers populate this by materializing the relevant `data_loaders`
  entry (or a boolean variable) at the current rewrite time; tests
  inject it directly.
"""
struct RuleContext
    grids::Dict{String,Dict{String,Any}}
    variables::Dict{String,Dict{String,Any}}
    query_point::Dict{String,Int}
    grid_name::Union{String,Nothing}
    mask_fields::Dict{String,Vector{Dict{String,Int}}}
    # esm-j1u: registry of `discretizations.<name>` schemes referenced by
    # `use:` rules (RFC §5.2 / §7.2.1). Empty when no schemes are declared
    # or when only inline-`replacement` rules are in play.
    # Holds both Scheme (§7.1) and MultiOutputStencilScheme (§7.9) entries.
    schemes::Dict{String,AbstractScheme}
    # ess-ebe: emission buffers for multi_output_stencil trigger 1
    # (directly-consumed path, RFC §7.9). Populated by
    # expand_multi_output_scheme_direct during rewrite; injected into
    # the enclosing model by _discretize_model! after equation processing.
    # Mutable containers in an otherwise-immutable struct: mutation is safe
    # because we never reassign the fields, only call push!/setindex!.
    emitted_equations::Vector{Dict{String,Any}}
    emitted_variables::Dict{String,Dict{String,Any}}
    emitted_scheme_keys::Set{String}
    # ess-699: resolution stack for demand-driven provider expansion (trigger 2,
    # RFC §7.9). Tracks which MultiOutputStencilScheme names are currently being
    # instantiated so that circular requires chains throw E_SCHEME_CYCLE.
    provider_resolution_stack::Set{String}
end

RuleContext() = RuleContext(Dict{String,Dict{String,Any}}(),
                            Dict{String,Dict{String,Any}}(),
                            Dict{String,Int}(),
                            nothing,
                            Dict{String,Vector{Dict{String,Int}}}(),
                            Dict{String,AbstractScheme}(),
                            Dict{String,Any}[],
                            Dict{String,Dict{String,Any}}(),
                            Set{String}(),
                            Set{String}())

RuleContext(grids, variables) = RuleContext(grids, variables,
                                            Dict{String,Int}(), nothing,
                                            Dict{String,Vector{Dict{String,Int}}}(),
                                            Dict{String,AbstractScheme}(),
                                            Dict{String,Any}[],
                                            Dict{String,Dict{String,Any}}(),
                                            Set{String}(),
                                            Set{String}())

# Backward-compatible 4-arg constructor (pre-mask_field callers).
RuleContext(grids::Dict{String,Dict{String,Any}},
            variables::Dict{String,Dict{String,Any}},
            query_point::Dict{String,Int},
            grid_name::Union{String,Nothing}) =
    RuleContext(grids, variables, query_point, grid_name,
                Dict{String,Vector{Dict{String,Int}}}(),
                Dict{String,AbstractScheme}(),
                Dict{String,Any}[],
                Dict{String,Dict{String,Any}}(),
                Set{String}(),
                Set{String}())

# Backward-compatible 5-arg constructor (pre-esm-j1u schemes callers).
RuleContext(grids::Dict{String,Dict{String,Any}},
            variables::Dict{String,Dict{String,Any}},
            query_point::Dict{String,Int},
            grid_name::Union{String,Nothing},
            mask_fields::Dict{String,Vector{Dict{String,Int}}}) =
    RuleContext(grids, variables, query_point, grid_name, mask_fields,
                Dict{String,AbstractScheme}(),
                Dict{String,Any}[],
                Dict{String,Dict{String,Any}}(),
                Set{String}(),
                Set{String}())

# Backward-compatible 6-arg constructor (pre-ess-ebe emission-buffer callers).
# Accepts Dict{String,<:AbstractScheme} (covariant) so callers that built a
# Dict{String,Scheme} (before MultiOutputStencilScheme existed) still compile.
RuleContext(grids::Dict{String,Dict{String,Any}},
            variables::Dict{String,Dict{String,Any}},
            query_point::Dict{String,Int},
            grid_name::Union{String,Nothing},
            mask_fields::Dict{String,Vector{Dict{String,Int}}},
            schemes::Dict{String,<:AbstractScheme}) =
    RuleContext(grids, variables, query_point, grid_name, mask_fields,
                Dict{String,AbstractScheme}(k => v for (k, v) in schemes),
                Dict{String,Any}[],
                Dict{String,Dict{String,Any}}(),
                Set{String}(),
                Set{String}())

"""
    with_query_point(ctx, point; grid=nothing) -> RuleContext

Return a copy of `ctx` with the given per-point index bindings (e.g.
`Dict("i"=>0, "j"=>3)`) installed, used to evaluate per-query-point
`region` / `where`-expression scopes per RFC §5.2.7. `grid`, when
supplied, names which grid entry in `ctx.grids` the point refers to —
used to resolve `region.boundary.side` against grid dim bounds.

The emission buffers (`emitted_equations`, `emitted_variables`,
`emitted_scheme_keys`, `provider_resolution_stack`) are shared with the
original context so that emissions from any derived context accumulate in
the same place.
"""
with_query_point(ctx::RuleContext, point::Dict{String,Int};
                 grid::Union{String,Nothing}=nothing) =
    RuleContext(ctx.grids, ctx.variables, point,
                grid === nothing ? ctx.grid_name : grid,
                ctx.mask_fields, ctx.schemes,
                ctx.emitted_equations,
                ctx.emitted_variables,
                ctx.emitted_scheme_keys,
                ctx.provider_resolution_stack)

"""
    check_guards(guards, bindings, ctx) -> Union{Dict{String,Expr}, Nothing}

Evaluate the guard list left-to-right, threading bindings. Each guard
may read or extend the binding map; a guard whose pvar-valued `grid`
field is unbound at entry binds it to the variable's actual grid
(§9.2.1 example pattern). Returns the extended bindings on success,
`nothing` on any failure.
"""
function check_guards(guards::Vector{Guard}, bindings::Dict{String,Expr},
                      ctx::RuleContext)
    b = bindings
    for g in guards
        b = check_guard(g, b, ctx)
        b === nothing && return nothing
    end
    return b
end

"""
    check_guard(guard, bindings, ctx) -> Union{Dict{String,Expr}, Nothing}

Evaluate a single guard per §5.2.4. Returns an extended binding map on
success (possibly the same `bindings` if no new pvar was bound), or
`nothing` on failure.
"""
function check_guard(g::Guard, b::Dict{String,Expr}, ctx::RuleContext)
    if g.name == "var_has_grid"
        return _guard_var_has_grid(g, b, ctx)
    elseif g.name == "dim_is_spatial_dim_of"
        return _guard_dim_is_spatial_dim_of(g, b, ctx)
    elseif g.name == "dim_is_periodic"
        return _guard_dim_is_periodic(g, b, ctx)
    elseif g.name == "dim_is_nonuniform"
        return _guard_dim_is_nonuniform(g, b, ctx)
    elseif g.name == "var_location_is"
        return _guard_var_location_is(g, b, ctx)
    elseif g.name == "var_shape_rank"
        return _guard_var_shape_rank(g, b, ctx)
    elseif g.name == "bind_side_axis"
        return _guard_bind_side_axis(g, b, ctx)
    elseif g.name == "bind_side_spacing"
        return _guard_bind_side_spacing(g, b, ctx)
    elseif g.name == "bind_side_dim_size"
        return _guard_bind_side_dim_size(g, b, ctx)
    end
    throw(RuleEngineError("E_UNKNOWN_GUARD",
        "unknown guard: $(g.name) (§5.2.4 closed set)"))
end

function _resolve_name(b::Dict{String,Expr}, key::String)::Union{String,Nothing}
    haskey(b, key) || return nothing
    v = b[key]
    return v isa VarExpr ? v.name : nothing
end

# Resolve a guard's field that may be a literal string or a pvar reference.
# If `field_val` is a pvar and the pvar is already bound, returns the bound
# name and `(b, false)` — no new binding. If unbound, returns
# `(nothing, true)` to indicate the caller should set it from context, and
# will bind via `_bind_pvar_name`. If `field_val` is a literal, returns
# `(field_val, false)`.
function _resolve_or_mark(g::Guard, b::Dict{String,Expr},
                          field::String)::Tuple{Union{String,Nothing},Bool,Union{String,Nothing}}
    v = get(g.params, field, nothing)
    v === nothing && return (nothing, false, nothing)
    s = String(v)
    if _is_pvar_string(s)
        bound = _resolve_name(b, s)
        return (bound, bound === nothing, s)
    end
    return (s, false, nothing)
end

function _bind_pvar_name(b::Dict{String,Expr}, pvar::String, name::String)
    nb = copy(b)
    nb[pvar] = VarExpr(name)
    return nb
end

function _guard_var_has_grid(g, b, ctx)
    pvar = String(g.params["pvar"])
    var_name = _resolve_name(b, pvar)
    var_name === nothing && return nothing
    meta = get(ctx.variables, var_name, nothing)
    meta === nothing && return nothing
    actual = get(meta, "grid", nothing)
    actual === nothing && return nothing
    (wanted, need_bind, pname) = _resolve_or_mark(g, b, "grid")
    if need_bind
        return _bind_pvar_name(b, pname, actual)
    end
    return (wanted === actual) ? b : nothing
end

function _guard_dim_is_spatial_dim_of(g, b, ctx)
    pvar = String(g.params["pvar"])
    dim_name = _resolve_name(b, pvar)
    dim_name === nothing && return nothing
    (grid, _, _) = _resolve_or_mark(g, b, "grid")
    grid === nothing && return nothing
    meta = get(ctx.grids, grid, nothing)
    meta === nothing && return nothing
    return (dim_name in get(meta, "spatial_dims", String[])) ? b : nothing
end

function _guard_dim_is_periodic(g, b, ctx)
    pvar = String(g.params["pvar"])
    dim_name = _resolve_name(b, pvar)
    if dim_name === nothing
        # §9.2.1 accepts a bare string in pvar (e.g. "x") — treat as a literal
        # dimension name when the string is not a pvar.
        pv = String(g.params["pvar"])
        dim_name = _is_pvar_string(pv) ? nothing : pv
    end
    dim_name === nothing && return nothing
    (grid, _, _) = _resolve_or_mark(g, b, "grid")
    grid === nothing && return nothing
    meta = get(ctx.grids, grid, nothing)
    meta === nothing && return nothing
    return (dim_name in get(meta, "periodic_dims", String[])) ? b : nothing
end

function _guard_dim_is_nonuniform(g, b, ctx)
    pvar = String(g.params["pvar"])
    dim_name = _resolve_name(b, pvar)
    if dim_name === nothing
        pv = String(g.params["pvar"])
        dim_name = _is_pvar_string(pv) ? nothing : pv
    end
    dim_name === nothing && return nothing
    (grid, _, _) = _resolve_or_mark(g, b, "grid")
    grid === nothing && return nothing
    meta = get(ctx.grids, grid, nothing)
    meta === nothing && return nothing
    return (dim_name in get(meta, "nonuniform_dims", String[])) ? b : nothing
end

function _guard_var_location_is(g, b, ctx)
    pvar = String(g.params["pvar"])
    var_name = _resolve_name(b, pvar)
    var_name === nothing && return nothing
    target = String(g.params["location"])
    meta = get(ctx.variables, var_name, nothing)
    meta === nothing && return nothing
    return (get(meta, "location", nothing) == target) ? b : nothing
end

function _guard_var_shape_rank(g, b, ctx)
    pvar = String(g.params["pvar"])
    var_name = _resolve_name(b, pvar)
    var_name === nothing && return nothing
    want = Int(g.params["rank"])
    meta = get(ctx.variables, var_name, nothing)
    meta === nothing && return nothing
    shape = get(meta, "shape", nothing)
    shape === nothing && return nothing
    return (length(shape) == want) ? b : nothing
end

# Maps BC side names to canonical axis labels ("x", "y", "z").
const _SIDE_TO_AXIS = Dict{String,String}(
    "xmin" => "x", "xmax" => "x", "west" => "x", "east" => "x",
    "ymin" => "y", "ymax" => "y", "south" => "y", "north" => "y",
    "zmin" => "z", "zmax" => "z", "bottom" => "z", "top" => "z",
)

# Maps BC side names to the 1-based index into the grid's spatial_dims list.
const _SIDE_TO_AXIS_IDX = Dict{String,Int}(
    "xmin" => 1, "xmax" => 1, "west" => 1, "east" => 1,
    "ymin" => 2, "ymax" => 2, "south" => 2, "north" => 2,
    "zmin" => 3, "zmax" => 3, "bottom" => 3, "top" => 3,
)

# Resolve a guard's side param which may be a pvar or literal string.
function _resolve_side_or_literal(g, b, param::String)::Union{String,Nothing}
    val = get(g.params, param, nothing)
    val === nothing && return nothing
    raw = String(val)
    _is_pvar_string(raw) ? _resolve_name(b, raw) : raw
end

function _guard_bind_side_axis(g, b, ctx)
    pvar      = String(g.params["pvar"])
    side_name = _resolve_side_or_literal(g, b, "side")
    side_name === nothing && return nothing
    axis = get(_SIDE_TO_AXIS, side_name, nothing)
    axis === nothing && return nothing
    return _bind_pvar_name(b, pvar, axis)
end

function _guard_bind_side_spacing(g, b, ctx)
    pvar      = String(g.params["pvar"])
    side_name = _resolve_side_or_literal(g, b, "side")
    side_name === nothing && return nothing
    grid_raw  = String(g.params["grid"])
    grid_name = _is_pvar_string(grid_raw) ? _resolve_name(b, grid_raw) : grid_raw
    grid_name === nothing && return nothing
    grid_meta = get(ctx.grids, grid_name, nothing)
    grid_meta === nothing && return nothing
    axis_idx  = get(_SIDE_TO_AXIS_IDX, side_name, nothing)
    axis_idx  === nothing && return nothing
    spatial   = get(grid_meta, "spatial_dims", String[])
    axis_idx > length(spatial) && return nothing
    dim_name  = spatial[axis_idx]
    dim_sizes = get(grid_meta, "dim_sizes", nothing)
    dim_sizes === nothing && return nothing
    N_val     = get(dim_sizes, dim_name, nothing)
    N_val === nothing && return nothing
    N         = Int(N_val)
    nb        = copy(b)
    nb[pvar]  = NumExpr(1.0 / N)
    return nb
end

function _guard_bind_side_dim_size(g, b, ctx)
    pvar      = String(g.params["pvar"])
    side_name = _resolve_side_or_literal(g, b, "side")
    side_name === nothing && return nothing
    grid_raw  = String(g.params["grid"])
    grid_name = _is_pvar_string(grid_raw) ? _resolve_name(b, grid_raw) : grid_raw
    grid_name === nothing && return nothing
    grid_meta = get(ctx.grids, grid_name, nothing)
    grid_meta === nothing && return nothing
    axis_idx  = get(_SIDE_TO_AXIS_IDX, side_name, nothing)
    axis_idx  === nothing && return nothing
    spatial   = get(grid_meta, "spatial_dims", String[])
    axis_idx > length(spatial) && return nothing
    dim_name  = spatial[axis_idx]
    dim_sizes = get(grid_meta, "dim_sizes", nothing)
    dim_sizes === nothing && return nothing
    N_val     = get(dim_sizes, dim_name, nothing)
    N_val === nothing && return nothing
    nb        = copy(b)
    nb[pvar]  = IntExpr(Int(N_val))
    return nb
end

# ============================================================================
# Rewriter (§5.2.5)
# ============================================================================

"""
    rewrite(expr, rules, ctx; max_passes=32) -> Expr

Run the rule engine on `expr` per RFC §5.2.5: each pass walks top-down,
the first rule whose pattern matches fires, the rewritten subtree is
sealed for the remainder of the pass (walker does NOT descend into the
rewrite), then we continue with siblings. A pass that produces no
rewrites terminates the loop. If `max_passes` is reached without
convergence, throws [`RuleEngineError`](@ref) with code
`E_RULES_NOT_CONVERGED`.
"""
function rewrite(expr::Expr, rules::Vector{Rule}, ctx::RuleContext=RuleContext();
                 max_passes::Int=32)::Expr
    current = expr
    for pass in 1:max_passes
        changed = Ref(false)
        current = _rewrite_pass(current, rules, ctx, changed)
        changed[] || return current
    end
    throw(RuleEngineError("E_RULES_NOT_CONVERGED",
        "rule engine did not converge within $max_passes passes"))
end

function _rewrite_pass(expr::Expr, rules::Vector{Rule}, ctx::RuleContext,
                       changed::Ref{Bool})::Expr
    for rule in rules
        m = match_pattern(rule.pattern, expr)
        m === nothing && continue
        m2 = check_guards(rule.where, m, ctx)
        m2 === nothing && continue
        check_scope(rule, m2, ctx) || continue
        new_expr = _apply_rule_rhs(rule, m2, ctx)
        changed[] = true
        return new_expr  # sealed: do not descend
    end
    if expr isa OpExpr
        new_args = Expr[_rewrite_pass(a, rules, ctx, changed) for a in expr.args]
        # Structural equality check avoids allocating a new node when nothing
        # below changed. Here we always allocate; OpExpr is immutable, cheap.
        return OpExpr(expr.op, new_args;
                      wrt=expr.wrt, dim=expr.dim,
                      int_var=expr.int_var, lower=expr.lower, upper=expr.upper,
                      output_idx=expr.output_idx,
                      expr_body=expr.expr_body,
                      reduce=expr.reduce, ranges=expr.ranges,
                      regions=expr.regions, values=expr.values,
                      shape=expr.shape, perm=expr.perm,
                      axis=expr.axis, fn=expr.fn,
                      name=expr.name, value=expr.value)
    end
    return expr
end

# Dispatch a fired rule's RHS: inline `replacement` (apply bindings) vs
# `use: <scheme>` (look up scheme + invoke §7 expansion). RFC §5.2 / §7.2.1.
function _apply_rule_rhs(rule::Rule, bindings::Dict{String,Expr},
                          ctx::RuleContext)::Expr
    if rule.replacement_scheme !== nothing
        sname = rule.replacement_scheme
        haskey(ctx.schemes, sname) || throw(RuleEngineError(
            "E_SCHEME_MISMATCH",
            "rule $(rule.name): `use: $sname` references a scheme not " *
            "declared in `discretizations`"))
        scheme = ctx.schemes[sname]
        # `applies_to` guard check (RFC §7.2.1 step 3): re-match the scheme's
        # depth-1 pattern against the rule-matched subtree's reconstruction
        # via `bindings`. The scheme's pattern variables must already appear
        # in the rule's bindings — name-aligned per §7.2.1 step 4.
        _check_applies_to(rule, scheme, bindings)
        if scheme isa Scheme
            return expand_scheme(scheme, bindings, ctx)
        elseif scheme isa MultiOutputStencilScheme
            # RFC §7.9 trigger 1 (directly-consumed): emit one observed
            # arrayop equation per named output and rewrite the matched
            # expression to index(primary_output, i, ...).
            scheme.primary !== nothing || throw(RuleEngineError("E_SCHEME_MISMATCH",
                "rule $(rule.name): `use: $sname` references a provider-only " *
                "multi_output_stencil scheme (primary=null); direct `use:` is not " *
                "allowed for provider-only schemes — use a consumer Scheme with a " *
                "`requires` entry instead (RFC §7.9 trigger 2)"))
            return expand_multi_output_scheme_direct(scheme, bindings, ctx)
        else
            throw(RuleEngineError("E_SCHEME_MISMATCH",
                "rule $(rule.name): `use: $sname` references an unsupported " *
                "scheme type $(typeof(scheme))"))
        end
    end
    rule.replacement === nothing && throw(RuleEngineError(
        "E_RULE_REPLACEMENT_MISSING",
        "rule $(rule.name): no replacement and no `use:` — should have been " *
        "rejected at parse time"))
    return apply_bindings(rule.replacement, bindings)
end

function _check_applies_to(rule::Rule, scheme::AbstractScheme,
                            bindings::Dict{String,Expr})
    pat = scheme.applies_to
    pat isa OpExpr || throw(RuleEngineError("E_SCHEME_MISMATCH",
        "scheme $(scheme.name): applies_to must be an op node"))
    rule_pat = rule.pattern
    rule_pat isa OpExpr || throw(RuleEngineError("E_SCHEME_MISMATCH",
        "rule $(rule.name): pattern must be an op node when `use:` is set"))
    pat.op == rule_pat.op || throw(RuleEngineError("E_SCHEME_MISMATCH",
        "rule $(rule.name) / scheme $(scheme.name): operator mismatch " *
        "(rule pattern: `$(rule_pat.op)`, scheme applies_to: `$(pat.op)`)"))
    # Verify any pvar referenced by the scheme's applies_to (and any pvar in
    # `dim`) is bound by the rule. Scheme's `applies_to` is a guard only —
    # it does not introduce new bindings (§7.2.1).
    _check_pvars_bound(scheme.name, pat, bindings)
    if pat.dim !== nothing && _is_pvar_string(pat.dim)
        haskey(bindings, pat.dim) || throw(RuleEngineError("E_SCHEME_MISMATCH",
            "rule $(rule.name) / scheme $(scheme.name): pattern variable " *
            "`$(pat.dim)` (dim) is not bound by rule pattern"))
    end
end

function _check_pvars_bound(scheme_name::String, e::Expr, bindings::Dict{String,Expr})
    if e isa VarExpr && _is_pvar(e)
        haskey(bindings, e.name) || throw(RuleEngineError("E_SCHEME_MISMATCH",
            "scheme $scheme_name: pattern variable `$(e.name)` referenced in " *
            "applies_to is not bound by the triggering rule (RFC §7.2.1)"))
    elseif e isa OpExpr
        for a in e.args
            _check_pvars_bound(scheme_name, a, bindings)
        end
    end
end

# ============================================================================
# JSON loading (rules and expressions)
# ============================================================================

"""
    parse_rule(obj) -> Rule
    parse_rule(name::AbstractString, obj) -> Rule

Build a [`Rule`](@ref) from a decoded JSON object (a `Dict` or similar).
The object must contain `pattern` and `replacement` fields. Optional:
`where` (array of guard objects OR an expression-AST predicate per
RFC §5.2.7), `region` (legacy advisory string OR a scope object per
RFC §5.2.7).
"""
function parse_rule(name::AbstractString, obj)::Rule
    pat = _parse_expr(_getkey(obj, "pattern"))
    repl_raw = _getkey(obj, "replacement"; default=nothing)
    use_raw = _getkey(obj, "use"; default=nothing)
    if repl_raw !== nothing && use_raw !== nothing
        throw(RuleEngineError("E_RULE_PARSE",
            "rule $name: `replacement` and `use` are mutually exclusive (RFC §5.2)"))
    end
    repl::Union{Expr,Nothing} = nothing
    use_scheme::Union{String,Nothing} = nothing
    if use_raw !== nothing
        use_raw isa AbstractString || throw(RuleEngineError("E_RULE_PARSE",
            "rule $name: `use` must be a string scheme name"))
        use_scheme = String(use_raw)
    elseif repl_raw !== nothing
        repl = _parse_expr(repl_raw)
    else
        throw(RuleEngineError("E_RULE_REPLACEMENT_MISSING",
            "rule $name: must declare either `replacement` (inline AST) or " *
            "`use: <scheme>` (RFC §5.2)"))
    end
    where_raw = _getkey(obj, "where"; default=nothing)
    guards, where_expr = _parse_where(String(name), where_raw)
    region_raw = _getkey(obj, "region"; default=nothing)
    region = _parse_region(String(name), region_raw)
    bp_raw = _getkey(obj, "boundary_policy"; default=nothing)
    boundary_policy = _parse_boundary_policy(String(name), bp_raw)
    gw_raw = _getkey(obj, "ghost_width"; default=nothing)
    ghost_width = _parse_ghost_width(String(name), gw_raw)
    bindings_raw = _getkey(obj, "bindings"; default=nothing)
    bindings = _parse_bindings(String(name), bindings_raw)
    return Rule(String(name), pat, guards, repl, region, where_expr,
                boundary_policy, ghost_width, bindings, use_scheme)
end

# Closed set of policy kinds accepted in either the string-form
# `boundary_policy` or in `BoundaryPolicySpec.kind` (RFC §5.2.8 / §7).
const _BOUNDARY_POLICY_KIND_VALUES = (
    "periodic", "reflecting", "one_sided_extrapolation", "prescribed",
    # v0.3.x backwards-compatible aliases
    "ghosted", "neumann_zero", "extrapolate",
)

const _BOUNDARY_POLICY_STRING_VALUES = (
    "periodic", "reflecting", "one_sided_extrapolation", "prescribed",
    "ghosted", "neumann_zero", "extrapolate",
)

function _parse_boundary_policy(name::String, raw)::BoundaryPolicy
    raw === nothing && return nothing
    if raw isa AbstractString
        s = String(raw)
        if !(s in _BOUNDARY_POLICY_STRING_VALUES)
            valid = join(_BOUNDARY_POLICY_STRING_VALUES, ", ")
            throw(RuleEngineError("E_RULE_PARSE",
                "rule $name: unknown boundary_policy `$s` (closed set: $valid)"))
        end
        return s
    end
    if _is_dict_like(raw)
        by_axis_raw = _getkey(raw, "by_axis"; default=nothing)
        by_axis_raw === nothing && throw(RuleEngineError("E_RULE_PARSE",
            "rule $name: `boundary_policy` object must have a `by_axis` field"))
        _is_dict_like(by_axis_raw) || throw(RuleEngineError("E_RULE_PARSE",
            "rule $name: `boundary_policy.by_axis` must be an object"))
        out = Dict{String,BoundaryPolicySpec}()
        for (axis, spec_raw) in _iterate_dict(by_axis_raw)
            saxis = String(axis)
            out[saxis] = _parse_boundary_policy_spec(name, saxis, spec_raw)
        end
        return out
    end
    throw(RuleEngineError("E_RULE_PARSE",
        "rule $name: `boundary_policy` must be a string or an object with a `by_axis` field"))
end

function _parse_boundary_policy_spec(name::String, axis::String, raw)::BoundaryPolicySpec
    _is_dict_like(raw) || throw(RuleEngineError("E_RULE_PARSE",
        "rule $name: boundary_policy.by_axis.$axis must be an object"))
    kind_raw = _getkey(raw, "kind"; default=nothing)
    kind_raw === nothing && throw(RuleEngineError("E_RULE_PARSE",
        "rule $name: boundary_policy.by_axis.$axis missing required field `kind`"))
    kind = String(kind_raw)
    if !(kind in _BOUNDARY_POLICY_KIND_VALUES)
        valid = join(_BOUNDARY_POLICY_KIND_VALUES, ", ")
        throw(RuleEngineError("E_RULE_PARSE",
            "rule $name: boundary_policy.by_axis.$axis: unknown kind `$kind` (closed set: $valid)"))
    end
    degree_raw = _getkey(raw, "degree"; default=nothing)
    degree::Union{Int,Nothing} = nothing
    if degree_raw !== nothing
        (degree_raw isa Integer) || throw(RuleEngineError("E_RULE_PARSE",
            "rule $name: boundary_policy.by_axis.$axis.degree must be an integer"))
        d = Int(degree_raw)
        (0 <= d <= 3) || throw(RuleEngineError("E_RULE_PARSE",
            "rule $name: boundary_policy.by_axis.$axis.degree must be between 0 and 3, got $d"))
        degree = d
    end
    desc_raw = _getkey(raw, "description"; default=nothing)
    desc = desc_raw === nothing ? nothing : String(desc_raw)
    return BoundaryPolicySpec(kind, degree, desc)
end

function _parse_ghost_width(name::String, raw)::GhostWidth
    raw === nothing && return nothing
    if raw isa Integer
        n = Int(raw)
        n >= 0 || throw(RuleEngineError("E_RULE_PARSE",
            "rule $name: `ghost_width` must be non-negative, got $n"))
        return n
    end
    if _is_dict_like(raw)
        by_axis_raw = _getkey(raw, "by_axis"; default=nothing)
        by_axis_raw === nothing && throw(RuleEngineError("E_RULE_PARSE",
            "rule $name: `ghost_width` object must have a `by_axis` field"))
        _is_dict_like(by_axis_raw) || throw(RuleEngineError("E_RULE_PARSE",
            "rule $name: `ghost_width.by_axis` must be an object"))
        out = Dict{String,Int}()
        for (axis, w_raw) in _iterate_dict(by_axis_raw)
            saxis = String(axis)
            (w_raw isa Integer) || throw(RuleEngineError("E_RULE_PARSE",
                "rule $name: ghost_width.by_axis.$saxis must be an integer"))
            w = Int(w_raw)
            w >= 0 || throw(RuleEngineError("E_RULE_PARSE",
                "rule $name: ghost_width.by_axis.$saxis must be non-negative, got $w"))
            out[saxis] = w
        end
        return out
    end
    throw(RuleEngineError("E_RULE_PARSE",
        "rule $name: `ghost_width` must be a non-negative integer or an object with a `by_axis` field"))
end

const _BINDING_KIND_VALUES = ("static", "per_step", "per_cell")

function _parse_bindings(name::String, raw)::Union{Dict{String,RuleBinding},Nothing}
    raw === nothing && return nothing
    _is_dict_like(raw) || throw(RuleEngineError("E_RULE_PARSE",
        "rule $name: `bindings` must be an object"))
    out = Dict{String,RuleBinding}()
    for (k, v) in _iterate_dict(raw)
        sk = String(k)
        _is_dict_like(v) || throw(RuleEngineError("E_RULE_PARSE",
            "rule $name: bindings.$sk must be an object"))
        kind_raw = _getkey(v, "kind"; default=nothing)
        kind_raw === nothing && throw(RuleEngineError("E_RULE_PARSE",
            "rule $name: bindings.$sk missing required field `kind`"))
        kind = String(kind_raw)
        if !(kind in _BINDING_KIND_VALUES)
            valid = join(_BINDING_KIND_VALUES, ", ")
            throw(RuleEngineError("E_RULE_PARSE",
                "rule $name: bindings.$sk: unknown kind `$kind` (closed set: $valid)"))
        end
        default_raw = _getkey(v, "default"; default=nothing)
        default_expr = default_raw === nothing ? nothing : _parse_expr(default_raw)
        desc_raw = _getkey(v, "description"; default=nothing)
        desc = desc_raw === nothing ? nothing : String(desc_raw)
        out[sk] = RuleBinding(kind, default_expr, desc)
    end
    return out
end

# Discriminate array-of-guards vs expression predicate (RFC §5.2.7).
function _parse_where(name::String, raw)
    raw === nothing && return (Guard[], nothing)
    if raw isa AbstractVector
        return ([_parse_guard(g) for g in raw], nothing)
    end
    if _is_dict_like(raw)
        # Must have an `op` field to be a valid expression predicate.
        op = _getkey(raw, "op"; default=nothing)
        op === nothing && throw(RuleEngineError("E_RULE_PARSE",
            "rule $name: `where` object must be an expression node with an `op` field"))
        return (Guard[], _parse_expr(raw))
    end
    throw(RuleEngineError("E_RULE_PARSE",
        "rule $name: `where` must be an array of guards or an expression object"))
end

# Discriminate legacy advisory string vs per-point scope object.
function _parse_region(name::String, raw)::Union{String,RuleRegion,Nothing}
    raw === nothing && return nothing
    if raw isa AbstractString
        return String(raw)
    end
    if _is_dict_like(raw)
        kind = _getkey(raw, "kind"; default=nothing)
        kind === nothing && throw(RuleEngineError("E_RULE_PARSE",
            "rule $name: `region` object must carry a `kind` field"))
        k = String(kind)
        if k == "boundary"
            side = _getkey(raw, "side"; default=nothing)
            side === nothing && throw(RuleEngineError("E_RULE_PARSE",
                "rule $name: region.boundary requires `side`"))
            return RegionBoundary(String(side))
        elseif k == "mask_field"
            field = _getkey(raw, "field"; default=nothing)
            field === nothing && throw(RuleEngineError("E_RULE_PARSE",
                "rule $name: region.mask_field requires `field`"))
            return RegionMaskField(String(field))
        elseif k == "index_range"
            axis = _getkey(raw, "axis"; default=nothing)
            lo = _getkey(raw, "lo"; default=nothing)
            hi = _getkey(raw, "hi"; default=nothing)
            (axis === nothing || lo === nothing || hi === nothing) && throw(
                RuleEngineError("E_RULE_PARSE",
                    "rule $name: region.index_range requires `axis`, `lo`, `hi`"))
            return RegionIndexRange(String(axis), Int(lo), Int(hi))
        end
        throw(RuleEngineError("E_RULE_PARSE",
            "rule $name: unknown region.kind `$k` (closed set: boundary, mask_field, index_range)"))
    end
    throw(RuleEngineError("E_RULE_PARSE",
        "rule $name: `region` must be a string (legacy advisory) or object (normative scope)"))
end

parse_rule(obj) = parse_rule(_getkey(obj, "name"), obj)

function _parse_guard(obj)::Guard
    name = String(_getkey(obj, "guard"))
    params = Dict{String,Any}()
    for (k, v) in _iterate_dict(obj)
        sk = String(k)
        sk == "guard" && continue
        params[sk] = _jvalue(v)
    end
    return Guard(name, params)
end

"""
    parse_rules(obj) -> Vector{Rule}

Parse the `rules` section of a model into an ordered vector of
[`Rule`](@ref). Accepts either the JSON-object-keyed-by-name form or the
JSON-array form per RFC §5.2.5.
"""
function parse_rules(obj)::Vector{Rule}
    if obj isa AbstractVector
        return Rule[parse_rule(r) for r in obj]
    end
    result = Rule[]
    for (k, v) in _iterate_dict(obj)
        push!(result, parse_rule(String(k), v))
    end
    return result
end

# Load an expression from a JSON-decoded value. Integers come through as
# `Integer`, floats as `AbstractFloat`, variable/pattern-variable strings
# as `AbstractString`, and operator nodes as dict-like objects with `op`.
function _parse_expr(v)::Expr
    if v isa Expr
        return v
    elseif v isa Integer
        return IntExpr(Int64(v))
    elseif v isa AbstractFloat
        return NumExpr(Float64(v))
    elseif v isa AbstractString
        return VarExpr(String(v))
    elseif _is_dict_like(v)
        # Delegate to the canonical expression parser so rule patterns and
        # `replacement` ASTs carry the FULL op schema — including arrayop
        # fields (output_idx / expr / ranges / reduce / axis / perm / shape /
        # values / regions / fn / int_var / lower / upper). The previous
        # hand-rolled branch only read op/args/wrt/dim, silently dropping every
        # arrayop-specific field and collapsing an arrayop replacement to a
        # content-free `arrayop{args:[…]}` marker (root cause of esd-3d7's
        # E_TREEWALK_UNBOUND_VARIABLE after migrating FD rules to the
        # arrayop-replacement form).
        return parse_expression(v)
    end
    throw(RuleEngineError("E_RULE_PARSE",
        "cannot parse expression of type $(typeof(v))"))
end

_string_or_nothing(x) = x === nothing ? nothing : String(x)

_is_dict_like(x) = x isa AbstractDict || (x isa JSON3.Object)

function _getkey(obj, key::AbstractString; default=nothing)
    if obj isa AbstractDict
        return haskey(obj, key) ? obj[key] : default
    end
    if obj isa JSON3.Object
        sym = Symbol(key)
        return haskey(obj, sym) ? obj[sym] : default
    end
    throw(RuleEngineError("E_RULE_PARSE",
        "cannot read key '$key' from value of type $(typeof(obj))"))
end

function _iterate_dict(obj)
    if obj isa AbstractDict
        return collect(pairs(obj))
    elseif obj isa JSON3.Object
        return [(String(k), obj[k]) for k in keys(obj)]
    end
    throw(RuleEngineError("E_RULE_PARSE",
        "cannot iterate value of type $(typeof(obj))"))
end

function _jvalue(v)
    if v isa AbstractString
        return String(v)
    elseif v isa Integer
        return Int64(v)
    elseif v isa AbstractFloat
        return Float64(v)
    elseif v isa Bool
        return v
    elseif v isa AbstractVector
        return Any[_jvalue(x) for x in v]
    end
    return v
end

# ============================================================================
# Scope evaluation — region object + where expression (RFC §5.2.7)
# ============================================================================

"""
    check_scope(rule, bindings, ctx) -> Bool

Evaluate a rule's `region` scope (if an object) and `where_expr`
predicate (if present) against `ctx.query_point`. Returns `true` when
the rule should fire at the current query point, `false` otherwise
(conservative fall-through).

When `ctx.query_point` is empty and the rule carries any per-point
scope, the rule is disabled (returns `false`) — see RFC §5.2.7's
`W_UNEVAL_SCOPE` handling. A legacy string `region` and a missing
`where_expr` pass unconditionally, preserving backwards compatibility.
"""
function check_scope(rule::Rule, bindings::Dict{String,Expr}, ctx::RuleContext)::Bool
    # Region check.
    if rule.region isa RuleRegion
        _eval_region(rule.region, bindings, ctx) || return false
    end
    # Per-point where-expression check.
    if rule.where_expr !== nothing
        _eval_where_expr(rule.where_expr, bindings, ctx) || return false
    end
    return true
end

function _eval_region(r::RegionIndexRange, b::Dict{String,Expr}, ctx::RuleContext)::Bool
    isempty(ctx.query_point) && return false
    haskey(ctx.query_point, r.axis) || return false
    v = ctx.query_point[r.axis]
    return r.lo <= v <= r.hi
end

function _eval_region(r::RegionBoundary, b::Dict{String,Expr}, ctx::RuleContext)::Bool
    isempty(ctx.query_point) && return false
    ctx.grid_name === nothing && return false
    meta = get(ctx.grids, ctx.grid_name, nothing)
    meta === nothing && return false
    bounds = get(meta, "dim_bounds", nothing)
    bounds === nothing && return false
    side = r.side
    # Map side name to (axis, lo-or-hi).
    side_map = Dict(
        "xmin" => ("x", :lo), "xmax" => ("x", :hi),
        "ymin" => ("y", :lo), "ymax" => ("y", :hi),
        "zmin" => ("z", :lo), "zmax" => ("z", :hi),
        "west" => ("x", :lo), "east" => ("x", :hi),
        "south" => ("y", :lo), "north" => ("y", :hi),
        "bottom" => ("z", :lo), "top" => ("z", :hi),
    )
    haskey(side_map, side) || return false
    (dim, which) = side_map[side]
    haskey(bounds, dim) || return false
    dim_bounds = bounds[dim]
    # Look up the canonical index name for that dim via grid.spatial_dims order.
    spatial_dims = get(meta, "spatial_dims", String[])
    idx_pos = findfirst(==(dim), spatial_dims)
    idx_pos === nothing && return false
    canonical = ("i", "j", "k", "l", "m")
    idx_pos > length(canonical) && return false
    idx_name = canonical[idx_pos]
    haskey(ctx.query_point, idx_name) || return false
    v = ctx.query_point[idx_name]
    target = which == :lo ? Int(dim_bounds[1]) : Int(dim_bounds[2])
    return v == target
end

function _eval_region(r::RegionMaskField, b::Dict{String,Expr}, ctx::RuleContext)::Bool
    isempty(ctx.query_point) && return false
    haskey(ctx.mask_fields, r.field) || return false
    points = ctx.mask_fields[r.field]
    for pt in points
        _point_subset_matches(pt, ctx.query_point) && return true
    end
    return false
end

# A truthy mask entry matches when every (axis, value) it declares
# agrees with the corresponding entry in `ctx.query_point`. Axes present
# in the query point but absent from the mask entry are ignored —
# mask entries can be as coarse as the mask's intrinsic dimensionality
# (e.g. a 2D surface mask on a 3D grid matches on i,j regardless of k).
function _point_subset_matches(mask_pt::Dict{String,Int},
                               query_pt::Dict{String,Int})::Bool
    isempty(mask_pt) && return false
    for (axis, v) in mask_pt
        haskey(query_pt, axis) || return false
        query_pt[axis] == v || return false
    end
    return true
end

"""
    _eval_where_expr(expr, bindings, ctx) -> Bool

Evaluate `expr` under pattern-variable bindings and query-point indices,
returning a boolean. Supports the scalar subset of §4 ops: arithmetic,
comparison, logical ops, and bare-string index references resolved
against `ctx.query_point` and `bindings` (bindings to `VarExpr` are
resolved as index names; bindings to `IntExpr` / `NumExpr` as constants).
Unsupported ops, unresolved names, or non-scalar results cause the
predicate to evaluate `false` (conservative fall-through).
"""
function _eval_where_expr(expr::Expr, b::Dict{String,Expr}, ctx::RuleContext)::Bool
    isempty(ctx.query_point) && return false
    val = _eval_scalar(expr, b, ctx)
    val === nothing && return false
    if val isa Bool
        return val
    elseif val isa Integer
        return val != 0
    elseif val isa AbstractFloat
        return val != 0.0
    end
    return false
end

function _eval_scalar(e::Expr, b::Dict{String,Expr}, ctx::RuleContext)
    if e isa IntExpr
        return e.value
    elseif e isa NumExpr
        return e.value
    elseif e isa VarExpr
        n = e.name
        # Pattern variable bound to something concrete?
        if _is_pvar_string(n) && haskey(b, n)
            return _eval_scalar(b[n], b, ctx)
        end
        # Query-point index?
        haskey(ctx.query_point, n) && return ctx.query_point[n]
        return nothing
    elseif e isa OpExpr
        return _eval_op(e, b, ctx)
    end
    return nothing
end

function _eval_op(e::OpExpr, b, ctx)
    op = e.op
    args = [_eval_scalar(a, b, ctx) for a in e.args]
    any(a -> a === nothing, args) && !(op in ("and", "or")) && return nothing
    if op == "+"
        return reduce(+, args; init=0)
    elseif op == "-"
        length(args) == 1 && return -args[1]
        return args[1] - reduce(+, args[2:end]; init=0)
    elseif op == "*"
        return reduce(*, args; init=1)
    elseif op == "/"
        length(args) >= 2 || return nothing
        return args[1] / args[2]
    elseif op == "=="
        length(args) == 2 || return nothing
        return args[1] == args[2]
    elseif op == "!="
        length(args) == 2 || return nothing
        return args[1] != args[2]
    elseif op == "<"
        length(args) == 2 || return nothing
        return args[1] < args[2]
    elseif op == "<="
        length(args) == 2 || return nothing
        return args[1] <= args[2]
    elseif op == ">"
        length(args) == 2 || return nothing
        return args[1] > args[2]
    elseif op == ">="
        length(args) == 2 || return nothing
        return args[1] >= args[2]
    elseif op == "and"
        return all(a -> a === true || (a isa Number && a != 0), args)
    elseif op == "or"
        return any(a -> a === true || (a isa Number && a != 0), args)
    elseif op == "not"
        length(args) == 1 || return nothing
        v = args[1]
        return !(v === true || (v isa Number && v != 0))
    end
    return nothing
end

# ============================================================================
# Unrewritten PDE op check (§11 Step 7)
# ============================================================================

const _PDE_OPS = Set(["grad", "div", "laplacian", "D", "bc"])

"""
    check_unrewritten_pde_ops(expr) -> Nothing

Scan `expr` for leftover PDE ops (`grad`, `div`, `laplacian`, `D`, `bc`)
and throw [`RuleEngineError`](@ref) `E_UNREWRITTEN_PDE_OP` if any are
found. Authors opt out by marking an equation `passthrough: true` at the
pipeline layer (§11); this check is run only on non-passthrough
equations.
"""
function check_unrewritten_pde_ops(expr::Expr)
    found = _find_pde_op(expr)
    if found !== nothing
        throw(RuleEngineError("E_UNREWRITTEN_PDE_OP",
            "equation still contains PDE op '$found' after rewrite; " *
            "annotate the equation with 'passthrough: true' to opt out"))
    end
    return nothing
end

function _find_pde_op(e::Expr)::Union{String,Nothing}
    if e isa OpExpr
        e.op in _PDE_OPS && return e.op
        for a in e.args
            r = _find_pde_op(a)
            r === nothing || return r
        end
    end
    return nothing
end
