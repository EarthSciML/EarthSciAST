# esm-spec §4.7 mount helpers: the walk of metaparameters declared by mounted
# documents, the data-source `extent` check, and mount-edge index-set renaming.

"""
    _collect_mount_declared_metaparameters(raw, base_path) -> Set{String}

The metaparameter names declared by every document `raw` MOUNTS, at either
§4.7 mount form — a top-level `models.<k>` / `reaction_systems.<k>` `{ref}` and
a `subsystems.<j>` `{ref}` — transitively through the mount DAG.

A §4.7 mount edge CONSUMES the referenced document's `metaparameters` at the
edge (§9.7.6 binding site 3), so those names never reach the mounting
document's own declared set — which is why a loader-API binding for one of them
used to be refused at a root that had no reason to redeclare it. This walk is
what lets the site-4 check (and the §8.9.4 `extent` check) ask "does ANYONE in
this assembly declare that name?" instead of "does the root".

Reads only each referenced file's top-level `metaparameters` KEYS. A ref that
cannot be read is IGNORED: this walk exists only to WIDEN acceptance, and the
resolution error belongs to the ref resolver, which reports it with the proper
mount pointer. `seen` (canonical ref identity) cycle-guards the walk.
"""
function _collect_mount_declared_metaparameters(
        raw, base_path::AbstractString,
        seen::Set{String} = Set{String}(); follow_imports::Bool = false
    )::Set{String}
    out = Set{String}()
    _is_object(raw) || return out
    base = String(base_path)

    function visit_ref!(ref_value)
        _is_object(ref_value) || return
        rv = _raw_get(ref_value, "ref")
        rv isa AbstractString || return
        ref_str = String(rv)
        key = try
            _canonical_ref(_expand_ref_env(ref_str, base), base)
        catch
            return
        end
        key in seen && return
        push!(seen, key)
        loaded = try
            _load_import_raw(ref_str, base, "mount-declared walk")
        catch
            return   # unreadable ref: not this walk's diagnostic to raise
        end
        child, child_base = loaded
        _is_object(child) || return
        decls = _raw_get(child, "metaparameters")
        if decls !== nothing && _is_object(decls)
            for (n, _) in pairs(decls)
                push!(out, string(n))
            end
        end
        union!(
            out, _collect_mount_declared_metaparameters(
                child, child_base, seen;
                follow_imports = follow_imports
            )
        )
        return
    end

    # The §9.7.2 import edges one scope carries, when asked for.
    function visit_imports!(holder)
        (follow_imports && _is_object(holder)) || return
        entries = _raw_get(holder, "expression_template_imports")
        entries isa AbstractVector || return
        for entry in entries
            visit_ref!(entry)
        end
        return
    end

    # A `subsystems` map to any depth: an INLINE entry may itself hold the
    # `{ref}` mount whose leaf declares the name.
    function visit_subsystems!(holder)
        subs = _raw_get(holder, "subsystems")
        (subs !== nothing && _is_object(subs)) || return
        for (_, sub) in pairs(subs)
            _is_object(sub) || continue
            visit_ref!(sub)                        # a `subsystems.<j>` {ref}
            visit_imports!(sub)
            visit_subsystems!(sub)
        end
        return
    end

    visit_imports!(raw)   # a DOCUMENT-level `expression_template_imports`
    for compkind in _COMPONENT_KINDS
        comps = _raw_get(raw, compkind)
        (comps !== nothing && _is_object(comps)) || continue
        for (_, comp) in pairs(comps)
            _is_object(comp) || continue
            visit_ref!(comp)                       # top-level `models.<k>` {ref}
            visit_imports!(comp)
            visit_subsystems!(comp)
        end
    end
    return out
end

