# tree_walk/resolve.jl — `_resolve_indices`: an expression with every `index`
# resolved to a slot, a literal or a run-time gather, dispatched on what the
# `index` reads. The pieces it calls live in resolve_ctx.jl, aggregate_expand.jl,
# gather_resolve.jl, shape_ops.jl, resolve_loops.jl and resolve_producers.jl.

# Resolve each expression in `args`, returning `(resolved, changed)`. When no
# element changes under resolution the ORIGINAL `args` vector is returned (no
# allocation) and `changed` is false, letting the caller keep its node verbatim;
# only the first differing element triggers a single copy. Shared by the `index`
# fallback and the generic-recurse arm of `_resolve_indices`.
function _resolve_arg_vec(args::Vector{ASTExpr}, rc::_ResolveCtx)
    changed = false
    new_args = args
    @inbounds for i in eachindex(args)
        a = args[i]
        # Manual union split: the abstract element type would make a bare
        # `_resolve_indices(a, rc)` a dynamic dispatch. Literals resolve to
        # themselves.
        r = a isa OpExpr ? _resolve_indices(a::OpExpr, rc) :
            a isa VarExpr ? _resolve_indices(a::VarExpr, rc) :
            a
        if r !== a
            if !changed
                new_args = copy(args)
                changed = true
            end
            new_args[i] = r
        end
    end
    return new_args, changed
end

"""
    _resolve_indices(expr, array_var_info, var_map, const_arrays = ∅, pgather = ∅, memo = nothing, bound = ∅)
    _resolve_indices(expr, rc::_ResolveCtx)

`expr` with every `index` resolved to a state slot reference, a ghost cell's
`0.0`, a const literal, or a run-time gather marker, and every scalar `faq`
expanded. The positional form starts a resolve with no guards in force; every
recursion passes its `_ResolveCtx`.
"""
_resolve_indices(
    expr::ASTExpr,
    array_var_info::Dict{String, Tuple{Vector{Int}, Vector{Int}}},
    var_map::AbstractDict{String, Int},
    const_arrays::AbstractDict = _EMPTY_CONST_ARRAYS,
    pgather::AbstractDict = _EMPTY_PGATHER,
    memo::_MaybeMemo = nothing,
    bound_syms::Set{String} = _EMPTY_BOUND_SYMS
) = _resolve_indices(
    expr, _ResolveCtx(
        array_var_info, var_map, const_arrays, pgather, memo, bound_syms, false, _ResolveGuards()
    )
)

_resolve_indices(expr::NumExpr, ::_ResolveCtx) = expr
_resolve_indices(expr::IntExpr, ::_ResolveCtx) = expr
function _resolve_indices(expr::VarExpr, rc::_ResolveCtx)
    var_map, pgather, const_arrays = rc.var_map, rc.pgather, rc.const_arrays
    # A bare reference to a one-cell live forcing buffer (a discrete
    # provider's buffer for a 0-d data-fed parameter, which has no `p` slot)
    # reads the buffer, as `index(name, 1)` does. A state slot wins, a name a
    # faq body binds shadows the buffer, and a build-owned discrete cache is
    # not one.
    if !haskey(var_map, expr.name) && !(expr.name in rc.bound) &&
            haskey(pgather, expr.name)
        pg = pgather[expr.name]::_PGatherArray
        if !pg.cache && length(pg.flat) == 1
            return OpExpr(
                "index", ASTExpr[];
                value = _PGatherRef(pg.flat, 1, expr.name)
            )
        end
    end
    # A bare reference to a scalar const field (a 0-d or one-cell const array,
    # such as a pure-I/O loader field, esm-spec §4.3) folds to its value, as
    # `index(name, …)` does. A multi-element array left bare passes through.
    if !haskey(var_map, expr.name) && haskey(const_arrays, expr.name)
        arr = const_arrays[expr.name]
        if arr isa AbstractArray && length(arr) == 1
            return NumExpr(Float64(first(arr)))
        end
    end
    return expr
