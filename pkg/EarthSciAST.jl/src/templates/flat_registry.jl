# The flatten-time merge of per-component template registries (esm-spec
# §9.6.4 rule 7, §10.7; esm-libraries-spec §4.7.5).

"""
    _merge_flat_registry(component_templates) -> (OrderedDict{String,Any}, OrderedDict{String,Dict{String,String}})

Merge the per-component materialized registries (compkey → block) into the
single document-scoped registry the flattened representation carries (esm-spec
§9.6.4 rule 7 / §10.7 / esm-libraries-spec §4.7.5 step 4): deep-equal same-name
entries dedupe at first occurrence; for a colliding name (see
[`_registry_collision_names`](@ref)) the owners whose entries are deep-equal,
once their nested references are renamed, share ONE entry named
`<first such owner's path>.<name>` (document order), so a definition two owners
carry identically (a leaf mounted twice) stays one definition, and each owner's
references are renamed to its entry in lockstep.

Returns the merged registry AND the per-component rename map
(`path → (old name => new name)`). The caller MUST apply that map to the owning
component's reference sites — `flatten` does so alongside namespacing — or the
renamed entries become unreachable. `nothing` in ⇒ empty out.
"""
function _merge_flat_registry(component_templates)
    merged = OrderedDict{String, Any}()
    rename = OrderedDict{String, Dict{String, String}}()
    component_templates === nothing && return (merged, rename)
    byname = OrderedDict{String, Vector{Tuple{String, Any}}}()
    # Document order (esm-libraries-spec §4.7.5 step 4, normative): components
    # in the order the file declares them, entries in the order their block
    # declares them.
    for (compkey, block) in component_templates
        _is_object(block) || continue
        path = String(last(split(compkey, "."; limit = 2)))
        for (k, _) in pairs(block)
            name = string(k)
            push!(get!(byname, name, Tuple{String, Any}[]), (path, _raw_get(block, name)))
        end
    end
    collide = _registry_collision_names(byname)
    # A colliding name's entries, callees first: each owner's entry with its
    # nested references renamed to that owner's entries, grouped by deep
    # equality; a group is one entry, named after its first owner.
    groups = Dict{String, Vector{Tuple{String, Any}}}()
    function settle(name::String)
        haskey(groups, name) && return groups[name]
        gs = Tuple{String, Any}[]
        for (path, decl) in byname[name]
            rn = Dict{String, String}()
            for c in _collect_apply_names!(String[], decl)
                (c in collide && c != name) || continue
                settle(c)
                new = get(get(rename, path, Dict{String, String}()), c, nothing)
                new === nothing || (rn[c] = new)
            end
            d = isempty(rn) ? decl : _rename_apply_refs(decl, rn)
            i = findfirst(g -> _json_equal(g[2], d), gs)
            if i === nothing
                push!(gs, ("$path.$name", d))
                i = length(gs)
            end
            get!(rename, path, Dict{String, String}())[name] = gs[i][1]
        end
        groups[name] = gs
        return gs
    end
    for (name, _) in byname
        name in collide && settle(name)
    end
    for (name, occ) in byname
        if name in collide
            for (newname, decl) in groups[name]
                merged[newname] = decl
            end
        else
            merged[name] = occ[1][2]
        end
    end
    return (merged, rename)
end

# ===========================================================================
# Flatten: template-registry merge (esm-spec §9.6.4 rule 7, §10.7;
# esm-libraries-spec §4.7.5)
# ===========================================================================

"""
    _rename_apply_refs(node, rename) -> node

Rewrite the `name` of every `apply_expression_template` reference in `node`
according to `rename` (old name → new name), in lockstep with a registry
rename. Sharing-preserving.
"""
function _rename_apply_refs(node, rename::AbstractDict{String, String})
    return _rewrite_json(node; leaves = false) do rw, n
        _is_apply_node(n) || return _JSON_DESCEND
        name = _raw_get(n, "name")
        (name isa AbstractString && haskey(rename, String(name))) || return _JSON_DESCEND
        out = _rewrite_json_children(rw, n; keep = "name")
        out === n && (out = OrderedDict{String, Any}(string(k) => v for (k, v) in pairs(n)))
        out["name"] = rename[String(name)]
        return out
    end
