"""
ESM Format JSON Parsing

Provides functionality to load and validate ESM files from JSON strings or files.
Uses manual JSON parsing and type coercion for full control over the deserialization process.
"""

using JSON3
using JSONSchema


# Recursively convert any JSON carrier into plain-`Dict{String,Any}` /
# `Vector{Any}` containers — the UNORDERED deep-plain normalizer, kept (beside
# the order-preserving `_to_ordered` in json_walk.jl) for two jobs where key
# order is deliberately NOT part of the contract:
#   * raw-passthrough values stored on typed structs and re-emitted verbatim
#     (`functional_affect`, loader `metadata`, the `_verbatim_decl` snapshots,
#     serialize.jl's import-entry copies), whose JSON3-written bytes depend on
#     them being plain Dicts;
#   * carrier-independent input to JSONSchema.jl (`validate_schema`), whose
#     `type: array` check does not recognize `JSON3.Array`.
#
# A leaf-only `Vector{Any}` (an inline number array) is already plain and is
# returned as is, not copied: none of the jobs above mutates one.
function _to_native_json(x)
    x isa Vector{Any} && _leaves_only(x) && return x
    # A JSON3 view's numbers are read back by `_json3_to_ordered` (json_walk.jl).
    (x isa JSON3.Array || x isa JSON3.Object) && return _to_native_json(_json3_to_ordered(x))
    if x isa AbstractVector
        return Any[_to_native_json(v) for v in x]
    elseif x isa AbstractDict
        return Dict{String, Any}(string(k) => _to_native_json(v) for (k, v) in pairs(x))
    else
        return x
    end
end

"""
    expression_from_json(data::Any) -> ASTExpr

Parse JSON data into an Expression (NumExpr, VarExpr, or OpExpr).
Handles the oneOf discriminated union based on JSON structure.
"""
function expression_from_json(data::Any)::ASTExpr
    # Bool <: Integer in Julia, so screen it first (JSON booleans should not
    # become integer literals — they do not appear in valid ESM expressions).
    if isa(data, Bool)
        throw(ParseError("Boolean literal is not a valid expression node"))
    elseif isa(data, Integer)
        # JSON integer token (no '.', no 'e') → IntExpr (RFC §5.4.6 parse rule)
        return IntExpr(Int64(data))
    elseif isa(data, AbstractFloat)
        # A JSON number whose value is integral and Int64-representable is an
        # INTEGER literal, regardless of source spelling (CONFORMANCE_SPEC
        # §5.5.3.1 rule 1). JSON3's scalar reader already narrows an integral
        # float token (`1.0`) to `Int64` on parse; the same narrowing is applied
        # here so the AST-literal boundary is uniform even when JSON3's
        # context-dependent structural inference materialises a bare integer
        # token (`1`) as `Float64` in a deeply-nested, schema-repeating document
        # (e.g. an integer ratio `{op:"/",args:[1,N]}` inside a `faq` `expr`
        # body), so that ratio re-emits as `1/N` in every binding. Non-integral
        # floats stay `NumExpr`.
        i = _as_int64(data)
        return i === nothing ? NumExpr(Float64(data)) : IntExpr(i)
    elseif isa(data, String)
        return VarExpr(data)
    elseif _raw_haskey(data, "op")
        # Any dict-like carrier (the post-wire native tree, or a JSON3.Object
        # fed directly) holding an `op` key — one shared parse path.
        return _parse_op_dict_memoized(data)
    else
        throw(ParseError("Invalid expression format: expected number, string, or object with 'op' field. Got: $(typeof(data))"))
    end
end

# NOTE: the `OpExpr` field ↔ wire-key contract (`OPEXPR_WIRE_KEYS`) and the
# field-spec table it derives from (`OPEXPR_FIELD_TABLE`) live in types.jl,
# next to the struct. The field-extraction core of `_parse_op_dict` below
# (`_parse_op_optional_fields`) is GENERATED from that table.

"""
    _PARSE_EXPR_MEMO_KEY

`task_local_storage` key under which [`_lower_and_coerce`](@ref) installs an
`IdDict{Any,ASTExpr}` identity memo for the duration of one `coerce_esm_file`
call. Template expansion builds STRUCTURALLY SHARED raw trees (`_substitute`
splices bindings and bodies by reference), so the same raw node object can hang
under many parents; parsing is a pure function of the node, and the memo makes
the typed IR mirror that sharing — each unique raw node coerces to ONE `OpExpr`,
keeping coercion linear in unique nodes instead of exponential in paths. The
key is the raw dict itself (`coerce_esm_file`'s entry normalization is
sharing-preserving, so the DAG's identity structure survives into the memo).
Outside an active memo scope, parsing is unmemoized — a caller that
hand-mutates raw dicts between `expression_from_json` calls sees unchanged
behavior.
"""
const _PARSE_EXPR_MEMO_KEY = :_earthsci_ast_parse_expression_memo

function _parse_op_dict_memoized(data)
    memo = get(
        task_local_storage(), _PARSE_EXPR_MEMO_KEY,
        nothing
    )::Union{Nothing, IdDict{Any, ASTExpr}}
    memo === nothing && return _parse_op_dict(data)
    r = get(memo, data, nothing)
    r === nothing || return r
    res = _parse_op_dict(data)
    memo[data] = res
    return res
end

# ── Generated optional-field extraction ─────────────────────────────────────
#
# One extraction statement per `OPEXPR_FIELD_TABLE` row (struct-field order),
# derived from the row's `kind` (expression-bearing shapes) or `parse` recipe
# tag (scalar coercions). Field lookup goes through `_raw_get` (string-keyed,
# null-as-absent), so each wire key is named exactly once — in the table.
# Op-conditional structural validation is spliced in at fixed positions
# (integral bounds directly after `upper`), which fixes the ParseError
# precedence on a node with several invalid fields.
function _parse_op_field_stmt(f::Symbol, spec)::Union{Expr, Nothing}
    (f === :op || f === :args) && return nothing        # structural, hand-parsed
    spec.kind === :internal && return nothing           # never on the wire
    w = String(spec.wire)
    rhs = if spec.kind === :expr
        :(_maybe(expression_from_json, _raw_get(data, $w, nothing)))
    elseif spec.kind === :expr_vec
        :(
            let raw = _raw_get(data, $w, nothing)
                raw === nothing ? nothing :
                    Vector{ASTExpr}([expression_from_json(v) for v in raw])
            end
        )
    elseif spec.kind === :expr_map
        :(
            let raw = _raw_get(data, $w, nothing)
                raw === nothing ? nothing :
                    Dict{String, ASTExpr}(
                        string(k) => expression_from_json(v)
                        for (k, v) in pairs(raw)
                    )
            end
        )
    elseif spec.kind === :ranges
        :(_coerce_ranges(_raw_get(data, $w, nothing)))
    elseif spec.kind === :join
        :(_coerce_join(_raw_get(data, $w, nothing)))
    elseif spec.parse === :string
        :(_opt_string(data, $w))
    elseif spec.parse === :int
        :(_opt_int(data, $w))
    elseif spec.parse === :int_vec
        :(
            let raw = _raw_get(data, $w, nothing)
                raw === nothing ? nothing : Vector{Int}([Int(x) for x in raw])
            end
        )
    elseif spec.parse === :bool
        :(_maybe(Bool, _raw_get(data, $w, nothing)))
    elseif spec.parse === :json
        # JSON-typed value (number, integer, or nested array); convert JSON3
        # containers to native Julia ones so downstream code doesn't have to
        # special-case JSON3 types.
        :(_maybe(_to_native_json, _raw_get(data, $w, nothing)))
    elseif spec.parse === :output_idx
        :(_coerce_output_idx(_raw_get(data, $w, nothing)))
    elseif spec.parse === :regions
        :(_coerce_regions(_raw_get(data, $w, nothing)))
    elseif spec.parse === :shape
        :(_coerce_shape(_raw_get(data, $w, nothing)))
    elseif spec.parse === :attrs
        :(_coerce_attrs(_raw_get(data, $w, nothing)))
    else
        error(
            "OPEXPR_FIELD_TABLE row $(f) has no parse recipe " *
                "(kind=$(spec.kind), parse=$(spec.parse))"
        )
    end
    return :($f = $rhs)