end
function _resolve_indices(expr::OpExpr, rc::_ResolveCtx)
    # The memo is keyed on node identity, which determines the result only
    # for one set of bound names: a symbolic resolve carries no memo or one of
    # its own (`_ResolveCtx.memo`).
    memo = rc.memo
    memo === nothing && return _resolve_indices_op(expr, rc)
    m = memo.resolve
    r = get(m, expr, nothing)
    r === nothing || return r
    n0 = memo.deferrals[]
    r = _resolve_indices_op(expr, rc)
    # A read deferred under a guard this node sits under is this context's
    # answer only: the same (interned) node reached unguarded must still raise
    # at build. A deferral under guards inside the node is the node's own.
    (memo.deferrals[] == n0 || isempty(rc.guards)) && (m[expr] = r)
    return r
end
function _resolve_indices_op(expr::OpExpr, rc::_ResolveCtx)
    # A template call resolves its arguments in this context; its body is
    # compiled once, apart (call.jl).
    _tpl_is_call(expr) && return _resolve_call_bindings(expr, rc)
    if _is_guarded_node_op(expr.op, length(expr.args)) &&
            expr.expr_body === nothing && expr.values === nothing
        return _resolve_guarded_op(expr, rc)
    end
    expr.op == "index" && return _resolve_index_op(expr, rc)
    if expr.op == "integral"
        r = _resolve_integral(expr, rc.array_var_info, rc.var_map)
        r === nothing || return r
    end
    # A scalar aggregate (empty output_idx) expands inline. A non-scalar one
    # outside an `index` passes through to `_compile`, which refuses it.
    if _is_faq_op(expr.op) && isempty(_output_idx_strings(expr))
        return _resolve_scalar_faq(expr, rc)
    end
    new_args, changed = _resolve_arg_vec(expr.args, rc)
    new_body = expr.expr_body
    if expr.expr_body !== nothing
        new_body = _resolve_indices(expr.expr_body, rc)
        changed |= new_body !== expr.expr_body
    end
    new_values = expr.values
    if expr.values !== nothing
        nv, vchanged = _resolve_arg_vec(expr.values, rc)
        new_values = nv
        changed |= vchanged
    end
    # Nothing changed: the node is already resolved and is returned as is.
    changed || return expr
    return reconstruct(expr; args = new_args, expr_body = new_body, values = new_values)
end


# ---- `index(target, k…)` --------------------------------------------------
# What `index(target, …)` indexes, judged from the form of `target` alone (a
# name's array source is `_array_source`). The order is significant: an inline
# `const` array is tested before the elementwise case, and every operator
# form before a name. The range analyses (src/range/) classify their targets
# with the same function.
@enum _IndexTarget::UInt8 begin
    _IT_FAQ             # a faq producer: its body at the output indices
    _IT_MAKEARRAY       # a makearray: the covering region's value
    _IT_SHAPE_OP        # reshape / transpose / concat: an index map onto the operand
    _IT_CONST_ARRAY     # an inline non-scalar `const`
    _IT_INDEX           # a nested `index`
    _IT_ELEMENTWISE     # an elementwise operator: the index pushes into its array operands
    _IT_NAME            # a variable name
    _IT_OTHER
end

function _index_target_kind(t::ASTExpr)::_IndexTarget
    t isa VarExpr && return _IT_NAME
    t isa OpExpr || return _IT_OTHER
    o = t::OpExpr
    _is_faq_op(o.op) && return _IT_FAQ
    o.op == "makearray" && return _IT_MAKEARRAY
    o.op in _SHAPE_REMAP_OPS && return _IT_SHAPE_OP
    o.op == "const" && return o.value isa AbstractVector ? _IT_CONST_ARRAY : _IT_OTHER
    o.op == "index" && return _IT_INDEX
    _is_scalar_op(o.op) && return _IT_ELEMENTWISE
    return _IT_OTHER
