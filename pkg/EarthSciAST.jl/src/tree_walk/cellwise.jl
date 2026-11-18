# tree_walk/cellwise.jl — cell-wise evaluation: an expression indexed at a cell, the
# per-cell evaluator, and the compile-once cell evaluators with their memo.

"""
    _index_at_cell(expr, idxs) -> ASTExpr

Broadcast-index an elementwise expression at the concrete 1-based cell `idxs`:
every array-PRODUCING node (`makearray`, or `faq` with non-empty
`output_idx`) is wrapped in `index(node, idxs…)`, elementwise ops are descended,
and scalar leaves (literals, scalar names, `index` gathers, scalar reductions)
pass through. The concrete-index dual of `_index_array_leaves` (loop-name form).
"""
function _index_at_cell(expr::EarthSciAST.ASTExpr, idxs::Vector{Int})::EarthSciAST.ASTExpr
    if expr isa OpExpr
        if _is_array_producer(expr)
            idx_args = ASTExpr[expr]
            for k in idxs
                push!(idx_args, IntExpr(Int64(k)))
            end
            return OpExpr("index", idx_args)
        end
        (
            expr.op == "faq" || expr.op == "makearray" ||
                expr.op == "index"
        ) && return expr
        return reconstruct(expr; args = ASTExpr[_index_at_cell(a, idxs) for a in expr.args])
    end
    return expr
end

"""
    _index_at_cell_sym(expr, syms) -> ASTExpr

The SYMBOLIC-output-index twin of [`_index_at_cell`](@ref) (wall2 Phase C): every
array-PRODUCING node is wrapped in `index(node, VarExpr(syms[1]), …)` instead of
`index(node, IntExpr(cell[1]), …)`, so the output indices stay symbolic through
`_resolve_indices`/unrolling and the whole observed body compiles ONCE with the
output indices bound as parameters (`syms` are reserved names the compile-once
`evaluate_cellwise` fast path binds per cell). Structurally identical to
`_index_at_cell` in every other respect — same descent through elementwise ops,
same scalar-leaf passthrough — so the resulting reduction term order (and thus the
floating-point sum) is byte-identical to the per-cell path with the output index
folded to a literal.
"""
function _index_at_cell_sym(
        expr::EarthSciAST.ASTExpr,
        syms::Vector{String}
    )::EarthSciAST.ASTExpr
    if expr isa OpExpr
        if _is_array_producer(expr)
            idx_args = ASTExpr[expr]
            for s in syms
                push!(idx_args, VarExpr(s))
            end
            return OpExpr("index", idx_args)
        end
        (
            expr.op == "faq" || expr.op == "makearray" ||
                expr.op == "index"
        ) && return expr
        return reconstruct(expr; args = ASTExpr[_index_at_cell_sym(a, syms) for a in expr.args])
    end
    return expr
end

