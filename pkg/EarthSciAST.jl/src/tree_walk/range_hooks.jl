# ========================================================================
# tree_walk/range_hooks.jl — the build's seams for a range-restricted
# program (API_SPEC §5.8, `restrict` / `lanes`; src/range_restricted.jl).
#
# A restricted build runs the ordinary pipeline under a task-local range spec.
# Without one (every other build) each hook below is the identity, so the
# build is unchanged.
# ========================================================================

const _RANGE_SPEC_KEY = :earthsci_range_spec

_range_spec_now() = get(task_local_storage(), _RANGE_SPEC_KEY, nothing)
_with_range_spec(f, spec) = task_local_storage(f, _RANGE_SPEC_KEY, spec)

# The equation stream after the ODE partition, clipped to the needed cells.
_range_restrict_parts(::Nothing, model, cls, parts, index_sets, const_arrays,
                      param_arrays) = parts

# Each array state's block, rebased onto the cells the program stores.
_range_state_boxes!(::Nothing, array_var_info) = array_var_info

# A materialized array observed's buffer block over its full extent `dims`, or
# `nothing` to leave the observed inlined.
_range_observed_box(::Nothing, name, dims) = (ones(Int, length(dims)), copy(dims))

# The fill equations of a materialized array observed over its block `box`.
_range_fill_equations(::Nothing, name, def, dims, box) =
    _materialized_fill_equations(name, def, dims)

# The build's forcing epoch (tree_walk/cadence_stamp.jl), which a lane
# program bumps when it rewrites its live lane buffers.
_range_build_epoch(::Nothing, epoch) = nothing

# The document and build keywords the AbstractDict front door hands the typed
# build, recorded so a restriction re-lowers without re-reading the document.
_range_front_door_done(::Nothing, file, model_name, kwd) = nothing

# Whether this build emits the code of every kernel the same way whatever part
# of the domain it covers: the whole-domain program of a range-restrictable
# operator and each of its tiles, which then share their compiled code.
_range_shared_code(::Nothing) = false

# The view the affine tier lowers one `faq` equation through so that a tile's
# kernels come out with the whole-domain program's structure
# (`_RangeAffineView`), with the equation's whole-domain ranges, or `nothing`.
# `var` is the equation's output variable and `clipped` the ranges of its loop
# subscripts, in subscript order.
_range_affine_view(::Nothing, var, clipped, var_map, array_var_info, xeq) = nothing

# ---- Tiles that share the whole-domain program's code ----
#
# A tile restricts an operator to its owned cells, so the build sees each
# equation over a smaller range and lays each variable out over the tile's
# storage. Lowered as is, the affine tier would cut that smaller range into
# boxes of its own, drop the boxes the tile does not own, and derive every box
# from the cells it keeps: the emitted program would differ from tile to tile,
# and each would pay its own compile.
#
# Instead the tier lowers the equation over its WHOLE-DOMAIN ranges, against a
# virtual layout in which every variable spans its whole-domain extents with
# the tile's own strides (`_RangeVMap`), so it cuts the same boxes and derives
# every box exactly as the whole-domain build does. Each kernel then runs only
# the cells of its box the tile owns, which may be none: an empty box is still
# emitted and runs zero iterations, so every tile emits the same code and
# carries what differs (bounds, bases, strides, slot tables) as run-time data.
#
# The virtual layout places each variable's block where the tile's layout puts
# it, extended over the whole domain, then shifted by `shift` slots so that no
# cell's slot is below 1 (slot 0 is the build's "no such cell"). Offsets
# between slots are the tile's, so every derived stride and offset is the
# tile's; what holds an absolute slot is shifted back onto the tile's layout:
# a box's base slot, each slot table and each fixed slot. A fixed slot of a
# cell the tile does not store (one only an empty box reads) is moved onto a
# slot of the same variable's tile block, which keeps its buffer and is never
# read. A per-box table (a slot table, a value table) covers only the cells of
# the box the tile runs, so a tile's build grows with its own cells, never with
# the domain's.

# A layout answering every name the way its `L` does, which records, for each
# slot it hands out by name, the variable that slot belongs to: the virtual
# layout's blocks overlap past the tile's cells, so a slot alone does not say.
struct _RangeVMap <: AbstractDict{String,Int}
    L::StateLayout
    names::Dict{Int,String}
end

function Base.get(m::_RangeVMap, key::AbstractString, default)
    s = get(m.L, key, 0)
    s == 0 && return default
    k = String(key)
    i = findlast('[', k)
    n = i === nothing ? k : k[1:prevind(k, i)]
    prev = get(m.names, s, nothing)
    prev === nothing ? (m.names[s] = n) : (prev == n || (m.names[s] = ""))
    return s
end
Base.get(m::_RangeVMap, key, default) = default
function Base.getindex(m::_RangeVMap, key)
    s = get(m, key, 0)
    s == 0 && throw(KeyError(key))
    return s