end

# Where the name `n` reads array values from, in the one precedence the
# resolve uses: an array state, a live forcing buffer, a const array (`:const`
# also for a scalar const field, which `_is_scalar_const_field` tells apart), or
# `:none`.
function _array_source(n::AbstractString, array_var_info, pgather, const_arrays)::Symbol
    haskey(array_var_info, n) && return :state
    haskey(pgather, n) && return :forcing
    haskey(const_arrays, n) && return :const
    return :none
end

# Whether the name `n` holds an array value (a scalar const field does not).
_array_name(n::AbstractString, array_var_info, pgather, const_arrays) =
    (
    s = _array_source(n, array_var_info, pgather, const_arrays);
    s === :state || s === :forcing || (s === :const && !_is_scalar_const_field(const_arrays[n]))
)

function _resolve_index_op(expr::OpExpr, rc::_ResolveCtx)
    array_var_info, const_arrays, pgather = rc.array_var_info, rc.const_arrays, rc.pgather
    isempty(expr.args) &&
        throw(TreeWalkError("E_TREEWALK_INDEX_EMPTY", "index op requires at least one arg"))
    target = expr.args[1]
    subs = expr.args[2:end]
    kind = _index_target_kind(target)
    if kind === _IT_FAQ
        # Expanded at build time by substituting the output indices and
        # unrolling the contracted ones, as `_compile_faq_percell!` does for a
        # whole-array derivative equation.
        return _resolve_index_of_faq(target::OpExpr, subs, rc)
    elseif kind === _IT_MAKEARRAY
        # The value whose region covers (k1, …); later regions win.
        return _resolve_index_of_makearray(target::OpExpr, subs, rc)
    elseif kind === _IT_SHAPE_OP
        return _resolve_indices(_index_through_shape_op(target::OpExpr, subs, rc), rc)
    elseif kind === _IT_ELEMENTWISE
        r = _resolve_index_of_elementwise(target::OpExpr, subs, rc)
        r === nothing || return r
    elseif kind === _IT_CONST_ARRAY
        return _resolve_index_of_inline_const(target::OpExpr, subs, rc)
    elseif kind === _IT_NAME
        n = (target::VarExpr).name
        src = _array_source(n, array_var_info, pgather, const_arrays)
        src === :state && return _resolve_index_of_state(n, subs, rc)
        src === :forcing && return _resolve_index_of_forcing(n, subs, rc)
        # Pre-computed constant arrays: run-time and constant subscripts alike
        # go through `_resolve_const_array_gather`.
        src === :const && return _resolve_const_array_gather(const_arrays[n], n, subs, rc)
    end
    # A scalar or unknown target: resolve the arguments only.
    new_args, changed = _resolve_arg_vec(expr.args, rc)
    changed || return expr
    return reconstruct(expr; args = new_args)
end

