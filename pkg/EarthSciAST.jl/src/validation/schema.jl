# The JSON-Schema validator: one record per violation, with its keyword and RFC 6901 pointer.

# Load schema at module initialization from bundled package data
const SCHEMA_PATH = joinpath(pkgdir(@__MODULE__), "data", "esm-schema.json")
# Track data file so precompile cache invalidates when schema changes.
@static if ccall(:jl_generating_output, Cint, ()) == 1
    include_dependency(SCHEMA_PATH)
end

# Global schema validator
const ESM_SCHEMA = if isfile(SCHEMA_PATH)
    try
        Schema(JSON3.read(read(SCHEMA_PATH, String)))
    catch e
        @warn "Failed to load ESM schema: $e"
        nothing
    end
else
    @warn "ESM schema file not found at $SCHEMA_PATH"
    nothing
end

# ── Schema-error collection (AJV-parity leaf enumeration) ───────────────────
#
# JSONSchema.jl's `validate` short-circuits at the FIRST failing keyword and, at
# a `oneOf`/`anyOf`/`allOf` node, reports ONLY the enclosing combinator — never
# the underlying keyword (e.g. the missing `required` inside the intended
# branch). It also reports the whole document at path "" but everything else at
# a 1-based Julia bracket path. The cross-language conformance contract
# (CONFORMANCE_SPEC §7.1.2) instead wants ONE record per schema violation, each
# carrying the standard JSON-Schema keyword that failed and the RFC-6901 JSON
# Pointer of the offending node (0-based array indices, root ""), matching
# TypeScript's AJV `allErrors` output.
#
# `_schema_walk!` walks the schema alongside the instance in one of two modes.
# MATCH mode (no error sink) answers "does `x` satisfy this subschema?" and
# stops at the first failure; it decides every combinator branch. COLLECT mode
# (an error sink) accumulates every leaf failure with its pointer. Both modes
# descend the applicator keywords (`properties`, `items`, `oneOf`, `if`,
# `additionalProperties`, …) here, with the library's semantics for each, and
# hand every leaf assertion keyword (`type`, `required`, `enum`, …) to
# JSONSchema.jl's own `_validate`. A VALID document — every combinator
# satisfied — yields ZERO errors, identical to the library;
# `test/schema_match_parity_test.jl` pins the match verdict to the library's.
#
# The library's whole-subschema `_validate` is not used, because on a deep
# expression its cost grows with depth on every failed check: it carries the
# instance path down the tree and renders it into a string for each failure,
# and a valid expression fails several checks per node (every `oneOf` branch
# of `Expression` but one, every `if` of `ExpressionNode` but one). It also
# dispatches on `Val{Symbol(k)}` for every keyword at every node. Here no
# path is kept in match mode, and the schema is compiled once into a linked
# graph of `_SchemaNode`s, so the walk does no `$ref` resolution, lookup or
# locking per node.

# RFC-6901 JSON Pointer builder. Each segment is prefixed with "/"; the special
# characters `~` and `/` are escaped per §4 of the RFC.
_ptr_escape(seg::AbstractString) = replace(replace(seg, "~" => "~0"), "/" => "~1")
_ptr_child(path::AbstractString, seg) = string(path, "/", _ptr_escape(string(seg)))

# Schema keywords that carry no assertion of their own (identifiers, metadata,
# and the `$defs`/`definitions` stores), skipped during the walk.
const _SCHEMA_ANNOTATION_KEYS = Set{String}(
    [
        "\$schema", "\$id", "\$ref", "\$anchor", "\$dynamicAnchor", "\$dynamicRef",
        "\$vocabulary", "\$comment", "\$defs", "definitions",
        "title", "description", "examples", "default", "deprecated",
        "readOnly", "writeOnly", "contentEncoding", "contentMediaType",
    ]
)

# A fresh, empty instance path for JSONSchema.jl's private `_validate`. Before
# v1.6 the path is a `String`; from v1.6 it is an `_InstancePath` segment vector
# that the library pushes to and pops from while it descends, so each
# validation gets its own; the walk below hands it only to leaf keywords, which
# leave it as they found it. Only the pass/fail verdict is read here, never the
# path, so the root path is all either version needs.
@static if isdefined(JSONSchema, :_InstancePath)
    _jsonschema_root_path() = JSONSchema._InstancePath()
else
    _jsonschema_root_path() = ""
end

