# Lowering of the ESM `faq` node (and the shapes its left-hand sides imply) to
# `SymbolicUtils.ArrayOp`.
const SymReal = SymUtils.SymReal
const ConstSR = SymUtils.Const{SymReal}

"""
    get_idx_vars(ndim) -> Vector

`ndim` symbolic integer index variables drawn from the shared ArrayOp index
pool (`SymbolicUtils.idxs_for_arrayop(SymReal)`), so indices interoperate
cleanly when ArrayOps are composed.
"""
function get_idx_vars(ndim::Int)
    idxs_arr = SymUtils.idxs_for_arrayop(SymReal)
    return [idxs_arr[d] for d in 1:ndim]
end

# ========================================
# faq reduction helpers
# ========================================

# The ⊕ spellings this lowering folds with, mapped to the Julia reducer the
# low-level `SymbolicUtils.ArrayOp` constructor takes (functions from the op
# registry, same pattern as `_BROADCAST_FNS` in lowering.jl).
const _REDUCE_FNS = Dict{String, Function}(
    name => EarthSciAST._op_spec(name).scalar_fn
        for name in ("+", "*", "max", "min")
)

# The reducer and the 0̄ identity of a `faq` node. `semiring`, when present,
# supersedes `reduce` (esm-spec §4.3.1); both come from the same resolution the
# tree walk uses (`_aggregate_oplus_identity`). The identity is what a
# combination rejected by the node's `filter` contributes. `bool_and_or` (⊕ =
# `or`) has no lowering here.
function _faq_reduce(expr::OpExpr)
    oplus, zerobar = EarthSciAST._aggregate_oplus_identity(expr.semiring, expr.reduce)
    fn = get(_REDUCE_FNS, oplus, nothing)
    fn === nothing && throw(
        ArgumentError(
            "faq reduction ⊕ = '$(oplus)'" *
                (expr.semiring === nothing ? "" : " (semiring '$(expr.semiring)')") *
                " has no ModelingToolkit lowering; the lowering folds +, *, max and min"
        )
    )
    return fn, zerobar
end

# ========================================
# Stencil boundary handling via numeric gather tables
# ========================================
#
# Background: an arrayop body for a discretized PDE stencil reads neighbor
# cells `u[i-1, j]`, `u[i, j+1]`, ... At a Dirichlet boundary (e.g. i=1) the
# read `u[i-1, j]` resolves to `u[0, j]`, which is OUTSIDE the 1:N field and
# must take the ghost value 0. The `_build_index` ghost guard only fires for
# CONCRETE integer indices; if we baked a SYMBOLIC offset `pool[k]-1` into the
# body, the OOB index would escape to scalarize-time as `u[0, j]` and raise an
# `ArgumentError` (out of `1:N` bounds).
#
# Fix (mirrors ESD's `_stencil_arrayop` / `_build_symbolic_ghost_extension` and
# the PDE-grid `_build_ghost_vals` / `_eval_at_nb`): resolve each stencil read
# over the declared range into a NUMERIC per-cell gather table at build time.
# Each `index` read `u[i±1, …]` becomes a `Const`-wrapped N-D table whose entry
# at output cell `(c₁,…,c_M)` is the in-bounds symbolic reference `u_sym[…]`,
# or `0` for an out-of-bounds (Dirichlet ghost) cell. The body then indexes that
# Const table with the RAW 1-based pool vars, so NO symbolic index ever leaves
# `1:N` — scalarize sees only 1-based positions into a precomputed table.

# The gather context itself (`_GatherCtx`) and the lowering context that carries
# it (`_Lowering.gather`) are defined in lowering.jl.

# Gate a per-combination body value by an aggregate `filter` predicate.
# A predicate over CONCRETE integer indices already folds to a `Bool` (the
# `_arrayop_scalar_reduce` path); a predicate over symbolic pool index vars
# stays symbolic and becomes an `ifelse`, which the ArrayOp scalarizer folds
# away once it substitutes concrete positions for the pool vars.
_gate_by_filter(pred::Bool, body, identity_val) = pred ? body : identity_val
_gate_by_filter(pred, body, identity_val) = ifelse(pred, body, identity_val)

