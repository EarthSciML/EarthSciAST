# Need-box analysis (API_SPEC §5.8, "Halo report" and tile rules 1–3).

#

#
# An abstract interpretation of the equation stream the build compiles (the
# `parts` the range seam receives: nested reductions hoisted, index-set
# ranges resolved; a template reference is read through its instance's body,
# never expanded — see "Reading through template references" below). Every loop variable is bound to the set
# of global cells it ranges over (`_Bind`); a subscript's image is computed by
# evaluating it with `_eval_const_int` over those cells, the function the
# compiler itself resolves a subscript with, so an affine offset, a `mod` wrap
# and an explicit wrap (`f[NLON-1]`) are all just images. A variable aligned
# with a cut axis also carries its offset interval relative to the output cell
# that (transitively) reads it, which is what the halo report is made of.

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
    return _Bind(
        _iset_union(a.cells, b.cells), isempty(a.axis) ? b.axis : a.axis,
        lo, hi, a.contracted || b.contracted, a.runtime || b.runtime
    )
end

# The cut axes of a decomposition, measured against the program.
struct _AxisModel
    cut::Dict{String, Tuple{String, Bool}}      # index set → (cut axis, is a face set)
    N::Dict{String, Int}                       # cut axis → its cell extent
    period::Dict{String, Union{Nothing, Int}}   # cut axis → period
end

_axis_domain(m::_AxisModel, axis::String, face::Bool) = 1:(m.N[axis] + (face ? 1 : 0))

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
    owned::Dict{String, UnitRange{Int}}        # cut axis → owned cells (tile)
    storage::Dict{String, UnitRange{Int}}      # cut axis → storage cells (tile)
    shapes::Dict{String, Vector{String}}       # array variable → index sets
    extents::Dict{String, Vector{Int}}         # array variable → extents
    states::Set{String}                       # array states
    obs_defs::Dict{String, ASTExpr}            # array observeds
    scalar_defs::Dict{String, ASTExpr}         # scalar observeds
    mat_obs::Set{String}
    params::Dict{String, Int}                  # integer-valued scalar parameters
    const_arrays::AbstractDict
    arrays::Set{String}                       # every non-state array name (const, live)
    reach::Dict{Tuple{String, String}, Tuple{Int, Int}}
    reads::Set{String}
    obs_need::Dict{String, Vector{_Bind}}
    work::Vector{String}
    scalar_stack::Set{String}
    # Seam crossings (tile mode): `(axis, face)` → its seam; the walk's current
    # context (`("", ())` for the state equations, `(observed, sides)` for an
    # observed evaluated on one side of each seam it crosses); the `index`
    # nodes being walked; and, per such node, per (variable, context), which
    # sides of each seam its reads land on (bit 1 near, bit 2 far).
    seams::Dict{Tuple{String, Bool}, _Seam}
    tag::Tuple{String, Tuple}
    idx_stack::Vector{Any}
    marks::IdDict{Any, Dict{Tuple{String, Tuple{String, Tuple}}, Vector{UInt8}}}
    # Template references (esm-spec §9.6.4 rule 2): the build's template table
    # (`nothing` when its model holds no reference) and the instance whose
    # body the walk is in (`nothing` in the equations themselves).
    tt::Any
    scope::Any
    # Reads inside template bodies that land on one side of a seam: per
    # (chain, node), where `chain` is the references the walk entered to
    # reach the body, outermost first (each the reference node as the walk
    # read it), and `node` the body's `index` node, as `marks` holds the
    # caller's reads. A body is shared by every use of its instance, so a read
    # past the seam is served by a seam instance of the body made for that
    # chain (tile.jl, "Reads past a periodic seam inside a template body").
    bmarks::Dict{Tuple{Vector{UInt}, UInt}, Tuple{Vector{Any}, Any, Dict{Tuple{String, Tuple{String, Tuple}}, Vector{UInt8}}}}
end

_NeedCtx(
    mode, axes, owned, storage, shapes, extents, states, obs_defs,
    scalar_defs, mat_obs, params, const_arrays, arrays, reach, reads, obs_need, work,
    scalar_stack
) =
    _NeedCtx(
    mode, axes, owned, storage, shapes, extents, states, obs_defs,
    scalar_defs, mat_obs, params, const_arrays, arrays, reach, reads, obs_need,
    work, scalar_stack, Dict{Tuple{String, Bool}, _Seam}(), ("", ()),
    Any[], IdDict{Any, Dict{Tuple{String, Tuple{String, Tuple}}, Vector{UInt8}}}(),
    _build_templates(), nothing,
    Dict{Tuple{Vector{UInt}, UInt}, Tuple{Vector{Any}, Any, Dict{Tuple{String, Tuple{String, Tuple}}, Vector{UInt8}}}}()
)

