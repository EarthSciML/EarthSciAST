# Tiles of a horizontal decomposition (API_SPEC §5.8, "Range-restricted
# right-hand sides"): the decomposition, measured against a program; the range
# spec whose seams (tree_walk/range_hooks.jl) clip a build's equation stream to
# the owned box and lay each state out over the cells the tile stores; and
# `halo` and `restrict`.

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
    axes::Vector{Pair{String, Union{Nothing, Int}}}
    faces::Vector{Pair{String, String}}
end

function Decomposition(; axes, faces = Pair{String, String}[])
    ax = Pair{String, Union{Nothing, Int}}[]
    for a in axes
        name, spec = first(a), last(a)
        period = spec isa NamedTuple ? get(spec, :period, nothing) : spec
        (period === nothing || period isa Integer) || throw(
            ArgumentError(
                "Decomposition: the period of axis '$name' must be an integer or `nothing`, got $(repr(period))"
            )
        )
        push!(ax, String(name) => (period === nothing ? nothing : Int(period)))
    end
    fc = Pair{String, String}[String(first(f)) => String(last(f)) for f in faces]
    return Decomposition(ax, fc)
end

# ============================================================================
# The decomposition against a program
# ============================================================================

# Every index set the program's states and observeds carry, with its extent.
function _program_sets(prog::RhsProgram)
    ext = Dict{String, Int}()
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

_box_invalid(set, why) = _range_error(
    ERROR_CODES.RANGE_BOX_INVALID,
    "index set '$set': $why (API_SPEC §5.8, \"Terms of a decomposition\")"
)

function _axis_model(prog::RhsProgram, dec::Decomposition)
    ext = _program_sets(prog)
    cut = Dict{String, Tuple{String, Bool}}()
    N = Dict{String, Int}()
    period = Dict{String, Union{Nothing, Int}}()
    faces_of = Dict{String, String}(dec.faces)
    for (a, P) in dec.axes
        haskey(cut, a) && throw(_box_invalid(a, "it is cut twice"))
        n = get(ext, a, nothing)
        if n === nothing
            # An axis only face variables carry: its extent is theirs less one.
            f = findfirst(p -> last(p) == a && haskey(ext, first(p)), dec.faces)
            f === nothing && throw(
                _box_invalid(
                    a, "no state or observed of this program " *
                        "is shaped on it; the program's index sets are " *
                        join(sort!(collect(keys(ext))), ", ")
                )
            )
            n = ext[first(dec.faces[f])] - 1
        end
        (P === nothing || P == n) || throw(
            _box_invalid(
                a,
                "its period is $P but its extent is $n; a period is the axis's global extent"
            )
        )
        cut[a] = (a, false)
        N[a] = n
        period[a] = P
    end
    for (f, a) in dec.faces
        haskey(N, a) || throw(
            _box_invalid(
                f,
                "it is declared a face set of '$a', which the decomposition does not cut"
            )
        )
        haskey(cut, f) && throw(_box_invalid(f, "it is both a cut axis and a face set"))
        n = get(ext, f, nothing)
        (n === nothing || n == N[a] + 1) || throw(
            _box_invalid(
                f,
                "a face set of '$a' has $(N[a] + 1) faces, but '$f' has $n"
            )
        )
        cut[f] = (a, true)
    end
    return _AxisModel(cut, N, period)
end

# The `owned`/`storage` keyword of `restrict` as axis → range.
function _axis_boxes(m::_AxisModel, spec, what::String)
    out = Dict{String, UnitRange{Int}}()
    for p in spec
        a, r = String(first(p)), last(p)
        haskey(m.N, a) || throw(
            _box_invalid(
                a, "the $what box names it, but the " *
                    "decomposition does not cut it"
            )
        )
        out[a] = Int(first(r)):Int(last(r))
    end
    for a in keys(m.N)
        haskey(out, a) || throw(_box_invalid(a, "the $what box does not give a range for it"))
    end
    return out
end

# ============================================================================
# The range spec: what the build seams do under `halo` and `restrict`
# ============================================================================

mutable struct _TileSpec <: _RangeSpec
    mode::Symbol                               # :halo or :tile
    axes::_AxisModel
    owned::Dict{String, UnitRange{Int}}
    storage::Dict{String, UnitRange{Int}}
    shapes::Dict{String, Vector{String}}        # array states (from the program)
    writes::Set{String}
    ctx::Any                                   # the `_NeedCtx` once analysed
    # The far-side blocks of states read past a seam: block name → (state,
    # the dimensions on which it holds the far piece).
    aliases::Dict{String, Tuple{String, Vector{Bool}}}
    # Sharing code across tiles (range_hooks.jl, "Tiles that share their
    # code"): each clipped equation's whole-domain ranges, keyed by its output
    # variable and its clipped ranges (both over the loop subscripts of the
    # output, in subscript order); each array variable's whole-domain extents;
    # the views made so far, per layout, and their bounds tables, per layout
    # and build table; the affine tier's stores, per build store; and the
    # cell each moved fixed slot reads, per descriptor table
    # (`_range_real_fixed!`).
    sranges::Dict{Tuple{String, Vector{Tuple{Int, Int}}}, Vector{UnitRange{Int}}}
    whole::Dict{String, Tuple{Vector{Int}, Vector{Int}}}
    views::IdDict{Any, Any}
    xeqs::IdDict{Any, Any}
    fixed::IdDict{Any, Dict{Int, Any}}
    memo::Union{Nothing, _ProgramMemo}          # the program's (`_ProgramMemo`)