end

# Per-op structural validators spliced in AFTER the named field's extraction.
const _PARSE_OP_VALIDATOR_AFTER = Dict{Symbol, Expr}(
    :upper => :(op == "integral" && _validate_integral_op(int_var, lower, upper)),
)

@eval function _parse_op_optional_fields(data, op::String, args::Vector{ASTExpr})
    $(
        (
            stmt for (f, spec) in pairs(OPEXPR_FIELD_TABLE)
                for stmt in (
                    _parse_op_field_stmt(f, spec),
                    get(_PARSE_OP_VALIDATOR_AFTER, f, nothing),
                )
                if stmt !== nothing
        )...
    )
    return (;
        $(
            (
                f for (f, spec) in pairs(OPEXPR_FIELD_TABLE)
                    if f !== :op && f !== :args && spec.kind !== :internal
            )...
        ),
    )
end

# Shared implementation for every dict-like carrier. The optional-field
# portion is generated from `OPEXPR_FIELD_TABLE` (see
# `_parse_op_optional_fields` above); only the structural `op`/`args` handling
# and op-existence rejections live here.
function _parse_op_dict(data)
    op = string(_raw_get(data, "op", nothing))
    if op in _REMOVED_OPS
        # The wire boundary (`_prepare_document_ops!`) rejects the whole
        # document first, with the node's path; this guards callers that parse
        # a node directly.
        throw(
            ParseError(
                "[E_REMOVED_OP] `\"op\": \"$(op)\"` was $(_removed_op_hint(op)).";
                code = ERROR_CODES.REMOVED_OP
            )
        )
    end
    if op == "call"
        # `call` is not an operator of the format (esm-spec §9 closure); a file
        # needs AST ops or `esm:std/*.esm` expression templates instead.
        throw(
            ParseError(
                "`call` op is not valid in v0.3.0+ (removed by esm-spec §9 closure). " *
                    "Migrate to AST ops or `esm:std/*.esm` expression templates."
            )
        )
    end
    # `apply_expression_template` is normally expanded by
    # `lower_expression_templates` before any tree reaches `expression_from_json`
    # (esm-spec §9.6). When a caller feeds an unexpanded node directly — as the
    # cross-language display conformance producer does — it is built into an
    # `OpExpr` carrying `name` + `bindings` so the pretty-printer can render it
    # per RENDERING_CONTRACT.md (matching the other four bindings), rather than
    # throwing. The load pipeline still lowers templates ahead of typed parsing,
    # so a loaded document never carries an `apply_expression_template` node.
    args_data = _raw_get(data, "args", ())
    args = Vector{ASTExpr}([expression_from_json(arg) for arg in args_data])
    flds = _parse_op_optional_fields(data, op, args)
    # The root of an expansion a load made of raw JSON at a mount carries its
    # template's name under `_TEMPLATE_ORIGIN_WIRE_KEY` (load provenance, never
    # authored, never serialized): it becomes `template_origin`, so the
    # elementwise lift sees an application (esm-spec §9.6.11).
    origin = data isa AbstractDict ? get(data, _TEMPLATE_ORIGIN_WIRE_KEY, nothing) : nothing
    origin isa AbstractString && return OpExpr(op, args; flds..., template_origin = String(origin))
    return OpExpr(op, args; flds...)
end

# ── Per-op validators for `_parse_op_dict` ──────────────────────────────────
#
# Ops with structural field requirements each get their own checker so the
# generic field-extraction skeleton in `_parse_op_dict` reads at one level.
# The error messages are part of the load-rejection contract.

# `integral`: requires the integration variable name (wire key `var`) and both
# bound expressions.
function _validate_integral_op(int_var, lower, upper)
    if int_var === nothing
        throw(ParseError("`integral` op requires `var` field (integration variable name)"))
    end
    if lower === nothing
        throw(ParseError("`integral` op requires `lower` field"))
    end
    if upper === nothing
        throw(ParseError("`integral` op requires `upper` field"))
    end
    return nothing
end

function _coerce_output_idx(data)
    data === nothing && return nothing
    out = Vector{Any}(undef, length(data))
    for (i, entry) in enumerate(data)
        out[i] = isa(entry, Number) ? Int(entry) : string(entry)
    end
    return out
end

# ========================================
# Uniform field access for JSON-carrier values
# ========================================
#
# Post-wire documents are the ONE normalized carrier (string-keyed native
# dicts, `_to_ordered`); a `JSON3.Object` fed directly to a coercer resolves
# string keys natively, so plain string-keyed `get`/`haskey` covers both.
# Optional-field coercion shorthands: fetch `key` (`_raw_get`, json_walk.jl:
# absent and null both read as `nothing`), propagate `nothing`, otherwise
# convert.
_opt_string(data, key::String) = _maybe(string, _raw_get(data, key, nothing))
_opt_float(data, key::String) = _maybe(Float64, _raw_get(data, key, nothing))
_opt_int(data, key::String) = _maybe(Int, _raw_get(data, key, nothing))

function _coerce_ranges(data)
    data === nothing && return nothing
    result = Dict{String, Any}()
    for (k, v) in pairs(data)
        sv = string(k)
        if v isa AbstractVector
            # Dense integer tuple [lo, hi] / [lo, step, hi] (as today).
            if all(x -> x isa Number, v)
                result[sv] = Any[Int(x) for x in v]
            else
                result[sv] = Any[x isa Number ? Int(x) : expression_from_json(x) for x in v]
            end
        else
            # Index-set reference (RFC semiring-faq-unified-ir §5.2):
            # { "from": <index_sets key>, "of"?: [parent index names] }.
            from_val = _raw_get(v, "from", nothing)
            from_val === nothing && throw(
                ParseError(
                    "ranges entry `$sv` must be a dense array [lo,hi]/[lo,step,hi] " *
                        "or an index-set reference object with a `from` key"
                )
            )
            of_raw = _raw_get(v, "of", nothing)
            of_names = of_raw === nothing ? String[] : String[string(x) for x in of_raw]
            result[sv] = IndexSetRef(string(from_val); of = of_names)
        end
    end
    return result
end

# Coerce the wire `join` array (M2, RFC semiring-faq-unified-ir §5.3) into the
# parsed clause form. Each wire clause is a `{ "on": [[left, right], …] }`
# object; the result is a `Vector{Any}` whose entries are
# `Vector{Tuple{String,String}}` — one list of key-column pairs per clause.
# Only STRUCTURAL validation lives here (≥1 pair, exactly length-2 pairs);
# key-type / symbol-resolution checks are deferred to build time so they can
# consult the index-set registry (`_resolve_join_gates`).
# Structural check of an overlap-clause env-factor arity (1 rings / 2 points /
# 4 rectangle bounds); the factor→range resolution is deferred to build time.
_valid_env_arity(k::Int) = (k == 1 || k == 2 || k == 4)

