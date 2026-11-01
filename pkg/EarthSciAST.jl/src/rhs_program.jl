# A reentrant right-hand side (API_SPEC §5.8, "Public right-hand side";
# issue #541): what a program shares, what a workspace owns, and forcing as an
# argument.
#
# A program (`rhs_program`, `select`, `restrict`, `lanes`; range_restricted.jl)
# is an ordinary native build whose `f!` is kept as a TEMPLATE: `rhs!` never
# calls it. The build also records what a workspace needs to make a private
# instance of it (`_ws_factory`): which objects are per-call state (caches and
# their CONST/TIME stamps, scratch, loop counters, threading verdicts), where
# the template reads each forcing and lane buffer, and the path from the root
# to each. A workspace (`_instantiate`) owns fresh copies of the state and its
# own buffer per forcing slot, which `rhs!` fills from the caller's
# `ForcingSet` once per set; the generated code and every read-only table are
# shared with the program. Two workspaces share nothing a call writes, so
# calls on distinct workspaces are reentrant whatever tier each rule landed on.

# ============================================================================
# Slots and sets
# ============================================================================

"""
    ParamSlot

One entry of a program's parameter vector ([`parameters`](@ref)): the flattened
parameter `name` and its declared `default` (`nothing` when it declares none).
"""
struct ParamSlot
    name::String
    default::Union{Float64, Nothing}
end

Base.:(==)(a::ParamSlot, b::ParamSlot) = a.name == b.name && isequal(a.default, b.default)

"""
    ForcingSlot

One buffer of a [`ForcingSet`](@ref) ([`forcing_slots`](@ref)): the flattened
`name`, its resolved `shape` (empty for a 0-d input) and its `kind`: `:forcing`
(an externally fed parameter: its `update` takes its value from a data source or
a handler) or `:array_parameter` (any other parameter the program reads as a
run-time array: a shaped parameter with a value under
`esm_problem(…; runtime_array_parameters = true)`, or one whose buffer the
caller bound through `param_arrays`).
"""
struct ForcingSlot
    name::String
    shape::Vector{Int}
    kind::Symbol
end

Base.:(==)(a::ForcingSlot, b::ForcingSlot) =
    a.name == b.name && a.shape == b.shape && a.kind === b.kind

"""
    StateBlock

One block of a program's `u` ([`state_layout`](@ref)): the flattened state
`name`, the 1-based `offset` of its first element, and its `shape` (empty for a
0-d state). Column-major, first index fastest.
"""
struct StateBlock
    name::String
    offset::Int
    shape::Vector{Int}
end

Base.:(==)(a::StateBlock, b::StateBlock) =
    a.name == b.name && a.offset == b.offset && a.shape == b.shape

"""
    ForcingSet

The forcing inputs of an evaluation (API_SPEC §5.8): one column-major buffer per
[`forcing_slots`](@ref) entry, in slot order, and an epoch no other set in the
process carries. Never mutated: the set holds its buffers by reference, so
writing into one after building the set is undefined behaviour (the epoch would
not change); build a new set instead ([`replace_forcing`](@ref) shares every
other buffer). Build one with [`forcing_set`](@ref) or
[`default_forcing_set`](@ref).
"""
mutable struct ForcingSet
    # Mutable for a stable address only (a holder stores the reference, never
    # a boxed copy); never written.
    const slots::Vector{ForcingSlot}
    const bufs::Vector{Vector{Float64}}
    const epoch::UInt64
end

# One process-wide counter, one value per set built: a workspace that primed
# epoch `e` holds exactly that set's contents.
const _FORCING_SET_EPOCH = Threads.Atomic{UInt64}(0)
_next_set_epoch() = Threads.atomic_add!(_FORCING_SET_EPOCH, UInt64(1)) + UInt64(1)

