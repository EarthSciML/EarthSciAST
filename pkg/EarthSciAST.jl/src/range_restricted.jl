# Range-restricted, operator-restricted right-hand sides (API_SPEC §5.8,
# "Range-restricted right-hand sides"; issue #540).
#
# A Problem's right-hand side evaluates the whole model over the whole domain.
# This file evaluates one OPERATOR — the summands a #539 provenance selection
# keeps, writing only the operator's variables — over the whole domain
# (`select`), over a TILE of a horizontal decomposition reading halo cells from
# a local extended array (`restrict`), or over LANES, a run-time list of cells
# or columns (`lanes`).
#
# Every program here is the ordinary native build of a rewritten equation
# stream. Selection rewrites the flattened system (§1). A tile builds the
# selected document under a range spec (tree_walk/range_hooks.jl), whose seams
# clip the equation stream to the owned box, lay each state out over the cells
# the tile stores and each array observed over the cells it needs (§3–§4); the
# compiler then resolves every read against that layout exactly as it does a
# whole-domain one, so the kernels, their offsets and their ghost cuts come
# out rebased by construction. A lane program is the native build of a derived
# document in which the lane sets are replaced by one lane index (§5).

# ============================================================================
# §0 Types
# ============================================================================

"""
    Decomposition(; axes, faces = [])

A horizontal decomposition (API_SPEC §5.8): the index sets a tiling cuts, each
with its period (`nothing` when the axis is not periodic; otherwise the axis's
global extent), and the face sets that stagger off a cut axis (`"lon_nodes" =>
"lon"`). Every other index set is whole on every tile.

```julia
dec = Decomposition(axes = ["lon" => (period = 144,), "lat" => (period = nothing,)],
                    faces = ["lon_nodes" => "lon"])
```
"""
struct Decomposition
    axes::Vector{Pair{String,Union{Nothing,Int}}}
    faces::Vector{Pair{String,String}}
end

function Decomposition(; axes, faces = Pair{String,String}[])
    ax = Pair{String,Union{Nothing,Int}}[]
    for a in axes
        name, spec = first(a), last(a)
        period = spec isa NamedTuple ? get(spec, :period, nothing) : spec
        (period === nothing || period isa Integer) || throw(ArgumentError(
            "Decomposition: the period of axis '$name' must be an integer or `nothing`, got $(repr(period))"))
        push!(ax, String(name) => (period === nothing ? nothing : Int(period)))
    end
    fc = Pair{String,String}[String(first(f)) => String(last(f)) for f in faces]
    return Decomposition(ax, fc)
end

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

"""
    LaneBlock

One variable's block in a lane buffer (API_SPEC §5.8, "Lanes"): `name`, its
non-lane index `sets` and their `extents`, and its `offset` in units of lanes:
element `e` (1-based, column-major over the non-lane sets) of lane `l` is at
slot `(offset + e - 1)·L + l`.
"""
struct LaneBlock
    name::String
    sets::Vector{String}
    extents::Vector{Int}
    offset::Int
end

"""
    LaneLayout

The `u` and `aux` blocks of a lane program, the lane sets, and the number of
elements per lane of each buffer (`u` and `aux`).
"""
struct LaneLayout
    u::Vector{LaneBlock}
    aux::Vector{LaneBlock}
    sets::Vector{String}
    n_u::Int
    n_aux::Int
end

# The copy maps of one program call: `u`/`aux` buffer slot → internal slot,
# and internal `du` slot → `du` buffer slot (the owned rows only).
struct _CopyMaps
    u_src::Vector{Int}
    u_dst::Vector{Int}
    aux_src::Vector{Int}
    aux_dst::Vector{Int}
    du_src::Vector{Int}
    du_dst::Vector{Int}
end

"""
    RhsProgram

A right-hand side as a program value (API_SPEC §5.8): [`rhs_program`](@ref)
returns the Problem's whole model, [`select`](@ref) one operator of it. Its
`u` covers the written variables and its `aux` the other states the kept rules
read. Evaluate it with [`rhs!`](@ref); restrict it with [`halo`](@ref),
[`restrict`](@ref) and [`lanes`](@ref).

This is the smallest program type the range-restricted entries need, not the
public right-hand-side type of #541 (U4).
"""
struct RhsProgram{F}
    seed::Any                       # `_program_seed(prob)`
    compiler::Symbol
    writes::Vector{String}          # W, flat-layout order
    aux_names::Vector{String}       # R \ W, flat-layout order
    flat::FlattenedSystem           # the selected flattened system
    doc::Dict{String,Any}           # its run document
    front::Any                      # (file, model_name, keywords) of the front door
    f!::F
    internal::StateLayout           # the slot space `f!` addresses
    shapes::Dict{String,Vector{String}}  # array state → index sets per dim
    layout::TileLayout
    maps::_CopyMaps
    claimed::Threads.Atomic{Bool}   # its own `f!` handed to a workspace
end

"""
    TileProgram

An operator restricted to one tile of a [`Decomposition`](@ref)
([`restrict`](@ref)). Evaluate it with [`rhs!`](@ref) on buffers in its
[`tile_layout`](@ref).
"""
struct TileProgram{F}
    op::RhsProgram
    dec::Decomposition
    owned::Dict{String,UnitRange{Int}}
    storage::Dict{String,UnitRange{Int}}
    f!::F
    internal::StateLayout
    layout::TileLayout
    maps::_CopyMaps
    claimed::Threads.Atomic{Bool}
end

# One pre-gathered lane input: `buf[l] = src[subs…]` at lane `l`'s cell.
struct _LaneGather
    buf::Vector{Float64}             # an instance's live buffer (C lanes)
    src::AbstractArray               # const array or live forcing buffer
    name::String
    subs::Vector{ASTExpr}
    vars::Vector{Pair{String,Int}}   # loop variable → lane-set row of `cells`
    consts::AbstractDict             # the const arrays a subscript may read
end

"""
    RhsWorkspace

Everything a program call writes ([`rhs_workspace`](@ref)): the internal state
and derivative vectors, the compiled right-hand side that addresses them (its
observed buffers and memoized values are per instance), and for a lane program
the live lane buffers that instance reads and the forcing epoch it stamps. The
first workspace of a program runs the program's own compiled instance; each
further one compiles its own. One workspace per concurrent caller.
"""
struct RhsWorkspace{F}
    owner::Any                              # the program this workspace serves
    u::Vector{Float64}
    du::Vector{Float64}
    f!::F
    index_bufs::Vector{Vector{Float64}}     # lane programs: lane-set index buffers
    gathers::Vector{_LaneGather}            # lane programs: the pre-gathered inputs of `f!`
    env::Dict{String,Int}                   # lane programs: subscript scratch
    epoch::Base.RefValue{UInt64}            # the forcing epoch `f!` stamps
end

# ============================================================================
# §1 Errors
# ============================================================================

_range_error(code::String, msg::AbstractString) = SimulateError(String(msg), code)

function _require_native(x, call::AbstractString)
    c = x isa RhsProgram ? x.compiler : x.op.compiler
    c === :native || throw(_range_error(ERROR_CODES.COMPILER_UNAVAILABLE,
        "$call needs a program built with compiler = :native; this one was built " *
        "with compiler = :$c, which has no range-restricted lowering (API_SPEC §5.8)"))
    return nothing
end

# ============================================================================
# §2 Selection (API_SPEC §5.8, "Selection")
# ============================================================================

_origin_eq(a::TermOrigin, b::TermOrigin) =
    a.component == b.component && a.coupling == b.coupling

_origin_str(o::TermOrigin) = o.component !== nothing ? "{component: $(o.component)}" :
                                                       "{coupling: $(o.coupling)}"

# The state a flattened equation's left-hand side differentiates, or `nothing`
# for an equation that is not a `D` equation.
function _d_target(lhs::ASTExpr)
    body = lhs
    if body isa OpExpr && _is_faq_op((body::OpExpr).op) && (body::OpExpr).expr_body !== nothing
        body = (body::OpExpr).expr_body
    end
    (body isa OpExpr && (body::OpExpr).op == "D" && length((body::OpExpr).args) == 1) ||
        return nothing
    a = (body::OpExpr).args[1]
    a isa VarExpr && return (a::VarExpr).name
    (a isa OpExpr && (a::OpExpr).op == "index" && !isempty((a::OpExpr).args) &&
     (a::OpExpr).args[1] isa VarExpr) && return ((a::OpExpr).args[1]::VarExpr).name
    return nothing
end

_normalize_terms(terms::Symbol) = terms === :all ? :all :
    throw(ArgumentError("select: `terms` is `:all` or a vector of TermOrigin, got :$terms"))
function _normalize_terms(terms)
    out = TermOrigin[]
    for t in terms
        t isa TermOrigin || throw(ArgumentError(
            "select: `terms` is `:all` or a vector of TermOrigin, got an element $(repr(t))"))
        push!(out, t)
    end
    return out
end

# The selected flattened system (rules 1–3 of "Selection") and the state names
# its kept rules read, directly or through observeds.
#
# `writable` is the set `writes` draws from: every state of `flat` for the
# Problem's whole model, a program's own written variables for a selection of
# a selection (whose other states are read-only `aux`).
function _select_flat(flat::FlattenedSystem, writes, terms,
                      writable = Set{String}(keys(flat.state_variables)))
    states = flat.state_variables
    W = Set{String}()
    if writes === :all
        union!(W, writable)
    else
        for w in writes
            ws = String(w)
            ws in writable || throw(SimulateError(
                "select: `writes` names '$ws', which is not a variable this program " *
                "writes; it writes $(join(sort!(collect(writable)), ", "))"))
            push!(W, ws)
        end
    end
    keep(c::Contribution) = terms === :all ||
        any(o -> any(t -> _origin_eq(o, t), terms), c.origins)
    eqs = Equation[]
    contribs = Vector{Contribution}[]
    for (eq, cs) in zip(flat.equations, flat.equation_contributions)
        tgt = _d_target(eq.lhs)
        if tgt === nothing
            push!(eqs, eq)
            push!(contribs, cs)
            continue
        end
        kept = Contribution[c for c in cs if keep(c)]
        if !(tgt in W)
            isempty(kept) || throw(_range_error(ERROR_CODES.RANGE_SELECTION_WRITES_INCOMPLETE,
                "select: '$tgt' has kept contributions authored by " *
                join(unique!([_origin_str(o) for c in kept for o in c.origins]), ", ") *
                " but is not in `writes`; add '$tgt' to `writes` or drop those terms"))
            continue
        end
        lifted = _is_lifted(eq, flat.lifted_shapes)
        if isempty(kept)
            # An operator that does not touch a variable it writes: rhs 0.
            zero = Contribution[Contribution(NumExpr(0.0), TermOrigin[])]
            push!(eqs, _equation_from(eq, zero, lifted))
            push!(contribs, zero)
        elseif length(kept) == length(cs)
            push!(eqs, eq)
            push!(contribs, cs)
        else
            push!(eqs, _equation_from(eq, kept, lifted))
            push!(contribs, kept)
        end
    end
    # ---- the states and observeds the kept rules reach ----
    # Read through every surviving template reference: a template body names
    # the variables its expansion reads.
    sel = FlattenedSystem(flat; equations = eqs, equation_contributions = contribs)
    xeqs = expand_flattened_refs(sel).equations
    defs = Dict{String,Vector{ASTExpr}}()
    roots = Set{String}()
    for eq in xeqs
        if _d_target(eq.lhs) !== nothing
            _referenced_var_names(eq.rhs, roots)
        elseif eq.lhs isa VarExpr
            push!(get!(() -> ASTExpr[], defs, (eq.lhs::VarExpr).name), eq.rhs)
        else
            _referenced_var_names(eq.lhs, roots)
            _referenced_var_names(eq.rhs, roots)
        end
    end
    reached = Set{String}()
    todo = collect(roots)
    while !isempty(todo)
        n = pop!(todo)
        n in reached && continue
        push!(reached, n)
        for d in get(defs, n, ASTExpr[])
            for r in _referenced_var_names(d)
                r in reached || push!(todo, r)
            end
        end
    end
    R = Set{String}(n for n in reached if haskey(states, n))
    live_states = union(W, R)
    live = union(reached, live_states)
    # ---- drop what no kept rule reaches ----
    eqs2 = Equation[]
    contribs2 = Vector{Contribution}[]
    for (eq, cs) in zip(eqs, contribs)
        if _d_target(eq.lhs) === nothing && eq.lhs isa VarExpr &&
           !((eq.lhs::VarExpr).name in live)
            continue
        end
        push!(eqs2, eq)
        push!(contribs2, cs)
    end
    filt(d) = OrderedDict{String,ModelVariable}(k => v for (k, v) in d if k in live)
    flat2 = FlattenedSystem(flat;
        state_variables = OrderedDict{String,ModelVariable}(k => v for (k, v) in states
                                                            if k in live_states),
        observed_variables = filt(flat.observed_variables),
        algebraic_variables = OrderedDict{String,ModelVariable}(
            k => v for (k, v) in flat.algebraic_variables if k in live_states),
        equations = eqs2,
        field_ics = Pair{String,ASTExpr}[p for p in flat.field_ics if first(p) in live_states],
        lifted_shapes = OrderedDict{String,Vector{Int}}(
            k => v for (k, v) in flat.lifted_shapes if k in live_states),
        equation_contributions = contribs2)
    return flat2, W, R
end

# The faq initialization equations whose target the selection kept.
function _select_init(init::Vector{Equation}, live_states)
    out = Equation[]
    for eq in init
        refs = _referenced_var_names(eq.lhs)
        any(r -> r in live_states, refs) && push!(out, eq)
    end
    return out
end

# ============================================================================
# §3 Building a program
# ============================================================================

abstract type _RangeSpec end

_range_restrict_parts(::_RangeSpec, model, cls, parts, index_sets, ca, pa) = parts
_range_state_boxes!(::_RangeSpec, avi) = avi
_range_observed_box(::_RangeSpec, name, dims) = (ones(Int, length(dims)), copy(dims))
_range_fill_equations(::_RangeSpec, name, def, dims, box) =
    _materialized_fill_equations(name, def, dims)
_range_front_door_done(::_RangeSpec, file, model_name, kwd) = nothing
_range_build_epoch(::_RangeSpec, epoch) = nothing

