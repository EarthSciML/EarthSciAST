# Compare the instructions the direct backend consumes. The key uses tile-local
# state and forcing positions, and exact constants. It includes the ordered
# write sections as well as the equations, so translated members must agree
# on boundary rules, ghost masks, fill dependencies and output row ownership.
# Thrown when a tile cannot share its class key; caught by `_tile_class_key`
# itself, never seen outside it.
struct _UnsharedTile <: EarthSciASTError end

function _tile_class_key(slots, windows, tile, dec)
    f = tile.f!
    rhs = f.rhs
    host = forcing_buffers(f)
    sources = IdDict{Vector{Float64}, Tuple{String, Any}}()
    byname = Dict(s.name => w for (s, w) in zip(slots, windows))
    for (name, arr) in pairs(host)
        get!(sources, arr, (String(name), get(byname, String(name), nothing)))
    end
    function readkey(arr, pos)
        name, window = sources[arr]
        window === nothing && return (name, pos)
        localpos = pos isa Int ? _tile_window_position(window, pos) :
            Int[_tile_window_position(window, i) for i in pos]
        return (name, localpos)
    end

    # Value-number the structural descriptions so a shared subexpression
    # contributes one entry even when it is read from many sites.
    intern = Dict{Any, Int}()
    keys = Any[]
    value(key) = get!(intern, key) do
        push!(keys, key)
        length(keys)
    end

    function walker(access, inv, argument = nothing)
        seen = _NodeMap{Int}()
        function key(n::_Node)
            return get!(seen, n) do
                k = n.kind
                if k === _NK_ACCESS
                    return value((:access, access[n.idx]))
                elseif k === _NK_PARAM_GATHER
                    return value((:forcing, readkey(n.payload, n.idx)))
                elseif k === _NK_CACHED
                    return value((:cache, n.payload === inv, n.idx))
                elseif k === _NK_ARG && argument !== nothing
                    return argument(n.idx)
                elseif k === _NK_CALL
                    # The direct emitter inlines the body. Compare it with
                    # only the scalar arguments the body actually reads.
                    site = n.payload::_CallSite
                    isempty(site.target.arrslots) || throw(_UnsharedTile())
                    body = walker(access, inv, i -> key(n.children[i]))
                    return body(site.target.body)
                elseif k === _NK_LITERAL || k === _NK_STATE || k === _NK_PARAM || k === _NK_TIME ||
                        k === _NK_OP || k === _NK_CONTRACTION
                    n.payload === nothing || throw(_UnsharedTile())
                    return value((k, n.op, n.literal, n.idx, n.sym, map(key, n.children)))
                end
                throw(_UnsharedTile())
            end
        end
        return key
    end
    function scalar(entries)
        key = walker((), nothing)
        return [(s, key(n)) for (s, n) in entries]
    end
    function kernel(k, p)
        p.vectorizable || throw(_UnsharedTile())
        isempty(p.out_slots) && return nothing
        access = map(eachindex(k.acc)) do i
            a = k.acc[i]
            if a.kind === _AK_ARR_FIXED
                return (:forcing, readkey(a.arr, a.idx))
            elseif a.kind === _AK_FORCING_BOX || a.kind === _AK_ARR_TBL_BOX
                return (:forcing, readkey(a.arr, p.forc[i]))
            elseif a.kind === _AK_STATE_FIXED
                return (:state, a.idx)
            elseif a.kind === _AK_STATE_AFFINE || a.kind === _AK_STATE_TBL_BOX
                return (:gather, p.gathers[i], p.ghost[i])
            elseif a.kind === _AK_CONST_BOX || a.kind === _AK_LOOP_IDX
                return (:literal, p.consts[i])
            end
            throw(_UnsharedTile())
        end
        key = walker(access, k.cse.inv_scratch)
        return (p.out_slots, map(key, k.cse.inv_recipes), map(key, k.cse.recipes), key(k.spine))
    end
    scans(folds) = [(s.slots, s.len, s.oplus, s.zerobar, s.inclusive) for s in folds]
    function stage(entries, ks, plans, folds)
        return (scalar(entries), filter(!isnothing, map(kernel, ks, plans)), scans(folds))
    end
    try
        isempty(rhs.array_contractions) || return nothing
        levels = map(rhs.mat_levels) do lvl
            isempty(_mat_contractions(lvl)) || throw(_UnsharedTile())
            stage(_mat_scalars(lvl), _mat_kernels(lvl), _mat_plans(lvl), _mat_scans(lvl))
        end
        prelude = map(walker((), nothing), rhs.cse_prelude)
        output = stage(rhs.rhs_list, rhs.acc_kernels, rhs.acc_plans, rhs.scan_folds)
        sizes = [w === nothing ? nothing : length.(w.box) for w in windows]
        origins = Dict(a => o for ((a, _), o) in zip(dec.axes, tile.origin))
        for (face, axis) in dec.faces
            origins[face] = origins[axis]
        end
        function layout(blocks)
            return map(blocks) do b
                shift(ranges) = [(first(r) - get(origins, set, 0), length(r)) for (set, r) in zip(b.sets, ranges)]
                (b.name, b.sets, b.base, b.strides, shift(b.storage), shift(b.owned))
            end
        end
        return (
            rhs.n_states, rhs.n_total, tile.layout.n_u, tile.layout.n_aux,
            layout(tile.layout.u), layout(tile.layout.aux),
            tile.maps.u, tile.maps.aux, tile.maps.du, tile.coordinates, tile.reach,
            sizes, levels, prelude, output, keys,
        )
    catch err
        err isa _UnsharedTile || rethrow()
        return nothing
    end
end

struct _TileClass{R, W, K}
    owner::_ProgramMemo
    slots::Vector{ForcingSlot}   # the forcing signature `windows` follow
    representative::R
    windows::W
    kernel::K
end

"""
    tile_classes(op::RhsProgram, decomposition, tiles) -> Vector{Tile}

Group tiles with identical tile-local programs. Pass each input tile as a
`Tile` or a named tuple with `owned` and `storage` boxes. The returned targets
can be passed to [`operator_ir`](@ref) with the same selected operator. Tiles
whose lowered instructions cannot be compared safely form individual classes.

A class fragment takes a traced Int32 vector of the owned-box lower corners,
in decomposition axis order. Its input layouts are the representative tile's
layouts, translated to that origin. Use [`forcing_reach`](@ref) with the
actual origin to obtain its forcing windows.
"""
tile_classes(op::RhsProgram, dec::Decomposition, tiles) =
    _tile_classes(op, dec, tiles, nothing, forcing_slots(op))

function _tile_classes(op::RhsProgram, dec::Decomposition, tiles, kernel, slots)
    classes = Dict{Any, Int}()
    targets = Tile[]
    for box in tiles
        if box isa Tile
            d = box.decomposition
            (d.axes == dec.axes && d.faces == dec.faces) ||
                throw(ArgumentError("tile decomposition differs from the class decomposition"))
        end
        tile = _restrict(op, dec; box.owned, box.storage, form = :oop, relocate = true)
        windows = _tile_forcing_windows(tile.f!, slots)
        key = _tile_class_key(slots, windows, tile, dec)
        group = key === nothing ? 0 : get(classes, key, 0)
        if group == 0
            cls = _TileClass(op.memo, copy(slots), tile, Dict(Tuple(tile.origin) => windows), kernel)
            push!(targets, Tile(dec, box.owned, box.storage, cls))
            key === nothing || (classes[key] = length(targets))
        else
            targets[group].class.windows[Tuple(tile.origin)] = windows
        end
    end
    return targets
end
