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
the raw JSON document, ahead of coercion, so the rejection can carry the
offending document path.
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
                code = ERROR_CODES.IC_IN_REACTION_SYSTEM,
                path = "/reaction_systems/$(rs_name)/constraint_equations/$(i - 1)",
                details = Dict{String,Any}("system" => String(rs_name),
                                           "species" => species,
                                           "constraint_equation_index" => i - 1)
            ))
        end
    end
end

"""
    load_path(path::AbstractString; metaparameters=Dict{String,Int}()) -> EsmFile

Read and parse an ESM document from a filesystem path.
Automatically resolves any subsystem references (local or remote) relative
to the directory containing the file. `metaparameters` binds the ROOT
document's open metaparameters at the loader API (esm-spec §9.7.6 binding
site 4): already-closed edge bindings win, API bindings beat `default`s.

One of THREE load entry points, replacing the single `load` whose `String`
argument meant a FILE PATH here and in Go but JSON TEXT in TypeScript and
Rust — same name, same argument type, opposite meanings, and no type error
anywhere to catch it. See also [`load_string`](@ref) and
[`load_document`](@ref).
"""
function load_path(path::AbstractString;
                   metaparameters::AbstractDict{String,<:Integer}=Dict{String,Int}())::EsmFile
    base_path = dirname(abspath(String(path)))
    raw_data = _read_json_document(read(String(path), String))
    return _load_document(raw_data, base_path; metaparameters=metaparameters)
end

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
function load_document(doc::AbstractDict;
              base_path::Union{Nothing,AbstractString}=nothing,
              metaparameters::AbstractDict{String,<:Integer}=Dict{String,Int}())::EsmFile
    # Wire boundary for the in-memory path: normalize the caller's dict (which
    # may be symbol-keyed, or nest JSON3 values) into the one post-wire carrier.
    return _load_document(_to_ordered(doc), String(something(base_path, pwd()));
                          metaparameters=metaparameters,
                          record_import_base=base_path !== nothing)
end

"""
    _load_document(raw_data, base_path; metaparameters) -> EsmFile

The document pipeline shared by every `load_*` entry point: top-level `{ref}` inlining
→ `_load_parsed` (version gates, schema validation, template lowering,
coercion) → nested subsystem-ref resolution. `raw_data` is the post-wire
native document (`_read_json_document` / the normalized in-memory dict).

Factored out so a file and the identical document held as a dict cannot drift
apart — the only difference between them is which `base_path` anchors the refs.
"""
function _load_document(raw_data, base_path::String;
                        metaparameters::AbstractDict{String,<:Integer}=Dict{String,Int}(),
                        injected_imports::AbstractVector=Any[],
                        native_subsystem_refs::Bool=true,
                        record_import_base::Bool=true)::EsmFile
    # esm-spec §9.7.6 site 4, widened past "the root document's" (§4.7): the
    # metaparameter names every document this one MOUNTS declares. Computed on
    # the AUTHORED tree — the inliner just below CONSUMES the top-level mount
    # stubs, so after it runs there is nothing left to walk.
    #
    # Guarded: the widening has exactly two consumers — the site-4 check and the
    # §8.9.4 `extent` check — and neither can matter unless this load carries
    # loader-API bindings or the document declares an `extent`. A document with
    # neither pays no ref reads at all, so the ordinary path is unchanged in
    # behaviour AND in I/O (no remote `{ref}` fetched once here and again by the
    # ref resolver).
    mount_declared = (!isempty(metaparameters) || _document_declares_an_extent(raw_data)) ?
        _collect_mount_declared_metaparameters(raw_data, base_path) : Set{String}()
    # esm-spec §8.9.4, statically: a `data_sources.<k>.extent` naming a
    # metaparameter neither this document nor any document it mounts declares is
    # `template_import_unknown_name` AT LOAD, so `validate` refuses it — rather
    # than once the source is finally SAMPLED at build, which reported a typo as
    # a loader-API failure on a document that had validated clean.
    #
    # HERE, on the AUTHORED tree, and not further down in `_load_parsed`: the
    # inliners just below CONSUME the top-level mount stubs and fold the leaf's
    # axes, so by then the document is in the resolved shape the check exempts
    # (see `_document_is_in_resolved_shape`) and nothing would be checked at all.
    # Rust runs it at the same point, ahead of ref resolution, for the same
    # reason.
    check_data_source_extents(raw_data, String(base_path), mount_declared)
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
    # The loader-API metaparameters (esm-spec §9.7.6 binding site 4) are threaded
    # into the model-ref inliner because it now runs the §4.7 edge pipeline: they
    # backfill each mounted leaf's own close for the names the LEAF declares, and
    # (overlaid on this document's declared defaults) they are the scope an edge
    # `bindings` EXPRESSION folds against.
    # The top-level form's §4.7 contributions are STAGED, not merged: the leaf's
    # content is spliced in HERE (the root's own §9.7 machinery must lower
    # through it), but its `index_sets` do not join the registry until the root
    # has CLOSED — §9.7.6 site 3, "subsystem refs resolve post-close". Merged
    # just below, at the same point the `subsystems.<k>` form merges, which is
    # what stops the two mount forms from answering the same document
    # differently (§4.7 "Two mount forms, one mechanism").
    staged_isets = OrderedDict{String,Any}()
    staged_refs = Dict{String,String}()   # which mount contributed each staged axis
    model_envs = Dict{String,Dict{String,Int}}()
    inlined_m = _inline_toplevel_model_refs(raw_data, base_path;
                                            metaparameters=metaparameters,
                                            staged=staged_isets,
                                            staged_refs=staged_refs,
                                            model_envs=model_envs)
    rs_src = inlined_m === nothing ? raw_data : inlined_m
    inlined_r = _inline_toplevel_reaction_system_refs(rs_src, base_path)
    inlined = inlined_r !== nothing ? inlined_r : inlined_m
    # One carrier end to end: the inliners emit the same normalized native
    # tree the parse boundary produces, so there is no re-serialize
    # type-launder between them and the typed pipeline.
    doc = inlined === nothing ? raw_data : inlined
    # esm-spec §4.7: the root's own `subsystems.<k>` mounts inline HERE, BEFORE
    # `_load_parsed` runs this document's §9.7 machinery and §9.6.3 fixpoint — a
    # `{ref}` resolves "before validation or any other processing", and a rule
    # this document's own component declares only reaches a rewrite-target inside
    # a component it mounts if the content is spliced in first (issue #311). The
    # typed walk at the end of this function ran after the fixpoint, too late.
    #
    # Below the §8.9.4 line, which is where it must be: `mount_declared` and the
    # static `extent` check above were read off the authored tree. Only CONTENT
    # moves; the contributions are STAGED with the top-level form's and merged
    # after the close, just below `_load_parsed`.
    # `native_subsystem_refs=false` skips this pass so the typed walk below does
    # all of it — only `native_typed_agreement_test.jl` asks for that.
    if native_subsystem_refs && _document_has_subsystem_refs(doc)
        doc = _to_ordered(doc)
        _inline_subsystem_refs!(doc, base_path, Set{String}();
                                parent_meta=_root_metaparameter_env(raw_data, metaparameters),
                                api_meta=metaparameters, staged=staged_isets,
                                staged_refs=staged_refs)
    end
    # esm-spec §8.2.1: resolve every `data_sources[*].source` location against
    # this document's own directory, before the typed pipeline sees the field,
    # so the typed `DataSourceLocation`, the EarthSciIO provider extension
    # (which re-serializes the loaded file) and `emit` all see one resolved form
    # and none of them needs a base directory. Idempotent (the output is
    # scheme-led), so parse -> emit -> parse is stable. Returns `nothing` when
    # there was nothing to resolve, which is the overwhelmingly common case.
    resolved_ds = _resolve_data_source_urls(doc, base_path)
    doc = resolved_ds === nothing ? doc : resolved_ds
    file = _load_parsed(doc; base_path=base_path, metaparameters=metaparameters,
                        injected_imports=injected_imports,
                        mount_declared=mount_declared)
    # Resolve nested subsystem references relative to the document's directory.
    # The loader-API bindings reach this mount form too (§4.7 "Two mount forms,
    # one mechanism"): a leaf mounted at a `subsystems.<k>` edge gets the same
    # site-4 backfill a top-level-mounted leaf gets, so a discovered `extent`
    # (§8.9.4) sizes its axis at either attachment point.
    # The ROOT's closed metaparameter environment travels with the walk: each
    # §4.7 contribution folds against it as it merges (esm-spec §4.7).
    root_env = _root_metaparameter_env(raw_data, metaparameters)
    # esm-spec §4.7 "Index-set merge", the deferred half for the top-level mount
    # form: the root has now closed and folded its own `index_sets`, so each
    # staged contribution folds against that same closed environment and then
    # merges deep-equal-or-`subsystem_index_set_conflict`.
    _merge_staged_index_sets!(file.index_sets, staged_isets, root_env; refs=staged_refs)
    resolve_subsystem_refs!(file, base_path; loader_metaparameters=metaparameters,
                            root_env=root_env, model_envs=model_envs)
    # esm-spec §10.10 / §4.7: relative `coupling_import` refs resolve against this
    # document's directory, which `flatten` would otherwise never learn. Only a
    # base the caller really gave is recorded (`load_path` always has one); a
    # document with no location of its own leaves `flatten`'s `base_path` in
    # charge, as it does in the other four bindings.
    record_import_base && _record_coupling_import_base!(file, base_path)
    return file
end