# A whole-domain program build: records the front door's product, so a
# restriction re-lowers from it.
struct _CaptureSpec <: _RangeSpec
    front::Base.RefValue{Any}
end
function _range_front_door_done(s::_CaptureSpec, file, model_name, kwd)
    s.front[] = (file, model_name, Dict{Symbol,Any}(kwd))
    return nothing
end

# The keyword set of a re-lowering: the front door's, with every registry a
# build may extend copied, so one build never sees another's additions.
function _relower_kwargs(front)
    _, _, kwd = front
    kw = Dict{Symbol,Any}()
    for (k, v) in kwd
        kw[k] = (k === :const_arrays || k === :param_arrays) ? copy(v) : v
    end
    kw[:materialize_out] = nothing
    kw[:inspect] = nothing
    return kw
end

# Build the program of `doc` (a selected run document) the way `esm_problem`
# built the Problem's, without its discrete-cadence cut.
function _program_build(seed, doc::Dict{String,Any})
    front = Ref{Any}(nothing)
    f!, _u0, _p, _ts, var_map = _with_range_spec(_CaptureSpec(front)) do
        _build_evaluator(doc; compiler = seed.compiler, form = :inplace,
            model_name = seed.model_name, parameter_overrides = seed.overrides,
            const_arrays = seed.const_arrays, param_arrays = seed.param_arrays,
            _gated_providers = seed.gated_providers, _sample_time = seed.sample_time)
    end
    return f!, var_map, front[]
end

# Re-lower a program's recorded front-door product under `spec`.
function _relower(prog::RhsProgram, spec::_RangeSpec)
    file, model_name, _ = prog.front
    kw = _relower_kwargs(prog.front)
    f!, _u0, _p, _ts, var_map = _with_compiler_plan(_plan_for(prog.compiler)) do
        _with_range_spec(spec) do
            _build_evaluator(file; model_name = model_name, kw...)
        end
    end
    return f!, var_map
end

# Each array state's index sets, from the flattened declaration (or `dim<d>`
# for a state whose declaration carries no shape).
function _state_shapes(flat::FlattenedSystem, internal::StateLayout)
    out = Dict{String,Vector{String}}()
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

# Column-major strides over a box.
function _box_strides(box::Vector{UnitRange{Int}})
    s = Vector{Int}(undef, length(box))
    acc = 1
    for d in eachindex(box)
        s[d] = acc
        acc *= length(box[d])
    end
    return s, acc
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
function _copy_maps(layout::TileLayout, internal::StateLayout, to_internal,
                    extra::AbstractDict = Dict{String,Vector{String}}())
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
    return _CopyMaps(u_src, u_dst, a_src, a_dst, du_src, du_dst)
end

function _whole_program(seed, flat::FlattenedSystem, W::Set{String}, R::Set{String},
                        writes, terms)
    init = seed.init
    live = union(W, R)
    init2 = (init === nothing || isempty(init)) ? Equation[] : _select_init(init, live)
    doc = _flat_run_doc(flat, seed.coordinates, seed.solver, init2)
    f!, internal, front = _program_build(seed, doc)
    present = Set{String}(vcat(collect(_layout_scalar_names(internal)),
                               [b.name for b in _layout_blocks(internal)]))
    unames = _flat_order(internal, [n for n in W if n in present])
    anames = _flat_order(internal, [n for n in R if n in present && !(n in W)])
    shapes = _state_shapes(flat, internal)
    gbox(n) = (b = _layout_block(internal, n);
               bx = UnitRange{Int}[b.lo[d]:b.hi[d] for d in eachindex(b.lo)]; (bx, bx))
    ublocks, nu = _make_blocks(internal, shapes, unames, gbox; owned = true)
    ablocks, na = _make_blocks(internal, shapes, anames, gbox; owned = false)
    layout = TileLayout(ublocks, ablocks, nu, na)
    maps = _copy_maps(layout, internal, (n, d, x) -> x)
    return RhsProgram(seed, seed.compiler, unames, anames, flat, doc, front, f!,
                      internal, shapes, layout, maps, Threads.Atomic{Bool}(false))
end

"""
    rhs_program(prob::EsmProblem) -> RhsProgram

The Problem's right-hand side as a program value (API_SPEC §5.8): the whole
model over the whole domain, with `u` every state of the Problem (in the
Problem's flat layout) and `aux` empty. [`select`](@ref) narrows it to one
operator; [`halo`](@ref), [`restrict`](@ref) and [`lanes`](@ref) restrict it.
"""
function rhs_program(prob::EsmProblem)
    c = compiler(prob)
    seed = c in (:native, :interpreter) ? _program_seed(prob) : nothing
    (seed === nothing || !(c in (:native, :interpreter))) &&
        throw(_range_error(ERROR_CODES.COMPILER_UNAVAILABLE,
            "rhs_program needs a Problem built by esm_problem with compiler = :native " *
            "(or :interpreter); this one was built with compiler = :$c, which carries no " *
            "program of its own (API_SPEC §5.8)"))
    flat, W, R = _select_flat(seed.flat, :all, :all)
    return _whole_program(seed, flat, W, R, :all, :all)
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
    return _whole_program(prog.seed, flat, W, R, writes, t)
end

"""
    tile_layout(x) -> TileLayout

The `u`/`aux` layout of a whole-domain program or a tile (API_SPEC §5.8,
"Layouts").
"""
tile_layout(x::RhsProgram) = x.layout
tile_layout(x::TileProgram) = x.layout

"""
    rhs_workspace(x) -> RhsWorkspace

Everything [`rhs!`](@ref) on `x` (a program, a tile or a lane program) writes.
One per concurrent caller: calls through different workspaces share nothing
mutable. The first workspace of `x` takes `x`'s own compiled instance; each
further one compiles another, so make them before the calls that use them, from
one task at a time.
"""
function rhs_workspace(x::Union{RhsProgram,TileProgram})
    f! = _claim!(x) ? x.f! : _fresh_instance(x)
    n = length(x.internal)
    return RhsWorkspace(x, zeros(n), zeros(n), f!, Vector{Float64}[], _LaneGather[],
                        Dict{String,Int}(), _new_forcing_epoch())
end

# Whether this call takes the program's own compiled instance for a workspace
# (the first one does; every later workspace compiles its own).
_claim!(x) = !Threads.atomic_xchg!(x.claimed, true)

# Two builds of one program lay their slots out identically.
function _same_layout(a::StateLayout, b::StateLayout)
    length(a) == length(b) && a.scalars == b.scalars || return false
    ba, bb = _layout_blocks(a), _layout_blocks(b)
    length(ba) == length(bb) || return false
    return all(((p, q),) -> p.name == q.name && p.base == q.base && p.lo == q.lo &&
                            p.hi == q.hi, zip(ba, bb))
end

function _check_instance(internal::StateLayout, x)
    _same_layout(internal, x.internal) || error(
        "rhs_workspace: a rebuild of this program laid its slots out differently")
    return nothing
end

# A fresh compiled instance of `x`'s right-hand side, over `x`'s layout.
function _fresh_instance(x::RhsProgram)
    f!, internal, _ = _program_build(x.seed, x.doc)
    _check_instance(internal, x)
    return f!
end

function _check_workspace(x, ws::RhsWorkspace)
    ws.owner === x || throw(ArgumentError(
        "rhs!: the workspace was made by `rhs_workspace` for another program"))
    return nothing
end

"""
    rhs!(du, x, ws, u, aux, p, t, fs = nothing) -> du

Evaluate the program or tile `x` (API_SPEC §5.8): `u` and `aux` in
[`tile_layout`](@ref)`(x)`, `p` the Problem's parameters, `fs` the forcing
buffers the program was built against (`forcing_buffers(prob)`) or `nothing`.
Writes only the owned rows of `du`; every other element is left untouched.
Allocation-free.
"""
function rhs!(du::AbstractVector, x::Union{RhsProgram,TileProgram}, ws::RhsWorkspace,
              u::AbstractVector, aux::AbstractVector, p, t, fs = nothing)
    L = x.layout
    length(u) == L.n_u || throw(DimensionMismatch(
        "rhs!: `u` has $(length(u)) elements; the layout has $(L.n_u)"))
    length(aux) == L.n_aux || throw(DimensionMismatch(
        "rhs!: `aux` has $(length(aux)) elements; the layout has $(L.n_aux)"))
    length(du) == L.n_u || throw(DimensionMismatch(
        "rhs!: `du` has $(length(du)) elements; the layout has $(L.n_u)"))
    _check_workspace(x, ws)
    m = x.maps
    U = ws.u
    @inbounds for k in eachindex(m.u_src)
        U[m.u_dst[k]] = u[m.u_src[k]]
    end
    @inbounds for k in eachindex(m.aux_src)
        U[m.aux_dst[k]] = aux[m.aux_src[k]]
    end
    D = ws.du
    ws.f!(D, U, p, t)
    @inbounds for k in eachindex(m.du_src)
        du[m.du_dst[k]] = D[m.du_src[k]]
    end
    return du
end

# ============================================================================
# §4 Need-box analysis (API_SPEC §5.8, "Halo report" and tile rules 1–3)
# ============================================================================
#
# An abstract interpretation of the equation stream the build compiles (the
# `parts` the range seam receives: templates expanded, nested reductions
# hoisted, index-set ranges resolved). Every loop variable is bound to the set
# of global cells it ranges over (`_Bind`); a subscript's image is computed by
# evaluating it with `_eval_const_int` over those cells, the function the
# compiler itself resolves a subscript with, so an affine offset, a `mod` wrap
# and an explicit wrap (`f[NLON-1]`) are all just images. A variable aligned
# with a cut axis also carries its offset interval relative to the output cell
# that (transitively) reads it, which is what the halo report is made of.

# A sorted list of disjoint, non-adjacent integer intervals.
struct _ISet
    ivs::Vector{UnitRange{Int}}
end
_ISet() = _ISet(UnitRange{Int}[])
_ISet(r::UnitRange{Int}) = isempty(r) ? _ISet() : _ISet(UnitRange{Int}[r])
Base.isempty(s::_ISet) = isempty(s.ivs)
Base.length(s::_ISet) = sum(length, s.ivs; init = 0)
Base.minimum(s::_ISet) = first(s.ivs[1])
Base.maximum(s::_ISet) = last(s.ivs[end])
Base.in(x::Integer, s::_ISet) = any(r -> x in r, s.ivs)
Base.:(==)(a::_ISet, b::_ISet) = a.ivs == b.ivs
_points(s::_ISet) = Iterators.flatten(s.ivs)

function _iset_points(pts)
    v = sort!(unique!(collect(Int, pts)))
    isempty(v) && return _ISet()
    out = UnitRange{Int}[]
    lo = prev = v[1]
    for x in Iterators.drop(v, 1)
        if x == prev + 1
            prev = x
        else
            push!(out, lo:prev)
            lo = prev = x
        end
    end
    push!(out, lo:prev)
    return _ISet(out)
end

function _iset_union(a::_ISet, b::_ISet)
    isempty(a) && return b
    isempty(b) && return a
    rs = sort!(vcat(a.ivs, b.ivs); by = first)
    out = UnitRange{Int}[rs[1]]
    for r in Iterators.drop(rs, 1)
        if first(r) <= last(out[end]) + 1
            out[end] = first(out[end]):max(last(out[end]), last(r))
        else
            push!(out, r)
        end
    end
    return _ISet(out)
end

function _iset_intersect(a::_ISet, r::UnitRange{Int})
    out = UnitRange{Int}[]
    for x in a.ivs
        y = max(first(x), first(r)):min(last(x), last(r))
        isempty(y) || push!(out, y)
    end
    return _ISet(out)
end
_iset_intersect(a::_ISet, b::_ISet) =
    foldl(_iset_union, (_iset_intersect(a, r) for r in b.ivs); init = _ISet())

function _iset_setdiff(a::_ISet, b::_ISet)
    out = UnitRange{Int}[]
    for x in a.ivs
        pieces = UnitRange{Int}[x]
        for r in b.ivs
            nxt = UnitRange{Int}[]
            for p in pieces
                lo = first(p):min(last(p), first(r) - 1)
                hi = max(first(p), last(r) + 1):last(p)
                isempty(lo) || push!(nxt, lo)
                isempty(hi) || push!(nxt, hi)
            end
            pieces = nxt
        end
        append!(out, pieces)
    end
    return _iset_points(Iterators.flatten(out))   # re-normalize
end

_iset_shift(a::_ISet, k::Int) = _ISet(UnitRange{Int}[(first(r) + k):(last(r) + k) for r in a.ivs])

# One loop variable's binding: the global cells it ranges over; the cut axis
# it is aligned with ("" for none); its offsets relative to the reading output
# cell (`dlo > dhi` when unknown); whether it is a contraction index; whether
# its value is only known at run time.
struct _Bind
    cells::_ISet
    axis::String
    dlo::Int
    dhi::Int
    contracted::Bool
    runtime::Bool
end
_Bind(cells::_ISet) = _Bind(cells, "", 1, 0, false, false)
_has_offsets(b::_Bind) = b.dlo <= b.dhi
_with_cells(b::_Bind, c::_ISet) = _Bind(c, b.axis, b.dlo, b.dhi, b.contracted, b.runtime)

function _bind_merge(a::_Bind, b::_Bind)
    lo = _has_offsets(a) ? (_has_offsets(b) ? min(a.dlo, b.dlo) : a.dlo) : b.dlo
    hi = _has_offsets(a) ? (_has_offsets(b) ? max(a.dhi, b.dhi) : a.dhi) : b.dhi
    return _Bind(_iset_union(a.cells, b.cells), isempty(a.axis) ? b.axis : a.axis,
                 lo, hi, a.contracted || b.contracted, a.runtime || b.runtime)
end

# The cut axes of a decomposition, measured against the program.
struct _AxisModel
    cut::Dict{String,Tuple{String,Bool}}      # index set → (cut axis, is a face set)
    N::Dict{String,Int}                       # cut axis → its cell extent
    period::Dict{String,Union{Nothing,Int}}   # cut axis → period
end

_axis_domain(m::_AxisModel, axis::String, face::Bool) = 1:(m.N[axis] + (face ? 1 : 0))
_axis_period(m::_AxisModel, axis::String) = m.period[axis]

