# The `load_*` entry points and the pass order of a load. Wire coercion is
# parse.jl's, emit is serialize.jl's, the §4.7 mount pipeline is mounts.jl's,
# references and their reader are ref_location.jl's.
#
# Pass order. Every document a load reads (root, mounted leaf, template
# library, coupling library) is read once through the load's `_DocumentSource`,
# which parses it and settles its op spellings (`_wire_document`).
#
#   root (`_load_document`)
#   1. on the authored tree: the names its mounts declare (only with loader-API
#      bindings or an `extent`), the §8.9.4 `extent` check, the `:root` rows of
#      `_AUTHORED_CHECKS`
#   2. `_inline_mounts!`: top-level `models.<k>`, then `reaction_systems.<k>`
#      stubs, then `subsystems.<k>` refs at any depth, each through the edge
#      pipeline below; contributed `index_sets` are staged, `data_sources` merge
#   3. §8.2.1 data-source locations against the root's base
#   4. `_load_parsed`: op floor (`gate = false`), schema, ic-in-reaction-system,
#      deprecated domain BCs
#   5. `_lower_and_coerce`: declaration snapshots, coupling injections (form B),
#      §9.7 machinery and metaparameter close, §9.6.3 fixpoint, registry
#      materialization, typed coercion
#   6. staged index sets fold against the root's closed environment and merge
#
#   mounted leaf (`_resolve_mount_edge`, mounts.jl), at either mount form
#   1. read; the `:mounted_leaf` rows of `_AUTHORED_CHECKS`; refuse a library
#   2. close (`_LeafClose`): bindings from above for the names it declares, then
#      the edge's own; the names its mounts declare
#   3. its own mounts, by the same `_inline_mounts!`, staged in its context
#   4. the edge's injection (form A), its §9.7 machinery under its close, the
#      fixpoint and full expansion, its `enum` ops against its own block
#   5. its staged index sets fold against its close and merge
#   6. the edge's `index_set_rename`, `url_substitutions`, then its data-source
#      locations against its own base
#
# The order of the authored checks decides which error a document with two
# faults reports; the corpus pins some of those.

"""
    _reject_ic_in_reaction_system(raw_data)

Raw-JSON structural check for spec §11.4.1: an `ic`-op equation MUST NOT appear
inside a reaction system's `constraint_equations`. A reaction system has no
`equations` field and hosts no initial conditions — a species' initial value is
its scalar `species.default`, and a non-constant / spatial IC is declared with a
scoped-reference `ic` equation in a MODEL (`ic(Chemistry.O3) ~ <field>`), never
inside the reaction system. Throws `ParseError` (diagnostic code
`ic_in_reaction_system`) on the first offending constraint equation. Operates on
the raw JSON document, ahead of coercion, so the rejection can carry the
offending document path.
"""
function _reject_ic_in_reaction_system(raw_data)
    rss = _raw_get(raw_data, "reaction_systems", nothing)
    rss === nothing && return
    for (rs_name, rs) in pairs(rss)
        ce = _raw_get(rs, "constraint_equations", nothing)
        ce === nothing && continue
        for (i, eq) in enumerate(ce)
            lhs = _raw_get(eq, "lhs", nothing)
            # Only operator-node LHSs carry an `op`; a bare-string / numeric LHS
            # (e.g. an algebraic constraint `"O3" ~ <value>`) is not an ic.
            _is_object(lhs) || continue
            _raw_get(lhs, "op", nothing) == "ic" || continue
            args = _raw_get(lhs, "args", nothing)
            species = (args !== nothing && length(args) >= 1 && args[1] isa AbstractString) ?
                String(args[1]) : ""
            throw(
                ParseError(
                    "ic equation not allowed in a reaction system; a reaction system has no " *
                        "equations field and hosts no ic equations (ICs are model-hosted: " *
                        "species.default, or a scoped-reference ic equation in a model, spec §11.4.1)";
                    code = ERROR_CODES.IC_IN_REACTION_SYSTEM,
                    path = "/reaction_systems/$(rs_name)/constraint_equations/$(i - 1)",
                    details = Dict{String, Any}(
                        "system" => String(rs_name),
                        "species" => species,
                        "constraint_equation_index" => i - 1
                    )
                )
            )
        end
    end
    return
end

"""
    load_path(path::AbstractString; metaparameters=Dict{String,Int}()) -> EsmFile

Read and parse an ESM document from a filesystem path: `.esm` JSON, or a
Markdown (`.md`) or Typst (`.typ`) source document, by the path's extension
(esm-spec §1.2.1). Automatically resolves any subsystem references (local or remote) relative
to the directory containing the file. `metaparameters` binds the ROOT
document's open metaparameters at the loader API (esm-spec §9.7.6 binding
site 4): already-closed edge bindings win, API bindings beat `default`s.

One of three load entry points, each named for what its argument is: a file
path here, JSON text for [`load_string`](@ref), and an already-parsed document
for [`load_document`](@ref).
"""
function load_path(
        path::AbstractString;
        metaparameters::AbstractDict{String, <:Integer} = Dict{String, Int}()
    )::EsmFile
    base_path = dirname(abspath(String(path)))
    path = String(path)
    raw_data = _wire_document(_parse_document_text(read(path, String), path))
    return _load_document(raw_data, base_path; metaparameters = metaparameters)
end

# Does the raw document `doc` import expression templates (`expression_template_imports`
# at the root or on a model / reaction system)?
function _has_template_imports(doc)::Bool
    _is_object(doc) || return false
    _raw_get(doc, "operator_imports", nothing) === nothing || return true
    for section in ("models", "reaction_systems")
        comps = _raw_get(doc, section, nothing)
        _is_object(comps) || continue
        for (_, comp) in pairs(comps)
            _raw_get(comp, "operator_imports", nothing) === nothing || return true
        end
    end
    return false
end

# The typed document of a raw dict for the build-side front doors that coerce
# without loading (`_build_evaluator(::AbstractDict)`, the pushdown desugar). A
# document that imports templates — `esm:std/*.esm` is how interpolation,
# calendar, geometry and the relational keys are written — goes through
# [`load_document`](@ref), which resolves the imports into the component
# template registries; coercion alone would leave every reference to them
# unresolvable.
_coerce_or_load(doc) = _has_template_imports(doc) ? load_document(doc) : coerce_esm_file(doc)

