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
4. §9.7.3 registration-time body checking (`_check_template_body_graph`,
   invoked per component from `lower_expression_templates`);
5. the §9.6.3 fixpoint on fully-concrete trees.

Round-trip is Option B (esm-spec §9.6.4, esm 0.9.0): the §9.7 machinery is
CONSUMED here — `expression_template_imports` and `metaparameters` do not
survive `parse → emit` — but the resolved, folded template registries are
retained per component and MATERIALIZED at emit (rule 5), with non-eager
`apply_expression_template` references preserved at their call sites. A pure
template-library file's top-level `expression_templates` snapshot survives
verbatim so a library round-trips to itself.

All diagnostics are raised as [`ExpressionTemplateError`](@ref) with the
stable §9.6.6 codes so they are machine-checkable across bindings.
"""

using OrderedCollections: OrderedDict

const _COMPONENT_KINDS = ("models", "reaction_systems")

# A template-library file MUST NOT declare any of these (esm-spec §9.7.1).
const _LIBRARY_FORBIDDEN_KEYS =
    ("models", "reaction_systems", "data_sources", "coupling", "domain")

# (`_raw_get` / `_raw_haskey` — string-keyed raw-JSON access — and
# `_to_ordered` — the ONE order- and sharing-preserving normalizer every tree
# the import resolver builds goes through — live in src/json_walk.jl with the
# shared traversal combinators.)

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
The rule is the `template_imports` row of [`_VERSION_GATES`](@ref).
"""
reject_template_imports_pre_v08(raw_data) =
    _check_version_gate(_VERSION_GATES.template_imports, raw_data)

# The pointers of the §9.7 constructs in a document, in the order the version
# gate reports them.
function _template_import_offences(raw_data)
    offences = String[]
    _raw_haskey(raw_data, "operators") && push!(offences, "/expression_templates")
    _raw_haskey(raw_data, "metaparameters") && push!(offences, "/metaparameters")
    _raw_haskey(raw_data, "operator_imports") &&
        push!(offences, "/expression_template_imports")
    for (compkind, cname, comp) in _components(raw_data)
        _raw_haskey(comp, "operator_imports") &&
            push!(offences, "/$compkind/$cname/expression_template_imports")
    end
    return offences
end

"""
    _is_template_library_doc(raw) -> Bool

True when `raw` has the template-library-file FORM (top-level
`expression_templates`, esm-spec §9.7.1). Purity (no models / reaction
systems / loaders / coupling / domain) is checked separately at import edges.
"""
_is_template_library_doc(raw) =
    _is_object(raw) && _raw_haskey(raw, "operators")

"""
    _reject_impure_template_library(raw_data)

A document carrying top-level `expression_templates` is a template-library file
(esm-spec §9.7.1), which MUST NOT declare `models`, `reaction_systems`,
`data_sources`, `coupling`, or `domain`. Rewrite rules are component-local
(§9.6.3 constraint 4), so beside a component the block is visible to nothing:
the document is rejected with `template_library_illegal_payload` rather than
loaded with the templates silently inert. An import target is held to the same
rule at the edge, as `template_import_not_library`.
"""
function _reject_impure_template_library(raw_data)
    _is_template_library_doc(raw_data) || return
    present = [k for k in _LIBRARY_FORBIDDEN_KEYS if _raw_haskey(raw_data, k)]
    isempty(present) && return
    throw(
        ExpressionTemplateError(
            ERROR_CODES.TEMPLATE_LIBRARY_ILLEGAL_PAYLOAD,
            "top-level `expression_templates` makes this document a template-library file, which MUST NOT declare " *
                join(("`$k`" for k in present), ", ") *
                " (esm-spec §9.7.1); templates declared there are visible to no component. Declare them in the component's own `expression_templates` block (§9.6.1), or move them to a template-library file and import it with `expression_template_imports` (§9.7.2)"
        )
    )
end

"""
Everything one template-library file exports after resolution in its OWN
scope: its effective template sequence (imports depth-first post-order, then
own declarations; esm-spec §9.7.4), its instantiated `index_sets`, and its
still-open metaparameter declarations (re-exported to the importer,
esm-spec §9.7.6 binding site 2). All three maps are ordered.
"""
mutable struct _TemplateScope
    templates::OrderedDict{String, Any}
    index_sets::OrderedDict{String, Any}
    metaparams::OrderedDict{String, Any}
end

_TemplateScope() = _TemplateScope(
    OrderedDict{String, Any}(),
    OrderedDict{String, Any}(),
    OrderedDict{String, Any}()
)

# ---------------------------------------------------------------------------
# Import-edge renaming / namespacing + free-name rebinding (esm-spec §9.7.7)
# ---------------------------------------------------------------------------

const _NAME_SEGMENT_RE = r"^[A-Za-z_][A-Za-z0-9_]*$"

"""
    _is_valid_dotted_name(s) -> Bool

Grammar for a `prefix` and for `rename`/`rebind` TARGETS (esm-spec §9.7.7):
one or more `[A-Za-z_][A-Za-z0-9_]*` segments joined by single dots — the
§4.6 scoped-reference shape. Keys are never grammar-checked: they must match
whatever the target actually exports (or whatever occurs free).
"""
_is_valid_dotted_name(s::AbstractString) =
    !isempty(s) && all(seg -> occursin(_NAME_SEGMENT_RE, seg), split(s, '.'))

# Throw the import-edge diagnostic `code` with `"<ctx>: <text>"`.
_bad_edge(code::String, ctx::AbstractString, text::AbstractString) =
    throw(ExpressionTemplateError(code, string(ctx, ": ", text)))

const _DOTTED_NAME_RULE =
    "(segments [A-Za-z_][A-Za-z0-9_]* joined by single dots; esm-spec §9.7.7)"

function _name_map(raw, field::String, ctx::String)::OrderedDict{String, String}
    out = OrderedDict{String, String}()
    raw === nothing && return out
    _is_object(raw) || _bad_edge(
        ERROR_CODES.TEMPLATE_IMPORT_RENAME_INVALID, ctx,
        "`$field` must be an object mapping names to names (esm-spec §9.7.7)"
    )
    for (k, v) in pairs(raw)
        ks = string(k)
        isempty(ks) && _bad_edge(
            ERROR_CODES.TEMPLATE_IMPORT_RENAME_INVALID, ctx,
            "`$field` has an empty key (esm-spec §9.7.7)"
        )
        (v isa AbstractString && _is_valid_dotted_name(string(v))) || _bad_edge(
            ERROR_CODES.TEMPLATE_IMPORT_RENAME_INVALID, ctx,
            "`$field`.$ks target $(repr(v)) is not a valid dotted identifier " *
                _DOTTED_NAME_RULE
        )
        out[ks] = string(v)
    end
    return out
end

# Is `v` a join clause's `on` — a list of `[left, right]` key-column pairs
# (esm-spec §4.9.5)? `on` occurs in exactly one place in the schema, a `join`
# clause, and its shape is unambiguous, so the key plus this test is a sound
# positional guard.
_is_join_on_pairs(v) = _is_array(v) && _allof(p -> _is_array(p) && length(p) == 2, v)

"""
    _rename_join_on(v, isetmap, fallback)

Rewrite a join clause's `on` key columns under an index-set rename (esm-spec
§9.7.7 / §4.7 transitivity list).

An `on` name resolves as a LOOP SYMBOL, then the INDEX SET one of the node's
ranges draws `{from}`, then a DATA COLUMN (CONFORMANCE_SPEC §5.5.8). Only the
middle class is an axis occurrence, and a rename map is keyed by axis name, so an
entry follows the rename **iff** it is a key of `isetmap`. Anything else — a loop
symbol, a data-column name — goes through `fallback` (the caller's ordinary
treatment for a bare string here: the §9.7.7 `varmap` fold, or identity at a
mount edge), so this rule only ever ADDS the axis case. The `isetmap` test runs
on the name AS SPELLED, before any fallback, so the two maps cannot chain.
"""
function _rename_join_on(v, isetmap::AbstractDict{String, String}, fallback)
    return Any[
        _is_array(pair) ?
            Any[
                e isa AbstractString ?
                (haskey(isetmap, String(e)) ? isetmap[String(e)] : fallback(String(e))) : e
                for e in pair
            ] : pair
            for pair in v
    ]
end

# (`_RENAME_AXIS_KEYS` / `_RENAME_PROTECTED_KEYS` — the key sets `_rename_walk`
# dispatches on — are derived from the canonical `_STRUCTURAL_FIELDS` table in
# templates/metaparameters.jl; register new structural fields THERE.)

