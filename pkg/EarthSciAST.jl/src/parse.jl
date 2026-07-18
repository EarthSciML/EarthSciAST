"""
ESM Format JSON Parsing

Provides functionality to load and validate ESM files from JSON strings or files.
Uses manual JSON parsing and type coercion for full control over the deserialization process.
"""

using JSON3
using JSONSchema


"""
    ParseError

Exception thrown when JSON parsing fails.
"""
struct ParseError <: Exception
    message::String
    original_error::Union{Exception,Nothing}
    # MACHINE-READABLE half, defaulting empty. A few parse/load-time rejections
    # are ALSO pinned structural findings the conformance harness reports as
    # `(code, path)` — `ic_in_reaction_system` at
    # `/reaction_systems/<R>/constraint_equations/<i>` is the current one — so
    # the throw carries everything `validate` needs to render that finding
    # instead of only an opaque string. An empty `code` marks an ordinary
    # parse failure with no pinned structural shape.
    code::String
    path::String
    details::Dict{String,Any}

    ParseError(message::String, original_error=nothing;
               code::AbstractString="", path::AbstractString="",
               details::AbstractDict=Dict{String,Any}()) =
        new(message, original_error, String(code), String(path), Dict{String,Any}(details))
end

Base.showerror(io::IO, e::ParseError) = print(io, "ParseError: ", e.message)


# Recursively convert any JSON carrier into plain-`Dict{String,Any}` /
# `Vector{Any}` containers — the UNORDERED deep-plain normalizer, kept (beside
# the order-preserving `_to_ordered` in json_walk.jl) for two jobs where key
# order is deliberately NOT part of the contract:
#   * raw-passthrough values stored on typed structs and re-emitted verbatim
#     (`functional_affect`, loader `metadata`, the `_verbatim_decl` snapshots,
#     serialize.jl's import-entry copies) — historically plain Dicts, and the
#     JSON3-write byte surface of `save` depends on that staying so;
#   * carrier-independent input to JSONSchema.jl (`validate_schema`), whose
#     `type: array` check does not recognize `JSON3.Array`.
function _to_native_json(x)
    if x isa JSON3.Array || x isa AbstractVector
        return Any[_to_native_json(v) for v in x]
    elseif x isa JSON3.Object || x isa AbstractDict
        return Dict{String,Any}(string(k) => _to_native_json(v) for (k, v) in pairs(x))
    else
        return x
    end
end

