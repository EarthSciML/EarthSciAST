# Lanes (API_SPEC §5.8, "Lanes"): an operator rebuilt with each lane set's
# loop collapsed to one lane index, evaluated over a run-time list of cells or
# columns.

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

# One pre-gathered lane input: `buf[l] = src[subs…]` at lane `l`'s cell.
struct _LaneGather
    buf::Vector{Float64}             # the program's live buffer (C lanes)
    src::AbstractArray               # const array or live forcing buffer
    dims::Vector{Int}                # `size(src)`
    name::String
    subs::Vector{ASTExpr}
    vars::Vector{Pair{String, Int}}   # loop variable → lane-set row of `cells`
    consts::AbstractDict             # the const arrays a subscript may read
    columns::Vector{Pair{String, UnitRange{Int}}}
end

# A pre-gathered input's subscripts, compiled once at program build.
#
# A subscript of a pre-gathered read is a function of the lane's global indices
# along the lane sets it reads (and of const arrays). At build it becomes one
# of two forms, each giving at a call the integer `_eval_const_int` gives:
#  - affine (`+`, `-`, `*` by a constant, integer literals): `c0 + Σ coef·v`,
#    then resolved on its axis as `_resolve_const_index` resolves it;
#  - anything else: a table over every index tuple of the lane sets it reads,
#    already resolved: the axis position, 0 where the resolution throws (the
#    read is 0.0), -1 where evaluating the subscript throws (the call raises
#    that error);
#  - anything else whose table would exceed `_LANE_SUBSCRIPT_TABLE_MAX`
#    entries: evaluated per lane at the call (`_eval_const_int`), which
#    allocates.
# So a call of the first two forms reads `cells` and integer tables only: no
# expression walk, no dictionary, no allocation.
struct _LaneSubscript
    rows::Vector{Int}       # the `cells` row of each lane set it reads
    exts::Vector{Int}       # those sets' extents
    affine::Bool
    tabled::Bool            # not affine: `table` holds it (else evaluated per lane)
    c0::Int
    coef::Vector{Int}       # per row (affine)
    table::Vector{Int32}    # column-major over `rows` (tabled)
end

# The largest subscript table built (entries, 4 bytes each). A table covers
# every index tuple of the lane sets its subscript reads, which at production
# extents (three full grid axes) is far too large to build or hold; a larger
# subscript is evaluated at the call instead. A `Ref` so a test can lower it.
const _LANE_SUBSCRIPT_TABLE_MAX = Ref(1 << 20)

struct _LaneGatherPlan
    subs::Vector{_LaneSubscript}
    dims::Vector{Int}
    strides::Vector{Int}     # column-major over `dims`
    policy::Vector{Symbol}   # each axis's boundary policy (`_const_dim_boundary`)
