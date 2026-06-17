# Scheme parsing + expansion per discretization RFC §7 / §7.2 / §7.2.1.
#
# Type definitions (`Selector`, `CartesianSelector`, `StencilEntry`, `Scheme`)
# live in `scheme_types.jl` (loaded before `rule_engine.jl`). This file holds
# the parser for `discretizations.<name>` blocks plus the `materialize` /
# `expand_scheme` runtime invoked by the rule engine when a rule's replacement
# is `use: <scheme>`.
#
# Supports: cartesian (esm-j1u).

# ============================================================================
# Parsing — discretizations.<name>
# ============================================================================

"""
    parse_scheme(name, raw) -> Scheme

Build a [`Scheme`](@ref) from a decoded JSON object. Required fields:
`applies_to`, `grid_family`, `stencil`. `combine` defaults to `"+"`;
`target_binding` defaults to `"\$target"`. Selector kinds are
discriminated by `selector.kind`. Cartesian selectors require `axis`
(string, possibly a pvar reference) and `offset` (integer).
"""
function parse_scheme(name::AbstractString, raw)::Scheme
    sname = String(name)
    _is_dict_like(raw) || throw(RuleEngineError("E_SCHEME_PARSE",
        "scheme $sname: must be an object"))

    applies_to_raw = _getkey(raw, "applies_to"; default=nothing)
    applies_to_raw === nothing && throw(RuleEngineError("E_SCHEME_PARSE",
        "scheme $sname: missing required field `applies_to`"))
    applies_to = _parse_expr(applies_to_raw)

    grid_family_raw = _getkey(raw, "grid_family"; default=nothing)
    grid_family_raw === nothing && throw(RuleEngineError("E_SCHEME_PARSE",
        "scheme $sname: missing required field `grid_family`"))
    grid_family = String(grid_family_raw)
    grid_family in ("cartesian", "unstructured") ||
        throw(RuleEngineError("E_SCHEME_PARSE",
            "scheme $sname: unknown grid_family `$grid_family` " *
            "(closed set: cartesian, unstructured)"))

    combine_raw = _getkey(raw, "combine"; default="+")
    combine = String(combine_raw)
    combine in ("+", "*", "min", "max") || throw(RuleEngineError("E_SCHEME_PARSE",
        "scheme $sname: combine `$combine` must be one of +, *, min, max"))

    stencil_raw     = _getkey(raw, "stencil";     default=nothing)
    stencil_gen_raw = _getkey(raw, "stencil_gen"; default=nothing)

    stencil_raw !== nothing && stencil_gen_raw !== nothing &&
        throw(RuleEngineError("E_SCHEME_PARSE",
            "scheme $sname: `stencil` and `stencil_gen` are mutually exclusive"))

    stencil = if stencil_gen_raw !== nothing
        _expand_stencil_gen(sname, grid_family, stencil_gen_raw)
    elseif stencil_raw !== nothing
        stencil_raw isa AbstractVector || throw(RuleEngineError("E_SCHEME_PARSE",
            "scheme $sname: `stencil` must be an array"))
        entries = StencilEntry[_parse_stencil_entry(sname, grid_family, e)
                               for e in stencil_raw]
        isempty(entries) && throw(RuleEngineError("E_SCHEME_PARSE",
            "scheme $sname: `stencil` must contain at least one entry"))
        entries
    else
        throw(RuleEngineError("E_SCHEME_PARSE",
            "scheme $sname: one of `stencil` or `stencil_gen` is required"))
    end

    accuracy_raw = _getkey(raw, "accuracy"; default=nothing)
    accuracy = accuracy_raw === nothing ? nothing : String(accuracy_raw)

    order_raw = _getkey(raw, "order"; default=nothing)
    order = nothing
    if order_raw !== nothing
        order_raw isa Integer || throw(RuleEngineError("E_SCHEME_PARSE",
            "scheme $sname: `order` must be an integer"))
        order = Int(order_raw)
        order > 0 || throw(RuleEngineError("E_SCHEME_PARSE",
            "scheme $sname: `order` must be a positive integer, got $order"))
    end

    requires_locations_raw = _getkey(raw, "requires_locations"; default=nothing)
    requires_locations = String[]
    if requires_locations_raw !== nothing
        requires_locations_raw isa AbstractVector || throw(RuleEngineError(
            "E_SCHEME_PARSE",
            "scheme $sname: `requires_locations` must be an array of strings"))
        requires_locations = String[String(s) for s in requires_locations_raw]
    end

    emits_location_raw = _getkey(raw, "emits_location"; default=nothing)
    emits_location = emits_location_raw === nothing ? nothing :
        String(emits_location_raw)

    target_binding_raw = _getkey(raw, "target_binding"; default="\$target")
    target_binding = String(target_binding_raw)

    requires_raw = _getkey(raw, "requires"; default=nothing)
    requires = Dict{String,String}()
    if requires_raw !== nothing
        _is_dict_like(requires_raw) || throw(RuleEngineError("E_SCHEME_PARSE",
            "scheme $sname: `requires` must be an object"))
        for (k, v) in _iterate_dict(requires_raw)
            sk = String(k)
            sv = String(v)
            occursin('#', sv) || throw(RuleEngineError("E_SCHEME_PARSE",
                "scheme $sname: `requires.$sk` must have the form " *
                "'<scheme>#<output>', got: $sv"))
            requires[sk] = sv
        end
    end

    return Scheme(sname, applies_to, grid_family, combine, stencil,
                  accuracy, order, requires_locations,
                  emits_location, target_binding, requires)
end

function _parse_stencil_entry(scheme_name::String, grid_family::String, raw)::StencilEntry
    _is_dict_like(raw) || throw(RuleEngineError("E_SCHEME_PARSE",
        "scheme $scheme_name: stencil entry must be an object"))
    sel_raw = _getkey(raw, "selector"; default=nothing)
    sel_raw === nothing && throw(RuleEngineError("E_SCHEME_PARSE",
        "scheme $scheme_name: stencil entry missing required field `selector`"))
    coeff_raw = _getkey(raw, "coeff"; default=nothing)
    coeff_raw === nothing && throw(RuleEngineError("E_SCHEME_PARSE",
        "scheme $scheme_name: stencil entry missing required field `coeff`"))
    sel = _parse_selector(scheme_name, grid_family, sel_raw)
    coeff = _parse_expr(coeff_raw)
    return StencilEntry(sel, coeff)
end

function _parse_selector(scheme_name::String, grid_family::String, raw)::Selector
    _is_dict_like(raw) || throw(RuleEngineError("E_SCHEME_PARSE",
        "scheme $scheme_name: selector must be an object"))
    kind_raw = _getkey(raw, "kind"; default=nothing)
    kind_raw === nothing && throw(RuleEngineError("E_SCHEME_PARSE",
        "scheme $scheme_name: selector missing required field `kind`"))
    kind = String(kind_raw)
    if kind == "cartesian"
        grid_family == "cartesian" || throw(RuleEngineError("E_SCHEME_PARSE",
            "scheme $scheme_name: cartesian selector incompatible with " *
            "grid_family=$grid_family"))
        axis_raw = _getkey(raw, "axis"; default=nothing)
        axis_raw === nothing && throw(RuleEngineError("E_SCHEME_PARSE",
            "scheme $scheme_name: cartesian selector missing `axis`"))
        offset_raw = _getkey(raw, "offset"; default=nothing)
        offset_raw === nothing && throw(RuleEngineError("E_SCHEME_PARSE",
            "scheme $scheme_name: cartesian selector missing `offset`"))
        offset_raw isa Integer || throw(RuleEngineError("E_SCHEME_PARSE",
            "scheme $scheme_name: cartesian selector `offset` must be integer"))
        return CartesianSelector(String(axis_raw), Int(offset_raw))
    end
    throw(RuleEngineError("E_SCHEME_PARSE",
        "scheme $scheme_name: selector kind `$kind` not yet supported " *
        "(supported: cartesian)"))
end