"""
    _merge_staged_index_sets!(registry, staged, env) -> registry

Merge the §4.7 contributions a deferred top-level mount STAGED into the mounting
document's typed registry (esm-spec §4.7 "Index-set merge").

The other half of the inline/merge split: `_inline_toplevel_model_refs!` spliced
the referenced content in early, so the root's own §9.7 machinery lowers through
it, and held the `index_sets` back until the root had closed. This is where they
arrive — folded against the closed environment first, then compared against a
registry whose own sizes the close has already folded, so two IDENTICAL
declarations agree instead of colliding (issue #198).
"""
function _merge_staged_index_sets!(registry::AbstractDict{String,IndexSet},
                                   staged::AbstractDict{String,Any},
                                   env::AbstractDict{String,<:Integer};
                                   refs::AbstractDict{String,String}=Dict{String,String}())
    isempty(staged) && return registry
    for (n, raw) in pairs(staged)
        decl = coerce_index_set(fold_mount_contribution(raw, env))
        if haskey(registry, n)
            # Named by the mount that contributed it, in the typed walk's words:
            # this merge now receives BOTH mount forms' contributions, so the
            # form cannot be assumed.
            _index_set_deep_equal(registry[n], decl) ||
                throw(ExpressionTemplateError(ERROR_CODES.SUBSYSTEM_INDEX_SET_CONFLICT,
                    _subsystem_index_set_conflict_message(n, get(refs, String(n), "a §4.7 mount"),
                                                          _index_set_show(decl),
                                                          _index_set_show(registry[n]))))
        else
            registry[n] = decl
        end
    end
    return registry
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
(Before that was shared, a stream-loaded document kept its subsystem refs as
unresolved `SubsystemRef`s, which `flatten` silently SKIPS: the same document
loaded from a stream flattened to a strictly smaller system, with no error.)
`base_path` anchors relative `expression_template_imports` refs and nested
`{ref}`s (esm-spec §9.7.2, §4.7), defaulting to `pwd()` for that; left at
`nothing` the document has no location of its own, so a relative
`coupling_import` ref resolves against `flatten`'s own `base_path` instead
(§10.10 -> §4.7). `metaparameters` binds the document's open metaparameters at
the loader API (esm-spec §9.7.6).
"""
function load_string(json::AbstractString; base_path::Union{Nothing,AbstractString}=nothing,
                     metaparameters::AbstractDict{String,<:Integer}=Dict{String,Int}(),
                     injected_imports::AbstractVector=Any[])::EsmFile
    raw_data = _read_json_document(json)
    return _load_document(raw_data, String(something(base_path, pwd()));
                          metaparameters=metaparameters,
                          injected_imports=injected_imports,
                          record_import_base=base_path !== nothing)
end

function load_string(io::IO; base_path::Union{Nothing,AbstractString}=nothing,
                     metaparameters::AbstractDict{String,<:Integer}=Dict{String,Int}(),
                     injected_imports::AbstractVector=Any[])::EsmFile
    return load_string(read(io, String); base_path=base_path,
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
    doc = _to_ordered(parsed)
    # Expression-node `op` spellings are settled HERE, at the one wire boundary,
    # so every document gets identical treatment — root, `{ref}`-loaded child,
    # template library, coupling library (docs/content/rfcs/faq-node-rename.md
    # §5.2). Doing it per-caller is what let `arrayop` survive its own 0.8.0
    # removal, and what let the `aggregate` alias reach `emit` through a `{ref}`.
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
    _load_parsed(raw_data; base_path, metaparameters, injected_imports) -> EsmFile

Shared typed-load pipeline over an already-JSON-parsed document: version
gates → schema validation → raw structural checks → §9.7 machinery →
template lowering → typed coercion. Reached by every public `load_*` entry
point through `_load_document`, which wraps it with the top-level `{ref}`
inlining and nested subsystem-ref resolution that make a loaded document
complete; `_load_local_ref` calls it directly because it drives the nested
walk itself with a shared cycle-detection set.
"""
function _load_parsed(raw_data; base_path::AbstractString=pwd(),
                      metaparameters::AbstractDict{String,<:Integer}=Dict{String,Int}(),
                      injected_imports::AbstractVector=Any[],
                      index_set_rename=nothing,
                      rename_where::AbstractString="mount edge",
                      mount_declared::Union{Nothing,AbstractSet{String}}=nothing,
                      mounted_leaf::Bool=false,
                      enclosing_env::AbstractDict{String,<:Integer}=Dict{String,Int}())::EsmFile
    # `load_document` hands us an in-memory dict that never passed through
    # `_read_json_document`, so the wire-boundary op pass runs here too. It is
    # idempotent: a document that already came through the reader carries no
    # alias, so this is a silent no-op rather than a second warning.
    #
    # `gate=false`: top-level `{ref}` inlining has already run by this point, so
    # this document is no longer the AUTHORED one. A legal 1.0.0 parent that
    # mounts a `faq`-using child now CONTAINS `faq` without ever having spelled
    # it, and gating it here would reject a document nobody authored wrongly.
    # The floor is raised instead, exactly as `emit` does (§5.5).
    _prepare_document_ops!(raw_data; gate=false)

    # v0.4.0 expression_templates / apply_expression_template are
    # rejected when the file declares esm < 0.4.0 (RFC §5.4 spec-version
    # gate). Surfaced before schema validation so the user sees the
    # version hint instead of a generic "extra property" error.
    reject_expression_templates_pre_v04(raw_data)

    # v0.8.0 §9.7 constructs (expression_template_imports, top-level
    # expression_templates, metaparameters) are rejected when the file
    # declares esm < 0.8.0 (esm-spec §9.6.5).
    reject_template_imports_pre_v08(raw_data)
    # Top-level `expression_templates` beside a component payload is a
    # template-library payload no component can see (esm-spec §9.7.1).
    _reject_impure_template_library(raw_data)
    # The top-level `solver` block arrives at esm 1.1.0 (esm-spec §2.2.4).
    reject_solver_pre_v11(raw_data)
    # Declared `units` on a `const` node arrive at esm 1.2.0 (esm-spec §4.8.5).
    reject_const_units_pre_v12(raw_data)

    # Validate schema
    schema_errors = validate_schema(raw_data)
    if !isempty(schema_errors)
        throw(SchemaValidationError(_format_schema_errors(schema_errors), schema_errors))
    end

    # v0.8.0 §11.4.1: reject an `ic`-op equation placed inside a reaction
    # system's `constraint_equations`. A raw JSON structural check run HERE,
    # ahead of coercion, so the rejection carries a document path rather than
    # surfacing from inside the typed tree (schema has already passed — the
    # file is schema-valid, `constraint_equations` is an array of Equation and
    # `ic` is a legal op, so nothing in JSON Schema forbids it). Diagnostic
    # code: `ic_in_reaction_system`.
    _reject_ic_in_reaction_system(raw_data)

    # Emit E_DEPRECATED_DOMAIN_BC for any v0.1.0-style domain-level
    # boundary_conditions (v0.2.0 transitional shim per RFC §10.1 +
    # gt-2fvs mayor decision). A follow-up bead flips this to a hard error.
    _warn_deprecated_domain_bc(raw_data)

    return _lower_and_coerce(raw_data, base_path;
                             metaparameters=metaparameters,
                             injected_imports=injected_imports,
                             index_set_rename=index_set_rename,
                             rename_where=rename_where,
                             mount_declared=mount_declared,
                             mounted_leaf=mounted_leaf,
                             enclosing_env=enclosing_env)
end