"""
    fold_mount_contribution(decl, env) -> decl

Fold ONE §4.7 mount contribution's interval `size` against the MOUNTING
document's already-closed metaparameter environment, before the deep-equal
comparison that merges it (esm-spec §4.7 "Index-set merge").

This is the step that makes the merge order answerable. A §4.7 mount resolves
POST-CLOSE (§9.7.6 site 3: "the mounting document closes its own metaparameters
before its refs resolve"), so by the time a contribution arrives the registry
side has already folded to integers. Comparing an unfolded contribution against
a folded registry entry makes two IDENTICAL declarations collide, which is issue
#198; and leaving the contribution unfolded publishes a resolved document whose
axis still carries a metaparameter name, which contradicts "the mounted form is
fully concrete when it splices in" and §9.7.6 site 5's "closed at some enclosing
document's close".

In THIS binding it does one more job: `IndexSet.size` is `Union{Int,Nothing}`, so
a still-symbolic size cannot survive typed coercion at all. Folding here, on the
native tree and after the leaf's own close, is what lets an assembler-scoped axis
cross a `subsystems.<k>` mount without widening the typed registry.

A `size` already an integer is returned unchanged. A `size` whose free names are
NOT all in `env` stays symbolic rather than throwing: the enclosing document is
not obliged to be able to close a name the assembly never declared. A size whose
names are all bound but which does not fold (`/` that does not divide exactly,
overflow) raises the folding error.
"""
function fold_mount_contribution(decl, env::AbstractDict{String, <:Integer})
    _is_object(decl) || return decl
    sz = _raw_get(decl, "size")
    sz === nothing && return decl
    (sz isa Integer && !(sz isa Bool)) && return decl
    expr = _to_native_json(sz)
    # A free name the enclosing environment does not bind leaves the size
    # symbolic; any other folding failure (inexact division, overflow, a
    # non-integer literal) is the document's error and propagates.
    all(n -> haskey(env, n), _collect_names!(String[], expr)) || return decl
    folded = eval_meta_expr(
        expr, Dict{String, Int}(String(k) => Int(v) for (k, v) in env),
        "index set size"
    )
    out = OrderedDict{String, Any}()
    for (k, v) in pairs(decl)
        out[String(k)] = v
    end
    out["size"] = folded
    return out
end

"""
    _fold_mount_contributions!(native_index_sets, env) -> native_index_sets

Apply [`fold_mount_contribution`](@ref) across one native `index_sets` block,
in place. Used on a MOUNTED leaf's registry once its own close has run, so a
size only the enclosing document can bind is concrete before coercion.
"""
function _fold_mount_contributions!(isets, env::AbstractDict{String, <:Integer})
    (isets !== nothing && _is_object(isets)) || return isets
    isempty(env) && return isets
    for (n, decl) in collect(pairs(isets))
        folded = fold_mount_contribution(decl, env)
        folded === decl || (isets[n] = folded)
    end
    return isets
end

"""
    _document_has_unresolved_mount(raw) -> Bool

Whether `raw` still carries an unresolved §4.7 mount — a top-level
`models.<k>` / `reaction_systems.<k>` `{ref}` or a `subsystems.<k>` `{ref}`.
"""
function _document_has_unresolved_mount(raw)::Bool
    _is_object(raw) || return false
    for compkind in _COMPONENT_KINDS
        comps = _raw_get(raw, compkind)
        (comps !== nothing && _is_object(comps)) || continue
        for (_, comp) in pairs(comps)
            _is_object(comp) || continue
            _has_field(comp, :ref) && return true
            subs = _raw_get(comp, "subsystems")
            (subs !== nothing && _is_object(subs)) || continue
            for (_, sub) in pairs(subs)
                (_is_object(sub) && _has_field(sub, :ref)) && return true
            end
        end
    end
    return false
end

"""
    _index_sets_are_fully_folded(raw) -> Bool

Whether `raw` declares at least one index set and every interval `size` in the
registry is already a concrete integer — the state a document reaches only
after its metaparameters have closed and folded. Requiring at least one entry
keeps the vacuous case (no `index_sets` at all, where nothing has been folded)
on the checked path.
"""
function _index_sets_are_fully_folded(raw)::Bool
    _is_object(raw) || return false
    isets = _raw_get(raw, "index_sets")
    (isets !== nothing && _is_object(isets)) || return false
    any_entry = false
    for (_, decl) in pairs(isets)
        any_entry = true
        _is_object(decl) || continue
        sz = _raw_get(decl, "size")
        sz === nothing && continue
        (sz isa Integer && !(sz isa Bool)) || return false
    end
    return any_entry
end

