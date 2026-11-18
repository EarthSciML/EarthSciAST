# Data-fed parameters: unit conversions, sources, record axes and shapes.

"""
    _check_update_unit_conversions!(errors, file, model, path, scope)

Walk the `unit_conversion` Expression of every `update.from` binding in `model`
(and, recursively, its subsystems). The binding lives on the
CONSUMING PARAMETER (esm-spec §8.5), so this is where the 0.x loader-variable
walk moved to. A plain numeric factor has nothing to resolve.
"""
function _check_update_unit_conversions!(
        errors::Vector{StructuralError}, file::EsmFile,
        model::Model, path::String, scope::Set{String}
    )
    _foreach_component(model, path) do m, p, _
        _check_update_unit_conversions_here!(errors, file, m, p, scope)
    end
    return errors
end

function _check_update_unit_conversions_here!(
        errors::Vector{StructuralError}, file::EsmFile,
        model::Model, path::String, scope::Set{String}
    )
    for name in sort!(collect(keys(model.variables)))
        rules = model.variables[name].update
        rules === nothing && continue
        for (ri, rule) in enumerate(rules)
            rule.from === nothing && continue
            uc = rule.from.unit_conversion
            isa(uc, ASTExpr) || continue
            append!(
                errors, validate_expression_references(
                    file, uc,
                    _update_rule_path(_pointer(path, "variables", name), rules, ri) *
                        "/from/unit_conversion";
                    scope = scope
                )
            )
        end
    end
    return errors
end

"""
    _check_update_sources!(errors, model, path, available)

esm-spec §8.5: a `data` update's `source` MUST name a declared `data_sources`
entry, or `data_source_undefined`. This is the only way left to name a data
source wrongly — a source is not a coupling endpoint, a subsystem,
or a scoped-reference path root — and, unlike the 0.x coupling reference it
replaces, it is schema-valid by construction (any string), so the defect
genuinely reaches structural validation instead of being masked by a schema
rejection.
"""
function _check_update_sources!(
        errors::Vector{StructuralError}, model::Model,
        path::String, available::Vector{String}
    )
    _foreach_component(model, path) do m, p, _
        _check_update_sources_here!(errors, m, p, available)
    end
    return errors
end

function _check_update_sources_here!(
        errors::Vector{StructuralError}, model::Model,
        path::String, available::Vector{String}
    )
    for name in sort!(collect(keys(model.variables)))
        rules = model.variables[name].update
        rules === nothing && continue
        for (ri, rule) in enumerate(rules)
            rule.kind == "data" || continue
            src = rule.source
            (src === nothing || src in available) && continue
            _report!(
                errors, ERROR_CODES.DATA_SOURCE_UNDEFINED,
                _pointer(path, "variables", name, "update"),
                "Parameter update names data source '$src', which the document " *
                    "does not declare",
                Dict{String, Any}(
                    "variable" => name, "source" => src,
                    "available_sources" => available
                )
            )
        end
    end
    return errors
end

"""
    _declared_variable(ix::_ScopedIndex, scoped) -> Union{ModelVariable, Parameter, Nothing}

The declaration the top-level scoped name `scoped` names in the declarations
`ix`: a model variable `Model[.Sub…].var`, or a reaction-system parameter
`System[.Sub…].param`; `nothing` when there is none (or it sits behind a `ref`
not yet mounted).
"""
function _declared_variable(ix::_ScopedIndex, scoped)
    scoped isa AbstractString || return nothing
    d = _resolve_declaration(ix, "", scoped; kinds = (:variable, :parameter))
    return d === nothing ? nothing : d.decl
end

"""
    _is_record_axis(file, name) -> Bool

esm-spec §8.5.1: whether `name` is a declared `interval` index set carrying
`"records": true`. An index set the document does not declare is not one.
"""
function _is_record_axis(file::EsmFile, name)::Bool
    name isa AbstractString || return false
    iset = get(file.index_sets, String(name), nothing)
    return iset !== nothing && iset.kind == "interval" && iset.records === true
end

"""
    _declared_shape_of(ix::_ScopedIndex, scoped) -> Union{Vector{String}, Nothing}

The declared `shape` of the variable a scoped name names (`[]` when it declares
none), or `nothing` when [`_declared_variable`](@ref) cannot reach it.
"""
function _declared_shape_of(ix::_ScopedIndex, scoped)
    v = _declared_variable(ix, scoped)
    v === nothing && return nothing
    return v.shape === nothing ? String[] : collect(String, v.shape)
