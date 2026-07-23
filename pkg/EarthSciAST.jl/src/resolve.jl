# ESM document load pipeline + subsystem-reference linker.
#
# Everything in this file is RESOLUTION, not wire coercion: the `load` entry
# points and their shared document pipeline (top-level `{ref}` inlining,
# version gates, schema validation, §9.7 template machinery, typed coercion
# hand-off), and the subsystem-ref linker — RFC-3986 URL joining /
# normalization, `${VAR}` ref expansion, path- and URL-scoped cycle
# detection, index-set registry merging, and metaparameter binding at
# reference edges (esm-spec §4.7, §9.7). Pure wire→struct coercion stays in
# parse.jl; the emit direction lives in serialize.jl.

"""
    _reject_ic_in_reaction_system(raw_data)

Raw-JSON structural check for spec §11.4.1: an `ic`-op equation MUST NOT appear
inside a reaction system's `constraint_equations`. A reaction system has no
`equations` field and hosts no initial conditions — a species' initial value is
its scalar `species.default`, and a non-constant / spatial IC is declared with a
scoped-reference `ic` equation in a MODEL (`ic(Chemistry.O3) ~ <field>`), never
inside the reaction system. Throws `ParseError` (diagnostic code
`ic_in_reaction_system`) on the first offending constraint equation. Operates on
the raw JSON document because Julia does not parse a reaction system's
`constraint_equations` into its typed form.
"""
function _reject_ic_in_reaction_system(raw_data)
    rss = _get_field(raw_data, :reaction_systems, nothing)
    rss === nothing && return
    for (rs_name, rs) in pairs(rss)
        ce = _get_field(rs, :constraint_equations, nothing)
        ce === nothing && continue
        for (i, eq) in enumerate(ce)
            lhs = _get_field(eq, :lhs, nothing)
            # Only operator-node LHSs carry an `op`; a bare-string / numeric LHS
            # (e.g. an algebraic constraint `"O3" ~ <value>`) is not an ic.
            _is_json_object(lhs) || continue
            _get_field(lhs, :op, nothing) == "ic" || continue
            args = _get_field(lhs, :args, nothing)
            species = (args !== nothing && length(args) >= 1 && args[1] isa AbstractString) ?
                      String(args[1]) : ""
            throw(ParseError(
                "ic equation not allowed in a reaction system; a reaction system has no " *
                "equations field and hosts no ic equations (ICs are model-hosted: " *
                "species.default, or a scoped-reference ic equation in a model, spec §11.4.1)";
                code = "ic_in_reaction_system",
                path = "/reaction_systems/$(rs_name)/constraint_equations/$(i - 1)",
                details = Dict{String,Any}("system" => String(rs_name),
                                           "species" => species,
                                           "constraint_equation_index" => i - 1)
            ))
        end
    end
end

"""
    load(path::String; metaparameters=Dict{String,Int}()) -> EsmFile

Load and parse an ESM file from a file path.
Automatically resolves any subsystem references (local or remote) relative
to the directory containing the file. `metaparameters` binds the ROOT
document's open metaparameters at the loader API (esm-spec §9.7.6 binding
site 4): already-closed edge bindings win, API bindings beat `default`s.
"""
function load(path::String;
              metaparameters::AbstractDict{String,<:Integer}=Dict{String,Int}())::EsmFile
    base_path = dirname(abspath(path))
    raw_data = _read_json_document(read(path, String))
    return _load_document(raw_data, base_path; metaparameters=metaparameters)
end

"""
    load(doc::AbstractDict; base_path=pwd(), metaparameters=Dict{String,Int}()) -> EsmFile

Load and parse an ESM document held in memory as a native Julia dict — the same
document a `.esm` file holds, just already parsed. Runs the identical pipeline
`load(::String)` runs (top-level `{ref}` inlining, schema validation,
expression-template lowering, coercion, subsystem-ref resolution); `base_path`
anchors the relative refs a file input anchors at its own directory.

Distinct from [`coerce_esm_file`](@ref), which only coerces: it does not
validate, and it leaves a `{ref}` subsystem as an unresolved `SubsystemRef`
that [`flatten`](@ref) then SKIPS — so a dict must come through here, not
through `coerce_esm_file`, before it is flattened and run.
"""
function load(doc::AbstractDict;
              base_path::AbstractString=pwd(),
              metaparameters::AbstractDict{String,<:Integer}=Dict{String,Int}())::EsmFile
    # Wire boundary for the in-memory path: normalize the caller's dict (which
    # may be symbol-keyed, or nest JSON3 values) into the one post-wire carrier.
    return _load_document(_to_ordered(doc), String(base_path);
                          metaparameters=metaparameters)
end

"""
    _load_document(raw_data, base_path; metaparameters) -> EsmFile

The document pipeline shared by every `load` method: top-level `{ref}` inlining
→ `_load_parsed` (version gates, schema validation, template lowering,
coercion) → nested subsystem-ref resolution. `raw_data` is the post-wire
native document (`_read_json_document` / the normalized in-memory dict).

Factored out so a file and the identical document held as a dict cannot drift
apart — the only difference between them is which `base_path` anchors the refs.
"""
function _load_document(raw_data, base_path::String;
                        metaparameters::AbstractDict{String,<:Integer}=Dict{String,Int}())::EsmFile
    # Inline any top-level model `{ref}` stubs (schema §4.7: `models.*` is
    # oneOf [Model, {ref}]) before the typed pipeline, so a simulation file that
    # references its components by `{"ref": "..."}` — as the Python runner's
    # by-name model resolver expects — loads here too. Returns `nothing` when
    # the file has no such stubs (the common case), in which case the
    # already-parsed document is reused as-is; only the stub path pays a copy
    # (the inliner rewrites the document structurally).
    # Two composable passes: top-level model `{ref}` stubs, then top-level
    # reaction_system `{ref}` stubs (schema §4.7: each block's entry is
    # oneOf [component, {ref}]). The reaction-system pass runs on the model
    # pass's output when it produced one, so an assembly may mount a
    # model AND a reaction system by reference on the same document.
    inlined_m = _inline_toplevel_model_refs(raw_data, base_path)
    rs_src = inlined_m === nothing ? raw_data : inlined_m
    inlined_r = _inline_toplevel_reaction_system_refs(rs_src, base_path)
    inlined = inlined_r !== nothing ? inlined_r : inlined_m
    # One carrier end to end: the inliners emit the same normalized native
    # tree the parse boundary produces, so there is no re-serialize
    # type-launder between them and the typed pipeline.
    doc = inlined === nothing ? raw_data : inlined
    file = _load_parsed(doc; base_path=base_path, metaparameters=metaparameters)
    # Resolve nested subsystem references relative to the document's directory.
    resolve_subsystem_refs!(file, base_path)
    return file
