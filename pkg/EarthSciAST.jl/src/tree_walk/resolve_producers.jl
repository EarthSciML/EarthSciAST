# tree_walk/resolve_producers.jl — `index(faq, …)` and `index(makearray, …)`
# in expression position: the producer read at a cell.

# Resolve index(faq(...), k1, k2, ...) in expression position by
# substituting the output_idx values and unrolling contracted indices at
# build time. Mirrors the LHS-faq expansion (`_compile_faq_percell!`) but
# produces a scalar ASTExpr instead of writing to rhs_list.
function _resolve_index_of_faq(faq_expr::OpExpr, idx_args::Vector{ASTExpr}, rc::_ResolveCtx)
    const_arrays = rc.const_arrays
    output_idx_strs = _output_idx_strings(faq_expr)
    length(output_idx_strs) == length(idx_args) ||
        throw(
        TreeWalkError(
            "E_TREEWALK_ARRAYOP_INDEX_NDIM",
            "faq output_idx has $(length(output_idx_strs)) dims " *
                "but $(length(idx_args)) index args"
        )
    )
    body = faq_expr.expr_body
    body === nothing &&
        throw(
        TreeWalkError(
            "E_TREEWALK_ARRAYOP_NO_BODY",
            "faq requires an expr body"
        )
    )
    ranges_dict = _ranges_dict(faq_expr)
    oplus, zerobar = _aggregate_oplus_identity(faq_expr.semiring, faq_expr.reduce)

    # Output-index substitution. Each output-index arg is EITHER a bound symbol —
    # kept SYMBOLIC, substituted as its own resolved-in-place expression so the
    # unrolled body reads `A[c, <sym>]` and lowers to a runtime `_ConstGatherRef`
    # — OR a build-time constant, folded to an `IntExpr`. With no bound
    # names every arg is constant.
    nd = length(output_idx_strs)
    symbolic = falses(nd)
    k_vals = Vector{Int}(undef, nd)
    idx_exprs = Dict{String, ASTExpr}()
    for d in 1:nd
        a = idx_args[d]
        if _subscript_is_runtime(a, const_arrays)
            symbolic[d] = true
            idx_exprs[output_idx_strs[d]] = a           # keep symbolic
        else
            k_vals[d] = _eval_const_int(a, _EMPTY_IDX_ENV, const_arrays)
            idx_exprs[output_idx_strs[d]] = IntExpr(Int64(k_vals[d]))
        end
    end
    any_symbolic = any(symbolic)
    sub_body = _sub_preserving(body, idx_exprs)

    # Contracted indices: all range keys NOT appearing in output_idx. A
    # contracted bound may be *expression-valued* — see `_expand_contract_range`;
    # the parent index of a ragged bound is one of THIS gather's output indices,
    # so a ragged bound is evaluable ONLY when that parent index is CONCRETE. In
    # symbolic mode a ragged bound over a symbolic output index has no concrete
    # value in `_out_idx_env`, so `_expand_int_range_dyn` throws `unbound loop var`
    # and the compile-once fast path falls back — exactly the intended coverage.
    contract_names = _contracted_index_names(ranges_dict, output_idx_strs)
    _out_idx_env = Dict{String, Int}(
        output_idx_strs[d] => k_vals[d]
            for d in 1:nd if !symbolic[d]
    )
    # A ragged bound over a symbolic output index becomes a run-time loop
    # (`_NK_RAGGED_LOOP`), which reads the bound at the cell the call is at.
    if any_symbolic && _is_symbolic(rc) &&
            any(n -> !_is_const_int_range(ranges_dict[n]), contract_names)
        return _resolve_ragged_faq_loop(
            faq_expr, sub_body, ranges_dict, idx_exprs, contract_names, oplus, zerobar, rc
        )
    end
    gates = faq_expr.join_gates
    contract_iters = _contract_iters_at(
        contract_names, [ranges_dict[n] for n in contract_names], _out_idx_env,
        const_arrays; canonical = _has_equality_join(gates)
    )

    filt0 = faq_expr.filter
    # Build-time join gates need CONCRETE output-index bindings (the join
    # binding is seeded from `_out_idx_env`). A symbolic output index has none,
    # so refuse the fast path here — the compile-once wrapper catches this and
    # falls back to the exact per-cell expansion (concrete mode is unaffected).
    # A filter is a run-time guard on each term either way: substituted with
    # the symbolic output index it is the `ifelse(pred, term, 0̄)` the concrete
    # expansion builds, over the same terms in the same order (`_window_iters`
    # judges the order on the unsubstituted filter), so the taken branch of
    # each term is the concrete term.
    any_symbolic && gates !== nothing &&
        throw(
        TreeWalkError(
            "E_TREEWALK_COMPILE_ONCE_UNSUPPORTED",
            "aggregate join_gates are not supported on the symbolic " *
                "compile-once path; falling back to per-cell resolution"
        )
    )
    if isempty(contract_names) && gates === nothing && filt0 === nothing
        return _resolve_indices(sub_body, rc)
    end

    # Join/filter expansion via the shared core; the filter carries the (fixed)
    # output-index substitution already, matching the hoisted `sub_body`. The
    # terms resolve under the same bound names, so the symbolic subscripts
    # survive into `_ConstGatherRef`s.
    filt = filt0 === nothing ? nothing : _sub_preserving(filt0, idx_exprs)
    contract_iters = _window_iters(contract_iters, filt0, contract_names, output_idx_strs)
    terms = ASTExpr[]
    _foreach_aggregate_term(
        sub_body, contract_names, contract_iters,
        gates, filt, zerobar, _out_idx_env
    ) do term
        push!(terms, _resolve_indices(term, rc))
    end
    if isempty(contract_names) && gates !== nothing
        return isempty(terms) ? NumExpr(zerobar) : only(terms)
    end
    return _combine_with_reducer(oplus, zerobar, terms)