# The offset `δ` as its nearest periodic image.
@inline function _wrap_offset(m::_AxisModel, axis::String, δ::Int)
    P = m.period[axis]
    P === nothing && return δ
    r = mod(δ, P)
    return r > P ÷ 2 ? r - P : r
end

# A tile's storage crossing the seam of a periodic axis: the in-domain cells it
# stores directly (`near`, which holds the owned box) and the images of the
# cells it stores past the seam (`far`, at the other end of the axis). The axis
# splits into two sides at `cut`, each holding one piece.
struct _Seam
    near::UnitRange{Int}
    far::UnitRange{Int}
    far_high::Bool                            # `far` lies above `near`
    cut::Int
end

_seam_far(s::_Seam, g::Integer) = s.far_high ? g > s.cut : g <= s.cut

# The seam a tile's storage `S` crosses on a periodic axis of period `P` (face
# cells when `face`), or `nothing` when it crosses none, or stores so much of
# the axis that both pieces meet (its block is then the whole axis, which is
# no larger than its storage).
function _tile_seam(S::UnitRange{Int}, dom::UnitRange{Int}, P::Int, face::Bool)
    Sf = face ? (first(S):(last(S) + 1)) : S
    issubset(Sf, dom) && return nothing
    near = max(first(Sf), first(dom)):min(last(Sf), last(dom))
    imgs = Int[]
    for x in Sf
        x in dom && continue
        y = x + P * cld(first(dom) - x, P)
        y in dom && push!(imgs, y)
    end
    (isempty(near) || isempty(imgs)) && return nothing
    far = minimum(imgs):maximum(imgs)
    if first(far) > last(near) + 1
        return _Seam(near, far, true, (last(near) + first(far)) ÷ 2)
    elseif last(far) < first(near) - 1
        return _Seam(near, far, false, (last(far) + first(near)) ÷ 2)
    end
    return nothing
end

mutable struct _NeedCtx
    mode::Symbol                              # :halo, :tile or :lane
    axes::_AxisModel
    owned::Dict{String,UnitRange{Int}}        # cut axis → owned cells (tile)
    storage::Dict{String,UnitRange{Int}}      # cut axis → storage cells (tile)
    shapes::Dict{String,Vector{String}}       # array variable → index sets
    extents::Dict{String,Vector{Int}}         # array variable → extents
    states::Set{String}                       # array states
    scalar_states::Set{String}
    obs_defs::Dict{String,ASTExpr}            # array observeds
    scalar_defs::Dict{String,ASTExpr}         # scalar observeds
    mat_obs::Set{String}
    params::Dict{String,Int}                  # integer-valued scalar parameters
    const_arrays::AbstractDict
    arrays::Set{String}                       # every non-state array name (const, live)
    reach::Dict{Tuple{String,String},Tuple{Int,Int}}
    reads::Set{String}
    obs_need::Dict{String,Vector{_Bind}}
    work::Vector{String}
    obs_rule::Dict{String,String}
    scalar_stack::Set{String}
    # Seam crossings (tile mode): `(axis, face)` → its seam; the walk's current
    # context (`("", ())` for the state equations, `(observed, sides)` for an
    # observed evaluated on one side of each seam it crosses); the `index`
    # nodes being walked; and, per such node, per (variable, context), which
    # sides of each seam its reads land on (bit 1 near, bit 2 far).
    seams::Dict{Tuple{String,Bool},_Seam}
    tag::Tuple{String,Tuple}
    idx_stack::Vector{Any}
    marks::IdDict{Any,Dict{Tuple{String,Tuple{String,Tuple}},Vector{UInt8}}}
end

_NeedCtx(mode, axes, owned, storage, shapes, extents, states, scalar_states, obs_defs,
         scalar_defs, mat_obs, params, const_arrays, arrays, reach, reads, obs_need, work,
         obs_rule, scalar_stack) =
    _NeedCtx(mode, axes, owned, storage, shapes, extents, states, scalar_states, obs_defs,
             scalar_defs, mat_obs, params, const_arrays, arrays, reach, reads, obs_need,
             work, obs_rule, scalar_stack, Dict{Tuple{String,Bool},_Seam}(), ("", ()),
             Any[], IdDict{Any,Dict{Tuple{String,Tuple{String,Tuple}},Vector{UInt8}}}())

# The seam dimension `d` of variable `n` crosses, or `nothing`.
function _dim_seam(ctx::_NeedCtx, n::String, d::Int)
    isempty(ctx.seams) && return nothing
    cut = get(ctx.axes.cut, ctx.shapes[n][d], nothing)
    cut === nothing && return nothing
    return get(ctx.seams, cut, nothing)
end

# Record which sides of its seams a read of `n` at `binds` lands on.
function _seam_mark!(ctx::_NeedCtx, n::String, binds::Vector{_Bind})
    isempty(ctx.seams) && return nothing
    bits = zeros(UInt8, length(binds))
    any_seam = false
    for d in eachindex(binds)
        s = _dim_seam(ctx, n, d)
        s === nothing && continue
        any_seam = true
        for r in binds[d].cells.ivs
            # An interval's sides: it is on one side unless it spans the cut.
            bits[d] |= _seam_far(s, first(r)) ? 0x02 : 0x01
            bits[d] |= _seam_far(s, last(r)) ? 0x02 : 0x01
        end
    end
    any_seam || return nothing
    node = isempty(ctx.idx_stack) ? nothing : ctx.idx_stack[end]
    d = get!(() -> Dict{Tuple{String,Tuple{String,Tuple}},Vector{UInt8}}(), ctx.marks, node)
    k = (n, ctx.tag)
    cur = get(d, k, nothing)
    d[k] = cur === nothing ? bits : cur .| bits
    return nothing
end

# The rule name a diagnostic shows: a hoisted reduction under its reader's name.
function _rule_display(name::AbstractString)
    s = String(name)
    occursin('\0', s) || return s
    parts = split(s, '\0'; keepempty = false)
    return string(parts[end], " (a nested reduction lifted out of it)")
end

_global_locality(rule, axis, why) = _range_error(ERROR_CODES.RANGE_GLOBAL_LOCALITY,
    "rule '$(_rule_display(rule))' has global locality along the decomposed index set " *
    "'$axis': $why. A tile cannot evaluate it; keep this operator whole-domain " *
    "(API_SPEC §5.8, decision 8)")

# The loop variables and the run-time names a subscript reads.
function _sub_names(ctx::_NeedCtx, s::ASTExpr, env)
    vars = String[]
    runtime = String[]
    for n in _referenced_var_names(s)
        if haskey(env, n)
            push!(vars, n)
        elseif haskey(ctx.params, n) || haskey(ctx.const_arrays, n)
            continue
        else
            push!(runtime, n)
        end
    end
    return sort!(vars), runtime
end

const _IMAGE_LIMIT = 50_000_000

# The binding of one subscript `s` at a dimension on index set `dimset`
# (`nothing` for an anonymous producer's dimension).
function _bind_sub(ctx::_NeedCtx, s::ASTExpr, env::Dict{String,_Bind},
                   anchors::Dict{String,String}, dimset::Union{Nothing,String},
                   rule::String)
    cut = dimset === nothing ? nothing : get(ctx.axes.cut, dimset, nothing)
    vars, runtime = _sub_names(ctx, s, env)
    if !isempty(runtime) || any(v -> env[v].runtime, vars)
        cut === nothing || throw(_global_locality(rule, dimset,
            "its subscript `$(format_expression(s, :ascii))` is data-dependent"))
        return _Bind(_ISet(), "", 1, 0, false, true)
    end
    if cut !== nothing
        for v in vars
            env[v].contracted && throw(_global_locality(rule, dimset,
                "it contracts (or scans) over the index `$v` along it"))
        end
    end
    # ---- the image ----
    idx = Dict{String,Int}(ctx.params)
    pts = Int[]
    n = prod((length(env[v].cells) for v in vars); init = 1)
    n > _IMAGE_LIMIT && _refuse_rule(_rule_display(rule),
        "tile restriction: the subscript `$(format_expression(s, :ascii))` ranges over " *
        "$n index combinations")
    evalat() = try
        _eval_const_int(s, idx, ctx.const_arrays)
    catch err
        err isa TreeWalkError || rethrow()
        cut === nothing || throw(_global_locality(rule, dimset,
            "its subscript `$(format_expression(s, :ascii))` has no value at build time"))
        nothing
    end
    per_x = length(vars) == 1 ? Tuple{Int,Int}[] : nothing
    if isempty(vars)
        g = evalat()
        g === nothing && return _Bind(_ISet(), "", 1, 0, false, true)
        push!(pts, g)
    else
        for combo in Iterators.product((collect(_points(env[v].cells)) for v in vars)...)
            for (k, v) in enumerate(vars)
                idx[v] = combo[k]
            end
            g = evalat()
            g === nothing && return _Bind(_ISet(), "", 1, 0, false, true)
            push!(pts, g)
            per_x === nothing || push!(per_x, (combo[1], g))
        end
    end
    image = _iset_points(pts)
    # ---- the alignment and the offsets ----
    axis, face = cut === nothing ? ("", false) : cut
    if cut === nothing
        al = unique!([env[v].axis for v in vars if !isempty(env[v].axis)])
        length(al) == 1 && length(vars) == 1 && (axis = al[1])
    end
    isempty(axis) && return _Bind(image, "", 1, 0, false, false)
    indom(g) = cut === nothing || g in _axis_domain(ctx.axes, axis, face)
    dlo, dhi = typemax(Int), typemin(Int)
    if per_x !== nothing && env[vars[1]].axis == axis
        b = env[vars[1]]
        if _has_offsets(b)
            for (x, g) in per_x
                indom(g) || continue
                δ = _wrap_offset(ctx.axes, axis, g - x)
                dlo = min(dlo, δ + b.dlo)
                dhi = max(dhi, δ + b.dhi)
            end
        end
    else
        a = get(anchors, axis, nothing)
        if a !== nothing && haskey(env, a) && _has_offsets(env[a])
            b = env[a]
            gs = [g for g in _points(image) if indom(g)]
            ys = collect(_points(b.cells))
            if length(gs) * length(ys) <= 1_000_000
                for g in gs, y in ys
                    δ = _wrap_offset(ctx.axes, axis, g - y)
                    dlo = min(dlo, δ + b.dlo)
                    dhi = max(dhi, δ + b.dhi)
                end
            elseif !isempty(gs)
                dlo = minimum(gs) - maximum(ys) + b.dlo
                dhi = maximum(gs) - minimum(ys) + b.dhi
            end
        end
    end
    dlo > dhi && return _Bind(image, axis, 1, 0, false, false)
    return _Bind(image, axis, dlo, dhi, false, false)
end

function _is_arrayish(ctx::_NeedCtx, e::ASTExpr)
    e isa VarExpr && return (e::VarExpr).name in ctx.states ||
                            haskey(ctx.obs_defs, (e::VarExpr).name) ||
                            (e::VarExpr).name in ctx.arrays
    e isa OpExpr || return false
    o = e::OpExpr
    (o.op == "makearray" || (_is_faq_op(o.op) && o.output_idx !== nothing &&
                             !isempty(o.output_idx))) && return true
    o.op == "const" && return o.value isa AbstractVector
    o.op == "index" && return false
    return any(a -> _is_arrayish(ctx, a), o.args)
end

# Walk an expression evaluated at the cells `env` binds.
function _need_walk!(ctx::_NeedCtx, e::ASTExpr, env::Dict{String,_Bind},
                     anchors::Dict{String,String}, rule::String)
    if e isa VarExpr
        n = (e::VarExpr).name
        haskey(env, n) && return nothing
        if haskey(ctx.scalar_defs, n)
            n in ctx.scalar_stack && return nothing
            push!(ctx.scalar_stack, n)
            try
                _need_walk!(ctx, ctx.scalar_defs[n], env, anchors, n)
            finally
                delete!(ctx.scalar_stack, n)
            end
        elseif n in ctx.states || haskey(ctx.obs_defs, n)
            # A bare whole-array reference in a cell context: every cell.
            sh = get(ctx.shapes, n, String[])
            for s in sh
                haskey(ctx.axes.cut, s) && throw(_global_locality(rule, s,
                    "it reads the whole array '$n' along it"))
            end
        end
        return nothing
    end
    e isa OpExpr || return nothing
    o = e::OpExpr
    if o.op == "index" && !isempty(o.args)
        push!(ctx.idx_stack, o)
        try
            _need_index!(ctx, o.args[1], ASTExpr[a for a in o.args[2:end]], env, anchors, rule)
        finally
            pop!(ctx.idx_stack)
        end
        return nothing
    end
    if _is_faq_op(o.op) && o.expr_body !== nothing
        # A bare aggregate: a reduction over its ranges.
        env2 = copy(env)
        for (k, r) in _ranges_dict(o)
            env2[String(k)] = _Bind(_range_cells(ctx, r), "", 1, 0, true, false)
        end
        _need_walk!(ctx, o.expr_body, env2, anchors, rule)
        o.filter === nothing || _need_walk!(ctx, o.filter, env2, anchors, rule)
        return nothing
    end
    for a in o.args
        _need_walk!(ctx, a, env, anchors, rule)
    end
    o.expr_body === nothing || _need_walk!(ctx, o.expr_body, env, anchors, rule)
    o.filter === nothing || _need_walk!(ctx, o.filter, env, anchors, rule)
    if o.values !== nothing
        for v in o.values
            _need_walk!(ctx, v, env, anchors, rule)
        end
    end
    return nothing
end

# The cells a `ranges` entry spans.
function _range_cells(ctx::_NeedCtx, r)
    r isa AbstractVector || return _ISet()
    vals = Int[]
    for x in r
        v = x isa Integer ? Int(x) : x isa ASTExpr ?
            (try _eval_const_int(x, Dict{String,Int}(ctx.params), ctx.const_arrays)
             catch err; err isa TreeWalkError || rethrow(); nothing end) : nothing
        v === nothing && return _ISet()
        push!(vals, v)
    end
    length(vals) == 2 && return _ISet(vals[1]:vals[2])
    length(vals) == 3 && return _iset_points(vals[1]:vals[2]:vals[3])
    return _ISet()
end

