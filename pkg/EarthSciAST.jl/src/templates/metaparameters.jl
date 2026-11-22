# Load-time `metaparameters` (esm-spec §9.7.6): declarations, substitution,
# folding of structural integer sites, and the per-document close.

# ---------------------------------------------------------------------------
# Metaparameters (esm-spec §9.7.6)
# ---------------------------------------------------------------------------

function _require_int(v, ctx::String)::Int64
    (v isa Integer && !(v isa Bool)) && return Int64(v)
    throw(
        ExpressionTemplateError(
            ERROR_CODES.METAPARAMETER_TYPE_ERROR,
            "$ctx: value $(repr(v)) is not an integer (esm-spec §9.7.6)"
        )
    )
end

function _collect_metaparam_decls(raw, origin::String)::OrderedDict{String, Any}
    out = OrderedDict{String, Any}()
    mp = _raw_get(raw, "metaparameters")
    mp === nothing && return out
    _is_object(mp) || throw(
        ExpressionTemplateError(
            ERROR_CODES.METAPARAMETER_TYPE_ERROR, "$origin: `metaparameters` must be an object"
        )
    )
    for (k, v) in pairs(mp)
        name = string(k)
        _is_object(v) || throw(
            ExpressionTemplateError(
                ERROR_CODES.METAPARAMETER_TYPE_ERROR,
                "$origin: metaparameters.$name must be an object with `type: \"integer\"`"
            )
        )
        t = _raw_get(v, "type")
        (t !== nothing && string(t) == "integer") || throw(
            ExpressionTemplateError(
                ERROR_CODES.METAPARAMETER_TYPE_ERROR,
                "$origin: metaparameters.$name: `type` must be \"integer\" (the only kind)"
            )
        )
        d = _raw_get(v, "default")
        d === nothing || _require_int(d, "$origin: metaparameters.$name default")
        out[name] = _to_ordered(v)
    end
    return out
end