function _schema_error_message(keyword::AbstractString)::String
    keyword == "required"             && return "missing required property"
    keyword == "additionalProperties" && return "unexpected additional property"
    keyword == "type"                 && return "value has the wrong type"
    keyword == "enum"                 && return "value is not one of the permitted values"
    keyword == "const"                && return "value does not equal the required constant"
    keyword == "oneOf"                && return "must match exactly one schema in oneOf"
    keyword == "anyOf"                && return "must match at least one schema in anyOf"
    keyword == "not"                  && return "must not match the schema"
    return "schema validation failed: $keyword"
end

_push_schema_error!(errors::Vector{SchemaError}, path::AbstractString, keyword::AbstractString) =
    push!(errors, SchemaError(String(path), _schema_error_message(keyword), String(keyword)))

# ── Compiled schema ─────────────────────────────────────────────────────────

# What a compiled subschema is, once its `\$ref` is resolved as the library
# resolves it.
const _NODE_OBJECT = 0x00    # an object of keywords
const _NODE_TRUE = 0x01
const _NODE_FALSE = 0x02
const _NODE_OTHER = 0x03     # anything else, left to the library

# What `_schema_walk_keyword!` does with a keyword. Keywords that assert
# nothing on their own (annotations, `then`/`else`, an `if` with neither,
# `additionalProperties: true`) are dropped at compile time.
const _KW_LEAF = 0x00                 # the library's method for it
const _KW_PROPERTIES = 0x01
const _KW_PATTERN_PROPERTIES = 0x02
const _KW_ADDITIONAL_PROPERTIES = 0x03  # holding a schema
const _KW_NO_ADDITIONAL_PROPERTIES = 0x04  # `additionalProperties: false`
const _KW_PROPERTY_NAMES = 0x05
const _KW_ITEMS = 0x06                # `items` holding one schema
const _KW_CONTAINS = 0x07
const _KW_ALLOF = 0x08
const _KW_ANYOF = 0x09
const _KW_ONEOF = 0x0a
const _KW_NOT = 0x0b
const _KW_IF = 0x0c
const _KW_PATTERN = 0x0d

# One keyword of a compiled object schema. Which payload fields are set
# depends on `kind`:
#   `sub`        the one subschema of `items`, `contains`, `propertyNames`,
#                `not`, `additionalProperties` and `if`;
#   `subs`       the branches of `allOf`/`anyOf`/`oneOf`; for `if`, its
#                `then` and `else` (either may be `nothing`);
#   `props`      `properties` by name; for `additionalProperties`, the
#                sibling `properties` it does not apply to;
#   `patterns`   the regex sources of `pattern`, of `patternProperties` (in
#                `subs` order), or of the sibling `patternProperties` that
#                `additionalProperties` does not apply to. Compiled on first
#                use, as the library compiles them only when it evaluates them.
#
# `N` is always `_SchemaNode`; the parameter only breaks the two types' cycle.
mutable struct _SchemaKeyword{N}
    const kind::UInt8
    const name::String
    const v::Any             # the keyword's value, for the library's method
    const val::Val           # `Val{Symbol(name)}()`, likewise
    const sub::Union{Nothing, N}
    const subs::Vector{Union{Nothing, N}}
    const props::Dict{String, N}
    const patterns::Vector{String}
    @atomic regexes::Union{Nothing, Vector{Regex}}
end

struct _SchemaNode
    kind::UInt8
    schema::Any              # the ref-resolved subschema, for the library's methods
    keywords::Vector{_SchemaKeyword{_SchemaNode}}  # filled after the node is linked
end

function _SchemaKeyword(
        kind, name, v;
        sub = nothing, subs = Union{Nothing, _SchemaNode}[],
        props = Dict{String, _SchemaNode}(), patterns = String[]
    )
    return _SchemaKeyword{_SchemaNode}(
        kind, name, v, Val{Symbol(name)}(), sub, subs, props, patterns, nothing
    )
end

function _keyword_regexes(kw::_SchemaKeyword)::Vector{Regex}
    r = @atomic :acquire kw.regexes
    r === nothing || return r
    r = Regex[Regex(p) for p in kw.patterns]
    @atomic :release kw.regexes = r
    return r
end

# Compile `schema` and everything reachable from it. `seen` maps each
# ref-resolved subschema (by identity) to its node, which both shares nodes
# between the places a definition is referenced from and closes the
# recursive references (`Expression` → `ExpressionNode` → `Expression`).
function _compile_schema(schema0, seen::IdDict{Any, _SchemaNode})
    schema = JSONSchema._resolve_refs(schema0)
    node = get(seen, schema, nothing)
    node === nothing || return node
    kind = schema === true ? _NODE_TRUE :
        schema === false ? _NODE_FALSE :
        schema isa AbstractDict ? _NODE_OBJECT : _NODE_OTHER
    node = _SchemaNode(kind, schema, _SchemaKeyword{_SchemaNode}[])
    seen[schema] = node
    kind == _NODE_OBJECT || return node
    for (k0, v) in schema
        kw = _compile_keyword(schema, String(k0), v, seen)
        kw === nothing || push!(node.keywords, kw)
    end
    return node
