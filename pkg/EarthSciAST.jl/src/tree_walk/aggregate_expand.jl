# tree_walk/aggregate_expand.jl — the one unroll of an aggregate's contracted
# indices (product, ragged nest, or gate-driven), shared by every expansion site.

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

# `pred` holds for `e` or a node under it reached through its operands alone
# (`_operands`: `args`, or a template call's arguments). The walk for a
# subscript or a range bound, which is integer arithmetic over names with no
# expression-bearing field but its operands.
_args_any(pred::P, e::ASTExpr) where {P} =
    pred(e)::Bool || (e isa OpExpr && _anyof(a -> _args_any(pred, a), _operands(e::OpExpr)))

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
