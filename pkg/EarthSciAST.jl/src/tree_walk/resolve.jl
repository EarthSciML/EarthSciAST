# ========================================================================
# tree_walk/resolve.jl — part of the tree-walk evaluator. Included by
# src/tree_walk.jl; see that file for the full layout and include order.
# Build-time index resolution: `_resolve_indices` and the faq/makearray
# expansions, the gathers it lowers (`_PGatherArray` and the run-time gather
# markers), and the guards a gather is resolved under.
# ========================================================================

# ---- Shared aggregate/einsum expansion core (one spelling, three sites) --------
# The three aggregate expansions — the LHS-faq einsum
# (`_compile_faq_percell!`), the expression-position gather
# (`_resolve_index_of_faq`), and the scalar reduction
# (`_resolve_scalar_faq`) — all unroll the same product: iterate the
# Cartesian product of the contracted-index iterators, drop join-rejected
# combinations at build time, substitute the concrete contracted
# indices into the (already output-index-substituted) `body`, and guard
# filter-rejected terms with a runtime `ifelse(pred, term, 0̄)` (§7.2). `emit!`
# receives each surviving term; the caller owns what happens next (resolve to a
# scalar ASTExpr vs resolve+compile to a `_Node`) and how the terms are ⊕-combined.
# With neither gates nor filter this is the plain expansion.
#
# Dict reuse: `_sub_preserving`/`_join_admits` only READ these dicts (never
# retain them), and the key SET is identical every iteration — only the values
# change — so `k_exprs` is overwritten in place instead of allocating a fresh
# `Dict` (and its string hashing) per contracted tuple. `binding` additionally
# holds the (fixed) output indices, seeded once from `out_env`. `filt` must
# already carry the output-index substitution (only the contracted indices are
# substituted here); `nothing` disables the guard, as a `nothing` `gates`
# disables the join.
# `body === nothing` is KEYS mode: `emit!` receives each surviving contracted
# index tuple itself (in the same order, through the same gates) instead of the
# substituted term, for a caller that only needs the indices (the TABLE fold's
# entry list, `_array_contraction_table`). A filter is not applied in keys mode.
const _AggBody = Union{ASTExpr, Nothing}

# ---- A ragged range whose parent is itself contracted (esm-spec §4.3.1) -------
# `{from: <ragged>, of: [r]}` with `r` contracted too: the range of `k` is
# `[1, index(offsets, r)]`, unknown until `r` is bound, so the contracted tuples
# are not a product of per-index iterators but a nest, `r` outer to `k`. The
# nest is listed once per cell (`_ContractNest`), each tuple in
# `contract_names` order, and `_foreach_aggregate_term` visits that list in
# place of the product.
struct _ContractNest
    tuples::Vector{Vector{Int}}
end

# A REVERSE scan folds DESCENDING (esm-spec §4.3.1): its suffix `⊕_{j ≥ i}` is
# the left fold `((b_N ⊕ b_{N-1}) ⊕ …) ⊕ b_i`, so one running accumulator
# walking the axis from the top computes every cell of it exactly (the scan
# tier's reversed fold). Every build of such an aggregate visits its terms from
# the high end down: the callers of `_foreach_aggregate_term` hand it the
# iterators `_window_iters` orders, judged on the filter BEFORE the output
# indices are substituted into it.
#
# Whether `filt` is a reverse scan window: the one contracted index `j` alone on
# the high side of an inequality whose other side is an output index
# (`j >= i`, `j > i`, `i <= j`, `i < j`). A bound that is not an output index
# (`j >= 2`, `j >= p`) is a plain filter and keeps the ascending order.
function _reverse_window(
        filt, contract_names::AbstractVector{<:AbstractString},
        out_names
    )
    length(contract_names) == 1 || return false
    filt isa OpExpr || return false
    f = filt::OpExpr
    length(f.args) == 2 || return false
    hi, lo = (f.op == ">=" || f.op == ">") ? (f.args[1], f.args[2]) :
        (f.op == "<=" || f.op == "<") ? (f.args[2], f.args[1]) : return false
    return hi isa VarExpr && (hi::VarExpr).name == contract_names[1] &&
        lo isa VarExpr && (lo::VarExpr).name in out_names
end

# The contracted iterators in the order the filter `filt` visits them.
_window_iters(iters, filt, contract_names, out_names) =
    _reverse_window(filt, contract_names, out_names) ?
    [collect(Int, Iterators.reverse(iters[1]))] : iters

function _foreach_aggregate_term(
        emit!::F, body::_AggBody,
        contract_names::Vector{String}, contract_iters,
        gates, filt, zerobar::Float64,
        out_env::Union{Nothing, Dict{String, Int}} = nothing
    ) where {F}
    k_exprs = Dict{String, ASTExpr}()
    binding = gates === nothing ? nothing :
        (out_env === nothing ? Dict{String, Int}() : Dict{String, Int}(out_env))
    # A gate carrying a prebuilt pair index can DRIVE this expansion instead
    # of merely filtering it — a `join.overlap` broad phase (§5.5.6 / Wall #1) or
    # a `join.on` value-equality match set (§5.5.8) alike — routed to
    # `_foreach_aggregate_term_gated`. Everything else (no join, a gate that
    # materialised no index) takes the untouched product below.
    ov = (gates === nothing || contract_iters isa _ContractNest) ? nothing :
        _drivable_gate(gates)
    ov === nothing || return _foreach_aggregate_term_gated(
        emit!, body,
        contract_names, contract_iters, gates, filt, zerobar, binding, ov, k_exprs
    )
    return _foreach_aggregate_product(
        emit!, body, contract_names, contract_iters,
        gates, filt, zerobar, binding, k_exprs, Val(false)
    )
end

# The shared unroll: `Iterators.product` over `iters` (which vary
# `contract_names[1]` FASTEST), join-gate rejection, contracted-index
# substitution, filter guard, emit. `COUNT` is a compile-time flag so the
# `:vi_enum_visits` count exists ONLY in the overlap-gated
# specialisation — the ungated expansion, the engine's hottest loop, keeps
# exactly the instruction stream it had.
function _foreach_aggregate_product(
        emit!::F, body::_AggBody,
        contract_names::Vector{String}, iters, gates, filt, zerobar::Float64,
        binding, k_exprs::Dict{String, ASTExpr}, ::Val{COUNT}
    ) where {F, COUNT}
    body === nothing && iters isa AbstractVector && length(iters) == 1 &&
        return _foreach_keys1(emit!, contract_names[1], iters[1], gates, binding, Val(COUNT))
    nvisit = 0
    for k_tuple in _agg_tuples(iters)
        if binding !== nothing
            COUNT && (nvisit += 1)
            for d in 1:length(contract_names)
                binding[contract_names[d]] = k_tuple[d]
            end
            _join_admits(gates, binding) || continue
        end
        if body === nothing
            emit!(k_tuple)
            continue
        end
        for d in 1:length(contract_names)
            k_exprs[contract_names[d]] = IntExpr(Int64(k_tuple[d]))
        end
        term = _sub_preserving(body, k_exprs)
        if filt !== nothing
            fsub = _sub_preserving(filt, k_exprs)
            term = OpExpr("ifelse", ASTExpr[fsub, term, NumExpr(zerobar)])
        end
        emit!(term)
    end
    COUNT && _count!(:vi_enum_visits, nvisit)
    return nothing
end

# The contracted tuples `_foreach_aggregate_product` visits: the product of the
# per-index iterators, or a nest's own list (`_ContractNest`).
_agg_tuples(iters) = Iterators.product(iters...)
_agg_tuples(nest::_ContractNest) = nest.tuples

# Keys mode over one contracted index: the product above with a single
# iterator, behind a function barrier so the loop is typed.
function _foreach_keys1(
        emit!::F, name::String, it, gates, binding,
        ::Val{COUNT}
    ) where {F, COUNT}
    nvisit = 0
    for k in it
        if binding !== nothing
            COUNT && (nvisit += 1)
            binding[name] = k
            _join_admits(gates, binding) || continue
        end
        emit!((k,))
    end
    COUNT && _count!(:vi_enum_visits, nvisit)
    return nothing
end

# ---- OVERLAP-gate DRIVEN expansion (§5.5.6 "Join admission" / Wall #1) ------
#
# An overlap gate resolves its WHOLE admissible pair set once, so it can drive
# enumeration rather than filter it. `_overlap_drive_plan` (broad_phase.jl) is
# the shared decision — the value-invention producer (`_vi_enumerate_join`)
# applies the identical policy, differing only in loop shape because its ranges
# may be ragged and are therefore resolved lazily. Three shapes reach here:
#
#   `:restrict` — one gated axis is an OUTPUT index (already bound in `binding`)
#     and the other is contracted. This is the ISRM binning aggregate
#     `E[c] = Σ_r […]` and its record-output mirror `P[r] = Σ_c […]`: the
#     contracted axis iterates only this output cell's candidate partners, so
#     the aggregate costs O(|candidates|) in total rather than O(N_c·N_r).
#   `:pairs` — both gated axes are contracted AND are the only two contracted
#     axes (the scalar-reduction form); the candidate pairs bind both at once.
#   `:reject` — both gated axes are already bound and the pair is not a
#     candidate: no leaf is admitted at all.
#
# Anything else plans `:none` and falls through to the full product. In EVERY
# shape `_join_admits` still runs per leaf, and the driven sequence is the exact
# order-preserving SUBSEQUENCE of the product the gate would have admitted — so
# the emitted terms, and hence the ⊕-reduction, are BIT-IDENTICAL to the
# filtered full product. The driver removes work; it never changes an answer.
#
# UNVISITED OUTPUT POSITIONS. Driving means an output cell with no candidate
# pair emits NO term. That is the correct answer, not a hole: the callers
# combine an empty term list into the semiring identity 0̄
# (`_combine_with_reducer`, and the explicit `rhs_zerobar` literal in
# `_compile_faq_percell!`) — e.g. an emission record outside the grid sums
# to 0 under `(+, 0)`.
function _foreach_aggregate_term_gated(
        emit!::F, body::_AggBody,
        contract_names::Vector{String}, contract_iters, gates, filt,
        zerobar::Float64, binding, ov, k_exprs::Dict{String, ASTExpr}
    ) where {F}
    plan = _overlap_drive_plan(
        ov, contract_names, binding,
        s -> contract_iters[findfirst(==(s), contract_names)::Int]
    )
    kind = plan[1]
    if kind === :reject
        return nothing
    elseif kind === :restrict
        d = findfirst(==(plan[2]), contract_names)::Int
        iters = Any[
            i == d ? plan[3] : contract_iters[i]
                for i in 1:length(contract_iters)
        ]
        return _foreach_aggregate_product(
            emit!, body, contract_names, iters,
            gates, filt, zerobar, binding, k_exprs, Val(true)
        )
    elseif kind === :pairs && length(contract_names) == 2
        # `Iterators.product` varies `contract_names[1]` fastest, so the product
        # ORDER over the surviving tuples is the pair list sorted by
        # (contract_names[2] position, contract_names[1] position).
        fast_is_l = plan[2] == contract_names[1]
        prs = sort(plan[4]; by = fast_is_l ? (p -> (p[2], p[1])) : (p -> (p[1], p[2])))
        cols = fast_is_l ? Any[Int[p[1] for p in prs], Int[p[2] for p in prs]] :
            Any[Int[p[2] for p in prs], Int[p[1] for p in prs]]
        return _foreach_aggregate_pairs(
            emit!, body, contract_names, cols,
            gates, filt, zerobar, binding, k_exprs
        )
    end
    return _foreach_aggregate_product(
        emit!, body, contract_names, contract_iters,
        gates, filt, zerobar, binding, k_exprs, Val(true)
    )
