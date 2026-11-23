# A standalone kernel already expresses its results as writes in a derived
# AST. Restrict that same program, then route its held states to u, z or dt.
struct _OperatorKernel
    inputs::Vector{NTuple{4, Int}}
    outputs::Vector{_CopyRun}
    passthrough::Bool
    direct::Bool
    n_u::Int
    n_aux::Int
    width::Int
    held_width::Int
    out_eltype::Union{Nothing, DataType}
end

function _kernel_operator_ir(prob, spec, target)
    ks, k = _fragment_kernel_set(prob, spec, target)
    # The kernel program is built from its own flattened system, so its
    # forcing slots need not be the kernel set's. The IR takes the kernel
    # set's signature and the build reads its buffers by name.
    slots = forcing_slots(ks)
    if target isa Whole
        base = _rhs_operator_ir(k.prog, target; slots)
        layout = (u = state_layout(ks), aux = z_layout(ks), out = kernel_layout(k))
        outputs = k.direct ? [_CopyRun(1, 1, k.n_u)] : [_CopyRun(s, d, n) for (s, d, n) in k.out_plan]
        plan = _OperatorKernel(k.aux_plan, outputs, k.map, k.direct, k.n_u, k.n_z, base.layout.n_u, base.layout.n_aux, spec.out_eltype)
    elseif k.direct
        base = _rhs_operator_ir(k.prog, target; slots)
        cap = target isa Lanes ? target.capacity : 1
        u, aux = cap * base.layout.n_u, cap * base.layout.n_aux
        layout = (u = base.layout.u, aux = base.layout.aux, out = _operator_kernel_blocks(base.layout.u, cap))
        inputs = [(2, 1, 1, aux)]
        plan = _OperatorKernel(inputs, [_CopyRun(1, 1, u)], false, true, u, aux, u, aux, spec.out_eltype)
    else
        srcs = Dict(b.name => p[1] for (b, p) in zip(k.prog.layout.aux, k.aux_plan))
        shared = Set(n for (n, src) in srcs if src in (0, 3) && haskey(k.prog.internal.scalars, n))
        base = _rhs_operator_ir(k.prog, target; shared_aux = shared, slots)
        layout, plan = _restricted_kernel_plan(k, base, srcs, spec.out_eltype)
    end
    extra = if target isa Lanes
        (base.extra[1], _lane_state_index(ks.rhs, (u = layout.u, sets = target.sets)))
    else
        base.extra
    end
    return OperatorIR(
        base.f, layout, base.maps, target, extra, parameter_names(ks.rhs), base.forcing, plan
    )
end

function _fragment_kernel_set(prob, spec, target)
    if target isa Tile && target.class !== nothing && target.class.kernel !== nothing
        data = target.class.kernel
        data.seed === prob.build.seed && isequal(data.spec, only(_normalize_specs([spec.spec]))) ||
            throw(ArgumentError("tile classes must be used with the Problem and kernel specification that built them"))
        return data.ks, data.k
    end
    ks = compile_kernels(prob, [spec.spec])
    return ks, only(values(ks.kernels))
end

_operator_block_shape(b::TileBlock, cap) = length.(b.storage)
_operator_block_shape(b::LaneBlock, cap) = [cap; b.extents]
_operator_block_base(b::TileBlock, cap) = b.base
_operator_block_base(b::LaneBlock, cap) = b.offset * cap + 1
_operator_block_len(b, cap) = prod(_operator_block_shape(b, cap); init = 1)

function _operator_kernel_blocks(blocks, cap)
    return KernelBlock[
        KernelBlock(b.name, _operator_block_base(b, cap), _operator_block_shape(b, cap)) for b in blocks
    ]
end

_rebase_kernel_block(b::TileBlock, offset, cap) =
    TileBlock(b.name, b.sets, b.storage, b.owned, offset, b.strides)
_rebase_kernel_block(b::LaneBlock, offset, cap) =
    LaneBlock(b.name, b.sets, b.extents, div(offset - 1, cap))

function _restricted_kernel_plan(k, base, srcs, out_eltype)
    cap = base.target isa Lanes ? base.target.capacity : 1
    all_aux = base.layout.aux
    u, z = similar(all_aux, 0), similar(all_aux, 0)
    lengths = [0, 0]
    inputs = NTuple{4, Int}[]
    for b in all_aux
        source = srcs[b.name]
        source == 0 && continue
        dst = _operator_block_base(b, cap)
        n = _operator_block_len(b, cap)
        if source == 3
            push!(inputs, (3, 0, dst, 1))
            continue
        end
        off = lengths[source] + 1
        push!(source == 1 ? u : z, _rebase_kernel_block(b, off, cap))
        push!(inputs, (source, off, dst, n))
        lengths[source] += n
    end
    locals = Dict(b.name => b for b in base.layout.u)
    original = Dict(b.base => b.name for b in k.prog.layout.u)
    out = k.map ? _operator_kernel_blocks(u, cap) : KernelBlock[]
    runs = _CopyRun[]
    offset = 1
    for (i, (source, dest, _)) in enumerate(k.out_plan)
        b = locals[original[source]]
        start = _operator_block_base(b, cap)
        n = _operator_block_len(b, cap)
        if k.map
            label = only(x.label for x in k.layout if x.offset == dest)
            ub = only(x for x in u if x.name == label)
            off = _operator_block_base(ub, cap)
            if b isa TileBlock
                for cell in CartesianIndices(Tuple(b.owned))
                    push!(runs, _CopyRun(_tile_slot(b, Tuple(cell)), _tile_slot(ub, Tuple(cell)), 1))
                end
            else
                push!(runs, _CopyRun(start, off, n))
            end
        else
            push!(out, KernelBlock(k.layout[i].label, offset, _operator_block_shape(b, cap)))
            push!(runs, _CopyRun(start, offset, n))
            offset += n
        end
    end
    width = cap * base.layout.n_u
    plan = _OperatorKernel(inputs, runs, k.map, false, lengths..., width, cap * base.layout.n_aux, out_eltype)
    return (u = u, aux = z, out = out), plan
end

"""
    tile_classes(prob::EsmProblem, decomposition, tiles; outputs::KernelOutputs)

Group tiles of the standalone output kernel. Use the returned targets with
`operator_ir(prob; target, outputs)` and the same kernel specification.
"""
function tile_classes(prob::EsmProblem, dec::Decomposition, tiles; outputs::KernelOutputs)
    ks = compile_kernels(prob, [outputs.spec])
    k = only(values(ks.kernels))
    spec = deepcopy(only(_normalize_specs([outputs.spec])))
    return _tile_classes(k.prog, dec, tiles, (; seed = prob.build.seed, spec, ks, k), forcing_slots(ks))
end