# ---------------------------------------------------------------------------
# Canonical structural-field table
# ---------------------------------------------------------------------------
# The registry of raw-JSON object keys whose values are structural, not
# expression positions, for metaparameter substitution (esm-spec §9.7.6, this
# file) and the import-edge rename walk (§9.7.7, templates/imports.jl). The
# skip/protect sets below are derived from it. An unregistered structural field
# has its string values rewritten as if they were variable references.
#
# Kinds:
#   :protected  — opaque to metaparameter substitution AND copied verbatim by
#                 the rename walk. (`name` and `where` additionally get a
#                 positional rename-walk branch: apply-template `name` maps
#                 through `tplmap`; a `where` OBJECT's §9.6.1 `shape` entries
#                 map through `isetmap` via `_rename_where`.)
#   :axis       — scalar value NAMES an index set / axis (`wrt`, `dim`, and
#                 `integral`'s `var`): the rename walk maps it through
#                 `isetmap`; also opaque to metaparameter substitution (an axis
#                 name is never an integer-valued metaparameter reference).
#   :bound      — an ordinary EXPRESSION position that may ALSO hold a bare axis
#                 name (`integral`'s `lower`/`upper`, esm-spec §4.2): the rename
#                 walk maps it through `isetmap` only when the string names a
#                 renamed index set, and it stays open to metaparameter
#                 substitution and to `varmap` like any other expression.
#   :node       — a node-header field describing the node itself (`op`, `id`,
#                 `expect_cadence`): opaque to metaparameter substitution and
#                 copied verbatim by the rename walk.
#   :registry   — a closed-registry id or enum parameterizing the node's op
#                 (`reduce`, `semiring`, `fn`, `table`, …): treated as `:node`.
#   :opaque     — a loop symbol, reference, id, enum, unit or free text that is
#                 not an expression position but that the rename walk does not
#                 protect: opaque to metaparameter substitution ONLY. (`of` and
#                 `on` also keep their dedicated rename-walk branches.)
#   :positional — no derived-set membership; handled by a dedicated branch in
#                 `_rename_walk` / `_collect_ref_names!`: `from` ({from:
#                 <indexSet>} references map through `isetmap`).
#
# The classification of every string-capable schema property, and the key set
# derived from it, lives in
# `tests/metaparameter_substitution/field_classification.json`; the test suite
# fails when `_META_SUBST_SKIP_KEYS` or `_NAME_KEYED_MAP_KEYS` disagree with it.
const _STRUCTURAL_FIELDS = (
    "metadata" => :protected,
    "params" => :protected,
    "type" => :protected,
    "units" => :protected,
    "kind" => :protected,
    "description" => :protected,
    "name" => :protected,
    "operator_imports" => :protected,
    "metaparameters" => :protected,
    "only" => :protected,
    # `where` match-scoping constraints (esm-spec §9.6.1) carry index-set
    # NAMES, a structural namespace — never expression positions.
    "where" => :protected,
    "wrt" => :axis,
    "dim" => :axis,
    # `integral`'s integration variable (esm-spec §4.2) is an axis NAME too —
    # the same kind of axis-naming scalar as `wrt`/`dim`, so an imported
    # `integral` rewrite rule follows its axis under rename exactly as a `D`
    # rule does, and a bound metaparameter of the same name never rewrites it.
    "var" => :axis,
    # `integral`'s BOUNDS (esm-spec §4.2) are full Expression positions — a
    # numeric literal, a parameter reference, an AST subtree — so they stay
    # variable-reference positions for `varmap`; only a bare string naming a
    # RENAMED index set (the cumulative form `"upper": "x"`) is an axis
    # occurrence and follows the rename (§9.7.7).
    "lower" => :bound,
    "upper" => :bound,
    # Node-header fields: an operator NAME is not an expression position
    # (esm-spec §9.7.6), so a metaparameter that happens to share a name with an
    # operator — `max`, say — must not rewrite `{"op": "max", …}` into
    # `{"op": 3, …}`, which then dies in the typed load with a raw "cannot
    # unmarshal number into `op`" instead of a diagnostic. `id` and
    # `expect_cadence` (`EXPRESSION_NODE_ANNOTATIONS`) are the same kind of
    # node-level annotation.
    "op" => :node,
    # esm 2.4.0: the defined operator a definition defines (esm-spec §9.6.1).
    "defines" => :node,
    (k => :node for k in EXPRESSION_NODE_ANNOTATIONS)...,
    "reduce" => :registry,
    "semiring" => :registry,
    "fn" => :registry,
    "side" => :registry,
    "attrs" => :registry,
    "members" => :registry,
    "from_faq" => :registry,
    # Loop symbols and bound index names of a `faq` node (join key columns and
    # the symbols they are read at, the output index
    # signature, a dependent range's parent indices). `metaparameter_name_conflict`
    # refuses a metaparameter spelled like a loop symbol, so a metaparameter
    # reaches these fields only as an `on` data-column name; they are names
    # wherever they appear, so they are skipped rather than left to that check.
    "on" => :opaque,
    "syms" => :opaque,
    "output_idx" => :opaque,
    "of" => :opaque,
    "handler_id" => :opaque,
    # References to files, components, data sources, data columns and the
    # import-edge rename vocabulary.
    "ref" => :opaque,
    "model" => :opaque,
    "reaction_system" => :opaque,
    "prefix" => :opaque,
    "rename" => :opaque,
    "rebind" => :opaque,
    "index_set_rename" => :opaque,
    "url_substitutions" => :opaque,
    "source" => :opaque,
    "file_variable" => :opaque,
    "path" => :opaque,
    # Closed enums.
    "direction" => :opaque,
    "hook" => :opaque,
    "root_find" => :opaque,
    "system_kind" => :opaque,
    "element_type" => :opaque,
    "scale" => :opaque,
    "format" => :opaque,
    "unmapped" => :opaque,
    # Units (unit symbols such as `m`, `s`, `K` are valid identifiers) and
    # free text.
    "default_units" => :opaque,
    "label" => :opaque,
    "location" => :opaque,
    "notes" => :opaque,
    "citation" => :opaque,
    "doi" => :opaque,
    "url" => :opaque,
    "_comment" => :opaque,
    "from" => :positional,
)

