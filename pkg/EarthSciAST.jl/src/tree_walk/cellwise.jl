# tree_walk/cellwise.jl — cell-wise evaluation: an expression indexed at a cell, the
# per-cell evaluator, and the compile-once cell evaluators with their memo.

# `expr` read at one cell given by `subscripts`: every array-PRODUCING node
# (`makearray`, or `faq` with non-empty `output_idx`) is wrapped in
# `index(node, subscripts…)`, as is `transpose`. Elementwise operators are
# descended, and scalar leaves (literals, scalar names, `index` gathers, scalar
# reductions) pass through. The concrete-cell dual of `_index_array_leaves`
# (loop-name form).
function _index_at(expr::ASTExpr, subscripts::Vector{ASTExpr})::ASTExpr
    expr isa OpExpr || return expr
    (_is_array_producer(expr) || (expr.op == "transpose" && !isempty(subscripts))) &&
        return OpExpr("index", ASTExpr[expr, subscripts...])
    _is_self_indexed_op(expr.op) && return expr
    return reconstruct(expr; args = ASTExpr[_index_at(a, subscripts) for a in expr.args])
end

# `_index_at` at a concrete 1-based cell.
_index_at_cell(expr::ASTExpr, idxs::Vector{Int}) =
    _index_at(expr, ASTExpr[IntExpr(Int64(k)) for k in idxs])

# `_index_at` at a cell named by the symbols `syms`, which stay symbolic through
# `_resolve_indices` and the unroll and are bound per cell as parameters. The
# reduction terms come out in the order the concrete cell gives them, so the
# floating-point result is the concrete cell's.
_index_at_cell_sym(expr::ASTExpr, syms::Vector{String}) =
    _index_at(expr, ASTExpr[VarExpr(s) for s in syms])

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
# time here.
#
# One resolve and compile per call, so per cell: it takes a license (or a
# refusal's one-cell probe), compiler.jl. Errors propagate.
function _eval_cellwise(
        ::_PerCellAccess, expr::EarthSciAST.ASTExpr, cell::Vector{Int};
        const_arrays::AbstractDict = _EMPTY_CONST_ARRAYS,
        params::AbstractDict = _EMPTY_PARAMS,
        t::Float64 = 0.0
    )::Float64
    psyms = Symbol[Symbol(k) for k in keys(params)]
    node = _compile_cell_body(_index_at_cell(expr, cell), String[], const_arrays, psyms)
    p_nt = NamedTuple{Tuple(psyms)}(Tuple(Float64[Float64(params[k]) for k in keys(params)]))
    return _eval_node(node, Float64[], p_nt, t)
end

# Resolve and compile a cell body once, the names `bound` declared bound (so a
# const read carrying one lowers to a run-time `_NK_CONST_GATHER`) and `psyms`
# the parameter names, in order. One build memo serves the resolve and the
# compile, and the compiled tree's shared nodes are evaluated once per cell
# (`_cell_memoize!`): an inlined observed chain reaches the same sub-tree from
# many parents, and walking it once per parent grows with the product of
# those fan-outs. Both memos return the value the unshared walk computes.
function _compile_cell_body(
        expr::ASTExpr, bound::Vector{String}, const_arrays::AbstractDict,
        psyms::Vector{Symbol}
    )::_Node
    bmemo = _BuildMemo()
    vmap = Dict{String, Int}()
    resolved = _resolve_indices(
        expr, Dict{String, Tuple{Vector{Int}, Vector{Int}}}(),
        vmap, const_arrays, _EMPTY_PGATHER, bmemo, Set{String}(bound)
    )
    return _cell_memoize!(
        _compile(resolved, vmap, Set{Symbol}(psyms), bmemo),
        NamedTuple{Tuple(psyms), NTuple{length(psyms), Float64}}
    )
end