end

# The `:pairs` drive shape: the two contracted symbols are bound TOGETHER from
# the gate's candidate pairs (already reordered by the caller to match
# `Iterators.product`'s slow/fast convention), so the emitted term sequence is
# the exact subsequence the filtered full product emitted.
function _foreach_aggregate_pairs(
        emit!::F, body::_AggBody,
        contract_names::Vector{String}, cols, gates, filt, zerobar::Float64,
        binding, k_exprs::Dict{String, ASTExpr}
    ) where {F}
    _count!(:vi_enum_visits, length(cols[1]))
    for p in 1:length(cols[1])
        for d in 1:length(contract_names)
            binding[contract_names[d]] = cols[d][p]
        end
        _join_admits(gates, binding) || continue
        if body === nothing
            emit!(ntuple(d -> cols[d][p]::Int, length(contract_names)))
            continue
        end
        for d in 1:length(contract_names)
            k_exprs[contract_names[d]] = IntExpr(Int64(cols[d][p]))
        end
        term = _sub_preserving(body, k_exprs)
        if filt !== nothing
            fsub = _sub_preserving(filt, k_exprs)
            term = OpExpr("ifelse", ASTExpr[fsub, term, NumExpr(zerobar)])
        end
        emit!(term)
    end
    return nothing
end

# Contracted (reduction) index names of an aggregate: the `ranges` keys NOT in
# `output_idx`, sorted so the expansion (and hence ⊕-accumulation) order is
# deterministic and identical across the three expansion sites.
_contracted_index_names(ranges_dict, output_idx) =
    sort!(String[n for n in keys(ranges_dict) if !(n in output_idx)])

# `pred` holds for `e` or a node under it reached through `args` alone. The
# walk for a subscript or a range bound, which is integer arithmetic over names
# with no expression-bearing field but its operands.
_args_any(pred::P, e::ASTExpr) where {P} =
    pred(e)::Bool || (e isa OpExpr && _anyof(a -> _args_any(pred, a), (e::OpExpr).args))

_ast_reads(e::ASTExpr, name::AbstractString) =
    _args_any(x -> x isa VarExpr && (x::VarExpr).name == name, e)

# For each contracted index, the other contracted indices its range reads, or
# `nothing` when no range reads one (the common case: a product).
function _contracted_parent_deps(contract_names, rspecs)
    deps = [Int[] for _ in contract_names]
    found = false
    for d in eachindex(contract_names), x in rspecs[d]
        x isa ASTExpr || continue
        for (j, n) in enumerate(contract_names)
            if j != d && _ast_reads(x, n) && !(j in deps[d])
                push!(deps[d], j)
                found = true
            end
        end
    end
    return found ? deps : nothing
end

# The nest of one cell. Outer to inner it runs the product's own order (the
# LAST contracted name outermost, `contract_names[1]` fastest), except that an
# index moves inside every contracted index its range reads, stably; each level
# is expanded under the values the outer levels bound, ascending.
function _contract_nest(
        contract_names, rspecs, deps, idx_env::Dict{String, Int},
        const_arrays::AbstractDict
    )
    tuples = Vector{Int}[]
    _walk_contract_nest(contract_names, rspecs, deps, idx_env, const_arrays) do cur
        push!(tuples, copy(cur))
    end
    return _ContractNest(tuples)
end

# The nest's levels, outermost first (see `_contract_nest`).
function _contract_nest_order(deps)
    nc = length(deps)
    order = Int[]
    placed = falses(nc)
    while length(order) < nc
        nxt = 0
        for d in nc:-1:1
            if !placed[d] && all(j -> placed[j], deps[d])
                nxt = d
                break
            end
        end
        nxt == 0 && (nxt = findlast(!, placed))  # a cycle (never valid)
        placed[nxt] = true
        push!(order, nxt)
    end
    return order
end

# Walk the nest, calling `emit(cur)` with each contracted tuple (in
# `contract_names` order; `cur` is reused, so copy it to keep it) in the order
# `_contract_nest` lists them. Every visitor of a nest goes through here, so the
# one-pass scatter (scatter.jl) and the per-cell expansion see the same order.
function _walk_contract_nest(
        emit::F, contract_names, rspecs, deps, idx_env::Dict{String, Int},
        const_arrays::AbstractDict
    ) where {F}
    order = _contract_nest_order(deps)
    env = Dict{String, Int}(idx_env)
    cur = zeros(Int, length(contract_names))
    _walk_contract_nest_level(emit, 1, order, cur, env, contract_names, rspecs, const_arrays)
    return nothing
end

function _walk_contract_nest_level(
        emit::F, depth::Int, order::Vector{Int}, cur::Vector{Int},
        env::Dict{String, Int}, contract_names, rspecs, const_arrays
    ) where {F}
    if depth > length(order)
        emit(cur)
        return nothing
    end
    d = order[depth]
    for v in _expand_contract_range(rspecs[d], env, const_arrays)
        cur[d] = v
        env[contract_names[d]] = v
        _walk_contract_nest_level(
            emit, depth + 1, order, cur, env, contract_names, rspecs, const_arrays
        )
    end
    return nothing
end

# The contracted iterators of one cell under `idx_env`: each range expanded
# (or its constant iterator in `consts`, when given), or the cell's
# `_ContractNest` when a range reads another contracted index.
function _contract_iters_at(
        contract_names, rspecs, idx_env::Dict{String, Int},
        const_arrays::AbstractDict, consts = nothing
    )
    deps = _contracted_parent_deps(contract_names, rspecs)
    deps === nothing ||
        return _contract_nest(contract_names, rspecs, deps, idx_env, const_arrays)
    return Vector{Int}[
        (consts !== nothing && consts[d] !== nothing) ? consts[d] :
            _expand_contract_range(rspecs[d], idx_env, const_arrays)
            for d in eachindex(contract_names)
    ]
end

# Expand one contracted-range spec to its concrete iteration vector. A constant
# `[lo,hi]`/`[lo,step,hi]` bound expands directly; an *expression-valued* bound —
# a RAGGED index-set range (`{from: <ragged>, of: [i]}`, esm-spec §4.3.1 /
# RFC §5.2) resolved to the per-cell dynamic upper bound `index(offsets, i)` —
# is evaluated under the current output-index environment `idx_env` via
# `_expand_int_range_dyn` (variable-valence segment reduction over the CSR
# offsets keyed factor — a const array; no host-side padding).
_expand_contract_range(rspec, idx_env::Dict{String, Int}, const_arrays::AbstractDict) =
    collect(
    _is_const_int_range(rspec) ? _expand_int_range(rspec) :
        _expand_int_range_dyn(rspec, idx_env, const_arrays)
)