end

# The symbolic form of a gather of a ragged contraction, `index(faq, i)` with
# `i` a loop counter of the whole-array contraction tier and the contracted range
# `[lo, hi]` an expression in `i` (a ragged set's `[1, index(offsets, i)]`):
# one `__ragged_loop` marker whose bounds are resolved like any other subscript,
# so the offsets read is a run-time const gather at the call's cell, and whose
# body is resolved once with the contracted index a loop counter. Each call then
# folds the cell's own row, `hi - lo + 1` terms, the CSR shape.
#
# The terms, their order and their fold are those of the per-cell expansion
# below (`_foreach_aggregate_term` then `_combine_with_reducer`), which is what
# the interpreter builds at a concrete cell. Taken only for one contracted
# index with no join and no filter; anything else declines with
# `E_TREEWALK_COMPILE_ONCE_UNSUPPORTED`, as the symbolic path always has.
function _resolve_ragged_faq_loop(
        faq_expr::OpExpr, sub_body::ASTExpr, ranges_dict,
        idx_exprs::Dict{String, ASTExpr}, contract_names::Vector{String},
        oplus::String, zerobar::Float64, rc::_ResolveCtx
    )
    decline(why) = throw(
        TreeWalkError(
            "E_TREEWALK_COMPILE_ONCE_UNSUPPORTED",
            "ragged contraction on the symbolic compile-once path: " * why
        )
    )
    length(contract_names) == 1 || decline("more than one contracted index")
    (faq_expr.join_gates === nothing && faq_expr.filter === nothing) ||
        decline("a join or a filter")
    _is_numeric_reducer(oplus) || decline("⊕ = $(oplus)")
    rspec = ranges_dict[contract_names[1]]
    rspec isa AbstractVector && length(rspec) in (2, 3) || decline("range arity")
    step = 1
    if length(rspec) == 3
        rspec[2] isa Integer || decline("a step that is not a constant integer")
        step = Int(rspec[2])
        step == 0 && decline("a zero step")
    end
    own = _derive(rc; memo = nothing)
    bound(x) = x isa Integer ? IntExpr(Int64(x)) :
        x isa ASTExpr ? _resolve_indices(_sub_preserving(x, idx_exprs), own) :
        decline("a bound that is not an integer or an expression")
    lo = bound(rspec[1])
    hi = bound(rspec[end])
    kname = _fresh_loopvar_name()
    kref = Ref(0)
    body = _sub_preserving(
        sub_body,
        Dict{String, ASTExpr}(contract_names[1] => VarExpr(kname))
    )
    resolved = _resolve_indices(body, _derive(own; bound = union(rc.bound, Set{String}((kname,)))))
    _register_loopvar!(kname, kref)
    return OpExpr(
        "__ragged_loop", ASTExpr[resolved, lo, hi];
        value = _Lowered(
            _NK_RAGGED_LOOP, Symbol(oplus), zerobar,
            _RaggedLoop(kref, step, _ragged_reach(rspec, rc.const_arrays))
        )
    )
end

# The mean row length of a ragged range `[1, index(offsets, …)]` over a const
# offsets array, for the threading verdict's work estimate; 1 when the bound is
# any other expression.
function _ragged_reach(rspec, const_arrays::AbstractDict)
    hi = rspec[end]
    (
        rspec[1] == 1 && hi isa OpExpr && (hi::OpExpr).op == "index" &&
            !isempty((hi::OpExpr).args) && (hi::OpExpr).args[1] isa VarExpr
    ) || return 1
    arr = get(const_arrays, ((hi::OpExpr).args[1]::VarExpr).name, nothing)
    (arr isa AbstractArray{<:Real} && !isempty(arr)) || return 1
    m = _dynamic(a -> sum(Float64, a) / length(a), arr)::Float64
    return isfinite(m) ? max(1, round(Int, m)) : 1
