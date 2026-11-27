import EarthSciAST: emit_fragment, gather_lanes, scatter_lanes

_E._kernel_output_eltype(::Type{Reactant.BFloat16}) = true

struct _DEParamVector
    values::_DEVal
    slots::Dict{Symbol, Int}
end

function _de_vector_param(ctx::_DECtx, p::_DEParamVector, sym::Symbol)
    slot = get(p.slots, sym, 0)
    slot > 0 || return _de_refuse(ctx, "the parameter `$sym`", "it has no position in the parameter vector.")
    ctx.keys64 === nothing || !haskey(ctx.keys64.slots, sym) || _de_refuse(
        ctx, "the binary64 key `$sym` outside an exact comparison",
        "it declares Float64 and is read only as an `==`/`!=` operand, which a binary32 " *
            "fragment evaluates exactly only when the other operand is a parameter or a " *
            "literal (esm-spec §11.3.3 P8); here the key reaches binary32 arithmetic."
    )
    _de_tally!(ctx, :param_input)
    return _de_slice(ctx, p.values, slot, slot; why = :parameter)
end

# The declared-binary64 scalar parameters a binary32 fragment reads only as
# `==`/`!=` operands (`OperatorIR.binary64_keys`): such a comparison runs on the
# binary64 input and supplies an exact flag to the binary32 arithmetic
# (esm-spec §11.3.3 P8). `p` is the parameter vector as passed.
struct _DEExactKeys
    p::_DEVal
    slots::Dict{Symbol, Int}
end

# `nd` as an exact comparison of a binary64 key, or `nothing` when it compares
# none. `nd` is a scalar or a lane-batched node.
function _de_exact_compare(ctx::_DECtx, nd)
    keys = ctx.keys64
    keys === nothing && return nothing
    (nd.op === :(==) || nd.op === :!=) || return nothing
    any(ch -> ch.kind === _E._NK_PARAM && haskey(keys.slots, ch.sym), nd.children) || return nothing
    length(nd.children) == 2 || _de_refuse(
        ctx, "`$(nd.op)` with $(length(nd.children)) arguments", "a comparison takes two."
    )
    operands = map(nd.children) do ch
        if ch.kind === _E._NK_PARAM && haskey(keys.slots, ch.sym)
            slot = keys.slots[ch.sym]
            _de_tally!(ctx, :param_input)
            return _de_res(
                _hlo.slice(
                    keys.p.v; result_0 = _de_ty(1, Float64),
                    start_indices = _MLIR.IR.DenseArrayAttribute(Int64[slot - 1]),
                    limit_indices = _MLIR.IR.DenseArrayAttribute(Int64[slot]),
                    strides = _MLIR.IR.DenseArrayAttribute(Int64[1]), location = _de_loc()
                )
            )
        elseif ch.kind === _E._NK_LITERAL && _de_lanes_uniform(ch)
            return _de_res(
                _hlo.constant(;
                    output = _de_ty(1, Float64),
                    value = _MLIR.IR.DenseElementsAttribute([ch.literal]), location = _de_loc()
                )
            )
        end
        return _de_refuse(
            ctx, "an exact comparison of a binary64 key with a computed operand",
            "a declared-Float64 key compared in a binary32 fragment must meet a parameter " *
                "or a literal, so the comparison can run in binary64 (esm-spec §11.3.3 P8)."
        )
    end
    _de_tally!(ctx, :compare)
    pred = _hlo.compare(
        operands[1], operands[2]; result_0 = _de_ty_i1(1),
        comparison_direction = _MLIR.API.stablehloComparisonDirectionAttrGet(
            _MLIR.IR.current_context(), _DE_COMPARE[nd.op]
        ),
        location = _de_loc()
    )
    return _de_select(ctx, _de_res(pred), 1, _de_const(ctx, 1.0), _de_const(ctx, 0.0))
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