end

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
[`lane_layout`](@ref). One build serves every batch size. Reentrant across
distinct workspaces: each [`rhs_workspace`](@ref) owns its lane buffers.
"""
struct LaneProgram{F}
    op::RhsProgram
    sets::Vector{String}
    C::Int
    f!::F
    internal::StateLayout
    layout::LaneLayout
    index_bufs::Vector{Vector{Float64}}   # per lane set, the live lane-index buffer
    gathers::Vector{_LaneGather}
    gather_slots::Vector{Int}        # per gather, its source's forcing slot (0: const)
    gplans::Vector{_LaneGatherPlan}  # per gather, its compiled subscripts
    gflat::Vector{Vector{Float64}}   # per gather of const data, that data (else empty)
    exts::Vector{Int}                # per lane set, its extent
    ucopy::Vector{_LaneCopy}
    acopy::Vector{_LaneCopy}
    params::Dict{String, Int}
    shared::_RhsShared
    # The live buffer of each lane's time (U19), the last lane buffer of a
    # workspace; `nothing` when the program reads no per-lane time.
    tbuf::Union{Nothing, Vector{Float64}}
    # The observeds of `t` evaluated once per call at one time (no lane set),
    # which a call at mixed times refuses.
    tshared::Vector{String}
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
    # The forcing set of the last gather that finished (`nothing` before the
    # first and after one that threw); `rhs!` evaluates the program's other
    # forcing reads against the same set.
    fs::Base.RefValue{Union{Nothing, ForcingSet}}
    owner::_RhsShared               # the lane program's
end

mutable struct _LaneSpec <: _RangeSpec
    kind::Symbol
    sets::Vector{String}
    C::Int
    shapes::Dict{String, Vector{String}}       # array states
    index_bufs::Dict{String, Vector{Float64}}  # lane set → live buffer
    gathers::Vector{_LaneGather}
    laned::Set{String}                         # states + lane-ified observeds
    obs_shapes::Dict{String, Vector{String}}
    params::Dict{String, Int}
    ext::Dict{String, Int}
    fragment::Bool
    # The live lane buffer of each lane's time (U19): `t` in the lane scope
    # reads it at the lane. `nothing` for an out-of-place fragment.
    tbuf::Union{Nothing, Vector{Float64}}
    # The 0-d observeds of `t` computed per lane, read at the lane index
    # (`_range_promote_model`).
    promoted::Set{String}
    # The observeds of `t` the state equations read that are evaluated once
    # per call, at one time (no lane set): a call at mixed times refuses them.
    tshared::Vector{String}
    # `t` and every observed that depends on it, which the hoist pass keeps
    # off a lane-free lift.
    tnames::Set{String}
    # The observeds of `t` on a lane set that have no lane form (one reads
    # another cell of an array on a lane set), with every observed of `t`
    # they read: computed over the whole domain once per call, at one time,
    # as an observed of `t` with no lane set is (`_lane_instance`).
    whole::Set{String}
end
_LaneSpec(args::Vararg{Any, 15}) = _LaneSpec(args..., Set{String}())

# Thrown by the lane rewrite of the observed `name` of `t`, which has no lane
# form: `names` is it and every observed of `t` it reads, which the build
# retries computing over the whole domain. Not an `EarthSciASTError`, so no
# recovery from a document error inside the build can swallow it before
# `_lane_instance` catches it.
struct _LaneWholeFallback <: Exception
    name::String
    names::Vector{String}
    why::String
end

_lane_refuse(rule, why) = _refuse_rule(_rule_display(rule), "lane: $why")

# The lane buffers are per-call inputs (tree_walk/range_hooks.jl): a call
# refills them for every chunk of lanes, so a value that reads one is computed
# on every call, like a value that reads the state, and no cadence stamp needs
# to see them change.
function _lane_buffers(spec::_LaneSpec)
    bufs = Vector{Float64}[spec.index_bufs[s] for s in spec.sets]
    append!(bufs, g.buf for g in spec.gathers)
    spec.tbuf === nothing || push!(bufs, spec.tbuf)
    return bufs
end
function _range_lane_inputs(spec::_LaneSpec)
    names = String["__lane_" * s for s in spec.sets]
    append!(names, "__lane_in_$k" for k in eachindex(spec.gathers))
    spec.tbuf === nothing || push!(names, "__lane_t")
    return names
end
# By address: a gather of a pre-gathered input with columns reads it through a
# reshape, which shares its memory.
_range_is_lane_buffer(spec::_LaneSpec, buf) =
    buf isa Array{Float64} && !isempty(buf) &&
    _anyof(b -> pointer(b) == pointer(buf), _lane_buffers(spec))

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

# A lane-rewritten observed's definition runs over the lane box (its lane
# axes narrowed to `1..C` and `1`, `_lane_scope_ranges`), which is what it
# stores (`_range_observed_box`). Its buffer has its declared shape's extents,
# the first lane axis widened to `C` when that set has fewer cells. `nothing`
# (inlined) unless the definition, read as `_materialized_obs_dims` reads one
# (distinct output indices, dense `1..n` ranges), produces exactly the box
# along each lane axis and the declared extent along each other axis.
function _range_observed_dims(spec::_LaneSpec, name, def, shape, index_sets, derived_extents)
    name in spec.laned ||
        return _materialized_obs_dims(def, shape, index_sets, derived_extents)
    declared = _declared_shape_extents(shape, index_sets, derived_extents)
    produced = _materialized_obs_dims(def, nothing, index_sets, derived_extents)
    (declared === nothing || produced === nothing || length(produced) != length(declared)) &&
        return nothing
    sh = spec.obs_shapes[name]
    dims = copy(declared)
    for d in eachindex(dims)
        r = _lane_box_dim(spec, sh, d)
        produced[d] == (r === nothing ? declared[d] : length(r)) || return nothing
        r === nothing || (dims[d] = max(dims[d], last(r)))
    end
    return dims
end

function _range_fill_equations(spec::_LaneSpec, name, def, dims, box)
    eqs = _materialized_fill_equations(name, def, dims)
    name in spec.laned || return eqs
    lo, hi = box
    out = Equation[]
    for eq in eqs
        L = eq.lhs::OpExpr
        args = ((L.expr_body::OpExpr).args[1]::OpExpr).args[2:end]
        rd = Dict{String, Any}(String(k) => r for (k, r) in L.ranges)
        for (d, a) in enumerate(args)
            a isa VarExpr && haskey(rd, (a::VarExpr).name) &&
                (rd[(a::VarExpr).name] = Any[lo[d], hi[d]])
        end
        push!(out, Equation(reconstruct(L; ranges = rd), eq.rhs))
    end
    return out
end

# The lane rewrite of one scope. `lanevars` maps each loop variable bound to a
# lane set to that set; `first` is the variable carrying the lane index;
# `ranges` holds the document range of every loop variable in scope (the
# innermost binder's), which an array `faq` read at that variable is checked
# against.
struct _LaneScope
    lanevars::Dict{String, String}
    first::String
    columns::Dict{String, UnitRange{Int}}
    ranges::Dict{String, Any}
end

function _lane_value(spec::_LaneSpec, sc::_LaneScope, set::String)
    return OpExpr("index", ASTExpr[VarExpr("__lane_" * set), VarExpr(sc.first)])
end

function _lane_rewrite(spec::_LaneSpec, ctx, e::ASTExpr, sc::_LaneScope, rule::String)
    if e isa VarExpr
        n = (e::VarExpr).name
        haskey(sc.lanevars, n) && return _lane_value(spec, sc, sc.lanevars[n])
        # U19: the time is the lane's own, and so is a 0-d observed of it.
        n == "t" && spec.tbuf !== nothing &&
            return OpExpr("index", ASTExpr[VarExpr("__lane_t"), VarExpr(sc.first)])
        n in spec.promoted && return OpExpr("index", ASTExpr[e, VarExpr(sc.first)])
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
    if _is_faq_op(o.op) && o.ranges !== nothing
        for k in keys(o.ranges)
            haskey(sc.lanevars, String(k)) && _lane_refuse(
                rule,
                "an aggregate rebinds the lane index '$k'"
            )
        end
        # The node's bound indices are in scope in the fields that see them.
        # `args` and the range bounds keep the outer scope; every other
        # expression field (`expr`, `filter`, `key`, …) is rewritten in the
        # node's scope, so no field is skipped that the in-place program
        # rewrites through `map_children`. In a fragment they also become
        # columns of a lane gather.
        columns = sc.columns
        if spec.fragment
            columns = copy(sc.columns)
            _lane_column_ranges!(columns, spec, o.ranges)
        end
        ranges = copy(sc.ranges)
        for (k, r) in o.ranges
            ranges[String(k)] = r
        end
        body = _LaneScope(sc.lanevars, sc.first, columns, ranges)
        return _map_children_scoped(
            x -> _lane_rewrite(spec, ctx, x, sc, rule),
            x -> _lane_rewrite(spec, ctx, x, body, rule), o, (:args, :ranges)
        )
    end
    return map_children(x -> _lane_rewrite(spec, ctx, x, sc, rule), o)
end

# `map_children` with two rewrites: `outer` for the fields named in
# `outer_fields`, `inner` for every other expression field of the node. The
# field walk is the one `map_children` runs, so a new expression field of
# `OpExpr` is never dropped.
function _map_children_scoped(outer::F, inner::G, o::OpExpr, outer_fields) where {F, G}
    kw = map(_MAPPED_FIELDS) do fld
        f = fld in outer_fields ? outer : inner
        mapper = getfield(@__MODULE__, getfield(_MAP_CHILD_FN, OPEXPR_FIELD_TABLE[fld].kind))
        fld => mapper(f, getfield(o, fld))
    end
    return reconstruct(o; kw...)
end

function _lane_rewrite_index(spec::_LaneSpec, ctx, o::OpExpr, sc::_LaneScope, rule::String)
    target = o.args[1]
    subs = ASTExpr[a for a in o.args[2:end]]
    if target isa VarExpr && (target::VarExpr).name in spec.laned
        n = (target::VarExpr).name
        sh = haskey(spec.shapes, n) ? spec.shapes[n] : spec.obs_shapes[n]
        length(sh) == length(subs) || return o
        # A lane array holds lane `l` at `l` on its first lane-set axis and at
        # 1 on its other lane-set axes (`_lane_box_dim`), whichever of the
        # scope's loop variables reads that axis: a read aligned by index-set
        # name (esm-spec §4.3.4), whose lane-set axes come in another order
        # than the scope's, still reads the lane's own cell.
        lane_axis = findfirst(s -> s in spec.sets, sh)
        new = ASTExpr[target]
        for d in eachindex(subs)
            s = subs[d]
            if sh[d] in spec.sets
                ok = s isa VarExpr && get(sc.lanevars, (s::VarExpr).name, "") == sh[d]
                ok || _lane_refuse(
                    rule, "it reads '$n' at `$(s)` " *
                        "along the lane set '$(sh[d])', which leaves the " *
                        (spec.kind === :cells ? "cell" : "column")
                )
                push!(new, d == lane_axis ? VarExpr(sc.first) : IntExpr(1))
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
        # Every subscript input must be const: a pre-gather reads it from the
        # build's data, not from a call's parameters or forcing set.
        other = [
            r for r in refs if !haskey(sc.lanevars, r) &&
                (haskey(sc.columns, r) || !(haskey(ctx.arrays, r) && !(r in ctx.livein)))
        ]
        if !isempty(lane) && all(r -> haskey(sc.columns, r), other)
            sort!(lane; by = r -> (findfirst(==(sc.lanevars[r]), spec.sets), r))
            columns = [r => sc.columns[r] for r in sort!(other)]
            k = length(spec.gathers) + 1
            shape = (spec.C, length.(last.(columns))...)
            buf = zeros(prod(shape))
            push!(
                spec.gathers, _LaneGather(
                    buf, ctx.arrays[n], collect(Int, size(ctx.arrays[n])), n, subs,
                    [r => findfirst(==(sc.lanevars[r]), spec.sets) for r in lane], ctx.arrays,
                    columns
                )
            )
            ctx.live["__lane_in_$k"] = isempty(columns) ? buf : reshape(buf, shape)
            idx = ASTExpr[VarExpr("__lane_in_$k"), VarExpr(sc.first)]
            for (r, range) in columns
                sub = VarExpr(r)
                shift = first(range) - 1
                push!(idx, shift == 0 ? sub : OpExpr("-", ASTExpr[sub, IntExpr(shift)]))
            end
            return OpExpr("index", idx)
        end
    end
    if _index_target_kind(target) === _IT_MAKEARRAY
        ma = target::OpExpr
        # A region that covers only part of a lane set along the axis a lane
        # subscript runs on (a coefficient that exists only at the surface,
        # region 1..1 along `lev`): which regions hold a lane's element
        # depends on the lane's cell, so the read is lowered to region
        # membership (`_lane_membership_read`) and rewritten as any
        # elementwise expression.
        partial = any(ma.regions) do region
            any(eachindex(region)) do d
                s = subs[d]
                set = s isa VarExpr ? get(sc.lanevars, (s::VarExpr).name, nothing) : nothing
                set === nothing && return false
                lo = _region_int(ctx.need, region[d][1])
                hi = _region_int(ctx.need, region[d][2])
                !(lo == 1 && hi == get(spec.ext, set, -1))
            end
        end
        if partial
            lowered = _lane_membership_read(spec, ctx, ma, subs, sc, rule)
            return _lane_rewrite(spec, ctx, lowered, sc, rule)
        end
        regions = Vector{Vector{Any}}[]
        bounds = Vector{Union{Nothing, Tuple{Int, Int}}}[]
        for region in ma.regions
            push!(
                bounds, Union{Nothing, Tuple{Int, Int}}[
                    _lane_bounds(_region_int(ctx.need, r[1]), _region_int(ctx.need, r[2]))
                        for r in region
                ]
            )
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
                (lo == 1 && hi == get(spec.ext, set, -1)) || _lane_refuse(
                    rule,
                    "a region boundary along the lane set '$set' depends on the cell"
                )
                r = (s::VarExpr).name == sc.first ? (1:spec.C) : (1:1)
                push!(nr, Any[first(r), last(r)])
            end
            push!(regions, nr)
        end
        # A value that is an array `faq` exactly over its region (the
        # planner's Jacobian documents write one per band field) is read at
        # the subscripts, so it is the `faq`'s body there: the whole-domain
        # build reads a region value at the absolute subscripts
        # (`_resolve_index_of_makearray`), so the value's axes must be the
        # region's own.
        vals = ASTExpr[
            (v isa OpExpr && _is_faq_op((v::OpExpr).op) && _lane_array_faq(v::OpExpr)) ?
                _lane_faq_read(spec, ctx, v::OpExpr, subs, sc, rule, bounds[r]) :
                _lane_rewrite(spec, ctx, v, sc, rule) for (r, v) in enumerate(ma.values)
        ]
        newsubs = ASTExpr[
            (s isa VarExpr && haskey(sc.lanevars, (s::VarExpr).name)) ? s :
                _lane_rewrite(spec, ctx, s, sc, rule) for s in subs
        ]
        return reconstruct(
            o; args = ASTExpr[
                reconstruct(ma; regions = regions, values = vals),
                newsubs...,
            ]
        )
    end
    if target isa OpExpr && _is_faq_op((target::OpExpr).op) && _lane_array_faq(target::OpExpr)
        return _lane_faq_read(spec, ctx, target::OpExpr, subs, sc, rule)
    end
    if target isa OpExpr && _is_array_producer(target)
        _lane_refuse(rule, "an array producer is indexed inside the lane scope")
    end
    return reconstruct(o; args = ASTExpr[_lane_rewrite(spec, ctx, a, sc, rule) for a in o.args])
end

_lane_array_faq(o::OpExpr) = o.output_idx !== nothing && !isempty(o.output_idx) &&
    o.expr_body !== nothing && o.ranges !== nothing

_lane_bounds(lo::Int, hi::Int) = (lo, hi)
_lane_bounds(lo, hi) = nothing

_lane_int(x::Integer) = Int(x)
_lane_int(x::IntExpr) = Int(x.value)
_lane_int(x) = nothing

# A range as its integer bounds `(lo, hi)`: a whole index set (`from` with no
# `of`) or a constant interval; `nothing` for any other range.
function _lane_range_bounds(spec::_LaneSpec, r)
    set = _lane_range_set(r)
    set === nothing || return haskey(spec.ext, set) ? (1, spec.ext[set]) : nothing
    if r isa AbstractVector && length(r) == 2
        return _lane_bounds(_lane_int(r[1]), _lane_int(r[2]))
    end
    return nothing
end

# The index set a `from` range runs over whole (no `of`), or `nothing`.
function _lane_range_set(r)
    if r isa IndexSetRef
        return isempty(r.of) ? r.from : nothing
    elseif r isa AbstractDict && haskey(r, "from")
        of = get(r, "of", nothing)
        (of === nothing || isempty(of)) || return nothing
        return String(r["from"])
    end
    return nothing
end

# Whether a lane may read the array `faq` `F` by its body alone: no `key`,
# `join` or `distinct` (those are scoped to the node and name its output
# indices), and an `args` list, if any, that names only operand arrays —
# variables, none of them an index the node binds. Such a list is the arrays
# the body reads (esm-spec §4.3.1) and changes nothing. One rule for every
# array `faq` a lane reads: a whole-array right-hand side, an observed defined
# whole, and a `makearray` region value.
function _lane_faq_fields_ok(F::OpExpr)
    bound(n) = (F.ranges !== nothing && haskey(F.ranges, n)) ||
        (F.output_idx !== nothing && n in _output_idx_strings(F))
    return F.key === nothing && (F.join === nothing || isempty(F.join)) &&
        F.distinct !== true && all(a -> a isa VarExpr && !bound(a.name), F.args)
end

const _LANE_FAQ_FIELDS_REFUSAL = "carries `key`, `join`, `distinct`, or `args` that are not " *
    "only the names of its operand arrays"

# `index(faq{output_idx o, ranges, body}, s…)`: the array `faq` read at the
# subscripts `s`, each a loop variable. That is the body with each `o_d`
# renamed `s_d` (capture-avoiding); any other range of the `faq` (a
# contraction) stays a scalar `faq` over it. The planner's whole-array
# right-hand sides `D(x) = faq{…}`, lowered to an indexed `faq`, and its
# Jacobian documents' `makearray` values arrive here.
#
# Each output axis must run over exactly what reads it, as the whole-domain
# build reads the `faq` at the absolute subscript: along a lane set, the whole
# set (`from` it with no `of`, or `[1, extent]`); as a `makearray` region value
# (`region` holds that region's integer bounds), the region's bounds; otherwise
# the range the subscript runs over in the enclosing scope.
function _lane_faq_read(
        spec::_LaneSpec, ctx, F::OpExpr, subs, sc::_LaneScope, rule::String,
        region = nothing
    )
    outs = _output_idx_strings(F)
    length(outs) == length(subs) || _lane_refuse(rule, "an array faq is read at the wrong rank")
    _lane_faq_fields_ok(F) ||
        _lane_refuse(rule, "an array faq read inside the lane scope " * _LANE_FAQ_FIELDS_REFUSAL)
    renames = Dict{String, ASTExpr}()
    names = Set{String}()
    for (d, (o, s)) in enumerate(zip(outs, subs))
        s isa VarExpr || _lane_refuse(rule, "an array faq is read at a computed subscript")
        sn = (s::VarExpr).name
        r = get(F.ranges, o, nothing)
        r === nothing && _lane_refuse(rule, "an array faq's output index '$o' has no range")
        set = get(sc.lanevars, sn, nothing)
        rb = _lane_range_bounds(spec, r)
        # Along a lane set: that set by name, or the interval over it.
        lane_ok = set !== nothing && (
            _lane_range_set(r) === nothing ? rb == (1, get(spec.ext, set, -1)) :
                _lane_range_set(r) == set
        )
        fits = if region !== nothing
            rb !== nothing && region[d] == rb && (set === nothing || lane_ok)
        elseif set !== nothing
            lane_ok
        else
            sr = get(sc.ranges, sn, nothing)
            # Read by position, as Rust does: the subscript's range starts at 1.
            rb !== nothing && sr !== nothing && _lane_range_bounds(spec, sr) == rb && rb[1] == 1
        end
        fits || _lane_refuse(
            rule, "an array faq's axis '$o' does not run over the whole of what reads it"
        )
        sn == o || (renames[o] = s)
        push!(names, sn)
    end
    contracted = Dict{String, Any}(String(k) => v for (k, v) in F.ranges if !(String(k) in outs))
    any(k -> k in names, keys(contracted)) &&
        _lane_refuse(rule, "an array faq's contraction rebinds a subscript")
    body = _lane_rename(F.expr_body, renames, rule)
    if isempty(contracted) && F.filter === nothing
        return _lane_rewrite(spec, ctx, body, sc, rule)
    end
    filt = F.filter === nothing ? nothing : _lane_rename(F.filter, renames, rule)
    G = reconstruct(F; output_idx = Any[], ranges = contracted, expr_body = body, filter = filt)
    return _lane_rewrite(spec, ctx, G, sc, rule)
end

# `e` with each output index renamed to its subscript, capture-avoiding: a
# nested binder of an output index's name shadows it (`_sub_preserving`), and
# one that binds a subscript's name where the renamed index is free would
# capture it, which is refused.
function _lane_rename(e::ASTExpr, renames::Dict{String, ASTExpr}, rule::String)
    isempty(renames) && return e
    _lane_check_capture(e, renames, rule)
    return _sub_preserving(e, renames)
end

function _lane_check_capture(e::ASTExpr, renames::Dict{String, ASTExpr}, rule::String)
    e isa OpExpr || return nothing
    o = e::OpExpr
    bound = _bound_symbols(o)
    active = renames
    if !isempty(bound)
        active = Dict{String, ASTExpr}(k => v for (k, v) in renames if !(k in bound))
        isempty(active) && return nothing
        free = nothing
        for (k, v) in active
            vnames = v isa VarExpr ? (String[(v::VarExpr).name]) : collect(free_variables(v))
            caught = findfirst(in(bound), vnames)
            caught === nothing && continue
            free === nothing && (free = free_variables(o))
            k in free && _lane_refuse(
                rule, "a nested aggregate binds '$(vnames[caught])', which an array " *
                    "faq's output index '$k' is renamed to"
            )
        end
    end
    map_children(x -> (_lane_check_capture(x, active, rule); x), o)
    return nothing
end

# The lane rewrite of `faq(D(index(v, …)))` / an observed's `faq` definition:
# the lane loop variables narrowed to the lane index (`1..C`) and `1`.
function _lane_scope_ranges(
        spec::_LaneSpec, outs::Vector{String}, sets::Vector{String},
        ranges, rule
    )
    lanevars = Dict{String, String}()
    first = ""
    newr = Dict{String, Any}(String(k) => r for (k, r) in ranges)
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
    columns = Dict{String, UnitRange{Int}}()
    if spec.fragment
        _lane_column_ranges!(columns, spec, ranges)
        for n in keys(lanevars)
            delete!(columns, n)
        end
    end
    scope_ranges = Dict{String, Any}(String(k) => r for (k, r) in ranges)
    return _LaneScope(lanevars, first, columns, scope_ranges), newr
end

function _lane_column_ranges!(columns, spec, ranges)
    for (name, r) in pairs(ranges)
        n = String(name)
        if r isa AbstractDict && haskey(r, "from") && haskey(spec.ext, r["from"])
            columns[n] = 1:spec.ext[r["from"]]
        elseif r isa AbstractVector && length(r) == 2
            a, b = map(x -> x isa Integer ? Int(x) : x isa IntExpr ? x.value : nothing, r)
            if a !== nothing && b !== nothing
                columns[n] = a:b
            else
                delete!(columns, n)
            end
        else
            delete!(columns, n)
        end
    end
    return columns
end

# Resolve the subscript with the same compiler used for integer gather nodes.
# Index symbols become input slots of this small expression program.
function _compile_lane_subscripts(g::_LaneGather)
    names = [first.(g.vars); first.(g.columns)]
    slots = Dict(n => i for (i, n) in enumerate(names))
    rc = _ResolveCtx(Dict{String, Tuple{Vector{Int}, Vector{Int}}}(), slots, copy(g.consts))
    return [_compile(_resolve_indices(e, rc), slots, Set{Symbol}()) for e in g.subs]
end

# `(c0, coef)` with `e == c0 + Σ coef[v]·v` over the lane variables `vars`
# (integer arithmetic, as `_subscript_binop`), or `nothing` when `e` is not of
# that form. `env` binds the build-time integer parameters.
function _lane_affine(e::ASTExpr, vars::Dict{String, Int}, env::Dict{String, Int})
    if e isa IntExpr
        return (Int((e::IntExpr).value), Dict{String, Int}())
    elseif e isa NumExpr
        v = (e::NumExpr).value
        return isinteger(v) ? (Int(v), Dict{String, Int}()) : nothing
    elseif e isa VarExpr
        n = (e::VarExpr).name
        haskey(vars, n) && return (0, Dict{String, Int}(n => 1))
        haskey(env, n) && return (env[n], Dict{String, Int}())
        return nothing
    end
    e isa OpExpr || return nothing
    o = e::OpExpr
    _tpl_is_call(o) && return nothing
    parts = Any[_lane_affine(a, vars, env) for a in o.args]
    any(isnothing, parts) && return nothing
    scale(p, k) = (k * p[1], Dict{String, Int}(v => k * c for (v, c) in p[2]))
    function add(p, q)
        c = copy(p[2])
        for (v, x) in q[2]
            c[v] = get(c, v, 0) + x
        end
        return (p[1] + q[1], c)
    end
    if o.op == "+" && !isempty(parts)
        return foldl(add, parts)
    elseif (o.op == "-" || o.op == "neg") && length(parts) == 1
        return scale(parts[1], -1)
    elseif o.op == "-" && length(parts) == 2
        return add(parts[1], scale(parts[2], -1))
    elseif o.op == "*" && !isempty(parts)
        varying = [p for p in parts if !isempty(p[2])]
        length(varying) <= 1 || return nothing
        k = prod(p[1] for p in parts if isempty(p[2]); init = 1)
        return isempty(varying) ? (k, Dict{String, Int}()) : scale(varying[1], k)
    end
    return nothing
end

# The plan of pre-gathered input `g`: `S` the lane sets in `cells` row order,
# `ext` their extents, `params` the build-time integer parameters.
function _lane_gather_plan(g::_LaneGather, S::Vector{String}, ext, params::Dict{String, Int})
    isempty(g.columns) || error("internal error: lanes: an in-place pre-gather has columns")
    row = Dict{String, Int}(g.vars)
    nd = length(g.dims)
    strides = Vector{Int}(undef, nd)
    acc = 1
    for d in 1:nd
        strides[d] = acc
        acc *= g.dims[d]
    end
    policy = Symbol[_const_dim_boundary(g.src, d) for d in 1:nd]
    subs = map(enumerate(g.subs)) do (d, e)
        reads = [v for v in _referenced_var_names(e) if haskey(row, v)]
        sort!(reads; by = v -> row[v])
        rows = Int[row[v] for v in reads]
        exts = Int[ext[S[r]] for r in rows]
        aff = _lane_affine(e, Dict{String, Int}(v => 1 for v in reads), params)
        if aff !== nothing
            c0, coef = aff
            return _LaneSubscript(
                rows, exts, true, false, c0, Int[get(coef, v, 0) for v in reads], Int32[]
            )
        end
        ntab = prod(big.(exts); init = big(1))
        ntab > _LANE_SUBSCRIPT_TABLE_MAX[] &&
            return _LaneSubscript(rows, exts, false, false, 0, Int[], Int32[])
        table = Vector{Int32}(undef, Int(ntab))
        env = copy(params)
        for (k, c) in enumerate(CartesianIndices(Tuple(1:x for x in exts)))
            for (j, v) in enumerate(reads)
                env[v] = c[j]
            end
            i = try
                _eval_const_int(e, env, g.consts)::Int
            catch
                nothing
            end
            table[k] = i === nothing ? Int32(-1) : Int32(_lane_resolve(g, policy, d, i))
        end
        return _LaneSubscript(rows, exts, false, true, 0, Int[], table)
    end
    return _LaneGatherPlan(subs, copy(g.dims), strides, policy)
end

# Const data as the flat `Float64` vector a pre-gather reads by linear
# position (its own memory when it is one already).
_lane_flat(a::Array{Float64}) = vec(a)
_lane_flat(a::AbstractArray) = Float64[Float64(a[i]) for i in 1:length(a)]

# Axis position `i` of axis `d` resolved by its boundary policy, as
# `_resolve_const_index` resolves it, or 0 where that throws (the read is 0.0).
@inline function _lane_resolve(g::_LaneGather, policy::Vector{Symbol}, d::Int, i::Int)
    n = @inbounds g.dims[d]
    1 <= i <= n && return i
    return _lane_resolve_oob(g, policy, d, i)
end
@noinline function _lane_resolve_oob(g::_LaneGather, policy::Vector{Symbol}, d::Int, i::Int)
    return try
        _resolve_const_index_oob(policy[d], g.name, d, i, g.dims[d])
    catch err
        err isa TreeWalkError || rethrow()
        0
    end
end

# An observed the lane program does not compute per lane (a 0-d observed, an
# array observed with no lane set or in `spec.whole`) is evaluated once over
# the whole domain, where a lane array (a state, an observed computed per
# lane) holds only the chunk's lanes, so it must read none, through any of the
# observeds it reads. One that reads a state is refused. One that reads an
# observed computed per lane takes that observed, and every other it reads,
# over the whole domain with it: the build is retried with them in
# `spec.whole` (`_lane_instance`). An out-of-place fragment (no time buffer)
# has no whole-domain evaluation and refuses it.
function _lane_check_whole_reads(spec::_LaneSpec, defs)
    for n in sort!(collect(keys(defs)))
        n in spec.laned && continue
        reached = String[]
        stack = String[n]
        while !isempty(stack)
            x = pop!(stack)
            (x in reached || !haskey(defs, x)) && continue
            push!(reached, x)
            for r in _referenced_var_names(defs[x])
                haskey(spec.shapes, r) && _lane_refuse(
                    n, "the observed '$n' is computed over the whole domain but " *
                        "reads the lane array '$r'"
                )
                push!(stack, r)
            end
        end
        k = findfirst(in(spec.laned), reached)
        k === nothing && continue
        why = "the observed '$n' is computed over the whole domain but reads " *
            "'$(reached[k])', which is computed per lane"
        spec.tbuf === nothing && _lane_refuse(n, why)
        throw(_LaneWholeFallback(reached[k], reached, why))
    end
    return nothing
end

function _range_restrict_parts(
        spec::_LaneSpec, model, cls, parts, index_sets,
        const_arrays, param_arrays
    )
    # ---- the context: arrays, extents, observeds ----
    arrays = Dict{String, Any}()
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
    states = Set{String}(parts.state_var_names)
    defs = Dict{String, ASTExpr}()
    for eq in parts.equations
        eq.lhs isa VarExpr || continue
        defs[(eq.lhs::VarExpr).name] = eq.rhs
    end
    # The state-dependent observeds.
    dep = Dict{String, Bool}()
    function statedep(n, seen = Set{String}())
        haskey(dep, n) && return dep[n]
        n in seen && return false
        push!(seen, n)
        r = _anyof(
            x -> x in states || (haskey(defs, x) && statedep(x, seen)),
            _referenced_var_names(defs[n])
        )
        dep[n] = r
        return r
    end
    # Every array observed on a lane set is evaluated per lane, a state-free one
    # included: its lane value is its value at the lane's cell, the same
    # expression of the same global indices.
    for (n, _) in defs
        v = get(model.variables, n, nothing)
        (v !== nothing && _is_array_shape(v.shape) && !(n in spec.whole)) || continue
        sh = String[string(s) for s in v.shape]
        any(s -> s in sh, spec.sets) || continue
        spec.obs_shapes[n] = sh
        push!(spec.laned, n)
    end
    for n in keys(spec.shapes)
        push!(spec.laned, n)
    end
    _lane_check_whole_reads(spec, defs)
    live = Dict{String, Any}()
    needctx = _NeedCtx(
        :lane, _AxisModel(
            Dict{String, Tuple{String, Bool}}(), Dict{String, Int}(),
            Dict{String, Union{Nothing, Int}}()
        ), Dict{String, UnitRange{Int}}(),
        Dict{String, UnitRange{Int}}(), Dict{String, Vector{String}}(),
        Dict{String, Vector{Int}}(), Set{String}(),
        Dict{String, ASTExpr}(), Dict{String, ASTExpr}(), Set{String}(),
        spec.params, arrays, Set{String}(), Dict{Tuple{String, String}, Tuple{Int, Int}}(),
        Set{String}(), Dict{String, Vector{_Bind}}(), String[], Set{String}()
    )
    livein = Set{String}(String(k) for k in keys(param_arrays))
    ctx = (; arrays, live, livein, need = needctx)
    eqs = Equation[]
    for eq in parts.equations
        tgt = _d_target(eq.lhs)
        if tgt !== nothing
            haskey(spec.shapes, tgt) || _lane_refuse(
                tgt,
                "the operator writes the 0-d state '$tgt', which no lane owns"
            )
            L = eq.lhs
            (L isa OpExpr && _is_faq_op((L::OpExpr).op)) || _lane_refuse(
                tgt,
                "its left-hand side is not an array equation"
            )
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
            body, filt, rr = try
                (
                    R isa OpExpr && _is_faq_op((R::OpExpr).op) &&
                        length(_output_idx_strings(R::OpExpr)) == length(spec.obs_shapes[n])
                ) ||
                    _lane_refuse(n, "the observed '$n' is not defined by an array aggregate")
                R = R::OpExpr
                sc, rr = _lane_scope_ranges(
                    spec, _output_idx_strings(R), spec.obs_shapes[n],
                    R.ranges, n
                )
                (
                    _lane_rewrite(spec, ctx, R.expr_body, sc, n),
                    R.filter === nothing ? nothing : _lane_rewrite(spec, ctx, R.filter, sc, n),
                    rr,
                )
            catch err
                # An observed of `t` (not of a state) with no lane form is
                # computed over the whole domain instead, with every observed
                # of `t` it reads, as Rust does.
                (
                    err isa TreeWalkError && err.code == ERROR_CODES.COMPILER_REFUSED_RULE &&
                        spec.tbuf !== nothing && n in spec.tnames && !statedep(n)
                ) || rethrow()
                names = String[]
                stack = String[n]
                while !isempty(stack)
                    x = pop!(stack)
                    (x in names || !haskey(defs, x)) && continue
                    push!(names, x)
                    append!(stack, r for r in _referenced_var_names(defs[x]) if r in spec.tnames)
                end
                throw(_LaneWholeFallback(n, names, err.detail))
            end
            push!(
                eqs, Equation(
                    eq.lhs, reconstruct(
                        R; ranges = rr, expr_body = body,
                        filter = filt
                    ); _comment = eq._comment
                )
            )
        else
            push!(eqs, eq)
        end
    end
    # The pre-gathered buffers join the live forcing buffers the build binds.
    for (k, v) in live
        param_arrays[k] = v
    end
    return _with_equations(parts, eqs)
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
lanes(op::RhsProgram, kind::Symbol, sets; chunk::Int = _LANE_CHUNK) =
    _lanes(op, kind, sets, chunk)

function _lanes(
        op::RhsProgram, kind::Symbol, sets, chunk::Int; form = :inplace, shared_aux = Set{String}()
    )
    _require_native(op, "lanes")
    kind in (:cells, :columns) || throw(
        _box_invalid(
            string(kind),
            "a lane kind is :cells or :columns"
        )
    )
    S = String[String(s) for s in sets]
    isempty(S) && throw(_box_invalid("", "no lane sets were given"))
    shapes = _array_shapes(op)
    for n in vcat(op.writes, op.aux_names)
        n in shared_aux && continue
        sh = get(shapes, n, nothing)
        sh === nothing && throw(
            _box_invalid(
                join(S, ", "),
                "the 0-d state '$n' carries no lane set"
            )
        )
        for s in S
            s in sh || throw(
                _box_invalid(
                    s, "the state '$n' (on $(join(sh, ", "))) " *
                        "does not carry the lane set '$s'"
                )
            )
        end
        others = [s for s in sh if !(s in S)]
        kind === :cells && !isempty(others) && throw(
            _box_invalid(
                join(others, ", "),
                "a :cells lane spans every index set of '$n'; add it to the lane sets " *
                    "or use :columns"
            )
        )
        kind === :columns && isempty(others) && throw(
            _box_invalid(
                join(S, ", "),
                "a :columns lane leaves a column, but the lane sets cover every index set of '$n'"
            )
        )
    end
    inst = _lane_instance(op, kind, S, chunk; form)
    internal = inst.internal
    # ---- the lane layout and its copy plans ----
    function blocks(names)
        out = LaneBlock[]
        plans = _LaneCopy[]
        off = 0
        for n in names
            if n in shared_aux
                push!(out, LaneBlock(n, String[], Int[], off))
                push!(plans, _LaneCopy(off, [internal.scalars[n]], 0))
                off += 1
                continue
            end
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
    lane_bufs = vcat(
        inst.index_bufs, Vector{Float64}[g.buf for g in inst.gathers],
        inst.tbuf === nothing ? Vector{Float64}[] : Vector{Float64}[inst.tbuf]
    )
    # A gather of a live buffer reads the call's forcing set: the live buffers
    # are the forcing slots, by name.
    gslots = Int[
        something(findfirst(s -> s.name == g.name, op.shared.slots), 0)
            for g in inst.gathers
    ]
    for (g, k) in zip(inst.gathers, gslots)
        k == 0 && haskey(inst.pa, g.name) && error(
            "internal error: lanes: the pre-gathered input '$(g.name)' is a live buffer " *
                "but no forcing slot"
        )
    end
    form === :oop && return (; inst..., layout, uplan, aplan, gslots)
    ext = _program_sets(op)
    gplans = _LaneGatherPlan[_lane_gather_plan(g, S, ext, inst.params) for g in inst.gathers]
    gflat = Vector{Float64}[
        k == 0 ? _lane_flat(g.src) : Float64[] for (g, k) in zip(inst.gathers, gslots)
    ]
    return LaneProgram(
        op, S, chunk, inst.f!, internal, layout, inst.index_bufs,
        inst.gathers, gslots, gplans, gflat, Int[ext[s] for s in S], uplan, aplan, inst.params,
        _derived_shared(
            op.shared, inst.f!, length(internal), inst.cap,
            inst.pa, lane_bufs
        ), inst.tbuf, inst.tshared
    )
end

# One compiled lane program: its right-hand side, the live lane buffers it
# reads, its gathers and its build's forcing epoch.
#
# An observed of `t` on a lane set with no lane form (it reads another cell)
# is computed over the whole domain, with every observed of `t` it reads, as
# an observed of `t` with no lane set is: the build is retried with it in
# `spec.whole` until no observed falls back. The one-time call is then the
# whole-domain program's, and a call at mixed times refuses those observeds.
function _lane_instance(op::RhsProgram, kind::Symbol, S::Vector{String}, chunk::Int; form = :inplace)
    whole = Set{String}()
    while true
        r = _lane_instance(op, kind, S, chunk, whole; form)
        r isa _LaneWholeFallback || return r
        r.name in whole && error("internal error: lanes: '$(r.name)' fell back twice")
        union!(whole, r.names)
    end
    return
end

function _lane_instance(
        op::RhsProgram, kind::Symbol, S::Vector{String}, chunk::Int, whole::Set{String};
        form = :inplace
    )
    index_bufs = Dict{String, Vector{Float64}}(s => zeros(chunk) for s in S)
    tbuf = form === :oop ? nothing : zeros(chunk)
    spec = _LaneSpec(
        kind, S, chunk, _array_shapes(op), index_bufs, _LaneGather[],
        Set{String}(), Dict{String, Vector{String}}(), Dict{String, Int}(),
        _program_sets(op), form === :oop, tbuf, Set{String}(), String[], Set{String}(),
        copy(whole)
    )
    # The lane-index buffers are live forcing buffers of the build.
    file, model_name, recorded = op.front
    opts = _relower_options(recorded)
    opts.form = form
    pa = Dict{String, Any}(
        String(k) => v for (k, v) in something(opts.param_arrays, Dict{String, Any}())
    )
    for (s, b) in index_bufs
        pa["__lane_" * s] = b
    end
    tbuf === nothing || (pa["__lane_t"] = tbuf)
    opts.param_arrays = pa
    cap = _WsCapture()
    built = try
        _with_ws_capture(cap) do
            _with_compiler_plan(_plan(op.compiler)) do
                _with_range_spec(spec) do
                    _build_selected(file, model_name, opts)
                end
            end
        end
    catch err
        err isa _LaneWholeFallback && return err
        rethrow()
    end
    f!, _u0, _p, _ts, internal = built
    return (;
        f!, internal, index_bufs = Vector{Float64}[index_bufs[s] for s in S],
        gathers = spec.gathers, params = spec.params, cap, pa, tbuf, tshared = spec.tshared,
    )
end

"""
    lane_layout(lanes::LaneProgram) -> LaneLayout