"""
    parse_expression(data::Any) -> ASTExpr

Parse JSON data into an Expression (NumExpr, VarExpr, or OpExpr).
Handles the oneOf discriminated union based on JSON structure.
"""
function parse_expression(data::Any)::ASTExpr
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
        # (e.g. an integer ratio `{op:"/",args:[1,N]}` inside an `aggregate`
        # `expr` body). Without this an integer ratio inside an aggregate would
        # round-trip as `1.0/N.0` and could never be byte-identical across the
        # five bindings. Non-integral floats stay `NumExpr`.
        if isfinite(data) && isinteger(data) &&
           typemin(Int64) <= data <= typemax(Int64) && Float64(Int64(data)) == data
            return IntExpr(Int64(data))
        end
        return NumExpr(Float64(data))
    elseif isa(data, String)
        return VarExpr(data)
    elseif _has_field(data, :op)
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
hand-mutates raw dicts between `parse_expression` calls sees unchanged
behavior.
"""
const _PARSE_EXPR_MEMO_KEY = :_earthsci_ast_parse_expression_memo

function _parse_op_dict_memoized(data)
    memo = get(task_local_storage(), _PARSE_EXPR_MEMO_KEY,
               nothing)::Union{Nothing,IdDict{Any,ASTExpr}}
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
# tag (scalar coercions). Field lookup goes through `_get_field` (string-keyed,
# null-as-absent), so each wire key is named exactly once — in the table.
# Op-conditional structural validation is spliced in at the same positions the
# historical hand-written extraction performed it (integral bounds directly
# after `upper`, `intersect_polygon` manifold directly after `manifold`), so
# ParseError precedence on multiply-invalid nodes is unchanged. `table_axes`
# is the one op-conditional extraction: the `axes` key is only parsed for a
# `table_lookup` node, and its coercer needs the already-extracted `table` id
# and `args` (the table row order guarantees `table` is bound first).
function _parse_op_field_stmt(f::Symbol, spec)::Union{Expr,Nothing}
    (f === :op || f === :args) && return nothing        # structural, hand-parsed
    spec.kind === :internal && return nothing           # never on the wire
    w = QuoteNode(spec.wire)
    rhs = if f === :table_axes
        :(op == "table_lookup" ?
            _coerce_table_lookup_axes(table, _get_field(data, $w, nothing), args) :
            nothing)
    elseif spec.kind === :expr
        :(_maybe(parse_expression, _get_field(data, $w, nothing)))
    elseif spec.kind === :expr_vec
        :(let raw = _get_field(data, $w, nothing)
            raw === nothing ? nothing :
                Vector{ASTExpr}([parse_expression(v) for v in raw])
        end)
    elseif spec.kind === :expr_map
        :(let raw = _get_field(data, $w, nothing)
            raw === nothing ? nothing :
                Dict{String,ASTExpr}(string(k) => parse_expression(v)
                                     for (k, v) in pairs(raw))
        end)
    elseif spec.kind === :ranges
        :(_coerce_ranges(_get_field(data, $w, nothing)))
    elseif spec.kind === :join
        :(_coerce_join(_get_field(data, $w, nothing)))
    elseif spec.parse === :string
        :(_opt_string(data, $w))
    elseif spec.parse === :int
        :(_opt_int(data, $w))
    elseif spec.parse === :int_vec
        :(let raw = _get_field(data, $w, nothing)
            raw === nothing ? nothing : Vector{Int}([Int(x) for x in raw])
        end)
    elseif spec.parse === :bool
        :(_maybe(Bool, _get_field(data, $w, nothing)))
    elseif spec.parse === :json
        # JSON-typed value (number, integer, or nested array); convert JSON3
        # containers to native Julia ones so downstream code doesn't have to
        # special-case JSON3 types.
        :(_maybe(_to_native_json, _get_field(data, $w, nothing)))
    elseif spec.parse === :output_idx
        :(_coerce_output_idx(_get_field(data, $w, nothing)))
    elseif spec.parse === :regions
        :(_coerce_regions(_get_field(data, $w, nothing)))
    elseif spec.parse === :shape
        :(_coerce_shape(_get_field(data, $w, nothing)))
    elseif spec.parse === :int_or_string
        :(let raw = _get_field(data, $w, nothing)
            raw === nothing ? nothing : (raw isa Integer ? Int(raw) : string(raw))
        end)
    else
        error("OPEXPR_FIELD_TABLE row $(f) has no parse recipe " *
              "(kind=$(spec.kind), parse=$(spec.parse))")
    end
    return :($f = $rhs)
end

# Per-op structural validators spliced in AFTER the named field's extraction.
const _PARSE_OP_VALIDATOR_AFTER = Dict{Symbol,Expr}(
    :upper => :(op == "integral" && _validate_integral_op(int_var, lower, upper)),
    :manifold => :(op == "intersect_polygon" && _validate_intersect_polygon_op(manifold)),
)

@eval function _parse_op_optional_fields(data, op::String, args::Vector{ASTExpr})
    $((stmt for (f, spec) in pairs(OPEXPR_FIELD_TABLE)
       for stmt in (_parse_op_field_stmt(f, spec),
                    get(_PARSE_OP_VALIDATOR_AFTER, f, nothing))
       if stmt !== nothing)...)
    return (; $((f for (f, spec) in pairs(OPEXPR_FIELD_TABLE)
                 if f !== :op && f !== :args && spec.kind !== :internal)...))
end

# Shared implementation for every dict-like carrier. The optional-field
# portion is generated from `OPEXPR_FIELD_TABLE` (see
# `_parse_op_optional_fields` above); only the structural `op`/`args` handling
# and op-existence rejections live here.
function _parse_op_dict(data)
    op = string(_get_field(data, :op, nothing))
    if op == "call"
        # The `call` op + `registered_functions` extension point was removed in
        # v0.3.0 (esm-spec §9 closure, RFC `closed-function-registry.md`).
        # Files written against the v0.2.x escape hatch must migrate to AST
        # ops or `fn` invocations of closed registry entries.
        throw(ParseError("`call` op is not valid in v0.3.0+ (removed by esm-spec §9 closure). " *
                         "Migrate to AST ops or `fn` invocations of the closed function registry."))
    end
    # `apply_expression_template` is normally expanded by
    # `lower_expression_templates` before any tree reaches `parse_expression`
    # (esm-spec §9.6). When a caller feeds an unexpanded node directly — as the
    # cross-language display conformance producer does — it is built into an
    # `OpExpr` carrying `name` + `bindings` so the pretty-printer can render it
    # per RENDERING_CONTRACT.md (matching the other four bindings), rather than
    # throwing. The load pipeline still lowers templates ahead of typed parsing,
    # so a loaded document never carries an `apply_expression_template` node.
    args_data = _get_field(data, :args, ())
    args = Vector{ASTExpr}([parse_expression(arg) for arg in args_data])
    flds = _parse_op_optional_fields(data, op, args)
    return OpExpr(op, args; flds...)
end

# ── Per-op validators for `_parse_op_dict` ──────────────────────────────────
#
# Ops with structural field requirements each get their own checker so the
# generic field-extraction skeleton in `_parse_op_dict` reads at one level.
# Error messages are load-rejection behavior — keep them byte-identical.

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

# `table_lookup` (esm-spec §9.5, v0.4.0): requires the `table` id and the
# per-axis input expression map (wire key `axes` — struct field `table_axes`);
# ``args`` MUST be empty (per-axis inputs live under `axes`). Returns the
# parsed axes map.
function _coerce_table_lookup_axes(table, axes_raw, args::Vector{ASTExpr})::Dict{String,ASTExpr}
    if table === nothing
        throw(ParseError("`table_lookup` op requires `table` field (esm-spec §9.5)"))
    end
    if axes_raw === nothing
        throw(ParseError("`table_lookup` op requires `axes` field (per-axis input expression map, esm-spec §9.5)"))
    end
    axes = Dict{String,ASTExpr}()
    for (k, v) in pairs(axes_raw)
        axes[string(k)] = parse_expression(v)
    end
    if !isempty(args)
        throw(ParseError("`table_lookup` op must have empty `args` (per-axis inputs live under `axes`, esm-spec §9.5)"))
    end
    return axes
end

# `intersect_polygon` (RFC §8.1 / Appendix B) is strictly manifold-required
# (the schema enforces it); fail fast here so a hand-built node mirrors that.
function _validate_intersect_polygon_op(manifold)
    if manifold === nothing
        throw(ParseError("`intersect_polygon` op requires a `manifold` field " *
                         "(planar / spherical / geodesic); it carries no default"))
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
# `_has_field` / `_get_field` are the canonical, non-throwing accessors — no
# try/catch control flow, no per-carrier special cases at use sites. A JSON
# `null` value is reported as absent by `_get_field` (callers uniformly treat
# `null` as "field not given").

# True when `data` is a dict-like JSON carrier.
_is_json_object(data) = data isa AbstractDict

_has_field(data, key::Symbol)::Bool =
    data isa AbstractDict && haskey(data, string(key))

function _get_field(data, key::Symbol, default)
    data isa AbstractDict || return default
    v = get(data, string(key), nothing)
    return v === nothing ? default : v
end

# Optional-field coercion shorthands: fetch `key`, propagate absent/null as
# `nothing`, otherwise convert. These replace the repeated
# `haskey(data, :k) && data.k !== nothing ? convert(data.k) : nothing` pattern.
_opt_string(data, key::Symbol) = _maybe(string, _get_field(data, key, nothing))
_opt_float(data, key::Symbol) = _maybe(Float64, _get_field(data, key, nothing))
_opt_int(data, key::Symbol) = _maybe(Int, _get_field(data, key, nothing))

function _coerce_ranges(data)
    data === nothing && return nothing
    result = Dict{String,Any}()
    for (k, v) in pairs(data)
        sv = string(k)
        if v isa AbstractVector
            # Dense integer tuple [lo, hi] / [lo, step, hi] (as today).
            if all(x -> x isa Number, v)
                result[sv] = Any[Int(x) for x in v]
            else
                result[sv] = Any[x isa Number ? Int(x) : parse_expression(x) for x in v]
            end
        else
            # Index-set reference (RFC semiring-faq-unified-ir §5.2):
            # { "from": <index_sets key>, "of"?: [parent index names] }.
            from_val = _get_field(v, :from, nothing)
            from_val === nothing && throw(ParseError(
                "ranges entry `$sv` must be a dense array [lo,hi]/[lo,step,hi] " *
                "or an index-set reference object with a `from` key"))
            of_raw = _get_field(v, :of, nothing)
            of_names = of_raw === nothing ? String[] : String[string(x) for x in of_raw]
            result[sv] = IndexSetRef(string(from_val); of=of_names)
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
function _coerce_join(data)
    data === nothing && return nothing
    clauses = Vector{Any}()
    for clause in data
        on_raw = _get_field(clause, :on, nothing)
        on_raw === nothing && throw(ParseError(
            "join clause requires an `on` array of [left, right] key-column " *
            "pairs (RFC semiring-faq-unified-ir §5.3)"))
        pairs_vec = Vector{Tuple{String,String}}()
        for pair in on_raw
            length(pair) == 2 || throw(ParseError(
                "join `on` entry must be a 2-element [left, right] pair, got " *
                "$(length(pair)) element(s) (RFC §5.3)"))
            push!(pairs_vec, (string(pair[1]), string(pair[2])))
        end
        isempty(pairs_vec) && throw(ParseError(
            "join clause `on` requires at least one key-column pair (RFC §5.3)"))
        push!(clauses, pairs_vec)
    end
    return clauses
end

function _coerce_regions(data)
    data === nothing && return nothing
    return Vector{Vector{Vector{Int}}}([
        Vector{Vector{Int}}([Vector{Int}([Int(x) for x in ax]) for ax in region])
        for region in data
    ])
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
    trigger_type_str = _opt_string(data, :type)

    if trigger_type_str == "condition" || (trigger_type_str === nothing && _has_field(data, :expression))
        expression = _get_field(data, :expression, nothing)
        if expression === nothing
            throw(ParseError("Condition trigger requires 'expression' field"))
        end
        return ConditionTrigger(parse_expression(expression))
    elseif trigger_type_str == "periodic" || (trigger_type_str === nothing && (_has_field(data, :interval) || _has_field(data, :period)))
        interval_val = _get_field(data, :interval, nothing)
        if interval_val === nothing
            interval_val = _get_field(data, :period, nothing)
        end
        if interval_val === nothing
            throw(ParseError("Periodic trigger requires 'interval' field"))
        end
        period = Float64(interval_val)
        phase_val = _get_field(data, :initial_offset, nothing)
        if phase_val === nothing
            phase_val = _get_field(data, :phase, 0.0)
        end
        phase = Float64(phase_val)
        return PeriodicTrigger(period, phase=phase)
    elseif trigger_type_str == "preset_times" || (trigger_type_str === nothing && _has_field(data, :times))
        times_val = _get_field(data, :times, nothing)
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
    coerce_esm_file(data::Any) -> EsmFile

Coerce raw JSON data into properly typed EsmFile with custom union type handling.

Accepts ANY dict-like JSON carrier — a `JSON3.Object` straight off the wire,
the load pipeline's already-native tree, or a `Dict` assembled in Julia code
(string- or symbol-keyed) — and normalizes it ONCE, here at the boundary, into
the single post-wire carrier (`_to_ordered`: string-keyed `OrderedDict` tree),
so every nested coercer speaks plain string-keyed `get`. The normalization is
sharing-preserving, so the structural sharing template expansion builds
carries through into the `parse_expression` identity memo. Callers never need
a `JSON3.read(JSON3.write(doc))` type-launder.
"""
function coerce_esm_file(data::Any)::EsmFile
    data = _to_ordered(data)

    # Extract required fields
    esm_raw = _get_field(data, :esm, nothing)
    esm_raw === nothing && throw(ParseError("ESM document requires an `esm` version field"))
    esm = string(esm_raw)
    metadata_raw = _get_field(data, :metadata, nothing)
    metadata_raw === nothing && throw(ParseError("ESM document requires a `metadata` object"))
    metadata = coerce_metadata(metadata_raw)

    # Extract optional fields with proper null/missing handling — `_get_field`
    # reports a JSON `null` as absent, matching the previous per-field
    # `haskey(data, :x) && data.x !== nothing` guards.
    models = _maybe(_get_field(data, :models, nothing)) do m
        Dict{String,Model}(string(k) => coerce_model(v) for (k, v) in pairs(m))
    end

    reaction_systems = _maybe(_get_field(data, :reaction_systems, nothing)) do rs
        Dict{String,ReactionSystem}(string(k) => coerce_reaction_system(v) for (k, v) in pairs(rs))
    end

    data_loaders = _maybe(_get_field(data, :data_loaders, nothing)) do dl
        Dict{String,DataLoader}(string(k) => coerce_data_loader(v) for (k, v) in pairs(dl))
    end

    # esm-spec v0.3.0 (§9 closure) removed the top-level `operators` block:
    # Track-A parameterizations migrate to AST + closed-function calls;
    # Track-B state-mutating schemes route through the discretization
    # RFC's named schemes (`docs/rfcs/closed-function-registry.md` §6).
    # File-loaded `operators` are now a hard error. (The typed `EsmFile`
    # fields survive for in-memory compatibility only and stay `nothing`
    # on every parse path.)
    if _get_field(data, :operators, nothing) !== nothing
        throw(ParseError("`operators` block is not valid in v0.3.0+ " *
                         "(removed by esm-spec §9 closure). Migrate per " *
                         "`docs/rfcs/closed-function-registry.md` §6."))
    end

    if _get_field(data, :registered_functions, nothing) !== nothing
        throw(ParseError("`registered_functions` block is not valid in v0.3.0+ " *
                         "(removed by esm-spec §9 closure). Use the closed " *
                         "function registry via `fn` ops with spec-defined names."))
    end

    coupling_raw = _get_field(data, :coupling, nothing)
    coupling = coupling_raw === nothing ? CouplingEntry[] :
        CouplingEntry[coerce_coupling_entry(c) for c in coupling_raw]

    # esm-spec v0.8.0: a single top-level `domain` object (the one temporal
    # domain shared by every component), not the old `domains` map of named
    # domains. Cross-grid coupling is now an ordinary regridding `transform`
    # expression, so there is no `interfaces` block either.
    domain = _maybe(coerce_domain, _get_field(data, :domain, nothing))

    # File-local enum mappings (esm-spec §9.3). Used by the `enum` AST op to
    # carry symbolic categorical labels in the source while the on-disk file
    # is loaded; `enum` ops are then lowered to integer `const` nodes
    # immediately after parsing so the in-memory tree never carries strings.
    enums = _maybe(coerce_enums, _get_field(data, :enums, nothing))

    # Component-scoped sampled function tables (esm-spec §9.5, v0.4.0). Each
    # entry carries named axes plus a literal nested-array data block;
    # referenced by table_lookup AST nodes via the table id key.
    function_tables = _maybe(coerce_function_tables,
                             _get_field(data, :function_tables, nothing))

    # Document-scoped index-set registry (RFC semiring-faq-unified-ir §5.2;
    # esm-spec v0.8.0). A single top-level `index_sets` object — sibling of
    # `models`/`domain`, shared by every component — that unifies ESM grid dims
    # and ESI categorical dims. `ranges[*]` `{from: <name>}` references, array
    # `shape`s, and derived-set `from_faq` edges resolve against it. Empty when
    # the document declares none.
    index_sets = Dict{String,IndexSet}()
    index_sets_raw = _get_field(data, :index_sets, nothing)
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
    # load pipeline — the tree-walk front-door's `flattened_to_esm`
    # reconstitution (esm-spec §9.6.4 Option B), or a direct
    # `coerce_esm_file`/`build_evaluator(dict)` call on a lowered 0.9.0 emit.
    # Capture them as `component_templates` so `apply_expression_template` nodes
    # in the coerced expressions stay resolvable; without this the references
    # compile into opaque op nodes that only fail at RHS evaluation time.
    component_templates = nothing
    let ct = Dict{String,Any}()
        for (compkind, comps_raw) in (("models", _get_field(data, :models, nothing)),
                                      ("reaction_systems", _get_field(data, :reaction_systems, nothing)))
            comps_raw === nothing && continue
            for (k, v) in pairs(comps_raw)
                tpl = _get_field(v, :expression_templates, nothing)
                tpl === nothing && continue
                # Native String-keyed form: the registry is probed with String
                # names (`haskey(reg, name)`) and read with `_raw_get`, and the
                # load path's `_materialize_components!` blocks are native too.
                ct["$compkind.$(string(k))"] = _to_native_json(tpl)
            end
        end
        isempty(ct) || (component_templates = ct)
    end
    file = EsmFile(esm, metadata,
                  models=models,
                  reaction_systems=reaction_systems,
                  data_loaders=data_loaders,
                  coupling=coupling,
                  domain=domain,
                  enums=enums,
                  function_tables=function_tables,
                  index_sets=index_sets,
                  component_templates=component_templates)
    # Lower every `enum` op to a `const` integer using the file-local map.
    # This runs once at load time so downstream consumers (evaluators,
    # canonicalize, codegen) never see enum strings in expression trees.
    lower_enums!(file)
    return file
