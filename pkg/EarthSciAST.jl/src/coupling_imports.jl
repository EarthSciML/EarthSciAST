"""
Coupling-library files and `coupling_import` role binding (esm-spec §10.9–§10.11).

A *coupling-library file* is a document whose payload is a top-level
`coupling_roles` map plus a role-scoped `coupling` array. An assembly reuses it
with a `{ type: "coupling_import", ref, bind }` coupling entry: at flatten the
import expands into concrete `variable_map` / `couple` / `operator_compose` /
`event` edges by substituting the bound actual component for every role-named
top-level segment (the §10.10.2 occurrence surface).

Expansion runs *inside* flatten (esm-spec §10.10.3), after subsystem mounting
(which happens at load, §2.1b) and before the coupling-rule step, so every
`bind` target resolves against fully-mounted components. The `coupling_import`
source entry is preserved for round-trip; only the flattened system carries the
expanded edges.

All diagnostics are raised as [`ExpressionTemplateError`](@ref) carrying the
stable §10.11 codes so they are machine-checkable across bindings. Mirrors the
TypeScript reference `pkg/earthsci-ast-ts/src/coupling-imports.ts`.
"""

# Payload keys a coupling-library file MUST NOT declare (esm-spec §10.9).
const _COUPLING_LIBRARY_FORBIDDEN_KEYS = (
    "models", "reaction_systems", "data_loaders", "domain",
    "index_sets", "metaparameters", "expression_templates",
)

# Coupling-entry types a library edge MAY carry (esm-spec §10.9).
const _ROLE_BEARING_TYPES = ("variable_map", "couple", "operator_compose", "event")

"""
    _is_coupling_library_doc(raw) -> Bool

True when `raw` has the coupling-library-file FORM (top-level `coupling_roles`,
esm-spec §10.9). Presence of that key is the sole positive identifier of the
file kind; purity is checked separately at the import edge.
"""
_is_coupling_library_doc(raw) = _is_object(raw) && _raw_haskey(raw, "coupling_roles")

# ---------------------------------------------------------------------------
# Reference rewriting — the §10.10.2 occurrence surface
# ---------------------------------------------------------------------------

function _head_segment(ref::AbstractString)::String
    i = findfirst('.', ref)
    return i === nothing ? String(ref) : String(ref[1:prevind(ref, i)])
end

"""
Replace the top-level segment of a scoped reference with its bound actual.
`"Fuel.w_0"` under `{Fuel => "FuelModelLookup"}` → `"FuelModelLookup.w_0"`; a
dotted bind value (`{Fuel => "Parent.Child"}`) → `"Parent.Child.w_0"`. A segment
not in `bind` is returned unchanged (e.g. bare `"t"`, literals).
"""
function _rewrite_scoped_ref(ref::AbstractString, bind::AbstractDict)::String
    i = findfirst('.', ref)
    head = i === nothing ? String(ref) : String(ref[1:prevind(ref, i)])
    tail = i === nothing ? "" : String(ref[i:end])
    actual = get(bind, head, nothing)
    return actual === nothing ? String(ref) : String(actual) * tail
end

"""Rewrite/visit every scoped reference inside a (native) Expression tree."""
function _rewrite_expr!(expr, fn)
    if expr isa AbstractString
        return fn(expr)
    elseif expr isa AbstractDict
        if haskey(expr, "args") && expr["args"] isa AbstractVector
            expr["args"] = Any[_rewrite_expr!(a, fn) for a in expr["args"]]
        end
        # `apply_expression_template` bindings VALUES are free-variable targets
        # (esm-spec §10.10.2) — Expressions in their own right.
        if get(expr, "op", nothing) == "apply_expression_template" &&
           haskey(expr, "bindings") && expr["bindings"] isa AbstractDict
            b = expr["bindings"]
            for k in collect(keys(b))
                b[k] = _rewrite_expr!(b[k], fn)
            end
        end
        return expr
    else
        return expr
    end
end

