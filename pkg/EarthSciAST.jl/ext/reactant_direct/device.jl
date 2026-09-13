# ========================================================================
# ext/reactant_direct/device.jl — WHERE the compiled program runs: the XLA
# client (host CPU or an attached GPU) and, across several devices of one
# client, the sharding of the flat state.
# ========================================================================
#
# WHY THIS IS A SEPARATE CONCERN FROM EMISSION. Nothing in the emitted
# StableHLO names a device: the same module compiles on either platform, and the
# platform is fixed by the CLIENT of the arrays fed to it, exactly as it is for
# the traced emitter. So device choice lives here, on the wrapper, and reaches
# XLA only through the `ConcreteRArray`/`ConcreteRNumber` constructors that
# `direct_state`, `direct_params` and `direct_time` call.
#
# THE FLAT STATE IS A CONCATENATION OF PER-VARIABLE CELL BLOCKS. The tree-walk's
# layout (src/tree_walk/build.jl, "flat state-vector cell names") is: state
# variables in sorted-name order, each contributing a CONTIGUOUS BLOCK of its
# own cells in column-major order; a scalar state is a block of one. One flat
# slot is exactly one cell, so the flat axis IS a cell axis — it is the cell
# axes of every state variable laid end to end. That is the axis this file
# shards, and it is the ONLY shardable axis: `u` is rank 1, there is no separate
# variable axis to cut.
#
# WHAT A SLAB SHARD MEANS, AND WHEN IT IS REFUSED. `Sharding.NamedSharding` over
# a one-dimensional mesh cuts the flat axis into `ndevices` equal CONTIGUOUS
# slabs. Such a cut is a clean cell shard only when it respects the block
# structure, so `direct_rhs` refuses (with the ordinary
# `E_DIRECT_EMIT_UNSUPPORTED` code) when it does not:
#
#   * fewer than two devices — there is nothing to shard, and asking for a
#     one-device mesh silently means "no sharding";
#   * `n_states` not divisible by the device count — the slabs would be ragged;
#   * a slab that is neither wholly inside ONE variable's block nor exactly a
#     union of WHOLE blocks. Such a slab holds a suffix of one variable's cells
#     and a prefix of another's: it is neither a cell shard of a variable nor a
#     variable shard, and the refusal names the variables it would straddle.
#
# The two accepted shapes are the two that mean something physically: a slab
# inside one block is a contiguous CELL RANGE of that variable (the stencil
# case — halos only at the two slab edges), and a slab of whole blocks is a
# VARIABLE partition (each device owns entire fields). Correctness never depends
# on this: GSPMD/Shardy would insert collectives for any cut. The refusal exists
# so that a caller who asks for a cell shard is told when the layout cannot give
# one, rather than silently getting an all-to-all.

# ---- the callable's supertype ------------------------------------------------

"""
    DirectCallable <: Function

The supertype of [`DirectRHS`](@ref) and [`DirectRHSBuffers`](@ref), declared
HERE so that this file — which is included before api.jl, because `DirectRHS`
has a [`DirectPlace`](@ref) field and a struct's field types must already exist —
can still dispatch the placement accessors on the wrapper. `_de_place` is the
one hook api.jl supplies.
"""
abstract type DirectCallable <: Function end

function _de_place end

# ---- clients ----------------------------------------------------------------

"""
    direct_client(spec) -> Reactant.XLA.AbstractClient

Resolve a device choice to an XLA client.

`spec` may be

  * `nothing` — Reactant's default backend (a GPU client when one initialized,
    otherwise the host CPU client);
  * `:cpu` / `"cpu"` — the host CPU client, always available;
  * `:gpu` / `"gpu"` / `:cuda` / `"cuda"` — the accelerator client. THROWS an
    ordinary error when no GPU is attached; that error is what the conformance
    adapter turns into the whole-output `unavailable` outcome, never into a
    pass;
  * an `XLA.AbstractClient` — used as given.

The platform a wrapper ended up on is [`direct_platform`](@ref).
"""
direct_client(client::Reactant.XLA.AbstractClient) = client
direct_client(::Nothing) = Reactant.XLA.default_backend()
direct_client(spec::Symbol) = direct_client(String(spec))
function direct_client(spec::AbstractString)
    s = lowercase(String(spec))
    s in ("cpu", "host") && return Reactant.XLA.client("cpu")
    s in ("gpu", "cuda", "rocm", "metal") && return Reactant.XLA.client(s == "gpu" ? "gpu" : s)
    s in ("default", "") && return Reactant.XLA.default_backend()
    error("unknown XLA device choice '$spec'; expected \"cpu\", \"gpu\" or \"default\"")
end

"""
    direct_platform(d) -> String

The XLA platform name (`"cpu"`, `"cuda"`, …) the wrapper `d` will compile and
run on, and the number of devices it will run across, as a short string for a
log line.
"""
direct_platform(d::DirectCallable) =
    string(Reactant.XLA.platform_name(direct_client(d)), " x", direct_devicecount(d))