"""
    _rename_walk(x, varmap, isetmap, tplmap)

One transitive-substitution pass over an imported declaration (esm-spec
§9.7.7): `varmap` (renamed open metaparameters + rebound free names) rewrites
bare strings in variable-reference positions; `isetmap` rewrites index-set
reference positions (`{"from": …}` values, the `wrt`/`dim`/`var` axis fields, a
bare-axis-name `integral` `lower`/`upper` bound, and the
`where.*.shape` match-scoping index-set names, in `body` and `match` alike);
`tplmap` rewrites `apply_expression_template.name`. Structural scalar fields
(`_RENAME_PROTECTED_KEYS`) and bound-index lists (range `of`) are never
rewritten. Pure syntactic substitution — no evaluation.

`where` is handled positionally (never by the protected-key copy that
metaparameter substitution uses, esm-spec §9.7.7): a `where` block is a map
{paramName: {shape: [indexSetName, …]}}. Import-edge rename renames templates,
index sets, and metaparameters — NOT template-internal param names — so the
constraint KEYS (param names) are copied verbatim while each constraint's
`shape` list entries are mapped through `isetmap` exactly like a `wrt`/`from`
index-set reference (a name absent from the map stays as spelled, matching the
body-reference rule). Without this the rule body/registry would use the renamed
`meshA.x` while `where` still said `x`, and registration would fail with
`template_constraint_unknown_index_set`.

Deliberately a direct recursion rather than a `_map_json` visitor: nearly
every object key needs sibling-context dispatch (the op-dependent apply
`name`, positional `from`/`of`/`where`, the axis/protected sets), so a
combinator visitor would rebuild every object by hand anyway and the
combinator would only ever handle arrays.
"""
function _rename_walk(
        x, varmap::AbstractDict{String, String},
        isetmap::AbstractDict{String, String},
        tplmap::AbstractDict{String, String}
    )
    if x isa AbstractString
        s = string(x)
        return haskey(varmap, s) ? varmap[s] : x
    elseif _is_array(x)
        return Any[_rename_walk(v, varmap, isetmap, tplmap) for v in x]
    elseif _is_object(x)
        op = _raw_get(x, "op")
        is_apply = op !== nothing && string(op) == APPLY_EXPRESSION_TEMPLATE_OP
        out = OrderedDict{String, Any}()
        for (k, v) in pairs(x)
            ks = string(k)
            if ks == "from" && v isa AbstractString
                out[ks] = get(isetmap, string(v), string(v))
            elseif ks in _RENAME_AXIS_KEYS && v isa AbstractString
                out[ks] = get(isetmap, string(v), string(v))
            elseif ks in _RENAME_BOUND_KEYS && v isa AbstractString &&
                    haskey(isetmap, string(v))
                out[ks] = isetmap[string(v)]
            elseif ks == "name" && is_apply && v isa AbstractString
                out[ks] = get(tplmap, string(v), string(v))
            elseif ks == "where" && _is_object(v)
                out[ks] = _rename_where(v, isetmap)
            elseif ks == "on" && _is_join_on_pairs(v)
                # A join clause's key columns (esm-spec §4.9.5). Only an entry
                # that is a KEY of `isetmap` is an axis occurrence; a loop symbol
                # or a data-column name keeps the varmap fold it had before this
                # rule existed.
                out[ks] = _rename_join_on(v, isetmap, e -> get(varmap, e, e))
            elseif ks in _NAME_KEYED_MAP_KEYS && _is_object(v)
                # A map keyed by author-chosen names (a `ranges` loop symbol, an
                # apply-node `bindings` param): an entry name is a declared name,
                # not a field, so it is never dispatched on (esm-spec §9.7.6
                # map-key rule). A `ranges` entry named `dim` still has its
                # `from` renamed.
                out[ks] = OrderedDict{String, Any}(
                    string(name) => _rename_walk(entry, varmap, isetmap, tplmap)
                        for (name, entry) in pairs(v)
                )
            elseif ks == "of" || ks in _RENAME_PROTECTED_KEYS
                out[ks] = _to_ordered(v)
            else
                out[ks] = _rename_walk(v, varmap, isetmap, tplmap)
            end
        end
        return out
    end
    return x
end

# Rewrite a `where` match-scoping block (esm-spec §9.6.1) under an import-edge
# index-set rename (esm-spec §9.7.7). Constraint KEYS (param names) are copied
# verbatim — rename never touches template-internal param names — and each
# constraint's `shape` list entries (index-set names) are mapped through
# `isetmap`, with any unmapped name left as spelled (the body-reference rule).
function _rename_where(whr, isetmap::AbstractDict{String, String})
    out = OrderedDict{String, Any}()
    for (p, cobj) in pairs(whr)
        if _is_object(cobj)
            cout = OrderedDict{String, Any}()
            for (ck, cv) in pairs(cobj)
                if string(ck) == "shape" && _is_array(cv)
                    cout[string(ck)] = Any[
                        e isa AbstractString ?
                            get(isetmap, string(e), string(e)) : _to_ordered(e) for e in cv
                    ]
                else
                    cout[string(ck)] = _to_ordered(cv)
                end
            end
            out[string(p)] = cout
        else
            out[string(p)] = _to_ordered(cobj)
        end
    end
    return out
end

"""
    _rename_decl(decl, varmap, isetmap, tplmap)

[`_rename_walk`](@ref) over one template declaration with the §9.6.1 shadowing
rule: the template's own `params` shadow like-named entries of `varmap` and
`isetmap` inside its `body`/`match` (a param is the inner binder; renaming
must not capture it). `tplmap` is never shadowed — params do not bind template
names.
"""
function _rename_decl(
        decl, varmap::AbstractDict{String, String},
        isetmap::AbstractDict{String, String},
        tplmap::AbstractDict{String, String}
    )
    pset = Set{String}(_TemplateDecl(decl).params)
    v2, i2 = varmap, isetmap
    if !isempty(pset)
        if any(p -> haskey(varmap, p), pset)
            v2 = OrderedDict{String, String}(k => v for (k, v) in varmap if !(k in pset))
        end
        if any(p -> haskey(isetmap, p), pset)
            i2 = OrderedDict{String, String}(k => v for (k, v) in isetmap if !(k in pset))
        end
    end
    return _rename_walk(decl, v2, i2, tplmap)
end

# Bound index symbols (loop symbols) of a subtree: the `output_idx` entries and
# `ranges` keys of every Expression node, at any nesting depth — the binder
# definition of the `reserved_index_symbol` rule (esm-spec §4.9.1.1), which is
# not limited to `faq`. Rebinding one
# would desynchronize the ranges KEYS (object keys, unreachable by value
# substitution) from their `expr` occurrences, so it is rejected outright; a
# metaparameter spelled like one is `metaparameter_name_conflict`.
function _collect_bound_syms!(out::Set{String}, x)
    _walk_json(x) do _, n
        _is_object(n) || return true
        _raw_get(n, "op") === nothing && return true
        oi = _raw_get(n, "output_idx")
        if oi !== nothing && _is_array(oi)
            for e in oi
                e isa AbstractString && push!(out, string(e))
            end
        end
        rg = _raw_get(n, "ranges")
        if rg !== nothing && _is_object(rg)
            for (k, _) in pairs(rg)
                push!(out, string(k))
            end
        end
        return true
    end
    return out
end

# Every bare string in a variable-reference position of a declaration (the
# positions `varmap` would rewrite), minus the per-template `params` shadow
# set. Used for the rebind occurs-check and the freshness (collision) guard.
function _collect_ref_names!(out::Set{String}, x, shadowed::Set{String})
    _walk_json(x) do key, n
        # Prune exactly the keys `_rename_walk` does not treat as
        # variable-reference positions (see `_STRUCTURAL_FIELDS`).
        if key !== nothing && (
                key == "from" || key in _RENAME_AXIS_KEYS ||
                    key == "of" || key in _RENAME_PROTECTED_KEYS
            )
            return false
        end
        # `_rename_walk`'s name-keyed map rule: an entry name is never pruned.
        if key !== nothing && key in _NAME_KEYED_MAP_KEYS && _is_object(n)
            for (_, entry) in pairs(n)
                _collect_ref_names!(out, entry, shadowed)
            end
            return false
        end
        if n isa AbstractString
            s = string(n)
            s in shadowed || push!(out, s)
        end
        return true
    end
    return out
end

