import EarthSciAST: emit_fragment, gather_lanes, scatter_lanes

struct _DEParamVector
    values::_DEVal
    slots::Dict{Symbol, Int}
end

function _de_vector_param(ctx::_DECtx, p::_DEParamVector, sym::Symbol)
    slot = get(p.slots, sym, 0)
    slot > 0 || return _de_refuse(ctx, "the parameter `$sym`", "it has no position in the parameter vector.")
    _de_tally!(ctx, :param_input)
    return _de_slice(ctx, p.values, slot, slot; why = :parameter)
end

struct _StableHLOFragment{T, I, B} <: Function
    ir::I
    buffers::B
    hostkeys::Vector{Vector{Float64}}
    parameter_slots::Dict{Symbol, Int}
    options::DirectEmitOptions
    tree_fold::Bool
end

Base.show(io::IO, f::_StableHLOFragment{T}) where {T} =
    print(io, "StableHLO fragment (", nameof(typeof(f.ir.target)), ", ", T, ")")

# This callable's fields are host IR and metadata. Treat the whole callable as
# a leaf in every tracing mode, including while-region discovery.
function Reactant.make_tracer(
        seen, @nospecialize(prev::Union{_StableHLOFragment, _E.OperatorIR}), @nospecialize(path), mode; kwargs...
    )
    if mode == Reactant.TracedToTypes
        push!(path, prev)
        return nothing
    end
    return prev
end

function emit_fragment(ir::_E.OperatorIR; eltype::Type = Float64, fold::Symbol = :tree)
    eltype in (Float32, Float64) || throw(ArgumentError("fragment eltype must be Float32 or Float64"))
    fold in (:tree, :reduce) || throw(ArgumentError("fragment fold must be :tree or :reduce"))
    host = _E.forcing_buffers(ir.f)
    buffers = map(keys(host)) do name
        slot = findfirst(s -> s.name == String(name), ir.forcing)
        slot !== nothing && return slot
        return _fragment_lane_buffer(ir, String(name))
    end
    names = Dict(Symbol(n) => i for (i, n) in enumerate(ir.params))
    return _StableHLOFragment{eltype, typeof(ir), typeof(buffers)}(
        ir, buffers, Vector{Float64}[values(host)...], names,
        DirectEmitOptions(), fold === :tree
    )
end

# Use the range lowerer's pre-gather descriptions. Affine integer index math
# stays in Int32 even when the model evaluates in Float32.
struct _LaneBuffer
    source::Int
    data::Any
    forms::Vector{_E._AffineForm}
    rows::Vector{Int}
    dims::Vector{Int}
    boundary::Vector{Symbol}
end

function _fragment_lane_buffer(ir, name)
    target = ir.target
    target isa _E.Lanes || throw(ArgumentError("unexpected fragment forcing buffer '$name'"))
    row = findfirst(s -> name == "__lane_" * s, target.sets)
    row !== nothing && return (:row, row)
    startswith(name, "__lane_in_") || throw(ArgumentError("unexpected lane buffer '$name'"))
    g = ir.extra[1][parse(Int, name[(length("__lane_in_") + 1):end])]
    vars = first.(g.vars)
    forms = _E._AffineForm[]
    for sub in g.subs
        form = _E._affine_form(sub, vars)
        form === nothing && _de_refuse_at(
            "lane fragment", "a nonaffine subscript of '$(g.name)'",
            "dynamic lane gathers currently require affine subscripts."
        )
        push!(forms, form)
    end
    slot = something(findfirst(s -> s.name == g.name, ir.forcing), 0)
    boundary = Symbol[_E._const_dim_boundary(g.src, d) for d in eachindex(g.dims)]
    return _LaneBuffer(slot, g.src, forms, last.(g.vars), g.dims, boundary)
end

function _fragment_lane_offsets(cells, plan::_LaneBuffer)
    offsets = zeros(Int32, size(cells, 2))
    valid = trues(size(cells, 2))
    stride = 1
    for d in eachindex(plan.dims)
        form = plan.forms[d]
        idx = fill(Int32(form.c0 - 1), size(cells, 2))
        for (c, row) in zip(form.c, plan.rows)
            iszero(c) || (idx = idx .+ Int32(c) .* cells[row, :])
        end
        n = Int32(plan.dims[d])
        if plan.boundary[d] === :periodic
            idx = mod.(idx, n)
        elseif plan.boundary[d] === :clamp
            idx = clamp.(idx, Int32(0), n - Int32(1))
        else
            valid = valid .& (idx .>= Int32(0)) .& (idx .< n)
            idx = clamp.(idx, Int32(0), n - Int32(1))
        end
        offsets = offsets .+ Int32(stride) .* idx
        stride *= n
    end
    return offsets, valid
end

_fragment_cell_row(cells, row) = cells[row, :]

function _fragment_buffer(::Type{T}, spec::Int, forcing, cells) where {T}
    return forcing[spec]
end

function _fragment_buffer(::Type{T}, spec::Tuple{Symbol, Int}, forcing, cells) where {T}
    row = Reactant.call_with_reactant(_fragment_cell_row, cells, spec[2])
    return _de_traced(_de_cast(_de_untraced(row), Int32, T), T)