# Expression-position ELEMENTWISE COMBINATION:
#     index(op(a, b, ...), k1, k2, ...)  ->  op(index(a, k...), index(b, k...), ...)
#
# Indexing an elementwise combination IS the combination of the indexed
# operands, so distributing is exact, not an approximation. Only operands
# that are themselves array-valued are wrapped; a scalar operand (a
# literal, a scalar parameter) broadcasts and must be left alone, exactly
# as it does under the §4.3.4 name-aligned rules.
#
# Without this, an observed whose expression COMBINES array-valued
# subexpressions cannot be indexed at all. The motivating case is a
# column integral of a discretised operator:
#     divh = D(Mx, lon) + D(My, lat)            # two lowered stencils
#     divh_col = aggregate_k index(divh, i, j, k)
# `divh` inlines to `+(makearray, makearray)`, the `+` has no index
# handler, so the generic recurse below walked INTO the makearrays and
# their stencils' own bound `i`/`j`/`k` — which the aggregate above never
# binds — escaped as `E_TREEWALK_UNBOUND_LOOP_VAR: j`. The two single-node
# cases (`index(aggregate,…)`, `index(makearray,…)`) were already handled
# right above; this closes the combination case they left open. `nothing`
# when no operand is array-valued.
function _resolve_index_of_elementwise(fa::OpExpr, subs::Vector{ASTExpr}, rc::_ResolveCtx)
    # The operand test is `_index_pushdown_arrayish` (build_helpers.jl),
    # shared with `_stencilize_index`: it looks THROUGH nested elementwise
    # ops, so `index(1 + cos(pi*zc), j)` — an elementwise-defined array
    # observed folded into a reader that gathers it — distributes down to
    # `1 + cos(pi*index(zc, j))` instead of dropping the gather and
    # leaving `zc` bare. The leaf test spans every array source an index
    # can gather (`_array_name`).
    _leaf_is_array(n) = _array_name(n, rc.array_var_info, rc.pgather, rc.const_arrays)
    _amemo = IdDict{OpExpr, Bool}()
    _arrayish(a) = _index_pushdown_arrayish(a, _leaf_is_array, _amemo)
    if _anyof(_arrayish, fa.args)
        # A combination with a shape-op operand is anonymous, and its
        # operands broadcast positionally (§4.3.4): each reads the
        # subscripts its own shape admits. A combination of variables
        # alone is left to the name-aligned lift, which has already
        # written each operand's own subscripts.
        fshape = _mentions_shape_op(fa) ? _remap_operand_shape(fa, rc) : nothing
        rext = fshape === nothing ? nothing : fshape[2]
        _subs_for(a) = (rext === nothing || length(rext) != length(subs)) ? subs :
            something(_broadcast_operand_subs(a, subs, rext, rc), subs)
        pushed = ASTExpr[
            _arrayish(a) ? OpExpr("index", ASTExpr[a, _subs_for(a)...]) : a
                for a in fa.args
        ]
        return _resolve_indices(reconstruct(fa; args = pushed), rc)
    end
    return nothing
end

# Expression-position INLINE `const` array literal:
# index({op:const, value:[…]}, k1, …). A non-scalar `const` used as an
# index target (e.g. the duo's `index({const [n][3][3]}, gt, d, k)`) is
# build-time literal data — the same shape as a REGISTERED const-array
# observed, only authored inline. Intern it (dedup by value) and gather it
# through the shared const-array path so a constant index folds to the
# element and a symbolic loop var lowers to a `_ConstGatherRef`. A scalar
# `const` is not an array target; it const-folds in `_compile`.
function _resolve_index_of_inline_const(c::OpExpr, subs::Vector{ASTExpr}, rc::_ResolveCtx)
    memo, const_arrays = rc.memo, rc.const_arrays
    vals, cname = memo === nothing ?
        _intern_inline_const(c, const_arrays) :
        get!(() -> _intern_inline_const(c, const_arrays), memo.inline, c)
    return _resolve_const_array_gather(vals, cname, subs, rc)
end