# Evaluate an elementwise-over-arrays expression at one concrete cell through
# the standard build-time pipeline (_index_at_cell → _resolve_indices → _compile
# → _eval_node). STATE references are not in scope — this is for build-time
# fields (grid geometry, §6.6.5 analytic references), never for RHS terms.
# Model PARAMETERS (load-time constants) supplied via `params` (name → value)
# ARE in scope: their names bind to their resolved values, so a
# parameter-dependent coordinate expression / observed / reference resolves
# (esm-spec §6.6.5). Binding them widens only what NAMES resolve, never how a
# value is computed — determinism and byte-identical output are preserved.
#
# `t` is the SIMULATION TIME the expression is evaluated at. `_compile` maps the
# name `t` to the evaluator's dedicated time slot rather than to a parameter
# read, so a time-dependent body reads this argument and nothing else: passing
# the time as an entry of `params` does not reach it. It defaults to `0.0`,
# which grid geometry and a setup buffer never read; an `ic` right-hand side,
# which reads `t` at the start of the run (esm-spec §11.4.2), reaches it with
# `t` renamed to a scalar bound to that start (`_ic_bind_start_time`), and an
# assertion, which carries a `time` of its own (esm-spec §6.6.3), passes its
# time here. Before this
# argument existed the slot was the literal `0.0` at every call site, so a
# `t`-dependent observed asserted at any other time read ZERO and reported a
# plausible-looking wrong number (issue #406).
#
# One resolve and compile per call, so per cell: it takes a license (or a
# refusal's one-cell probe), compiler.jl.
function _eval_cellwise(
        ::_PerCellAccess, expr::EarthSciAST.ASTExpr, cell::Vector{Int};
        const_arrays::AbstractDict = _EMPTY_CONST_ARRAYS,
        params::AbstractDict = _EMPTY_PARAMS,
        t::Float64 = 0.0
    )::Float64
    cellwise = _index_at_cell(expr, cell)
    # One build memo for the resolve and the compile, and the shared nodes of
    # the compiled tree evaluated once (`_cell_memoize!`): an inlined observed
    # chain reaches the same sub-tree from many parents (a template parameter
    # written at each of its uses, an observed read by several others), and
    # walking it once per parent grows with the product of those fan-outs.
    # Both memos return the value the unshared walk computes.
    bmemo = _BuildMemo()
    vmap = Dict{String, Int}()
    resolved = _resolve_indices(
        cellwise,
        Dict{String, Tuple{Vector{Int}, Vector{Int}}}(),
        vmap, const_arrays, _EMPTY_PGATHER, bmemo
    )
    psyms = Symbol[Symbol(k) for k in keys(params)]
    pvals = Float64[Float64(params[k]) for k in keys(params)]
    p_nt = NamedTuple{Tuple(psyms)}(Tuple(pvals))
    node = _cell_memoize!(
        _compile(resolved, vmap, Set{Symbol}(psyms), bmemo), typeof(p_nt)
    )
    return _eval_node(node, Float64[], p_nt, t)
end

# ============================================================
# 5b'. Compile-once cellwise evaluator (wall2 Phase C — THE Wall #2 fix)
# ============================================================
#
# `evaluate_cellwise` materialises an array-valued observed / analytic reference at
# every output cell. The straightforward path (`_eval_cellwise`, one cell at a time)
# re-runs the ENTIRE `_index_at_cell → _resolve_indices → _compile` pipeline PER
# cell, so for a CONTRACTING aggregate over const arrays — `conc[rcv] = Σ_c
# A[c,rcv]·E[c]` — it rebuilds AND recompiles the whole N_src-wide reduction tree
# once per output cell (the output index is baked to a literal, forcing every
# `A[c,rcv]` const read to constant-fold per cell). That is O(N_cells × N_src)
# alloc-heavy recompilation on a type-unstable ASTExpr path — Wall #2.
#
# The compile-once path resolves+compiles the observed body a SINGLE time with the
# OUTPUT INDICES BOUND AS PARAMETERS (kept symbolic through the unroll — a const
# read carrying an output index lowers to a runtime `_NK_CONST_GATHER`, everything
# else folds exactly as before), then evaluates each cell by rebinding ONLY the
# output-index params and re-walking the type-stable compiled tree. The contracted
# indices still unroll to the SAME concrete values in the SAME order via the SAME
# `_foreach_aggregate_term`/`_combine_with_reducer`, so the reduction term order —
# and thus the floating-point sum — is BYTE-IDENTICAL to the per-cell path.
#
# It is a PURE OPTIMISATION: whenever anything is unsupported (a ragged /
# output-dependent contracted bound, a join/filter aggregate, a makearray keyed on
# the output index, or any resolve/compile error) `_cellwise_compile_once` returns
# `nothing` and `evaluate_cellwise` falls back to the exact per-cell loop — output
# byte-identical to today.