end

_TileSpec(mode, axes, owned, storage, shapes, writes, ctx, memo = nothing) =
    _TileSpec(
    mode, axes, owned, storage, shapes, writes, ctx,
    Dict{String, Tuple{String, Vector{Bool}}}(),
    Dict{Tuple{String, Vector{Tuple{Int, Int}}}, Vector{UnitRange{Int}}}(),
    Dict{String, Tuple{Vector{Int}, Vector{Int}}}(), IdDict{Any, Any}(),
    IdDict{Any, Any}(), IdDict{Any, Dict{Int, Any}}(), memo
)

# Whether a tile shares its code with the operator's other tiles: always, but
# for one whose storage crosses a periodic seam (its far-side blocks have no
# counterpart in another tile's layout).
_tile_shares_code(spec::_TileSpec) =
    spec.mode === :tile && spec.ctx !== nothing && isempty(spec.ctx.seams)
_range_shared_code(spec::_TileSpec) = _tile_shares_code(spec)
_range_memo(spec::_TileSpec) = spec.memo

function _range_fixed_ident(spec::_TileSpec, acc, i)
    d = get(spec.fixed, acc, nothing)
    return d === nothing ? nothing : get(d, i, nothing)
end

function _range_affine_view(spec::_TileSpec, var, clipped, var_map, avi, xeq)
    _tile_shares_code(spec) || return nothing
    var_map isa StateLayout || return nothing
    sr = get(spec.sranges, (String(var), _range_key(clipped)), nothing)
    sr === nothing && return nothing
    vm, shift, done = get!(spec.views, var_map) do
        V, sh = _range_virtual_layout(var_map, spec.whole)
        (_RangeVMap(V, Dict{Int, String}()), sh, IdDict{Any, Nothing}())
    end
    # Every array variable's bounds, the whole-domain extents of those the
    # tile cuts: made once per layout and bounds table, which a build fixes
    # before it lowers its first equation.
    wa = get!(spec.views, (var_map, avi)) do
        w = Dict{String, Tuple{Vector{Int}, Vector{Int}}}(avi)
        for (n, e) in spec.whole
            haskey(w, n) && (w[n] = e)
        end
        w
    end
    store = xeq === nothing ? nothing : get!(() -> _XEqStore(), spec.xeqs, xeq)
    return _RangeAffineView(vm, wa, shift, var_map, store, done, spec.fixed), sr
end

# Record the whole-domain ranges of a clipped equation (`clipped` and `whole`
# over the loop subscripts of `var`, in subscript order).
function _record_sranges!(spec::_TileSpec, var::String, clipped, whole)
    spec.sranges[(var, _range_key(clipped))] = UnitRange{Int}[whole...]
    return nothing
end

# Ranges as their end points: every empty range is `==` every other, and two
# empty clips of different regions must stay apart.
_range_key(rs) = Tuple{Int, Int}[(first(r), last(r)) for r in rs]

# The loop-subscript ranges of a `faq` left-hand side `L` writing `var`, in
# subscript order, as unit ranges (`nothing` when one is not a single run).
function _lhs_loop_ranges(ctx::_NeedCtx, L::OpExpr)
    inner = (L.expr_body::OpExpr).args[1]
    (inner isa OpExpr && (inner::OpExpr).op == "index") || return nothing
    rd = _ranges_dict(L)
    out = UnitRange{Int}[]
    for a in (inner::OpExpr).args[2:end]
        (a isa VarExpr && haskey(rd, (a::VarExpr).name)) || continue
        r = rd[(a::VarExpr).name]
        (r isa AbstractVector && length(r) == 2) || return nothing
        lo, hi = r
        if !(lo isa Integer && hi isa Integer)
            c = _range_cells(ctx, r)
            length(c.ivs) == 1 || return nothing
            lo, hi = minimum(c), maximum(c)
        end
        push!(out, Int(lo):Int(hi))
    end
    return out
end

# How a `halo` analysis leaves the build once the need analysis has run: the
# build stops at the range seam and `halo` takes the analysis. Not an
# `EarthSciASTError`, so no recovery from a document error between the seam and
# `halo` can swallow it.
struct _HaloDone <: Exception
    ctx::_NeedCtx
end