end

# Resolve index(makearray(regions=[...], values=[...]), k1, k2, ...) by
# selecting the value expression whose region covers (k1, k2, ...).
# Later regions overwrite earlier ones, matching the Python reference
# semantics (`_eval_makearray` in numpy_interpreter.py).
function _resolve_index_of_makearray(makearray_expr::OpExpr, idx_args::Vector{ASTExpr}, rc::_ResolveCtx)
    regions = makearray_expr.regions === nothing ?
        Vector{Vector{Vector{Any}}}() : makearray_expr.regions
    values = makearray_expr.values === nothing ? ASTExpr[] : makearray_expr.values
    length(regions) == length(values) ||
        throw(
        TreeWalkError(
            "E_TREEWALK_MAKEARRAY_MISMATCH",
            "makearray regions/values length mismatch " *
                "($(length(regions)) vs $(length(values)))"
        )
    )
    if !isempty(rc.bound) && any(a -> _reads_bound_sym(a, rc.bound), idx_args)
        return _resolve_index_of_makearray_symbolic(
            regions, _bind_makearray_loops(makearray_expr, values, idx_args), idx_args, rc
        )
    end
    k_vals = [_eval_const_int(a, _EMPTY_IDX_ENV, rc.const_arrays) for a in idx_args]
    ndim = length(k_vals)
    result_expr::ASTExpr = NumExpr(0.0)  # default: 0 if no region covers the point
    result_region = nothing
    for (region, val_expr) in zip(regions, values)
        length(region) == ndim ||
            throw(
            TreeWalkError(
                "E_TREEWALK_MAKEARRAY_NDIM",
                "makearray region has $(length(region)) dims but $(ndim) indices"
            )
        )
        in_region = all(
            k_vals[d] >= region[d][1] && k_vals[d] <= region[d][2]
                for d in 1:ndim
        )
        in_region && ((result_expr, result_region) = (val_expr, region))  # overwrite; last match wins
    end
    result_expr = _bind_makearray_loop(makearray_expr, result_expr, idx_args)
    # esm-spec §9.6.8: a region value MAY be a self-contained ARRAY-VALUED
    # aggregate (the spec's worked example authors the interior stencil and the
    # boundary faces this way, each with its own `output_idx`/`ranges`). The
    # value array is indexed at the same point (k1, …). A value of lower rank
    # than the makearray covers the region's NON-SINGLETON axes — a face region
    # pins the other axes to a single line (e.g. the [[1,1],[1,NLAT]] west face
    # holds an aggregate over `j` alone).
    if _is_array_producer(result_expr)
        re = result_expr::OpExpr
        rank = _producer_rank(re)
        axes = _region_value_axes(
            rank, ndim,
            d -> result_region !== nothing && result_region[d][1] == result_region[d][2]
        )
        rank == length(axes) ||
            throw(
            TreeWalkError(
                "E_TREEWALK_MAKEARRAY_VALUE_RANK",
                "makearray region value produces a rank-$(rank) array " *
                    "but the region has $(length(axes)) non-singleton " *
                    "axis/axes of $(ndim) total"
            )
        )
        sel = k_vals[axes]
        sel_exprs = ASTExpr[IntExpr(Int64(v)) for v in sel]
        return re.op == "makearray" ?
            _resolve_index_of_makearray(re, sel_exprs, rc) :
            _resolve_index_of_faq(re, sel_exprs, rc)
    end
    return _resolve_indices(result_expr, rc)
end

# A `makearray`'s string `output_idx` entries are loop symbols it binds to the
# cell being assembled (esm-spec §4.3, "Shadowing"; the pointwise lift tags its
# operator makearray this way, esm-libraries-spec §4.7.5). Read at `idx_args`,
# each such symbol takes the subscript in its position: the substitution that
# does it, or `nothing` when there is none to make. A makearray read at its own
# symbols (the lift's `index(M, ℓ…)`) needs none, so its values stay the shared
# nodes identity-keyed memos expect.
function _makearray_loop_bindings(makearray_expr::OpExpr, idx_args::Vector{ASTExpr})
    oi = makearray_expr.output_idx
    (oi === nothing || isempty(oi)) && return nothing
    length(oi) == length(idx_args) ||
        throw(
        TreeWalkError(
            "E_TREEWALK_MAKEARRAY_NDIM",
            "makearray output_idx names $(length(oi)) loop symbols but it is " *
                "read with $(length(idx_args)) indices"
        )
    )
    loops = Dict{String, ASTExpr}()
    for (sym, k) in zip(oi, idx_args)
        sym isa AbstractString || continue
        k isa VarExpr && (k::VarExpr).name == sym && continue
        loops[String(sym)] = k
    end
    return isempty(loops) ? nothing : loops