# A scalar externally fed parameter is a 0-d forcing slot of a program, not a
# parameter (API_SPEC §5.8, "Forcing sets"). The build reads forcing through
# arrays, so the program's flattened system declares it over a one-cell index
# set and reads `index(name, 1)` wherever it read `name`; its buffer holds the
# one value.
const _SCALAR_SLOT_SET = "__esm_scalar_slot"

_is_scalar_slot(v) = v isa ModelVariable && !_is_array_shape(v.shape) && _externally_fed(v)

function _scalar_slots_to_arrays(flat::FlattenedSystem)
    names = String[n for (n, v) in flat.parameters if _is_scalar_slot(v)]
    isempty(names) && return flat
    b = Dict{String, ASTExpr}(
        n => OpExpr("index", ASTExpr[VarExpr(n), IntExpr(1)])
            for n in names
    )
    sub(e) = substitute(e, b)
    params = OrderedDict{String, ModelVariable}()
    for (n, v) in flat.parameters
        params[n] = n in names ?
            ModelVariable(
                v.type; default = v.default, description = v.description,
                units = v.units, default_units = v.default_units,
                shape = [_SCALAR_SLOT_SET], location = v.location,
                distribution = v.distribution, update = v.update,
                element_type = v.element_type
            ) : v
    end
    sets = copy(flat.index_sets)
    sets[_SCALAR_SLOT_SET] = IndexSet("interval"; size = 1)
    return FlattenedSystem(
        flat;
        parameters = params, index_sets = sets,
        discrete_parameters = OrderedDict{String, ModelVariable}(
            k => get(params, k, v) for (k, v) in flat.discrete_parameters
        ),
        equations = Equation[
            Equation(sub(e.lhs), sub(e.rhs); _comment = e._comment)
                for e in flat.equations
        ],
        equation_contributions = Vector{Contribution}[
            Contribution[Contribution(sub(c.expr), c.origins) for c in cs]
                for cs in flat.equation_contributions
        ]
    )
end

# Whether a parameter's `update` takes its value from a data source or a handler.
_externally_fed(::Nothing) = false
function _externally_fed(v::ModelVariable)
    v.type == ParameterVariable || return false
    for u in something(v.update, ParameterUpdate[])
        (u.from !== nothing || u.handler !== nothing) && return true
    end
    return false
end

_slots_of(x) = x.shared.slots

"""
    forcing_slots(x) -> Vector{ForcingSlot}

The buffers a [`ForcingSet`](@ref) of `x` (a program, a tile or a lane program)
holds, in ascending byte order of flattened name. A derived program has its
parent's slots.
"""
forcing_slots(x) = _slots_of(x)

function _slot_buffer(s::ForcingSlot, buf, what::AbstractString)
    buf isa AbstractArray || throw(
        ArgumentError(
            "$what: the buffer for '$(s.name)' is a $(typeof(buf)), not an array"
        )
    )
    n = prod(s.shape; init = 1)
    length(buf) == n || throw(
        DimensionMismatch(
            "$what: the buffer for '$(s.name)' has $(length(buf)) elements; the slot's " *
                "shape $(Tuple(s.shape)) has $n"
        )
    )
    # An `Array{Float64}` is held as it is (its linear view shares its memory);
    # any other array is read once into one.
    return buf isa Array{Float64} ? vec(buf) : Vector{Float64}(vec(collect(buf)))
end

"""
    forcing_set(x, bufs) -> ForcingSet

A forcing set for `x` (API_SPEC §5.8): `bufs` holds one buffer per
[`forcing_slots`](@ref)`(x)` entry, in slot order, each of `prod(shape)`
elements read in linear (column-major) order. The buffers are held by
reference; the set gets a fresh epoch. A wrong count or length is a
`DimensionMismatch`.
"""
function forcing_set(x, bufs)
    slots = _slots_of(x)
    length(bufs) == length(slots) || throw(
        DimensionMismatch(
            "forcing_set: $(length(bufs)) buffers for $(length(slots)) forcing slots" *
                (isempty(slots) ? "" : " ($(join((s.name for s in slots), ", ")))")
        )
    )
    flat = Vector{Float64}[_slot_buffer(s, b, "forcing_set") for (s, b) in zip(slots, bufs)]
    return ForcingSet(slots, flat, _next_set_epoch())