end

"""
    load(io::IO; base_path=pwd(), metaparameters=Dict{String,Int}()) -> EsmFile

Load and parse an ESM file from an IO stream. `base_path` anchors relative
`expression_template_imports` refs (esm-spec §9.7.2); `metaparameters` binds
the document's open metaparameters at the loader API (esm-spec §9.7.6).
"""
function load(io::IO; base_path::AbstractString=pwd(),
              metaparameters::AbstractDict{String,<:Integer}=Dict{String,Int}(),
              injected_imports::AbstractVector=Any[])::EsmFile
    json_string = read(io, String)
    raw_data = _read_json_document(json_string)
    return _load_parsed(raw_data; base_path=base_path,
                        metaparameters=metaparameters,
                        injected_imports=injected_imports)
end

"""
    _read_json_document(json_string) -> OrderedDict{String,Any} document

THE wire boundary: parse a JSON document string and normalize it — once, here
— into the single post-wire carrier (`_to_ordered`: order-preserving,
string-keyed native tree). Everything downstream (schema validation, template
lowering, coercion) speaks exactly this one carrier. A malformed-JSON failure
is rebranded as a [`ParseError`](@ref) ("Invalid JSON: …"); ONLY the JSON3
parse is guarded — downstream schema/coercion errors propagate with their own
types, never rebranded as JSON errors.
"""
function _read_json_document(json_string::AbstractString)
    parsed = try
        JSON3.read(json_string)
    catch e
        msg = hasfield(typeof(e), :msg) ? e.msg : sprint(showerror, e)
        throw(ParseError("Invalid JSON: $(msg)", e))
    end
    return _to_ordered(parsed)
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
    _load_parsed(raw_data; base_path, metaparameters, injected_imports) -> EsmFile

Shared typed-load pipeline over an already-JSON-parsed document: version
gates → schema validation → raw structural checks → §9.7 machinery →
template lowering → typed coercion. Used by both `load(::IO)` and
`load(::String)` (which parses the file once and reuses the document).
"""
function _load_parsed(raw_data; base_path::AbstractString=pwd(),
                      metaparameters::AbstractDict{String,<:Integer}=Dict{String,Int}(),
                      injected_imports::AbstractVector=Any[])::EsmFile
    # v0.4.0 expression_templates / apply_expression_template are
    # rejected when the file declares esm < 0.4.0 (RFC §5.4 spec-version
    # gate). Surfaced before schema validation so the user sees the
    # version hint instead of a generic "extra property" error.
    reject_expression_templates_pre_v04(raw_data)

    # v0.8.0 §9.7 constructs (expression_template_imports, top-level
    # expression_templates, metaparameters) are rejected when the file
    # declares esm < 0.8.0 (esm-spec §9.6.5).
    reject_template_imports_pre_v08(raw_data)

    # Validate schema
    schema_errors = validate_schema(raw_data)
    if !isempty(schema_errors)
        throw(SchemaValidationError(_format_schema_errors(schema_errors), schema_errors))
    end

    # v0.8.0 §11.4.1: reject an `ic`-op equation placed inside a reaction
    # system's `constraint_equations`. Julia does not parse a reaction
    # system's `constraint_equations` into its typed form, so this is a raw
    # JSON structural check run here (schema has already passed — the file
    # is schema-valid, `constraint_equations` is an array of Equation and
    # `ic` is a legal op, so nothing in JSON Schema forbids it). Diagnostic
    # code: `ic_in_reaction_system`.
    _reject_ic_in_reaction_system(raw_data)

    # Emit E_DEPRECATED_DOMAIN_BC for any v0.1.0-style domain-level
    # boundary_conditions (v0.2.0 transitional shim per RFC §10.1 +
    # gt-2fvs mayor decision). A follow-up bead flips this to a hard error.
    _warn_deprecated_domain_bc(raw_data)

    return _lower_and_coerce(raw_data, base_path;
                             metaparameters=metaparameters,
                             injected_imports=injected_imports)
end

"""
    _lower_and_coerce(raw_data, base_path; metaparameters, injected_imports) -> EsmFile

Shared injection → template-machinery → lowering → wrap → coercion tail of the
load pipeline, used by `_load_parsed` and `_load_remote_ref`.

Resolves esm-spec §9.7 machinery first — template-library imports
(depth-first post-order, per-edge metaparameter instantiation), index_sets
merge, metaparameter close+fold — then expands `apply_expression_template`
ops / fires `match` rules to the §9.6.3 fixpoint. After both passes the typed
tree carries no apply_expression_template nodes, no `expression_templates`
blocks, no imports, and no metaparameters — downstream consumers see only
normal Expression ASTs (Option A round-trip).