end

"""
    coerce_enums(data) -> Dict{String,Dict{String,Int}}

Coerce the top-level `enums` JSON block into the typed map carried on
[`EsmFile`](@ref). Validates per esm-spec §9.3:

- enum names are non-empty strings
- symbolic keys are non-empty strings
- values are positive integers
- within a single enum, integer values are unique

Throws [`ParseError`](@ref) on any violation.
"""
function coerce_enums(data)::Dict{String,Dict{String,Int}}
    out = Dict{String,Dict{String,Int}}()
    for (enum_name_raw, mapping_raw) in pairs(data)
        enum_name = string(enum_name_raw)
        if isempty(enum_name)
            throw(ParseError("enums: enum name must be non-empty"))
        end
        if !(mapping_raw isa AbstractDict)
            throw(ParseError("enums.$(enum_name): mapping must be a JSON object"))
        end
        mapping = Dict{String,Int}()
        seen_values = Set{Int}()
        for (sym_raw, int_raw) in pairs(mapping_raw)
            sym = string(sym_raw)
            if isempty(sym)
                throw(ParseError("enums.$(enum_name): symbol name must be non-empty"))
            end
            if !(int_raw isa Integer) || int_raw isa Bool
                throw(ParseError("enums.$(enum_name).$(sym): value must be a positive integer (got $(typeof(int_raw)))"))
            end
            int_v = Int(int_raw)
            if int_v <= 0
                throw(ParseError("enums.$(enum_name).$(sym): value must be a positive integer (got $(int_v))"))
            end
            if int_v in seen_values
                throw(ParseError("enums.$(enum_name): integer value $(int_v) is duplicated"))
            end
            push!(seen_values, int_v)
            mapping[sym] = int_v
        end
        out[enum_name] = mapping
    end
    return out
