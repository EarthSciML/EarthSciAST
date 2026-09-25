# The flat state layout: which slot of `u` each state element occupies.
#
# Scalars take slots 1..n_scalar in their sorted-name order; then every array
# variable, in sorted-name order, takes one contiguous block over the bounding
# box `lo:hi` of its cells, first index fastest (column-major). An array block
# is therefore a base slot plus extents, and a cell's slot is arithmetic:
#
#     slot = base + Σ_d (idx[d] - lo[d]) * strides[d]
#
# `StateLayout` is also the `var_map` every consumer reads (`prob.var_map`,
# `_compile`'s name → slot lookup, the inline-test and output surfaces): it is an
# `AbstractDict{String,Int}` keyed by the element names `_cell_key` spells
# (`"u[2,3]"`), answered by parsing the key back to a block and an index, so no
# string is made or stored per cell. Iteration yields every element in slot
# order. The map is immutable; a caller that needs a mutable copy gets a
# `Dict` from `copy`/`Dict(...)`.

"""
    _ArrayBlock

One array variable's contiguous run of state slots: `base` is the slot of the
`lo` corner, the block covers the box `lo:hi` (inclusive, per dimension), and
`strides` are its column-major strides (first index fastest).
"""
struct _ArrayBlock
    name::String
    base::Int
    lo::Vector{Int}
    hi::Vector{Int}
    strides::Vector{Int}
    len::Int
end

function _ArrayBlock(name::String, base::Int, lo::Vector{Int}, hi::Vector{Int})
    n = length(lo)
    strides = Vector{Int}(undef, n)
    s = 1
    for d in 1:n
        strides[d] = s
        s *= max(hi[d] - lo[d] + 1, 0)
    end
    return _ArrayBlock(name, base, lo, hi, strides, s)
end

"""
    _block_slot(b::_ArrayBlock, idx) -> Int

The slot of cell `idx` of block `b`, or 0 when `idx` has the wrong rank or lies
outside the block's box.
"""
@inline function _block_slot(b::_ArrayBlock, idx)
    length(idx) == length(b.lo) || return 0
    s = b.base
    @inbounds for d in eachindex(b.lo)
        v = Int(idx[d])
        (b.lo[d] <= v <= b.hi[d]) || return 0
        s += (v - b.lo[d]) * b.strides[d]
    end
    return s
end

"""
    _block_cell!(idx, b::_ArrayBlock, slot) -> idx

Decode `slot` (which must lie in `b`) into its multi-index, written into `idx`.
"""
@inline function _block_cell!(idx::AbstractVector{Int}, b::_ArrayBlock, slot::Int)
    r = slot - b.base
    @inbounds for d in length(b.lo):-1:1
        q, r = divrem(r, b.strides[d])
        idx[d] = b.lo[d] + q
    end
    return idx
end

_block_cell(b::_ArrayBlock, slot::Int) = _block_cell!(Vector{Int}(undef, length(b.lo)), b, slot)

# The block's box as a tuple of ranges, the `CartesianIndices` of its cells in
# slot order.
_block_ranges(b::_ArrayBlock) = ntuple(d -> b.lo[d]:b.hi[d], length(b.lo))

"""
    StateLayout <: AbstractDict{String,Int}

The flat state layout (see the file header): scalar names with their slots, and
one `_ArrayBlock` per array variable. Accessors: [`_layout_block`](@ref),
[`_layout_slot`](@ref), [`_layout_blocks`](@ref), [`_layout_scalar_names`](@ref),
[`_slot_key`](@ref), [`_layout_extend`](@ref). As an `AbstractDict` it answers
`get`/`getindex`/`haskey`/`length`/iteration over the element names.
"""
struct StateLayout <: AbstractDict{String,Int}
    scalar_names::Vector{String}          # slot order
    scalars::Dict{String,Int}
    blocks::Vector{_ArrayBlock}           # slot order, contiguous after the scalars
    block_of::Dict{String,Int}            # array name → position in `blocks`
    n::Int
end

"""
    StateLayout(scalar_names, arrays) -> StateLayout

`scalar_names` take slots `1:length(scalar_names)` in the given order; `arrays`
is a vector of `name => (lo, hi)` pairs laid out after them, in the given order.
"""
function StateLayout(scalar_names::Vector{String},
                     arrays::AbstractVector{<:Pair{String,<:Tuple{Vector{Int},Vector{Int}}}})
    scalars = Dict{String,Int}()
    sizehint!(scalars, length(scalar_names))
    for (i, s) in enumerate(scalar_names)
        scalars[s] = i
    end
    L = StateLayout(scalar_names, scalars, _ArrayBlock[], Dict{String,Int}(),
                    length(scalar_names))
    return _layout_extend(L, arrays)