"""
    load_document(doc::AbstractDict; base_path=nothing, metaparameters=Dict{String,Int}()) -> EsmFile

Parse an ESM document held in memory as a native Julia dict — the same
document a `.esm` file holds, just already parsed. Runs the identical pipeline
[`load_path`](@ref) runs (top-level `{ref}` inlining, schema validation,
expression-template lowering, coercion, subsystem-ref resolution); `base_path`
anchors the relative refs a file input anchors at its own directory, and
defaults to `pwd()` for that. Left at `nothing` the document has no location of
its own, so a relative `coupling_import` ref resolves against `flatten`'s own
`base_path` instead (esm-spec §10.10 -> §4.7).

Distinct from [`coerce_esm_file`](@ref), which only coerces: it does not
validate, and it leaves a `{ref}` subsystem as an unresolved `SubsystemRef`
that [`flatten`](@ref) then SKIPS — so a dict must come through here, not
through `coerce_esm_file`, before it is flattened and run.
"""
function load_document(
        doc::AbstractDict;
        base_path::Union{Nothing, AbstractString} = nothing,
        metaparameters::AbstractDict{String, <:Integer} = Dict{String, Int}()
    )::EsmFile
    # Wire boundary for the in-memory path: normalize the caller's dict (which
    # may be symbol-keyed, or nest JSON3 values) into the one post-wire carrier,
    # and settle its `op` spellings as `_read_json_document` does for text, so
    # the version gates read the same RAISED `esm` on both paths (esm-spec §4.7).
    raw_data = _to_ordered(doc)
    _prepare_document_ops!(raw_data)
    return _load_document(
        raw_data, String(something(base_path, pwd()));
        metaparameters = metaparameters,
        record_import_base = base_path !== nothing
    )
end

"""
    _load_document(raw_data, base_path; metaparameters, source, record_import_base) -> EsmFile

The document pipeline every `load_*` entry point runs; `raw_data` is the
post-wire root (`_read_json_document` / the normalized in-memory dict). The
pass order is drawn at the top of this file.

Also the ONE internal entry for tests and adapters that need to control what
a load reads: `source` is the load's reader ([`_DocumentSource`](@ref)), e.g.
`_DocumentSource(fetch = url -> ...)` for an offline http(s) host. It is
created fresh per load otherwise.
"""
function _load_document(
        raw_data, base_path::AbstractString;
        metaparameters::AbstractDict{String, <:Integer} = Dict{String, Int}(),
        record_import_base::Bool = true,
        source::_DocumentSource = _DocumentSource()
    )::EsmFile
    base = _ref_base(String(base_path))
    # 1. On the authored tree, before the mounts are inlined and consume the
    #    leaves' `metaparameters`: the names the mounted documents declare
    #    (guarded: only the loader-API check and the `extent` check read it),
    #    the §8.9.4 `extent` check, and this file's own authored checks.
    mount_declared = (!isempty(metaparameters) || _document_declares_an_extent(raw_data)) ?
        _collect_mount_declared_metaparameters(raw_data, base, source) : Set{String}()
    check_data_source_extents(raw_data, base, source, mount_declared)
    _check_authored_document(raw_data, :root)
    # 2. Every §4.7 mount, both forms, through the edge pipeline. Only content
    #    moves now; the mounts' `index_sets` are staged until the root closes.
    ctx = _root_mount_context(raw_data, metaparameters, source)
    doc = raw_data
    if _document_has_mount(raw_data)
        doc = _to_ordered(raw_data)
        _inline_mounts!(doc, base, ctx)
        _strip_mount_provenance!(doc)
    end
    # 3. §8.2.1: every data-source location against this document's base.
    located = _resolve_data_source_urls(doc, base)
    doc = located === nothing ? doc : located
    # 4. Schema and raw checks, §9.7 machinery and the fixpoint, coercion.
    file = _load_parsed(doc, base; metaparameters, mount_declared, source)
    # 5. The staged contributions, folded against the root's closed environment.
    _merge_staged_index_sets!(file.index_sets, ctx.staged, ctx.env)
    # Relative `coupling_import` refs resolve against this document's directory
    # (§10.10), recorded only when the caller gave a base.
    record_import_base && (file = _record_coupling_import_base(file, base_path))
    # §8.5.1: the deprecated `records_per_sample`, one warning per load.
    _warn_deprecated_records_per_sample(file)
    return file
end

"""
    load_string(json::AbstractString; base_path=nothing, metaparameters=Dict{String,Int}()) -> EsmFile
    load_string(io::IO; base_path=nothing, metaparameters=Dict{String,Int}()) -> EsmFile

Parse an ESM document from JSON TEXT — held as a `String`, or streamed from an
`IO` the method reads to a string first (the `::IO` method is a sanctioned
Julia decoration on the canonical `load_string`, not a fourth entry point:
`JSON3.read` and `read` accept both shapes too).

Runs the SAME pipeline [`load_path`](@ref) and [`load_document`](@ref) run —
`_load_document`: top-level `{ref}` inlining, version gates, schema
validation, template lowering, coercion, and nested subsystem-ref resolution.
`base_path` anchors relative `expression_template_imports` refs and nested
`{ref}`s (esm-spec §9.7.2, §4.7), defaulting to `pwd()` for that; left at
`nothing` the document has no location of its own, so a relative
`coupling_import` ref resolves against `flatten`'s own `base_path` instead
(§10.10 -> §4.7). `metaparameters` binds the document's open metaparameters at
the loader API (esm-spec §9.7.6).
"""
function load_string(
        json::AbstractString; base_path::Union{Nothing, AbstractString} = nothing,
        metaparameters::AbstractDict{String, <:Integer} = Dict{String, Int}()
    )::EsmFile
    raw_data = _read_json_document(json)
    return _load_document(
        raw_data, String(something(base_path, pwd()));
        metaparameters = metaparameters,
        record_import_base = base_path !== nothing
    )
end

function load_string(
        io::IO; base_path::Union{Nothing, AbstractString} = nothing,
        metaparameters::AbstractDict{String, <:Integer} = Dict{String, Int}()
    )::EsmFile
    return load_string(
        read(io, String); base_path = base_path,
        metaparameters = metaparameters
    )
end

"""
    _read_json_document(json_string) -> OrderedDict{String,Any} document

THE wire boundary: parse a JSON document string and normalize it — once, here
— into the single post-wire carrier ([`_wire_document`](@ref)). Everything
downstream (schema validation, template lowering, coercion) speaks exactly this
one carrier. A malformed-JSON failure is a [`ParseError`](@ref)
("Invalid JSON: …"); downstream schema/coercion errors propagate with their own
types, never rebranded as JSON errors.
"""
_read_json_document(json_string::AbstractString) = _wire_document(_parse_json_text(json_string))

# `JSON3.read`, with a malformed document reported as a `ParseError`.
function _parse_json_text(json_string::AbstractString)
    return try
        JSON3.read(json_string)
    catch e
        _is_resource_error(e) && rethrow()
        msg = hasfield(typeof(e), :msg) ? e.msg : sprint(showerror, e)
        throw(ParseError("Invalid JSON: $(msg)", e))
    end