"""
Apply `structfn` to every structural system/scoped reference of a coupling entry
and `exprfn` to every scoped reference inside its Expression fields (esm-spec
§10.10.2). Mutates the (native) `entry` dict in place (callers pass a clone).
"""
function _rewrite_entry!(entry::AbstractDict, structfn, exprfn)
    t = get(entry, "type", nothing)
    if t == "variable_map"
        if haskey(entry, "from") && entry["from"] isa AbstractString
            entry["from"] = structfn(entry["from"])
        end
        if haskey(entry, "to") && entry["to"] isa AbstractString
            entry["to"] = structfn(entry["to"])
        end
        if haskey(entry, "transform") && entry["transform"] isa AbstractDict
            entry["transform"] = _rewrite_expr!(entry["transform"], exprfn)
        end

    elseif t == "couple"
        if haskey(entry, "systems") && entry["systems"] isa AbstractVector
            entry["systems"] = Any[structfn(s) for s in entry["systems"]]
        end
        conn = get(entry, "connector", nothing)
        if conn isa AbstractDict && haskey(conn, "equations") && conn["equations"] isa AbstractVector
            for eq in conn["equations"]
                eq isa AbstractDict || continue
                if haskey(eq, "from") && eq["from"] isa AbstractString
                    eq["from"] = structfn(eq["from"])
                end
                if haskey(eq, "to") && eq["to"] isa AbstractString
                    eq["to"] = structfn(eq["to"])
                end
                if haskey(eq, "expression")
                    eq["expression"] = _rewrite_expr!(eq["expression"], exprfn)
                end
            end
        end

    elseif t == "operator_compose"
        if haskey(entry, "systems") && entry["systems"] isa AbstractVector
            entry["systems"] = Any[structfn(s) for s in entry["systems"]]
        end
        tr = get(entry, "translate", nothing)
        if tr isa AbstractDict
            next = Dict{String,Any}()
            for (k, v) in pairs(tr)
                nk = structfn(string(k))
                if v isa AbstractString
                    next[nk] = structfn(v)
                elseif v isa AbstractDict
                    vv = _to_native_json(v)
                    if haskey(vv, "var") && vv["var"] isa AbstractString
                        vv["var"] = structfn(vv["var"])
                    end
                    next[nk] = vv
                else
                    next[nk] = v
                end
            end
            entry["translate"] = next
        end

    elseif t == "event"
        if haskey(entry, "conditions") && entry["conditions"] isa AbstractVector
            entry["conditions"] = Any[_rewrite_expr!(c, exprfn) for c in entry["conditions"]]
        end
        rewrite_affect = function (a)
            a isa AbstractDict || return a
            if haskey(a, "lhs") && a["lhs"] isa AbstractString
                a["lhs"] = structfn(a["lhs"])
            end
            if haskey(a, "rhs")
                a["rhs"] = _rewrite_expr!(a["rhs"], exprfn)
            end
            return a
        end
        if haskey(entry, "affects") && entry["affects"] isa AbstractVector
            entry["affects"] = Any[rewrite_affect(a) for a in entry["affects"]]
        end
        if haskey(entry, "affect_neg") && entry["affect_neg"] isa AbstractVector
            entry["affect_neg"] = Any[rewrite_affect(a) for a in entry["affect_neg"]]
        end
        trig = get(entry, "trigger", nothing)
        if trig isa AbstractDict && get(trig, "type", nothing) == "condition" &&
           haskey(trig, "expression")
            trig["expression"] = _rewrite_expr!(trig["expression"], exprfn)
        end
        fa = get(entry, "functional_affect", nothing)
        if fa isa AbstractDict
            for key in ("read_vars", "read_params", "modified_params")
                if haskey(fa, key) && fa[key] isa AbstractVector
                    fa[key] = Any[structfn(x) for x in fa[key]]
                end
            end
        end
        if haskey(entry, "discrete_parameters") && entry["discrete_parameters"] isa AbstractVector
            entry["discrete_parameters"] = Any[structfn(x) for x in entry["discrete_parameters"]]
        end
    end
    return entry
end

"""
Collect the top-level role segments a library edge references. Structural ref
fields (systems[], from/to, translate keys, event var lists) always name a role;
Expression strings name a role only when they are scoped references (contain a
dot) — bare Expression operands like `"t"` are incidental.
"""
function _collect_role_segments(edge)::Set{String}
    seen = Set{String}()
    clone = _to_native_json(edge)  # fresh deep copy; never mutates the source
    structfn = function (ref)
        push!(seen, _head_segment(ref))
        return ref
    end
    exprfn = function (ref)
        occursin('.', ref) && push!(seen, _head_segment(ref))
        return ref
    end
    _rewrite_entry!(clone, structfn, exprfn)
    return seen
end

# ---------------------------------------------------------------------------
# Ref loading (synchronous, mirrors the §9.7 template resolver)
# ---------------------------------------------------------------------------