end

"""
    _rename_expr_apply_refs(e, rename) -> ASTExpr

Typed-AST twin of [`_rename_apply_refs`](@ref): rewrite the `name` of every
`apply_expression_template` `OpExpr` in `e` according to `rename` (old → new),
in lockstep with the flatten-time registry rename (esm-spec §10.7). Recurses via
`map_children`, which descends `bindings` values too, so a nested reference
passed as a binding is renamed as well. Returns `e` unchanged when nothing hits.
"""
_rename_expr_apply_refs(e::VarExpr, ::AbstractDict{String, String}) = e
_rename_expr_apply_refs(e::NumExpr, ::AbstractDict{String, String}) = e
_rename_expr_apply_refs(e::IntExpr, ::AbstractDict{String, String}) = e
function _rename_expr_apply_refs(e::OpExpr, rename::AbstractDict{String, String})
    r = map_children(c -> _rename_expr_apply_refs(c, rename), e)::OpExpr
    if r.op == APPLY_EXPRESSION_TEMPLATE_OP && r.name !== nothing &&
            haskey(rename, r.name::String)
        return reconstruct(r; name = rename[r.name::String])
    end
    return r
end

"""
    flatten_template_registries(loaded) -> (root, merged_registry)

The flatten-time template-registry merge (esm-spec §9.6.4 rule 7, §10.7;
esm-libraries-spec §4.7.5 step 4) over an Option-B loaded multi-component
document `loaded`: every component's match-less `expression_templates` entries
go through [`_merge_flat_registry`](@ref) (`match` rules are not merged; only
match-less templates are referenceable, §9.6.2), so

- **deep-equal same-name entries dedupe at first occurrence** — two components
  importing one stencil produce identical folded bodies, kept once under the
  bare name;
- **a non-deep-equal same-name collision** renames the entries to
  `<ComponentPath>.<name>`, one entry per distinct definition, named after its
  first owner, with every owner's `apply_expression_template` references
  rewritten in lockstep (total, deterministic; no new diagnostic);
- **collisions propagate along the reference DAG** — a declaration that
  references a colliding name collides too (see
  [`_registry_collision_names`](@ref)), so a byte-identical wrapper over a
  per-component leaf is renamed per owner rather than deduped into a single body
  whose nested reference no longer resolves.

The merged registry is in document order: components as the file declares
them, entries as their block declares them. Returns the rewritten document
`root` (each component's reference sites renamed and its
`expression_templates` block removed) and the merged registry as an
`OrderedDict` (the FlattenedSystem's first-class registry field). Downstream
consumers resolve surviving references against it or `Expand` them (§9.6.4
rule 2).
"""
function flatten_template_registries(loaded)
    root = _to_ordered(loaded)::OrderedDict{String, Any}
    comps = Tuple{String, OrderedDict{String, Any}}[]       # (path, comp)
    blocks = OrderedDict{String, Any}()                    # compkey => match-less block
    for (compkind, cname, comp) in _components(root)
        push!(comps, (cname, comp::OrderedDict{String, Any}))
        tpl = _raw_get(comp, "operators")
        _is_object(tpl) || continue
        blocks["$compkind.$cname"] = OrderedDict{String, Any}(
            string(n) => d for (n, d) in pairs(tpl) if _raw_get(d, "match") === nothing
        )
    end
    merged, rename = _merge_flat_registry(blocks)

    # Rewrite each component's reference sites in lockstep with its renames,
    # and drop its now-merged block from the flattened form.
    for (path, comp) in comps
        rn = get(rename, path, nothing)
        if rn !== nothing
            for k in collect(keys(comp))
                k == "operators" && continue
                comp[k] = _rename_apply_refs(comp[k], rn)
            end
        end
        delete!(comp, "operators")
    end
    return (root, merged)
end