# Pure-integer evaluation of an ESM index-argument expression given concrete
# integer values for the output index vars (`binding`). Returns the resolved
# Int, or `nothing` if the expression is not resolvable to a concrete integer
# from the output vars alone (e.g. it references a reduction var, a parameter,
# or a non-affine/function term — in which case the read is NOT gather-eligible
# and the caller falls back to the symbolic-offset path).
function _eval_index_arg_int(e::EsmExpr, binding::Dict{String, Int})
    if e isa IntExpr
        return Int(e.value)
    elseif e isa NumExpr
        v = e.value
        (isfinite(v) && v == floor(v)) || return nothing
        return Int(v)
    elseif e isa VarExpr
        return get(binding, e.name, nothing)
    elseif e isa OpExpr
        if e.op == "+" || e.op == "-" || e.op == "*"
            vals = Int[]
            for a in e.args
                r = _eval_index_arg_int(a, binding)
                r === nothing && return nothing
                push!(vals, r)
            end
            isempty(vals) && return nothing
            if e.op == "+"
                return sum(vals)
            elseif e.op == "*"
                return prod(vals)
            else # "-"
                return length(vals) == 1 ? -vals[1] : foldl(-, vals)
            end
        end
        return nothing
    end
    return nothing
end

# True iff EVERY index arg of an `index` node is resolvable to a concrete
# integer from the output index vars alone (across the whole output grid).
# Such reads are handled by a numeric gather table; everything else falls back.
function _index_args_gatherable(idx_args::Vector{<:EsmExpr}, ctx::_GatherCtx)
    isempty(idx_args) && return false
    # Probe with the lower-corner physical indices; `_eval_index_arg_int`
    # returns `nothing` structurally (independent of the concrete values) when
    # a non-output symbol or unsupported op appears, so one probe suffices.
    binding = Dict{String, Int}(name => lo for (name, (_, lo, _, _)) in ctx.out_vars)
    for a in idx_args
        _eval_index_arg_int(a, binding) === nothing && return false
    end
    return true
end

# Build the per-output-cell gather table for a single indexed read of a shaped
# state-variable array `arr` (a `Symbolics.Arr`). `idx_args` are the ESM index
# expressions (affine in the output vars). Each entry of the returned N-D table
# is `unwrap(arr[resolved...])` for an in-bounds read or `0` for a Dirichlet
# ghost (any axis out of the array's declared bounds). The table is then
# `Const`-wrapped and indexed by the output pool vars so it scalarizes cleanly.
function _build_gather_read(arr, idx_args::Vector{<:EsmExpr}, ctx::_GatherCtx)
    sz = size(arr)                       # declared 1-based field extent, e.g. (3, 3)
    ndim_out = length(ctx.out_order)
    dims = ntuple(d -> ctx.out_vars[ctx.out_order[d]][3], ndim_out)  # (N₁, …, N_M)

    table = Array{Any}(undef, dims...)
    for cell in CartesianIndices(dims)
        # Physical index value for each output var at this cell.
        binding = Dict{String, Int}()
        for d in 1:ndim_out
            name = ctx.out_order[d]
            _, lo, _, st = ctx.out_vars[name]
            binding[name] = lo + (cell[d] - 1) * st
        end
        # Resolve each axis index of the read.
        resolved = ntuple(
            k -> _eval_index_arg_int(idx_args[k], binding)::Int,
            length(idx_args)
        )
        inbounds = length(resolved) == length(sz) &&
            all(1 <= resolved[k] <= sz[k] for k in 1:length(resolved))
        table[cell] = inbounds ? Symbolics.unwrap(getindex(arr, resolved...)) :
            Symbolics.unwrap(Symbolics.Num(0))
    end

    pool_idx = Any[ctx.out_vars[ctx.out_order[d]][1] for d in 1:ndim_out]
    return Symbolics.wrap(ConstSR(table)[pool_idx...])
end

