"""
    OPEXPR_FIELD_TABLE

The `OpExpr` field-spec table, from which every field-generic consumer is
derived:

- the wire contract [`OPEXPR_WIRE_KEYS`](@ref) (parse + serialize key set),
- `_parse_op_optional_fields` (parse.jl, generated field extraction),
- `_serialize_opexpr_field` (serialize.jl, per-kind wire encoding),
- [`reconstruct(::OpExpr)`](@ref) (generated below),
- the expression walkers `child_exprs` / `foreach_child` /
  `_foreach_subexpr_children` / `map_children` / `foreach_child_with_path`
  (expression.jl, generated).

One row per struct field, in exact struct-field order (asserted at load).
Columns:

- `wire`: the JSON key the field is parsed from / serialized to (`nothing`
  for an internal, never-serialized field). Two fields are spelled
  differently on the wire: `int_var` ↔ `var` and `expr_body` ↔ `expr`.
- `kind`: the field's shape class, which determines BOTH its wire encoding
  and whether/how the expression walkers traverse it:
    - `:expr`      — optional nested `ASTExpr` (traversed),
    - `:expr_vec`  — `Vector{ASTExpr}` (traversed; `args` is the one
                     required instance, the rest are optional),
    - `:expr_map`  — `Dict{String,ASTExpr}` (values traversed in sorted-key
                     order). NOTE: `bindings` (template parameter →
                     argument-expression map) IS traversed like any other
                     expression-bearing field.
    - `:ranges`    — the `ranges` map: `IndexSetRef` or dense bound vectors
                     whose entries MAY be expression-valued (only those
                     `ASTExpr` entries are traversed),
    - `:join`      — the parsed join clauses (column-NAME strings, no
                     sub-expressions; bespoke wire encoding),
    - `:scalar`    — plain data (strings/ints/JSON), identity-encoded on the
                     wire, never traversed,
    - `:internal`  — build-time only; never parsed, serialized or traversed.
- `parse`: for `:scalar` fields, the parse-recipe tag `_parse_op_optional_fields`
  dispatches on (`:string`, `:int`, `:int_vec`, `:bool`, `:json`,
  `:output_idx`, `:regions`, `:shape`, `:attrs`); `nothing`
  when the `kind` alone determines parsing.
- `binds_scope`: `true` for the one field whose keys validate's
  `_bound_index_symbols` puts in reference-check scope (`bindings`, the
  template formal-parameter names). `free_variables`' binder subtraction
  (`_bound_symbols`) does not use it.

Adding an `OpExpr` field without a row here fails the load-time assert below;
`round_trip_regression_test.jl` then pins its real parse/serialize behavior.
"""
const OPEXPR_FIELD_TABLE = (
    op = (wire = :op, kind = :scalar, parse = nothing, binds_scope = false),
    args = (wire = :args, kind = :expr_vec, parse = nothing, binds_scope = false),
    wrt = (wire = :wrt, kind = :scalar, parse = :string, binds_scope = false),
    dim = (wire = :dim, kind = :scalar, parse = :string, binds_scope = false),
    int_var = (wire = :var, kind = :scalar, parse = :string, binds_scope = false),
    lower = (wire = :lower, kind = :expr, parse = nothing, binds_scope = false),
    upper = (wire = :upper, kind = :expr, parse = nothing, binds_scope = false),
    output_idx = (wire = :output_idx, kind = :scalar, parse = :output_idx, binds_scope = false),
    expr_body = (wire = :expr, kind = :expr, parse = nothing, binds_scope = false),
    reduce = (wire = :reduce, kind = :scalar, parse = :string, binds_scope = false),
    semiring = (wire = :semiring, kind = :scalar, parse = :string, binds_scope = false),
    ranges = (wire = :ranges, kind = :ranges, parse = nothing, binds_scope = false),
    regions = (wire = :regions, kind = :scalar, parse = :regions, binds_scope = false),
    values = (wire = :values, kind = :expr_vec, parse = nothing, binds_scope = false),
    shape = (wire = :shape, kind = :scalar, parse = :shape, binds_scope = false),
    perm = (wire = :perm, kind = :scalar, parse = :int_vec, binds_scope = false),
    axis = (wire = :axis, kind = :scalar, parse = :int, binds_scope = false),
    fn = (wire = :fn, kind = :scalar, parse = :string, binds_scope = false),
    name = (wire = :name, kind = :scalar, parse = :string, binds_scope = false),
    value = (wire = :value, kind = :scalar, parse = :json, binds_scope = false),
    units = (wire = :units, kind = :scalar, parse = :string, binds_scope = false),
    join = (wire = :join, kind = :join, parse = nothing, binds_scope = false),
    filter = (wire = :filter, kind = :expr, parse = nothing, binds_scope = false),
    join_gates = (wire = nothing, kind = :internal, parse = nothing, binds_scope = false),
    id = (wire = :id, kind = :scalar, parse = :string, binds_scope = false),
    distinct = (wire = :distinct, kind = :scalar, parse = :bool, binds_scope = false),
    key = (wire = :key, kind = :expr, parse = nothing, binds_scope = false),
    bindings = (wire = :bindings, kind = :expr_map, parse = nothing, binds_scope = true),
    expect_cadence = (wire = :expect_cadence, kind = :scalar, parse = :string, binds_scope = false),
    attrs = (wire = :attrs, kind = :scalar, parse = :attrs, binds_scope = false),
    template_origin = (wire = nothing, kind = :internal, parse = nothing, binds_scope = false),
)