end

"""
    default_forcing_set(x) -> ForcingSet

The Problem's forcing when [`rhs_program`](@ref) ran — provider data, a
caller's array, or the declared default broadcast over the slot's shape, and an
array parameter's value — copied then. Every call returns the same set; a
derived program returns its parent's.
"""
default_forcing_set(x) = x.shared.default

"""
    replace_forcing(fs::ForcingSet, slot::Integer, buf) -> ForcingSet

A new set with a new epoch: `fs` with its 1-based `slot` holding `buf`, every
other buffer shared. `fs` is unchanged.
"""
function replace_forcing(fs::ForcingSet, slot::Integer, buf)
    1 <= slot <= length(fs.slots) || throw(
        ArgumentError(
            "replace_forcing: slot $slot of a set with $(length(fs.slots)) slots"
        )
    )
    bufs = copy(fs.bufs)
    bufs[slot] = _slot_buffer(fs.slots[slot], buf, "replace_forcing")
    return ForcingSet(fs.slots, bufs, _next_set_epoch())
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
function parameter_vector(x, overrides::AbstractDict = Dict{String, Float64}())
    ps = x.shared.params
    idx = Dict{String, Int}(s.name => i for (i, s) in enumerate(ps))
    for k in keys(overrides)
        haskey(idx, String(k)) || throw(
            SimulateError(
                "parameter_vector: '$k' is not a parameter of this program; its parameters are " *
                    (isempty(ps) ? "none" : join((s.name for s in ps), ", "))
            )
        )
    end
    out = Vector{Float64}(undef, length(ps))
    for (i, s) in enumerate(ps)
        v = get(overrides, s.name, get(overrides, Symbol(s.name), nothing))
        v === nothing && (v = s.default)
        v === nothing && throw(
            SimulateError(
                "parameter_vector: the parameter '$(s.name)' has no default and no override"
            )
        )
        out[i] = Float64(v)
    end
    return out
end

# ============================================================================
# Workspaces: an instance factory recorded at program build
# ============================================================================
#
# A program's compiled right-hand side (its template `f!`) is a graph of
# closures and section structs over three kinds of object:
#  - per-call state, of the types in `_WsState`: the prelude and observed
#    caches with their CONST/TIME stamps, kernel scratch, forcing epochs,
#    threading verdicts, contraction masks, loop counters (`Ref`s), boxed
#    closure variables and dictionaries; and every array the build registered
#    as scratch where it allocated it (`_ws_scratch!`), because generated code
#    writes it;
#  - the forcing and lane buffers it reads, which the build recorded by
#    identity (`_ws_note_pgather!`) and the program maps to its slots;
#  - everything else (generated code, const data, index tables, geometry),
#    which nothing writes once the build has finished.
# `_ws_factory` walks the graph once, when the program is built: it records the
# objects of the first two kinds and the spine, the objects on a path from the
# root to one of them. `_instantiate` builds a workspace's private instance from
# that record: a fresh copy of each piece of state, the workspace's own buffer
# wherever the template holds a forcing or lane buffer, a rebuilt spine, and
# every other object shared by reference with the template and every other
# workspace.

# Per-call state: each workspace holds its own.
const _WsState = Union{
    _CSECache, _ObsExtVec, _AccScratch, _ForcingEpoch, _SecTCache, _ACMask,
    Base.RefValue, Core.Box, AbstractDict,
}

# Mutable types a build constructs and never writes afterwards.
const _WsReadOnly = Union{OpExpr}

# Leaves that hold no reference to anything a workspace replaces. A run-time
# equality scatter's flag pool (`_ScatterSeen`, scatter.jl) hands each call its
# own buffer under a lock, so every workspace shares it.
const _WsLeaf = Union{
    String, Symbol, Expr, Module, DataType, UnionAll, Union, Core.TypeName,
    Method, Core.MethodInstance, GlobalRef, Regex,
    RuntimeGeneratedFunctions.RuntimeGeneratedFunction, _ScatterSeen,
}