end

"""
    _param_to_var_target_map(coupling) -> Dict{String, Vector{String}}

The `to` of every `param_to_var` `variable_map` entry of `coupling`, keyed by
its `from`, in coupling order (esm-spec §8.5.1, esm-libraries-spec §4.7.3).
Built once per pass and shared by every data-fed parameter it judges.
"""
function _param_to_var_target_map(coupling)
    targets = Dict{String, Vector{String}}()
    for e in coupling
        (e isa CouplingVariableMap && e.transform == "param_to_var") || continue
        push!(get!(() -> String[], targets, e.from), e.to)
    end
    return targets
end


"""
    _typed_record_shapes(decls, targets, scoped, var; defer_empty) -> Union{Vector{Vector{String}}, Nothing}

The record shapes of the data-fed parameter `var` (a model variable or a
reaction-system parameter; scoped name `scoped`) that this pass can see, over
the `param_to_var` edges `targets` ([`_param_to_var_target_map`](@ref); see
[`_record_shapes`](@ref)), or `nothing` when none is decidable yet: every
`param_to_var` target is unreachable, or the parameter is shapeless, the `from`
of no target, and `defer_empty` says one may still arrive (the document holds a
`coupling_import`, which expands at `flatten`). A shapeless parameter that no
target can reach has the empty record shape.
"""
function _typed_record_shapes(
        decls::_ScopedIndex, targets::AbstractDict, scoped::AbstractString,
        var::Union{ModelVariable, Parameter}; defer_empty::Bool
    )
    shapes, mapped = _record_shapes(
        var.shape, get(targets, scoped, String[]), t -> _declared_shape_of(decls, t)
    )
    mapped || return defer_empty ? nothing : Vector{String}[String[]]
    return isempty(shapes) ? nothing : shapes
end

# A record shape as the document spells it, for a diagnostic: `["rec", "x"]`.
_shape_show(shape) = "[" * join(("\"$x\"" for x in shape), ", ") * "]"

"""
    _record_shape_findings(file, decls, targets, scope, name, var, rule, src, at; defer_empty, refs_pending = false)
        -> (findings::Vector{Tuple{String, String, Dict{String, Any}}}, records::Union{Int, Nothing})

esm-spec §8.5.1 rules 2, 3 and the deprecated field's agreement, for one `data`
rule of the parameter `name` (in component `scope`) drawing from the
`DataSource` `src`, at the rule pointer `at`: each finding as `(code, message,
details)`. Checked against the record shapes this pass can see
([`_typed_record_shapes`](@ref), over the `param_to_var` edges `targets`); none
decidable, no finding. While `refs_pending` (some mount is unresolved: the
document's declarations `decls` are incomplete), a record shape whose first entry names an index
set the document does not declare is skipped: a mount may declare it. Also returns the number of records
the parameter receives (`nothing` when not decided, or misplaced), which
`flatten` gives its `LoaderField`. Shared by validation (which pushes the
findings) and `flatten` (which throws the first).

- `record_axis_misplaced`: a record axis anywhere but first, or record shapes
  that disagree about beginning with one. Nothing else is checked then: the
  number of records is not defined.
- `record_axis_time_invariant_source`: two records, from a source with no
  `temporal` block or no `temporal.start`.
- `records_per_sample_invalid`: a written `records_per_sample` (the rule's own,
  else the source's) that is not the number the record shape gives.
"""
function _record_shape_findings(
        file::EsmFile, decls::_ScopedIndex, targets::AbstractDict, scope::AbstractString,
        name::AbstractString, var::Union{ModelVariable, Parameter}, rule, src,
        at::AbstractString; defer_empty::Bool, refs_pending::Bool = false
    )
    out = Tuple{String, String, Dict{String, Any}}[]
    shapes = _typed_record_shapes(decls, targets, "$scope.$name", var; defer_empty = defer_empty)
    shapes === nothing && return out, nothing
    if refs_pending
        filter!(s -> isempty(s) || haskey(file.index_sets, first(s)), shapes)
        isempty(shapes) && return out, nothing
    end
    misplaced, records = _record_axis_verdict(shapes, n -> _is_record_axis(file, n))
    if misplaced
        push!(
            out, (
                ERROR_CODES.RECORD_AXIS_MISPLACED,
                "Parameter '$name' (at $at) is data-fed, so a record axis may only " *
                    "be the first entry of its record shape, and every record shape " *
                    "must agree on whether it begins with one; its record shapes " *
                    "are $(join(_shape_show.(shapes), ", "))",
                Dict{String, Any}("variable" => name, "record_shapes" => shapes),
            )
        )
        return out, nothing
    end
    if records == 2 && (
            src.temporal === nothing || src.temporal.start === nothing ||
                isempty(src.temporal.start)
        )
        what = src.temporal === nothing ? "no temporal block" : "no temporal start"
        push!(
            out, (
                ERROR_CODES.RECORD_AXIS_TIME_INVARIANT_SOURCE,
                "Parameter '$name' (at $at) receives two records per sample (its " *
                    "record shape $(_shape_show(first(shapes))) begins with a record axis) from " *
                    "data source '$(rule.source)', which declares $what, so it is " *
                    "time-invariant and has no successor record",
                Dict{String, Any}("variable" => name, "source" => rule.source),
            )
        )
    end
    written = _written_records_per_sample(rule.from, src)
    if written !== nothing && written != records
        push!(
            out, (
                ERROR_CODES.RECORDS_PER_SAMPLE_INVALID,
                "Parameter '$name' (at $at) has records_per_sample $written written " *
                    "for it, but its record shape $(_shape_show(first(shapes))) gives it $records " *
                    "(two only when the first entry is an interval index set with " *
                    "\"records\": true, esm-spec §8.5.1)",
                Dict{String, Any}(
                    "variable" => name, "records_per_sample" => written,
                    "record_shape" => first(shapes),
                ),
            )
        )
    end
    return out, records