"""
    _lower_and_coerce(raw_data, base_path; metaparameters, injected_imports) -> EsmFile

Shared injection → template-machinery → lowering → wrap → coercion tail of the
load pipeline, used by `_load_parsed` and `_load_remote_ref`.

Resolves esm-spec §9.7 machinery first — template-library imports
(depth-first post-order, per-edge metaparameter instantiation), index_sets
merge, metaparameter close+fold — then expands `apply_expression_template`
ops / fires `match` rules to the §9.6.3 fixpoint. After both passes the typed
tree carries no apply_expression_template nodes, no per-component
`expression_templates` blocks and no imports — downstream consumers see only
normal Expression ASTs (Option A round-trip). The top-level
`expression_templates` / `metaparameters` DECLARATIONS are NOT consumed: Option A
expands call sites, it does not delete declarations (esm-spec §9.6.4 rule 5), so
they survive on the resolved tree and are additionally snapshotted below for the
`EsmFile`.

esm-spec §9.7.10 forms A/B: any scope-directed injection — a subsystem-ref
edge's `injected_imports` (form A) or a coupling entry's injection map
(form B) — is folded into the target components' own
`expression_template_imports` BEFORE resolution, so the ordinary import
resolver + §9.6.3 fixpoint lower the target under the assembler-chosen
discretization.
"""
function _lower_and_coerce(raw_data, base_path::AbstractString;
                           metaparameters::AbstractDict{String,<:Integer}=Dict{String,Int}(),
                           injected_imports::AbstractVector=Any[],
                           index_set_rename=nothing,
                           rename_where::AbstractString="mount edge",
                           mount_declared::Union{Nothing,AbstractSet{String}}=nothing,
                           mounted_leaf::Bool=false,
                           enclosing_env::AbstractDict{String,<:Integer}=Dict{String,Int}())::EsmFile
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
                                          metaparameters=metaparameters,
                                          mount_declared=mount_declared,
                                          mounted_leaf=mounted_leaf)
    lowered_src = resolved === nothing ? machinery_input : resolved
    # esm-spec §4.7 "Index-set merge", the fold half. The leaf has now closed
    # everything IT can bind; a `size` still symbolic names something only the
    # MOUNTING document declares, and §9.7.6 site 5 closes it there. Fold it
    # against the enclosing environment now, on the native tree — `IndexSet.size`
    # is `Union{Int,Nothing}`, so a symbolic size cannot survive the coercion
    # below, and this is what lets an assembler-scoped axis cross a mount at all.
    if mounted_leaf && !isempty(enclosing_env)
        isets = _raw_get(lowered_src, "index_sets")
        if isets !== nothing && _is_object(isets)
            lowered_src = _to_ordered(lowered_src)
            _fold_mount_contributions!(_raw_get(lowered_src, "index_sets"), enclosing_env)
        end
    end
    loaded = lower_expression_templates(lowered_src)
    # esm-spec §4.7 "Mount-edge index-set renaming", pipeline step 2. The
    # referenced document has now resolved in its OWN scope — its imports, this
    # edge's `bindings` and injection, its metaparameter close and fold, the
    # §9.6.3 fixpoint — so its `index_sets` are the post-resolution vocabulary
    # the edge's `index_set_rename` speaks. Applied here, BEFORE the per-component
    # registries are materialized and stripped, so a mounted rule instance's
    # `wrt` / `where` `shape` follow the axis. Before the leaf's own nested mounts
    # resolve, too: each nested edge renames what IT contributes, at its own edge.
    # `nothing` / empty ⇒ identity, so an edge that does not use the field
    # resolves exactly as before.
    machinery_ran = loaded !== lowered_src
    if index_set_rename !== nothing
        loaded = apply_mount_index_set_rename(loaded, index_set_rename, rename_where)
    end
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
    if machinery_ran
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
                comp_tpls = OrderedDict{String,Any}(k => v for (k, v) in blocks)
            end
            bump && (esm_stamp = _esm_stamp_floor(get(root, "esm", nothing)))
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
            data_sources=file.data_sources,
            coupling=file.coupling,
            domain=file.domain,
            enums=file.enums,
            function_tables=file.function_tables,
            index_sets=file.index_sets,
            expression_templates=templates,
            metaparameters=metaparams,
            component_templates=component_templates,
            coordinates=coordinates,
            # `coupling_roles` is read at the coercion boundary (no lowering
            # pass rewrites it), so carry the already-coerced value across
            # this rebuild rather than re-snapshotting it. `solver` (esm-spec
            # §2.2) is read at the same boundary for the same reason and is
            # carried the same way — dropping it here would delete the block on
            # every document that goes through template lowering.
            coupling_roles=file.coupling_roles,
            solver=file.solver)

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
# (`function_tables`, `data_sources`) are merged in from the component; `enums` stay
# file-local and are lowered at the edge (esm-spec §9.3).
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
            ERROR_CODES.SUBSYSTEM_REF_IS_TEMPLATE_LIBRARY,
            "Subsystem ref '$(ref)' targets a template-library file$(suffix); " *
            "libraries are imported via expression_template_imports (esm-spec §9.7.1)"))
    end
    if _is_coupling_library_doc(raw_doc)
        throw(ExpressionTemplateError(
            ERROR_CODES.SUBSYSTEM_REF_IS_COUPLING_LIBRARY,
            "Subsystem ref '$(ref)' targets a coupling-library file$(suffix); " *
            "libraries are imported via a coupling_import coupling entry (esm-spec §10.9)"))
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
`NTGT = NX*NY`), and that is ALL it is for. It is NOT the environment that
backfills a mounted leaf's own close — see
[`_inline_toplevel_model_refs!`](@ref). Mirrors the Rust
`root_metaparameter_env` and the Python `root_meta_env`.
"""
function _root_metaparameter_env(raw_data,
                                 api_meta::AbstractDict{String,<:Integer})::Dict{String,Int}
    env = Dict{String,Int}()
    decls = _get_field(raw_data, :metaparameters, nothing)
    if _is_json_object(decls)
        for (n, d) in pairs(decls)
            dv = _get_field(d, :default, nothing)
            (dv isa Integer && !(dv isa Bool)) || continue
            env[string(n)] = Int(dv)
        end
    end
    for (k, v) in api_meta
        env[string(k)] = Int(v)
    end
    return env
end

"""
    _native_index_set_show(decl) -> String

One-line rendering of a POST-WIRE `index_sets` declaration for the
`subsystem_index_set_conflict` diagnostic, which esm-spec §4.7 requires to name
"both contributors, both definitions, and the `index_set_rename` remedy". The
native-dict twin of [`_index_set_show`](@ref), which renders the typed
[`IndexSet`](@ref) the `subsystems.<k>` edge merges.
"""
function _native_index_set_show(decl)::String
    decl isa AbstractDict || return string(decl)
    parts = String[]
    for k in ("kind", "size", "members", "of", "offsets", "values", "from_faq")
        haskey(decl, k) && push!(parts, "$(k)=$(decl[k])")
    end
    return isempty(parts) ? string(decl) : join(parts, ", ")
end

"""
    _merge_native_index_sets!(native, comp, ref) -> native

Merge a mounted component file's top-level `index_sets` into the importing
document's registry at the NATIVE-dict layer (esm-spec §4.7 "Index-set merge").

The typed [`_merge_subsystem_index_sets!`](@ref) cannot serve here: a top-level
`models.<k>` `{ref}` mount is inlined by a raw pre-pass that runs BEFORE schema
validation and coercion, so both sides are still post-wire `OrderedDict` trees.
The RULE is the same one — deep-equal redeclaration is idempotent (`==` on the
post-wire carrier is structural and key-order-independent), an absent name is
added, and a non-deep-equal collision throws
[`ExpressionTemplateError`](@ref) with the stable code
`subsystem_index_set_conflict`. Merging here is what keeps the two model mount
forms consistent: an assembly that mounts a leaf through a top-level `ref`
inherits the leaf's axes exactly as one that mounts it as a subsystem does,
instead of having to redeclare them.

EVERY declaration merges, including an `interval` whose `size` is still a
metaparameter NAME. Before [`_inline_toplevel_model_refs!`](@ref) ran the §4.7
edge pipeline this merge held such a declaration back, and the assembly had to
redeclare the axis — the gap §4.7's "without redeclaring them" forbids.

A `size` is concrete here only when the leaf HAS §9.7 machinery: then the edge
closed and folded its `metaparameters` (esm-spec §9.7.6 site 3) before calling
this. A leaf with NO machinery has no close to run, so a `size` naming a
metaparameter the ASSEMBLER declares still arrives here SYMBOLIC and merges that
way, to be closed by the mounting document's own §9.7.6 pass. The comparison
below is `==` on the post-wire carrier — structural, with no symbolic handling —
so on that path the idempotence it enforces is SYNTACTIC: a mount that restates
the leaf's axis verbatim (`size: "n_rows"`) merges clean, and one that restates
it with the concrete number the name folds to (`size: 7`) is a
`subsystem_index_set_conflict`. Rust agrees on both, because it merges at the
same point in its pipeline — on the raw document, BEFORE the mounting document's
own close. Python merges AFTER its close, so it sees the mounting document's
declaration already folded (`size: 7`) and refuses the VERBATIM restatement too.
A three-way verdict split on that one document, recorded (not fixed) in
`ESM_COMPLIANCE_VALIDATION_MATRIX.md` BEHAV-04-D-003: deleting the restatement,
which is what the merge exists to make possible, loads in all three.
"""
function _merge_native_index_sets!(native::AbstractDict{String,Any}, comp, ref::String;
                                  staged::Union{Nothing,AbstractDict{String,Any}}=nothing,
                                  staged_refs::Union{Nothing,AbstractDict{String,String}}=nothing)
    loaded = get(comp, "index_sets", nothing)
    (loaded isa AbstractDict && !isempty(loaded)) || return native
    # Deferred at the ROOT: the contribution is STAGED, not merged, until the
    # mounting document has closed (esm-spec §9.7.6 site 3, "subsystem refs
    # resolve post-close"). `_load_document` folds and merges it afterwards.
    registry = staged === nothing ?
        get!(() -> OrderedDict{String,Any}(), native, "index_sets") : staged
    registry isa AbstractDict || return native
    for (n, decl) in loaded
        if haskey(registry, n)
            registry[n] == decl || throw(ExpressionTemplateError(
                ERROR_CODES.SUBSYSTEM_INDEX_SET_CONFLICT,
                "index set '$(n)' from subsystem ref '$(ref)' " *
                "($(_native_index_set_show(decl))) collides with a non-deep-equal " *
                "declaration already in the importing document's registry " *
                "($(_native_index_set_show(registry[n]))) — contributed by the " *
                "document's own `index_sets` or by an earlier mount. A referenced " *
                "subsystem file's top-level index_sets merge into the importing " *
                "document's registry; deep-equal redeclaration is idempotent, " *
                "a size/kind disagreement is a load-time error (esm-spec §4.7). " *
                "If the two are genuinely different axes that happen to share a " *
                "name, rename one at its mount edge with `index_set_rename` " *
                "(esm-spec §4.7 \"Mount-edge index-set renaming\"), e.g. " *
                "{\"ref\": \"$(ref)\", \"index_set_rename\": {\"$(n)\": \"$(n)_2\"}}."))
        else
            registry[n] = decl
            # Which mount contributed it, so the deferred merge can name it.
            staged_refs === nothing || (staged_refs[String(n)] = ref)
        end
    end
    return native
end

"""
    _inline_toplevel_model_refs(raw_data, base_path; metaparameters) -> Union{Nothing,Dict{String,Any}}

Return a native ESM dict with every top-level model `{ref}` stub replaced by the
referenced component's model (and its `index_sets` / `function_tables`
/ `data_sources` merged in), or `nothing` when `raw_data` has no such stub.
The stub path copies the document (`_to_ordered`, order-preserving) so the
in-place worker never mutates the caller's tree; the reaction-system inliner
composes on the same copy, and `load_document` resolves stubs exactly
as `load_path` does.

