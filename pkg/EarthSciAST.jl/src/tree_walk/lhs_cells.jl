# tree_walk/lhs_cells.jl — part of the tree-walk evaluator: which state
# variables are arrays, the cells an equation's left-hand side writes, the
# classification of a derivative left-hand side, and model selection.

# Detect which state variables are used in array context (inside index ops)
# by scanning equation LHS patterns and initial_condition keys.
function _detect_array_vars(
        equations::Vector{Equation},
        state_var_names::Set{String},
        initial_conditions::AbstractDict
    )
    detected = Set{String}()
    # From initial conditions: "u[3]" style keys imply array usage.
    _foreach_ic_cell(
        initial_conditions,
        (vname, _) -> (vname in state_var_names && push!(detected, vname)),
        (vname, _, _) -> (vname in state_var_names && push!(detected, vname))
    )
    # From equation LHS patterns.
    for eq in equations
        lhs = eq.lhs
        if _is_indexed_D_lhs(lhs)
            inner = (lhs::OpExpr).args[1]::OpExpr
            first_arg = inner.args[1]
            if first_arg isa VarExpr && first_arg.name in state_var_names
                push!(detected, first_arg.name)
            end
        elseif lhs isa OpExpr && _is_faq_op(lhs.op)
            body = lhs.expr_body
            if body isa OpExpr && body.op == "D" && !isempty(body.args)
                inner = body.args[1]
                if inner isa OpExpr && inner.op == "index" && !isempty(inner.args)
                    fa = inner.args[1]
                    if fa isa VarExpr && fa.name in state_var_names
                        push!(detected, fa.name)
                    end
                end
            end
        end
    end
    return detected
end

# Scan equations and initial_conditions to discover all array cells.
# Returns Dict{String,_DiscoveredCells}: var_name → the cells its equation LHSs and
# per-cell initial-condition keys name. A `faq` LHS whose subscripts are each a
# constant or ±(one loop index) + constant, with no loop index shared between
# subscripts, names a box, recorded arithmetically; any other LHS is enumerated
# cell by cell.
function _discover_array_cells(
        equations::Vector{Equation},
        initial_conditions::AbstractDict,
        array_var_names::Set{String}
    )
    cells = Dict{String, _DiscoveredCells}()

    # From initial conditions: "u[3]" or "u[2,3]" style keys, and whole inline
    # array profiles.
    _foreach_ic_cell(
        initial_conditions,
        (vname, indices) -> (
            vname in array_var_names &&
                _cellset_push_point!(get!(_DiscoveredCells, cells, vname), indices, vname)
        ),
        (vname, lo, hi) -> (
            vname in array_var_names &&
                _cellset_push_box!(get!(_DiscoveredCells, cells, vname), lo, hi, vname)
        )
    )

    # From equation LHS.
    for eq in equations
        _scan_lhs_cells!(cells, eq.lhs, array_var_names)
    end
    return cells
end

# The affine form `coef * loop_index[pos] + c` of an index expression, as
# `(pos, coef, c)` with `pos = 0` for a constant, or `nothing` when the
# expression is not one (`_affine_form`, with no subexpression moving with two
# different loop indices).
function _lhs_index_affine(a::ASTExpr, idx_names::Vector{String})
    f = _affine_form(a, idx_names; single = true)
    f === nothing && return nothing
    pos = findfirst(!iszero, f.c)
    return pos === nothing ? (0, 0, f.c0) : (pos, f.c[pos], f.c0)
end

# The box a `faq` LHS's subscripts sweep over `range_iters`, as `(lo, hi)`, or
# `nothing` when the cells do not form a box (a stride other than ±1, a loop
# index in two subscripts, or a subscript `_lhs_index_affine` cannot read).
# Only called with every range non-empty.
function _lhs_cells_box(idx_args, idx_names::Vector{String}, range_iters)
    n = length(idx_args)
    lo = Vector{Int}(undef, n)
    hi = Vector{Int}(undef, n)
    used = falses(length(idx_names))
    for d in 1:n
        t = _lhs_index_affine(idx_args[d], idx_names)
        t === nothing && return nothing
        pos, coef, k = t
        if pos == 0
            lo[d] = hi[d] = k
            continue
        end
        used[pos] && return nothing
        used[pos] = true
        r = range_iters[pos]
        (length(r) == 1 || step(r) == 1 || step(r) == -1) || return nothing
        (coef == 1 || coef == -1 || length(r) == 1) || return nothing
        a = coef * first(r) + k
        b = coef * last(r) + k
        lo[d] = min(a, b)
        hi[d] = max(a, b)
    end
    return lo, hi
end