"""
    parse_multi_output_stencil_scheme(name, raw) -> MultiOutputStencilScheme

Build a [`MultiOutputStencilScheme`](@ref) from a decoded JSON object per RFC §7.9.
Validates:
- `outputs` equals the key set of `stencil` (E_OUTPUTS_STENCIL_MISMATCH).
- Each per-output stencil entry list is non-empty and valid per §7.1.
- `primary`, when non-null, names a declared output (E_PRIMARY_NOT_AN_OUTPUT).
- `outputs` contains no duplicate names (E_PROVIDER_NAME_CLASH).
"""
function parse_multi_output_stencil_scheme(name::AbstractString, raw)::MultiOutputStencilScheme
    sname = String(name)
    _is_dict_like(raw) || throw(RuleEngineError("E_SCHEME_PARSE",
        "scheme $sname: must be an object"))

    applies_to_raw = _getkey(raw, "applies_to"; default=nothing)
    applies_to_raw === nothing && throw(RuleEngineError("E_SCHEME_PARSE",
        "scheme $sname: missing required field `applies_to`"))
    applies_to = _parse_expr(applies_to_raw)

    grid_family_raw = _getkey(raw, "grid_family"; default=nothing)
    grid_family = grid_family_raw === nothing ? "cartesian" : String(grid_family_raw)
    grid_family in ("cartesian", "unstructured") ||
        throw(RuleEngineError("E_SCHEME_PARSE",
            "scheme $sname: unknown grid_family `$grid_family` " *
            "(closed set: cartesian, unstructured)"))

    outputs_raw = _getkey(raw, "outputs"; default=nothing)
    outputs_raw === nothing && throw(RuleEngineError("E_SCHEME_PARSE",
        "scheme $sname: missing required field `outputs`"))
    outputs_raw isa AbstractVector || throw(RuleEngineError("E_SCHEME_PARSE",
        "scheme $sname: `outputs` must be an array"))
    outputs = String[String(o) for o in outputs_raw]
    isempty(outputs) && throw(RuleEngineError("E_SCHEME_PARSE",
        "scheme $sname: `outputs` must contain at least one entry"))

    seen_outputs = Set{String}()
    for o in outputs
        o in seen_outputs && throw(RuleEngineError("E_PROVIDER_NAME_CLASH",
            "scheme $sname: duplicate output name `$o` in `outputs`"))
        push!(seen_outputs, o)
    end

    stencil_raw = _getkey(raw, "stencil"; default=nothing)
    stencil_raw === nothing && throw(RuleEngineError("E_SCHEME_PARSE",
        "scheme $sname: missing required field `stencil`"))
    _is_dict_like(stencil_raw) || throw(RuleEngineError("E_SCHEME_PARSE",
        "scheme $sname: `stencil` must be an object (keyed by output name)"))

    stencil_keys = Set{String}(String(k) for (k, _) in _iterate_dict(stencil_raw))

    # Parse optional `derived` block (RFC §7.9 OQ3).
    derived_raw = _getkey(raw, "derived"; default=nothing)
    derived = Dict{String,Expr}()
    derived_keys = Set{String}()
    if derived_raw !== nothing
        _is_dict_like(derived_raw) || throw(RuleEngineError("E_SCHEME_PARSE",
            "scheme $sname: `derived` must be an object (keyed by output name)"))
        for (dk, dv) in _iterate_dict(derived_raw)
            sdk = String(dk)
            derived[sdk] = _parse_expr(dv)
            push!(derived_keys, sdk)
        end
        # Overlap: a name cannot appear in both stencil and derived.
        overlap = stencil_keys ∩ derived_keys
        isempty(overlap) || throw(RuleEngineError("E_DERIVED_STENCIL_OVERLAP",
            "scheme $sname: output names $(sort(collect(overlap))) appear in both " *
            "`stencil` and `derived`; each output must be defined in exactly one block"))
    end

    all_scheme_outputs = stencil_keys ∪ derived_keys
    all_scheme_outputs == seen_outputs || throw(RuleEngineError("E_OUTPUTS_STENCIL_MISMATCH",
        "scheme $sname: `outputs` $(sort(collect(seen_outputs))) does not match " *
        "the union of `stencil` keys $(sort(collect(stencil_keys))) and `derived` " *
        "keys $(sort(collect(derived_keys)))"))

    stencil = Dict{String,Vector{StencilEntry}}()
    for (ok, ov) in _iterate_dict(stencil_raw)
        sok = String(ok)
        ov isa AbstractVector || throw(RuleEngineError("E_SCHEME_PARSE",
            "scheme $sname: stencil entry for output `$sok` must be an array"))
        isempty(ov) && throw(RuleEngineError("E_SCHEME_PARSE",
            "scheme $sname: stencil entry list for output `$sok` must be non-empty"))
        stencil[sok] = StencilEntry[_parse_stencil_entry(sname, grid_family, e)
                                    for e in ov]
    end

    primary_raw = _getkey(raw, "primary"; default=nothing)
    primary = nothing
    if primary_raw !== nothing && !isnothing(primary_raw) &&
            !(primary_raw isa Nothing)
        pstr = String(primary_raw)
        pstr in seen_outputs || throw(RuleEngineError("E_PRIMARY_NOT_AN_OUTPUT",
            "scheme $sname: `primary` value `$pstr` is not a declared output " *
            "(declared: $(sort(collect(seen_outputs))))"))
        primary = pstr
    end

    emits_location_raw = _getkey(raw, "emits_location"; default=nothing)
    emits_location = emits_location_raw === nothing ? nothing : String(emits_location_raw)

    accuracy_raw = _getkey(raw, "accuracy"; default=nothing)
    accuracy = accuracy_raw === nothing ? nothing : String(accuracy_raw)

    order_raw = _getkey(raw, "order"; default=nothing)
    order = nothing
    if order_raw !== nothing
        order_raw isa Integer || throw(RuleEngineError("E_SCHEME_PARSE",
            "scheme $sname: `order` must be an integer"))
        order = Int(order_raw)
        order > 0 || throw(RuleEngineError("E_SCHEME_PARSE",
            "scheme $sname: `order` must be a positive integer, got $order"))
    end

    requires_locations_raw = _getkey(raw, "requires_locations"; default=nothing)
    requires_locations = String[]
    if requires_locations_raw !== nothing
        requires_locations_raw isa AbstractVector || throw(RuleEngineError(
            "E_SCHEME_PARSE",
            "scheme $sname: `requires_locations` must be an array of strings"))
        requires_locations = String[String(s) for s in requires_locations_raw]
    end

    target_binding_raw = _getkey(raw, "target_binding"; default="\$target")
    target_binding = String(target_binding_raw)

    return MultiOutputStencilScheme(sname, applies_to, grid_family, outputs,
                                    stencil, derived, primary, emits_location,
                                    accuracy, order, requires_locations,
                                    target_binding)
end