`metaparameters` are the loader-API bindings (esm-spec §9.7.6 binding site 4).
They are threaded to the worker in BOTH of the two shapes the edge pipeline
needs, which are not interchangeable: this document's full closed environment
(its declared `default`s overlaid with the API bindings) is the scope an edge
`bindings` EXPRESSION folds against, while the API bindings ALONE backfill a
mounted leaf's own close.

`visited` lets a caller that is ALREADY resolving refs — `_load_local_ref`, when
the file it mounted as a `subsystems.<k>` edge turns out to be an assembly —
share its path-scoped cycle set, so a mount cycle that crosses the two forms is
caught. Defaults to a fresh set for the document entry point.
"""
function _inline_toplevel_model_refs(raw_data, base_path::String;
        metaparameters::AbstractDict{String,<:Integer}=Dict{String,Int}(),
        visited::Set{String}=Set{String}(),
        staged::Union{Nothing,AbstractDict{String,Any}}=nothing,
        staged_refs::Union{Nothing,AbstractDict{String,String}}=nothing,
        model_envs::Union{Nothing,AbstractDict{String,Dict{String,Int}}}=nothing)
    models = _get_field(raw_data, :models, nothing)
    models === nothing && return nothing
    has_stub = any(values(models)) do m
        _is_json_object(m) && _has_field(m, :ref) && !_has_field(m, :variables)
    end
    has_stub || return nothing
    native = _to_ordered(raw_data)
    _inline_toplevel_model_refs!(native, base_path, visited;
                                 parent_meta=_root_metaparameter_env(raw_data, metaparameters),
                                 api_meta=metaparameters,
                                 staged=staged,
                                 staged_refs=staged_refs,
                                 model_envs=model_envs)
    return native
end

"""
    _resolve_mount_edge_core(entry, ref, refpath, base_path, visited;
                             mount_noun, parent_meta, api_meta) -> (comp, compdir)

The per-edge core of the esm-spec §4.7 edge pipeline, shared by BOTH mount forms:
read the referenced document, run its version gates and library rejections,
close its metaparameters with this edge's `bindings` (§9.7.6 site 3, with the
site-4 loader-API backfill for the names the leaf declares), apply this edge's
§9.7.10 form-A injection, resolve its §9.7 machinery and run the §9.6.3
fixpoint, and apply this edge's `index_set_rename`.

The caller owns the cycle-detection push/pop on `visited` and everything the
two mount forms do DIFFERENTLY once the leaf is resolved — a `models.<k>` edge
selects one model and merges the leaf's by-name blocks, a `subsystems.<k>`
edge requires exactly one component. Extracted so the `subsystems.<k>` form can
run this same code on the native dictionary instead of a second copy of it on
the typed tree (the duplication `_inline_toplevel_model_refs!`'s own docstring
refuses).
"""
# Lower `target`'s `enum` ops against the `enums` block of `document`, the file
# mounted at this §4.7 edge (esm-spec §9.3), naming the edge in the diagnostic.
function _lower_mounted_enums_at_edge(document, target, mount_noun::AbstractString)
    try
        return _lower_mounted_document_enums(document, target)
    catch e
        e isa EnumLoweringError || rethrow()
        throw(ExpressionTemplateError(e.code,
            "$(mount_noun): $(e.message) — an `enum` op in a mounted file resolves " *
            "against that file's own `enums` block (esm-spec §9.3)"))
    end
end

function _resolve_mount_edge_core(entry::AbstractDict, ref::String, refpath::String,
                                  base_path::String, visited::Set{String};
                                  mount_noun::String,
                                  parent_meta::AbstractDict{String,<:Integer}=Dict{String,Int}(),
                                  api_meta::AbstractDict{String,<:Integer}=Dict{String,Int}())
    isfile(refpath) || throw(SubsystemRefError(
        "Referenced model file not found: $(refpath) (from ref '$(ref)')"))
    comp = _read_json_document(read(refpath, String))
    comp isa AbstractDict{String,Any} || throw(SubsystemRefError(
        "Referenced model file '$(ref)' did not parse as a JSON object"))
    # esm-spec §4.7 "Edge pipeline" step (1): the referenced document
    # resolves in its OWN scope, exactly as the `subsystems.<k>` edge
    # resolves it in `_load_ref` — the two mount forms are one mechanism,
    # so a binding MUST NOT make them differ. The version gates first
    # (§5.4 / §9.6.5), then the library rejections: a §4.7 ref MUST NOT
    # target a template library or a coupling library. Same rejection as
    # `_load_local_ref` / `_load_remote_ref`.
    reject_expression_templates_pre_v04(comp)
    reject_template_imports_pre_v08(comp)
    _reject_library_ref(comp, ref, refpath)
    compdir = dirname(refpath)

    # §9.7.6 binding site 3: close the leaf's metaparameters. Explicit
    # edge `bindings` win, backfilled by the LOADER-API bindings (site 4)
    # for the names the leaf DECLARES — see this function's docstring for
    # why the backfill reads `api_meta` and never `parent_meta`.
    leaf_decls = let md = get(comp, "metaparameters", nothing)
        md isa AbstractDict ? Set(String[string(k) for k in keys(md)]) : Set{String}()
    end
    bindings = Dict{String,Int}()
    for (k, v) in api_meta
        string(k) in leaf_decls && (bindings[string(k)] = Int(v))
    end
    bindings_raw = get(entry, "bindings", nothing)
    if bindings_raw !== nothing
        bindings_raw isa AbstractDict || throw(ExpressionTemplateError(
            ERROR_CODES.METAPARAMETER_TYPE_ERROR,
            "$(mount_noun) `bindings` must be an object of metaparameter " *
            "expressions (esm-spec §9.7.6)"))
        for (bk, bv) in pairs(bindings_raw)
            bctx = "$(mount_noun), binding '$(string(bk))'"
            # Structural grammar check at the edge (bad op / empty args /
            # float — even with a symbolic arg), then fold against the
            # MOUNTING document's closed environment.
            expr = require_meta_expr(_to_native_json(bv), bctx)
            bindings[string(bk)] = Int(eval_meta_expr(expr, parent_meta, bctx))
        end
    end

    # esm-spec §8.9.4 "When the check is evaluated": COLLECT FIRST. The
    # mount-declared set is read off the leaf AS AUTHORED — its nested `{ref}`
    # edges still unresolved — because the nested walk just below consumes each
    # of those mounted leaves' `metaparameters` at its edge (§9.7.6 site 3),
    # after which the names a conforming `extent` reaches are gone. Guarded on
    # the edge's close being non-empty: with nothing to check the set is unused,
    # and the walk would re-read every nested ref for nothing.
    leaf_mount_declared = isempty(bindings) ? Set{String}() :
        _collect_mount_declared_metaparameters(comp, compdir)

    # esm-spec §4.7: a `{ref}` resolves "before validation or any other
    # processing", so the leaf's OWN nested mounts — BOTH forms — inline HERE,
    # ahead of this edge's §9.7.10 injection and the §9.6.3 fixpoint below.
    # §9.7.10 defines the injection as "as if the target had added those entries
    # to the END of its own `expression_template_imports`", and a component's own
    # imports lower a rewrite-target inside a component it mounts — so the
    # fixpoint must see the mounted content or the two halves of that sentence
    # disagree (issue #311). They ran after the rename before, which was too late.
    #
    # Only CONTENT moves. Their `index_sets` are STAGED, because THIS leaf has not
    # closed yet, and land after its close below — the same inline/merge split the
    # root makes. `leaf_env` is this leaf's CLOSED environment: its declared
    # defaults overlaid with this edge's `bindings`, which win (§9.7.6 site 3).
    leaf_env = _root_metaparameter_env(comp, bindings)
    # The fold environment for what those nested mounts contribute (esm-spec §4.7
    # "Which environment a contribution folds against"): the ENCLOSING environment
    # overlaid with this leaf's CLOSED one — its declared defaults, then the
    # bindings that close it — for the names the leaf DECLARES. The enclosing base
    # is what lets a name ONLY an outer scope declares still fold against that
    # outer scope; the declared-names filter is what stops an outer metaparameter
    # the leaf never declared from sizing an axis the leaf owns. Kept apart from
    # `leaf_env`, which nested edge binding EXPRESSIONS fold against and which
    # must stay the leaf's own.
    leaf_decls = let md = get(comp, "metaparameters", nothing)
        md isa AbstractDict ? Set(String[string(k) for k in keys(md)]) : Set{String}()
    end
    leaf_fold_env = Dict{String,Int}(String(k) => Int(v) for (k, v) in parent_meta)
    for (k, v) in leaf_env
        k in leaf_decls && (leaf_fold_env[k] = v)
    end
    leaf_staged = OrderedDict{String,Any}()
    _inline_toplevel_model_refs!(comp, compdir, visited;
                                 parent_meta=leaf_env, api_meta=api_meta, staged=leaf_staged)
    _inline_subsystem_refs!(comp, compdir, visited;
                            parent_meta=leaf_env, api_meta=api_meta, staged=leaf_staged)

    # §9.7.10 form A: the edge's `expression_template_imports` inject a
    # discretization into the LEAF's own scope BEFORE resolution, so the
    # §9.6.3 fixpoint lowers its rewrite-targets at the mount and an
    # assembler chooses the scheme for a discretization-agnostic PDE leaf
    # without editing the leaf. Their own relative refs are authored by
    # the assembler carrying the edge, so they absolutize against THIS
    # document's directory, not the leaf's.
    edge_imports = get(entry, "expression_template_imports", nothing)
    injected = Any[]
    if edge_imports isa AbstractVector && !isempty(edge_imports)
        imports_native = _to_ordered(edge_imports)
        _absolutize_nested_refs!(imports_native, base_path)
        injected = Any[e for e in imports_native]
    end
    injected_root = apply_scope_injections(comp, injected)
    injected_root === nothing || (comp = injected_root)

    # Resolve the leaf's §9.7 machinery under that close, then run the
    # §9.6.3 rewrite fixpoint, so the spliced component carries the
    # fully-expanded Option-A image and the assembling document's
    # lowering never resolves the leaf's template names against its own
    # registry. A leaf with no machinery has nothing to resolve
    # (`resolve_template_machinery` returns `nothing`), but its component-local
    # templates still expand here: its own calls bind their parameters, so an
    # `enum` op a parameter spells resolves against the leaf's block below, not
    # the mounting document's (esm-spec §9.3).
    # `mounted_leaf=true`: this IS a §4.7 mount edge, so an index-set
    # `size` the leaf cannot close stays SYMBOLIC — it merges into the
    # mounting document's registry and closes there (§9.7.6 site 5).
    # Whether that happened used to turn on `_has_import_machinery`, a
    # whole-document boolean, so one `expression_template_imports` entry
    # for a library the leaf never calls flipped the leaf from "axis
    # merges and the assembler closes it" to `metaparameter_unbound`.
    # `mount_declared` covers the leaf's OWN nested mounts, so the
    # site-4 widening composes down the reference DAG; it was collected above,
    # before the nested walk, for the reason given there.
    resolved = resolve_template_machinery(comp, compdir; metaparameters=bindings,
                                          mount_declared=leaf_mount_declared,
                                          mounted_leaf=true)
    comp = expand_document(lower_expression_templates(resolved === nothing ? comp : resolved))

    # esm-spec §9.3: the leaf's `enum` ops resolve against ITS OWN `enums` block,
    # here, while that block is still at hand. The mounting document's block is a
    # different one and `enums` do not merge across a mount, so an importer
    # declaring an enum of the same name cannot change what the leaf computes.
    # The leaf's own nested mounts were lowered at their own edges above.
    comp = _lower_mounted_enums_at_edge(comp, comp, mount_noun)

    # The leaf has now CLOSED, so what its own nested mounts staged can land:
    # each contribution folded against the leaf's closed environment — esm-spec
    # §4.7 "Which environment it folds against": a merge folds against the
    # environment of whatever registry it lands in — then merged by the §4.7
    # deep-equal-or-`subsystem_index_set_conflict` rule. A contribution
    # deep-equal to an axis the leaf declares itself adds no key, which is what
    # keeps that axis renameable just below.
    comp isa AbstractDict{String,Any} || (comp = _to_ordered(comp))
    before_nested = let is = get(comp, "index_sets", nothing)
        is isa AbstractDict ? Set{String}(String(k) for k in keys(is)) : Set{String}()
    end
    if !isempty(leaf_staged)
        folded = OrderedDict{String,Any}(String(n) => fold_mount_contribution(d, leaf_fold_env)
                                         for (n, d) in leaf_staged)
        _merge_native_index_sets!(comp, OrderedDict{String,Any}("index_sets" => folded), ref)
    end
    nested_contributed = let is = get(comp, "index_sets", nothing)
        is isa AbstractDict ?
            setdiff(Set{String}(String(k) for k in keys(is)), before_nested) : Set{String}()
    end

    # Step (2): `index_set_rename` speaks the resolved leaf's own
    # post-resolution vocabulary, so it applies HERE — after the close and fold
    # above. Its VOCABULARY is what this document declares and imports, so the
    # names only its nested mounts contributed are held out (§4.7 "Renaming is
    # per edge"); its REACH is the whole resolved leaf, so an axis the leaf
    # declares itself is renamed through the nested content too.
    rename_raw = get(entry, "index_set_rename", nothing)
    if rename_raw !== nothing
        comp = apply_mount_index_set_rename(comp, rename_raw, mount_noun;
                                            nested_contributed=nested_contributed)
    end
    return comp, compdir, leaf_fold_env
end

"""
    _document_has_subsystem_refs(doc) -> Bool