"""
    _ImportEdge(entry, origin)

One `expression_template_imports` entry (esm-spec §9.7.2, §9.7.7), its keys read
once. `ref` is checked here (an entry that is not an object, or has no
non-empty string `ref`, is `template_import_unresolved`); `prefix`, `rename`
and `rebind` are kept as written and checked by [`_edge_name_maps`](@ref), in
the order the edge's steps run. `ctx` is the diagnostic prefix
`"<origin>: import of '<ref>'"`.
"""
struct _ImportEdge
    ref::String
    origin::String
    ctx::String
    bindings::Any
    only::Union{Nothing, Vector{String}}
    prefix::Any
    rename::Any
    rebind::Any
end

function _ImportEdge(entry, origin::String)
    _is_object(entry) || _bad_edge(
        ERROR_CODES.TEMPLATE_IMPORT_UNRESOLVED, origin,
        "expression_template_imports entries must be objects with a `ref` field"
    )
    ref_raw = _raw_get(entry, "ref")
    (ref_raw isa AbstractString && !isempty(string(ref_raw))) || _bad_edge(
        ERROR_CODES.TEMPLATE_IMPORT_UNRESOLVED, origin,
        "expression_template_imports entry requires a non-empty string `ref`"
    )
    ref = string(ref_raw)
    bindings = _raw_get(entry, "bindings")
    only_raw = _raw_get(entry, "only")
    only = (only_raw !== nothing && _is_array(only_raw)) ?
        String[string(n) for n in only_raw] : nothing
    return _ImportEdge(
        ref, origin, "$origin: import of '$ref'",
        (bindings !== nothing && _is_object(bindings)) ? bindings : nothing,
        only, _raw_get(entry, "prefix"), _raw_get(entry, "rename"),
        _raw_get(entry, "rebind")
    )
end

"""
    _edge_name_maps(scope, edge) -> Union{Nothing, NamedTuple}

The final name of every name `scope` exports at `edge` under its `prefix` and
`rename`, per namespace (`tplmap`, `isetmap`, `metamap`), and its `rebind` map;
`nothing` when the edge renames nothing. Checks the three keys' shapes, that
every `rename` key names a surviving export, and that no two names of one
namespace end on the same final name.
"""
function _edge_name_maps(scope::_TemplateScope, edge::_ImportEdge)
    ctx = edge.ctx
    rename = _name_map(edge.rename, "rename", ctx)
    rebind = _name_map(edge.rebind, "rebind", ctx)
    prefix_raw = edge.prefix
    if prefix_raw !== nothing &&
            !(prefix_raw isa AbstractString && _is_valid_dotted_name(string(prefix_raw)))
        _bad_edge(
            ERROR_CODES.TEMPLATE_IMPORT_RENAME_INVALID, ctx,
            "`prefix` $(repr(prefix_raw)) is not a valid dotted identifier $(_DOTTED_NAME_RULE)"
        )
    end
    prefix = _maybe(string, prefix_raw)
    (prefix === nothing && isempty(rename) && isempty(rebind)) && return nothing

    # `rename` keys must name a surviving exported name (typo protection).
    exported = Set{String}()
    union!(exported, keys(scope.templates))
    union!(exported, keys(scope.index_sets))
    union!(exported, keys(scope.metaparams))
    for k in keys(rename)
        k in exported || _bad_edge(
            ERROR_CODES.TEMPLATE_IMPORT_RENAME_UNKNOWN_NAME, ctx,
            "`rename` names '$k', which the target does not export at this " *
                "edge (the surviving exports are templates after `only`, index sets, and " *
                "metaparameters left open by this edge's `bindings`; esm-spec §9.7.7)"
        )
    end

    final(n) = haskey(rename, n) ? rename[n] : (prefix === nothing ? n : "$(prefix).$(n)")
    tplmap = OrderedDict{String, String}(n => final(n) for n in keys(scope.templates))
    isetmap = OrderedDict{String, String}(n => final(n) for n in keys(scope.index_sets))
    metamap = OrderedDict{String, String}(n => final(n) for n in keys(scope.metaparams))

    # Per-namespace final-name uniqueness.
    for (what, m) in (
            ("template", tplmap), ("index set", isetmap),
            ("metaparameter", metamap),
        )
        seen = Dict{String, String}()
        for (o, n) in m
            haskey(seen, n) && _bad_edge(
                ERROR_CODES.TEMPLATE_IMPORT_RENAME_COLLISION, ctx,
                "$what names '$(seen[n])' and '$o' both map to '$n' after " *
                    "renaming (esm-spec §9.7.7)"
            )
            seen[n] = o
        end
    end
    return (; tplmap, isetmap, metamap, rebind, exported)
end

"""
    _check_rebind(scope, maps, ctx)

`rebind` addresses only names that occur free in the surviving declarations,
and no renamed or rebound name may capture a name still in use there (a
remaining free name, a bound index symbol, a template parameter, or another
target) (esm-spec §9.7.7).
"""
function _check_rebind(scope::_TemplateScope, maps, ctx::String)
    free = Set{String}()
    bound = Set{String}()
    params_all = Set{String}()
    for (_, d) in scope.templates
        _collect_bound_syms!(bound, d)
        shadowed = Set{String}(_TemplateDecl(d).params)
        union!(params_all, shadowed)
        _collect_ref_names!(free, d, shadowed)
    end
    for (_, d) in scope.index_sets
        for f in ("offsets", "values")
            v = _raw_get(d, f)
            v isa AbstractString && push!(free, string(v))
        end
    end
    setdiff!(free, keys(scope.metaparams))   # declared names are not free

    for k in keys(maps.rebind)
        k in maps.exported && _bad_edge(
            ERROR_CODES.TEMPLATE_IMPORT_REBIND_UNKNOWN_NAME, ctx,
            "`rebind` names '$k', a declared name of the target (template / " *
                "index set / metaparameter) — `rebind` addresses only free names; use " *
                "`rename` for declared names (esm-spec §9.7.7)"
        )
        k in bound && _bad_edge(
            ERROR_CODES.TEMPLATE_IMPORT_RENAME_INVALID, ctx,
            "`rebind` key '$k' is a bound index symbol (`output_idx` / " *
                "`ranges`) of an imported template, not a free name (esm-spec §9.7.7)"
        )
        k in free || _bad_edge(
            ERROR_CODES.TEMPLATE_IMPORT_REBIND_UNKNOWN_NAME, ctx,
            "`rebind` names '$k', which does not occur free in the imported " *
                "declarations (esm-spec §9.7.7)"
        )
    end

    taken = union(Set{String}(setdiff(free, keys(maps.rebind))), bound, params_all)
    newnames = String[]
    for (o, n) in maps.metamap
        o != n && push!(newnames, n)
    end
    for (o, n) in maps.rebind
        o != n && push!(newnames, n)
    end
    for t in newnames
        t in taken && _bad_edge(
            ERROR_CODES.TEMPLATE_IMPORT_RENAME_COLLISION, ctx,
            "renamed/rebound name '$t' collides with a name still in use " *
                "inside the imported declarations (a remaining free name, a bound index " *
                "symbol, a template param, or another rename/rebind target; esm-spec §9.7.7)"
        )
        push!(taken, t)
    end
    return nothing
end

"""
    _rename_scope!(scope, maps) -> scope

Apply the checked maps to `scope` in one simultaneous substitution (identity
entries dropped): declared names take their final names, and every occurrence
inside the surviving declarations follows (`_rename_decl`, `_rename_walk`, an
index set's `of` list).
"""
function _rename_scope!(scope::_TemplateScope, maps)
    varmap = OrderedDict{String, String}()
    for (o, n) in maps.metamap
        o != n && (varmap[o] = n)
    end
    for (o, n) in maps.rebind
        o != n && (varmap[o] = n)
    end
    iset_changed = OrderedDict{String, String}(o => n for (o, n) in maps.isetmap if o != n)
    tpl_changed = OrderedDict{String, String}(o => n for (o, n) in maps.tplmap if o != n)

    newt = OrderedDict{String, Any}()
    for (n, d) in scope.templates
        newt[maps.tplmap[n]] = _rename_decl(d, varmap, iset_changed, tpl_changed)
    end
    scope.templates = newt

    newi = OrderedDict{String, Any}()
    for (n, d) in scope.index_sets
        nd = _rename_walk(d, varmap, iset_changed, tpl_changed)
        of = _raw_get(nd, "of")
        if of !== nothing && _is_array(of)
            nd["of"] = Any[
                e isa AbstractString ? get(iset_changed, string(e), string(e)) : e
                    for e in of
            ]
        end
        newi[maps.isetmap[n]] = nd
    end
    scope.index_sets = newi

    newm = OrderedDict{String, Any}()
    for (n, d) in scope.metaparams
        newm[maps.metamap[n]] = d
    end
    scope.metaparams = newm
    return scope