# A per-cell evaluator specialised on the parameter key tuple `syms` (a TYPE
# parameter, so `NamedTuple{syms}` construction is type-stable and isbits →
# stack-allocated, no heap), the fixed scalar-param count `NP`, and the output rank
# `NI`. Calling it at a cell rebinds only the `NI` output-index params; the `NP`
# scalar params are captured once in `base`.
# `t` is the simulation time the compiled body is evaluated at; see
# `_eval_cellwise` for why it cannot travel as a parameter. It is fixed per
# evaluator (one assertion reads one time), stays `Float64` so the struct is
# still isbits, and is `0.0` for every build-time caller.
struct _CellEval{syms, NP, NI}
    node::_Node
    base::NTuple{NP, Float64}
    t::Float64
end

# The output indices of one cell as an `NTuple{NI,Float64}`. `Val(NI)` makes
# `ntuple` fully-unrolled + type-stable, and `cell` is passed (not captured) so the
# read stays allocation-free.
@inline _idx_tuple(cell, ::Val{NI}) where {NI} =
    ntuple(d -> @inbounds(Float64(cell[d])), Val(NI))

@inline function (ce::_CellEval{syms, NP, NI})(cell::AbstractVector{<:Integer}) where {syms, NP, NI}
    vals = (ce.base..., _idx_tuple(cell, Val(NI))...)   # isbits tuple → stack
    p_nt = NamedTuple{syms}(vals)                        # type-stable (syms is a type param)
    return _eval_node(ce.node, _NO_STATE_U, p_nt, ce.t)
end

# Engagement counts (`_count!`, compiler.jl): how often the compile-once fast
# path engages (`_cellwise_compile_once_impl` returns a `_CellEval`,
# `:cellwise_fastpath_hit`) versus falls back to the per-cell loop (`nothing`,
# `:cellwise_fastpath_miss`). Every caller goes through this wrapper, which
# returns the impl's result unchanged.
function _cellwise_compile_once(
        expr::EarthSciAST.ASTExpr, nidx::Int,
        const_arrays::AbstractDict,
        params::AbstractDict;
        bind_syms::Union{Nothing, Vector{String}} = nothing,
        t::Float64 = 0.0
    )
    ce = _cellwise_compile_once_impl(
        expr, nidx, const_arrays, params;
        bind_syms = bind_syms, t = t
    )
    if ce === nothing
        _count!(:cellwise_fastpath_miss)
    else
        _count!(:cellwise_fastpath_hit)
    end
    return ce
end

# ---- Per-cell memo of shared sub-trees ----
# A compiled cell evaluator is a DAG: a node reached from several parents (the
# same resolved sub-tree in several unrolled terms) is walked once per parent.
# Every such node whose value depends only on the cell's parameters and `t`
# (it reads no state, no loop counter and no live buffer) is wrapped in a
# `:cellmemo` node that keeps the last (parameters, `t`) it was evaluated at
# and its value, so it is computed once per cell. The value is the walk's own
# value, so the result is unchanged bit for bit. `P` is the evaluator's
# parameter `NamedTuple` type, so an entry is stored inline and a miss
# allocates nothing. Each thread has its own entry: only the task running on a
# thread reads or writes that thread's entry, and it does not yield between
# the read and the write, so threads never share one; a task that moves to
# another thread between two cells finds an entry whose key says whether it
# holds this cell's value.
struct _CellMemo{P}
    entries::Vector{Tuple{Bool, P, Float64, Float64}}
end
function _CellMemo{P}() where {P <: NamedTuple}
    blank = (false, P(ntuple(_ -> NaN, Val(fieldcount(P)))), NaN, NaN)
    return _CellMemo{P}(fill(blank, Threads.maxthreadid()))
end

const _CELL_IMPURE_KINDS = (
    _NK_STATE, _NK_CACHED, _NK_PARAM_GATHER, _NK_LOOPVAR, _NK_STATE_GATHER,
    _NK_RECUR_GATHER, _NK_LIVE_GATHER,
)