Whether any `models.<M>` in `doc` mounts a LOCAL `subsystems.<S>` `{ref}` at any
depth. The early §4.7 subsystem pass in `_load_document` copies the document, so
it is skipped outright for the common document that mounts nothing.
"""
function _document_has_subsystem_refs(doc)::Bool
    models = _get_field(doc, :models, nothing)
    _is_json_object(models) || return false
    has(m) = begin
        subs = _get_field(m, :subsystems, nothing)
        _is_json_object(subs) || return false
        for (_, sub) in pairs(subs)
            _is_json_object(sub) || continue
            r = _get_field(sub, :ref, nothing)
            r isa AbstractString && return true
            has(sub) && return true
        end
        false
    end
    for (_, m) in pairs(models)
        _is_json_object(m) && has(m) && return true
    end
    return false
end

"""
    _inline_subsystem_refs!(native, base_path, visited; parent_meta, api_meta, staged) -> native

The esm-spec §4.7 `subsystems.<k>` mount form on the NATIVE dictionary: every
`models.<M>.subsystems.<S>` `{ref}` in `native` is resolved through the SAME
per-edge core the top-level `models.<k>` form uses
([`_resolve_mount_edge_core`](@ref)) and its single model is spliced in place,
recursing through inline subsystems.

This is what lets a `{ref}` be inlined BEFORE `_load_parsed` runs the document's
own §9.7 machinery and §9.6.3 fixpoint — §4.7 resolves a ref "before validation
or any other processing", and a rewrite-target inside a mounted component only
lowers if the content is there when the fixpoint runs (issue #311). The typed
walk (`_resolve_refs_in_file!`) ran after `_load_parsed`, which is too late.

Only the CONTENT moves early. Each mount's `index_sets` go to `staged` when it
is given — the ROOT, which has not closed yet — and merge after the close
(`_merge_staged_index_sets!`); otherwise into `native`'s own registry.

Remote (`http(s)://`) refs are left in place for the typed resolver, exactly as
[`_inline_toplevel_model_refs!`](@ref) leaves them: it reads targets with
`isfile`.

Diagnostics match the typed walk byte for byte, because the shared corpus pins
them for all five bindings (`tests/invalid/expected_errors.json`): the same
codes, the same messages, and the same mount site stamped by `_with_mount_site`
so `load_failure_structural_error` renders `/models/<parent>/subsystems/<sub>`.
"""
# One of TWO paths for the §4.7 `subsystems.<k>` form: this native pass serves
# LOADING; `_resolve_refs_in_file!` (the typed walk) serves remote refs and direct
# callers of `resolve_subsystem_refs!`. `test/native_typed_agreement_test.jl` runs
# both over the local-ref corpus and fails if they disagree.
function _inline_subsystem_refs!(native::AbstractDict{String,Any}, base_path::String,
                                 visited::Set{String};
                                 parent_meta::AbstractDict{String,<:Integer}=Dict{String,Int}(),
                                 api_meta::AbstractDict{String,<:Integer}=Dict{String,Int}(),
                                 staged::Union{Nothing,AbstractDict{String,Any}}=nothing,
                                 staged_refs::Union{Nothing,AbstractDict{String,String}}=nothing)
    models = get(native, "models", nothing)
    models isa AbstractDict || return native
    for (mname, model) in collect(models)
        model isa AbstractDict || continue
        _inline_model_subsystems!(native, model, String(mname), base_path, visited;
                                  parent_meta=parent_meta, api_meta=api_meta, staged=staged,
                                  staged_refs=staged_refs)
    end
    return native
end

function _inline_model_subsystems!(native::AbstractDict{String,Any}, model::AbstractDict,
                                   parent_name::String, base_path::String, visited::Set{String};
                                   parent_meta, api_meta, staged, staged_refs=nothing)
    subs = get(model, "subsystems", nothing)
    subs isa AbstractDict || return
    for (sub_key, sub) in collect(subs)
        sub isa AbstractDict || continue
        sub_name = String(sub_key)
        if haskey(sub, "ref") && sub["ref"] isa AbstractString
            ref = _expand_ref_env(String(sub["ref"]))   # esm-spec §4.7 ${VAR} expansion
            (_is_url(ref) || _is_url(base_path)) && continue   # typed resolver's
            try
                canonical = _canonical_ref(ref, base_path)
                canonical in visited &&
                    throw(SubsystemRefError("Circular subsystem reference detected: $(canonical)"))
                push!(visited, canonical)
                try
                    refpath = abspath(joinpath(base_path, ref))
                    isfile(refpath) || throw(SubsystemRefError(
                        "Subsystem reference '$(ref)' could not be resolved — file does not exist";
                        code=ERROR_CODES.UNRESOLVED_SUBSYSTEM_REF, ref=ref))
                    comp, compdir, _ = _resolve_mount_edge_core(sub, ref, refpath, base_path, visited;
                        mount_noun="subsystem ref '$(ref)'", parent_meta=parent_meta,
                        api_meta=api_meta)
                    cmodels = get(comp, "models", nothing)
                    (cmodels isa AbstractDict && length(cmodels) == 1) || throw(SubsystemRefError(
                        "Subsystem reference '$(ref)' resolves to a file containing multiple " *
                        "top-level systems; exactly one is required";
                        code=ERROR_CODES.AMBIGUOUS_SUBSYSTEM_REF, ref=ref))
                    cmodel = first(values(cmodels))
                    _absolutize_nested_refs!(cmodel, compdir)
                    subs[sub_key] = cmodel
                    _merge_native_index_sets!(native, comp, ref; staged=staged, staged_refs=staged_refs)
                finally
                    delete!(visited, canonical)
                end
            catch e
                # The typed `_load_ref` surfaces these two as-is and wraps anything
                # else; the mount site is stamped by the only frame that knows it.
                err = if e isa SubsystemRefError || e isa ExpressionTemplateError
                    e
                else
                    SubsystemRefError("Failed to resolve subsystem ref '$(ref)': $(e)")
                end
                err isa SubsystemRefError ? throw(_with_mount_site(err, sub_name, parent_name)) :
                                            throw(err)
            end
        else
            # An inline subsystem: recurse, with this subsystem as the parent — the
            # typed walk's `_resolve_model_refs!` names the mount site the same way.
            _inline_model_subsystems!(native, sub, sub_name, base_path, visited;
                                      parent_meta=parent_meta, api_meta=api_meta, staged=staged,
                                      staged_refs=staged_refs)
        end
    end
end

"""
    _inline_toplevel_model_refs!(native, base_path, visited; parent_meta, api_meta)

In-place native-dict worker for [`_inline_toplevel_model_refs`](@ref).

Each top-level `models.<k>` `{ref}` MOUNT EDGE runs the SAME normative edge
pipeline (esm-spec §4.7 "Edge pipeline") that [`_resolve_subsystem_ref`](@ref)
runs at a `subsystems.<k>` edge, because "Two mount forms, one mechanism"
forbids the two attachment points from differing:

1. the referenced document resolves in its OWN scope — the library gates, this
   edge's `bindings` and §9.7.10 form-A injection, its metaparameter close and
   fold, the §9.6.3 fixpoint;
2. this edge's `index_set_rename` applies to that resolved document;
3. the renamed `index_sets` merge into THIS document's registry under the
   deep-equal-or-`subsystem_index_set_conflict` rule, and the component splices
   in.

The leaf's own nested top-level model-refs then resolve in the leaf's directory,
sharing this walk's path-scoped cycle set, so the merge composes transitively.
On top of the shared pipeline this form additionally merges the leaf's
`function_tables` / `data_sources` up (parent wins on a key clash) and
drops the leaf's inline `tests` (esm-spec §6.6: they do not cross a mount edge).

`parent_meta` is the MOUNTING document's closed metaparameter environment (its
`default`s overlaid with the loader-API bindings, esm-spec §9.7.6 sites 5 and
4). Edge `bindings` expressions fold against it, and that is ALL it is for.
`api_meta` is the loader-API bindings ALONE (site 4), and only they — for the
names the LEAF declares — backfill the leaf's own close, so a leaf mounted with
no explicit edge `bindings` still resolves under the caller's grid instead of
falling back to its own defaults. Explicit edge `bindings` win; names the leaf
does not declare are never forwarded, so they cannot raise
`template_import_unknown_name` against the leaf.

