include("range/tile_forcing.jl")

# Traceable backends consume the same out-of-place tree-walk build as the
# standalone XLA compiler. Range selection happens before that build.

"""
    RhsSelection(; writes = :all, terms = :all)

Writable state names and term origins passed to [`select`](@ref).
"""
Base.@kwdef struct RhsSelection{W, T}
    writes::W = :all
    terms::T = :all
end

"""A whole-domain target for [`operator_ir`](@ref)."""
struct Whole end

"""
    Tile(decomposition; owned, storage)

A tile target for [`operator_ir`](@ref), with the same boxes as [`restrict`](@ref).
"""
struct Tile{O, S, C}
    decomposition::Decomposition
    owned::O
    storage::S
    class::C
end
Tile(dec::Decomposition; owned, storage) = Tile(dec, owned, storage)
Tile(dec::Decomposition, owned, storage) = Tile(dec, owned, storage, nothing)

"""
    Lanes(kind, sets, capacity)

A fixed-capacity lane target for [`operator_ir`](@ref). The lane sets and kind
are those accepted by [`lanes`](@ref).
"""
struct Lanes
    kind::Symbol
    sets::Vector{String}
    capacity::Int
    function Lanes(kind::Symbol, sets, capacity::Integer)
        capacity > 0 || throw(ArgumentError("lane capacity must be positive"))
        names = String[String(s) for s in sets]
        allunique(names) || throw(ArgumentError("lane sets must be distinct"))
        return new(kind, names, Int(capacity))
    end
end

"""
    KernelOutputs(spec; out_eltype = nothing)

A single [`compile_kernels`](@ref) specification for a whole-domain output
fragment. Optionally cast the returned output blocks to `out_eltype`, one of
`Float16`, `Float32` or `Float64`.
"""
struct KernelOutputs{S}
    spec::S
    out_eltype::Union{Nothing, DataType}
    function KernelOutputs(spec::S, out_eltype) where {S}
        out_eltype === nothing || out_eltype in (Float16, Float32, Float64) ||
            throw(ArgumentError("kernel output type must be Float16, Float32 or Float64, got $out_eltype"))
        return new{S}(spec, out_eltype)
    end
end
KernelOutputs(spec; out_eltype = nothing) = KernelOutputs(spec, out_eltype)

"""Host-side tree-walk IR and input layouts for [`emit_fragment`](@ref)."""
struct OperatorIR{F, L, M, T, E}
    f::F
    layout::L
    maps::M
    target::T
    extra::E
    params::Vector{String}
    forcing::Vector{ForcingSlot}
end

"""
    operator_ir(prob; select = RhsSelection(), target = Whole(), outputs = :du)
    operator_ir(prog::RhsProgram; target = Whole())

Build the out-of-place tree-walk IR for a selected operator. Its state and
forcing tensors are described by [`ir_layout`](@ref), [`parameter_names`](@ref)
and [`forcing_slots`](@ref). With `outputs = KernelOutputs(spec)`, compile the
named kernel against the Problem, using its `u` and `z` inputs.
"""
function operator_ir(
        prob::EsmProblem; select::RhsSelection = RhsSelection(),
        target = Whole(), outputs = :du
    )
    if outputs isa KernelOutputs
        target isa Whole || throw(ArgumentError("kernel specifications require a Whole target"))
        (select.writes === :all && select.terms === :all) || throw(ArgumentError("kernel specifications define their own selection"))
        ks = compile_kernels(prob, [outputs.spec])
        k = only(values(ks.kernels))
        return _kernel_operator_ir(k, ks, outputs.out_eltype)
    end
    outputs === :du || throw(ArgumentError("outputs must be :du or a KernelOutputs"))
    op = rhs_program(prob)
    if select.writes !== :all || select.terms !== :all
        op = EarthSciAST.select(op; select.writes, select.terms)
    end
    return operator_ir(op; target)
end

function _operator_build(prog::RhsProgram)
    file, name, recorded = prog.front
    opts = _relower_options(recorded)
    opts.form = :oop
    f, _, _, _, _ = _with_compiler_plan(_plan(prog.compiler)) do
        _build_selected(file, name, opts)
    end
    return f
end

function operator_ir(prog::RhsProgram; target = Whole())
    params = parameter_names(prog)
    slots = copy(forcing_slots(prog))
    if target isa Whole
        return OperatorIR(_operator_build(prog), prog.layout, prog.maps, target, nothing, params, slots)
    elseif target isa Tile
        if target.class === nothing
            tile = _restrict(prog, target.decomposition; target.owned, target.storage, form = :oop)
            windows = _tile_forcing_windows(tile.f!, slots)
        else
            target.class.owner === prog.memo ||
                throw(ArgumentError("tile classes must be used with the operator that built them"))
            tile = target.class.representative
            windows = target.class.windows[Tuple(tile.origin)]
        end
        info = (; tile.reach, windows, tile.coordinates)
        return OperatorIR(tile.f!, tile.layout, tile.maps, target, info, params, slots)
    elseif target isa Lanes
        lane = _lanes(prog, target.kind, target.sets, target.capacity; form = :oop)
        maps = _lane_operator_maps(lane, target.capacity)
        return OperatorIR(
            lane.f!, lane.layout, maps, target, (lane.gathers, _lane_state_index(prog, lane.layout)),
            params, slots
        )
    end
    throw(ArgumentError("target must be Whole, Tile or Lanes"))