# Keys whose VALUES are never expression positions: metaparameter names are
# substituted as bare variable-reference strings, so structural string fields
# must not be rewritten. Template `params` shadowing is handled separately in
# `_substitute_metaparams_decl`.
#
# All five bindings MUST hold the SAME set here — a divergence is silent until a
# document happens to name a metaparameter after a structural field's value
# (`tests/conformance/expression_templates/metaparam_axis_name_collision`).
#
# Every structural kind but `:bound` and `:positional` is in: an expression
# position is the ONLY thing substitution may rewrite, and `:bound` is the one
# structural-table entry that IS one. `:opaque` is in this set but not in
# `_RENAME_PROTECTED_KEYS` below, so the two sets are derived separately.
const _META_SUBST_SKIP_KEYS = Set{String}(
    k for (k, kind) in _STRUCTURAL_FIELDS
        if kind === :protected || kind === :axis || kind === :node ||
        kind === :registry || kind === :opaque
)

# Keys whose value is a map keyed by AUTHOR-CHOSEN names (variables, species,
# loop symbols, template params, …). A map key is a declared name, not a field,
# so it is never looked up in `_META_SUBST_SKIP_KEYS`: a variable named `source`
# or a template param named `label` still has its value substituted. A key in
# both sets (`where`, `rename`, …) is skipped whole.
const _NAME_KEYED_MAP_KEYS = Set{String}(
    [
        "variables", "species", "parameters", "guesses", "subsystems",
        "operators", "ranges", "bindings", "config", "coords",
        "initial_conditions", "parameter_overrides", "pinned_coords", "map",
        "rename", "rebind", "index_set_rename", "url_substitutions", "where",
    ]
)

# Scalar Expression-node fields whose string value names an AXIS / index set
# (rewritten by the index-set rename map, param-shadowed like §9.6.1).
const _RENAME_AXIS_KEYS = Set{String}(
    k for (k, kind) in _STRUCTURAL_FIELDS if kind === :axis
)

# Expression-position fields that ALSO admit a bare axis name (`integral`'s
# `lower`/`upper`): the index-set rename applies only when the string names a
# renamed index set; anything else stays an ordinary variable-reference
# position.
const _RENAME_BOUND_KEYS = Set{String}(
    k for (k, kind) in _STRUCTURAL_FIELDS if kind === :bound
)

# Object keys whose values are never variable-reference positions for the
# rename walk: the metaparameter skip set plus the remaining scalar structural
# ExpressionNode fields (`op`, closed-registry ids, literal enums). `from`,
# `wrt`/`dim`, apply-`name`, and `of` are handled positionally in the walk.
const _RENAME_PROTECTED_KEYS = Set{String}(
    k for (k, kind) in _STRUCTURAL_FIELDS
        if kind === :protected || kind === :axis || kind === :node || kind === :registry
)

"""
    _substitute_metaparams(x, values)

Substitute closed metaparameter names — appearing as bare strings, the
variable-reference surface syntax — with their integer values, everywhere
except the `_META_SUBST_SKIP_KEYS` structural fields (esm-spec §9.7.6:
expression-position substitution; no folding here). The entries of a
`_NAME_KEYED_MAP_KEYS` map are walked without a skip lookup on their names.
"""
function _substitute_metaparams(x, values::AbstractDict{String})
    return _map_json(x) do key, n
        if key !== nothing
            key in _META_SUBST_SKIP_KEYS && return _to_ordered(n)
            key in _NAME_KEYED_MAP_KEYS && _is_object(n) &&
                return _substitute_metaparams_map(n, values)
        end
        if n isa AbstractString
            s = string(n)
            haskey(values, s) && return values[s]
        end
        return _JSON_DESCEND
    end
end

function _substitute_metaparams_map(n, values::AbstractDict{String})
    return OrderedDict{String, Any}(
        string(k) => _substitute_metaparams(v, values) for (k, v) in pairs(n)
    )
end