The backfill deliberately does NOT read `parent_meta`: that additionally carries
the mounting document's OWN declared defaults, and forwarding those would let an
assembler's unrelated `NLEV` silently override the leaf's own default for a name
the edge never bound — a different answer from the one the SAME leaf gets at a
`subsystems.<k>` mount, which is exactly what §4.7 forbids. Mirrors the Python
`_load_ref_data` backfill and the Rust `inline_toplevel_model_refs`.
"""
function _inline_toplevel_model_refs!(native::AbstractDict{String,Any}, base_path::String,
                                      visited::Set{String};
        parent_meta::AbstractDict{String,<:Integer}=Dict{String,Int}(),
        api_meta::AbstractDict{String,<:Integer}=Dict{String,Int}(),
        staged::Union{Nothing,AbstractDict{String,Any}}=nothing,
        staged_refs::Union{Nothing,AbstractDict{String,String}}=nothing,
        model_envs::Union{Nothing,AbstractDict{String,Dict{String,Int}}}=nothing)
    models = get(native, "models", nothing)
    models isa AbstractDict || return
    for (name, entry) in collect(models)
        (entry isa AbstractDict && haskey(entry, "ref") &&
            !haskey(entry, "variables")) || continue
        ref = _expand_ref_env(String(entry["ref"]))  # esm-spec §4.7 ${VAR} expansion
        # `bindings` / `index_set_rename` diagnostics name the mount form they
        # were read at, so the two forms' messages stay distinguishable.
        mount_noun = "top-level model ref '$(ref)'"
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
            comp, compdir, leaf_child_env = _resolve_mount_edge_core(entry, ref, refpath, base_path, visited;
                mount_noun=mount_noun, parent_meta=parent_meta, api_meta=api_meta)

            # The leaf's own nested mounts — both forms — were inlined inside
            # `_resolve_mount_edge_core`, before its fixpoint (issue #311).
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
            # esm-spec §6.6: inline tests do NOT cross a mount edge. They are
            # assertions about the leaf under the leaf's OWN standalone
            # conditions, and the mounting document may couple it — replacing a
            # parameter, reshaping it, feeding it another component's state — so
            # re-running them here would check a claim the leaf's author never
            # made. They run when the leaf's own file is the test target, which a
            # directory-wide `run_tests` reaches anyway.
            cmodel isa AbstractDict && delete!(cmodel, "tests")
            # Any relative `{ref}` the resolution above did not consume anchors at
            # the LEAF's directory, not at the parent it is about to land in.
            _absolutize_nested_refs!(cmodel, compdir)
            models[name] = cmodel
            # The root walk resolves this spliced model's `subsystems.<k>` refs
            # later; they must fold in THIS leaf's scope, not the root's.
            model_envs === nothing || (model_envs[String(name)] = leaf_child_env)
            # esm-spec §4.7 "Index-set merge", pipeline step (3): the leaf's
            # document-scoped `index_sets` join THIS document's registry, exactly
            # as they do at a subsystem-ref edge (`_resolve_subsystem_ref`) — the
            # two mount forms are one mechanism at two attachment points, so an
            # assembly may shape its coupling over the leaf's axes without
            # redeclaring them. Merged AFTER the leaf's own resolution and nested
            # mounts above, so `comp`'s registry already carries whatever ITS own
            # mounts brought in and the merge composes transitively. Unlike the
            # by-name blocks below, the importer does NOT silently win a clash: a
            # non-deep-equal collision is the load-time error
            # `subsystem_index_set_conflict`.
            _merge_native_index_sets!(native, comp, ref; staged=staged, staged_refs=staged_refs)
            # Merge the by-name blocks the model's AST references; the parent wins
            # on a key clash (its own definitions take precedence). `enums` is not
            # one of them: it is file-local (esm-spec §9.3), and the leaf's `enum`
            # ops were already lowered against it at the edge.
            for blk in ("function_tables", "data_sources")
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
`function_tables` / `data_sources` merged in), or `nothing` when
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
`"reaction_system"` selector), and merges the `function_tables` / `data_sources`
blocks the reaction system's AST references (parent wins on a clash).
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
        # Same refusal as `_inline_toplevel_model_refs!`, for the same reason:
        # a top-level `{ref}` stub is spliced by a raw pre-pass with no resolved
        # mounted document to rename (esm-spec §4.7 "Where it applies").
        if haskey(entry, "index_set_rename") && entry["index_set_rename"] !== nothing
            throw(ExpressionTemplateError(
                ERROR_CODES.SUBSYSTEM_INDEX_SET_RENAME_UNSUPPORTED_MOUNT_FORM,
                "reaction_systems.$(name): `index_set_rename` is not supported at " *
                "this mount form. This binding inlines a top-level `{ref}` with a " *
                "raw pre-pass that defers the leaf's §9.7 resolution to the root " *
                "document, so the edge has no resolved mounted document to rename " *
                "and the leaf would merge under its ORIGINAL axis names. Mount the " *
                "component at a `subsystems.<k>` `{ref}` edge instead, where the " *
                "rename applies (esm-spec §4.7 \"Mount-edge index-set renaming\")"))
        end
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
            comp = _read_json_document(read(refpath, String))
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
            # esm-spec §6.6: inline tests do not cross a mount edge — the
            # reaction-system twin of the rule in `_inline_toplevel_model_refs!`.
            crsys isa AbstractDict && delete!(crsys, "tests")
            # esm-spec §9.3: the reaction system's `enum` ops resolve against its
            # OWN file's `enums` block, which does not merge into this document.
            # Its §9.7 resolution is deferred to the root, so a template body keeps
            # the ops its `params` spell for the call site.
            crsys = _lower_mounted_enums_at_edge(comp, crsys,
                                                 "top-level reaction system ref '$(ref)'")
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
            # Not `enums`: it is file-local (esm-spec §9.3), lowered above.
            for blk in ("function_tables", "data_sources")
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
    # also arrives here as a string-keyed native dict (`load_document`),
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
struct SubsystemRefError <: EarthSciASTError
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

    SubsystemRefError(message::AbstractString;
                      code::AbstractString=ERROR_CODES.UNRESOLVED_SUBSYSTEM_REF,
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
function resolve_subsystem_refs!(file::EsmFile, base_path::String;
        loader_metaparameters::AbstractDict{String,<:Integer}=Dict{String,Int}(),
        root_env::AbstractDict{String,<:Integer}=Dict{String,Int}(),
        model_envs::AbstractDict{String,<:AbstractDict{String,Int}}=Dict{String,Dict{String,Int}}())
    visited = Set{String}()
    _resolve_refs_in_file!(file, base_path, visited; api_meta=loader_metaparameters,
                           root_env=root_env, model_envs=model_envs)
end

"""
    _resolve_refs_in_file!(file::EsmFile, base_path::String, visited::Set{String})