# A region bound as an integer.
function _region_int(ctx::_NeedCtx, x)
    x isa Integer && return Int(x)
    x isa ASTExpr || return nothing
    try
        return _eval_const_int(x, Dict{String,Int}(ctx.params), ctx.const_arrays)
    catch err
        err isa TreeWalkError || rethrow()
        return nothing
    end
end

# `box \ cut` as a list of disjoint boxes.
function _box_subtract(boxes::Vector{Vector{UnitRange{Int}}}, cut::Vector{UnitRange{Int}})
    out = Vector{UnitRange{Int}}[]
    for b in boxes
        inter = [max(first(b[d]), first(cut[d])):min(last(b[d]), last(cut[d])) for d in eachindex(b)]
        if any(isempty, inter)
            push!(out, b)
            continue
        end
        rest = copy(b)
        for d in eachindex(b)
            lo = first(rest[d]):(first(inter[d]) - 1)
            hi = (last(inter[d]) + 1):last(rest[d])
            isempty(lo) || (p = copy(rest); p[d] = lo; push!(out, p))
            isempty(hi) || (p = copy(rest); p[d] = hi; push!(out, p))
            rest[d] = inter[d]
        end
    end
    return out
end

# Restrict `env` to the points whose subscript `s` lands in `r`; `nothing` when
# none does.
function _restrict_env(ctx::_NeedCtx, env::Dict{String,_Bind}, s::ASTExpr,
                       r::UnitRange{Int})
    vars, runtime = _sub_names(ctx, s, env)
    isempty(runtime) || return env
    idx = Dict{String,Int}(ctx.params)
    if isempty(vars)
        g = try _eval_const_int(s, idx, ctx.const_arrays) catch err
            err isa TreeWalkError || rethrow(); return env end
        return g in r ? env : nothing
    end
    length(vars) == 1 || return env
    v = vars[1]
    keep = Int[]
    for x in _points(env[v].cells)
        idx[v] = x
        g = try _eval_const_int(s, idx, ctx.const_arrays) catch err
            err isa TreeWalkError || rethrow(); return env end
        g in r && push!(keep, x)
    end
    isempty(keep) && return nothing
    env2 = copy(env)
    env2[v] = _with_cells(env[v], _iset_points(keep))
    return env2
end

# Walk `index(target, subs…)` at the cells `env` binds.
function _need_index!(ctx::_NeedCtx, target::ASTExpr, subs::Vector{ASTExpr},
                      env::Dict{String,_Bind}, anchors::Dict{String,String}, rule::String)
    for s in subs
        _need_walk!(ctx, s, env, anchors, rule)
    end
    if target isa VarExpr
        n = (target::VarExpr).name
        if n in ctx.states
            sh = ctx.shapes[n]
            length(sh) == length(subs) || return nothing
            binds = _Bind[_bind_sub(ctx, subs[d], env, anchors, sh[d], rule) for d in eachindex(subs)]
            _record_state_read!(ctx, n, binds, rule)
            _seam_mark!(ctx, n, binds)
        elseif haskey(ctx.obs_defs, n)
            sh = ctx.shapes[n]
            length(sh) == length(subs) || return nothing
            binds = _Bind[_bind_sub(ctx, subs[d], env, anchors, sh[d], rule) for d in eachindex(subs)]
            _need_observed!(ctx, n, binds, rule)
            _seam_mark!(ctx, n, binds)
        elseif haskey(ctx.scalar_defs, n)
            _need_walk!(ctx, target, env, anchors, rule)
        end
        return nothing
    end
    target isa OpExpr || return nothing
    o = target::OpExpr
    if _is_faq_op(o.op) && o.expr_body !== nothing
        outs = _output_idx_strings(o)
        rd = _ranges_dict(o)
        env2 = copy(env)
        anchors2 = copy(anchors)
        for (d, x) in enumerate(outs)
            d <= length(subs) || break
            b = _bind_sub(ctx, subs[d], env, anchors, nothing, rule)
            if haskey(rd, x) && !b.runtime
                rc = _range_cells(ctx, rd[x])
                isempty(rc) || (b = _with_cells(b, _iset_intersect(b.cells, rc)))
            end
            env2[x] = b
            isempty(b.axis) || (anchors2[b.axis] = x)
        end
        for (k, r) in rd
            k in outs && continue
            env2[String(k)] = _Bind(_range_cells(ctx, r), "", 1, 0, true, false)
        end
        any(x -> haskey(env2, x) && !env2[x].runtime && isempty(env2[x].cells), outs) &&
            return nothing
        _need_walk!(ctx, o.expr_body, env2, anchors2, rule)
        o.filter === nothing || _need_walk!(ctx, o.filter, env2, anchors2, rule)
        return nothing
    end
    if o.op == "makearray" && o.regions !== nothing && o.values !== nothing
        regions, values = o.regions, o.values
        boxes = Vector{Vector{UnitRange{Int}}}()
        ok = true
        for region in regions
            box = UnitRange{Int}[]
            for d in eachindex(region)
                lo = _region_int(ctx, region[d][1])
                hi = _region_int(ctx, region[d][2])
                (lo === nothing || hi === nothing) && (ok = false; break)
                push!(box, lo:hi)
            end
            ok || break
            push!(boxes, box)
        end
        outs = o.output_idx === nothing ? String[] : _output_idx_strings(o)
        if !ok || any(b -> length(b) != length(subs), boxes)
            for v in values
                _need_walk!(ctx, v, env, anchors, rule)
            end
            return nothing
        end
        for r in eachindex(boxes)
            effs = Vector{UnitRange{Int}}[boxes[r]]
            for s in (r + 1):length(boxes)
                effs = _box_subtract(effs, boxes[s])
            end
            for eb in effs
                env2 = env
                for d in eachindex(subs)
                    env2 === nothing && break
                    env2 = _restrict_env(ctx, env2, subs[d], eb[d])
                end
                env2 === nothing && continue
                anchors2 = anchors
                if !isempty(outs)
                    env2 = copy(env2)
                    anchors2 = copy(anchors)
                    for (d, x) in enumerate(outs)
                        d <= length(subs) || break
                        b = _bind_sub(ctx, subs[d], env2, anchors, nothing, rule)
                        b.runtime || (b = _with_cells(b, _iset_intersect(b.cells, eb[d])))
                        env2[x] = b
                        isempty(b.axis) || (anchors2[b.axis] = x)
                    end
                end
                _need_region_value!(ctx, values[r], boxes[r], subs, env2, anchors2, rule)
            end
        end
        return nothing
    end
    if o.op == "const"
        return nothing
    end
    if o.op == "index"
        _need_walk!(ctx, o, env, anchors, rule)
        return nothing
    end
    # An elementwise combination of arrays: the index pushes down to each.
    for a in o.args
        if _is_arrayish(ctx, a)
            _need_index!(ctx, a, subs, env, anchors, rule)
        else
            _need_walk!(ctx, a, env, anchors, rule)
        end
    end
    return nothing
end

# A `makearray` region's value at the cells `env` binds: an array producer is
# gathered at the cell (at the region's non-singleton axes when its rank is
# lower), anything else is the cell's value as it stands.
function _need_region_value!(ctx::_NeedCtx, val::ASTExpr, box::Vector{UnitRange{Int}},
                             subs::Vector{ASTExpr}, env, anchors, rule::String)
    if val isa OpExpr && _is_array_producer(val)
        v = val::OpExpr
        rank = v.op == "makearray" ?
            ((v.regions === nothing || isempty(v.regions)) ? 0 : length(v.regions[1])) :
            length(_output_idx_strings(v))
        if rank > 0
            sel = rank == length(subs) ? subs :
                  ASTExpr[subs[d] for d in eachindex(subs) if length(box[d]) != 1]
            length(sel) == rank &&
                return _need_index!(ctx, v, sel, env, anchors, rule)
        end
    end
    return _need_walk!(ctx, val, env, anchors, rule)
end

# The cells of `g` (global, in domain) that a tile's storage resolves (rule 2):
# `g` itself, or on a periodic axis an image `g ± P`.
function _storage_resolves(ctx::_NeedCtx, axis::String, face::Bool, g::Int)
    S = ctx.storage[axis]
    Sf = face ? (first(S):(last(S) + 1)) : S
    g in Sf && return true
    P = ctx.axes.period[axis]
    P === nothing && return false
    k = cld(first(Sf) - g, P)
    return (g + k * P) in Sf
end

# The image of `g` nearest the storage box, for a diagnostic.
function _near_storage(ctx::_NeedCtx, axis::String, g::Int)
    P = ctx.axes.period[axis]
    P === nothing && return g
    S = ctx.storage[axis]
    c = (first(S) + last(S)) / 2
    return g + P * round(Int, (c - g) / P)
end

function _record_state_read!(ctx::_NeedCtx, n::String, binds::Vector{_Bind}, rule::String)
    push!(ctx.reads, n)
    sh = ctx.shapes[n]
    for d in eachindex(sh)
        cut = get(ctx.axes.cut, sh[d], nothing)
        cut === nothing && continue
        axis, face = cut
        b = binds[d]
        if _has_offsets(b)
            k = (n, sh[d])
            lo, hi = get(ctx.reach, k, (typemax(Int), typemin(Int)))
            ctx.reach[k] = (min(lo, b.dlo), max(hi, b.dhi))
        end
        ctx.mode === :tile || continue
        cells = _iset_intersect(b.cells, _axis_domain(ctx.axes, axis, face))
        missing = Int[g for g in _points(cells) if !_storage_resolves(ctx, axis, face, g)]
        isempty(missing) && continue
        shown = sort!(unique!([_near_storage(ctx, axis, g) for g in missing]))
        runs = _iset_points(shown).ivs
        S = ctx.storage[axis]
        throw(_range_error(ERROR_CODES.RANGE_HALO_INSUFFICIENT,
            "rule '$(_rule_display(rule))' reads '$n' along index set '$(sh[d])' at " *
            join(["[$(first(r)), $(last(r))]" for r in runs], ", ") *
            " (unwrapped), outside the tile's storage $(face ? "faces $(first(S)):$(last(S) + 1)" : "box $(first(S)):$(last(S))")" *
            " and with no periodic image in it; widen the storage box by the halo " *
            "`halo(op, dec)` reports (API_SPEC §5.8, tile rule 2)"))
    end
    return nothing
end

function _need_observed!(ctx::_NeedCtx, n::String, binds::Vector{_Bind}, rule::String)
    sh = ctx.shapes[n]
    ext = ctx.extents[n]
    nb = Vector{_Bind}(undef, length(sh))
    for d in eachindex(sh)
        b = binds[d]
        cut = get(ctx.axes.cut, sh[d], nothing)
        if cut === nothing
            nb[d] = _Bind(_ISet(1:ext[d]))
        else
            cells = b.cells
            n in ctx.mat_obs && (cells = _iset_intersect(cells, 1:ext[d]))
            nb[d] = _Bind(cells, cut[1], b.dlo, b.dhi, false, b.runtime)
        end
    end
    cur = get(ctx.obs_need, n, nothing)
    merged = cur === nothing ? nb : _Bind[_bind_merge(cur[d], nb[d]) for d in eachindex(nb)]
    grew = cur === nothing || any(d -> merged[d].cells != cur[d].cells ||
                                       merged[d].dlo != cur[d].dlo ||
                                       merged[d].dhi != cur[d].dhi, eachindex(merged))
    if grew
        ctx.obs_need[n] = merged
        haskey(ctx.obs_rule, n) || (ctx.obs_rule[n] = rule)
        n in ctx.work || push!(ctx.work, n)
    end
    return nothing
end

# Walk the observeds the worklist holds, each over its accumulated need.
function _need_drain!(ctx::_NeedCtx)
    while !isempty(ctx.work)
        n = popfirst!(ctx.work)
        binds = ctx.obs_need[n]
        any(b -> isempty(b.cells) && !b.runtime, binds) && continue
        # Evaluated on each side of each seam it crosses separately, so every
        # read in its definition is told which side it serves.
        sdims = [d for d in eachindex(binds) if _dim_seam(ctx, n, d) !== nothing]
        for sides in Iterators.product((false:true for _ in sdims)...)
            bs = copy(binds)
            for (k, d) in enumerate(sdims)
                s = _dim_seam(ctx, n, d)::_Seam
                bs[d] = _with_cells(bs[d], _seam_side_cells(s, bs[d].cells, sides[k]))
            end
            any(b -> isempty(b.cells) && !b.runtime, bs) && continue
            env = Dict{String,_Bind}()
            anchors = Dict{String,String}()
            subs = ASTExpr[]
            for d in eachindex(bs)
                v = "\0rr\0$d"
                env[v] = bs[d]
                isempty(bs[d].axis) || (anchors[bs[d].axis] = v)
                push!(subs, VarExpr(v))
            end
            ctx.tag = (n, Tuple(sides))
            _need_index!(ctx, ctx.obs_defs[n], subs, env, anchors, n)
        end
        ctx.tag = ("", ())
    end
    return nothing
end

# The cells of `c` on the near (`far = false`) or far side of seam `s`.
_seam_side_cells(s::_Seam, c::_ISet, far::Bool) =
    s.far_high == far ? _iset_intersect(c, (s.cut + 1):typemax(Int) - 1) :
                        _iset_intersect(c, (typemin(Int) + 1):s.cut)

# ============================================================================
# §5 The decomposition against a program
# ============================================================================

# Every index set the program's states and observeds carry, with its extent.
function _program_sets(prog::RhsProgram)
    ext = Dict{String,Int}()
    for b in _layout_blocks(prog.internal)
        sh = prog.shapes[b.name]
        for d in eachindex(sh)
            ext[sh[d]] = max(get(ext, sh[d], 0), b.hi[d])
        end
    end
    for (k, is) in prog.flat.index_sets
        is.size === nothing || (ext[String(k)] = max(get(ext, String(k), 0), is.size))
    end
    return ext
end

_box_invalid(set, why) = _range_error(ERROR_CODES.RANGE_BOX_INVALID,
    "index set '$set': $why (API_SPEC §5.8, \"Terms of a decomposition\")")

