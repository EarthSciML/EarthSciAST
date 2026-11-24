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

A single [`compile_kernels`](@ref) specification for an output fragment.
Optionally cast the returned blocks to `Float16`, `Float32` or `Float64`.
With Reactant loaded, `BFloat16` is also supported.
"""
struct KernelOutputs{S}
    spec::S
    out_eltype::Union{Nothing, DataType}
    function KernelOutputs(spec::S, out_eltype) where {S}
        out_eltype === nothing || _kernel_output_eltype(out_eltype) ||
            throw(ArgumentError("unsupported kernel output element type $out_eltype"))
        return new{S}(spec, out_eltype)
    end
end
KernelOutputs(spec; out_eltype = nothing) = KernelOutputs(spec, out_eltype)
_kernel_output_eltype(T) = T in (Float16, Float32, Float64)

"""Host-side tree-walk IR and input layouts for [`emit_fragment`](@ref).
`W` is the working precision, `Float32` or `Float64`. `binary64_keys` names
the declared-Float64 parameters a binary32 operator reads only as `==`/`!=`
operands; their comparisons run in binary64 (esm-spec §11.3.3 P8)."""
struct OperatorIR{F, L, M, T, E, K, W}
    f::F
    layout::L
    maps::M
    target::T
    extra::E
    params::Vector{String}
    forcing::Vector{ForcingSlot}
    kernel::K
    working_eltype::Type{W}
    binary64_keys::Vector{String}
end
OperatorIR(f, layout, maps, target, extra, params, forcing, kernel = nothing) =
    OperatorIR(f, layout, maps, target, extra, params, forcing, kernel, Float64, String[])

# The working precision of `prog` under `unspecified_eltype = requested`, and
# its binary64 comparison keys (`OperatorIR.binary64_keys`).

function _operator_eltype(prog::RhsProgram, requested::Type)
    requested in (Float32, Float64) ||
        throw(ArgumentError("unspecified_eltype must be Float32 or Float64"))
    requested === Float64 && return Float64, String[]

    request = "operator_ir(…; unspecified_eltype = Float32)"
    conflict(msg) = throw(_range_error(ERROR_CODES.PRECISION_CHOICE_CONFLICT, "$request: $msg"))
    file = prog.seed.prep.file
    if file === nothing
        # A caller-supplied flattened system carries no format version, so an
        # omitted `domain.element_type` is unspecified or a binary64
        # declaration depending on a version gate it cannot answer.
        dom = prog.flat.domain
        declared = dom === nothing ? nothing : dom.element_type
        declared === nothing && conflict(
            "the program has no source document, so whether its omitted " *
                "`domain.element_type` leaves precision unspecified (esm 2.4.0 and later) " *
                "or declares Float64 cannot be determined (esm-spec §11.3.3)"
        )
        conflict("the document declares $declared working precision")
    end
    source = precision_source(file)
    source == "unspecified" || conflict("the document declares $source working precision")

    flat = expand_flattened_refs(prog.flat)
    variables = merge(flat.parameters, flat.observed_variables, flat.state_variables)
    # `quantities` holds every name read or written as a quantity; a name used
    # only as an `==`/`!=` operand or a `join.on` key is in `used` alone.
    quantities = Set{String}(prog.writes)
    union!(quantities, prog.aux_names)
    used = copy(quantities)
    compared = Set{String}()
    for (i, eq) in enumerate(flat.equations), expr in (eq.lhs, eq.rhs)
        _quantity_var_names(expr, quantities)
        _visit_keys(expr, String[]) do key, op
            var = get(variables, key, nothing)
            var === nothing && return
            push!(used, key)
            op == "join.on" || push!(compared, key)
            var.element_type === nothing && throw(
                _range_error(
                    ERROR_CODES.KEY_PRECISION_UNSPECIFIED,
                    "$request: $key has unspecified precision in $op in operator equation $i"
                )
            )
        end
    end
    union!(used, quantities)
    names = sort!([name for name in used if haskey(variables, name)])
    eligible = filter(n -> variables[n].element_type === nothing, names)
    isempty(eligible) && conflict(
        "no variable read or written has unspecified precision; variables: " * join(names, ", ")
    )
    # A declared-binary64 key compared exactly supplies only its flag to the
    # binary32 group (esm-spec §11.3.3 P8), so only quantities can conflict.
    # A `join.on` key is matched while the program is built, in binary64; an
    # `==`/`!=` key is compared in the fragment, which reads a scalar
    # parameter in binary64.
    params = Set(parameter_names(prog))
    keys = String[]
    for name in names
        variables[name].element_type == "Float64" || continue
        name in quantities && conflict(
            "$name declares Float64, while $(first(eligible)) resolves to Float32. " *
                "A fragment uses one working precision."
        )
        name in compared || continue
        name in params || conflict(
            "$name declares Float64 and is compared with `==`/`!=`, but a binary32 " *
                "fragment compares a binary64 key exactly only when it is a scalar parameter"
        )
        push!(keys, name)
    end
    return Float32, keys
end

# The variable names `expr` reads as quantities: every reference except a
# direct operand of `==` or `!=` (through any `index` chain, whose subscripts
# are quantities), which `_visit_keys` reports as a key. A subexpression
# shared by identity is walked once.
function _quantity_var_names(expr, acc::Set{String}, seen = IdDict{OpExpr, Nothing}())
    if expr isa VarExpr
        push!(acc, expr.name)
    elseif expr isa OpExpr && !haskey(seen, expr)
        seen[expr] = nothing
        expr.wrt === nothing || push!(acc, expr.wrt::String)
        walk(e) = _quantity_var_names(e, acc, seen)
        if expr.op == "==" || expr.op == "!="
            for arg in expr.args
                while arg isa OpExpr && arg.op == "index" && !isempty(arg.args)
                    foreach(walk, @view arg.args[2:end])
                    arg = arg.args[1]
                end
                arg isa VarExpr || walk(arg)
            end
        else
            foreach_child(walk, expr)
        end
    end
    return acc
end

"""
    operator_ir(prob; select = RhsSelection(), target = Whole(), outputs = :du, unspecified_eltype = Float64)
    operator_ir(prog::RhsProgram; target = Whole(), unspecified_eltype = Float64)