function emit_fragment(
        ir::_E.OperatorIR; eltype::Type = ir.working_eltype, fold::Symbol = :tree,
        calls::Symbol = :functions
    )
    eltype in (Float32, Float64) || throw(ArgumentError("fragment eltype must be Float32 or Float64"))
    eltype === ir.working_eltype || throw(
        _E._range_error(
            _E.ERROR_CODES.PRECISION_CHOICE_CONFLICT,
            "emit_fragment requested $eltype for an operator resolved to $(ir.working_eltype)"
        )
    )
    fold in (:tree, :reduce) || throw(ArgumentError("fragment fold must be :tree or :reduce"))
    host = _E.forcing_buffers(ir.f)
    buffers = map(keys(host)) do name
        slot = findfirst(s -> s.name == String(name), ir.forcing)
        slot !== nothing && return slot
        if ir.target isa _E.Tile
            row = findfirst(
                i -> name === Symbol(_E._tile_coordinate_name(i)), eachindex(ir.extra.coordinates)
            )
            row !== nothing && return _TileCoordinateBuffer(row, ir.extra.coordinates[row])
        end
        return _fragment_lane_buffer(ir, String(name))
    end
    names = Dict(Symbol(n) => i for (i, n) in enumerate(ir.params))
    # Use one gather for fragmented reads so the graph does not acquire
    # slices as the tile or lane capacity grows.
    return _StableHLOFragment{eltype, typeof(ir), typeof(buffers)}(
        ir, buffers, Vector{Float64}[values(host)...], names,
        DirectEmitOptions(; read = :always, calls), fold === :tree
    )
end

struct _TileCoordinateBuffer
    row::Int
    offsets::UnitRange{Int}
end

function _fragment_buffer(::Type{T}, plan::_TileCoordinateBuffer, forcing, origin) where {T}
    row = plan.row
    n = length(plan.offsets)
    attr(v) = _MLIR.IR.DenseArrayAttribute(Int64[v])
    start = _hlo.slice(
        origin.mlir_data; result_0 = _de_ty(1, Int32),
        start_indices = attr(row - 1), limit_indices = attr(row), strides = attr(1),
        location = _de_loc()
    )
    base = _de_res(start)
    if first(plan.offsets) != 0
        shift = _hlo.constant(;
            output = _de_ty(1, Int32),
            value = _MLIR.IR.DenseElementsAttribute(Int32[first(plan.offsets)]), location = _de_loc()
        )
        base = _de_res(_hlo.add(base, _de_res(shift); result = _de_ty(1, Int32), location = _de_loc()))
    end
    if n != 1
        ty = _de_ty(n, Int32)
        repeated = _hlo.broadcast_in_dim(
            base; result_0 = ty, broadcast_dimensions = attr(0), location = _de_loc()
        )
        offsets = _hlo.iota(; output = ty, iota_dimension = 0, location = _de_loc())
        base = _de_res(_hlo.add(_de_res(repeated), _de_res(offsets); result = ty, location = _de_loc()))
    end
    return _de_traced(_de_cast(_DEVal(base, n), Int32, T), T)
end

# The range lowerer gives each distinct read a compact buffer. Its index
# program runs in Int32, independent of the model's arithmetic precision.
struct _LaneBuffer
    source::Int
    data::AbstractArray
    subs::Vector{_E._Node}
    rows::Vector{Int}
    columns::Vector{UnitRange{Int}}
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
    slot = something(findfirst(s -> s.name == g.name, ir.forcing), 0)
    boundary = Symbol[_E._const_dim_boundary(g.src, d) for d in eachindex(g.dims)]
    return _LaneBuffer(slot, g.src, _E._compile_lane_subscripts(g), last.(g.vars), last.(g.columns), g.dims, boundary)
end

function _fragment_iota(n)
    ty = _de_ty(n, Int32)
    op = _hlo.iota(; output = ty, iota_dimension = 0, location = _de_loc())
    return _de_traced(_DEVal(_de_res(op), n), Int32)
end

function _fragment_lane_coordinates(cells, rows, columns, flat)
    cap = size(cells, 2)
    isempty(columns) && return [cells[row, :] for row in rows]
    # Flatten column-major over [lane, column variables...]. Generate the
    # column bindings arithmetically from one iota for the whole buffer.
    copy_lanes = mod.(flat, Int32(cap)) .+ Int32(1)
    coords = [cells[row, :][copy_lanes] for row in rows]
    stride = cap
    for r in columns
        idx = mod.(div.(flat, Int32(stride)), Int32(length(r))) .+ Int32(first(r))
        push!(coords, idx)
        stride *= length(r)
    end
    return coords
end

# The integer subscript operators, as the host's `_subscript_binop`. A bare
# `/` is absent: the host accepts only an exact quotient and raises on any
# other, which a traced fragment cannot do, so it is refused when traced.
const _LANE_INDEX_BINOP = Dict{Symbol, Function}(
    :+ => +, :- => -, :* => *, :mod => mod, :min => min, :max => max,
    :< => <, :<= => <=, :> => >, :>= => >=, :(==) => ==, :!= => !=
)

# Whether a read of `boundary` past an axis leaves the array. Such a read is
# masked rather than raised: pre-gathers are eager, so a guard in the rule
# must be able to discard it, as in the native lane program.
_fragment_axis_masked(boundary::Symbol) = !(boundary === :periodic || boundary === :clamp)