# A causal recurrence (esm-spec §4.3.1.1) along a decomposed axis reads every
# earlier position on that axis, so a tile cannot evaluate it: refused, as a
# scan along a cut axis is. Along any other axis its self-reads stay on the
# cell's own position across the cut, and the sweep runs over the cells the
# tile needs (recurrence_sweep.jl). A definition whose axis cannot be decided
# here is left to the build, which refuses it with its own code.
function _refuse_cut_recurrences(spec::_TileSpec, obs_defs, shapes)
    for n in sort!(collect(keys(obs_defs)))
        def = obs_defs[n]
        (def isa OpExpr && _is_faq_op(def.op) && def.expr_body !== nothing) || continue
        recurrence_self_reference_kind(n, def; templates = _build_templates()) === :indexed || continue
        idx = _output_idx_strings(def)
        sh = get(shapes, n, nothing)
        (sh === nothing || length(sh) != length(idx)) && continue
        axis = try
            first(_recurrence_axis(n, def, idx))
        catch err
            err isa TreeWalkError || rethrow()
            continue
        end
        haskey(spec.axes.cut, sh[axis]) && throw(
            _global_locality(
                n, sh[axis],
                "it is a causal recurrence (esm-spec §4.3.1.1) along it, whose every " *
                    "cell reads the cells before it on that axis"
            )
        )
    end
    return nothing
end

# The whole-domain build's resolved observed definitions, shapes and extents.
function _need_context(
        spec::_TileSpec, model, cls, parts, index_sets, const_arrays,
        param_arrays
    )
    shapes = Dict{String, Vector{String}}(spec.shapes)
    extents = Dict{String, Vector{Int}}()
    obs_defs = Dict{String, ASTExpr}()
    scalar_defs = Dict{String, ASTExpr}()
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
    _refuse_cut_recurrences(spec, obs_defs, shapes)
    params = Dict{String, Int}()
    for (k, v) in parts.param_scope
        (v isa Real && isfinite(v) && isinteger(v)) && (params[String(k)] = Int(v))
    end
    arrays = Set{String}(String(k) for k in keys(const_arrays))
    union!(arrays, (String(k) for k in keys(param_arrays)))
    union!(arrays, (String(k) for k in keys(cls.const_obs_arrays)))
    ca = isempty(cls.const_obs_arrays) ? const_arrays :
        merge(
            Dict{String, Any}(String(k) => v for (k, v) in cls.const_obs_arrays),
            Dict{String, Any}(String(k) => v for (k, v) in const_arrays)
        )
    states = Set{String}(n for n in keys(spec.shapes))
    ctx = _NeedCtx(
        spec.mode, spec.axes, spec.owned, spec.storage, shapes, extents,
        states, obs_defs, scalar_defs,
        Set{String}(cls.mat_array_vars), params, ca, arrays,
        Dict{Tuple{String, String}, Tuple{Int, Int}}(), Set{String}(),
        Dict{String, Vector{_Bind}}(), String[], Set{String}()
    )
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
    rr = Dict{String, Any}(String(k) => r for (k, r) in R.ranges)
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

# Whether a tile build shares its code with the operator's other tiles
# (`_tile_shares_code`).
_ctx_shares_code(ctx::_NeedCtx) = ctx.mode === :tile && isempty(ctx.seams)

# Set loop variable `x`'s range in `newr` to the empty `[lo, lo - 1]`, `lo` the
# first cell of its range `rd[x]`; false when that range has no cell.
function _range_none!(ctx::_NeedCtx, newr, rd, x::String)
    c = _range_cells(ctx, rd[x])
    isempty(c) && return false
    lo = minimum(c)
    newr[x] = Any[lo, lo - 1]
    return true
end

