# The direct backend's forcing inputs can be smaller than the arrays the
# range compiler used to resolve global subscripts. Keep the rectangular
# footprint in global coordinates and remap each compiled read to the window.
struct _TileForcingWindow
    dims::Vector{Int}
    box::Vector{UnitRange{Int}}
end

_tile_window_length(w::_TileForcingWindow) = prod(length, w.box; init = 1)
_tile_window_length(::Nothing) = 0

function _tile_window_position(w::_TileForcingWindow, pos::Int)
    global_cell = CartesianIndices(Tuple(w.dims))[pos]
    slot, stride = 1, 1
    for (x, r) in zip(Tuple(global_cell), w.box)
        x in r || error("forcing position $pos lies outside the tile window")
        slot += (x - first(r)) * stride
        stride *= length(r)
    end
    return slot
end

function _tile_forcing_windows(f::_OopRHS, slots)
    host = forcing_buffers(f)
    positions = IdDict{Vector{Float64}, Union{Nothing, Set{Int}}}(
        arr => Set{Int}() for arr in values(host)
    )
    function record(arr, inds)
        found = positions[arr]
        found === nothing || union!(found, inds)
        return nothing
    end
    # Dynamic gather addresses and template bodies can contain subscripts that
    # a direct backend resolves later. Keep those source arrays whole until
    # their footprints are available to the range compiler.
    seen = _NodeMap{Bool}()
    function walk(n::_Node)
        haskey(seen, n) && return nothing
        seen[n] = true
        if n.kind === _NK_PARAM_GATHER
            record(n.payload, (n.idx,))
        elseif n.kind === _NK_LIVE_GATHER
            positions[(n.payload::_ConstGatherArray).flat] = nothing
        elseif n.kind === _NK_CALL
            site = n.payload::_CallSite
            for arg in site.arrays
                if arg.kind === :live && arg.data isa _ConstGatherArray
                    positions[arg.data.flat] = nothing
                end
            end
            walk(site.target.body)
        end
        foreach(walk, n.children)
        return nothing
    end
    function kernels(ks, plans)
        for (k, p) in zip(ks, plans)
            p.vectorizable || continue
            isempty(p.out_slots) && continue
            for (i, a) in enumerate(k.acc)
                if a.kind === _AK_ARR_FIXED
                    record(a.arr, (a.idx,))
                elseif a.kind === _AK_FORCING_BOX || a.kind === _AK_ARR_TBL_BOX
                    record(a.arr, p.forc[i])
                end
            end
            walk(k.spine)
            foreach(walk, k.cse.recipes)
            foreach(walk, k.cse.inv_recipes)
        end
        return nothing
    end
    rhs = f.rhs
    foreach(walk, rhs.cse_prelude)
    foreach(((_, n),) -> walk(n), rhs.rhs_list)
    kernels(rhs.acc_kernels, rhs.acc_plans)
    for lvl in rhs.mat_levels
        foreach(((_, n),) -> walk(n), _mat_scalars(lvl))
        kernels(_mat_kernels(lvl), _mat_plans(lvl))
    end
    return map(slots) do slot
        name = Symbol(slot.name)
        hasproperty(host, name) || return nothing
        found = positions[getproperty(host, name)]
        found === nothing && return _TileForcingWindow(copy(slot.shape), UnitRange{Int}[1:d for d in slot.shape])
        isempty(found) && return nothing
        grid = CartesianIndices(Tuple(slot.shape))
        lo, hi = fill(typemax(Int), length(slot.shape)), fill(typemin(Int), length(slot.shape))
        for pos in found
            cell = grid[pos]
            for d in eachindex(lo)
                lo[d] = min(lo[d], cell[d])
                hi[d] = max(hi[d], cell[d])
            end
        end
        return _TileForcingWindow(copy(slot.shape), UnitRange{Int}[l:h for (l, h) in zip(lo, hi)])
    end
end