end

function _lane_operator_maps(lane, capacity)
    function pairs(plans)
        src, dst = Int[], Int[]
        for p in plans, e in eachindex(p.slot1), c in 1:capacity
            push!(src, (p.offset + e - 1) * capacity + c)
            push!(dst, p.slot1[e] + (c - 1) * p.lstride)
        end
        return src, dst
    end
    us, ud = pairs(lane.uplan)
    as, ad = pairs(lane.aplan)
    return _CopyMaps(_copy_runs(us, ud), _copy_runs(as, ad), _copy_runs(ud, us))
end

# Project a whole-domain writable state onto the same species-major layout as
# the lane lowerer. Each block is a sum of a per-cell offset and the fixed
# offsets of the non-lane elements.
function _lane_state_index(prog::RhsProgram, layout::LaneLayout)
    blocks = Dict(b.name => b for b in prog.layout.u)
    axes = layout.sets
    plans = map(layout.u) do lane
        b = blocks[lane.name]
        axis = [findfirst(==(s), b.sets) for s in axes]
        strides = Int32[b.strides[d] for d in axis]
        extents = Int32[length(b.storage[d]) for d in axis]
        dims = [findfirst(==(s), b.sets) for s in lane.sets]
        offsets = Int32[
            b.base + sum(((i[j] - 1) * b.strides[d] for (j, d) in enumerate(dims)); init = 0)
                for i in CartesianIndices(Tuple(lane.extents))
        ]
        return (strides, extents, vec(offsets))
    end
    return (prog.layout.n_u, plans)
end

function _kernel_operator_ir(k::Kernel, ks::KernelSet, out_eltype)
    prog = k.prog
    return OperatorIR(
        _operator_build(prog), (u = state_layout(ks), aux = z_layout(ks), out = kernel_layout(k)),
        prog.maps, Whole(), (k, prog.layout, out_eltype),
        parameter_names(ks.rhs), copy(forcing_slots(ks))
    )
end

"""The state, auxiliary and output layout of an [`operator_ir`](@ref) build."""
ir_layout(ir::OperatorIR) = ir.layout

"""
    halo(ir::OperatorIR)

State halo reach of the tile used to build `ir`. Keys and offsets follow
[`halo`](@ref).
"""
function halo(ir::OperatorIR)
    ir.target isa Tile || throw(ArgumentError("halo requires tile operator IR"))
    return copy(ir.extra.reach)
end

"""Scalar parameter names in dense input-vector order."""
parameter_names(p::RhsProgram) = String[s.name for s in parameters(p)]
parameter_names(ir::OperatorIR) = copy(ir.params)

forcing_slots(ir::OperatorIR) = copy(ir.forcing)

"""
    forcing_reach(ir::OperatorIR[, origin])

The rectangular global-coordinate forcing windows of a tile, in
[`forcing_slots`](@ref) order. Each entry is a vector of inclusive ranges, one
per source dimension, or `nothing` for an unused source. A source read at
addresses that cannot be bounded statically may require its whole extent.
Flatten each window column-major before passing it to a StableHLO fragment,
using an empty tensor for an unused source. For a tile class,
pass the actual owned-box origin to get that member's windows.
"""
function forcing_reach(ir::OperatorIR, origin = nothing)
    ir.target isa Tile || throw(ArgumentError("forcing_reach requires tile operator IR"))
    windows = if origin === nothing
        ir.extra.windows
    else
        ir.target.class === nothing && throw(ArgumentError("only tile classes accept an origin"))
        get(ir.target.class.windows, Tuple(origin)) do
            throw(ArgumentError("origin is not a member of this tile class"))
        end
    end
    return [w === nothing ? nothing : copy(w.box) for w in windows]
end

"""
    emit_fragment(ir; eltype = Float64, fold = :tree)

With Reactant loaded, create a host callable that emits a StableHLO fragment
into the caller's trace. Call it on traced arguments `(u, aux, p, t, forcing)`;
lane targets also take `cells` and output kernels with time-step inputs take
`dt`. See the compiled backend guide for layouts and precision.
"""
function emit_fragment end

"""
    gather_lanes(ir, u, cells)

Within a Reactant trace, gather the writable blocks of the whole-domain state
`u` into the lane layout of `ir`. Cell coordinates are 1-based and may repeat.
`cells` is a traced input, so its range cannot be checked: a lane whose cell
lies outside the domain reads an unspecified element of `u`.
"""
function gather_lanes end

"""
    scatter_lanes(ir, u, updates, cells)

Within a Reactant trace, return a fresh whole-domain state with the writable
lane blocks in `updates` replacing the cells selected by `cells`. The caller
supplies distinct cells. A lane whose cell lies outside the domain writes
nothing, so it cannot overwrite another variable's block.
"""
function scatter_lanes end

include("range/tile_classes.jl")