end

"""
    _parse_document_text(text, location) -> parsed document

Read a document's `text` in the format its `location` names (esm-spec §1.2.1):
a path, or a URL's path (its query and fragment ignored), ending in `.md` is
Markdown ([`parse_markdown`](@ref)), one ending in `.typ` Typst
([`parse_typst`](@ref)), and every other name JSON. The format is never guessed
from the text. Every read of a document from a path or URL goes through here;
the result then takes the JSON pipeline ([`_wire_document`](@ref)).

Throws a [`ParseError`](@ref): JSON that does not parse, or a source document
its reader refuses (`code` `parse_error`, or `removed_op`).
"""
function _parse_document_text(text::AbstractString, location::AbstractString)
    path = _is_url(location) ? _url_split(location)[2] : location
    endswith(path, ".md") && return parse_markdown(text)
    endswith(path, ".typ") && return parse_typst(text)
    return _parse_json_text(text)
end

"""
    _wire_document(parsed) -> post-wire document

A parsed JSON value in the post-wire carrier (`_to_ordered`: order-preserving,
string-keyed native tree) with its expression-node `op` spellings settled
(`_prepare_document_ops!`). Every document a load reads passes here once — the
root, a mounted document, a template library, a coupling library — so a removed
op cannot slip in through a reference.
"""
function _wire_document(parsed)
    doc = try
        _to_ordered(parsed)
    catch e
        # JSON3 interns object keys as `Symbol`s, and a `Symbol` cannot hold a
        # NUL, so a key carrying one fails here, before the schema's
        # `$defs/Identifier` pattern can reject it. Report it as that schema
        # violation (esm-spec §4.9.1.2), not as a raw language-level error.
        (e isa ArgumentError && occursin("\\0", e.msg)) || rethrow()
        err = SchemaError(
            "", "an object key contains a NUL character; a declared name " *
                "MUST NOT contain a control character (esm-spec §4.9.1.2)",
            "propertyNames"
        )
        throw(SchemaValidationError(_format_schema_errors([err]), [err]))
    end
    _prepare_document_ops!(doc)
    return doc
end

"""
    _format_schema_errors(schema_errors) -> String

Render the schema-validation error list as the multi-line diagnostic message
used by [`SchemaValidationError`](@ref) (one `  - path: message (keyword)`
line per error). `validate_schema` enumerates EVERY leaf schema violation
(AJV-parity, including the keywords inside a failed `oneOf`/`anyOf` branch), so
this routinely renders several lines; the header count reflects that.
"""
function _format_schema_errors(schema_errors)::String
    n = length(schema_errors)
    error_msg = "Schema validation failed with $(n) $(n == 1 ? "error" : "errors"):\n"
    for error in schema_errors
        error_msg *= "  - $(error.path): $(error.message) ($(error.keyword))\n"
    end
    return error_msg
end

"""
    _esm_version(doc) -> Union{Nothing, Tuple{Int,Int,Int}}
    _parse_esm_version(v::AbstractString) -> Union{Nothing, Tuple{Int,Int,Int}}

The `(major, minor, patch)` a document declares in `esm` (or a version string
spells), or `nothing` when it is not in the schema's `MAJOR.MINOR.PATCH` form
or a part does not fit an `Int`. The one version reader of the load-time
gates.
"""
function _esm_version(doc)
    _is_object(doc) || return nothing
    v = _raw_get(doc, "esm", nothing)
    v isa AbstractString || return nothing
    return _parse_esm_version(v)
end

function _parse_esm_version(v::AbstractString)
    m = match(r"^(\d+)\.(\d+)\.(\d+)$", v)
    m === nothing && return nothing
    parts = map(c -> tryparse(Int, c), m.captures)
    any(isnothing, parts) && return nothing
    return (parts[1], parts[2], parts[3])
end

"""
    _VersionGate

One "construct X arrives at esm V" rule. A document declaring a version below
`since` that `offences` finds X in (pointers, document order) is refused with
`refusal(declared, offences)`. `roles` are the documents the gate applies to
(see `_AUTHORED_CHECKS`; `:wire` is the op-spelling boundary,
`_prepare_document_ops!`).
"""
struct _VersionGate
    since::Tuple{Int, Int, Int}
    roles::Tuple{Vararg{Symbol}}
    offences::Function
    refusal::Function
end

# A gate whose refusal is the `ExpressionTemplateError` every gate but `faq`
# raises: "<subject> esm >= V; file declares D. Offending path: P", naming the
# first offence, or every one (`Offending paths: P1, P2`) when `all`.
function _VersionGate(
        since::Tuple{Int, Int, Int}, code::String, subject::String,
        roles::Tuple{Vararg{Symbol}}, offences::Function; all::Bool = false
    )
    floor = join(since, ".")
    refusal = (declared, offs) -> ExpressionTemplateError(
        code,
        "$(subject) esm >= $(floor); file declares $(declared). " *
            (all ? "Offending paths: $(join(offs, ", "))" : "Offending path: $(first(offs))");
        path = first(offs)
    )
    return _VersionGate(since, roles, offences, refusal)
end

# The pointers of the §9.6 constructs in a document: a component's
# `expression_templates` block, then every `apply_expression_template` node.
function _expression_template_offences(doc)
    # The esm-2.4.0 names and their old spellings alike (esm-spec §9.6.5).
    offences = String[]
    for (compkind, cname, comp) in _components(doc)
        for k in ("operators", "expression_templates")
            _raw_haskey(comp, k) && push!(offences, "/$compkind/$cname/$k")
        end
    end
    _find_apply_paths!(offences, doc, "")
    _visit_json(doc; path = "") do _, n, ptr
        _raw_get(n, "op") == "apply_expression_template" && push!(offences, string(ptr))
        return true
    end
    return offences
end

# `[pointer]` when the document's `solver` block carries `field`.
function _solver_field_offence(doc, field::String)
    solver = _raw_get(doc, "solver")
    (solver !== nothing && _is_object(solver) && _raw_haskey(solver, field)) || return String[]
    return ["/solver/$field"]
end

_found(p) = p === nothing ? String[] : String[p]

# The first `lb` / `ub` on a model variable, at any depth of inline subsystems.
function _variable_bound_offence(doc)
    models = _raw_get(doc, "models")
    (models !== nothing && _is_object(models)) || return String[]
    for (name, model) in pairs(models)
        p = _first_raw_bound(model, "/models/$(name)")
        p === nothing || return String[p]
    end
    return String[]
end