"""
    parse_schemes(raw, base_path="", visited=nothing) -> Dict{String,AbstractScheme}

Parse the top-level `discretizations` block into a name-keyed registry of
[`AbstractScheme`](@ref) entries. Handles both §7.1 flat stencil schemes
([`Scheme`](@ref)) and §7.9 multi-output stencil schemes
([`MultiOutputStencilScheme`](@ref)). Accepts the JSON-object-keyed-by-name
form. Returns an empty dict for `nothing` / empty / missing input.

When `base_path` is provided, entries of the form `{ref: "<path-or-URL>"}`
are resolved by loading the external ESD rule file and splicing its
`discretizations` block in place of the ref. `visited` is a cycle-detection
guard (a `Set{String}` of canonical references already on the call stack).

After parsing all entries, validates consumer `requires` references:
each value must resolve to a `<sibling-scheme>#<output>` where the sibling
is a `MultiOutputStencilScheme` and the output is in its `outputs` array
(E_PROVIDER_NOT_FOUND, E_OUTPUT_NOT_FOUND per RFC §7.9).
"""
function parse_schemes(raw, base_path::String = "",
                       visited::Union{Nothing,Set{String}} = nothing)::Dict{String,AbstractScheme}
    out = Dict{String,AbstractScheme}()
    raw === nothing && return out
    _is_dict_like(raw) || return out
    for (k, v) in _iterate_dict(raw)
        sk = String(k)
        # Resolve {ref} entries: load the target file, extract its single scheme
        # definition, and parse it under the parent key (§4.7.1 "spliced in place").
        if _is_dict_like(v) && _getkey(v, "ref"; default=nothing) !== nothing
            ref_val = String(_getkey(v, "ref"))
            if isempty(base_path)
                throw(RuleEngineError("E_SCHEME_REF",
                    "discretizations entry '$sk': {ref} resolution requires a " *
                    "base path — pass `source_path` to discretize()"))
            end
            if visited === nothing
                visited = Set{String}()
            end
            scheme_def = _resolve_discretization_ref(sk, ref_val, base_path, visited)
            out[sk] = parse_scheme(sk, scheme_def)
            continue
        end
        kind_raw = _is_dict_like(v) ? _getkey(v, "kind"; default=nothing) : nothing
        kind = kind_raw === nothing ? "stencil" : String(kind_raw)
        if kind == "multi_output_stencil"
            out[sk] = parse_multi_output_stencil_scheme(sk, v)
        elseif kind == "stencil"
            out[sk] = parse_scheme(sk, v)
        else
            # Defer other kinds (cross_metric, dimensional_split, grid_dispatch, …).
            continue
        end
    end

    # Cross-scheme validation: resolve all consumer `requires` references.
    for (_, sch) in out
        sch isa Scheme || continue
        isempty(sch.requires) && continue
        for (local_name, ref) in sch.requires
            parts = split(ref, '#'; limit=2)
            provider_name = String(parts[1])
            output_name   = String(parts[2])
            if !haskey(out, provider_name) || !(out[provider_name] isa MultiOutputStencilScheme)
                throw(RuleEngineError("E_PROVIDER_NOT_FOUND",
                    "scheme $(sch.name): `requires.$local_name` references " *
                    "provider `$provider_name` which is not a multi_output_stencil " *
                    "scheme in the same discretizations block"))
            end
            provider = out[provider_name]::MultiOutputStencilScheme
            output_name in provider.outputs || throw(RuleEngineError("E_OUTPUT_NOT_FOUND",
                "scheme $(sch.name): `requires.$local_name` references output " *
                "`$output_name` which is not declared in provider `$provider_name` " *
                "(declared outputs: $(provider.outputs))"))
        end
    end

    return out
end

"""
    _resolve_discretization_ref(scheme_name, ref, base_path, visited) -> raw scheme dict

Load the ESM file at `ref` (local path or URL) via the subsystem `_load_ref`
machinery, extract its `discretizations` block, and return the single raw scheme
definition dict. The returned dict is parsed by the caller under `scheme_name`.

Raises `RuleEngineError` if the file has no `discretizations` block or if it
does not contain exactly one scheme (§4.7.1 requires a single scheme per file).
"""
function _resolve_discretization_ref(scheme_name::String, ref::String,
                                      base_path::String, visited::Set{String})
    local loaded::EsmFile
    try
        loaded = _load_ref(ref, base_path, visited)
    catch e
        if e isa SubsystemRefError
            throw(RuleEngineError("E_SCHEME_REF",
                "discretization ref '$ref': $(e.message)"))
        end
        rethrow(e)
    end
    disc_raw = loaded.discretizations
    if disc_raw === nothing || isempty(disc_raw)
        throw(RuleEngineError("E_SCHEME_REF",
            "discretization ref '$ref' (for scheme '$scheme_name') resolved to a " *
            "file with no `discretizations` block"))
    end
    if length(disc_raw) != 1
        throw(RuleEngineError("E_SCHEME_REF",
            "discretization ref '$ref' (for scheme '$scheme_name') must contain " *
            "exactly one scheme definition, found $(length(disc_raw))"))
    end
    _, scheme_def = first(disc_raw)
    return scheme_def
end

# ============================================================================
# Materialize — neighbor selector → list of index expressions (§7.2 row 1)
# ============================================================================

# Canonical $target component names for cartesian grids per RFC §7.1.1.
const _CARTESIAN_CANONICAL_NAMES = ("i", "j", "k", "l", "m")

"""
    materialize(sel::CartesianSelector, target::Vector{Expr}, axis_pos::Int) -> Vector{Expr}

Materialize a cartesian selector at the given target index list per
RFC §7.2 row 1: replace the component at `axis_pos` with
`{op: "+", args: [target[axis_pos], offset]}`; pass the rest through
unchanged. `axis_pos` is the 1-based position of the selector's axis
within the grid's dimension-declaration order (per §7.1.1's "dimension
name → \$target component" mapping).
"""
function materialize(sel::CartesianSelector, target::Vector{Expr},
                     axis_pos::Int)::Vector{Expr}
    1 <= axis_pos <= length(target) || throw(RuleEngineError(
        "E_SCHEME_MATERIALIZE",
        "cartesian selector axis position $axis_pos out of range " *
        "[1,$(length(target))]"))
    out = Vector{Expr}(undef, length(target))
    for (i, comp) in enumerate(target)
        if i == axis_pos
            out[i] = OpExpr("+", Expr[comp, IntExpr(sel.offset)])
        else
            out[i] = comp
        end
    end
    return out
end

# ============================================================================
# Scheme expansion — entry point invoked from the rule engine
# ============================================================================

"""
    expand_scheme(scheme, bindings, ctx) -> Expr

Apply a §7 scheme at the rule's bound subtree. `bindings` carries the
pattern-variable substitution from rule matching (`\$u`, `\$x`, `\$target`,
…). `ctx.grids` and `ctx.variables` provide the grid metadata needed to
resolve canonical \$target component names (§7.1.1) and to choose the
operand variable's spatial-dim order.

Returns the lowered AST per §7.2:
`combine_k(coeff_k * operand_ref_k)`.

Throws [`RuleEngineError`](@ref) with code `E_SCHEME_MISMATCH` when the
scheme's `applies_to` cannot be reconciled with the rule's bindings, or
`E_SCHEME_MATERIALIZE` when target/grid metadata is insufficient to
resolve a selector.
"""
function expand_scheme(scheme::Scheme,
                       bindings::Dict{String,Expr},
                       ctx::RuleContext)::Expr
    operand_var = _scheme_operand(scheme, bindings)
    grid_name = _operand_grid(operand_var, ctx)
    spatial_dims = _grid_spatial_dims(grid_name, ctx)
    target = _cartesian_target(spatial_dims)

    # §6.2.1 — extract nonuniform dims and metric array names from grid metadata
    _gm = get(ctx.grids, grid_name, nothing)
    _nonuniform_dims = _gm !== nothing ? get(_gm, "nonuniform_dims", String[]) : String[]
    _metric_names = _gm !== nothing ? get(_gm, "metric_array_names", String[]) : String[]

    # For from_grid stencil_gen: auto-register __stgfw_ weight array names so
    # _rewrite_metric_refs can index them to index(__stgfw_…, i) during expansion.
    _metric_names = _augment_metric_names_stgfw(scheme, bindings, _metric_names)

    # RFC §7.9 trigger 2: demand-driven provider resolution.
    requires_subs = Dict{String,String}()
    if !isempty(scheme.requires)
        for (local_name, ref) in scheme.requires
            parts = split(ref, '#'; limit=2)
            provider_name = String(parts[1])
            output_name   = String(parts[2])
            provider = ctx.schemes[provider_name]::MultiOutputStencilScheme
            mangled = _demand_resolve_provider(provider, bindings, ctx)
            requires_subs[local_name] = mangled[output_name]
        end
    end

    terms = Expr[_expand_stencil_entry(scheme, e, operand_var, target,
                                       spatial_dims, bindings,
                                       _nonuniform_dims, _metric_names,
                                       requires_subs)
                 for e in scheme.stencil]

    if length(terms) == 1
        return terms[1]
    end
    return OpExpr(scheme.combine, terms)
end

function _scheme_operand(scheme::Scheme, bindings::Dict{String,Expr})::Expr
    pat = scheme.applies_to
    pat isa OpExpr || throw(RuleEngineError("E_SCHEME_MISMATCH",
        "scheme $(scheme.name): applies_to must be an op node"))
    isempty(pat.args) && throw(RuleEngineError("E_SCHEME_MISMATCH",
        "scheme $(scheme.name): applies_to has no args; cannot identify operand"))
    operand_pat = pat.args[1]
    operand_pat isa VarExpr && _is_pvar(operand_pat) || throw(RuleEngineError(
        "E_SCHEME_MISMATCH",
        "scheme $(scheme.name): applies_to first arg must be a pattern variable " *
        "(e.g. \$u)"))
    pname = operand_pat.name
    haskey(bindings, pname) || throw(RuleEngineError("E_SCHEME_MISMATCH",
        "scheme $(scheme.name): operand pattern variable $pname not bound by " *
        "rule pattern"))
    return bindings[pname]
