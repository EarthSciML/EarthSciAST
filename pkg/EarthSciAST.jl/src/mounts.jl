# esm-spec §4.7 mounts: the walk of the metaparameters mounted documents
# declare, the data-source `extent` check, mount-edge index-set renaming, and the
# mount pipeline itself (`_MountEdge`, `_MountContext`, `_LeafClose`,
# `_resolve_mount_edge`, the two mount forms, `resolve_subsystem_refs!`). The
# pass order is drawn at the top of resolve.jl.

"""
    _collect_mount_declared_metaparameters(raw, base, src) -> Set{String}

The metaparameter names declared by every document `raw` MOUNTS, at either
§4.7 mount form — a top-level `models.<k>` / `reaction_systems.<k>` `{ref}` and
a `subsystems.<j>` `{ref}` — transitively through the mount DAG.

A §4.7 mount edge CONSUMES the referenced document's `metaparameters` at the
edge (§9.7.6 binding site 3), so those names never reach the mounting
document's own declared set. This walk is what lets the site-4 check (and the
§8.9.4 `extent` check) ask "does ANYONE in this assembly declare that name?"
instead of "does the root". With `follow_imports` it also follows §9.7.2
import edges.

Reads each referenced file through the load's reader `src`, so the mount
pipeline that resolves the same edges later reads nothing twice. A ref that
cannot be read is IGNORED: this walk exists only to WIDEN acceptance, and the
resolution error belongs to the mount pipeline, which reports it with the
proper mount pointer. `seen` (canonical ref identity) cycle-guards the walk.
"""
function _collect_mount_declared_metaparameters(
        raw, base::_RefBase, src::_DocumentSource,
        seen::Set{String} = Set{String}(); follow_imports::Bool = false
    )::Set{String}
    out = Set{String}()
    _is_object(raw) || return out

    function visit_ref!(ref_value)
        _is_object(ref_value) || return
        rv = _raw_get(ref_value, "ref")
        rv isa AbstractString || return
        t = _resolve_ref(base, String(rv))
        t.key in seen && return
        push!(seen, t.key)
        child = try
            _read_document(src, t; copy = false)
        catch e
            # An unreadable or refused document is the mount's diagnostic to
            # raise, not this walk's.
            e isa EarthSciASTError || rethrow()
            return
        end
        _is_object(child) || return
        decls = _raw_get(child, "metaparameters")
        if decls !== nothing && _is_object(decls)
            for (n, _) in pairs(decls)
                push!(out, string(n))
            end
        end
        union!(
            out, _collect_mount_declared_metaparameters(
                child, t.base, src, seen; follow_imports = follow_imports
            )
        )
        return
    end

    # The §9.7.2 import edges one scope carries, when asked for.
    function visit_imports!(holder)
        (follow_imports && _is_object(holder)) || return
        entries = _raw_get(holder, "operator_imports")
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
    for (_, _, comp) in _components(raw)
        visit_ref!(comp)                       # top-level `models.<k>` {ref}
        visit_imports!(comp)
        visit_subsystems!(comp)
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
a folded registry entry makes two IDENTICAL declarations collide; and leaving the contribution unfolded publishes a resolved document whose
axis still carries a metaparameter name, which contradicts "the mounted form is
fully concrete when it splices in" and §9.7.6 site 5's "closed at some enclosing
document's close".

In this binding it does one more job: `IndexSet.size` is `Union{Int,Nothing}`, so
a still-symbolic size cannot survive typed coercion at all; folding a staged
contribution before it is coerced is what lets an assembler-scoped axis cross a
mount.

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
    _document_has_unresolved_mount(raw) -> Bool

