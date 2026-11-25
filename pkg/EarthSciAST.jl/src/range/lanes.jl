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
    ucopy::Vector{_LaneCopy}
    acopy::Vector{_LaneCopy}
    params::Dict{String, Int}
    shared::_RhsShared
    # The live buffer of each lane's time (U19), the last lane buffer of a
    # workspace; `nothing` when the program reads no per-lane time.
    tbuf::Union{Nothing, Vector{Float64}}
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
    env::Dict{String, Int}           # a gather's subscript bindings
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
end

_lane_refuse(rule, why) = _refuse_rule(_rule_display(rule), "lane: $why")

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
        # U19: the time is the lane's own.
        n == "t" && spec.tbuf !== nothing &&
            return OpExpr("index", ASTExpr[VarExpr("__lane_t"), VarExpr(sc.first)])
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
    # `args` and `key` are scoped to the node itself; the body alone moves.
    (isempty(F.args) && F.key === nothing) ||
        _lane_refuse(rule, "an array faq read inside the lane scope carries `args` or `key`")
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
            rb !== nothing && sr !== nothing && _lane_range_bounds(spec, sr) == rb
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
            ((v::VarExpr).name in bound) || continue
            free === nothing && (free = free_variables(o))
            k in free && _lane_refuse(
                rule, "a nested aggregate binds '$((v::VarExpr).name)', which an array " *
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
            body = _lane_rewrite(spec, ctx, R.expr_body, sc, n)
            filt = R.filter === nothing ? nothing : _lane_rewrite(spec, ctx, R.filter, sc, n)
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
    return LaneProgram(
        op, S, chunk, inst.f!, internal, layout, inst.index_bufs,
        inst.gathers, gslots, uplan, aplan, inst.params,
        _derived_shared(
            op.shared, inst.f!, length(internal), inst.cap,
            inst.pa, lane_bufs
        ), inst.tbuf
    )
end

# One compiled lane program: its right-hand side, the live lane buffers it
# reads, its gathers and its build's forcing epoch.
function _lane_instance(op::RhsProgram, kind::Symbol, S::Vector{String}, chunk::Int; form = :inplace)
    index_bufs = Dict{String, Vector{Float64}}(s => zeros(chunk) for s in S)
    tbuf = form === :oop ? nothing : zeros(chunk)
    spec = _LaneSpec(
        kind, S, chunk, _array_shapes(op), index_bufs, _LaneGather[],
        Set{String}(), Dict{String, Vector{String}}(), Dict{String, Int}(),
        _program_sets(op), form === :oop, tbuf
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
    f!, _u0, _p, _ts, internal = _with_ws_capture(cap) do
        _with_compiler_plan(_plan(op.compiler)) do
            _with_range_spec(spec) do
                _build_selected(file, model_name, opts)
            end
        end
    end
    return (;
        f!, internal, index_bufs = Vector{Float64}[index_bufs[s] for s in S],
        gathers = spec.gathers, params = spec.params, cap, pa, tbuf,
    )
end

"""
    lane_layout(lanes::LaneProgram) -> LaneLayout

The `u`/`aux` lane layout (API_SPEC §5.8, "Lanes"): element `e` of variable `v`
for lane `l` of an `L`-lane batch is at slot `(offset_v + e - 1)·L + l`.
"""
lane_layout(lp::LaneProgram) = lp.layout

parameters(lp::LaneProgram) = lp.shared.params

function rhs_workspace(lp::LaneProgram)
    ws = _instantiate(lp.shared)
    merge!(ws.env, lp.params)
    return ws
end

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
    Base.RefValue{Union{Nothing, ForcingSet}}(nothing), lp.shared,
    Dict{String, Int}(lp.params)
)

# Pre-gathered input `k` at the cell of lane `l` of `cells`, stored into
# `buf[c]`: read from the call's forcing buffer, or from const data.
function _lane_gather!(
        buf::Vector{Float64}, c::Int, lp::LaneProgram, k::Int, fs::ForcingSet,
        cells::AbstractMatrix, l::Int, env::Dict{String, Int}
    )
    g = lp.gathers[k]
    slot = lp.gather_slots[k]
    if slot == 0
        _lane_gather_store!(buf, c, g, g.src, cells, l, env)
    else
        _lane_gather_store!(buf, c, g, fs.bufs[slot], cells, l, env)
    end
    return nothing
end

# A barrier: `src`'s concrete type is known inside, so the read does not box.
function _lane_gather_store!(
        buf::Vector{Float64}, c::Int, g::_LaneGather, src::A,
        cells::AbstractMatrix, l::Int, env::Dict{String, Int}
    ) where {A}
    @inbounds buf[c] = _lane_gather_value(g, src, cells, l, env)
    return nothing
end

# The value of pre-gathered input `g` (read from `src`, linear over `g.src`'s
# shape) at the cell of lane `l` of `cells`.
function _lane_gather_value(
        g::_LaneGather, src::AbstractArray, cells::AbstractMatrix, l::Int,
        env::Dict{String, Int}
    )
    for (v, row) in g.vars
        env[v] = Int(cells[row, l])
    end
    shp = g.src
    lin = 0
    stride = 1
    for d in eachindex(g.subs)
        i = _eval_const_int(g.subs[d], env, g.consts)::Int
        n = g.dims[d]
        if !(1 <= i <= n)
            i = try
                _resolve_const_index(shp, g.name, d, i, n)
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
    li.fs[] = nothing
    env = li.env
    for l in 1:L
        src = min(l, Int(n))
        for k in eachindex(li.index)
            li.index[k][l] = Float64(cells[k, src])
        end
        for k in eachindex(lp.gathers)
            _lane_gather!(li.gathered[k], l, lp, k, fs, cells, src, env)
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
    # The lane buffers changed under the TIME tier's stamps.
    _bump_workspace_epochs!(ws)
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
# `tof(l)`; a padding lane copies an active lane's inputs and time.
function _lane_rhs!(du, lp::LaneProgram, ws::RhsWorkspace, u, aux, p, tof::F, fs::ForcingSet, cells, n, L) where {F}
    _prime!(ws, fs)
    C = lp.C
    env = ws.env
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
            for k in eachindex(lp.gathers)
                _lane_gather!(lb[ni + k], c, lp, k, fs, cells, l, env)
            end
            tb === nothing || (tb[c] = tof(l))
        end
        _lane_chunk!(du, lp, ws, u, aux, p, tof(s0 + 1), L, s0, m)
    end
    return du
end

function rhs!(
        du::AbstractVector, lp::LaneProgram, ws::RhsWorkspace, u::AbstractVector,
        aux::AbstractVector, p, t, li::LaneInputs, cells::AbstractMatrix, n::Integer
    )
    L = _lane_check(lp, ws, du, u, aux, p, cells, n)
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
            lp.tbuf === nothing || (lb[end][c] = Float64(t))
        end
        _lane_chunk!(du, lp, ws, u, aux, p, t, L, s0, m)
    end
    return du
end

"""
    rhs!(du, lanes::LaneProgram, ws, u, aux, p, ts::AbstractVector, fs::ForcingSet, cells, n) -> du

Each lane at its own time (U19): lane `l ≤ n` evaluates at `ts[l]`, and its
value equals the whole-domain program's at `cells[:, l]` and time `ts[l]`,
bit for bit, whatever the other lanes' times. `ts` holds at least `n` times.

One pass over the batch, whatever its times: the lane program reads `t` from a
lane buffer of times, and every 0-d observed that depends on `t` is computed
per lane ([`_range_promote_model`](@ref)). With equal times the call equals
the one-time call.
"""
function rhs!(
        du::AbstractVector, lp::LaneProgram, ws::RhsWorkspace, u::AbstractVector,
        aux::AbstractVector, p, ts::AbstractVector{<:Real}, fs::ForcingSet,
        cells::AbstractMatrix, n::Integer
    )
    L = _lane_check(lp, ws, du, u, aux, p, cells, n)
    length(ts) >= n || throw(
        DimensionMismatch("rhs!: $(length(ts)) times for n = $n lanes")
    )
    lp.tbuf === nothing && throw(
        ArgumentError("rhs!: this lane program was built without a time per lane")
    )
    return _lane_rhs!(du, lp, ws, u, aux, p, l -> Float64(ts[l]), fs, cells, n, L)
end

# ---------------------------------------------------------------------------
# A time per lane (U19): 0-d observeds of `t` computed per lane.

_range_promote_model(spec, model) = model

"""
    _range_promote_model(spec::_LaneSpec, model) -> model

Before a lane build classifies its variables: every 0-d observed that depends
on `t`, directly or through other such observeds, becomes an array observed
over the shape of the written states (the lane sets and any others), each
element its 0-d value, so a lane program computes it per lane at the lane's
own time. Its definition becomes an array `faq` over that shape, and every
read of it inside an array `faq` over that shape (a state equation, a band
field) the read at that `faq`'s output indices. The values are the 0-d
observed's, so each lane equals the whole-domain program bit for bit.
"""
function _range_promote_model(spec::_LaneSpec, model)
    spec.tbuf === nothing && return model
    # The written states' shape: the first array state carrying every lane set.
    S = nothing
    for n in sort!(collect(keys(spec.shapes)))
        sh = spec.shapes[n]
        all(x -> x in sh, spec.sets) && (S = sh; break)
    end
    S === nothing && return model
    all(x -> haskey(spec.ext, x), S) || return model
    defs = Dict{String, ASTExpr}()
    for eq in model.equations
        eq.lhs isa VarExpr && (defs[(eq.lhs::VarExpr).name] = eq.rhs)
    end
    scalar(n) = (v = get(model.variables, n, nothing); v !== nothing && !_is_array_shape(v.shape))
    memo = Dict{String, Bool}()
    function tdep(n, seen = Set{String}())
        haskey(memo, n) && return memo[n]
        n in seen && return false
        push!(seen, n)
        r = _anyof(x -> x == "t" || (haskey(defs, x) && scalar(x) && tdep(x, seen)), _referenced_var_names(defs[n]))
        memo[n] = r
        return r
    end
    P = Set{String}(n for n in keys(defs) if scalar(n) && tdep(n))
    isempty(P) && return model
    outs = ["__lt$d" for d in eachindex(S)]
    sizes = [spec.ext[x] for x in S]
    vars = copy(model.variables)
    for n in P
        vars[n] = reconstruct(model.variables[n]; shape = copy(S))
    end
    eqs = Equation[]
    for eq in model.equations
        if eq.lhs isa VarExpr && (eq.lhs::VarExpr).name in P
            body = _promote_reads(eq.rhs, P, outs)
            F = OpExpr(
                "faq", ASTExpr[]; output_idx = Any[outs...],
                ranges = Dict{String, Any}(o => Any[1, k] for (o, k) in zip(outs, sizes)),
                expr_body = body
            )
            push!(eqs, Equation(eq.lhs, F; _comment = eq._comment))
        else
            push!(eqs, Equation(eq.lhs, _promote_in_faqs(eq.rhs, P, S, sizes), _comment = eq._comment))
        end
    end
    return reconstruct(model; variables = vars, equations = eqs)
end

# Every bare read of a promoted observed in `e`, with `outs` bound, as its
# read at `outs`.
function _promote_reads(e, P, outs)
    if e isa VarExpr
        return (e::VarExpr).name in P ? OpExpr("index", ASTExpr[e, (VarExpr(o) for o in outs)...]) : e
    end
    e isa OpExpr || return e
    o = e::OpExpr
    if o.op == "index" && !isempty(o.args) && o.args[1] isa VarExpr && (o.args[1]::VarExpr).name in P
        return reconstruct(o; args = ASTExpr[o.args[1], (_promote_reads(a, P, outs) for a in o.args[2:end])...])
    end
    return map_children(x -> _promote_reads(x, P, outs), o)
end

# Whether a `faq`'s output axes run over the whole of the shape `S`.
function _promote_faq_matches(o::OpExpr, S, sizes)
    outs = _output_idx_strings(o)
    length(outs) == length(S) || return false
    for (d, x) in enumerate(outs)
        r = get(o.ranges, x, nothing)
        if r isa IndexSetRef
            (r.from == S[d] && isempty(r.of)) || return false
        elseif r isa AbstractDict && haskey(r, "from")
            r["from"] == S[d] || return false
        elseif r isa AbstractVector && length(r) == 2
            lo = r[1] isa Integer ? Int(r[1]) : r[1] isa IntExpr ? (r[1]::IntExpr).value : nothing
            hi = r[2] isa Integer ? Int(r[2]) : r[2] isa IntExpr ? (r[2]::IntExpr).value : nothing
            (lo == 1 && hi == sizes[d]) || return false
        else
            return false
        end
    end
    return true
end

# The reads of promoted observeds inside every array `faq` over `S` in `e`.
function _promote_in_faqs(e, P, S, sizes)
    e isa OpExpr || return e
    o = e::OpExpr
    if _is_faq_op(o.op) && o.ranges !== nothing && _promote_faq_matches(o, S, sizes)
        return _promote_reads(o, P, _output_idx_strings(o))
    end
    return map_children(x -> _promote_in_faqs(x, P, S, sizes), o)
end