# Build an un-scalarized `Symbolics.wrap(ArrayOp)` for an ESM `arrayop` node.
# All index variables are drawn from the shared `SymbolicUtils.idxs_for_arrayop`
# pool; the body is built once with symbolic indices and handed to MTK's
# `mtkcompile` to own scalarization. The pool vars run over `1:length(r)`;
# the body sees each range's physical index through `idx_body` below.
#
# Stencil neighbor reads that can leave the field bounds at a boundary cell are
# materialized as numeric gather tables (see `_build_gather_read` above) so no
# symbolic out-of-bounds index ever reaches the scalarizer.
function _build_arrayop_sym(expr::OpExpr, L::_Lowering)
    output_idx = expr.output_idx === nothing ? Any[] : expr.output_idx
    body = expr.expr_body
    body === nothing && throw(ArgumentError("arrayop node missing 'expr' body"))
    reduce_fn, identity_val = _faq_reduce(expr)

    expr.ranges === nothing && throw(
        ArgumentError(
            "arrayop without explicit 'ranges' is not supported — all index " *
                "variables must declare a concrete range"
        )
    )
    expr.join === nothing && expr.join_gates === nothing || throw(
        ArgumentError(
            "relational `join` clauses on an aggregate are not supported by the " *
                "MTK evaluator path — use the tree-walk evaluator (`esm_problem`)"
        )
    )
    ranges = Dict{String, StepRange{Int, Int}}()
    for (name, r) in expr.ranges
        ranges[name] = _range_int(r, L.extents)
    end

    output_names = String[]
    for entry in output_idx
        if entry isa AbstractString
            name = String(entry)
            haskey(ranges, name) || throw(ArgumentError("arrayop output index '$name' has no declared range"))
            push!(output_names, name)
        elseif entry == 1
            # Singleton axis — no iteration variable; shape 1 handled below.
        else
            throw(ArgumentError("arrayop output_idx entry must be a string or 1, got $(entry)"))
        end
    end

    # Pure scalar output (empty output_idx or all singletons): pre-scalarize
    # via integer iteration (rare path, not in current simulation fixtures).
    if isempty(output_names)
        return _arrayop_scalar_reduce(
            body, L, ranges, reduce_fn, expr.filter, identity_val
        )
    end

    # Draw symbolic integer index vars from the shared pool.
    # One per named range entry (output + reduction) + one per singleton axis.
    n_singletons = count(==(1), output_idx)
    all_named = collect(keys(ranges))
    n_named = length(all_named)
    pool = get_idx_vars(n_named + n_singletons)
    # idx_sym: raw pool vars, used as keys in output_idx_syms and ranges_sym.
    # idx_body: the physical index as a function of the pool var, bound in
    # `L.vars` for body evaluation. SymbolicUtils scalarizes by iterating the
    # shape (1:length(r)) and substituting pool[k] = 1..N, so for a range
    # `lo:st:hi` the body sees `lo + (pool[k] - 1) * st` (e.g. i ∈ 2:4 gives
    # 2..4 for pool[k] = 1..3, and i ∈ 1:2:5 gives 1, 3, 5).
    idx_sym = Dict{String, Any}()
    idx_body = Dict{String, Any}()
    for (k, name) in enumerate(all_named)
        r = ranges[name]
        idx_sym[name] = pool[k]
        # Use pool[k] directly (BasicSymbolic{SymReal}), not Symbolics.wrap(pool[k])
        # (Num), so that u[idx_body[i], idx_body[j]] dispatches correctly.
        idx_body[name] = if step(r) == 1
            first(r) == 1 ? pool[k] : pool[k] + (first(r) - 1)
        else
            step(r) * pool[k] + (first(r) - step(r))
        end
    end
    singleton_vars = [pool[n_named + s] for s in 1:n_singletons]

    # Build the gather context for the OUTPUT index vars. Stencil reads whose
    # indices are affine in these (and so resolvable to a concrete cell index)
    # are materialized as numeric gather tables inside `_build_index`, which
    # keeps boundary/ghost reads within `1:N`. Reads referencing reduction-only
    # index vars are not gatherable and fall back to the symbolic-offset path
    # below (correct for in-bounds contractions, which was already passing).
    out_vars = Dict{String, Tuple{Any, Int, Int, Int}}()
    out_order = String[]
    for entry in output_idx
        entry isa AbstractString || continue
        name = String(entry)
        r = ranges[name]
        out_vars[name] = (pool[findfirst(==(name), all_named)], first(r), length(r), step(r))
        push!(out_order, name)
    end
    gather_ctx = _GatherCtx(out_vars, out_order)

    # Bind the OFFSET-ADJUSTED index vars and install the gather context so
    # `_build_index` can intercept gather-eligible reads; both are restored
    # afterwards.
    body_sym = _with_bindings(L, idx_body) do
        _with_gather(L, gather_ctx) do
            b = _esm_to_symbolic(body, L)
            # `filter` gate (RFC semiring-faq-unified-ir §5.3, esm-spec §4.3.1).
            # The predicate is built under the SAME index bindings as the body, so
            # a cumulative/prefix reduction — `filter: {"<=": ["j", "i"]}` and
            # friends — becomes `ifelse(j <= i, body, identity)` over the full
            # rectangular `i × j` range. The scalarizer substitutes concrete
            # positions for both pool vars, folding each `ifelse` to one branch,
            # so cell `i` reduces exactly the admitted WINDOW (which `j` values
            # contribute), which is the part of §4.3.1 this path does honor.
            #
            # ORDER IS NOT HONORED — read this before trusting a low bit.
            # §4.3.1 additionally makes the ascending-`j` LEFT FOLD normative:
            # `((b_a ⊕ b_{a+1}) ⊕ b_{a+2}) ⊕ …`, lowest admitted `j` first. This
            # path cannot deliver that. The gated terms are handed to SymbolicUtils
            # as an n-ary `+`, which stores and emits them in ITS canonical term
            # order, not ours; re-association is inherent to lowering a sum into a
            # symbolic algebra and is not something a caller can switch off.
            #
            # The divergence is NOT confined to the last ulp. On a window whose
            # partial sums cancel it is O(1) absolute — with u = [1e16, 1, -1e16, 1]
            # the normative fold gives fwd_inc = [1e16, 1e16, 0, 1] (what the
            # tree-walk evaluator produces) while this path gives [1e16, 1e16, 1, 2].
            # Bit-agreement with the tree-walk holds only when the summands are
            # exactly representable and no cancellation occurs — which is why the
            # conformance fixtures (powers of two; 0.5/0.25/0.125) match bit-for-bit
            # and are NOT evidence of a general guarantee.
            #
            # esm-spec §4.3.1 pins bit-exactness on the EXECUTING bindings; in Julia
            # that is the tree-walk evaluator (`_build_evaluator`, src/tree_walk/
            # scan.jl, pinned by test/scan_prefix_test.jl), not this MTK export
            # path. Callers who need the normative low bits must use it.
            # Pinned by "Cumulative prefix reductions (MTK lowering)" in
            # test/mtk/array_ops_mtk_test.jl, where the cancellation case is `@test_broken`.
            if expr.filter !== nothing
                pred = _esm_to_symbolic(expr.filter, L)
                b = _gate_by_filter(pred, b, identity_val)
            end
            b
        end
    end

    # Assemble output index symbol list using RAW pool vars (not offset-adjusted),
    # interleaving named and singleton vars.
    output_idx_syms = Any[]
    s_i = 0
    for entry in output_idx
        if entry isa AbstractString
            push!(output_idx_syms, idx_sym[String(entry)])
        else
            s_i += 1
            push!(output_idx_syms, singleton_vars[s_i])
        end
    end

    # Ranges dict keyed by RAW pool vars, all 1-based (shape = 1:length(r)).
    # The body uses idx_body (offset-adjusted) so physical index values are correct.
    ranges_sym = Dict{Any, Any}()
    for (name, r) in ranges
        ranges_sym[idx_sym[name]] = StepRange(1, 1, length(r))
    end
    for sv in singleton_vars
        ranges_sym[sv] = StepRange(1, 1, 1)
    end

    body_unwrapped = Symbolics.unwrap(body_sym)
    # arrayop_shape requires a BasicSymbolic; wrap numeric constants (e.g. literal
    # Dirichlet BC bodies like `0.0`) so ArrayOp construction doesn't MethodError.
    if !(body_unwrapped isa SymUtils.BasicSymbolic)
        body_unwrapped = ConstSR(body_unwrapped)
    end
    arr_op = SymUtils.ArrayOp{SymReal}(
        output_idx_syms, body_unwrapped,
        reduce_fn, nothing, ranges_sym
    )
    return Symbolics.wrap(arr_op)