end

function _operand_grid(operand::Expr, ctx::RuleContext)::String
    name = operand isa VarExpr ? operand.name : nothing
    name === nothing && throw(RuleEngineError("E_SCHEME_MATERIALIZE",
        "operand of a cartesian scheme must be a bare variable reference; " *
        "complex AST operands are not yet supported"))
    meta = get(ctx.variables, name, nothing)
    meta === nothing && throw(RuleEngineError("E_SCHEME_MATERIALIZE",
        "operand variable `$name` not present in RuleContext.variables"))
    grid = get(meta, "grid", nothing)
    grid === nothing && throw(RuleEngineError("E_SCHEME_MATERIALIZE",
        "operand variable `$name` has no associated grid metadata"))
    return String(grid)
end

function _grid_spatial_dims(grid_name::String, ctx::RuleContext)::Vector{String}
    meta = get(ctx.grids, grid_name, nothing)
    meta === nothing && throw(RuleEngineError("E_SCHEME_MATERIALIZE",
        "grid `$grid_name` not present in RuleContext.grids"))
    dims = get(meta, "spatial_dims", nothing)
    (dims isa AbstractVector && !isempty(dims)) || throw(RuleEngineError(
        "E_SCHEME_MATERIALIZE",
        "grid `$grid_name` has no spatial_dims metadata"))
    return String[String(d) for d in dims]
end

function _cartesian_target(spatial_dims::Vector{String})::Vector{Expr}
    n = length(spatial_dims)
    n <= length(_CARTESIAN_CANONICAL_NAMES) || throw(RuleEngineError(
        "E_SCHEME_MATERIALIZE",
        "cartesian schemes support up to $(length(_CARTESIAN_CANONICAL_NAMES)) " *
        "dimensions per RFC §7.1.1; grid has $n"))
    return Expr[VarExpr(_CARTESIAN_CANONICAL_NAMES[i]) for i in 1:n]
end

function _expand_stencil_entry(scheme::Scheme, entry::StencilEntry,
                               operand_var::Expr, target::Vector{Expr},
                               spatial_dims::Vector{String},
                               bindings::Dict{String,Expr},
                               nonuniform_dims::Vector{String}=String[],
                               metric_array_names::Vector{String}=String[],
                               requires_subs::Dict{String,String}=Dict{String,String}())::Expr
    sel = entry.selector
    sel isa CartesianSelector || throw(RuleEngineError("E_SCHEME_MATERIALIZE",
        "scheme $(scheme.name): non-cartesian selectors not supported in this " *
        "binding yet"))
    axis_name = _resolve_axis_pvar(scheme, sel.axis, bindings)
    axis_pos = findfirst(==(axis_name), spatial_dims)
    axis_pos === nothing && throw(RuleEngineError("E_SCHEME_MATERIALIZE",
        "scheme $(scheme.name): selector axis `$axis_name` not in grid " *
        "spatial_dims $(spatial_dims)"))

    indices = materialize(sel, target, axis_pos)
    operand_ref = OpExpr("index", Expr[operand_var, indices...])

    coeff = apply_bindings(entry.coeff, bindings)

    # For from_grid stencil_gen entries: resolve the axis pvar embedded in the
    # __stgfw_ weight array name (e.g. __stgfw_$z_2_n1 → __stgfw_z_2_n1).
    if coeff isa VarExpr && startswith(coeff.name, "__stgfw_")
        coeff = VarExpr(replace(coeff.name, sel.axis => axis_name))
    end

    # Substitute provider-emitted names for their local aliases in coefficients.
    if !isempty(requires_subs)
        coeff = _apply_requires_substitution(coeff, requires_subs)
    end

    # §6.2.1 — auto-index rewrite: metric-array names → index(name, target_idx).
    # Triggers for (a) any nonuniform metric array and (b) __stgfw_ weight arrays
    # regardless of whether the axis appears in nonuniform_dims.
    needs_rewrite = !isempty(metric_array_names) &&
        (axis_name in nonuniform_dims ||
         (coeff isa VarExpr && startswith(coeff.name, "__stgfw_")))
    if needs_rewrite
        coeff = _rewrite_metric_refs(coeff, metric_array_names, target[axis_pos])
    end

    return OpExpr("*", Expr[coeff, operand_ref])
end

function _resolve_axis_pvar(scheme::Scheme, axis::String,
                            bindings::Dict{String,Expr})::String
    if _is_pvar_string(axis)
        haskey(bindings, axis) || throw(RuleEngineError("E_SCHEME_MISMATCH",
            "scheme $(scheme.name): axis pattern variable `$axis` is not bound " *
            "by rule pattern"))
        v = bindings[axis]
        v isa VarExpr || throw(RuleEngineError("E_SCHEME_MISMATCH",
            "scheme $(scheme.name): axis pattern variable `$axis` must bind a " *
            "bare name; got $(typeof(v))"))
        return v.name
    end
    return axis
end

# ============================================================================
# Multi-output stencil — trigger 1 (directly-consumed path, RFC §7.9, ess-ebe)
# ============================================================================

# Extract the bound operand expression from a MultiOutputStencilScheme's
# applies_to. The first arg of applies_to must be a pattern variable.
function _scheme_operand_multi(scheme::MultiOutputStencilScheme,
                                bindings::Dict{String,Expr})::Expr
    pat = scheme.applies_to
    pat isa OpExpr || throw(RuleEngineError("E_SCHEME_MISMATCH",
        "scheme $(scheme.name): applies_to must be an op node"))
    isempty(pat.args) && throw(RuleEngineError("E_SCHEME_MISMATCH",
        "scheme $(scheme.name): applies_to has no args; cannot identify operand"))
    operand_pat = pat.args[1]
    operand_pat isa VarExpr && _is_pvar(operand_pat) || throw(RuleEngineError(
        "E_SCHEME_MISMATCH",
        "scheme $(scheme.name): applies_to first arg must be a pattern variable"))
    pname = operand_pat.name
    haskey(bindings, pname) || throw(RuleEngineError("E_SCHEME_MISMATCH",
        "scheme $(scheme.name): operand pattern variable $pname not bound by rule"))
    return bindings[pname]
end

# Return the string value of the bound axis dimension (from applies_to.dim),
# or nothing if the scheme has no dim pvar.
function _scheme_axis_name(scheme::AbstractScheme,
                            bindings::Dict{String,Expr})::Union{String,Nothing}
    pat = scheme.applies_to
    pat isa OpExpr || return nothing
    pat.dim === nothing && return nothing
    if _is_pvar_string(pat.dim)
        haskey(bindings, pat.dim) || return nothing
        v = bindings[pat.dim]
        v isa VarExpr || return nothing
        return v.name
    end
    return pat.dim
end

# Mangle an output name per the RFC §7.9 convention:
#   <output>__<operand>[__<axis>]
function _mangle_output_name(output::String, operand::String,
                              axis::Union{String,Nothing})::String
    axis === nothing && return "$(output)__$(operand)"
    return "$(output)__$(operand)__$(axis)"
end

# Stable memoization key: "<scheme>:<output>=<mangled>, ..." (sorted by output).
function _emit_memokey(scheme_name::String,
                        mangled::Dict{String,String})::String
    parts = sort!(["$(k)=$(v)" for (k, v) in mangled])
    return scheme_name * ":" * join(parts, ",")
end

