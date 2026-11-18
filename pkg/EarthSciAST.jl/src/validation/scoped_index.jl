# The declarations a scoped name can resolve to (esm-spec §4.9.7), indexed once.

"""
    _Declaration(kind, decl)

One declared member of a component: a model's variable (`kind = :variable`,
`decl::ModelVariable`), or a reaction system's species (`:species`,
`decl::Species`) or parameter (`:parameter`, `decl::Parameter`).
"""
struct _Declaration
    kind::Symbol
    decl::Union{ModelVariable, Species, Parameter}
end

# Every declaration kind; the default policy of a lookup.
const _ALL_DECLARATION_KINDS = (:variable, :species, :parameter)

"""
    _ScopedIndex

Every member of every component below some roots, by scoped name
(`<root>.<sub>….<member>`), with the scoped names of the components themselves
(`components`) and whether every mount below the roots is resolved
(`complete`; an unresolved `SubsystemRef` contributes nothing). Built once per
pass by [`_scoped_index`](@ref); [`_resolve_declaration`](@ref) reads it.
"""
struct _ScopedIndex
    members::Dict{String, _Declaration}
    components::Set{String}
    complete::Bool
end

"""
    _scoped_index(file::EsmFile) -> _ScopedIndex
    _scoped_index(roots) -> _ScopedIndex

The index of every top-level model and reaction system of `file`, at any
depth; or of `roots`, `name => component` pairs (a component's own subsystems,
for the paths relative to it). A non-component root (an unresolved mount) is
skipped and marks the index incomplete.
"""
function _scoped_index(roots)
    members = Dict{String, _Declaration}()
    components = Set{String}()
    complete = Ref(true)
    for (name, root) in roots
        if !(root isa Union{Model, ReactionSystem})
            complete[] = false
            continue
        end
        _foreach_component(root, ""; scope = String(name)) do c, _, _, scope
            push!(components, scope)
            _add_declarations!(members, c, scope)
            all(s -> s isa Union{Model, ReactionSystem}, values(c.subsystems)) ||
                (complete[] = false)
        end
    end
    return _ScopedIndex(members, components, complete[])
end
function _scoped_index(file::EsmFile)
    roots = Pair{String, Any}[]
    file.models === nothing || append!(roots, pairs(file.models))
    file.reaction_systems === nothing || append!(roots, pairs(file.reaction_systems))
    return _scoped_index(roots)
end
_scoped_index(::Nothing) = _ScopedIndex(Dict{String, _Declaration}(), Set{String}(), true)

function _add_declarations!(members, m::Model, scope::String)
    for (name, v) in m.variables
        members["$scope.$name"] = _Declaration(:variable, v)
    end
    return members
end
function _add_declarations!(members, rs::ReactionSystem, scope::String)
    for s in rs.species
        members["$scope.$(s.name)"] = _Declaration(:species, s)
    end
    for p in rs.parameters
        members["$scope.$(p.name)"] = _Declaration(:parameter, p)
    end
    return members
end

"""
    _resolve_scoped(members, from, ref) -> Union{String, Nothing}

The scoped name `ref` resolves to when written in the component whose scoped
name is `from` (esm-spec §4.9.7): its own member or a path relative to its own
subsystems (`from.ref`), else, for a dotted `ref`, the top-level path `ref`
itself; `nothing` when `members` (any dictionary keyed by scoped name) holds
neither. With `from = ""` only the top-level path is tried, and with
`absolute = false` only the paths from `from`.
"""
function _resolve_scoped(
        members::AbstractDict, from::AbstractString, ref::AbstractString;
        absolute::Bool = true
    )
    if !isempty(from)
        inner = string(from, ".", ref)
        haskey(members, inner) && return inner
    end
    return absolute && occursin('.', ref) && haskey(members, ref) ? String(ref) : nothing
end

"""
    _resolve_declaration(ix, from, ref; kinds = _ALL_DECLARATION_KINDS, absolute = true)
        -> Union{_Declaration, Nothing}

The declaration `ref` names from scope `from` ([`_resolve_scoped`](@ref)), when
its kind is one of `kinds`. Callers differ on what a dotted name may reach, and
say so with the two policy arguments: `kinds` (a data-fed record shape or a
bound reads a model variable or a reaction-system parameter, never a species;
an equation's left-hand side only a model variable) and `absolute` (whether a
top-level path is tried after the paths from `from`). A member of another kind
still occupies its name: the lookup does not fall through to a further layer.
"""
function _resolve_declaration(
        ix::_ScopedIndex, from::AbstractString, ref::AbstractString;
        kinds = _ALL_DECLARATION_KINDS, absolute::Bool = true
    )
    key = _resolve_scoped(ix.members, from, ref; absolute = absolute)
    key === nothing && return nothing
    d = ix.members[key]
    return d.kind in kinds ? d : nothing
end