end

"""
    _layout_extend(L, arrays) -> StateLayout

A new layout holding every slot of `L` plus one block per `name => (lo, hi)` of
`arrays`, appended after `L`'s last slot in the given order. `L` is unchanged
and shares its scalar table with the result.
"""
function _layout_extend(L::StateLayout,
                        arrays::AbstractVector{<:Pair{String,<:Tuple{Vector{Int},Vector{Int}}}})
    isempty(arrays) && return L
    blocks = copy(L.blocks)
    block_of = copy(L.block_of)
    n = L.n
    for (name, (lo, hi)) in arrays
        b = _ArrayBlock(name, n + 1, copy(lo), copy(hi))
        push!(blocks, b)
        block_of[name] = length(blocks)
        n += b.len
    end
    return StateLayout(L.scalar_names, L.scalars, blocks, block_of, n)
end

"""
    _layout_block(L, name) -> Union{_ArrayBlock,Nothing}

The block of array variable `name`, or `nothing` when `name` is not an array
variable of the layout.
"""
@inline function _layout_block(L::StateLayout, name::AbstractString)
    i = get(L.block_of, name, 0)
    return i == 0 ? nothing : @inbounds(L.blocks[i])
end

"""
    _layout_slot(L, name, idx) -> Int

The slot of cell `idx` of array variable `name`, or 0 when there is none; the
arithmetic form of `get(L, _cell_key(name, idx), 0)`.
"""
@inline function _layout_slot(L::StateLayout, name::AbstractString, idx)
    b = _layout_block(L, name)
    return b === nothing ? 0 : _block_slot(b, idx)
end

_layout_blocks(L::StateLayout) = L.blocks
_layout_scalar_names(L::StateLayout) = L.scalar_names

# The block holding `slot`, by bisection over the (slot-ordered) blocks; 0 for
# a scalar slot.
function _block_index_of_slot(L::StateLayout, slot::Int)
    bs = L.blocks
    lo, hi = 1, length(bs)
    (hi == 0 || slot < bs[1].base) && return 0
    while lo < hi
        mid = (lo + hi + 1) >>> 1
        if bs[mid].base <= slot
            lo = mid
        else
            hi = mid - 1
        end
    end
    return lo
end

"""
    _slot_key(L, slot) -> String

The element name of `slot`: the scalar's name, or `_cell_key(name, idx)` for an
array cell.
"""
function _slot_key(L::StateLayout, slot::Int)
    slot <= length(L.scalar_names) && return L.scalar_names[slot]
    b = L.blocks[_block_index_of_slot(L, slot)]
    return _cell_key(b.name, _block_cell(b, slot))
end

# Parse one decimal index written by `string(::Int)`: an optional `-`, then
# digits with no leading zero (and no `-0`). Returns `(value, ok)`.
@inline function _parse_cell_int(s::String, i::Int, j::Int)
    i > j && return (0, false)
    neg = false
    if codeunit(s, i) == UInt8('-')
        neg = true
        i += 1
        i > j && return (0, false)
    end
    (j - i + 1) > 18 && return (0, false)
    c1 = codeunit(s, i)
    (c1 == UInt8('0') && (j > i || neg)) && return (0, false)
    v = 0
    @inbounds for k in i:j
        c = codeunit(s, k)
        (UInt8('0') <= c <= UInt8('9')) || return (0, false)
        v = 10v + Int(c - UInt8('0'))
    end
    return (neg ? -v : v, true)
end

# The slot `key` names if it is exactly `_cell_key(name, idx)` for a cell of
# one of `L`'s blocks; 0 otherwise.
function _cell_key_slot(L::StateLayout, key::String)
    n = ncodeunits(key)
    (n >= 3 && codeunit(key, n) == UInt8(']')) || return 0
    isempty(L.blocks) && return 0
    # The name is everything before the LAST '[' (the index list holds none).
    p = 0
    @inbounds for k in (n - 1):-1:1
        if codeunit(key, k) == UInt8('[')
            p = k
            break
        end
    end
    p <= 1 && return 0
    b = _layout_block(L, SubString(key, 1, p - 1))
    b === nothing && return 0
    rank = length(b.lo)
    slot = b.base
    p + 1 == n && return rank == 0 ? slot : 0
    d = 0
    i = p + 1
    last = n - 1
    @inbounds while true
        # One index: [i, j]
        j = i
        while j <= last && codeunit(key, j) != UInt8(',')
            j += 1
        end
        d += 1
        d > rank && return 0
        v, ok = _parse_cell_int(key, i, j - 1)
        ok || return 0
        (b.lo[d] <= v <= b.hi[d]) || return 0
        slot += (v - b.lo[d]) * b.strides[d]
        j > last && break
        i = j + 1
    end
    return d == rank ? slot : 0