struct _WsFactory
    template::Any
    # Object → `:state`, `:scratch`, `(:slot, k)` or `(:lane, k)`.
    kinds::IdDict{Any, Any}
    spine::IdDict{Any, Nothing}
    slot_len::Vector{Int}
    slot_read::Vector{Bool}     # whether the template reads slot k at all
    lane_len::Vector{Int}
    n::Int                      # the internal slot count of `u` / `du`
end

# What a program shares with every workspace of it (and what identifies the
# program to them): the parameter and forcing-slot signatures, the default
# forcing set, and the factory of its workspaces. A derived program has its
# parent's signatures and default set and a factory of its own. Mutable for
# identity only; never written.
mutable struct _RhsShared
    const params::Vector{ParamSlot}
    const slots::Vector{ForcingSlot}
    const default::ForcingSet
    const factory::_WsFactory
end

function _ws_refuse(what)
    throw(
        ErrorException(
            "internal error: a program's right-hand side holds $what, " *
                "which a workspace cannot instantiate"
        )
    )
end

@static if isdefined(Base, :Memory)
    _is_memory(x) = x isa Memory
else
    _is_memory(x) = false
end

struct _WsWalk
    kinds::IdDict{Any, Any}
    aliases::IdDict{Any, Any}           # forcing / lane buffer → (:slot | :lane, k)
    scratch::IdDict{Any, Nothing}
    guard::Vector{Tuple{UInt, UInt, String}}   # memory of each forcing / lane buffer
    parents::IdDict{Any, Vector{Any}}
    seen::IdDict{Any, Nothing}
end

function _ws_guard(x::Array{Float64}, w::_WsWalk)
    isempty(x) && return nothing
    p = UInt(pointer(x))
    q = p + UInt(8 * length(x))
    for (a, b, name) in w.guard
        (p < b && a < q) && _ws_refuse(
            "an array over the memory of the live buffer " *
                "'$name' that the build did not record"
        )
    end
    return nothing
end

function _ws_walk!(@nospecialize(x), @nospecialize(parent), w::_WsWalk)
    isbits(x) && return nothing
    x isa _WsLeaf && return nothing
    parent === nothing || push!(get!(Vector{Any}, w.parents, x), parent)
    haskey(w.seen, x) && return nothing
    w.seen[x] = nothing
    a = get(w.aliases, x, nothing)
    if a !== nothing
        w.kinds[x] = a
        return nothing
    end
    if x isa Array && isbitstype(eltype(x))
        if haskey(w.scratch, x)
            w.kinds[x] = :scratch
        elseif x isa Array{Float64}
            _ws_guard(x, w)
        end
        return nothing
    end
    _is_memory(x) && (isbitstype(eltype(x)) ? (return nothing) : _ws_refuse("a $(typeof(x))"))
    x isa Union{
        Task, Base.AbstractLock, Base.GenericCondition, Channel, WeakKeyDict, Ptr,
        Threads.Atomic,
    } && _ws_refuse("a $(typeof(x))")
    if x isa _WsState
        w.kinds[x] = :state
        if x isa Union{_CSECache, _ObsExtVec, _AccScratch}
            # Its buffer may also be read through a codegen table.
            haskey(w.seen, x.f64) || (w.seen[x.f64] = nothing)
            w.kinds[x.f64] = :scratch
        end
        x isa Union{_CSECache, _ObsExtVec} && _ws_walk!(x.epoch, x, w)
        x isa _ACMask && _ws_walk!(x.f, x, w)
        x isa Base.RefValue && isdefined(x, :x) && _ws_walk!(x[], x, w)
        x isa Core.Box && isdefined(x, :contents) && _ws_walk!(x.contents, x, w)
        if x isa AbstractDict
            for (k, v) in x
                _ws_walk!(k, x, w)
                _ws_walk!(v, x, w)
            end
        end
        return nothing
    end
    if x isa Array
        @inbounds for i in eachindex(x)
            isassigned(x, i) && _ws_walk!(x[i], x, w)
        end
        return nothing
    end
    ismutable(x) && !(x isa _WsReadOnly) && _ws_refuse("a mutable $(typeof(x))")
    for i in 1:nfields(x)
        isdefined(x, i) || continue
        xi = getfield(x, i)
        xi isa Ptr && _ws_refuse("a raw pointer in a $(typeof(x))")
        _ws_walk!(xi, x, w)
    end
    return nothing