# Whether a pre-gather is masked: one of its axes, or of a table read inside
# its subscripts, leaves the array on an out-of-range read.
_fragment_lane_masked(plan::_LaneBuffer) =
    any(_fragment_axis_masked, plan.boundary) || any(_fragment_index_masked, plan.subs)

function _fragment_index_masked(nd::_E._Node)
    if nd.kind === _E._NK_CONST_GATHER
        any(_fragment_axis_masked, (nd.payload::_E._ConstGatherArray).boundary) && return true
    elseif nd.kind === _E._NK_CALL
        return _fragment_index_masked(_de_inline_call(nothing, nd))
    end
    return any(_fragment_index_masked, nd.children)
end

# The flat offsets of a gather at the subscripts `subs`, and the lanes whose
# read stays inside the array: every masked axis in range, and every table
# read inside the subscripts too. A table read that leaves its array is
# clamped to keep the gather in bounds, and its lane is marked invalid.
function _fragment_gather_offsets(subs, dims, boundary, inputs, L)
    offsets = first(inputs) .* Int32(0)
    valid = Ref(offsets .== Int32(0))
    stride = 1
    for d in eachindex(dims)
        idx = _fragment_index_node(subs[d], inputs, L, valid) .- Int32(1)
        n = Int32(dims[d])
        if boundary[d] === :periodic
            idx = mod.(idx, n)
        else
            if _fragment_axis_masked(boundary[d])
                valid[] = valid[] .& (idx .>= Int32(0)) .& (idx .< n)
            end
            idx = clamp.(idx, Int32(0), n - Int32(1))
        end
        offsets = offsets .+ Int32(stride) .* idx
        stride *= n
    end
    return offsets, valid[]
end

# The integer value of a subscript node at each lane, as the host's
# `_index_int`. `valid` collects the lanes whose table reads stay in range;
# `ifelse` keeps only the taken branch's, as the host evaluates only it.
function _fragment_index_node(nd::_E._Node, inputs, L, valid::Ref)
    kind = nd.kind
    kind === _E._NK_STATE && return inputs[nd.idx]
    kind === _E._NK_LITERAL && return fill(Int32(nd.literal), L)
    if kind === _E._NK_CONST_GATHER
        a = nd.payload::_E._ConstGatherArray
        off, ok = _fragment_gather_offsets(nd.children, a.dims, a.boundary, inputs, L)
        valid[] = valid[] .& ok
        table = Reactant.promote_to(TracedRArray{Float64, 1}, a.flat)
        return round.(Int32, table[off .+ Int32(1)])
    end
    kind === _E._NK_CALL && return _fragment_index_node(_de_inline_call(nothing, nd), inputs, L, valid)
    kind === _E._NK_OP || return _de_refuse_at(
        "lane fragment", "an integer index node of kind $(_de_kindname(kind))", "it cannot be evaluated from the lane coordinates."
    )
    ev(n) = _fragment_index_node(n, inputs, L, valid)
    op, args = nd.op, nd.children
    if op === :ifelse
        c = ev(args[1]) .!= Int32(0)
        yes, no = Ref(c .| true), Ref(c .| true)
        a = _fragment_index_node(args[2], inputs, L, yes)
        b = _fragment_index_node(args[3], inputs, L, no)
        valid[] = valid[] .& ifelse.(c, yes[], no[])
        return ifelse.(c, a, b)
    elseif op === :floor || op === :ceil
        a = only(args)
        if a.kind === _E._NK_OP && a.op === :/ && length(a.children) == 2
            x, y = ev(a.children[1]), ev(a.children[2])
            q, r = div.(x, y), rem.(x, y)
            same_sign = (r .< Int32(0)) .== (y .< Int32(0))
            round_up = op === :ceil
            needs_adjustment = (r .!= Int32(0)) .& (same_sign .== round_up)
            return q .+ ifelse.(needs_adjustment, round_up ? Int32(1) : Int32(-1), Int32(0))
        end
        return ev(a)
    elseif op === :neg || (op === :- && length(args) == 1)
        return .-ev(only(args))
    elseif op === :/
        return _de_refuse_at(
            "lane fragment", "a bare quotient in an integer subscript",
            "the host accepts only an exact quotient and raises on any other " *
                "(E_TREEWALK_INEXACT_SUBSCRIPT), which a traced fragment cannot do. " *
                "Round it explicitly with `floor(a / b)` or `ceil(a / b)`."
        )
    end
    binop = get(_LANE_INDEX_BINOP, op, nothing)
    binop === nothing && return _de_refuse_at("lane fragment", "the integer index operator $op", "it is not supported by the integer gather path.")
    return foldl(args[2:end]; init = ev(args[1])) do x, y
        Int32.(binop.(x, ev(y)))
    end