end

"""
    coerce_function_tables(data) -> Dict{String,FunctionTable}

Coerce the top-level `function_tables` JSON block into the typed map
carried on [`EsmFile`](@ref) (esm-spec §9.5, v0.4.0). Each entry holds
ordered named axes plus a literal nested-array data block referenced by
`table_lookup` AST nodes.
"""
function coerce_function_tables(data)::Dict{String,FunctionTable}
    out = Dict{String,FunctionTable}()
    for (table_name_raw, entry_raw) in pairs(data)
        table_name = string(table_name_raw)
        if isempty(table_name)
            throw(ParseError("function_tables: table name must be non-empty"))
        end
        if !(entry_raw isa AbstractDict)
            throw(ParseError("function_tables.$(table_name): entry must be a JSON object"))
        end
        axes_raw = get(entry_raw, "axes", nothing)
        if axes_raw === nothing
            throw(ParseError("function_tables.$(table_name): `axes` is required (esm-spec §9.5)"))
        end
        axes_vec = Vector{FunctionTableAxis}()
        for ax_raw in axes_raw
            ax_name = string(get(ax_raw, "name", ""))
            if isempty(ax_name)
                throw(ParseError("function_tables.$(table_name).axes: axis `name` must be non-empty"))
            end
            ax_values_raw = get(ax_raw, "values", nothing)
            if ax_values_raw === nothing
                throw(ParseError("function_tables.$(table_name).axes.$(ax_name): `values` is required"))
            end
            ax_values = Vector{Float64}([Float64(v) for v in ax_values_raw])
            ax_units = _maybe(string, get(ax_raw, "units", nothing))
            push!(axes_vec, FunctionTableAxis(ax_name, ax_values; units=ax_units))
        end
        if !haskey(entry_raw, "data")
            throw(ParseError("function_tables.$(table_name): `data` is required (esm-spec §9.5)"))
        end
        data_native = _to_native_json(entry_raw["data"])
        description = _maybe(string, get(entry_raw, "description", nothing))
        interpolation = _maybe(string, get(entry_raw, "interpolation", nothing))
        out_of_bounds = _maybe(string, get(entry_raw, "out_of_bounds", nothing))
        outputs = _maybe(_get_field(entry_raw, :outputs, nothing)) do os
            Vector{String}([string(s) for s in os])
        end
        shape = _maybe(_get_field(entry_raw, :shape, nothing)) do shp
            Vector{Int}([Int(s) for s in shp])
        end
        schema_version = _opt_string(entry_raw, :schema_version)
        out[table_name] = FunctionTable(axes_vec, data_native;
            description=description, interpolation=interpolation,
            out_of_bounds=out_of_bounds, outputs=outputs, shape=shape,
            schema_version=schema_version)
    end
    return out
end


"""
    coerce_metadata(data::Any) -> Metadata

Coerce JSON data into Metadata type.
"""
function coerce_metadata(data::Any)::Metadata
    name = string(data["name"])
    description = _opt_string(data, :description)
    authors = haskey(data, "authors") ? [string(a) for a in data["authors"]] : String[]
    license = _opt_string(data, :license)
    created = _opt_string(data, :created)
    modified = _opt_string(data, :modified)
    tags = haskey(data, "tags") ? [string(t) for t in data["tags"]] : String[]
    references = haskey(data, "references") ? [coerce_reference(r) for r in data["references"]] : Reference[]

    return Metadata(name,
                   description=description,
                   authors=authors,
                   license=license,
                   created=created,
                   modified=modified,
                   tags=tags,
                   references=references)