# ---- Reading through template references ----
#
# A reference denotes its expansion, and the walk reads it as such without
# building it: at a reference it walks the body the build compiles for that
# instance (templates/frames.jl `_tpl_frame`; with the call's lanes, call.jl
# `_call_hoist_plan`, so a read the caller makes is walked where the caller
# makes it, as the tree node the seam rewrite can reach), and at a parameter
# of the body it walks the call site's binding in the caller's scope. The loop
# bindings `env` are those of the expansion at that point (a binding is read
# under the binders the body has open there, as the expansion substitutes it),
# so a subscript is evaluated as its expansion would be: grounded to the
# caller's spelling (`_need_ground`), a small expression, never a body.

# One instance being walked: its frame, the reference, the caller's scope.
struct _NeedScope
    fr::_TplFrame
    call::OpExpr
    up::Union{Nothing, _NeedScope}
end

_need_is_arg(n::AbstractString) = startswith(n, _TPL_ARG) || startswith(n, _TPL_FREE) ||
    startswith(n, _TPL_LANE) || startswith(n, _TPL_OUT)

# The binding of the body argument `n` of scope `sc` (read in `sc.up`).
function _need_arg(sc::_NeedScope, n::String)
    b = sc.call.bindings
    if startswith(n, _TPL_ARG)
        v = b === nothing ? nothing : get(b, n[(ncodeunits(_TPL_ARG) + 1):end], nothing)
        v === nothing && (v = _tpl_arg(sc.fr, n)[1])
        return v, sc.up
    elseif startswith(n, _TPL_FREE)
        v = b === nothing ? nothing : get(b, n, nothing)
        return (v === nothing ? VarExpr(n[(ncodeunits(_TPL_FREE) + 1):end]) : v), sc.up
    end
    v = b === nothing ? nothing : get(b, n, nothing)
    v === nothing && throw(
        TreeWalkError(
            "E_TREEWALK_UNBOUND_VARIABLE",
            "template '$(sc.fr.name)': no binding for $(repr(n))"
        )
    )
    return v, sc.up
end

# The references the walk entered to reach scope `sc`, outermost first.
function _need_chain(sc::_NeedScope)
    out = Any[]
    s = sc
    while s !== nothing
        push!(out, s.call)
        s = s.up
    end
    return reverse!(out)
end

# Run `f()` with the walk in scope `sc`.
function _need_in(f, ctx, sc)
    old = ctx.scope
    ctx.scope = sc
    try
        return f()
    finally
        ctx.scope = old
    end
end

# `e`, read in the walk's scope, with every body argument replaced by its
# binding (grounded in turn): the expression as the caller spells it. For a
# subscript or a range bound only.
_need_ground(ctx::_NeedCtx, e) = ctx.scope === nothing ? e : _need_ground(e, ctx.scope)
_need_ground(e, ::Nothing) = e
function _need_ground(e, sc::_NeedScope)
    if e isa VarExpr
        _need_is_arg(e.name) || return e
        b, up = _need_arg(sc, e.name)
        return _need_ground(b, up)
    end
    e isa OpExpr || return e
    return map_children(c -> _need_ground(c, sc), e)
end

# The body the walk reads for the reference `o` in the walk's scope, its
# scope, and whether it is an element call read through its whole array
# body (`:whole`, the element subscripts its `"\0out\0"` bindings) or a body
# read as it stands (`:body`); `nothing` when the reference cannot be read
# (no table, or a template the template checks report).
function _need_enter(ctx::_NeedCtx, o::OpExpr)
    tt = ctx.tt
    tt === nothing && return nothing
    parent = ctx.scope === nothing ? nothing : (ctx.scope::_NeedScope).fr
    fr = _tpl_frame_or_nothing(tt, o, parent)
    fr === nothing && return nothing
    sc = _NeedScope(fr, o, ctx.scope)
    if _call_has_lanes(o)
        info = _tpl_call_info(tt, o.name)
        if info !== nothing
            S = _call_fixed!(Dict{String, Any}(), o.name, info, o.bindings)
            hp = _call_hoist_plan(tt, _tpl_def(tt, o.name), S, _call_outs(info, o))
            return hp.body, sc, :body
        end
    end
    return fr.body, sc, (_tpl_is_elem(o) ? :whole : :body)