end

function _fragment_buffer(::Type{T}, spec::_LaneBuffer, forcing, cells) where {T}
    off, valid = Reactant.call_with_reactant(_fragment_lane_offsets, cells, spec)
    src = spec.source == 0 ? Reactant.promote_to(TracedRArray{T, 1}, T.(vec(spec.data))) : forcing[spec.source]
    dn = _MLIR.API.stablehloGatherDimensionNumbersGet(
        _MLIR.IR.current_context(), 0, Int64[], 1, Int64[0], 0, Int64[],
        0, Int64[], 1, Int64[0], 1
    )
    L = length(off)
    S = _de_eltype(src)
    op = _hlo.gather(
        src.mlir_data, off.mlir_data; result = _de_ty(L, S), dimension_numbers = dn,
        slice_sizes = _MLIR.IR.DenseArrayAttribute(Int64[1]), indices_are_sorted = false,
        location = _de_loc()
    )
    out = _de_cast(_DEVal(_de_res(op), L), S, T)
    zero_val = _hlo.constant(;
        output = _de_ty(L, T), value = _MLIR.IR.DenseElementsAttribute(zeros(T, L)),
        location = _de_loc()
    )
    masked = _hlo.select(valid.mlir_data, out.v, _de_res(zero_val); result = _de_ty(L, T), location = _de_loc())
    return _de_traced(_DEVal(_de_res(masked), L), T)
end

function _fragment_check(forcing, ir)
    length(forcing) == length(ir.forcing) ||
        throw(DimensionMismatch("forcing must follow forcing_slots(ir)"))
    for (buf, slot) in zip(forcing, ir.forcing)
        buf isa Union{TracedRArray{Float32, 1}, TracedRArray{Float64, 1}} ||
            throw(ArgumentError("forcing slot '$(slot.name)' requires a traced flat floating-point tensor"))
        length(buf) == prod(slot.shape; init = 1) ||
            throw(DimensionMismatch("forcing slot '$(slot.name)' has the wrong length"))
    end
    return nothing
end

function _fragment_context(f::_StableHLOFragment{T}, p, t, forcing, cells, param_slots) where {T}
    rhs = f.ir.f.rhs
    _fragment_check(forcing, f.ir)
    inputs = map(spec -> _fragment_buffer(T, spec, forcing, cells), f.buffers)
    params = _DEParamVector(_de_cast(_de_untraced(p), Float64, T), param_slots)
    return _DECtx(
        rhs.n_states, rhs.n_total, params, _de_cast(_de_time(t), Float64, T),
        nothing, inputs, f.hostkeys, Dict{Int, String}(), f.options;
        precision = T, tree_fold = f.tree_fold
    )
end

function _fragment_copy!(dst::_DEMap, src::_DEVal, runs)
    for r in runs, i in 0:(r.len - 1)
        dst.m[r.dst + i] = (src, r.src + i)
    end
    return nothing
end

function _fragment_output(ctx, internal::_DEMap, maps, width)
    width == 0 && return _de_arrconst(ctx, Float64[])
    out = _DEMap(width)
    for r in maps, i in 0:(r.len - 1)
        out.m[r.dst + i] = internal.m[r.src + i]
    end
    return _de_assemble(ctx, out, width)
end

function _fragment_rhs(f::_StableHLOFragment{T}, u, aux, p, t, forcing, cells) where {T}
    ir = f.ir
    L = ir.target isa _E.Lanes ? ir.target.capacity : 1
    width = L * ir.layout.n_u
    length(u) == width || throw(DimensionMismatch("u has the wrong length for the fragment layout"))
    length(aux) == L * ir.layout.n_aux || throw(DimensionMismatch("aux has the wrong length for the fragment layout"))
    length(p) == length(ir.params) || throw(DimensionMismatch("p must follow parameter_names(ir)"))
    ctx = _fragment_context(f, p, t, forcing, cells, f.parameter_slots)
    _fragment_copy!(ctx.ue, _de_untraced(u), ir.maps.u)
    _fragment_copy!(ctx.ue, _de_untraced(aux), ir.maps.aux)
    du = _de_emit!(ctx, ir.f.rhs)
    return _de_traced(_fragment_output(ctx, du, ir.maps.du, width), T)
end

function (f::_StableHLOFragment{T})(
        u::TracedRArray{T, 1}, aux::TracedRArray{T, 1}, p::TracedRArray{Float64, 1},
        t::TracedRNumber{Float64}, forcing::Tuple
    ) where {T}
    f.ir.target isa _E.Lanes && throw(ArgumentError("lane fragments require a cells tensor"))
    if f.ir.target isa _E.Whole && f.ir.extra !== nothing
        return _fragment_kernel(f, u, aux, p, t, forcing, nothing)
    end
    return _fragment_rhs(f, u, aux, p, t, forcing, nothing)
end