function _axis_model(prog::RhsProgram, dec::Decomposition)
    ext = _program_sets(prog)
    cut = Dict{String,Tuple{String,Bool}}()
    N = Dict{String,Int}()
    period = Dict{String,Union{Nothing,Int}}()
    faces_of = Dict{String,String}(dec.faces)
    for (a, P) in dec.axes
        haskey(cut, a) && throw(_box_invalid(a, "it is cut twice"))
        n = get(ext, a, nothing)
        if n === nothing
            # An axis only face variables carry: its extent is theirs less one.
            f = findfirst(p -> last(p) == a && haskey(ext, first(p)), dec.faces)
            f === nothing && throw(_box_invalid(a, "no state or observed of this program " *
                "is shaped on it; the program's index sets are " *
                join(sort!(collect(keys(ext))), ", ")))
            n = ext[first(dec.faces[f])] - 1
        end
        (P === nothing || P == n) || throw(_box_invalid(a,
            "its period is $P but its extent is $n; a period is the axis's global extent"))
        cut[a] = (a, false)
        N[a] = n
        period[a] = P
    end
    for (f, a) in dec.faces
        haskey(N, a) || throw(_box_invalid(f,
            "it is declared a face set of '$a', which the decomposition does not cut"))
        haskey(cut, f) && throw(_box_invalid(f, "it is both a cut axis and a face set"))
        n = get(ext, f, nothing)
        (n === nothing || n == N[a] + 1) || throw(_box_invalid(f,
            "a face set of '$a' has $(N[a] + 1) faces, but '$f' has $n"))
        cut[f] = (a, true)
    end
    return _AxisModel(cut, N, period)
end

# The `owned`/`storage` keyword of `restrict` as axis → range.
function _axis_boxes(m::_AxisModel, spec, what::String)
    out = Dict{String,UnitRange{Int}}()
    for p in spec
        a, r = String(first(p)), last(p)
        haskey(m.N, a) || throw(_box_invalid(a, "the $what box names it, but the " *
            "decomposition does not cut it"))
        out[a] = Int(first(r)):Int(last(r))
    end
    for a in keys(m.N)
        haskey(out, a) || throw(_box_invalid(a, "the $what box does not give a range for it"))
    end
    return out
end

# ============================================================================
# §6 The range spec: what the build seams do under `halo` and `restrict`
# ============================================================================

mutable struct _TileSpec <: _RangeSpec
    mode::Symbol                               # :halo or :tile
    axes::_AxisModel
    owned::Dict{String,UnitRange{Int}}
    storage::Dict{String,UnitRange{Int}}
    shapes::Dict{String,Vector{String}}        # array states (from the program)
    writes::Set{String}
    ctx::Any                                   # the `_NeedCtx` once analysed
    # The far-side blocks of states read past a seam: block name → (state,
    # the dimensions on which it holds the far piece).
    aliases::Dict{String,Tuple{String,Vector{Bool}}}
end

_TileSpec(mode, axes, owned, storage, shapes, writes, ctx) =
    _TileSpec(mode, axes, owned, storage, shapes, writes, ctx,
              Dict{String,Tuple{String,Vector{Bool}}}())

struct _HaloDone <: EarthSciASTError
    ctx::_NeedCtx
end

# The whole-domain build's resolved observed definitions, shapes and extents.
function _need_context(spec::_TileSpec, model, cls, parts, index_sets, const_arrays,
                       param_arrays)
    shapes = Dict{String,Vector{String}}(spec.shapes)
    extents = Dict{String,Vector{Int}}()
    obs_defs = Dict{String,ASTExpr}()
    scalar_defs = Dict{String,ASTExpr}()
    for eq in parts.equations
        eq.lhs isa VarExpr || continue
        n = (eq.lhs::VarExpr).name
        n in parts.state_var_names && continue
        v = get(model.variables, n, nothing)
        if v !== nothing && _is_array_shape(v.shape)
            sh = String[string(s) for s in v.shape]
            dims = _materialized_obs_dims(eq.rhs, v.shape, index_sets, parts.derived_extents)
            dims === nothing && (dims = Int[get(spec.axes.N, s, 0) for s in sh])
            obs_defs[n] = eq.rhs
            shapes[n] = sh
            extents[n] = dims
        else
            scalar_defs[n] = eq.rhs
        end
    end
    params = Dict{String,Int}()
    for (k, v) in parts.param_scope
        (v isa Real && isfinite(v) && isinteger(v)) && (params[String(k)] = Int(v))
    end
    arrays = Set{String}(String(k) for k in keys(const_arrays))
    union!(arrays, (String(k) for k in keys(param_arrays)))
    union!(arrays, (String(k) for k in keys(cls.const_obs_arrays)))
    ca = isempty(cls.const_obs_arrays) ? const_arrays :
         merge(Dict{String,Any}(String(k) => v for (k, v) in cls.const_obs_arrays),
               Dict{String,Any}(String(k) => v for (k, v) in const_arrays))
    states = Set{String}(n for n in keys(spec.shapes))
    scalar_states = Set{String}(n for n in parts.state_var_names if !(n in states))
    ctx = _NeedCtx(spec.mode, spec.axes, spec.owned, spec.storage, shapes, extents,
                   states, scalar_states, obs_defs, scalar_defs,
                   Set{String}(cls.mat_array_vars), params, ca, arrays,
                   Dict{Tuple{String,String},Tuple{Int,Int}}(), Set{String}(),
                   Dict{String,Vector{_Bind}}(), String[], Dict{String,String}(),
                   Set{String}())
    if spec.mode === :tile
        for (a, P) in spec.axes.period
            P === nothing && continue
            for face in (false, true)
                sm = _tile_seam(spec.storage[a], _axis_domain(spec.axes, a, face), P, face)
                sm === nothing || (ctx.seams[(a, face)] = sm)
            end
        end
    end
    return ctx
end

# The output cells of a `D` equation's loop variable at dimension `d` of `v`.
function _output_cells(ctx::_NeedCtx, v::String, d::Int, rng)
    cells = _range_cells(ctx, rng)
    sh = ctx.shapes[v]
    cut = get(ctx.axes.cut, sh[d], nothing)
    cut === nothing && return cells, ""
    axis, face = cut
    dom = _axis_domain(ctx.axes, axis, face)
    if ctx.mode === :tile
        B = ctx.owned[axis]
        ob = face ? (first(B):(last(B) + (last(B) == ctx.axes.N[axis] ? 1 : 0))) : B
        return _iset_intersect(cells, ob), axis
    end
    return _iset_intersect(cells, dom), axis
end

# The right-hand side of an equation whose left-hand side `faq` (output indices
# `louts`) was clipped: `clips` maps a left-hand loop variable to its new range,
# and a right-hand `faq` output takes the range of the left-hand output it
# lines up with. Equal ranks line up by position, whatever each side names its
# indices; a lower-rank right-hand side (its output names are the left-hand
# loops it keeps) by name.
function _clip_rhs_ranges(rhs::ASTExpr, louts::Vector{String}, clips::AbstractDict)
    (rhs isa OpExpr && _is_faq_op((rhs::OpExpr).op) && (rhs::OpExpr).ranges !== nothing) ||
        return rhs
    R = rhs::OpExpr
    routs = _output_idx_strings(R)
    rr = Dict{String,Any}(String(k) => r for (k, r) in R.ranges)
    for (x, r) in clips
        y = if length(routs) == length(louts)
            d = findfirst(==(x), louts)
            d === nothing ? nothing : routs[d]
        else
            x in routs ? x : nothing
        end
        (y !== nothing && haskey(rr, y)) && (rr[y] = r)
    end
    return reconstruct(R; ranges = rr)
end

# Walk one `D` equation; return it clipped to the owned box (tile mode), or
# `nothing` when the tile owns none of its cells.
function _need_root!(ctx::_NeedCtx, eq::Equation, rule::String)
    lhs = eq.lhs
    if lhs isa OpExpr && _is_faq_op((lhs::OpExpr).op)
        L = lhs::OpExpr
        outs = _output_idx_strings(L)
        inner = (L.expr_body::OpExpr).args[1]
        (inner isa OpExpr && (inner::OpExpr).op == "index") || return eq
        v = rule
        args = (inner::OpExpr).args[2:end]
        haskey(ctx.shapes, v) && length(ctx.shapes[v]) == length(args) || return eq
        rd = _ranges_dict(L)
        env = Dict{String,_Bind}()
        anchors = Dict{String,String}()
        newr = Dict{String,Any}(String(k) => r for (k, r) in rd)
        for (d, a) in enumerate(args)
            if a isa VarExpr && haskey(rd, (a::VarExpr).name)
                x = (a::VarExpr).name
                cells, axis = _output_cells(ctx, v, d, rd[x])
                isempty(cells) && return nothing
                env[x] = isempty(axis) ? _Bind(cells) : _Bind(cells, axis, 0, 0, false, false)
                isempty(axis) || (anchors[axis] = x)
                if !isempty(axis) && ctx.mode === :tile
                    length(cells.ivs) == 1 || _refuse_rule(_rule_display(rule),
                        "tile restriction: its output cells along '$axis' are not one range")
                    newr[x] = Any[minimum(cells), maximum(cells)]
                end
            else
                g = try
                    _eval_const_int(a, Dict{String,Int}(ctx.params), ctx.const_arrays)
                catch err
                    err isa TreeWalkError || rethrow()
                    _refuse_rule(_rule_display(rule),
                        "tile restriction: its left-hand side subscript " *
                        "`$(format_expression(a, :ascii))` is neither a loop index nor a constant")
                end
                cells, axis = _output_cells(ctx, v, d, Any[g, g])
                isempty(cells) && return nothing
            end
        end
        rhs = eq.rhs
        if rhs isa OpExpr && _is_faq_op((rhs::OpExpr).op) &&
           length(_output_idx_strings(rhs::OpExpr)) == length(outs)
            _need_index!(ctx, rhs, ASTExpr[VarExpr(x) for x in outs], env, anchors, rule)
        else
            _need_walk!(ctx, rhs, env, anchors, rule)
        end
        ctx.mode === :tile || return eq
        newlhs = reconstruct(L; ranges = newr)
        clips = Dict{String,Any}(x => newr[x] for x in outs if haskey(newr, x))
        newrhs = _clip_rhs_ranges(rhs, outs, clips)
        return Equation(newlhs, newrhs; _comment = eq._comment)
    end
    body = lhs
    a = (body::OpExpr).args[1]
    if a isa OpExpr && (a::OpExpr).op == "index"
        args = (a::OpExpr).args[2:end]
        v = rule
        if haskey(ctx.shapes, v)
            for (d, x) in enumerate(args)
                g = try
                    _eval_const_int(x, Dict{String,Int}(ctx.params), ctx.const_arrays)
                catch err
                    err isa TreeWalkError || rethrow()
                    return eq
                end
                cells, _ = _output_cells(ctx, v, d, Any[g, g])
                isempty(cells) && return nothing
            end
        end
        _need_walk!(ctx, eq.rhs, Dict{String,_Bind}(), Dict{String,String}(), rule)
        return eq
    end
    # A 0-d state.
    ctx.mode === :tile && throw(_range_error(ERROR_CODES.RANGE_GLOBAL_LOCALITY,
        "the operator writes the 0-d state '$rule', which no tile owns; a 0-d state " *
        "write has global locality (API_SPEC §5.8, decision 8)"))
    _need_walk!(ctx, eq.rhs, Dict{String,_Bind}(), Dict{String,String}(), rule)
    return eq
end

function _range_restrict_parts(spec::_TileSpec, model, cls, parts, index_sets,
                               const_arrays, param_arrays)
    ctx = _need_context(spec, model, cls, parts, index_sets, const_arrays, param_arrays)
    spec.ctx = ctx
    eqs = Equation[]
    for eq in parts.equations
        tgt = _d_target(eq.lhs)
        if tgt === nothing
            push!(eqs, eq)
            continue
        end
        e2 = _need_root!(ctx, eq, tgt)
        e2 === nothing || push!(eqs, e2)
    end
    _need_drain!(ctx)
    spec.mode === :halo && throw(_HaloDone(ctx))
    isempty(ctx.seams) || (eqs = _seam_equations(ctx, spec, eqs))
    return merge(parts, (equations = eqs,))
end

# ---- Reads past a periodic seam ----
#
# A tile whose storage crosses a seam lays each state out over the piece it
# stores directly (`near`) and, as a second block, the piece past the seam
# (`far`), so its internal vector is as long as its storage, never the axis.
# Every read is sent to the block its cells lie in: a state read past the seam
# reads the far block (a block named by `_seam_alias`, holding the same global
# coordinates), and an observed read past the seam is evaluated there, from its
# definition rewritten for that side. The need walk recorded, per read and per
# context, which side each read lands on (`_seam_mark!`); a read that lands on
# both is refused.

_seam_alias(n::String, far::Vector{Bool}) = "__seam_" * join(Int.(far)) * "__" * n

struct _SeamRewrite
    ctx::_NeedCtx
    aliases::Dict{String,Tuple{String,Vector{Bool}}}
    inline::Dict{Tuple{String,Tuple},ASTExpr}
end

# The dimensions on which the read of `n` at `node` lands past the seam in
# context `tag` (`:any`: every context), or `nothing` for a read that does not
# (or that the walk never reached).
function _seam_far_dims(ctx::_NeedCtx, node, n::String, tag)
    m = get(ctx.marks, node, nothing)
    m === nothing && return nothing
    bits = nothing
    if tag === :any
        for ((v, _), b) in m
            v == n || continue
            bits = bits === nothing ? copy(b) : bits .| b
        end
    else
        bits = get(m, (n, tag), nothing)
    end
    bits === nothing && return nothing
    far = Bool[b == 0x02 for b in bits]
    for d in eachindex(bits)
        bits[d] == 0x03 && _refuse_rule(_rule_display(n),
            "tile restriction: one read of '$n' reaches cells on both sides of the " *
            "periodic seam of '$(ctx.shapes[n][d])' within the tile's storage; give the " *
            "tile a storage box that does not cross the seam")
    end
    return any(far) ? far : nothing
end

# `f` over every expression child of `o`; `o` itself when none changes.
function _seam_map(f, o::OpExpr)
    args = ASTExpr[f(a) for a in o.args]
    body = o.expr_body === nothing ? nothing : f(o.expr_body)
    filt = o.filter === nothing ? nothing : f(o.filter)
    vals = o.values === nothing ? nothing : ASTExpr[f(v) for v in o.values]
    lo = o.lower === nothing ? nothing : f(o.lower)
    hi = o.upper === nothing ? nothing : f(o.upper)
    same = all(k -> args[k] === o.args[k], eachindex(args)) && body === o.expr_body &&
           filt === o.filter && lo === o.lower && hi === o.upper &&
           (vals === nothing || all(k -> vals[k] === o.values[k], eachindex(vals)))
    same && return o
    return reconstruct(o; args = args, expr_body = body, filter = filt, values = vals,
                       lower = lo, upper = hi)