Internal recursive resolver for subsystem references in an EsmFile.
"""
# One of TWO paths for the §4.7 `subsystems.<k>` form: this typed walk serves
# remote refs and direct callers of `resolve_subsystem_refs!`; `_inline_subsystem_refs!`
# (the native pass) serves LOADING. `test/native_typed_agreement_test.jl` runs both
# over the local-ref corpus and fails if they disagree.
function _resolve_refs_in_file!(file::EsmFile, base_path::String, visited::Set{String};
        api_meta::AbstractDict{String,<:Integer}=Dict{String,Int}(),
        root_env::AbstractDict{String,<:Integer}=Dict{String,Int}(),
        model_envs::AbstractDict{String,<:AbstractDict{String,Int}}=Dict{String,Dict{String,Int}}())
    # Resolve model subsystem refs. The document's own index-set registry is
    # threaded down the walk so every referenced subsystem file's top-level
    # `index_sets` merge into it (esm-spec §4.7, mirroring §9.7.5).
    if file.models !== nothing
        for (name, model) in file.models
            # A top-level-mounted leaf's own subsystem refs fold in THAT leaf's
            # closed scope (recorded by the inliner), not the root's (esm-spec §4.7).
            _resolve_model_refs!(file.models, name, model, base_path, visited,
                                 file.index_sets; api_meta=api_meta,
                                 root_env=get(model_envs, String(name), root_env))
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
                              registry::AbstractDict{String,IndexSet};
                              api_meta::AbstractDict{String,<:Integer}=Dict{String,Int}(),
                              root_env::AbstractDict{String,<:Integer}=Dict{String,Int}())
    # Only Model values carry subsystems to walk; a SubsystemRef leaf has none.
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
                _resolve_subsystem_ref(sub_value, base_path, visited, registry;
                                       api_meta=api_meta, root_env=root_env)
            catch e
                e isa SubsystemRefError || rethrow()
                throw(_with_mount_site(e, sub_name, name))
            end
        else
            # Inline Model — recurse into its own subsystems.
            _resolve_model_refs!(model.subsystems, sub_name, sub_value, base_path,
                                 visited, registry; api_meta=api_meta, root_env=root_env)
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
# The `subsystem_index_set_conflict` message for a mounted document's axis `n`,
# contributed by the mount of `ref`, colliding with a non-deep-equal declaration
# already in the importing document's registry. ONE builder for every merge site —
# the typed walk (`_merge_subsystem_index_sets!`) and the native pass's deferred
# merge (`_merge_staged_index_sets!`) — so the two report the same failure in the
# same words; `native_typed_agreement_test.jl` compares them.
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
function _merge_subsystem_index_sets!(registry::AbstractDict{String,IndexSet},
                                      loaded::EsmFile, ref::String)
    for (n, decl) in loaded.index_sets
        if haskey(registry, n)
            _index_set_deep_equal(registry[n], decl) ||
                throw(ExpressionTemplateError(ERROR_CODES.SUBSYSTEM_INDEX_SET_CONFLICT,
                    _subsystem_index_set_conflict_message(n, ref, _index_set_show(decl),
                                                          _index_set_show(registry[n]))))
        else
            registry[n] = decl
        end
    end
    return registry
end

"""
    _resolve_subsystem_ref(ref, base_path, visited, registry) -> Model

Load the ESM file at `ref` and return its single top-level model (esm-spec
§4.7). Errors unless the file contains exactly one model. From esm 1.0.0 a data
source is an ingest registry entry rather than a component, so a file whose only
top-level entry is a `data_sources` block resolves to nothing mountable.
A `SubsystemRef`'s `bindings` close the referenced document's open
metaparameters (esm-spec §9.7.6 binding site 3); a `ref` targeting a
template-library file is rejected with `subsystem_ref_is_template_library`.
The referenced file's top-level `index_sets` merge into `registry` — the
importing document's registry — with the §4.7 deep-equal-or-error rule
(`subsystem_index_set_conflict`).
"""
function _resolve_subsystem_ref(ref::SubsystemRef, base_path::String, visited::Set{String},
                                registry::AbstractDict{String,IndexSet};
                                api_meta::AbstractDict{String,<:Integer}=Dict{String,Int}(),
                                root_env::AbstractDict{String,<:Integer}=Dict{String,Int}())
    # esm-spec §9.7.10 form A: the edge's `expression_template_imports` inject a
    # discretization into the referenced component's own scope, threaded into
    # its load so the §9.6.3 fixpoint lowers its rewrite-targets at the mount.
    loaded = _load_ref(ref.ref, base_path, visited;
                       metaparameters=ref.bindings,
                       api_meta=api_meta,
                       enclosing_env=root_env,
                       injected_imports=ref.expression_template_imports,
                       index_set_rename=ref.index_set_rename,
                       rename_where="subsystem ref '$(ref.ref)'")
    n_models = loaded.models === nothing ? 0 : length(loaded.models)
    if n_models != 1
        throw(SubsystemRefError(
            "Subsystem reference '$(ref.ref)' resolves to a file containing multiple " *
            "top-level systems; exactly one is required";
            code=ERROR_CODES.AMBIGUOUS_SUBSYSTEM_REF, ref=ref.ref))
    end
    # esm-spec §4.7: the mounted file's document-scoped index sets (already
    # metaparameter-folded, incl. any brought in by ITS own subsystem refs)
    # join the importing document's registry, so the importer's variables may
    # be shaped over the mesh file's axes and a disagreement fails loudly.
    _merge_subsystem_index_sets!(registry, loaded, ref.ref)
    return first(values(loaded.models))
end

_resolve_subsystem_ref(ref::String, base_path::String, visited::Set{String},
                       registry::AbstractDict{String,IndexSet}=OrderedDict{String,IndexSet}();
                       api_meta::AbstractDict{String,<:Integer}=Dict{String,Int}()) =
    _resolve_subsystem_ref(SubsystemRef(ref), base_path, visited, registry; api_meta=api_meta)

"""
    _resolve_reaction_system_refs!(rsys_dict, name, rsys, base_path, visited)

