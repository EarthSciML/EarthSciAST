# One resolver from a caller's spelling of a name to the name a build uses.
#
# Every surface that takes a name from a caller — `p`, `u0`, `providers`,
# `const_arrays`, `remake`, an inline test's overrides and assertions, an
# `observed_field` read, an output request — resolves it here, against a
# `NameTable` of the names that surface can designate. What differs between
# surfaces is only which bare spellings they admit (the `bare` policy of
# `resolve_key`), never the rules themselves.

"""
    NameTable(names; namespaces)

The names one surface of a build can designate (flattened, component-qualified
parameter names, state elements, array bases or observeds), the component and
subsystem namespaces a qualified key's leading segments may name, and every
proper dotted suffix of each name with the names that carry it.
"""
struct NameTable
    names::Set{String}
    namespaces::Set{String}
    by_suffix::Dict{String, Vector{String}}
end

function NameTable(names; namespaces = nothing)
    ns = Set{String}(String(n) for n in names)
    by_suffix = Dict{String, Vector{String}}()
    for n in ns, s in _dotted_suffixes(n)
        push!(get!(by_suffix, s, String[]), n)
    end
    for v in values(by_suffix)
        sort!(v)
    end
    return NameTable(ns, namespaces === nothing ? _override_namespaces(ns) : namespaces, by_suffix)
end

"""
    KeyResolution

What [`resolve_key`](@ref) made of one key: `name` (or `nothing`), `how` it matched
— `:exact`, `:qualified` (a dotted key whose leading segments are namespaces
and whose remainder is a name), `:suffix` (the key is a dotted suffix of
exactly one name), `:ambiguous` (a suffix of several; `candidates` lists them)
or `:unknown` — and the `candidates` of an ambiguous key.
"""
struct KeyResolution
    name::Union{Nothing, String}
    how::Symbol
    candidates::Vector{String}
end

"""
    resolve_key(t::NameTable, key; bare = :unique) -> KeyResolution

The name `key` designates, by esm-spec §6.6.2 in precedence order:

1. an exact name;
2. a dotted key whose LONGEST dotted suffix is a name, every dropped leading
   segment naming a component or subsystem (`Missing.u` is not re-pointed at
   `u`);
3. a key that is itself a dotted suffix of names — resolved when exactly one
   name carries it, ambiguous otherwise.

`bare` restricts rule 3 for a surface whose spec admits fewer spellings:
`:unique` (the §6.6.2 rule), `:single_component` (a key with no `.` resolves
only when every name lies in one component, API_SPEC §5.8 `observed_field`),
or `:never` (rules 1 and 2 only).
"""
function resolve_key(t::NameTable, key::AbstractString; bare::Symbol = :unique)::KeyResolution
    k = String(key)
    k in t.names && return KeyResolution(k, :exact, String[])
    hit = _dotted_suffix_hit(t.names, t.namespaces, k)
    hit === nothing || return KeyResolution(hit, :qualified, String[])
    bare === :never && return KeyResolution(nothing, :unknown, String[])
    cands = get(t.by_suffix, k, nothing)
    cands === nothing && return KeyResolution(nothing, :unknown, String[])
    if bare === :single_component && !occursin('.', k)
        length(_name_components(t)) == 1 || return KeyResolution(nothing, :ambiguous, copy(cands))
    end
    length(cands) == 1 && return KeyResolution(cands[1], :suffix, String[])
    return KeyResolution(nothing, :ambiguous, copy(cands))
end

# The components of a table's names: everything before a name's final segment,
# `""` for an unqualified one.
_name_components(t::NameTable) = Set{String}(
    occursin('.', n) ? String(rsplit(n, '.'; limit = 2)[1]) : "" for n in t.names
)

"""
    canonicalize_keys(::Type{V}, t::NameTable, keyed::AbstractDict) -> (normalized, unknown, ambiguous, collisions)

Every key of `keyed` resolved (`resolve_key`), its value converted to `V` (`Any`
keeps it). An exact key wins over any other key for the same name; two
non-exact keys for one name collide.

Returns `normalized` (name → value), `unknown` (sorted keys that designate
nothing), `ambiguous` (key → candidates) and `collisions` (name → the sorted
non-exact keys that designate it), so the caller raises the three failures
apart, each with its remedy (correct the name; qualify it; drop a key).
"""
function canonicalize_keys(::Type{V}, t::NameTable, keyed::AbstractDict) where {V}
    normalized = Dict{String, V}()
    unknown = String[]
    ambiguous = Dict{String, Vector{String}}()
    exact = Set{String}()
    claims = Dict{String, Vector{Tuple{String, Any}}}()
    for (rawk, v) in keyed
        k = String(rawk)
        r = resolve_key(t, k)
        if r.how === :exact
            push!(exact, k)
            normalized[k] = _override_value(V, v)
        elseif r.how === :ambiguous
            ambiguous[k] = r.candidates
        elseif r.how === :unknown
            push!(unknown, k)
        else
            push!(get!(claims, r.name, Tuple{String, Any}[]), (k, v))
        end
    end
    collisions = Dict{String, Vector{String}}()
    for (name, cs) in claims
        name in exact && continue
        if length(cs) > 1
            collisions[name] = sort!(String[k for (k, _) in cs])
        else
            normalized[name] = _override_value(V, cs[1][2])
        end
    end
    sort!(unknown)
    return normalized, unknown, ambiguous, collisions
end

@inline _override_value(::Type{Any}, v) = v
@inline _override_value(::Type{V}, v) where {V} = V(v)

# Raise the first failure of a `canonicalize_keys` result on `surface` (`"p"`,
# `"providers"`, …) whose names are `kind`s (`"parameter"`, `"state"`): an
# ambiguous key, then two keys for one name, then (when `unknown_message` is
# given) an unknown key. One exception type, `SimulateError`, whatever the
# surface; an unknown key carries `unknown_override_key`.
function _raise_key_failures(
        surface::AbstractString, kind::AbstractString, unknown, ambiguous, collisions;
        unknown_message = nothing
    )
    if !isempty(ambiguous)
        k, cands = first(sort!(collect(ambiguous), by = first))
        throw(SimulateError(_override_ambiguous_message(surface, k, cands; kind = kind)))
    end
    if !isempty(collisions)
        name, ks = first(sort!(collect(collisions), by = first))
        throw(SimulateError(_override_collision_message(surface, kind, name, ks)))
    end
    if unknown_message !== nothing && !isempty(unknown)
        throw(SimulateError(unknown_message(first(unknown)), ERROR_CODES.UNKNOWN_OVERRIDE_KEY))
    end
    return nothing
end

# The esm-spec §6.6.2 "two keys, one name" diagnostic, worded identically in
# Python (`_collision_message`) and Rust
# (`SimulateError::CollidingParameterKeys`).
_override_collision_message(
    surface::AbstractString, kind::AbstractString,
    name::AbstractString, keys_::AbstractVector{String}
) =
    "$(surface): $(length(keys_)) keys designate the $(kind) '$(name)' " *
    "($(join(keys_, ", "))). Supply exactly one override key per name " *
    "(esm-spec §6.6.2)."

# The esm-spec §6.6.2 "a key several names carry" diagnostic.
_override_ambiguous_message(
    surface::AbstractString, k::AbstractString, cands::AbstractVector{String};
    kind::AbstractString = "parameter"
) =
    "$(surface): ambiguous $(kind) name '$(k)' — it is carried " *
    "as a suffix by $(length(cands)) $(kind)s ($(join(sort(cands), ", "))). " *
    "Qualify it further with its owning component (esm-spec §6.6.2)."