end

# The factory of the template `f!` (with `n` internal slots) of a build that
# recorded `cap`: `slots` names the forcing slots and `slot_bufs[k]` holds the
# build's own buffer for slot `k`; `lane_bufs` are a lane program's lane
# buffers. Refuses (at program build) a template that reads a live buffer
# through an array the build did not record, and any mutable object the
# factory does not know to be state or read-only.
function _ws_factory(
        template, n::Int, cap::_WsCapture, slots::Vector{ForcingSlot},
        slot_bufs::Vector{<:AbstractArray},
        lane_bufs::Vector{Vector{Float64}} = Vector{Float64}[]
    )
    aliases = IdDict{Any, Any}()
    guard = Tuple{UInt, UInt, String}[]
    function alias!(buf, kind, k, name)
        aliases[buf] = (kind, k)
        return isempty(buf) || push!(
            guard, (
                UInt(pointer(buf)), UInt(pointer(buf)) + UInt(8 * length(buf)),
                name,
            )
        )
    end
    for (k, s) in enumerate(slots)
        alias!(slot_bufs[k], :slot, k, s.name)
        for pg in cap.pgathers
            g = get(pg, s.name, nothing)
            g === nothing || alias!(g.flat, :slot, k, s.name)
        end
    end
    for (k, b) in enumerate(lane_bufs)
        alias!(b, :lane, k, "lane buffer $k")
    end
    w = _WsWalk(
        IdDict{Any, Any}(), aliases, cap.scratch, guard, IdDict{Any, Vector{Any}}(),
        IdDict{Any, Nothing}()
    )
    _ws_walk!(template, nothing, w)
    spine = IdDict{Any, Nothing}()
    stack = collect(Any, keys(w.kinds))
    while !isempty(stack)
        y = pop!(stack)
        for q in get(w.parents, y, ())
            haskey(spine, q) && continue
            spine[q] = nothing
            push!(stack, q)
        end
    end
    read = fill(false, length(slots))
    for k in values(w.kinds)
        k isa Tuple && k[1] === :slot && (read[k[2]] = true)
    end
    return _WsFactory(
        template, w.kinds, spine, Int[length(b) for b in slot_bufs], read,
        Int[length(b) for b in lane_bufs], n
    )
end

# The forcing slot buffers of `pa` (a build's buffer registry), in slot order.
_slot_buffers(slots::Vector{ForcingSlot}, pa) = Array{Float64}[pa[s.name] for s in slots]

struct _InstCtx
    fac::_WsFactory
    memo::IdDict{Any, Any}
    fbufs::Vector{Vector{Float64}}
    lbufs::Vector{Vector{Float64}}
    epochs::Vector{_ForcingEpoch}
    caches::Vector{Any}
end

_inst_buffer(x::Array{Float64}, b::Vector{Float64}) =
    x isa Vector{Float64} ? b : reshape(b, size(x))

function _inst(@nospecialize(x), c::_InstCtx)
    isbits(x) && return x
    y = get(c.memo, x, c)
    y === c || return y
    k = get(c.fac.kinds, x, nothing)
    k === nothing || return _inst_kind(x, k, c)
    haskey(c.fac.spine, x) || return x
    return _inst_spine(x, c)
end