end

function _seam_rewrite(rw::_SeamRewrite, e::ASTExpr, tag)
    e isa OpExpr || return e
    o = e::OpExpr
    if o.op == "index" && !isempty(o.args)
        args = ASTExpr[_seam_target(rw, o.args[1], o, tag)]
        for a in Iterators.drop(o.args, 1)
            push!(args, _seam_rewrite(rw, a, tag))
        end
        all(k -> args[k] === o.args[k], eachindex(args)) && return o
        return reconstruct(o; args = args)
    end
    return _seam_map(x -> _seam_rewrite(rw, x, tag), o)
end

# The target of the `index` node `node` (`nothing` for an observed's own
# definition), rewritten: a state read past the seam reads its far block, an
# observed read past the seam its definition on that side.
function _seam_target(rw::_SeamRewrite, t::ASTExpr, node, tag)
    ctx = rw.ctx
    if t isa VarExpr
        n = (t::VarExpr).name
        if n in ctx.states
            far = _seam_far_dims(ctx, node, n, tag)
            far === nothing && return t
            a = _seam_alias(n, far)
            rw.aliases[a] = (n, far)
            return VarExpr(a)
        elseif haskey(ctx.obs_defs, n)
            far = _seam_far_dims(ctx, node, n, tag)
            far === nothing && return t
            sides = Tuple(far[d] for d in eachindex(far) if _dim_seam(ctx, n, d) !== nothing)
            return get!(rw.inline, (n, sides)) do
                _seam_target(rw, ctx.obs_defs[n], nothing, (n, sides))
            end
        end
        return t
    end
    t isa OpExpr || return t
    o = t::OpExpr
    (o.op == "index" || o.op == "makearray" || o.op == "const" ||
     (_is_faq_op(o.op) && o.expr_body !== nothing)) && return _seam_rewrite(rw, o, tag)
    # An elementwise combination of arrays: each array operand is read at the
    # cells of `node` itself.
    return _seam_map(o) do x
        _is_arrayish(ctx, x) ? _seam_target(rw, x, node, tag) : _seam_rewrite(rw, x, tag)
    end
end

function _seam_equations(ctx::_NeedCtx, spec::_TileSpec, eqs::Vector{Equation})
    rw = _SeamRewrite(ctx, spec.aliases, Dict{Tuple{String,Tuple},ASTExpr}())
    out = Equation[]
    for eq in eqs
        rhs = if _d_target(eq.lhs) !== nothing
            _seam_rewrite(rw, eq.rhs, ("", ()))
        elseif eq.lhs isa VarExpr && haskey(ctx.obs_defs, (eq.lhs::VarExpr).name)
            n = (eq.lhs::VarExpr).name
            near = Tuple(false for d in eachindex(ctx.shapes[n]) if _dim_seam(ctx, n, d) !== nothing)
            _seam_target(rw, eq.rhs, nothing, (n, near))
        elseif eq.lhs isa VarExpr && haskey(ctx.scalar_defs, (eq.lhs::VarExpr).name)
            _seam_rewrite(rw, eq.rhs, :any)
        else
            eq.rhs
        end
        push!(out, rhs === eq.rhs ? eq : Equation(eq.lhs, rhs; _comment = eq._comment))
    end
    return out
end

# Each array state's internal box: the in-domain cells of its storage, in
# global coordinates. Where the storage crosses a periodic seam, that is the
# piece on the tile's side, and the piece past the seam is a block of its own
# (`_seam_alias`) for the reads that land there; a storage that wraps onto
# itself takes the whole axis.
function _range_state_boxes!(spec::_TileSpec, avi)
    seams = spec.ctx === nothing ? Dict{Tuple{String,Bool},_Seam}() : spec.ctx.seams
    for (n, (lo, hi)) in collect(avi)
        sh = get(spec.shapes, n, nothing)
        sh === nothing && continue
        lo2, hi2 = copy(lo), copy(hi)
        for d in eachindex(sh)
            cut = get(spec.axes.cut, sh[d], nothing)
            cut === nothing && continue
            axis, face = cut
            S = spec.storage[axis]
            Sf = face ? (first(S):(last(S) + 1)) : S
            dom = _axis_domain(spec.axes, axis, face)
            sm = get(seams, cut, nothing)
            if sm !== nothing
                lo2[d], hi2[d] = first(sm.near), last(sm.near)
            elseif spec.axes.period[axis] !== nothing && !issubset(Sf, dom)
                lo2[d], hi2[d] = first(dom), last(dom)
            else
                r = max(first(Sf), first(dom)):min(last(Sf), last(dom))
                lo2[d], hi2[d] = first(r), last(r)
            end
        end
        avi[n] = (lo2, hi2)
    end
    for (a, (n, far)) in spec.aliases
        lo, hi = avi[n]
        lo2, hi2 = copy(lo), copy(hi)
        for d in eachindex(far)
            far[d] || continue
            sm = seams[spec.axes.cut[spec.shapes[n][d]]]
            lo2[d], hi2[d] = first(sm.far), last(sm.far)
        end
        avi[a] = (lo2, hi2)
    end
    return avi
end

function _range_observed_box(spec::_TileSpec, name, dims)
    need = get(spec.ctx.obs_need, name, nothing)
    need === nothing && return nothing
    sh = spec.ctx.shapes[name]
    lo, hi = ones(Int, length(dims)), copy(dims)
    for d in eachindex(dims)
        haskey(spec.axes.cut, sh[d]) || continue
        c = _obs_near_cells(spec.ctx, name, d, _iset_intersect(need[d].cells, 1:dims[d]))
        isempty(c) && return nothing
        lo[d], hi[d] = minimum(c), maximum(c)
    end
    return (lo, hi)
end

# The cells of observed `n`'s buffer along dimension `d`: past a seam an
# observed is evaluated where it is read, so its buffer holds its near side.
function _obs_near_cells(ctx::_NeedCtx, n::String, d::Int, c::_ISet)
    s = _dim_seam(ctx, n, d)
    return s === nothing ? c : _seam_side_cells(s, c, false)
end

function _range_fill_equations(spec::_TileSpec, name, def, dims, box)
    eqs = _materialized_fill_equations(name, def, dims)
    need = spec.ctx.obs_need[name]
    sh = spec.ctx.shapes[name]
    out = Equation[]
    for eq in eqs
        L = eq.lhs::OpExpr
        args = ((L.expr_body::OpExpr).args[1]::OpExpr).args[2:end]
        rd = Dict{String,Any}(String(k) => r for (k, r) in L.ranges)
        pieces = Vector{Pair{String,Vector{UnitRange{Int}}}}()
        for (d, a) in enumerate(args)
            (a isa VarExpr && haskey(rd, (a::VarExpr).name)) || continue
            haskey(spec.axes.cut, sh[d]) || continue
            x = (a::VarExpr).name
            r = rd[x]
            span = Int(r[1]):Int(r[end])
            c = _iset_intersect(_obs_near_cells(spec.ctx, name, d,
                                                _iset_intersect(need[d].cells, 1:dims[d])), span)
            push!(pieces, x => c.ivs)
        end
        any(p -> isempty(last(p)), pieces) && continue
        for combo in Iterators.product((last(p) for p in pieces)...)
            r2 = copy(rd)
            for (k, p) in enumerate(pieces)
                r2[first(p)] = Any[first(combo[k]), last(combo[k])]
            end
            lhs = reconstruct(L; ranges = r2)
            clips = Dict{String,Any}(first(p) => r2[first(p)] for p in pieces)
            rhs = _clip_rhs_ranges(eq.rhs, _output_idx_strings(L), clips)
            push!(out, Equation(lhs, rhs))
        end
    end
    return out
end

# ============================================================================
# §7 `halo` and `restrict`
# ============================================================================

"""
    halo(op::RhsProgram, dec::Decomposition) -> Dict{Tuple{String,String},Tuple{Int,Int}}

The halo report (API_SPEC §5.8): for every state the operator reads and every
cut or face index set on its shape, `(variable, set) => (lo, hi)`, how far the
owned output reaches into that state along that set. Offsets compose through
observeds, each `makearray` region contributes its own reach, and a periodic
wrap counts as reach across the seam.

Raises `range_global_locality` for a contraction, scan or data-dependent
subscript along a cut axis, `range_box_invalid` for a decomposition that does
not fit the program, and `compiler_unavailable` unless the program was built
with `compiler = :native`.
"""
function halo(op::RhsProgram, dec::Decomposition)
    _require_native(op, "halo")
    m = _axis_model(op, dec)
    spec = _TileSpec(:halo, m, Dict{String,UnitRange{Int}}(), Dict{String,UnitRange{Int}}(),
                     _array_shapes(op), Set(op.writes), nothing)
    ctx = try
        _relower(op, spec)
        error("halo: the build did not reach the range seam")
    catch err
        err isa _HaloDone || rethrow()
        err.ctx
    end
    out = Dict{Tuple{String,String},Tuple{Int,Int}}()
    for n in ctx.reads
        n in ctx.states || continue
        for s in ctx.shapes[n]
            haskey(m.cut, s) || continue
            lo, hi = get(ctx.reach, (n, s), (0, 0))
            out[(n, s)] = (max(0, -lo), max(0, hi))
        end
    end
    return out
end

_array_shapes(op::RhsProgram) =
    Dict{String,Vector{String}}(b.name => op.shapes[b.name] for b in _layout_blocks(op.internal))

"""
    restrict(op::RhsProgram, dec::Decomposition; owned, storage) -> TileProgram

The operator restricted to one tile (API_SPEC §5.8, "Tile semantics"): `owned`
and `storage` give one inclusive range per cut axis (`"lon" => 17:32`), in
global coordinates, unwrapped on a periodic axis. The tile writes only its owned
rows and reads only its storage: an in-domain read outside storage with no
periodic image in it raises `range_halo_insufficient`; a 0-d state write or a
contraction, scan or data-dependent gather along a cut axis raises
`range_global_locality`; a box that does not fit raises `range_box_invalid`.
"""
function restrict(op::RhsProgram, dec::Decomposition; owned, storage)
    _require_native(op, "restrict")
    m = _axis_model(op, dec)
    ow = _axis_boxes(m, owned, "owned")
    st = _axis_boxes(m, storage, "storage")
    for (a, B) in ow
        isempty(B) && throw(_box_invalid(a, "the owned box $B is empty"))
        (first(B) >= 1 && last(B) <= m.N[a]) || throw(_box_invalid(a,
            "the owned box $(first(B)):$(last(B)) is not inside 1:$(m.N[a])"))
        issubset(B, st[a]) || throw(_box_invalid(a,
            "the owned box $(first(B)):$(last(B)) is not inside the storage box " *
            "$(first(st[a])):$(last(st[a]))"))
    end
    for n in op.writes
        haskey(op.internal.scalars, n) && throw(_range_error(ERROR_CODES.RANGE_GLOBAL_LOCALITY,
            "the operator writes the 0-d state '$n', which no tile owns; a 0-d state " *
            "write has global locality (API_SPEC §5.8, decision 8)"))
    end
    shapes = _array_shapes(op)
    spec = _TileSpec(:tile, m, ow, st, shapes, Set(op.writes), nothing)
    f!, internal = _relower(op, spec)
    # ---- the tile's layout and copy maps ----
    gb = Dict{String,Vector{UnitRange{Int}}}(
        b.name => UnitRange{Int}[b.lo[d]:b.hi[d] for d in eachindex(b.lo)]
        for b in _layout_blocks(op.internal))
    function boxes(n)
        sh = shapes[n]
        st_b = copy(gb[n])
        ow_b = copy(gb[n])
        for d in eachindex(sh)
            cut = get(m.cut, sh[d], nothing)
            cut === nothing && continue
            axis, face = cut
            S, B = st[axis], ow[axis]
            st_b[d] = face ? (first(S):(last(S) + 1)) : S
            ow_b[d] = face ? (first(B):(last(B) + (last(B) == m.N[axis] ? 1 : 0))) : B
        end
        return st_b, ow_b
    end
    ublocks, nu = _make_blocks(internal, op.shapes, op.writes, boxes; owned = true)
    ablocks, na = _make_blocks(internal, op.shapes, op.aux_names, boxes; owned = false)
    layout = TileLayout(ublocks, ablocks, nu, na)
    function to_internal(n, d, x)
        cut = get(m.cut, shapes[n][d], nothing)
        cut === nothing && return x
        axis, face = cut
        dom = _axis_domain(m, axis, face)
        x in dom && return x
        P = m.period[axis]
        P === nothing && return nothing
        y = x + P * cld(first(dom) - x, P)
        return y in dom ? y : nothing
    end
    extra = Dict{String,Vector{String}}()
    for (a, (n, _)) in spec.aliases
        push!(get!(() -> String[], extra, n), a)
    end
    foreach(sort!, values(extra))
    maps = _copy_maps(layout, internal, to_internal, extra)
    return TileProgram(op, dec, ow, st, f!, internal, layout, maps, Threads.Atomic{Bool}(false))
end

function _fresh_instance(x::TileProgram)
    op = x.op
    spec = _TileSpec(:tile, _axis_model(op, x.dec), x.owned, x.storage, _array_shapes(op),
                     Set(op.writes), nothing)
    f!, internal = _relower(op, spec)
    _check_instance(internal, x)
    return f!
end

# ============================================================================
# §8 Lanes (API_SPEC §5.8, "Lanes")
# ============================================================================
#
# A lane program is the operator rebuilt with each lane set's loop collapsed
# onto one lane index. Every state, and every state-dependent observed, keeps
# its rank: the lane index runs along its first lane dimension over `1..C` and
# its other lane dimensions are pinned to `1`, so a state read at offset 0 is
# an ordinary in-box read and a column read keeps its offset. Every other use
# of a lane loop variable — a coordinate, a level gate, a subscript of a
# forcing buffer, an array parameter or a state-free observed — reads a live
# lane buffer holding each lane's global index (`__lane_<set>`), or, for an
# array read whose subscript depends on the lane alone, a live pre-gathered
# lane input. One build serves every batch: a call runs its lanes through the
# `C`-lane program chunk by chunk.