end

# Scalar-output fallback: iterate all ranges and reduce. Used only when
# output_idx is empty or all-singleton (no named output dimensions).
function _arrayop_scalar_reduce(
        body, L::_Lowering, ranges, reduce_fn,
        filt = nothing, identity_val = 0.0
    )
    all_names = collect(keys(ranges))
    range_tuple = Tuple(ranges[n] for n in all_names)
    acc = nothing
    for vals in Iterators.product(range_tuple...)
        contrib = _with_bindings(L, zip(all_names, map(Int, vals))) do
            b = _esm_to_symbolic(body, L)
            if filt !== nothing
                pred = _esm_to_symbolic(filt, L)
                b = _gate_by_filter(pred, b, identity_val)
            end
            b
        end
        acc = acc === nothing ? contrib : reduce_fn(acc, contrib)
    end
    return acc === nothing ? Symbolics.Num(0) : acc
end

# Compute the authoritative shape for array state variables by taking the
# union of all LHS-defined cell ranges across equations. This correctly
# handles both full-domain periodic stencils (where ghost-cell body accesses
# would otherwise cause infer_array_shapes to widen beyond the real grid)
# and interior-only stencils with separate scalar boundary equations.
#
# Three LHS forms are recognized:
#   1. faq      — output_idx+ranges give a rectangular region
#   2. D(u[k])  — scalar differential with a concrete integer index
#   3. index(u, k1, k2, ...) — direct indexed LHS
#
# The resulting shape is the union of all such contributions per variable.
function _lhs_arrayop_shapes(
        equations::Vector{Equation},
        extents::AbstractDict = _NO_EXTENTS
    )
    shapes = Dict{String, Vector{UnitRange{Int}}}()
    for eq in equations
        lhs = eq.lhs
        lhs isa OpExpr || continue
        # The ESM wire tag `faq`, not SymbolicUtils' `ArrayOp`.
        if lhs.op == "faq"
            lhs.ranges === nothing && continue
            lhs.output_idx === nothing && continue
            isempty(lhs.output_idx) && continue
            body = lhs.expr_body
            body isa OpExpr || continue
            vname = if body.op == "D" && !isempty(body.args)
                inner = body.args[1]
                (
                        inner isa OpExpr && inner.op == "index" &&
                        !isempty(inner.args) && inner.args[1] isa VarExpr
                    ) ?
                    inner.args[1].name : nothing
            elseif body.op == "index"
                (!isempty(body.args) && body.args[1] isa VarExpr) ?
                    body.args[1].name : nothing
            else
                nothing
            end
            vname === nothing && continue
            axis_ranges = UnitRange{Int}[]
            all_found = true
            for entry in lhs.output_idx
                entry isa AbstractString || continue
                r = get(lhs.ranges, String(entry), nothing)
                if r === nothing
                    all_found = false; break
                end
                lo, hi = _range_bounds_int(r, extents)
                push!(axis_ranges, lo:hi)
            end
            (!all_found || isempty(axis_ranges)) && continue
            _merge_lhs_shape!(shapes, vname, axis_ranges)
        elseif lhs.op == "D" && !isempty(lhs.args)
            # Scalar D(u[k], t): concrete integer index for boundary cells
            inner = lhs.args[1]
            inner isa OpExpr && inner.op == "index" || continue
            !isempty(inner.args) && inner.args[1] isa VarExpr || continue
            vname = inner.args[1].name
            axis_ranges = _concrete_index_ranges(inner.args[2:end])
            axis_ranges === nothing && continue
            _merge_lhs_shape!(shapes, vname, axis_ranges)
        elseif lhs.op == "index"
            # Direct indexed LHS: u[k1, k2, ...] = ...
            !isempty(lhs.args) && lhs.args[1] isa VarExpr || continue
            vname = lhs.args[1].name
            axis_ranges = _concrete_index_ranges(lhs.args[2:end])
            axis_ranges === nothing && continue
            _merge_lhs_shape!(shapes, vname, axis_ranges)
        end
    end
    return shapes
