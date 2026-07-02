"""
Load-time resolution for esm-spec §9.7: template-library files, cross-file
`expression_template_imports`, and load-time `metaparameters`
(docs/content/rfcs/template-library-imports.md; esm-libraries-spec §2.1c).

Everything here resolves BEFORE the §9.6.3 rewrite fixpoint
(`lower_expression_templates`) and before any validator sees the tree.
Per document the order is innermost-first (esm-spec §9.7.6):

1. resolve imports (recursively, depth-first post-order, instantiating the
   imported subtree with the edge's metaparameter `bindings` at each edge);
2. merge imported `index_sets` into the document registry;
3. close and fold this document's metaparameters (loader-API bindings, then
   defaults; `metaparameter_unbound` if still open);
4. §9.7.3 registration-time body composition (`_compose_template_bodies!`,
   invoked per component from `lower_expression_templates`);
5. the §9.6.3 fixpoint on fully-concrete trees.

Round-trip is Option A: `expression_template_imports`, `metaparameters`, and
top-level `expression_templates` do not survive `parse → emit`; the emitted
form is the expanded, folded document.

All diagnostics are raised as [`ExpressionTemplateError`](@ref) with the
stable §9.6.6 codes so they are machine-checkable across bindings.
"""

using OrderedCollections: OrderedDict

"""
Maximum template-body reference-chain depth (counted in templates along the
longest chain, so a 33-template chain is rejected) before a file is rejected
with `template_body_expansion_too_deep` (esm-spec §9.7.3). Pinned identically
across all bindings.
"""
const MAX_TEMPLATE_EXPANSION_DEPTH = 32

const _COMPONENT_KINDS = ("models", "reaction_systems")

# A template-library file MUST NOT declare any of these (esm-spec §9.7.1).
const _LIBRARY_FORBIDDEN_KEYS =
    ("models", "reaction_systems", "data_loaders", "coupling", "domain")

_raw_get(x, key::String) = get(x, key, get(x, Symbol(key), nothing))
_raw_haskey(x, key::String) = haskey(x, key) || haskey(x, Symbol(key))

"""
    _to_ordered(x)

Deep-normalize a JSON view (JSON3.Object/Array or Dict/Vector) into
`OrderedDict{String,Any}` / `Vector{Any}` PRESERVING document key order —
unlike `_to_dict`, whose plain `Dict` loses it. Declaration order is normative
for the §9.6.3 tie-break, so every tree the import resolver builds is ordered.
"""
function _to_ordered(x)
    if _is_object(x)
        out = OrderedDict{String,Any}()
        for (k, v) in pairs(x)
            out[string(k)] = _to_ordered(v)
        end
        return out
    elseif _is_array(x)
        return Any[_to_ordered(v) for v in x]
    end
    return x
end

# ---------------------------------------------------------------------------
# Spec-version gate (esm-spec §9.6.5)
# ---------------------------------------------------------------------------

"""
    reject_template_imports_pre_v08(raw_data)

`expression_template_imports`, top-level `expression_templates`
(template-library files), and `metaparameters` arrive at `esm: 0.8.0`; files
declaring an earlier version that carry any of them are rejected with
`template_import_version_too_old` (esm-spec §9.6.5). Mirrors
[`reject_expression_templates_pre_v04`](@ref) for the §9.7 constructs.
"""
function reject_template_imports_pre_v08(raw_data)
    raw_data === nothing && return
    _is_object(raw_data) || return
    esm_raw = _raw_get(raw_data, "esm")
    esm_raw === nothing && return
    m = match(r"^(\d+)\.(\d+)\.(\d+)$", string(esm_raw))
    m === nothing && return
    major = parse(Int, m.captures[1])
    minor = parse(Int, m.captures[2])
    (major == 0 && minor < 8) || return

    offences = String[]
    _raw_haskey(raw_data, "expression_templates") && push!(offences, "/expression_templates")
    _raw_haskey(raw_data, "metaparameters") && push!(offences, "/metaparameters")
    _raw_haskey(raw_data, "expression_template_imports") &&
        push!(offences, "/expression_template_imports")
    for compkind in _COMPONENT_KINDS
        comps = _raw_get(raw_data, compkind)
        (comps !== nothing && _is_object(comps)) || continue
        for (cname, comp) in pairs(comps)
            _is_object(comp) || continue
            _raw_haskey(comp, "expression_template_imports") &&
                push!(offences, "/$compkind/$(string(cname))/expression_template_imports")
        end
    end
    isempty(offences) && return
    throw(ExpressionTemplateError(
        "template_import_version_too_old",
        "expression_template_imports / top-level expression_templates / metaparameters " *
        "require esm >= 0.8.0; file declares $(string(esm_raw)). " *
        "Offending paths: $(join(offences, ", "))"))
end