# Walk one `D` equation; return it clipped to the owned box (tile mode), or
# `nothing` when the tile owns none of its cells. A tile that shares its code
# keeps a `faq` equation it owns no cell of, over an empty range along a loop
# variable (`[lo, lo - 1]`, `lo` the first cell of the variable's range), so
# it lowers the equation as every other tile does, with no cell to run.
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
        env = Dict{String, _Bind}()
        anchors = Dict{String, String}()
        newr = Dict{String, Any}(String(k) => r for (k, r) in rd)
        # Whether the tile runs none of the equation's cells (a subscript
        # misses the owned box) and keeps it all the same.
        keep = _ctx_shares_code(ctx)
        none = false
        loops = String[]
        for (d, a) in enumerate(args)
            if a isa VarExpr && haskey(rd, (a::VarExpr).name)
                x = (a::VarExpr).name
                push!(loops, x)
                cells, axis = _output_cells(ctx, v, d, rd[x])
                if isempty(cells)
                    (keep && _range_none!(ctx, newr, rd, x)) || return nothing
                    none = true
                    continue
                end
                env[x] = isempty(axis) ? _Bind(cells) : _Bind(cells, axis, 0, 0, false, false)
                isempty(axis) || (anchors[axis] = x)
                if !isempty(axis) && ctx.mode === :tile
                    length(cells.ivs) == 1 || _refuse_rule(
                        _rule_display(rule),
                        "tile restriction: its output cells along '$axis' are not one range"
                    )
                    newr[x] = Any[minimum(cells), maximum(cells)]
                end
            else
                g = _region_int(ctx, a)
                g === nothing && _refuse_rule(
                    _rule_display(rule),
                    "tile restriction: its left-hand side subscript " *
                        "`$(a)` is neither a loop index nor a constant"
                )
                cells, axis = _output_cells(ctx, v, d, Any[g, g])
                if isempty(cells)
                    keep || return nothing
                    none = true
                end
            end
        end
        # A constant subscript off the owned box runs no cell through an empty
        # loop variable.
        if none && !any(x -> isempty(_range_cells(ctx, newr[x])), loops)
            (!isempty(loops) && _range_none!(ctx, newr, rd, first(loops))) || return nothing
        end
        rhs = eq.rhs
        # (An equation kept over no cells reads nothing.)
        if !none
            if rhs isa OpExpr && _is_faq_op((rhs::OpExpr).op) &&
                    length(_output_idx_strings(rhs::OpExpr)) == length(outs)
                _need_index!(ctx, rhs, ASTExpr[VarExpr(x) for x in outs], env, anchors, rule)
            else
                _need_walk!(ctx, rhs, env, anchors, rule)
            end
        end
        ctx.mode === :tile || return eq
        newlhs = reconstruct(L; ranges = newr)
        clips = Dict{String, Any}(x => newr[x] for x in outs if haskey(newr, x))
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
                g = _region_int(ctx, x)
                g === nothing && return eq
                cells, _ = _output_cells(ctx, v, d, Any[g, g])
                isempty(cells) && return nothing
            end
        end
        _need_walk!(ctx, eq.rhs, Dict{String, _Bind}(), Dict{String, String}(), rule)
        return eq
    end
    # A 0-d state.
    ctx.mode === :tile && throw(
        _range_error(
            ERROR_CODES.RANGE_GLOBAL_LOCALITY,
            "the operator writes the 0-d state '$rule', which no tile owns; a 0-d state " *
                "write has global locality (API_SPEC §5.8, decision 8)"
        )
    )
    _need_walk!(ctx, eq.rhs, Dict{String, _Bind}(), Dict{String, String}(), rule)
    return eq
end

function _range_restrict_parts(
        spec::_TileSpec, model, cls, parts, index_sets,
        const_arrays, param_arrays
    )
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
        e2 === nothing && continue
        push!(eqs, e2)
        if spec.mode === :tile && e2.lhs isa OpExpr && _is_faq_op((e2.lhs::OpExpr).op)
            w = _lhs_loop_ranges(ctx, eq.lhs::OpExpr)
            c = _lhs_loop_ranges(ctx, e2.lhs::OpExpr)
            (w === nothing || c === nothing || length(w) != length(c)) ||
                _record_sranges!(spec, tgt, c, w)
        end
    end
    _need_drain!(ctx)
    spec.mode === :halo && throw(_HaloDone(ctx))
    isempty(ctx.seams) || (eqs = _seam_equations(ctx, spec, eqs))
    return _with_equations(parts, eqs)
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
_seam_obs_alias(n::String, far::Vector{Bool}) = "__seamobs_" * join(Int.(far)) * "__" * n

struct _SeamRewrite
    ctx::_NeedCtx
    aliases::Dict{String, Tuple{String, Vector{Bool}}}
    inline::Dict{Tuple{String, Tuple}, ASTExpr}
    # Seam instances made so far, per (chain of references, context).
    inst::Dict{Tuple{Vector{UInt}, Any}, Union{Nothing, String}}
    # An observed read past the seam inside a template body: the implicit
    # parameter the seam instance reads it as (`_seam_obs_alias`) => the
    # observed's definition on that side, the array expression a reference
    # binds it to.
    obs::Dict{String, ASTExpr}
end

# The dimensions on which the read of `n` at `node` lands past the seam in
# context `tag` (`:any`: every context), or `nothing` for a read that does not
# (or that the walk never reached).
_seam_far_dims(ctx::_NeedCtx, node, n::String, tag) =
    _seam_far_dims(ctx, get(ctx.marks, node, nothing), n, tag)