"""
    _VERSION_GATES

Every "construct arrives at esm V" rule, in the order they are checked; the
order decides which code a document old for two reasons reports. Each file is
held to its own declared version (esm-spec §4.7): the gates run on a document as
authored, before anything is mounted into it. The `solver.external` and
`solver.time_span` gates apply to the root alone (§2.2.6, §2.2.7 "Mounting");
`faq` is checked at the op-spelling boundary of every document read
(`_prepare_document_ops!`).
"""
const _VERSION_GATES = (
    # §9.6.5: expression templates and their references (RFC §5.4).
    expression_templates = _VersionGate(
        (0, 4, 0), ERROR_CODES.OPERATOR_VERSION_TOO_OLD,
        "operators / apply_operator (or expression_templates / apply_expression_template) require",
        (:root, :mounted_leaf, :template_library), _expression_template_offences; all = true
    ),
    # §9.6.5: the §9.7 constructs.
    template_imports = _VersionGate(
        (0, 8, 0), ERROR_CODES.OPERATOR_IMPORT_VERSION_TOO_OLD,
        "operator_imports / top-level operators / metaparameters (or their old spellings) require",
        (:root, :mounted_leaf, :template_library), d -> _template_import_offences(d); all = true
    ),
    # §2.2.4: the top-level `solver` block.
    solver = _VersionGate(
        (1, 1, 0), ERROR_CODES.SOLVER_VERSION_TOO_OLD,
        "the top-level `solver` block requires", (:root, :mounted_leaf),
        d -> _raw_haskey(d, "solver") ? ["/solver"] : String[]
    ),
    # §2.2.4 requirement 4: `solver.external` and `solver.time_span`.
    solver_external = _VersionGate(
        (1, 3, 0), ERROR_CODES.SOLVER_EXTERNAL_VERSION_TOO_OLD,
        "`solver.external` requires", (:root,), d -> _solver_field_offence(d, "external")
    ),
    solver_time_span = _VersionGate(
        (1, 3, 0), ERROR_CODES.SOLVER_TIME_SPAN_VERSION_TOO_OLD,
        "`solver.time_span` requires", (:root,), d -> _solver_field_offence(d, "time_span")
    ),
    # §4.8.5 item 6: declared `units` on an expression node, in a template
    # library's bodies as anywhere else.
    const_units = _VersionGate(
        (1, 2, 0), ERROR_CODES.CONST_UNITS_VERSION_TOO_OLD,
        "declared `units` on an expression node require",
        (:root, :mounted_leaf, :template_library),
        d -> _found(_find_units_bearing_node(d, ""))
    ),
    # §6.3.2: variable bounds. Only this file's inline models and subsystems;
    # a `{ref}` subsystem is gated against its own version when mounted.
    variable_bounds = _VersionGate(
        (2, 1, 0), ERROR_CODES.VARIABLE_BOUNDS_VERSION_TOO_OLD,
        "variable bounds (`lb` / `ub`) require", (:root, :mounted_leaf),
        d -> _variable_bound_offence(d)
    ),
    # §4.2 "The `faq` tag": a `ParseError`, like the `removed_op` refusal
    # beside it at the wire boundary.
    faq = _VersionGate(
        (1, 1, 0), (:wire,), d -> _found(_find_op_path(d, "faq")),
        (declared, offs) -> ParseError(
            "[E_FAQ_VERSION_TOO_OLD] faq_version_too_old at $(first(offs)): the " *
                "`faq` op arrives at esm 1.1.0; file declares $(declared). " *
                "Raise the declared version. " *
                "See docs/content/rfcs/faq-node-rename.md.";
            code = ERROR_CODES.FAQ_VERSION_TOO_OLD, path = first(offs)
        )
    ),
)

# The pointers `gate` finds in `doc` when `doc` declares a version below the
# gate's; empty otherwise.
function _version_gate_offences(gate::_VersionGate, doc)
    v = _esm_version(doc)
    (v === nothing || v >= gate.since) && return String[]
    return gate.offences(doc)
end

"""
    _check_version_gate(gate, doc)

Throw `gate`'s refusal when `doc` declares a version below it and uses the
construct; `nothing` otherwise.
"""
function _check_version_gate(gate::_VersionGate, doc)
    offs = _version_gate_offences(gate, doc)
    isempty(offs) && return nothing
    throw(gate.refusal(string(_raw_get(doc, "esm", nothing)), offs))
end

"""
    _check_version_gates(doc, role)

Run every [`_VERSION_GATES`](@ref) row that applies to `role`, in order.
"""
function _check_version_gates(doc, role::Symbol)
    for gate in _VERSION_GATES
        role in gate.roles && _check_version_gate(gate, doc)
    end
    return nothing
end

# The checks a document gets AS ITS FILE SPELLS IT, in the order they run, and
# the roles each applies to. Each runs before anything is inlined into the
# document, so a mounted file is judged by its own declared version, not the
# mounting file's (`tests/valid/version_gate_older_mounts_newer.esm`). The
# version gates run first, so a document old for its constructs reports the
# version before any other refusal; the order decides which error a document
# with two faults reports.
#
# Roles: `:root` (the document a `load_*` entry point was given),
# `:mounted_leaf` (a document a §4.7 mount edge reads), `:template_library`
# (§9.7.2 import target). A coupling library's own checks are
# `_validate_library`'s. The `solver.external` / `time_span` checks are the
# root's alone: a mounted leaf's `solver` block does not cross the mount
# (§2.2.6 "Mounting", §2.2.7 "Mounting").
const _AUTHORED_CHECKS = (
    ((d, role) -> _check_version_gates(d, role), (:root, :mounted_leaf, :template_library)),
    # Top-level `expression_templates` beside a component payload (§9.7.1).
    ((d, _) -> _reject_impure_template_library(d), (:root,)),
    # A `${` in `solver.external` (§2.2.6), a `time_span` that is no interval
    # (§2.2.7).
    ((d, _) -> _reject_solver_external_unresolved(d), (:root,)),
    ((d, _) -> _reject_solver_time_span_invalid(d), (:root,)),
    # The template-origin mark is load provenance; no file spells it.
    ((d, _) -> _reject_authored_template_origins(d), (:root, :mounted_leaf)),
)

"""
    _check_authored_document(doc, role)

Run the [`_AUTHORED_CHECKS`](@ref) that apply to `role` on `doc`, the document
as its file spells it, before anything is inlined into it.
"""
function _check_authored_document(doc, role::Symbol)
    for (check, roles) in _AUTHORED_CHECKS
        role in roles && check(doc, role)
    end
    return nothing
end