# Expand one stencil entry from a MultiOutputStencilScheme output.
# Mirrors _expand_stencil_entry but accepts the scheme by its concrete type
# to allow error messages that name the output.
function _expand_stencil_entry_multi(scheme::MultiOutputStencilScheme,
                                      output_name::String,
                                      entry::StencilEntry,
                                      operand_var::Expr,
                                      target::Vector{Expr},
                                      spatial_dims::Vector{String},
                                      bindings::Dict{String,Expr},
                                      nonuniform_dims::Vector{String}=String[],
                                      metric_array_names::Vector{String}=String[])::Expr
    sel = entry.selector
    sel isa CartesianSelector || throw(RuleEngineError("E_SCHEME_MATERIALIZE",
        "scheme $(scheme.name) output $output_name: " *
        "non-cartesian selectors not yet supported"))
    axis_name = if _is_pvar_string(sel.axis)
        haskey(bindings, sel.axis) || throw(RuleEngineError("E_SCHEME_MISMATCH",
            "scheme $(scheme.name): axis pvar `$(sel.axis)` not bound"))
        v = bindings[sel.axis]
        v isa VarExpr || throw(RuleEngineError("E_SCHEME_MISMATCH",
            "scheme $(scheme.name): axis pvar `$(sel.axis)` must bind a bare name"))
        v.name
    else
        sel.axis
    end
    axis_pos = findfirst(==(axis_name), spatial_dims)
    axis_pos === nothing && throw(RuleEngineError("E_SCHEME_MATERIALIZE",
        "scheme $(scheme.name) output $output_name: selector axis " *
        "`$axis_name` not in grid spatial_dims $spatial_dims"))
    indices = materialize(sel, target, axis_pos)
    operand_ref = OpExpr("index", Expr[operand_var, indices...])
    coeff = apply_bindings(entry.coeff, bindings)
    if !isempty(metric_array_names) && axis_name in nonuniform_dims
        coeff = _rewrite_metric_refs(coeff, metric_array_names, target[axis_pos])
    end
    return OpExpr("*", Expr[coeff, operand_ref])
end

"""
    expand_multi_output_scheme_direct(scheme, bindings, ctx) -> Expr

Implement RFC §7.9 trigger 1 (directly-consumed path): called by the rule
engine when a `use:` rule fires on a `MultiOutputStencilScheme` with a
non-null `primary`.

Emits one observed arrayop equation per declared output into
`ctx.emitted_equations`, auto-declares the output variables into
`ctx.emitted_variables`, and returns an `index(primary_output, i, …)` Expr
that the rule engine substitutes at the matched expression site.

Expansion is memoized by `(scheme, mangled_output_names)` so that if the
same operand/axis binding fires twice in one document, the observed equations
are only emitted once.

V1 scope: periodic dimensions only. Throws `E_SCHEME_BOUNDED_DIM` for any
non-periodic spatial dimension (OQ1 follow-on bead).
"""
function expand_multi_output_scheme_direct(scheme::MultiOutputStencilScheme,
                                            bindings::Dict{String,Expr},
                                            ctx::RuleContext)::Expr
    # 1. Recover operand.
    operand_expr = _scheme_operand_multi(scheme, bindings)
    operand_expr isa VarExpr || throw(RuleEngineError("E_SCHEME_MATERIALIZE",
        "scheme $(scheme.name): operand must be a bare variable reference " *
        "for multi_output_stencil expansion"))
    operand_name = operand_expr.name

    # 2. Grid metadata.
    grid_name    = _operand_grid(operand_expr, ctx)
    spatial_dims = _grid_spatial_dims(grid_name, ctx)
    gmeta        = ctx.grids[grid_name]
    periodic_dims = String.(get(gmeta, "periodic_dims", String[]))
    dim_sizes    = get(gmeta, "dim_sizes", Dict{String,Any}())

    # 3. (OQ1 resolved) Bounded dimensions are now supported; no restriction.

    # 4. Compute mangled output names.
    axis_name = _scheme_axis_name(scheme, bindings)
    mangled = Dict{String,String}(
        o => _mangle_output_name(o, operand_name, axis_name)
        for o in scheme.outputs)

    # 5. Memoization — skip emission if already done for this instantiation.
    memo_key = _emit_memokey(scheme.name, mangled)
    if !(memo_key in ctx.emitted_scheme_keys)
        push!(ctx.emitted_scheme_keys, memo_key)

        # 6. Shared stencil infrastructure.
        nd          = length(spatial_dims)
        target      = _cartesian_target(spatial_dims)
        nonuniform  = String.(get(gmeta, "nonuniform_dims", String[]))
        metric_arr  = String.(get(gmeta, "metric_array_names", String[]))
        output_idx  = String[_CARTESIAN_CANONICAL_NAMES[d] for d in 1:nd]
        is_face     = !isnothing(scheme.emits_location) &&
                      scheme.emits_location == "face"
        ranges      = Dict{String,Any}()
        for d in 1:nd
            dim_name = spatial_dims[d]
            sz = get(dim_sizes, dim_name, nothing)
            sz === nothing && throw(RuleEngineError("E_SCHEME_MATERIALIZE",
                "scheme $(scheme.name): grid '$grid_name' missing size for " *
                "dim '$dim_name'"))
            # Face-located output on a bounded axis has n+1 faces (OQ1, RFC §7.9).
            face_staggered = is_face && !(dim_name in periodic_dims) &&
                             !isnothing(axis_name) && dim_name == axis_name
            ranges[output_idx[d]] = Any[1, face_staggered ? Int(sz) + 1 : Int(sz)]
        end

        # 7. Emit one observed arrayop equation per stencil output.
        for out_name in scheme.outputs
            haskey(scheme.stencil, out_name) || continue
            entries    = scheme.stencil[out_name]
            terms      = Expr[_expand_stencil_entry_multi(scheme, out_name, e,
                                   operand_expr, target, spatial_dims, bindings,
                                   nonuniform, metric_arr)
                               for e in entries]
            rhs_scalar = length(terms) == 1 ? terms[1] : OpExpr("+", terms)
            rhs_canon  = canonicalize(rhs_scalar)
            rhs_dict   = serialize_expression(rhs_canon)

            mn = mangled[out_name]
            lhs_index_args = Any[mn]
            for idx in output_idx; push!(lhs_index_args, idx); end

            eqn = Dict{String,Any}(
                "lhs" => Dict{String,Any}(
                    "op"         => "arrayop",
                    "args"       => Any[],
                    "output_idx" => output_idx,
                    "expr"       => Dict{String,Any}(
                        "op"   => "index",
                        "args" => lhs_index_args,
                    ),
                    "ranges" => Dict{String,Any}(k => v for (k, v) in ranges),
                ),
                "rhs" => Dict{String,Any}(
                    "op"         => "arrayop",
                    "args"       => Any[],
                    "output_idx" => output_idx,
                    "expr"       => rhs_dict,
                    "ranges" => Dict{String,Any}(k => v for (k, v) in ranges),
                ),
                "observed"   => true,
                "emitted_by" => scheme.name,
            )
            push!(ctx.emitted_equations, eqn)

            # Auto-declare the output variable.
            operand_meta   = get(ctx.variables, operand_name, Dict{String,Any}())
            operand_shape  = get(operand_meta, "shape", Any[String(d) for d in spatial_dims])
            emit_loc       = scheme.emits_location === nothing ? "cell_center" :
                             scheme.emits_location
            ctx.emitted_variables[mn] = Dict{String,Any}(
                "type"     => "observed",
                "units"    => "1",
                "shape"    => operand_shape,
                "location" => emit_loc,
            )
        end

        # 7b. Emit one observed arrayop equation per derived output (RFC §7.9 OQ3).
        # Derived expressions reference stencil output names; substitute each with
        # index(mangled_name, target...) so the RHS is a pointwise scalar expression.
        if !isempty(scheme.derived)
            stencil_subs = Dict{String,String}(
                o => mangled[o] for o in scheme.outputs if haskey(scheme.stencil, o))
            operand_meta  = get(ctx.variables, operand_name, Dict{String,Any}())
            operand_shape = get(operand_meta, "shape", Any[String(d) for d in spatial_dims])
            emit_loc      = scheme.emits_location === nothing ? "cell_center" :
                            scheme.emits_location
            for d_name in scheme.outputs
                haskey(scheme.derived, d_name) || continue
                d_expr = scheme.derived[d_name]
                d_mn   = mangled[d_name]
                rhs_scalar = _apply_derived_substitution(
                    apply_bindings(d_expr, bindings), stencil_subs, target)
                rhs_canon  = canonicalize(rhs_scalar)
                rhs_dict   = serialize_expression(rhs_canon)
                lhs_index_args = Any[d_mn]
                for idx in output_idx; push!(lhs_index_args, idx); end
                eqn = Dict{String,Any}(
                    "lhs" => Dict{String,Any}(
                        "op"         => "arrayop",
                        "args"       => Any[],
                        "output_idx" => output_idx,
                        "expr"       => Dict{String,Any}(
                            "op"   => "index",
                            "args" => lhs_index_args,
                        ),
                        "ranges" => Dict{String,Any}(k => v for (k, v) in ranges),
                    ),
                    "rhs" => Dict{String,Any}(
                        "op"         => "arrayop",
                        "args"       => Any[],
                        "output_idx" => output_idx,
                        "expr"       => rhs_dict,
                        "ranges" => Dict{String,Any}(k => v for (k, v) in ranges),
                    ),
                    "observed"   => true,
                    "emitted_by" => scheme.name,
                )
                push!(ctx.emitted_equations, eqn)
                ctx.emitted_variables[d_mn] = Dict{String,Any}(
                    "type"     => "observed",
                    "units"    => "1",
                    "shape"    => operand_shape,
                    "location" => emit_loc,
                )
            end
        end
    end

    # 8. Return index(primary_mangled, i[, j, …]) as the replacement Expr.
    primary_mn = mangled[scheme.primary]
    idx_args   = Expr[VarExpr(primary_mn)]
    for idx in String[_CARTESIAN_CANONICAL_NAMES[d] for d in 1:length(spatial_dims)]
        push!(idx_args, VarExpr(idx))
    end
    return OpExpr("index", idx_args)
