# A reentrant right-hand side (API_SPEC §5.8, "Public right-hand side";
# issue #541): what a program shares, what a workspace owns, and forcing as an
# argument.
#
# A program (`rhs_program`, `select`, `restrict`, `lanes`; range_restricted.jl)
# is an ordinary native build whose `f!` is kept as a TEMPLATE: `rhs!` never
# calls it. Every piece of per-call state that `f!` touches — the prelude cache
# and its CONST/TIME stamps, kernel scratch, observed buffers, loop counters,
# threading verdicts, the forcing buffers it gathers, a lane program's lane
# buffers — is a mutable object reachable from that closure. A workspace holds
# a private instance of the template (`_instantiate`): every such object
# copied, the generated code and every other immutable leaf shared, and every
# forcing read redirected to the workspace's own slot buffer, which `rhs!`
# fills from the caller's `ForcingSet` once per set. Two workspaces share no
# mutable object, so calls on distinct workspaces are reentrant whatever tier
# each rule landed on.

# ============================================================================
# Slots and sets
# ============================================================================

"""
    ParamSlot

One entry of a program's parameter vector ([`parameters`](@ref)): the flattened
parameter `name` and its `default`, the value the Problem resolved (the
document default, or the `esm_problem(…; p)` override).
"""
struct ParamSlot
    name::String
    default::Union{Nothing,Float64}
end

"""
    ForcingSlot

One buffer of a [`ForcingSet`](@ref) ([`forcing_slots`](@ref)): the forcing
`name`, its `shape` (column-major, first index fastest, as the state) and its
`kind`: `:forcing` (a live forcing buffer) or `:array_parameter` (a shaped
parameter made a run-time input by `esm_problem(…; runtime_array_parameters =
true)`).
"""
struct ForcingSlot
    name::String
    shape::Vector{Int}
    kind::Symbol
end

Base.:(==)(a::ForcingSlot, b::ForcingSlot) =
    a.name == b.name && a.shape == b.shape && a.kind === b.kind

# What every program built from one Problem shares (and what identifies a
# program to its workspaces): the parameter and forcing-slot signatures and the
# buffers its template `f!` gathers. Mutable for identity only; never written.
mutable struct _RhsShared
    const params::Vector{ParamSlot}
    const slots::Vector{ForcingSlot}
    # The template's forcing buffers, in slot order: the Problem's live buffers.
    const originals::Vector{Array{Float64}}
    # Buffers a lane program writes per call (lane indices, pre-gathered
    # inputs); a workspace owns its own copy of each.
    const lane_originals::Vector{Vector{Float64}}
end

_RhsShared(params, slots, originals) =
    _RhsShared(params, slots, originals, Vector{Float64}[])

# The same signatures, a different program (a tile, a lane program).
_RhsShared(s::_RhsShared, lane_originals::Vector{Vector{Float64}} = Vector{Float64}[]) =
    _RhsShared(s.params, s.slots, s.originals, lane_originals)

"""
    ForcingSet

The forcing inputs of one evaluation (API_SPEC §5.8): one dense column-major
buffer per [`forcing_slots`](@ref) entry and a process-unique epoch. A set is
immutable by contract: it holds the caller's buffers by reference, and a caller
that changes a value builds a new set ([`replace`](@ref) shares every other
buffer). Build one with [`forcing_set`](@ref) or [`default_forcing_set`](@ref).
"""
struct ForcingSet
    slots::Vector{ForcingSlot}
    arrays::Vector{Array{Float64}}   # as given, for the caller
    flat::Vector{Vector{Float64}}    # the same memory, linear
    epoch::UInt64
end

# One process-wide counter: two sets never share an epoch, so a workspace that
# primed epoch `e` holds exactly that set's contents.
const _FORCING_SET_EPOCH = Threads.Atomic{UInt64}(0)
_next_set_epoch() = Threads.atomic_add!(_FORCING_SET_EPOCH, UInt64(1)) + UInt64(1)

_slots_of(x) = x.shared.slots

"""
    forcing_slots(prog) -> Vector{ForcingSlot}

The buffers a [`ForcingSet`](@ref) of `prog` (a program, a tile or a lane
program) holds, in order: the Problem's forcing buffers sorted by name, the
order [`forcing_buffers`](@ref)`(prob)` uses.
"""
forcing_slots(x) = _slots_of(x)