end

function _fragment_lane_offsets(cells, plan::_LaneBuffer, flat)
    inputs = _fragment_lane_coordinates(cells, plan.rows, plan.columns, flat)
    return _fragment_gather_offsets(plan.subs, plan.dims, plan.boundary, inputs, length(first(inputs)))
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
    flat = isempty(spec.columns) ? nothing :
        _fragment_iota(size(cells, 2) * prod(length, spec.columns; init = 1))
    off, valid = Reactant.call_with_reactant(_fragment_lane_offsets, cells, spec, flat)
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
    _fragment_lane_masked(spec) || return _de_traced(out, T)
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
    for (i, (buf, slot)) in enumerate(zip(forcing, ir.forcing))
        buf isa Union{TracedRArray{Float32, 1}, TracedRArray{Float64, 1}} ||
            throw(ArgumentError("forcing slot '$(slot.name)' requires a traced flat floating-point tensor"))
        window_length = ir.target isa _E.Tile ? _E._tile_window_length(ir.extra.windows[i]) : -1
        whole_length = ir.target isa _E.Tile && ir.target.class !== nothing ?
            window_length : prod(slot.shape; init = 1)
        length(buf) in (whole_length, window_length) ||
            throw(DimensionMismatch("forcing slot '$(slot.name)' has the wrong length"))
    end
    return nothing
end

