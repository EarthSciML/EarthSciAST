# tree_walk/shape_ops.jl — `reshape`, `transpose`, `concat` and
# elementwise broadcasting as index maps onto their operands.

# ── Shape ops as index maps (esm-spec §4.3.5) ────────────────────────────────
# `reshape`, `transpose` and `concat` only relabel cells, so an element of one
# is an element of its operand at other subscripts. `index(shape_op(X), k…)` is
# rewritten here into `index(X, k′…)` and resolved again, so the shape op never
# reaches `_compile` and every tier sees an ordinary gather.
#
# A shape-op result is anonymous and 1-based. `reshape` is column-major (the
# order the Rust interpreter and `tests/fixtures/faq/11_reshape_roundtrip.esm`
# pin); `transpose`'s `perm` is 0-based with output axis `d` reading operand axis
# `perm[d]`, reversed axes when absent; `concat`'s `axis` is 0-based and a
# scalar operand is one element long.
#
# Subscripts that fold to integers map exactly. A symbolic subscript maps only
# where the remap is a relabelling of axes (a `transpose`, a `reshape` that
# inserts or drops unit axes, a `concat` subscript off the joined axis); any
# other symbolic remap needs integer division or a per-cell operand choice and
# is refused by name.
const _SHAPE_REMAP_OPS = Tuple(sort!(collect(_ops_with(:shape_remap))))

_try_const_int(a::ASTExpr, const_arrays) =
try
    _eval_const_int(a, _EMPTY_IDX_ENV, const_arrays)
catch err
    err isa TreeWalkError || rethrow()
    nothing
end

# `(lo, ext)` of an array-valued expression the shape-op remap can see through,
# `(Int[], Int[])` for a scalar, `nothing` when the shape is not known here.
# A whole-array operand uses its buffer's rank even when it holds one cell.
# Elementwise operands still allow a scalar field supplied in a one-cell buffer.
function _remap_operand_shape(e::ASTExpr, rc::_ResolveCtx; whole::Bool = false)
    array_var_info, const_arrays, pgather = rc.array_var_info, rc.const_arrays, rc.pgather
    e isa NumExpr && return (Int[], Int[])
    e isa IntExpr && return (Int[], Int[])
    if e isa VarExpr
        n = (e::VarExpr).name
        src = _array_source(n, array_var_info, pgather, const_arrays)
        if src === :state
            lo, hi = array_var_info[n]
            return (copy(lo), hi .- lo .+ 1)
        elseif src === :forcing
            return (ones(Int, length(pgather[n].dims)), copy(pgather[n].dims))
        elseif src === :const
            arr = const_arrays[n]
            (arr isa AbstractArray && (whole || !_is_scalar_const_field(arr))) ||
                return (Int[], Int[])
            return (ones(Int, ndims(arr)), collect(Int, size(arr)))
        end
        return (Int[], Int[])
    end
    e isa OpExpr || return nothing
    o = e::OpExpr
    if o.op == "reshape"
        (o.shape === nothing || !all(s -> s isa Integer, o.shape)) && return nothing
        ext = Int[Int(s) for s in o.shape]
        return (ones(Int, length(ext)), ext)
    elseif o.op == "transpose"
        length(o.args) == 1 || return nothing
        s = _remap_operand_shape(o.args[1], rc; whole = true)
        s === nothing && return nothing
        perm = _transpose_perm(o, length(s[2]))
        return (ones(Int, length(perm)), s[2][perm .+ 1])
    elseif o.op == "concat"
        parts = [_remap_operand_shape(a, rc) for a in o.args]
        (isempty(parts) || any(p -> p === nothing, parts)) && return nothing
        ax = something(o.axis, 0) + 1
        exts = [isempty(p[2]) ? [1] : p[2] for p in parts]
        ext = copy(exts[1])
        ax <= length(ext) || return nothing
        ext[ax] = sum(x[ax] for x in exts)
        return (ones(Int, length(ext)), ext)
    elseif _is_scalar_op(o.op)
        shapes = [_remap_operand_shape(a, rc) for a in o.args]
        any(s -> s === nothing, shapes) && return nothing
        ext = _positional_broadcast_extent([s[2] for s in shapes], o)
        return (ones(Int, length(ext)), ext)
    end
    return nothing
end

# §4.3.4 positional broadcast of anonymous operand extents: left-aligned, the
# lower rank padded with trailing singletons; two extents that differ on an axis
# where neither is 1 are incompatible.
function _positional_broadcast_extent(exts::Vector{Vector{Int}}, at::OpExpr)
    r = maximum(length, exts; init = 0)
    out = ones(Int, r)
    for x in exts, d in 1:r
        xd = d <= length(x) ? x[d] : 1
        if out[d] == 1
            out[d] = xd
        elseif xd != 1 && xd != out[d]
            throw(
                TreeWalkError(
                    "E_TREEWALK_BROADCAST_SHAPE",
                    "operands of '$(at.op)' are not broadcast-compatible: extents " *
                        "$(join(exts, ", ")) disagree on axis $(d) (esm-spec §4.3.4)"
                )
            )
        end
    end
    return out
end

function _transpose_perm(o::OpExpr, rank::Int)
    perm = o.perm === nothing ? collect((rank - 1):-1:0) : copy(o.perm)
    sort(perm) == collect(0:(rank - 1)) ||
        throw(
        TreeWalkError(
            "E_TREEWALK_SHAPE_OP",
            "transpose perm $(perm) is not a permutation of the operand's $(rank) axes " *
                "(esm-spec §4.3.5)"
        )
    )
    return perm
end