The `u`/`aux` lane layout (API_SPEC §5.8, "Lanes"): element `e` of variable `v`
for lane `l` of an `L`-lane batch is at slot `(offset_v + e - 1)·L + l`.
"""
lane_layout(lp::LaneProgram) = lp.layout

parameters(lp::LaneProgram) = lp.shared.params

rhs_workspace(lp::LaneProgram) = _instantiate(lp.shared)

"""
    lane_inputs(lanes::LaneProgram, L::Integer) -> LaneInputs

Buffers for the non-state inputs of an `L`-lane batch: each lane set's global
index and every pre-gathered array read. Fill them with
[`gather_lane_inputs!`](@ref).
"""
lane_inputs(lp::LaneProgram, L::Integer) =
    LaneInputs(
    [zeros(Int(L)) for _ in lp.index_bufs],
    [zeros(Int(L)) for _ in lp.gathers], Int(L),
    Base.RefValue{Union{Nothing, ForcingSet}}(nothing), lp.shared
)

# Pre-gathered input `k` at the cell of lane `l` of `cells`, stored into
# `buf[c]`: read from the call's forcing buffer, or from const data.
@inline function _lane_gather!(
        buf::Vector{Float64}, c::Int, lp::LaneProgram, k::Int, fs::ForcingSet,
        cells::AbstractMatrix, l::Int
    )
    slot = @inbounds lp.gather_slots[k]
    src = slot == 0 ? (@inbounds lp.gflat[k]) : (@inbounds fs.bufs[slot])
    @inbounds buf[c] = _lane_gather_value(lp, k, src, cells, l)
    return nothing
end

# The value of pre-gathered input `k` (read from `src`, linear over its
# source's shape) at the cell of lane `l` of `cells`, whose indices are in
# their sets' ranges (`_lane_check_cells`). The subscripts are evaluated in
# order: one that throws raises its error, and the first that resolves
# outside its axis makes the read 0.0.
function _lane_gather_value(
        lp::LaneProgram, k::Int, src::Vector{Float64}, cells::AbstractMatrix, l::Int
    )
    gp = @inbounds lp.gplans[k]
    lin = 0
    @inbounds for d in eachindex(gp.subs)
        s = gp.subs[d]
        if s.affine
            i = s.c0
            for j in eachindex(s.rows)
                i += s.coef[j] * Int(cells[s.rows[j], l])
            end
            1 <= i <= gp.dims[d] || (i = _lane_resolve_oob(lp.gathers[k], gp.policy, d, i))
        elseif !s.tabled
            i = _lane_resolve(lp.gathers[k], gp.policy, d, _lane_subscript_eval(lp, k, d, cells, l))
        else
            e = 0
            st = 1
            for j in eachindex(s.rows)
                e += (Int(cells[s.rows[j], l]) - 1) * st
                st *= s.exts[j]
            end
            i = Int(s.table[e + 1])
            i < 0 && _lane_subscript_throw(lp, k, d, cells, l)
        end
        i == 0 && return 0.0
        lin += (i - 1) * gp.strides[d]
    end
    return @inbounds src[lin + 1]
end

# Subscript `d` of pre-gathered input `k` at the cell of lane `l`, evaluated
# (not resolved on its axis): a subscript too large to table, or one whose
# table says it throws here.
@noinline function _lane_subscript_eval(lp::LaneProgram, k::Int, d::Int, cells, l::Int)
    g = lp.gathers[k]
    env = Dict{String, Int}(lp.params)
    for (v, row) in g.vars
        env[v] = Int(cells[row, l])
    end
    return _eval_const_int(g.subs[d], env, g.consts)::Int
end

# A subscript whose evaluation throws at this cell: raise its error.
@noinline function _lane_subscript_throw(lp::LaneProgram, k::Int, d::Int, cells, l::Int)
    _lane_subscript_eval(lp, k, d, cells, l)
    g = lp.gathers[k]
    return error("internal error: lanes: the subscript $d of the pre-gathered read of '$(g.name)' threw at build but not now")
end

# Every index of lanes `1..n` of `cells` in its lane set's range.
function _lane_check_cells(lp::LaneProgram, cells::AbstractMatrix, n::Integer, call::String)
    @inbounds for l in 1:Int(n), k in eachindex(lp.exts)
        v = cells[k, l]
        1 <= v <= lp.exts[k] || _lane_cell_out_of_range(lp, call, k, l, v)
    end
    return nothing
end
@noinline _lane_cell_out_of_range(lp::LaneProgram, call, k, l, v) = throw(
    ArgumentError(
        "$call: cells[$k, $l] = $v is outside the lane set '$(lp.sets[k])' " *
            "(1..$(lp.exts[k]))"
    )
)

"""
    gather_lane_inputs!(li::LaneInputs, lanes::LaneProgram, p, t, fs, cells, n) -> li