# ---- Compile-once cell evaluation ----
# `_eval_cellwise` resolves and compiles the whole body at every cell, so a
# contracting aggregate over const arrays (`conc[rcv] = Σ_c A[c,rcv]·E[c]`)
# rebuilds its whole reduction per output cell. The compile-once evaluator
# (`_cell_evaluator`) resolves and compiles the body once with the output
# indices bound as parameters (a const read carrying one lowers to a run-time
# `_NK_CONST_GATHER`, everything else folds) and evaluates each cell
# by rebinding them. The contracted indices unroll to the same values in the
# same order, so every sum is the per-cell path's, bit for bit. Whatever it
# cannot compile, it declines (`nothing`), and the caller evaluates per cell.

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
    length(cell) == NI || _cell_rank_mismatch(length(cell), NI)
    vals = (ce.base..., _idx_tuple(cell, Val(NI))...)   # isbits tuple → stack
    p_nt = NamedTuple{syms}(vals)                        # type-stable (syms is a type param)
    return _eval_node(ce.node, _NO_STATE_U, p_nt, ce.t)
end

@noinline _cell_rank_mismatch(n::Int, ni::Int) = throw(
    TreeWalkError(
        "E_TREEWALK_UNSUPPORTED_EQUATION",
        "cell evaluator: cell rank $n ≠ output rank $ni"
    )
)

# The compile-once evaluator of a field `expr` over an `nidx`-D output grid
# (`nidx == 0` is a shapeless target: one cell, nothing to bind), or `nothing`
# when it cannot be compiled and the caller evaluates per cell. The output
# indices are bound under reserved names, or `bind_syms` when given (a
# precomputed contraction binds its own output symbols). Counts each answer
# (`:cellwise_fastpath_hit` / `:cellwise_fastpath_miss`, `_count!` in
# compiler.jl).
function _cellwise_compile_once(
        expr::EarthSciAST.ASTExpr, nidx::Int,
        const_arrays::AbstractDict,
        params::AbstractDict;
        bind_syms::Union{Nothing, Vector{String}} = nothing,
        t::Float64 = 0.0
    )
    syms = bind_syms === nothing ? _cell_oidx_syms(nidx) : bind_syms
    ce = nidx >= 0 && length(syms) == nidx ?
        _cell_evaluator(expr, syms, const_arrays, params; index_outputs = true, t = t) :
        nothing
    _count!(ce === nothing ? :cellwise_fastpath_miss : :cellwise_fastpath_hit)
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

# The reserved names (no document can author them) an `n`-D output cell's
# indices are bound under.
_cell_oidx_syms(n::Int) = String["__esm_oidx_$d" for d in 1:n]

# Compile `expr` once with the names `syms` bound as parameters after those of
# `params`, and return the `_CellEval` that evaluates it at a cell (the values
# of `syms`, in order), or `nothing` when it cannot be compiled or a name of
# `syms` is repeated, is `t` or is a parameter. With `index_outputs`, `expr` is
# a field and each array-producing node is first read at the cell
# (`_index_at_cell_sym`); without it, `expr` is already scalar at the bound
# tuple, as a join-gated aggregate's term is, whose admitted tuples come from a
# build-time index and are walked in that order.
function _cell_evaluator(
        expr::ASTExpr, syms::Vector{String}, const_arrays::AbstractDict,
        params::AbstractDict; index_outputs::Bool, t::Float64 = 0.0
    )
    allunique(syms) || return nothing
    for s in syms
        (s == "t" || haskey(params, s)) && return nothing
    end
    pkeys = collect(keys(params))
    psyms = Symbol[Symbol(k) for k in pkeys]
    append!(psyms, Symbol.(syms))
    node = try
        body = index_outputs ? _index_at_cell_sym(expr, syms) : expr
        _compile_cell_body(body, syms, const_arrays, psyms)
    catch err
        _is_resource_error(err) && rethrow()
        return nothing
    end
    base = ntuple(i -> Float64(params[pkeys[i]]), length(pkeys))
    return _CellEval{Tuple(psyms), length(pkeys), length(syms)}(node, base, t)
end

# A scalar term compiled once with every loop symbol it reads bound
# (`_cell_evaluator` without the output read), or `nothing`.
_scalarwise_compile_once(
    expr::ASTExpr, syms::Vector{String}, const_arrays::AbstractDict,
    params::AbstractDict; t::Float64 = 0.0
) = isempty(syms) ? nothing :
    _cell_evaluator(expr, syms, const_arrays, params; index_outputs = false, t = t)

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