end

"""
    _apply_edge_renames!(scope, edge) -> scope

Apply one import edge's `prefix` / `rename` / `rebind` (esm-spec §9.7.7) to
the target's surviving export scope (templates after `only`, all index sets,
metaparameters still open after this edge's `bindings`), transitively through
every occurrence inside the surviving declarations. Runs after `bindings` and
`only`, before the §9.7.4/§9.7.5 merge, so dedup and conflict detection see
the final names.
"""
function _apply_edge_renames!(scope::_TemplateScope, edge::_ImportEdge)
    maps = _edge_name_maps(scope, edge)
    maps === nothing && return scope
    _check_rebind(scope, maps, edge.ctx)
    return _rename_scope!(scope, maps)
end

# ---------------------------------------------------------------------------
# Import-graph resolution (esm-spec §9.7.2 / §9.7.4 / §9.7.5)
# ---------------------------------------------------------------------------

# An index-set declaration with `"records": false` dropped (JSON3 or Dict
# carrier), so it compares equal to the same declaration without `records`.
function _drop_false_records(d)
    d isa AbstractDict || return d
    any(((k, v),) -> String(k) == "records" && v === false, pairs(d)) || return d
    return Dict{String, Any}(String(k) => v for (k, v) in pairs(d) if String(k) != "records")
end

# Raw index-set declarations equal as the §4.7 / §9.7.5 merges judge them:
# deep-equal, with `"records": false` read as an absent `records`.
_index_set_raw_equal(a, b) =
    a == b || _json_equal(_drop_false_records(a), _drop_false_records(b))

function _merge_named!(
        dst::OrderedDict{String, Any}, name::String, decl,
        code::String, what::String, origin::String
    )
    if haskey(dst, name)
        # Deep-equal redeclaration (a diamond import) dedups at first
        # occurrence; a non-equal collision is a conflict (esm-spec §9.7.4/§9.7.5).
        # `_json_equal` is carrier-agnostic, so no pre-normalization is needed.
        _json_equal(dst[name], decl) && return
        # `"records": false` and an absent `records` are one index-set
        # declaration (esm-spec §8.5.1).
        what == "index set" && _index_set_raw_equal(dst[name], decl) && return
        throw(
            ExpressionTemplateError(
                code,
                "$origin: $what '$name' collides with a non-deep-equal existing definition (esm-spec §9.7.4/§9.7.5)"
            )
        )
    end
    dst[name] = decl
    return
end

function _merge_scope!(dst::_TemplateScope, src::_TemplateScope, origin::String)
    for (n, d) in src.templates
        _merge_named!(
            dst.templates, n, d,
            ERROR_CODES.TEMPLATE_IMPORT_NAME_CONFLICT, "template", origin
        )
    end
    for (n, d) in src.index_sets
        _merge_named!(
            dst.index_sets, n, d,
            ERROR_CODES.TEMPLATE_IMPORT_INDEX_SET_CONFLICT, "index set", origin
        )
    end
    for (n, d) in src.metaparams
        _merge_named!(
            dst.metaparams, n, d,
            ERROR_CODES.TEMPLATE_IMPORT_NAME_CONFLICT, "metaparameter", origin
        )
    end
    return
end

"""
    _collect_own_templates(raw, origin) -> OrderedDict{String,Any}

Collect a document/component/library's OWN `expression_templates` block as an
ordered name → declaration map (declaration order is normative for the §9.6.3
tie-break), deep-normalized via `_to_ordered`, and validate the declarations
(`_validate_templates`). Absent or non-object blocks yield an empty map. The
one collect/validate step shared by library resolution, the root-library
phase, and the per-component phase — they differ only in `origin`.
"""
function _collect_own_templates(raw, origin::String)::OrderedDict{String, Any}
    own = OrderedDict{String, Any}()
    tpl = _raw_get(raw, "operators")
    if tpl !== nothing && _is_object(tpl)
        for (n, d) in pairs(tpl)
            own[string(n)] = _to_ordered(d)
        end
    end
    _validate_templates(own, origin)
    return own
end

# Append own template declarations to a scope's template map — imports first,
# then own declarations in declaration order (esm-spec §9.7.4) — with the
# §9.7.4/§9.7.5 dedup/conflict rules.
function _merge_own_templates!(dst::OrderedDict{String, Any}, raw, origin::String)
    for (n, d) in _collect_own_templates(raw, origin)
        _merge_named!(dst, n, d, ERROR_CODES.TEMPLATE_IMPORT_NAME_CONFLICT, "template", origin)
    end
    return dst
end

# Merge a resolved scope's index sets and still-open metaparameter
# declarations into the ROOT document's registries (`resolve_template_machinery`
# phases 1-2; same conflict rules as the scope merge).
function _merge_scope_registries!(
        doc_isets::OrderedDict{String, Any},
        doc_meta::OrderedDict{String, Any},
        scope::_TemplateScope, origin::String
    )
    for (n, d) in scope.index_sets
        _merge_named!(
            doc_isets, n, d, ERROR_CODES.TEMPLATE_IMPORT_INDEX_SET_CONFLICT,
            "index set", origin
        )
    end
    for (n, d) in scope.metaparams
        _merge_named!(
            doc_meta, n, d, ERROR_CODES.TEMPLATE_IMPORT_NAME_CONFLICT,
            "metaparameter", origin
        )
    end
    return
end

"""
    _instantiate_scope!(scope, values, ctx)

Per-edge metaparameter instantiation (esm-spec §9.7.6 binding site 1):
substitute the bound names throughout the exported templates and index sets,
then fold the structural sites that are now closed. A bound VALUE is a
metaparameter expression (usually an integer literal, but possibly a symbolic
`NX*NY` over the importer's still-open metaparameters); `_fold_*` leaves any
site still carrying a free name symbolic for the importer's close.
"""
function _instantiate_scope!(scope::_TemplateScope, values::AbstractDict{String}, ctx::String)
    newt = OrderedDict{String, Any}()
    for (n, d) in scope.templates
        nd = _substitute_metaparams_decl(d, values)
        _fold_structural_sites!(nd, ctx)
        newt[n] = nd
    end
    scope.templates = newt
    newis = OrderedDict{String, Any}()
    for (n, d) in scope.index_sets
        newis[n] = _substitute_metaparams(d, values)
    end
    _fold_index_set_sizes!(newis, ctx; strict = false)
    scope.index_sets = newis
    return
end

"""
    _read_library(src, base, ref, origin) -> (raw, target)

Read the template library an `expression_template_imports` entry's `ref` names
(esm-spec §9.7.2), resolved against the importing document's `base`, through
the load's reader `src`; or through `src.read_library` when the caller supplied
one (the `load_ref` keyword of [`resolve_template_machinery`](@ref)). Returns
the post-wire document and its `_RefTarget`, whose `key` is the cycle identity
and whose `base` anchors the library's own imports. A target that cannot be
read is `template_import_unresolved`.
"""
function _read_library(src::_DocumentSource, base::_RefBase, ref::String, origin::String)
    t = _resolve_ref(src, base, ref)
    if src.read_library !== nothing
        raw, target_dir = src.read_library(ref, _base_string(base), origin)
        return _library_wire_form(raw),
            _RefTarget(t.key, _ref_base(String(target_dir)), t.ref, t.authored)
    end
    return try
        _read_document(src, t), t
    catch e
        e isa _RefUnreadable || rethrow()
        throw(_library_unreadable(e, origin))
    end
end

function _library_unreadable(u::_RefUnreadable, origin::String)
    t = u.target
    msg = if u.reason === :not_found
        "$origin: template-library file not found: $(t.key) (from ref '$(t.authored)')"
    elseif u.reason === :invalid_json
        "$origin: template-library ref '$(t.key)' is not valid JSON: $(u.cause.original_error)"
    elseif _is_remote(t)
        "$origin: failed to download template-library ref '$(t.ref)' " *
            "(resolved to '$(t.key)'): $(_unreadable_cause(u))"
    else
        "$origin: template-library file could not be read: $(t.key) " *
            "(from ref '$(t.authored)'): $(_unreadable_cause(u))"
    end
    return ExpressionTemplateError(ERROR_CODES.TEMPLATE_IMPORT_UNRESOLVED, msg)
end