"""
    _load_parsed(doc, base; metaparameters, mount_declared, source) -> EsmFile

The root's passes after its mounts are inlined: the op-spelling floor, schema
validation, the raw structural checks, then [`_lower_and_coerce`](@ref).
"""
function _load_parsed(
        raw_data, base::_RefBase;
        metaparameters::AbstractDict{String, <:Integer} = Dict{String, Int}(),
        mount_declared::Union{Nothing, AbstractSet{String}} = nothing,
        source::_DocumentSource = _DocumentSource()
    )::EsmFile
    # `gate = false`: with its mounts inlined this document is no longer the
    # authored one. A 1.0.0 parent that mounts a `faq`-using child contains
    # `faq` without having spelled it, so the floor is raised instead, as
    # `emit` does (§5.5). Idempotent otherwise: no second warning.
    _prepare_document_ops!(raw_data; gate = false)
    # Schema, on the document without the template-origin marks a mount's
    # expansion carries (load provenance, esm-spec §9.6.11).
    schema_errors = validate_schema(_strip_template_origins(raw_data))
    if !isempty(schema_errors)
        throw(SchemaValidationError(_format_schema_errors(schema_errors), schema_errors))
    end
    # §11.4.1: schema-valid but not allowed; checked on the raw tree so the
    # refusal carries a document path.
    _reject_ic_in_reaction_system(raw_data)
    _warn_deprecated_domain_bc(raw_data)
    return _lower_and_coerce(
        raw_data, base; metaparameters = metaparameters,
        mount_declared = mount_declared, source = source
    )
end

"""
    _lower_and_coerce(doc, base; metaparameters, mount_declared, source) -> EsmFile

The root's §9.7 and coercion tail: the §9.7.10 form-B injections of coupling
entries, the §9.7 machinery (imports, index-set merge, metaparameter close and
fold), the §9.6.3 fixpoint, then typed coercion. The top-level
`expression_templates`, `metaparameters` and `coordinates` declarations are
snapshotted verbatim first: Option A expands call sites, it does not delete
declarations (esm-spec §9.6.4 rule 5), and the lowering rewrites those blocks.
Surviving `apply_expression_template` references and the per-component
registries they name are kept (§9.6.4 Option B) and travel on the `EsmFile`.
"""
function _lower_and_coerce(
        raw_data, base::_RefBase;
        metaparameters::AbstractDict{String, <:Integer} = Dict{String, Int}(),
        mount_declared::Union{Nothing, AbstractSet{String}} = nothing,
        source::_DocumentSource = _DocumentSource()
    )::EsmFile
    raw_templates = _verbatim_decl(raw_data, "operators")
    raw_metaparams = _verbatim_decl(raw_data, "metaparameters")
    raw_coordinates = _verbatim_decl(raw_data, "coordinates")

    injected_root = apply_scope_injections(raw_data, Any[])
    machinery_input = injected_root === nothing ? raw_data : injected_root
    resolved = _resolve_template_machinery(
        machinery_input, base, source;
        metaparameters = metaparameters, mount_declared = mount_declared
    )
    lowered_src = resolved === nothing ? machinery_input : resolved
    loaded = lower_expression_templates(lowered_src)
    comp_tpls = nothing
    esm_stamp = nothing
    expanded = loaded
    if loaded !== lowered_src
        # The machinery ran (the no-machinery fast path returns its input by
        # identity). Coupling `variable_map` transform references stay
        # references (esm-spec §10.4): the receiving component's materialized
        # registry carries their templates, then the registries are stripped
        # from the coercion tree.
        root = loaded
        authored = _authored_template_names(machinery_input)
        blocks, bump = _materialize_components!(root, authored)
        for (_, _, comp) in _components(root)
            delete!(comp, "operators")
        end
        isempty(blocks) || (comp_tpls = OrderedDict{String, Any}(k => v for (k, v) in blocks))
        bump && (esm_stamp = _esm_stamp_floor(get(root, "esm", nothing)))
    end
    # Coerce under an identity parse memo (`_PARSE_EXPR_MEMO_KEY`) so the
    # sharing the template expansion built carries into the typed IR.
    file = task_local_storage(_PARSE_EXPR_MEMO_KEY, IdDict{Any, ASTExpr}()) do
        coerce_esm_file(expanded; document_base = _solver_external_base(_base_string(base)))
    end
    return _with_declarations(
        file, raw_templates, raw_metaparams;
        component_templates = comp_tpls, esm = esm_stamp,
        coordinates = raw_coordinates
    )
end

# A deep, plain-`Dict` copy of a top-level declaration block, or `nothing`.
# Plain `Dict`/`Vector`/scalars only (`_to_native_json`) — the snapshot lives
# on the typed `EsmFile` and is re-emitted verbatim by `serialize_esm_file`,
# whose byte surface has always been the plain-Dict one.
function _verbatim_decl(raw_data, key::String)
    v = _raw_get(raw_data, key, nothing)
    v === nothing && return nothing
    d = _to_native_json(v)
    return d isa AbstractDict ? d : nothing
end

# Rebuild `file` with the verbatim declaration blocks, the per-component
# materialized template registries and a possibly version-stamped `esm`. Each
# keyword replaces its field (`nothing` clears it), except `esm = nothing`, which
# keeps `file.esm`. With every keyword `nothing`, `file` comes back as is.
_with_declarations(
    file::EsmFile, templates, metaparams;
    component_templates = nothing, esm = nothing, coordinates = nothing
) =
    (
        templates === nothing && metaparams === nothing &&
        component_templates === nothing && esm === nothing && coordinates === nothing
    ) ? file :
    reconstruct(
        file;
        esm = esm === nothing ? file.esm : esm,
        expression_templates = templates,
        metaparameters = metaparams,
        component_templates = component_templates,
        coordinates = coordinates
    )

"""
    _warn_deprecated_domain_bc(raw_data)

Emit an `@warn` for each `domains.<d>.boundary_conditions` encountered: the
deprecated v0.1.0 spelling of `models.<M>.boundary_conditions` (RFC §9).
"""
function _warn_deprecated_domain_bc(raw_data)
    domains = _raw_get(raw_data, "domains", nothing)
    domains === nothing && return
    for (domain_name, domain) in domains
        if _raw_haskey(domain, "boundary_conditions")
            @warn string(
                "[E_DEPRECATED_DOMAIN_BC] domains.", domain_name,
                ".boundary_conditions is deprecated in ESM v0.2.0; migrate ",
                "to models.<M>.boundary_conditions ",
                "(docs/content/rfcs/discretization.md §9)."
            )
        end
    end
    return
end