"""
    _default_coupling_load_ref(ref, base_path) -> raw JSON doc

Default resolver for a `coupling_import` `ref`: reads the local file the ref
resolves to (via `_canonical_ref`) and parses it as JSON. Remote (http/https)
refs are rejected — download the file and import it by local path. Raises
`coupling_import_unresolved` on any failure.
"""
function _default_coupling_load_ref(ref::AbstractString, base_path::AbstractString)
    if _is_url(ref)
        throw(ExpressionTemplateError(
            "coupling_import_unresolved",
            "remote coupling_import ref '$(ref)' cannot be loaded synchronously; " *
            "download the file and import it by local path"))
    end
    path = _canonical_ref(String(ref), String(base_path))
    if !isfile(path)
        throw(ExpressionTemplateError(
            "coupling_import_unresolved",
            "coupling-library file not found or unreadable: $(path) (from ref '$(ref)')"))
    end
    local content::String
    try
        content = read(path, String)
    catch e
        throw(ExpressionTemplateError(
            "coupling_import_unresolved",
            "coupling-library file not found or unreadable: $(path) (from ref '$(ref)'): $(e)"))
    end
    try
        return JSON3.read(content)
    catch e
        throw(ExpressionTemplateError(
            "coupling_import_unresolved",
            "coupling-library ref '$(path)' is not valid JSON: $(e)"))
    end
end

# ---------------------------------------------------------------------------
# Component resolution (esm-spec §10.10.1)
# ---------------------------------------------------------------------------

_node_subsystems(node::Model) = node.subsystems
_node_subsystems(node::ReactionSystem) = node.subsystems
_node_subsystems(::Any) = nothing

"""
    _resolves_to_component(file::EsmFile, value::AbstractString) -> Bool

Resolve a `bind` value as a component path (esm-spec §10.10.1) — a system or
loader node, walking `models`/`reaction_systems`/`data_loaders` then nested
`subsystems`, never terminating on a variable.
"""
function _resolves_to_component(file::EsmFile, value::AbstractString)::Bool
    segs = split(value, '.')
    isempty(segs) && return false
    top = String(segs[1])
    node = nothing
    if file.models !== nothing && haskey(file.models, top)
        node = file.models[top]
    elseif file.reaction_systems !== nothing && haskey(file.reaction_systems, top)
        node = file.reaction_systems[top]
    elseif file.data_loaders !== nothing && haskey(file.data_loaders, top)
        node = file.data_loaders[top]
    end
    node === nothing && return false
    for i in 2:length(segs)
        subs = _node_subsystems(node)
        subs === nothing && return false
        key = String(segs[i])
        haskey(subs, key) || return false
        node = subs[key]
        node === nothing && return false
    end
    return true
end

# ---------------------------------------------------------------------------
# Library validation + expansion
# ---------------------------------------------------------------------------