"""
    _is_template_library_doc(raw) -> Bool

True when `raw` has the template-library-file FORM (top-level
`expression_templates`, esm-spec §9.7.1). Purity (no models / reaction
systems / loaders / coupling / domain) is checked separately at import edges.
"""
_is_template_library_doc(raw) =
    _is_object(raw) && _raw_haskey(raw, "expression_templates")

# ---------------------------------------------------------------------------
# Metaparameters (esm-spec §9.7.6)
# ---------------------------------------------------------------------------

function _require_int(v, ctx::String)::Int64
    (v isa Integer && !(v isa Bool)) && return Int64(v)
    throw(ExpressionTemplateError(
        "metaparameter_type_error",
        "$ctx: value $(repr(v)) is not an integer (esm-spec §9.7.6)"))
end

function _collect_metaparam_decls(raw, origin::String)::OrderedDict{String,Any}
    out = OrderedDict{String,Any}()
    mp = _raw_get(raw, "metaparameters")
    mp === nothing && return out
    _is_object(mp) || throw(ExpressionTemplateError(
        "metaparameter_type_error", "$origin: `metaparameters` must be an object"))
    for (k, v) in pairs(mp)
        name = string(k)
        _is_object(v) || throw(ExpressionTemplateError(
            "metaparameter_type_error",
            "$origin: metaparameters.$name must be an object with `type: \"integer\"`"))
        t = _raw_get(v, "type")
        (t !== nothing && string(t) == "integer") || throw(ExpressionTemplateError(
            "metaparameter_type_error",
            "$origin: metaparameters.$name: `type` must be \"integer\" (the only kind)"))
        d = _raw_get(v, "default")
        d === nothing || _require_int(d, "$origin: metaparameters.$name default")
        out[name] = _to_ordered(v)
    end
    return out
end

# Keys whose VALUES are never expression positions: metaparameter names are
# substituted as bare variable-reference strings, so structural string fields
# must not be rewritten. Template `params` shadowing is handled separately in
# `_substitute_metaparams_decl`.
const _META_SUBST_SKIP_KEYS = Set{String}([
    "metadata", "params", "type", "units", "kind", "description", "name",
    "wrt", "expression_template_imports", "metaparameters", "only",
])

"""
    _substitute_metaparams(x, values)

Substitute closed metaparameter names — appearing as bare strings, the
variable-reference surface syntax — with their integer values, everywhere
except the `_META_SUBST_SKIP_KEYS` structural fields (esm-spec §9.7.6:
expression-position substitution; no folding here).
"""
function _substitute_metaparams(x, values::AbstractDict{String,Int64})
    if x isa AbstractString
        s = string(x)
        return haskey(values, s) ? values[s] : x
    elseif _is_array(x)
        return Any[_substitute_metaparams(v, values) for v in x]
    elseif _is_object(x)
        out = OrderedDict{String,Any}()
        for (k, v) in pairs(x)
            ks = string(k)
            out[ks] = ks in _META_SUBST_SKIP_KEYS ? _to_ordered(v) :
                      _substitute_metaparams(v, values)
        end
        return out
    end
    return x
end

"""
    _substitute_metaparams_decl(decl, values)

Metaparameter substitution over one `expression_templates` entry: the
template's own `params` shadow like-named metaparameters inside its `body`
and `match` (a param is the inner binder; substitution must not capture it).
"""
function _substitute_metaparams_decl(decl, values::AbstractDict{String,Int64})
    params = _raw_get(decl, "params")
    shadowed = values
    if params !== nothing && _is_array(params) &&
       any(p -> haskey(values, string(p)), params)
        v2 = Dict{String,Int64}(values)
        for p in params
            delete!(v2, string(p))
        end
        shadowed = v2
    end
    return _substitute_metaparams(decl, shadowed)
end