# Shift a 1-based subscript onto an operand axis whose origin is `lo`.
_remap_shift(k::ASTExpr, lo::Int) =
    lo == 1 ? k : OpExpr("+", ASTExpr[k, IntExpr(Int64(lo - 1))])

_shape_remap_refuse(o::OpExpr, why::AbstractString) =
    throw(
    TreeWalkError(
        "E_TREEWALK_SHAPE_OP",
        "index($(o.op)(…), …): $(why) (esm-spec §4.3.5)"
    )
)

# `index(o, subs…)` with `o` a shape op → `index(X, subs′…)` (or the scalar
# operand itself for a scalar `concat` part). Not yet resolved: the caller runs
# `_resolve_indices` on the result, which recurses through nested shape ops.
function _index_through_shape_op(o::OpExpr, subs::Vector{ASTExpr}, rc::_ResolveCtx)::ASTExpr
    shp = _remap_operand_shape(o, rc)
    shp === nothing && _shape_remap_refuse(o, "the operand's shape is not known at build time")
    ext = shp[2]
    length(subs) == length(ext) ||
        _shape_remap_refuse(o, "the result is rank $(length(ext)) but got $(length(subs)) subscripts")
    ks = Union{Int, Nothing}[_try_const_int(s, rc.const_arrays) for s in subs]
    for d in eachindex(ks)
        k = ks[d]
        (k === nothing || 1 <= k <= ext[d]) ||
            _shape_remap_refuse(o, "subscript $(k) is out of range 1:$(ext[d]) on axis $(d)")
    end
    at(d, lo) = ks[d] === nothing ? _remap_shift(subs[d], lo) : IntExpr(Int64(ks[d] - 1 + lo))
    if o.op == "transpose"
        x = o.args[1]
        xlo, _ = _remap_operand_shape(x, rc; whole = true)
        perm = _transpose_perm(o, length(ext))
        xs = Vector{ASTExpr}(undef, length(ext))
        for d in eachindex(perm)
            xs[perm[d] + 1] = at(d, xlo[perm[d] + 1])
        end
        return OpExpr("index", ASTExpr[x, xs...])
    elseif o.op == "reshape"
        length(o.args) == 1 || _shape_remap_refuse(o, "reshape takes one operand")
        x = o.args[1]
        xs0 = _remap_operand_shape(x, rc)
        xs0 === nothing && _shape_remap_refuse(o, "the operand's shape is not known at build time")
        xlo, xext = xs0
        prod(xext) == prod(ext) ||
            _shape_remap_refuse(
            o, "shape $(ext) holds $(prod(ext)) elements but the " *
                "operand holds $(prod(xext))"
        )
        if all(k -> k !== nothing, ks)
            lin = 0; stride = 1
            for d in eachindex(ext)
                lin += (ks[d] - 1) * stride; stride *= ext[d]
            end
            xs = Vector{ASTExpr}(undef, length(xext))
            for d in eachindex(xext)
                xs[d] = IntExpr(Int64(xlo[d] + lin % xext[d]))
                lin ÷= xext[d]
            end
            return OpExpr("index", ASTExpr[x, xs...])
        end
        nz_t = [d for d in eachindex(ext) if ext[d] != 1]
        nz_x = [d for d in eachindex(xext) if xext[d] != 1]
        ext[nz_t] == xext[nz_x] ||
            _shape_remap_refuse(
            o, "a symbolic subscript through a reshape that reorders " *
                "elements needs integer division, which has no gather form"
        )
        xs = ASTExpr[IntExpr(Int64(xlo[d])) for d in eachindex(xext)]
        for (dt, dx) in zip(nz_t, nz_x)
            xs[dx] = at(dt, xlo[dx])
        end
        return OpExpr("index", ASTExpr[x, xs...])
    end
    # concat
    ax = something(o.axis, 0) + 1
    kax = ks[ax]
    kax === nothing &&
        _shape_remap_refuse(
        o, "a symbolic subscript on the joined axis selects an operand " *
            "per cell, which has no gather form"
    )
    off = 0
    for a in o.args
        plo, pext = _remap_operand_shape(a, rc)
        n = isempty(pext) ? 1 : pext[ax]
        if kax <= off + n
            isempty(pext) && return a
            xs = ASTExpr[
                d == ax ? IntExpr(Int64(kax - off - 1 + plo[d])) : at(d, plo[d])
                    for d in eachindex(pext)
            ]
            return OpExpr("index", ASTExpr[a, xs...])
        end
        off += n
    end
    return _shape_remap_refuse(o, "subscript $(kax) is past the joined axis")
end

# True iff a shape op is an operand of `e`, looking through elementwise ops.
_mentions_shape_op(e::ASTExpr) = e isa OpExpr && (
    (e::OpExpr).op in _SHAPE_REMAP_OPS ||
        (_is_scalar_op((e::OpExpr).op) && _anyof(_mentions_shape_op, (e::OpExpr).args))
)

# The subscripts one operand of an elementwise combination is gathered at, under
# the §4.3.4 positional rule: an operand of lower rank reads the leading
# subscripts, and an operand axis of extent 1 against a longer result axis reads
# its one element. `nothing` when the operand needs no adjustment.
function _broadcast_operand_subs(
        a::ASTExpr, subs::Vector{ASTExpr}, result_ext::Vector{Int}, rc::_ResolveCtx
    )
    s = _remap_operand_shape(a, rc)
    s === nothing && return nothing
    lo, ext = s
    length(ext) <= length(subs) || return nothing
    adj = length(ext) < length(subs)
    out = ASTExpr[subs[d] for d in eachindex(ext)]
    for d in eachindex(ext)
        if ext[d] == 1 && result_ext[d] > 1
            out[d] = IntExpr(Int64(lo[d])); adj = true
        end
    end
    return adj ? out : nothing
end