function _seam_far_dims(ctx::_NeedCtx, m::Union{Nothing, AbstractDict}, n::String, tag)
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
        bits[d] == 0x03 && _refuse_rule(
            _rule_display(n),
            "tile restriction: one read of '$n' reaches cells on both sides of the " *
                "periodic seam of '$(ctx.shapes[n][d])' within the tile's storage; give the " *
                "tile a storage box that does not cross the seam"
        )
    end
    return any(far) ? far : nothing
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
    r = map_children(x -> _seam_rewrite(rw, x, tag), o)
    _tpl_is_call(o) && (r = _seam_call(rw, o, r::OpExpr, tag))
    return r
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
            return _seam_obs_far(rw, n, far)
        end
        return t
    end
    t isa OpExpr || return t
    o = t::OpExpr
    kind = _index_target_kind(o)
    (
        kind === _IT_INDEX || kind === _IT_MAKEARRAY || o.op == "const" ||
            (kind === _IT_FAQ && o.expr_body !== nothing)
    ) && return _seam_rewrite(rw, o, tag)
    # An elementwise combination of arrays: each array operand is read at the
    # cells of `node` itself.
    r = map_children(o) do x
        _is_arrayish(ctx, x) ? _seam_target(rw, x, node, tag) : _seam_rewrite(rw, x, tag)
    end
    _tpl_is_call(o) && (r = _seam_call(rw, o, r::OpExpr, tag))
    return r
end

# The definition of observed `n` evaluated on the far side `far` of its seams.
function _seam_obs_far(rw::_SeamRewrite, n::String, far::Vector{Bool})
    ctx = rw.ctx
    sides = Tuple(far[d] for d in eachindex(far) if _dim_seam(ctx, n, d) !== nothing)
    return get!(rw.inline, (n, sides)) do
        _seam_target(rw, ctx.obs_defs[n], nothing, (n, sides))
    end
end

# ---- Reads past a periodic seam inside a template body ----
#
# A template reference is compiled once per instance, its body shared by every
# use (call.jl), so a read the body makes cannot be sent to the far block at
# one use by rewriting the body in place. The need walk recorded each read a
# body makes per chain of references that reached it (`_NeedCtx.bmarks`); a
# reference whose body (or a body it calls) reads a state past the seam at
# this use is pointed at a SEAM INSTANCE of its template: a template of its
# own (`<name>\0seam\0<key>`), registered once in the build's registry as
# structural instances and view parts are, whose body is the template's with
# each such read made of the far block instead (`_seam_alias`, the block the
# seam rewrite sends an inlined read past the seam to), and each reference in
# it whose body does so pointed at that template's seam instance in turn. The
# far block is a name the body reads from its caller, so it is an implicit
# parameter of the instance, passed down the chain as every implicit
# parameter is. An OBSERVED read past the seam is made of the implicit
# parameter `_seam_obs_alias` instead, which the reference binds to the
# observed's definition on that side (`_seam_obs_far`, the expression the
# seam rewrite substitutes for an inlined read): an array expression, which
# the call evaluates lazily, at the cell the body reads (call.jl, "Array
# expressions compiled into the instance"); a nested seam instance's
# reference passes it on as it passes any implicit parameter. The key is the
# instance body itself: two uses that read past the seam alike share one seam
# instance, and a reference that reads nothing past the seam (every reference
# in a tile whose storage crosses no seam) keeps the ordinary instance. No body
# is expanded.

const _TPL_SEAM = "\0seam\0"

# `new` (the reference `orig` with its bindings rewritten) pointed at its seam
# instance when its body reads past the seam at this use.
function _seam_call(rw::_SeamRewrite, orig::OpExpr, new::OpExpr, tag)
    isempty(rw.ctx.bmarks) && return new
    name = _seam_instance(rw, orig, Any[orig], tag)
    name === nothing && return new
    _seam_check_lanes(rw.ctx.tt, orig, name)
    # Each observed the instance reads past the seam, bound to its far side.
    def = _tpl_def(rw.ctx.tt, name)
    nb = nothing
    for f in def.closed.free
        v = get(rw.obs, f, nothing)
        v === nothing && continue
        nb === nothing && (nb = new.bindings === nothing ? Dict{String, ASTExpr}() : Dict{String, ASTExpr}(new.bindings))
        nb[_TPL_FREE * f] = v
    end
    return nb === nothing ? reconstruct(new; name = name) : reconstruct(new; name = name, bindings = nb)
end

# The body the need walk read for the reference `call` (`_need_enter`) and the
# node of the template's prepared body it stands for (they have one shape: a
# lane replaces a read by a leaf, an element call reads its element).
function _seam_walked_body(tt, call::OpExpr)
    def = _tpl_def(tt, call.name)
    def.closed === nothing && throw(
        TreeWalkError(
            "E_TREEWALK_UNSUPPORTED_OP",
            "template '$(call.name)' reads past a periodic seam within a tile's storage and " *
                "has a parameter in a structural position; the build makes no seam instance of it"
        )
    )
    C = def.closed.body
    if _call_has_lanes(call)
        info = _tpl_call_info(tt, call.name)
        if info !== nothing
            outs = _call_outs(info, call)
            S = _call_fixed!(Dict{String, Any}(), call.name, info, call.bindings)
            hp = _call_hoist_plan(tt, def, S, outs)
            return hp.body, (isempty(outs) ? C : (C::OpExpr).expr_body), def
        end
    end
    return C, C, def
end

