# ========================================================================
# ext/reactant_direct/device.jl — WHERE the compiled program runs: the XLA
# client (host CPU or an attached GPU) and, across several devices of one
# client, the sharding of the flat state.
# ========================================================================
#
# WHY THIS IS A SEPARATE CONCERN FROM EMISSION. Nothing in the emitted
# StableHLO names a device: the same module compiles on either platform, and the
# platform is fixed by the CLIENT of the arrays fed to it. So device choice
# lives here, on the wrapper, and reaches
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
    DirectCallable{SHARDED} <: Function

The supertype of [`DirectRHS`](@ref) and [`DirectRHSBuffers`](@ref), declared
HERE, before api.jl, so that this file can dispatch on the wrapper. `_de_place`
is the one hook api.jl supplies.

`SHARDED` is a `Bool`: whether the wrapper was built with a cell-axis shard. It
is a TYPE parameter rather than a field or a runtime flag because the two cases
have to be separate METHODS — of the device-input builders below and of the
traced body's tail (`_de_constrain` in api.jl). See "one device is the static
case" below.
"""
abstract type DirectCallable{SHARDED} <: Function end

function _de_place end

# ---- WHY THE PLACEMENT IS NOT A FIELD OF THE CALLABLE ------------------------
#
# `Reactant.@compile d(u, p, t)` traces `d` ITSELF: the callable is an argument
# like any other, so Reactant walks its type and its fields, and Julia infers
# the whole traced call through them. Hanging the placement off `DirectRHS` as a
# field — even one field of one concrete, un-parameterized struct — puts an XLA
# client, and (under a shard) a `Sharding.Mesh` and two `AbstractSharding`s,
# inside what is traced and inferred.
#
# This lane cannot afford that. Inferring a compile of the direct emitter already
# trips Julia's stack-overflow guard several times (the "detected a stack
# overflow" warnings are its ordinary output here), and when one of those unwinds
# at the wrong point the process WEDGES: it stops accumulating CPU inside
# `typeinf`, under Reactant's generated `call_llvm_generator`, and never returns
# — no error, no progress, on the CPU client as readily as on a GPU one. Every
# avoidable thing in the inferred path is therefore worth removing, and an XLA
# client reachable from the traced argument is avoidable.
#
# So the traced object carries nothing about WHERE it runs. `DirectRHS` is
# exactly the three fields the unsharded lane had (`f`, `names`, `stats`), and
# the placement lives HERE, in a module-level table keyed by the callable's
# identity. The accessors below read it, the input builders read it, and
# `_de_run` reads the shard out of it AT TRACE TIME to attach the
# `sharding_constraint` — a value looked up beside the trace, never a field
# inside it.
#
# The table holds its keys WEAKLY, so a wrapper that goes out of scope takes its
# placement with it. `DirectRHS` is mutable, so identity is its own; hashing and
# equality on it are `objectid` / `===`, which is what makes the table an
# identity table. `Base.WeakKeyDict` carries its own lock, so concurrent builds
# are safe.
const _DE_PLACES = Base.WeakKeyDict{Any,Any}()

"""
    _de_register_place!(d, place) -> d