# `index(v, k…)` of an array state `v`: the cell's state reference, a ghost
# cell's `0.0`, or a run-time state gather when a subscript is only known per
# call.
function _resolve_index_of_state(vname::String, idx_args::Vector{ASTExpr}, rc::_ResolveCtx)
    var_map, const_arrays = rc.var_map, rc.const_arrays
    lo, hi = rc.array_var_info[vname]
    length(idx_args) == length(lo) ||
        throw(
        TreeWalkError(
            "E_TREEWALK_INDEX_NDIM",
            "$(vname) has $(length(lo))D but got $(length(idx_args)) index args"
        )
    )
    # Runtime state gather: a subscript depends on
    # a contraction loop variable, so the slot is not a build-time constant.
    # Lower to `_NK_STATE_GATHER` (the state-source loop case). Fires ONLY on
    # the loop-build path (`__esm_lv_*` names); the concrete path below is
    # untouched otherwise.
    # A subscript computed at run time from a parameter, a state or an
    # observed (bound symbols keep their own path) reads its slot the
    # same way.
    if any(
            a -> _refs_loopvar(a) || _subscript_is_runtime(a, rc.bound, const_arrays),
            idx_args
        )
        return _resolve_state_gather(vname, lo, hi, idx_args, rc)
    end
    # Pass const_arrays so nested index expressions like u[conn[c,k]] can be
    # resolved: _eval_const_int will look up conn[c,k] as an integer. A
    # lookup out of range under a guard the build cannot show taken
    # reads its slot at run time instead (see `_resolve_guarded_op`).
    indices = try
        [_eval_const_int(a, _EMPTY_IDX_ENV, const_arrays) for a in idx_args]
    catch err
        (
            err isa TreeWalkError && err.code == "E_TREEWALK_CONSTARRAY_OOB" &&
                _guarded_oob_deferred(rc)
        ) ||
            rethrow()
        return _resolve_state_gather(vname, lo, hi, idx_args, rc)
    end
    for d in 1:length(indices)
        if indices[d] < lo[d] || indices[d] > hi[d]
            return NumExpr(0.0)  # ghost cell
        end
    end
    cname = _cell_key(vname, indices)
    haskey(var_map, cname) ||
        throw(TreeWalkError("E_TREEWALK_MISSING_CELL", cname))
    return VarExpr(cname)
end

# Live forcing buffer bound via `param_arrays`: reroute
# this gather to a LIVE read instead of the frozen const-fold below. The
# array is a discrete-cadence loader buffer (the driver routes const-cadence
# data to `const_arrays` and discrete-cadence data here), so its contents
# change at refresh boundaries and MUST NOT be inlined as a build-time
# literal. Bounds-check and column-major-linearize the constant indices at
# build time, then carry the aliased flat buffer + the offset to `_compile`
# (which emits a `_NK_PARAM_GATHER`) as a typed `_PGatherRef` in `value`.
# The ref also carries the buffer's registry NAME, which is what gives the
# gather a canonicalizable CSE identity — `index` being CSE-opaque only stops
# the gather from being hoisted itself, it does NOT keep the ref out of
# `canonical_json`, which sees it as a child of every hoistable ancestor
# (see `_PGatherRef` in node.jl / `_pgather_key_expr` in scalar_cse.jl).
function _resolve_index_of_forcing(name::String, idx_args_expr::Vector{ASTExpr}, rc::_ResolveCtx)
    const_arrays = rc.const_arrays
    pg = rc.pgather[name]::_PGatherArray
    length(idx_args_expr) == length(pg.dims) ||
        throw(
        TreeWalkError(
            "E_TREEWALK_PGATHER_NDIM",
            "forcing array '$(name)' is $(length(pg.dims))D " *
                "but got $(length(idx_args_expr)) indices"
        )
    )
    # A subscript a symbolic resolve keeps symbolic (a contraction's loop
    # counter, `F[i]`) has no build-time value: the gather stays a read of
    # the live buffer at an offset computed per call (`_LiveGatherRef`),
    # with each constant subscript bounds-checked here as below. Only
    # loop counters and literals qualify; any other run-time subscript
    # (one reading a state, a parameter or `t`) is refused below.
    if _is_symbolic(rc) &&
            _anyof(a -> _subscript_is_runtime(a, const_arrays), idx_args_expr) &&
            all(
            a -> !_subscript_is_runtime(a, const_arrays) ||
                _subscript_from_counters(a, rc.bound),
            idx_args_expr
        )
        sub_nodes = Vector{ASTExpr}(undef, length(idx_args_expr))
        for d in eachindex(idx_args_expr)
            a = idx_args_expr[d]
            if _subscript_is_runtime(a, const_arrays)
                sub_nodes[d] = _resolve_indices(a, rc)
            else
                ci = _eval_const_int(a, _EMPTY_IDX_ENV, const_arrays)
                # Out of range under a guard the build cannot show
                # taken: the run-time gather checks it if evaluated.
                (1 <= ci <= pg.dims[d]) || _guarded_oob_deferred(rc) ||
                    _throw_pgather_oob(name, ci, pg.dims[d], d)
                sub_nodes[d] = IntExpr(Int64(ci))
            end
        end
        return OpExpr(
            "index", sub_nodes;
            value = _LiveGatherRef(pg.flat, pg.dims, name)
        )
    end
    int_indices = [
        _eval_const_int(a, _EMPTY_IDX_ENV, const_arrays)
            for a in idx_args_expr
    ]
    for d in 1:length(pg.dims)
        (1 <= int_indices[d] <= pg.dims[d]) && continue
        # The guarded out-of-range rule (above): a read the build
        # cannot show evaluated becomes the run-time gather, which
        # raises the same error if it is.
        _guarded_oob_deferred(rc) && return OpExpr(
            "index", ASTExpr[IntExpr(Int64(i)) for i in int_indices];
            value = _LiveGatherRef(pg.flat, pg.dims, name)
        )
        _throw_pgather_oob(name, int_indices[d], pg.dims[d], d)
    end
    lin = LinearIndices(Tuple(pg.dims))[int_indices...]
    return OpExpr(
        "index", ASTExpr[];
        value = _PGatherRef(pg.flat, lin, name)
    )