function _cell_memoize!(root::_Node, ::Type{P}) where {P <: NamedTuple}
    refs = IdDict{_Node, Int}()
    pure = IdDict{_Node, Bool}()
    function visit(n::_Node)
        c = get(refs, n, 0)
        refs[n] = c + 1
        c == 0 || return pure[n]
        p = !(n.kind in _CELL_IMPURE_KINDS) && n.op !== :cellmemo
        for ch in n.children
            p &= visit(ch)
        end
        return pure[n] = p
    end
    visit(root)
    wrap = IdDict{_Node, _Node}()
    for (n, c) in refs
        (c >= 2 && pure[n] && !isempty(n.children)) || continue
        wrap[n] = _mknode(
            kind = _NK_OP, op = :cellmemo, payload = _CellMemo{P}(), children = _Node[n]
        )
    end
    isempty(wrap) && return root
    seen = IdDict{_Node, Nothing}()
    function rewire(n::_Node)
        haskey(seen, n) && return
        seen[n] = nothing
        for k in eachindex(n.children)
            ch = n.children[k]
            rewire(ch)
            w = get(wrap, ch, nothing)
            w === nothing || (n.children[k] = w)
        end
        return
    end
    rewire(root)
    return get(wrap, root, root)
end

@inline function _eval_cellmemo(n::_Node, u, p, t, ::Type{T})::Float64 where {T}
    m = n.payload
    if m isa _CellMemo{typeof(p)} && t isa Float64
        tid = Threads.threadid()
        if tid <= length(m.entries)
            e = @inbounds m.entries[tid]
            e[1] && e[2] === p && e[3] === t && return e[4]
            v = Float64(_eval_node(n.children[1], u, p, t, T))
            @inbounds m.entries[tid] = (true, p, t, v)
            return v
        end
    end
    return Float64(_eval_node(n.children[1], u, p, t, T))
end

# Build the compile-once evaluator for `expr` over an `nidx`-D output grid, or
# `nothing` if the fast path cannot apply (the caller falls back to per-cell). The
# resolve+compile is attempted ONCE with the output indices bound as reserved
# parameters; ANY failure (unsupported construct, unbound name, …) yields `nothing`.
function _cellwise_compile_once_impl(
        expr::EarthSciAST.ASTExpr, nidx::Int,
        const_arrays::AbstractDict,
        params::AbstractDict;
        bind_syms::Union{Nothing, Vector{String}} = nothing,
        t::Float64 = 0.0
    )
    # `nidx == 0` is a SHAPELESS (rank-0) target — one cell, no output index to
    # bind. It compiles exactly like any other: no reserved index parameters, an
    # empty symbol list for `_index_at_cell_sym` (which then makes the same
    # `index(producer)` wrap the concrete `_index_at_cell` makes for an empty
    # cell), and one evaluation. It used to be declined here, which sent every
    # scalar observed to the per-cell walk — and, once the compiler gained a
    # strict tier, to a refusal for the one shape that cannot possibly walk
    # "per cell" more than once.
    nidx >= 0 || return nothing
    # Reserved output-index parameter names (never authored by a user), one per
    # output dimension. Guard against the (impossible-in-practice) name collision.
    # `bind_syms` overrides them with caller-chosen names (wall2 Phase D reuses
    # this to compile a BLAS-precomputed wrapper, binding the aggregate's own
    # output symbols); the default is byte-identical to the Phase C behaviour.
    syms_str = bind_syms === nothing ? String["__esm_oidx_$d" for d in 1:nidx] : bind_syms
    length(syms_str) == nidx || return nothing
    for s in syms_str
        (s == "t" || haskey(params, s)) && return nothing
    end
    pkeys = collect(keys(params))
    psyms = Symbol[Symbol(k) for k in pkeys]
    for s in syms_str
        push!(psyms, Symbol(s))
    end
    bound = Set{String}(syms_str)
    node = try
        cellwise = _index_at_cell_sym(expr, syms_str)
        # One build memo for the resolve and the compile: a sub-tree shared by
        # reference (an inner reduction that does not read the enclosing
        # unrolled loop's symbol, such as the `argmin` template's minimum) resolves and
        # compiles to one node, which `_cell_memoize!` then evaluates once per
        # cell.
        bmemo = _BuildMemo()
        vmap = Dict{String, Int}()
        resolved = _resolve_indices(
            cellwise,
            Dict{String, Tuple{Vector{Int}, Vector{Int}}}(),
            vmap, const_arrays,
            _EMPTY_PGATHER, bmemo, bound
        )
        _cell_memoize!(
            _compile(resolved, vmap, Set{Symbol}(psyms), bmemo),
            NamedTuple{Tuple(psyms), NTuple{length(psyms), Float64}}
        )
    catch err
        _is_resource_error(err) && rethrow()
        return nothing   # anything unsupported → per-cell fallback
    end
    base = ntuple(i -> Float64(params[pkeys[i]]), length(pkeys))
    return _CellEval{Tuple(psyms), length(pkeys), nidx}(node, base, t)