function _inst_kind(@nospecialize(x), @nospecialize(k), c::_InstCtx)
    if k isa Tuple
        b = k[1] === :slot ? c.fbufs[k[2]] : c.lbufs[k[2]]
        return c.memo[x] = _inst_buffer(x, b)
    elseif k === :scratch
        return c.memo[x] = copy(x)
    end
    # A fresh piece of per-call state: no tier it memoizes is valid yet.
    if x isa _CSECache
        y = _CSECache(
            _inst(x.f64, c), nothing, _CSE_INVALID, _CSE_INVALID, _CSE_INVALID,
            NaN, UInt64(0), _CSE_INVALID, _CSE_INVALID, UInt64(0),
            _inst(x.epoch, c)
        )
        push!(c.caches, y)
        return c.memo[x] = y
    elseif x isa _ObsExtVec
        y = _ObsExtVec(
            _inst(x.f64, c), nothing, _CSE_INVALID, _CSE_INVALID, _CSE_INVALID,
            NaN, UInt64(0), _CSE_INVALID, _CSE_INVALID, UInt64(0),
            _inst(x.epoch, c), nothing
        )
        push!(c.caches, y)
        return c.memo[x] = y
    elseif x isa _AccScratch
        return c.memo[x] = _AccScratch(_inst(x.f64, c), nothing)
    elseif x isa _ForcingEpoch
        # A workspace tracks its forcing set's epoch itself, never the
        # process-wide refresh count.
        e = _ForcingEpoch(UInt64(0), false)
        push!(c.epochs, e)
        return c.memo[x] = e
    elseif x isa _SecTCache
        # Serial: a workspace never dispatches to Polyester's pool.
        return c.memo[x] = _SecTCache(
            -3, x.ncells, x.disjoint, x.work, 1, nothing, nothing,
            x.rmw
        )
    elseif x isa _ACMask
        y = typeof(x)(_inst(x.f, c), _CSE_INVALID, 0)
        push!(c.caches, y)
        return c.memo[x] = y
    elseif x isa Base.RefValue
        y = typeof(x)()
        c.memo[x] = y
        isdefined(x, :x) && (y[] = _inst(x[], c))
        return y
    elseif x isa Core.Box
        y = Core.Box()
        c.memo[x] = y
        isdefined(x, :contents) && (y.contents = _inst(x.contents, c))
        return y
    elseif x isa AbstractDict
        y = empty(x)
        c.memo[x] = y
        for (key, v) in x
            y[_inst(key, c)] = _inst(v, c)
        end
        return y
    end
    return _ws_refuse("a $(typeof(x))")
end

function _inst_spine(@nospecialize(x), c::_InstCtx)
    if x isa Array
        y = similar(x)
        c.memo[x] = y
        @inbounds for i in eachindex(x)
            isassigned(x, i) && (y[i] = _inst(x[i], c))
        end
        return y
    end
    T = typeof(x)::DataType
    nf = nfields(x)
    if ismutable(x)
        y = ccall(:jl_new_struct_uninit, Any, (Any,), T)
        c.memo[x] = y
        for i in 1:nf
            isdefined(x, i) || continue
            ccall(
                :jl_set_nth_field, Cvoid, (Any, Csize_t, Any), y, i - 1,
                _inst(getfield(x, i), c)
            )
        end
        return y
    end
    flds = Vector{Any}(undef, nf)
    for i in 1:nf
        if !isdefined(x, i)
            nf = i - 1
            break
        end
        flds[i] = _inst(getfield(x, i), c)
    end
    return c.memo[x] = ccall(:jl_new_structv, Any, (Any, Ptr{Any}, UInt32), T, flds, nf)
end