end

"""
    _check_record_axes!(errors, file)

esm-spec §8.5.1 rule 1, `record_axis_invalid` at `/index_sets/<name>`: an index
set carrying `"records": true` whose size is not 2. A size still symbolic (not
folded to an integer) is skipped.
"""
function _check_record_axes!(errors::Vector{StructuralError}, file::EsmFile)
    for name in sort!(collect(keys(file.index_sets)))
        iset = file.index_sets[name]
        iset.records === true || continue
        (iset.size === nothing || iset.size == 2) && continue
        _report!(
            errors, ERROR_CODES.RECORD_AXIS_INVALID,
            "/index_sets/$name",
            "Index set '$name' is a record axis (\"records\": true), so its " *
                "size must be 2 (the record at or before the query time and the " *
                "next); it is $(iset.size)",
            Dict{String, Any}("index_set" => name, "size" => iset.size)
        )
    end
    return errors
end

"""
    _check_record_shapes!(errors, file)

esm-spec §8.5.1 at every depth of every model and reaction system: the
deprecated `from.records_per_sample` on a rule that is not `data`
(`records_per_sample_invalid`), and, for every `data` rule of a parameter, the
findings of [`_record_shape_findings`](@ref). A shapeless parameter that is the
`from` of no `param_to_var` entry is checked here only when the document's
`coupling` holds no `coupling_import`; a target this pass cannot reach is
skipped, and the reachable ones are judged. `flatten` checks what arrives after
expansion. The pointer is the rule's: `…/update` for the object form,
`…/update/<i>` for the array form.
"""
function _check_record_shapes!(
        errors::Vector{StructuralError}, file::EsmFile, decls::_ScopedIndex = _scoped_index(file)
    )
    targets = _param_to_var_target_map(file.coupling)
    defer_empty = any(e -> e isa CouplingImport, file.coupling)
    function check(scope, name, var, declpath)
        rules = var.update
        rules === nothing && return
        for (ri, rule) in enumerate(rules)
            rule.from === nothing && continue
            at = _update_rule_path(_pointer(declpath, name), rules, ri)
            if rule.kind != "data"
                rule.from.records_per_sample === nothing && continue
                _report!(
                    errors, ERROR_CODES.RECORDS_PER_SAMPLE_INVALID,
                    at,
                    "Parameter '$name' sets from.records_per_sample on a " *
                        "'$(rule.kind)' rule; only a 'data' rule names a source " *
                        "to read records from",
                    Dict{String, Any}("variable" => name, "kind" => rule.kind)
                )
                continue
            end
            src = (rule.source === nothing || file.data_sources === nothing) ? nothing :
                get(file.data_sources, rule.source, nothing)
            src === nothing && continue  # data_source_undefined reports it
            findings, _ = _record_shape_findings(
                file, decls, targets, scope, name, var, rule, src, at;
                defer_empty = defer_empty, refs_pending = !decls.complete
            )
            for (code, msg, details) in findings
                _report!(
                    errors, code,
                    at,
                    msg,
                    details
                )
            end
        end
        return
    end
    _for_each_data_param(check, file)
    return errors