end

# Decode the index arguments of an `index` node (`args[2:end]`) into
# single-cell ranges `v:v`. Returns `nothing` when any index is not a
# concrete integer (IntExpr, or a whole-number NumExpr) or when there are no
# index args at all — the caller skips such an LHS as a shape contribution.
function _concrete_index_ranges(args)
    axis_ranges = UnitRange{Int}[]
    for a in args
        if a isa IntExpr
            v = Int(a.value)
        elseif a isa NumExpr && isinteger(a.value)
            v = Int(a.value)
        else
            return nothing
        end
        push!(axis_ranges, v:v)
    end
    return isempty(axis_ranges) ? nothing : axis_ranges
end

function _merge_lhs_shape!(
        shapes::Dict{String, Vector{UnitRange{Int}}},
        vname::String, axis_ranges::Vector{UnitRange{Int}}
    )
    return if haskey(shapes, vname)
        ex = shapes[vname]
        length(ex) == length(axis_ranges) || return
        for (d, r) in enumerate(axis_ranges)
            ex[d] = min(first(ex[d]), first(r)):max(last(ex[d]), last(r))
        end
    else
        shapes[vname] = copy(axis_ranges)
    end
end

# Decode a `ranges` entry to integer bounds.
#
# Two spellings reach here (src/parse.jl `_parse_ranges`):
#   1. a dense array `[lo, hi]` / `[lo, step, hi]`;
#   2. an `IndexSetRef` — `{ "from": <index_sets key>, "of"?: [...] }` (RFC
#      semiring-faq-unified-ir §5.2) — whose extent lives in the DOCUMENT-scoped
#      index-set registry, not in the node. `extents` is that registry reduced to
#      name => size (see `_index_set_extents` in variables.jl); it arrives here
#      as `_Lowering.extents`.
#
# Anything else is rejected with an `ArgumentError` naming the offending form —
# never a `MethodError`.
#
# `_range_int` returns the iteration range itself (a stepped `[start, step,
# stop]` keeps its step, esm-spec §4.3.1); `_range_bounds_int` returns the first
# and last index that range visits.
const _NO_EXTENTS = Dict{String, Int}()