end

function _compile_keyword(schema, k::String, v, seen)
    sub(s) = _compile_schema(s, seen)
    (k in _SCHEMA_ANNOTATION_KEYS || k == "then" || k == "else") && return nothing
    if k == "properties" && v isa AbstractDict
        return _SchemaKeyword(
            _KW_PROPERTIES, k, v;
            props = Dict{String, _SchemaNode}(String(p) => sub(s) for (p, s) in v)
        )
    elseif k == "patternProperties" && v isa AbstractDict
        pats = collect(pairs(v))
        return _SchemaKeyword(
            _KW_PATTERN_PROPERTIES, k, v;
            subs = Union{Nothing, _SchemaNode}[sub(s) for (_, s) in pats],
            patterns = String[String(p) for (p, _) in pats]
        )
    elseif k == "additionalProperties" && (v isa AbstractDict || v isa Bool)
        v === true && return nothing
        props = get(schema, "properties", nothing)
        pprops = get(schema, "patternProperties", nothing)
        return _SchemaKeyword(
            v === false ? _KW_NO_ADDITIONAL_PROPERTIES : _KW_ADDITIONAL_PROPERTIES, k, v;
            sub = v isa AbstractDict ? sub(v) : nothing,
            # Only the names matter here; the nodes are those of `properties`.
            props = props isa AbstractDict ?
                Dict{String, _SchemaNode}(String(p) => sub(s) for (p, s) in props) :
                Dict{String, _SchemaNode}(),
            patterns = pprops isa AbstractDict ? String[String(p) for p in keys(pprops)] : String[]
        )
    elseif k == "propertyNames"
        return _SchemaKeyword(_KW_PROPERTY_NAMES, k, v; sub = sub(v))
    elseif k == "items" && v isa AbstractDict
        # `items` as a tuple or a Bool, and `additionalItems`, stay leaves:
        # their semantics differ between JSONSchema releases.
        return _SchemaKeyword(_KW_ITEMS, k, v; sub = sub(v))
    elseif k == "contains"
        return _SchemaKeyword(_KW_CONTAINS, k, v; sub = sub(v))
    elseif k in ("allOf", "anyOf", "oneOf") && v isa AbstractVector
        kind = k == "allOf" ? _KW_ALLOF : k == "anyOf" ? _KW_ANYOF : _KW_ONEOF
        return _SchemaKeyword(kind, k, v; subs = Union{Nothing, _SchemaNode}[sub(s) for s in v])
    elseif k == "not"
        return _SchemaKeyword(_KW_NOT, k, v; sub = sub(v))
    elseif k == "if"
        # An `if` with neither `then` nor `else` is ignored, as by the library.
        (haskey(schema, "then") || haskey(schema, "else")) || return nothing
        return _SchemaKeyword(
            _KW_IF, k, v; sub = sub(v),
            subs = Union{Nothing, _SchemaNode}[
                haskey(schema, "then") ? sub(schema["then"]) : nothing,
                haskey(schema, "else") ? sub(schema["else"]) : nothing,
            ]
        )
    elseif k == "pattern" && v isa String
        return _SchemaKeyword(_KW_PATTERN, k, v; patterns = [v])
    end
    return _SchemaKeyword(_KW_LEAF, k, v)
end

# The compiled form of the root schema, built on first use and kept for as
# long as the same root object is asked for (the ESM schema is a constant).
const _SCHEMA_COMPILED = Ref{Any}(nothing)
const _SCHEMA_COMPILED_LOCK = ReentrantLock()

function _compiled_schema(root)::_SchemaNode
    return lock(_SCHEMA_COMPILED_LOCK) do
        cached = _SCHEMA_COMPILED[]
        cached !== nothing && cached[1] === root && return cached[2]::_SchemaNode
        node = _compile_schema(root, IdDict{Any, _SchemaNode}())
        _SCHEMA_COMPILED[] = (root, node)
        return node
    end
end

# ── The walk ────────────────────────────────────────────────────────────────

# `sink` is `nothing` in match mode, or the error vector in collect mode.
const _SchemaSink = Union{Nothing, Vector{SchemaError}}