end

"""
    _for_each_data_param(f, file)

Call `f(scope, name, decl, declpath)` for every declared parameter-bearing
entry a `data` rule can sit on, in sorted order: each model variable at every
subsystem depth (`declpath` = `/models/<M>[/subsystems/<S>…]/variables`) and
each reaction-system parameter at every depth
(`/reaction_systems/<R>[/subsystems/<S>…]/parameters`). `scope` is the
component's scoped name.
"""
function _for_each_data_param(f, file::EsmFile)
    if file.models !== nothing
        for name in sort!(collect(keys(file.models)))
            _foreach_component(file.models[name], _pointer("", "models", name); scope = name) do m, p, _, s
                for vname in sort!(collect(keys(m.variables)))
                    f(s, vname, m.variables[vname], _pointer(p, "variables"))
                end
            end
        end
    end
    if file.reaction_systems !== nothing
        for name in sort!(collect(keys(file.reaction_systems)))
            _foreach_component(
                file.reaction_systems[name], _pointer("", "reaction_systems", name);
                scope = name, sorted = true
            ) do rs, p, _, s
                for prm in sort(rs.parameters; by = x -> x.name)
                    f(s, prm.name, prm, _pointer(p, "parameters"))
                end
            end
        end
    end
    return nothing
end

"""
    deprecated_records_per_sample_sites(file::EsmFile) -> Vector{String}

The JSON pointers at which the deprecated `records_per_sample` (esm-spec §8.3,
§8.5.1; removed at esm 3.0.0) is written in a loaded document, sorted
(byte-order): `/data_sources/<S>/temporal/records_per_sample` and
`/models/<M>[/subsystems/<S>…]/variables/<v>/update[/<i>]/from/records_per_sample`
and `/reaction_systems/<R>[/subsystems/<S>…]/parameters/<p>/update[/<i>]/from/records_per_sample`
(`/<i>` only for an array-form `update`). Empty when the document never writes
it. The load entry points warn `deprecated_records_per_sample` once, naming
these, when it is not empty.
"""
function deprecated_records_per_sample_sites(file::EsmFile)::Vector{String}
    sites = String[]
    if file.data_sources !== nothing
        for (sname, src) in file.data_sources
            t = src.temporal
            (t !== nothing && t.records_per_sample !== nothing) || continue
            push!(sites, "/data_sources/$sname/temporal/records_per_sample")
        end
    end
    _for_each_data_param(file) do _scope, name, var, declpath
        rules = var.update
        rules === nothing && return
        for (ri, rule) in enumerate(rules)
            (rule.from !== nothing && rule.from.records_per_sample !== nothing) || continue
            push!(
                sites, _update_rule_path("$declpath/$name", rules, ri) *
                    "/from/records_per_sample"
            )
        end
        return
    end
    return sort!(sites)
end

"""
    _warn_deprecated_records_per_sample(file::EsmFile)

The load-time `deprecated_records_per_sample` warning (esm-spec §8.5.1): ONE
`@warn` per load naming every site
[`deprecated_records_per_sample_sites`](@ref) finds, none when it finds none.
Called by the public load entry points once refs are mounted, never by a nested
(ref-mounted) load, so a load warns at most once.
"""
function _warn_deprecated_records_per_sample(file::EsmFile)
    sites = deprecated_records_per_sample_sites(file)
    isempty(sites) && return nothing
    @warn string(
        "deprecated_records_per_sample: `records_per_sample` is deprecated and is ",
        "removed at esm 3.0.0; the number of records a data-fed parameter receives ",
        "is said by its record shape, two when its first axis is an interval index ",
        "set with \"records\": true (esm-spec §8.5.1). Written at: ",
        join(sites, ", "), "."
    )
    return nothing
end