"""
    _substitute_metaparams_field(key, v, values)

[`_substitute_metaparams`](@ref) applied to the value `v` of the object field
`key`, for a caller that iterates an object's fields itself: the field is
skipped, walked as a name-keyed map, or walked, exactly as it would be inside
the recursive walk.
"""
function _substitute_metaparams_field(key::AbstractString, v, values::AbstractDict{String})
    key in _META_SUBST_SKIP_KEYS && return _to_ordered(v)
    key in _NAME_KEYED_MAP_KEYS && _is_object(v) && return _substitute_metaparams_map(v, values)
    return _substitute_metaparams(v, values)
end

"""
    _substitute_metaparams_decl(decl, values)

Metaparameter substitution over one `expression_templates` entry: the
template's own `params` shadow like-named metaparameters inside its `body`
and `match` (a param is the inner binder; substitution must not capture it).
"""
function _substitute_metaparams_decl(decl, values::AbstractDict{String})
    params = _TemplateDecl(decl).params
    shadowed = values
    if any(p -> haskey(values, p), params)
        v2 = Dict(values)
        for p in params
            delete!(v2, p)
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
function _try_fold(x, ctx::String)::Union{Int64, Nothing}
    (x isa Integer && !(x isa Bool)) && return Int64(x)
    x isa AbstractString && return nothing
    if x isa Number
        throw(
            ExpressionTemplateError(
                ERROR_CODES.METAPARAMETER_TYPE_ERROR,
                "$ctx: non-integer literal $x in a structural integer site (esm-spec §9.7.6)"
            )
        )
    end
    _is_object(x) || throw(
        ExpressionTemplateError(
            ERROR_CODES.METAPARAMETER_TYPE_ERROR,
            "$ctx: invalid metaparameter expression (expected integer, name, or {op, args})"
        )
    )
    op_raw = _raw_get(x, "op")
    args = _raw_get(x, "args")
    (op_raw === nothing || args === nothing || !_is_array(args) || isempty(args)) &&
        throw(
        ExpressionTemplateError(
            ERROR_CODES.METAPARAMETER_TYPE_ERROR,
            "$ctx: invalid metaparameter expression (expected {op: +|-|*|/, args: [...]})"
        )
    )
    vals = Union{Int64, Nothing}[_try_fold(a, ctx) for a in args]
    any(v -> v === nothing, vals) && return nothing
    ivals = Int64[v for v in vals]
    op = string(op_raw)
    op in ("+", "-", "*", "/") || throw(
        ExpressionTemplateError(
            ERROR_CODES.METAPARAMETER_TYPE_ERROR,
            "$ctx: op '$op' is not allowed in a metaparameter expression (only + - * /)"
        )
    )
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
                v == 0 && throw(
                    ExpressionTemplateError(
                        ERROR_CODES.METAPARAMETER_TYPE_ERROR, "$ctx: division by zero"
                    )
                )
                rem(acc, v) == 0 || throw(
                    ExpressionTemplateError(
                        ERROR_CODES.METAPARAMETER_TYPE_ERROR,
                        "$ctx: $acc / $v does not divide exactly (esm-spec §9.7.6)"
                    )
                )
                acc = div(acc, v)
            end
        end
        return acc
    catch e
        e isa OverflowError && throw(
            ExpressionTemplateError(
                ERROR_CODES.METAPARAMETER_TYPE_ERROR,
                "$ctx: 64-bit integer overflow while folding a metaparameter expression"
            )
        )
        rethrow(e)
    end
end

# Every bare string of a metaparameter expression except the structural value
# under `"op"` (the free-name scan for unbound-name diagnostics).
function _collect_names!(out::Vector{String}, x)
    _walk_json(x) do key, n
        key == "op" && return false
        n isa AbstractString && push!(out, string(n))
        return true
    end
    return out
end

