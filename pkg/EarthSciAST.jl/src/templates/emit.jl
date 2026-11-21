# Raw-document `Expand`, reference-preserving emit (esm-spec §9.6.4 rule 5)
# and its canonical byte writer.

# ===========================================================================
# `Expand` — the public full-expansion function (esm-spec §9.6.4 rule 2)
# ===========================================================================

"""
    Expand(loaded) -> Dict{String,Any}
    expand_document(loaded) -> Dict{String,Any}

Fully expand every surviving `apply_expression_template` reference in a document
`loaded` by `lower_expression_templates` (Option B), producing the Option-A
image: every reference replaced by its expansion (pure substitution to the
acyclic fixpoint, §9.6.4 rule 2) and every per-component `expression_templates`
block stripped. Deterministic — the DAG is acyclic and substitution confluent,
so `Expand(load_path(f))` is structurally equal to the pre-0.9.0 expanded form (the
`expanded*.esm` conformance oracle, §9.6.7). Non-destructive: `loaded` is deep
copied first.
"""
function expand_document(loaded)
    (loaded === nothing || !_is_object(loaded)) && return loaded
    root = _to_ordered(loaded)::OrderedDict{String, Any}

    # Capture each component's named registry BEFORE stripping the blocks.
    comp_named = Dict{Tuple{String, String}, Dict{String, Any}}(
        (compkind, cname) => _component_templates(comp)
            for (compkind, cname, comp) in _components(root)
    )
    for (compkind, cname, comp) in _components(root)
        named = comp_named[(compkind, cname)]
        for k in collect(keys(comp))
            (k == "expression_templates" || k == "expression_template_imports") && continue
            comp[k] = _expand_all(comp[k], named, "$compkind.$cname.$k")
        end
        haskey(comp, "expression_templates") && delete!(comp, "expression_templates")
    end

    for (i, entry, tr, comp_name) in _variable_map_transforms(root)
        named = get(
            comp_named, ("models", comp_name),
            get(comp_named, ("reaction_systems", comp_name), nothing)
        )
        named === nothing && continue
        entry["transform"] = _expand_all(tr, named, "coupling[$(i)].transform")
    end

    return root
end

"""
    Expand(loaded) -> Dict{String,Any}

Public alias for [`expand_document`](@ref) using the spec's spelling
(esm-spec §9.6.4 rule 2). `Expand ∘ load` reproduces the Option-A expanded form.
"""
Expand(loaded) = expand_document(loaded)

# ===========================================================================
# Reference-preserving emit (esm-spec §9.6.4 rule 5, §9.6.7)
# ===========================================================================

"""
    _ref_closure(refnames, named) -> Set{String}

The transitive closure of the templates named by `refnames` (surviving-reference
names), following references inside materialized bodies, keeping only MATCH-LESS
entries (esm-spec §9.6.4 rule 5: match rules are never materialized).
"""
_ref_closure(refnames, named::AbstractDict)::Set{String} =
    _reachable(_template_graph(named), refnames; through = n -> _raw_get(named[n], "match") === nothing)

"""
    _authored_template_names(raw_source) -> Dict{String,Vector{String}}

Per-component template names authored in-file in `raw_source` (compkind.cname
→ ordered names). Emit keeps these in authored position (esm-spec §9.6.4 rule
5): a match-less entry always, a `match` rule only when a firing referenced it
(it is then materialized without `match`, `where` and `priority`);
imported/derived templates are materialized instead.
"""
function _authored_template_names(raw_source)::Dict{String, Vector{String}}
    authored = Dict{String, Vector{String}}()
    for (compkind, cname, comp) in _components(raw_source)
        tpl = _raw_get(comp, "expression_templates")
        (tpl !== nothing && _is_object(tpl)) || continue
        authored["$compkind.$cname"] = String[
            string(n) for (n, d) in pairs(tpl) if _is_object(d)
        ]
    end
    return authored
end