esm-spec §9.7.10 forms A/B: any scope-directed injection — a subsystem-ref
edge's `injected_imports` (form A) or a coupling entry's injection map
(form B) — is folded into the target components' own
`expression_template_imports` BEFORE resolution, so the ordinary import
resolver + §9.6.3 fixpoint lower the target under the assembler-chosen
discretization.
"""
function _lower_and_coerce(raw_data, base_path::AbstractString;
                           metaparameters::AbstractDict{String,<:Integer}=Dict{String,Int}(),
                           injected_imports::AbstractVector=Any[])::EsmFile
    # Snapshot the top-level DECLARATIONS verbatim, BEFORE any lowering touches
    # them. Option A expands call sites; it does not delete declarations (esm-spec
    # §9.6.4 rule 5), and a pure template library must round-trip to itself — but
    # the lowering below rewrites these blocks in place (bodies composed,
    # metaparameters folded away) and then strips them, so the snapshot has to be
    # taken here, off the raw document, or the emitted registry is a mangled one.
    raw_templates = _verbatim_decl(raw_data, :expression_templates)
    raw_metaparams = _verbatim_decl(raw_data, :metaparameters)
    # streaming-output-sinks RFC §8.3: the additive document-scoped `coordinates`
    # registry, snapshotted verbatim like the two above (coercion ignores it) so it
    # survives to `serialize_esm_file` and to the streaming-output writer.
    raw_coordinates = _verbatim_decl(raw_data, :coordinates)

    injected_root = apply_scope_injections(raw_data, injected_imports)
    machinery_input = injected_root === nothing ? raw_data : injected_root
    resolved = resolve_template_machinery(machinery_input, String(base_path);
                                          metaparameters=metaparameters)
    lowered_src = resolved === nothing ? machinery_input : resolved
    loaded = lower_expression_templates(lowered_src)
    # esm-spec §9.6.4 Option B: `lower_expression_templates` PRESERVES surviving
    # `apply_expression_template` references and per-component registries.
    #   * Default (fast path): references survive into the typed IR. The
    #     per-component registries are MATERIALIZED (`_materialize_components!`) and
    #     carried on the EsmFile so `save` emits the reference-preserving form
    #     (R1 / §9.6.4 rule 5). The build paths handle references (tree-walk via a
    #     per-node `Expand` fallback; MTK Expands-at-entry).
    #   * `ESS_TEMPLATE_REF_DISABLE=1`: Expand at load (Option-A image), references
    #     never reach the build. This is the escape hatch analogous to
    #     `ESS_STENCIL_DISABLE` and the differential-test baseline (gate d).
    comp_tpls = nothing
    esm_stamp = nothing
    if loaded !== lowered_src
        # Template machinery ran: `loaded` is the fresh rewritten native root
        # (the no-machinery fast path returns its input BY IDENTITY).
        if _template_ref_disabled()
            expanded = expand_document(loaded)
        else
            root = loaded
            authored = _authored_template_names(machinery_input)
            # Coupling `variable_map` transform references can't be per-component
            # materialized (coupling is not a component), so expand them against
            # the receiving component's registry BEFORE it is stripped below.
            _expand_coupling_transform_refs!(root)
            blocks, bump = _materialize_components!(root, authored)
            # The materialized blocks travel on the EsmFile (for emit); strip them
            # from the coerce tree so `coerce_esm_file` only sees the surviving
            # references in expression positions.
            for compkind in ("models", "reaction_systems")
                comps = get(root, compkind, nothing)
                (comps isa AbstractDict) || continue
                for (_, comp) in comps
                    comp isa AbstractDict && haskey(comp, "expression_templates") &&
                        delete!(comp, "expression_templates")
                end
            end
            if !isempty(blocks)
                comp_tpls = Dict{String,Any}(k => v for (k, v) in blocks)
            end
            bump && (esm_stamp = "0.9.0")
            expanded = root
        end
    else
        # No component templates (e.g. a directly-loaded library file, or a
        # metaparameters-only problem file): the document flows on unchanged;
        # `coerce_esm_file` normalizes at its own boundary.
        expanded = loaded
    end
    # Coerce under an identity parse memo (see `_PARSE_EXPR_MEMO_KEY`) so the
    # structural sharing the template-expansion passes built in the raw tree
    # carries over into the typed IR as shared `OpExpr` nodes — which the
    # build-time `IdDict` memo caches (tree_walk/compile.jl) then exploit.
    file = task_local_storage(_PARSE_EXPR_MEMO_KEY, IdDict{Any,ASTExpr}()) do
        coerce_esm_file(expanded)
    end
    return _with_declarations(file, raw_templates, raw_metaparams;
                              component_templates=comp_tpls, esm=esm_stamp,
                              coordinates=raw_coordinates)
end

"""
    _template_ref_disabled() -> Bool

The `ESS_TEMPLATE_REF_DISABLE=1` escape hatch (analogous to `ESS_STENCIL_DISABLE`,
RFC out-of-line-expression-templates §7.7 / §12): when set, expression-template
references are Expanded at load (the Option-A image) and never reach the build;
when unset (default), references survive into the typed IR and the build handles
them. Gate (d)'s differential builds a fixture both ways and compares exactly.
"""
_template_ref_disabled() = get(ENV, "ESS_TEMPLATE_REF_DISABLE", "") == "1"

# A deep, plain-`Dict` copy of a top-level declaration block, or `nothing`.
# Plain `Dict`/`Vector`/scalars only (`_to_native_json`) — the snapshot lives
# on the typed `EsmFile` and is re-emitted verbatim by `serialize_esm_file`,
# whose byte surface has always been the plain-Dict one.
function _verbatim_decl(raw_data, key::Symbol)
    v = _get_field(raw_data, key, nothing)
    v === nothing && return nothing
    d = _to_native_json(v)
    return d isa AbstractDict ? d : nothing
end

# Rebuild `file` carrying the verbatim declaration blocks and, from esm 0.9.0
# (Option B), the per-component MATERIALIZED template registries + a possibly
# version-stamped `esm`. `EsmFile` is immutable.
_with_declarations(file::EsmFile, templates, metaparams;
                   component_templates=nothing, esm=nothing, coordinates=nothing) =
    (templates === nothing && metaparams === nothing &&
     component_templates === nothing && esm === nothing && coordinates === nothing) ? file :
    EsmFile(esm === nothing ? file.esm : esm, file.metadata;
            models=file.models,
            reaction_systems=file.reaction_systems,
            data_loaders=file.data_loaders,
            coupling=file.coupling,
            domain=file.domain,
            enums=file.enums,
            function_tables=file.function_tables,
            index_sets=file.index_sets,
            expression_templates=templates,
            metaparameters=metaparams,
            component_templates=component_templates,
            coordinates=coordinates)

# ========================================
# Top-level model {ref} resolution (schema §4.7: models.* = oneOf [Model, {ref}])
# ========================================
#
# A bare `{"ref": "..."}` top-level model points at a component file's single
# model (the WildlandFire-style simulation files wire their components this way,
# matching the Python runner's by-name model resolver). The typed coercion path
# requires a `Model` with `variables`, so the reference is inlined at the
# raw-JSON level — before schema validation, expression-template lowering, and
# coercion — and the blocks the model's AST references by name
# (`function_tables`, `enums`, `data_loaders`) are merged in from the component.
# Nested subsystem `{ref}`s inside the component are rewritten to absolute paths
# so the later `resolve_subsystem_refs!` pass (anchored at the *parent* dir)
# still finds them. Resolution recurses (a component may itself reference another
# at top level) with cycle detection shared across the walk.

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

Both the local/remote subsystem loaders and the top-level model-ref inliner
(`_inline_toplevel_model_refs!`) route through here, so template *and* coupling
libraries are rejected uniformly at every subsystem-ref site.
"""
function _reject_library_ref(raw_doc, ref::AbstractString,
                             location::Union{AbstractString,Nothing})
    suffix = location === nothing ? "" : " ($(location))"
    if _is_template_library_doc(raw_doc)
        throw(ExpressionTemplateError(
            "subsystem_ref_is_template_library",
            "Subsystem ref '$(ref)' targets a template-library file$(suffix); " *
            "libraries are imported via expression_template_imports (esm-spec §9.7.1)"))
    end
    if _is_coupling_library_doc(raw_doc)
        throw(ExpressionTemplateError(
            "subsystem_ref_is_coupling_library",
            "Subsystem ref '$(ref)' targets a coupling-library file$(suffix); " *
            "libraries are imported via a coupling_import coupling entry (esm-spec §10.9)"))
    end
    return nothing
end