# Pair each node of the walked body `w` with the prepared body's node `c` it
# stands for.
function _seam_pair!(corr::IdDict{Any, Any}, w, c)
    (w isa OpExpr && c isa OpExpr) || return corr
    haskey(corr, w) && return corr
    w.op == c.op || return corr
    corr[w] = c
    for (f, spec) in pairs(OPEXPR_FIELD_TABLE)
        x = getfield(w, f)
        y = getfield(c, f)
        (x === nothing || y === nothing) && continue
        if spec.kind === :expr
            _seam_pair!(corr, x, y)
        elseif spec.kind === :expr_vec
            length(x) == length(y) || continue
            for k in eachindex(x)
                _seam_pair!(corr, x[k], y[k])
            end
        elseif spec.kind === :expr_map
            for (k, v) in x
                u = get(y, k, nothing)
                u === nothing || _seam_pair!(corr, v, u)
            end
        end
    end
    return corr
end

# Whether the marks `m` of one body read hold context `tag`.
_seam_tag_in(m, tag) = tag === :any || any(k -> k[2] == tag, keys(m))

# The seam instance of the reference `call` reached through `chain` (the
# references the walk entered, outermost first, ending with `call`) in
# context `tag`, registered in the build's registry; `nothing` when its body
# reads nothing past the seam there.
function _seam_instance(rw::_SeamRewrite, call::OpExpr, chain::Vector{Any}, tag)
    ctx = rw.ctx
    ids = UInt[objectid(c) for c in chain]
    return get!(rw.inst, (ids, tag)) do
        L = length(ids)
        direct = IdDict{Any, String}()      # walked read => far block it reads
        nested = IdDict{Any, Nothing}()     # walked reference with reads below
        for ((cids, _), (ch, node, m)) in ctx.bmarks
            (length(cids) >= L && view(cids, 1:L) == ids && _seam_tag_in(m, tag)) || continue
            if length(cids) > L
                nested[ch[L + 1]] = nothing
                continue
            end
            for n in unique!([k[1] for k in keys(m)])
                far = _seam_far_dims(ctx, m, n, tag)
                far === nothing && continue
                if n in ctx.states
                    a = _seam_alias(n, far)
                    rw.aliases[a] = (n, far)
                else
                    a = _seam_obs_alias(n, far)
                    get!(rw.obs, a) do
                        e = _seam_obs_far(rw, n, far)
                        _tpl_array_expr(e, ctx.tt) || _refuse_rule(
                            _rule_display(n),
                            "tile restriction: template '$(call.name)' reads the observed '$n' past " *
                                "the periodic seam within the tile's storage, and its definition there " *
                                "is no elementwise array expression a template call can evaluate; give " *
                                "the tile a storage box that does not cross the seam"
                        )
                        e
                    end
                end
                direct[node] = a
            end
        end
        tt = ctx.tt
        swap = IdDict{Any, Any}()
        W, C, def = (isempty(direct) && isempty(nested)) ? (nothing, nothing, nothing) :
            _seam_walked_body(tt, call)
        if W !== nothing
            corr = _seam_pair!(IdDict{Any, Any}(), W, C)
            for (node, a) in direct
                c = get(corr, node, nothing)
                c === nothing && throw(_seam_lost(call))
                swap[c] = reconstruct(c::OpExpr; args = ASTExpr[VarExpr(a); (c::OpExpr).args[2:end]])
            end
            for y in keys(nested)
                yn = _seam_instance(rw, y::OpExpr, Any[chain; y], tag)
                yn === nothing && continue
                c = get(corr, y, nothing)
                c === nothing && throw(_seam_lost(call))
                swap[c] = reconstruct(c::OpExpr; name = yn)
            end
        end
        isempty(swap) && return nothing
        body = _seam_swap(def.closed.body, swap, IdDict{OpExpr, ASTExpr}())
        return _seam_register!(tt, String(call.name), body)
    end
end

_seam_lost(call) = TreeWalkError(
    "E_TREEWALK_UNSUPPORTED_OP",
    "template '$(call.name)': a read past a periodic seam was not found in the body the build compiles"
)

# `e` with each node of `swap` replaced.
function _seam_swap(e::ASTExpr, swap::IdDict{Any, Any}, memo::IdDict{OpExpr, ASTExpr})
    e isa OpExpr || return e
    got = get(swap, e, nothing)
    got === nothing || return got
    r = get(memo, e, nothing)
    r === nothing || return r
    return memo[e] = map_children(c -> _seam_swap(c, swap, memo), e)
end