# The table must cover EXACTLY the struct's fields, in struct-field order —
# the walkers/parse/serialize generators iterate it in this order.
@assert keys(OPEXPR_FIELD_TABLE) == fieldnames(OpExpr) "OPEXPR_FIELD_TABLE rows must match fieldnames(OpExpr) exactly, in order"

"""
    OPEXPR_WIRE_KEYS

The `OpExpr` field ↔ wire (JSON) key contract, DERIVED from
[`OPEXPR_FIELD_TABLE`](@ref): every field with a non-`nothing` `wire` column,
mapped to its JSON key. `join_gates` is the one struct field deliberately
absent: it is a build-time artifact, never parsed or serialized. Consumed by
`serialize_expression`'s emit loop and pinned field-by-field by
`round_trip_regression_test.jl`.
"""
const OPEXPR_WIRE_KEYS = (;
    (
        f => spec.wire for (f, spec) in pairs(OPEXPR_FIELD_TABLE)
            if spec.wire !== nothing
    )...,
)

# Accept any AbstractVector of ASTExpr-subtypes (e.g. Vector{VarExpr},
# Vector{OpExpr}, mixed Any arrays) and widen to Vector{ASTExpr}. This keeps
# call sites terse — callers don't need to annotate `ASTExpr[...]` when they
# construct a homogeneous argument list.
function OpExpr(op::String, args::AbstractVector; kwargs...)
    widened = Vector{ASTExpr}(undef, length(args))
    for (i, a) in enumerate(args)
        widened[i] = a
    end
    return OpExpr(op, widened; kwargs...)
end

# GENERATED from `fieldnames(OpExpr)` (see OPEXPR_FIELD_TABLE): one kwarg per
# struct field, each defaulting to the corresponding field of `e`, forwarded
# positionally (NamedTuple-free on the hot path) to `_new_typed` in
# struct-field order — so a newly added field is copied by default and can
# never be silently dropped.
@eval function reconstruct(
        e::OpExpr;
        op::String = e.op,
        args = e.args,
        $(
            (
                Expr(:kw, f, :(e.$f)) for f in fieldnames(OpExpr)
                    if f !== :op && f !== :args
            )...
        )
    )
    # Positional (NamedTuple-free) construction on the hot path. `args` defaults to
    # the `Vector{ASTExpr}` field and callers overwrite it with `Vector{ASTExpr}`s, so the
    # `isa` fast path is the norm; the widening branch accepts any
    # `AbstractVector` of `ASTExpr`, as the keyword constructor's
    # `OpExpr(op, args::AbstractVector)` overload does.
    argv = args isa Vector{ASTExpr} ? args : Vector{ASTExpr}(args)
    return _new_typed(
        OpExpr, op, argv,
        $((f for f in fieldnames(OpExpr) if f !== :op && f !== :args)...)
    )
end

@doc """
    reconstruct(e::OpExpr; op=…, args=…, <any OpExpr field>=…) -> OpExpr

Rebuild an `OpExpr`, copying EVERY field from `e` by default and overriding only
the keywords explicitly passed. This is the ONE canonical, field-preserving way
to reconstruct a node after a structural rewrite (substitution, namespacing,
simplification, canonicalization, …).

It exists because `OpExpr` carries ~25 optional fields (aggregate
`semiring`/`ranges`/`output_idx`/`expr_body`/`reduce`, relational
`join`/`filter`/`join_gates`/`distinct`/`key`, `int_var`/`lower`/`upper`, …) and
hand-listed reconstruction sites each drop whatever they forget, which makes
`flatten`/`substitute`/`namespace_expr` lossy. Routing every rewrite through `reconstruct` makes
field preservation the default and a drop an explicit, visible choice — and the
method is GENERATED from `fieldnames(OpExpr)`, so a newly added field is
preserved automatically.

Callers that transform sub-expressions should pass the already-transformed
result for the relevant field, e.g. `reconstruct(e; args=new_args)` or
`reconstruct(e; expr_body=new_body, filter=new_filter)`.

    reconstruct(x; <any field of x>=…)

The same for every document record type in [`RECORD_FIELD_TABLES`](@ref) and
for `ReactionSystem` and `EsmFile` (generated below the tables): every field is
copied from `x` unless passed, and the result is built through the type's
constructor, so its normalizations and checks run.
""" reconstruct


# Record wire-mapping tables