# Coerce a `{ "overlap": { "src_env": [...], "tgt_env": [...], "eps": 0.0 } }`
# join clause into the parsed `_OverlapJoinSpec`. Only STRUCTURAL
# validation here (present env arrays, legal arity); factor / range resolution
# runs at build time against the const-array registry + document index sets.
function _coerce_overlap_clause(ov)
    src_raw = _raw_get(ov, "src_env", nothing)
    tgt_raw = _raw_get(ov, "tgt_env", nothing)
    (src_raw === nothing || tgt_raw === nothing) && throw(
        ParseError(
            "join `overlap` clause requires both `src_env` and `tgt_env` arrays of " *
                "envelope factor names"
        )
    )
    src_env = String[string(x) for x in src_raw]
    tgt_env = String[string(x) for x in tgt_raw]
    _valid_env_arity(length(src_env)) || throw(
        ParseError(
            "join `overlap` `src_env` must name 1 (rings), 2 (point [x,y]), or 4 " *
                "(rect [xmin,ymin,xmax,ymax]) factors; got $(length(src_env))"
        )
    )
    _valid_env_arity(length(tgt_env)) || throw(
        ParseError(
            "join `overlap` `tgt_env` must name 1 (rings), 2 (point [x,y]), or 4 " *
                "(rect [xmin,ymin,xmax,ymax]) factors; got $(length(tgt_env))"
        )
    )
    eps_raw = _raw_get(ov, "eps", nothing)
    eps = eps_raw === nothing ? 0.0 : Float64(eps_raw)
    return _OverlapJoinSpec(src_env, tgt_env, eps, eps_raw !== nothing)
end

function _coerce_join(data)
    data === nothing && return nothing
    clauses = Vector{Any}()
    for clause in data
        ov_raw = _raw_get(clause, "overlap", nothing)
        if ov_raw !== nothing
            push!(clauses, _coerce_overlap_clause(ov_raw))
            continue
        end
        on_raw = _raw_get(clause, "on", nothing)
        on_raw === nothing && throw(
            ParseError(
                "join clause requires an `on` array of [left, right] key-column " *
                    "pairs, or an `overlap` object with `src_env`/`tgt_env` envelope " *
                    "factors (RFC semiring-faq-unified-ir §5.3)"
            )
        )
        pairs_vec = Vector{Tuple{String, String}}()
        for pair in on_raw
            length(pair) == 2 || throw(
                ParseError(
                    "join `on` entry must be a 2-element [left, right] pair, got " *
                        "$(length(pair)) element(s) (RFC §5.3)"
                )
            )
            push!(pairs_vec, (string(pair[1]), string(pair[2])))
        end
        isempty(pairs_vec) && throw(
            ParseError(
                "join clause `on` requires at least one key-column pair (RFC §5.3)"
            )
        )
        # `syms` names the two RANGE SYMBOLS the clause's pairs are read at
        # (CONFORMANCE_SPEC §5.5.8) — the self-join disambiguation. Only its
        # SHAPE is checked here; whether the names are ranges of the node is a
        # build-time question, resolved with the rest of the clause.
        syms_raw = _raw_get(clause, "syms", nothing)
        syms = nothing
        if syms_raw !== nothing
            length(syms_raw) == 2 || throw(
                ParseError(
                    "join `syms` must be a 2-element [left, right] pair of range " *
                        "symbols, got \$(length(syms_raw)) element(s) " *
                        "(CONFORMANCE_SPEC §5.5.8)"
                )
            )
            syms = (string(syms_raw[1]), string(syms_raw[2]))
        end
        push!(clauses, _OnJoinSpec(pairs_vec, syms))
    end
    return clauses
end

# One `regions[*][*][*]` bound. Concrete integers stay `Int` (the overwhelmingly
# common case — metaparameters are folded on the RAW tree before typed coercion,
# esm-spec §9.7.6). Anything else is a `MetaparameterExpression` the schema
# admits (a symbolic dimension name, or an arithmetic node over one) and is kept
# as an `ASTExpr`, so a still-open bound survives the typed round-trip instead of
# crashing in `Int(x)`.
_coerce_region_bound(x) =
    (x isa Integer && !(x isa Bool)) ? Int(x) :
    (x isa Real && isinteger(x)) ? Int(x) :
    expression_from_json(x)

function _coerce_regions(data)
    data === nothing && return nothing
    return Vector{Vector{Vector{Any}}}(
        [
            Vector{Vector{Any}}(
                [
                    Vector{Any}([_coerce_region_bound(x) for x in ax])
                        for ax in region
                ]
            )
                for region in data
        ]
    )
end

# `attrs` — the OPEN rewrite-target op's named scalar attributes (esm-spec
# §4.2). Distinct from the `:json` recipe only in that the schema pins the top
# level to an OBJECT: a non-object is a ParseError here rather than a `TypeError`
# from the struct field's `Union{Dict{String,Any},Nothing}` conversion. Values
# are converted to native containers so downstream code never sees JSON3 types,
# exactly as `_to_native_json` does for `value`.
function _coerce_attrs(data)
    data === nothing && return nothing
    # `JSON3.Object <: AbstractDict`, so this covers both dict-like carriers.
    isa(data, AbstractDict) ||
        throw(
        ParseError(
            "`attrs` must be a JSON object of named scalar " *
                "attributes (esm-spec §4.2), got $(typeof(data))"
        )
    )
    return Dict{String, Any}(string(k) => _to_native_json(v) for (k, v) in pairs(data))
end

function _coerce_shape(data)
    data === nothing && return nothing
    out = Vector{Any}(undef, length(data))
    for (i, entry) in enumerate(data)
        out[i] = isa(entry, Number) ? Int(entry) : string(entry)
    end
    return out
end

"""
    coerce_model_variable_type(data::String) -> ModelVariableType

Coerce a string into the ModelVariableType enum. Accepts each member's wire
spelling and its legacy aliases, per [`MODEL_VARIABLE_TYPE_TABLE`](@ref)
(types.jl — the derived `_MODEL_VARIABLE_TYPE_FROM_STRING` lookup).
"""
function coerce_model_variable_type(data::String)::ModelVariableType
    t = get(_MODEL_VARIABLE_TYPE_FROM_STRING, data, nothing)
    t === nothing && throw(ParseError("Invalid ModelVariableType: $data"))
    return t
end