end

"""
    coerce_reference(data::Any) -> Reference

Coerce JSON data into Reference type.
"""
function coerce_reference(data::Any)::Reference
    doi = _opt_string(data, :doi)
    citation = _opt_string(data, :citation)
    url = _opt_string(data, :url)
    notes = _opt_string(data, :notes)

    return Reference(doi=doi, citation=citation, url=url, notes=notes)
end

"""
    coerce_model(data::Any) -> Model

Coerce JSON data into Model type.
"""
function coerce_model(data::Any)::Model
    variables = Dict{String,ModelVariable}()
    for (k, v) in pairs(data["variables"])
        variables[string(k)] = coerce_model_variable(v)
    end

    equations = [coerce_equation(eq) for eq in data["equations"]]

    # Handle new schema format with separate event arrays
    discrete_events = DiscreteEvent[]
    continuous_events = ContinuousEvent[]

    if haskey(data, "discrete_events")
        discrete_events = [coerce_discrete_event(ev) for ev in data["discrete_events"]]
    end

    if haskey(data, "continuous_events")
        continuous_events = [coerce_continuous_event(ev) for ev in data["continuous_events"]]
    end

    # Initialization equations and solver guesses (gt-ebuq).
    initialization_equations = _maybe(_get_field(data, :initialization_equations, nothing)) do eqs
        [coerce_equation(eq) for eq in eqs]
    end
    initialization_equations === nothing && (initialization_equations = Equation[])
    guesses = Dict{String,Union{Float64,ASTExpr}}()
    guesses_raw = _get_field(data, :guesses, nothing)
    if guesses_raw !== nothing
        for (k, v) in pairs(guesses_raw)
            if v isa Number
                guesses[string(k)] = Float64(v)
            else
                guesses[string(k)] = parse_expression(v)
            end
        end
    end
    system_kind = _opt_string(data, :system_kind)

    # Inline tests / tolerance (schema gt-cc1).
    tolerance = _maybe(coerce_tolerance, _get_field(data, :tolerance, nothing))
    tests_raw = _get_field(data, :tests, nothing)
    tests = tests_raw !== nothing ?
        EarthSciAST.InlineTest[coerce_test(t) for t in tests_raw] :
        EarthSciAST.InlineTest[]

    # Inline subsystems (schema §4.7, oneOf [Model, DataLoader, SubsystemRef]):
    # each entry is coerced by `_coerce_subsystem_entry`.
    subsystems = Dict{String,SubsystemNode}()
    subsystems_raw = _get_field(data, :subsystems, nothing)
    if subsystems_raw !== nothing
        for (k, v) in pairs(subsystems_raw)
            subsystems[string(k)] = _coerce_subsystem_entry(string(k), v)
        end
    end

    return Model(variables, equations;
                 discrete_events=discrete_events,
                 continuous_events=continuous_events,
                 subsystems=subsystems,
                 tolerance=tolerance,
                 tests=tests,
                 initialization_equations=initialization_equations,
                 guesses=guesses,
                 system_kind=system_kind)
end

"""
    _coerce_subsystem_entry(name::String, v) -> Union{Model,DataLoader,SubsystemRef}

Coerce one `subsystems` entry (schema §4.7, oneOf [Model, DataLoader,
SubsystemRef]): a child Model, a pure-I/O DataLoader (RFC pure-io-data-loaders
§4.3), or a `{"ref": "..."}` reference. Inline Model / DataLoader entries are
coerced recursively; ref entries become a `SubsystemRef` placeholder that
`resolve_subsystem_refs!` replaces in place with the loaded component. `name`
is the subsystem key, used only in metaparameter-binding diagnostics.
"""
function _coerce_subsystem_entry(name::String, v)
    if _get_field(v, :ref, nothing) !== nothing
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
        bindings = Dict{String,Int}()
        bindings_raw = _get_field(v, :bindings, nothing)
        if bindings_raw !== nothing
            for (bk, bv) in pairs(bindings_raw)
                bctx = "subsystems.$(name): binding '$(string(bk))'"
                expr = require_meta_expr(_to_native_json(bv), bctx)
                bindings[string(bk)] =
                    Int(eval_meta_expr(expr, Dict{String,Int64}(), bctx))
            end
        end
        # Optional `expression_template_imports` injects a discretization
        # into the REFERENCED component's own scope (esm-spec §9.7.10
        # form A). Kept as raw §9.7.2 entries; `_resolve_subsystem_ref`
        # threads them into the referenced document's load and the
        # §9.6.3 fixpoint consumes them before the mounted form is set.
        injected = Any[]
        imports_raw = _get_field(v, :expression_template_imports, nothing)
        if imports_raw !== nothing
            injected = Any[_to_native_json(e) for e in imports_raw]
        end
        return SubsystemRef(string(v["ref"]), bindings, injected)
    elseif haskey(v, "kind") && haskey(v, "source")
        # Loader-required fields (kind + source) discriminate an inline
        # data loader from a Model, which carries equations instead.
        return coerce_data_loader(v)
    else
        return coerce_model(v)
    end
end

"""
    coerce_tolerance(data::Any) -> Tolerance

Parse a schema `Tolerance` object into the Julia `Tolerance` struct.
"""
function coerce_tolerance(data::Any)::Tolerance
    abs_val = _opt_float(data, :abs)
    rel_val = _opt_float(data, :rel)
    return Tolerance(; abs=abs_val, rel=rel_val)
end

"""
    coerce_time_span(data::Any) -> TimeSpan

Parse a schema `TimeSpan` object.
"""
function coerce_time_span(data::Any)::TimeSpan
    start_val = Float64(data["start"])
    stop_val = Float64(data["end"])
    return TimeSpan(start_val, stop_val)
end

"""
    coerce_assertion(data::Any) -> Assertion

Parse a schema `Assertion` object.
"""
function coerce_assertion(data::Any)::Assertion
    variable = string(data["variable"])
    time_val = Float64(data["time"])
    expected = Float64(data["expected"])
    tolerance = _maybe(coerce_tolerance, _get_field(data, :tolerance, nothing))
    coords = nothing
    coords_raw = _get_field(data, :coords, nothing)
    if coords_raw !== nothing
        coords = Dict{String,Float64}()
        for (k, v) in pairs(coords_raw)
            coords[string(k)] = Float64(v)
        end
    end
    reduce_val = _opt_string(data, :reduce)
    reference = nothing
    ref = _get_field(data, :reference, nothing)
    if ref !== nothing
        # The from_file shape is a JSON object whose `type` is the literal
        # string "from_file"; everything else — including an inline Expression
        # AST, which is ALSO an object — is parsed as an Expression. The
        # discriminator MUST be the `type` field: testing "is it dict-like"
        # (the previous bug) routed every inline reference to the from_file
        # branch and left the §6.6.5 analytic-reference path unreachable.
        reftype = ref isa AbstractDict && haskey(ref, "type") ?
            string(ref["type"]) : ""
        if reftype == "from_file"
            reference = Dict{String,Any}()
            for (k, v) in pairs(ref)
                reference[string(k)] = v
            end
        else
            reference = parse_expression(ref)
        end
    end
    return Assertion(variable, time_val, expected;
                     tolerance=tolerance,
                     coords=coords,
                     reduce=reduce_val,
                     reference=reference)