# Register the seam instance of template `name` whose prepared body is `body`
# (parameters and implicit parameters as sentinels): its declaration is the
# template's, with `body` written back in the declaration's own names.
function _seam_register!(tt, name::String, body::ASTExpr)
    m = Dict{String, ASTExpr}()
    foreach_subexpr(body) do x
        if x isa VarExpr && _tpl_is_sentinel(x.name)
            pre = startswith(x.name, _TPL_ARG) ? _TPL_ARG : _TPL_FREE
            m[x.name] = VarExpr(x.name[(ncodeunits(pre) + 1):end])
        end
    end
    raw = serialize_expression(_tpl_subst_scoped(body, m, IdDict{OpExpr, ASTExpr}()))
    sname = string(name, _TPL_SEAM, bytes2hex(SHA.sha1(_stable_json(raw))))
    if !haskey(tt.reg, sname)
        nd = OrderedDict{String, Any}()
        for (k, v) in pairs(tt.reg[name])
            nd[string(k)] = v
        end
        nd["body"] = raw
        tt.reg[sname] = nd
    end
    return sname
end

# A reference's reads the caller makes (its lanes, made for the ordinary
# instance and seam-rewritten with the caller's tree) are those of its seam
# instance: the instance reads past the seam only where the body reads on
# some paths, never a lane.
function _seam_check_lanes(tt, call::OpExpr, sname::String)
    _call_has_lanes(call) || return nothing
    info = _tpl_call_info(tt, call.name)::_TplCallInfo
    sinfo = _tpl_call_info(tt, sname)
    outs = _call_outs(info, call)
    S = _call_fixed!(Dict{String, Any}(), call.name, info, call.bindings)
    a = _call_hoist_plan(tt, _tpl_def(tt, call.name), S, outs).gathers
    b = sinfo === nothing ? nothing : _call_hoist_plan(tt, _tpl_def(tt, sname), S, outs).gathers
    (
        b !== nothing && length(a) == length(b) &&
            all(k -> _tpl_bkey(tt, a[k], nothing) == _tpl_bkey(tt, b[k], nothing), eachindex(a))
    ) || throw(
        TreeWalkError(
            "E_TREEWALK_UNSUPPORTED_OP",
            "template '$(call.name)': its seam instance reads other cells in the caller " *
                "than the template does"
        )
    )
    return nothing
end

function _seam_equations(ctx::_NeedCtx, spec::_TileSpec, eqs::Vector{Equation})
    rw = _SeamRewrite(
        ctx, spec.aliases, Dict{Tuple{String, Tuple}, ASTExpr}(),
        Dict{Tuple{Vector{UInt}, Any}, Union{Nothing, String}}(), Dict{String, ASTExpr}()
    )
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
    seams = spec.ctx === nothing ? Dict{Tuple{String, Bool}, _Seam}() : spec.ctx.seams
    for (n, (lo, hi)) in collect(avi)
        sh = get(spec.shapes, n, nothing)
        sh === nothing && continue
        lo2, hi2 = copy(lo), copy(hi)
        wlo, whi = copy(lo), copy(hi)
        for d in eachindex(sh)
            cut = get(spec.axes.cut, sh[d], nothing)
            cut === nothing && continue
            axis, face = cut
            S = spec.storage[axis]
            Sf = face ? (first(S):(last(S) + 1)) : S
            dom = _axis_domain(spec.axes, axis, face)
            sm = get(seams, cut, nothing)
            wlo[d], whi[d] = first(dom), last(dom)
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
        spec.whole[n] = (wlo, whi)
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
    spec.whole[name] = (ones(Int, length(dims)), copy(dims))
    sh = spec.ctx.shapes[name]
    lo, hi = ones(Int, length(dims)), copy(dims)
    for d in eachindex(dims)
        haskey(spec.axes.cut, sh[d]) || continue
        c = _obs_near_cells(spec.ctx, name, d, _iset_intersect(need[d].cells, 1:dims[d]))
        isempty(c) && return nothing
        lo[d], hi[d] = minimum(c), maximum(c)
        if _tile_shares_code(spec)
            # Laid out over the tile's storage, as a state on the same sets
            # is, so a read of it keeps the constant offset from the cell
            # written that it has in the whole-domain program.
            axis, face = spec.axes.cut[sh[d]]
            S = spec.storage[axis]
            lo[d] = max(1, min(lo[d], first(S)))
            hi[d] = min(dims[d], max(hi[d], last(S) + (face ? 1 : 0)))
        end
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
        rd = Dict{String, Any}(String(k) => r for (k, r) in L.ranges)
        pieces = Vector{Pair{String, Vector{UnitRange{Int}}}}()
        for (d, a) in enumerate(args)
            (a isa VarExpr && haskey(rd, (a::VarExpr).name)) || continue
            haskey(spec.axes.cut, sh[d]) || continue
            x = (a::VarExpr).name
            r = rd[x]
            span = Int(r[1]):Int(r[end])
            c = _iset_intersect(
                _obs_near_cells(
                    spec.ctx, name, d,
                    _iset_intersect(need[d].cells, 1:dims[d])
                ), span
            )
            push!(pieces, x => c.ivs)
        end
        # A tile that shares its code keeps every region, over the one run of
        # cells it needs there or none, so its fills are lowered as every
        # other tile's are.
        if _tile_shares_code(spec) && all(p -> length(last(p)) <= 1, pieces)
            r2 = copy(rd)
            for (x, ivs) in pieces
                lo = Int(rd[x][1])
                r2[x] = isempty(ivs) ? Any[lo, lo - 1] : Any[first(ivs[1]), last(ivs[1])]
            end
            lhs = reconstruct(L; ranges = r2)
            clips = Dict{String, Any}(first(p) => r2[first(p)] for p in pieces)
            rhs = _clip_rhs_ranges(eq.rhs, _output_idx_strings(L), clips)
            neq = Equation(lhs, rhs)
            w = _lhs_loop_ranges(spec.ctx, L)
            c = _lhs_loop_ranges(spec.ctx, lhs)
            (w === nothing || c === nothing || length(w) != length(c)) ||
                _record_sranges!(spec, name, c, w)
            push!(out, neq)
            continue
        end
        any(p -> isempty(last(p)), pieces) && continue
        for combo in Iterators.product((last(p) for p in pieces)...)
            r2 = copy(rd)
            for (k, p) in enumerate(pieces)
                r2[first(p)] = Any[first(combo[k]), last(combo[k])]
            end
            lhs = reconstruct(L; ranges = r2)
            clips = Dict{String, Any}(first(p) => r2[first(p)] for p in pieces)
            rhs = _clip_rhs_ranges(eq.rhs, _output_idx_strings(L), clips)
            push!(out, Equation(lhs, rhs))
        end
    end
    return out