"""
    _inline_toplevel_model_refs(raw_data, base_path) -> Union{Nothing,Dict{String,Any}}

Return a native ESM dict with every top-level model `{ref}` stub replaced by the
referenced component's model (and its `function_tables` / `enums` /
`data_loaders` merged in), or `nothing` when `raw_data` has no such stub.
The stub path copies the document (`_to_ordered`, order-preserving) so the
in-place worker never mutates the caller's tree; the reaction-system inliner
composes on the same copy, and `load(::AbstractDict)` resolves stubs exactly
as `load(::String)` does.
"""
function _inline_toplevel_model_refs(raw_data, base_path::String)
    models = _get_field(raw_data, :models, nothing)
    models === nothing && return nothing
    has_stub = any(values(models)) do m
        _is_json_object(m) && _has_field(m, :ref) && !_has_field(m, :variables)
    end
    has_stub || return nothing
    native = _to_ordered(raw_data)
    _inline_toplevel_model_refs!(native, base_path, Set{String}())
    return native
end

"""
    _inline_toplevel_model_refs!(native, base_path, visited)

In-place native-dict worker for [`_inline_toplevel_model_refs`](@ref).
"""
function _inline_toplevel_model_refs!(native::AbstractDict{String,Any}, base_path::String,
                                      visited::Set{String})
    models = get(native, "models", nothing)
    models isa AbstractDict || return
    for (name, entry) in collect(models)
        (entry isa AbstractDict && haskey(entry, "ref") &&
            !haskey(entry, "variables")) || continue
        ref = _expand_ref_env(String(entry["ref"]))  # esm-spec §4.7 ${VAR} expansion
        # Optional model selector: when the referenced file holds several models
        # (e.g. an ESD regridder library), `model` names which one to splice in.
        sel = haskey(entry, "model") && entry["model"] !== nothing ?
              String(entry["model"]) : nothing
        refpath = abspath(joinpath(base_path, ref))
        # Cycle detection is PATH-scoped (push on enter, pop on exit) so the same
        # single-model file may be referenced by several model instances — only a
        # reference cycle along the current resolution path is an error.
        if refpath in visited
            throw(SubsystemRefError("Circular top-level model reference detected: $(refpath)"))
        end
        push!(visited, refpath)
        try
            isfile(refpath) || throw(SubsystemRefError(
                "Referenced model file not found: $(refpath) (from ref '$(ref)')"))
            comp = _to_ordered(JSON3.read(read(refpath, String)))
            comp isa AbstractDict{String,Any} || throw(SubsystemRefError(
                "Referenced model file '$(ref)' did not parse as a JSON object"))
            # A §4.7 subsystem ref (here, a top-level model `{ref}`) MUST NOT
            # target a library file — neither a template library nor a coupling
            # library. Same rejection as `_load_local_ref` / `_load_remote_ref`.
            _reject_library_ref(comp, ref, refpath)
            compdir = dirname(refpath)
            _inline_toplevel_model_refs!(comp, compdir, visited)   # component-of-component
            cmodels = get(comp, "models", nothing)
            cmodels isa AbstractDict || throw(SubsystemRefError(
                "Top-level model ref '$(ref)' resolves to a file with no models block"))
            cmodel = if sel !== nothing
                haskey(cmodels, sel) || throw(SubsystemRefError(
                    "Top-level model ref '$(ref)' has no model '$(sel)' " *
                    "(available: $(join(sort(collect(keys(cmodels))), ", ")))"))
                cmodels[sel]
            else
                length(cmodels) == 1 || throw(SubsystemRefError(
                    "Top-level model ref '$(ref)' resolves to $(length(cmodels)) models; " *
                    "add a \"model\" selector to choose one " *
                    "(available: $(join(sort(collect(keys(cmodels))), ", ")))"))
                first(values(cmodels))
            end
            _absolutize_nested_refs!(cmodel, compdir)
            models[name] = cmodel
            # esm-spec §9.7.10 form A at a TOP-LEVEL model-ref edge: the edge's
            # `expression_template_imports` inject a discretization into the
            # referenced (now spliced-in) component's own scope — exactly as a
            # subsystem-ref edge does (`_resolve_subsystem_ref`), so an assembler
            # chooses the scheme for a discretization-agnostic PDE leaf without
            # editing the leaf. The edge's import refs are authored relative to
            # THIS document's directory (not the leaf's), so absolutize them
            # against `base_path`, then append AFTER the leaf's own imports
            # (§9.7.10 merge order: target's own first, then injected). The merged
            # doc is resolved once at the root, so the loader-API metaparameters
            # (grid resolution) reach the leaf document-wide.
            edge_imports = get(entry, "expression_template_imports", nothing)
            if edge_imports isa AbstractVector && !isempty(edge_imports)
                imports_native = _to_ordered(edge_imports)
                _absolutize_nested_refs!(imports_native, base_path)
                _append_component_imports!(cmodel, imports_native)
            end
            # Merge the by-name blocks the model's AST references; the parent wins
            # on a key clash (its own definitions take precedence).
            for blk in ("function_tables", "data_loaders", "enums")
                src = get(comp, blk, nothing)
                (src isa AbstractDict && !isempty(src)) || continue
                dst = get!(() -> Dict{String,Any}(), native, blk)
                dst isa AbstractDict || continue
                for (k, v) in src
                    haskey(dst, k) || (dst[k] = v)
                end
            end
        finally
            delete!(visited, refpath)
        end
    end
    return
end

"""
    _inline_toplevel_reaction_system_refs(raw_data, base_path) -> Union{Nothing,Dict{String,Any}}

Return a native ESM dict with every top-level reaction_system `{ref}` stub
replaced by the referenced component's reaction system (and its
`function_tables` / `enums` / `data_loaders` merged in), or `nothing` when
`raw_data` has no such stub. The reaction-system analogue of
[`_inline_toplevel_model_refs`](@ref) (schema §4.7: a `reaction_systems` entry is
`oneOf [ReactionSystem, {ref}]`), so an assembly may mount an external
reaction-system file — e.g. `superfast.esm` — by reference instead of inlining
its whole `reaction_systems` block. Accepts the post-wire native document or
the model-ref inliner's output, so the two top-level inliners compose on one
document.
"""
function _inline_toplevel_reaction_system_refs(raw_data, base_path::String)
    rsystems = _get_field(raw_data, :reaction_systems, nothing)
    rsystems === nothing && return nothing
    has_stub = any(values(rsystems)) do r
        _is_json_object(r) && _has_field(r, :ref) && !_has_field(r, :species)
    end
    has_stub || return nothing
    native = _to_ordered(raw_data)
    _inline_toplevel_reaction_system_refs!(native, base_path, Set{String}())
    return native
end