"""
    _try_fold(x, ctx) -> Union{Int64,Nothing}

Fold a metaparameter expression (integer literal, name, or `{op, args}` over
`+ - * /`) to a concrete `Int64` with exact 64-bit arithmetic (esm-spec
§9.7.6). Returns `nothing` when the expression still contains a bare name
(an open metaparameter awaiting a later binding site, or a template-param
slot inside a rule body) — the site is left symbolic for a later pass.
Throws `metaparameter_type_error` for a non-integer literal, an op outside
`+ - * /` over concrete args, inexact division, or 64-bit overflow.
"""
function _try_fold(x, ctx::String)::Union{Int64,Nothing}
    (x isa Integer && !(x isa Bool)) && return Int64(x)
    x isa AbstractString && return nothing
    if x isa Number
        throw(ExpressionTemplateError(
            "metaparameter_type_error",
            "$ctx: non-integer literal $x in a structural integer site (esm-spec §9.7.6)"))
    end
    _is_object(x) || throw(ExpressionTemplateError(
        "metaparameter_type_error",
        "$ctx: invalid metaparameter expression (expected integer, name, or {op, args})"))
    op_raw = _raw_get(x, "op")
    args = _raw_get(x, "args")
    (op_raw === nothing || args === nothing || !_is_array(args) || isempty(args)) &&
        throw(ExpressionTemplateError(
            "metaparameter_type_error",
            "$ctx: invalid metaparameter expression (expected {op: +|-|*|/, args: [...]})"))
    vals = Union{Int64,Nothing}[_try_fold(a, ctx) for a in args]
    any(v -> v === nothing, vals) && return nothing
    ivals = Int64[v for v in vals]
    op = string(op_raw)
    op in ("+", "-", "*", "/") || throw(ExpressionTemplateError(
        "metaparameter_type_error",
        "$ctx: op '$op' is not allowed in a metaparameter expression (only + - * /)"))
    try
        acc = ivals[1]
        if op == "-" && length(ivals) == 1
            return Base.checked_neg(acc)
        end
        for v in ivals[2:end]
            if op == "+"
                acc = Base.checked_add(acc, v)
            elseif op == "-"
                acc = Base.checked_sub(acc, v)
            elseif op == "*"
                acc = Base.checked_mul(acc, v)
            else # "/"
                v == 0 && throw(ExpressionTemplateError(
                    "metaparameter_type_error", "$ctx: division by zero"))
                rem(acc, v) == 0 || throw(ExpressionTemplateError(
                    "metaparameter_type_error",
                    "$ctx: $acc / $v does not divide exactly (esm-spec §9.7.6)"))
                acc = div(acc, v)
            end
        end
        return acc
    catch e
        e isa OverflowError && throw(ExpressionTemplateError(
            "metaparameter_type_error",
            "$ctx: 64-bit integer overflow while folding a metaparameter expression"))
        rethrow(e)
    end
end

function _collect_names!(out::Vector{String}, x)
    if x isa AbstractString
        push!(out, string(x))
    elseif _is_array(x)
        for v in x
            _collect_names!(out, v)
        end
    elseif _is_object(x)
        for (k, v) in pairs(x)
            string(k) == "op" && continue
            _collect_names!(out, v)
        end
    end
    return out
end

"""
    _fold_structural_sites!(x, ctx)

Fold metaparameter expressions in the structural integer sites — `aggregate`
dense `ranges` tuple entries and `makearray` `regions` bound pairs — to
concrete integers, in place, wherever they are already closed. Entries still
carrying a bare name (a template-param slot, or an open metaparameter in a
not-yet-fully-bound library) are left symbolic for a later binding site.
Index-set sizes are folded separately by [`_fold_index_set_sizes!`](@ref).
"""
function _fold_structural_sites!(x, ctx::String)
    if _is_array(x)
        for v in x
            _fold_structural_sites!(v, ctx)
        end
        return
    end
    _is_object(x) || return
    op = get(x, "op", nothing)
    op_str = op === nothing ? "" : string(op)
    if op_str == "aggregate"
        ranges = get(x, "ranges", nothing)
        if ranges !== nothing && _is_object(ranges)
            for (k, rv) in pairs(ranges)
                _is_array(rv) || continue   # {from: ...} index-set refs untouched
                for (i, entry) in enumerate(rv)
                    (entry isa Integer && !(entry isa Bool)) && continue
                    f = _try_fold(entry, "$ctx: aggregate ranges.$(string(k))")
                    f === nothing || (rv[i] = f)
                end
            end
        end
    elseif op_str == "makearray"
        regions = get(x, "regions", nothing)
        if regions !== nothing && _is_array(regions)
            for region in regions
                _is_array(region) || continue
                for bounds in region
                    _is_array(bounds) || continue
                    for (i, entry) in enumerate(bounds)
                        (entry isa Integer && !(entry isa Bool)) && continue
                        f = _try_fold(entry, "$ctx: makearray regions bound")
                        f === nothing || (bounds[i] = f)
                    end
                end
            end
        end
    end
    for (_, v) in pairs(x)
        _fold_structural_sites!(v, ctx)
    end
    return
end

"""
    _fold_index_set_sizes!(index_sets, ctx; strict)

Fold interval `size` metaparameter expressions in an `index_sets` registry.
With `strict = true` (the root document, after its metaparameters closed) any
remaining bare name is `metaparameter_unbound`; with `strict = false` (a
library instantiated at an edge that left some metaparameters open) open
sizes stay symbolic and close at a later binding site.
"""
function _fold_index_set_sizes!(index_sets::AbstractDict, ctx::String; strict::Bool)
    for (name, decl) in pairs(index_sets)
        _is_object(decl) || continue
        sz = get(decl, "size", nothing)
        sz === nothing && continue
        (sz isa Integer && !(sz isa Bool)) && continue
        f = _try_fold(sz, "$ctx: index_sets.$(string(name)).size")
        if f === nothing
            strict && throw(ExpressionTemplateError(
                "metaparameter_unbound",
                "$ctx: index_sets.$(string(name)).size references unbound name(s) " *
                "$(join(unique(_collect_names!(String[], sz)), ", ")) (esm-spec §9.7.6)"))
        else
            decl["size"] = f
        end
    end
    return