"""
    direct_client(d) -> XLA client
    direct_shard(d)  -> `DirectShard` or `nothing`
    direct_devicecount(d) -> Int

The placement a wrapper was built with.
"""
direct_client(d::DirectCallable) = _de_place(d).client
direct_shard(d::DirectCallable) = _de_place(d).shard
direct_devicecount(d::DirectCallable) =
    (s = direct_shard(d); s === nothing ? 1 : s.ndevices)

# ---- the resolved sharding ---------------------------------------------------

"""
    DirectShard

A resolved cell-axis sharding: the one-dimensional `Sharding.Mesh` over the
chosen devices, the `NamedSharding` for the rank-1 flat state (and for `du`),
and a `Replicated` annotation for the scalar inputs (`t` and every parameter),
which every device needs a copy of.

Built by [`direct_rhs`](@ref) from its `sharding` keyword; never constructed by
hand.
"""
struct DirectShard
    # Abstractly typed ON PURPOSE (see `DirectRHS`): this object is reachable
    # from the traced callable, and parameterizing it on the mesh's and the
    # sharding's own type parameters is what pushes inference at the
    # `Reactant.@compile` call site past the stack-overflow guard.
    mesh::Reactant.Sharding.Mesh
    state::Reactant.Sharding.AbstractSharding
    replicated::Reactant.Sharding.AbstractSharding
    ndevices::Int
end

"""
    DirectPlace

The one placement field a [`DirectRHS`](@ref) carries: the XLA client its device
inputs are built on, and the cell-axis [`DirectShard`](@ref) or `nothing`. Read
it through [`direct_client`](@ref) and [`direct_shard`](@ref) rather than by
field name.
"""
struct DirectPlace
    client::Reactant.XLA.AbstractClient
    shard::Union{Nothing,DirectShard}
end

# The mesh axis is named for what it cuts. One axis only: `u` is rank 1.
const _DE_MESH_AXIS = :cells

"""
    direct_devices(client; count = nothing) -> Vector

The addressable devices of `client`, in ordinal order, truncated to the first
`count` when one is given. This is what a `sharding` request meshes over.
"""
function direct_devices(client::Reactant.XLA.AbstractClient; count = nothing)
    devs = collect(Reactant.XLA.addressable_devices(client))
    sort!(devs; by = Reactant.XLA.device_ordinal)
    count === nothing && return devs
    n = Int(count)
    n <= length(devs) ||
        error("asked to shard across $n device(s) but the " *
              "$(Reactant.XLA.platform_name(client)) client has only " *
              "$(length(devs)) addressable device(s)")
    return devs[1:n]
end

# The per-variable blocks of the flat state, as (first slot, last slot, name).
# Derived from the var map `direct_rhs` was given: a cell name is `v[i,j]`, a
# scalar state is a bare name, and the layout guarantees each variable's slots
# are contiguous. Returns `nothing` when the wrapper was built without a var map
# (no names, so no block structure to check against).
function _de_state_blocks(names::Dict{Int,String}, n::Int)
    isempty(names) && return nothing
    base = Vector{String}(undef, n)
    for i in 1:n
        nm = get(names, i, "")
        isempty(nm) && return nothing
        b = findfirst('[', nm)
        base[i] = b === nothing ? nm : nm[1:prevind(nm, b)]
    end
    blocks = Tuple{Int,Int,String}[]
    start = 1
    for i in 2:n
        base[i] == base[i - 1] && continue
        push!(blocks, (start, i - 1, base[i - 1]))
        start = i
    end
    push!(blocks, (start, n, base[n]))
    return blocks
end

# Refuse a slab cut that is neither "inside one block" nor "whole blocks".
function _de_check_block_alignment(blocks, n::Int, ndev::Int)
    blocks === nothing && return nothing   # no var map: nothing to check against
    width = n ÷ ndev
    edges = Set{Int}(b[2] for b in blocks)          # last slot of each block
    for d in 0:(ndev - 1)
        lo = d * width + 1
        hi = lo + width - 1
        hit = [b for b in blocks if b[1] <= hi && b[2] >= lo]
        length(hit) == 1 && continue                 # inside one block: a cell range
        # several blocks: accept only if the slab is exactly whole blocks.
        (hit[1][1] == lo && hit[end][2] == hi) && continue
        partial = String[b[3] for b in hit if b[1] < lo || b[2] > hi]
        _de_refuse("a cell-axis shard slab that straddles a variable block",
            "device $d would hold flat slots $lo:$hi, which is a partial piece " *
            "of more than one state variable (" * join(partial, ", ") * "). The " *
            "flat state lays each variable's cells end to end, so a contiguous " *
            "slab is a clean cell shard only when it stays inside one " *
            "variable's block or covers whole blocks. Shard across a device " *
            "count that divides the block structure, or leave `sharding` unset " *
            "and run on one device. Block boundaries end at flat slots " *
            join(sort!(collect(edges)), ", ") * ".")
    end
    return nothing