"""
    _inline_toplevel_reaction_system_refs!(native, base_path, visited)

In-place native-dict worker for [`_inline_toplevel_reaction_system_refs`](@ref).
Mirrors [`_inline_toplevel_model_refs!`](@ref): loads each stub's referenced file,
splices in its single top-level reaction system (or the one named by a
`"reaction_system"` selector), and merges the `function_tables` / `data_loaders`
/ `enums` blocks the reaction system's AST references (parent wins on a clash).
Cycle detection is PATH-scoped, so the same single-reaction-system file may be
mounted under several assembly keys.
"""
function _inline_toplevel_reaction_system_refs!(native::AbstractDict{String,Any}, base_path::String,
                                                visited::Set{String})
    rsystems = get(native, "reaction_systems", nothing)
    rsystems isa AbstractDict || return
    for (name, entry) in collect(rsystems)
        (entry isa AbstractDict && haskey(entry, "ref") &&
            !haskey(entry, "species")) || continue
        ref = _expand_ref_env(String(entry["ref"]))  # esm-spec §4.7 ${VAR} expansion
        # Optional reaction-system selector: when the referenced file holds
        # several reaction systems, `reaction_system` names which one to splice.
        sel = haskey(entry, "reaction_system") && entry["reaction_system"] !== nothing ?
              String(entry["reaction_system"]) : nothing
        refpath = abspath(joinpath(base_path, ref))
        if refpath in visited
            throw(SubsystemRefError("Circular top-level reaction system reference detected: $(refpath)"))
        end
        push!(visited, refpath)
        try
            isfile(refpath) || throw(SubsystemRefError(
                "Referenced reaction system file not found: $(refpath) (from ref '$(ref)')"))
            comp = _to_ordered(JSON3.read(read(refpath, String)))
            comp isa AbstractDict{String,Any} || throw(SubsystemRefError(
                "Referenced reaction system file '$(ref)' did not parse as a JSON object"))
            # A §4.7 subsystem ref MUST NOT target a template/coupling library.
            _reject_library_ref(comp, ref, refpath)
            compdir = dirname(refpath)
            # component-of-component: the referenced file may itself mount refs.
            _inline_toplevel_model_refs!(comp, compdir, visited)
            _inline_toplevel_reaction_system_refs!(comp, compdir, visited)
            crsystems = get(comp, "reaction_systems", nothing)
            crsystems isa AbstractDict || throw(SubsystemRefError(
                "Top-level reaction system ref '$(ref)' resolves to a file with no reaction_systems block"))
            crsys = if sel !== nothing
                haskey(crsystems, sel) || throw(SubsystemRefError(
                    "Top-level reaction system ref '$(ref)' has no reaction system '$(sel)' " *
                    "(available: $(join(sort(collect(keys(crsystems))), ", ")))"))
                crsystems[sel]
            else
                length(crsystems) == 1 || throw(SubsystemRefError(
                    "Top-level reaction system ref '$(ref)' resolves to $(length(crsystems)) reaction systems; " *
                    "add a \"reaction_system\" selector to choose one " *
                    "(available: $(join(sort(collect(keys(crsystems))), ", ")))"))
                first(values(crsystems))
            end
            _absolutize_nested_refs!(crsys, compdir)
            rsystems[name] = crsys
            # esm-spec §9.7.10 form A at a TOP-LEVEL reaction-system-ref edge:
            # the edge's `expression_template_imports` inject into the referenced
            # component's own scope, appended AFTER its own imports (§9.7.10 merge
            # order), with refs anchored at THIS document's directory.
            edge_imports = get(entry, "expression_template_imports", nothing)
            if edge_imports isa AbstractVector && !isempty(edge_imports)
                imports_native = _to_ordered(edge_imports)
                _absolutize_nested_refs!(imports_native, base_path)
                _append_component_imports!(crsys, imports_native)
            end
            # Merge the by-name blocks the reaction system's AST references; the
            # parent wins on a key clash (its own definitions take precedence).
            for blk in ("function_tables", "data_loaders", "enums")
                src = get(comp, blk, nothing)
                (src isa AbstractDict && !isempty(src)) || continue
                dst = get!(() -> Dict{String,Any}(), native, blk)
                dst isa AbstractDict || continue
                for (k, v) in src
                    haskey(dst, k) || (dst[k] = v)
                end
            end
        finally
            delete!(visited, refpath)
        end
    end
    return
end

"""
    _absolutize_nested_refs!(node, compdir)

Rewrite every relative `{"ref": "..."}` under `node` to an absolute path anchored
at `compdir`, so the references resolve after the model is spliced into a parent
whose directory differs.
"""
function _absolutize_nested_refs!(node, compdir::String)
    if node isa AbstractDict
        r = get(node, "ref", nothing)
        if r isa AbstractString
            r = _expand_ref_env(r)  # esm-spec §4.7 ${VAR} expansion (before anchoring)
            node["ref"] = (startswith(r, "/") || startswith(r, "http://") ||
                           startswith(r, "https://")) ? r : abspath(joinpath(compdir, r))
        end
        for v in values(node)
            _absolutize_nested_refs!(v, compdir)
        end
    elseif node isa AbstractVector
        for v in node
            _absolutize_nested_refs!(v, compdir)
        end
    end
    return
end

"""
    _warn_deprecated_domain_bc(raw_data)

Emit an `@warn` for each `domains.<d>.boundary_conditions` encountered.
This is the v0.2.0 transitional shim introduced by gt-2fvs; the canonical
form is `models.<M>.boundary_conditions` (RFC §9). A follow-up bead will
turn the warning into a schema-level hard error.
"""
function _warn_deprecated_domain_bc(raw_data)
    # Through `_get_field` / `_has_field`, not a symbol-keyed `get`: the document
    # also arrives here as a string-keyed native dict (`load(::AbstractDict)`),
    # for which a symbol lookup silently finds nothing and skips the check.
    domains = _get_field(raw_data, :domains, nothing)
    domains === nothing && return
    for (domain_name, domain) in domains
        if _has_field(domain, :boundary_conditions)
            @warn string(
                "[E_DEPRECATED_DOMAIN_BC] domains.", domain_name,
                ".boundary_conditions is deprecated in ESM v0.2.0; migrate ",
                "to models.<M>.boundary_conditions ",
                "(docs/rfcs/discretization.md §9)."
            )
        end
    end
    return
end

# ========================================
# Subsystem Reference Resolution
# ========================================