"""
    _validate_meta_expr(x, ctx)

Structural grammar check for a metaparameter expression (esm-spec §9.7.6),
independent of whether its names are yet concrete: integer literal, name
string, or `{op: +|-|*|/, args: [...non-empty...]}` recursively. Unlike
[`_try_fold`](@ref) (which defers op-validation until every arg is concrete),
this catches an inadmissible op (`%`, missing `args`, float literal) at the
binding EDGE even when an arg is still a symbolic importer name.
"""
function _validate_meta_expr(x, ctx::String)
    (x isa Integer && !(x isa Bool)) && return
    x isa AbstractString && return
    if x isa Number
        throw(
            ExpressionTemplateError(
                ERROR_CODES.METAPARAMETER_TYPE_ERROR,
                "$ctx: non-integer literal $(repr(x)) in a metaparameter expression (esm-spec §9.7.6)"
            )
        )
    end
    _is_object(x) || throw(
        ExpressionTemplateError(
            ERROR_CODES.METAPARAMETER_TYPE_ERROR,
            "$ctx: invalid metaparameter expression (expected integer, name, or {op, args})"
        )
    )
    op = _raw_get(x, "op")
    args = _raw_get(x, "args")
    (
        (op !== nothing && string(op) in ("+", "-", "*", "/")) &&
            args !== nothing && _is_array(args) && !isempty(args)
    ) ||
        throw(
        ExpressionTemplateError(
            ERROR_CODES.METAPARAMETER_TYPE_ERROR,
            "$ctx: invalid metaparameter expression (expected {op: +|-|*|/, args: [...]})"
        )
    )
    for a in args
        _validate_meta_expr(a, ctx)
    end
    return
end

"""
    require_meta_expr(v, ctx) -> v

Validate that `v` is a *metaparameter expression* (esm-spec §9.7.6): an
integer literal, a metaparameter-name string, or a `{op: +|-|*|/, args: [...]}`
tree over the same. Returns `v` unchanged (UNFOLDED) — its free names close at
a later binding site. Raises `metaparameter_type_error` on an inadmissible
node.

This is the relaxed replacement for [`_require_int`](@ref) at the metaparameter
*binding* sites (import edge / subsystem edge). Before this, binding values were
bare integers; a binding may now derive a child metaparameter from an arithmetic
combination of the importer's metaparameters (e.g. `NTGT = NX*NY`), which import
renaming (name→name) could not express.
"""
function require_meta_expr(v, ctx::String)
    _validate_meta_expr(v, ctx)
    return v
end

"""
    eval_meta_expr(expr, env, ctx) -> Int64

Fold a metaparameter expression to a concrete integer against a CLOSED
environment `env` (name → int) — the importing document's metaparameter scope
(esm-spec §9.7.6 binding value flow). Substitutes the env names, then folds with
the exact-integer [`_try_fold`](@ref) arithmetic (`/` must divide exactly;
64-bit overflow is an error). Raises `template_import_unknown_name` if the
expression references a name absent from `env` — the mount-edge typo failure,
keeping error locality at the edge that authored the expression.
"""
function eval_meta_expr(expr, env::AbstractDict{String, <:Integer}, ctx::String)::Int64
    folded = _try_fold(_substitute_metaparams(expr, env), ctx)
    if folded === nothing
        free = sort(unique(String[n for n in _collect_names!(String[], expr) if !haskey(env, n)]))
        throw(
            ExpressionTemplateError(
                ERROR_CODES.TEMPLATE_IMPORT_UNKNOWN_NAME,
                "$ctx: metaparameter expression references " *
                    "$(isempty(free) ? "a name" : join(free, ", ")) not in the importing " *
                    "document's metaparameter scope (esm-spec §9.7.6)"
            )
        )
    end
    return folded
end