const _LANE_CHUNK = 64

# Copy plan of one variable between the lane layout and the internal layout.
struct _LaneCopy
    offset::Int                      # in units of lanes
    slot1::Vector{Int}               # internal slot of lane 1, per column element
    lstride::Int                     # internal slot step per lane
end

"""
    LaneProgram

An operator over a run-time list of cells (`:cells`) or columns (`:columns`)
([`lanes`](@ref)). Evaluate it with [`rhs!`](@ref) on buffers in its
[`lane_layout`](@ref). One build serves every batch size; one workspace per
concurrent caller ([`rhs_workspace`](@ref)).
"""
struct LaneProgram{F}
    op::RhsProgram
    kind::Symbol
    sets::Vector{String}
    C::Int
    f!::F
    internal::StateLayout
    layout::LaneLayout
    index_bufs::Vector{Vector{Float64}}   # per lane set, the live lane-index buffer of `f!`
    gathers::Vector{_LaneGather}          # the pre-gathered inputs of `f!`
    ucopy::Vector{_LaneCopy}
    acopy::Vector{_LaneCopy}
    params::Dict{String,Int}
    epoch::Base.RefValue{UInt64}          # the forcing epoch of `f!`'s build
    claimed::Threads.Atomic{Bool}
end

"""
    LaneInputs

Per-lane buffers of a lane program's non-state inputs ([`lane_inputs`](@ref)):
each lane set's global indices and every pre-gathered array read, for one
batch of `L` lanes. Filled by [`gather_lane_inputs!`](@ref).
"""
struct LaneInputs
    index::Vector{Vector{Float64}}
    gathered::Vector{Vector{Float64}}
    L::Int
end

mutable struct _LaneSpec <: _RangeSpec
    kind::Symbol
    sets::Vector{String}
    C::Int
    shapes::Dict{String,Vector{String}}       # array states
    index_bufs::Dict{String,Vector{Float64}}  # lane set → live buffer
    gathers::Vector{_LaneGather}
    laned::Set{String}                         # states + lane-ified observeds
    obs_shapes::Dict{String,Vector{String}}
    params::Dict{String,Int}
    ext::Dict{String,Int}
    epoch::Any                                 # the build's forcing epoch
end

_lane_refuse(rule, why) = _refuse_rule(_rule_display(rule), "lane: $why")

_range_build_epoch(spec::_LaneSpec, epoch) = (spec.epoch = epoch; nothing)

_lane_box_dim(spec::_LaneSpec, shape::Vector{String}, d::Int) =
    shape[d] in spec.sets ?
        (d == findfirst(s -> s in spec.sets, shape) ? (1:spec.C) : (1:1)) : nothing

function _range_state_boxes!(spec::_LaneSpec, avi)
    for (n, (lo, hi)) in collect(avi)
        sh = get(spec.shapes, n, nothing)
        sh === nothing && continue
        lo2, hi2 = copy(lo), copy(hi)
        for d in eachindex(sh)
            r = _lane_box_dim(spec, sh, d)
            r === nothing && continue
            lo2[d], hi2[d] = first(r), last(r)
        end
        avi[n] = (lo2, hi2)
    end
    return avi
end

function _range_observed_box(spec::_LaneSpec, name, dims)
    name in spec.laned || return (ones(Int, length(dims)), copy(dims))
    sh = spec.obs_shapes[name]
    lo, hi = ones(Int, length(dims)), copy(dims)
    for d in eachindex(sh)
        r = _lane_box_dim(spec, sh, d)
        r === nothing || (lo[d] = first(r); hi[d] = last(r))
    end
    return (lo, hi)
end

function _range_fill_equations(spec::_LaneSpec, name, def, dims, box)
    eqs = _materialized_fill_equations(name, def, dims)
    name in spec.laned || return eqs
    lo, hi = box
    out = Equation[]
    for eq in eqs
        L = eq.lhs::OpExpr
        args = ((L.expr_body::OpExpr).args[1]::OpExpr).args[2:end]
        rd = Dict{String,Any}(String(k) => r for (k, r) in L.ranges)
        for (d, a) in enumerate(args)
            a isa VarExpr && haskey(rd, (a::VarExpr).name) &&
                (rd[(a::VarExpr).name] = Any[lo[d], hi[d]])
        end
        push!(out, Equation(reconstruct(L; ranges = rd), eq.rhs))
    end
    return out
end

# The lane rewrite of one scope. `lanevars` maps each loop variable bound to a
# lane set to that set; `first` is the variable carrying the lane index.
struct _LaneScope
    lanevars::Dict{String,String}
    first::String
end

function _lane_value(spec::_LaneSpec, sc::_LaneScope, set::String)
    return OpExpr("index", ASTExpr[VarExpr("__lane_" * set), VarExpr(sc.first)])
end

function _lane_rewrite(spec::_LaneSpec, ctx, e::ASTExpr, sc::_LaneScope, rule::String)
    if e isa VarExpr
        n = (e::VarExpr).name
        haskey(sc.lanevars, n) && return _lane_value(spec, sc, sc.lanevars[n])
        if n in spec.laned
            _lane_refuse(rule, "it reads the whole array '$n'")
        end
        return e
    end
    e isa OpExpr || return e
    o = e::OpExpr
    if o.op == "index" && !isempty(o.args)
        return _lane_rewrite_index(spec, ctx, o, sc, rule)
    end
    args = ASTExpr[_lane_rewrite(spec, ctx, a, sc, rule) for a in o.args]
    body = o.expr_body === nothing ? nothing : _lane_rewrite(spec, ctx, o.expr_body, sc, rule)
    filt = o.filter === nothing ? nothing : _lane_rewrite(spec, ctx, o.filter, sc, rule)
    vals = o.values === nothing ? nothing :
           ASTExpr[_lane_rewrite(spec, ctx, v, sc, rule) for v in o.values]
    if _is_faq_op(o.op) && o.ranges !== nothing
        for k in keys(o.ranges)
            haskey(sc.lanevars, String(k)) && _lane_refuse(rule,
                "an aggregate rebinds the lane index '$k'")
        end
    end
    return reconstruct(o; args = args, expr_body = body, filter = filt, values = vals)
end

function _lane_rewrite_index(spec::_LaneSpec, ctx, o::OpExpr, sc::_LaneScope, rule::String)
    target = o.args[1]
    subs = ASTExpr[a for a in o.args[2:end]]
    if target isa VarExpr && (target::VarExpr).name in spec.laned
        n = (target::VarExpr).name
        sh = haskey(spec.shapes, n) ? spec.shapes[n] : spec.obs_shapes[n]
        length(sh) == length(subs) || return o
        new = ASTExpr[target]
        for d in eachindex(subs)
            s = subs[d]
            if sh[d] in spec.sets
                ok = s isa VarExpr && get(sc.lanevars, (s::VarExpr).name, "") == sh[d]
                ok || _lane_refuse(rule, "it reads '$n' at `$(format_expression(s, :ascii))` " *
                    "along the lane set '$(sh[d])', which leaves the " *
                    (spec.kind === :cells ? "cell" : "column"))
                push!(new, s)
            else
                push!(new, _lane_rewrite(spec, ctx, s, sc, rule))
            end
        end
        return reconstruct(o; args = new)
    end
    if target isa VarExpr && haskey(ctx.arrays, (target::VarExpr).name)
        n = (target::VarExpr).name
        refs = Set{String}()
        for s in subs
            _referenced_var_names(s, refs)
        end
        lane = [r for r in refs if haskey(sc.lanevars, r)]
        other = [r for r in refs if !haskey(sc.lanevars, r) && !haskey(spec.params, r) &&
                                    !haskey(ctx.arrays, r)]
        if !isempty(lane) && isempty(other)
            k = length(spec.gathers) + 1
            buf = zeros(spec.C)
            push!(spec.gathers, _LaneGather(buf, ctx.arrays[n], n, subs,
                [r => findfirst(==(sc.lanevars[r]), spec.sets) for r in lane], ctx.arrays))
            ctx.live["__lane_in_$k"] = buf
            return OpExpr("index", ASTExpr[VarExpr("__lane_in_$k"), VarExpr(sc.first)])
        end
    end
    if target isa OpExpr && (target::OpExpr).op == "makearray"
        ma = target::OpExpr
        regions = Vector{Vector{Any}}[]
        for region in ma.regions
            nr = Vector{Any}[]
            for d in eachindex(region)
                s = subs[d]
                set = s isa VarExpr ? get(sc.lanevars, (s::VarExpr).name, nothing) : nothing
                if set === nothing
                    push!(nr, region[d])
                    continue
                end
                lo = _region_int(ctx.need, region[d][1])
                hi = _region_int(ctx.need, region[d][2])
                (lo == 1 && hi == get(spec.ext, set, -1)) || _lane_refuse(rule,
                    "a region boundary along the lane set '$set' depends on the cell")
                r = (s::VarExpr).name == sc.first ? (1:spec.C) : (1:1)
                push!(nr, Any[first(r), last(r)])
            end
            push!(regions, nr)
        end
        vals = ASTExpr[_lane_rewrite(spec, ctx, v, sc, rule) for v in ma.values]
        newsubs = ASTExpr[(s isa VarExpr && haskey(sc.lanevars, (s::VarExpr).name)) ? s :
                          _lane_rewrite(spec, ctx, s, sc, rule) for s in subs]
        return reconstruct(o; args = ASTExpr[reconstruct(ma; regions = regions, values = vals),
                                             newsubs...])
    end
    if target isa OpExpr && _is_array_producer(target)
        _lane_refuse(rule, "an array producer is indexed inside the lane scope")
    end
    return reconstruct(o; args = ASTExpr[_lane_rewrite(spec, ctx, a, sc, rule) for a in o.args])
end

# The lane rewrite of `faq(D(index(v, …)))` / an observed's `faq` definition:
# the lane loop variables narrowed to the lane index (`1..C`) and `1`.
function _lane_scope_ranges(spec::_LaneSpec, outs::Vector{String}, sets::Vector{String},
                            ranges, rule)
    lanevars = Dict{String,String}()
    first = ""
    newr = Dict{String,Any}(String(k) => r for (k, r) in ranges)
    for (x, s) in zip(outs, sets)
        s in spec.sets || continue
        lanevars[x] = s
        if isempty(first)
            first = x
            newr[x] = Any[1, spec.C]
        else
            newr[x] = Any[1, 1]
        end
    end
    isempty(first) && _lane_refuse(rule, "it carries none of the lane sets")
    return _LaneScope(lanevars, first), newr
end

function _range_restrict_parts(spec::_LaneSpec, model, cls, parts, index_sets,
                               const_arrays, param_arrays)
    # ---- the context: arrays, extents, observeds ----
    arrays = Dict{String,Any}()
    for (k, v) in const_arrays
        arrays[String(k)] = v
    end
    for (k, v) in cls.const_obs_arrays
        arrays[String(k)] = v
    end
    for (k, v) in param_arrays
        arrays[String(k)] = v
    end
    for (k, v) in parts.param_scope
        (v isa Real && isfinite(v) && isinteger(v)) && (spec.params[String(k)] = Int(v))
    end
    extent = Dict{String,Int}()
    for (k, is) in index_sets
        is.size === nothing || (extent[String(k)] = is.size)
    end
    states = Set{String}(parts.state_var_names)
    defs = Dict{String,ASTExpr}()
    for eq in parts.equations
        eq.lhs isa VarExpr || continue
        defs[(eq.lhs::VarExpr).name] = eq.rhs
    end
    # The state-dependent observeds.
    dep = Dict{String,Bool}()
    function statedep(n, seen = Set{String}())
        haskey(dep, n) && return dep[n]
        n in seen && return false
        push!(seen, n)
        r = any(x -> x in states || (haskey(defs, x) && statedep(x, seen)),
                _referenced_var_names(defs[n]))
        dep[n] = r
        return r
    end
    # Every array observed on a lane set is evaluated per lane, a state-free one
    # included: its lane value is its value at the lane's cell, the same
    # expression of the same global indices.
    for (n, _) in defs
        v = get(model.variables, n, nothing)
        if v !== nothing && _is_array_shape(v.shape)
            sh = String[string(s) for s in v.shape]
            any(s -> s in sh, spec.sets) || continue
            spec.obs_shapes[n] = sh
            push!(spec.laned, n)
        elseif statedep(n)
            # A 0-d observed of the state reads cells of other lanes.
            any(x -> x in spec.laned || x in keys(spec.shapes), _referenced_var_names(defs[n])) &&
                _lane_refuse(n, "the 0-d observed '$n' reads lane arrays")
        end
    end
    for n in keys(spec.shapes)
        push!(spec.laned, n)
    end
    live = Dict{String,Any}()
    needctx = _NeedCtx(:lane, _AxisModel(Dict{String,Tuple{String,Bool}}(), Dict{String,Int}(),
                       Dict{String,Union{Nothing,Int}}()), Dict{String,UnitRange{Int}}(),
                       Dict{String,UnitRange{Int}}(), Dict{String,Vector{String}}(),
                       Dict{String,Vector{Int}}(), Set{String}(), Set{String}(),
                       Dict{String,ASTExpr}(), Dict{String,ASTExpr}(), Set{String}(),
                       spec.params, arrays, Set{String}(), Dict{Tuple{String,String},Tuple{Int,Int}}(),
                       Set{String}(), Dict{String,Vector{_Bind}}(), String[],
                       Dict{String,String}(), Set{String}())
    ctx = (; arrays, live, extent, need = needctx)
    eqs = Equation[]
    for eq in parts.equations
        tgt = _d_target(eq.lhs)
        if tgt !== nothing
            haskey(spec.shapes, tgt) || _lane_refuse(tgt,
                "the operator writes the 0-d state '$tgt', which no lane owns")
            L = eq.lhs
            (L isa OpExpr && _is_faq_op((L::OpExpr).op)) || _lane_refuse(tgt,
                "its left-hand side is not an array equation")
            L = L::OpExpr
            inner = (L.expr_body::OpExpr).args[1]::OpExpr
            outs = String[]
            for a in inner.args[2:end]
                a isa VarExpr || _lane_refuse(tgt, "its left-hand side subscript is not a loop index")
                push!(outs, (a::VarExpr).name)
            end
            sc, newr = _lane_scope_ranges(spec, outs, spec.shapes[tgt], L.ranges, tgt)
            rhs = eq.rhs
            if rhs isa OpExpr && _is_faq_op((rhs::OpExpr).op) &&
               length(_output_idx_strings(rhs::OpExpr)) == length(outs)
                R = rhs::OpExpr
                routs = _output_idx_strings(R)
                rsc, rr = _lane_scope_ranges(spec, routs, spec.shapes[tgt], R.ranges, tgt)
                body = _lane_rewrite(spec, ctx, R.expr_body, rsc, tgt)
                filt = R.filter === nothing ? nothing : _lane_rewrite(spec, ctx, R.filter, rsc, tgt)
                rhs = reconstruct(R; ranges = rr, expr_body = body, filter = filt)
            else
                rhs = _lane_rewrite(spec, ctx, rhs, sc, tgt)
            end
            push!(eqs, Equation(reconstruct(L; ranges = newr), rhs; _comment = eq._comment))
        elseif eq.lhs isa VarExpr && (eq.lhs::VarExpr).name in spec.laned
            n = (eq.lhs::VarExpr).name
            R = eq.rhs
            (R isa OpExpr && _is_faq_op((R::OpExpr).op) &&
             length(_output_idx_strings(R::OpExpr)) == length(spec.obs_shapes[n])) ||
                _lane_refuse(n, "the observed '$n' is not defined by an array aggregate")
            R = R::OpExpr
            sc, rr = _lane_scope_ranges(spec, _output_idx_strings(R), spec.obs_shapes[n],
                                        R.ranges, n)
            body = _lane_rewrite(spec, ctx, R.expr_body, sc, n)
            filt = R.filter === nothing ? nothing : _lane_rewrite(spec, ctx, R.filter, sc, n)
            push!(eqs, Equation(eq.lhs, reconstruct(R; ranges = rr, expr_body = body,
                                                     filter = filt); _comment = eq._comment))
        else
            push!(eqs, eq)
        end
    end
    # The pre-gathered buffers join the live forcing buffers the build binds.
    for (k, v) in live
        param_arrays[k] = v
    end
    return merge(parts, (equations = eqs,))