"""
    coerce_trigger(data) -> DiscreteEventTrigger

Coerce JSON data into a DiscreteEventTrigger based on the schema discriminator.

Accepts Dict or JSON3.Object. Uses the "type" field (preferred, per current schema)
with fallback to field-based discrimination for backward compatibility.

Schema-defined variants:
- {"type": "condition", "expression": ...} -> ConditionTrigger
- {"type": "periodic", "interval": ..., "initial_offset": ...} -> PeriodicTrigger
- {"type": "preset_times", "times": [...]} -> PresetTimesTrigger
"""
function coerce_trigger(data)::DiscreteEventTrigger
    trigger_type_str = _opt_string(data, "type")

    if trigger_type_str == "condition" || (trigger_type_str === nothing && _raw_haskey(data, "expression"))
        expression = _raw_get(data, "expression", nothing)
        if expression === nothing
            throw(ParseError("Condition trigger requires 'expression' field"))
        end
        return ConditionTrigger(expression_from_json(expression))
    elseif trigger_type_str == "periodic" || (trigger_type_str === nothing && (_raw_haskey(data, "interval") || _raw_haskey(data, "period")))
        interval_val = _raw_get(data, "interval", nothing)
        if interval_val === nothing
            interval_val = _raw_get(data, "period", nothing)
        end
        if interval_val === nothing
            throw(ParseError("Periodic trigger requires 'interval' field"))
        end
        period = Float64(interval_val)
        phase_val = _raw_get(data, "initial_offset", nothing)
        if phase_val === nothing
            phase_val = _raw_get(data, "phase", nothing)
        end
        return PeriodicTrigger(period, phase = phase_val)
    elseif trigger_type_str == "preset_times" || (trigger_type_str === nothing && _raw_haskey(data, "times"))
        times_val = _raw_get(data, "times", nothing)
        if times_val === nothing
            throw(ParseError("Preset times trigger requires 'times' field"))
        end
        times = [Float64(t) for t in times_val]
        return PresetTimesTrigger(times)
    else
        throw(ParseError("Invalid DiscreteEventTrigger: unknown type '$(trigger_type_str)' and no recognized discriminator field"))
    end
end

"""
    coerce_esm_file(data::Any; document_base=nothing) -> EsmFile

Coerce raw JSON data into properly typed EsmFile with custom union type handling.
`document_base` is the absolute directory the document was read from, recorded
beside it for [`solver_external_location`](@ref) (esm-spec §2.2.6).

Accepts ANY dict-like JSON carrier — a `JSON3.Object` straight off the wire,
the load pipeline's already-native tree, or a `Dict` assembled in Julia code
(string- or symbol-keyed) — and normalizes it ONCE, here at the boundary, into
the single post-wire carrier (`_to_ordered`: string-keyed `OrderedDict` tree),
so every nested coercer speaks plain string-keyed `get`. The normalization is
sharing-preserving, so the structural sharing template expansion builds
carries through into the `expression_from_json` identity memo. Callers never need
a `JSON3.read(JSON3.write(doc))` type-launder. Coercion only reads the tree, so
inline number arrays are shared with `data` rather than copied
(`_to_ordered_shared`).
"""
function coerce_esm_file(
        data::Any;
        document_base::Union{Nothing, AbstractString} = nothing
    )::EsmFile
    # A typed constructor refuses a bad value with an `ArgumentError`, which is
    # right for a caller building it in Julia; reached from a document, the
    # same refusal is about the document, so it leaves as a `ParseError`.
    try
        return _coerce_esm_file(data, document_base)
    catch e
        e isa ArgumentError || rethrow()
        throw(ParseError(e.msg, e))
    end
end

function _coerce_esm_file(data::Any, document_base::Union{Nothing, AbstractString})::EsmFile
    data = _to_ordered_shared(data)

    # Extract required fields
    esm_raw = _raw_get(data, "esm", nothing)
    esm_raw === nothing && throw(ParseError("ESM document requires an `esm` version field"))
    esm = string(esm_raw)
    metadata_raw = _raw_get(data, "metadata", nothing)
    metadata_raw === nothing && throw(ParseError("ESM document requires a `metadata` object"))
    metadata = coerce_metadata(metadata_raw)

    # Optional fields: `_raw_get` reports a JSON `null` as absent.
    models = _maybe(_raw_get(data, "models", nothing)) do m
        OrderedDict{String, Model}(string(k) => coerce_model(v) for (k, v) in pairs(m))
    end

    reaction_systems = _maybe(_raw_get(data, "reaction_systems", nothing)) do rs
        OrderedDict{String, ReactionSystem}(
            string(k) => coerce_reaction_system(v)
                for (k, v) in pairs(rs)
        )
    end

    data_sources = _maybe(_raw_get(data, "data_sources", nothing)) do dl
        Dict{String, DataSource}(string(k) => coerce_data_source(v) for (k, v) in pairs(dl))
    end

    if _raw_get(data, "registered_functions", nothing) !== nothing
        throw(
            ParseError(
                "`registered_functions` block is not valid in v0.3.0+ " *
                    "(removed by esm-spec §9 closure). Use AST ops or " *
                    "`esm:std/*.esm` expression templates."
            )
        )
    end

    coupling_raw = _raw_get(data, "coupling", nothing)
    coupling = coupling_raw === nothing ? CouplingEntry[] :
        CouplingEntry[coerce_coupling_entry(c) for c in coupling_raw]

    # A single top-level `domain` object: the one temporal domain shared by
    # every component (esm-spec §11).
    domain = _maybe(coerce_domain, _raw_get(data, "domain", nothing))

    # File-local enum mappings (esm-spec §9.3). Used by the `enum` AST op to
    # carry symbolic categorical labels in the source while the on-disk file
    # is loaded; `enum` ops are then lowered to integer `const` nodes
    # immediately after parsing so the in-memory tree never carries strings.
    enums = _maybe(coerce_enums, _raw_get(data, "enums", nothing))


    # Document-scoped index-set registry (RFC semiring-faq-unified-ir §5.2;
    # esm-spec v0.8.0). A single top-level `index_sets` object — sibling of
    # `models`/`domain`, shared by every component — that unifies ESM grid dims
    # and ESI categorical dims. `ranges[*]` `{from: <name>}` references, array
    # `shape`s, and derived-set `from_faq` edges resolve against it. Empty when
    # the document declares none.
    index_sets = OrderedDict{String, IndexSet}()
    index_sets_raw = _raw_get(data, "index_sets", nothing)
    if index_sets_raw !== nothing
        for (k, v) in pairs(index_sets_raw)
            index_sets[string(k)] = coerce_index_set(v)
        end
    end

    # NOTE: the top-level `expression_templates` / `metaparameters` DECLARATIONS
    # are not read here. By this point the lowering has rewritten and stripped
    # them; `_lower_and_coerce` snapshots them verbatim off the RAW document and
    # attaches them to the returned `EsmFile` (§9.6.4 rule 5).
    #
    # PER-COMPONENT `expression_templates` blocks are a different matter: on the
    # ordinary load path `_lower_and_coerce` strips them before coercion (and
    # attaches the materialized registries itself), so seeing one here means the
    # document came through a path that carries surviving references WITHOUT the
    # load pipeline — a reload of a `flattened_to_esm` export (esm-spec §9.6.4
    # Option B), or a direct `coerce_esm_file`/`_build_evaluator(dict)` call on a
    # lowered 0.9.0 emit.
    # Capture them as `component_templates` so `apply_expression_template` nodes
    # in the coerced expressions stay resolvable; without this the references
    # compile into opaque op nodes that only fail at RHS evaluation time.
    component_templates = nothing
    let ct = OrderedDict{String, Any}()
        for (compkind, comps_raw) in (
                ("models", _raw_get(data, "models", nothing)),
                ("reaction_systems", _raw_get(data, "reaction_systems", nothing)),
            )
            comps_raw === nothing && continue
            for (k, v) in pairs(comps_raw)
                tpl = _raw_get(v, "operators", nothing)
                tpl === nothing && continue
                # Native String-keyed form: the registry is probed with String
                # names (`haskey(reg, name)`) and read with `_raw_get`, and the
                # load path's `_materialize_components!` blocks are native too.
                ct["$compkind.$(string(k))"] = _to_native_json(tpl)
            end
        end
        isempty(ct) || (component_templates = ct)
    end
    # Coupling-library formal roles (esm-spec §10.9), kept VERBATIM. Read here
    # rather than snapshotted in `_lower_and_coerce` like `metaparameters`
    # because no lowering pass rewrites it — and reading it at the coercion
    # boundary means the direct `coerce_esm_file` entry point keeps it too.
    coupling_roles = _maybe(_to_native_json, _raw_get(data, "coupling_roles", nothing))

    # Document-scoped solver hints (esm-spec §2.2), read at the coercion
    # boundary for the same reason as `coupling_roles` above: no lowering pass
    # rewrites the block, and reading it here means the direct
    # `coerce_esm_file` entry point keeps it too. Typed rather than verbatim
    # because `solve` READS it (§2.2.2 resolution order).
    solver = coerce_solver(_raw_get(data, "solver", nothing))

    file = EsmFile(
        esm, metadata,
        models = models,
        reaction_systems = reaction_systems,
        data_sources = data_sources,
        coupling = coupling,
        domain = domain,
        enums = enums,
        index_sets = index_sets,
        component_templates = component_templates,
        coupling_roles = coupling_roles,
        solver = solver,
        document_base = document_base === nothing ? nothing : String(document_base)
    )
    # Lower every `enum` op to a `const` integer using the file-local map.
    # This runs once at load time so downstream consumers (evaluators,
    # canonicalize, codegen) never see enum strings in expression trees.
    lower_enums!(file)
    return file