"""
    _document_is_in_resolved_shape(raw) -> Bool

Whether `raw` is in the shape only a RESOLVED document has: no unresolved §4.7
mount left, and at least one index set with every interval `size` already a
concrete integer.

[`check_data_source_extents`](@ref) is an AUTHORING check and has to stay
idempotent. A §4.7 mount CONSUMES the leaf's `metaparameters` (§9.7.6 site 3),
so once a document has been resolved, a name only the leaf declared is declared
nowhere and the `{ref}` stub the mount walk reads is gone — while the `extent`
that named it is still there, having already done its job. A binding that
re-loads its own resolved document (Rust does, at build) must not be told that
document is invalid. esm-spec §8.9.4 states the exemption normatively, so all
five bindings answer the same document the same way.
"""
_document_is_in_resolved_shape(raw)::Bool =
    !_document_has_unresolved_mount(raw) && _index_sets_are_fully_folded(raw)

"""
    _document_declares_an_extent(raw) -> Bool

Whether any `data_sources` entry carries an `extent` (esm-spec §8.9.4).

The cheap guard on the mount walk above: the widened §9.7.6 site-4 check and
[`check_data_source_extents`](@ref) are its only callers, and neither can
matter unless the load either carries loader-API bindings or the document
declares an `extent`. A document with neither pays no ref reads for this at all
— which also keeps a remote `{ref}` from being fetched once for the walk and
again for the ref resolver.
"""
function _document_declares_an_extent(raw)::Bool
    _is_object(raw) || return false
    sources = _raw_get(raw, "data_sources")
    (sources !== nothing && _is_object(sources)) || return false
    for (_, src) in pairs(sources)
        _is_object(src) || continue
        ex = _raw_get(src, "extent")
        (ex !== nothing && _is_object(ex)) && return true
    end
    return false
end

"""
    check_data_source_extents(raw, base_path, mount_declared=nothing)

esm-spec §8.9.4: every `data_sources.<k>.extent.metaparameter` MUST name a
metaparameter THIS document declares, or one a document it MOUNTS declares.

A discovered extent is a §9.7.6 site-4 loader-API binding, and "binding an
unknown name is an error" — but that error could only be raised once the source
had been SAMPLED, which happens at build. So an `extent` naming a metaparameter
nobody declares used to validate clean and fail only when the file was read,
with a diagnostic about the loader API rather than about the typo. The
condition is decidable from the documents alone, so it is decided HERE, at
load, and `validate` refuses it: `template_import_unknown_name`, the code
§9.7.6 already gives an unknown name at a binding site (no new code — §9.6.6
codes are the cross-binding contract).
"""
function check_data_source_extents(
        raw, base_path::AbstractString,
        mount_declared::Union{Nothing, AbstractSet{String}} = nothing
    )
    _is_object(raw) || return
    sources = _raw_get(raw, "data_sources")
    (sources !== nothing && _is_object(sources)) || return
    # Collect the extent sites FIRST: a document with no `extent` at all must
    # not pay the mount walk, and must not reach `_collect_metaparam_decls`
    # (whose own type diagnostics belong to resolution, not to this check).
    sites = Tuple{String, String}[]
    for (key, src) in pairs(sources)
        _is_object(src) || continue
        extent = _raw_get(src, "extent")
        (extent !== nothing && _is_object(extent)) || continue
        name = _raw_get(extent, "metaparameter")
        name isa AbstractString || continue
        push!(sites, (string(key), String(name)))
    end
    isempty(sites) && return
    _document_is_in_resolved_shape(raw) && return
    declared = Set{String}(keys(_collect_metaparam_decls(raw, "document")))
    union!(
        declared, mount_declared === nothing ?
            _collect_mount_declared_metaparameters(raw, base_path) : mount_declared
    )
    # Widened LAZILY, only for a name about to be refused: a metaparameter an
    # imported library declares and the edge leaves unbound is RE-EXPORTED into
    # this document's scope (§9.7.6 site 2) and is a perfectly good loader-API
    # binding target — but this check runs on the AUTHORED tree, before the
    # imports resolve, so it has to walk for it. A conforming document pays
    # nothing: the walk runs only on the path that would otherwise throw.
    reachable = nothing
    for (key, name) in sites
        name in declared && continue
        if reachable === nothing
            reachable = _collect_mount_declared_metaparameters(
                raw, base_path;
                follow_imports = true
            )
        end
        name in reachable && continue
        throw(
            ExpressionTemplateError(
                ERROR_CODES.TEMPLATE_IMPORT_UNKNOWN_NAME,
                "data_sources.$key.extent binds metaparameter '$name', which neither " *
                    "this document nor any document it mounts declares " *
                    "(esm-spec §8.9.4, §9.7.6)"
            )
        )
    end
    return