"""
    _resolve_import_entry(entry, base, stack, origin, src) -> _TemplateScope

Resolve ONE `expression_template_imports` entry (esm-spec §9.7.2): load and
check the target and resolve it in its own scope (`_load_library`), bind this
edge's metaparameters (`_bind_edge!`), filter by `only` (`_filter_only!`), then
apply the edge's `prefix`/`rename`/`rebind` (`_apply_edge_renames!`). `base` is
the importing document's base and `src` the load's reader.
"""
function _resolve_import_entry(
        entry, base::_RefBase, stack::Vector{String},
        origin::String, src::_DocumentSource
    )::_TemplateScope
    edge = _ImportEdge(entry, origin)
    scope = _load_library(edge, base, stack, src)
    _bind_edge!(scope, edge)
    _filter_only!(scope, edge)
    return _apply_edge_renames!(scope, edge)
end

"""
    _load_library(edge, base, stack, src) -> _TemplateScope

Read the library `edge.ref` names (path-scoped cycle detection over canonical
refs, as §4.7), check it as authored and as a pure, schema-valid template
library (§9.7.1), and resolve it in its own scope (`_process_library`). A
diagnostic raised inside the library names its file.
"""
function _load_library(edge::_ImportEdge, base::_RefBase, stack::Vector{String}, src::_DocumentSource)
    origin, ref = edge.origin, edge.ref
    # Keyed on the resolved spelling, so a bundled file has one identity
    # however it is reached (`esm:std/<f>`, or relative inside the bundle).
    canonical = _resolve_ref(src, base, ref).key
    if canonical in stack
        cyc = vcat(stack[findfirst(==(canonical), stack):end], [canonical])
        _bad_edge(
            ERROR_CODES.TEMPLATE_IMPORT_CYCLE, origin,
            "import-graph cycle detected: $(join(cyc, " -> ")) (esm-spec §9.7.2)"
        )
    end

    raw, target = _read_library(src, base, ref, origin)
    _in_file(() -> _check_authored_document(raw, :template_library), target.key)

    # Library purity (esm-spec §9.7.1): a component file and a coupling-library
    # file are not importable as a template library.
    _is_coupling_library_doc(raw) && _bad_edge(
        ERROR_CODES.TEMPLATE_IMPORT_IS_COUPLING_LIBRARY, origin,
        "import target '$ref' is a coupling-library file " *
            "(has `coupling_roles`), not a template library (esm-spec §10.9)"
    )
    _is_template_library_doc(raw) || _bad_edge(
        ERROR_CODES.TEMPLATE_IMPORT_NOT_LIBRARY, origin,
        "import target '$ref' lacks top-level `expression_templates` — " *
            "not a template-library file (esm-spec §9.7.1)"
    )
    for k in _LIBRARY_FORBIDDEN_KEYS
        _raw_haskey(raw, k) && _bad_edge(
            ERROR_CODES.TEMPLATE_IMPORT_NOT_LIBRARY, origin,
            "import target '$ref' declares `$k` — not a pure template-library file (esm-spec §9.7.1)"
        )
    end
    schema_errors = validate_schema(raw)
    isempty(schema_errors) || _bad_edge(
        ERROR_CODES.TEMPLATE_IMPORT_UNRESOLVED, origin,
        "import target '$ref' failed schema validation: " *
            "$(schema_errors[1].path): $(schema_errors[1].message)"
    )

    push!(stack, canonical)
    try
        return _in_file(target.key) do
            _process_library(raw, target.base, stack, "$origin -> $ref", src)
        end
    finally
        pop!(stack)
    end
end

"""
    _bind_edge!(scope, edge) -> scope

The edge's metaparameter `bindings` (esm-spec §9.7.6 binding site 1). A value
may be an expression over the importer's metaparameters (`NX*NY`); those are
not closed yet at an import edge (innermost-first), so it is carried
symbolically into the target and folds when the importer closes. A bound name
leaves the scope's open metaparameters.
"""
function _bind_edge!(scope::_TemplateScope, edge::_ImportEdge)
    edge.bindings === nothing && return scope
    origin, ref = edge.origin, edge.ref
    values = Dict{String, Any}()
    for (k, v) in pairs(edge.bindings)
        name = string(k)
        haskey(scope.metaparams, name) || _bad_edge(
            ERROR_CODES.TEMPLATE_IMPORT_UNKNOWN_NAME, origin,
            "import of '$ref' binds metaparameter '$name', which the " *
                "target neither declares nor re-exports (esm-spec §9.7.6)"
        )
        values[name] = require_meta_expr(
            _to_ordered(v),
            "$origin: import of '$ref', binding '$name'"
        )
    end
    isempty(values) && return scope
    _instantiate_scope!(scope, values, "$origin -> $ref")
    for name in keys(values)
        delete!(scope.metaparams, name)
    end
    return scope
end

"""
    _filter_only!(scope, edge) -> scope

`only` visibility filtering (esm-spec §9.7.2), after the target's own wiring
resolved in its own scope. The kept templates' bodies may reference other
templates of the target (a boundary rule calling an interior stencil); bodies
are not inlined (§9.7.3), so those travel along as the reference closure, or
the references would dangle (§9.6.4 rule 5).
"""
function _filter_only!(scope::_TemplateScope, edge::_ImportEdge)
    keep = edge.only
    keep === nothing && return scope
    for n in keep
        haskey(scope.templates, n) || _bad_edge(
            ERROR_CODES.TEMPLATE_IMPORT_UNKNOWN_NAME, edge.origin,
            "`only` names template '$n', which '$(edge.ref)' does not declare (esm-spec §9.7.2)"
        )
    end
    kept = _reachable(_template_graph(scope.templates), keep)
    filtered = OrderedDict{String, Any}()
    for (n, d) in scope.templates
        n in kept && (filtered[n] = d)
    end
    scope.templates = filtered
    return scope
end

"""
    _process_library(raw, base, stack, origin, src) -> _TemplateScope

Resolve a template-library document in its OWN scope: its imports
(depth-first post-order), then its own templates / index sets /
metaparameters appended in declaration order (esm-spec §9.7.4), then §9.7.3
body composition — so a BC-layer body reference to an imported interior
stencil closes here, before any `only` filtering by a downstream importer.
"""
function _process_library(
        raw, base::_RefBase, stack::Vector{String},
        origin::String, src::_DocumentSource
    )::_TemplateScope
    scope = _TemplateScope()
    imports = _raw_get(raw, "operator_imports")
    if imports !== nothing && _is_array(imports)
        for entry in imports
            sub = _resolve_import_entry(entry, base, stack, origin, src)
            _merge_scope!(scope, sub, origin)
        end
    end

    own = _collect_own_templates(raw, origin)
    for (n, d) in own
        own[n] = _lower_library_template_enums(raw, n, d, origin)
    end
    for (n, d) in own
        _merge_named!(
            scope.templates, n, d, ERROR_CODES.TEMPLATE_IMPORT_NAME_CONFLICT,
            "template", origin
        )
    end

    isets = _raw_get(raw, "index_sets")
    if isets !== nothing && _is_object(isets)
        for (n, d) in pairs(isets)
            _merge_named!(
                scope.index_sets, string(n), _to_ordered(d),
                ERROR_CODES.TEMPLATE_IMPORT_INDEX_SET_CONFLICT, "index set", origin
            )
        end
    end

    for (n, d) in _collect_metaparam_decls(raw, origin)
        _merge_named!(
            scope.metaparams, n, d, ERROR_CODES.TEMPLATE_IMPORT_NAME_CONFLICT,
            "metaparameter", origin
        )
    end

    # §9.7.3 body-reference DAG validation in the library's own scope.
    _check_template_body_graph(scope.templates, origin)
    _expand_library_enum_calls!(scope.templates, raw, collect(String, keys(own)), origin)
    # In the library's own scope, before an importing edge's `bindings`
    # instantiate the templates and consume the names it closes.
    _check_metaparam_loop_symbols(keys(scope.metaparams), origin, scope.templates)
    return scope
end

