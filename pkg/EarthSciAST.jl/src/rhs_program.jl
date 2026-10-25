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
# a private instance of the template (`_new_workspace`): every such object
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
parameter `name` and its declared `default` (`nothing` when it declares none).
"""
struct ParamSlot
    name::String
    default::Union{Float64,Nothing}
end

Base.:(==)(a::ParamSlot, b::ParamSlot) = a.name == b.name && isequal(a.default, b.default)

"""
    ForcingSlot

One buffer of a [`ForcingSet`](@ref) ([`forcing_slots`](@ref)): the flattened
`name`, its resolved `shape` (empty for a 0-d input) and its `kind`: `:forcing`
(an externally fed parameter: its `update` takes its value from a data source or
a handler) or `:array_parameter` (a shaped parameter made a run-time input by
`esm_problem(…; runtime_array_parameters = true)`).
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
struct ForcingSet
    slots::Vector{ForcingSlot}
    bufs::Vector{Vector{Float64}}
    epoch::UInt64
end

# One process-wide counter, one value per set built: a workspace that primed
# epoch `e` holds exactly that set's contents.
const _FORCING_SET_EPOCH = Threads.Atomic{UInt64}(0)
_next_set_epoch() = Threads.atomic_add!(_FORCING_SET_EPOCH, UInt64(1)) + UInt64(1)

# What a program and the programs derived from it share (and what identifies a
# program to its workspaces): the parameter and forcing-slot signatures, the
# buffers its template `f!` gathers, and its default forcing set. Mutable for
# identity only; never written.
mutable struct _RhsShared
    const params::Vector{ParamSlot}
    const slots::Vector{ForcingSlot}
    # The template's forcing buffers, in slot order (the program build's own).
    const originals::Vector{Array{Float64}}
    const default::ForcingSet
    # Buffers a lane program writes per call (lane indices, pre-gathered
    # inputs); a workspace owns its own copy of each.
    const lane_originals::Vector{Vector{Float64}}
end

# The same signatures, default set and buffers, a different program (a tile or
# a lane program, which re-lower from their operator's build).
_RhsShared(s::_RhsShared, lane_originals::Vector{Vector{Float64}} = Vector{Float64}[]) =
    _RhsShared(s.params, s.slots, s.originals, s.default, lane_originals)

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
    b = Dict{String,ASTExpr}(n => OpExpr("index", ASTExpr[VarExpr(n), IntExpr(1)])
                             for n in names)
    sub(e) = substitute(e, b)
    params = OrderedDict{String,ModelVariable}()
    for (n, v) in flat.parameters
        params[n] = n in names ?
            ModelVariable(v.type; default = v.default, description = v.description,
                          units = v.units, default_units = v.default_units,
                          shape = [_SCALAR_SLOT_SET], location = v.location,
                          distribution = v.distribution, update = v.update,
                          element_type = v.element_type) : v
    end
    sets = copy(flat.index_sets)
    sets[_SCALAR_SLOT_SET] = IndexSet("interval"; size = 1)
    return FlattenedSystem(flat;
        parameters = params, index_sets = sets,
        discrete_parameters = OrderedDict{String,ModelVariable}(
            k => get(params, k, v) for (k, v) in flat.discrete_parameters),
        equations = Equation[Equation(sub(e.lhs), sub(e.rhs); _comment = e._comment)
                             for e in flat.equations],
        equation_contributions = Vector{Contribution}[
            Contribution[Contribution(sub(c.expr), c.origins) for c in cs]
            for cs in flat.equation_contributions])
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
    buf isa AbstractArray || throw(ArgumentError(
        "$what: the buffer for '$(s.name)' is a $(typeof(buf)), not an array"))
    n = prod(s.shape; init = 1)
    length(buf) == n || throw(DimensionMismatch(
        "$what: the buffer for '$(s.name)' has $(length(buf)) elements; the slot's " *
        "shape $(Tuple(s.shape)) has $n"))
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
    length(bufs) == length(slots) || throw(DimensionMismatch(
        "forcing_set: $(length(bufs)) buffers for $(length(slots)) forcing slots" *
        (isempty(slots) ? "" : " ($(join((s.name for s in slots), ", ")))")))
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
    1 <= slot <= length(fs.slots) || throw(ArgumentError(
        "replace_forcing: slot $slot of a set with $(length(fs.slots)) slots"))
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
        ws.fused[k] && copyto!(ws.fbufs[k], fs.bufs[k])
    end
    _bump_workspace_epochs!(ws)
    ws.primed = fs.epoch
    return nothing
end
