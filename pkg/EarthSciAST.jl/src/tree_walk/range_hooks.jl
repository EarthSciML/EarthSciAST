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
_range_restrict_parts(
    ::Nothing, model, cls, parts, index_sets, const_arrays,
    param_arrays
) = parts

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
# of the domain it covers: a tile that shares its code with the operator's
# other tiles (range_restricted.jl, `_tile_shares_code`). Such a build gives up
# the optimizations that read a box's cells (kernel-class merging, the literal
# fold of a uniform table, row fusion and fission, a boundary slab's literal
# extent); every other build, the whole-domain program's included, keeps them.
_range_shared_code(::Nothing) = false

# The view the affine tier lowers one `faq` equation through so that a tile's
# kernels come out with the whole-domain structure every sharing tile emits
# (`_RangeAffineView`), with the equation's whole-domain ranges, or `nothing`.
# `var` is the equation's output variable and `clipped` the ranges of its loop
# subscripts, in subscript order.
_range_affine_view(::Nothing, var, clipped, var_map, array_var_info, xeq) = nothing

# ---- What a program's re-lowerings reuse from its own build ----
#
# A tile (or a halo) re-lowers its program's document, so without help its
# build would redo work whose answer depends only on the program, at the cost
# of the whole domain: converting a shaped parameter's data to a Float64 array,
# flattening a const array for a box read, and checking a predicate at every
# cell of a whole-domain box (the affine tier lowers a sharing tile over the
# whole-domain boxes). The program's own build records those answers here and
# every re-lowering of it reads them; the affine tier's box answers are also
# recorded by the tile that first needs one. Restrictions of one program may
# build on several threads at once, hence the lock.
struct _ProgramMemo
    lock::ReentrantLock
    arrays::IdDict{Any, Any}             # const data → its Float64 array
    flats::IdDict{Any, Vector{Float64}}  # a const array → its flat copy
    inline::Dict{Any, Any}               # a shaped parameter's broadcast value
    verdicts::Dict{Any, Any}             # an affine-tier box check → its answer
    # The first decomposition the program was asked about (`halo`,
    # `restrict`), and the tile over its whole domain under it, through which
    # a workspace made after that evaluates the program (`_decomposed_form`):
    # `missing` until a workspace asks, `nothing` where there is none.
    dec::Base.RefValue{Any}
    form::Base.RefValue{Any}
end
_ProgramMemo() = _ProgramMemo(
    ReentrantLock(), IdDict{Any, Any}(),
    IdDict{Any, Vector{Float64}}(), Dict{Any, Any}(),
    Dict{Any, Any}(), Ref{Any}(nothing), Ref{Any}(missing)
)

# The memo this build reads (`nothing` for none), and whether it is the
# program's own build, which records every answer.
_range_memo(::Nothing) = nothing
_range_memo_records(::Nothing) = false

# `memo.<table>[key]`, else `make()`, recorded where `record`.
function _memo_get(
        make, memo::Union{Nothing, _ProgramMemo}, table::Symbol, key,
        record::Bool
    )
    memo === nothing && return make()
    d = getfield(memo, table)
    got = lock(() -> get(d, key, nothing), memo.lock)
    got === nothing || return got
    v = make()
    record && lock(() -> get!(d, key, v), memo.lock)
    return v
end
_memo_get(make, spec, table::Symbol, key) =
    _memo_get(make, _range_memo(spec), table, key, _range_memo_records(spec))

# The cell entry `i` of descriptor table `acc` reads, when it is a fixed slot a
# tile build moved onto its layout (`_range_real_fixed!`): its variable (or
# `nothing`) and its virtual slot. `nothing` for every other slot, whose value
# names its cell.
_range_fixed_ident(::Nothing, acc, i) = nothing

# ---- Tiles that share their code ----
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
# emitted and runs zero iterations, and an equation the tile owns no cell of is
# kept over no cells (`_need_root!`, range_restricted.jl), so every tile emits
# the same code and carries what differs (bounds, bases, strides, slot tables)
# as run-time data. Whatever the emitter would decide from a box's cells it
# decides from the box's place in the program instead: the buffer a state read
# addresses from the variable it reads (`_range_real_repls!`), a fixed read's
# prologue local from the cell it reads (`_range_fixed_ident`), and a check
# over a box's cells from the box's recorded answer (`_box_holds`,
# stencil_affine.jl); what can only be decided from the cells is not done
# (`_range_shared_code`). A tile whose storage crosses a periodic seam lays
# out far-side blocks no other tile has, so it is lowered over its own cells.
# The whole-domain program is not a sharing build: it keeps every
# optimization, and compiles its own code.
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
# the box the tile runs, and the answers and data that depend only on the
# program come from its build (`_ProgramMemo`), so a tile's build grows with
# its own cells, never with the domain's.

# A layout answering every name the way its `L` does, which records, for each
# slot it hands out by name, the variable that slot belongs to: the virtual
# layout's blocks overlap past the tile's cells, so a slot alone does not say.
struct _RangeVMap <: AbstractDict{String, Int}
    L::StateLayout
    names::Dict{Int, String}
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
    avi::Dict{String, Tuple{Vector{Int}, Vector{Int}}}
    shift::Int
    real::StateLayout                 # the tile's own layout
    xeq::Any                          # the tier's cross-equation store for this view
    done::IdDict{Any, Nothing}         # descriptor tables already moved onto `real`
    # Per descriptor table moved onto `real`, the cell each of its fixed slots
    # reads (`_range_real_fixed!`); one store per tile build.
    fixed::IdDict{Any, Dict{Int, Any}}