"""
    SubsystemRefError

Exception thrown when subsystem reference resolution fails.
"""
struct SubsystemRefError <: Exception
    message::String
    # The MACHINE-READABLE half (finding (f)). A subsystem ref that does not
    # resolve is a validation finding with a canonical code, a document pointer
    # and `details` — the corpus pins `unresolved_subsystem_ref` /
    # `ambiguous_subsystem_ref` at `/models/<M>/subsystems/<S>` — not merely a
    # thrown string. Load still THROWS (a document with an unresolvable mount
    # cannot be built), but the throw now carries everything `validate` needs to
    # render the pinned structural error instead of a bare message.
    #
    # The deep site knows the `ref` and the code; only the caller knows which
    # subsystem of which model it was mounting, so it enriches on the way out.
    code::String
    ref::String
    subsystem::String
    parent_model::String

    SubsystemRefError(message::AbstractString; code::AbstractString="unresolved_subsystem_ref",
                      ref::AbstractString="", subsystem::AbstractString="",
                      parent_model::AbstractString="") =
        new(String(message), String(code), String(ref), String(subsystem), String(parent_model))
end

Base.showerror(io::IO, e::SubsystemRefError) =
    print(io, "SubsystemRefError: ", e.message)

# Re-throw `e` with the mount site filled in. The resolver raises from deep
# inside `_load_ref`, where the parent model and subsystem key are not known.
_with_mount_site(e::SubsystemRefError, subsystem::AbstractString, parent_model::AbstractString) =
    SubsystemRefError(e.message; code=e.code, ref=e.ref,
                      subsystem = isempty(e.subsystem) ? subsystem : e.subsystem,
                      parent_model = isempty(e.parent_model) ? parent_model : e.parent_model)

"""
    resolve_subsystem_refs!(file::EsmFile, base_path::String)

Resolve all subsystem references in-place. Walks all models and reaction_systems,
and for each subsystem that was parsed from a `{"ref": "..."}` object, loads the
referenced file and replaces the subsystem content.

References can be:
- Local file paths (resolved relative to `base_path`)
- Remote URLs starting with `http://` or `https://`

Circular references are detected and raise a `SubsystemRefError`.

# Arguments
- `file::EsmFile`: the parsed ESM file to resolve references in
- `base_path::String`: directory path for resolving relative file references
"""
function resolve_subsystem_refs!(file::EsmFile, base_path::String)
    visited = Set{String}()
    _resolve_refs_in_file!(file, base_path, visited)
end

"""
    _resolve_refs_in_file!(file::EsmFile, base_path::String, visited::Set{String})

Internal recursive resolver for subsystem references in an EsmFile.
"""
function _resolve_refs_in_file!(file::EsmFile, base_path::String, visited::Set{String})
    # Resolve model subsystem refs. The document's own index-set registry is
    # threaded down the walk so every referenced subsystem file's top-level
    # `index_sets` merge into it (esm-spec §4.7, mirroring §9.7.5).
    if file.models !== nothing
        for (name, model) in file.models
            _resolve_model_refs!(file.models, name, model, base_path, visited,
                                 file.index_sets)
        end
    end

    # Resolve reaction system subsystem refs
    if file.reaction_systems !== nothing
        for (name, rsys) in file.reaction_systems
            _resolve_reaction_system_refs!(file.reaction_systems, name, rsys, base_path, visited)
        end
    end
end

"""
    _resolve_model_refs!(models_dict, name, model, base_path, visited, registry)

Recursively resolve subsystem references within a Model's subsystems.
`registry` is the importing **document's** index-set registry
(`EsmFile.index_sets`): every referenced subsystem file's top-level
`index_sets` merge into it at resolution time (esm-spec §4.7).
"""
function _resolve_model_refs!(models_dict, name::String,
                              model, base_path::String, visited::Set{String},
                              registry::Dict{String,IndexSet})
    # Only Model values carry subsystems to walk; DataLoader / SubsystemRef
    # leaves have none.
    model isa Model || return
    for (sub_name, sub_value) in collect(model.subsystems)
        if sub_value isa SubsystemRef
            # Replace the reference in place with the loaded component. The
            # loaded file's own refs are already resolved by `_load_ref`.
            #
            # The resolver raises from deep inside `_load_ref`, which knows the
            # `ref` but not WHERE it was mounted. This is the only frame that
            # knows both, so it stamps the mount site on the way out — that is
            # what lets `validate` render the pinned pointer
            # `/models/<parent>/subsystems/<sub>` (finding (f)).
            model.subsystems[sub_name] = try
                _resolve_subsystem_ref(sub_value, base_path, visited, registry)
            catch e
                e isa SubsystemRefError || rethrow()
                throw(_with_mount_site(e, sub_name, name))
            end
        else
            # Inline Model (recurse into its subsystems) or DataLoader (leaf).
            _resolve_model_refs!(model.subsystems, sub_name, sub_value, base_path,
                                 visited, registry)
        end
    end
end

# Deep (structural) equality of two typed `IndexSet` declarations — the §4.7 /
# §9.7.5 idempotent-redeclaration test. Field-wise `==` (the default struct
# `==` falls back to `===`, which is identity for heap-allocated member
# vectors, so it cannot be used here).
_index_set_deep_equal(a::IndexSet, b::IndexSet) =
    a.kind == b.kind && a.size == b.size && a.members == b.members &&
    a.of == b.of && a.offsets == b.offsets && a.values == b.values &&
    a.from_faq == b.from_faq && a.members_raw == b.members_raw &&
    a.member_factor == b.member_factor

# One-line display of an IndexSet for the conflict diagnostic.
_index_set_show(s::IndexSet) =
    "kind=$(s.kind)" * (s.size === nothing ? "" : ", size=$(s.size)") *
    (s.members === nothing ? "" : ", members=$(s.members)") *
    (s.of === nothing ? "" : ", of=$(s.of)") *
    (s.from_faq === nothing ? "" : ", from_faq=$(s.from_faq)")

"""
    _merge_subsystem_index_sets!(registry, loaded, ref)

Merge a referenced subsystem file's top-level `index_sets` into the importing
document's registry (esm-spec §4.7, mirroring the §9.7.5 template-import
merge). The referenced document's metaparameters are already closed and
folded (`_load_ref` binds them at the edge, §9.7.6 site 3), so the merge
compares concrete declarations. Deep-equal redeclaration is idempotent; a
non-equal collision throws [`ExpressionTemplateError`](@ref) with the stable
code `subsystem_index_set_conflict` (§9.6.6) — the mounted-mesh failure mode
this makes loud: a mesh file whose axis size disagrees with the importer's
declaration must fail at load, not silently resolve against the importer.
"""
function _merge_subsystem_index_sets!(registry::Dict{String,IndexSet},
                                      loaded::EsmFile, ref::String)
    for (n, decl) in loaded.index_sets
        if haskey(registry, n)
            _index_set_deep_equal(registry[n], decl) ||
                throw(ExpressionTemplateError("subsystem_index_set_conflict",
                    "index set '$(n)' from subsystem ref '$(ref)' " *
                    "($(_index_set_show(decl))) collides with a non-deep-equal " *
                    "declaration in the importing document " *
                    "($(_index_set_show(registry[n]))). A referenced subsystem " *
                    "file's top-level index_sets merge into the importing " *
                    "document's registry; deep-equal redeclaration is idempotent, " *
                    "a size/kind disagreement is a load-time error (esm-spec §4.7)."))
        else
            registry[n] = decl
        end
    end
    return registry