function _scan_lhs_cells!(cells, lhs::ASTExpr, array_var_names::Set{String})
    if _is_time_derivative(lhs) &&
            length(lhs.args) == 1 && lhs.args[1] isa OpExpr &&
            lhs.args[1].op == "index"
        # D(index(var, k...))
        inner = lhs.args[1]
        first_arg = inner.args[1]
        first_arg isa VarExpr || return
        first_arg.name in array_var_names || return
        idx_args = inner.args[2:end]
        try
            indices = [_eval_const_int(a, _EMPTY_IDX_ENV) for a in idx_args]
            vname = first_arg.name
            _cellset_push_point!(get!(_DiscoveredCells, cells, vname), indices, vname)
        catch err
            # A non-constant index expression is simply not discoverable here
            # (the faq path enumerates it); anything else is a real bug.
            err isa TreeWalkError || rethrow()
        end
        return
    end
    if lhs isa OpExpr && _is_faq_op(lhs.op)
        # aggregate(expr=D(index(var, idx_exprs...)), output_idx=[...], ranges={...})
        lhs_body = lhs.expr_body
        lhs_body === nothing && return
        _is_time_derivative(lhs_body) &&
            length(lhs_body.args) == 1 && lhs_body.args[1] isa OpExpr &&
            lhs_body.args[1].op == "index" || return
        inner = lhs_body.args[1]
        first_arg = inner.args[1]
        first_arg isa VarExpr || return
        first_arg.name in array_var_names || return
        vname = first_arg.name

        idx_names = _output_idx_strings(lhs)
        ranges_dict = _ranges_dict(lhs)
        range_iters = [_expand_int_range(ranges_dict[n]) for n in idx_names]

        cs = get!(_DiscoveredCells, cells, vname)
        any(isempty, range_iters) && return
        idx_args = inner.args[2:end]
        box = _lhs_cells_box(idx_args, idx_names, range_iters)
        if box !== nothing
            _cellset_push_box!(cs, box[1], box[2], vname)
            return
        end
        try
            idx_env = Dict{String, Int}()
            indices = Vector{Int}(undef, length(idx_args))
            for idx_tuple in Iterators.product(range_iters...)
                for d in 1:length(idx_names)
                    idx_env[idx_names[d]] = idx_tuple[d]
                end
                for d in eachindex(idx_args)
                    indices[d] = _eval_const_int(idx_args[d], idx_env)
                end
                _cellset_push_point!(cs, indices, vname)
            end
        catch err
            # An index expression that is not constant under the loop bindings
            # is not discoverable here; anything else is a real bug.
            err isa TreeWalkError || rethrow()
        end
        return
    end
end

# Every LHS predicate below reads "is this a time derivative?" through
# `_is_time_derivative`, which applies esm-spec §4.2's default: an ABSENT `wrt`
# MEANS `t`. Spelling the test `lhs.wrt == "t"` dropped that default on this
# pathway while `classification.jl` kept it, so the tree-walk runner refused
# `{"op": "D", "args": ["z"]}` with `E_TREEWALK_UNSUPPORTED_EQUATION` for a
# document `ode_states` had already reported `z` as a state of
# (EarthSciAST#407).

# Identify D(scalar_var) — the classic scalar ODE LHS.
function _is_scalar_D_lhs(lhs)
    return _is_time_derivative(lhs) &&
        length(lhs.args) == 1 && isa(lhs.args[1], VarExpr)
end

# Identify D(index(var, k...)) — indexed scalar derivative.
function _is_indexed_D_lhs(lhs)
    return _is_time_derivative(lhs) &&
        length(lhs.args) == 1 &&
        isa(lhs.args[1], OpExpr) && lhs.args[1].op == "index"
end

# Identify faq(D(index(var, ...)), ...) — array-loop derivative LHS.
function _is_faq_D_lhs(lhs)
    lhs isa OpExpr && _is_faq_op(lhs.op) || return false
    body = lhs.expr_body
    body === nothing && return false
    return _is_time_derivative(body) &&
        length(body.args) == 1 &&
        body.args[1] isa OpExpr && body.args[1].op == "index"
end

# Extract the scalar body from a faq node (or return expr unchanged).
# Used to unwrap the RHS of a faq equation.
function _extract_faq_body(expr::ASTExpr)
    if expr isa OpExpr && _is_faq_op(expr.op)
        expr.expr_body !== nothing && return expr.expr_body
    end
    return expr
end

function _select_model(file::EsmFile, name::Union{Nothing, AbstractString})
    file.models === nothing &&
        throw(TreeWalkError("E_TREEWALK_NO_MODEL", "EsmFile.models is nothing"))
    models = file.models
    if name !== nothing
        haskey(models, String(name)) ||
            throw(TreeWalkError("E_TREEWALK_NO_MODEL", String(name)))
        return models[String(name)]
    end
    length(models) == 1 ||
        throw(
        TreeWalkError(
            "E_TREEWALK_AMBIGUOUS_MODEL",
            "specify model_name; have: " *
                join(collect(keys(models)), ", ")
        )
    )
    return first(values(models))
end