function _slot_buffer(s::ForcingSlot, buf)
    buf isa AbstractArray || throw(ArgumentError(
        "forcing_set: the buffer for '$(s.name)' is a $(typeof(buf)), not an array"))
    a = buf isa Array{Float64} ? buf : Array{Float64}(buf)
    n = prod(s.shape; init = 1)
    if size(a) == Tuple(s.shape) || (ndims(a) == 1 && length(a) == n)
        return a
    end
    throw(DimensionMismatch("forcing_set: the buffer for '$(s.name)' has size " *
        "$(size(a)); the slot's shape is $(Tuple(s.shape)) (column-major, or flat of " *
        "length $n)"))
end

function _make_set(slots::Vector{ForcingSlot}, arrays::Vector{Array{Float64}})
    flat = Vector{Float64}[vec(a) for a in arrays]
    return ForcingSet(slots, arrays, flat, _next_set_epoch())
end

"""
    forcing_set(prog, bufs) -> ForcingSet

A forcing set for `prog` (API_SPEC §5.8): `bufs` is a NamedTuple or a dictionary
keyed by slot name, or a vector in [`forcing_slots`](@ref) order. Every slot is
required; each buffer has the slot's shape (or is flat, column-major). The
buffers are held by reference, not copied; the set gets a new epoch.
"""
function forcing_set(x, bufs)
    slots = _slots_of(x)
    arrays = Vector{Array{Float64}}(undef, length(slots))
    if bufs isa NamedTuple || bufs isa AbstractDict
        names = Set{String}(s.name for s in slots)
        for k in keys(bufs)
            String(k) in names || throw(ArgumentError(
                "forcing_set: '$k' is not a forcing slot of this program; its slots are " *
                (isempty(slots) ? "none" : join((s.name for s in slots), ", "))))
        end
        for (i, s) in enumerate(slots)
            v = bufs isa NamedTuple ? get(bufs, Symbol(s.name), nothing) :
                get(bufs, s.name, get(bufs, Symbol(s.name), nothing))
            v === nothing && throw(ArgumentError(
                "forcing_set: no buffer for the forcing slot '$(s.name)'"))
            arrays[i] = _slot_buffer(s, v)
        end
    else
        length(bufs) == length(slots) || throw(DimensionMismatch(
            "forcing_set: $(length(bufs)) buffers for $(length(slots)) forcing slots"))
        for (i, (s, v)) in enumerate(zip(slots, bufs))
            arrays[i] = _slot_buffer(s, v)
        end
    end
    return _make_set(slots, arrays)
end

"""
    default_forcing_set(prog) -> ForcingSet

A forcing set holding a copy of the Problem's forcing buffers as they are now.
"""
default_forcing_set(x) =
    _make_set(_slots_of(x), Array{Float64}[copy(a) for a in x.shared.originals])

_slot_index(fs::ForcingSet, k::Integer) =
    1 <= k <= length(fs.slots) ? Int(k) :
    throw(ArgumentError("replace: slot $k of a set with $(length(fs.slots)) slots"))
function _slot_index(fs::ForcingSet, name::Union{AbstractString,Symbol})
    i = findfirst(s -> s.name == String(name), fs.slots)
    i === nothing && throw(ArgumentError("replace: '$name' is not a forcing slot of this set"))
    return i
end

"""
    replace(fs::ForcingSet, slot => buf, …) -> ForcingSet

A new set with a new epoch, sharing every buffer of `fs` but the replaced ones.
`slot` is a slot index or name.
"""
function Base.replace(fs::ForcingSet, reps::Pair...)
    arrays = copy(fs.arrays)
    for r in reps
        i = _slot_index(fs, first(r))
        arrays[i] = _slot_buffer(fs.slots[i], last(r))
    end
    return _make_set(fs.slots, arrays)
end

"""
    forcing_epoch(fs::ForcingSet) -> UInt64

The set's epoch: unique in the process, never reused.
"""
forcing_epoch(fs::ForcingSet) = fs.epoch

# ============================================================================
# Parameters
# ============================================================================