end

"""
    _resolve_subsystem_ref(ref, base_path, visited, registry) -> Union{Model,DataLoader}

Load the ESM file at `ref` and return its single top-level model or data loader
(esm-spec §4.7). A single-loader file (RFC pure-io-data-loaders §4.4) resolves to
that loader. Errors unless the file contains exactly one model or data loader.
A `SubsystemRef`'s `bindings` close the referenced document's open
metaparameters (esm-spec §9.7.6 binding site 3); a `ref` targeting a
template-library file is rejected with `subsystem_ref_is_template_library`.
The referenced file's top-level `index_sets` merge into `registry` — the
importing document's registry — with the §4.7 deep-equal-or-error rule
(`subsystem_index_set_conflict`).
"""
function _resolve_subsystem_ref(ref::SubsystemRef, base_path::String, visited::Set{String},
                                registry::Dict{String,IndexSet})
    # esm-spec §9.7.10 form A: the edge's `expression_template_imports` inject a
    # discretization into the referenced component's own scope, threaded into
    # its load so the §9.6.3 fixpoint lowers its rewrite-targets at the mount.
    loaded = _load_ref(ref.ref, base_path, visited;
                       metaparameters=ref.bindings,
                       injected_imports=ref.expression_template_imports)
    n_models = loaded.models === nothing ? 0 : length(loaded.models)
    n_loaders = loaded.data_loaders === nothing ? 0 : length(loaded.data_loaders)
    total = n_models + n_loaders
    if total != 1
        throw(SubsystemRefError(
            "Subsystem reference '$(ref.ref)' resolves to a file containing multiple " *
            "top-level systems; exactly one is required";
            code="ambiguous_subsystem_ref", ref=ref.ref))
    end
    # esm-spec §4.7: the mounted file's document-scoped index sets (already
    # metaparameter-folded, incl. any brought in by ITS own subsystem refs)
    # join the importing document's registry, so the importer's variables may
    # be shaped over the mesh file's axes and a disagreement fails loudly.
    _merge_subsystem_index_sets!(registry, loaded, ref.ref)
    return n_models == 1 ? first(values(loaded.models)) : first(values(loaded.data_loaders))
end

_resolve_subsystem_ref(ref::String, base_path::String, visited::Set{String},
                       registry::Dict{String,IndexSet}=Dict{String,IndexSet}()) =
    _resolve_subsystem_ref(SubsystemRef(ref), base_path, visited, registry)

"""
    _resolve_reaction_system_refs!(rsys_dict, name, rsys, base_path, visited)

Recursively resolve subsystem references within a ReactionSystem's subsystems.
"""
function _resolve_reaction_system_refs!(rsys_dict::Dict{String,ReactionSystem}, name::String,
                                        rsys::ReactionSystem, base_path::String, visited::Set{String})
    for (sub_name, sub_rsys) in rsys.subsystems
        # Recursively resolve nested subsystem refs
        _resolve_reaction_system_refs!(rsys.subsystems, sub_name, sub_rsys, base_path, visited)
    end
end

"""
    _load_ref(ref::String, base_path::String, visited::Set{String}) -> EsmFile

Load a referenced ESM file from a local path or URL, with circular reference detection.

# Arguments
- `ref::String`: the reference string (local path or URL)
- `base_path::String`: directory for resolving relative paths
- `visited::Set{String}`: set of already-visited references for cycle detection
"""
function _load_ref(ref::String, base_path::String, visited::Set{String};
                   metaparameters::AbstractDict{String,<:Integer}=Dict{String,Int}(),
                   injected_imports::AbstractVector=Any[])::EsmFile
    # esm-spec §4.7: expand `${VAR}` from the environment before resolving.
    ref = _expand_ref_env(ref)
    # Normalize the reference for cycle detection
    canonical = _canonical_ref(ref, base_path)

    if canonical in visited
        throw(SubsystemRefError("Circular subsystem reference detected: $(canonical)"))
    end
    push!(visited, canonical)

    try
        if _is_url(ref) || _is_url(base_path)
            # An absolute URL ref, or a relative ref inside a document that
            # was itself loaded from a URL: resolve against the URL base
            # (`canonical` is exactly the joined, normalized URL).
            return _load_remote_ref(canonical, visited; metaparameters=metaparameters,
                                    injected_imports=injected_imports)
        else
            return _load_local_ref(ref, base_path, visited; metaparameters=metaparameters,
                                   injected_imports=injected_imports)
        end
    catch e
        if e isa SubsystemRefError || e isa ExpressionTemplateError
            # ExpressionTemplateError carries the stable §9.6.6 diagnostic
            # codes (e.g. `subsystem_ref_is_template_library`,
            # `metaparameter_unbound`) — surfaced as-is for machine checking.
            rethrow(e)
        else
            throw(SubsystemRefError("Failed to resolve subsystem ref '$(ref)': $(e)"))
        end
    end
end

"""
    _is_url(s) -> Bool

True iff `s` is an http(s) URL (the two remote-reference schemes of
esm-spec §4.7).
"""
_is_url(s::AbstractString) = startswith(s, "http://") || startswith(s, "https://")

"""
    _url_split(url) -> (scheme_authority, path, suffix)

Split an http(s) URL into its scheme + authority (`"https://host[:port]"`),
its path (always at least `"/"`), and the trailing query/fragment suffix
(possibly empty).
"""
function _url_split(url::AbstractString)
    m = match(r"^(https?://[^/?#]*)([^?#]*)([\s\S]*)$", url)
    m === nothing && throw(ArgumentError("not an http(s) URL: '$url'"))
    scheme_authority, path, suffix = m.captures
    return String(scheme_authority), (isempty(path) ? "/" : String(path)), String(suffix)
end

"""
    _remove_dot_segments(path) -> String

RFC 3986 §5.2.4 dot-segment removal for a URL path beginning with `/`:
`"/a/b/../c/./d.esm"` → `"/a/c/d.esm"`. `..` never climbs above the root.
"""
function _remove_dot_segments(path::AbstractString)::String
    segs = split(path, '/')
    out = String[]
    for seg in segs
        if seg == "."
            continue
        elseif seg == ".."
            length(out) > 1 && pop!(out)
        else
            push!(out, String(seg))
        end
    end
    # A trailing "." / ".." leaves the result a directory: keep the slash.
    !isempty(segs) && (segs[end] == "." || segs[end] == "..") && push!(out, "")
    joined = join(out, "/")
    return isempty(joined) || joined == "/" ? "/" : joined
end