end

# ---------------------------------------------------------------------------
# Mount-edge index-set renaming (esm-spec §4.7 "Mount-edge index-set renaming")
# ---------------------------------------------------------------------------

"""
    _mount_rename_walk!(x, m)

One index-set substitution pass, IN PLACE, over a fully resolved mounted
document (esm-spec §4.7 "Mount-edge index-set renaming", transitivity list).

Deliberately NOT [`_rename_walk`](@ref): that walk is written for template and
index-set DECLARATIONS, where `from` only ever occurs as a range reference and
every bare string is a variable-reference position. A mount carries a whole
component, where `from` also names a data source (`Parameter.update.from`), a
coupling endpoint (`variable_map.from`) and a connector endpoint, and where
`shape` lists, `Assertion.coords` keys and `DataSourceSelectAxis.gated_by` name
axes no declaration walk ever sees. So this walk touches ONLY positions that are
index-set names BY POSITION and never rewrites a bare string on its own account —
a name it does not recognise is left exactly as spelled.

`x` must already be a mutable native tree (`_to_ordered`).
"""
function _mount_rename_walk!(x, m::AbstractDict{String, String})
    if _is_array(x)
        for e in x
            _mount_rename_walk!(e, m)
        end
        return x
    end
    _is_object(x) || return x

    # An ExpressionNode is identified by its `op`; only there are wrt/dim/var,
    # the `integral` bounds and `ranges` axis positions (esm-spec §4.2 / §4.3.1).
    is_node = get(x, "op", nothing) isa AbstractString
    if is_node
        for k in Iterators.flatten((_RENAME_AXIS_KEYS, _RENAME_BOUND_KEYS))
            v = get(x, k, nothing)
            if v isa AbstractString && haskey(m, String(v))
                x[k] = m[String(v)]
            end
        end
        ranges = get(x, "ranges", nothing)
        if _is_object(ranges)
            for (_, rv) in pairs(ranges)
                # `{"from": <index set>}`; a range's own `of` is a list of BOUND
                # SYMBOLS, never index-set names.
                _is_object(rv) || continue
                frm = get(rv, "from", nothing)
                if frm isa AbstractString && haskey(m, String(frm))
                    rv["from"] = m[String(frm)]
                end
            end
        end
        # `join.<i>.on` key columns (§4.9.5): an entry follows the rename iff it
        # names a renamed index set; a loop symbol or a data-column name is left
        # as spelled. A clause's `syms` are bound symbols, never axes.
        join_clauses = get(x, "join", nothing)
        if _is_array(join_clauses)
            for clause in join_clauses
                _is_object(clause) || continue
                on = get(clause, "on", nothing)
                _is_join_on_pairs(on) || continue
                clause["on"] = _rename_join_on(on, m, identity)
            end
        end
    else
        # `ModelVariable`/`Parameter` `shape` and a `where` constraint's `shape`
        # are ordered index-set names; an ExpressionNode `shape` (`reshape`'s
        # target extents) are integers, so the `is_node` guard plus the string
        # test cover both.
        shape = get(x, "shape", nothing)
        if _is_array(shape)
            x["shape"] = Any[e isa AbstractString ? get(m, String(e), e) : e for e in shape]
        end
    end

    # `DataSourceSelectAxis.gated_by` names a `kind: "derived"` set.
    gated = get(x, "gated_by", nothing)
    if gated isa AbstractString && haskey(m, String(gated))
        x["gated_by"] = m[String(gated)]
    end

    # `Assertion.coords` KEYS are spatial index-set names (esm-spec §6.6.5).
    coords = get(x, "coords", nothing)
    if _is_object(coords) && any(haskey(m, String(k)) for k in keys(coords))
        renamed = OrderedDict{String, Any}()
        for (k, v) in pairs(coords)
            renamed[get(m, String(k), String(k))] = v
        end
        x["coords"] = renamed
    end

    for (_, v) in pairs(x)
        _mount_rename_walk!(v, m)
    end
    return x
end