end

# `integral(u, var = x)` by Euler/midpoint quadrature, `dx * Σ u[k]`, when the
# integrand is a 1-D array state; `nothing` otherwise (a scalar integrand
# resolves as any other operator).
function _resolve_integral(expr::OpExpr, array_var_info, var_map)
    isempty(expr.args) &&
        throw(
        TreeWalkError(
            "E_TREEWALK_INTEGRAL_EMPTY",
            "integral op requires at least one arg"
        )
    )
    integrand = expr.args[1]
    iv = expr.int_var
    iv === nothing &&
        throw(
        TreeWalkError(
            "E_TREEWALK_INTEGRAL_NO_INTVAR",
            "integral op requires `var` field (integration variable name)"
        )
    )
    if integrand isa VarExpr && haskey(array_var_info, integrand.name)
        vname = integrand.name
        lo_vec, hi_vec = array_var_info[vname]
        length(lo_vec) == 1 ||
            throw(
            TreeWalkError(
                "E_TREEWALK_INTEGRAL_NDIM",
                "euler_integral supports 1D integration only; " *
                    "'$vname' has $(length(lo_vec)) dimensions"
            )
        )
        lo1 = lo_vec[1]; hi1 = hi_vec[1]
        cells = ASTExpr[VarExpr(_cell_key(vname, [i])) for i in lo1:hi1]
        for c in cells
            cname = (c::VarExpr).name
            haskey(var_map, cname) ||
                throw(TreeWalkError("E_TREEWALK_MISSING_CELL", cname))
        end
        return OpExpr("*", ASTExpr[VarExpr("d$(iv)"), OpExpr("+", cells)])
    end
    return nothing
end

function _resolve_call_bindings(expr::OpExpr, rc::_ResolveCtx)
    # Every argument is resolved here, implicit ones included (a name the body
    # reads from its caller resolves as it would where expansion put it: a
    # scalar const field folds to its value).
    expr = _call_with_implicit(expr)
    b = expr.bindings
    b === nothing && return expr
    nb = b
    for (k, v) in b
        r = v isa OpExpr ? _resolve_indices(v::OpExpr, rc) :
            v isa VarExpr ? _resolve_indices(v::VarExpr, rc) : v
        if r !== v
            nb === b && (nb = copy(b))
            nb[k] = r
        end
    end
    return nb === b ? expr : reconstruct(expr; bindings = nb)
end