Whether `raw` still carries an unresolved §4.7 mount — a top-level
`models.<k>` / `reaction_systems.<k>` `{ref}` or a `subsystems.<k>` `{ref}`.
"""
function _document_has_unresolved_mount(raw)::Bool
    _is_object(raw) || return false
    for (_, _, comp) in _components(raw)
        _raw_haskey(comp, "ref") && return true
        subs = _raw_get(comp, "subsystems")
        (subs !== nothing && _is_object(subs)) || continue
        for (_, sub) in pairs(subs)
            (_is_object(sub) && _raw_haskey(sub, "ref")) && return true
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
re-loads its own resolved document must not be told that document is invalid
(esm-spec §8.9.4 states the exemption).
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
    check_data_source_extents(raw, base, src, mount_declared=nothing)

esm-spec §8.9.4: every `data_sources.<k>.extent.metaparameter` MUST name a
metaparameter THIS document declares, or one a document it MOUNTS declares.

A discovered extent is a §9.7.6 site-4 loader-API binding, and "binding an
unknown name is an error". The condition is decidable from the documents alone,
so it is decided at load, and `validate` refuses it with
`template_import_unknown_name`, the code §9.7.6 gives an unknown name at a
binding site.
"""
function check_data_source_extents(
        raw, base::_RefBase, src::_DocumentSource,
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
            _collect_mount_declared_metaparameters(raw, base, src) : mount_declared
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
                raw, base, src; follow_imports = true
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

    isets = _raw_get(doc, "index_sets", nothing)
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

# ---------------------------------------------------------------------------
# Mount helpers: library refusal, environments, precision, enums, data sources
# ---------------------------------------------------------------------------

"""
    _reject_library_ref(raw_doc, ref, location)

A §4.7 subsystem reference (including a top-level model `{ref}`) MUST NOT
target a library file — the reference mechanisms are disjoint: template
libraries are imported via `expression_template_imports` (esm-spec §9.7.1) and
coupling libraries via a `coupling_import` coupling entry (esm-spec §10.9).
Throws [`ExpressionTemplateError`](@ref) with the stable diagnostic code
(`subsystem_ref_is_template_library` / `subsystem_ref_is_coupling_library`,
esm-spec §9.6.6). `location` — the resolved path, or `nothing` for a remote
URL ref — is appended parenthesized to the message when given.
"""
function _reject_library_ref(
        raw_doc, ref::AbstractString,
        location::Union{AbstractString, Nothing}
    )
    suffix = location === nothing ? "" : " ($(location))"
    if _is_template_library_doc(raw_doc)
        throw(
            ExpressionTemplateError(
                ERROR_CODES.SUBSYSTEM_REF_IS_TEMPLATE_LIBRARY,
                "Subsystem ref '$(ref)' targets a template-library file$(suffix); " *
                    "libraries are imported via expression_template_imports (esm-spec §9.7.1)"
            )
        )
    end
    if _is_coupling_library_doc(raw_doc)
        throw(
            ExpressionTemplateError(
                ERROR_CODES.SUBSYSTEM_REF_IS_COUPLING_LIBRARY,
                "Subsystem ref '$(ref)' targets a coupling-library file$(suffix); " *
                    "libraries are imported via a coupling_import coupling entry (esm-spec §10.9)"
            )
        )
    end
    return nothing
end

"""
    _root_metaparameter_env(raw_data, api_meta) -> Dict{String,Int}

The MOUNTING document's closed metaparameter environment: its own declared
integer `default`s overlaid with the loader-API bindings (esm-spec §9.7.6 sites
5 and 4). Computed on the RAW document, before resolution consumes the
`metaparameters` block.

This is the scope a §4.7 mount edge's binding EXPRESSIONS fold against (e.g.
`NTGT = NX*NY`). It is not what backfills a mounted leaf's own close (see
[`_LeafClose`](@ref)).
"""
function _root_metaparameter_env(
        raw_data,
        api_meta::AbstractDict{String, <:Integer}
    )::Dict{String, Int}
    env = Dict{String, Int}()
    decls = _raw_get(raw_data, "metaparameters", nothing)
    if _is_object(decls)
        for (n, d) in pairs(decls)
            dv = _raw_get(d, "default", nothing)
            (dv isa Integer && !(dv isa Bool)) || continue
            env[string(n)] = Int(dv)
        end
    end
    for (k, v) in api_meta
        env[string(k)] = Int(v)
    end
    return env
end

# esm-spec §4.7 "Working precision crosses a mount". A ROOT that declares no
# `domain.element_type` evaluates in binary64 (§11.3); a MOUNTED document that
# declares none adopts its mounter's.
const _DEFAULT_ELEMENT_TYPE = "Float64"

# The `domain.element_type` a document declares — a raw dict or a typed file —
# or `nothing`.
function _declared_element_type(doc)
    if doc isa EsmFile
        return doc.domain === nothing ? nothing : doc.domain.element_type
    end
    doc isa AbstractDict || return nothing
    d = get(doc, "domain", nothing)
    d isa AbstractDict || return nothing
    et = get(d, "element_type", nothing)
    return et isa AbstractString ? String(et) : nothing
end

"""
    _carry_mounted_element_type!(component, leaf, enclosing, where)

Carry a mounted document's declared working precision `leaf` onto the component
it splices in (esm-spec §4.7 "Working precision crosses a mount"). Nothing is
written for a leaf that declares none (it adopts the mounting document's), nor
when `leaf` equals `enclosing`, the mounting document's EFFECTIVE precision.
Otherwise every variable of the component, and of every subsystem it carries at
any depth, that declares no `element_type` of its own gets `leaf`. A reaction
system's species and parameters have no `element_type`, so a component that is,
or carries, one is refused with `element_type_uncarried`.
"""
function _carry_mounted_element_type!(
        component, leaf, enclosing::AbstractString,
        where::AbstractString
    )
    (leaf === nothing || leaf == enclosing) && return component
    _stamp_element_type!(component, String(leaf), String(enclosing), String(where), "")
    return component
end

function _element_type_uncarried(leaf, enclosing, where, path)
    at = isempty(path) ? "" : " (subsystem '$(path)')"
    return SubsystemRefError(
        "$(where): the mounted document declares `domain.element_type: \"$(leaf)\"` " *
            "but the document mounting it evaluates in $(enclosing), and the component " *
            "carries a reaction system$(at) whose species and parameters cannot declare a " *
            "per-variable `element_type`; the mount cannot keep the leaf's precision " *
            "(esm-spec §4.7 \"Working precision crosses a mount\"). Declare the same " *
            "`domain.element_type` on the mounting document, or remove it from the leaf";
        code = ERROR_CODES.ELEMENT_TYPE_UNCARRIED
    )
end

_sub_path(path, name) = isempty(path) ? String(name) : "$(path).$(name)"

function _stamp_element_type!(sys::AbstractDict, leaf, enclosing, where, path)
    (haskey(sys, "species") || haskey(sys, "reactions")) &&
        throw(_element_type_uncarried(leaf, enclosing, where, path))
    vars = get(sys, "variables", nothing)
    if vars isa AbstractDict
        for (_, d) in vars
            d isa AbstractDict && !haskey(d, "element_type") && (d["element_type"] = leaf)
        end
    end
    subs = get(sys, "subsystems", nothing)
    if subs isa AbstractDict
        for (name, sub) in subs
            _stamp_element_type!(sub, leaf, enclosing, where, _sub_path(path, name))
        end
    end
    return nothing
end

_stamp_element_type!(_, leaf, enclosing, where, path) = nothing

# Lower `target`'s `enum` ops against the `enums` block of `document`, the file
# mounted at this §4.7 edge (esm-spec §9.3), naming the edge in the diagnostic.
function _lower_mounted_enums_at_edge(document, target, mount_noun::AbstractString)
    try
        return _lower_mounted_document_enums(document, target)
    catch e
        e isa EnumLoweringError || rethrow()
        throw(
            ExpressionTemplateError(
                e.code,
                "$(mount_noun): $(e.message) — an `enum` op in a mounted file resolves " *
                    "against that file's own `enums` block (esm-spec §9.3)"
            )
        )
    end
end

"""
    _declared_metaparameter_names(raw) -> Set{String}

The names a raw document's top-level `metaparameters` block declares.
"""
function _declared_metaparameter_names(raw)
    md = _raw_get(raw, "metaparameters", nothing)
    return _is_object(md) ? Set{String}(string(k) for k in keys(md)) : Set{String}()
end

"""
    _bindings_from_above(api_meta, forwarded) -> Dict{String,Int}

What a mounted leaf is handed from above, before its own edge `bindings` (which
win over both): the loader-API bindings `api_meta` (esm-spec §9.7.6 site 4),
overlaid with the edge bindings `forwarded` through an assembly (§4.7
"Bindings reach through an assembly"), which win. The caller filters it to the
names the leaf declares.
"""
function _bindings_from_above(
        api_meta::AbstractDict{String, <:Integer}, forwarded::AbstractDict{String, <:Integer}
    )
    out = Dict{String, Int}(String(k) => Int(v) for (k, v) in api_meta)
    for (k, v) in forwarded
        out[String(k)] = Int(v)
    end
    return out
end

"""
    _forward_through_assembly(forwarded, edge_bindings, leaf_decls, mount_declared) -> Dict

The edge bindings a mounted leaf forwards to its OWN mount edges (esm-spec §4.7
"Bindings reach through an assembly"), kept apart from the loader-API
bindings, which every depth receives unchanged (§9.7.6 site 4):

* each binding forwarded to this leaf from above (`forwarded`) whose name the
  leaf does NOT declare (`leaf_decls`) — one the leaf declares closes it here
  and stops, so a document further down that declares the name again keeps its
  own edge's binding or its default;
* each of this edge's own `edge_bindings` whose name the leaf does not declare
  but a document in its mount tree does (`mount_declared`, read before those
  mounts are inlined), overriding the former. A name nobody declares is not
  forwarded; the leaf's own close refuses it as `template_import_unknown_name`.
"""
function _forward_through_assembly(
        forwarded::AbstractDict{String, <:Integer},
        edge_bindings::AbstractDict{String, <:Integer},
        leaf_decls::AbstractSet{String}, mount_declared::AbstractSet{String}
    )
    out = Dict{String, Int}()
    for (k, v) in forwarded
        String(k) in leaf_decls || (out[String(k)] = Int(v))
    end
    for (k, v) in edge_bindings
        (!(String(k) in leaf_decls) && String(k) in mount_declared) && (out[String(k)] = Int(v))
    end
    return out
end

# esm-spec §4.7 "A mounted document's data sources": which mount edge contributed
# each `data_sources` entry a document received, held on the document only while
# its mounts are being inlined (string values, so every walker passes it by) and
# stripped by `_strip_mount_provenance!` before the document is processed
# further. An entry with no provenance is the document's OWN.
const _MOUNT_PROVENANCE_KEY = "__esm_mounted_data_sources"

_strip_mount_provenance!(doc) = (doc isa AbstractDict && delete!(doc, _MOUNT_PROVENANCE_KEY); doc)

_merge_conflict(name, first_edge, second_edge) = ExpressionTemplateError(
    ERROR_CODES.DATA_SOURCE_MERGE_CONFLICT,
    "data_sources.$(name): two mounts contribute different entries for this " *
        "source — $(first_edge) and $(second_edge) — after `url_substitutions` and " *
        "§8.2.1 resolution, and the mounting document does not declare it itself. " *
        "Neither may silently win; give the sources different names, or declare " *
        "'$(name)' in the mounting document to choose one (esm-spec §4.7 \"A mounted " *
        "document's data sources\")"
)

"""
    _hoist_mounted_sources!(native, comp, edge) -> native

Merge the resolved leaf `comp`'s `data_sources` into the mounting document
`native`, contributed by the mount edge `edge` (esm-spec §4.7 "A mounted
document's data sources"): the mounting document's OWN entry wins; an entry two
mounts contribute merges once when the two are structurally equal and is
`data_source_merge_conflict` otherwise.
"""
function _hoist_mounted_sources!(native::AbstractDict, comp, edge::AbstractString)
    src = get(comp, "data_sources", nothing)
    (src isa AbstractDict && !isempty(src)) || return native
    dst = get!(() -> OrderedDict{String, Any}(), native, "data_sources")
    dst isa AbstractDict || return native
    prov = get!(() -> OrderedDict{String, Any}(), native, _MOUNT_PROVENANCE_KEY)
    for (k, v) in src
        name = String(k)
        if haskey(dst, name)
            haskey(prov, name) || continue          # the document's own entry wins
            # Structurally equal (esm-spec §4.7 "identical": members by name in
            # any order, arrays element-wise, numbers by value; the shared
            # `_json_equal`): a diamond merges once.
            _json_equal(dst[name], v) && continue
            throw(_merge_conflict(name, prov[name], edge))
        end
        dst[name] = v
        prov[name] = String(edge)
    end
    return native
end

"""
    _document_has_subsystem_refs(doc) -> Bool

Whether any `models.<M>` in `doc` mounts a `subsystems.<S>` `{ref}` at any
depth.
"""
function _document_has_subsystem_refs(doc)::Bool
    models = _raw_get(doc, "models", nothing)
    _is_object(models) || return false
    has(m) = begin
        subs = _raw_get(m, "subsystems", nothing)
        _is_object(subs) || return false
        for (_, sub) in pairs(subs)
            _is_object(sub) || continue
            r = _raw_get(sub, "ref", nothing)
            r isa AbstractString && return true
            has(sub) && return true
        end
        false
    end
    for (_, m) in pairs(models)
        _is_object(m) && has(m) && return true
    end
    return false
end


# ---------------------------------------------------------------------------
# The §4.7 mount pipeline: one edge pipeline for both mount forms, for a local
# or a remote leaf, at the root and inside a mounted leaf
# ---------------------------------------------------------------------------

"""
    _MountEdge

One §4.7 mount edge as written: the `ref`, the edge's metaparameter `bindings`
(expressions, folded against the mounting document's environment), its
§9.7.10 `expression_template_imports` injection, its `index_set_rename` and
`url_substitutions`, and, for the top-level form, the `model` /
`reaction_system` selector. Built from a raw stub or from a typed
[`SubsystemRef`](@ref); the pipeline reads these keys nowhere else.
"""
struct _MountEdge
    ref::String
    bindings::Any
    imports::Any
    index_set_rename::Any
    url_substitutions::Any
    selector::Union{Nothing, String}
end

function _MountEdge(entry::AbstractDict, selector_key::Union{Nothing, String} = nothing)
    sel = selector_key === nothing ? nothing : get(entry, selector_key, nothing)
    return _MountEdge(
        String(entry["ref"]), get(entry, "bindings", nothing),
        get(entry, "operator_imports", nothing),
        get(entry, "index_set_rename", nothing), get(entry, "url_substitutions", nothing),
        sel === nothing ? nothing : String(sel)
    )
end

_MountEdge(r::SubsystemRef) = _MountEdge(
    r.ref, isempty(r.bindings) ? nothing : Dict{String, Any}(r.bindings),
    r.expression_template_imports, r.index_set_rename, r.url_substitutions, nothing
)

"""
    _StagedIndexSets

The `index_sets` a document's mounts contribute, held back until that document
has closed its own metaparameters (§9.7.6 site 3, "subsystem refs resolve
post-close"), with the ref of the mount that contributed each.
"""
struct _StagedIndexSets
    decls::OrderedDict{String, Any}
    refs::Dict{String, String}
end
_StagedIndexSets() = _StagedIndexSets(OrderedDict{String, Any}(), Dict{String, String}())

"""
    _MountContext

What the mounts of ONE document share: the load's reader `source`, the
path-scoped cycle `stack` of canonical ref keys (shared by the whole load, so a
cycle crossing the two mount forms is caught), the loader-API bindings
`api_meta` (every depth, §9.7.6 site 4), the edge bindings `forwarded` through
an assembly (§4.7 "Bindings reach through an assembly"), `env`, the mounting
document's closed metaparameter environment that edge binding expressions fold
against, `precision`, its effective working precision (§4.7 "Working precision
crosses a mount"), and `staged`, where its mounts' index sets wait for its close.
"""
struct _MountContext
    source::_DocumentSource
    stack::Vector{String}
    api_meta::Dict{String, Int}
    forwarded::Dict{String, Int}
    env::Dict{String, Int}
    precision::String
    staged::_StagedIndexSets
end

# The context for the mounts of a root document `raw` loaded with the
# loader-API bindings `api_meta`.
function _root_mount_context(raw, api_meta::AbstractDict{String, <:Integer}, source::_DocumentSource)
    return _MountContext(
        source, String[], Dict{String, Int}(String(k) => Int(v) for (k, v) in api_meta),
        Dict{String, Int}(), _root_metaparameter_env(raw, api_meta),
        something(_declared_element_type(raw), _DEFAULT_ELEMENT_TYPE), _StagedIndexSets()
    )
end

"""
    _LeafClose(comp, edge, leaf_base, ctx, mount_noun)

How a mounted leaf `comp` closes at `edge` (§9.7.6 site 3), computed from its
declarations and the mounting context before anything is inlined into it:

* `bindings`, the leaf's close: what reaches it from above (loader-API, then
  forwarded bindings) for the names it DECLARES, then the edge's own bindings,
  which win. The mounting document's own declared defaults (`ctx.env`) never
  backfill: they are its own close, and forwarding them would let an
  assembler's unrelated metaparameter resize a leaf axis the edge never bound.
* `edge_bindings`, the edge's own bindings alone (only they may be forwarded).
* `decls`, the names the leaf declares.
* `env`, the leaf's closed environment (its defaults overlaid with `bindings`),
  which its own edges' binding expressions fold against.
* `fold_env`, what its own mounts' contributions fold against (§4.7 "Which
  environment a contribution folds against"): the enclosing environment
  overlaid with `env` for the names the leaf declares.
* `mount_declared`, the names the documents the leaf mounts declare, read on the
  leaf as authored (§8.9.4 "collect first"); empty when nothing binds the leaf.
"""
struct _LeafClose
    bindings::Dict{String, Int}
    edge_bindings::Dict{String, Int}
    decls::Set{String}
    env::Dict{String, Int}
    fold_env::Dict{String, Int}
    mount_declared::Set{String}
end

function _LeafClose(comp, edge::_MountEdge, leaf_base::_RefBase, ctx::_MountContext, mount_noun::String)
    decls = _declared_metaparameter_names(comp)
    bindings = Dict{String, Int}()
    for (k, v) in _bindings_from_above(ctx.api_meta, ctx.forwarded)
        k in decls && (bindings[k] = v)
    end
    edge_bindings = _fold_edge_bindings(edge.bindings, ctx.env, mount_noun)
    merge!(bindings, edge_bindings)
    mount_declared = isempty(bindings) ? Set{String}() :
        _collect_mount_declared_metaparameters(comp, leaf_base, ctx.source)
    env = _root_metaparameter_env(comp, bindings)
    fold_env = copy(ctx.env)
    for (k, v) in env
        k in decls && (fold_env[k] = v)
    end
    return _LeafClose(bindings, edge_bindings, decls, env, fold_env, mount_declared)
end

# An edge's `bindings`, each a metaparameter expression checked for grammar and
# folded against the mounting document's closed environment `env`.
function _fold_edge_bindings(bindings_raw, env::AbstractDict{String, Int}, mount_noun::String)
    out = Dict{String, Int}()
    bindings_raw === nothing && return out
    bindings_raw isa AbstractDict || throw(
        ExpressionTemplateError(
            ERROR_CODES.METAPARAMETER_TYPE_ERROR,
            "$(mount_noun) `bindings` must be an object of metaparameter " *
                "expressions (esm-spec §9.7.6)"
        )
    )
    for (bk, bv) in pairs(bindings_raw)
        bctx = "$(mount_noun), binding '$(string(bk))'"
        expr = require_meta_expr(_to_native_json(bv), bctx)
        out[string(bk)] = Int(eval_meta_expr(expr, env, bctx))
    end
    return out
end

# The context for the mounts of a leaf that closes as `close`, whose effective
# precision is `precision`.
_child_context(ctx::_MountContext, close::_LeafClose, precision::String) = _MountContext(
    ctx.source, ctx.stack, ctx.api_meta,
    _forward_through_assembly(ctx.forwarded, close.edge_bindings, close.decls, close.mount_declared),
    close.env, precision, _StagedIndexSets()
)

"""
    _resolve_mount_edge(edge, target, base, ctx; mount_noun, file_noun, unreadable)
        -> (comp, leaf_precision)

The esm-spec §4.7 edge pipeline, shared by both mount forms and by every leaf,
local or fetched: the referenced document `target` resolves in its OWN scope,
then this edge's rename and data-source locations apply. `base` is the mounting
document's base, `ctx` its mount context. The caller owns the cycle check and
what the two forms do differently with the result (which component it takes,
where it lands). `unreadable` turns a `_RefUnreadable` into the form's
diagnostic. In order:

1. read the leaf; the authored checks of a `:mounted_leaf`
   ([`_check_authored_document`](@ref)); refuse a library file;
2. close the leaf ([`_LeafClose`](@ref));
3. inline the leaf's own mounts, both forms, into it — before its injection
   and fixpoint, since a `{ref}` resolves "before any other processing" and a
   rule the leaf declares must reach a rewrite-target inside what it mounts;
4. the edge's §9.7.10 injection, the leaf's §9.7 machinery under its close,
   the §9.6.3 fixpoint and full expansion, then its `enum` ops against its own
   `enums` block (§9.3);
5. land what the leaf's own mounts staged, folded against its close;
6. the edge's `index_set_rename` (§4.7 "Mount-edge index-set renaming"), whose
   vocabulary excludes what only the nested mounts contributed;
7. the edge's `url_substitutions`, then the leaf's data-source locations
   against the leaf's own base (§4.7 "A mounted document's data sources").
"""
function _resolve_mount_edge(
        edge::_MountEdge, target::_RefTarget, base::_RefBase, ctx::_MountContext;
        mount_noun::String, file_noun::String, unreadable::Function
    )
    comp = try
        _in_file(() -> _read_document(ctx.source, target), target.key)
    catch e
        e isa _RefUnreadable || rethrow()
        throw(unreadable(e))
    end
    comp isa AbstractDict{String, Any} || throw(
        SubsystemRefError(
            "Referenced $(file_noun) file '$(target.ref)' did not parse as a JSON object";
            code = ERROR_CODES.UNRESOLVED_SUBSYSTEM_REF
        )
    )
    leaf_precision = _declared_element_type(comp)
    # What the leaf itself declares is checked and closed in the
    # leaf's own file; a diagnostic escaping this block names it.
    comp, nested_contributed = _in_file(target.key) do
        _close_mounted_leaf(comp, edge, target, base, ctx, leaf_precision, mount_noun)
    end
    if edge.index_set_rename !== nothing
        comp = apply_mount_index_set_rename(
            comp, edge.index_set_rename, mount_noun; nested_contributed = nested_contributed
        )
    end
    apply_mount_url_substitutions!(comp, edge.url_substitutions, _base_string(base), mount_noun)
    located = _in_file(() -> _resolve_data_source_urls(comp, target.base), target.key)
    located === nothing || (comp["data_sources"] = located["data_sources"])
    return comp, leaf_precision
end

# Steps 1 to 5 of `_resolve_mount_edge`, on the leaf `comp` read from `target`.
# Returns the closed leaf and the index-set names that reached its
# registry only through its own mounts.
function _close_mounted_leaf(
        comp, edge::_MountEdge, target::_RefTarget, base::_RefBase,
        ctx::_MountContext, leaf_precision, mount_noun::String
    )
    _check_authored_document(comp, :mounted_leaf)
    _reject_library_ref(comp, target.ref, _is_remote(target) ? nothing : target.key)

    close = _LeafClose(comp, edge, target.base, ctx, mount_noun)
    child = _child_context(ctx, close, something(leaf_precision, ctx.precision))
    _inline_mounts!(comp, target.base, child)
    # To the mounting document the leaf's whole `data_sources` now comes from
    # this one edge.
    _strip_mount_provenance!(comp)

    # The injected imports are the assembler's, so their relative refs resolve
    # against the MOUNTING document's base, not the leaf's.
    if edge.imports isa AbstractVector && !isempty(edge.imports)
        imports_native = _to_ordered(edge.imports)
        _absolutize_nested_refs!(imports_native, base; pin = ctx.source)
        injected_root = apply_scope_injections(comp, Any[e for e in imports_native])
        injected_root === nothing || (comp = injected_root)
    end
    # `mounted_leaf`: an index-set `size` the leaf cannot close stays symbolic
    # and closes in the registry it merges into (§9.7.6 site 5).
    resolved = _resolve_template_machinery(
        comp, target.base, ctx.source; metaparameters = close.bindings,
        mount_declared = close.mount_declared, mounted_leaf = true
    )
    # The leaf keeps its references: each component keeps its match-less
    # template definitions (closed in the leaf's own file, and already its
    # `match` rules' fixpoint), which the mounting document merges into its
    # own registry by flatten's rule (`_hoist_mounted_templates!`, or flatten's
    # registry merge for a top-level mount).
    comp = _mounted_registries!(lower_expression_templates(resolved === nothing ? comp : resolved))
    comp = _lower_mounted_enums_at_edge(comp, comp, mount_noun)
    comp isa AbstractDict{String, Any} || (comp = _to_ordered(comp))

    nested_contributed = _land_staged_index_sets!(comp, child.staged, close.fold_env, target.ref)
    return comp, nested_contributed
end

# The lowered leaf `comp` with each component's `expression_templates` block
# kept for the mounting document: its match-less entries only (the `match`
# rules have fired in the leaf), and none on a component no reference reads.
function _mounted_registries!(comp)
    _is_object(comp) || return comp
    comp = comp isa OrderedDict{String, Any} ? comp : _to_ordered(comp)
    for (_, _, c) in _components(comp)
        blk = _raw_get(c, "operators")
        _is_object(blk) || continue
        keep = OrderedDict{String, Any}(
            string(n) => d for (n, d) in pairs(blk) if _raw_get(d, "match") === nothing
        )
        used = any(k -> k != "operators" && _has_apply_op(c[k]), collect(keys(c)))
        if isempty(keep) || !used
            delete!(c, "operators")
        else
            c["operators"] = keep
        end
    end
    return comp
end

# A leaf's own mounts have staged their index sets; the leaf has closed, so they
# fold against `fold_env` and merge into its registry. Returns the names that
# reached the registry only through those mounts.
function _land_staged_index_sets!(comp::AbstractDict, staged::_StagedIndexSets, fold_env, ref::String)
    isempty(staged.decls) && return Set{String}()
    registry = get!(() -> OrderedDict{String, Any}(), comp, "index_sets")
    before = Set{String}(String(k) for k in keys(registry))
    folded = OrderedDict{String, Any}(
        String(n) => fold_mount_contribution(d, fold_env) for (n, d) in staged.decls
    )
    _merge_raw_index_sets!(registry, folded, ref)
    return setdiff(Set{String}(String(k) for k in keys(registry)), before)
end

"""
    _merge_raw_index_sets!(registry, decls, ref; refs = nothing) -> registry

Merge a mounted document's `index_sets` declarations `decls`, contributed by
the mount of `ref`, into `registry` (esm-spec §4.7 "Index-set merge"): an
absent name is added, a deep-equal redeclaration is idempotent (`==` on the
post-wire carrier), anything else is `subsystem_index_set_conflict`. `refs`,
when given, records which mount contributed each added name.
"""
function _merge_raw_index_sets!(
        registry::AbstractDict, decls, ref::String;
        refs::Union{Nothing, AbstractDict{String, String}} = nothing
    )
    (decls isa AbstractDict && !isempty(decls)) || return registry
    for (n, decl) in decls
        if haskey(registry, n)
            _index_set_raw_equal(registry[n], decl) || throw(
                ExpressionTemplateError(
                    ERROR_CODES.SUBSYSTEM_INDEX_SET_CONFLICT,
                    _subsystem_index_set_conflict_message(
                        n, ref, _index_set_show(decl), _index_set_show(registry[n])
                    )
                )
            )
        else
            registry[n] = decl
            refs === nothing || (refs[String(n)] = ref)
        end
    end
    return registry
end

# The `subsystem_index_set_conflict` message, for every merge site (esm-spec
# §4.7 requires it to name both contributors, both definitions and the
# `index_set_rename` remedy).
_subsystem_index_set_conflict_message(n, ref, decl_show, existing_show) =
    "index set '$(n)' from subsystem ref '$(ref)' " *
    "($(decl_show)) collides with a non-deep-equal " *
    "declaration already in the importing document's registry " *
    "($(existing_show)) — contributed by the " *
    "document's own `index_sets` or by an earlier mount. A " *
    "referenced subsystem file's top-level index_sets merge into " *
    "the importing document's registry; deep-equal redeclaration " *
    "is idempotent, a size/kind disagreement is a load-time error " *
    "(esm-spec §4.7). If the two are genuinely different axes that " *
    "happen to share a name, rename one at its mount edge with " *
    "`index_set_rename` (esm-spec §4.7 \"Mount-edge index-set " *
    "renaming\"), e.g. {\"ref\": \"$(ref)\", " *
    "\"index_set_rename\": {\"$(n)\": \"$(n)_2\"}}."

# One-line display of an index-set declaration for the conflict message: a
# typed `IndexSet`, or a post-wire declaration.
_index_set_show(s::IndexSet) =
    "kind=$(s.kind)" * (s.size === nothing ? "" : ", size=$(s.size)") *
    (s.members === nothing ? "" : ", members=$(s.members)") *
    (s.of === nothing ? "" : ", of=$(s.of)") *
    (s.from_faq === nothing ? "" : ", from_faq=$(s.from_faq)") *
    (something(s.records, false) ? ", records=true" : "")

function _index_set_show(decl)
    decl isa AbstractDict || return string(decl)
    parts = String[]
    for k in ("kind", "size", "members", "of", "offsets", "values", "from_faq")
        haskey(decl, k) && push!(parts, "$(k)=$(decl[k])")
    end
    return isempty(parts) ? string(decl) : join(parts, ", ")
end

"""
    _inline_mounts!(doc, base, ctx) -> doc

Inline every §4.7 mount of `doc` in place: the top-level `models.<k>` stubs,
then the `reaction_systems.<k>` stubs, then every `subsystems.<k>` `{ref}` at
any depth, each through [`_resolve_mount_edge`](@ref). Their `index_sets` go to
`ctx.staged`; their `data_sources` merge into `doc`.
"""
function _inline_mounts!(doc::AbstractDict{String, Any}, base::_RefBase, ctx::_MountContext)
    for form in _TOPLEVEL_MOUNT_FORMS
        _inline_toplevel_form!(form, doc, base, ctx)
    end
    models = get(doc, "models", nothing)
    if models isa AbstractDict
        for (mname, model) in collect(models)
            model isa AbstractDict && _inline_model_subsystems!(doc, model, String(mname), base, ctx)
        end
    end
    return doc
end

# Whether `doc` has a mount for `_inline_mounts!` to inline.
function _document_has_mount(doc)::Bool
    for form in _TOPLEVEL_MOUNT_FORMS
        block = _raw_get(doc, String(form.block), nothing)
        _is_object(block) || continue
        any(values(block)) do c
            _is_object(c) && _raw_haskey(c, "ref") && !_raw_haskey(c, String(form.body_key))
        end && return true
    end
    return _document_has_subsystem_refs(doc)
end

# Run `f()` with `key` on the mount cycle stack, or throw `cycle()` when it is
# already on the current resolution path. Path-scoped: two sibling edges may
# mount the same file (a diamond).
function _on_mount_stack(f, ctx::_MountContext, key::String, cycle::Function)
    key in ctx.stack && throw(cycle())
    push!(ctx.stack, key)
    try
        return f()
    finally
        pop!(ctx.stack)
    end
end

# The `subsystems.<k>` form's diagnostic for a leaf that cannot be read; a
# leaf that is not JSON is an unresolved mount too.
function _subsystem_unreadable(u::_RefUnreadable)
    t = u.target
    u.reason === :invalid_json && return SubsystemRefError(
        "Failed to resolve subsystem ref '$(t.ref)': $(_unreadable_cause(u))";
        code = ERROR_CODES.UNRESOLVED_SUBSYSTEM_REF, ref = t.ref
    )
    why = u.reason === :not_found ? "file does not exist" :
        _is_remote(t) ? "fetching $(t.key) failed: $(_unreadable_cause(u))" :
        "reading $(t.key) failed: $(_unreadable_cause(u))"
    return SubsystemRefError(
        "Subsystem reference '$(t.ref)' could not be resolved — $(why)";
        code = ERROR_CODES.UNRESOLVED_SUBSYSTEM_REF, ref = t.ref
    )
end

function _inline_model_subsystems!(
        doc::AbstractDict{String, Any}, model::AbstractDict, parent_name::String,
        base::_RefBase, ctx::_MountContext
    )
    subs = get(model, "subsystems", nothing)
    subs isa AbstractDict || return
    for (sub_key, sub) in collect(subs)
        sub isa AbstractDict || continue
        if get(sub, "ref", nothing) isa AbstractString
            subs[sub_key] = _mount_subsystem!(doc, _MountEdge(sub), String(sub_key), parent_name, base, ctx)
        else
            _inline_model_subsystems!(doc, sub, String(sub_key), base, ctx)
        end
    end
    return
end

"""
    _mount_subsystem!(host, edge, sub_name, parent_name, base, ctx) -> model

The `subsystems.<k>` mount form: resolve `edge` and return the leaf's single
model, staging its `index_sets` in `ctx` and merging its `data_sources` into
`host`. A failure that is not a package error is rebranded as an
`unresolved_subsystem_ref` (`_rebrand`); a package error propagates, and every
`SubsystemRefError` carries the mount site so `validate` renders
`/models/<parent>/subsystems/<sub>`.
"""
function _mount_subsystem!(
        host::AbstractDict, edge::_MountEdge, sub_name::String, parent_name::String,
        base::_RefBase, ctx::_MountContext
    )
    target = _resolve_ref(base, edge.ref)
    ref = target.ref
    try
        return _rebrand(
            ERROR_CODES.UNRESOLVED_SUBSYSTEM_REF, "Failed to resolve subsystem ref '$(ref)'";
            as = SubsystemRefError, ref = ref
        ) do
            _on_mount_stack(
                ctx, target.key,
                () -> SubsystemRefError(
                    "Circular subsystem reference detected: $(target.key)";
                    code = ERROR_CODES.UNRESOLVED_SUBSYSTEM_REF
                )
            ) do
                comp, leaf_precision = _resolve_mount_edge(
                    edge, target, base, ctx; mount_noun = "subsystem ref '$(ref)'",
                    file_noun = "model", unreadable = _subsystem_unreadable
                )
                cmodels = get(comp, "models", nothing)
                (cmodels isa AbstractDict && length(cmodels) == 1) || throw(
                    SubsystemRefError(
                        "Subsystem reference '$(ref)' resolves to a file containing multiple " *
                            "top-level systems; exactly one is required";
                        code = ERROR_CODES.AMBIGUOUS_SUBSYSTEM_REF, ref = ref
                    )
                )
                cmodel = first(values(cmodels))
                _carry_mounted_element_type!(cmodel, leaf_precision, ctx.precision, "subsystem ref '$(ref)'")
                _absolutize_nested_refs!(cmodel, target.base)
                _merge_raw_index_sets!(
                    ctx.staged.decls, get(comp, "index_sets", nothing), ref; refs = ctx.staged.refs
                )
                _hoist_mounted_sources!(host, comp, "models.$(parent_name).subsystems.$(sub_name) (ref '$(ref)')")
                cmodel
            end
        end
    catch e
        e isa SubsystemRefError || rethrow()
        throw(_with_mount_site(e, sub_name, parent_name))
    end
end

# The two top-level mount forms (esm-spec §4.7 "Two mount forms, one mechanism"):
# the block a `{ref}` stub sits in, the key whose presence marks an inline
# component rather than a stub, the optional selector naming one component of a
# multi-component leaf, and the nouns its diagnostics use.
struct _TopLevelMountForm
    block::String
    body_key::String
    selector::String
    noun::String
    plural::String
end

# In the order they inline: a document may mount a model AND a reaction system
# by reference, and the reaction-system pass runs on the model pass's output.
const _TOPLEVEL_MOUNT_FORMS = (
    _TopLevelMountForm("models", "variables", "model", "model", "models"),
    _TopLevelMountForm(
        "reaction_systems", "species", "reaction_system", "reaction system",
        "reaction systems"
    ),
)

# The top-level form's diagnostic for a leaf that cannot be read.
function _toplevel_unreadable(u::_RefUnreadable, form::_TopLevelMountForm)
    u.reason === :invalid_json && return u.cause
    t = u.target
    u.reason === :not_found && return SubsystemRefError(
        "Referenced $(form.noun) file not found: $(t.key) (from ref '$(t.ref)')";
        code = ERROR_CODES.UNRESOLVED_SUBSYSTEM_REF
    )
    return SubsystemRefError(
        "Referenced $(form.noun) file could not be " *
            "$(_is_remote(t) ? "fetched" : "read"): $(t.key) (from ref '$(t.ref)'): " *
            _unreadable_cause(u);
        code = ERROR_CODES.UNRESOLVED_SUBSYSTEM_REF
    )
end

"""
    _inline_toplevel_form!(form, doc, base, ctx)

The top-level mount form: each `<form.block>.<k>` `{ref}` stub of `doc` is
replaced by the one component the resolved leaf holds in that block, or the one
the edge's selector names. The leaf's `index_sets` are staged in `ctx`, its
`data_sources` merge into `doc`, and its inline `tests` are dropped (esm-spec
§6.6: they are claims about the leaf under its own standalone conditions and do
not cross a mount edge). A stub whose `ref` is not a string is left for the
schema check.
"""
function _inline_toplevel_form!(
        form::_TopLevelMountForm, doc::AbstractDict{String, Any}, base::_RefBase,
        ctx::_MountContext
    )
    components = get(doc, form.block, nothing)
    components isa AbstractDict || return
    for (name, entry) in collect(components)
        (
            entry isa AbstractDict && get(entry, "ref", nothing) isa AbstractString &&
                !haskey(entry, form.body_key)
        ) || continue
        edge = _MountEdge(entry, form.selector)
        target = _resolve_ref(base, edge.ref)
        ref = target.ref
        mount_noun = "top-level $(form.noun) ref '$(ref)'"
        _on_mount_stack(
            ctx, target.key,
            () -> SubsystemRefError(
                "Circular top-level $(form.noun) reference detected: $(target.key)";
                code = ERROR_CODES.UNRESOLVED_SUBSYSTEM_REF
            )
        ) do
            comp, leaf_precision = _resolve_mount_edge(
                edge, target, base, ctx; mount_noun = mount_noun, file_noun = form.noun,
                unreadable = u -> _toplevel_unreadable(u, form)
            )
            leaf_components = get(comp, form.block, nothing)
            leaf_components isa AbstractDict || throw(
                SubsystemRefError(
                    "Top-level $(form.noun) ref '$(ref)' resolves to a file with no $(form.block) block";
                    code = ERROR_CODES.UNRESOLVED_SUBSYSTEM_REF
                )
            )
            available = join(sort(collect(keys(leaf_components))), ", ")
            sel = edge.selector
            component = if sel !== nothing
                haskey(leaf_components, sel) || throw(
                    SubsystemRefError(
                        "Top-level $(form.noun) ref '$(ref)' has no $(form.noun) '$(sel)' " *
                            "(available: $(available))";
                        code = ERROR_CODES.UNRESOLVED_SUBSYSTEM_REF
                    )
                )
                leaf_components[sel]
            else
                # A top-level mount names its component with a selector, so a
                # leaf of several without one is a ref that does not resolve:
                # `unresolved_subsystem_ref`, as every binding answers
                # (tests/conformance/toplevel_reaction_system_ref/expected.json).
                # `ambiguous_subsystem_ref` is the subsystem edge's code, which
                # has no selector to add.
                length(leaf_components) == 1 || throw(
                    SubsystemRefError(
                        "Top-level $(form.noun) ref '$(ref)' resolves to " *
                            "$(length(leaf_components)) $(form.plural); " *
                            "add a \"$(form.selector)\" selector to choose one " *
                            "(available: $(available))";
                        code = ERROR_CODES.UNRESOLVED_SUBSYSTEM_REF
                    )
                )
                first(values(leaf_components))
            end
            component isa AbstractDict && delete!(component, "tests")
            _carry_mounted_element_type!(component, leaf_precision, ctx.precision, mount_noun)
            _absolutize_nested_refs!(component, target.base)
            components[name] = component
            _merge_raw_index_sets!(
                ctx.staged.decls, get(comp, "index_sets", nothing), ref; refs = ctx.staged.refs
            )
            # `enums` do not travel up: they are file-local (esm-spec §9.3).
            _hoist_mounted_sources!(doc, comp, "$(form.block).$(name) (ref '$(ref)')")
            nothing
        end
    end
    return
end

"""
    _absolutize_nested_refs!(node, base; pin = nothing)

Rewrite every `{"ref": "..."}` under `node` to the canonical key it resolves to
against `base`, so it still resolves once the node is spliced into a document
with a different base. With `pin` (the load's `_DocumentSource`), each local
key is pinned there, so it still names that file when the node is spliced into
a document read over http(s).
"""
function _absolutize_nested_refs!(node, base::_RefBase; pin::Union{Nothing, _DocumentSource} = nothing)
    if node isa AbstractDict
        r = get(node, "ref", nothing)
        if r isa AbstractString
            t = _resolve_ref(base, r)
            node["ref"] = t.key
            (pin === nothing || _is_remote(t)) || push!(pin.pinned, t.key)
        end
        for v in values(node)
            _absolutize_nested_refs!(v, base; pin = pin)
        end
    elseif node isa AbstractVector
        for v in node
            _absolutize_nested_refs!(v, base; pin = pin)
        end
    end
    return
end

"""
    _merge_staged_index_sets!(registry, staged, env) -> registry

Merge what a root's mounts staged into its typed registry once the root has
closed (esm-spec §4.7 "Index-set merge"): each contribution folds against the
root's closed environment `env`, then merges deep-equal-or-
`subsystem_index_set_conflict` against a registry whose own sizes the close has
already folded.
"""
function _merge_staged_index_sets!(
        registry::AbstractDict{String, IndexSet}, staged::_StagedIndexSets,
        env::AbstractDict{String, <:Integer}
    )
    for (n, raw) in pairs(staged.decls)
        decl = coerce_index_set(fold_mount_contribution(raw, env))
        if haskey(registry, n)
            _index_set_deep_equal(registry[n], decl) || throw(
                ExpressionTemplateError(
                    ERROR_CODES.SUBSYSTEM_INDEX_SET_CONFLICT,
                    _subsystem_index_set_conflict_message(
                        n, get(staged.refs, String(n), "a §4.7 mount"),
                        _index_set_show(decl), _index_set_show(registry[n])
                    )
                )
            )
        else
            registry[n] = decl
        end
    end
    return registry
end

# Deep (structural) equality of two typed `IndexSet` declarations. Field-wise:
# the default struct `==` falls back to `===` for the member vectors.
_index_set_deep_equal(a::IndexSet, b::IndexSet) =
    a.kind == b.kind && a.size == b.size && a.members == b.members &&
    a.of == b.of && a.offsets == b.offsets && a.values == b.values &&
    a.from_faq == b.from_faq && a.members_raw == b.members_raw &&
    a.member_factor == b.member_factor &&
    something(a.records, false) == something(b.records, false)

"""
    resolve_subsystem_refs!(file::EsmFile, base_path) -> EsmFile

Resolve, in place, every `subsystems.<k>` `{ref}` left in a typed `file` as a
[`SubsystemRef`](@ref), at any depth, relative to `base_path` (a directory or
an http(s) URL directory). Each runs the same §4.7 edge pipeline a load runs
([`_resolve_mount_edge`](@ref)) and its single model replaces the reference;
the mounted documents' `index_sets` merge into `file.index_sets`. A load
already resolves every mount, so a loaded file comes back unchanged.

**Use the returned file.** A mounted document's `data_sources` merge into the
mounting document (esm-spec §4.7 "A mounted document's data sources"). When
`file` declares a `data_sources` registry they merge into it in place (its own
entry wins) and the return value is `file` itself; when it declares none,
`EsmFile` being immutable, the return value is a rebuilt `EsmFile` carrying
them. Write `file = resolve_subsystem_refs!(file, base_path)`.

Circular references raise a `SubsystemRefError`.
"""
function resolve_subsystem_refs!(file::EsmFile, base_path::AbstractString)
    file.models === nothing && return file
    ctx = _MountContext(
        _DocumentSource(), String[], Dict{String, Int}(), Dict{String, Int}(),
        Dict{String, Int}(), something(_declared_element_type(file), _DEFAULT_ELEMENT_TYPE),
        _StagedIndexSets()
    )
    base = _ref_base(String(base_path))
    own = file.data_sources === nothing ? String[] : collect(keys(file.data_sources))
    host = OrderedDict{String, Any}(
        "data_sources" => OrderedDict{String, Any}(n => nothing for n in own)
    )
    for (name, model) in file.models
        mounted = _resolve_typed_subsystems!(model, String(name), base, ctx, host)
        isempty(mounted) || (file = _merge_typed_mounted_templates!(file, String(name), model, mounted))
    end
    _merge_staged_index_sets!(file.index_sets, ctx.staged, Dict{String, Int}())
    prov = get(host, _MOUNT_PROVENANCE_KEY, nothing)
    prov === nothing && return file
    mounted = Dict{String, DataSource}(
        n => coerce_data_source(host["data_sources"][n]) for n in keys(prov)
    )
    if file.data_sources !== nothing
        merge!(file.data_sources, mounted)
        return file
    end
    return reconstruct(file; data_sources = mounted)
end

# The typed mount path's twin of `_hoist_mounted_templates!`: the mounted
# models' definitions join the top-level model `name`'s registry in
# `file.component_templates` by the same rule (`_merge_mounted_blocks`), the
# model's own references follow its renames, and each mounted model is coerced
# into place.
function _merge_typed_mounted_templates!(file::EsmFile, name::String, model::Model, mounted)
    ct = file.component_templates
    key = "models.$name"
    own = ct === nothing ? nothing : get(ct, key, nothing)
    block, rn = _merge_mounted_blocks(own, name, Tuple{String, Any}[(p, m[3]) for (p, m) in mounted])
    rn === nothing || map_expressions!(e -> _rename_expr_apply_refs(e, rn), model)
    for (_, (parent, sub_name, raw)) in mounted
        delete!(raw, "operators")
        parent.subsystems[sub_name] = coerce_model(raw)
    end
    if ct === nothing
        file = reconstruct(file; component_templates = OrderedDict{String, Any}(key => block))
    else
        ct[key] = block
    end
    return file
end

function _resolve_typed_subsystems!(
        model::Model, name::String, base::_RefBase, ctx::_MountContext, host::AbstractDict,
        mounted::Vector{Tuple{String, Any}} = Tuple{String, Any}[], prefix::String = ""
    )
    for (sub_name, sub) in collect(model.subsystems)
        path = isempty(prefix) ? String(sub_name) : "$prefix.$(sub_name)"
        if sub isa SubsystemRef
            raw = _mount_subsystem!(host, _MountEdge(sub), String(sub_name), name, base, ctx)
            if _is_object(_raw_get(raw, "operators"))
                # Kept references: coerced once its definitions have joined
                # the top-level component's registry (`resolve_subsystem_refs!`).
                push!(mounted, (path, (model, String(sub_name), raw)))
            else
                model.subsystems[sub_name] = coerce_model(raw)
            end
        elseif sub isa Model
            _resolve_typed_subsystems!(sub, String(sub_name), base, ctx, host, mounted, path)
        end
    end
    return mounted
end