end

# Compile a SCALAR term once with `syms` — every loop symbol it reads, output and
# contracted alike — bound as parameters, or `nothing` if it cannot be compiled.
#
# The difference from `_cellwise_compile_once` is only the `_index_at_cell_sym`
# wrap that one applies first: that one is handed a FIELD expression and has to
# index each array-producing node at the output cell, while this one is handed a
# term that is already scalar at a fixed (output, contracted) tuple. Everything
# after that is the same pipeline — `_resolve_indices` with the symbols declared
# BOUND, so a const read carrying one lowers to a runtime `_NK_CONST_GATHER`,
# then `_compile` with the symbols in the parameter set — and the result is the
# same `_CellEval`, called with a key vector holding the symbols' values in
# `syms` order.
#
# It exists for the join-gated aggregate (Phase E in inline_tests.jl), whose
# admitted (output, contracted) tuples are chosen by a build-time index and so
# cannot be enumerated symbolically. Compiling the TERM once and walking the
# gate's own key sequence keeps the whole field on one compile, which is what
# `compiler=:native` promises; `:interpreter` remains the oracle it is checked
# against.
function _scalarwise_compile_once(
        expr::EarthSciAST.ASTExpr, syms::Vector{String},
        const_arrays::AbstractDict,
        params::AbstractDict; t::Float64 = 0.0
    )
    isempty(syms) && return nothing
    length(unique(syms)) == length(syms) || return nothing
    for s in syms
        (s == "t" || haskey(params, s)) && return nothing
    end
    pkeys = collect(keys(params))
    psyms = Symbol[Symbol(k) for k in pkeys]
    for s in syms
        push!(psyms, Symbol(s))
    end
    bound = Set{String}(syms)
    node = try
        resolved = _resolve_indices(
            expr,
            Dict{String, Tuple{Vector{Int}, Vector{Int}}}(),
            Dict{String, Int}(), const_arrays,
            _EMPTY_PGATHER, nothing, bound
        )
        _compile(resolved, Dict{String, Int}(), Set{Symbol}(psyms))
    catch err
        _is_resource_error(err) && rethrow()
        return nothing
    end
    base = ntuple(i -> Float64(params[pkeys[i]]), length(pkeys))
    return _CellEval{Tuple(psyms), length(pkeys), length(syms)}(node, base, t)
end

# Function barrier: evaluate `ce` at every cell. `ce` arrives concretely typed
# (`CE` is inferred from it), so the per-cell call is a STATIC dispatch and the loop
# body allocates nothing beyond the single output vector.
function _eval_cells(ce::CE, cells::AbstractVector) where {CE <: _CellEval}
    out = Vector{Float64}(undef, length(cells))
    @inbounds for i in eachindex(cells)
        out[i] = ce(cells[i])
    end
    return out
end
