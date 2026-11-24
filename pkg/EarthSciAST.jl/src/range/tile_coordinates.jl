# A reusable tile can use a loop coordinate as a numeric value. Turn those
# reads into live coordinate buffers before scalar folding or affine lowering.
# Subscripts keep the representative coordinates: state addresses are local
# to its layout and forcing addresses are rebased to its input windows.
_tile_coordinate_name(row) = "__tile_coord_$row"

function _tile_coordinate_scope(lhs::OpExpr, shape, spec)
    inner = lhs.expr_body
    inner isa OpExpr && !isempty(inner.args) || return Dict{String, Int}()
    idx = inner.args[1]
    # Both a derivative fill and an ordinary observed fill wrap their index.
    if idx isa OpExpr && idx.op == "index" && length(idx.args) == length(shape) + 1
        return _tile_coordinate_scope(idx.args[2:end], shape, spec)
    end
    return Dict{String, Int}()
end

function _tile_coordinate_scope(indices, shape, spec)
    return Dict{String, Int}(
        a.name => row for (a, set) in zip(indices, shape)
            if a isa VarExpr && haskey(spec.axes.cut, set)
            for row in (findfirst(==(spec.axes.cut[set][1]), spec.coordinate_axes),)
    )
end

function _tile_coordinate_expr(e::VarExpr, vars, spec)
    row = get(vars, e.name, 0)
    row == 0 && return e
    lower = first(spec.coordinate_boxes[row])
    i = lower == 1 ? e : OpExpr("-", ASTExpr[e, IntExpr(lower - 1)])
    return OpExpr("index", ASTExpr[VarExpr(_tile_coordinate_name(row)), i])
end
_tile_coordinate_expr(e::ASTExpr, vars, spec) = e

function _tile_coordinate_expr(e::OpExpr, vars, spec)
    isempty(vars) && return e
    if e.op == "index" && !isempty(e.args)
        # A producer's value expression may still refer to the enclosing index.
        # The subscripts themselves are resolved by the representative build.
        target = _tile_coordinate_expr(e.args[1], vars, spec)
        return reconstruct(e; args = ASTExpr[target; e.args[2:end]])
    end
    scoped = if e.ranges !== nothing
        filter(p -> !haskey(e.ranges, first(p)), vars)
    else
        vars
    end
    return map_children(x -> _tile_coordinate_expr(x, scoped, spec), e)
end

function _tile_coordinate_rhs(eq, shape, spec)
    isempty(spec.coordinate_axes) && return eq
    lhs = eq.lhs
    lhs isa OpExpr && _is_faq_op(lhs.op) || return eq
    vars = _tile_coordinate_scope(lhs, shape, spec)
    rhs = eq.rhs
    if rhs isa OpExpr && _is_faq_op(rhs.op) &&
            length(_output_idx_strings(rhs)) == length(_output_idx_strings(lhs))
        renamed = Dict{String, Int}()
        for (a, b) in zip(_output_idx_strings(lhs), _output_idx_strings(rhs))
            haskey(vars, a) && (renamed[b] = vars[a])
        end
        rhs = reconstruct(rhs; expr_body = _tile_coordinate_expr(rhs.expr_body, renamed, spec))
    else
        rhs = _tile_coordinate_expr(rhs, vars, spec)
    end
    return Equation(lhs, rhs; _comment = eq._comment)
end

function _tile_coordinate_obs(eq, n, spec)
    rhs = eq.rhs
    rhs isa OpExpr && _is_faq_op(rhs.op) && haskey(spec.ctx.shapes, n) || return eq
    shape = spec.ctx.shapes[n]
    indices = VarExpr.(_output_idx_strings(rhs))
    length(indices) == length(shape) || return eq
    vars = _tile_coordinate_scope(indices, shape, spec)
    rhs = reconstruct(rhs; expr_body = _tile_coordinate_expr(rhs.expr_body, vars, spec))
    return Equation(eq.lhs, rhs; _comment = eq._comment)
end

function _tile_coordinates!(spec, eqs, param_arrays)
    isempty(spec.coordinate_axes) && return eqs
    ctx = spec.ctx
    for (row, axis) in enumerate(spec.coordinate_axes)
        storage = spec.storage[axis]
        lo, hi = first(storage), last(storage)
        for (n, needs) in ctx.obs_need
            for (set, need) in zip(ctx.shapes[n], needs)
                haskey(spec.axes.cut, set) && spec.axes.cut[set][1] == axis || continue
                isempty(need.cells) && continue
                lo = min(lo, minimum(need.cells))
                hi = max(hi, maximum(need.cells))
            end
        end
        # Face sets can extend one position beyond the last cell center.
        any(a -> a == (axis, true), values(spec.axes.cut)) && (hi = max(hi, last(storage) + 1))
        spec.coordinate_boxes[row] = lo:hi
        param_arrays[_tile_coordinate_name(row)] = zeros(hi - lo + 1)
    end
    return map(eqs) do eq
        tgt = _d_target(eq.lhs)
        if tgt !== nothing && haskey(ctx.shapes, tgt)
            return _tile_coordinate_rhs(eq, ctx.shapes[tgt], spec)
        elseif eq.lhs isa VarExpr
            return _tile_coordinate_obs(eq, eq.lhs.name, spec)
        end
        return eq
    end
end