"""
    _materialize_components!(root, authored) -> (blocks, bump)

The shared per-component materialization (esm-spec §9.6.4 rule 5): for each
component of the Option-B loaded `root`, compute its emitted
`expression_templates` block — authored match-less entries first in authored
order, then the materialized transitive closure of its surviving references
(match-less), lexicographically sorted — write it back onto the component, and
drop consumed `expression_template_imports`. Returns `blocks` (compkey →
`OrderedDict` emitted block, keyed `"<compkind>.<cname>"`, only for components
with a non-empty block) and `bump` (true iff any surviving reference or
materialized entry remains → §9.6.4 rule 8 version stamp). Shared by
[`emit_document`](@ref) (raw emit) and the typed load path (`_lower_and_coerce`).
"""
function _materialize_components!(root, authored::Dict{String, Vector{String}})
    # ORDERED by component: `_merge_flat_registry` consumes this map positionally
    # (esm-libraries-spec §4.7.5 step 4 makes the merged registry document-
    # ordered), and `_components` walks the raw document's own order.
    blocks = OrderedDict{String, OrderedDict{String, Any}}()
    bump = false
    for (compkind, cname, comp) in _components(root)
        key = "$compkind.$cname"
        named = _component_templates(comp)
        refnames = Set{String}()
        for (k, v) in comp
            (
                string(k) == "expression_templates" ||
                    string(k) == "expression_template_imports"
            ) && continue
            for r in _collect_apply_names!(String[], v)
                push!(refnames, r)
            end
        end
        isempty(refnames) || (bump = true)
        materialized = _ref_closure(refnames, named)
        authored_here = get(authored, key, String[])
        authored_set = Set(authored_here)

        emit_block = OrderedDict{String, Any}()
        for n in authored_here
            # A `match` rule nothing references still carries its `match`
            # (a referenced one was materialized without it, §9.6.4 rule 3).
            haskey(named, n) && _raw_get(named[n], "match") === nothing &&
                (emit_block[n] = named[n])
        end
        for n in sort(collect(setdiff(materialized, authored_set)))
            emit_block[n] = named[n]
            bump = true
        end

        if isempty(emit_block)
            haskey(comp, "expression_templates") && delete!(comp, "expression_templates")
        else
            comp["expression_templates"] = emit_block
            blocks[key] = emit_block
        end
        haskey(comp, "expression_template_imports") &&
            delete!(comp, "expression_template_imports")
    end
    haskey(root, "expression_template_imports") && delete!(root, "expression_template_imports")
    return (blocks, bump)
end

"""
    _registry_collision_names(byname) -> Set{String}

The set of template names that MUST be owner-path renamed by the flatten-time
registry merge (esm-spec §9.6.4 rule 7 / §10.7). `byname` maps a template name
to its per-component occurrences `[(path, decl), …]`.

A name collides directly when its occurrences are not all deep-equal. The set is
then closed under the reference DAG: **if a declaration references a colliding
name, that declaration collides too**, in every component that carries it. This
propagation is what makes the rename total.

Without it, the common multi-model shape silently breaks. Two components import
one rule library; the leaf stencil folds differently per component (a rebind, a
metaparameter, or — in `flatten` — the §10.7 component-scoping of its free
variables) so it renames to `A.leaf` / `B.leaf`, while the intermediate wrapper
that REFERENCES the leaf is byte-identical and would dedup under its bare name.
The single deduped body then carries a reference to a name no longer in the
registry, and expansion fails with
`apply_expression_template_unknown_template` naming a template no component ever
mentioned. Renaming the wrapper per owner too lets each copy's nested reference
be rewritten to its own owner's leaf.

A consequence worth relying on: a name left OUT of the returned set never
references a name inside it, so deduped entries need no reference rewriting.
"""
function _registry_collision_names(byname::AbstractDict)::Set{String}
    refs = OrderedDict{String, Vector{String}}()
    for (name, occ) in byname
        s = String[]
        for (_, decl) in occ
            _collect_apply_names!(s, decl)
        end
        refs[name] = unique!(s)
    end
    flags = _flagged(_TemplateGraph(refs)) do name
        occ = byname[name]
        !all(o -> _json_equal(occ[1][2], o[2]), occ)
    end
    return Set{String}(n for (n, f) in flags if f)
end

# Each `variable_map` coupling entry of the raw document `root` whose
# `transform` is an expression object, as `(index, entry, transform,
# receiving component)`: the receiving component is the first segment of `to`,
# whose template registry the transform's references resolve against
# (esm-spec §10.4/§10.5).
function _variable_map_transforms(root)
    out = Tuple{Int, Any, Any, String}[]
    coupling = get(root, "coupling", nothing)
    coupling isa AbstractVector || return out
    for (i, entry) in enumerate(coupling)
        _is_object(entry) || continue
        get(entry, "type", nothing) == "variable_map" || continue
        tr = get(entry, "transform", nothing)
        _is_object(tr) || continue
        target = get(entry, "to", nothing)
        target isa AbstractString || continue
        push!(out, (i, entry, tr, String(first(split(target, "."; limit = 2)))))
    end
    return out
end

"""
    _expand_coupling_transform_refs!(root)

Expand surviving `apply_expression_template` references inside `variable_map`
coupling `transform`s (esm-spec §10.4) against the RECEIVING component's registry.
Coupling is not a component, so these references cannot be per-component
materialized (§9.6.4 rule 5); expanding them at load keeps the coupling section
self-contained. Called by the typed load path before `_materialize_components!`
strips the component registries.
"""
function _expand_coupling_transform_refs!(root)
    for (_, entry, tr, comp_name) in _variable_map_transforms(root)
        comp = nothing
        for (_, cname, c) in _components(root)
            cname == comp_name && (comp = c; break)
        end
        comp === nothing && continue
        _is_object(_raw_get(comp, "expression_templates")) || continue
        named = _component_templates(comp)
        entry["transform"] = _expand_all(tr, named, "coupling.transform")
    end
    return
end

"""
    TEMPLATE_MACHINERY_MIN_ESM

The format version at which the Option-B template machinery landed. A document
carrying a surviving `apply_expression_template` reference or a materialized
`expression_templates` block is stamped to AT LEAST this (esm-spec §9.6.4 rule
8).
"""
const TEMPLATE_MACHINERY_MIN_ESM = "0.9.0"