"""
    _fold_structural_sites!(x, ctx)

Fold metaparameter expressions in the structural integer sites — `faq`
dense `ranges` tuple entries and `makearray` `regions` bound pairs — to
concrete integers, in place, wherever they are already closed. Entries still
carrying a bare name (a template-param slot, or an open metaparameter in a
not-yet-fully-bound library) are left symbolic for a later binding site.
Index-set sizes are folded separately by [`_fold_index_set_sizes!`](@ref).
"""
function _fold_structural_sites!(x, ctx::String)
    # `_walk_json` visits parents first, so each structural array is folded in
    # place at its owning `faq` / `makearray` node before the walk
    # descends into it (the fold replaces entries, never reshapes).
    _walk_json(x) do _, n
        # An array of numbers or number rows holds no faq or makearray node.
        _is_array(n) && return _may_hold_object(n)
        _is_object(n) || return true
        op = get(n, "op", nothing)
        op_str = op === nothing ? "" : string(op)
        if op_str == "faq"
            ranges = get(n, "ranges", nothing)
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
            regions = get(n, "regions", nothing)
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
        return true
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
            strict && throw(
                ExpressionTemplateError(
                    ERROR_CODES.METAPARAMETER_UNBOUND,
                    "$ctx: index_sets.$(string(name)).size references unbound name(s) " *
                        "$(join(unique(_collect_names!(String[], sz)), ", ")) (esm-spec §9.7.6)"
                )
            )
        else
            decl["size"] = f
        end
    end
    return
end

# Whether the document's own `index_sets` carry a `size` that is not an integer
# literal: a metaparameter name, or an expression still to fold.
function _has_open_index_set_size(raw)
    _is_object(raw) || return false
    isets = get(raw, "index_sets", nothing)
    _is_object(isets) || return false
    return any(values(isets)) do decl
        _is_object(decl) || return false
        sz = get(decl, "size", nothing)
        sz !== nothing && !(sz isa Integer && !(sz isa Bool))
    end
end

# --- phase 3: close this document's metaparameters (§9.7.6 sites 4-5) ---
# Loader-API bindings win, then declaration defaults; any name still open is
# `metaparameter_unbound`. Returns the closed name → Int64 environment.
#
# `mount_declared` is the set of metaparameter names declared by the documents
# this one MOUNTS (§4.7, either mount form, transitively —
# `_collect_mount_declared_metaparameters`). A loader-API binding may name one
# of those: it is meaningful even though THIS document does not declare it,
# because the mount edge forwards it into the leaf's own close for the names
# the leaf declares. Such a name is accepted and CONSUMED here — it closes
# nothing in this scope, so it is absent from the returned environment (the
# loop below builds that environment from `doc_meta` alone). A name in NEITHER
# set is still a typo and still raises `template_import_unknown_name`:
# bindings never invent metaparameters (§9.7.6).
function _close_document_metaparams(
        doc_meta::OrderedDict{String, Any},
        metaparameters::AbstractDict{String, <:Integer},
        mount_declared::AbstractSet{String} = Set{String}()
    )::Dict{String, Int64}
    api = Dict{String, Int64}()
    for (k, v) in pairs(metaparameters)
        api[string(k)] = _require_int(v, "loader API metaparameter '$(string(k))'")
    end
    for k in sort(collect(keys(api)))
        (haskey(doc_meta, k) || k in mount_declared) || throw(
            ExpressionTemplateError(
                ERROR_CODES.TEMPLATE_IMPORT_UNKNOWN_NAME,
                "loader API binds metaparameter '$k', which neither this document " *
                    "nor any document it mounts declares (esm-spec §9.7.6)"
            )
        )
    end
    values = Dict{String, Int64}()
    open_names = String[]
    for (name, decl) in doc_meta
        if haskey(api, name)
            values[name] = api[name]
        else
            d = _raw_get(decl, "default")
            d === nothing ? push!(open_names, name) : (values[name] = Int64(d))
        end
    end
    isempty(open_names) || throw(
        ExpressionTemplateError(
            ERROR_CODES.METAPARAMETER_UNBOUND,
            "metaparameter(s) $(join(open_names, ", ")) still open after edge bindings, " *
                "loader-API bindings, and defaults (esm-spec §9.7.6)"
        )
    )
    return values
end