function _fragment_context(f::_StableHLOFragment{T}, p, t, forcing, cells, param_slots) where {T}
    rhs = f.ir.f.rhs
    _fragment_check(forcing, f.ir)
    inputs = map(spec -> _fragment_buffer(T, spec, forcing, cells), f.buffers)
    windows = f.ir.target isa _E.Tile ?
        Union{Nothing, _E._TileForcingWindow}[i isa Int ? f.ir.extra.windows[i] : nothing for i in f.buffers] : nothing
    params = _DEParamVector(_de_cast(_de_untraced(p), Float64, T), param_slots)
    keys64 = isempty(f.ir.binary64_keys) ? nothing : _DEExactKeys(
            _de_untraced(p), Dict(Symbol(k) => param_slots[Symbol(k)] for k in f.ir.binary64_keys)
        )
    return _DECtx(
        rhs.n_states, rhs.n_total, params, _de_cast(_de_time(t), Float64, T),
        nothing, inputs, f.hostkeys, Dict{Int, String}(), f.options;
        precision = T, tree_fold = f.tree_fold, windows, keys64
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
    f.ir.target isa _E.Tile && f.ir.target.class !== nothing &&
        throw(ArgumentError("tile class fragments require an origin tensor"))
    return _fragment_call(f, u, aux, p, t, forcing, nothing, nothing)
end

function (f::_StableHLOFragment{T})(
        u::TracedRArray{T, 1}, aux::TracedRArray{T, 1}, p::TracedRArray{Float64, 1},
        t::TracedRNumber{Float64}, forcing::Tuple, cells::TracedRArray{Int32, 2},
        dt::Union{Nothing, TracedRNumber{Float64}} = nothing
    ) where {T}
    target = f.ir.target
    target isa _E.Lanes || throw(ArgumentError("only lane fragments take a cells tensor"))
    size(cells) == (length(target.sets), target.capacity) ||
        throw(DimensionMismatch("cells must have one row per lane set and one column per lane"))
    return _fragment_call(f, u, aux, p, t, forcing, cells, dt)
end

function (f::_StableHLOFragment{T})(
        u::TracedRArray{T, 1}, aux::TracedRArray{T, 1}, p::TracedRArray{Float64, 1},
        t::TracedRNumber{Float64}, forcing::Tuple, origin::TracedRArray{Int32, 1},
        dt::Union{Nothing, TracedRNumber{Float64}} = nothing
    ) where {T}
    target = f.ir.target
    target isa _E.Tile && target.class !== nothing ||
        throw(ArgumentError("only tile class fragments take an origin tensor"))
    length(origin) == length(target.decomposition.axes) ||
        throw(DimensionMismatch("origin must have one coordinate per decomposition axis"))
    return _fragment_call(f, u, aux, p, t, forcing, origin, dt)
end

function (f::_StableHLOFragment{T})(
        u::TracedRArray{T, 1}, aux::TracedRArray{T, 1}, p::TracedRArray{Float64, 1},
        t::TracedRNumber{Float64}, forcing::Tuple, dt::TracedRNumber{Float64}
    ) where {T}
    target = f.ir.target
    (target isa _E.Lanes || (target isa _E.Tile && target.class !== nothing)) &&
        throw(ArgumentError("pass the cells or origin tensor before dt"))
    return _fragment_call(f, u, aux, p, t, forcing, nothing, dt)
end

# Under `calls = :functions` the operator is emitted ONCE per trace as a private
# function (one per argument types) and each use is a `func.call`, so an RK4
# leaf holds the operator once, not four times. Reactant's call cache keys the
# function by the fragment (a trace leaf, by identity) and the traced argument
# types; every input is an argument, so the body captures nothing.
function _fragment_call(f, u, aux, p, t, forcing, indices, dt)
    f.options.calls === :functions &&
        return Reactant.Ops.call(_fragment_body, f, u, aux, p, t, forcing, indices, dt)
    return _fragment_body(f, u, aux, p, t, forcing, indices, dt)
end

function _fragment_body(f, u, aux, p, t, forcing, indices, dt)
    if f.ir.kernel === nothing
        dt === nothing || throw(ArgumentError("only output kernels take a dt argument"))
        return _fragment_rhs(f, u, aux, p, t, forcing, indices)
    end
    return _fragment_kernel(f, u, aux, p, t, forcing, indices, dt)
end

function _fragment_kernel(f::_StableHLOFragment{T}, u, aux, p, t, forcing, indices, dt) where {T}
    ir = f.ir
    k = ir.kernel
    length(u) == k.n_u || throw(DimensionMismatch("u has the wrong length for the kernel"))
    length(aux) == k.n_aux || throw(DimensionMismatch("aux has the wrong length for the kernel"))
    length(p) == length(ir.params) || throw(DimensionMismatch("p must follow parameter_names(ir)"))
    ctx = _fragment_context(f, p, t, forcing, indices, f.parameter_slots)
    umap = _de_untraced(u)
    zmap = _de_untraced(aux)
    amap = _DEMap(k.held_width)
    for (source, s, d, n) in k.inputs
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
    state = _fragment_output(ctx, du, ir.maps.du, k.width)
    blocks = ir.layout.out
    out = _DEMap(sum(b -> prod(b.shape; init = 1), blocks; init = 0))
    k.passthrough && _fragment_copy!(out, umap, (_E._CopyRun(1, 1, k.n_u),))
    _fragment_copy!(out, state, k.outputs)
    S = something(k.out_eltype, T)
    return map(Tuple(blocks)) do block
        n = prod(block.shape; init = 1)
        val = _de_emit_runs(ctx, out.m[block.offset:(block.offset + n - 1)])
        _de_traced(_de_cast(val, T, S), S)
    end
end


# Positions of every lane element in the whole-domain `u`, lane-major within
# each block. With `width`, a lane whose cell lies outside the domain gets the
# out-of-range position `width + 1`, which a scatter drops.
function _fragment_lane_positions(cells, plans, width = nothing)
    capacity = size(cells, 2)
    positions = map(plans) do (strides, extents, offsets)
        base = cells[1, :] .* Int32(0)
        valid = base .== Int32(0)
        for (row, stride) in enumerate(strides)
            c = cells[row, :]
            base = base .+ (c .- Int32(1)) .* stride
            valid = valid .& (c .>= Int32(1)) .& (c .<= extents[row])
        end
        pos = reshape(base, capacity, 1) .+ reshape(offsets, 1, length(offsets))
        if width !== nothing
            pos = ifelse.(reshape(valid, capacity, 1), pos, Int32(width + 1))
        end
        return vec(pos)
    end
    isempty(positions) && return Reactant.promote_to(TracedRArray{Int32, 1}, Int32[])
    return reduce(vcat, positions)
end

function _fragment_lane_indices(ir, u, cells; drop_outside = false)
    target = ir.target
    target isa _E.Lanes || throw(ArgumentError("lane assembly requires Lanes operator IR"))
    size(cells) == (length(target.sets), target.capacity) ||
        throw(DimensionMismatch("cells must follow the lane layout"))
    width, plans = ir.extra[2]
    length(u) == width || throw(DimensionMismatch("u must follow the whole-domain writable layout"))
    return Reactant.call_with_reactant(
        _fragment_lane_positions, cells, plans, drop_outside ? width : nothing
    )
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
    indices = _fragment_lane_indices(ir, u, cells; drop_outside = true)
    length(indices) == length(updates) || throw(DimensionMismatch("updates must follow the lane layout"))
    return Reactant.call_with_reactant(_fragment_scatter_state, u, updates, indices)
end