"""
    _expand_one(lib, ref, bind, file) -> Vector{CouplingEntry}

Validate a resolved coupling-library document and expand one `coupling_import`
entry into its concrete edges, bound to `bind`. Raises the esm-spec §10.11
diagnostics.
"""
function _expand_one(lib, ref::AbstractString, bind::AbstractDict, file::EsmFile)::Vector{CouplingEntry}
    if !_is_coupling_library_doc(lib)
        throw(ExpressionTemplateError(
            "coupling_import_not_library",
            "coupling_import ref '$(ref)' lacks top-level `coupling_roles` — " *
            "not a coupling-library file (esm-spec §10.9)"))
    end

    # Purity (esm-spec §10.9).
    for k in _COUPLING_LIBRARY_FORBIDDEN_KEYS
        if _raw_haskey(lib, k)
            throw(ExpressionTemplateError(
                "coupling_library_illegal_payload",
                "coupling-library '$(ref)' declares `$(k)` — a coupling library is " *
                "nothing but roles + wiring (esm-spec §10.9)"))
        end
    end

    rolesobj = _raw_get(lib, "coupling_roles")
    roles = _is_object(rolesobj) ? String[string(k) for k in keys(rolesobj)] : String[]
    if isempty(roles)
        throw(ExpressionTemplateError(
            "coupling_library_illegal_payload",
            "coupling-library '$(ref)' declares no roles " *
            "(esm-spec §10.9: `coupling_roles` is required, non-empty)"))
    end
    edges_raw = _raw_get(lib, "coupling")
    edges = _is_array(edges_raw) ? collect(edges_raw) : Any[]
    if isempty(edges)
        throw(ExpressionTemplateError(
            "coupling_library_illegal_payload",
            "coupling-library '$(ref)' has an empty `coupling` array " *
            "(esm-spec §10.9: required, non-empty)"))
    end

    # Edge-type + role-scope checks over the declared roles.
    role_set = Set{String}(roles)
    used_roles = Set{String}()
    for edge in edges
        _is_object(edge) || continue
        etype = _raw_get(edge, "type")
        if etype == "coupling_import"
            throw(ExpressionTemplateError(
                "coupling_library_nested_import",
                "coupling-library '$(ref)' contains a nested coupling_import " *
                "(v1 forbids layering, esm-spec §10.9)"))
        end
        if etype == "callback" || _raw_haskey(edge, "expression_template_imports")
            throw(ExpressionTemplateError(
                "coupling_library_illegal_payload",
                "coupling-library '$(ref)' edge of type '$(etype)' is not " *
                "role-substitutable (no callback entries or edge-level " *
                "expression_template_imports, esm-spec §10.9)"))
        end
        if !(etype isa AbstractString) || !(String(etype) in _ROLE_BEARING_TYPES)
            throw(ExpressionTemplateError(
                "coupling_library_illegal_payload",
                "coupling-library '$(ref)' contains an unsupported edge type " *
                "'$(etype)' (esm-spec §10.9)"))
        end
        for seg in _collect_role_segments(edge)
            if !(seg in role_set)
                throw(ExpressionTemplateError(
                    "coupling_edge_unknown_role",
                    "coupling-library '$(ref)': edge references '$(seg)', which is " *
                    "not a declared role (esm-spec §10.9)"))
            end
            push!(used_roles, seg)
        end
    end
    for role in roles
        if !(role in used_roles)
            throw(ExpressionTemplateError(
                "coupling_role_unused",
                "coupling-library '$(ref)': role '$(role)' is declared but " *
                "referenced by no edge (esm-spec §10.9)"))
        end
    end

    # Binding — total and checked (esm-spec §10.10.1).
    for key in keys(bind)
        if !(key in role_set)
            throw(ExpressionTemplateError(
                "coupling_import_unknown_role",
                "coupling_import ref '$(ref)': bind key '$(key)' is not a declared " *
                "role (esm-spec §10.10.1)"))
        end
    end
    for role in roles
        if !haskey(bind, role)
            throw(ExpressionTemplateError(
                "coupling_import_role_unbound",
                "coupling_import ref '$(ref)': role '$(role)' has no bind entry " *
                "(binding is total, esm-spec §10.10.1)"))
        end
        if !_resolves_to_component(file, bind[role])
            throw(ExpressionTemplateError(
                "coupling_import_bind_not_a_component",
                "coupling_import ref '$(ref)': bind '$(role)' -> '$(bind[role])' " *
                "does not resolve to a component (esm-spec §10.10.1)"))
        end
    end

    # Expand: substitute bound actuals for role names, one simultaneous rewrite.
    rw = ref_ -> _rewrite_scoped_ref(ref_, bind)
    expanded = CouplingEntry[]
    for edge in edges
        clone = _to_native_json(edge)
        _rewrite_entry!(clone, rw, rw)
        push!(expanded, coerce_coupling_entry(clone))
    end
    return expanded
end

"""
    expand_coupling_imports(file::EsmFile; base_path=".", load_ref=nothing)
        -> Vector{CouplingEntry}

Expand every `CouplingImport` entry in `file.coupling` into concrete edges,
splicing them in the position of the import entry (esm-spec §10.10.3). Returns
the effective coupling vector; a file with no `coupling_import` entries returns
`file.coupling` unchanged (same object, so no reload) and needs no options.

`base_path` anchors the import `ref`s. `load_ref` is an optional resolver
`(ref, base_path) -> raw JSON doc` (tests supply an in-memory resolver); it
defaults to [`_default_coupling_load_ref`](@ref).
"""
function expand_coupling_imports(file::EsmFile; base_path::AbstractString=".",
                                 load_ref=nothing)::Vector{CouplingEntry}
    coupling = file.coupling
    any(e -> e isa CouplingImport, coupling) || return coupling
    loader = load_ref === nothing ? _default_coupling_load_ref : load_ref
    out = CouplingEntry[]
    for entry in coupling
        if !(entry isa CouplingImport)
            push!(out, entry)
            continue
        end
        local lib
        try
            lib = loader(entry.ref, base_path)
        catch e
            e isa ExpressionTemplateError && rethrow(e)
            throw(ExpressionTemplateError(
                "coupling_import_unresolved",
                "coupling_import ref '$(entry.ref)' failed to load: $(e)"))
        end
        for expanded_edge in _expand_one(lib, entry.ref, entry.bind, file)
            push!(out, expanded_edge)
        end
    end
    return out
end