end

function Base.get(L::StateLayout, key::AbstractString, default)
    k = String(key)
    s = _cell_key_slot(L, k)
    s != 0 && return s
    return get(L.scalars, k, default)
end
Base.get(L::StateLayout, key, default) = default
function Base.getindex(L::StateLayout, key)
    s = get(L, key, 0)
    s == 0 && throw(KeyError(key))
    return s
end
Base.haskey(L::StateLayout, key) = get(L, key, 0) != 0
Base.length(L::StateLayout) = L.n
Base.isempty(L::StateLayout) = L.n == 0

function Base.iterate(L::StateLayout, slot::Int=1)
    slot > L.n && return nothing
    return (_slot_key(L, slot) => slot, slot + 1)
end

"""
    _vm_slot(var_map, name, idx) -> Int

The slot of cell `idx` of array `name` in any name → slot map: arithmetic on a
`StateLayout`, the `_cell_key` lookup otherwise. 0 when there is no such cell.
"""
@inline _vm_slot(L::StateLayout, name::AbstractString, idx) = _layout_slot(L, name, idx)
_vm_slot(var_map::AbstractDict, name::AbstractString, idx) =
    get(var_map, _cell_key(String(name), idx), 0)

# ---------------------------------------------------------------------------
# Discovered cell sets
# ---------------------------------------------------------------------------

"""
    _DiscoveredCells

The cells an array variable's equations and initial conditions name: a union
of boxes (each an inclusive `(lo, hi)` pair) and single points (flattened,
`rank` entries each). The state layout needs only its bounding box; the
field-`ic` fold visits the cells themselves, in lexicographic order
([`_foreach_cell_lex`](@ref)).
"""
mutable struct _DiscoveredCells
    rank::Int                                  # -1 until the first cell
    boxes::Vector{Tuple{Vector{Int},Vector{Int}}}
    points::Vector{Int}
    npoints::Int
end
_DiscoveredCells() = _DiscoveredCells(-1, Tuple{Vector{Int},Vector{Int}}[], Int[], 0)

Base.isempty(cs::_DiscoveredCells) = isempty(cs.boxes) && cs.npoints == 0

function _cellset_rank!(cs::_DiscoveredCells, r::Int, name::AbstractString)
    cs.rank == -1 && (cs.rank = r)
    cs.rank == r || throw(TreeWalkError("E_TREEWALK_UNSUPPORTED_SHAPE",
        "array variable '$(name)' is indexed with $(cs.rank) and with $(r) subscripts"))
    return nothing
end

function _cellset_push_point!(cs::_DiscoveredCells, idx::AbstractVector{<:Integer}, name)
    _cellset_rank!(cs, length(idx), name)
    append!(cs.points, idx)
    cs.npoints += 1
    return cs
end

# A non-empty box (`lo[d] <= hi[d]` on every dimension).
function _cellset_push_box!(cs::_DiscoveredCells, lo::Vector{Int}, hi::Vector{Int}, name)
    _cellset_rank!(cs, length(lo), name)
    push!(cs.boxes, (lo, hi))
    return cs
end

"""
    _cellset_bbox(cs) -> (lo, hi)

The bounding box of a non-empty cell set.
"""
function _cellset_bbox(cs::_DiscoveredCells)
    r = cs.rank
    lo = fill(typemax(Int), r)
    hi = fill(typemin(Int), r)
    for (blo, bhi) in cs.boxes
        @inbounds for d in 1:r
            lo[d] = min(lo[d], blo[d])
            hi[d] = max(hi[d], bhi[d])
        end
    end
    pts = cs.points
    @inbounds for k in 0:(cs.npoints - 1)
        for d in 1:r
            v = pts[k * r + d]
            lo[d] = min(lo[d], v)
            hi[d] = max(hi[d], v)
        end
    end
    return lo, hi
end