"""
    apply_mount_index_set_rename(doc, rename_raw, where) -> native tree

Apply a mount edge's `index_set_rename` to a FULLY RESOLVED mounted document
(esm-spec §4.7 "Mount-edge index-set renaming"), returning a mutable native tree.

Runs at pipeline step 2: after the referenced document has resolved as a complete
document (its own imports, this edge's `bindings` and §9.7.10 injection, its
metaparameter close and the §9.6.3 fixpoint) and BEFORE its `index_sets` merge
into the mounting registry — so the map's KEYS speak the mounted document's own
post-resolution vocabulary, exactly as §9.7.7's `rename` speaks the import
target's export vocabulary.

An absent (`nothing`) or empty map is the identity, which is what makes the field
purely additive.
"""
function apply_mount_index_set_rename(
        doc, rename_raw, where::AbstractString;
        nested_contributed::AbstractSet{String} = Set{String}()
    )
    (rename_raw === nothing || !_is_object(doc)) && return doc
    requested = _name_map(rename_raw, "index_set_rename", where)

    isets = _get_field(doc, :index_sets, nothing)
    # `nested_contributed` names the index sets that reached this registry ONLY
    # through a mount nested inside the referenced document. esm-spec §4.7 scopes
    # this edge to "what THIS referenced document declares and imports", so they
    # are held out of the edge's vocabulary: naming one is
    # `subsystem_index_set_rename_unknown_name`. A name the document ALSO
    # declares itself is not in the set and is renamed normally — the §4.7 merge
    # already made the two one axis, so the rename reaches the nested content.
    declared = _is_object(isets) ?
        String[string(k) for k in keys(isets) if !(string(k) in nested_contributed)] : String[]

    # Renames never invent names (esm-spec §4.7, mirroring §9.7.7).
    for key in keys(requested)
        key in declared || throw(
            ExpressionTemplateError(
                ERROR_CODES.SUBSYSTEM_INDEX_SET_RENAME_UNKNOWN_NAME,
                "$(where): `index_set_rename` names index set '$(key)', which the " *
                    "resolved mounted document does not declare (it declares: " *
                    "$(isempty(declared) ? "none" : join(declared, ", "))). Keys speak the " *
                    "MOUNTED document's own post-resolution vocabulary (esm-spec §4.7 " *
                    "\"Mount-edge index-set renaming\")"
            )
        )
    end

    # Identity entries are no-ops; everything else must land on a distinct name.
    changed = OrderedDict{String, String}(o => n for (o, n) in requested if o != n)
    isempty(changed) && return doc
    finals = String[]
    for name in declared
        final = get(changed, name, name)
        final in finals && throw(
            ExpressionTemplateError(
                ERROR_CODES.TEMPLATE_IMPORT_RENAME_COLLISION,
                "$(where): `index_set_rename` maps two index sets onto '$(final)'; " *
                    "post-rename names must be distinct within one mount edge " *
                    "(esm-spec §4.7 / §9.7.7)"
            )
        )
        push!(finals, final)
    end

    root = _to_ordered(doc)::OrderedDict{String, Any}
    _mount_rename_walk!(root, changed)

    # Re-key the registry last, preserving declaration order, and rewrite each
    # ragged/derived `of` parent list (an index-set-name list — unlike a range's
    # `of`, which the walk deliberately leaves alone).
    sets = get(root, "index_sets", nothing)
    if _is_object(sets)
        renamed = OrderedDict{String, Any}()
        for (name, decl) in pairs(sets)
            if _is_object(decl)
                of = get(decl, "of", nothing)
                if _is_array(of)
                    decl["of"] = Any[
                        e isa AbstractString ? get(changed, String(e), e) : e
                            for e in of
                    ]
                end
            end
            final = get(changed, string(name), string(name))
            # A renamed axis may land on the name of an axis this edge does NOT
            # rename — one a mount nested inside the referenced document
            # contributed. Deep equality is idempotent; a disagreement is the
            # §4.7 merge rule's own `subsystem_index_set_conflict`.
            if haskey(renamed, final) && !_index_set_raw_equal(renamed[final], decl)
                throw(
                    ExpressionTemplateError(
                        ERROR_CODES.SUBSYSTEM_INDEX_SET_CONFLICT,
                        "$(where): `index_set_rename` maps index set '$(name)' onto " *
                            "'$(final)', which a mount nested inside the referenced document " *
                            "already contributes with a non-deep-equal declaration (esm-spec §4.7)"
                    )
                )
            end
            renamed[final] = decl
        end
        root["index_sets"] = renamed
    end
    return root
end