end

# The virtual layout of `L` with each block spanning `whole[name]`, and its
# shift.
function _range_virtual_layout(L::StateLayout, whole::AbstractDict)
    ext = Tuple{_ArrayBlock, Vector{Int}, Vector{Int}, Int}[]
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
        push!(
            blocks, _ArrayBlock(
                b.name, base + shift, copy(wlo), copy(whi),
                copy(b.strides), span
            )
        )
        top = max(top, base + shift + span - 1)
    end
    scalars = Dict{String, Int}(k => v + shift for (k, v) in L.scalars)
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
#
# Each state-lane descriptor also carries, as its `idx`, a slot of the
# variable it reads, from which the emitter takes the buffer the read
# addresses (`_cg_side`, codegen_kernel.jl): a property of the variable, the
# same in every tile, where the slots a tile's box reads depend on the cells
# it runs, which may be none.
function _range_real_repls!(view::_RangeAffineView, lane_repl, recipes)
    for k in eachindex(lane_repl)
        rec = recipes[k]
        rec.kind == LANE_STATE || continue
        r = lane_repl[k]
        r isa _AccRepl || continue
        a = r.desc
        (a.kind === _AK_STATE_TBL_BOX || a.kind === _AK_STATE_AFFINE) || continue
        b = _vm_block(view.real, rec.var_name)
        conn, off = a.conn, a.off
        if a.kind === _AK_STATE_TBL_BOX && a.conn isa UnitRange{Int}
            if b !== nothing
                conn = b.base:(b.base + b.len - 1)
                off = a.off - (b.base + view.shift - first(a.conn))
            else
                # Cells laid out one by one: each is the tile's slot plus `shift`.
                conn = (first(a.conn) - view.shift):(last(a.conn) - view.shift)
                (first(conn) >= 1 && last(conn) <= view.real.n) ||
                    throw(
                    ErrorException(
                        "internal error: tile build: the slots " *
                            "$(a.conn) of '$(rec.var_name)' are not slots of the tile's layout"
                    )
                )
            end
        elseif a.kind === _AK_STATE_TBL_BOX
            tbl = a.conn::Vector{Int}
            if !haskey(view.done, tbl)
                @inbounds for j in eachindex(tbl)
                    v = tbl[j]
                    v == 0 || (tbl[j] = v - view.shift)
                end
                view.done[tbl] = nothing
            end
        end
        lane_repl[k] = _AccRepl(
            _AccDesc(
                a.kind, a.arr, conn, a.delta,
                _range_var_slot(view, rec, b), a.width, a.col,
                a.dim, a.s1, a.s2, a.s3, off, a.v, a.sx
            )
        )
    end
    return lane_repl
end

# A slot of the tile's layout holding a cell of the variable lane `rec` reads
# (its block's first), or 0 when there is none to name.
function _range_var_slot(view::_RangeAffineView, rec, b)
    b === nothing || return b.base
    blk = _state_slot_block(rec)
    blk === nothing && return 0
    s = first(blk) - view.shift
    return 1 <= s <= view.real.n ? s : 0
end

# Move every fixed slot of `kernels` onto the tile's layout: each kernel's own,
# and those of its sub-kernels (`K.subs` holds every sub-kernel reachable from
# `K`, nested ones included). A descriptor table shared by several kernels is
# moved once. Each moved slot's variable and virtual slot are recorded
# (`view.fixed`), which name the cell it reads where clamping a slot the tile
# does not store merges it with another (`_range_fixed_ident`).
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
                get!(() -> Dict{Int, Any}(), view.fixed, acc)[i] = (name, a.idx)
            end
        end
    end
    return kernels
end

# ---- What a program build records for its workspaces (src/rhs_program.jl) ----
#
# A program's workspace is a private instance of its compiled right-hand side.
# The instance needs, by identity, the arrays through which the build reads
# each live buffer (its `_PGatherArray`s) and every array generated code
# writes at run time besides `du` and the per-call state types (a build
# registers each as scratch where it allocates it). A build with no capture
# open records nothing.
struct _WsCapture
    pgathers::Vector{Any}
    scratch::IdDict{Any, Nothing}
end
_WsCapture() = _WsCapture(Any[], IdDict{Any, Nothing}())

const _WS_CAPTURE_KEY = :earthsci_ws_capture

_ws_capture_now() = get(task_local_storage(), _WS_CAPTURE_KEY, nothing)
_with_ws_capture(f, c::_WsCapture) = task_local_storage(f, _WS_CAPTURE_KEY, c)

function _ws_note_pgather!(pgather)
    c = _ws_capture_now()
    c === nothing || push!(c.pgathers, pgather)
    return nothing
end

# Mark `x`, an array generated code writes at run time, as per-instance scratch.
function _ws_scratch!(x)
    c = _ws_capture_now()
    c === nothing || (c.scratch[x] = nothing)
    return x
end