"""
    _foreach_cell_lex(f, cs)

Call `f(idx::Vector{Int})` once for every cell of `cs`, in lexicographic order
of the index tuples (the first index slowest), the order a sorted vector of
index vectors has. `idx` is reused between calls.
"""
function _foreach_cell_lex(f, cs::_DiscoveredCells)
    isempty(cs) && return nothing
    r = cs.rank
    lo, hi = _cellset_bbox(cs)
    full = any(b -> b[1] == lo && b[2] == hi, cs.boxes)
    mask = nothing
    if !full
        dims = ntuple(d -> hi[d] - lo[d] + 1, r)
        m = falses(dims)
        for (blo, bhi) in cs.boxes
            view(m, ntuple(d -> (blo[d] - lo[d] + 1):(bhi[d] - lo[d] + 1), r)...) .= true
        end
        pts = cs.points
        for k in 0:(cs.npoints - 1)
            m[ntuple(d -> pts[k * r + d] - lo[d] + 1, r)...] = true
        end
        mask = m
    end
    idx = Vector{Int}(undef, r)
    # Lexicographic = the first index slowest: walk the reversed box
    # column-major.
    for J in CartesianIndices(ntuple(d -> lo[r + 1 - d]:hi[r + 1 - d], r))
        @inbounds for d in 1:r
            idx[d] = J[r + 1 - d]
        end
        if mask !== nothing
            @inbounds mask[ntuple(d -> idx[d] - lo[d] + 1, r)...] || continue
        end
        f(idx)
    end
    return nothing
end

# ---------------------------------------------------------------------------
# Initial conditions with inline array profiles
# ---------------------------------------------------------------------------

"""
    _InlineICs <: AbstractDict{String,Any}

An `initial_conditions` map whose INLINE ARRAY entries (esm-spec §6.3) are held
as arrays and read as the per-cell keys `u[1]`, `u[2,3]`, … they stand for,
without a key per cell. `explicit` holds every other entry verbatim; a per-cell
key written there wins over the profile's value for that cell.
"""
struct _InlineICs <: AbstractDict{String,Any}
    explicit::Dict{String,Any}
    arrays::Vector{Pair{String,Array{Float64}}}
    array_of::Dict{String,Int}
    n::Int
end

function _InlineICs(explicit::Dict{String,Any}, arrays::Vector{Pair{String,Array{Float64}}})
    array_of = Dict{String,Int}(first(p) => i for (i, p) in enumerate(arrays))
    n = length(explicit)
    for (_, v) in arrays
        n += length(v)
    end
    # A per-cell key written explicitly shadows its profile cell.
    for k in keys(explicit)
        _inline_ic_cell(array_of, arrays, k) === nothing || (n -= 1)
    end
    return _InlineICs(explicit, arrays, array_of, n)
end

# `(array position, CartesianIndex)` when `key` is exactly `_cell_key(name, I)`
# for a cell `I` of one of the profiles; `nothing` otherwise.
function _inline_ic_cell(array_of::Dict{String,Int}, arrays, key::AbstractString)
    k = String(key)
    n = ncodeunits(k)
    (n >= 4 && codeunit(k, n) == UInt8(']')) || return nothing
    p = something(findlast(==('['), k), 0)
    p <= 1 && return nothing
    i = get(array_of, SubString(k, 1, p - 1), 0)
    i == 0 && return nothing
    v = arrays[i][2]
    parts = split(SubString(k, p + 1, n - 1), ',')
    length(parts) == ndims(v) || return nothing
    idx = Vector{Int}(undef, length(parts))
    for d in eachindex(parts)
        s = String(parts[d])
        x, ok = _parse_cell_int(s, 1, ncodeunits(s))
        (ok && 1 <= x <= size(v, d)) || return nothing
        idx[d] = x
    end
    return (i, CartesianIndex(Tuple(idx)))
end

function Base.get(ics::_InlineICs, key::AbstractString, default)
    v = get(ics.explicit, String(key), ics)
    v === ics || return v
    hit = _inline_ic_cell(ics.array_of, ics.arrays, key)
    hit === nothing && return default
    return ics.arrays[hit[1]][2][hit[2]]
end
Base.get(ics::_InlineICs, key, default) = get(ics.explicit, key, default)
function Base.getindex(ics::_InlineICs, key)
    v = get(ics, key, ics)
    v === ics && throw(KeyError(key))
    return v
end
Base.haskey(ics::_InlineICs, key) = get(ics, key, ics) !== ics
Base.length(ics::_InlineICs) = ics.n