"""
    RECORD_FIELD_TABLES

The per-type field-spec tables for the regular record types, from which both
wire directions are generated (`coerce_<fn>` in parse.jl, `serialize_<fn>` in
serialize.jl). One entry per type:

- `T`: the struct's name (a `Symbol`; resolved in this module).
- `fn`: the coercer/serializer name suffix (`coerce_<fn>` / `serialize_<fn>`).
- `tag`: for a coupling-entry type, the `"type"` discriminator string the
  serializer emits first (`nothing`/absent otherwise; the parse side never
  reads it — `coerce_coupling_entry` dispatches on it before calling in).
- `injected`: `true` when the record's `name` is the KEY of an enclosing
  name-keyed map, injected as the coercer's first argument and never
  read from or emitted to the record's own wire body (Species, Parameter).
- `rows`: one row per struct field, in parse order (which fixes which
  ParseError a node with several invalid fields reports; emission follows the
  same order). Row columns:
    - `f`: struct field name == constructor keyword name.
    - `wire`: the JSON key (renames live here: `stop` ↔ `"end"`).
    - `kind`: the value class, naming the coercion/encoding pair —
      `:string` (`string(v)`/identity), `:string_strict` (`String(v)`),
      `:float`, `:int`, `:bool`, `:number_or_string`, `:number_or_expr`,
      `:variable_bound` (number kept as authored, or a name; esm-spec §6.3.2),
      `:expr`, `:expr_vec`, `:string_vec` (`string.()` each),
      `:string_vec_strict` (`Vector{String}(v)`), `:float_map`,
      `:value_map` (scalar-or-inline-array map, esm-spec §6.6.2),
      `:inline_value` (scalar-or-inline-array, esm-spec §6.3),
      `:str_keyed_copy` (string-keyed shallow `Dict{String,Any}` copy),
      `:raw` (`_to_native_json` verbatim passthrough), `:raw_vec`,
      `:model_variable_type`, `:record`/`:record_vec`/`:record_map`
      (nested `coerce_<of>`/`serialize_<of>`; `T` names the element type),
      `:custom` (`parse_fn` on the fetched value; `emit_fn` on the struct).
    - `mode`: parse-side fetch policy — `:req` (`data[wire]`, KeyError when
      missing), `:req_err`
      (`_raw_haskey` guard throwing the PINNED `req_err` message; a JSON
      `null` value then flows to the converter — or to `default` when the
      row has one), `:req_nullerr`
      (null-or-absent throws `req_err`), `:opt` (absent/null → `nothing`),
      `:opt_empty` (absent/null → `default`), `:default` (absent/null →
      `default`, present → converted), `:force` (fetch null-as-absent and
      convert unconditionally, so the converter's own error surfaces).
    - `emit`: serialize-side omission policy — `:always`, `:nonnothing`,
      `:nonempty`, `:nondefault` (against `default`), `:custom`
      (`emit_fn(x)`, `nothing` skips the key), `:never`.
    - `pos`: `true` for the constructor's positional arguments (in row
      order); all other rows pass as keywords.

Hand-written instead: the discriminated unions (`coerce_coupling_entry`,
`coerce_trigger` / `serialize_trigger`, `_coerce_subsystem_entry` /
`_serialize_subsystem`), `ReactionSystem`, `Reaction`, `CouplingVariableMap`,
`coerce_enums` and the `EsmFile` orchestrator.

A load-time assert (below) pins each entry's rows to `fieldnames(T)` exactly;
`round_trip_regression_test.jl` / `conformance_round_trip_test.jl` pin the
wire behavior.
"""
const RECORD_FIELD_TABLES = (
    (
        T = :Reference, fn = :reference, rows = (
            (f = :doi, wire = "doi", kind = :string, mode = :opt, emit = :nonnothing),
            (f = :citation, wire = "citation", kind = :string, mode = :opt, emit = :nonnothing),
            (f = :url, wire = "url", kind = :string, mode = :opt, emit = :nonnothing),
            (f = :notes, wire = "notes", kind = :string, mode = :opt, emit = :nonnothing),
        ),
    ),
    (
        T = :Metadata, fn = :metadata, rows = (
            (f = :name, wire = "name", kind = :string, mode = :req, emit = :always, pos = true),
            (f = :description, wire = "description", kind = :string, mode = :opt, emit = :nonnothing),
            (f = :authors, wire = "authors", kind = :string_vec, mode = :opt_empty, default = :(String[]), emit = :nonempty),
            (f = :license, wire = "license", kind = :string, mode = :opt, emit = :nonnothing),
            (f = :created, wire = "created", kind = :string, mode = :opt, emit = :nonnothing),
            (f = :modified, wire = "modified", kind = :string, mode = :opt, emit = :nonnothing),
            (f = :tags, wire = "tags", kind = :string_vec, mode = :opt_empty, default = :(String[]), emit = :nonempty),
            (
                f = :references, wire = "references", kind = :record_vec, of = :reference, eltype = :Reference,
                mode = :opt_empty, default = :(Reference[]), emit = :nonempty,
            ),
            # `discretize()` diagnostics (RFC §12) and the reserved `x_esd`
            # extension point — all four kept VERBATIM, never interpreted here.
            (f = :system_class, wire = "system_class", kind = :string, mode = :opt, emit = :nonnothing),
            (f = :dae_info, wire = "dae_info", kind = :raw, mode = :opt, emit = :nonnothing),
            (f = :discretized_from, wire = "discretized_from", kind = :raw, mode = :opt, emit = :nonnothing),
            (f = :x_esd, wire = "x_esd", kind = :raw, mode = :opt, emit = :nonnothing),
        ),
    ),
    (
        T = :Tolerance, fn = :tolerance, rows = (
            (f = :abs, wire = "abs", kind = :float, mode = :opt, emit = :nonnothing),
            (f = :rel, wire = "rel", kind = :float, mode = :opt, emit = :nonnothing),
        ),
    ),
    (
        T = :TimeSpan, fn = :time_span, rows = (
            (f = :start, wire = "start", kind = :float, mode = :req, emit = :always, pos = true),
            (f = :stop, wire = "end", kind = :float, mode = :req, emit = :always, pos = true),
        ),
    ),
    (
        T = :Species, fn = :species, injected = true, rows = (
            (f = :units, wire = "units", kind = :string, mode = :opt, emit = :nonnothing),
            (f = :default, wire = "default", kind = :float, mode = :opt, emit = :nonnothing),
            (f = :description, wire = "description", kind = :string, mode = :opt, emit = :nonnothing),
            (f = :default_units, wire = "default_units", kind = :string, mode = :opt, emit = :nonnothing),
            (f = :constant, wire = "constant", kind = :bool, mode = :opt, emit = :nonnothing),
        ),
    ),
    (
        T = :Parameter, fn = :parameter, injected = true, rows = (
            # `default` is OPTIONAL: esm-schema.json's `Parameter` declares no
            # `required` list, so a parameter valued by a `distribution` (or wholly
            # by a data-source `update`) legally carries none. `mode = :req` here
            # made such a document a hard `KeyError` at load — not a drop, a
            # rejection of a conforming file.
            (f = :default, wire = "default", kind = :float, mode = :opt, emit = :nonnothing, pos = true),
            (f = :description, wire = "description", kind = :string, mode = :opt, emit = :nonnothing),
            (f = :units, wire = "units", kind = :string, mode = :opt, emit = :nonnothing),
            (f = :default_units, wire = "default_units", kind = :string, mode = :opt, emit = :nonnothing),
            (f = :shape, wire = "shape", kind = :string_vec, mode = :opt, emit = :nonnothing),
            # The §6.3 value model, shared verbatim with `ModelVariable`: both name
            # the same hand-written hook pairs (per-kind distribution spelling; the
            # object-or-array `update` union).
            (
                f = :distribution, wire = "distribution", kind = :custom,
                parse_fn = :coerce_distribution, mode = :opt,
                emit = :custom, emit_fn = :_emit_distribution,
            ),
            (
                f = :update, wire = "update", kind = :custom,
                parse_fn = :_coerce_parameter_update_spec, mode = :opt,
                emit = :custom, emit_fn = :_emit_parameter_update_spec,
            ),
        ),
    ),
    (
        T = :Equation, fn = :equation, rows = (
            (f = :lhs, wire = "lhs", kind = :expr, mode = :req, emit = :always, pos = true),
            (f = :rhs, wire = "rhs", kind = :expr, mode = :req, emit = :always, pos = true),
            (f = :_comment, wire = "_comment", kind = :string, mode = :opt, emit = :nonnothing),
        ),
    ),
    (
        T = :AffectEquation, fn = :affect_equation, rows = (
            (f = :lhs, wire = "lhs", kind = :string, mode = :default, default = "", emit = :always, pos = true),
            (f = :rhs, wire = "rhs", kind = :expr, mode = :force, emit = :always, pos = true),
        ),
    ),
    (
        T = :Domain, fn = :domain, rows = (
            (
                f = :independent_variable, wire = "independent_variable", kind = :string,
                mode = :default, default = "t", emit = :nondefault,
            ),
            (f = :temporal, wire = "temporal", kind = :str_keyed_copy, mode = :opt, emit = :nonnothing),
            (f = :element_type, wire = "element_type", kind = :string, mode = :opt, emit = :nonnothing),
            (f = :array_type, wire = "array_type", kind = :string, mode = :opt, emit = :nonnothing),
        ),
    ),
    (
        T = :DataSourceLocation, fn = :data_source_location, rows = (
            (f = :url_template, wire = "url_template", kind = :string, mode = :req, emit = :always, pos = true),
            (f = :mirrors, wire = "mirrors", kind = :string_vec, mode = :opt, emit = :nonnothing),
        ),
    ),
    (
        T = :DataSourceTemporal, fn = :data_source_temporal, rows = (
            (f = :start, wire = "start", kind = :string, mode = :opt, emit = :nonnothing),
            (f = :stop, wire = "end", kind = :string, mode = :opt, emit = :nonnothing),
            (f = :file_period, wire = "file_period", kind = :string, mode = :opt, emit = :nonnothing),
            (f = :frequency, wire = "frequency", kind = :string, mode = :opt, emit = :nonnothing),
            (f = :records_per_file, wire = "records_per_file", kind = :number_or_string, mode = :opt, emit = :nonnothing),
            (f = :time_variable, wire = "time_variable", kind = :string, mode = :opt, emit = :nonnothing),
            (f = :records_per_sample, wire = "records_per_sample", kind = :int, mode = :opt, emit = :nonnothing),
        ),
    ),
    (
        T = :DataSourceDeterminism, fn = :data_source_determinism, rows = (
            (f = :endian, wire = "endian", kind = :string, mode = :opt, emit = :nonnothing),
            (f = :float_format, wire = "float_format", kind = :string, mode = :opt, emit = :nonnothing),
            (f = :integer_width, wire = "integer_width", kind = :int, mode = :opt, emit = :nonnothing),
        ),
    ),
    (
        T = :DataSource, fn = :data_source, rows = (
            (f = :kind, wire = "kind", kind = :string, mode = :req, emit = :always, pos = true),
            (f = :source, wire = "source", kind = :record, of = :data_source_location, mode = :req, emit = :always, pos = true),
            (f = :temporal, wire = "temporal", kind = :record, of = :data_source_temporal, mode = :opt, emit = :nonnothing),
            # Emit-side residue AS A COLUMN: determinism is emitted only when
            # present AND its serialized dict is non-empty — a doubly
            # conditional policy, so it names a hand-written hook.
            (
                f = :determinism, wire = "determinism", kind = :record, of = :data_source_determinism, mode = :opt,
                emit = :custom, emit_fn = :_emit_data_source_determinism,
            ),
            # The decode / slice / filter blocks, kept VERBATIM: nothing in this
            # package reads them back — their job is to reach the format reader
            # that does, unchanged (esm-spec §8).
            (f = :reader_options, wire = "reader_options", kind = :raw, mode = :opt, emit = :nonnothing),
            (f = :select, wire = "select", kind = :raw, mode = :opt, emit = :nonnothing),
            (f = :record_filter, wire = "record_filter", kind = :raw, mode = :opt, emit = :nonnothing),
            (f = :extent, wire = "extent", kind = :raw, mode = :opt, emit = :nonnothing),
            (f = :reference, wire = "reference", kind = :record, of = :reference, mode = :opt, emit = :nonnothing),
            (f = :metadata, wire = "metadata", kind = :raw, mode = :opt, emit = :nonnothing),
        ),
    ),
    (
        T = :CouplingImport, fn = :coupling_import, tag = "coupling_import", rows = (
            (
                f = :ref, wire = "ref", kind = :string_strict, mode = :req_err,
                req_err = "coupling_import requires 'ref' field", emit = :always, pos = true,
            ),
            (
                f = :bind, wire = "bind", kind = :custom, parse_fn = :_coerce_coupling_import_bind,
                mode = :opt_empty, default = :(Dict{String, String}()),
                emit = :custom, emit_fn = :_emit_coupling_import_bind, pos = true,
            ),
            (f = :description, wire = "description", kind = :string, mode = :opt, emit = :nonnothing),
        ),
    ),
    (
        T = :CouplingOperatorCompose, fn = :operator_compose, tag = "operator_compose", rows = (
            (
                f = :systems, wire = "systems", kind = :string_vec_strict, mode = :req_err,
                req_err = "operator_compose requires 'systems' field", emit = :always, pos = true,
            ),
            (f = :translate, wire = "translate", kind = :str_keyed_copy, mode = :opt, emit = :nonnothing),
            (f = :description, wire = "description", kind = :string, mode = :opt, emit = :nonnothing),
            (f = :lifting, wire = "lifting", kind = :string, mode = :opt, emit = :nonnothing),
            # esm-libraries-spec §4.7.1 step 5. TRI-STATE, so `:opt`/`:nonnothing`
            # rather than a defaulted bool: an ABSENT key and an explicit `false`
            # mean different things, and an explicit `false` must survive the round
            # trip — dropping it as "the default" would silently re-arm the
            # zero-merge refusal on every document that opted out.
            (
                f = :require_match, wire = "require_match", kind = :bool,
                mode = :opt, emit = :nonnothing,
            ),
        ),
    ),
    (
        T = :CouplingCouple, fn = :couple, tag = "couple", rows = (
            (
                f = :systems, wire = "systems", kind = :string_vec_strict, mode = :req_err,
                req_err = "couple requires 'systems' field", emit = :always, pos = true,
            ),
            (
                f = :connector, wire = "connector", kind = :str_keyed_copy, mode = :req_err,
                req_err = "couple requires 'connector' field", emit = :always, pos = true,
            ),
            (f = :description, wire = "description", kind = :string, mode = :opt, emit = :nonnothing),
            (f = :lifting, wire = "lifting", kind = :string, mode = :opt, emit = :nonnothing),
        ),
    ),
    (
        T = :CouplingOperatorApply, fn = :operator_apply, tag = "operator_apply", rows = (
            (
                f = :operator, wire = "operator", kind = :string_strict, mode = :req_err,
                req_err = "operator_apply requires 'operator' field", emit = :always, pos = true,
            ),
            (f = :description, wire = "description", kind = :string, mode = :opt, emit = :nonnothing),
        ),
    ),
    (
        T = :CouplingCallback, fn = :callback, tag = "callback", rows = (
            (
                f = :callback_id, wire = "callback_id", kind = :string_strict, mode = :req_err,
                req_err = "callback requires 'callback_id' field", emit = :always, pos = true,
            ),
            (f = :config, wire = "config", kind = :str_keyed_copy, mode = :opt, emit = :nonnothing),
            (f = :description, wire = "description", kind = :string, mode = :opt, emit = :nonnothing),
        ),
    ),
    (
        T = :CouplingEvent, fn = :coupling_event, tag = "event", rows = (
            (
                f = :event_type, wire = "event_type", kind = :string_strict, mode = :req_err,
                req_err = "event requires 'event_type' field", emit = :always, pos = true,
            ),
            (f = :name, wire = "name", kind = :string, mode = :opt, emit = :nonnothing),
            (f = :conditions, wire = "conditions", kind = :expr_vec, mode = :opt, emit = :nonnothing),
            (f = :trigger, wire = "trigger", kind = :record, of = :trigger, mode = :opt, emit = :nonnothing),
            (
                f = :affects, wire = "affects", kind = :record_vec, of = :affect_equation,
                eltype = :AffectEquation, mode = :req_err,
                req_err = "event requires 'affects' field", emit = :always, pos = true,
            ),
            (
                f = :affect_neg, wire = "affect_neg", kind = :record_vec, of = :affect_equation,
                eltype = :AffectEquation, mode = :opt, emit = :nonnothing,
            ),
            (f = :root_find, wire = "root_find", kind = :string, mode = :opt, emit = :nonnothing),
            (f = :reinitialize, wire = "reinitialize", kind = :bool, mode = :opt, emit = :nonnothing),
            (f = :description, wire = "description", kind = :string, mode = :opt, emit = :nonnothing),
        ),
    ),
    (
        T = :IndexSet, fn = :index_set, rows = (
            (
                f = :kind, wire = "kind", kind = :string, mode = :req_nullerr,
                req_err = "index_sets entry requires a `kind` field", emit = :always, pos = true,
            ),
            (f = :size, wire = "size", kind = :int, mode = :opt, emit = :nonnothing),
            # ONE wire key, TWO struct fields (the §5.3 representation policy):
            # `members` is the stringified convenience view; `members_raw` retains
            # the originally-typed values only when some member is non-string, and
            # is what round-trips back to the wire `members` key when present.
            (
                f = :members, wire = "members", kind = :custom, parse_fn = :_coerce_index_set_members,
                mode = :opt, emit = :custom, emit_fn = :_emit_index_set_members,
            ),
            (
                f = :members_raw, wire = "members", kind = :custom,
                parse_fn = :_coerce_index_set_members_raw, mode = :opt, emit = :never,
            ),
            (f = :of, wire = "of", kind = :string_vec, mode = :opt, emit = :nonnothing),
            (f = :offsets, wire = "offsets", kind = :string, mode = :opt, emit = :nonnothing),
            (f = :values, wire = "values", kind = :string, mode = :opt, emit = :nonnothing),
            (f = :from_faq, wire = "from_faq", kind = :string, mode = :opt, emit = :nonnothing),
            (f = :member_factor, wire = "member_factor", kind = :string, mode = :opt, emit = :nonnothing),
            (f = :records, wire = "records", kind = :bool, mode = :opt, emit = :nonnothing),
        ),
    ),
    (
        T = :ModelVariable, fn = :model_variable, rows = (
            (f = :type, wire = "type", kind = :model_variable_type, mode = :req, emit = :always, pos = true),
            # Scalar, or INLINE ARRAY DATA for a shaped variable (esm-spec §6.3).
            (f = :default, wire = "default", kind = :inline_value, mode = :opt, emit = :nonnothing),
            (f = :description, wire = "description", kind = :string, mode = :opt, emit = :nonnothing),
            (f = :units, wire = "units", kind = :string, mode = :opt, emit = :nonnothing),
            (f = :default_units, wire = "default_units", kind = :string, mode = :opt, emit = :nonnothing),
            (f = :shape, wire = "shape", kind = :string_vec, mode = :opt, emit = :nonnothing),
            (f = :location, wire = "location", kind = :string, mode = :opt, emit = :nonnothing),
            # The two parameter value fields of esm 1.0.0 (§6.3). `distribution`
            # spells its parameters differently per kind and `update` is an
            # object-or-array union, so both name hand-written hook pairs rather
            # than a column shape the table can express.
            (
                f = :distribution, wire = "distribution", kind = :custom,
                parse_fn = :coerce_distribution, mode = :opt,
                emit = :custom, emit_fn = :_emit_distribution,
            ),
            (
                f = :update, wire = "update", kind = :custom,
                parse_fn = :_coerce_parameter_update_spec, mode = :opt,
                emit = :custom, emit_fn = :_emit_parameter_update_spec,
            ),
            (f = :element_type, wire = "element_type", kind = :string, mode = :opt, emit = :nonnothing),
            # esm-spec §6.3.2: a number or a variable name, emitted as authored.
            (f = :lb, wire = "lb", kind = :variable_bound, mode = :opt, emit = :nonnothing),
            (f = :ub, wire = "ub", kind = :variable_bound, mode = :opt, emit = :nonnothing),
        ),
    ),
    (
        T = :FunctionalUpdate, fn = :functional_update, rows = (
            (
                f = :handler_id, wire = "handler_id", kind = :string_strict, mode = :req_err,
                req_err = "update handler requires a 'handler_id' field", emit = :always, pos = true,
            ),
            (f = :read_vars, wire = "read_vars", kind = :string_vec, mode = :opt, emit = :nonnothing),
            (f = :read_params, wire = "read_params", kind = :string_vec, mode = :opt, emit = :nonnothing),
            (f = :config, wire = "config", kind = :str_keyed_copy, mode = :opt, emit = :nonnothing),
        ),
    ),
    (
        T = :DataSourceBinding, fn = :data_source_binding, rows = (
            (
                f = :file_variable, wire = "file_variable", kind = :string_strict, mode = :req_err,
                req_err = "update 'from' requires a 'file_variable' field", emit = :always, pos = true,
            ),
            (f = :unit_conversion, wire = "unit_conversion", kind = :number_or_expr, mode = :opt, emit = :nonnothing),
            (f = :codes, wire = "codes", kind = :str_keyed_copy, mode = :opt, emit = :nonnothing),
            (f = :select, wire = "select", kind = :str_keyed_copy, mode = :opt, emit = :nonnothing),
            (f = :records_per_sample, wire = "records_per_sample", kind = :int, mode = :opt, emit = :nonnothing),
            (f = :description, wire = "description", kind = :string, mode = :opt, emit = :nonnothing),
            (f = :reference, wire = "reference", kind = :record, of = :reference, mode = :opt, emit = :nonnothing),
        ),
    ),
    (
        T = :ParameterUpdate, fn = :parameter_update, rows = (
            (
                f = :kind, wire = "kind", kind = :string_strict, mode = :req_nullerr,
                req_err = "parameter update requires a 'kind' field", emit = :always, pos = true,
            ),
            (f = :times, wire = "times", kind = :float_vec, mode = :opt, emit = :nonnothing),
            (f = :interval, wire = "interval", kind = :float, mode = :opt, emit = :nonnothing),
            (f = :initial_offset, wire = "initial_offset", kind = :float, mode = :opt, emit = :nonnothing),
            (f = :when, wire = "when", kind = :expr, mode = :opt, emit = :nonnothing),
            (f = :direction, wire = "direction", kind = :string, mode = :opt, emit = :nonnothing),
            (f = :source, wire = "source", kind = :string, mode = :opt, emit = :nonnothing),
            (f = :hook, wire = "hook", kind = :string, mode = :opt, emit = :nonnothing),
            (f = :expression, wire = "expression", kind = :expr, mode = :opt, emit = :nonnothing),
            (f = :from, wire = "from", kind = :record, of = :data_source_binding, mode = :opt, emit = :nonnothing),
            (f = :handler, wire = "handler", kind = :record, of = :functional_update, mode = :opt, emit = :nonnothing),
        ),
    ),
    (
        T = :ContinuousEvent, fn = :continuous_event, rows = (
            (
                f = :conditions, wire = "conditions", kind = :expr_vec, mode = :req_err,
                req_err = "ContinuousEvent requires 'conditions' field", default = :(ASTExpr[]),
                emit = :always, pos = true,
            ),
            (
                f = :affects, wire = "affects", kind = :record_vec, of = :affect_equation,
                eltype = :AffectEquation, mode = :opt_empty, default = :(AffectEquation[]),
                emit = :always, pos = true,
            ),
            (
                f = :affect_neg, wire = "affect_neg", kind = :record_vec, of = :affect_equation,
                eltype = :AffectEquation, mode = :opt, emit = :nonnothing,
            ),
            (f = :root_find, wire = "root_find", kind = :string, mode = :opt, emit = :nonnothing),
            (f = :reinitialize, wire = "reinitialize", kind = :bool, mode = :opt, emit = :nonnothing),
            (f = :description, wire = "description", kind = :string, mode = :opt, emit = :nonnothing),
            (f = :name, wire = "name", kind = :string, mode = :opt, emit = :nonnothing),
        ),
    ),
    (
        T = :DiscreteEvent, fn = :discrete_event, rows = (
            (
                f = :trigger, wire = "trigger", kind = :record, of = :trigger, mode = :req_err,
                req_err = "DiscreteEvent requires 'trigger' field", emit = :always, pos = true,
            ),
            # `affects` is the only affect channel; a handler lives on the
            # parameter it writes (`update.handler`), and an `affects` LHS naming
            # a parameter is `event_affects_parameter`.
            # `:custom` names a hand-written hook on BOTH sides. Parse keeps the
            # per-entry lhs/rhs presence check; emit must name a hook too, because
            # `_record_emit_expr` has no `:custom` case and would otherwise emit the
            # `AffectEquation` structs verbatim — a JSON3 field dump carrying `wrt`,
            # `label`, `output`, … that does not validate against the schema.
            (
                f = :affects, wire = "affects", kind = :custom, parse_fn = :_coerce_discrete_affects,
                mode = :opt_empty, default = :(AffectEquation[]),
                emit = :custom, emit_fn = :_emit_discrete_event_affects, pos = true,
            ),
            (f = :reinitialize, wire = "reinitialize", kind = :bool, mode = :opt, emit = :nonnothing),
            (f = :description, wire = "description", kind = :string, mode = :opt, emit = :nonnothing),
            (f = :name, wire = "name", kind = :string, mode = :opt, emit = :nonnothing),
        ),
    ),
    (
        T = :Assertion, fn = :assertion, rows = (
            (f = :variable, wire = "variable", kind = :string, mode = :req, emit = :always, pos = true),
            (f = :time, wire = "time", kind = :float, mode = :req, emit = :always, pos = true),
            (f = :expected, wire = "expected", kind = :float, mode = :req, emit = :always, pos = true),
            (f = :tolerance, wire = "tolerance", kind = :record, of = :tolerance, mode = :opt, emit = :nonnothing),
            (f = :coords, wire = "coords", kind = :float_map, mode = :opt, emit = :nonnothing),
            (f = :reduce, wire = "reduce", kind = :string, mode = :opt, emit = :nonnothing),
            # from_file-vs-Expression discriminated union (spec §6.6.5): the
            # `type` field — not dict-ness — routes to the verbatim from_file
            # shape; anything else parses as an Expression AST.
            (
                f = :reference, wire = "reference", kind = :custom, parse_fn = :_coerce_assertion_reference,
                mode = :opt, emit = :custom, emit_fn = :_emit_assertion_reference,
            ),
        ),
    ),
    (
        T = :InlineTest, fn = :test, rows = (
            (f = :id, wire = "id", kind = :string, mode = :req, emit = :always, pos = true),
            (
                f = :time_span, wire = "time_span", kind = :record, of = :time_span, mode = :req,
                emit = :always, pos = true,
            ),
            (
                f = :assertions, wire = "assertions", kind = :record_vec, of = :assertion,
                eltype = :Assertion, mode = :req, emit = :always, pos = true,
            ),
            (f = :description, wire = "description", kind = :string, mode = :opt, emit = :nonnothing),
            (
                f = :initial_conditions, wire = "initial_conditions", kind = :value_map,
                mode = :opt_empty, default = :(Dict{String, Any}()), emit = :nonempty,
            ),
            (
                f = :parameter_overrides, wire = "parameter_overrides", kind = :value_map,
                mode = :opt_empty, default = :(Dict{String, Any}()), emit = :nonempty,
            ),
            (f = :tolerance, wire = "tolerance", kind = :record, of = :tolerance, mode = :opt, emit = :nonnothing),
            # esm-spec §9.7.10 form C: a test's injected imports are authored
            # per-run config and DO survive parse → emit (unlike a component's
            # own imports, which the load-time fixpoint consumes).
            (
                f = :expression_template_imports, wire = "operator_imports", kind = :raw_vec,
                mode = :opt_empty, default = :(Any[]), emit = :nonempty,
            ),
        ),
    ),
    (
        T = :Model, fn = :model, rows = (
            (
                f = :variables, wire = "variables", kind = :record_map, of = :model_variable,
                eltype = :ModelVariable, mode = :req, emit = :always, pos = true,
            ),
            (
                f = :equations, wire = "equations", kind = :record_vec, of = :equation,
                eltype = :Equation, mode = :req, emit = :always, pos = true,
            ),
            (
                f = :discrete_events, wire = "discrete_events", kind = :record_vec, of = :discrete_event,
                eltype = :DiscreteEvent, mode = :opt_empty, default = :(DiscreteEvent[]), emit = :nonempty,
            ),
            (
                f = :continuous_events, wire = "continuous_events", kind = :record_vec, of = :continuous_event,
                eltype = :ContinuousEvent, mode = :opt_empty, default = :(ContinuousEvent[]), emit = :nonempty,
            ),
            (
                f = :initialization_equations, wire = "initialization_equations", kind = :record_vec,
                of = :equation, eltype = :Equation, mode = :opt_empty, default = :(Equation[]),
                emit = :nonempty,
            ),
            # number-or-Expression solver guesses — a per-value union,
            # so a hand-written hook pair.
            (
                f = :guesses, wire = "guesses", kind = :custom, parse_fn = :_coerce_model_guesses,
                mode = :opt_empty, default = :(Dict{String, Union{Float64, ASTExpr}}()),
                emit = :custom, emit_fn = :_emit_model_guesses,
            ),
            (f = :system_kind, wire = "system_kind", kind = :string, mode = :opt, emit = :nonnothing),
            (f = :tolerance, wire = "tolerance", kind = :record, of = :tolerance, mode = :opt, emit = :nonnothing),
            (
                f = :tests, wire = "tests", kind = :record_vec, of = :test, eltype = :InlineTest,
                mode = :opt_empty, default = :(InlineTest[]), emit = :nonempty,
            ),
            # Inline analyses, carried VERBATIM (nothing here runs them).
            (
                f = :analyses, wire = "analyses", kind = :raw_vec, mode = :opt_empty,
                default = :(Any[]), emit = :nonempty,
            ),
            (
                f = :reference, wire = "reference", kind = :record, of = :reference,
                mode = :opt, emit = :nonnothing,
            ),
            # schema §4.7 subsystems: per-entry oneOf [Model, SubsystemRef],
            # sniffed by the hand-written union hooks. A data source is a registry
            # entry, never a subsystem.
            (
                f = :subsystems, wire = "subsystems", kind = :custom, parse_fn = :_coerce_model_subsystems,
                mode = :opt_empty, default = :(Dict{String, SubsystemNode}()),
                emit = :custom, emit_fn = :_emit_model_subsystems,
            ),
        ),
    ),
)