"""
    parameter_vector(prog, overrides = Dict()) -> Vector{Float64}

The parameter vector of `prog` in [`parameters`](@ref) order: each entry the
override named for it, else its default. Strict: an override naming no
parameter, or a parameter with neither, is an error naming it.
"""
function parameter_vector(x, overrides::AbstractDict = Dict{String,Float64}())
    ps = x.shared.params
    idx = Dict{String,Int}(s.name => i for (i, s) in enumerate(ps))
    for k in keys(overrides)
        haskey(idx, String(k)) || throw(SimulateError(
            "parameter_vector: '$k' is not a parameter of this program; its parameters are " *
            (isempty(ps) ? "none" : join((s.name for s in ps), ", "))))
    end
    out = Vector{Float64}(undef, length(ps))
    for (i, s) in enumerate(ps)
        v = get(overrides, s.name, get(overrides, Symbol(s.name), nothing))
        v === nothing && (v = s.default)
        v === nothing && throw(SimulateError(
            "parameter_vector: the parameter '$(s.name)' has no default and no override"))
        out[i] = Float64(v)
    end
    return out
end

# ============================================================================
# Workspaces: a private instance of a program's template
# ============================================================================

"""
    RhsWorkspace

The mutable state of [`rhs!`](@ref) on one program (API_SPEC §5.8): a private
instance of the program's compiled right-hand side (its caches, scratch and
stamps), the internal state and derivative vectors, a buffer per forcing slot
and the epoch of the forcing set it last loaded. One per concurrent caller;
usable with the program that made it only.
"""
mutable struct RhsWorkspace{F}
    const shared::_RhsShared
    const f!::F
    const u::Vector{Float64}
    const du::Vector{Float64}
    # Per forcing slot, the buffer the instance gathers (empty for a slot it
    # does not read), and whether it reads it.
    const fbufs::Vector{Vector{Float64}}
    const fused::Vector{Bool}
    # Per lane buffer of a lane program (`shared.lane_originals` order).
    const lbufs::Vector{Vector{Float64}}
    const epochs::Vector{_ForcingEpoch}
    const env::Dict{String,Int}
    primed::UInt64
end

# The instantiation walk: a deep copy that shares immutable leaves and the
# generated code, substitutes buffers by memory, and gives every forcing epoch
# and threading verdict its workspace form.
struct _InstCtx
    d::IdDict{Any,Any}
    ptrs::Vector{Tuple{UInt,Int,Int}}       # (data pointer, length, buffer index)
    subs::Vector{Vector{Float64}}           # buffer index → its replacement
    hit::Vector{Bool}
    epochs::Vector{_ForcingEpoch}
end

const _INST_SHARED_LEAVES = Union{String,Symbol,Expr,Module,DataType,UnionAll,Union,
                                  Core.TypeName,Method,Core.MethodInstance,GlobalRef,
                                  Regex,RuntimeGeneratedFunctions.RuntimeGeneratedFunction}

function _inst_error(what)
    throw(ErrorException("internal error: a program's right-hand side holds $what, " *
                         "which a workspace cannot instantiate"))
end

# A Float64 array aliasing a substituted buffer: the replacement (reshaped to
# the alias's shape), `nothing` when it aliases none. A partial overlap fails
# closed: the instance would otherwise keep a private copy of forcing memory.
function _inst_subst(x::Array{Float64}, c::_InstCtx)
    isempty(x) && return nothing
    p = UInt(pointer(x))
    n = length(x)
    for (q, m, k) in c.ptrs
        if p == q && n == m
            c.hit[k] = true
            s = c.subs[k]
            return x isa Vector{Float64} ? s : reshape(s, size(x))
        end
        (p < q + 8m && q < p + 8n) &&
            _inst_error("an array overlapping part of a forcing or lane buffer")
    end
    return nothing
end

@static if isdefined(Base, :Memory)
    _is_memory(x) = x isa Memory
else
    _is_memory(x) = false
end

function _inst(@nospecialize(x), c::_InstCtx)
    isbits(x) && return x
    x isa _INST_SHARED_LEAVES && return x
    if ismutable(x)
        y = get(c.d, x, c)
        y === c || return y
    end
    if x isa _ForcingEpoch
        e = _ForcingEpoch(UInt64(0), false)
        push!(c.epochs, e)
        return c.d[x] = e
    elseif x isa _SecTCache
        # Serial: the workspace path never dispatches to Polyester's pool.
        return c.d[x] = _SecTCache(-3, x.ncells, x.disjoint, x.work, 1, nothing, nothing, x.rmw)
    elseif x isa Array
        if x isa Array{Float64}
            s = _inst_subst(x, c)
            s === nothing || return c.d[x] = s
        end
        isbitstype(eltype(x)) && return Base.deepcopy_internal(x, c.d)
        y = similar(x)
        c.d[x] = y
        @inbounds for i in eachindex(x)
            isassigned(x, i) && (y[i] = _inst(x[i], c))
        end
        return y
    elseif _is_memory(x)
        isbitstype(eltype(x)) && return Base.deepcopy_internal(x, c.d)
        _inst_error("a $(typeof(x))")
    elseif x isa Union{Dict,IdDict}
        y = empty(x)
        c.d[x] = y
        for (k, v) in x
            y[_inst(k, c)] = _inst(v, c)
        end
        return y
    elseif x isa Union{Task,Base.AbstractLock,Base.GenericCondition,Channel,WeakKeyDict,Ptr}
        _inst_error("a $(typeof(x))")
    end
    y = _inst_struct(x, c)
    if y isa _CSECache || y isa _ObsExtVec
        # A fresh instance holds no valid tier: its forcing is not loaded yet.
        y.stamp64 = _CSE_INVALID
        y.stampalt = _CSE_INVALID
        y.tp64 = _CSE_INVALID
        y.tpalt = _CSE_INVALID
    end
    return y