"""
    _prepare_document_ops!(doc; gate = true) -> Nothing

Settle expression-node `op` spellings for ONE document, in four steps:

1. `arrayop` (removed at esm 0.8.0) is rejected BY NAME. It is a well-formed
   identifier, so esm-spec §4.2 would otherwise admit it as an OPEN
   rewrite-target op — the document would load silently and fail much later as
   `unlowered_operator`, or never.
2. The ops and the block esm 2.0.0 removed (`_REMOVED_OPS_2_0_0`, among them
   `aggregate`, the pre-1.1.0 spelling of `faq`) are rejected BY NAME, for the
   same reason (`_reject_removed_2_0_0!`).
3. The deprecated spellings `neg` and `pow` are rewritten to unary `-` and
   `^`, with one `deprecated_op` warning for the document
   (`_rewrite_deprecated_ops!`, esm-spec §4.2 "Deprecated ops").
   A model declaring `"system_kind": "pde"` gets one `deprecated_system_kind`
   warning for the document (`_warn_deprecated_system_kind`, esm 2.4.0).
4. The `faq` version gate: `faq` arrives at esm 1.1.0 (esm-spec §2.2.4, the
   rule the top-level `solver` block follows). With `gate = false`
   (post-inlining: a 1.0.0 parent whose mounted child uses `faq`), the declared
   version is raised to the 1.1.0 floor instead, the same rule `emit` applies
   (docs/content/rfcs/faq-node-rename.md §5.5).
"""
function _prepare_document_ops!(doc; gate::Bool = true)::Nothing
    at = _find_op_path(doc, "arrayop")
    if at !== nothing
        throw(
            ParseError(
                "[E_REMOVED_OP] removed_op at $(at): `\"op\": \"arrayop\"` was " *
                    "removed at esm 0.8.0 and is not a deprecated alias; use " *
                    "`\"op\": \"faq\"` (the Functional Aggregate Query node). " *
                    "See docs/content/rfcs/faq-node-rename.md.";
                code = ERROR_CODES.REMOVED_OP, path = at
            )
        )
    end
    _reject_removed_2_0_0!(doc)
    _rewrite_old_spellings!(doc)
    _rewrite_deprecated_ops!(doc)
    # Only on the authored document's own pass: the post-inlining pass
    # (`gate = false`) sees the same models again and must not warn twice.
    gate && _warn_deprecated_system_kind(doc)
    if gate
        _check_version_gate(_VERSION_GATES.faq, doc)
        return nothing
    end
    isempty(_version_gate_offences(_VERSION_GATES.faq, doc)) && return nothing
    for key in (:esm, "esm")
        if haskey(doc, key)
            doc[key] = "1.1.0"
            break
        end
    end
    return nothing
end

"""
    _library_wire_form(raw) -> post-wire library document

A template or coupling library as loaded (by the default loader or a caller's
`load_ref`), copied into the post-wire carrier and passed through the same
op-spelling boundary as every other document (`_prepare_document_ops!`): a
removed op is refused by name and `neg` / `pow` are rewritten with the
`deprecated_op` warning. A non-object is returned unchanged for the caller's
own diagnostic.
"""
function _library_wire_form(raw)
    _is_object(raw) || return raw
    doc = _to_ordered(raw)
    _prepare_document_ops!(doc)
    return doc
end

# The `op` / `fn` / `args` field key of a post-wire node: the carrier is
# string-keyed, but an in-memory caller's dict may still be symbol-keyed.
function _node_key(n, name::String)
    haskey(n, name) && return name
    sym = Symbol(name)
    haskey(n, sym) && return sym
    return nothing
end

"""
    _warn_deprecated_system_kind(doc) -> Vector{String}

esm 2.4.0 dropped the `"pde"` system kind. A model declaring
`"system_kind": "pde"` is not refused: the field is kept as written, counts as
absent for classification ([`declared_system_kind`](@ref)), and the document
gets ONE `@warn` with the code `deprecated_system_kind` naming every such model
by JSON pointer, subsystems included at any depth
(`/models/<name>/system_kind`, `/models/<name>/subsystems/<sub>/system_kind`),
in document order with each model before its subsystems. Returns those
pointers.
"""
function _warn_deprecated_system_kind(doc)::Vector{String}
    sites = String[]
    _is_object(doc) || return sites
    _pde_system_kind_sites!(sites, _raw_get(doc, "models", nothing), _pointer("", "models"))
    isempty(sites) && return sites
    @warn string(
        "deprecated_system_kind: the system_kind value \"pde\" is deprecated ",
        "(esm 2.4.0) and ignored; the model is treated as its derived kind. ",
        "Declared at: ", join(sites, ", "), "."
    )
    return sites
end

# ---------------------------------------------------------------------------
# esm 2.4.0 "one operator type": old spellings read at the wire boundary
# (esm-spec §9.6.12 "Old names (no refusal)", §4.2 "Reading earlier documents")
# ---------------------------------------------------------------------------

# Old field spelling → new (warning `deprecated_field`).
const _DEPRECATED_FIELDS = (
    "expression_templates" => "operators",
    "expression_template_imports" => "operator_imports",
)
# Old op spelling of the reference node (warning `deprecated_op`).
const _OLD_APPLY_OP = "apply_expression_template"
# The other spellings of the spatial derivative (warning `deprecated_op`).
const _PARTIAL_SPELLINGS = ("δ", "∂")

# Objects whose keys are author-chosen names, not fields: a field spelling is
# never renamed among them (a variable may be called `expression_templates`).
const _OLD_SPELLING_NAME_MAPS = union(
    _NAME_KEYED_MAP_KEYS,
    Set{String}([
        "models", "reaction_systems", "data_sources", "index_sets", "enums",
        "metaparameters", "domains", "coupling_roles",
    ]),
)

"""
    _rewrite_old_spellings!(doc) -> Vector{String}

esm 2.4.0 (esm-spec §9.6.12, §4.2): read the spellings an earlier document
wrote, in place, on every document a load touches, never refusing one:

- the field `expression_templates` as `operators` and
  `expression_template_imports` as `operator_imports` (warning
  `deprecated_field`), wherever a field of that name appears (never among the
  keys of a name-keyed map);
- the op `apply_expression_template` as `apply_operator`, and the spatial
  derivative — a `D` whose `wrt` is present and is not the literal `"t"`, and
  the spellings `δ` and `∂` — as `partial`, every other field kept (warning
  `deprecated_op`). A `D` whose `wrt` is one of the enclosing definition's
  `params` is left as written: it is decided per definition instance
  (§9.6.4 rule 3; `_instance_partial!`).

One warning per code per document, naming each site as `<pointer> (<old>)`.
Idempotent. Returns the sites (fields first, then ops).
"""
function _rewrite_old_spellings!(doc)::Vector{String}
    fsites = String[]
    osites = String[]
    seen = IdDict{Any, Nothing}()
    task_local_storage(:esm_doc_independent_variable, _document_iv_rename(doc)) do
        _old_spellings_walk!(doc, "", false, nothing, fsites, osites, seen)
    end
    isempty(fsites) || @warn string(
        "deprecated_field: the fields `expression_templates` and ",
        "`expression_template_imports` are read as `operators` and ",
        "`operator_imports` (esm 2.4.0, esm-spec §9.6.12). Read at: ",
        join(fsites, ", "), "."
    )
    isempty(osites) || @warn string(
        "deprecated_op: `apply_expression_template` is read as `apply_operator`, ",
        "and a spatial `D` (and `δ`, `∂`) as `partial` (esm 2.4.0, esm-spec §4.2, ",
        "§9.6.12). Rewritten at: ", join(osites, ", "), "."
    )
    return vcat(fsites, osites)