# §9.7.6: a metaparameter name must not spell a loop symbol (a `ranges` key or
# `output_idx` entry of an Expression node) anywhere in `trees`. Substitution
# rewrites every bare string that spells a bound metaparameter, and inside the
# node that binds it a loop symbol is exactly such a string, so no field rule
# can tell the two apart.
function _check_metaparam_loop_symbols(names, origin::String, trees...)
    isempty(names) && return
    bound = Set{String}()
    for t in trees
        _collect_bound_syms!(bound, t)
    end
    for name in names
        string(name) in bound && throw(
            ExpressionTemplateError(
                ERROR_CODES.METAPARAMETER_NAME_CONFLICT,
                "$origin: metaparameter '$name' collides with a loop symbol " *
                    "(a `ranges` key or `output_idx` entry) (esm-spec §9.7.6)"
            )
        )
    end
    return
end

# --- phase 4: §9.7.6 name-collision check — no shadowing of visible names ---
function _check_metaparam_name_conflicts(
        root::OrderedDict{String, Any},
        top_templates::OrderedDict{String, Any},
        doc_meta::OrderedDict{String, Any},
        doc_isets::OrderedDict{String, Any}
    )
    isempty(doc_meta) && return
    visible = Set{String}(String[string(k) for k in keys(doc_isets)])
    for (_, _, comp) in _components(root), blk in ("variables", "species", "parameters")
        b = get(comp, blk, nothing)
        (b !== nothing && _is_object(b)) || continue
        for (vn, _) in pairs(b)
            push!(visible, string(vn))
        end
    end
    for name in keys(doc_meta)
        name in visible && throw(
            ExpressionTemplateError(
                ERROR_CODES.METAPARAMETER_NAME_CONFLICT,
                "metaparameter '$name' collides with a visible " *
                    "variable/parameter/species/index-set name (esm-spec §9.7.6)"
            )
        )
    end
    # Components carry their imported templates by now; `top_templates` is a
    # root library's effective top-level sequence, imports included.
    _check_metaparam_loop_symbols(keys(doc_meta), "document", root, top_templates)
    return
end

# --- phase 5: expression-position substitution of the closed values ---
# Rewrites components and top-level templates in place (with per-declaration
# `params` shadowing); returns the substituted index-set registry (the input
# one when there is nothing to substitute).
function _substitute_closed_metaparams!(
        root::OrderedDict{String, Any},
        top_templates::OrderedDict{String, Any},
        doc_isets::OrderedDict{String, Any},
        values::Dict{String, Int64}
    )
    isempty(values) && return doc_isets
    for (_, _, comp) in _components(root), k in collect(keys(comp))
        if k == "operators" && _is_object(comp[k])
            tpl = comp[k]
            for (tn, td) in collect(pairs(tpl))
                tpl[tn] = _substitute_metaparams_decl(td, values)
            end
        else
            comp[k] = _substitute_metaparams_field(k, comp[k], values)
        end
    end
    for (tn, td) in collect(pairs(top_templates))
        top_templates[tn] = _substitute_metaparams_decl(td, values)
    end
    newisets = OrderedDict{String, Any}()
    for (n, d) in doc_isets
        newisets[n] = _substitute_metaparams(d, values)
    end
    return newisets
end

# --- phase 6: fold structural sites on the closed document ---
#
# `strict` says whether this document is the LAST scope that could close a
# name. At a ROOT document it is, so a still-open index-set `size` is
# `metaparameter_unbound`. At a §4.7 mount edge it is NOT: the leaf resolves in
# its own scope, but its `index_sets` then merge into the MOUNTING document's
# registry (§4.7 "Index-set merge") and close there, so an axis this scope
# cannot size stays SYMBOLIC and travels up rather than failing here. That is
# §9.7.6 site 5's "a metaparameter an edge leaves unbound ... is closed at some
# enclosing document's close", applied to the axis the name sizes.
function _fold_closed_document!(
        root::OrderedDict{String, Any},
        top_templates::OrderedDict{String, Any},
        doc_isets::OrderedDict{String, Any};
        strict::Bool = true
    )
    for (compkind, cname, comp) in _components(root)
        _fold_structural_sites!(comp, "$compkind.$cname")
    end
    for (tn, td) in pairs(top_templates)
        _fold_structural_sites!(td, "document.expression_templates.$tn")
    end
    _fold_index_set_sizes!(doc_isets, "document"; strict = strict)
    return
end