end

# ---------------------------------------------------------------------------
# Registration-time body composition (esm-spec §9.7.3)
# ---------------------------------------------------------------------------

function _collect_apply_names!(out::Vector{String}, x)
    if _is_array(x)
        for c in x
            _collect_apply_names!(out, c)
        end
        return out
    end
    if _is_object(x)
        op = _raw_get(x, "op")
        if op !== nothing && string(op) == APPLY_EXPRESSION_TEMPLATE_OP
            nm = _raw_get(x, "name")
            nm !== nothing && push!(out, string(nm))
        end
        for (_, v) in pairs(x)
            _collect_apply_names!(out, v)
        end
    end
    return out
end

function _inline_applies(node, templates::AbstractDict, scope::String)
    if _is_array(node)
        return Any[_inline_applies(c, templates, scope) for c in node]
    end
    _is_object(node) || return node
    out = Dict{String,Any}()
    for (k, v) in pairs(node)
        out[string(k)] = _inline_applies(v, templates, scope)
    end
    op = get(out, "op", nothing)
    if op !== nothing && string(op) == APPLY_EXPRESSION_TEMPLATE_OP
        # Referenced bodies are already closed (topological order), so a single
        # `_expand_apply` produces an apply-free subtree; the bindings' own
        # sub-ASTs were inlined by the post-order walk above.
        return _expand_apply(out, templates, scope)
    end
    return out
end

"""
    _compose_template_bodies!(templates, scope)

Registration-time body composition (esm-spec §9.7.3): template bodies MAY
reference other in-scope MATCH-LESS templates via `apply_expression_template`
nodes. Builds the body-reference graph, rejects cycles
(`apply_expression_template_recursive_body`) and chains deeper than
`MAX_TEMPLATE_EXPANSION_DEPTH` templates (`template_body_expansion_too_deep`),
then inlines dependencies-first by pure substitution — confluent, so
topological order cannot affect the result. Afterwards every `body` is a
closed Expression AST with zero `apply_expression_template` nodes; runs
BEFORE the §9.6.3 fixpoint ever consults a `match` rule.
"""
function _compose_template_bodies!(templates::AbstractDict{String,Any}, scope::String)
    isempty(templates) && return
    refs = Dict{String,Vector{String}}()
    for (name, decl) in templates
        body = _raw_get(decl, "body")
        refs[name] = _collect_apply_names!(String[], body)
    end
    any(!isempty, values(refs)) || return

    for name in sort(collect(keys(refs)))
        for r in refs[name]
            tdecl = get(templates, r, nothing)
            tdecl === nothing && throw(ExpressionTemplateError(
                "apply_expression_template_unknown_template",
                "$scope.expression_templates.$name: body references undeclared template '$r' (esm-spec §9.7.3)"))
            if _raw_get(tdecl, "match") !== nothing
                throw(ExpressionTemplateError(
                    "apply_expression_template_unknown_template",
                    "$scope.expression_templates.$name: body references '$r', a `match` " *
                    "rewrite rule — only match-less templates are invocable by name (esm-spec §9.7.3)"))
            end
        end
    end

    # DFS over the reference graph: cycle detection, chain-depth bound, and a
    # dependencies-first (post-) order for inlining.
    state = Dict{String,Int}()   # 1 = on stack, 2 = done
    depth = Dict{String,Int}()   # templates on the longest chain from this node
    order = String[]
    chain = String[]
    function visit(name::String)::Int
        st = get(state, name, 0)
        if st == 1
            cyc = vcat(chain[findfirst(==(name), chain):end], [name])
            throw(ExpressionTemplateError(
                "apply_expression_template_recursive_body",
                "$scope.expression_templates: template-body reference cycle " *
                "$(join(cyc, " -> ")) (esm-spec §9.7.3)"))
        end
        st == 2 && return depth[name]
        state[name] = 1
        push!(chain, name)
        d = 1
        for r in refs[name]
            d = max(d, 1 + visit(r))
        end
        pop!(chain)
        state[name] = 2
        depth[name] = d
        d > MAX_TEMPLATE_EXPANSION_DEPTH && throw(ExpressionTemplateError(
            "template_body_expansion_too_deep",
            "$scope.expression_templates.$name: body-reference chain of $d templates " *
            "exceeds MAX_TEMPLATE_EXPANSION_DEPTH=$MAX_TEMPLATE_EXPANSION_DEPTH (esm-spec §9.7.3)"))
        push!(order, name)
        return d
    end
    for name in sort(collect(keys(refs)))
        visit(name)
    end

    for name in order
        isempty(refs[name]) && continue
        decl = templates[name]
        decl["body"] = _inline_applies(_raw_get(decl, "body"), templates,
                                       "$scope.expression_templates.$name")
    end
    return