# Resolve index(faq(...), k1, k2, ...) in expression position by
# substituting the output_idx values and unrolling contracted indices at
# build time. Mirrors the LHS-faq expansion (`_compile_faq_percell!`) but
# produces a scalar ASTExpr instead of writing to rhs_list.
function _resolve_index_of_faq(
        faq_expr::OpExpr, idx_args::Vector{ASTExpr},
        array_var_info, var_map, const_arrays,
        pgather::AbstractDict = _EMPTY_PGATHER,
        memo::_MaybeMemo = nothing,
        bound_syms::Set{String} = _EMPTY_BOUND_SYMS
    )
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
    # — OR a build-time constant, folded to an `IntExpr`. With an EMPTY
    # `bound_syms` every arg is constant.
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
    if any_symbolic && !isempty(bound_syms) &&
            any(n -> !_is_const_int_range(ranges_dict[n]), contract_names)
        return _resolve_ragged_faq_loop(
            faq_expr, sub_body, ranges_dict, idx_exprs,
            contract_names, oplus, zerobar, array_var_info,
            var_map, const_arrays, pgather, bound_syms
        )
    end
    contract_iters = _contract_iters_at(
        contract_names, [ranges_dict[n] for n in contract_names], _out_idx_env, const_arrays
    )

    gates = faq_expr.join_gates
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
        return _resolve_indices(
            sub_body, array_var_info, var_map, const_arrays,
            pgather, memo, bound_syms
        )
    end

    # Join/filter expansion via the shared core; the filter carries the (fixed)
    # output-index substitution already, matching the hoisted `sub_body`. The
    # term resolution forwards `bound_syms` so the symbolic subscripts survive
    # into `_ConstGatherRef`s (in concrete mode `bound_syms` is empty → no-op).
    filt = filt0 === nothing ? nothing : _sub_preserving(filt0, idx_exprs)
    contract_iters = _window_iters(contract_iters, filt0, contract_names, output_idx_strs)
    terms = ASTExpr[]
    _foreach_aggregate_term(
        sub_body, contract_names, contract_iters,
        gates, filt, zerobar, _out_idx_env
    ) do term
        push!(
            terms, _resolve_indices(
                term, array_var_info, var_map, const_arrays,
                pgather, memo, bound_syms
            )
        )
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
        oplus::String, zerobar::Float64, array_var_info, var_map, const_arrays,
        pgather::AbstractDict, bound_syms::Set{String}
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
    bound(x) = x isa Integer ? IntExpr(Int64(x)) :
        x isa ASTExpr ? _resolve_indices(
            _sub_preserving(x, idx_exprs), array_var_info,
            var_map, const_arrays, pgather, nothing,
            bound_syms
        ) :
        decline("a bound that is not an integer or an expression")
    lo = bound(rspec[1])
    hi = bound(rspec[end])
    kname = _fresh_loopvar_name()
    kref = Ref(0)
    body = _sub_preserving(
        sub_body,
        Dict{String, ASTExpr}(contract_names[1] => VarExpr(kname))
    )
    kbsyms = union(bound_syms, Set{String}((kname,)))
    resolved = _resolve_indices(
        body, array_var_info, var_map, const_arrays, pgather,
        nothing, kbsyms
    )
    _register_loopvar!(kname, kref)
    return OpExpr(
        "__ragged_loop", ASTExpr[resolved, lo, hi];
        value = _RaggedLoopBuild(
            kref, step, _ragged_reach(rspec, const_arrays),
            Symbol(oplus), zerobar
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
function _resolve_index_of_makearray(
        makearray_expr::OpExpr, idx_args::Vector{ASTExpr},
        array_var_info, var_map, const_arrays,
        pgather::AbstractDict = _EMPTY_PGATHER,
        memo::_MaybeMemo = nothing,
        bound_syms::Set{String} = _EMPTY_BOUND_SYMS
    )
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
    if !isempty(bound_syms) && any(a -> _reads_bound_sym(a, bound_syms), idx_args)
        return _resolve_index_of_makearray_symbolic(
            regions, _bind_makearray_loops(makearray_expr, values, idx_args), idx_args,
            array_var_info, var_map, const_arrays, pgather, memo, bound_syms
        )
    end
    k_vals = [_eval_const_int(a, _EMPTY_IDX_ENV, const_arrays) for a in idx_args]
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
        rank = re.op == "makearray" ?
            ((re.regions === nothing || isempty(re.regions)) ? 0 : length(re.regions[1])) :
            length(_output_idx_strings(re))
        sel = if rank == ndim
            k_vals
        else
            nonsingleton = [
                d for d in 1:ndim
                    if result_region === nothing ||
                    result_region[d][1] != result_region[d][2]
            ]
            rank == length(nonsingleton) ||
                throw(
                TreeWalkError(
                    "E_TREEWALK_MAKEARRAY_VALUE_RANK",
                    "makearray region value produces a rank-$(rank) array " *
                        "but the region has $(length(nonsingleton)) non-singleton " *
                        "axis/axes of $(ndim) total"
                )
            )
            k_vals[nonsingleton]
        end
        sel_exprs = ASTExpr[IntExpr(Int64(v)) for v in sel]
        return re.op == "makearray" ?
            _resolve_index_of_makearray(
                re, sel_exprs, array_var_info, var_map,
                const_arrays, pgather, memo, bound_syms
            ) :
            _resolve_index_of_faq(
                re, sel_exprs, array_var_info, var_map,
                const_arrays, pgather, memo, bound_syms
            )
    end
    return _resolve_indices(
        result_expr, array_var_info, var_map, const_arrays,
        pgather, memo, bound_syms
    )
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
        regions, values, idx_args::Vector{ASTExpr},
        array_var_info, var_map, const_arrays,
        pgather::AbstractDict, memo::_MaybeMemo, bound_syms::Set{String}
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
        _reads_bound_sym(a, bound_syms) ? nothing :
            _eval_const_int(a, _EMPTY_IDX_ENV, const_arrays) for a in idx_args
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
            rank = re.op == "makearray" ?
                ((re.regions === nothing || isempty(re.regions)) ? 0 : length(re.regions[1])) :
                length(_output_idx_strings(re))
            sel = rank == ndim ? collect(1:ndim) :
                [d for d in 1:ndim if region[d][1] != region[d][2]]
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
    return _resolve_indices(
        acc, array_var_info, var_map, const_arrays, pgather, memo, bound_syms
    )
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
function _remap_operand_shape(
        e::ASTExpr, array_var_info, const_arrays,
        pgather::AbstractDict = _EMPTY_PGATHER
    )
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
            (arr isa AbstractArray && !_is_scalar_const_field(arr)) || return (Int[], Int[])
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
        s = _remap_operand_shape(o.args[1], array_var_info, const_arrays, pgather)
        s === nothing && return nothing
        perm = _transpose_perm(o, length(s[2]))
        return (ones(Int, length(perm)), s[2][perm .+ 1])
    elseif o.op == "concat"
        parts = [_remap_operand_shape(a, array_var_info, const_arrays, pgather) for a in o.args]
        (isempty(parts) || any(p -> p === nothing, parts)) && return nothing
        ax = something(o.axis, 0) + 1
        exts = [isempty(p[2]) ? [1] : p[2] for p in parts]
        ext = copy(exts[1])
        ax <= length(ext) || return nothing
        ext[ax] = sum(x[ax] for x in exts)
        return (ones(Int, length(ext)), ext)
    elseif _is_scalar_op(o.op)
        shapes = [_remap_operand_shape(a, array_var_info, const_arrays, pgather) for a in o.args]
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
function _index_through_shape_op(
        o::OpExpr, subs::Vector{ASTExpr},
        array_var_info, const_arrays,
        pgather::AbstractDict = _EMPTY_PGATHER
    )::ASTExpr
    shp = _remap_operand_shape(o, array_var_info, const_arrays, pgather)
    shp === nothing && _shape_remap_refuse(o, "the operand's shape is not known at build time")
    ext = shp[2]
    length(subs) == length(ext) ||
        _shape_remap_refuse(o, "the result is rank $(length(ext)) but got $(length(subs)) subscripts")
    ks = Union{Int, Nothing}[_try_const_int(s, const_arrays) for s in subs]
    for d in eachindex(ks)
        k = ks[d]
        (k === nothing || 1 <= k <= ext[d]) ||
            _shape_remap_refuse(o, "subscript $(k) is out of range 1:$(ext[d]) on axis $(d)")
    end
    at(d, lo) = ks[d] === nothing ? _remap_shift(subs[d], lo) : IntExpr(Int64(ks[d] - 1 + lo))
    if o.op == "transpose"
        x = o.args[1]
        xlo, _ = _remap_operand_shape(x, array_var_info, const_arrays, pgather)
        perm = _transpose_perm(o, length(ext))
        xs = Vector{ASTExpr}(undef, length(ext))
        for d in eachindex(perm)
            xs[perm[d] + 1] = at(d, xlo[perm[d] + 1])
        end
        return OpExpr("index", ASTExpr[x, xs...])
    elseif o.op == "reshape"
        length(o.args) == 1 || _shape_remap_refuse(o, "reshape takes one operand")
        x = o.args[1]
        xs0 = _remap_operand_shape(x, array_var_info, const_arrays, pgather)
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
        plo, pext = _remap_operand_shape(a, array_var_info, const_arrays, pgather)
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
        a::ASTExpr, subs::Vector{ASTExpr}, result_ext::Vector{Int},
        array_var_info, const_arrays,
        pgather::AbstractDict = _EMPTY_PGATHER
    )
    s = _remap_operand_shape(a, array_var_info, const_arrays, pgather)
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

# ── Runtime contraction loop gate ─────────────────────────────────────────────
# Depth of the array-equation per-cell resolve (`_compile_faq_percell!`). A
# scalar aggregate nested INSIDE an array-equation cell body must keep unrolling:
# its compiled node flows into the stencil / access-kernel merge (acc_merge.jl,
# stencil_affine.jl, oop_merge.jl), which model unrolled scalar terms — so the
# loop node is confined to SCALAR contexts (rhs_list / scalar observeds), where the
# eval-time consumer is exactly `_eval_node` (which handles it) and the CSE keyer
# (xcse.jl, which safely DECLINES an unknown kind → leaves it inline). The depth
# is the build's (`_BuildState.array_cell_depth`, compiler.jl).

# A member of a symbolic resolve's bound names that no index name can be: the
# whole-array nest puts it in the bound names it resolves its term with
# (`_resolve_array_contraction_term(...; nest_scalar_loops=true)`), and every
# resolve of that term passes it down with them. A scalar reduction nested in
# the term then stays a loop (`_resolve_scalar_faq`) instead of unrolling one
# term per contracted index into the nest's one body, which would make the
# generated code as long as the reduction. The nest's emitter writes it as a
# counted loop (`_cg_emit`, array_contraction.jl). A resolve started anywhere
# else has bound names without it, so it never sees the loop node.
const _NEST_SCALAR_LOOPS = "\0nest_scalar_loops"

# Tier gate and coverage floor. On under `native`, but only for reductions at
# least `_contraction_loop_min()` long — small reductions keep unrolling so the
# vast existing small-aggregate test surface (and its CSE / stencil interactions)
# is byte-for-byte unchanged. Off, the pure unroll is the reference everywhere.
#
# The floor is overridden with ESS_CONTRACTION_LOOP_MIN: a REFUSAL BOUNDARY
# under `native`, because which side of it a reduction falls on decides which
# tier compiles the equation and therefore whether the compiler can express it.
_contraction_loop_enabled() = _compiler_plan_now().contraction_loop
# The build reads it once, when it starts (`_BuildContext`, compiler.jl).
_contraction_loop_min() = _tuning_now().contraction_loop_min

# Resolve `body` with each of `names` replaced by a fresh reserved loop-var
# name (`_fresh_loopvar_name`) kept symbolic, plus the bound names in
# `extra_syms`: `(refs, resolved)`, one `Ref` per name in `names` order, or
# a `_Decline` (`:symbolic_body_did_not_lower`, the error's text as its
# detail) when the body does not resolve that way. Only a document-level
# refusal (an `EarthSciASTError`) is such a decline: a resource error never is
# (errors.jl) — the per-cell path a caller falls back to resolves the SAME body
# once per output cell, so reading an exhausted heap as "this body will not
# resolve symbolically" walks the build into a far larger allocation with the
# cause erased — and a programming error would otherwise surface only as a
# tier that declined. `memo` is `nothing` or one made for this symbolic resolve
# alone, never the concrete RHS build's. The refs are published to
# the build state (`_register_loopvar!`), so `_compile` lowers each surviving loop-var `VarExpr` to an
# `_NK_LOOPVAR` reading its ref, only after a clean resolve.
function _resolve_symbolic(
        body::ASTExpr, names::Vector{String}, extra_syms::Set{String},
        array_var_info, var_map, const_arrays, pgather::AbstractDict,
        memo::_MaybeMemo = nothing
    )
    fresh = String[_fresh_loopvar_name() for _ in names]
    refs = Base.RefValue{Int}[Ref(0) for _ in names]
    subs = Dict{String, ASTExpr}(names[d] => VarExpr(fresh[d]) for d in eachindex(names))
    subbed = _sub_preserving(body, subs)
    bsyms = union(Set{String}(fresh), extra_syms)
    resolved = try
        _resolve_indices(subbed, array_var_info, var_map, const_arrays, pgather, memo, bsyms)
    catch err
        err isa EarthSciASTError || rethrow()
        return _Decline(:symbolic_body_did_not_lower, sprint(showerror, err))
    end
    for d in eachindex(fresh)
        _register_loopvar!(fresh[d], refs[d])
    end
    return refs, resolved
end

# Try to compile a uniform contraction to a single runtime loop node instead of
# unrolling it. Returns a `__contract_loop` marker-op
# ASTExpr (lowered to `_NK_CONTRACTION_LOOP` by `_compile`) on success, or
# the resolve's `_Decline` to fall back to the exact unroll. Keeps the contracted index SYMBOLIC
# (a reserved bound-sym `VarExpr`) and resolves the body ONCE: a loop var reaching
# a const-array subscript lowers to a runtime `_NK_CONST_GATHER` (existing Phase-C
# machinery); a loop var reaching a STATE index or a ragged bound throws
# `E_TREEWALK_UNBOUND_LOOP_VAR` here — caught, and we unroll (correctness first).
function _try_build_contraction_loop(
        body::ASTExpr, contract_names::Vector{String},
        ranges::AbstractVector, oplus::String, zerobar::Float64,
        array_var_info, var_map, const_arrays, pgather::AbstractDict;
        # The enclosing symbolic resolve's own bound names, which the body may
        # read (a reduction nested in the whole-array nest's term).
        outer_syms::Set{String} = _EMPTY_BOUND_SYMS
    )
    got = _resolve_symbolic(
        body, contract_names, outer_syms, array_var_info, var_map, const_arrays, pgather
    )
    got isa _Decline && return got
    refs, resolved = got
    oplus_sym = Symbol(oplus)
    node::ASTExpr = resolved
    # Nest innermost-first: `contract_names[1]` varies FASTEST in the unroll's
    # `Iterators.product` order, so it is the INNERMOST loop — the fold order then
    # matches the unrolled `_combine_with_reducer` accumulation.
    for d in eachindex(contract_names)
        r = ranges[d]
        node = OpExpr(
            "__contract_loop", ASTExpr[node];
            value = _ContractLoopBuild(
                refs[d], first(r), last(r), step(r),
                oplus_sym, zerobar
            )
        )
    end
    return node
end

# ── Whole-array contraction loop nest ────────────────
# Kill-switch + coverage floor for the tier that keeps the OUTPUT indices
# symbolic too (see `_resolve_array_contraction_term`). WHICH tier gets an
# equation is decided by POSITION in the cascade: `_compile_faq_equation!`
# offers this one once the affine tier has declined, so the alternative is
# always the per-cell build. The in-place build offers it every such equation;
# the floor applies only to the out-of-place build, whose emitters compile the
# per-cell build's cells and have no arm for this tier's section, so there an
# equation under the floor keeps the per-cell build they can emit.
#
# The contraction-loop gate disables this tier too: it forces the pure-unroll
# reference EVERYWHERE, and this tier is a contraction loop — one that also
# loops the output index.
#
# The floor is overridden with ESS_ARRAY_CONTRACTION_MIN. It is a tuning
# threshold, not a refusal boundary: moving it moves an out-of-place equation
# between this tier and the per-cell build.
_array_contraction_enabled() =
    _compiler_plan_now().array_contraction && _contraction_loop_enabled()
_array_contraction_min() = _tuning_now().array_contraction_min

# The term of an array einsum resolved ONCE with its output and its contracted
# indices all symbolic (reserved loop-var names), and no reduction around it:
# `(out_refs, contract_refs, resolved)`, or a `_Decline` when the body does not
# resolve that way. Keeping the output indices symbolic as well as the
# contracted ones makes the build O(1) in both extents: the body's reads lower
# through the run-time gather machinery (a const read at an output subscript is
# `_NK_CONST_GATHER`, a state read `_NK_STATE_GATHER`, a bare output symbol
# `_NK_LOOPVAR`) and the caller drives the counters at eval time. The
# whole-array nest (array_contraction.jl) drives the contracted refs from the
# admitted tuples or its own loops; `_compile_init_once` (no contracted index)
# compiles the term once for every output cell.
function _resolve_array_contraction_term(
        body::ASTExpr, out_names::Vector{String},
        contract_names::Vector{String},
        array_var_info, var_map, const_arrays, pgather::AbstractDict;
        # The whole-array nest's own resolve, whose emitter writes a nested
        # scalar reduction as a loop (`_NEST_SCALAR_LOOPS`).
        nest_scalar_loops::Bool = false,
        # A build memo of THIS resolve's own (never the concrete RHS build's):
        # a sub-tree reached from several parents (a template parameter written
        # at each of its uses) then resolves once, and the caller compiles the
        # result with the same memo, so the emitter sees one shared node.
        memo::_MaybeMemo = nothing
    )
    nout = length(out_names)
    extra = nest_scalar_loops ? Set{String}((_NEST_SCALAR_LOOPS,)) : _EMPTY_BOUND_SYMS
    got = _resolve_symbolic(
        body, vcat(out_names, contract_names), extra,
        array_var_info, var_map, const_arrays, pgather, memo
    )
    got isa _Decline && return got
    refs, resolved = got
    return (refs[1:nout], refs[(nout + 1):end], resolved)
end

# Expand a scalar faq (empty output_idx) to a plain scalar ASTExpr by
# unrolling all contracted indices at build time and combining them with the
# declared reducer. This is the build-time equivalent of an einsum over a
# general expression body — compile once, evaluate cheaply at every RHS call.
function _resolve_scalar_faq(
        faq_expr::OpExpr, array_var_info, var_map, const_arrays,
        pgather::AbstractDict = _EMPTY_PGATHER,
        memo::_MaybeMemo = nothing,
        bound_syms::Set{String} = _EMPTY_BOUND_SYMS
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
    # Every range key contracts (a scalar aggregate has no output indices).
    contract_names = _contracted_index_names(ranges_dict, ())
    # A contracted range bound may be a per-cell INDEX EXPRESSION (e.g. the
    # variable-valence unstructured reduction's `index(n_edges_on_cell, i)`).
    # This scalar-faq resolver is reached from `_resolve_indices` AFTER the
    # outer loop variable has been substituted to a literal in `body`/`ranges`,
    # so the bound is evaluable now via `_eval_const_int` against `const_arrays`
    # with the empty idx_env (any surviving symbol would be unbound — an error,
    # as before). Constant bounds pass through unchanged (backward compatible).
    contract_iters = _contract_iters_at(
        contract_names, [ranges_dict[n] for n in contract_names], _EMPTY_IDX_ENV, const_arrays
    )
    # Build-time join gates + runtime filter guard (§5.3 / §7.2). Every join
    # key of a scalar aggregate is a contracted symbol, so the binding is the
    # contraction tuple (no output-index seed).
    gates = faq_expr.join_gates
    filt0 = faq_expr.filter
    if isempty(contract_names) && gates === nothing && filt0 === nothing
        return _resolve_indices(
            body, array_var_info, var_map, const_arrays,
            pgather, memo, bound_syms
        )
    end
    # ── Runtime contraction loop opt-in ──────────────
    # Emit a compile-once loop for a SIMPLE UNIFORM reduction; everything else
    # unrolls. Gated conservatively (correctness first):
    #   * enabled by the compiler plan, and NOT already inside an array-equation cell resolve
    #     (loop node is confined to scalar-walker contexts — see `_BuildState.array_cell_depth`);
    #   * NOT the symbolic compile-once cellwise path (`bound_syms` empty) — that
    #     path binds its own reserved symbols and runs a separate evaluator;
    #   * a plain arithmetic reducer ∈ {+,*,max,min}, no join gates / filter;
    #   * every contracted range a CONSTANT integer range (ragged bounds keep
    #     unrolling — they already resolve to a per-cell concrete bound);
    #   * total reduction length ≥ the coverage floor;
    #   * the body resolves with the index symbolic (`_try_build_contraction_loop`
    #     returns a `_Decline` otherwise → unroll).
    if _contraction_loop_enabled() && _build_state().array_cell_depth == 0 &&
            isempty(bound_syms) && gates === nothing && filt0 === nothing &&
            _is_numeric_reducer(oplus) &&
            all(n -> _is_const_int_range(ranges_dict[n]), contract_names)
        ranges = [_expand_int_range(ranges_dict[n]) for n in contract_names]
        total = isempty(ranges) ? 0 : prod(length(r) for r in ranges)
        if total >= _contraction_loop_min() && all(!isempty, ranges)
            looped = _try_build_contraction_loop(
                body, contract_names, ranges,
                oplus, zerobar, array_var_info, var_map, const_arrays, pgather
            )
            looped isa _Decline || return looped
        end
    end
    # Nested in the whole-array nest's term (`_NEST_SCALAR_LOOPS` among the
    # bound names), a reduction over ONE constant range at least the loop floor
    # long stays a loop that reads the nest's counters. It folds from 0̄, so its
    # value is the unroll's below bit for bit: the same terms in the same order,
    # left to right from the same seed (esm-spec §4.3.1). Two or more
    # contracted indices keep unrolling, since nested loops would group the sum
    # by the outer index.
    if _NEST_SCALAR_LOOPS in bound_syms && gates === nothing &&
            filt0 === nothing && length(contract_names) == 1 &&
            _is_numeric_reducer(oplus) &&
            _is_const_int_range(ranges_dict[contract_names[1]])
        r = _expand_int_range(ranges_dict[contract_names[1]])
        if length(r) >= _contraction_loop_min()
            looped = _try_build_contraction_loop(
                body, contract_names, [r], oplus,
                zerobar, array_var_info, var_map, const_arrays,
                pgather; outer_syms = bound_syms
            )
            looped isa _Decline || return looped
        end
    end
    terms = ASTExpr[]
    _foreach_aggregate_term(
        body, contract_names, contract_iters,
        gates, filt0, zerobar
    ) do term
        push!(
            terms, _resolve_indices(
                term, array_var_info, var_map, const_arrays,
                pgather, memo, bound_syms
            )
        )
    end
    return _combine_with_reducer(oplus, zerobar, terms; scalar = true)
end

# Replace index(var, k1, k2, ...) nodes:
#   - In-bounds state/array var → VarExpr(cell_key) referencing the flat state slot.
#   - In-bounds const_array entry → NumExpr(literal) inlining the pre-computed value.
#   - Out-of-bounds → NumExpr(0.0) (ghost-cell convention for state arrays).
# array_var_info: var_name → (lo::Vector{Int}, hi::Vector{Int})
# const_arrays: pre-computed float arrays (1D Fornberg weights, or ND mesh connectivity)
#   keyed by array name; index(name, i1, i2, ...) → NumExpr(const_arrays[name][i1,i2,...])
#   also used for indirect gather: u[index(conn, c, k)] resolves conn[c,k] as an integer index.
# Read-only sentinel — see the `_EMPTY_*` invariant block next to
# `_EMPTY_DERIVED_EXTENTS`.
const _EMPTY_CONST_ARRAYS = Dict{String, AbstractArray{Float64}}()

# Empty scalar-parameter scope for a build-time cellwise evaluation with no
# parameters bound (the common case). Shared so `_eval_cellwise` /
# `evaluate_cellwise` avoid allocating a fresh dict per call on the no-param
# path. Read-only sentinel — see the `_EMPTY_*` invariant block next to
# `_EMPTY_DERIVED_EXTENTS`.
const _EMPTY_PARAMS = Dict{String, Float64}()

# A live forcing buffer bound by reference into the evaluator.
# Unlike `const_arrays` (build-time-FROZEN: `index(arr,…)` const-folds to a
# `NumExpr` literal, tree_walk.jl const-array branch), a `_PGatherArray` reroutes
# the SAME `index(forcing,…)` gather to a LIVE read of a captured `flat`
# `Vector{Float64}`. `flat = vec(buffer)` aliases the caller's dense
# `Array{Float64}` buffer, so a discrete refresh callback's in-place `buffer .= …`
# shows through to the RHS with zero reallocation. `dims` carries
# the source shape for bounds-checking + column-major linearization at build time.
# Reading the captured `flat` (NOT `getfield(p, runtime_sym)`) is what keeps the
# read zero-alloc: a runtime-symbol `getfield` on a heterogeneous NamedTuple boxes
# the union and would also regress the scalar `_NK_PARAM` path.
struct _PGatherArray
    flat::Vector{Float64}   # aliased flat view of the caller's buffer (live, by-ref)
    dims::Vector{Int}       # original shape — bounds-check + linearize at build time
    # A cache the build owns (a discrete-cadence var's, `_build_discrete_materializer!`)
    # rather than a forcing buffer the caller or a provider supplied.
    cache::Bool
    _PGatherArray(flat, dims, cache) = _new_typed(_PGatherArray, flat, dims, cache)
end
_def_new_typed(_PGatherArray)
_PGatherArray(flat, dims) = _PGatherArray(flat, dims, false)
# Read-only sentinel — see the `_EMPTY_*` invariant block next to
# `_EMPTY_DERIVED_EXTENTS`.
const _EMPTY_PGATHER = Dict{String, _PGatherArray}()

# The set of index symbol names kept SYMBOLIC through `_resolve_indices`: the
# compile-once cellwise path's output indices, and the loop indices of a
# contraction loop, a ragged loop, the whole-array nest and the scatter. A
# const-array read whose subscript names one becomes a runtime
# `_ConstGatherRef` rather than a folded `NumExpr`; so does one whose subscript
# reads a parameter, a state or `t` (`_subscript_is_runtime`), whatever the
# set holds. The default threaded through the resolve recursion is this shared
# read-only empty set — see the `_EMPTY_*` invariant block next to
# `_EMPTY_DERIVED_EXTENTS`.
const _EMPTY_BOUND_SYMS = Set{String}()

# True iff a subscript's value is known only at run time: it references a name
# no integer environment binds here — a bound output-index symbol, or a
# parameter, a state, an observed or `t` (esm-spec §4.3.2 lets a subscript be
# any integer-valued expression) — or reads an array producer. After loop substitution every other name a
# subscript holds is an array in an `index` head position or a binder of a
# producer inside it. `local` holds names that do not count: a producer's own
# binders, and for a caller that keeps bound symbols on its own path, those.
function _subscript_is_runtime(
        e::ASTExpr, local_names::Set{String},
        const_arrays::Union{Nothing, AbstractDict} = nothing
    )::Bool
    e isa VarExpr && return !((e::VarExpr).name in local_names)
    e isa OpExpr || return false
    o = e::OpExpr
    # An array producer read at the subscript (`c[j[i]]` with `j` an inlined
    # faq) has no integer evaluation; resolved, it is the producer's body at
    # that subscript, evaluated in floating point as the run time would.
    _is_array_producer(o) && return true
    inner = local_names
    binders = String[]
    o.output_idx === nothing || for x in o.output_idx
        x isa AbstractString && push!(binders, String(x))
    end
    o.ranges === nothing || for k in keys(o.ranges)
        push!(binders, String(k))
    end
    isempty(binders) || (inner = union(local_names, binders))
    for (k, a) in enumerate(o.args)
        if k == 1 && o.op == "index" && a isa VarExpr
            # A gather from anything but a const array (a state, a
            # materialized observed) reads a run-time value.
            (const_arrays === nothing || haskey(const_arrays, (a::VarExpr).name)) ||
                return true
            continue
        end
        _subscript_is_runtime(a, inner, const_arrays) && return true
    end
    o.expr_body === nothing ||
        (_subscript_is_runtime(o.expr_body, inner, const_arrays) && return true)
    o.filter === nothing ||
        (_subscript_is_runtime(o.filter, inner, const_arrays) && return true)
    if o.values !== nothing
        for v in o.values
            _subscript_is_runtime(v, inner, const_arrays) && return true
        end
    end
    return false
end
_subscript_is_runtime(e::ASTExpr, const_arrays::AbstractDict) =
    _subscript_is_runtime(e, _EMPTY_BOUND_SYMS, const_arrays)

# True iff a run-time subscript is built only from loop counters — a bound
# output-index symbol of a symbolic resolve, or a contraction loop variable
# (`__esm_lv_*`) — integer literals, `+ - *`, and a quotient that is the DIRECT
# operand of `floor` or `ceil`: what a gather can evaluate from the counters
# alone (`_index_int`) and the walk can compile. (`mod` is no esm operator, so
# the scalar compiler refuses it; admitting it here would refuse a subscript the
# unrolled fold evaluates.) The rounded quotient is the cell-to-row
# reindex a flattened loader field takes (`F[floor((c - 1) / NX) + 1, c - NX *
# floor((c - 1) / NX)]`, reseact's NEI emissions, issue #665).
#
# Every intermediate must be an integer, because the traced evaluator works in
# integers while the walk evaluates the subscript in floating point and rounds
# once at the end. So a quotient anywhere else (`floor(2 * (k / 3))`,
# `floor(k / 2 + k / 3)`, a bare `k / 2`) and a non-integer literal
# (`floor(k * 0.5)`) are refused: the two evaluators would read different rows.
# The quotient's own operands follow the same rule. A subscript that reads a
# state, an observed, a parameter, `t` or an array is not one.
_subscript_from_counters(e::VarExpr, bound_syms::Set{String}) =
    e.name in bound_syms || startswith(e.name, _LOOPVAR_PREFIX)
_subscript_from_counters(::IntExpr, ::Set{String}) = true
_subscript_from_counters(e::NumExpr, ::Set{String}) = isinteger(e.value)
function _subscript_from_counters(e::OpExpr, bound_syms::Set{String})
    op = e.op
    if op == "+" || op == "-" || op == "*"
        return all(a -> _subscript_from_counters(a, bound_syms), e.args)
    elseif (op == "floor" || op == "ceil") && length(e.args) == 1
        q = e.args[1]
        q isa OpExpr && q.op == "/" && length(q.args) == 2 &&
            return all(a -> _subscript_from_counters(a, bound_syms), q.args)
        return _subscript_from_counters(q, bound_syms)
    end
    return false
end
_subscript_from_counters(::ASTExpr, ::Set{String}) = false

# ── Guarded out-of-range reads ───────────────────────────────────────────────
# esm-spec evaluates `ifelse` lazily and `and` / `or` with short circuit, so a
# const read out of range under a branch the cell does not take is no error
# (the interpreter raises E_TREEWALK_CONSTARRAY_OOB where a read is
# EVALUATED). The resolve below builds every branch, so it keeps, per task,
# the guards the node being resolved sits under: the resolved condition and
# the truth value its branch needs. An out-of-range constant subscript is
# then raised at build only when every guard is decided at build and taken;
# otherwise it becomes a run-time gather that raises the same error if it is
# ever evaluated.
const _ResolveGuards = Vector{Tuple{ASTExpr, Bool}}
_resolve_guards() = get!(
    () -> _ResolveGuards(), task_local_storage(),
    :esm_resolve_guards
)::_ResolveGuards

# Whether the read the current guards protect is certainly evaluated: every
# guard reads only literals (so its value is the build's to know) and has the
# value its branch needs. A guard that reads any name — a state, a parameter,
# an observed, `t` — is decided at run time.
function _guarded_read_taken(guards::_ResolveGuards)
    for (c, want) in guards
        isempty(_referenced_var_names(c)) || return false
        v = try
            _eval_node(
                _compile(c, Dict{String, Int}(), Set{Symbol}()),
                Float64[], NamedTuple(), 0.0
            )
        catch err
            err isa EarthSciASTError || rethrow()
            return false
        end
        (v != 0) == want || return false
    end
    return true
end

# Whether an out-of-range read under the current guards is left for run time:
# some guard is in force and the build cannot show every one taken.
function _guarded_oob_deferred()
    guards = _resolve_guards()
    return !isempty(guards) && !_guarded_read_taken(guards)
end

@noinline _throw_pgather_oob(name, ci, n, d) = throw(
    TreeWalkError(
        "E_TREEWALK_PGATHER_OOB",
        "forcing array '$(name)' index $(ci) out of range [1, $(n)] on dim $(d)"
    )
)

# A const read at constant subscripts the build may not raise for (see above):
# the run-time gather, which resolves each subscript under the array's
# boundary policy when — and only if — it is evaluated.
_deferred_const_gather(vals::AbstractArray, name::String, subs::Vector{Int}) =
    OpExpr(
    "index", ASTExpr[IntExpr(Int64(i)) for i in subs];
    value = _ConstGatherRef(vals, name)
)

# Resolve `ifelse` / `and` / `or` with each lazily evaluated operand under its
# guard (see above). Every other operand is resolved exactly as the generic
# recursion does, and an unchanged node is returned as is.
function _resolve_guarded_op(
        expr::OpExpr, array_var_info, var_map, const_arrays,
        pgather, memo, bound_syms
    )
    args = expr.args
    guards = _resolve_guards()
    depth = length(guards)
    new_args = Vector{ASTExpr}(undef, length(args))
    res(a) = (a isa OpExpr || a isa VarExpr) ?
        _resolve_indices(
            a, array_var_info, var_map, const_arrays, pgather, memo,
            bound_syms
        ) : a
    try
        new_args[1] = res(args[1])
        if expr.op == "ifelse"
            push!(guards, (new_args[1], true))
            new_args[2] = res(args[2])
            guards[end] = (new_args[1], false)
            new_args[3] = res(args[3])
        else
            for j in 2:length(args)
                push!(guards, (new_args[j - 1], expr.op == "and"))
                new_args[j] = res(args[j])
            end
        end
    finally
        resize!(guards, depth)
    end
    all(i -> new_args[i] === args[i], eachindex(args)) && return expr
    return reconstruct(expr; args = new_args)
end

# Gather from a build-time-constant Float64 array `vals` (registry `name`, used
# only for CSE identity / diagnostics) at the subscript expressions
# `idx_args_expr`. This is the ONE spelling of the const-array read, shared by
# the registered-const-array `index(name, …)` branch and the INLINE
# `index({op:const, value:[…]}, …)` branch below. Fully-constant subscripts fold
# to the scalar element (a `NumExpr` literal, the byte-identical frozen path); a
# subscript that references a bound output-index symbol kept symbolic (the
# compile-once `evaluate_cellwise` fast path, non-empty `bound_syms`) keeps the
# read runtime-varying and lowers to a `_ConstGatherRef` (→ `_NK_CONST_GATHER`),
# with the constant dims still folded to `IntExpr`s under the same
# `_resolve_const_index` boundary policy.
function _resolve_const_array_gather(
        vals::AbstractArray, name::String,
        idx_args_expr::Vector{ASTExpr},
        array_var_info::Dict{String, Tuple{Vector{Int}, Vector{Int}}},
        var_map::AbstractDict{String, Int}, const_arrays::AbstractDict,
        pgather::AbstractDict, memo::_MaybeMemo, bound_syms::Set{String}
    )
    length(idx_args_expr) == ndims(vals) ||
        throw(
        TreeWalkError(
            "E_TREEWALK_CONSTARRAY_NDIM",
            "const array '$(name)' is $(ndims(vals))D " *
                "but got $(length(idx_args_expr)) indices"
        )
    )
    if _anyof(a -> _subscript_is_runtime(a, const_arrays), idx_args_expr)
        sub_nodes = Vector{ASTExpr}(undef, length(idx_args_expr))
        guards = _resolve_guards()
        for d in 1:ndims(vals)
            a = idx_args_expr[d]
            if _subscript_is_runtime(a, const_arrays)
                sub_nodes[d] = _resolve_indices(
                    a, array_var_info, var_map,
                    const_arrays, pgather, memo, bound_syms
                )
            else
                ci = _const_subscript_int(a, const_arrays)
                # The guarded out-of-range rule, as for a read at constant
                # subscripts only: under a guard the build cannot show taken,
                # the out-of-range constant stays for the run-time gather,
                # which raises if the read is ever evaluated.
                if !isempty(guards) && !(1 <= ci <= size(vals, d)) &&
                        _const_dim_boundary(vals, d) === :error &&
                        !_guarded_read_taken(guards)
                    memo === nothing || (memo.deferrals[] += 1)
                else
                    ci = _resolve_const_index(vals, name, d, ci, size(vals, d))
                end
                sub_nodes[d] = IntExpr(Int64(ci))
            end
        end
        return OpExpr("index", sub_nodes; value = _ConstGatherRef(vals, name))
    end
    # Fully-constant subscripts: inline the value as a NumExpr literal.
    int_indices = Int[_const_subscript_int(a, const_arrays) for a in idx_args_expr]
    guards = _resolve_guards()
    if !isempty(guards) &&
            _anyof(
            d -> !(1 <= int_indices[d] <= size(vals, d)) &&
                _const_dim_boundary(vals, d) === :error, 1:ndims(vals)
        ) &&
            !_guarded_read_taken(guards)
        memo === nothing || (memo.deferrals[] += 1)
        return _deferred_const_gather(vals, name, int_indices)
    end
    for d in 1:ndims(vals)
        int_indices[d] = _resolve_const_index(vals, name, d, int_indices[d], size(vals, d))
    end
    return NumExpr(Float64(vals[int_indices...]))
end

# A build-constant subscript as the integer it selects, by `_eval_const_int`'s
# integer arithmetic (`/` is `div`, every operand an integer). A `faq` in it — a
# comparison count, the bracket index of the interpolation templates
# (lib/interp.esm) at a literal query — is the one term that integer evaluator
# cannot take, since it reads array entries as integers and a count compares
# float entries: each such term is evaluated alone with the float evaluator, as
# the run time evaluates it, and stands in the subscript as the literal it
# evaluates to. A value that is not an integer is then refused exactly as that
# literal written by hand would be.
function _const_subscript_int(a::ASTExpr, const_arrays::AbstractDict)
    _holds_faq(a) && (a = _fold_faq_terms(a, const_arrays, IdDict{OpExpr, ASTExpr}()))
    return _eval_const_int(a, _EMPTY_IDX_ENV, const_arrays)
end
_holds_faq(e::ASTExpr) = _args_any(x -> x isa OpExpr && _is_faq_op((x::OpExpr).op), e)

# `e` with each `faq` sub-term replaced by the literal it evaluates to; the
# nodes above one are copied, every other node is `e`'s own. Memoized by
# identity, so a sub-term shared by reference is evaluated once.
function _fold_faq_terms(e::ASTExpr, const_arrays::AbstractDict, memo::IdDict{OpExpr, ASTExpr})
    e isa OpExpr && _holds_faq(e) || return e
    got = get(memo, e, nothing)
    got === nothing || return got
    r = if _is_faq_op(e.op)
        t = _resolve_indices(
            e, Dict{String, Tuple{Vector{Int}, Vector{Int}}}(), Dict{String, Int}(), const_arrays
        )
        NumExpr(_eval_node(_compile(t, Dict{String, Int}(), Set{Symbol}()), Float64[], NamedTuple(), 0.0))
    else
        reconstruct(e; args = ASTExpr[_fold_faq_terms(x, const_arrays, memo) for x in e.args])
    end
    return memo[e] = r
end

# Name prefix reserved for INTERNED inline-`const` array literals (below). Kept
# distinct from any authored variable name so a synthetic entry can never shadow
# a real const-array observed, and so the dedup scan can cheaply skip non-inline
# registry rows.
const _INLINE_CONST_PREFIX = "__inline_const#"

# Materialize an inline `const`-op array literal (a nested-vector `value`) into a
# dense Float64 array and INTERN it into the const-array registry so it gathers
# through the exact same path a registered const-array observed takes
# (`_resolve_const_array_gather`). Deduped BY VALUE: an identical literal resolves
# to one registry name, so its symbolic gathers share a CSE identity (a
# content-hashed name makes this deterministic even across separately-built
# equations). The gather captures `vals` directly, so registration is not needed
# for correctness — it is the task's "intern into `const_arrays`" contract plus a
# single shared array object; it is skipped for the read-only empty sentinel.
function _intern_inline_const(cexpr::OpExpr, const_arrays::AbstractDict)
    vals = _const_op_to_array(cexpr.value)
    same(v) = _dynamic((a, b) -> size(a) == size(b) && a == b, v, vals)::Bool
    name = string(_INLINE_CONST_PREFIX, hash(vals))
    # Every interned literal is registered under its own content hash and no
    # two registered ones are equal, so an equal literal is normally the one
    # under `name`. Equality is `==`, under which a value equal to this one may
    # hash differently only through a signed zero: then, or on a hash
    # collision, the scan below decides.
    v0 = get(const_arrays, name, nothing)
    v0 !== nothing && same(v0) && return v0, name
    v0 === nothing && !_dynamic(a -> any(iszero, a), vals)::Bool && return _intern_new_const(vals, name, const_arrays)
    for (k, v) in const_arrays
        (startswith(k, _INLINE_CONST_PREFIX) && same(v)) && return v, k
    end
    return _intern_new_const(vals, name, const_arrays)
end
function _intern_new_const(vals, name::String, const_arrays::AbstractDict)
    const_arrays === _EMPTY_CONST_ARRAYS || (const_arrays[name] = vals)
    return vals, name
end

# True iff the subscript `e` references a runtime contraction LOOP variable (a
# reserved `__esm_lv_*` name — `_LOOPVAR_PREFIX`); such names appear only where
# a contraction is kept as a run-time loop. One of the triggers for lowering a
# state-array read to a runtime `_NK_STATE_GATHER`. Distinct from
# `_reads_bound_sym`, which fires for ANY symbol in a caller-supplied set.
_refs_loopvar(e::ASTExpr) =
    _args_any(x -> x isa VarExpr && startswith((x::VarExpr).name, _LOOPVAR_PREFIX), e)

# Lower a STATE-array read whose subscripts depend on a contraction loop variable
# (`q[donor(i,k)]`) to a runtime `_NK_STATE_GATHER`. The
# frozen slot table maps every in-bounds state cell to its flat `u` slot (built
# once per state var per build, shared across output cells via the build state's slot tables);
# the subscript expressions resolve normally (a loop var → `_NK_LOOPVAR`; an indirect
# `index(conn,i,k)` → a nested `_NK_CONST_GATHER`) and become the node's children,
# evaluated + bounds-checked at eval time. A missing state cell (sparse layout)
# throws, which the loop-build try/catch converts to a fall-back to the exact unroll.
function _resolve_state_gather(
        vname::String, lo::Vector{Int}, hi::Vector{Int},
        idx_args::Vector{ASTExpr}, array_var_info, var_map::AbstractDict{String, Int},
        const_arrays::AbstractDict, pgather::AbstractDict, memo::_MaybeMemo,
        bound_syms::Set{String}
    )
    nd = length(lo)
    sub_nodes = ASTExpr[
        _resolve_indices(
            a, array_var_info, var_map, const_arrays,
            pgather, memo, bound_syms
        ) for a in idx_args
    ]
    slot_flat, strides = get!(_build_state().slot_tables, vname) do
        dims = Int[hi[d] - lo[d] + 1 for d in 1:nd]
        strd = Vector{Int}(undef, nd)
        strd[1] = 1
        for d in 2:nd
            strd[d] = strd[d - 1] * dims[d - 1]
        end
        total = prod(dims)
        sf = Vector{Int}(undef, total)
        cur = Vector{Int}(undef, nd)
        # A variable laid out as one block is read by arithmetic; formatting a
        # cell key per cell would make this table cost far more per cell than
        # the integers it holds.
        blk = _vm_block(var_map, vname)
        if blk !== nothing && blk.lo == lo && blk.hi == hi && blk.strides == strd
            for lin in 0:(total - 1)
                sf[lin + 1] = blk.base + lin
            end
            return (sf, strd)
        end
        for lin in 0:(total - 1)
            rem = lin
            for d in 1:nd
                cur[d] = lo[d] + (rem % dims[d]); rem ÷= dims[d]
            end
            slot = blk === nothing ? 0 : _block_slot(blk, cur)
            if slot == 0
                cname = _cell_key(vname, cur)
                haskey(var_map, cname) ||
                    throw(TreeWalkError("E_TREEWALK_MISSING_CELL", cname))
                slot = var_map[cname]
            end
            sf[lin + 1] = slot
        end
        (sf, strd)
    end
    return OpExpr(
        "__state_gather", sub_nodes;
        value = _StateGatherRef(slot_flat, strides, copy(lo), copy(hi))
    )
end

# Resolve each expression in `args`, returning `(resolved, changed)`. When no
# element changes under resolution the ORIGINAL `args` vector is returned (no
# allocation) and `changed` is false, letting the caller keep its node verbatim;
# only the first differing element triggers a single copy. Shared by the `index`
# fallback and the generic-recurse arm of `_resolve_indices`.
function _resolve_arg_vec(
        args::Vector{ASTExpr},
        array_var_info::Dict{String, Tuple{Vector{Int}, Vector{Int}}},
        var_map::AbstractDict{String, Int},
        const_arrays::AbstractDict,
        pgather::AbstractDict,
        memo::_MaybeMemo = nothing,
        bound_syms::Set{String} = _EMPTY_BOUND_SYMS
    )
    changed = false
    new_args = args
    @inbounds for i in eachindex(args)
        a = args[i]
        # Manual union-split (see `_sub_arg_vec`): the abstract `ASTExpr` element type
        # makes a bare `_resolve_indices(a, …)` a dynamic dispatch. `NumExpr`/
        # `IntExpr` resolve to themselves, so short-circuit them; `VarExpr` may
        # const-fold (scalar loader field) so it keeps its call; `OpExpr` recurses —
        # both now dispatch statically.
        r = a isa OpExpr ? _resolve_indices(a, array_var_info, var_map, const_arrays, pgather, memo, bound_syms) :
            a isa VarExpr ? _resolve_indices(a, array_var_info, var_map, const_arrays, pgather, memo, bound_syms) :
            a                                            # NumExpr / IntExpr: verbatim
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

function _resolve_indices(
        expr::NumExpr,
        array_var_info::Dict{String, Tuple{Vector{Int}, Vector{Int}}},
        var_map::AbstractDict{String, Int},
        const_arrays::AbstractDict = _EMPTY_CONST_ARRAYS,
        pgather::AbstractDict = _EMPTY_PGATHER,
        memo::_MaybeMemo = nothing,
        bound_syms::Set{String} = _EMPTY_BOUND_SYMS
    )
    return expr
end
function _resolve_indices(
        expr::IntExpr,
        array_var_info::Dict{String, Tuple{Vector{Int}, Vector{Int}}},
        var_map::AbstractDict{String, Int},
        const_arrays::AbstractDict = _EMPTY_CONST_ARRAYS,
        pgather::AbstractDict = _EMPTY_PGATHER,
        memo::_MaybeMemo = nothing,
        bound_syms::Set{String} = _EMPTY_BOUND_SYMS
    )
    return expr
end
function _resolve_indices(
        expr::VarExpr,
        array_var_info::Dict{String, Tuple{Vector{Int}, Vector{Int}}},
        var_map::AbstractDict{String, Int},
        const_arrays::AbstractDict = _EMPTY_CONST_ARRAYS,
        pgather::AbstractDict = _EMPTY_PGATHER,
        memo::_MaybeMemo = nothing,
        bound_syms::Set{String} = _EMPTY_BOUND_SYMS
    )
    # Bare (un-indexed) reference to a const-array-backed SCALAR field
    # (RFC pure-io-data-loaders §4.3): a pure-I/O data-loader subsystem lowers
    # each of its variables to a const-array-backed observed keyed
    # `<owner>.<subkey>.<var>` (see flatten `_collect_model!`), and the provider
    # seam materializes a CONST loader field into `const_arrays` under that same
    # name (simulate.jl). When such a field is referenced by BARE name (not via a
    # gather `index(name, …)`) and is a genuine scalar — a 0-D field or a
    # single-cell array — const-fold it to its literal value here, so the compiler
    # (which only consults state/param maps) resolves it exactly as the gather path
    # already resolves `index(name, …)`. A live state slot always wins (never a
    # loader field), and a multi-element array left bare is not scalarisable, so it
    # passes through unchanged for the array machinery / normal error path.
    # The live sibling: a bare reference to a ONE-CELL forcing buffer — the
    # buffer a discrete provider rewrites for a 0-d data-fed parameter — reads
    # the buffer, never a literal, exactly as `index(name, 1)` does below. The
    # partition gives such a parameter no `p` slot (`_partition_variables`), so
    # this is the only place its value comes from. A name a faq body binds
    # shadows the buffer (`bound_syms`), and a discrete-cadence cache the build
    # registered beside the buffers is not one.
    if !haskey(var_map, expr.name) && !(expr.name in bound_syms) &&
            haskey(pgather, expr.name)
        pg = pgather[expr.name]::_PGatherArray
        if !pg.cache && length(pg.flat) == 1
            return OpExpr(
                "index", ASTExpr[];
                value = _PGatherRef(pg.flat, 1, expr.name)
            )
        end
    end
    if !haskey(var_map, expr.name) && haskey(const_arrays, expr.name)
        arr = const_arrays[expr.name]
        if arr isa AbstractArray && length(arr) == 1
            return NumExpr(Float64(first(arr)))
        end
    end
    return expr
end
function _resolve_indices(
        expr::OpExpr,
        array_var_info::Dict{String, Tuple{Vector{Int}, Vector{Int}}},
        var_map::AbstractDict{String, Int},
        const_arrays::AbstractDict = _EMPTY_CONST_ARRAYS,
        pgather::AbstractDict = _EMPTY_PGATHER,
        memo::_MaybeMemo = nothing,
        bound_syms::Set{String} = _EMPTY_BOUND_SYMS
    )
    # The memo is keyed on node identity and is a pure function of the node ONLY
    # for a fixed `bound_syms`. It is threaded exclusively on the empty-`bound_syms`
    # RHS-build path (the compile-once fast path passes `memo=nothing`), so the two
    # modes never share a memo — a symbolic resolution can never be served from a
    # concrete memo entry.
    memo === nothing &&
        return _resolve_indices_op(expr, array_var_info, var_map, const_arrays, pgather, nothing, bound_syms)
    m = memo.resolve
    r = get(m, expr, nothing)
    r === nothing || return r
    n0 = memo.deferrals[]
    r = _resolve_indices_op(expr, array_var_info, var_map, const_arrays, pgather, memo, bound_syms)
    # A read deferred under a guard this node sits under is this context's
    # answer only: the same (interned) node reached unguarded must still raise
    # at build. A deferral under guards inside the node is the node's own.
    (memo.deferrals[] == n0 || isempty(_resolve_guards())) && (m[expr] = r)
    return r
end
function _resolve_indices_op(
        expr::OpExpr,
        array_var_info::Dict{String, Tuple{Vector{Int}, Vector{Int}}},
        var_map::AbstractDict{String, Int},
        const_arrays::AbstractDict = _EMPTY_CONST_ARRAYS,
        pgather::AbstractDict = _EMPTY_PGATHER,
        memo::_MaybeMemo = nothing,
        bound_syms::Set{String} = _EMPTY_BOUND_SYMS
    )
    if (
            expr.op == "ifelse" && length(expr.args) == 3 ||
                (expr.op == "and" || expr.op == "or") && length(expr.args) >= 2
        ) &&
            expr.expr_body === nothing && expr.values === nothing
        return _resolve_guarded_op(
            expr, array_var_info, var_map, const_arrays,
            pgather, memo, bound_syms
        )
    end
    expr.op == "index" && return _resolve_index_op(
        expr, array_var_info, var_map, const_arrays, pgather, memo, bound_syms
    )
    if expr.op == "integral"
        r = _resolve_integral(expr, array_var_info, var_map)
        r === nothing || return r
    end
    # Scalar aggregate (empty output_idx) in expression position: expand inline.
    # Non-scalar aggregate (non-empty output_idx) must be wrapped in index() —
    # handled by the _resolve_indices index-of-aggregate branch above.
    if _is_faq_op(expr.op)
        if isempty(_output_idx_strings(expr))
            return _resolve_scalar_faq(expr, array_var_info, var_map, const_arrays, pgather, memo, bound_syms)
        end
        # Non-scalar faq without index() — pass through (will become a
        # compile-time error in _compile with a helpful message).
    end
    new_args, changed = _resolve_arg_vec(expr.args, array_var_info, var_map, const_arrays, pgather, memo, bound_syms)
    new_body = expr.expr_body
    if expr.expr_body !== nothing
        new_body = _resolve_indices(expr.expr_body, array_var_info, var_map, const_arrays, pgather, memo, bound_syms)
        changed |= new_body !== expr.expr_body
    end
    new_values = expr.values
    if expr.values !== nothing
        nv, vchanged = _resolve_arg_vec(expr.values, array_var_info, var_map, const_arrays, pgather, memo, bound_syms)
        new_values = nv
        changed |= vchanged
    end
    # No child, body, or value expression changed under resolution ⇒ the node is
    # already fully resolved; return it verbatim rather than rebuilding a ~30-field
    # OpExpr. In a stencil RHS the pure-parameter subtrees hit this fast path.
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

function _resolve_index_op(
        expr::OpExpr, array_var_info, var_map, const_arrays, pgather, memo, bound_syms
    )
    isempty(expr.args) &&
        throw(TreeWalkError("E_TREEWALK_INDEX_EMPTY", "index op requires at least one arg"))
    target = expr.args[1]
    subs = expr.args[2:end]
    kind = _index_target_kind(target)
    if kind === _IT_FAQ
        # Expanded at build time by substituting the output indices and
        # unrolling the contracted ones, as `_compile_faq_percell!` does for a
        # whole-array derivative equation.
        return _resolve_index_of_faq(
            target::OpExpr, subs, array_var_info, var_map, const_arrays, pgather, memo, bound_syms
        )
    elseif kind === _IT_MAKEARRAY
        # The value whose region covers (k1, …); later regions win.
        return _resolve_index_of_makearray(
            target::OpExpr, subs, array_var_info, var_map, const_arrays, pgather, memo, bound_syms
        )
    elseif kind === _IT_SHAPE_OP
        return _resolve_indices(
            _index_through_shape_op(target::OpExpr, subs, array_var_info, const_arrays, pgather),
            array_var_info, var_map, const_arrays, pgather, memo, bound_syms
        )
    elseif kind === _IT_ELEMENTWISE
        r = _resolve_index_of_elementwise(
            target::OpExpr, subs, array_var_info, var_map, const_arrays, pgather, memo, bound_syms
        )
        r === nothing || return r
    elseif kind === _IT_CONST_ARRAY
        return _resolve_index_of_inline_const(
            target::OpExpr, subs, array_var_info, var_map, const_arrays, pgather, memo, bound_syms
        )
    elseif kind === _IT_NAME
        n = (target::VarExpr).name
        src = _array_source(n, array_var_info, pgather, const_arrays)
        src === :state && return _resolve_index_of_state(
            n, subs, array_var_info, var_map, const_arrays, pgather, memo, bound_syms
        )
        src === :forcing && return _resolve_index_of_forcing(
            n, subs, array_var_info, var_map, const_arrays, pgather, memo, bound_syms
        )
        # Pre-computed constant arrays: run-time and constant subscripts alike
        # go through `_resolve_const_array_gather`.
        src === :const && return _resolve_const_array_gather(
            const_arrays[n], n, subs, array_var_info, var_map,
            const_arrays, pgather, memo, bound_syms
        )
    end
    # A scalar or unknown target: resolve the arguments only.
    new_args, changed = _resolve_arg_vec(expr.args, array_var_info, var_map, const_arrays, pgather, memo, bound_syms)
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
function _resolve_index_of_elementwise(
        fa::OpExpr, subs::Vector{ASTExpr}, array_var_info, var_map, const_arrays,
        pgather, memo, bound_syms
    )
    # The operand test is `_index_pushdown_arrayish` (build_helpers.jl),
    # shared with `_stencilize_index`: it looks THROUGH nested elementwise
    # ops, so `index(1 + cos(pi*zc), j)` — an elementwise-defined array
    # observed folded into a reader that gathers it — distributes down to
    # `1 + cos(pi*index(zc, j))` instead of dropping the gather and
    # leaving `zc` bare. The leaf test spans every array source an index
    # can gather (`_array_name`).
    _leaf_is_array(n) = _array_name(n, array_var_info, pgather, const_arrays)
    _amemo = IdDict{OpExpr, Bool}()
    _arrayish(a) = _index_pushdown_arrayish(a, _leaf_is_array, _amemo)
    if _anyof(_arrayish, fa.args)
        # A combination with a shape-op operand is anonymous, and its
        # operands broadcast positionally (§4.3.4): each reads the
        # subscripts its own shape admits. A combination of variables
        # alone is left to the name-aligned lift, which has already
        # written each operand's own subscripts.
        fshape = _mentions_shape_op(fa) ?
            _remap_operand_shape(fa, array_var_info, const_arrays, pgather) : nothing
        rext = fshape === nothing ? nothing : fshape[2]
        _subs_for(a) = (rext === nothing || length(rext) != length(subs)) ? subs :
            something(
                _broadcast_operand_subs(
                    a, subs, rext, array_var_info,
                    const_arrays, pgather
                ), subs
            )
        pushed = ASTExpr[
            _arrayish(a) ? OpExpr("index", ASTExpr[a, _subs_for(a)...]) : a
                for a in fa.args
        ]
        return _resolve_indices(
            reconstruct(fa; args = pushed), array_var_info,
            var_map, const_arrays, pgather, memo, bound_syms
        )
    end
    return nothing
end

# Expression-position INLINE `const` array literal:
# index({op:const, value:[…]}, k1, …). A non-scalar `const` used as an
# index target (e.g. the duo's `index({const [n][3][3]}, gt, d, k)`) is
# build-time literal data — the same shape as a REGISTERED const-array
# observed, only authored inline. Intern it (dedup by value) and gather it
# through the shared const-array path so a constant index folds to the
# element and a symbolic loop var lowers to a `_ConstGatherRef`. Without
# this the literal survives untouched to `_compile` and hits the
# `non-scalar const outside an array-consuming position` dead-end. A SCALAR
# `const` (a `Real` value) is not an array target — it falls through to the
# generic recurse and const-folds in `_compile` as before.
function _resolve_index_of_inline_const(
        c::OpExpr, subs::Vector{ASTExpr}, array_var_info, var_map, const_arrays,
        pgather, memo, bound_syms
    )
    vals, cname = memo === nothing ?
        _intern_inline_const(c, const_arrays) :
        get!(() -> _intern_inline_const(c, const_arrays), memo.inline, c)
    return _resolve_const_array_gather(
        vals, cname, subs,
        array_var_info, var_map, const_arrays, pgather, memo, bound_syms
    )
end

# `index(v, k…)` of an array state `v`: the cell's state reference, a ghost
# cell's `0.0`, or a run-time state gather when a subscript is only known per
# call.
function _resolve_index_of_state(
        vname::String, idx_args::Vector{ASTExpr}, array_var_info, var_map, const_arrays,
        pgather, memo, bound_syms
    )
    lo, hi = array_var_info[vname]
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
            a -> _refs_loopvar(a) || _subscript_is_runtime(a, bound_syms, const_arrays),
            idx_args
        )
        return _resolve_state_gather(
            vname, lo, hi, idx_args, array_var_info,
            var_map, const_arrays, pgather, memo, bound_syms
        )
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
                !isempty(_resolve_guards()) && !_guarded_read_taken(_resolve_guards())
        ) ||
            rethrow()
        return _resolve_state_gather(
            vname, lo, hi, idx_args, array_var_info,
            var_map, const_arrays, pgather, memo, bound_syms
        )
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
function _resolve_index_of_forcing(
        name::String, idx_args_expr::Vector{ASTExpr}, array_var_info, var_map, const_arrays,
        pgather, memo, bound_syms
    )
    pg = pgather[name]::_PGatherArray
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
    if !isempty(bound_syms) &&
            _anyof(a -> _subscript_is_runtime(a, const_arrays), idx_args_expr) &&
            all(
            a -> !_subscript_is_runtime(a, const_arrays) ||
                _subscript_from_counters(a, bound_syms),
            idx_args_expr
        )
        sub_nodes = Vector{ASTExpr}(undef, length(idx_args_expr))
        for d in eachindex(idx_args_expr)
            a = idx_args_expr[d]
            if _subscript_is_runtime(a, const_arrays)
                sub_nodes[d] = _resolve_indices(
                    a, array_var_info, var_map, const_arrays,
                    pgather, memo, bound_syms
                )
            else
                ci = _eval_const_int(a, _EMPTY_IDX_ENV, const_arrays)
                # Out of range under a guard the build cannot show
                # taken: the run-time gather checks it if evaluated.
                (1 <= ci <= pg.dims[d]) || _guarded_oob_deferred() ||
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
        _guarded_oob_deferred() && return OpExpr(
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