end

"""
    _wire_old_spellings(raw) -> raw′

`raw` itself when it spells nothing an earlier document wrote (§9.6.12, §4.2),
else an ordered copy read through [`_rewrite_old_spellings!`](@ref). For entry
points a caller may reach without the load's wire boundary
(`lower_expression_templates`, `resolve_template_machinery`).
"""
function _wire_old_spellings(raw)
    _is_object(raw) || return raw
    _has_old_spellings(raw) || return raw
    doc = _to_ordered(raw)
    _rewrite_old_spellings!(doc)
    return doc
end

function _has_old_spellings(x)::Bool
    return _visit_json(x) do _, n
        _is_object(n) || return true
        for (k, _) in pairs(n)
            ks = string(k)
            (ks == "expression_templates" || ks == "expression_template_imports") && return _JSON_STOP
        end
        op = _raw_get(n, "op")
        if op isa AbstractString
            (op == _OLD_APPLY_OP || op in _PARTIAL_SPELLINGS) && return _JSON_STOP
            if op == "D"
                w = _raw_get(n, "wrt")
                (w !== nothing && w != "t") && return _JSON_STOP
            end
        end
        return true
    end
end

# The document's own renamed independent variable (`domain.independent_variable`
# when declared and not "t"), or `nothing` (esm-spec §4.2 "The derivative axis").
function _document_iv_rename(doc)
    _is_object(doc) || return nothing
    dom = _raw_get(doc, "domain")
    (dom !== nothing && _is_object(dom)) || return nothing
    iv = _raw_get(dom, "independent_variable")
    (iv isa AbstractString && iv != "t") || return nothing
    return String(iv)
end

# Rename `old` to `new` among the keys of `node`, keeping key order.
function _rename_field_inplace!(node, old::String, new::String)
    ok = _node_key(node, old)
    ok === nothing && return false
    nk = _node_key(node, new)
    if nk !== nothing
        # Both spellings in one object: nothing to choose between silently.
        throw(
            ParseError(
                "[E_DEPRECATED_FIELD] an object carries both `$old` and its esm-2.4.0 " *
                    "spelling `$new`; write only `$new` (esm-spec §9.6.12).";
                code = ERROR_CODES.OPERATOR_INVALID_DEFINITION
            )
        )
    end
    entries = collect(pairs(node))
    empty!(node)
    for (k, v) in entries
        if k == ok
            node[k isa Symbol ? Symbol(new) : new] = v
        else
            node[k] = v
        end
    end
    return true
end

function _old_spellings_walk!(
        node, at::String, namemap::Bool, params::Union{Nothing, Set{String}},
        fsites::Vector{String}, osites::Vector{String}, seen
    )
    if _is_object(node)
        haskey(seen, node) && return nothing
        seen[node] = nothing
        if !namemap
            for (old, new) in _DEPRECATED_FIELDS
                _rename_field_inplace!(node, old, new) &&
                    push!(fsites, string(_pointer(at, new), " (", old, ")"))
            end
            opk = _node_key(node, "op")
            if opk !== nothing && node[opk] isa AbstractString
                op = String(node[opk])
                if op == _OLD_APPLY_OP
                    node[opk] = APPLY_EXPRESSION_TEMPLATE_OP
                    push!(osites, string(at, " (", op, ")"))
                elseif op in _PARTIAL_SPELLINGS
                    node[opk] = "partial"
                    push!(osites, string(at, " (", op, ")"))
                elseif op == "D"
                    wk = _node_key(node, "wrt")
                    w = wk === nothing ? nothing : node[wk]
                    iv = get(task_local_storage(), :esm_doc_independent_variable, nothing)
                    if w !== nothing && iv !== nothing && w == iv &&
                            !(params !== nothing && String(w) in params)
                        # esm-spec §4.2 "The derivative axis": `wrt` naming the
                        # document's renamed independent variable is the time
                        # derivative, read with the literal axis (no warning).
                        node[wk] = "t"
                    elseif w !== nothing && w != "t" &&
                            !(w isa AbstractString && params !== nothing && String(w) in params)
                        node[opk] = "partial"
                        push!(osites, string(at, " (D)"))
                    end
                end
            end
        end
        for (k, v) in pairs(node)
            _is_json_leaf(v) && continue
            ks = string(k)
            if !namemap && ks == "operators" && _is_object(v)
                # A definition block: each entry's own params decide a `D`
                # whose `wrt` names one of them.
                haskey(seen, v) && continue
                seen[v] = nothing
                for (dn, dv) in pairs(v)
                    _is_json_leaf(dv) && continue
                    p = _is_object(dv) ? _raw_get(dv, "params") : nothing
                    P = (p !== nothing && _is_array(p)) ?
                        Set{String}(String(x) for x in p if x isa AbstractString) : nothing
                    _old_spellings_walk!(
                        dv, _pointer(at, ks, string(dn)), false, P, fsites, osites, seen
                    )
                end
                continue
            end
            _old_spellings_walk!(
                v, _pointer(at, ks), !namemap && ks in _OLD_SPELLING_NAME_MAPS,
                params, fsites, osites, seen
            )
        end
    elseif _is_array(node)
        _may_hold_object(node) || return nothing
        haskey(seen, node) && return nothing
        seen[node] = nothing
        for (i, v) in enumerate(node)
            _is_json_leaf(v) && continue
            _old_spellings_walk!(v, string(at, "/", i - 1), false, params, fsites, osites, seen)
        end
    end
    return nothing
end


function _pde_system_kind_sites!(sites::Vector{String}, models, at::String)
    _is_object(models) || return sites
    for (name, model) in pairs(models)
        _is_object(model) || continue
        here = _pointer(at, string(name))
        _raw_get(model, "system_kind", nothing) == "pde" &&
            push!(sites, _pointer(here, "system_kind"))
        _pde_system_kind_sites!(
            sites, _raw_get(model, "subsystems", nothing), _pointer(here, "subsystems")
        )
    end
    return sites
end