end
Base.haskey(m::_RangeVMap, key) = get(m.L, key, 0) != 0
Base.length(m::_RangeVMap) = length(m.L)
Base.iterate(m::_RangeVMap, st...) = iterate(m.L, st...)
@inline _vm_slot(m::_RangeVMap, name::AbstractString, idx) = _vm_slot(m.L, name, idx)
_vm_block(m::_RangeVMap, name::AbstractString) = _vm_block(m.L, name)

struct _RangeAffineView
    vm::_RangeVMap
    # Every variable's whole-domain extents, the bounds a read is checked
    # against (a read outside them is a ghost, as in the whole-domain build).
    avi::Dict{String,Tuple{Vector{Int},Vector{Int}}}
    shift::Int
    real::StateLayout                 # the tile's own layout
    xeq::Any                          # the tier's cross-equation store for this view
    done::IdDict{Any,Nothing}         # descriptor tables already moved onto `real`
end

# The virtual layout of `L` with each block spanning `whole[name]`, and its
# shift.
function _range_virtual_layout(L::StateLayout, whole::AbstractDict)
    ext = Tuple{_ArrayBlock,Vector{Int},Vector{Int},Int}[]
    lowest = 1
    for b in L.blocks
        wlo, whi = get(whole, b.name, (b.lo, b.hi))
        base = b.base
        @inbounds for d in eachindex(b.lo)
            base += (wlo[d] - b.lo[d]) * b.strides[d]
        end
        push!(ext, (b, wlo, whi, base))
        lowest = min(lowest, base)
    end
    shift = 1 - lowest
    blocks = _ArrayBlock[]
    top = L.n + shift
    for (b, wlo, whi, base) in ext
        span = 1
        @inbounds for d in eachindex(wlo)
            span += (whi[d] - wlo[d]) * b.strides[d]
        end
        push!(blocks, _ArrayBlock(b.name, base + shift, copy(wlo), copy(whi),
                                  copy(b.strides), span))
        top = max(top, base + shift + span - 1)
    end
    scalars = Dict{String,Int}(k => v + shift for (k, v) in L.scalars)
    V = StateLayout(copy(L.scalar_names), scalars, blocks, copy(L.block_of), top)
    return V, shift
end

# The slot of the tile's layout that the virtual slot `v` of variable `name`
# stands for: the same cell's slot when the tile stores it, a slot of the same
# block otherwise (`nothing` when the variable is not known).
function _range_real_slot(view::_RangeAffineView, name, v::Int)
    r = v - view.shift
    name === nothing && return clamp(r, 1, view.real.n)
    b = _vm_block(view.real, name)
    b === nothing && return clamp(r, 1, view.real.n)
    return clamp(r, b.base, b.base + b.len - 1)
end

# Move a box's state-lane lowerings onto the tile's layout (see the section
# note): a slot table's entries, and the identity run of a lane read on its own
# grid, which becomes the run of the variable's tile block. A tile's slot
# table covers only the cells of the box it runs (`_box_table_addr`,
# stencil_affine.jl), which it stores, and every other entry is 0.
function _range_real_repls!(view::_RangeAffineView, lane_repl, recipes)
    for k in eachindex(lane_repl)
        rec = recipes[k]
        rec.kind == LANE_STATE || continue
        r = lane_repl[k]
        r isa _AccRepl || continue
        a = r.desc
        a.kind === _AK_STATE_TBL_BOX || continue
        b = _vm_block(view.real, rec.var_name)
        if a.conn isa UnitRange{Int}
            b === nothing && continue
            lo0 = first(a.conn)
            conn = b.base:(b.base + b.len - 1)
            off = a.off - (b.base + view.shift - lo0)
            lane_repl[k] = _AccRepl(_AccDesc(a.kind, a.arr, conn, a.delta, a.idx, a.width,
                                             a.col, a.dim, a.s1, a.s2, a.s3, off, a.v, a.sx))
        else
            tbl = a.conn::Vector{Int}
            haskey(view.done, tbl) && continue
            @inbounds for j in eachindex(tbl)
                v = tbl[j]
                v == 0 || (tbl[j] = v - view.shift)
            end
            view.done[tbl] = nothing
        end
    end
    return lane_repl
end

# Move every fixed slot of `kernels` (and of their sub-kernels) onto the tile's
# layout. A descriptor table shared by several kernels is moved once.
function _range_real_fixed!(view::_RangeAffineView, kernels)
    for K in kernels
        for acc in Iterators.flatten(((K.acc,), (S.acc for S in K.subs)))
            haskey(view.done, acc) && continue
            view.done[acc] = nothing
            for i in eachindex(acc)
                a = acc[i]
                a.kind === _AK_STATE_FIXED || continue
                name = get(view.vm.names, a.idx, nothing)
                name == "" && (name = nothing)
                acc[i] = _AccStateFixed(_range_real_slot(view, name, a.idx))
            end
        end
    end
    return kernels
end