# Each entry's rows (plus the injected map-key name, when marked) must cover
# EXACTLY the struct's fields — a new field without a row fails at load, the
# same guarantee `OPEXPR_FIELD_TABLE` gives `OpExpr`.
for spec in RECORD_FIELD_TABLES
    T = getfield(@__MODULE__, spec.T)
    covered = Set{Symbol}(row.f for row in spec.rows)
    get(spec, :injected, false) && push!(covered, :name)
    @assert covered == Set(fieldnames(T)) "RECORD_FIELD_TABLES.$(spec.T) rows must cover fieldnames($(spec.T)) exactly"
end

# `reconstruct(x::T; <field> = …)` for a type whose constructor takes the fields
# `pos` positionally and every other field as a keyword: each field defaults to
# `x`'s, and the constructor's normalizations and checks run on the result.
function _def_reconstruct(T::DataType, pos)
    rec = gensym(:rec)
    fs = fieldnames(T)
    sig = (Expr(:kw, f, :($rec.$f)) for f in fs)
    kws = Any[Expr(:kw, f, f) for f in fs if !(f in pos)]
    call = isempty(kws) ? Expr(:call, T, pos...) :
        Expr(:call, T, Expr(:parameters, kws...), pos...)
    return @eval reconstruct($rec::$T; $(sig...)) = $call
end

for spec in RECORD_FIELD_TABLES
    pos = Symbol[row.f for row in spec.rows if get(row, :pos, false)]
    get(spec, :injected, false) && pushfirst!(pos, :name)
    _def_reconstruct(getfield(@__MODULE__, spec.T), pos)
end
_def_reconstruct(ReactionSystem, (:species, :reactions))
_def_reconstruct(EsmFile, (:esm, :metadata))