end

# The region values of `makearray_expr` read at `idx_args`, and one of them.
function _bind_makearray_loops(makearray_expr::OpExpr, values, idx_args::Vector{ASTExpr})
    loops = _makearray_loop_bindings(makearray_expr, idx_args)
    loops === nothing && return values
    memo = _SubMemo()
    return ASTExpr[_sub_preserving(v, loops, memo) for v in values]
end
function _bind_makearray_loop(makearray_expr::OpExpr, value::ASTExpr, idx_args::Vector{ASTExpr})
    loops = _makearray_loop_bindings(makearray_expr, idx_args)
    return loops === nothing ? value : _sub_preserving(value, loops)
end

# `index(makearray, k…)` with a subscript that reads a symbol bound on the
# symbolic path (an output index of the compile-once form, a loop counter of
# the whole-array contraction tier): the region is chosen at run time. The
# selection is a chain of `ifelse`s, one per region in document order with the
# last region outermost, so the last region covering the point wins and a
# point no region covers reads 0, as the concrete selection above does. Each
# branch is the value the concrete selection picks for a point in that region,
# read at the same subscripts, so the taken branch computes what the per-cell
# expansion computes. A region that a constant subscript misses is dropped.
#
# Only subscripts in exact integer arithmetic (`+`, `-`, `*` of integers and
# symbols) and integer region bounds are taken; anything else declines as the
# symbolic path always has.
function _resolve_index_of_makearray_symbolic(
        regions, values, idx_args::Vector{ASTExpr}, rc::_ResolveCtx
    )
    decline(why) = throw(
        TreeWalkError(
            "E_TREEWALK_COMPILE_ONCE_UNSUPPORTED",
            "makearray read at a symbolic subscript: " * why
        )
    )
    all(_is_exact_int_subscript, idx_args) ||
        decline("a subscript that is not a sum, difference or product of integers and symbols")
    ndim = length(idx_args)
    k_const = Union{Nothing, Int}[
        _reads_bound_sym(a, rc.bound) ? nothing :
            _eval_const_int(a, _EMPTY_IDX_ENV, rc.const_arrays) for a in idx_args
    ]
    acc::ASTExpr = NumExpr(0.0)
    for (region, val_expr) in zip(regions, values)
        length(region) == ndim ||
            throw(
            TreeWalkError(
                "E_TREEWALK_MAKEARRAY_NDIM",
                "makearray region has $(length(region)) dims but $(ndim) indices"
            )
        )
        conds = ASTExpr[]
        covers = true
        for d in 1:ndim
            lo, hi = region[d][1], region[d][2]
            (lo isa Integer && hi isa Integer) || decline("a region bound that is not an integer")
            if k_const[d] === nothing
                push!(conds, OpExpr(">=", ASTExpr[idx_args[d], IntExpr(Int64(lo))]))
                push!(conds, OpExpr("<=", ASTExpr[idx_args[d], IntExpr(Int64(hi))]))
            elseif !(lo <= k_const[d] <= hi)
                covers = false
                break
            end
        end
        covers || continue
        branch = val_expr
        if _is_array_producer(val_expr)
            re = val_expr::OpExpr
            rank = _producer_rank(re)
            sel = _region_value_axes(rank, ndim, d -> region[d][1] == region[d][2])
            rank == length(sel) ||
                throw(
                TreeWalkError(
                    "E_TREEWALK_MAKEARRAY_VALUE_RANK",
                    "makearray region value produces a rank-$(rank) array " *
                        "but the region has $(length(sel)) non-singleton " *
                        "axis/axes of $(ndim) total"
                )
            )
            branch = OpExpr("index", ASTExpr[re; idx_args[sel]])
        end
        acc = isempty(conds) ? branch :
            OpExpr(
                "ifelse", ASTExpr[
                    length(conds) == 1 ? conds[1] : OpExpr("and", conds), branch, acc,
                ]
            )
    end
    return _resolve_indices(acc, rc)
end

# Whether the subscript `e` reads one of `syms` as a free name.
_reads_bound_sym(e::ASTExpr, syms::Set{String})::Bool =
    _args_any(x -> x isa VarExpr && (x::VarExpr).name in syms, e)

# A subscript whose value is the same in integer and in floating-point
# arithmetic: integers and names under `+`, `-` and `*`.
function _is_exact_int_subscript(e::ASTExpr)::Bool
    (e isa IntExpr || e isa VarExpr) && return true
    e isa OpExpr || return false
    o = e::OpExpr
    (o.op in ("+", "-", "*") && o.expr_body === nothing && o.ranges === nothing) || return false
    return all(_is_exact_int_subscript, o.args)
end