# Iteration: the explicit entries, then each profile's cells (column-major) that
# no explicit key shadows.
function Base.iterate(ics::_InlineICs, state=(1, nothing, 0))
    phase, it, ai = state
    if phase == 1
        r = it === nothing ? iterate(ics.explicit) : iterate(ics.explicit, it)
        r !== nothing && return (r[1], (1, r[2], 0))
        phase, it, ai = 2, nothing, 1
    end
    while ai <= length(ics.arrays)
        name, v = ics.arrays[ai]
        C = CartesianIndices(v)
        r = it === nothing ? iterate(C) : iterate(C, it)
        if r === nothing
            ai += 1
            it = nothing
            continue
        end
        I, it = r
        key = _cell_key(name, collect(Int, Tuple(I)))
        haskey(ics.explicit, key) && continue
        return (key => v[I], (2, it, ai))
    end
    return nothing
end

"""
    _foreach_ic_cell(ics, point, box)

Visit the cells an `initial_conditions` map names: `point(name, idx)` for each
per-cell key (`_parse_cell_key`'s reading of it) and `box(name, lo, hi)` for
each whole inline profile.
"""
function _foreach_ic_cell(ics::AbstractDict, point, box)
    for (key, _) in ics
        parsed = _parse_cell_key(String(key))
        parsed === nothing && continue
        point(parsed[1], parsed[2])
    end
    return nothing
end
function _foreach_ic_cell(ics::_InlineICs, point, box)
    _foreach_ic_cell(ics.explicit, point, box)
    for (name, v) in ics.arrays
        isempty(v) && continue
        box(name, ones(Int, ndims(v)), collect(Int, size(v)))
    end
    return nothing
end

# Whether an `initial_conditions` map can name any array cell at all, so a
# per-cell "explicit value wins" test can be skipped for the common map that
# holds only whole-variable keys.
_ics_may_name_cells(ics::_InlineICs) = true
_ics_may_name_cells(ics::AbstractDict) =
    any(k -> (s = String(k); !isempty(s) && last(s) == ']'), keys(ics))

"""
    _apply_ics_by_slot!(set, L::StateLayout, ics)

Call `set(slot, value)` for every entry of `ics` that names a state element of
`L`, profiles before explicit keys so an explicit key wins.
"""
function _apply_ics_by_slot!(set, L::StateLayout, ics::AbstractDict)
    for (key, v) in ics
        key isa AbstractString || continue
        s = get(L, key, 0)
        s == 0 || set(s, v)
    end
    return nothing
end
function _apply_ics_by_slot!(set, L::StateLayout, ics::_InlineICs)
    for (name, v) in ics.arrays
        b = _layout_block(L, name)
        b === nothing && continue
        idx = Vector{Int}(undef, ndims(v))
        for I in CartesianIndices(v)
            for d in eachindex(idx)
                idx[d] = I[d]
            end
            s = _block_slot(b, idx)
            s == 0 || set(s, v[I])
        end
    end
    _apply_ics_by_slot!(set, L, ics.explicit)
    return nothing
end

"""
    _VarMapOverlay(extra, base) <: AbstractDict{String,Int}

A name → slot map that answers from `extra` first and then from `base`, the
way a copy of `base` with `extra`'s entries written in would, without copying
`base`. `extra` holds only sentinel names (they start with a NUL byte), never an
array cell's key, so a cell lookup goes straight to `base`.
"""
struct _VarMapOverlay{M<:AbstractDict{String,Int}} <: AbstractDict{String,Int}
    extra::Dict{String,Int}
    base::M
end

function Base.get(o::_VarMapOverlay, key, default)
    v = get(o.extra, key, nothing)
    return v === nothing ? get(o.base, key, default) : v
end
function Base.getindex(o::_VarMapOverlay, key)
    v = get(o.extra, key, nothing)
    return v === nothing ? o.base[key] : v
end
Base.haskey(o::_VarMapOverlay, key) = haskey(o.extra, key) || haskey(o.base, key)
Base.length(o::_VarMapOverlay) =
    length(o.base) + count(k -> !haskey(o.base, k), keys(o.extra))
function Base.iterate(o::_VarMapOverlay, state=(true, nothing))
    first_phase, it = state
    if first_phase
        r = it === nothing ? iterate(o.extra) : iterate(o.extra, it)
        r !== nothing && return (r[1], (true, r[2]))
        it = nothing
    end
    while true
        r = it === nothing ? iterate(o.base) : iterate(o.base, it)
        r === nothing && return nothing
        haskey(o.extra, first(r[1])) && (it = r[2]; continue)
        return (r[1], (false, r[2]))
    end
end
@inline _vm_slot(o::_VarMapOverlay, name::AbstractString, idx) = _vm_slot(o.base, name, idx)
