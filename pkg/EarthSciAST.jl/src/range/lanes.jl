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
# lane set to that set; `first` is the variable carrying the lane index.
struct _LaneScope
    lanevars::Dict{String, String}
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
    if _is_faq_op(o.op) && o.ranges !== nothing
        for k in keys(o.ranges)
            haskey(sc.lanevars, String(k)) && _lane_refuse(
                rule,
                "an aggregate rebinds the lane index '$k'"
            )
        end
    end
    return map_children(x -> _lane_rewrite(spec, ctx, x, sc, rule), o)
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
                !(haskey(ctx.arrays, r) && !(r in ctx.livein))
        ]
        if !isempty(lane) && isempty(other)
            k = length(spec.gathers) + 1
            buf = zeros(spec.C)
            push!(
                spec.gathers, _LaneGather(
                    buf, ctx.arrays[n], collect(Int, size(ctx.arrays[n])), n, subs,
                    [r => findfirst(==(sc.lanevars[r]), spec.sets) for r in lane], ctx.arrays
                )
            )
            ctx.live["__lane_in_$k"] = buf
            return OpExpr("index", ASTExpr[VarExpr("__lane_in_$k"), VarExpr(sc.first)])
        end
    end
    if _index_target_kind(target) === _IT_MAKEARRAY
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
                (lo == 1 && hi == get(spec.ext, set, -1)) || _lane_refuse(
                    rule,
                    "a region boundary along the lane set '$set' depends on the cell"
                )
                r = (s::VarExpr).name == sc.first ? (1:spec.C) : (1:1)
                push!(nr, Any[first(r), last(r)])
            end
            push!(regions, nr)
        end
        vals = ASTExpr[_lane_rewrite(spec, ctx, v, sc, rule) for v in ma.values]
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
    if target isa OpExpr && _is_array_producer(target)
        _lane_refuse(rule, "an array producer is indexed inside the lane scope")
    end
    return reconstruct(o; args = ASTExpr[_lane_rewrite(spec, ctx, a, sc, rule) for a in o.args])
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
    return _LaneScope(lanevars, first), newr
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

function _lanes(op::RhsProgram, kind::Symbol, sets, chunk::Int; form = :inplace)
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
    lane_bufs = vcat(inst.index_bufs, Vector{Float64}[g.buf for g in inst.gathers])
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
        )
    )
end

# One compiled lane program: its right-hand side, the live lane buffers it
# reads, its gathers and its build's forcing epoch.
function _lane_instance(op::RhsProgram, kind::Symbol, S::Vector{String}, chunk::Int; form = :inplace)
    index_bufs = Dict{String, Vector{Float64}}(s => zeros(chunk) for s in S)
    spec = _LaneSpec(
        kind, S, chunk, _array_shapes(op), index_bufs, _LaneGather[],
        Set{String}(), Dict{String, Vector{String}}(), Dict{String, Int}(),
        _program_sets(op)
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
        gathers = spec.gathers, params = spec.params, cap, pa,
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
        aux::AbstractVector, p, t, fs::ForcingSet, cells::AbstractMatrix, n::Integer
    )
    L = _lane_check(lp, ws, du, u, aux, p, cells, n)
    _prime!(ws, fs)
    C = lp.C
    env = ws.env
    ni = length(lp.index_bufs)
    lb = ws.lbufs
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
        end
        _lane_chunk!(du, lp, ws, u, aux, p, t, L, s0, m)
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
        end
        _lane_chunk!(du, lp, ws, u, aux, p, t, L, s0, m)
    end
    return du
end