# A child's pointer, built only when there is somewhere to report it.
_walk_path(::Nothing, path::String, seg) = path
_walk_path(::Vector{SchemaError}, path::String, seg) = _ptr_child(path, seg)

# Record a failure of `keyword` at `path` (collect mode) and return `false`.
_walk_fail!(::Nothing, path, keyword) = false
_walk_fail!(errors::Vector{SchemaError}, path, keyword) =
    (_push_schema_error!(errors, path, keyword); false)

# Does `x` satisfy `node`? In collect mode every failure beneath is recorded
# and the walk goes on; in match mode it stops at the first. `root` is the
# library's empty instance path, passed to its leaf methods.
function _schema_walk!(sink::_SchemaSink, x, node::_SchemaNode, path::String, root)::Bool
    kind = node.kind
    kind == _NODE_TRUE && return true
    kind == _NODE_FALSE && return _walk_fail!(sink, path, "schema")
    if kind == _NODE_OTHER
        # Not a schema: the library's to judge (or to refuse); nothing to report.
        return sink !== nothing || JSONSchema._validate(x, node.schema, root) === nothing
    end
    ok = true
    for kw in node.keywords
        _schema_walk_keyword!(sink, x, node, kw, path, root) && continue
        sink === nothing && return false
        ok = false
    end
    return ok
end

_schema_matches(x, node::_SchemaNode, root) = _schema_walk!(nothing, x, node, "", root)

# Is a property name outside both `properties` and `patternProperties`?
_is_additional(kw::_SchemaKeyword, k) =
    !haskey(kw.props, k) && !_anyof(r -> occursin(r, k), _keyword_regexes(kw))

# One keyword of `node` on `x`, with the semantics of the library's
# `_validate(x, schema, Val(k), v, path)` under the argument types its
# method takes.
function _schema_walk_keyword!(sink::_SchemaSink, x, node::_SchemaNode, kw::_SchemaKeyword, path::String, root)::Bool
    kind = kw.kind
    if kind == _KW_PROPERTIES
        x isa AbstractDict || return true
        ok = true
        for (xk, xv) in x
            sub = get(kw.props, xk, nothing)
            sub === nothing && continue
            _schema_walk!(sink, xv, sub, _walk_path(sink, path, xk), root) && continue
            sink === nothing && return false
            ok = false
        end
        return ok
    elseif kind == _KW_PATTERN_PROPERTIES
        x isa AbstractDict || return true
        ok = true
        for (r, sub) in zip(_keyword_regexes(kw), kw.subs)
            for (xk, xv) in x
                occursin(r, xk) || continue
                _schema_walk!(sink, xv, sub::_SchemaNode, _walk_path(sink, path, xk), root) && continue
                sink === nothing && return false
                ok = false
            end
        end
        return ok
    elseif kind == _KW_ADDITIONAL_PROPERTIES
        x isa AbstractDict || return true
        ok = true
        for (xk, xv) in x
            _is_additional(kw, xk) || continue
            _schema_walk!(sink, xv, kw.sub::_SchemaNode, _walk_path(sink, path, xk), root) && continue
            sink === nothing && return false
            ok = false
        end
        return ok
    elseif kind == _KW_NO_ADDITIONAL_PROPERTIES
        x isa AbstractDict || return true
        _anyof(xk -> _is_additional(kw, xk), keys(x)) || return true
        return _walk_fail!(sink, path, "additionalProperties")
    elseif kind == _KW_PROPERTY_NAMES
        x isa AbstractDict || return true
        sub = kw.sub::_SchemaNode
        _allof(xk -> _schema_matches(xk, sub, root), keys(x)) && return true
        return _walk_fail!(sink, path, "propertyNames")
    elseif kind == _KW_ITEMS
        x isa AbstractVector || return true
        sub = kw.sub::_SchemaNode
        ok = true
        for (i, xi) in enumerate(x)
            _schema_walk!(sink, xi, sub, _walk_path(sink, path, i - 1), root) && continue
            sink === nothing && return false
            ok = false
        end
        return ok
    elseif kind == _KW_CONTAINS
        x isa AbstractVector || return true
        sub = kw.sub::_SchemaNode
        _anyof(xi -> _schema_matches(xi, sub, root), x) && return true
        return _walk_fail!(sink, path, "contains")
    elseif kind == _KW_ALLOF
        ok = true
        for sub in kw.subs
            _schema_walk!(sink, x, sub::_SchemaNode, path, root) && continue
            sink === nothing && return false
            ok = false
        end
        return ok
    elseif kind == _KW_ANYOF
        _anyof(sub -> _schema_matches(x, sub::_SchemaNode, root), kw.subs) && return true
        _walk_fail!(sink, path, "anyOf")
        # Every branch failed: descend them all for the underlying leaf errors.
        sink === nothing || for sub in kw.subs
            _schema_walk!(sink, x, sub::_SchemaNode, path, root)
        end
        return false
    elseif kind == _KW_ONEOF
        nmatch = 0
        for sub in kw.subs
            _schema_matches(x, sub::_SchemaNode, root) || continue
            nmatch += 1
            nmatch > 1 && break
        end
        nmatch == 1 && return true
        _walk_fail!(sink, path, "oneOf")
        # ZERO matches ⇒ every branch failed, so descend them all for the
        # underlying leaf errors. ≥2 matches ⇒ the branches PASS (no leaf error
        # to find); the `oneOf` itself is the finding.
        nmatch == 0 && sink !== nothing && for sub in kw.subs
            _schema_walk!(sink, x, sub::_SchemaNode, path, root)
        end
        return false
    elseif kind == _KW_NOT
        _schema_matches(x, kw.sub::_SchemaNode, root) || return true
        return _walk_fail!(sink, path, "not")
    elseif kind == _KW_IF
        branch = _schema_matches(x, kw.sub::_SchemaNode, root) ? kw.subs[1] : kw.subs[2]
        return branch === nothing || _schema_walk!(sink, x, branch, path, root)
    elseif kind == _KW_PATTERN && x isa String
        # The library's check, `occursin(Regex(v), x)`, with the pattern
        # compiled once rather than per string.
        occursin(only(_keyword_regexes(kw)), x) && return true
        return _walk_fail!(sink, path, "pattern")
    end
    # A leaf assertion keyword (`type`, `required`, `enum`, `minItems`, …), or
    # an applicator in a form left to the library: evaluated by JSONSchema.jl
    # exactly as in a normal validation, failing at THIS node.
    JSONSchema._validate(x, node.schema, kw.val, kw.v, root) === nothing && return true
    return _walk_fail!(sink, path, kw.name)