end

"""
    coerce_solver(data) -> Union{Solver,Nothing}

Coerce the top-level `solver` block (esm-spec §2.2) into the typed
[`Solver`](@ref) carried on [`EsmFile`](@ref), or `nothing` when the document
declares none.

Field VALUES are not re-validated here — the schema already pins the two enums,
the two positive tolerances, the non-empty `external` string and the shape of
`time_span`, and this runs after schema validation. What it
does is keep absence distinguishable from any default: a missing key stays
`nothing` rather than acquiring a value the author never wrote.
"""
function coerce_solver(data)
    data === nothing && return nothing
    data isa AbstractDict || return nothing
    _f(k) = _raw_get(data, k)  # 2-arity; absent reports as `nothing`
    _num(v) = v === nothing ? nothing : Float64(v)
    _str(v) = v === nothing ? nothing : String(v)
    # A bound keeps its authored form (esm-spec §2.2.7): a timestamp stays the
    # string and an integer stays an integer, so `emit` writes back what was
    # read (`0`, not `0.0`). An integer past Int64 has no exact home and is
    # carried as its binary64 value.
    _bound(v) = v isa AbstractString ? String(v) :
        v isa Integer ? something(_as_int64(v), Float64(v)) : Float64(v)
    span = _f("time_span")
    s = Solver(
        stiffness = _str(_f("stiffness")),
        abstol = _num(_f("abstol")),
        reltol = _num(_f("reltol")),
        splitting = _str(_f("splitting")),
        external = _str(_f("external")),
        time_span = span === nothing ? nothing :
            SolverTimeSpan(
                _bound(_raw_get(span, "start")),
                _bound(_raw_get(span, "end"))
            )
    )
    # §2.2: an EMPTY block normalizes to absence at load. `{}` is legal and
    # means what omitting the block means, so the typed document never holds a
    # block with nothing set — which is what keeps the five bindings from
    # disagreeing about whether `{}` survives `parse -> emit`. A block holding
    # only `external`, or only `time_span`, is not empty.
    all(
        isnothing, (
            s.stiffness, s.abstol, s.reltol, s.splitting, s.external,
            s.time_span,
        )
    ) &&
        return nothing
    return s
end

"""
    coerce_enums(data) -> Dict{String,Dict{String,Int}}

Coerce the top-level `enums` JSON block into the typed map carried on
[`EsmFile`](@ref). Validates per esm-spec §9.3:

- enum names are non-empty strings
- symbolic keys are non-empty strings
- values are integers — ANY integer, negative, zero or positive: an enum
  member is a categorical code, not a 1-based position (CONFORMANCE_SPEC,
  "An `enums` Member Is a Code, Not a Position")
- within a single enum, integer values are unique — an
  [`EnumLoweringError`](@ref) with code `enum_duplicate_value`

Throws [`ParseError`](@ref) on any other violation.
"""
function coerce_enums(data)::Dict{String, Dict{String, Int}}
    out = Dict{String, Dict{String, Int}}()
    for (enum_name_raw, mapping_raw) in pairs(data)
        enum_name = string(enum_name_raw)
        if isempty(enum_name)
            throw(ParseError("enums: enum name must be non-empty"))
        end
        if !(mapping_raw isa AbstractDict)
            throw(ParseError("enums.$(enum_name): mapping must be a JSON object"))
        end
        mapping = Dict{String, Int}()
        for (sym_raw, int_raw) in pairs(mapping_raw)
            sym = string(sym_raw)
            if isempty(sym)
                throw(ParseError("enums.$(enum_name): symbol name must be non-empty"))
            end
            if !(int_raw isa Integer) || int_raw isa Bool
                throw(ParseError("enums.$(enum_name).$(sym): value must be an integer (got $(typeof(int_raw)))"))
            end
            mapping[sym] = Int(int_raw)
        end
        out[enum_name] = mapping
    end
    _check_enum_values_unique(out)
    return out
end

