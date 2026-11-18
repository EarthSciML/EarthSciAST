# ========================================
# 9. Backward Compatibility Helpers
# ========================================

"""
    dict_to_stoichiometry_entries(dict::AbstractDict{String,<:Real}) -> Vector{StoichiometryEntry}

Convert old-style species→coefficient dict format to new StoichiometryEntry vector format.
Accepts any numeric coefficient type (`Int`, `Float64`, …) — fractional stoichiometries
are supported by the v0.2.x schema.
"""
function dict_to_stoichiometry_entries(dict::AbstractDict{String, <:Real})::Vector{StoichiometryEntry}
    return [StoichiometryEntry(species, stoichiometry) for (species, stoichiometry) in dict]
end

"""
    stoichiometry_entries_to_dict(entries::Vector{StoichiometryEntry}) -> Dict{String,Float64}

Convert new StoichiometryEntry vector format to species→coefficient dict.
"""
function stoichiometry_entries_to_dict(entries::Vector{StoichiometryEntry})::Dict{String, Float64}
    return Dict(entry.species => entry.stoichiometry for entry in entries)
end

# Deterministic 64-bit FNV-1a hash. Used for content-derived ids; unlike
# `Base.hash`, its value is stable across Julia versions and sessions.
function _fnv1a64(s::AbstractString)::UInt64
    h = 0xcbf29ce484222325
    for b in codeunits(s)
        h = (h ⊻ UInt64(b)) * 0x00000100000001b3
    end
    return h
end

# Render a JSON-compatible value (as produced by `serialize_expression`) to a
# deterministic string: object keys are emitted in sorted order, so the result
# depends only on content, never on Dict iteration order.
_stable_json(x::AbstractDict) =
    "{" * join(
    sort!(
        [
            string(repr(String(string(k))), ":", _stable_json(v))
                for (k, v) in pairs(x)
        ]
    ), ","
) * "}"
_stable_json(x::AbstractVector) = "[" * join([_stable_json(v) for v in x], ",") * "]"
_stable_json(x::AbstractString) = repr(String(x))
_stable_json(x) = string(x)

"""
    Reaction(reactants::AbstractDict{String,<:Real}, products::AbstractDict{String,<:Real}, rate::ASTExpr) -> Reaction

Convenience constructor that creates a reaction with an
auto-generated, content-derived id: the same reactants, products, and rate
always produce the same id (deterministic across sessions and Julia versions,
unlike `Base.hash`).
"""
function Reaction(reactants::AbstractDict{String, <:Real}, products::AbstractDict{String, <:Real}, rate::ASTExpr)
    # Content-derived id: sorted species:stoichiometry lists plus a
    # deterministic rendering of the rate AST, digested with FNV-1a.
    fmt(d) = join(sort!(["$(k):$(Float64(v))" for (k, v) in d]), ",")
    content = fmt(reactants) * "=>" * fmt(products) * "|" *
        _stable_json(serialize_expression(rate))
    id = "reaction_" * string(_fnv1a64(content), base = 16, pad = 16)

    substrates = isempty(reactants) ? nothing : dict_to_stoichiometry_entries(reactants)
    products_vec = isempty(products) ? nothing : dict_to_stoichiometry_entries(products)

    return Reaction(id, substrates, products_vec, rate)
end

"""
    get_reactants_dict(reaction::Reaction) -> Dict{String,Float64}

Get reactants as dictionary for backward compatibility.
"""
function get_reactants_dict(reaction::Reaction)::Dict{String, Float64}
    # Ordered field via `raw_substrates`, collapsed to the unordered Dict view.
    substrates_field = raw_substrates(reaction)
    if substrates_field === nothing
        return Dict{String, Float64}()
    else
        return stoichiometry_entries_to_dict(substrates_field)
    end
end

"""
    get_products_dict(reaction::Reaction) -> Dict{String,Float64}

Get products as dictionary for backward compatibility.
"""
function get_products_dict(reaction::Reaction)::Dict{String, Float64}
    # Ordered field via `raw_products`, collapsed to the unordered Dict view.
    products_field = raw_products(reaction)
    if products_field === nothing
        return Dict{String, Float64}()
    else
        return stoichiometry_entries_to_dict(products_field)
    end
end

"""
    raw_substrates(r::Reaction) -> Union{Vector{StoichiometryEntry},Nothing}
    raw_products(r::Reaction)  -> Union{Vector{StoichiometryEntry},Nothing}

The `substrates` / `products` fields as stored: the ORDERED
`Vector{StoichiometryEntry}` (or `nothing` for a source/sink reaction, ∅ → X /
X → ∅). Named accessors for the raw fields so ordered author-entry access reads
the same at every call site (equivalent to `r.substrates` / `r.products` now
that the `getproperty` shim is gone). For the unordered `Dict{String,Float64}`
species→coefficient view, use [`get_reactants_dict`](@ref) /
[`get_products_dict`](@ref).
"""
raw_substrates(r::Reaction) = getfield(r, :substrates)
raw_products(r::Reaction) = getfield(r, :products)

# NOTE: `Reaction` has no `getproperty` override — plain `r.substrates` /
# `r.products` reach the stored ORDERED `Vector{StoichiometryEntry}` fields
# directly. Use `raw_substrates` / `raw_products` for that ordered view and
# `get_reactants_dict` / `get_products_dict` for the unordered
# `Dict{String,Float64}` species→coefficient view.