"""
    RhsWorkspace

The mutable state of [`rhs!`](@ref) on one program (API_SPEC §5.8): a private
instance of the program's compiled right-hand side (its caches, scratch and
stamps; the generated code and every read-only table are the program's), the
internal state and derivative vectors, a buffer per forcing slot the program
reads and the epoch of the forcing set it last loaded. One per concurrent
caller; usable with the program that made it only.
"""
mutable struct RhsWorkspace{F}
    const shared::_RhsShared
    const f!::F
    const u::Vector{Float64}
    const du::Vector{Float64}
    # Per forcing slot, the buffer the instance reads (empty for a slot the
    # program does not read), and whether it reads it.
    const fbufs::Vector{Vector{Float64}}
    const fread::Vector{Bool}
    # Per lane buffer of a lane program.
    const lbufs::Vector{Vector{Float64}}
    const epochs::Vector{_ForcingEpoch}
    # The memoizing caches, whose stamps a failed call invalidates.
    const caches::Vector{Any}
    const env::Dict{String, Int}
    primed::UInt64
end

# A workspace of the program sharing `shared`.
function _instantiate(shared::_RhsShared)
    fac = shared.factory
    fbufs = Vector{Float64}[r ? zeros(n) : Float64[] for (n, r) in zip(fac.slot_len, fac.slot_read)]
    lbufs = Vector{Float64}[zeros(n) for n in fac.lane_len]
    c = _InstCtx(fac, IdDict{Any, Any}(), fbufs, lbufs, _ForcingEpoch[], Any[])
    f = _inst(fac.template, c)
    return RhsWorkspace(
        shared, f, zeros(fac.n), zeros(fac.n), fbufs, copy(fac.slot_read),
        lbufs, c.epochs, c.caches, Dict{String, Int}(), UInt64(0)
    )
end

function _check_workspace(shared::_RhsShared, ws::RhsWorkspace)
    ws.shared === shared || throw(
        ArgumentError(
            "rhs!: the workspace was made by rhs_workspace of another program"
        )
    )
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

# After a call that threw: a tier may be half refilled under the stamp of the
# values it held before, so no memoized value is trusted again until refilled,
# and the next call reloads its forcing set.
function _ws_invalidate!(ws::RhsWorkspace)
    for x in ws.caches
        if x isa Union{_CSECache, _ObsExtVec}
            x.stamp64 = _CSE_INVALID
            x.stampalt = _CSE_INVALID
            x.tp64 = _CSE_INVALID
            x.tpalt = _CSE_INVALID
        elseif x isa _ACMask
            x.stamp = _CSE_INVALID
        end
    end
    _bump_workspace_epochs!(ws)
    ws.primed = UInt64(0)
    return nothing
end

# The instance's `f!` on the workspace's internal vectors, fail-closed.
@inline function _ws_eval!(ws::RhsWorkspace, p, t)
    try
        ws.f!(ws.du, ws.u, p, t)
    catch
        _ws_invalidate!(ws)
        rethrow()
    end
    return nothing
end

function _check_forcing_set(slots::Vector{ForcingSlot}, fs::ForcingSet, call::AbstractString)
    (fs.slots === slots || fs.slots == slots) || throw(
        ArgumentError(
            "$call: the forcing set was made for another program (its slots are " *
                "$(join((s.name for s in fs.slots), ", ")); this program's are " *
                "$(join((s.name for s in slots), ", ")))"
        )
    )
    return nothing
end

function _check_parameters(shared::_RhsShared, p, call::AbstractString)
    p isa AbstractVector || return nothing
    n = length(shared.params)
    length(p) == n || throw(
        DimensionMismatch(
            "$call: `p` has $(length(p)) elements; the program has $n parameters" *
                (n == 0 ? "" : " ($(join((s.name for s in shared.params), ", ")))")
        )
    )
    return nothing
end

# Load `fs` into the workspace when it is not the set the workspace holds: the
# one copy per (workspace, set), never one per call.
function _prime!(ws::RhsWorkspace, fs::ForcingSet)
    fs.epoch == ws.primed && return nothing
    _check_forcing_set(ws.shared.slots, fs, "rhs!")
    @inbounds for k in eachindex(ws.fbufs)
        ws.fread[k] && copyto!(ws.fbufs[k], fs.bufs[k])
    end
    _bump_workspace_epochs!(ws)
    ws.primed = fs.epoch
    return nothing
end