Recursively resolve subsystem references within a ReactionSystem's subsystems.
"""
function _resolve_reaction_system_refs!(rsys_dict::AbstractDict{String,ReactionSystem}, name::String,
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
                   api_meta::AbstractDict{String,<:Integer}=Dict{String,Int}(),
                   enclosing_env::AbstractDict{String,<:Integer}=Dict{String,Int}(),
                   injected_imports::AbstractVector=Any[],
                   index_set_rename=nothing,
                   rename_where::AbstractString="mount edge")::EsmFile
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
                                    api_meta=api_meta,
                                    injected_imports=injected_imports,
                                    index_set_rename=index_set_rename,
                                    rename_where=rename_where)
        else
            return _load_local_ref(ref, base_path, visited; metaparameters=metaparameters,
                                   api_meta=api_meta,
                                   enclosing_env=enclosing_env,
                                   injected_imports=injected_imports,
                                   index_set_rename=index_set_rename,
                                   rename_where=rename_where)
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
    _backfill_leaf_metaparameters(raw_leaf, bindings, api_meta) -> AbstractDict

The §9.7.6 site-4 backfill at a `subsystems.<k>` mount edge: seed the leaf's
close with the LOADER-API bindings for the names the LEAF DECLARES, then let
the edge's explicit `bindings` (site 3) win over them. The twin of the backfill
`_inline_toplevel_model_refs!` runs at the top-level `models.<k>` form — §4.7
"Two mount forms, one mechanism": a binding MUST NOT make the two forms differ,
and without this one a discovered `extent` (§8.9.4) sized a top-level-mounted
leaf from the data while the same leaf mounted as a subsystem fell through to
its own placeholder default. That is a silent wrong answer — a zero-length
ingested field behind a clean validate and a clean exit — not a diagnostic.

The FILTER is load-bearing in both directions (§4.7). A name the leaf does not
declare is dropped rather than forwarded, or it would raise
`template_import_unknown_name` against a leaf that never asked for it. And the
map read here is `api_meta`, the loader-API bindings ONLY — never the mounting
document's `parent_meta`, which also carries that document's own declared
DEFAULTS. Those are its own site-5 close, not a binding on anything it mounts;
forwarding them would let an assembler's unrelated metaparameter silently
resize a leaf axis the edge never bound.
"""
function _backfill_leaf_metaparameters(raw_leaf,
        bindings::AbstractDict{String,<:Integer},
        api_meta::AbstractDict{String,<:Integer})
    isempty(api_meta) && return bindings
    decls = _raw_get(raw_leaf, "metaparameters")
    (decls !== nothing && decls isa AbstractDict) || return bindings
    out = Dict{String,Int}()
    for (k, v) in pairs(api_meta)
        haskey(decls, string(k)) && (out[string(k)] = Int(v))
    end
    isempty(out) && return bindings
    for (k, v) in pairs(bindings)          # explicit edge bindings win (site 3)
        out[string(k)] = Int(v)
    end
    return out
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
                         api_meta::AbstractDict{String,<:Integer}=Dict{String,Int}(),
                         enclosing_env::AbstractDict{String,<:Integer}=Dict{String,Int}(),
                         injected_imports::AbstractVector=Any[],
                         index_set_rename=nothing,
                         rename_where::AbstractString="mount edge")::EsmFile
    resolved_path = abspath(joinpath(base_path, ref))

    if !isfile(resolved_path)
        throw(SubsystemRefError(
            "Subsystem reference '$(ref)' could not be resolved — file does not exist";
            code=ERROR_CODES.UNRESOLVED_SUBSYSTEM_REF, ref=ref))
    end

    # A §4.7 subsystem ref MUST NOT target a template- or coupling-library
    # file — those reference mechanisms are disjoint (esm-spec §9.7.1, §10.9).
    content = read(resolved_path, String)
    raw_ref_doc = _read_json_document(content)
    _reject_library_ref(raw_ref_doc, ref, resolved_path)

    # Parse the referenced file with the typed pipeline ONLY — deliberately not
    # a public `load_*` entry point, which would resolve nested refs with a
    # FRESH `visited` set and defeat cycle detection. This function drives the
    # nested walk itself, below, carrying the shared `visited` through. The
    # ref's directory anchors its template imports, the edge's `bindings` close
    # its metaparameters (esm-spec §9.7.6 site 3), and `injected_imports`
    # inject the edge's discretization into its single component's scope
    # (esm-spec §9.7.10 form A).
    ref_base = dirname(resolved_path)
    effective = _backfill_leaf_metaparameters(raw_ref_doc, metaparameters, api_meta)
    # The mounted file may itself be an ASSEMBLY, whose own `models.<k>` entries
    # are `{ref}` mount edges. Which attachment point mounted it does not change
    # what it IS, and esm-spec §4.7 "Two mount forms, one mechanism" forbids
    # answering an assembly differently at the two — so its own top-level mounts
    # inline here, in its own directory, exactly as `_load_document` inlines them
    # for a document loaded directly. Sharing `visited` makes a cycle that
    # crosses the two mount forms a `SubsystemRefError` rather than a stack
    # overflow. Returns `nothing` for the common leaf that mounts nothing.
    #
    # Before `_load_parsed`, because the typed pipeline has no `Model` to build
    # from a bare `{ref}`: without this the mount reaches `_resolve_subsystem_ref`
    # as an unresolved edge. Local refs only — the inliner reads its targets with
    # `isfile`, so an assembly reached over http(s) is out of its reach (and out
    # of `_load_remote_ref`'s, which is why that path is untouched).
    ref_doc = _read_json_document(content)
    # `api_meta` travels into the leaf's own top-level mounts too, so the §9.7.6
    # site-4 backfill composes down the reference DAG at BOTH mount forms — the
    # same threading TypeScript's `inlineNestedTopLevelMounts` and Go's
    # `inlineNestedTopLevelModelRefs` do.
    inlined_ref = _inline_toplevel_model_refs(ref_doc, ref_base; visited=visited,
                                              metaparameters=api_meta)
    file = _load_parsed(inlined_ref === nothing ? ref_doc : inlined_ref; base_path=ref_base,
                        metaparameters=effective,
                        injected_imports=injected_imports,
                        index_set_rename=index_set_rename,
                        rename_where=rename_where,
                        mount_declared=(isempty(effective) ? Set{String}() :
                            _collect_mount_declared_metaparameters(raw_ref_doc, ref_base)),
                        mounted_leaf=true,
                        enclosing_env=enclosing_env)

    # Recursively resolve refs in the loaded file, relative to its own directory.
    # `api_meta` travels with the walk, so a leaf mounted two edges down gets the
    # same site-4 backfill (filtered to what IT declares) the first one got.
    # esm-spec §4.7 "Which environment a contribution folds against": the
    # registry these nested mounts land in is THIS leaf's, so they fold against
    # the leaf's own closed environment — its declared defaults overlaid with the
    # loader-API bindings — not the root's.
    _resolve_refs_in_file!(file, ref_base, visited; api_meta=api_meta,
                           root_env=_root_metaparameter_env(raw_ref_doc, effective))

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
                          api_meta::AbstractDict{String,<:Integer}=Dict{String,Int}(),
                          injected_imports::AbstractVector=Any[],
                          index_set_rename=nothing,
                          rename_where::AbstractString="mount edge")::EsmFile
    local content::String
    try
        content = _fetch_url(url)
    catch e
        throw(SubsystemRefError("Failed to download subsystem ref '$(url)': $(e)"))
    end

    raw_data = _read_json_document(content)

    reject_expression_templates_pre_v04(raw_data)
    reject_template_imports_pre_v08(raw_data)
    # The top-level `solver` block arrives at esm 1.1.0 (esm-spec §2.2.4).
    reject_solver_pre_v11(raw_data)
    # Declared `units` on a `const` node arrive at esm 1.2.0 (esm-spec §4.8.5).
    reject_const_units_pre_v12(raw_data)

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
    effective = _backfill_leaf_metaparameters(raw_data, metaparameters, api_meta)
    file = _lower_and_coerce(raw_data, url_base; metaparameters=effective,
                             injected_imports=injected_imports,
                             index_set_rename=index_set_rename,
                             rename_where=rename_where,
                             mount_declared=(isempty(effective) ? Set{String}() :
                                 _collect_mount_declared_metaparameters(raw_data, url_base)),
                             mounted_leaf=true)

    # Nested subsystem refs inside the remote document resolve against the
    # same URL base (relative refs join onto the URL; absolute URLs and the
    # shared `visited` set keep cycle detection canonical).
    _resolve_refs_in_file!(file, url_base, visited; api_meta=api_meta)

    return file
end

"""
    _prepare_document_ops!(doc) -> Int

Settle expression-node `op` spellings for ONE document, in three steps:

1. `arrayop` (removed at esm 0.8.0) is rejected BY NAME. It is a well-formed
   identifier, so esm-spec §4.2 would otherwise admit it as an OPEN
   rewrite-target op — the document would load silently and fail much later as
   `unlowered_operator`, or never.
2. The `faq` version gate, on the AUTHORED form: `faq` arrives at esm 1.1.0
   (esm-spec §2.2.4, the rule the top-level `solver` block follows). This runs
   BEFORE normalization deliberately — `aggregate` IS the pre-1.1.0 spelling,
   so a 1.0.0 document carrying the alias is legal and must not trip this gate.
3. `aggregate` is normalized to `faq`, ONE `E_DEPRECATED_OP_ALIAS` warning is
   raised for the document naming the count, and the declared version is raised
   to the 1.1.0 floor so the upgraded document is self-consistent rather than
   spelling a 1.1.0 construct under an older version.

Returns the number of nodes normalized.
See `docs/content/rfcs/faq-node-rename.md`.
"""
function _prepare_document_ops!(doc; gate::Bool=true)::Int
    at = _find_op_path(doc, "arrayop")
    if at !== nothing
        throw(ParseError("[E_REMOVED_OP] removed_op at $(at): `\"op\": \"arrayop\"` was " *
                         "removed at esm 0.8.0 and is not a deprecated alias; use " *
                         "`\"op\": \"faq\"` (the Functional Aggregate Query node). " *
                         "See docs/content/rfcs/faq-node-rename.md."))
    end
    faq_at = _find_op_path(doc, "faq")
    if gate && faq_at !== nothing && _declared_below_v11(doc)
        declared = _get_field(doc, :esm, nothing)
        throw(ParseError("[E_FAQ_VERSION_TOO_OLD] faq_version_too_old at $(faq_at): the " *
                         "`faq` op arrives at esm 1.1.0; file declares $(declared). Use " *
                         "`\"op\": \"aggregate\"` (the deprecated pre-1.1.0 spelling) or " *
                         "raise the declared version. " *
                         "See docs/content/rfcs/faq-node-rename.md."))
    end
    n = _rewrite_op_aliases!(doc)
    if !gate && faq_at !== nothing && _declared_below_v11(doc)
        # Post-inlining: the document CONTAINS `faq` without having spelled it
        # — a legal 1.0.0 parent whose mounted child uses `faq`. Raise the floor
        # rather than reject, the same rule `emit` applies
        # (docs/content/rfcs/faq-node-rename.md §5.5).
        for key in (:esm, "esm")
            if haskey(doc, key)
                doc[key] = "1.1.0"
                break
            end
        end
    end
    if n > 0
        if _declared_below_v11(doc)
            for key in (:esm, "esm")
                if haskey(doc, key)
                    doc[key] = "1.1.0"
                    break
                end
            end
        end
        @warn string(
            "[E_DEPRECATED_OP_ALIAS] `\"op\": \"aggregate\"` is the pre-1.1.0 ",
            "spelling of `\"op\": \"faq\"` (Functional Aggregate Query); ", n,
            n == 1 ? " node was" : " nodes were", " normalized on load. ",
            "The alias is REMOVED at esm 2.0.0 — re-emit this document to ",
            "migrate it (docs/content/rfcs/faq-node-rename.md)."
        )
    end
    return n
end

"""
    _rewrite_op_aliases!(node) -> Int

Rewrite every `"op": "aggregate"` to `"op": "faq"` in place; return the count.
The document arrives both symbol-keyed (in-memory callers) and string-keyed
(the JSON wire), so the key is probed in both spellings.
"""
function _rewrite_op_aliases!(node)::Int
    n = 0
    if node isa AbstractDict
        for key in (:op, "op")
            if haskey(node, key) && get(node, key, nothing) == "aggregate"
                node[key] = "faq"
                n += 1
                break
            end
        end
        for v in values(node)
            n += _rewrite_op_aliases!(v)
        end
    elseif node isa AbstractVector
        for v in node
            n += _rewrite_op_aliases!(v)
        end
    end
    return n
end

"""
    _find_op_path(node, op, at="") -> Union{String,Nothing}

Path of the first node carrying `"op" => op`, or `nothing`.
"""
function _find_op_path(node, op::AbstractString, at::AbstractString="")
    if node isa AbstractDict
        for key in (:op, "op")
            if haskey(node, key) && get(node, key, nothing) == op
                return at
            end
        end
        for (k, v) in node
            hit = _find_op_path(v, op, string(at, "/", k))
            hit === nothing || return hit
        end
    elseif node isa AbstractVector
        for (i, v) in enumerate(node)
            hit = _find_op_path(v, op, string(at, "/", i - 1))
            hit === nothing || return hit
        end
    end
    return nothing
end

"""
    _declared_below_v11(doc) -> Bool

Does `doc` declare an `esm` version below 1.1.0?
"""
function _declared_below_v11(doc)::Bool
    doc isa AbstractDict || return false
    esm = _get_field(doc, :esm, nothing)
    esm isa AbstractString || return false
    parts = split(String(esm), '.')
    length(parts) >= 2 || return false
    major = tryparse(Int, parts[1]); minor = tryparse(Int, parts[2])
    (major === nothing || minor === nothing) && return false
    return (major, minor) < (1, 1)
end