# Resolve the `enum` symbols a template library binds in its OWN calls
# (esm-spec §9.3, §9.7.5). After `_lower_library_template_enums`, the only
# `enum` ops left in the library's scope are spelled with a template parameter.
# A call that binds such a parameter to a symbol is an instance (esm-spec §9.6.4
# rule 3: the instance includes the symbols the call binds): the called
# template's body is lowered against the library's block for that instance,
# without expanding the call, and the call is re-pointed to the lowered body,
# registered as `<name>.variant<k>`. The authored template keeps its body: the
# importer may still call it with a symbol of its own, which resolves at the
# importer's call site. Instances follow the reference DAG (a call that forwards
# a bound symbol into another call lowers that one too). An op the lowering
# leaves spelled with the calling template's own parameter stays open for the
# importer's binding. Runs after `_check_template_body_graph`, so the reference
# DAG is acyclic.
function _expand_library_enum_calls!(
        named, library, own_names::Vector{String},
        origin::String
    )
    graph = _template_graph(named)
    bearing = _transitive_op_flags(named, op -> op == "enum"; graph = graph)
    # (template, bound symbols) => (lowered body, the instance key of each
    # re-pointed reference in it); bodies are computed children first.
    insts = OrderedDict{Tuple{String, String}, Tuple{Any, IdDict{Any, Tuple{String, String}}}}()
    # The symbols a reference `n` binds to the parameters of its template, as
    # literals or through `lits` (the enclosing instance's symbols).
    function bound_symbols(n, caller_params, lits)
        nm = _raw_get(n, "name")
        (nm isa AbstractString && get(bearing, String(nm), false)) || return nothing
        b = _raw_get(n, "bindings")
        _is_object(b) || return nothing
        syms = Dict{String, String}()
        for (k, v) in pairs(b)
            v isa AbstractString || continue
            if String(v) in caller_params
                haskey(lits, String(v)) && (syms[string(k)] = lits[String(v)])
            else
                syms[string(k)] = String(v)
            end
        end
        isempty(syms) && return nothing
        return (String(nm), syms)
    end
    function repoint(body, caller_params, lits)
        refs = IdDict{Any, Tuple{String, String}}()
        out = _rewrite_json(body; leaves = false) do rw, n
            _is_apply_node(n) || return _JSON_DESCEND
            nn = _rewrite_json_children(rw, n; keep = "name")
            bs = bound_symbols(n, caller_params, lits)
            bs === nothing && return nn
            key = instance(bs[1], bs[2])
            key === nothing && return nn
            nn = nn === n ? OrderedDict{String, Any}(string(k) => v for (k, v) in pairs(n)) : nn
            refs[nn] = key
            return nn
        end
        return out, refs
    end
    function instance(name::String, syms::Dict{String, String})
        decl = named[name]
        params = _TemplateDecl(decl).params
        lits = Dict{String, String}(p => syms[p] for p in params if haskey(syms, p))
        key = (name, _canonical_compact(Dict{String, Any}(lits)))
        haskey(insts, key) && return key
        body = _raw_get(decl, "body")
        # The bound symbols, written into the `enum` ops that spell them.
        subst = _rewrite_json(body; leaves = false) do _, n
            _raw_get(n, "op") == "enum" || return _JSON_DESCEND
            args = _raw_get(n, "args")
            (args !== nothing && _is_array(args)) || return n
            na = Any[(a isa AbstractString && haskey(lits, String(a))) ? lits[String(a)] : a for a in args]
            na == collect(args) && return n
            n2 = OrderedDict{String, Any}(string(k) => v for (k, v) in pairs(n))
            n2["args"] = na
            return n2
        end
        open_decl = OrderedDict{String, Any}(
            "params" => String[p for p in params if !haskey(lits, p)], "body" => subst
        )
        lowered = _lower_library_template_body(library, name, open_decl, subst, origin)
        lowered, refs = repoint(lowered, Set{String}(params), lits)
        insts[key] = (lowered, refs)
        return key
    end
    own_refs = OrderedDict{String, Tuple{Any, IdDict{Any, Tuple{String, String}}}}()
    for n in own_names
        decl = get(named, n, nothing)
        (decl !== nothing && _is_object(decl) && _raw_haskey(decl, "body")) || continue
        any(r -> get(bearing, r, false), graph.refs[n]) || continue
        own_refs[n] = repoint(_raw_get(decl, "body"), Set{String}(_TemplateDecl(decl).params), Dict{String, String}())
    end
    isempty(insts) && return named
    # Name the instances children first: a template after every template its
    # instances' bodies reference; each distinct lowered body of a template is
    # `<name>.variant<k>`, k in the order of the bodies' canonical bytes.
    final = Dict{Tuple{String, String}, String}()
    rename(body, refs) = _rewrite_json(body; leaves = false) do rw, n
        _is_apply_node(n) || return _JSON_DESCEND
        nn = _rewrite_json_children(rw, n; keep = "name")
        key = get(refs, n, nothing)
        key === nothing && return nn
        out = OrderedDict{String, Any}(string(k) => v for (k, v) in pairs(nn))
        out["name"] = final[key]
        return out
    end
    by_name = OrderedDict{String, Vector{Tuple{String, String}}}()
    for key in keys(insts)
        push!(get!(by_name, key[1], Tuple{String, String}[]), key)
    end
    done = Set{String}()
    function name_template(t)
        t in done && return
        push!(done, t)
        for key in by_name[t], (_, ck) in insts[key][2]
            name_template(ck[1])
        end
        bodies = Any[rename(insts[k]...) for k in by_name[t]]
        canon = String[_canonical_compact(b) for b in bodies]
        distinct = sort!(unique(canon))
        names = Dict{String, String}()
        for (i, c) in enumerate(distinct)
            vn = "$t.variant$i"
            while haskey(named, vn)
                vn *= "_"
            end
            nd = OrderedDict{String, Any}(string(k) => v for (k, v) in pairs(named[t]))
            nd["body"] = bodies[findfirst(==(c), canon)]
            named[vn] = nd
            names[c] = vn
        end
        for (k, c) in zip(by_name[t], canon)
            final[k] = names[c]
        end
        return
    end
    for t in keys(by_name)
        name_template(t)
    end
    for (n, (body, refs)) in own_refs
        decl = OrderedDict{String, Any}(string(k) => v for (k, v) in pairs(named[n]))
        decl["body"] = rename(body, refs)
        named[n] = decl
    end
    return named
end

# Lower the `enum` ops in one of a template library's OWN template bodies
# against the library's `enums` block (esm-spec §9.3), before the template
# reaches an importer whose block is a different one. An op spelled with one of
# the template's `params` stays open and resolves at the call site.
function _lower_library_template_enums(library, name::String, decl, origin::String)
    (_is_object(decl) && _raw_haskey(decl, "body")) || return decl
    decl["body"] = _lower_library_template_body(
        library, name, decl,
        _raw_get(decl, "body"), origin
    )
    return decl
end

# `body`, a body of the library's template `name` (`decl`), with its `enum` ops
# lowered against the library's `enums` block. An op spelled with one of
# `decl`'s `params` stays open.
function _lower_library_template_body(library, name::String, decl, body, origin::String)
    params = Set{String}(_TemplateDecl(decl).params)
    try
        return _lower_enum_ops_for_file(library, body, params)
    catch e
        e isa EnumLoweringError || rethrow()
        throw(
            ExpressionTemplateError(
                e.code,
                "$origin: template '$name': $(e.message) — an `enum` op in a template " *
                    "library resolves against that library's own `enums` block (esm-spec §9.3)"
            )
        )
    end
end

# ---------------------------------------------------------------------------
# Root-document resolution (the load-time entry point)
# ---------------------------------------------------------------------------

function _has_import_machinery(raw)
    _is_object(raw) || return false
    (
        _raw_haskey(raw, "operators") ||
            _raw_haskey(raw, "metaparameters") ||
            _raw_haskey(raw, "operator_imports")
    ) && return true
    for (_, _, comp) in _components(raw)
        _raw_haskey(comp, "operator_imports") && return true
    end
    return false
end

# --- phase 1: top-level templates + imports (root template-library file) ---
# Resolve the root's own imports into a top scope, merge its own templates
# (§9.7.4 order), and land the scope's index sets / open metaparameters in the
# document registries. Returns the effective top-level template map.
function _resolve_root_templates!(
        root::OrderedDict{String, Any}, base::_RefBase,
        stack::Vector{String},
        doc_isets::OrderedDict{String, Any},
        doc_meta::OrderedDict{String, Any}, src::_DocumentSource
    )::OrderedDict{String, Any}
    topscope = _TemplateScope()
    imports = get(root, "operator_imports", nothing)
    if imports !== nothing && _is_array(imports)
        for entry in imports
            sub = _resolve_import_entry(entry, base, stack, "document", src)
            _merge_scope!(topscope, sub, "document")
        end
    end
    _merge_own_templates!(topscope.templates, root, "document")
    _merge_scope_registries!(doc_isets, doc_meta, topscope, "document")
    return topscope.templates
end