"""
    _coerce_subsystem_entry(name::String, v) -> Union{Model,SubsystemRef}

Coerce one `subsystems` entry (schema §4.7, oneOf [Model, SubsystemRef]): a
child Model, or a `{"ref": "..."}` reference. Inline Model entries are coerced
recursively; ref entries become a `SubsystemRef` placeholder that
`resolve_subsystem_refs!` replaces in place with the loaded component. `name`
is the subsystem key, used only in metaparameter-binding diagnostics.

A data source is an ingest registry entry, not a component, so it never
appears here (esm-spec §8).
"""
function _coerce_subsystem_entry(name::String, v)
    if _raw_get(v, "ref", nothing) !== nothing
        # Optional `bindings` closes the referenced document's open
        # metaparameters at this edge (esm-spec §9.7.6 binding site 3). A
        # binding VALUE may be a metaparameter EXPRESSION — an integer, a
        # name in the MOUNTING document's metaparameter scope, or a
        # `{op:+|-|*|/, args}` tree over the same (e.g. `NTGT = NX*NY`),
        # which import renaming (name→name) cannot express. A subsystem ref
        # is resolved as a complete document folded to concrete integers AT
        # the mount, so — unlike an import edge — each binding value folds
        # IMMEDIATELY against the mounting document's already-closed
        # metaparameter environment (the mount closes its own
        # metaparameters before its refs resolve). That environment has
        # already been substituted into these values by
        # `resolve_template_machinery` (which closes this document's
        # metaparameters before coercion), so folding here collapses the
        # expression to a concrete int; a value naming a metaparameter the
        # document does not declare survives the substitution and fails
        # loudly with `template_import_unknown_name`.
        bindings = Dict{String, Int}()
        bindings_raw = _raw_get(v, "bindings", nothing)
        if bindings_raw !== nothing
            for (bk, bv) in pairs(bindings_raw)
                bctx = "subsystems.$(name): binding '$(string(bk))'"
                expr = require_meta_expr(_to_native_json(bv), bctx)
                bindings[string(bk)] =
                    Int(eval_meta_expr(expr, Dict{String, Int64}(), bctx))
            end
        end
        # Optional `expression_template_imports` injects a discretization
        # into the REFERENCED component's own scope (esm-spec §9.7.10
        # form A). Kept as raw §9.7.2 entries; the mount pipeline
        # (`_resolve_mount_edge`) threads them into the referenced document's load and the
        # §9.6.3 fixpoint consumes them before the mounted form is set.
        injected = Any[]
        imports_raw = _raw_get(v, "operator_imports", nothing)
        if imports_raw !== nothing
            injected = Any[_to_native_json(e) for e in imports_raw]
        end
        # Optional `index_set_rename` translates the MOUNTED document's index-set
        # names into this document's vocabulary at load (esm-spec §4.7
        # "Mount-edge index-set renaming"). Kept as a raw name→name map;
        # the mount pipeline (`_resolve_mount_edge`) threads it into the referenced document's load
        # and applies it once that document has resolved in its own scope, so it
        # is consumed at the mount and does not survive `parse → emit`.
        iset_rename = nothing
        rename_raw = _raw_get(v, "index_set_rename", nothing)
        if rename_raw !== nothing
            # A malformed (non-object) map is `template_import_rename_invalid`.
            iset_rename = _is_object(rename_raw) ?
                OrderedDict{String, String}(
                    string(rk) => string(rv) for (rk, rv) in pairs(rename_raw)
                ) :
                OrderedDict{String, String}()
            _is_object(rename_raw) || throw(
                ExpressionTemplateError(
                    ERROR_CODES.TEMPLATE_IMPORT_RENAME_INVALID,
                    "subsystems.$(name): `index_set_rename` must be an object mapping " *
                        "index-set names to names (esm-spec §4.7)"
                )
            )
        end
        # Optional `url_substitutions` binds the mounted document's data-source
        # placeholders (esm-spec §4.7 "Binding a data source's location at the
        # mount"). Kept raw; `apply_mount_url_substitutions!` checks its shape
        # at the edge.
        url_subs = _raw_get(v, "url_substitutions", nothing)
        return SubsystemRef(
            string(v["ref"]),
            Dict{String, Int}(bindings), Any[e for e in injected],
            iset_rename, url_subs === nothing ? nothing : _to_native_json(url_subs)
        )
    else
        return coerce_model(v)
    end
end


"""
    coerce_reaction_system(data::Any) -> ReactionSystem

Coerce JSON data into ReactionSystem type.
"""
function coerce_reaction_system(data::Any)::ReactionSystem
    # Convert species dict to vector - species are now keyed by name
    species = [coerce_species(string(k), v) for (k, v) in pairs(data["species"])]
    reactions = [coerce_reaction(r) for r in data["reactions"]]
    # Convert parameters dict to vector - parameters are now keyed by name
    parameters = haskey(data, "parameters") ?
        [coerce_parameter(string(k), v) for (k, v) in pairs(data["parameters"])] : Parameter[]

    # Inline tests / tolerance — same shape as on Model.
    tolerance = _maybe(coerce_tolerance, _raw_get(data, "tolerance", nothing))
    tests_raw = _raw_get(data, "tests", nothing)
    tests = tests_raw !== nothing ?
        EarthSciAST.InlineTest[coerce_test(t) for t in tests_raw] :
        EarthSciAST.InlineTest[]

    # The rest of the schema's `ReactionSystem`. `analyses` stays raw (nothing
    # here runs one); the events and constraint equations get the same typed
    # forms they have on a `Model`.
    _raw_vec(key) = _raw_get(data, key, ())
    constraint_equations = Equation[coerce_equation(x) for x in _raw_vec("constraint_equations")]
    discrete_events = DiscreteEvent[coerce_discrete_event(x) for x in _raw_vec("discrete_events")]
    continuous_events = ContinuousEvent[coerce_continuous_event(x) for x in _raw_vec("continuous_events")]
    analyses = Any[_to_native_json(x) for x in _raw_vec("analyses")]
    reference = _maybe(coerce_reference, _raw_get(data, "reference", nothing))
    subsystems = _coerce_reaction_system_subsystems(_raw_get(data, "subsystems", nothing))

    return ReactionSystem(
        species, reactions; parameters = parameters,
        constraint_equations = constraint_equations,
        discrete_events = discrete_events,
        continuous_events = continuous_events,
        subsystems = subsystems,
        tolerance = tolerance, tests = tests,
        analyses = analyses, reference = reference
    )
end

"""
    _coerce_reaction_system_subsystems(raw) -> OrderedDict{String,ReactionSystem}

Coerce a reaction system's `subsystems` block (schema §4.7: each entry is
`oneOf [ReactionSystem, SubsystemRef]`). Recurses through
[`coerce_reaction_system`](@ref), so a hierarchy of any depth survives.

The `{"ref": …}` arm is REJECTED rather than skipped. `ReactionSystem.subsystems`
is typed `OrderedDict{String,ReactionSystem}` and has no unresolved-ref arm the
way `Model.subsystems` does (`SubsystemNode`), and `resolve_subsystem_refs!`
walks models only — so accepting one could only mean silently dropping it.
"""
function _coerce_reaction_system_subsystems(raw)::OrderedDict{String, ReactionSystem}
    out = OrderedDict{String, ReactionSystem}()
    raw === nothing && return out
    for (k, v) in pairs(raw)
        name = string(k)
        if v isa AbstractDict && _raw_haskey(v, "ref")
            throw(
                ParseError(
                    "reaction system subsystem '$(name)' is a `{ref}` include, which " *
                        "is not supported: a reaction-system subsystem must be inline " *
                        "(esm-schema.json ReactionSystem.subsystems oneOf arm 1)";
                    path = "/subsystems/$(name)/ref"
                )
            )
        end
        out[name] = coerce_reaction_system(v)
    end
    return out
end


"""
    coerce_reaction(data::Any) -> Reaction

Coerce JSON data into Reaction type.
"""
function coerce_reaction(data::Any)::Reaction
    id = string(data["id"])
    name = _maybe(string, get(data, "name", nothing))

    # Substrates / products can be null (source / sink reactions).
    # Stoichiometry may be integer or fractional per v0.2.x schema — the
    # StoichiometryEntry constructor enforces finite positivity.
    stoich_entries(key) = _maybe(get(data, key, nothing)) do entries
        [
            StoichiometryEntry(string(entry["species"]), entry["stoichiometry"])
                for entry in entries
        ]
    end
    substrates = stoich_entries("substrates")
    products = stoich_entries("products")

    rate = expression_from_json(data["rate"])

    reference = _maybe(coerce_reference, get(data, "reference", nothing))

    return Reaction(id, substrates, products, rate, name = name, reference = reference)
end


"""
    coerce_coupling_entry(data::Any) -> CouplingEntry

Coerce JSON data into concrete CouplingEntry subtype based on the 'type' field.
"""
function coerce_coupling_entry(data::Any)::CouplingEntry
    if !(data isa AbstractDict) || !haskey(data, "type")
        throw(ParseError("CouplingEntry must be an object with 'type' field"))
    end

    coupling_type = data["type"]

    if coupling_type == "operator_compose"
        return coerce_operator_compose(data)
    elseif coupling_type == "couple"
        return coerce_couple(data)
    elseif coupling_type == "variable_map"
        return coerce_variable_map(data)
    elseif coupling_type == "operator_apply"
        return coerce_operator_apply(data)
    elseif coupling_type == "callback"
        return coerce_callback(data)
    elseif coupling_type == "event"
        return coerce_coupling_event(data)
    elseif coupling_type == "coupling_import"
        return coerce_coupling_import(data)
    else
        throw(ParseError("Unknown coupling type: $coupling_type"))
    end