end

# ---------------------------------------------------------------------------
# Import-graph resolution (esm-spec §9.7.2 / §9.7.4 / §9.7.5)
# ---------------------------------------------------------------------------

"""
Everything one template-library file exports after resolution in its OWN
scope: its effective template sequence (imports depth-first post-order, then
own declarations; esm-spec §9.7.4), its instantiated `index_sets`, and its
still-open metaparameter declarations (re-exported to the importer,
esm-spec §9.7.6 binding site 2). All three maps are ordered.
"""
mutable struct _TemplateScope
    templates::OrderedDict{String,Any}
    index_sets::OrderedDict{String,Any}
    metaparams::OrderedDict{String,Any}
end

_TemplateScope() = _TemplateScope(OrderedDict{String,Any}(),
                                  OrderedDict{String,Any}(),
                                  OrderedDict{String,Any}())

function _merge_named!(dst::OrderedDict{String,Any}, name::String, decl,
                       code::String, what::String, origin::String)
    if haskey(dst, name)
        # Deep-equal redeclaration (a diamond import) dedups at first
        # occurrence; a non-equal collision is a conflict (esm-spec §9.7.4/§9.7.5).
        _json_equal(_normalize(dst[name]), _normalize(decl)) && return
        throw(ExpressionTemplateError(
            code,
            "$origin: $what '$name' collides with a non-deep-equal existing definition (esm-spec §9.7.4/§9.7.5)"))
    end
    dst[name] = decl
    return
end

function _merge_scope!(dst::_TemplateScope, src::_TemplateScope, origin::String)
    for (n, d) in src.templates
        _merge_named!(dst.templates, n, d, "template_import_name_conflict", "template", origin)
    end
    for (n, d) in src.index_sets
        _merge_named!(dst.index_sets, n, d, "template_import_index_set_conflict", "index set", origin)
    end
    for (n, d) in src.metaparams
        _merge_named!(dst.metaparams, n, d, "template_import_name_conflict", "metaparameter", origin)
    end
    return
end

"""
    _instantiate_scope!(scope, values, ctx)

Per-edge metaparameter instantiation (esm-spec §9.7.6 binding site 1):
substitute the bound names as integer literals throughout the exported
templates and index sets, then fold the structural sites that are now closed.
"""
function _instantiate_scope!(scope::_TemplateScope, values::Dict{String,Int64}, ctx::String)
    newt = OrderedDict{String,Any}()
    for (n, d) in scope.templates
        nd = _substitute_metaparams_decl(d, values)
        _fold_structural_sites!(nd, ctx)
        newt[n] = nd
    end
    scope.templates = newt
    newis = OrderedDict{String,Any}()
    for (n, d) in scope.index_sets
        newis[n] = _substitute_metaparams(d, values)
    end
    _fold_index_set_sizes!(newis, ctx; strict=false)
    scope.index_sets = newis
    return
end

function _load_import_raw(ref::String, base_dir::String, origin::String)
    if startswith(ref, "http://") || startswith(ref, "https://")
        local content::String
        try
            tmp = Base.download(ref)
            content = read(tmp, String)
            rm(tmp, force=true)
        catch e
            throw(ExpressionTemplateError(
                "template_import_unresolved",
                "$origin: failed to download template-library ref '$ref': $e"))
        end
        raw = try
            JSON3.read(content)
        catch e
            throw(ExpressionTemplateError(
                "template_import_unresolved",
                "$origin: template-library ref '$ref' is not valid JSON: $e"))
        end
        # Relative refs inside a remote library have no resolvable base; they
        # fail as unresolved when encountered.
        return raw, base_dir
    end
    path = abspath(joinpath(base_dir, ref))
    isfile(path) || throw(ExpressionTemplateError(
        "template_import_unresolved",
        "$origin: template-library file not found: $path (from ref '$ref')"))
    raw = try
        JSON3.read(read(path, String))
    catch e
        throw(ExpressionTemplateError(
            "template_import_unresolved",
            "$origin: template-library ref '$path' is not valid JSON: $e"))
    end
    return raw, dirname(path)
end