end

# ============================================================================
# `halo` and `restrict`
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
    spec = _TileSpec(
        :halo, m, Dict{String, UnitRange{Int}}(), Dict{String, UnitRange{Int}}(),
        _array_shapes(op), Set(op.writes), nothing, op.memo
    )
    ctx = try
        _relower(op, spec)
        error("halo: the build did not reach the range seam")
    catch err
        err isa _HaloDone || rethrow()
        err.ctx
    end
    return _halo_reach(ctx)
end

function _halo_reach(ctx::_NeedCtx)
    out = Dict{Tuple{String, String}, Tuple{Int, Int}}()
    for n in ctx.reads
        n in ctx.states || continue
        for s in ctx.shapes[n]
            haskey(ctx.axes.cut, s) || continue
            lo, hi = get(ctx.reach, (n, s), (0, 0))
            out[(n, s)] = (max(0, -lo), max(0, hi))
        end
    end
    return out
end

_array_shapes(op::RhsProgram) =
    Dict{String, Vector{String}}(b.name => op.shapes[b.name] for b in _layout_blocks(op.internal))

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
restrict(op::RhsProgram, dec::Decomposition; owned, storage) =
    _restrict(op, dec; owned, storage)

function _restrict(op::RhsProgram, dec::Decomposition; owned, storage, form = :inplace)
    _require_native(op, "restrict")
    m = _axis_model(op, dec)
    ow = _axis_boxes(m, owned, "owned")
    st = _axis_boxes(m, storage, "storage")
    for (a, B) in ow
        isempty(B) && throw(_box_invalid(a, "the owned box $B is empty"))
        (first(B) >= 1 && last(B) <= m.N[a]) || throw(
            _box_invalid(
                a,
                "the owned box $(first(B)):$(last(B)) is not inside 1:$(m.N[a])"
            )
        )
        issubset(B, st[a]) || throw(
            _box_invalid(
                a,
                "the owned box $(first(B)):$(last(B)) is not inside the storage box " *
                    "$(first(st[a])):$(last(st[a]))"
            )
        )
    end
    for n in op.writes
        haskey(op.internal.scalars, n) && throw(
            _range_error(
                ERROR_CODES.RANGE_GLOBAL_LOCALITY,
                "the operator writes the 0-d state '$n', which no tile owns; a 0-d state " *
                    "write has global locality (API_SPEC §5.8, decision 8)"
            )
        )
    end
    shapes = _array_shapes(op)
    spec = _TileSpec(:tile, m, ow, st, shapes, Set(op.writes), nothing, op.memo)
    f!, internal, cap, pa = _relower(op, spec; form)
    # ---- the tile's layout and copy maps ----
    gb = Dict{String, Vector{UnitRange{Int}}}(
        b.name => UnitRange{Int}[b.lo[d]:b.hi[d] for d in eachindex(b.lo)]
            for b in _layout_blocks(op.internal)
    )
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
    extra = Dict{String, Vector{String}}()
    for (a, (n, _)) in spec.aliases
        push!(get!(() -> String[], extra, n), a)
    end
    foreach(sort!, values(extra))
    maps = _copy_maps(layout, internal, to_internal, extra)
    form === :oop && return (; f!, layout, maps, reach = _halo_reach(spec.ctx))
    return TileProgram(
        op, f!, internal, layout, maps,
        _derived_shared(op.shared, f!, length(internal), cap, pa)
    )
end