end


"""
    coerce_variable_map(data::AbstractDict) -> CouplingVariableMap

Parse variable_map coupling entry.
"""
function coerce_variable_map(data::AbstractDict)::CouplingVariableMap
    required_fields = ["from", "to", "transform"]
    for field in required_fields
        if !haskey(data, field)
            throw(ParseError("variable_map requires '$field' field"))
        end
    end

    from = String(data["from"])
    to = String(data["to"])
    # `transform` is either one of the named transform strings or an Expression
    # operator node (esm-spec §10.4: the expression-transform widening; the
    # degenerate bare-string/number Expression spellings are not admissible in
    # this slot, so a string here is always a named transform).
    raw_transform = data["transform"]
    transform = if raw_transform isa AbstractString
        String(raw_transform)
    elseif raw_transform isa AbstractDict
        expression_from_json(raw_transform)
    else
        throw(ParseError("variable_map 'transform' must be a named transform string or an expression operator node"))
    end
    factor = _opt_float(data, "factor")
    description = _opt_string(data, "description")
    lifting = _opt_string(data, "lifting")

    # The "an expression transform takes no factor" invariant is enforced ONCE,
    # by the `CouplingVariableMap` constructor (types.jl). The parser rethrows
    # that `ArgumentError` as a `ParseError` with the load-side message.
    try
        return CouplingVariableMap(from, to, transform; factor = factor, description = description, lifting = lifting)
    catch e
        if e isa ArgumentError && transform isa ASTExpr && factor !== nothing
            throw(ParseError("variable_map: an expression 'transform' takes no 'factor' (fold the scaling into the expression)"))
        end
        rethrow()
    end
end


# ========================================
# Table-generated record coercers
# ========================================
#
# One `coerce_<fn>` per `RECORD_FIELD_TABLES` entry (types.jl — the shared
# per-type field tables; the serialize direction is generated from the SAME
# table in serialize.jl). Each generated coercer extracts one local per row,
# in table order (which fixes ParseError precedence),
# then calls the type's constructor with the table's positional/keyword
# split. Irregular residue (discriminated unions, name-keyed-map↔vector
# conversions, context-threaded messages) stays hand-written above; the
# `:custom` rows below name their hand-written per-field hooks.

# ── Hand-written `:custom` parse hooks (named by RECORD_FIELD_TABLES rows) ──
# Model `guesses`: number-or-Expression solver-guess map.
function _coerce_model_guesses(v)
    guesses = Dict{String, Union{Float64, ASTExpr}}()
    for (k, x) in pairs(v)
        guesses[string(k)] = x isa Number ? Float64(x) : expression_from_json(x)
    end
    return guesses
end

# Model `subsystems` (schema §4.7): each entry is oneOf [Model, SubsystemRef],
# sniffed per entry by `_coerce_subsystem_entry` (the key is threaded in for
# metaparameter-binding diagnostics).
_coerce_model_subsystems(v) = OrderedDict{String, SubsystemNode}(
    string(k) => _coerce_subsystem_entry(string(k), x) for (k, x) in pairs(v)
)


# DiscreteEvent `affects`: each entry must carry both lhs and rhs (pinned
# per-entry ParseError), then coerces as an ordinary AffectEquation.
function _coerce_discrete_affects(v)
    affects = AffectEquation[]
    for a in v
        if !_raw_haskey(a, "lhs") || !_raw_haskey(a, "rhs")
            throw(ParseError("AffectEquation requires 'lhs' and 'rhs' fields"))
        end
        push!(affects, coerce_affect_equation(a))
    end
    return affects
end

"""
    coerce_distribution(data) -> Distribution

Coerce a schema `Distribution` object (esm-spec §6.3). The three kinds spell
their location and scale differently on the wire — `normal` uses `mean`/`std`,
`lognormal` uses `mu`/`sigma`, `uniform` uses `low`/`high` — so the parse maps
each onto the struct's role-named fields and `_emit_distribution` restores the
wire names. `kind` is closed: anything outside the three is rejected here
rather than carried as an opaque string a downstream sampler cannot honour.
"""
function coerce_distribution(data)
    data isa AbstractDict ||
        throw(ParseError("distribution must be an object"))
    kind = _raw_get(data, "kind", nothing)
    kind === nothing && throw(ParseError("distribution requires a 'kind' field"))
    kind = string(kind)
    num_or_vec(v) = v isa AbstractVector ? Float64[Float64(x) for x in v] : Float64(v)
    cov = let c = _raw_get(data, "cov", nothing)
        c === nothing ? nothing :
            Vector{Float64}[Float64[Float64(x) for x in row] for row in c]
    end
    if kind == "normal"
        loc = _raw_get(data, "mean", nothing)
        loc === nothing && throw(ParseError("normal distribution requires 'mean'"))
        sc = _raw_get(data, "std", nothing)
        return Distribution(
            "normal"; location = num_or_vec(loc),
            scale = (sc === nothing ? nothing : num_or_vec(sc)), cov = cov
        )
    elseif kind == "lognormal"
        loc = _raw_get(data, "mu", nothing)
        loc === nothing && throw(ParseError("lognormal distribution requires 'mu'"))
        sc = _raw_get(data, "sigma", nothing)
        return Distribution(
            "lognormal"; location = num_or_vec(loc),
            scale = (sc === nothing ? nothing : num_or_vec(sc)), cov = cov
        )
    elseif kind == "uniform"
        lo = _raw_get(data, "low", nothing)
        hi = _raw_get(data, "high", nothing)
        (lo === nothing || hi === nothing) &&
            throw(ParseError("uniform distribution requires 'low' and 'high'"))
        return Distribution("uniform"; low = num_or_vec(lo), high = num_or_vec(hi))
    end
    throw(
        ParseError(
            "Invalid distribution kind: $(kind) " *
                "(expected one of normal, lognormal, uniform)"
        )
    )
end

"""
    _coerce_parameter_update_spec(v) -> Vector{ParameterUpdate}

Coerce a schema `ParameterUpdateSpec` (esm-spec §5.4): EITHER one rule object
OR an ordered array of two or more. Both spellings become a vector, so every
consumer iterates one shape; the emitted spelling is recovered from the length.

The two array constraints are enforced here because they are what makes the
representation unique — a one-element array and a `wiener` rule inside an array
are both invalid, so neither can be normalised into the vector and silently
re-emitted as the legal form.
"""
function _coerce_parameter_update_spec(v)
    if v isa AbstractVector
        length(v) >= 2 || throw(
            ParseError(
                "parameter `update` array requires at least two rules; a single " *
                    "rule MUST be written as the object form (esm-spec 5.4)"
            )
        )
        rules = ParameterUpdate[coerce_parameter_update(x) for x in v]
        for r in rules
            r.kind == "wiener" && throw(
                ParseError(
                    "parameter `update` array may not contain a `wiener` rule: a " *
                        "driving noise process is the parameter's whole value " *
                        "(esm-spec 5.4)"
                )
            )
        end
        return rules
    end
    return ParameterUpdate[coerce_parameter_update(v)]