end

function _inst_struct(@nospecialize(x), c::_InstCtx)
    T = typeof(x)::DataType
    nf = nfields(x)
    if ismutable(x)
        y = ccall(:jl_new_struct_uninit, Any, (Any,), T)
        c.d[x] = y
        for i in 1:nf
            isdefined(x, i) || continue
            xi = getfield(x, i)
            xi isa Ptr && _inst_error("a raw pointer in a $(T)")
            isbits(xi) || (xi = _inst(xi, c))
            ccall(:jl_set_nth_field, Cvoid, (Any, Csize_t, Any), y, i - 1, xi)
        end
        return y
    end
    nf == 0 && return x
    flds = Vector{Any}(undef, nf)
    for i in 1:nf
        if !isdefined(x, i)
            nf = i - 1
            break
        end
        xi = getfield(x, i)
        xi isa Ptr && _inst_error("a raw pointer in a $(T)")
        flds[i] = isbits(xi) ? xi : _inst(xi, c)
    end
    return ccall(:jl_new_structv, Any, (Any, Ptr{Any}, UInt32), T, flds, nf)
end

# A workspace for the template `f!` of a program sharing `shared`, whose
# internal slot space has `n` entries.
function _new_workspace(shared::_RhsShared, template, n::Int)
    bufs = Array{Float64}[shared.originals..., shared.lane_originals...]
    nf = length(shared.originals)
    subs = Vector{Float64}[zeros(length(b)) for b in bufs]
    ptrs = Tuple{UInt,Int,Int}[(UInt(pointer(b)), length(b), k)
                               for (k, b) in enumerate(bufs) if !isempty(b)]
    c = _InstCtx(IdDict{Any,Any}(), ptrs, subs, fill(false, length(bufs)), _ForcingEpoch[])
    f = _inst(template, c)
    fbufs = Vector{Float64}[c.hit[k] ? subs[k] : Float64[] for k in 1:nf]
    return RhsWorkspace(shared, f, zeros(n), zeros(n), fbufs, c.hit[1:nf],
                        subs[(nf + 1):end], c.epochs,
                        Dict{String,Int}(), UInt64(0))
end

function _check_workspace(shared::_RhsShared, ws::RhsWorkspace)
    ws.shared === shared || throw(ArgumentError(
        "rhs!: the workspace was made by rhs_workspace of another program"))
    return nothing
end

# Every memoized value that read a forcing or lane buffer is TIME tier and
# stamps the instance's epochs; moving them refills it on the next call.
@inline function _bump_workspace_epochs!(ws::RhsWorkspace)
    @inbounds for e in ws.epochs
        _bump_epoch!(e)
    end
    return nothing
end

# Load `fs` into the workspace when it is not the set the workspace holds: the
# one copy per (workspace, set), never one per call.
function _prime!(ws::RhsWorkspace, fs::ForcingSet)
    fs.epoch == ws.primed && return nothing
    slots = ws.shared.slots
    (fs.slots === slots || fs.slots == slots) || throw(ArgumentError(
        "rhs!: the forcing set was made for another program (its slots are " *
        "$(join((s.name for s in fs.slots), ", ")); this program's are " *
        "$(join((s.name for s in slots), ", ")))"))
    @inbounds for k in eachindex(ws.fbufs)
        ws.fused[k] && copyto!(ws.fbufs[k], fs.flat[k])
    end
    _bump_workspace_epochs!(ws)
    ws.primed = fs.epoch
    return nothing
end