end

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
    node, sc = isempty(ctx.idx_stack) ? (nothing, nothing) : ctx.idx_stack[end]
    d = if sc === nothing
        get!(() -> Dict{Tuple{String, Tuple{String, Tuple}}, Vector{UInt8}}(), ctx.marks, node)
    else
        # A read a template body makes: recorded for the chain of references
        # that reached the body (the body is shared; the chain is this use).
        chain = _need_chain(sc::_NeedScope)
        k = (UInt[objectid(c) for c in chain], objectid(node))
        get!(ctx.bmarks, k) do
            (chain, node, Dict{Tuple{String, Tuple{String, Tuple}}, Vector{UInt8}}())
        end[3]
    end
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
    # An array argument computed for a call in its equation (call.jl
    # `_hoist_array_arguments`); any other lifted name is a nested reduction.
    m = match(_HOIST_LABEL_RE, s)
    m !== nothing && m[1] == _ARGARR_KIND &&
        return string(parts[end], " (an array argument of a call in it, computed before the call)")
    return string(parts[end], " (a nested reduction lifted out of it)")
end

_global_locality(rule, axis, why) = _range_error(
    ERROR_CODES.RANGE_GLOBAL_LOCALITY,
    "rule '$(_rule_display(rule))' has global locality along the decomposed index set " *
        "'$axis': $why. A tile cannot evaluate it; keep this operator whole-domain " *
        "(API_SPEC §5.8, decision 8)"
)

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
function _bind_sub(
        ctx::_NeedCtx, s::ASTExpr, env::Dict{String, _Bind},
        anchors::Dict{String, String}, dimset::Union{Nothing, String},
        rule::String
    )
    cut = dimset === nothing ? nothing : get(ctx.axes.cut, dimset, nothing)
    vars, runtime = _sub_names(ctx, s, env)
    if !isempty(runtime) || any(v -> env[v].runtime, vars)
        cut === nothing || throw(
            _global_locality(
                rule, dimset,
                "its subscript `$(s)` is data-dependent"
            )
        )
        return _Bind(_ISet(), "", 1, 0, false, true)
    end
    if cut !== nothing
        for v in vars
            env[v].contracted && throw(
                _global_locality(
                    rule, dimset,
                    "it contracts (or scans) over the index `$v` along it"
                )
            )
        end
    end
    # ---- the image ----
    idx = Dict{String, Int}(ctx.params)
    pts = Int[]
    n = prod((length(env[v].cells) for v in vars); init = 1)
    n > _IMAGE_LIMIT && _refuse_rule(
        _rule_display(rule),
        "tile restriction: the subscript `$(s)` ranges over " *
            "$n index combinations"
    )
    function evalat()
        g = _const_int_or_nothing(s, idx, ctx.const_arrays)
        (g === nothing && cut !== nothing) && throw(
            _global_locality(
                rule, dimset,
                "its subscript `$(s)` has no value at build time"
            )
        )
        return g
    end
    per_x = length(vars) == 1 ? Tuple{Int, Int}[] : nothing
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
    if e isa VarExpr && ctx.scope !== nothing && _need_is_arg((e::VarExpr).name)
        b, up = _need_arg(ctx.scope, (e::VarExpr).name)
        return _need_in(() -> _is_arrayish(ctx, b), ctx, up)
    end
    if _tpl_is_call(e) && !_tpl_is_elem(e::OpExpr)
        st = _need_enter(ctx, e::OpExpr)
        if st !== nothing
            body, sc, _ = st
            return _need_in(() -> _is_arrayish(ctx, body), ctx, sc)
        end
    end
    e isa VarExpr && return (e::VarExpr).name in ctx.states ||
        haskey(ctx.obs_defs, (e::VarExpr).name) ||
        (e::VarExpr).name in ctx.arrays
    e isa OpExpr || return false
    o = e::OpExpr
    kind = _index_target_kind(o)
    kind === _IT_MAKEARRAY && return true
    kind === _IT_FAQ && return o.output_idx !== nothing && !isempty(o.output_idx)
    kind === _IT_CONST_ARRAY && return true
    (kind === _IT_INDEX || o.op == "const") && return false
    return _anyof(a -> _is_arrayish(ctx, a), o.args)
end