"""
    _esm_stamp_floor(declared) -> String

The version to stamp on an emitted document: its own `esm` when that already
meets [`TEMPLATE_MACHINERY_MIN_ESM`](@ref), else the floor.

The stamp is a MINIMUM — "a consumer needs at least this" — so it may only ever
RAISE a version. Writing the floor unconditionally would downgrade an esm 1.0.0
document to `0.9.0`, whose schema does not describe it at all: 1.0.0 declares
`unknown` variables and a `data_sources` registry that 0.9.0 has no place for.
"""
function _esm_stamp_floor(declared)
    declared isa AbstractString || return TEMPLATE_MACHINERY_MIN_ESM
    d = _parse_esm_version(declared)
    d === nothing && return TEMPLATE_MACHINERY_MIN_ESM
    return d >= _parse_esm_version(TEMPLATE_MACHINERY_MIN_ESM) ? String(declared) :
        TEMPLATE_MACHINERY_MIN_ESM
end

"""
    emit_document(raw_source, base_path) -> Dict{String,Any}

Produce the reference-preserving, self-contained emitted document (esm-spec
§9.6.4 rule 5, RFC out-of-line-expression-templates §7.5) from a source document
(a fixture, or an already-emitted document for the idempotency property). Loads
`raw_source` under Option B, then materializes each component's
`expression_templates` block ([`_materialize_components!`](@ref)), drops consumed
`expression_template_imports`, and version-stamps `esm: 0.9.0` when any surviving
reference or materialized entry remains (§9.6.4 rule 8). `emit_esm_string ∘
emit_document` is a byte-wise fixed point under reload.

`raw_source` passes the same wire boundary a load applies
(`_prepare_document_ops!`), on a copy: a removed op is refused, and a
deprecated `neg` / `pow` is rewritten with the `deprecated_op` warning, so
neither spelling survives into the emitted document (esm-spec §4.2).
"""
function emit_document(raw_source, base_path::AbstractString)
    if raw_source isa AbstractDict || _is_object(raw_source)
        raw_source = _to_ordered(raw_source)
        _prepare_document_ops!(raw_source)
    end
    authored = _authored_template_names(raw_source)
    resolved = resolve_template_machinery(raw_source, String(base_path))
    src = resolved === nothing ? raw_source : resolved
    loaded = lower_expression_templates(src)
    # Fast path returns `src` by identity; normalize it into a fresh mutable
    # native tree. The processed path already returns one.
    root = loaded === src ? _to_ordered(loaded)::OrderedDict{String, Any} : loaded
    _blocks, bump = _materialize_components!(root, authored)
    bump && (root["esm"] = _esm_stamp_floor(get(root, "esm", nothing)))
    return root
end

# --- Canonical byte writer (2-space indent, keys sorted except the ordered
#     `expression_templates` block) — the cross-binding byte-identity surface. ---

_emit_norm(x) =
    (x isa AbstractDict) ?
    OrderedDict{String, Any}(string(k) => _emit_norm(v) for (k, v) in pairs(x)) :
    (_is_object(x)) ?
    OrderedDict{String, Any}(string(k) => _emit_norm(v) for (k, v) in pairs(x)) :
    (x isa AbstractVector || _is_array(x)) ? Any[_emit_norm(v) for v in x] : x

function _emit_write(io::IO, x, indent::Int; preserve::Bool = false)
    pad = "  "^indent
    pad1 = "  "^(indent + 1)
    return if x isa AbstractDict
        isempty(x) && return print(io, "{}")
        ks = preserve ? collect(keys(x)) : sort(collect(keys(x)))
        print(io, "{\n")
        for (i, k) in enumerate(ks)
            print(io, pad1, JSON3.write(string(k)), ": ")
            _emit_write(
                io, x[k], indent + 1;
                preserve = (string(k) == "expression_templates")
            )
            i < length(ks) && print(io, ",")
            print(io, "\n")
        end
        print(io, pad, "}")
    elseif x isa AbstractVector
        isempty(x) && return print(io, "[]")
        print(io, "[\n")
        for (i, v) in enumerate(x)
            print(io, pad1)
            _emit_write(io, v, indent + 1)
            i < length(x) && print(io, ",")
            print(io, "\n")
        end
        print(io, pad, "]")
    else
        print(io, JSON3.write(x))
    end
end

"""
    emit_esm_string(doc) -> String

Canonical byte serialization of an emitted document (esm-spec §9.6.4 rule 5):
2-space indent, object keys sorted lexicographically EXCEPT the entries of an
`expression_templates` object, which preserve their authored-first /
materialized-sorted order. The cross-binding byte-identity surface for the
Option-B emitted form and the target of the `emitted.esm` goldens.
"""
function emit_esm_string(doc)::String
    io = IOBuffer()
    _emit_write(io, _emit_norm(doc), 0)
    print(io, "\n")
    return String(take!(io))
end