function (f::_StableHLOFragment{T})(
        u::TracedRArray{T, 1}, aux::TracedRArray{T, 1}, p::TracedRArray{Float64, 1},
        t::TracedRNumber{Float64}, forcing::Tuple, cells::TracedRArray{Int32, 2}
    ) where {T}
    target = f.ir.target
    target isa _E.Lanes || throw(ArgumentError("only lane fragments take a cells tensor"))
    size(cells) == (length(target.sets), target.capacity) ||
        throw(DimensionMismatch("cells must have one row per lane set and one column per lane"))
    return _fragment_rhs(f, u, aux, p, t, forcing, cells)
end

function (f::_StableHLOFragment{T})(
        u::TracedRArray{T, 1}, aux::TracedRArray{T, 1}, p::TracedRArray{Float64, 1},
        t::TracedRNumber{Float64}, forcing::Tuple, dt::TracedRNumber{Float64}
    ) where {T}
    f.ir.target isa _E.Whole && f.ir.extra !== nothing ||
        throw(ArgumentError("only output kernels take a dt argument"))
    return _fragment_kernel(f, u, aux, p, t, forcing, dt)
end

function _fragment_kernel(f::_StableHLOFragment{T}, u, aux, p, t, forcing, dt) where {T}
    ir = f.ir
    k, layout, output_type = ir.extra
    length(u) == k.n_u || throw(DimensionMismatch("u has the wrong length for the kernel"))
    length(aux) == k.n_z || throw(DimensionMismatch("aux has the wrong length for the kernel"))
    length(p) == k.n_p || throw(DimensionMismatch("p must follow parameter_names(ir)"))
    params = Dict(Symbol(s.name) => i for (s, i) in zip(_E.parameters(k.prog), k.p_map))
    ctx = _fragment_context(f, p, t, forcing, nothing, params)
    umap = _de_untraced(u)
    zmap = _de_untraced(aux)
    amap = _DEMap(layout.n_aux)
    for (source, s, d, n) in k.aux_plan
        if source == 3
            dt === nothing && throw(ArgumentError("the kernel requires a traced dt argument"))
            val = _de_cast(_de_untraced(dt), Float64, T)
            _de_write!(ctx, amap, collect(d:(d + n - 1)), val)
        elseif source != 0
            _fragment_copy!(amap, source == 1 ? umap : zmap, (_E._CopyRun(s, d, n),))
        end
    end
    k.direct && _fragment_copy!(ctx.ue, umap, ir.maps.u)
    for r in ir.maps.aux, i in 0:(r.len - 1)
        ctx.ue.m[r.dst + i] = amap.m[r.src + i]
    end
    du = _de_emit!(ctx, ir.f.rhs)
    state = _fragment_output(ctx, du, ir.maps.du, layout.n_u)
    out = _DEMap(k.out_len)
    k.map && _fragment_copy!(out, umap, (_E._CopyRun(1, 1, k.n_u),))
    runs = k.direct ? (_E._CopyRun(1, 1, k.n_u),) :
        (_E._CopyRun(s, d, n) for (s, d, n) in k.out_plan)
    _fragment_copy!(out, state, runs)
    S = something(output_type, T)
    return map(Tuple(k.layout)) do block
        n = prod(block.shape; init = 1)
        val = _de_emit_runs(ctx, out.m[block.offset:(block.offset + n - 1)])
        _de_traced(_de_cast(val, T, S), S)
    end
end


function _fragment_lane_positions(cells, plans)
    capacity = size(cells, 2)
    positions = map(plans) do (strides, offsets)
        base = zeros(Int32, capacity)
        for (row, stride) in enumerate(strides)
            base = base .+ (cells[row, :] .- Int32(1)) .* stride
        end
        return vec(reshape(base, capacity, 1) .+ reshape(offsets, 1, length(offsets)))
    end
    return reduce(vcat, positions)
end

function _fragment_lane_indices(ir, u, cells)
    target = ir.target
    target isa _E.Lanes || throw(ArgumentError("lane assembly requires Lanes operator IR"))
    size(cells) == (length(target.sets), target.capacity) ||
        throw(DimensionMismatch("cells must follow the lane layout"))
    width, plans = ir.extra[2]
    length(u) == width || throw(DimensionMismatch("u must follow the whole-domain writable layout"))
    return Reactant.call_with_reactant(_fragment_lane_positions, cells, plans)
end

_fragment_gather_state(u, indices) = u[indices]
_fragment_scatter_state(u, updates, indices) = Reactant.Ops.scatter_setindex(
    u, Reactant.Ops.reshape(indices, length(indices), 1), updates
)

function gather_lanes(
        ir::_E.OperatorIR, u::TracedRArray{T, 1}, cells::TracedRArray{Int32, 2}
    ) where {T}
    indices = _fragment_lane_indices(ir, u, cells)
    return Reactant.call_with_reactant(_fragment_gather_state, u, indices)
end

function scatter_lanes(
        ir::_E.OperatorIR, u::TracedRArray{T, 1}, updates::TracedRArray{T, 1},
        cells::TracedRArray{Int32, 2}
    ) where {T}
    indices = _fragment_lane_indices(ir, u, cells)
    length(indices) == length(updates) || throw(DimensionMismatch("updates must follow the lane layout"))
    return Reactant.call_with_reactant(_fragment_scatter_state, u, updates, indices)
end