end

# `spec` -> a DirectShard, or `nothing` for "run on one device".
_de_resolve_shard(::Nothing, client, n::Int, names::Dict{Int,String}) = nothing
function _de_resolve_shard(spec, client, n::Int, names::Dict{Int,String})
    devs = if spec isa Integer
        direct_devices(client; count = spec)
    elseif spec === :cells || spec === true || (spec isa AbstractString && lowercase(String(spec)) == "cells")
        direct_devices(client)
    elseif spec isa AbstractVector
        collect(spec)
    else
        error("unknown `sharding` request $(repr(spec)); expected `nothing`, " *
              "`:cells`, a device count, or a vector of devices")
    end
    ndev = length(devs)
    ndev >= 2 ||
        _de_refuse("a cell-axis shard across $ndev device(s)",
            "sharding needs at least two devices; the " *
            "$(Reactant.XLA.platform_name(client)) client exposes $ndev " *
            "addressable device(s). Leave `sharding` unset to run on one.")
    n % ndev == 0 ||
        _de_refuse("a cell-axis shard of a $n-slot state across $ndev devices",
            "the flat state length is not divisible by the device count, so the " *
            "slabs would be ragged. Shard across a device count that divides " *
            "$n, or leave `sharding` unset.")
    blocks = _de_state_blocks(names, n)
    _de_check_block_alignment(blocks, n, ndev)
    mesh = Reactant.Sharding.Mesh(reshape(collect(Int64, Reactant.XLA.device_ordinal.(devs)),
                                          ndev), (_DE_MESH_AXIS,))
    return DirectShard(mesh,
                       Reactant.Sharding.NamedSharding(mesh, (_DE_MESH_AXIS,)),
                       Reactant.Sharding.Replicated(mesh), ndev)
end

# ---- device-resident inputs --------------------------------------------------

"""
    direct_state(d, u) -> ConcreteRArray

The flat state `u` as a device array on `d`'s client, carrying `d`'s cell-axis
sharding when one was requested. Feed this to the compiled program; `Array(...)`
on the result brings `du` back.
"""
# RETURN TYPES ARE DECLARED ABSTRACT on purpose. A sharded `ConcreteRArray`
# across N devices is `ConcretePJRTArray{Float64,1,N}` — a DIFFERENT concrete
# type from the unsharded `...,1}` — so a helper whose device count is a runtime
# value returns a union over N. Letting that union reach the `Reactant.@compile`
# call site makes Julia split it there, and the split is deep enough to print
# "detected a stack overflow" (non-fatal, but it costs minutes of inference per
# compile). Widening here stops it at the source.
function direct_state(d::DirectCallable, u::AbstractVector)::Reactant.AbstractConcreteArray{Float64,1}
    a = Array{Float64,1}(u)
    sh = direct_shard(d)
    sh === nothing && return Reactant.ConcreteRArray(a; client = direct_client(d))
    return Reactant.ConcreteRArray(a; client = direct_client(d), sharding = sh.state)
end

"""
    direct_time(d, t) -> ConcreteRNumber

The time input on `d`'s client, replicated across the shard's devices.
"""
function direct_time(d::DirectCallable, t::Real)::Reactant.AbstractConcreteNumber{Float64}
    x = Float64(t)
    sh = direct_shard(d)
    sh === nothing && return Reactant.ConcreteRNumber(x; client = direct_client(d))
    return Reactant.ConcreteRNumber(x; client = direct_client(d),
                                    sharding = sh.replicated)
end

"""
    direct_params(d, p) -> NamedTuple

The parameter NamedTuple with every value moved to `d`'s client as a
`ConcreteRNumber` (replicated under a shard), so that a fixture's parameter
overrides change the VALUES fed to one executable rather than forcing another
compile. `nothing` passes through.
"""
direct_params(d::DirectCallable, ::Nothing) = nothing
direct_params(d::DirectCallable, p::NamedTuple) =
    NamedTuple{keys(p)}(map(v -> direct_time(d, Float64(v)), values(p)))

"""
    direct_buffers(d, bufs) -> container

The live forcing buffers as device arrays on `d`'s client, aligned with
`forcing_buffers(f)`. Forcing buffers are whole-field inputs read by gathers
from anywhere in the domain, so they are REPLICATED rather than sharded: a
sharded forcing field would make every read a collective.
"""
function direct_buffers(d::DirectCallable, bufs)
    cl = direct_client(d)
    sh = direct_shard(d)
    conv(v) = begin
        a = Array{Float64,1}(v)
        sh === nothing ? Reactant.ConcreteRArray(a; client = cl) :
            Reactant.ConcreteRArray(a; client = cl, sharding = sh.replicated)
    end
    return map(conv, bufs)
end