"""
    _resolve_import_entry(entry, base_dir, stack, origin) -> _TemplateScope

Resolve ONE `expression_template_imports` entry (esm-spec §9.7.2): load the
target (path-scoped cycle detection over canonical refs, as §4.7), verify
library purity, resolve the target recursively in its own scope, instantiate
at this edge's `bindings`, then apply `only` visibility filtering.
"""
function _resolve_import_entry(entry, base_dir::String, stack::Vector{String},
                               origin::String)::_TemplateScope
    _is_object(entry) || throw(ExpressionTemplateError(
        "template_import_unresolved",
        "$origin: expression_template_imports entries must be objects with a `ref` field"))
    ref_raw = _raw_get(entry, "ref")
    (ref_raw isa AbstractString && !isempty(string(ref_raw))) ||
        throw(ExpressionTemplateError(
            "template_import_unresolved",
            "$origin: expression_template_imports entry requires a non-empty string `ref`"))
    ref = string(ref_raw)
    canonical = _canonical_ref(ref, base_dir)
    if canonical in stack
        cyc = vcat(stack[findfirst(==(canonical), stack):end], [canonical])
        throw(ExpressionTemplateError(
            "template_import_cycle",
            "$origin: import-graph cycle detected: $(join(cyc, " -> ")) (esm-spec §9.7.2)"))
    end

    raw, target_dir = _load_import_raw(ref, base_dir, origin)
    reject_expression_templates_pre_v04(raw)
    reject_template_imports_pre_v08(raw)

    # Library purity (esm-spec §9.7.1): the two reference mechanisms are
    # disjoint — a component/subsystem file is not importable as a library.
    _is_template_library_doc(raw) || throw(ExpressionTemplateError(
        "template_import_not_library",
        "$origin: import target '$ref' lacks top-level `expression_templates` — " *
        "not a template-library file (esm-spec §9.7.1)"))
    for k in _LIBRARY_FORBIDDEN_KEYS
        _raw_haskey(raw, k) && throw(ExpressionTemplateError(
            "template_import_not_library",
            "$origin: import target '$ref' declares `$k` — not a pure template-library file (esm-spec §9.7.1)"))
    end
    schema_errors = validate_schema(raw)
    isempty(schema_errors) || throw(ExpressionTemplateError(
        "template_import_unresolved",
        "$origin: import target '$ref' failed schema validation: " *
        "$(schema_errors[1].path): $(schema_errors[1].message)"))

    push!(stack, canonical)
    scope = try
        _process_library(raw, target_dir, stack, "$origin -> $ref")
    finally
        pop!(stack)
    end

    # Edge metaparameter bindings (esm-spec §9.7.6 binding site 1).
    bindings_raw = _raw_get(entry, "bindings")
    values = Dict{String,Int64}()
    if bindings_raw !== nothing && _is_object(bindings_raw)
        for (k, v) in pairs(bindings_raw)
            name = string(k)
            haskey(scope.metaparams, name) || throw(ExpressionTemplateError(
                "template_import_unknown_name",
                "$origin: import of '$ref' binds metaparameter '$name', which the " *
                "target neither declares nor re-exports (esm-spec §9.7.6)"))
            values[name] = _require_int(v, "$origin: import of '$ref', binding '$name'")
        end
    end
    if !isempty(values)
        _instantiate_scope!(scope, values, "$origin -> $ref")
        for name in keys(values)
            delete!(scope.metaparams, name)
        end
    end

    # `only` visibility filtering (esm-spec §9.7.2) — after the target's own
    # internal wiring resolved in its own scope.
    only_raw = _raw_get(entry, "only")
    if only_raw !== nothing && _is_array(only_raw)
        keep = String[string(n) for n in only_raw]
        for n in keep
            haskey(scope.templates, n) || throw(ExpressionTemplateError(
                "template_import_unknown_name",
                "$origin: `only` names template '$n', which '$ref' does not declare (esm-spec §9.7.2)"))
        end
        keepset = Set(keep)
        filtered = OrderedDict{String,Any}()
        for (n, d) in scope.templates
            n in keepset && (filtered[n] = d)
        end
        scope.templates = filtered
    end
    return scope
end

"""
    _process_library(raw, dir, stack, origin) -> _TemplateScope

Resolve a template-library document in its OWN scope: its imports
(depth-first post-order), then its own templates / index sets /
metaparameters appended in declaration order (esm-spec §9.7.4), then §9.7.3
body composition — so a BC-layer body reference to an imported interior
stencil closes here, before any `only` filtering by a downstream importer.
"""
function _process_library(raw, dir::String, stack::Vector{String},
                          origin::String)::_TemplateScope
    scope = _TemplateScope()
    imports = _raw_get(raw, "expression_template_imports")
    if imports !== nothing && _is_array(imports)
        for entry in imports
            sub = _resolve_import_entry(entry, dir, stack, origin)
            _merge_scope!(scope, sub, origin)
        end
    end

    own = OrderedDict{String,Any}()
    tpl = _raw_get(raw, "expression_templates")
    if tpl !== nothing && _is_object(tpl)
        for (n, d) in pairs(tpl)
            own[string(n)] = _to_ordered(d)
        end
    end
    _validate_templates(Dict{String,Any}(own), origin)
    for (n, d) in own
        _merge_named!(scope.templates, n, d, "template_import_name_conflict", "template", origin)
    end

    isets = _raw_get(raw, "index_sets")
    if isets !== nothing && _is_object(isets)
        for (n, d) in pairs(isets)
            _merge_named!(scope.index_sets, string(n), _to_ordered(d),
                          "template_import_index_set_conflict", "index set", origin)
        end
    end

    for (n, d) in _collect_metaparam_decls(raw, origin)
        _merge_named!(scope.metaparams, n, d, "template_import_name_conflict",
                      "metaparameter", origin)
    end

    # §9.7.3 body composition in the library's own scope (decl objects are
    # mutated in place, so scope.templates sees the closed bodies).
    _compose_template_bodies!(Dict{String,Any}(scope.templates), origin)
    return scope
