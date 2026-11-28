# Right-hand sides as program values (API_SPEC §5.8, "Public right-hand side"
# and "Range-restricted right-hand sides").
#
# A Problem's right-hand side evaluates the whole model over the whole domain.
# A program evaluates it, or one OPERATOR of it — the summands a provenance
# selection keeps, writing only the operator's variables (`select`,
# range/selection.jl) — over the whole domain, over a TILE of a horizontal
# decomposition reading halo cells from a local extended array (`restrict`,
# range/tile.jl, sized by the need-box analysis of range/need_analysis.jl), or
# over LANES, a run-time list of cells or columns (`lanes`, range/lanes.jl).
# Every program is the ordinary native build of a rewritten equation stream:
# a tile builds the selected document under a range spec whose seams
# (tree_walk/range_hooks.jl) clip the equation stream to the owned box and lay
# each state out over the cells the tile stores, so the kernels, their offsets
# and their ghost cuts come out rebased by construction.
#
# This file holds what every program shares: what a program shares between
# callers, what a workspace owns, forcing as an argument, the layouts, and the
# build and evaluation of a program.
#
# A program is an ordinary native build whose `f!` is kept as a TEMPLATE: `rhs!` never
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

# The slot's buffer from a provider sample; documented with the name method
# (data_refresh.jl).
forcing_from_sample(sample, slot::ForcingSlot) =
    vec(forcing_from_sample(sample, slot.name; shape = slot.shape))

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
        params[n] = n in names ? reconstruct(v; shape = [_SCALAR_SLOT_SET]) : v
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
                    (isempty(ps) ? "none" : join((s.name for s in ps), ", ")),
                ERROR_CODES.UNKNOWN_OVERRIDE_KEY
            )
        )
    end
    out = Vector{Float64}(undef, length(ps))
    for (i, s) in enumerate(ps)
        v = get(overrides, s.name, get(overrides, Symbol(s.name), nothing))
        v === nothing && (v = s.default)
        v === nothing && throw(
            SimulateError(
                "parameter_vector: the parameter '$(s.name)' has no default and no override",
                ERROR_CODES.PARAMETER_UNBOUND
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

# Per-call state: each workspace holds its own. A type is per-call state when
# it has the three methods below: `_ws_children!` (what the factory walks from
# it), `_ws_fresh` (a workspace's fresh copy of it, valid for no memoized tier
# yet) and `_ws_invalidate!` (its stamps reset after a call that threw; the
# identity for a type with none). A type of the first kind without them is
# refused at program build, by name.
const _WsState = Union{
    _CSECache, _ObsExtVec, _AccScratch, _ForcingEpoch, _SecTCache, _ACMask,
    Base.RefValue, Core.Box, AbstractDict, _CallTarget,
}

# A memoizing cache: its buffer may also be read through a codegen table.
const _WsCache = Union{_CSECache, _ObsExtVec}

function _ws_children!(x::Union{_WsCache, _AccScratch}, w)
    haskey(w.seen, x.f64) || (w.seen[x.f64] = nothing)
    w.kinds[x.f64] = :scratch
    x isa _WsCache && _ws_walk!(x.epoch, x, w)
    return nothing
end
_ws_children!(x::_ACMask, w) = _ws_walk!(x.f, x, w)
_ws_children!(x::Base.RefValue, w) = (isdefined(x, :x) && _ws_walk!(x[], x, w); nothing)
_ws_children!(x::Core.Box, w) = (isdefined(x, :contents) && _ws_walk!(x.contents, x, w); nothing)
function _ws_children!(x::AbstractDict, w)
    for (k, v) in x
        _ws_walk!(k, x, w)
        _ws_walk!(v, x, w)
    end
    return nothing
end
_ws_children!(::Union{_ForcingEpoch, _SecTCache}, w) = nothing
# A template compiled as a call (tree_walk/call.jl): its argument stack and the
# running call's frame are per-call state; its body and block layouts are
# walked like any other part of the program.
function _ws_children!(x::_CallTarget, w)
    _ws_walk!(x.body, x, w)
    _ws_walk!(x.blocks, x, w)
    return nothing
end

function _ws_fresh(x::_CSECache, c)
    y = _CSECache(
        _inst(x.f64, c), nothing, _CSE_INVALID, _CSE_INVALID, _CSE_INVALID,
        NaN, UInt64(0), _CSE_INVALID, _CSE_INVALID, UInt64(0),
        _inst(x.epoch, c)
    )
    push!(c.caches, y)
    return c.memo[x] = y
end
function _ws_fresh(x::_ObsExtVec, c)
    y = _ObsExtVec(
        _inst(x.f64, c), nothing, _CSE_INVALID, _CSE_INVALID, _CSE_INVALID,
        NaN, UInt64(0), _CSE_INVALID, _CSE_INVALID, UInt64(0),
        _inst(x.epoch, c), nothing, _CSE_INVALID, UInt64(0), _CSE_INVALID, UInt64(0)
    )
    push!(c.caches, y)
    return c.memo[x] = y
end
_ws_fresh(x::_AccScratch, c) = c.memo[x] = _AccScratch(_inst(x.f64, c), nothing)
function _ws_fresh(x::_ForcingEpoch, c)
    # A workspace tracks its forcing set's epoch itself: its buffers change
    # only when it loads a new set, which bumps it (announced).
    e = _ForcingEpoch(UInt64(0), true)
    push!(c.epochs, e)
    return c.memo[x] = e
end
# Serial: a workspace never dispatches to Polyester's pool. A negative verdict
# is serial; this one is decided for every call, not measured.
const _SECT_SERIAL_WORKSPACE = -3
_ws_fresh(x::_SecTCache, c) = c.memo[x] = _SecTCache(
    _SECT_SERIAL_WORKSPACE, x.ncells, x.disjoint, x.work, 1, nothing, nothing, x.rmw,
    x.min_work
)
function _ws_fresh(x::_ACMask, c)
    y = typeof(x)(_inst(x.f, c), _CSE_INVALID, 0)
    push!(c.caches, y)
    return c.memo[x] = y
end
function _ws_fresh(x::Base.RefValue, c)
    y = typeof(x)()
    c.memo[x] = y
    isdefined(x, :x) && (y[] = _inst(x[], c))
    return y
end
function _ws_fresh(x::Core.Box, c)
    y = Core.Box()
    c.memo[x] = y
    isdefined(x, :contents) && (y.contents = _inst(x.contents, c))
    return y
end
function _ws_fresh(x::AbstractDict, c)
    y = empty(x)
    c.memo[x] = y
    for (key, v) in x
        y[_inst(key, c)] = _inst(v, c)
    end
    return y
end

function _ws_fresh(x::_CallTarget, c)
    y = _CallTarget(
        x.name, x.key, x.slots, x.arrslots, x.arrkinds, x.arrdims, x.body, _ArgStack(), 0,
        x.nodes, _ArrArg[], x.passed, x.baseidx, x.blocks
    )
    c.memo[x] = y
    y.body = _inst(x.body, c)
    y.blocks = _inst(x.blocks, c)
    push!(c.caches, y)
    return y
end
_ws_invalidate!(x::_CallTarget) = (x.fp = 0; x.stack.top = 0; empty!(x.curarrs); nothing)

function _ws_invalidate!(x::_WsCache)
    x.stamp64 = _CSE_INVALID
    x.stampalt = _CSE_INVALID
    x.tp64 = _CSE_INVALID
    x.tpalt = _CSE_INVALID
    if x isa _ObsExtVec
        x.fp64 = _CSE_INVALID
        x.fpalt = _CSE_INVALID
    end
    return nothing
end
_ws_invalidate!(x::_ACMask) = (x.stamp = _CSE_INVALID; nothing)

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
        return _ws_children!(x, w)
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
    return _ws_fresh(x, c)
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
        lbufs, c.epochs, c.caches, UInt64(0)
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
    foreach(_ws_invalidate!, ws.caches)
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
    # A set built by hand (`ForcingSet(slots, bufs, epoch)`) is not checked by
    # `forcing_set`; the lane gathers read its buffers unchecked.
    length(fs.bufs) == length(slots) || throw(
        ArgumentError(
            "$call: the forcing set holds $(length(fs.bufs)) buffers for " *
                "$(length(slots)) forcing slots"
        )
    )
    @inbounds for k in eachindex(slots)
        n = prod(slots[k].shape; init = 1)
        length(fs.bufs[k]) == n || _forcing_buffer_length_error(call, slots[k], fs.bufs[k], n)
    end
    return nothing
end
@noinline _forcing_buffer_length_error(call, s::ForcingSlot, buf, n) = throw(
    ArgumentError(
        "$call: the forcing set's buffer for slot '$(s.name)' has $(length(buf)) " *
            "elements; the slot's shape $(Tuple(s.shape)) has $n"
    )
)

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

# ============================================================================
# Layouts and programs
# ============================================================================

"""
    TileBlock

One variable's block in a program's `u`, `aux` or `du` buffer (API_SPEC §5.8,
"Layouts"): `name`, its index `sets` in shape order, its `storage` and `owned`
boxes per set (inclusive, global coordinates; `owned` is empty for an `aux`
block), its 1-based `base` slot and its column-major `strides`. A 0-d state has
no sets and one slot.
"""
struct TileBlock
    name::String
    sets::Vector{String}
    storage::Vector{UnitRange{Int}}
    owned::Vector{UnitRange{Int}}
    base::Int
    strides::Vector{Int}
end

"""
    TileLayout

The `u` and `aux` blocks of a program (whole-domain or tile), in flat-layout
order (0-d states by sorted name, then arrays by sorted name), and the two
buffer lengths. `du` has `u`'s layout.
"""
struct TileLayout
    u::Vector{TileBlock}
    aux::Vector{TileBlock}
    n_u::Int
    n_aux::Int
end

# One contiguous copy: `len` slots from `src` on to `dst` on.
struct _CopyRun
    src::Int
    dst::Int
    len::Int
end

# The copy maps of one program call, as runs: `u`/`aux` buffer slot → internal
# slot, and internal `du` slot → `du` buffer slot (the owned rows only). A tile
# block contiguous along its first dimension is one run per row, a whole-domain
# block one run.
struct _CopyMaps
    u::Vector{_CopyRun}
    aux::Vector{_CopyRun}
    du::Vector{_CopyRun}
end

# The per-slot pairs `src[k] → dst[k]` as maximal runs, in the same order: the
# same assignments, made by `copyto!`.
function _copy_runs(src::Vector{Int}, dst::Vector{Int})
    runs = _CopyRun[]
    k = 1
    while k <= length(src)
        j = k
        while j < length(src) && src[j + 1] == src[j] + 1 && dst[j + 1] == dst[j] + 1
            j += 1
        end
        push!(runs, _CopyRun(src[k], dst[k], j - k + 1))
        k = j + 1
    end
    return runs
end

@inline function _copy_runs!(dst::AbstractVector, src::AbstractVector, runs::Vector{_CopyRun})
    @inbounds for r in runs
        copyto!(dst, r.dst, src, r.src, r.len)
    end
    return dst
end

"""
    RhsProgram

A right-hand side as a program value (API_SPEC §5.8): [`rhs_program`](@ref)
returns the Problem's whole model, [`select`](@ref) one operator of it. Its
`u` covers the written variables and its `aux` the other states the kept rules
read. Evaluate it with [`rhs!`](@ref) on a [`rhs_workspace`](@ref) per
concurrent caller; restrict it with [`halo`](@ref), [`restrict`](@ref) and
[`lanes`](@ref). Immutable once built: one program serves every thread.
"""
struct RhsProgram{F}
    seed::Any                       # the Problem's `_ProgramSeed`
    compiler::Symbol
    writes::Vector{String}          # W, flat-layout order
    aux_names::Vector{String}       # R \ W, flat-layout order
    flat::FlattenedSystem           # the selected flattened system
    front::Any                      # (file, model_name, BuildOptions) the front door produced
    f!::F
    internal::StateLayout           # the slot space `f!` addresses
    shapes::Dict{String, Vector{String}}  # array state → index sets per dim
    layout::TileLayout
    maps::_CopyMaps
    shared::_RhsShared
    memo::_ProgramMemo              # what its re-lowerings reuse from its build
end

"""
    TileProgram

An operator restricted to one tile of a [`Decomposition`](@ref)
([`restrict`](@ref)). Evaluate it with [`rhs!`](@ref) on buffers in its
[`tile_layout`](@ref).
"""
struct TileProgram{F}
    op::RhsProgram
    f!::F
    internal::StateLayout
    layout::TileLayout
    maps::_CopyMaps
    shared::_RhsShared
end

# ============================================================================
# Errors
# ============================================================================

_range_error(code::String, msg::AbstractString) = SimulateError(String(msg), code)

function _require_native(x, call::AbstractString)
    c = x isa RhsProgram ? x.compiler : x.op.compiler
    c === :native || throw(
        _range_error(
            ERROR_CODES.COMPILER_UNAVAILABLE,
            "$call needs a program built with compiler = :native; this one was built " *
                "with compiler = :$c, which has no range-restricted lowering (API_SPEC §5.8)"
        )
    )
    return nothing
end

# ============================================================================
# Building and evaluating a program
# ============================================================================

# A whole-domain program build: records the front door's product, so a
# restriction re-lowers from it.
struct _CaptureSpec <: _RangeSpec
    front::Base.RefValue{Any}
    memo::_ProgramMemo
end
_range_memo(s::_CaptureSpec) = s.memo
_range_memo_records(::_CaptureSpec) = true
function _range_front_door_done(s::_CaptureSpec, file, model_name, opts::BuildOptions)
    s.front[] = (file, model_name, copy(opts))
    return nothing
end

# Build the program of `file` (a run file of `seed`'s prepared run) the way
# `esm_problem` built the Problem's, without its discrete-cadence cut,
# recording what its workspaces need (`_WsCapture`).
#
# Every externally fed parameter is a live buffer of the program (a forcing
# slot), whatever the Problem's own build made of it: the build registers each
# one the Problem holds no buffer for, filled with its value, in the program's
# own copy of the buffer registry (`pa`, returned).
#
# `products` and `param_classes` are the build's sinks, which a Problem built as
# its program (`esm_problem(…; program_build = true)`) passes on; the build's
# initial state `u0` is returned for that Problem too.
function _program_build(
        seed::_ProgramSeed, file::EsmFile; products = nothing, param_classes = nothing,
        caller_u0 = nothing
    )
    front = Ref{Any}(nothing)
    memo = _ProgramMemo()
    pa = Dict{String, Any}(String(k) => v for (k, v) in seed.param_arrays)
    cap = _WsCapture()
    f!, u0, p, _ts, var_map = _with_ws_capture(cap) do
        _with_range_spec(_CaptureSpec(front, memo)) do
            _build_run(
                file; compiler = seed.compiler, form = :inplace,
                model_name = seed.model_name, parameter_overrides = seed.overrides,
                const_arrays = seed.const_arrays, param_arrays = pa,
                gated_providers = seed.gated_providers, sample_time = seed.sample_time,
                runtime_array_parameters = seed.runtime_array_parameters,
                live_fed_parameters = true,
                ic_t0 = seed.ic_t0,
                ic_data = seed.ic_data,
                products = products, param_classes = param_classes,
                caller_u0 = caller_u0
            )
        end
    end
    return f!, var_map, front[], u0, p, pa, cap, memo
end

# The parameter and forcing-slot signatures of a program built from `seed`
# (API_SPEC §5.8, "States and parameters", "Forcing sets"), whose build
# resolved the parameter NamedTuple `p` and the buffer registry `pa`, its
# default forcing set (a copy of those buffers now), and the factory of the
# workspaces of its template `f!` (`n` internal slots, build record `cap`).
#
# A slot's kind is the parameter's, whatever supplied its buffer: `:forcing`
# for an externally fed parameter (or a buffer no parameter declares, a
# provider's), `:array_parameter` for every other one: a shaped parameter made
# live by `runtime_array_parameters`, or one whose buffer the caller handed
# `esm_problem` as `param_arrays`.
function _program_shared(seed::_ProgramSeed, p, pa, f!, n::Int, cap::_WsCapture)
    decl = seed.prep.flat.parameters
    function declared(n)
        v = get(decl, n, nothing)
        return (v !== nothing && v.default isa Real) ? Float64(v.default) : nothing
    end
    params = p === nothing ? ParamSlot[] :
        ParamSlot[ParamSlot(String(k), declared(String(k))) for k in keys(p)]
    sort!(params; by = s -> s.name)
    function kind(n)
        v = get(decl, n, nothing)
        return (v === nothing || _externally_fed(v)) ? :forcing : :array_parameter
    end
    names = sort!(String[String(k) for k in keys(pa)])
    slots = ForcingSlot[
        ForcingSlot(
            n, _is_scalar_slot(get(decl, n, nothing)) ? Int[] :
                collect(Int, size(pa[n])), kind(n)
        ) for n in names
    ]
    bufs = _slot_buffers(slots, pa)
    default = ForcingSet(
        slots, Vector{Float64}[vec(copy(a)) for a in bufs],
        _next_set_epoch()
    )
    return _RhsShared(params, slots, default, _ws_factory(f!, n, cap, slots, bufs))
end

# A derived program's: its parent's signatures and default set, and a factory
# of its own template.
_derived_shared(
    parent::_RhsShared, f!, n::Int, cap::_WsCapture, pa,
    lane_bufs::Vector{Vector{Float64}} = Vector{Float64}[]
) =
    _RhsShared(
    parent.params, parent.slots, parent.default,
    _ws_factory(
        f!, n, cap, parent.slots, _slot_buffers(parent.slots, pa),
        lane_bufs
    )
)

# Re-lower a program's recorded front-door product under `spec`.
function _relower(prog::RhsProgram, spec::_RangeSpec; form = :inplace)
    file, model_name, recorded = prog.front
    opts = _relower_options(recorded)
    opts.form = form
    cap = _WsCapture()
    f!, _u0, _p, _ts, var_map = _with_ws_capture(cap) do
        _with_compiler_plan(_plan(prog.compiler)) do
            _with_range_spec(spec) do
                _build_selected(file, model_name, opts)
            end
        end
    end
    return f!, var_map, cap, opts.param_arrays
end

# Each array state's index sets, from the flattened declaration (or `dim<d>`
# for a state whose declaration carries no shape).
function _state_shapes(flat::FlattenedSystem, internal::StateLayout)
    out = Dict{String, Vector{String}}()
    for b in _layout_blocks(internal)
        v = get(flat.state_variables, b.name, nothing)
        sh = v === nothing ? nothing : v.shape
        out[b.name] = (sh !== nothing && length(sh) == length(b.lo)) ?
            String[string(s) for s in sh] : String["dim$d" for d in eachindex(b.lo)]
    end
    return out
end

# The flat-layout order of `names` over the internal layout: 0-d states by
# sorted name, then arrays by sorted name.
function _flat_order(internal::StateLayout, names)
    sc = sort!([n for n in names if haskey(internal.scalars, n)])
    ar = sort!([n for n in names if _layout_block(internal, n) !== nothing])
    return vcat(sc, ar)
end

# Column-major strides over a box and its cell count: the build's own block
# rule (`_ArrayBlock`).
function _box_strides(box::Vector{UnitRange{Int}})
    b = _ArrayBlock("", 1, Int[first(r) for r in box], Int[last(r) for r in box])
    return b.strides, b.len
end

# Blocks over `names` with storage/owned boxes from `boxes(name)`.
function _make_blocks(internal::StateLayout, shapes, names, boxes; owned::Bool)
    blocks = TileBlock[]
    base = 1
    for n in names
        if haskey(internal.scalars, n)
            push!(blocks, TileBlock(n, String[], UnitRange{Int}[], UnitRange{Int}[], base, Int[]))
            base += 1
            continue
        end
        st, ow = boxes(n)
        strides, len = _box_strides(st)
        push!(blocks, TileBlock(n, shapes[n], st, owned ? ow : UnitRange{Int}[], base, strides))
        base += len
    end
    return blocks, base - 1
end

# `slot` of global cell `g` in `b`, or 0 outside its storage box.
@inline function _tile_slot(b::TileBlock, g)
    s = b.base
    @inbounds for d in eachindex(b.storage)
        r = b.storage[d]
        (first(r) <= g[d] <= last(r)) || return 0
        s += (g[d] - first(r)) * b.strides[d]
    end
    return s
end

# The copy maps between a layout and the internal slot space. `to_internal(name,
# d, g)` maps a storage coordinate to its internal (global) coordinate, or
# `nothing` for a cell the program never reads (a dead halo cell); a cell
# outside the variable's own block may lie in one of its `extra` blocks (the
# pieces past a periodic seam).
function _copy_maps(
        layout::TileLayout, internal::StateLayout, to_internal,
        extra::AbstractDict = Dict{String, Vector{String}}()
    )
    function fill_in!(src, dst, blocks)
        for b in blocks
            if isempty(b.sets) && isempty(b.storage)
                push!(src, b.base)
                push!(dst, internal.scalars[b.name])
                continue
            end
            ib = _layout_block(internal, b.name)
            g = Vector{Int}(undef, length(b.storage))
            for c in CartesianIndices(Tuple(b.storage))
                ok = true
                for d in eachindex(g)
                    x = to_internal(b.name, d, c[d])
                    x === nothing && (ok = false; break)
                    g[d] = x
                end
                ok || continue
                s = _block_slot(ib, g)
                for a in get(extra, b.name, ())
                    s == 0 || break
                    s = _block_slot(_layout_block(internal, a), g)
                end
                s == 0 && continue
                push!(src, _tile_slot(b, Tuple(c)))
                push!(dst, s)
            end
        end
        return
    end
    u_src, u_dst, a_src, a_dst = Int[], Int[], Int[], Int[]
    fill_in!(u_src, u_dst, layout.u)
    fill_in!(a_src, a_dst, layout.aux)
    du_src, du_dst = Int[], Int[]
    for b in layout.u
        if isempty(b.sets) && isempty(b.storage)
            push!(du_src, internal.scalars[b.name])
            push!(du_dst, b.base)
            continue
        end
        ib = _layout_block(internal, b.name)
        for c in CartesianIndices(Tuple(b.owned))
            s = _block_slot(ib, Tuple(c))
            s == 0 && error("owned cell $(Tuple(c)) of '$(b.name)' is not in the program's layout")
            push!(du_src, s)
            push!(du_dst, _tile_slot(b, Tuple(c)))
        end
    end
    return _CopyMaps(
        _copy_runs(u_src, u_dst), _copy_runs(a_src, a_dst), _copy_runs(du_src, du_dst)
    )
end

_whole_program(
    seed, flat::FlattenedSystem, W::Set{String}, R::Set{String};
    parent = nothing
) = first(_whole_program_built(seed, flat, W, R; parent = parent))

# `_whole_program`, with the build's sinks `products` and `param_classes` filled
# and its initial state and parameters: `(prog, u0, p)`.
function _whole_program_built(
        seed, flat::FlattenedSystem, W::Set{String}, R::Set{String};
        parent = nothing, products = nothing, param_classes = nothing, caller_u0 = nothing
    )
    live = union(W, R)
    init = _select_init(_initialization_system(seed.prep.flat), live)
    file = _run_file(seed.prep; flat = _scalar_slots_to_arrays(flat), init = init)
    f!, internal, front, u0, p, pa, cap, memo = _program_build(
        seed, file; products = products, param_classes = param_classes, caller_u0 = caller_u0
    )
    present = Set{String}(
        vcat(
            collect(_layout_scalar_names(internal)),
            [b.name for b in _layout_blocks(internal)]
        )
    )
    unames = _flat_order(internal, [n for n in W if n in present])
    anames = _flat_order(internal, [n for n in R if n in present && !(n in W)])
    shapes = _state_shapes(flat, internal)
    gbox(n) = (
        b = _layout_block(internal, n);
        bx = UnitRange{Int}[b.lo[d]:b.hi[d] for d in eachindex(b.lo)]; (bx, bx)
    )
    ublocks, nu = _make_blocks(internal, shapes, unames, gbox; owned = true)
    ablocks, na = _make_blocks(internal, shapes, anames, gbox; owned = false)
    layout = TileLayout(ublocks, ablocks, nu, na)
    maps = _copy_maps(layout, internal, (n, d, x) -> x)
    prog = RhsProgram(
        seed, seed.compiler, unames, anames, flat, front, f!,
        internal, shapes, layout, maps,
        parent === nothing ?
            _program_shared(seed, p, pa, f!, length(internal), cap) :
            _derived_shared(parent, f!, length(internal), cap, pa),
        memo
    )
    return prog, u0, p
end

"""
    rhs_program(prob::EsmProblem; unspecified_eltype = Float64) -> RhsProgram

The Problem's right-hand side as a program value (API_SPEC §5.8): the whole
model over the whole domain, with `u` every state of the Problem (in the
Problem's flat layout) and `aux` empty. [`select`](@ref) narrows it to one
operator; [`halo`](@ref), [`restrict`](@ref) and [`lanes`](@ref) restrict it.

Its inputs besides the state are a parameter vector ([`parameters`](@ref)) and
a [`ForcingSet`](@ref) ([`forcing_slots`](@ref)): every externally fed
parameter, and under `runtime_array_parameters` every shaped parameter with a
value, is read from the set, never from build-time data.
[`default_forcing_set`](@ref) holds the Problem's forcing as it is now.
An explicit `unspecified_eltype = Float32` is refused with `float32_unsupported`
because the native RHS evaluates in binary64.
"""
function rhs_program(prob::EsmProblem; unspecified_eltype::Type = Float64)
    unspecified_eltype in (Float32, Float64) ||
        throw(ArgumentError("unspecified_eltype must be Float32 or Float64"))
    unspecified_eltype === Float32 && throw(
        _range_error(
            ERROR_CODES.FLOAT32_UNSUPPORTED,
            "binary32 evaluation of unspecified precision (esm-spec §11.3.3)"
        )
    )
    b = prob.build
    b.seed === nothing && throw(
        _range_error(
            ERROR_CODES.COMPILER_UNAVAILABLE,
            "rhs_program needs a Problem built by esm_problem with compiler = :native " *
                "(or :interpreter); this one was built with compiler = :$(compiler(prob)), " *
                "which carries no program of its own (API_SPEC §5.8)"
        )
    )
    # The model is lowered once per Problem: the first call builds the program
    # (unless `esm_problem(…; program_build = true)` already did) and every call
    # returns it with its default forcing set holding the Problem's forcing as
    # it is now.
    lock(b.program_lock) do
        b.program[] === nothing && (b.program[] = first(_problem_program(b.seed)))
    end
    return _current_program(b, prob.param_buffers)
end

# The whole-model program of `seed` with the build's sinks `products` and
# `param_classes` filled, and the build's initial state and parameters:
# `(prog, u0, p)`. `rhs_program` builds it with no sinks; a Problem built with
# `program_build = true` is built from it, with its own.
function _problem_program(
        seed::_ProgramSeed; products = nothing, param_classes = nothing, caller_u0 = nothing
    )
    flat, W, R = _select_flat(seed.prep.flat, :all, :all)
    return _whole_program_built(
        seed, flat, W, R; products = products, param_classes = param_classes,
        caller_u0 = caller_u0
    )
end

# The program the Problem build `b` holds, with its default forcing set copied
# from the Problem's live buffers `live` when one of them has changed since the
# set was taken (a discrete provider's refresh writes them in place). The
# program then held is that one, so a later call with nothing changed returns
# the same value. A slot the Problem holds no buffer for is one the program's
# build registered itself, which nothing writes; its buffer is kept.
function _current_program(b::_ProblemBuild, live::AbstractDict)
    return lock(b.program_lock) do
        prog = b.program[]::RhsProgram
        sh = prog.shared
        d = sh.default
        stale(k, s) = (x = get(live, s.name, nothing); x !== nothing && !isequal(vec(x), d.bufs[k]))
        any(((k, s),) -> stale(k, s), enumerate(sh.slots)) || return prog
        bufs = Vector{Float64}[
            haskey(live, s.name) ? vec(copy(live[s.name])) : d.bufs[k]
                for (k, s) in enumerate(sh.slots)
        ]
        cur = RhsProgram(
            prog.seed, prog.compiler, prog.writes, prog.aux_names, prog.flat,
            prog.front, prog.f!, prog.internal, prog.shapes, prog.layout, prog.maps,
            _RhsShared(sh.params, sh.slots, ForcingSet(sh.slots, bufs, _next_set_epoch()), sh.factory),
            prog.memo
        )
        b.program[] = cur
        return cur
    end
end

"""
    select(prog::RhsProgram; writes = :all, terms = :all) -> RhsProgram

The program of one operator (API_SPEC §5.8, "Selection"): every flattened
equation keeps the contributions whose #539 origins intersect `terms` (a
vector of [`TermOrigin`](@ref), matched by equality; `:all` keeps every one),
summed as a left fold in their original order; equations whose target is not
in `writes` (a vector of flattened state names, or `:all`) are dropped, and a
kept equation with no kept contribution writes `0`. The result's `u` covers
`writes` and its `aux` the other states the kept rules read.

A selection of a selection composes: its `terms` keep only the contributions
both selections keep, and its `writes` (`:all` meaning `prog`'s own) must be
variables `prog` writes.

Raises `range_selection_writes_incomplete` when a variable outside `writes` has
a kept contribution.
"""
function select(prog::RhsProgram; writes = :all, terms = :all)
    t = _normalize_terms(terms)
    # A selection of a selection selects from the program's own flattened
    # system: its contributions are the ones the first selection kept, and its
    # writable variables are the first selection's `writes`.
    flat, W, R = _select_flat(prog.flat, writes, t, Set{String}(prog.writes))
    return _whole_program(prog.seed, flat, W, R; parent = prog.shared)
end

"""
    tile_layout(x) -> TileLayout

The `u`/`aux` layout of a whole-domain program or a tile (API_SPEC §5.8,
"Layouts").
"""
tile_layout(x::RhsProgram) = x.layout
tile_layout(x::TileProgram) = x.layout

"""
    parameters(prog) -> Vector{ParamSlot}

The entries of a vector `p` (API_SPEC §5.8): sorted flattened parameter names,
the positional order the compiled program indexes, each with its default.
Build a vector with [`parameter_vector`](@ref); `rhs!` also takes the Problem's
NamedTuple `prob.p`.
"""
parameters(x::Union{RhsProgram, TileProgram}) = x.shared.params

"""
    n_states(prog) -> Int

The length of `u` (API_SPEC §5.8, "States and parameters").
"""
n_states(x::Union{RhsProgram, TileProgram}) = x.layout.n_u

"""
    state_layout(prog) -> Vector{StateBlock}

The `u` blocks in flat-layout order (0-d states by sorted name, then arrays by
sorted name): name, 1-based offset, shape. Derived from
[`tile_layout`](@ref)`(prog)`; a tile's shapes are its storage box's.
"""
state_layout(x::Union{RhsProgram, TileProgram}) = _state_blocks(x.layout.u)

# Tile blocks as the name, offset and storage shape a caller indexes by.
_state_blocks(blocks::Vector{TileBlock}) =
    StateBlock[StateBlock(b.name, b.base, Int[length(r) for r in b.storage]) for b in blocks]

"""
    rhs_workspace(x) -> RhsWorkspace

The mutable state of [`rhs!`](@ref) on `x` (a program, a tile or a lane
program): a private instance of its compiled right-hand side — its own caches,
scratch and forcing buffers; the generated code and every read-only table are
the program's. One per concurrent caller; a workspace may move between threads
but serves one call at a time.
"""
rhs_workspace(x::Union{RhsProgram, TileProgram}) = _instantiate(x.shared)

"""
    rhs!(du, x, ws, u, aux, p, t, fs::ForcingSet) -> du

Evaluate the program or tile `x` (API_SPEC §5.8): `u` and `aux` in
[`tile_layout`](@ref)`(x)`, `p` a vector in [`parameters`](@ref) order or the
Problem's NamedTuple, `fs` a [`ForcingSet`](@ref) of `x`, `ws` a
[`rhs_workspace`](@ref) of `x`. The result is a function of `(x, u, aux, p, t,
fs)`'s contents alone: bitwise the same on every workspace and thread, whatever
the workspace evaluated before. Writes only the owned rows of `du`; every other
element is left untouched. Reentrant across distinct workspaces, never
threaded internally, allocation-free in steady state. A buffer or a vector `p`
of the wrong length is a `DimensionMismatch`; a workspace or set of another
program an `ArgumentError`. A call that throws leaves the workspace usable: the
next call recomputes everything the failed one may have half written.
"""
function rhs!(
        du::AbstractVector, x::Union{RhsProgram, TileProgram}, ws::RhsWorkspace,
        u::AbstractVector, aux::AbstractVector, p, t, fs::ForcingSet
    )
    return _rhs_eval!(du, x.layout, x.maps, x.shared, ws, u, aux, p, t, fs)
end

function _rhs_eval!(
        du::AbstractVector, L::TileLayout, m::_CopyMaps, shared::_RhsShared,
        ws::RhsWorkspace, u::AbstractVector, aux::AbstractVector, p, t,
        fs::ForcingSet
    )
    _check_workspace(shared, ws)
    length(u) == L.n_u || throw(
        DimensionMismatch(
            "rhs!: `u` has $(length(u)) elements; the layout has $(L.n_u)"
        )
    )
    length(aux) == L.n_aux || throw(
        DimensionMismatch(
            "rhs!: `aux` has $(length(aux)) elements; the layout has $(L.n_aux)"
        )
    )
    length(du) == L.n_u || throw(
        DimensionMismatch(
            "rhs!: `du` has $(length(du)) elements; the layout has $(L.n_u)"
        )
    )
    _check_parameters(shared, p, "rhs!")
    _prime!(ws, fs)
    _copy_runs!(ws.u, u, m.u)
    _copy_runs!(ws.u, aux, m.aux)
    _ws_eval!(ws, p, t)
    _copy_runs!(du, ws.du, m.du)
    return du
end