# --- phase 2: per-component imports (models / reaction systems, §9.7.2) ---
# Each component carrying `expression_template_imports` gets its effective
# template sequence (imports depth-first post-order, then local declarations)
# as its own template block; scope index sets / open metaparameters merge into
# the document registries.
function _resolve_component_imports!(
        root::OrderedDict{String, Any}, base::_RefBase,
        stack::Vector{String},
        doc_isets::OrderedDict{String, Any},
        doc_meta::OrderedDict{String, Any}, src::_DocumentSource
    )
    for (compkind, cname, comp) in _components(root)
        imports = get(comp, "operator_imports", nothing)
        imports === nothing && continue
        cscope = _TemplateScope()
        corigin = "$compkind.$cname"
        if _is_array(imports)
            for entry in imports
                sub = _resolve_import_entry(entry, base, stack, corigin, src)
                _merge_scope!(cscope, sub, corigin)
            end
        end
        _merge_own_templates!(cscope.templates, comp, corigin)
        _merge_scope_registries!(doc_isets, doc_meta, cscope, corigin)
        # The effective sequence (imports depth-first post-order, then
        # local declarations) becomes the component's template block; the
        # OrderedDict key order IS the §9.6.3 declaration order.
        comp["operators"] = cscope.templates
        delete!(comp, "operator_imports")
    end
    return
end

"""
    resolve_template_machinery(raw_data, base_path;
                               metaparameters=Dict{String,Int}(), load_ref=nothing,
                               mount_declared=nothing, mounted_leaf=false)

Resolve every esm-spec §9.7 construct of the ROOT document `raw_data`
(relative import refs resolve against `base_path`): imports recursively with
per-edge instantiation, `index_sets` merge, metaparameter close
(`metaparameters` is the loader-API binding site 4; already-closed edge
bindings win, then API bindings, then defaults) and fold, expression-position
substitution, and — for a root library file — §9.7.3 body composition.

`load_ref` is an optional reader of raw library documents
`(ref, base_dir, origin) -> (raw_doc, target_base_dir)` for the import edges,
mirroring [`expand_coupling_imports`](@ref)'s keyword; `nothing` (the default)
reads files and http(s) URLs. What it returns passes the same op-spelling
boundary as a file read.

Returns an order-preserving native tree ready for
[`lower_expression_templates`](@ref) with `expression_template_imports`
consumed — that IS an import edge — and the top-level `expression_templates` /
`metaparameters` DECLARATIONS restored VERBATIM from a pre-folding snapshot
(esm-spec §9.6.4 rule 5: Option A expands call sites, it does not delete
declarations; a template-library file MUST round-trip to itself). `nothing`
when the document carries no §9.7 machinery (the fast path).

`mount_declared` widens the §9.7.6 site-4 check to the names declared by the
documents this one mounts — see
[`_collect_mount_declared_metaparameters`](@ref). `mounted_leaf` says this call
IS a §4.7 mount edge, so an index-set `size` this scope cannot close stays
symbolic for the MOUNTING registry to close (§9.7.6 site 5).
"""
function resolve_template_machinery(
        raw_data, base_path::AbstractString;
        metaparameters::AbstractDict{String, <:Integer} = Dict{String, Int}(),
        load_ref = nothing,
        mount_declared::Union{Nothing, AbstractSet{String}} = nothing,
        mounted_leaf::Bool = false
    )
    return _resolve_template_machinery(
        raw_data, _ref_base(base_path), _DocumentSource(read_library = load_ref);
        metaparameters = metaparameters, mount_declared = mount_declared,
        mounted_leaf = mounted_leaf
    )
end

# [`resolve_template_machinery`](@ref) on a typed base, reading every import
# through the load's reader `src`.
function _resolve_template_machinery(
        raw_data, base::_RefBase, src::_DocumentSource;
        metaparameters::AbstractDict{String, <:Integer} = Dict{String, Int}(),
        mount_declared::Union{Nothing, AbstractSet{String}} = nothing,
        mounted_leaf::Bool = false
    )
    mounted = mount_declared === nothing ? Set{String}() : mount_declared
    if !_has_import_machinery(raw_data)
        # A binding naming something a MOUNTED document declares is meaningful
        # even here: this document has no §9.7 machinery of its own, and the
        # mount edge forwards the name into the leaf's close. Only a name NO
        # document in the assembly declares is the typo this refuses.
        unknown = sort(
            collect(
                String[
                    string(k) for k in keys(metaparameters)
                        if !(string(k) in mounted)
                ]
            )
        )
        isempty(unknown) || throw(
            ExpressionTemplateError(
                ERROR_CODES.TEMPLATE_IMPORT_UNKNOWN_NAME,
                "loader API binds metaparameter(s) $(join(unknown, ", ")) which neither " *
                    "this document nor any document it mounts declares (esm-spec §9.7.6)"
            )
        )
        # A ROOT document has no enclosing scope to close an axis it cannot
        # size, so a `size` naming a metaparameter nothing declares is
        # `metaparameter_unbound` here too (esm-spec §4.7, §9.7.6) rather than a
        # raw conversion failure in the typed coercion. A mounted leaf's stays
        # symbolic for the mounting registry to close.
        if !mounted_leaf && _has_open_index_set_size(raw_data)
            root = _to_ordered(raw_data)::OrderedDict{String, Any}
            _fold_index_set_sizes!(root["index_sets"], "document"; strict = true)
            return root
        end
        return nothing
    end
    root = _to_ordered(raw_data)::OrderedDict{String, Any}
    stack = String[]

    # Snapshot the §9.7.1 DECLARATIONS exactly as authored, BEFORE any phase
    # below composes a body, folds a metaparameter, or otherwise mutates the
    # working copies. Restored verbatim in phase 7 (esm-spec §9.6.4 rule 5 — the
    # rationale is there). `deepcopy` because the folding phases rewrite these
    # sub-trees IN PLACE: an aliased "snapshot" would emit the folded form.
    orig_templates = haskey(root, "operators") ?
        deepcopy(root["operators"]) : nothing
    orig_metaparams = haskey(root, "metaparameters") ?
        deepcopy(root["metaparameters"]) : nothing

    doc_meta = _collect_metaparam_decls(root, "document")
    doc_isets = OrderedDict{String, Any}()
    if haskey(root, "index_sets") && _is_object(root["index_sets"])
        for (n, d) in pairs(root["index_sets"])
            doc_isets[string(n)] = d
        end
    end

    is_library = haskey(root, "operators")
    top_templates = is_library ?
        _resolve_root_templates!(
            root, base, stack, doc_isets, doc_meta, src
        ) :
        OrderedDict{String, Any}()
    _resolve_component_imports!(
        root, base, stack, doc_isets, doc_meta, src
    )
    values = _close_document_metaparams(doc_meta, metaparameters, mounted)
    _check_metaparam_name_conflicts(root, top_templates, doc_meta, doc_isets)
    doc_isets = _substitute_closed_metaparams!(root, top_templates, doc_isets, values)
    # `mounted_leaf` says a MOUNTING document's registry will receive these
    # index sets and close them (§4.7 "Index-set merge"), so an axis this scope
    # cannot size stays symbolic instead of being `metaparameter_unbound` here,
    # whether or not the leaf imports anything (§4.7: "a component's shape is not
    # allowed to stop resolving because a shared expression was factored into a
    # library it imports and never calls").
    _fold_closed_document!(root, top_templates, doc_isets; strict = !mounted_leaf)

    # --- phase 7: root library file — check the body graph, consume the
    #     import EDGE, restore the DECLARATIONS verbatim ---
    #
    # esm-spec §9.6.4 rule 5: Option A expands call sites, it does not delete
    # declarations. `expression_template_imports` is an import edge, consumed
    # here, and does not survive `parse → emit`. A top-level
    # `expression_templates` registry and a top-level `metaparameters` block
    # (§9.7.1) are declarations: both survive `parse → emit` verbatim, so a
    # template library round-trips to itself (§9.7.6 "Ordering within load"),
    # in the resolved document as in the `EsmFile`.
    #
    # The authored snapshots are restored, not the working copies, whose bodies
    # are composed and metaparameters substituted; they are the same blocks the
    # `EsmFile` carries. Assignment keeps each block in its authored key
    # position.
    if is_library
        _check_template_body_graph(top_templates, "document")
    end
    delete!(root, "operator_imports")
    if orig_templates === nothing
        delete!(root, "operators")
    else
        root["operators"] = orig_templates
    end
    if orig_metaparams === nothing
        delete!(root, "metaparameters")
    else
        root["metaparameters"] = orig_metaparams
    end
    isempty(doc_isets) || (root["index_sets"] = doc_isets)
    return root
end