function _range_bounds_int(r, extents::AbstractDict = _NO_EXTENTS)
    rr = _range_int(r, extents)
    isempty(rr) && throw(ArgumentError("range $(r) is empty"))
    return first(rr), last(rr)
end

function _range_int(r::AbstractVector, extents::AbstractDict = _NO_EXTENTS)
    all(x -> x isa Integer, r) || throw(
        ArgumentError(
            "expression-valued range bounds are not supported by the MTK evaluator path"
        )
    )
    if length(r) == 2
        return Int(r[1]):1:Int(r[2])
    elseif length(r) == 3
        Int(r[2]) == 0 && throw(ArgumentError("range $(r) has step 0"))
        return Int(r[1]):Int(r[2]):Int(r[3])
    end
    throw(ArgumentError("range must have 2 or 3 entries, got $(length(r))"))
end

function _range_int(
        r::EarthSciAST.IndexSetRef,
        extents::AbstractDict = _NO_EXTENTS
    )
    isempty(r.of) || throw(
        ArgumentError(
            "ragged index-set range `{from: \"$(r.from)\", of: $(r.of)}` is not " *
                "supported by the MTK evaluator path — its extent varies with its " *
                "parent index, so it has no single rectangular bound"
        )
    )
    n = get(extents, r.from, nothing)
    n === nothing && throw(
        ArgumentError(
            "cannot resolve the extent of index set '$(r.from)' in the MTK " *
                "evaluator path: it is not in the flattened system's index-set " *
                "registry. Build the system from a `FlattenedSystem` whose " *
                "`index_sets` carry it (`flatten(::EsmFile)`); `flatten(::Model)` " *
                "wraps the model in a synthetic file with an EMPTY registry"
        )
    )
    n < 1 && throw(
        ArgumentError(
            "index set '$(r.from)' has non-positive size $(n)"
        )
    )
    return 1:1:Int(n)
end

_range_int(r, extents::AbstractDict = _NO_EXTENTS) = throw(
    ArgumentError(
        "unsupported `ranges` entry of type $(typeof(r)): the MTK evaluator path " *
            "accepts a dense `[lo, hi]`/`[lo, step, hi]` array or an index-set " *
            "reference `{from: <index set>}`"
    )
)