end

"""
    lanes(op::RhsProgram, kind::Symbol, sets) -> LaneProgram

The operator over a run-time list of cells (`kind = :cells`, `sets` every index
set of the written variables' shape) or columns (`kind = :columns`, `sets` the
horizontal sets) (API_SPEC §5.8, "Lanes"). `sets` orders the rows of a call's
`cells` matrix. For every lane `l ≤ n` and written variable `v`,
`du_L[v, l]` equals the whole-domain evaluation at `cells[:, l]` bitwise.

A read that leaves the cell (or the column) raises `compiler_refused_rule`
naming the rule; lane sets that do not fit the program raise
`range_box_invalid`.
"""
function lanes(op::RhsProgram, kind::Symbol, sets; chunk::Int = _LANE_CHUNK)
    _require_native(op, "lanes")
    kind in (:cells, :columns) || throw(_box_invalid(string(kind),
        "a lane kind is :cells or :columns"))
    S = String[String(s) for s in sets]
    isempty(S) && throw(_box_invalid("", "no lane sets were given"))
    shapes = _array_shapes(op)
    for n in vcat(op.writes, op.aux_names)
        sh = get(shapes, n, nothing)
        sh === nothing && throw(_box_invalid(join(S, ", "),
            "the 0-d state '$n' carries no lane set"))
        for s in S
            s in sh || throw(_box_invalid(s, "the state '$n' (on $(join(sh, ", "))) " *
                "does not carry the lane set '$s'"))
        end
        others = [s for s in sh if !(s in S)]
        kind === :cells && !isempty(others) && throw(_box_invalid(join(others, ", "),
            "a :cells lane spans every index set of '$n'; add it to the lane sets " *
            "or use :columns"))
        kind === :columns && isempty(others) && throw(_box_invalid(join(S, ", "),
            "a :columns lane leaves a column, but the lane sets cover every index set of '$n'"))
    end
    inst = _lane_instance(op, kind, S, chunk)
    internal = inst.internal
    # ---- the lane layout and its copy plans ----
    function blocks(names)
        out = LaneBlock[]
        plans = _LaneCopy[]
        off = 0
        for n in names
            sh = shapes[n]
            ib = _layout_block(internal, n)
            nl = [d for d in eachindex(sh) if !(sh[d] in S)]
            wb = _layout_block(op.internal, n)
            extents = Int[wb.hi[d] for d in nl]
            push!(out, LaneBlock(n, sh[nl], extents, off))
            fd = findfirst(s -> s in S, sh)
            slot1 = Int[]
            g = ones(Int, length(sh))
            for c in CartesianIndices(Tuple(1:x for x in extents))
                for (k, d) in enumerate(nl)
                    g[d] = c[k]
                end
                g[fd] = 1
                push!(slot1, _block_slot(ib, g))
            end
            push!(plans, _LaneCopy(off, slot1, ib.strides[fd]))
            off += isempty(extents) ? 1 : prod(extents)
        end
        return out, plans, off
    end
    ub, uplan, nu = blocks(op.writes)
    ab, aplan, na = blocks(op.aux_names)
    layout = LaneLayout(ub, ab, S, nu, na)
    return LaneProgram(op, kind, S, chunk, inst.f!, internal, layout, inst.index_bufs,
                       inst.gathers, uplan, aplan, inst.params, inst.epoch,
                       Threads.Atomic{Bool}(false))
end

# One compiled instance of a lane program: its right-hand side, the live lane
# buffers that instance reads, and its build's forcing epoch.
function _lane_instance(op::RhsProgram, kind::Symbol, S::Vector{String}, chunk::Int)
    index_bufs = Dict{String,Vector{Float64}}(s => zeros(chunk) for s in S)
    spec = _LaneSpec(kind, S, chunk, _array_shapes(op), index_bufs, _LaneGather[],
                     Set{String}(), Dict{String,Vector{String}}(), Dict{String,Int}(),
                     _program_sets(op), nothing)
    # The lane-index buffers are live forcing buffers of the build.
    file, model_name, _ = op.front
    kw = _relower_kwargs(op.front)
    pa = get(kw, :param_arrays, Dict{String,Any}())
    pa = Dict{String,Any}(String(k) => v for (k, v) in pa)
    for (s, b) in index_bufs
        pa["__lane_" * s] = b
    end
    kw[:param_arrays] = pa
    f!, _u0, _p, _ts, internal = _with_compiler_plan(_plan_for(op.compiler)) do
        _with_range_spec(spec) do
            _build_evaluator(file; model_name = model_name, kw...)
        end
    end
    spec.epoch isa _ForcingEpoch || error("lanes: the build did not report its forcing epoch")
    return (; f!, internal, index_bufs = Vector{Float64}[index_bufs[s] for s in S],
            gathers = spec.gathers, params = spec.params, epoch = spec.epoch::_ForcingEpoch)
end

"""
    lane_layout(lanes::LaneProgram) -> LaneLayout

The `u`/`aux` lane layout (API_SPEC §5.8, "Lanes"): element `e` of variable `v`
for lane `l` of an `L`-lane batch is at slot `(offset_v + e - 1)·L + l`.
"""
lane_layout(lp::LaneProgram) = lp.layout

function rhs_workspace(lp::LaneProgram)
    inst = if _claim!(lp)
        (f! = lp.f!, index_bufs = lp.index_bufs, gathers = lp.gathers, epoch = lp.epoch)
    else
        i = _lane_instance(lp.op, lp.kind, lp.sets, lp.C)
        _check_instance(i.internal, lp)
        length(i.gathers) == length(lp.gathers) || error(
            "rhs_workspace: a rebuild of this lane program gathers different inputs")
        i
    end
    n = length(lp.internal)
    return RhsWorkspace(lp, zeros(n), zeros(n), inst.f!, inst.index_bufs, inst.gathers,
                        Dict{String,Int}(lp.params), inst.epoch)
end

"""
    lane_inputs(lanes::LaneProgram, L::Integer) -> LaneInputs

Buffers for the non-state inputs of an `L`-lane batch: each lane set's global
index and every pre-gathered array read. Fill them with
[`gather_lane_inputs!`](@ref).
"""
lane_inputs(lp::LaneProgram, L::Integer) =
    LaneInputs([zeros(Int(L)) for _ in lp.index_bufs],
               [zeros(Int(L)) for _ in lp.gathers], Int(L))

# The value of pre-gathered input `g` at the cell of lane `l` of `cells`.
function _lane_gather_value(g::_LaneGather, cells::AbstractMatrix, l::Int,
                            env::Dict{String,Int})
    for (v, row) in g.vars
        env[v] = Int(cells[row, l])
    end
    src = g.src
    lin = 0
    stride = 1
    for d in eachindex(g.subs)
        i = _eval_const_int(g.subs[d], env, g.consts)
        n = size(src, d)
        if !(1 <= i <= n)
            i = try
                _resolve_const_index(src, g.name, d, i, n)
            catch err
                err isa TreeWalkError || rethrow()
                return 0.0
            end
        end
        lin += (i - 1) * stride
        stride *= n
    end
    return Float64(src[lin + 1])
end

"""
    gather_lane_inputs!(li::LaneInputs, lanes::LaneProgram, p, t, fs, cells, n) -> li

Fill `li` for the first `n` lanes of `cells` (an `Int32` `[D, L]` matrix, rows in
the program's lane-set order); lanes past `n` take lane `n`'s inputs.
"""
function gather_lane_inputs!(li::LaneInputs, lp::LaneProgram, p, t, fs,
                             cells::AbstractMatrix, n::Integer)
    L = li.L
    size(cells, 2) == L || throw(DimensionMismatch(
        "gather_lane_inputs!: `cells` has $(size(cells, 2)) lanes; the inputs hold $L"))
    env = Dict{String,Int}(lp.params)
    for l in 1:L
        src = min(l, Int(n))
        for k in eachindex(li.index)
            li.index[k][l] = Float64(cells[k, src])
        end
        for (k, g) in enumerate(lp.gathers)
            li.gathered[k][l] = _lane_gather_value(g, cells, src, env)
        end
    end
    return li
end

function _lane_check(lp::LaneProgram, ws::RhsWorkspace, du, u, aux, cells, n)
    _check_workspace(lp, ws)
    L = size(cells, 2)
    size(cells, 1) == length(lp.sets) || throw(DimensionMismatch(
        "rhs!: `cells` has $(size(cells, 1)) rows; the lane sets are $(join(lp.sets, ", "))"))
    (1 <= n <= L) || throw(ArgumentError("rhs!: n = $n lanes of an L = $L batch"))
    length(u) == lp.layout.n_u * L || throw(DimensionMismatch(
        "rhs!: `u` has $(length(u)) elements; the lane layout needs $(lp.layout.n_u * L)"))
    length(aux) == lp.layout.n_aux * L || throw(DimensionMismatch(
        "rhs!: `aux` has $(length(aux)) elements; the lane layout needs $(lp.layout.n_aux * L)"))
    length(du) == lp.layout.n_u * L || throw(DimensionMismatch(
        "rhs!: `du` has $(length(du)) elements; the lane layout needs $(lp.layout.n_u * L)"))
    return L
end

# Run lanes `s0+1 … s0+m` of the batch through the program, after its lane
# buffers hold their inputs.
function _lane_chunk!(du, lp::LaneProgram, ws::RhsWorkspace, u, aux, p, t, L::Int,
                      s0::Int, m::Int)
    U = ws.u
    C = lp.C
    for (plans, buf) in ((lp.ucopy, u), (lp.acopy, aux))
        for pl in plans
            @inbounds for e in eachindex(pl.slot1)
                base = (pl.offset + e - 1) * L + s0
                s1 = pl.slot1[e]
                for c in 1:C
                    U[s1 + (c - 1) * pl.lstride] = buf[base + min(c, m)]
                end
            end
        end
    end
    # The lane buffers changed under an unchanged `(p, t)`: the instance's
    # time-cadence values must refill.
    _bump_epoch!(ws.epoch)
    D = ws.du
    ws.f!(D, U, p, t)
    @inbounds for pl in lp.ucopy
        for e in eachindex(pl.slot1)
            base = (pl.offset + e - 1) * L + s0
            s1 = pl.slot1[e]
            for c in 1:m
                du[base + c] = D[s1 + (c - 1) * pl.lstride]
            end
        end
    end
    return nothing
end

function rhs!(du::AbstractVector, lp::LaneProgram, ws::RhsWorkspace, u::AbstractVector,
              aux::AbstractVector, p, t, fs, cells::AbstractMatrix, n::Integer)
    L = _lane_check(lp, ws, du, u, aux, cells, n)
    C = lp.C
    env = ws.env
    for s0 in 0:C:(n - 1)
        m = min(C, n - s0)
        for c in 1:C
            l = s0 + min(c, m)
            for k in eachindex(ws.index_bufs)
                ws.index_bufs[k][c] = Float64(cells[k, l])
            end
            for g in ws.gathers
                g.buf[c] = _lane_gather_value(g, cells, l, env)
            end
        end
        _lane_chunk!(du, lp, ws, u, aux, p, t, L, s0, m)
    end
    return du
end

function rhs!(du::AbstractVector, lp::LaneProgram, ws::RhsWorkspace, u::AbstractVector,
              aux::AbstractVector, p, t, li::LaneInputs, cells::AbstractMatrix, n::Integer)
    L = _lane_check(lp, ws, du, u, aux, cells, n)
    li.L == L || throw(DimensionMismatch("rhs!: the lane inputs hold $(li.L) lanes; the batch has $L"))
    C = lp.C
    for s0 in 0:C:(n - 1)
        m = min(C, n - s0)
        for c in 1:C
            l = s0 + min(c, m)
            for k in eachindex(ws.index_bufs)
                ws.index_bufs[k][c] = li.index[k][l]
            end
            for (k, g) in enumerate(ws.gathers)
                g.buf[c] = li.gathered[k][l]
            end
        end
        _lane_chunk!(du, lp, ws, u, aux, p, t, L, s0, m)
    end
    return du
end