end

# ---------------------------------------------------------------------------
# Root-document resolution (the load-time entry point)
# ---------------------------------------------------------------------------

function _has_import_machinery(raw)
    _is_object(raw) || return false
    (_raw_haskey(raw, "expression_templates") ||
     _raw_haskey(raw, "metaparameters") ||
     _raw_haskey(raw, "expression_template_imports")) && return true
    for compkind in _COMPONENT_KINDS
        comps = _raw_get(raw, compkind)
        (comps !== nothing && _is_object(comps)) || continue
        for (_, comp) in pairs(comps)
            _is_object(comp) || continue
            _raw_haskey(comp, "expression_template_imports") && return true
        end
    end
    return false
end

"""
    resolve_template_machinery(raw_data, base_path; metaparameters=Dict{String,Int}())

Resolve every esm-spec §9.7 construct of the ROOT document `raw_data`
(relative import refs resolve against `base_path`): imports recursively with
per-edge instantiation, `index_sets` merge, metaparameter close
(`metaparameters` is the loader-API binding site 4; already-closed edge
bindings win, then API bindings, then defaults) and fold, expression-position
substitution, and — for a root library file — §9.7.3 body composition.

Returns an order-preserving native tree ready for
[`lower_expression_templates`](@ref) with `expression_template_imports`,
`metaparameters`, and top-level `expression_templates` consumed (Option A
round-trip: none survives `parse → emit`), or `nothing` when the document
carries no §9.7 machinery (the legacy fast path).
"""
function resolve_template_machinery(raw_data, base_path::AbstractString;
        metaparameters::AbstractDict{String,<:Integer}=Dict{String,Int}())
    if !_has_import_machinery(raw_data)
        isempty(metaparameters) || throw(ExpressionTemplateError(
            "template_import_unknown_name",
            "loader API binds metaparameter(s) " *
            "$(join(sort(collect(String[string(k) for k in keys(metaparameters)])), ", ")) " *
            "but the document declares none (esm-spec §9.7.6)"))
        return nothing
    end
    base_dir = String(base_path)
    root = _to_ordered(raw_data)::OrderedDict{String,Any}
    stack = String[]

    doc_meta = _collect_metaparam_decls(root, "document")
    doc_isets = OrderedDict{String,Any}()
    if haskey(root, "index_sets") && _is_object(root["index_sets"])
        for (n, d) in pairs(root["index_sets"])
            doc_isets[string(n)] = d
        end
    end

    # --- top-level templates + imports (root template-library file) ---
    is_library = haskey(root, "expression_templates")
    top_templates = OrderedDict{String,Any}()
    if is_library
        topscope = _TemplateScope()
        imports = get(root, "expression_template_imports", nothing)
        if imports !== nothing && _is_array(imports)
            for entry in imports
                sub = _resolve_import_entry(entry, base_dir, stack, "document")
                _merge_scope!(topscope, sub, "document")
            end
        end
        own = OrderedDict{String,Any}()
        tpl = root["expression_templates"]
        if _is_object(tpl)
            for (n, d) in pairs(tpl)
                own[string(n)] = d
            end
        end
        _validate_templates(Dict{String,Any}(own), "document")
        for (n, d) in own
            _merge_named!(topscope.templates, n, d, "template_import_name_conflict",
                          "template", "document")
        end
        for (n, d) in topscope.index_sets
            _merge_named!(doc_isets, n, d, "template_import_index_set_conflict",
                          "index set", "document")
        end
        for (n, d) in topscope.metaparams
            _merge_named!(doc_meta, n, d, "template_import_name_conflict",
                          "metaparameter", "document")
        end
        top_templates = topscope.templates
    end

    # --- per-component imports (models / reaction systems, esm-spec §9.7.2) ---
    for compkind in _COMPONENT_KINDS
        comps = get(root, compkind, nothing)
        (comps !== nothing && _is_object(comps)) || continue
        for (cname, comp) in pairs(comps)
            _is_object(comp) || continue
            imports = get(comp, "expression_template_imports", nothing)
            imports === nothing && continue
            cscope = _TemplateScope()
            corigin = "$compkind.$(string(cname))"
            if _is_array(imports)
                for entry in imports
                    sub = _resolve_import_entry(entry, base_dir, stack, corigin)
                    _merge_scope!(cscope, sub, corigin)
                end
            end
            tpl = get(comp, "expression_templates", nothing)
            if tpl !== nothing && _is_object(tpl)
                own = OrderedDict{String,Any}()
                for (n, d) in pairs(tpl)
                    own[string(n)] = d
                end
                _validate_templates(Dict{String,Any}(own), corigin)
                for (n, d) in own
                    _merge_named!(cscope.templates, n, d,
                                  "template_import_name_conflict", "template", corigin)
                end
            end
            for (n, d) in cscope.index_sets
                _merge_named!(doc_isets, n, d, "template_import_index_set_conflict",
                              "index set", corigin)
            end
            for (n, d) in cscope.metaparams
                _merge_named!(doc_meta, n, d, "template_import_name_conflict",
                              "metaparameter", corigin)
            end
            # The effective sequence (imports depth-first post-order, then
            # local declarations) becomes the component's template block; the
            # OrderedDict key order IS the §9.6.3 declaration order.
            comp["expression_templates"] = cscope.templates
            delete!(comp, "expression_template_imports")
        end
    end

    # --- close this document's metaparameters (§9.7.6 sites 4-5) ---
    api = Dict{String,Int64}()
    for (k, v) in pairs(metaparameters)
        api[string(k)] = _require_int(v, "loader API metaparameter '$(string(k))'")
    end
    for k in sort(collect(keys(api)))
        haskey(doc_meta, k) || throw(ExpressionTemplateError(
            "template_import_unknown_name",
            "loader API binds metaparameter '$k', which the document does not declare (esm-spec §9.7.6)"))
    end
    values = Dict{String,Int64}()
    open_names = String[]
    for (name, decl) in doc_meta
        if haskey(api, name)
            values[name] = api[name]
        else
            d = _raw_get(decl, "default")
            d === nothing ? push!(open_names, name) : (values[name] = Int64(d))
        end
    end
    isempty(open_names) || throw(ExpressionTemplateError(
        "metaparameter_unbound",
        "metaparameter(s) $(join(open_names, ", ")) still open after edge bindings, " *
        "loader-API bindings, and defaults (esm-spec §9.7.6)"))

    # --- §9.7.6 name-collision check: no shadowing of visible names ---
    if !isempty(doc_meta)
        visible = Set{String}(String[string(k) for k in keys(doc_isets)])
        for compkind in _COMPONENT_KINDS
            comps = get(root, compkind, nothing)
            (comps !== nothing && _is_object(comps)) || continue
            for (_, comp) in pairs(comps)
                _is_object(comp) || continue
                for blk in ("variables", "species", "parameters")
                    b = get(comp, blk, nothing)
                    (b !== nothing && _is_object(b)) || continue
                    for (vn, _) in pairs(b)
                        push!(visible, string(vn))
                    end
                end
            end
        end
        for name in keys(doc_meta)
            name in visible && throw(ExpressionTemplateError(
                "metaparameter_name_conflict",
                "metaparameter '$name' collides with a visible " *
                "variable/parameter/species/index-set name (esm-spec §9.7.6)"))
        end
    end

    # --- expression-position substitution of the closed values ---
    if !isempty(values)
        for compkind in _COMPONENT_KINDS
            comps = get(root, compkind, nothing)
            (comps !== nothing && _is_object(comps)) || continue
            for (cname, comp) in pairs(comps)
                _is_object(comp) || continue
                for k in collect(keys(comp))
                    if k == "expression_templates" && _is_object(comp[k])
                        tpl = comp[k]
                        for (tn, td) in collect(pairs(tpl))
                            tpl[tn] = _substitute_metaparams_decl(td, values)
                        end
                    else
                        comp[k] = _substitute_metaparams(comp[k], values)
                    end
                end
            end
        end
        for (tn, td) in collect(pairs(top_templates))
            top_templates[tn] = _substitute_metaparams_decl(td, values)
        end
        newisets = OrderedDict{String,Any}()
        for (n, d) in doc_isets
            newisets[n] = _substitute_metaparams(d, values)
        end
        doc_isets = newisets
    end

    # --- fold structural sites on the closed document ---
    for compkind in _COMPONENT_KINDS
        comps = get(root, compkind, nothing)
        (comps !== nothing && _is_object(comps)) || continue
        for (cname, comp) in pairs(comps)
            _is_object(comp) || continue
            _fold_structural_sites!(comp, "$compkind.$(string(cname))")
        end
    end
    for (tn, td) in pairs(top_templates)
        _fold_structural_sites!(td, "document.expression_templates.$tn")
    end
    _fold_index_set_sizes!(doc_isets, "document"; strict=true)

    # --- root library file: compose bodies (validation), then strip; no §9.7
    #     construct survives parse → emit (esm-spec §9.7.6 round-trip) ---
    if is_library
        _compose_template_bodies!(Dict{String,Any}(top_templates), "document")
        delete!(root, "expression_templates")
    end
    delete!(root, "expression_template_imports")
    delete!(root, "metaparameters")
    isempty(doc_isets) || (root["index_sets"] = doc_isets)
    return root
end