"""
    _rewrite_deprecated_ops!(doc) -> Vector{String}

esm-spec §4.2 "Deprecated ops": rewrite, in place, every expression node of
`doc` spelling `neg` with one operand to unary `-`, every `pow` with two
operands to `^`, and every one-operand `broadcast` whose `fn` is `neg` to
`fn: "-"`. Every other field of the node is kept; a use with the wrong operand
count is left as written, so its arity error is unchanged. When anything was
rewritten, ONE `@warn` with the code `deprecated_op` names each rewritten node.
Returns one site per node, in pre-order: its RFC 6901 JSON pointer (`""` for
the root) and the spelling it had, as `<pointer> (neg)`, `<pointer> (pow)` or
`<pointer> (broadcast fn neg)`, the format every binding's warning uses.
Idempotent: a second pass over the same document finds nothing and stays
silent.
"""
function _rewrite_deprecated_ops!(doc)::Vector{String}
    sites = String[]
    seen = IdDict{Any, Nothing}()
    _rewrite_deprecated_ops_walk!(doc, "", sites, seen)
    isempty(sites) && return sites
    @warn string(
        "deprecated_op: the op spellings `neg` (write unary `-`) and `pow` ",
        "(write `^`) are deprecated (esm-spec §4.2 \"Deprecated ops\"); they were ",
        "rewritten on load and will be removed in a later major version. ",
        "Rewritten at: ", join(sites, ", "), "."
    )
    return sites
end

function _rewrite_deprecated_ops_walk!(node, at::String, sites::Vector{String}, seen)
    if _is_object(node)
        haskey(seen, node) && return nothing
        seen[node] = nothing
        opk = _node_key(node, "op")
        argk = _node_key(node, "args")
        if opk !== nothing
            op = node[opk]
            args = argk === nothing ? nothing : node[argk]
            rep = op isa AbstractString ? get(_DEPRECATED_OPS, String(op), nothing) : nothing
            if rep !== nothing && args isa AbstractVector && length(args) == _op_spec(op).arity.start
                node[opk] = rep
                push!(sites, string(at, " (", op, ")"))
            elseif op == "broadcast" && args isa AbstractVector && length(args) == 1
                # `neg` is strictly unary, so a broadcast of it with any other
                # operand count keeps its arity error (`invalid_broadcast_fn`).
                fnk = _node_key(node, "fn")
                if fnk !== nothing && node[fnk] == "neg"
                    node[fnk] = "-"
                    push!(sites, string(at, " (broadcast fn neg)"))
                end
            end
        end
        for (k, v) in pairs(node)
            _is_json_leaf(v) && continue
            _rewrite_deprecated_ops_walk!(v, _pointer(at, string(k)), sites, seen)
        end
    elseif _is_array(node)
        _may_hold_object(node) || return nothing
        haskey(seen, node) && return nothing
        seen[node] = nothing
        for (i, v) in enumerate(node)
            _is_json_leaf(v) && continue
            _rewrite_deprecated_ops_walk!(v, string(at, "/", i - 1), sites, seen)
        end
    end
    return nothing
end

# The ops and the block esm 2.0.0 removed. Each is replaced by an
# `esm:std/*.esm` expression template (`aggregate` by `faq`, of which it was
# the deprecated pre-1.1.0 spelling), and the offline codemod
# (`python -m earthsci_ast.migrate`) rewrites a 1.x document that uses them.
const _REMOVED_OPS_2_0_0 = (
    "fn", "table_lookup", "skolem", "rank", "intersect_polygon",
    "polygon_intersection_area", "argmin", "argmax", "aggregate",
)

const _REMOVED_2_0_0_HINT =
    "removed at esm 2.0.0; run the codemod (`python -m earthsci_ast.migrate`) " *
    "to rewrite the document onto the `esm:std/*.esm` expression templates"

"""
    _REMOVED_OPS

Every op spelling the format removed (esm-spec §4.2 "Removed ops"): `arrayop`
(esm 0.8.0) and [`_REMOVED_OPS_2_0_0`](@ref). The document formats refuse the
same tuple (`DocumentFormats.MExpr.REMOVED_OPS` is this object).
"""
const _REMOVED_OPS = ("arrayop", _REMOVED_OPS_2_0_0...)

# What replaces a removed op, for its diagnostic.
_removed_op_hint(op::AbstractString) =
    op == "arrayop" ?
    "removed at esm 0.8.0; use `\"op\": \"faq\"` (the Functional Aggregate Query " *
    "node), see docs/content/rfcs/faq-node-rename.md" :
    _REMOVED_2_0_0_HINT

"""
    _removed_2_0_0_finding(doc) -> Union{Nothing, Tuple{String, String}}

`(name, path)` of the first construct esm 2.0.0 removed that `doc` uses: an
expression node whose `op` is one of `_REMOVED_OPS_2_0_0`, or a
`function_tables` block at the top level or on a model / reaction system.
`nothing` when there is none.
"""
function _removed_2_0_0_finding(doc)
    _is_object(doc) || return nothing
    for key in (:function_tables, "function_tables")
        haskey(doc, key) && return ("function_tables", "/function_tables")
    end
    for section in _COMPONENT_KINDS
        comps = _raw_get(doc, section, nothing)
        _is_object(comps) || continue
        for (cname, comp) in pairs(comps)
            _is_object(comp) || continue
            for key in (:function_tables, "function_tables")
                haskey(comp, key) &&
                    return ("function_tables", "/$(section)/$(cname)/function_tables")
            end
        end
    end
    removed = Ref("")
    hit(n) = (
        op = _raw_get(n, "op", nothing);
        (op isa AbstractString && op in _REMOVED_OPS_2_0_0) && (removed[] = String(op); true)
    )
    path = _find_json_path(hit, doc)
    return path === nothing ? nothing : (removed[], path)
end

"""
    _reject_removed_2_0_0!(doc)

Throw the `removed_op` [`ParseError`](@ref) for the first construct esm 2.0.0
removed (`_removed_2_0_0_finding`). Runs BY NAME at the wire boundary, before
schema validation: every removed op is a well-formed identifier, so esm-spec
§4.2 would otherwise admit it as an open rewrite-target op and the document
would fail much later as `unlowered_operator`.
"""
function _reject_removed_2_0_0!(doc)
    f = _removed_2_0_0_finding(doc)
    f === nothing && return nothing
    name, at = f
    what = name == "function_tables" ? "the `function_tables` block" :
        "`\"op\": \"$(name)\"`"
    throw(
        ParseError(
            "[E_REMOVED_OP] removed_op at $(at): $(what) was $(_REMOVED_2_0_0_HINT).";
            code = ERROR_CODES.REMOVED_OP, path = at,
            details = Dict{String, Any}("name" => name)
        )
    )
end

"""
    _find_op_path(node, op, at="") -> Union{String,Nothing}

Path of the first node carrying `"op" => op`, or `nothing`.
"""
_find_op_path(node, op::AbstractString, at::AbstractString = "") =
    _find_json_path(
    n -> any(k -> haskey(n, k) && get(n, k, nothing) == op, (:op, "op")),
    node, at
)