Build the out-of-place tree-walk IR for a selected operator. Its state and
forcing tensors are described by [`ir_layout`](@ref), [`parameter_names`](@ref)
and [`forcing_slots`](@ref). With `outputs = KernelOutputs(spec)`, compile the
named kernel against the Problem, using its `u` and `z` inputs.
Set `unspecified_eltype = Float32` to build a binary32 fragment for a group
whose variables all resolve to Float32 under esm-spec §11.3.3.
"""
function operator_ir(
        prob::EsmProblem; select::RhsSelection = RhsSelection(),
        target = Whole(), outputs = :du, unspecified_eltype::Type = Float64
    )
    if outputs isa KernelOutputs
        (select.writes === :all && select.terms === :all) || throw(ArgumentError("kernel specifications define their own selection"))
        return _kernel_operator_ir(prob, outputs, target; unspecified_eltype)
    end
    outputs === :du || throw(ArgumentError("outputs must be :du or a KernelOutputs"))
    op = rhs_program(prob)
    if select.writes !== :all || select.terms !== :all
        # Each call selects a fresh program, which a tile class built from
        # an earlier selection never belongs to.
        target isa Tile && target.class !== nothing && throw(
            ArgumentError(
                "a tile class cannot be combined with `select`: select the " *
                    "program once, `prog = select(rhs_program(prob); ...)`, build the " *
                    "classes from `prog` and call `operator_ir(prog; target)`"
            )
        )
        op = EarthSciAST.select(op; select.writes, select.terms)
    end
    return operator_ir(op; target, unspecified_eltype)
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

operator_ir(prog::RhsProgram; target = Whole(), unspecified_eltype::Type = Float64) =
    _rhs_operator_ir(prog, target; unspecified_eltype)

# `slots` is the forcing signature of the IR. Tile forcing windows are
# computed against it by name, so `ir.extra.windows[i]` is the window of
# `ir.forcing[i]`: a kernel's IR passes its kernel set's signature, which the
# kernel program reads by name.
function _rhs_operator_ir(
        prog::RhsProgram, target; shared_aux = Set{String}(), slots = forcing_slots(prog),
        unspecified_eltype::Type = Float64
    )
    T, keys = _operator_eltype(prog, unspecified_eltype)
    T === Float64 && return _rhs_operator_ir(prog, target, T, keys; shared_aux, slots)
    # The native build computes in binary64. A binary32 operator reuses it
    # only when the build evaluated none of the model's arithmetic on the
    # host, since those results would be rounded once instead of per
    # operation (esm-spec §11.3.1). A tile or lane build may be memoized from
    # before this call, so the whole-domain build of the same equations is
    # recorded for it too.
    ir, sites = _recording_host_arithmetic() do
        target isa Whole || _operator_build(prog)
        _rhs_operator_ir(prog, target, T, keys; shared_aux, slots)
    end
    isempty(sites) || throw(
        _range_error(
            ERROR_CODES.FLOAT32_UNSUPPORTED,
            "operator_ir(…; unspecified_eltype = Float32): the Julia build evaluates " *
                join(sites, "; ") * " once in binary64, so a binary32 fragment would " *
                "round each result once rather than per operation (esm-spec §11.3.1)"
        )
    )
    return ir
end

function _rhs_operator_ir(prog::RhsProgram, target, T::DataType, keys::Vector{String}; shared_aux, slots)
    params = parameter_names(prog)
    slots = copy(slots)
    if target isa Whole
        return OperatorIR(_operator_build(prog), prog.layout, prog.maps, target, nothing, params, slots, nothing, T, keys)
    elseif target isa Tile
        if target.class === nothing
            tile = _restrict(prog, target.decomposition; target.owned, target.storage, form = :oop)
            windows = _tile_forcing_windows(tile.f!, slots)
        else
            target.class.owner === prog.memo ||
                throw(ArgumentError("tile classes must be used with the operator that built them"))
            target.class.slots == slots ||
                throw(ArgumentError("tile classes must be used with the forcing signature that built them"))
            tile = target.class.representative
            windows = target.class.windows[Tuple(tile.origin)]
        end
        info = (; tile.reach, windows, tile.coordinates)
        return OperatorIR(tile.f!, tile.layout, tile.maps, target, info, params, slots, nothing, T, keys)
    elseif target isa Lanes
        lane = _lanes(prog, target.kind, target.sets, target.capacity; form = :oop, shared_aux)
        maps = _lane_operator_maps(lane, target.capacity)
        return OperatorIR(
            lane.f!, lane.layout, maps, target, (lane.gathers, _lane_state_index(prog, lane.layout)),
            params, slots, nothing, T, keys
        )
    end
    throw(ArgumentError("target must be Whole, Tile or Lanes"))
end

function _lane_operator_maps(lane, capacity)
    function pairs(plans)
        src, dst = Int[], Int[]
        for p in plans, e in eachindex(p.slot1), c in 1:(p.lstride == 0 ? 1 : capacity)
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
function _lane_state_index(prog::RhsProgram, layout)
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
    emit_fragment(ir; eltype = ir.working_eltype, fold = :tree)

With Reactant loaded, create a host callable that emits a StableHLO fragment
into the caller's trace. Call it on traced arguments `(u, aux, p, t, forcing)`;
tile classes also take `origin` and lane targets take `cells`. If an output
kernel reads a time step, append `dt`. The fragment uses the IR's working
precision, including when `eltype` is supplied explicitly. Binary32 operations
and reductions accumulate in expression order. See the compiled backend
guide for layouts and precision.
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
include("operator_kernels.jl")