end

"""
    coerce_test(data::Any) -> InlineTest

Parse a schema `InlineTest` object into the Julia `InlineTest` struct.
"""
function coerce_test(data::Any)::EarthSciAST.InlineTest
    id = string(data["id"])
    time_span = coerce_time_span(data["time_span"])
    assertions = [coerce_assertion(a) for a in data["assertions"]]
    description = _opt_string(data, :description)
    ic = Dict{String,Float64}()
    ic_raw = _get_field(data, :initial_conditions, nothing)
    if ic_raw !== nothing
        for (k, v) in pairs(ic_raw)
            ic[string(k)] = Float64(v)
        end
    end
    po = Dict{String,Float64}()
    po_raw = _get_field(data, :parameter_overrides, nothing)
    if po_raw !== nothing
        for (k, v) in pairs(po_raw)
            po[string(k)] = Float64(v)
        end
    end
    tolerance = _maybe(coerce_tolerance, _get_field(data, :tolerance, nothing))
    # esm-spec §9.7.10 form C / §6.6.6: raw §9.7.2 import entries naming the
    # discretization this test runs under. Retained (not consumed at load) so
    # the PDE runner can build a per-test ephemeral instance and so the field
    # survives round-trip.
    injected = Any[]
    imports_raw = _get_field(data, :expression_template_imports, nothing)
    if imports_raw !== nothing
        injected = Any[_to_native_json(e) for e in imports_raw]
    end
    return EarthSciAST.InlineTest(id, time_span, assertions;
        description=description,
        initial_conditions=ic,
        parameter_overrides=po,
        tolerance=tolerance,
        expression_template_imports=injected)
end

"""
    coerce_model_variable(data::Any) -> ModelVariable

Coerce JSON data into ModelVariable type.
"""
function coerce_model_variable(data::Any)::ModelVariable
    var_type = coerce_model_variable_type(string(data["type"]))
    default = _opt_float(data, :default)
    description = _opt_string(data, :description)
    expression = _maybe(parse_expression, _get_field(data, :expression, nothing))
    units = _opt_string(data, :units)
    default_units = _opt_string(data, :default_units)
    shape = _maybe(_get_field(data, :shape, nothing)) do shp
        String[string(d) for d in shp]
    end
    location = _opt_string(data, :location)
    noise_kind = _opt_string(data, :noise_kind)
    correlation_group = _opt_string(data, :correlation_group)

    return ModelVariable(var_type,
                        default=default,
                        description=description,
                        expression=expression,
                        units=units,
                        default_units=default_units,
                        shape=shape,
                        location=location,
                        noise_kind=noise_kind,
                        correlation_group=correlation_group)
end

"""
    coerce_equation(data::Any) -> Equation

Coerce JSON data into Equation type.
"""
function coerce_equation(data::Any)::Equation
    lhs = parse_expression(data["lhs"])
    rhs = parse_expression(data["rhs"])
    comment = _opt_string(data, :_comment)
    return Equation(lhs, rhs; _comment=comment)
end

"""
    coerce_discrete_event(data::Any) -> DiscreteEvent

Coerce JSON data specifically into DiscreteEvent.

Schema: DiscreteEvent must have a trigger, and exactly one of 'affects' (array
of AffectEquation) or 'functional_affect' (a registered handler descriptor).
Affects are stored as `AffectEquation`s ({lhs, rhs}), the same shape
`ContinuousEvent` uses. A schema 'functional_affect' handler descriptor is
preserved verbatim on the event's `functional_affect` field (it cannot be
executed symbolically, but it round-trips losslessly through serialize).
"""
function coerce_discrete_event(data::Any)::DiscreteEvent
    if !_has_field(data, :trigger)
        throw(ParseError("DiscreteEvent requires 'trigger' field"))
    end

    trigger = coerce_trigger(_get_field(data, :trigger, nothing))

    affects = AffectEquation[]
    if _has_field(data, :affects)
        raw_affects = _get_field(data, :affects, [])
        for a in raw_affects
            if !_has_field(a, :lhs) || !_has_field(a, :rhs)
                throw(ParseError("AffectEquation requires 'lhs' and 'rhs' fields"))
            end
            push!(affects, coerce_affect_equation(a))
        end
    end

    # Schema functional_affect is a registered handler descriptor
    # (handler_id, read_vars, read_params, modified_params?, config?). Keep
    # the raw descriptor so serialize re-emits it unchanged instead of
    # inventing a bogus {lhs, rhs} affect equation.
    functional_affect = _maybe(_to_native_json, _get_field(data, :functional_affect, nothing))

    description = _opt_string(data, :description)

    # Discrete parameters (MTK `discrete_parameters`): names the event mutates
    # as parameters rather than states. Kept on the event so `validate` can
    # check each names a declared parameter, and so serialize round-trips it.
    discrete_parameters = _maybe(Vector{String},
                                 _get_field(data, :discrete_parameters, nothing))

    return DiscreteEvent(trigger, affects, description=description,
                         functional_affect=functional_affect,
                         discrete_parameters=discrete_parameters)
end

"""
    coerce_continuous_event(data::Any) -> ContinuousEvent

Coerce JSON data specifically into ContinuousEvent.

Handles optional schema fields (affect_neg, root_find, name, discrete_parameters)
by ignoring them — the current Julia ContinuousEvent type does not model them,
but their presence must not cause load to fail.
"""
function coerce_continuous_event(data::Any)::ContinuousEvent
    if !_has_field(data, :conditions)
        throw(ParseError("ContinuousEvent requires 'conditions' field"))
    end

    raw_conditions = _get_field(data, :conditions, [])
    conditions = ASTExpr[parse_expression(c) for c in raw_conditions]

    raw_affects = _has_field(data, :affects) ? _get_field(data, :affects, []) : []
    affects = AffectEquation[coerce_affect_equation(a) for a in raw_affects]

    description = _opt_string(data, :description)

    return ContinuousEvent(conditions, affects, description=description)
end