"""
    _url_normalize(url) -> String

Canonical form of an http(s) URL for cycle detection: dot segments removed
from the path, scheme/authority and any query/fragment preserved verbatim.
"""
function _url_normalize(url::AbstractString)::String
    sa, path, suffix = _url_split(url)
    return sa * _remove_dot_segments(path) * suffix
end

"""
    _url_join(base_url::AbstractString, ref::AbstractString) -> String

Resolve `ref` against `base_url`, where `base_url` names the DIRECTORY a
URL-loaded document was fetched from (`_url_dirname`). Absolute http(s)
refs pass through (normalized); `/`-rooted refs replace the base path;
anything else joins onto the base directory. Dot segments are removed
(RFC 3986 §5.2 relative resolution for the cases §4.7 admits)."""
function _url_join(base_url::AbstractString, ref::AbstractString)::String
    _is_url(ref) && return _url_normalize(ref)
    sa, bpath, _ = _url_split(base_url) # base query/fragment never inherited
    path = startswith(ref, "/") ? String(ref) :
           (endswith(bpath, "/") ? bpath * ref : bpath * "/" * ref)
    return sa * _remove_dot_segments(path)
end

"""
    _url_dirname(url) -> String

The URL of the directory containing `url`'s document — the base against
which the document's own relative refs resolve (drops the last path
segment and any query/fragment): `"https://h/lib/a.esm"` → `"https://h/lib"`.
"""
function _url_dirname(url::AbstractString)::String
    sa, path, _ = _url_split(url)
    i = findlast('/', path)
    return (i === nothing || i <= 1) ? sa : sa * path[1:prevind(path, i)]
end

"""
    _download_url_contents(url) -> String

Default URL fetcher: download `url` via `Base.download` and return its contents.
"""
function _download_url_contents(url::AbstractString)::String
    tmp = Base.download(url)
    content = read(tmp, String)
    rm(tmp, force=true)
    return content
end

const _URL_FETCHER = Ref{Function}(_download_url_contents)

"""
    _fetch_url(url) -> String

Fetch the contents of an http(s) URL. Indirected through `_URL_FETCHER`
so tests can substitute an offline fetcher (see `template_imports_test.jl`);
the default is [`_download_url_contents`](@ref) (`Base.download`).
"""
_fetch_url(url::AbstractString)::String = _URL_FETCHER[](url)

"""
    _canonical_ref(ref::String, base_path::String) -> String

Produce a canonical key for a reference, used for cycle detection.
URL identity is canonical: an absolute http(s) ref is normalized
(dot segments removed), and a relative ref whose referencing document
was itself loaded from a URL (`base_path` is a URL base) is joined
against that base. Local paths are resolved to absolute paths.
"""
function _canonical_ref(ref::String, base_path::String)::String
    if _is_url(ref)
        return _url_normalize(ref)
    elseif _is_url(base_path)
        return _url_join(base_path, ref)
    else
        return abspath(joinpath(base_path, ref))
    end
end

"""
    _load_local_ref(ref::String, base_path::String, visited::Set{String}) -> EsmFile

Load a locally referenced ESM file.
"""
function _load_local_ref(ref::String, base_path::String, visited::Set{String};
                         metaparameters::AbstractDict{String,<:Integer}=Dict{String,Int}(),
                         injected_imports::AbstractVector=Any[])::EsmFile
    resolved_path = abspath(joinpath(base_path, ref))

    if !isfile(resolved_path)
        throw(SubsystemRefError(
            "Subsystem reference '$(ref)' could not be resolved — file does not exist";
            code="unresolved_subsystem_ref", ref=ref))
    end

    # A §4.7 subsystem ref MUST NOT target a template- or coupling-library
    # file — those reference mechanisms are disjoint (esm-spec §9.7.1, §10.9).
    content = read(resolved_path, String)
    raw_ref_doc = JSON3.read(content)
    _reject_library_ref(raw_ref_doc, ref, resolved_path)

    # Parse the referenced file using the IO-based load (no ref resolution on
    # its own); the ref's directory anchors its template imports, the edge's
    # `bindings` close its metaparameters (esm-spec §9.7.6 site 3), and
    # `injected_imports` inject the edge's discretization into its single
    # component's scope (esm-spec §9.7.10 form A).
    ref_base = dirname(resolved_path)
    file = load(IOBuffer(content); base_path=ref_base, metaparameters=metaparameters,
                injected_imports=injected_imports)

    # Recursively resolve refs in the loaded file, relative to its own directory
    _resolve_refs_in_file!(file, ref_base, visited)

    return file
end

"""
    _load_remote_ref(url::String, visited::Set{String}) -> EsmFile

Load a remotely referenced ESM file from an (already joined, normalized)
URL. The document's OWN relative references — template imports and nested
subsystem refs — resolve against the URL's directory (`_url_dirname`),
mirroring `_load_local_ref`'s dirname anchoring; cycle detection carries
`visited` through with canonical URL identity.
"""
function _load_remote_ref(url::String, visited::Set{String}=Set{String}();
                          metaparameters::AbstractDict{String,<:Integer}=Dict{String,Int}(),
                          injected_imports::AbstractVector=Any[])::EsmFile
    local content::String
    try
        content = _fetch_url(url)
    catch e
        throw(SubsystemRefError("Failed to download subsystem ref '$(url)': $(e)"))
    end

    raw_data = JSON3.read(content)

    reject_expression_templates_pre_v04(raw_data)
    reject_template_imports_pre_v08(raw_data)

    # A §4.7 subsystem ref MUST NOT target a template- or coupling-library
    # file (esm-spec §9.7.1, §10.9). No location suffix for a remote ref: the
    # URL already appears as the ref itself.
    _reject_library_ref(raw_data, url, nothing)

    schema_errors = validate_schema(raw_data)
    if !isempty(schema_errors)
        # Carry the full per-error diagnostics (path/message/keyword) so a
        # schema-invalid remote component is as debuggable as a local one.
        throw(SubsystemRefError("Schema validation failed for remote ref '$(url)': " *
                                _format_schema_errors(schema_errors)))
    end

    # The URL base anchors the remote document's own template imports
    # (esm-spec §9.7.2: relative refs resolve against the referencing
    # file's location — for a URL-loaded file, its URL directory). A
    # subsystem-ref edge's injected discretization (esm-spec §9.7.10 form A)
    # folds into the single component's scope before resolution.
    url_base = _url_dirname(url)
    file = _lower_and_coerce(raw_data, url_base; metaparameters=metaparameters,
                             injected_imports=injected_imports)

    # Nested subsystem refs inside the remote document resolve against the
    # same URL base (relative refs join onto the URL; absolute URLs and the
    # shared `visited` set keep cycle detection canonical).
    _resolve_refs_in_file!(file, url_base, visited)

    return file
end