end

# Collapse identical (path, keyword) findings (a `oneOf` branch descent or a
# per-extra-key `additionalProperties` scan can raise the same finding twice).
# The comparator matches on (keyword, path) sets, so this is loss-free.
function _dedup_schema_errors(errors::Vector{SchemaError})::Vector{SchemaError}
    seen = Set{Tuple{String, String}}()
    out = SchemaError[]
    for e in errors
        key = (e.path, e.keyword)
        key in seen && continue
        push!(seen, key)
        push!(out, e)
    end
    return out
end

"""
    validate_schema(data::Any) -> Vector{SchemaError}

Validate `data` (a native JSON tree of `Dict`/`Vector`/scalars) against the ESM
schema. Returns an empty vector when valid; otherwise ONE `SchemaError` per
schema violation (CONFORMANCE_SPEC §7.1.2), each carrying:

- `path` — the RFC-6901 JSON Pointer of the offending node (document root `""`,
  0-based array indices);
- `keyword` — the JSON-Schema keyword that failed (`required`, `type`, `enum`,
  `minItems`, `oneOf`, `additionalProperties`, …);
- `message` — free human-readable text (not part of the conformance contract).

Unlike JSONSchema.jl's single-issue `validate`, this enumerates leaf failures
INSIDE failed `oneOf`/`anyOf`/`allOf`/`if` branches (see
`_schema_walk!`), matching TypeScript's AJV `allErrors` output.
"""
function validate_schema(data::Any)::Vector{SchemaError}
    if ESM_SCHEMA === nothing
        @warn "Schema validation skipped - schema not loaded"
        return SchemaError[]
    end
    errors = SchemaError[]
    try
        # Normalise to NATIVE JSON containers first. Callers hand this function
        # different carriers — the load pipeline the post-wire ordered tree,
        # the conformance producer a native `Dict{String,Any}` tree, direct
        # callers possibly a raw `JSON3.Object` — and JSON3's `JSON3.Array` is
        # not a `Base.Array`, so JSONSchema.jl's `type: array` check (and every
        # `oneOf` branch that depends on it) misfires on the JSON3 carrier.
        # Coercing to native containers makes the walk carrier-independent.
        native = _to_native_json(data)
        _schema_walk!(errors, native, _compiled_schema(ESM_SCHEMA.data), "", _jsonschema_root_path())
    catch e
        e isa InterruptException && rethrow()
        return [SchemaError("", "Schema validation error: $(e)", "error")]
    end
    return _dedup_schema_errors(errors)
end