"""
    coerce_affect_equation(data::Any) -> AffectEquation

Coerce JSON data into AffectEquation type.
"""
function coerce_affect_equation(data::Any)::AffectEquation
    # Through `_get_field` (string-keyed, null-as-absent), matching every
    # other coercion helper.
    lhs = string(_get_field(data, :lhs, ""))
    rhs = parse_expression(_get_field(data, :rhs, nothing))
    return AffectEquation(lhs, rhs)
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

    # Inline tests / tolerance (schema gt-cc1) — same shape as on Model.
    tolerance = _maybe(coerce_tolerance, _get_field(data, :tolerance, nothing))
    tests_raw = _get_field(data, :tests, nothing)
    tests = tests_raw !== nothing ?
        EarthSciAST.InlineTest[coerce_test(t) for t in tests_raw] :
        EarthSciAST.InlineTest[]

    return ReactionSystem(species, reactions; parameters=parameters,
                          tolerance=tolerance, tests=tests)
end

"""
    coerce_species(name::String, data::Any) -> Species

Coerce JSON data into Species type with explicit name.
"""
function coerce_species(name::String, data::Any)::Species
    units = _opt_string(data, :units)
    default = _opt_float(data, :default)
    description = _opt_string(data, :description)
    default_units = _opt_string(data, :default_units)
    constant = _maybe(Bool, _get_field(data, :constant, nothing))

    return Species(name, units=units, default=default, description=description, default_units=default_units, constant=constant)
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
        [StoichiometryEntry(string(entry["species"]), entry["stoichiometry"])
         for entry in entries]
    end
    substrates = stoich_entries("substrates")
    products = stoich_entries("products")

    rate = parse_expression(data["rate"])

    reference = _maybe(coerce_reference, get(data, "reference", nothing))

    return Reaction(id, substrates, products, rate, name=name, reference=reference)
end

"""
    coerce_parameter(name::String, data::Any) -> Parameter

Coerce JSON data into Parameter type with explicit name.
"""
function coerce_parameter(name::String, data::Any)::Parameter
    default = Float64(data["default"])
    description = _opt_string(data, :description)
    units = _opt_string(data, :units)
    default_units = _opt_string(data, :default_units)

    return Parameter(name, default, description=description, units=units, default_units=default_units)
end

"""
    coerce_data_loader_source(data::Any) -> DataLoaderSource

Coerce JSON data into a DataLoaderSource.
"""
function coerce_data_loader_source(data::Any)::DataLoaderSource
    url_template = string(data["url_template"])
    mirrors = _maybe(_get_field(data, :mirrors, nothing)) do ms
        [string(m) for m in ms]
    end
    return DataLoaderSource(url_template; mirrors=mirrors)
end

"""
    coerce_data_loader_temporal(data::Any) -> DataLoaderTemporal
"""
function coerce_data_loader_temporal(data::Any)::DataLoaderTemporal
    start = _opt_string(data, :start)
    stop = _opt_string(data, :end)
    file_period = _opt_string(data, :file_period)
    frequency = _opt_string(data, :frequency)
    records_per_file = _maybe(_get_field(data, :records_per_file, nothing)) do v
        v isa Number ? Int(v) : string(v)
    end
    time_variable = _opt_string(data, :time_variable)
    return DataLoaderTemporal(; start=start, stop=stop, file_period=file_period,
                              frequency=frequency, records_per_file=records_per_file,
                              time_variable=time_variable)
end

"""
    coerce_data_loader_variable(data::Any) -> DataLoaderVariable
"""
function coerce_data_loader_variable(data::Any)::DataLoaderVariable
    file_variable = string(data["file_variable"])
    units = string(data["units"])
    unit_conversion = _maybe(_get_field(data, :unit_conversion, nothing)) do v
        v isa Number ? Float64(v) : parse_expression(v)
    end
    description = _opt_string(data, :description)
    reference = _maybe(coerce_reference, _get_field(data, :reference, nothing))
    return DataLoaderVariable(file_variable, units;
                              unit_conversion=unit_conversion,
                              description=description,
                              reference=reference)
end

"""
    coerce_data_loader_determinism(data::Any) -> DataLoaderDeterminism
"""
function coerce_data_loader_determinism(data::Any)::DataLoaderDeterminism
    endian = _opt_string(data, :endian)
    float_format = _opt_string(data, :float_format)
    integer_width = _opt_int(data, :integer_width)
    return DataLoaderDeterminism(; endian=endian, float_format=float_format, integer_width=integer_width)
end

"""
    coerce_data_loader(data::Any) -> DataLoader

Coerce JSON data into the STAC-like DataLoader type.
"""
function coerce_data_loader(data::Any)::DataLoader
    kind = string(data["kind"])
    source = coerce_data_loader_source(data["source"])

    temporal = _maybe(coerce_data_loader_temporal, _get_field(data, :temporal, nothing))
    determinism = _maybe(coerce_data_loader_determinism, _get_field(data, :determinism, nothing))

    variables = Dict{String,DataLoaderVariable}(
        string(k) => coerce_data_loader_variable(v) for (k, v) in pairs(data["variables"])
    )

    reference = _maybe(coerce_reference, _get_field(data, :reference, nothing))
    metadata = _maybe(_to_native_json, _get_field(data, :metadata, nothing))

    return DataLoader(kind, source, variables;
                      temporal=temporal,
                      determinism=determinism,
                      reference=reference,
                      metadata=metadata)
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
    coerce_coupling_import(data::AbstractDict) -> CouplingImport

Parse a `coupling_import` coupling entry (esm-spec §10.10). The entry carries a
`ref` to a coupling-library file and a `bind` map (role name → component); it is
stored verbatim and expanded at flatten by `expand_coupling_imports`.
"""
function coerce_coupling_import(data::AbstractDict)::CouplingImport
    if !haskey(data, "ref")
        throw(ParseError("coupling_import requires 'ref' field"))
    end
    ref = String(data["ref"])
    bind = Dict{String,String}()
    bind_raw = _get_field(data, :bind, nothing)
    if bind_raw !== nothing
        if !(bind_raw isa AbstractDict)
            throw(ParseError("coupling_import 'bind' must be an object mapping role names to components"))
        end
        for (k, v) in pairs(bind_raw)
            bind[string(k)] = String(v)
        end
    end
    description = _opt_string(data, :description)
    return CouplingImport(ref, bind; description=description)
end

"""
    coerce_operator_compose(data::AbstractDict) -> CouplingOperatorCompose

Parse operator_compose coupling entry.
"""
function coerce_operator_compose(data::AbstractDict)::CouplingOperatorCompose
    if !haskey(data, "systems")
        throw(ParseError("operator_compose requires 'systems' field"))
    end

    systems = Vector{String}(data["systems"])
    # JSON3.Object keys are Symbols — convert to String explicitly so the
    # Dict{String,Any} field doesn't choke on Symbol→String conversion.
    translate = _maybe(_get_field(data, :translate, nothing)) do t
        Dict{String,Any}(string(k) => v for (k, v) in pairs(t))
    end
    description = _opt_string(data, :description)
    lifting = _opt_string(data, :lifting)

    return CouplingOperatorCompose(systems; translate=translate, description=description, lifting=lifting)
end

"""
    coerce_couple(data::AbstractDict) -> CouplingCouple