end

# Assertion `reference` (spec §6.6.5): the from_file shape is a JSON object
# whose `type` is the literal string "from_file"; everything else — including
# an inline Expression AST, which is ALSO an object — parses as an Expression.
# The discriminator MUST be the `type` field: "is it dict-like" would route
# every inline reference to the from_file branch.
function _coerce_assertion_reference(ref)
    reftype = ref isa AbstractDict && haskey(ref, "type") ?
        string(ref["type"]) : ""
    if reftype == "from_file"
        reference = Dict{String, Any}()
        for (k, v) in pairs(ref)
            reference[string(k)] = v
        end
        return reference
    end
    return expression_from_json(ref)
end


# coupling_import `bind` (esm-spec §10.10): role name → component map.
function _coerce_coupling_import_bind(v)
    if !(v isa AbstractDict)
        throw(ParseError("coupling_import 'bind' must be an object mapping role names to components"))
    end
    bind = Dict{String, String}()
    for (k, x) in pairs(v)
        bind[string(k)] = String(x)
    end
    return bind
end

# index_sets `members`: the stringified convenience view.
_coerce_index_set_members(v) = String[string(x) for x in v]

# index_sets `members_raw`: original member types retained ONLY when some
# member is not a string, so the join-key validator can reject float / null
# keys (RFC §5.3). A string-only set keeps `members_raw === nothing`.
_coerce_index_set_members_raw(v) =
    any(x -> !(x isa AbstractString), v) ? Any[x for x in v] : nothing


# Parse-side value conversion for one table row: returns the expression
# coercing `v` (the fetched wire value) per the row's `kind`.
function _record_parse_expr(row, v)
    kind = row.kind
    return if kind === :string
        :(string($v))
    elseif kind === :string_strict
        :(String($v))
    elseif kind === :float
        :(Float64($v))
    elseif kind === :int
        :(Int($v))
    elseif kind === :bool
        :(Bool($v))
    elseif kind === :number_or_string
        :(
            let x = $v
                x isa Number ? Int(x) : string(x)
            end
        )
    elseif kind === :number_or_expr
        :(
            let x = $v
                x isa Number ? Float64(x) : expression_from_json(x)
            end
        )
    elseif kind === :variable_bound
        :(_coerce_variable_bound($v))
    elseif kind === :expr
        :(expression_from_json($v))
    elseif kind === :expr_vec
        :(ASTExpr[expression_from_json(x) for x in $v])
    elseif kind === :string_vec
        :([string(x) for x in $v])
    elseif kind === :float_vec
        :(Float64[Float64(x) for x in $v])
    elseif kind === :string_vec_strict
        :(Vector{String}($v))
    elseif kind === :float_map
        :(Dict{String, Float64}(string(k) => Float64(x) for (k, x) in pairs($v)))
    elseif kind === :value_map
        # esm-spec §6.6.2: a value is a scalar or INLINE ARRAY DATA (a row-major
        # nested JSON array for a shaped variable), coerced to Float64 / a dense
        # Array{Float64,N} by `_coerce_inline_value`.
        :(Dict{String, Any}(string(k) => _coerce_inline_value(x) for (k, x) in pairs($v)))
    elseif kind === :inline_value
        :(_coerce_inline_value($v))
    elseif kind === :str_keyed_copy
        :(Dict{String, Any}(string(k) => x for (k, x) in pairs($v)))
    elseif kind === :raw
        :(_to_native_json($v))
    elseif kind === :raw_vec
        :(Any[_to_native_json(e) for e in $v])
    elseif kind === :model_variable_type
        :(coerce_model_variable_type(string($v)))
    elseif kind === :record
        :($(Symbol(:coerce_, row.of))($v))
    elseif kind === :record_vec
        :($(row.eltype)[$(Symbol(:coerce_, row.of))(x) for x in $v])
    elseif kind === :record_map
        :(
            OrderedDict{String, $(row.eltype)}(
                string(k) => $(Symbol(:coerce_, row.of))(x)
                    for (k, x) in pairs($v)
            )
        )
    elseif kind === :custom
        :($(row.parse_fn)($v))
    else
        error("RECORD_FIELD_TABLES: unknown kind $(kind) for field $(row.f)")
    end
end

# One `<field> = <fetch+convert>` statement per row, per the row's `mode`
# (fetch policy). See the RECORD_FIELD_TABLES docstring (types.jl) for the
# exact policy each mode encodes.
function _record_coerce_stmt(row)
    f = row.f
    key = w = row.wire
    mode = row.mode
    return if mode === :req
        :($f = $(_record_parse_expr(row, :(data[$w]))))
    elseif mode === :req_err
        body = haskey(row, :default) ?
            :(
                let v = _raw_get(data, $key, nothing)
                    v === nothing ? $(row.default) : $(_record_parse_expr(row, :v))
            end
            ) :
            _record_parse_expr(row, :(_raw_get(data, $key, nothing)))
        quote
            _raw_haskey(data, $key) || throw(ParseError($(row.req_err)))
            $f = $body
        end
    elseif mode === :req_nullerr
        quote
            $f = let v = _raw_get(data, $key, nothing)
                v === nothing && throw(ParseError($(row.req_err)))
                $(_record_parse_expr(row, :v))
            end
        end
    elseif mode === :opt
        :(
            $f = let v = _raw_get(data, $key, nothing)
                v === nothing ? nothing : $(_record_parse_expr(row, :v))
            end
        )
    elseif mode === :opt_empty || mode === :default
        :(
            $f = let v = _raw_get(data, $key, nothing)
                v === nothing ? $(row.default) : $(_record_parse_expr(row, :v))
            end
        )
    elseif mode === :force
        :($f = $(_record_parse_expr(row, :(_raw_get(data, $key, nothing)))))
    else
        error("RECORD_FIELD_TABLES: unknown mode $(mode) for field $(row.f)")
    end
end

# GENERATED coercers: one per table entry, named `coerce_<fn>`, constructing
# the type with the table's positional args (in row order; an `injected`
# map-key name leads) and one keyword per remaining row.
for spec in RECORD_FIELD_TABLES
    fname = Symbol(:coerce_, spec.fn)
    injected = get(spec, :injected, false)
    stmts = Any[_record_coerce_stmt(row) for row in spec.rows]
    posargs = Any[]
    injected && push!(posargs, :name)
    append!(posargs, Any[row.f for row in spec.rows if get(row, :pos, false)])
    kwargs = Any[Expr(:kw, row.f, row.f) for row in spec.rows if !get(row, :pos, false)]
    ctor = isempty(kwargs) ?
        Expr(:call, spec.T, posargs...) :
        Expr(:call, spec.T, Expr(:parameters, kwargs...), posargs...)
    argdecls = injected ? Any[:(name::String), :(data::Any)] : Any[:(data::Any)]
    @eval function $fname($(argdecls...))::$(spec.T)
        $(stmts...)
        return $ctor
    end
    @eval @doc $(
        """
            coerce_$(spec.fn)($(injected ? "name, " : "")data) -> $(spec.T)

        Coerce JSON data into `$(spec.T)`. GENERATED from `RECORD_FIELD_TABLES`
        (types.jl) — one extraction per row, in table order;
        the serialize direction is generated from the same table in serialize.jl.
        """
    ) $fname
end