Record `place` as the placement of the callable `d`. Called once, by
[`direct_rhs`](@ref), on a freshly built wrapper.
"""
function _de_register_place!(d, place)
    _DE_PLACES[d] = place
    return d
end

# The placement of `d`, or — for a wrapper built before any was recorded — the
# default one: Reactant's own default backend, unsharded, which is what the
# lane did before device choice existed.
_de_lookup_place(d) =
    get(() -> DirectPlace(Reactant.XLA.default_backend(), nothing), _DE_PLACES, d)

# `_de_run` reads the shard through this lookup WHILE TRACING, to attach the
# `sharding_constraint` to `du`. Nothing inside it is a traced operation — it is
# a host-side table read — so Reactant is told not to rewrite it, which keeps
# `WeakKeyDict`'s lock and finalizer machinery out of the traced function's
# inference. `Reactant.@skip_rewrite_func` is the documented way to say that;
# per its docstring it is invoked both at global scope (so precompilation sees
# it) and from the extension's `__init__` (so a loaded-from-cache session does).
# THE WALK ITSELF IS SKIPPED TOO, and for a stronger reason than tidiness.
#
# Reactant's interpreter rewrites every type-unstable call in a traced body into
# its generated `call_with_reactant`, and that generator runs a whole nested
# GPUCompiler inference to produce the replacement code. `_de_emit!` is a
# RECURSIVE walk over the tree-walk IR, whose `_Node.payload` is `Any`, so
# without this every level of the IR was one more nested generator: the compile
# wedged inside `typeinf`, or printed "detected a stack overflow" and took the
# process down with SIGSEGV, at a depth that depends on the fixture and on what
# inference happened to have cached. A BIGGER stack makes it worse, not better —
# it lets the nesting run deeper before the guard fires, so the crash lands
# further inside Reactant's own machinery. The default stack is the right one.
#
# The walk does not need the interpreter. It builds `stablehlo.*` operations
# directly on the traced values' `mlir_data` and otherwise reads host data, so
# there is no `@reactant_overlay` method for the interpreter to find. Marking
# the entry is enough: a skipped call is left alone in the rewritten body and
# runs NATIVELY, and nothing reachable from it is rewritten either, so one mark
# covers the whole recursion rather than one mark per function on the cycle.
# (`Reactant.should_rewrite_call` consults the skip set per FUNCTION, not per
# method signature, and it is consulted only where a rewritten body calls out.)
#
# The two places under the walk that DO want Reactant's own semantics say so by
# name instead: `Reactant.Ops.reduce` re-enters the interpreter itself when it
# traces a reduction body, and interp.jl hands its lane evaluators back with an
# explicit `Reactant.call_with_reactant`. Both are O(1) in the grid and neither
# nests, so the generator depth under `@compile` is now a small constant.
function _de_skip_rewrite!()
    Reactant.@skip_rewrite_func _de_lookup_place
    Reactant.@skip_rewrite_func _de_emit!
    return nothing
end
_de_skip_rewrite!()

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
direct_client(d::DirectCallable) = _de_place(d).client::Reactant.XLA.AbstractClient
direct_shard(d::DirectCallable) = _de_place(d).shard::Union{Nothing,DirectShard}
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
    # Abstractly typed, and kept OUT of the traced callable entirely (see "why
    # the placement is not a field of the callable" above): a mesh and a
    # sharding reachable from the object `Reactant.@compile` traces is what
    # wedged inference at the call site.
    mesh::Reactant.Sharding.Mesh
    state::Reactant.Sharding.AbstractSharding
    replicated::Reactant.Sharding.AbstractSharding
    ndevices::Int
end

"""
    DirectPlace

The placement recorded for a [`DirectRHS`](@ref): the XLA client its device
inputs are built on, and the cell-axis [`DirectShard`](@ref) or `nothing`. It is
NOT a field of the wrapper — it is held beside it, in `_DE_PLACES` — because a
callable that carries it is a callable `Reactant.@compile` cannot get through.
Read it through [`direct_client`](@ref) and [`direct_shard`](@ref).
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

# ---- ONE DEVICE IS THE STATIC CASE ------------------------------------------
#
# The values these builders return are the ARGUMENTS of `Reactant.@compile`, so
# their Julia types are what the compile is inferred through. A sharded
# `ConcreteRArray` across N devices is `ConcretePJRTArray{Float64,1,N}` — a
# different concrete type from the unsharded `...,1}` — so ONE builder that
# decides at runtime returns either a union over N or, if the return type is
# declared, an abstract `AbstractConcreteArray`. Either shape reaching the
# `@compile` call site sends inference into a recursion that trips the
# stack-overflow guard and then wedges the compile: the process stops
# accumulating CPU inside `typeinf` and never comes back. Declaring the abstract
# return type does NOT avoid this — it is one of the two shapes that cause it.
#
# So the builders are split on `SHARDED` instead. The unsharded methods — the
# ones every one-device run and the whole `compiled_rhs` tier take — have a
# single return path with a fully concrete type, and infer like the unsharded
# lane always did. Only the sharded methods are type-unstable in the device
# count, and only a sharded run pays for it.

"""
    direct_state(d, u) -> ConcreteRArray

The flat state `u` as a device array on `d`'s client, carrying `d`'s cell-axis
sharding when one was requested. Feed this to the compiled program; `Array(...)`
on the result brings `du` back.
"""
direct_state(d::DirectCallable{false}, u::AbstractVector) =
    Reactant.ConcreteRArray(Array{Float64,1}(u); client = direct_client(d))
direct_state(d::DirectCallable{true}, u::AbstractVector) =
    Reactant.ConcreteRArray(Array{Float64,1}(u); client = direct_client(d),
                            sharding = (direct_shard(d)::DirectShard).state)

"""
    direct_time(d, t) -> ConcreteRNumber

The time input on `d`'s client, replicated across the shard's devices.
"""
direct_time(d::DirectCallable{false}, t::Real) =
    Reactant.ConcreteRNumber(Float64(t); client = direct_client(d))
direct_time(d::DirectCallable{true}, t::Real) =
    Reactant.ConcreteRNumber(Float64(t); client = direct_client(d),
                             sharding = (direct_shard(d)::DirectShard).replicated)

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
function direct_buffers(d::DirectCallable{false}, bufs)
    cl = direct_client(d)
    return map(v -> Reactant.ConcreteRArray(Array{Float64,1}(v); client = cl), bufs)
end
function direct_buffers(d::DirectCallable{true}, bufs)
    cl = direct_client(d)
    rep = (direct_shard(d)::DirectShard).replicated
    return map(v -> Reactant.ConcreteRArray(Array{Float64,1}(v); client = cl,
                                            sharding = rep), bufs)
end