Parse couple coupling entry.
"""
function coerce_couple(data::AbstractDict)::CouplingCouple
    required_fields = ["systems", "connector"]
    for field in required_fields
        if !haskey(data, field)
            throw(ParseError("couple requires '$field' field"))
        end
    end

    systems = Vector{String}(data["systems"])
    # JSON3.Object keys are Symbols — convert to String explicitly so the
    # Dict{String,Any} constructor doesn't choke on Symbol→String conversion.
    connector_raw = data["connector"]
    connector = Dict{String,Any}(string(k) => v for (k, v) in pairs(connector_raw))
    description = _opt_string(data, :description)
    lifting = _opt_string(data, :lifting)

    return CouplingCouple(systems, connector; description=description, lifting=lifting)
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
        parse_expression(raw_transform)
    else
        throw(ParseError("variable_map 'transform' must be a named transform string or an expression operator node"))
    end
    factor = _opt_float(data, :factor)
    description = _opt_string(data, :description)
    lifting = _opt_string(data, :lifting)

    # The "an expression transform takes no factor" invariant is enforced ONCE,
    # by the `CouplingVariableMap` constructor (types.jl). The parser rebrands
    # that `ArgumentError` as a `ParseError` carrying the historical parse-side
    # message, so the error type/message seen from `load` is unchanged.
    try
        return CouplingVariableMap(from, to, transform; factor=factor, description=description, lifting=lifting)
    catch e
        if e isa ArgumentError && transform isa ASTExpr && factor !== nothing
            throw(ParseError("variable_map: an expression 'transform' takes no 'factor' (fold the scaling into the expression)"))
        end
        rethrow()
    end
end

"""
    coerce_operator_apply(data::AbstractDict) -> CouplingOperatorApply

Parse operator_apply coupling entry.
"""
function coerce_operator_apply(data::AbstractDict)::CouplingOperatorApply
    if !haskey(data, "operator")
        throw(ParseError("operator_apply requires 'operator' field"))
    end

    operator = String(data["operator"])
    description = _opt_string(data, :description)

    return CouplingOperatorApply(operator; description=description)
end

"""
    coerce_callback(data::AbstractDict) -> CouplingCallback

Parse callback coupling entry.
"""
function coerce_callback(data::AbstractDict)::CouplingCallback
    if !haskey(data, "callback_id")
        throw(ParseError("callback requires 'callback_id' field"))
    end

    callback_id = String(data["callback_id"])
    # JSON3.Object keys are Symbols; stringify explicitly.
    config = _maybe(_get_field(data, :config, nothing)) do c
        Dict{String,Any}(string(k) => v for (k, v) in pairs(c))
    end
    description = _opt_string(data, :description)

    return CouplingCallback(callback_id; config=config, description=description)
end

"""
    coerce_coupling_event(data::AbstractDict) -> CouplingEvent

Parse event coupling entry.

Named `coerce_coupling_event` (not `coerce_event`) so the coupling-entry
parser can never be confused with the model-event coercers
(`coerce_discrete_event` / `coerce_continuous_event`).
"""
function coerce_coupling_event(data::AbstractDict)::CouplingEvent
    if !haskey(data, "event_type")
        throw(ParseError("event requires 'event_type' field"))
    end

    event_type = String(data["event_type"])

    # Parse conditions for continuous events
    conditions = _maybe(_get_field(data, :conditions, nothing)) do cs
        ASTExpr[parse_expression(c) for c in cs]
    end

    # Parse trigger for discrete events
    trigger = _maybe(coerce_trigger, _get_field(data, :trigger, nothing))

    # Parse affects (required)
    if !haskey(data, "affects")
        throw(ParseError("event requires 'affects' field"))
    end
    affects = [coerce_affect_equation(a) for a in data["affects"]]

    # Parse optional fields
    affect_neg = _maybe(_get_field(data, :affect_neg, nothing)) do an
        [coerce_affect_equation(a) for a in an]
    end

    discrete_parameters = _maybe(Vector{String},
                                 _get_field(data, :discrete_parameters, nothing))

    root_find = _opt_string(data, :root_find)

    reinitialize = _maybe(Bool, _get_field(data, :reinitialize, nothing))

    description = _opt_string(data, :description)

    return CouplingEvent(event_type, affects;
                        conditions=conditions, trigger=trigger, affect_neg=affect_neg,
                        discrete_parameters=discrete_parameters, root_find=root_find,
                        reinitialize=reinitialize, description=description)
end

"""
    coerce_index_set(data::Any) -> IndexSet

Coerce one JSON `index_sets` registry entry into an `IndexSet`
(RFC semiring-faq-unified-ir §5.2). Kind-conditional fields (`size`, `members`,
`of`/`offsets`/`values`, `from_faq`) are read when present; completeness per kind
is enforced by JSON-schema validation, not here.
"""
function coerce_index_set(data::Any)::IndexSet
    kind_raw = _get_field(data, :kind, nothing)
    kind_raw === nothing &&
        throw(ParseError("index_sets entry requires a `kind` field"))
    size_val = _opt_int(data, :size)
    members_raw = _get_field(data, :members, nothing)
    members = members_raw === nothing ? nothing : String[string(x) for x in members_raw]
    # Keep the original member types ONLY when some member is not a string, so the
    # join-key validator can reject float / null keys (RFC §5.3). A string-only
    # set keeps `members_typed === nothing` and is unchanged from before.
    members_typed = members_raw === nothing ? nothing :
        (any(x -> !(x isa AbstractString), members_raw) ? Any[x for x in members_raw] : nothing)
    of_raw = _get_field(data, :of, nothing)
    of = of_raw === nothing ? nothing : String[string(x) for x in of_raw]
    offsets = _opt_string(data, :offsets)
    values = _opt_string(data, :values)
    from_faq = _opt_string(data, :from_faq)
    return IndexSet(string(kind_raw); size=size_val, members=members, of=of,
                    offsets=offsets, values=values, from_faq=from_faq,
                    members_raw=members_typed)
end

"""
    coerce_domain(data::Any) -> Domain

Coerce JSON data into Domain type.
"""
function coerce_domain(data::Any)::Domain
    temporal = _maybe(get(data, "temporal", nothing)) do t
        Dict{String,Any}(string(k) => v for (k, v) in pairs(t))
    end
    iv = get(data, "independent_variable", nothing)
    return Domain(independent_variable = iv === nothing ? "t" : string(iv),
                  temporal = temporal)
end
