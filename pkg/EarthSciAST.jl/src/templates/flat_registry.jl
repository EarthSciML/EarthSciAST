# The flatten-time merge of per-component template registries (esm-spec
# §9.6.4 rule 7, §10.7; esm-libraries-spec §4.7.5).

"""
    _merge_flat_registry(component_templates) -> (OrderedDict{String,Any}, OrderedDict{String,Dict{String,String}})

Merge the per-component materialized registries (compkey → block) into the
single document-scoped registry the flattened representation carries (esm-spec
§9.6.4 rule 7 / §10.7 / esm-libraries-spec §4.7.5 step 4): deep-equal same-name
entries dedupe at first occurrence; a colliding name (see
[`_registry_collision_names`](@ref)) renames its entry in EVERY owning component
to `<ComponentPath>.<name>`, with nested references inside the renamed bodies
rewritten in lockstep.

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
    # DOCUMENT ORDER (esm-libraries-spec §4.7.5 step 4, normative): components in
    # the order the file declares them, entries in the order their block declares
    # them. Both loops previously sorted "so dedup first-occurrence and the
    # collision rename are reproducible" — document order is equally
    # reproducible, and it is the order the spec fixes. Sorting agreed with it
    # only when component names happened to sort in declaration order. The
    # dedup / collision-rename SEMANTICS below are untouched.
    for (compkey, block) in component_templates
        _is_object(block) || continue
        path = String(last(split(compkey, "."; limit = 2)))
        for (k, _) in pairs(block)
            name = string(k)
            push!(get!(byname, name, Tuple{String, Any}[]), (path, _raw_get(block, name)))
        end
    end
    collide = _registry_collision_names(byname)
    for (name, occ) in byname
        if name in collide
            for (path, decl) in occ
                newname = "$path.$name"
                merged[newname] = decl
                get!(rename, path, Dict{String, String}())[name] = newname
            end
        else
            merged[name] = occ[1][2]
        end
    end
    # Nested references inside the renamed bodies follow their owner's map.
    for (_, rn) in rename
        for (_, new) in rn
            haskey(merged, new) && (merged[new] = _rename_apply_refs(merged[new], rn))
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
esm-libraries-spec §4.7.5 step 4). Given an Option-B loaded multi-component
document `loaded`, merge every component's `expression_templates` registry into
a single document-scoped merged registry:

- **Deep-equal dedup at first occurrence** — the common case, two components
  importing one stencil produce identical folded bodies, kept once under the
  bare name.
- **Non-deep-equal same-name collision** — both entries are renamed
  deterministically to `<ComponentPath>.<name>` and their
  `apply_expression_template` references are rewritten in lockstep (total,
  deterministic; no new diagnostic).
- **Collisions propagate along the reference DAG** — a declaration that
  references a colliding name collides too (see
  [`_registry_collision_names`](@ref)), so a byte-identical wrapper over a
  per-component leaf is renamed per owner rather than deduped into a single body
  whose nested reference no longer resolves.

Returns the rewritten document `root` (component reference sites updated) and
the merged registry as an `OrderedDict` (the FlattenedSystem's first-class
registry field). Downstream consumers resolve surviving references against it
or `Expand` them (§9.6.4 rule 2). `match` rules are not merged (only match-less
templates are referenceable, §9.6.2).
"""
function flatten_template_registries(loaded)
    root = _to_ordered(loaded)::OrderedDict{String, Any}
    # (path, compkind, cname, comp, named)
    comps = Tuple{String, String, String, OrderedDict{String, Any}, Dict{String, Any}}[]
    for (compkind, cname, comp) in _components(root)
        # Match rules are not merged.
        named = filter(((_, d),) -> _raw_get(d, "match") === nothing, _component_templates(comp))
        push!(comps, (cname, compkind, cname, comp::OrderedDict{String, Any}, named))
    end

    # Group each template name across components (preserving first-seen path).
    byname = OrderedDict{String, Vector{Tuple{String, Any}}}()
    for (path, _, _, _, named) in comps
        for n in sort(collect(keys(named)))
            push!(get!(byname, n, Tuple{String, Any}[]), (path, named[n]))
        end
    end

    merged = OrderedDict{String, Any}()
    rename = Dict{String, Dict{String, String}}()   # path => (old => new)
    collide = _registry_collision_names(byname)
    for name in sort(collect(keys(byname)))
        occ = byname[name]
        if name in collide
            for (path, decl) in occ                 # collision: owner-path rename
                newname = "$path.$name"
                merged[newname] = decl
                get!(rename, path, Dict{String, String}())[name] = newname
            end
        else
            merged[name] = occ[1][2]                # deep-equal dedup
        end
    end

    # Rewrite reference sites in lockstep (component expression positions and the
    # carried bodies of the renamed entries).
    for (path, _, _, comp, _) in comps
        rn = get(rename, path, nothing)
        rn === nothing && continue
        for k in collect(keys(comp))
            k == "expression_templates" && continue
            comp[k] = _rename_apply_refs(comp[k], rn)
        end
        # The merged (renamed) bodies owned by this path get their nested
        # references rewritten too.
        for (old, new) in rn
            haskey(merged, new) && (merged[new] = _rename_apply_refs(merged[new], rn))
        end
        # Drop the now-merged per-component block from the flattened form.
        haskey(comp, "expression_templates") && delete!(comp, "expression_templates")
    end
    for (_, _, _, comp, named) in comps
        # Components with no rename still surrender their (merged) block.
        haskey(comp, "expression_templates") && delete!(comp, "expression_templates")
    end

    return (root, merged)
end