# Walk an expression evaluated at the cells `env` binds.
function _need_walk!(
        ctx::_NeedCtx, e::ASTExpr, env::Dict{String, _Bind},
        anchors::Dict{String, String}, rule::String
    )
    if e isa VarExpr
        n = (e::VarExpr).name
        if ctx.scope !== nothing && _need_is_arg(n)
            b, up = _need_arg(ctx.scope, n)
            _need_in(() -> _need_walk!(ctx, b, env, anchors, rule), ctx, up)
            return nothing
        end
        haskey(env, n) && return nothing
        if haskey(ctx.scalar_defs, n)
            n in ctx.scalar_stack && return nothing
            push!(ctx.scalar_stack, n)
            try
                _need_in(() -> _need_walk!(ctx, ctx.scalar_defs[n], env, anchors, n), ctx, nothing)
            finally
                delete!(ctx.scalar_stack, n)
            end
        elseif n in ctx.states || haskey(ctx.obs_defs, n)
            # A bare whole-array reference in a cell context: every cell.
            sh = get(ctx.shapes, n, String[])
            for s in sh
                haskey(ctx.axes.cut, s) && throw(
                    _global_locality(
                        rule, s,
                        "it reads the whole array '$n' along it"
                    )
                )
            end
        end
        return nothing
    end
    e isa OpExpr || return nothing
    o = e::OpExpr
    if o.op == "index" && !isempty(o.args)
        push!(ctx.idx_stack, (o, ctx.scope))
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
    if _tpl_is_call(o)
        st = _need_enter(ctx, o)
        if st === nothing
            # No template table: the cells its arguments read (call.jl).
            foreach(c -> _need_walk!(ctx, c, env, anchors, rule), _read_operands(o))
            return nothing
        end
        body, sc, how = st
        if how === :whole
            # An element call: its array body read at the element subscripts.
            outs = _tpl_out_bindings(o)
            foreach(s -> _need_walk!(ctx, s, env, anchors, rule), outs)
            gsubs = ASTExpr[_need_ground(ctx, s) for s in outs]
            _need_in(() -> _need_index_g!(ctx, body, gsubs, env, anchors, rule), ctx, sc)
        else
            _need_in(() -> _need_walk!(ctx, body, env, anchors, rule), ctx, sc)
        end
        return nothing
    end
    foreach_child(c -> _need_walk!(ctx, c, env, anchors, rule), o)
    return nothing
end

# The cells a `ranges` entry spans.
function _range_cells(ctx::_NeedCtx, r)
    r isa AbstractVector || return _ISet()
    vals = Int[]
    for x in r
        v = _region_int(ctx, x)
        v === nothing && return _ISet()
        push!(vals, v)
    end
    length(vals) == 2 && return _ISet(vals[1]:vals[2])
    length(vals) == 3 && return _iset_points(vals[1]:vals[2]:vals[3])
    return _ISet()
end

# The build-time integer value of subscript `e` under the loop bindings `env`
# (`_eval_const_int`, the function the compiler resolves a subscript with), or
# `nothing` when it has none.
function _const_int_or_nothing(e::ASTExpr, env::AbstractDict, consts)::Union{Int, Nothing}
    try
        return _eval_const_int(e, env, consts)
    catch err
        err isa TreeWalkError || rethrow()
        return nothing
    end
end

# A region bound as an integer, or `nothing` when it has no build-time value.
function _region_int(ctx::_NeedCtx, x)
    x isa Integer && return Int(x)
    x isa ASTExpr || return nothing
    return _const_int_or_nothing(_need_ground(ctx, x), Dict{String, Int}(ctx.params), ctx.const_arrays)
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
function _restrict_env(
        ctx::_NeedCtx, env::Dict{String, _Bind}, s::ASTExpr,
        r::UnitRange{Int}
    )
    vars, runtime = _sub_names(ctx, s, env)
    isempty(runtime) || return env
    idx = Dict{String, Int}(ctx.params)
    if isempty(vars)
        g = _const_int_or_nothing(s, idx, ctx.const_arrays)
        g === nothing && return env
        return g in r ? env : nothing
    end
    length(vars) == 1 || return env
    v = vars[1]
    keep = Int[]
    for x in _points(env[v].cells)
        idx[v] = x
        g = _const_int_or_nothing(s, idx, ctx.const_arrays)
        g === nothing && return env
        g in r && push!(keep, x)
    end
    isempty(keep) && return nothing
    env2 = copy(env)
    env2[v] = _with_cells(env[v], _iset_points(keep))
    return env2
end

