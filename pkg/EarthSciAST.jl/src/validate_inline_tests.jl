# Static checks on every inline test (esm-spec §6.6), decidable from the document
# alone and so owed by every binding, executing or not:
#
# - an assertion `variable` that is a bare name (element suffix removed) the
#   asserting component does not declare is `undefined_variable` (§6.6.3); a
#   dotted target names a declaration elsewhere and is resolved by the runtime;
# - an `initial_conditions` / `parameter_overrides` key that matches no declared
#   name under the §6.6.2 rules is `unknown_override_key`; skipped when the
#   document still holds an unresolved `{ref}` mount a key could name into;
# - an assertion whose form does not match the declared rank of its target is
#   `assertion_rank_mismatch` (§6.6.5).

const _ELEMENT_SUFFIX = r"^(.*?)\[[^\]]*\]$"

# `u[1]` -> ("u", true); a name without an element suffix is unchanged.
function _strip_element_suffix(name::AbstractString)
    m = match(_ELEMENT_SUFFIX, name)
    return m === nothing ? (String(name), false) : (String(m.captures[1]), true)
end

# Escape one JSON Pointer reference token (RFC 6901).
_pointer_token(key::AbstractString) = replace(replace(key, "~" => "~0"), "/" => "~1")

# The names an assertion may target by a bare name, mapped to the declared
# `shape` (empty when absent): a model's `variables`, or a reaction system's
# `species` (which carry no shape) and `parameters`.
function _test_target_shapes(model::Model)
    return Dict{String,Vector{String}}(
        name => (v.shape === nothing ? String[] : v.shape) for (name, v) in model.variables)
end
function _test_target_shapes(rs::ReactionSystem)
    shapes = Dict{String,Vector{String}}(sp.name => String[] for sp in rs.species)
    for p in rs.parameters
        shapes[p.name] = p.shape === nothing ? String[] : p.shape
    end
    return shapes
end

# The document's declared names qualified as a flatten qualifies them
# (`<component>.<name>`, `<component>.<subsystem>.<name>` at any depth), the
# component and subsystem names §6.6.2 rule 2 validates a key's leading segments
# against, and whether every mount is resolved.
function _declared_override_names(file::EsmFile)
    names = Set{String}()
    namespaces = Set{String}()
    complete = Ref(true)
    function walk(prefix::String, component)
        if !(component isa Model || component isa ReactionSystem)
            complete[] = false
            return
        end
        push!(namespaces, last(split(prefix, '.')))
        for name in keys(_test_target_shapes(component))
            push!(names, "$prefix.$name")
        end
        for (sub_name, sub) in component.subsystems
            walk("$prefix.$sub_name", sub)
        end
    end
    file.models === nothing || for (name, model) in file.models
        walk(String(name), model)
    end
    file.reaction_systems === nothing || for (name, rs) in file.reaction_systems
        walk(String(name), rs)
    end
    return names, namespaces, complete[]
end

# Whether `key` reaches a declared name under §6.6.2 rules 1-3: an exact hit; a
# dotted suffix of the key that is a name, every dropped leading segment naming a
# component or subsystem; or the key a dotted suffix of some name. Ambiguity is a
# runtime diagnostic, so one match suffices.
function _override_key_matches(key::AbstractString, names::Set{String}, namespaces::Set{String})
    key in names && return true
    parts = split(key, '.')
    for i in 2:length(parts)
        if join(parts[i:end], '.') in names && all(p -> String(p) in namespaces, parts[1:i-1])
            return true
        end
    end
    tail = "." * key
    return any(n -> endswith(n, tail), names)
end

function _check_inline_tests!(errors::Vector{StructuralError}, tests, component_path::String,
                              shapes::Dict{String,Vector{String}}, names, namespaces, complete)
    for (ti, test) in enumerate(tests)
        base = "$component_path/tests/$(ti-1)"
        if complete
            for (field, overrides) in (("initial_conditions", test.initial_conditions),
                                       ("parameter_overrides", test.parameter_overrides))
                for key in sort!(collect(keys(overrides)))
                    bare_key, _ = _strip_element_suffix(key)
                    _override_key_matches(bare_key, names, namespaces) && continue
                    push!(errors, StructuralError(
                        "$base/$field/$(_pointer_token(key))",
                        "Override key \"$key\" in $field matches no declared name",
                        ERROR_CODES.UNKNOWN_OVERRIDE_KEY,
                        Dict{String,Any}("key" => key, "field" => field)))
                end
            end
        end
        for (ai, assertion) in enumerate(test.assertions)
            bare, is_element = _strip_element_suffix(assertion.variable)
            occursin('.', bare) && continue
            pointer = "$base/assertions/$(ai-1)"
            if !haskey(shapes, bare)
                push!(errors, StructuralError(
                    "$pointer/variable",
                    "Variable \"$bare\" referenced in assertion variable but not declared",
                    ERROR_CODES.UNDEFINED_VARIABLE,
                    Dict{String,Any}("variable" => bare)))
                continue
            end
            is_element && continue
            shape = shapes[bare]
            selects = assertion.coords !== nothing || assertion.reduce !== nothing
            if !isempty(shape) && !selects
                push!(errors, StructuralError(
                    pointer,
                    "Assertion on shaped variable \"$bare\" selects no scalar (give coords, reduce, or an element name)",
                    ERROR_CODES.ASSERTION_RANK_MISMATCH,
                    Dict{String,Any}("variable" => bare, "shape" => shape)))
            elseif isempty(shape) && selects
                push!(errors, StructuralError(
                    pointer,
                    "Assertion on scalar variable \"$bare\" carries coords or reduce",
                    ERROR_CODES.ASSERTION_RANK_MISMATCH,
                    Dict{String,Any}("variable" => bare, "shape" => String[])))
            end
        end
    end
    return errors
end

# The static inline-test checks over every top-level component, in sorted order
# so the findings do not depend on dictionary iteration.
function _validate_inline_tests(file::EsmFile)::Vector{StructuralError}
    errors = StructuralError[]
    names, namespaces, complete = _declared_override_names(file)
    if file.models !== nothing
        for name in sort!(collect(keys(file.models)))
            model = file.models[name]
            _check_inline_tests!(errors, model.tests, "/models/$name",
                                 _test_target_shapes(model), names, namespaces, complete)
        end
    end
    if file.reaction_systems !== nothing
        for name in sort!(collect(keys(file.reaction_systems)))
            rs = file.reaction_systems[name]
            _check_inline_tests!(errors, rs.tests, "/reaction_systems/$name",
                                 _test_target_shapes(rs), names, namespaces, complete)
        end
    end
    return errors
end