Fill `li` for the first `n` lanes of `cells` (an `Int32` `[D, L]` matrix, rows in
the program's lane-set order); lanes past `n` take lane `n`'s inputs. `li` must
come from [`lane_inputs`](@ref)`(lanes, L)` and `fs` be a [`ForcingSet`](@ref)
of `lanes`. A gather that throws leaves `li` holding no gather, so `rhs!`
refuses it until a gather finishes.
"""
function gather_lane_inputs!(
        li::LaneInputs, lp::LaneProgram, p, t, fs::ForcingSet,
        cells::AbstractMatrix, n::Integer
    )
    li.owner === lp.shared || throw(
        ArgumentError(
            "gather_lane_inputs!: the lane inputs were made by lane_inputs of another program"
        )
    )
    _check_forcing_set(lp.shared.slots, fs, "gather_lane_inputs!")
    L = li.L
    size(cells, 1) == length(lp.sets) || throw(
        DimensionMismatch(
            "gather_lane_inputs!: `cells` has $(size(cells, 1)) rows; the lane sets are " *
                join(lp.sets, ", ")
        )
    )
    size(cells, 2) == L || throw(
        DimensionMismatch(
            "gather_lane_inputs!: `cells` has $(size(cells, 2)) lanes; the inputs hold $L"
        )
    )
    1 <= n <= L || throw(
        DimensionMismatch(
            "gather_lane_inputs!: n = $n lanes of an L = $L batch"
        )
    )
    _lane_check_cells(lp, cells, n, "gather_lane_inputs!")
    li.fs[] = nothing
    for l in 1:L
        src = min(l, Int(n))
        for k in eachindex(li.index)
            li.index[k][l] = Float64(cells[k, src])
        end
        for k in eachindex(lp.gathers)
            _lane_gather!(li.gathered[k], l, lp, k, fs, cells, src)
        end
    end
    li.fs[] = fs
    return li
end

function _lane_check(lp::LaneProgram, ws::RhsWorkspace, du, u, aux, p, cells, n)
    _check_workspace(lp.shared, ws)
    _check_parameters(lp.shared, p, "rhs!")
    L = size(cells, 2)
    size(cells, 1) == length(lp.sets) || throw(
        DimensionMismatch(
            "rhs!: `cells` has $(size(cells, 1)) rows; the lane sets are $(join(lp.sets, ", "))"
        )
    )
    # A lane count out of range is a length, as in `gather_lane_inputs!`.
    (1 <= n <= L) || throw(DimensionMismatch("rhs!: n = $n lanes of an L = $L batch"))
    _lane_check_cells(lp, cells, n, "rhs!")
    length(u) == lp.layout.n_u * L || throw(
        DimensionMismatch(
            "rhs!: `u` has $(length(u)) elements; the lane layout needs $(lp.layout.n_u * L)"
        )
    )
    length(aux) == lp.layout.n_aux * L || throw(
        DimensionMismatch(
            "rhs!: `aux` has $(length(aux)) elements; the lane layout needs $(lp.layout.n_aux * L)"
        )
    )
    length(du) == lp.layout.n_u * L || throw(
        DimensionMismatch(
            "rhs!: `du` has $(length(du)) elements; the lane layout needs $(lp.layout.n_u * L)"
        )
    )
    return L
end

# Run lanes `s0+1 … s0+m` of the batch through the program, after its lane
# buffers hold their inputs.
function _lane_chunk!(
        du, lp::LaneProgram, ws::RhsWorkspace, u, aux, p, t, L::Int,
        s0::Int, m::Int
    )
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
    # The lane buffers are per-call inputs: no memoized value reads one
    # (`_range_lane_inputs`), so a chunk leaves every cadence stamp standing.
    D = ws.du
    _ws_eval!(ws, p, t)
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

"""
    rhs!(du, lanes::LaneProgram, ws, u, aux, p, t, fs::ForcingSet, cells, n) -> du
    rhs!(du, lanes::LaneProgram, ws, u, aux, p, t, li::LaneInputs, cells, n) -> du

Evaluate the first `n` lanes of an `L`-lane batch (API_SPEC §5.8, "Lanes"):
`u`, `aux`, `du` in [`lane_layout`](@ref), `cells` an `[D, L]` matrix of global
indices (rows in the lane-set order). The second form takes every pre-gathered
input from `li` ([`gather_lane_inputs!`](@ref)) instead of gathering it here,
and evaluates against the forcing set `li` was gathered from. Every per-call
buffer is the workspace's: reentrant across distinct workspaces.
"""
function rhs!(
        du::AbstractVector, lp::LaneProgram, ws::RhsWorkspace, u::AbstractVector,
        aux::AbstractVector, p, t::Real, fs::ForcingSet, cells::AbstractMatrix, n::Integer
    )
    L = _lane_check(lp, ws, du, u, aux, p, cells, n)
    return _lane_rhs!(du, lp, ws, u, aux, p, _ -> Float64(t), fs, cells, n, L)
end

# The lanes `1..n` in chunks of the program's `C` lanes, lane `l` at time
# `tof(l)`; a padding lane copies an active lane's inputs and takes the first
# lane's time, `tof(1)`.
function _lane_rhs!(du, lp::LaneProgram, ws::RhsWorkspace, u, aux, p, tof::F, fs::ForcingSet, cells, n, L) where {F}
    _prime!(ws, fs)
    C = lp.C
    ni = length(lp.index_bufs)
    lb = ws.lbufs
    tb = lp.tbuf === nothing ? nothing : lb[end]
    for s0 in 0:C:(n - 1)
        m = min(C, n - s0)
        for c in 1:C
            l = s0 + min(c, m)
            for k in 1:ni
                lb[k][c] = Float64(cells[k, l])
            end
            tb === nothing || (tb[c] = c <= m ? tof(l) : tof(1))
        end
        # Gather by gather, each over the chunk's lanes.
        for k in eachindex(lp.gathers)
            buf = lb[ni + k]
            for c in 1:C
                _lane_gather!(buf, c, lp, k, fs, cells, s0 + min(c, m))
            end
        end
        _lane_chunk!(du, lp, ws, u, aux, p, tof(s0 + 1), L, s0, m)
    end
    return du
end

function rhs!(
        du::AbstractVector, lp::LaneProgram, ws::RhsWorkspace, u::AbstractVector,
        aux::AbstractVector, p, t::Real, li::LaneInputs, cells::AbstractMatrix, n::Integer
    )
    L = _lane_check(lp, ws, du, u, aux, p, cells, n)
    return _lane_gathered_rhs!(du, lp, ws, u, aux, p, _ -> Float64(t), li, n, L)
end

# The pre-gathered form of `_lane_rhs!`: every lane input from `li`, lane `l`
# at time `tof(l)` and a padding lane at `tof(1)`.
function _lane_gathered_rhs!(
        du, lp::LaneProgram, ws::RhsWorkspace, u, aux, p, tof::F, li::LaneInputs, n, L
    ) where {F}
    li.owner === lp.shared || throw(
        ArgumentError(
            "rhs!: the lane inputs were made by lane_inputs of another program"
        )
    )
    li.L == L || throw(DimensionMismatch("rhs!: the lane inputs hold $(li.L) lanes; the batch has $L"))
    fs = li.fs[]
    fs === nothing && throw(
        ArgumentError(
            "rhs!: the lane inputs hold no gather (gather_lane_inputs! was never called, or " *
                "its last call threw)"
        )
    )
    _prime!(ws, fs)
    C = lp.C
    ni = length(lp.index_bufs)
    lb = ws.lbufs
    tb = lp.tbuf === nothing ? nothing : lb[end]
    for s0 in 0:C:(n - 1)
        m = min(C, n - s0)
        for c in 1:C
            l = s0 + min(c, m)
            for k in 1:ni
                lb[k][c] = li.index[k][l]
            end
            for k in eachindex(lp.gathers)
                lb[ni + k][c] = li.gathered[k][l]
            end
            tb === nothing || (tb[c] = c <= m ? tof(l) : tof(1))
        end
        _lane_chunk!(du, lp, ws, u, aux, p, tof(s0 + 1), L, s0, m)
    end
    return du
end

"""
    rhs!(du, lanes::LaneProgram, ws, u, aux, p, ts::AbstractVector, fs::ForcingSet, cells, n) -> du

Each lane at its own time (U19): lane `l ≤ n` evaluates at `ts[l]`, and its
value equals the whole-domain program's at `cells[:, l]` and time `ts[l]`,
bit for bit, whatever the other lanes' times. `ts` holds at least `n` and at
most `L` times; a padding lane takes `ts[1]`.

One pass over the batch, whatever its times: the lane program reads `t` from a
lane buffer of times, and every 0-d observed that depends on `t` is computed
per lane ([`_range_promote_model`](@ref)). With equal times the call equals
the one-time call. An observed of `t` that carries no lane set is evaluated
once per call, at one time: when the state equations read one, the times of
lanes `1..n` must be equal, or the call throws an `ArgumentError` naming it.
"""
function rhs!(
        du::AbstractVector, lp::LaneProgram, ws::RhsWorkspace, u::AbstractVector,
        aux::AbstractVector, p, ts::AbstractVector{<:Real}, fs::ForcingSet,
        cells::AbstractMatrix, n::Integer
    )
    L = _lane_check(lp, ws, du, u, aux, p, cells, n)
    _lane_check_times(lp, ts, n, L)
    return _lane_rhs!(du, lp, ws, u, aux, p, l -> Float64(ts[l]), fs, cells, n, L)
end

"""
    rhs!(du, lanes::LaneProgram, ws, u, aux, p, ts::AbstractVector, li::LaneInputs, cells, n) -> du

The pre-gathered call ([`gather_lane_inputs!`](@ref)) with each lane at its
own time: as the call with a time per lane and a forcing set, every
non-state input taken from `li`.
"""
function rhs!(
        du::AbstractVector, lp::LaneProgram, ws::RhsWorkspace, u::AbstractVector,
        aux::AbstractVector, p, ts::AbstractVector{<:Real}, li::LaneInputs,
        cells::AbstractMatrix, n::Integer
    )
    L = _lane_check(lp, ws, du, u, aux, p, cells, n)
    _lane_check_times(lp, ts, n, L)
    return _lane_gathered_rhs!(du, lp, ws, u, aux, p, l -> Float64(ts[l]), li, n, L)
end

# `ts` for lanes `1..n` of an `L`-lane batch: at least `n` and at most `L`
# times, a program built with a time per lane, and equal times when an
# observed of `t` is evaluated once per call.
function _lane_check_times(lp::LaneProgram, ts, n, L)
    n <= length(ts) <= L || throw(
        DimensionMismatch("rhs!: $(length(ts)) times for n = $n lanes of an L = $L batch")
    )
    lp.tbuf === nothing && throw(
        ArgumentError("rhs!: this lane program was built without a time per lane")
    )
    if !isempty(lp.tshared) && any(l -> ts[l] != ts[1], 2:n)
        throw(
            ArgumentError(
                "rhs!: the lanes' times differ, but the observed(s) " *
                    join(("'$x'" for x in lp.tshared), ", ") * " depend on `t` and have " *
                    "no per-lane form (no lane set, or a read of another cell), so the lane " *
                    "program evaluates them once per call at one time; give every lane the " *
                    "same time"
            )
        )
    end
    return nothing
end

# ---------------------------------------------------------------------------
# A time per lane (U19): 0-d observeds of `t` computed per lane.

_range_promote_model(spec, model, index_sets = nothing) = model

"""
    _range_name_faq_axes(spec::_LaneSpec, model, index_sets) -> model

An observed declared with no shape whose one definition is an array `faq` over
intervals `[1, n]` (the planner's derivative observeds, `_dt_x`) takes, at
shape promotion, an anonymous interval index set per axis (`x__r`), which no
lane set is, so a lane build would evaluate it whole (and refuse it when it
reads the state). In a lane build each such axis takes instead the one index
set of the axis's extent the `faq` body reads its output index along as a
subscript of a variable whose axes are known; when every axis has one, they
become the observed's shape and its `faq`'s ranges, so one along a lane set
is computed per lane (and, when it depends on `t`, at each lane's own time)
like a declared array observed. The extents are unchanged, so the values
are: a lane equals the whole-domain program at its cell bit for bit.
An axis the body reads along no such set (an offset subscript alone, a bare
loop index), or along two, stays anonymous, as in Rust; so does every axis of
an observed with two definitions, which the validator reports.
"""
function _range_name_faq_axes(spec::_LaneSpec, model, index_sets)
    named(s) = haskey(spec.ext, s)
    function extent(s)
        named(s) && return spec.ext[s]
        is = get(index_sets, s, nothing)
        return is isa IndexSet && is.size !== nothing ? Int(is.size) : nothing
    end
    axes = Dict{String, Vector{String}}()
    for (n, v) in model.variables
        _is_array_shape(v.shape) && all(named, v.shape) && (axes[n] = String[v.shape...])
    end
    # The defining equation of each observed declared with no shape and
    # defined once.
    defs = Dict{String, Int}()
    twice = Set{String}()
    for (k, eq) in enumerate(model.equations)
        eq.lhs isa VarExpr || continue
        n = (eq.lhs::VarExpr).name
        v = get(model.variables, n, nothing)
        (v === nothing || !_promoted_shape(n, v.shape)) && continue
        haskey(defs, n) && push!(twice, n)
        defs[n] = k
    end
    names = sort!([n for n in keys(defs) if !(n in twice)])
    found = Dict{String, Tuple{Vector{String}, OpExpr}}()
    grew = true
    while grew
        grew = false
        for n in names
            haskey(axes, n) && continue
            r = _range_faq_output_sets(spec, model.equations[defs[n]].rhs, axes, extent)
            r === nothing && continue
            axes[n] = r[1]
            found[n] = r
            grew = true
        end
    end
    isempty(found) && return model
    vars = copy(model.variables)
    eqs = copy(model.equations)
    for (n, (sh, F)) in found
        vars[n] = reconstruct(model.variables[n]; shape = sh)
        eq = eqs[defs[n]]
        eqs[defs[n]] = Equation(eq.lhs, F; _comment = eq._comment)
    end
    return reconstruct(model; variables = vars, equations = eqs)
end

# Whether `shape` is no declared shape: none, or the anonymous index sets
# (`name__r`) shape promotion names an inline-range `faq`'s axes with.
_promoted_shape(name, shape) =
    shape === nothing || all(s -> startswith(String(s), name * "__"), shape)

# The index set of each output axis of the array `faq` `body` and the `faq`
# ranging over them, or `nothing` when `body` is no array `faq`, repeats an
# output index (a diagonal, not an array of that rank), or an axis has no
# such set (`_range_name_faq_axes`).
function _range_faq_output_sets(spec::_LaneSpec, body, axes, extent)
    (body isa OpExpr && _is_faq_op((body::OpExpr).op)) || return nothing
    F = body::OpExpr
    outs = _output_idx_strings(F)
    (isempty(outs) || length(outs) != length(F.output_idx) || !allunique(outs)) &&
        return nothing
    F.expr_body === nothing && return nothing
    rd = _ranges_dict(F)
    sets = String[]
    newr = Dict{String, Any}(rd)
    for o in outs
        r = get(rd, o, nothing)
        r === nothing && return nothing
        set = _lane_range_set(r)
        set !== nothing && haskey(spec.ext, set) && (push!(sets, set); continue)
        hi = if set !== nothing
            extent(set)
        elseif r isa AbstractVector && length(r) == 2 && _lane_int(r[1]) == 1
            _lane_int(r[2])
        else
            nothing
        end
        hi === nothing && return nothing
        read = filter!(s -> extent(s) == hi, _range_subscript_sets!(Set{String}(), F.expr_body, o, axes))
        length(read) == 1 || return nothing
        push!(sets, only(read))
        newr[o] = IndexSetRef(only(read))
    end
    return sets, reconstruct(F; ranges = newr)
end

# The index sets `e` reads the loop symbol `o` along: the axis of each
# `index(v, …)` subscript that is `o` itself, `v` a variable with known axes.
# A nested binder of `o` hides it.
function _range_subscript_sets!(out::Set{String}, e, o::String, axes)
    e isa OpExpr || return out
    E = e::OpExpr
    E.ranges !== nothing && haskey(E.ranges, o) && return out
    if E.op == "index" && !isempty(E.args) && E.args[1] isa VarExpr
        a = get(axes, (E.args[1]::VarExpr).name, nothing)
        if a !== nothing
            for (d, x) in enumerate(E.args[2:end])
                (x isa VarExpr && (x::VarExpr).name == o && d <= length(a)) && push!(out, a[d])
            end
        end
    elseif E.op == "index" && !isempty(E.args) && E.args[1] isa OpExpr &&
            _is_faq_op((E.args[1]::OpExpr).op)
        # An array `faq` read at `o` (the lifted form `index(faq{r…}, o…)`):
        # `o` runs along what the `faq` body reads its output index along.
        G = E.args[1]::OpExpr
        gouts = _output_idx_strings(G)
        for (d, x) in enumerate(E.args[2:end])
            (x isa VarExpr && (x::VarExpr).name == o && d <= length(gouts)) || continue
            set = _lane_range_set(get(_ranges_dict(G), gouts[d], nothing))
            set === nothing || push!(out, set)
            G.expr_body === nothing || _range_subscript_sets!(out, G.expr_body, gouts[d], axes)
        end
    end
    for c in E.args
        _range_subscript_sets!(out, c, o, axes)
    end
    for c in (E.lower, E.upper, E.expr_body, E.filter)
        c === nothing || _range_subscript_sets!(out, c, o, axes)
    end
    E.values === nothing || foreach(c -> _range_subscript_sets!(out, c, o, axes), E.values)
    return out
end

"""
    _range_promote_model(spec::_LaneSpec, model, index_sets) -> model

Before a lane build classifies its variables, in every lane build (an
out-of-place fragment's, and for observeds free of `t`, too, since one that
reads the state has no whole-domain form), the interval `faq` observeds'
axes take index-set names ([`_range_name_faq_axes`](@ref)). Then, in a build
with a time per lane: every 0-d observed that depends
on `t` (through any observeds) becomes one value per lane, an array observed
over the first lane set whose definition is an array `faq` over it with the
0-d body, so a lane program computes it once per lane at the lane's own time.
The lane rewrite reads it at the lane index wherever the 0-d name is read
([`_lane_rewrite`](@ref)), so every position a 0-d observed can be read in is
read per lane, and each lane equals the whole-domain program bit for bit.

A 0-d observed read by a definition the lane rewrite does not reach (an array
observed with no lane set, or another 0-d observed that stays 0-d) stays 0-d.
It, and every array observed with no lane set that depends on `t`, is
evaluated once per call at one time; they are recorded in `spec.tshared`
(those the state equations read), and a call at mixed times refuses them.
"""
function _range_promote_model(spec::_LaneSpec, model, index_sets = Dict{String, IndexSet}())
    model = _range_name_faq_axes(spec, model, index_sets)
    spec.tbuf === nothing && return model
    defs = Dict{String, ASTExpr}()
    for eq in model.equations
        eq.lhs isa VarExpr && (defs[(eq.lhs::VarExpr).name] = eq.rhs)
    end
    tdep = _range_time_dependent(defs)
    shape(n) = (v = get(model.variables, n, nothing); v === nothing ? nothing : v.shape)
    laned(n) = !(n in spec.whole) &&
        (s = shape(n); _is_array_shape(s) && any(x -> String(x) in spec.sets, s))
    P = Set{String}(n for n in tdep if !_is_array_shape(shape(n)))
    # Only a lane-rewritten definition has a lane index to read one at.
    changed = true
    while changed
        changed = false
        for (n, d) in defs
            (n in P || laned(n)) && continue
            for r in _referenced_var_names(d)
                r in P && (delete!(P, r); changed = true)
            end
        end
    end
    # The observeds the state equations read, through other observeds.
    reach = Set{String}()
    stack = String[]
    for eq in model.equations
        eq.lhs isa VarExpr || append!(stack, _referenced_var_names(eq.rhs))
    end
    while !isempty(stack)
        n = pop!(stack)
        (n in reach || !haskey(defs, n)) && continue
        push!(reach, n)
        append!(stack, _referenced_var_names(defs[n]))
    end
    spec.tshared = sort!([n for n in tdep if n in reach && !(n in P) && !laned(n)])
    spec.tnames = union!(Set{String}(["t"]), tdep)
    isempty(P) && return model
    spec.promoted = P
    L1 = spec.sets[1]
    vars = copy(model.variables)
    for n in P
        vars[n] = reconstruct(model.variables[n]; shape = [L1])
    end
    # An `ic` right-hand side that reads a promoted observed, directly or
    # through other observeds, would read it as a scalar at the start of the
    # run; a lane program has no use for the initial state (the caller fills
    # every lane block), so such an `ic` is left out of the lane build.
    reads_P = Set{String}(P)
    grew = true
    while grew
        grew = false
        for (n, d) in defs
            n in reads_P && continue
            if _anyof(in(reads_P), _referenced_var_names(d))
                push!(reads_P, n)
                grew = true
            end
        end
    end
    is_ic(eq) = eq.lhs isa OpExpr && (eq.lhs::OpExpr).op == "ic"
    eqs = Equation[]
    for eq in model.equations
        if is_ic(eq) && _anyof(in(reads_P), _referenced_var_names(eq.rhs))
            continue
        elseif eq.lhs isa VarExpr && (eq.lhs::VarExpr).name in P
            F = OpExpr(
                "faq", ASTExpr[]; output_idx = Any[_LANE_PROMOTED_IDX],
                ranges = Dict{String, Any}(_LANE_PROMOTED_IDX => IndexSetRef(L1)),
                expr_body = eq.rhs
            )
            push!(eqs, Equation(eq.lhs, F; _comment = eq._comment))
        else
            push!(eqs, eq)
        end
    end
    return reconstruct(model; variables = vars, equations = eqs)
end

# The loop variable of a promoted observed's definition.
const _LANE_PROMOTED_IDX = "__lane_i"

# The observeds (any shape) whose definitions depend on `t`, directly or
# through other observeds.
function _range_time_dependent(defs::Dict{String, ASTExpr})
    memo = Dict{String, Bool}()
    function tdep(n, seen)
        haskey(memo, n) && return memo[n]
        n in seen && return false
        push!(seen, n)
        r = _anyof(
            x -> x == "t" || (haskey(defs, x) && tdep(x, seen)),
            _referenced_var_names(defs[n])
        )
        memo[n] = r
        return r
    end
    return Set{String}(n for n in keys(defs) if tdep(n, Set{String}()))
end

# Whether the hoist pass (tree_walk/hoist.jl) keeps a nested reduction with
# free names `free` in place rather than lift it over the sets `sets`: in a
# lane build with a time per lane, one that depends on `t` and would land on no
# lane set, which the lane program would evaluate once per call at one time.
_range_hoist_keep(spec, free, sets) = false
_range_hoist_keep(spec::_LaneSpec, free, sets) =
    !isempty(spec.tnames) && any(in(spec.tnames), free) && !any(in(spec.sets), sets)


# `index(makearray(regions, values), subs…)` as region membership:
# `ifelse(in_k, value_k at subs, …ifelse(in_1, value_1 at subs, 0))`, the last
# region holding the element winning (esm-spec §4.3.2). The regions must start
# at 1 along every axis (the Rust binding reads a makearray relative to where
# its regions start, this one at the absolute subscript; at 1 both agree). A
# region value is a scalar expression (the same at every element) or an array
# `faq` whose output indices span either every dimension of its region or only
# its non-singleton ones, each over a unit stride range exactly as long as its
# region dimension; it is read at `sub − lo + start` on each dimension it
# spans. A `faq` value carrying `args`, `key`, `join` or `distinct`, one whose
# contraction runs over a set of an output index, and one whose contraction
# (or any nested binder) would capture a subscript are refused. Inside a
# region one cell thick along a lane set (`lo == hi`), the lane's coordinate
# there is `lo`, so a read of a lane array at the literal `lo` on that axis is
# written as the read at the lane's own subscript (a lane reads a state only
# at its own cell). The Rust binding lowers the same way.
function _lane_membership_read(spec::_LaneSpec, ctx, ma::OpExpr, subs, sc, rule::String)
    all_bounds = Vector{Tuple{Int, Int}}[]
    for region in ma.regions
        length(region) == length(subs) || _lane_refuse(rule, "a makearray is read at the wrong rank")
        bounds = Tuple{Int, Int}[]
        for r in region
            lo = _region_int(ctx.need, r[1]); hi = _region_int(ctx.need, r[2])
            (lo isa Integer && hi isa Integer) || _lane_refuse(rule, "a makearray has a symbolic region bound")
            push!(bounds, (Int(lo), Int(hi)))
        end
        push!(all_bounds, bounds)
    end
    for d in eachindex(subs)
        isempty(all_bounds) || minimum(b[d][1] for b in all_bounds) == 1 ||
            _lane_refuse(rule, "a makearray's regions do not start at 1")
    end
    # The names the subscripts mention: a binder of one of them in a region
    # value would capture the subscript once it is substituted in.
    sub_names = Set{String}()
    for s in subs
        union!(sub_names, free_variables(s))
    end
    out = NumExpr(0.0)
    for (bounds, value) in zip(all_bounds, ma.values)
        conds = ASTExpr[]
        for (s, (lo, hi)) in zip(subs, bounds)
            if lo == hi
                push!(conds, OpExpr("==", ASTExpr[s, IntExpr(lo)]))
            else
                push!(conds, OpExpr(">=", ASTExpr[s, IntExpr(lo)]))
                push!(conds, OpExpr("<=", ASTExpr[s, IntExpr(hi)]))
            end
        end
        v = value
        read = if v isa OpExpr && _is_faq_op((v::OpExpr).op) && _lane_array_faq(v::OpExpr)
            _lane_faq_fields_ok(v::OpExpr) ||
                _lane_refuse(rule, "a faq region value " * _LANE_FAQ_FIELDS_REFUSAL)
            outs = _output_idx_strings(v)
            dims = length(outs) == length(bounds) ? collect(eachindex(bounds)) :
                [d for d in eachindex(bounds) if bounds[d][1] != bounds[d][2]]
            length(dims) == length(outs) || _lane_refuse(rule, "a faq region value does not fit its region")
            # The value's element at the read: its body with each output
            # index renamed to the subscript, shifted onto the value's own
            # range (`sub - lo + start`). Each output range must be exactly as
            # long as its region dimension, so the shifted subscript stays
            # inside it.
            renames = Dict{String, ASTExpr}()
            for (o, d) in zip(outs, dims)
                lo, hi = bounds[d]
                r = get(v.ranges, o, nothing)
                b = r === nothing ? nothing : _lane_range_bounds(spec, r)
                b === nothing && _lane_refuse(
                    rule, "a faq region value's axis '$o' does not run over a unit stride range"
                )
                b[2] - b[1] == hi - lo || _lane_refuse(
                    rule, "a faq region value's axis '$o' does not run over its region $lo..$hi"
                )
                shift = b[1] - lo
                renames[o] = shift == 0 ? subs[d] : OpExpr("+", ASTExpr[subs[d], IntExpr(shift)])
            end
            contracted = Dict{String, Any}(String(k) => x for (k, x) in v.ranges if !(String(k) in outs))
            any(k -> k in sub_names, keys(contracted)) &&
                _lane_refuse(rule, "a faq region value's contraction rebinds a subscript")
            for r in values(contracted)
                of = r isa IndexSetRef ? r.of :
                    (r isa AbstractDict ? something(get(r, "of", nothing), String[]) : String[])
                any(p -> String(p) in outs, of) && _lane_refuse(
                    rule, "a faq region value's contraction runs over a set of one of its output indices"
                )
            end
            body = _lane_rename(v.expr_body, renames, rule)
            if isempty(contracted) && v.filter === nothing
                body
            else
                filt = v.filter === nothing ? nothing : _lane_rename(v.filter, renames, rule)
                reconstruct(v; output_idx = Any[], ranges = contracted, expr_body = body, filter = filt)
            end
        elseif v isa OpExpr && (_is_faq_op((v::OpExpr).op) || _index_target_kind(v) === _IT_MAKEARRAY)
            _lane_refuse(rule, "a makearray holds an array region value a lane cannot read")
        else
            v
        end
        # Retargeted after the rename, so a subscript it writes in is not
        # renamed again.
        thin = Tuple{String, Int, ASTExpr}[]
        for (d, s) in enumerate(subs)
            set = s isa VarExpr ? get(sc.lanevars, (s::VarExpr).name, nothing) : nothing
            set !== nothing && bounds[d][1] == bounds[d][2] && push!(thin, (set, bounds[d][1], s))
        end
        isempty(thin) || (read = _lane_retarget_thin(spec, read, thin, Set{String}(), rule))
        cond = length(conds) == 1 ? conds[1] : OpExpr("and", conds)
        out = OpExpr("ifelse", ASTExpr[cond, read, out])
    end
    return out
end

# `e` with every lane-array read at the literal `lo` of a `thin` entry on an
# axis of its lane set read at that entry's subscript instead
# (`_lane_membership_read`). `bound` holds the names the binders enclosing `e`
# bind; writing a subscript in under a binder of its name would capture it,
# which is refused.
function _lane_retarget_thin(spec::_LaneSpec, e::ASTExpr, thin, bound::Set{String}, rule::String)
    e isa OpExpr || return e
    bs = _bound_symbols(e::OpExpr)
    inner = isempty(bs) ? bound : union(bound, Set{String}(String(b) for b in bs))
    o = map_children(c -> _lane_retarget_thin(spec, c, thin, inner, rule), e)
    if o.op == "index" && !isempty(o.args) && o.args[1] isa VarExpr
        n = (o.args[1]::VarExpr).name
        sh = haskey(spec.shapes, n) ? spec.shapes[n] : get(spec.obs_shapes, n, nothing)
        if sh !== nothing && length(sh) == length(o.args) - 1
            args = copy(o.args)
            changed = false
            for (p, set) in enumerate(sh)
                a = args[p + 1]
                k = a isa IntExpr ? Int(a.value) : a isa Integer ? Int(a) : nothing
                k === nothing && continue
                i = findfirst(x -> x[1] == set && x[2] == k, thin)
                i === nothing && continue
                any(in(bound), free_variables(thin[i][3])) && _lane_refuse(
                    rule, "a region value's binder would capture a lane subscript"
                )
                args[p + 1] = thin[i][3]
                changed = true
            end
            changed && return reconstruct(o; args = args)
        end
    end
    return o
end