end

# ============================================================================
# Multi-output stencil — trigger 2 (demand-driven provider, RFC §7.9, ess-699)
# ============================================================================

# Walk `expr` and replace bare VarExpr names found in `subs` with the
# corresponding mangled name. Pattern variables ($-prefixed) are untouched —
# apply_bindings handles those before this runs.
function _apply_requires_substitution(expr::Expr,
                                       subs::Dict{String,String})::Expr
    isempty(subs) && return expr
    if expr isa VarExpr && !_is_pvar(expr) && haskey(subs, expr.name)
        return VarExpr(subs[expr.name])
    end
    if expr isa OpExpr
        changed = false
        new_args = Expr[]
        for a in expr.args
            na = _apply_requires_substitution(a, subs)
            push!(new_args, na)
            na !== a && (changed = true)
        end
        changed || return expr
        return OpExpr(expr.op, new_args;
                      wrt=expr.wrt, dim=expr.dim,
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

# Replace bare VarExpr names found in `subs` with `index(mangled_name, target...)`.
# Used to expand derived output expressions, where each stencil output name is
# replaced by an indexed reference at the current arrayop target indices.
# Pattern variables ($-prefixed) are untouched — apply_bindings handles those first.
function _apply_derived_substitution(expr::Expr,
                                      subs::Dict{String,String},
                                      target::Vector{Expr})::Expr
    isempty(subs) && return expr
    if expr isa VarExpr && !_is_pvar(expr) && haskey(subs, expr.name)
        mn = subs[expr.name]
        return OpExpr("index", Expr[VarExpr(mn), target...])
    end
    if expr isa OpExpr
        changed = false
        new_args = Expr[]
        for a in expr.args
            na = _apply_derived_substitution(a, subs, target)
            push!(new_args, na)
            na !== a && (changed = true)
        end
        changed || return expr
        return OpExpr(expr.op, new_args;
                      wrt=expr.wrt, dim=expr.dim,
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

"""
    _demand_resolve_provider(provider, bindings, ctx) -> Dict{String,String}

RFC §7.9 trigger 2 — demand-driven provider instantiation. Called from
`expand_scheme` when a consumer `Scheme` carries a non-empty `requires` map.

Uses the consumer's inherited `bindings` to determine the provider's operand
and axis (§7.2.1 name-flow, same mechanism as sibling-scheme refs in
`dimensional_split` and `cross_metric`). Emits one observed arrayop equation
per declared output into `ctx.emitted_equations` and auto-declares the output
variables into `ctx.emitted_variables`.

Memoized by `(provider.name, mangled_output_names)` via `ctx.emitted_scheme_keys`
so that diamond deps (two consumers sharing a provider) emit exactly once.

Returns `Dict{String,String}` mapping each declared output name to its
mangled variable name (`<output>__<operand>[__<axis>]`).

Throws:
- `E_SCHEME_CYCLE` if `provider.name` is already on `ctx.provider_resolution_stack`.
- `E_SCHEME_BOUNDED_DIM` for non-periodic spatial dimensions (v1 scope).
- `E_PROVIDER_NAME_CLASH` if a mangled name is already owned by a different provider.
"""
function _demand_resolve_provider(provider::MultiOutputStencilScheme,
                                   bindings::Dict{String,Expr},
                                   ctx::RuleContext)::Dict{String,String}
    # 1. Recover operand from consumer's inherited bindings.
    operand_expr = _scheme_operand_multi(provider, bindings)
    operand_expr isa VarExpr || throw(RuleEngineError("E_SCHEME_MATERIALIZE",
        "scheme $(provider.name): provider operand must be a bare variable reference"))
    operand_name = operand_expr.name

    # 2. Grid metadata.
    grid_name    = _operand_grid(operand_expr, ctx)
    spatial_dims = _grid_spatial_dims(grid_name, ctx)
    gmeta        = ctx.grids[grid_name]
    periodic_dims = String.(get(gmeta, "periodic_dims", String[]))

    # 3. (OQ1 resolved) Bounded dimensions are now supported; no restriction.

    # 4. Compute mangled output names.
    axis_name = _scheme_axis_name(provider, bindings)
    mangled = Dict{String,String}(
        o => _mangle_output_name(o, operand_name, axis_name)
        for o in provider.outputs)

    # 5. Memoization: if already instantiated with this binding set, return cached result.
    memo_key = _emit_memokey(provider.name, mangled)
    memo_key in ctx.emitted_scheme_keys && return mangled

    # 6. Cycle detection (only relevant for not-yet-memoized instantiation).
    if provider.name in ctx.provider_resolution_stack
        stack_list = join(sort!(collect(ctx.provider_resolution_stack)), ", ")
        throw(RuleEngineError("E_SCHEME_CYCLE",
            "demand-driven provider resolution cycle: scheme '$(provider.name)' is " *
            "already being resolved (stack: $stack_list)"))
    end

    # 7. Mark in-progress: add to resolution stack and memo set before emitting.
    push!(ctx.provider_resolution_stack, provider.name)
    push!(ctx.emitted_scheme_keys, memo_key)
    try
        dim_sizes   = get(gmeta, "dim_sizes", Dict{String,Any}())
        nd          = length(spatial_dims)
        target      = _cartesian_target(spatial_dims)
        nonuniform  = String.(get(gmeta, "nonuniform_dims", String[]))
        metric_arr  = String.(get(gmeta, "metric_array_names", String[]))
        output_idx  = String[_CARTESIAN_CANONICAL_NAMES[d] for d in 1:nd]
        is_face     = !isnothing(provider.emits_location) &&
                      provider.emits_location == "face"
        ranges      = Dict{String,Any}()
        for d in 1:nd
            dim_name = spatial_dims[d]
            sz = get(dim_sizes, dim_name, nothing)
            sz === nothing && throw(RuleEngineError("E_SCHEME_MATERIALIZE",
                "scheme $(provider.name): grid '$grid_name' missing size for " *
                "dim '$dim_name'"))
            # Face-located output on a bounded axis has n+1 faces (OQ1, RFC §7.9).
            face_staggered = is_face && !(dim_name in periodic_dims) &&
                             !isnothing(axis_name) && dim_name == axis_name
            ranges[output_idx[d]] = Any[1, face_staggered ? Int(sz) + 1 : Int(sz)]
        end

        operand_meta  = get(ctx.variables, operand_name, Dict{String,Any}())
        operand_shape = get(operand_meta, "shape", Any[String(d) for d in spatial_dims])
        emit_loc      = provider.emits_location === nothing ? "cell_center" :
                        provider.emits_location

        # Emit stencil outputs first (derived outputs may reference their mangled names).
        for out_name in provider.outputs
            haskey(provider.stencil, out_name) || continue
            mn = mangled[out_name]

            # Pre-declared variable: author supplied it in the document; skip emission.
            mn in keys(ctx.variables) && continue

            # Clash: a different instantiation already emitted this mangled name.
            if mn in keys(ctx.emitted_variables)
                throw(RuleEngineError("E_PROVIDER_NAME_CLASH",
                    "scheme $(provider.name): mangled output name '$mn' was already " *
                    "emitted by a different provider instantiation"))
            end

            entries    = provider.stencil[out_name]
            terms      = Expr[_expand_stencil_entry_multi(provider, out_name, e,
                                   operand_expr, target, spatial_dims, bindings,
                                   nonuniform, metric_arr)
                               for e in entries]
            rhs_scalar = length(terms) == 1 ? terms[1] : OpExpr("+", terms)
            rhs_canon  = canonicalize(rhs_scalar)
            rhs_dict   = serialize_expression(rhs_canon)

            lhs_index_args = Any[mn]
            for idx in output_idx; push!(lhs_index_args, idx); end

            eqn = Dict{String,Any}(
                "lhs" => Dict{String,Any}(
                    "op"         => "arrayop",
                    "args"       => Any[],
                    "output_idx" => output_idx,
                    "expr"       => Dict{String,Any}(
                        "op"   => "index",
                        "args" => lhs_index_args,
                    ),
                    "ranges" => Dict{String,Any}(k => v for (k, v) in ranges),
                ),
                "rhs" => Dict{String,Any}(
                    "op"         => "arrayop",
                    "args"       => Any[],
                    "output_idx" => output_idx,
                    "expr"       => rhs_dict,
                    "ranges" => Dict{String,Any}(k => v for (k, v) in ranges),
                ),
                "observed"   => true,
                "emitted_by" => provider.name,
            )
            push!(ctx.emitted_equations, eqn)
            ctx.emitted_variables[mn] = Dict{String,Any}(
                "type"     => "observed",
                "units"    => "1",
                "shape"    => operand_shape,
                "location" => emit_loc,
            )
        end

        # Emit derived outputs (RFC §7.9 OQ3).
        if !isempty(provider.derived)
            stencil_subs = Dict{String,String}(
                o => mangled[o] for o in provider.outputs if haskey(provider.stencil, o))
            for d_name in provider.outputs
                haskey(provider.derived, d_name) || continue
                d_mn = mangled[d_name]
                d_mn in keys(ctx.variables) && continue
                if d_mn in keys(ctx.emitted_variables)
                    throw(RuleEngineError("E_PROVIDER_NAME_CLASH",
                        "scheme $(provider.name): mangled derived output name '$d_mn' " *
                        "was already emitted by a different provider instantiation"))
                end
                d_expr     = provider.derived[d_name]
                rhs_scalar = _apply_derived_substitution(
                    apply_bindings(d_expr, bindings), stencil_subs, target)
                rhs_canon  = canonicalize(rhs_scalar)
                rhs_dict   = serialize_expression(rhs_canon)
                lhs_index_args = Any[d_mn]
                for idx in output_idx; push!(lhs_index_args, idx); end
                eqn = Dict{String,Any}(
                    "lhs" => Dict{String,Any}(
                        "op"         => "arrayop",
                        "args"       => Any[],
                        "output_idx" => output_idx,
                        "expr"       => Dict{String,Any}(
                            "op"   => "index",
                            "args" => lhs_index_args,
                        ),
                        "ranges" => Dict{String,Any}(k => v for (k, v) in ranges),
                    ),
                    "rhs" => Dict{String,Any}(
                        "op"         => "arrayop",
                        "args"       => Any[],
                        "output_idx" => output_idx,
                        "expr"       => rhs_dict,
                        "ranges" => Dict{String,Any}(k => v for (k, v) in ranges),
                    ),
                    "observed"   => true,
                    "emitted_by" => provider.name,
                )
                push!(ctx.emitted_equations, eqn)
                ctx.emitted_variables[d_mn] = Dict{String,Any}(
                    "type"     => "observed",
                    "units"    => "1",
                    "shape"    => operand_shape,
                    "location" => emit_loc,
                )
            end
        end
    finally
        delete!(ctx.provider_resolution_stack, provider.name)
    end

    return mangled
end

# ============================================================================
# §6.2.1 — rewrite bare metric-array VarExpr nodes to indexed form.
# Bare name "dz" in a nonuniform dimension → OpExpr("index", [VarExpr("dz"), target_idx]).
# Existing index nodes (already-explicit array accesses) are passed through unchanged,
# so the author-written neighbor index dz[k+1] is never double-wrapped.
function _rewrite_metric_refs(expr::Expr, metric_names::Vector{String},
                               target_idx::Expr)::Expr
    if expr isa VarExpr && expr.name in metric_names
        return OpExpr("index", Expr[expr, target_idx])
    elseif expr isa OpExpr && expr.op == "index"
        return expr  # already an explicit index reference — pass through
    elseif expr isa OpExpr
        new_args = Expr[_rewrite_metric_refs(a, metric_names, target_idx)
                        for a in expr.args]
        return OpExpr(expr.op, new_args;
                      wrt=expr.wrt, dim=expr.dim, output_idx=expr.output_idx,
                      expr_body=expr.expr_body, reduce=expr.reduce,
                      ranges=expr.ranges, regions=expr.regions,
                      values=expr.values, shape=expr.shape, perm=expr.perm,
                      axis=expr.axis, fn=expr.fn, name=expr.name, value=expr.value)
    end
    return expr
end

# ============================================================================
# stencil_gen — declarative FD weight generation via Fornberg recurrence
# ============================================================================

# Scan `scheme.stencil` for __stgfw_ weight array VarExpr coefficients (produced by
# _expand_stencil_gen with spacing="from_grid") and return an augmented copy of
# `base_names` that includes the resolved weight array names.  Resolving the axis pvar
# (e.g. "$z" → "z") is necessary before _rewrite_metric_refs can match the names.
function _augment_metric_names_stgfw(scheme::Scheme, bindings::Dict{String,Expr},
                                      base_names::Vector{String})::Vector{String}
    extra = String[]
    for entry in scheme.stencil
        entry.coeff isa VarExpr || continue
        startswith(entry.coeff.name, "__stgfw_") || continue
        sel = entry.selector
        sel isa CartesianSelector || continue
        axis_name = _resolve_axis_pvar(scheme, sel.axis, bindings)
        resolved = replace(entry.coeff.name, sel.axis => axis_name)
        resolved in base_names && continue
        resolved in extra && continue
        push!(extra, resolved)
    end
    isempty(extra) && return base_names
    return vcat(base_names, extra)
end

"""
    _stgfw_name(axis, accuracy_order, offset) -> String

Return the canonical name for a per-location Fornberg weight array generated by
`stencil_gen` with `spacing="from_grid"`. Convention:

    __stgfw_{axis}_{accuracy_order}_{sign}{|offset|}

where `sign` is `"n"` for negative offsets and `"p"` for positive.
Example: axis="z", accuracy_order=4, offset=-2  →  `"__stgfw_z_4_n2"`
"""
function _stgfw_name(axis::String, accuracy_order::Int, offset::Int)::String
    sign_str = offset < 0 ? "n$(abs(offset))" : "p$(offset)"
    return "__stgfw_$(axis)_$(accuracy_order)_$(sign_str)"
end

"""
    _fornberg_weights_float(z, x, m) -> Vector{Float64}

Compute finite-difference weights for the `m`-th derivative at evaluation
point `z` given node positions `x`, using the Fornberg (1988) recurrence
(Algorithm 1 from "Generation of Finite Difference Formulas on Arbitrarily
Spaced Grids", Mathematics of Computation 51, 699–706).

The evaluation order follows the canonical loop structure of Fornberg (1988)
Eq. (3.1). Cross-language implementations MUST reproduce this same evaluation
order and IEEE 754 double-precision arithmetic for conformance.

Returns: `w` where `w[i]` is the weight for node `x[i]` in the approximation
`f^(m)(z) ≈ Σ_i w[i] * f(x[i])`.
"""
function _fornberg_weights_float(z::Float64, x::AbstractVector{<:Real}, m::Int)::Vector{Float64}
    N = length(x)
    m < N || error("derivative order m=$m must be < N=$N nodes")
    c = zeros(Float64, N, m + 1)
    c[1, 1] = 1.0
    c1 = 1.0
    c4 = Float64(x[1]) - z
    for n in 2:N
        mn = min(n - 1, m)
        c2 = 1.0
        c5 = c4
        c4 = Float64(x[n]) - z
        for ν in 1:n-1
            c3 = Float64(x[n]) - Float64(x[ν])
            c2 *= c3
            if ν == n - 1
                for s in mn:-1:1
                    c[n, s + 1] = c1 * (s * c[n-1, s] - c5 * c[n-1, s + 1]) / c2
                end
                c[n, 1] = -c1 * c5 * c[n-1, 1] / c2
            end
            for s in mn:-1:1
                c[ν, s + 1] = (c4 * c[ν, s + 1] - s * c[ν, s]) / c3
            end
            c[ν, 1] = c4 * c[ν, 1] / c3
        end
        c1 = c2
    end
    return c[:, m + 1]
end

"""
    _fornberg_centered_weights_int(accuracy_order) -> Vector{Tuple{Int,Int,Int}}

Exact integer representation of centered finite-difference weights for the
1st derivative on a uniform grid, using a common-denominator (LCM) form.

Returns a list of `(offset, numerator, denominator)` triples sorted by offset,
where `weight_at_offset = numerator / (denominator * h)` and `denominator` is
the LCM of all individual weights' denominators. This produces the same canonical
numerator/denominator pairs as hand-authored stencil files for orders 2, 4, 6, 8, …

Formula for k = 1, …, m (where m = accuracy_order ÷ 2):
  w_k = (-1)^(k+1) · (m!)² / [k · (m+k)! · (m-k)!]
  w_{-k} = -w_k  (antisymmetry of the 1st derivative)

Verified against tabulated values (Abramowitz & Stegun Table 25.2, Wikipedia).
"""
function _fornberg_centered_weights_int(accuracy_order::Int)::Vector{Tuple{Int,Int,Int}}
    iseven(accuracy_order) && accuracy_order >= 2 || error(
        "accuracy_order must be a positive even integer, got $accuracy_order")
    m = accuracy_order ÷ 2
    mfact = factorial(Int64(m))

    # Compute reduced rational weights for positive offsets
    weights_pos = Rational{Int64}[]
    for k in 1:m
        sgn = isodd(k) ? Int64(1) : Int64(-1)
        num = sgn * mfact * mfact
        den = Int64(k) * factorial(Int64(m + k)) * factorial(Int64(m - k))
        push!(weights_pos, Rational{Int64}(num, den))  # auto-reduces via gcd
    end

    # Common denominator: LCM of all reduced denominators
    denom_lcm = Int64(1)
    for w in weights_pos
        denom_lcm = lcm(denom_lcm, denominator(w))
    end

    # Build sorted (offset, int_numerator, denom_lcm) tuples
    result = Tuple{Int,Int,Int}[]
    for k in 1:m
        w   = weights_pos[k]
        int_num = Int64(numerator(w)) * div(denom_lcm, denominator(w))
        push!(result, (-k, -int_num, denom_lcm))   # negative offset
        push!(result, ( k,  int_num, denom_lcm))   # positive offset
    end
    sort!(result, by=first)
    return result
end

"""
    _expand_stencil_gen(scheme_name, grid_family, raw) -> Vector{StencilEntry}

Expand a `stencil_gen` descriptor into explicit [`StencilEntry`](@ref) objects at
parse time. The generated stencil entries are byte-identical in canonical JSON
to hand-authored stencils for the same family and accuracy order.

Supported: `method="fornberg"`, `deriv_order=1`, `stagger="centered"` (uniform
cartesian grid). One-sided stagger and higher derivative orders land in
follow-on bead ess-5b.
"""
function _expand_stencil_gen(scheme_name::String, grid_family::String,
                              raw)::Vector{StencilEntry}
    _is_dict_like(raw) || throw(RuleEngineError("E_SCHEME_PARSE",
        "scheme $scheme_name: stencil_gen must be an object"))

    # method
    method_raw = _getkey(raw, "method"; default=nothing)
    method_raw === nothing && throw(RuleEngineError("E_SCHEME_PARSE",
        "scheme $scheme_name: stencil_gen missing required field `method`"))
    method = String(method_raw)
    method == "fornberg" || throw(RuleEngineError("E_SCHEME_PARSE",
        "scheme $scheme_name: stencil_gen.method `$method` not supported " *
        "(supported: fornberg)"))

    # deriv_order
    deriv_raw = _getkey(raw, "deriv_order"; default=nothing)
    deriv_raw === nothing && throw(RuleEngineError("E_SCHEME_PARSE",
        "scheme $scheme_name: stencil_gen missing required field `deriv_order`"))
    deriv_raw isa Integer || throw(RuleEngineError("E_SCHEME_PARSE",
        "scheme $scheme_name: stencil_gen.deriv_order must be an integer"))
    deriv_order = Int(deriv_raw)
    deriv_order == 1 || throw(RuleEngineError("E_SCHEME_PARSE",
        "scheme $scheme_name: stencil_gen.deriv_order=$deriv_order not yet supported " *
        "(only 1 is implemented; higher orders land in follow-on bead ess-5b)"))

    # accuracy_order
    acc_raw = _getkey(raw, "accuracy_order"; default=nothing)
    acc_raw === nothing && throw(RuleEngineError("E_SCHEME_PARSE",
        "scheme $scheme_name: stencil_gen missing required field `accuracy_order`"))
    acc_raw isa Integer || throw(RuleEngineError("E_SCHEME_PARSE",
        "scheme $scheme_name: stencil_gen.accuracy_order must be an integer"))
    accuracy_order = Int(acc_raw)
    (iseven(accuracy_order) && accuracy_order >= 2) || throw(RuleEngineError("E_SCHEME_PARSE",
        "scheme $scheme_name: stencil_gen.accuracy_order must be a positive even integer, " *
        "got $accuracy_order"))

    # stagger
    stagger_raw = _getkey(raw, "stagger"; default=nothing)
    stagger_raw === nothing && throw(RuleEngineError("E_SCHEME_PARSE",
        "scheme $scheme_name: stencil_gen missing required field `stagger`"))
    stagger = String(stagger_raw)
    stagger == "centered" || throw(RuleEngineError("E_SCHEME_PARSE",
        "scheme $scheme_name: stencil_gen.stagger `$stagger` not supported " *
        "(supported: centered; onesided lands in follow-on bead ess-5b)"))

    # grid_family must be cartesian for stencil_gen
    grid_family == "cartesian" || throw(RuleEngineError("E_SCHEME_PARSE",
        "scheme $scheme_name: stencil_gen requires grid_family=cartesian " *
        "(got $grid_family)"))

    # axis
    axis_raw = _getkey(raw, "axis"; default=nothing)
    axis_raw === nothing && throw(RuleEngineError("E_SCHEME_PARSE",
        "scheme $scheme_name: stencil_gen missing required field `axis`"))
    axis = String(axis_raw)

    # spacing
    spacing_raw = _getkey(raw, "spacing"; default=nothing)
    spacing_raw === nothing && throw(RuleEngineError("E_SCHEME_PARSE",
        "scheme $scheme_name: stencil_gen missing required field `spacing`"))
    spacing = String(spacing_raw)

    if spacing == "from_grid"
        # Non-uniform grid path: generate stencil entries whose coefficients are
        # VarExpr references to per-location float weight arrays.  The actual
        # float values are computed from the grid node coordinates at ODE-build
        # time; expand_scheme auto-registers the array names as metric arrays so
        # _rewrite_metric_refs indexes them to index(__stgfw_…, i) at expand time.
        m = accuracy_order ÷ 2
        entries = StencilEntry[]
        for k in vcat(-m:-1, 1:m)
            coeff = VarExpr(_stgfw_name(axis, accuracy_order, k))
            push!(entries, StencilEntry(CartesianSelector(axis, k), coeff))
        end
        return entries
    end

    # Uniform path: Generate Fornberg weights in LCM-denominator integer form and
    # build StencilEntry objects with coeff = num / (den * spacing).
    weight_triples = _fornberg_centered_weights_int(accuracy_order)
    entries = StencilEntry[]
    for (offset, int_num, int_den) in weight_triples
        coeff = OpExpr("/", Expr[
            IntExpr(Int64(int_num)),
            OpExpr("*", Expr[IntExpr(Int64(int_den)), VarExpr(spacing)])
        ])
        push!(entries, StencilEntry(CartesianSelector(axis, offset), coeff))
    end
    return entries
end