# Walk `index(target, subs…)` at the cells `env` binds.
function _need_index!(
        ctx::_NeedCtx, target::ASTExpr, subs::Vector{ASTExpr},
        env::Dict{String, _Bind}, anchors::Dict{String, String}, rule::String
    )
    for s in subs
        _need_walk!(ctx, s, env, anchors, rule)
    end
    gsubs = ctx.scope === nothing ? subs : ASTExpr[_need_ground(ctx, s) for s in subs]
    return _need_index_g!(ctx, target, gsubs, env, anchors, rule)
end

# `_need_index!` past the subscripts' own reads, the subscripts grounded (they
# read no body argument, so they hold in any scope).
function _need_index_g!(
        ctx::_NeedCtx, target::ASTExpr, subs::Vector{ASTExpr},
        env::Dict{String, _Bind}, anchors::Dict{String, String}, rule::String
    )
    if target isa VarExpr && ctx.scope !== nothing && _need_is_arg((target::VarExpr).name)
        b, up = _need_arg(ctx.scope, (target::VarExpr).name)
        return _need_in(() -> _need_index_g!(ctx, b, subs, env, anchors, rule), ctx, up)
    end
    if _tpl_is_call(target) && !_tpl_is_elem(target::OpExpr)
        st = _need_enter(ctx, target::OpExpr)
        if st !== nothing
            body, sc, _ = st
            return _need_in(() -> _need_index_g!(ctx, body, subs, env, anchors, rule), ctx, sc)
        end
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
    kind = _index_target_kind(o)
    if kind === _IT_FAQ && o.expr_body !== nothing
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
    if kind === _IT_MAKEARRAY && o.regions !== nothing && o.values !== nothing
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
    (kind === _IT_CONST_ARRAY || o.op == "const") && return nothing
    if kind === _IT_INDEX
        _need_walk!(ctx, o, env, anchors, rule)
        return nothing
    end
    # An elementwise combination of arrays: the index pushes down to each.
    for a in o.args
        if _is_arrayish(ctx, a)
            _need_index_g!(ctx, a, subs, env, anchors, rule)
        else
            _need_walk!(ctx, a, env, anchors, rule)
        end
    end
    return nothing
end

# A `makearray` region's value at the cells `env` binds: an array producer is
# gathered at the cell (at the region's non-singleton axes when its rank is
# lower), anything else is the cell's value as it stands.
function _need_region_value!(
        ctx::_NeedCtx, val::ASTExpr, box::Vector{UnitRange{Int}},
        subs::Vector{ASTExpr}, env, anchors, rule::String
    )
    if val isa VarExpr && ctx.scope !== nothing && _need_is_arg((val::VarExpr).name)
        b, up = _need_arg(ctx.scope, (val::VarExpr).name)
        return _need_in(() -> _need_region_value!(ctx, b, box, subs, env, anchors, rule), ctx, up)
    end
    if _tpl_is_call(val) && !_tpl_is_elem(val::OpExpr)
        st = _need_enter(ctx, val::OpExpr)
        if st !== nothing
            body, sc, _ = st
            return _need_in(() -> _need_region_value!(ctx, body, box, subs, env, anchors, rule), ctx, sc)
        end
    end
    if val isa OpExpr && _is_array_producer(val)
        v = val::OpExpr
        rank = _producer_rank(v)
        if rank > 0
            sel = subs[_region_value_axes(rank, length(subs), d -> length(box[d]) == 1)]
            length(sel) == rank &&
                return _need_index_g!(ctx, v, sel, env, anchors, rule)
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
        throw(
            _range_error(
                ERROR_CODES.RANGE_HALO_INSUFFICIENT,
                "rule '$(_rule_display(rule))' reads '$n' along index set '$(sh[d])' at " *
                    join(["[$(first(r)), $(last(r))]" for r in runs], ", ") *
                    " (unwrapped), outside the tile's storage $(face ? "faces $(first(S)):$(last(S) + 1)" : "box $(first(S)):$(last(S))")" *
                    " and with no periodic image in it; widen the storage box by the halo " *
                    "`halo(op, dec)` reports (API_SPEC §5.8, tile rule 2)"
            )
        )
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
    grew = cur === nothing || any(
        d -> merged[d].cells != cur[d].cells ||
            merged[d].dlo != cur[d].dlo ||
            merged[d].dhi != cur[d].dhi, eachindex(merged)
    )
    if grew
        ctx.obs_need[n] = merged
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
            env = Dict{String, _Bind}()
            anchors = Dict{String, String}()
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
    s.far_high == far ? _iset_intersect(c, (s.cut + 1):(typemax(Int) - 1)) :
    _iset_intersect(c, (typemin(Int) + 1):s.cut)