# ===================================================================
# Scope-directed template injection (esm-spec §9.7.10)
#
# The consuming surface — a §4.7 subsystem-ref edge (form A), a §10 coupling
# entry (form B), or a §6.6/§6.7 test/analysis (form C) — may register imports
# into a TARGET component's own scope without editing the leaf. Forms A/B are
# applied here, at the raw-data level, BEFORE `resolve_template_machinery`: each
# widens the target component's `expression_template_imports` in the §9.7.10
# merge order, so the ordinary import resolver + §9.6.3 fixpoint lower the
# target's rewrite-targets with no engine change. Form C is applied by the PDE
# test runner (`inline_tests.jl`) in a per-test ephemeral build.
# ===================================================================

"""
    _has_scope_injection(raw, injected) -> Bool

True iff a scope-directed injection (esm-spec §9.7.10) must be applied to
`raw` before template resolution: a non-empty subsystem-ref edge list
`injected` (form A), or any `coupling` entry carrying an
`expression_template_imports` map (form B).
"""
function _has_scope_injection(raw, injected)::Bool
    injected !== nothing && !isempty(injected) && return true
    _is_object(raw) || return false
    coupling = _raw_get(raw, "coupling")
    coupling isa AbstractVector || return false
    for entry in coupling
        _is_object(entry) && _raw_haskey(entry, "operator_imports") && return true
    end
    return false
end

# Append raw §9.7.2 import entries to a component's own
# `expression_template_imports` (esm-spec §9.7.10 merge order: the target's own
# imports first, then the injected list). `comp` is a mutable native tree.
function _append_component_imports!(comp::AbstractDict, imports)
    existing = get(comp, "operator_imports", nothing)
    base = existing === nothing ? Any[] : Any[e for e in existing]
    for e in imports
        push!(base, _to_ordered(e))
    end
    comp["operator_imports"] = base
    return comp
end

"""
    _apply_subsystem_ref_injection!(root, injected)

esm-spec §9.7.10 form A: append the subsystem-ref edge's injected §9.7.2 import
entries to the single top-level component's own `expression_template_imports`,
so the referenced document is lowered under the assembler-chosen discretization.
`root` is a mutable native tree; a referenced subsystem file holds exactly one
top-level model or reaction system (§4.7), which is the implicit target. A
data-loader-only referenced file has no expression positions, so the injection
finds no home and the mount fails cleanly downstream.
"""
function _apply_subsystem_ref_injection!(root::AbstractDict, injected)
    (injected === nothing || isempty(injected)) && return root
    for compkind in _COMPONENT_KINDS
        comps = get(root, compkind, nothing)
        (comps isa AbstractDict && !isempty(comps)) || continue
        cname = first(keys(comps))
        comp = comps[cname]
        comp isa AbstractDict || continue
        _append_component_imports!(comp, injected)
        return root
    end
    return root
end

# Collect, for one coupling entry, the set of system names it references
# (esm-spec §10.8): `operator_compose`/`couple` → `systems`; `variable_map` →
# the owning systems of `from`/`to`; `event` → owning systems of any scoped
# reference in the entry. A `callback` references none.
function _coupling_referenced_systems(entry::AbstractDict)::Set{String}
    out = Set{String}()
    ctype = string(get(entry, "type", ""))
    if ctype in ("operator_compose", "couple")
        sys = get(entry, "systems", nothing)
        if sys isa AbstractVector
            for s in sys
                push!(out, string(s))
                push!(out, String(first(split(string(s), '.'))))
            end
        end
    elseif ctype == "variable_map"
        for k in ("from", "to")
            v = get(entry, k, nothing)
            v === nothing && continue
            push!(out, String(first(split(string(v), '.'))))
        end
    elseif ctype == "event"
        _collect_scoped_owners!(out, entry)
    end
    return out
end

# Walk `x` and add the owning-system segment of every scoped reference (a
# string of the form "System.var") to `out`. Used for `event` entries whose
# system references are spread across conditions/affects.
function _collect_scoped_owners!(out::Set{String}, x)
    if x isa AbstractString
        occursin('.', x) && push!(out, String(first(split(x, '.'))))
    elseif x isa AbstractDict
        for (_, v) in pairs(x)
            _collect_scoped_owners!(out, v)
        end
    elseif x isa AbstractVector
        for v in x
            _collect_scoped_owners!(out, v)
        end
    end
    return out
end

"""
    _apply_coupling_injections!(root)

esm-spec §9.7.10 form B / §10.8: for each `coupling` entry carrying an
`expression_template_imports` map `{ <target>: [imports...] }`, resolve each
target key to a top-level system and append its imports to that system's own
`expression_template_imports` (merge order §9.7.10). The map is consumed here
(deleted from the entry) so form B does not survive `parse → emit`.

Diagnostics (esm-spec §9.6.6): a key naming no system the entry references is
`template_inject_target_unknown`; a key resolving to neither a model nor a
reaction system is `template_inject_target_not_component`. A data source is
not a component, so a coupling entry cannot reference one and such a key
never reaches this resolution — it fails the `referenced` check first. Only
top-level system targets are resolved by this binding — a nested
`Parent.Child` key is out of scope (RFC §8.3) and reported as
`template_inject_target_not_component`.
"""
function _apply_coupling_injections!(root::AbstractDict)
    coupling = get(root, "coupling", nothing)
    coupling isa AbstractVector || return root
    models = get(root, "models", nothing)
    rsystems = get(root, "reaction_systems", nothing)
    _is_top(d, k) = d isa AbstractDict && haskey(d, k)
    for entry in coupling
        entry isa AbstractDict || continue
        inj = get(entry, "operator_imports", nothing)
        inj === nothing && continue
        inj isa AbstractDict || throw(
            ExpressionTemplateError(
                ERROR_CODES.TEMPLATE_INJECT_TARGET_NOT_COMPONENT,
                "coupling entry `expression_template_imports` must be a map from a " *
                    "target system name to a list of imports (esm-spec §9.7.10 / §10.8)"
            )
        )
        referenced = _coupling_referenced_systems(entry)
        for (target, imports) in pairs(inj)
            tname = string(target)
            (tname in referenced) || throw(
                ExpressionTemplateError(
                    ERROR_CODES.TEMPLATE_INJECT_TARGET_UNKNOWN,
                    "coupling entry `expression_template_imports` key '$tname' names no " *
                        "system referenced by that entry (esm-spec §9.7.10 / §10.8). " *
                        "The entry references: " *
                        "$(isempty(referenced) ? "(none)" : join(sort(collect(referenced)), ", "))."
                )
            )
            if _is_top(models, tname)
                comp = models[tname]
            elseif _is_top(rsystems, tname)
                comp = rsystems[tname]
            else
                throw(
                    ExpressionTemplateError(
                        ERROR_CODES.TEMPLATE_INJECT_TARGET_NOT_COMPONENT,
                        "coupling entry `expression_template_imports` key '$tname' resolves to " *
                            "neither a top-level model nor a reaction system " *
                            "(esm-spec §9.7.10). Nested `Parent.Child` targets are out of scope."
                    )
                )
            end
            comp isa AbstractDict || throw(
                ExpressionTemplateError(
                    ERROR_CODES.TEMPLATE_INJECT_TARGET_NOT_COMPONENT,
                    "coupling entry `expression_template_imports` key '$tname' does not name a " *
                        "component object (esm-spec §9.7.10)."
                )
            )
            imports isa AbstractVector || throw(
                ExpressionTemplateError(
                    ERROR_CODES.TEMPLATE_IMPORT_NOT_LIBRARY,
                    "coupling entry `expression_template_imports` value for '$tname' must be a " *
                        "list of §9.7.2 import entries (esm-spec §9.7.10 / §10.8)."
                )
            )
            _append_component_imports!(comp, imports)
        end
        delete!(entry, "operator_imports")
    end
    return root
end

"""
    apply_scope_injections(raw, injected) -> mutable native tree

esm-spec §9.7.10 forms A + B: if `raw` needs a scope-directed injection (a
non-empty subsystem-ref edge list `injected`, or a coupling entry carrying an
injection map), return a mutable native copy of `raw` with the injected imports
folded into the target components' own `expression_template_imports`, ready for
`resolve_template_machinery`. Returns `nothing` when no injection applies, so
the caller keeps its original (JSON3) fast path.
"""
function apply_scope_injections(raw, injected)
    _has_scope_injection(raw, injected) || return nothing
    root = _to_ordered(raw)::OrderedDict{String, Any}
    _apply_subsystem_ref_injection!(root, injected)
    _apply_coupling_injections!(root)
    return root
end
