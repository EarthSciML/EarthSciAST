# ========================================================================
# ext/reactant_direct/ops.jl — the elementwise op ladder, the ⊕-fold forms
# (chain and `stablehlo.reduce`), and the host const-fold.
# ========================================================================

# ---- elementwise -------------------------------------------------------------

function _de_bin(ctx::_DECtx, f::F, a::_DEVal, b::_DEVal)::_DEVal where {F}
    L = max(a.len, b.len)
    a = _de_bcast(ctx, a, L); b = _de_bcast(ctx, b, L)
    _de_tally!(ctx, :arith)
    op = f(a.v, b.v; result = _de_ty(ctx, L), location = _de_loc())
    return _DEVal(_de_res(op), L)
end

function _de_un(ctx::_DECtx, f::F, a::_DEVal)::_DEVal where {F}
    _de_tally!(ctx, :arith)
    op = f(a.v; result = _de_ty(ctx, a.len), location = _de_loc())
    return _DEVal(_de_res(op), a.len)
end

function _de_pred(ctx::_DECtx, dir::String, a::_DEVal, b::_DEVal)
    L = max(a.len, b.len)
    a = _de_bcast(ctx, a, L); b = _de_bcast(ctx, b, L)
    _de_tally!(ctx, :compare)
    op = _hlo.compare(
        a.v, b.v; result_0 = _de_ty_i1(L),
        comparison_direction = _MLIR.API.stablehloComparisonDirectionAttrGet(
            _MLIR.IR.current_context(), dir
        ),
        location = _de_loc()
    )
    return (_de_res(op), L)
end

function _de_select(ctx::_DECtx, pred, L::Int, a::_DEVal, b::_DEVal)::_DEVal
    a = _de_bcast(ctx, a, L); b = _de_bcast(ctx, b, L)
    _de_tally!(ctx, :select)
    op = _hlo.select(pred, a.v, b.v; result = _de_ty(ctx, L), location = _de_loc())
    return _DEVal(_de_res(op), L)
end

function _de_cmp(ctx::_DECtx, dir::String, a::_DEVal, b::_DEVal)::_DEVal
    pred, L = _de_pred(ctx, dir, a, b)
    return _de_select(ctx, pred, L, _de_const(ctx, 1.0), _de_const(ctx, 0.0))
end

_de_nonzero(ctx::_DECtx, a::_DEVal) = _de_pred(ctx, "NE", a, _de_const(ctx, 0.0))

const _DE_UNARY = Dict{Symbol, Any}(
    :cos => _hlo.cosine, :sin => _hlo.sine, :exp => _hlo.exponential, :log => _hlo.log,
    :sqrt => _hlo.sqrt, :abs => _hlo.abs, :tanh => _hlo.tanh, :tan => _hlo.tan,
    :floor => _hlo.floor, :ceil => _hlo.ceil, :sign => _hlo.sign,
)
# `log10` is the one registry op with neither a StableHLO nor a CHLO opcode.
# `log(x) / ln(10)` is what the Rust lane emits for it (`UnCode::Log10`,
# simulate_array/tape/xla_emit.rs), with the SAME constant — `log(10.0)` and
# Rust's `f64::consts::LN_10` are the same Float64 — so the two compiled
# backends compute it identically and can share a conformance fixture. It is
# NOT Julia's `log10`, which is correctly rounded and can differ from the
# quotient in the last bit; that difference lives inside the `transcendental`
# tolerance class (rtol 1e-12), which is the class every fixture using it
# carries. Emitted as a divide rather than a multiply by `log10(ℯ)` because a
# division rounds once where the reciprocal rounds twice.
function _de_log10(ctx::_DECtx, a::_DEVal)::_DEVal
    return _de_bin(
        ctx, _hlo.divide, _de_un(ctx, _hlo.log, a),
        _de_const(ctx, log(10.0))
    )
end

# The transcendentals StableHLO itself does not carry. CHLO is the
# decomposition dialect the StableHLO pipeline already expands for `Ops.asin`
# and friends, so these lower to the same programs Reactant's own builders
# reach — not to a hand-rolled series here.
const _DE_UNARY_CHLO = Dict{Symbol, Any}(
    :asin => _chlo.asin, :acos => _chlo.acos, :atan => _chlo.atan,
    :asinh => _chlo.asinh, :acosh => _chlo.acosh, :atanh => _chlo.atanh,
    :sinh => _chlo.sinh, :cosh => _chlo.cosh,
)
const _DE_COMPARE = Dict{Symbol, String}(
    :< => "LT", :<= => "LE", :> => "GT", :>= => "GE", :(==) => "EQ", :!= => "NE",
)

# ---- ⊕-folds -----------------------------------------------------------------
#
# NUMERICS. The interpreter's fold is a LEFT fold seeded from the semiring's 0̄,
# in child order, and a chain of binary ops reproduces it exactly. A
# `stablehlo.reduce` does not: XLA is free to reassociate, so a long `+` fold
# can differ in the last bits. That is inside every tolerance class the
# `compiled_rhs` tier defines (`reduction` is the class such a fold belongs to),
# and it is the ONLY place this emitter deliberately leaves the interpreter's
# association order. The cut is `DirectEmitOptions.reduce_min` (default 32): below
# it the chain, at or above it one reduce, so short folds — every scalar
# contraction in a small model — stay bit-identical.

function _de_semiring_fn(ctx::_DECtx, op::Symbol)
    op === :+ && return _hlo.add
    op === :* && return _hlo.multiply
    op === :max && return _hlo.maximum
    op === :min && return _hlo.minimum
    return _de_refuse(
        ctx,
        "the semiring operator `$op`",
        "only `+`, `*`, `max` and `min` have a StableHLO reduction form here."
    )
end

_de_semiring_jl(ctx::_DECtx, op::Symbol) =
    _E._is_numeric_reducer(op) ? _E._REDUCER_INDEX[op].fn : _de_semiring_fn(ctx, op)

# One `stablehlo.reduce` over `terms`, seeded from `zbar`. The terms are
# concatenated into a `tensor<(L*n)xf64>`, reshaped to `(L, n)` — column `j` is
# term `j`, which is exactly what the concatenation laid down in column-major —
# and reduced along the term axis.
function _de_reduce_terms(
        ctx::_DECtx, op::Symbol, zbar::Float64,
        terms::Vector{_DEVal}, L::Int
    )::_DEVal
    n = length(terms)
    flat = _de_concat(ctx, _DEVal[_de_bcast(ctx, x, L) for x in terms])
    x2 = Reactant.Ops.reshape(_de_traced(flat, ctx.precision), L, n)
    init = Reactant.promote_to(TracedRNumber{ctx.precision}, ctx.precision(zbar))
    r = Reactant.Ops.reduce(x2, init, Int[2], _de_semiring_jl(ctx, op))
    _de_tally!(ctx, :reduce)
    return _de_untraced(r)
end

# The SEEDLESS left fold an n-ary operator node takes: `((c1 ⊕ c2) ⊕ c3)…`,
# the interpreter's association order (`_eval_node_op`), and never a reduce — an
# operator node has no 0̄ to seed a monoid with, and seeding `+` with `0.0`
# would turn a sum of `-0.0`s into `0.0`.
function _de_chain(ctx::_DECtx, f::F, c::Vector{_DEVal})::_DEVal where {F}
    ctx.tree_fold && return _de_balanced_fold(ctx, f, c, 1, length(c))
    r = c[1]
    for i in 2:length(c)
        r = _de_bin(ctx, f, r, c[i])
    end
    return r
end

# The SEEDED ⊕-fold a semiring contraction takes, seeded from the node's own 0̄.
function _de_fold_terms(
        ctx::_DECtx, op::Symbol, zbar::Float64,
        terms::Vector{_DEVal}
    )::_DEVal
    isempty(terms) && return _de_const(ctx, zbar)
    L = maximum(x.len for x in terms)
    if ctx.tree_fold
        f = _de_semiring_fn(ctx, op)
        return _de_balanced_fold(ctx, f, [_de_const(ctx, zbar); terms], 1, length(terms) + 1)
    end
    if length(terms) >= ctx.opts.reduce_min
        return _de_reduce_terms(ctx, op, zbar, terms, L)
    end
    f = _de_semiring_fn(ctx, op)
    s = _de_const(ctx, zbar)
    for x in terms
        s = _de_bin(ctx, f, s, x)
    end
    return s
end

# Include the seed as term one, preserving the same order on every target.
function _de_balanced_fold(ctx::_DECtx, f::F, terms, lo, hi) where {F}
    lo == hi && return terms[lo]
    mid = (lo + hi) ÷ 2
    return _de_bin(
        ctx, f, _de_balanced_fold(ctx, f, terms, lo, mid),
        _de_balanced_fold(ctx, f, terms, mid + 1, hi)
    )
end

# ---- the operator table ------------------------------------------------------
#
# `_DE_OPS` maps every operator a `_Node` can carry to its emitter
# `(ctx, op, c) -> _DEVal`, `c` being the already-emitted operands. Its keys are
# checked at load against the operator registry's shaped rows
# (`EarthSciAST._SHAPED_OP_SYMS`, the set `_compile_op` admits), so an operator
# the interpreter evaluates and this table was not taught fails at package load
# rather than at emission. The same keys are the host const-fold's operator set
# (`_de_static`). `_de_op` checks the registry arity before an entry runs, so no
# entry restates it.
#
# n-ary `+`/`*`/`max`/`min` left-fold in the interpreter's association order
# (`_eval_node_op`), so every intermediate has broadcast's shape and the same
# grouping.
#
# TWO PLACES THIS IS NOT BIT-IDENTICAL TO THE INTERPRETER, both accepted inside
# the `compiled_rhs` tolerance classes:
#
#   * `max` / `min`. Julia's `max(x, NaN)` returns NaN and propagates a NaN from
#     either side; `stablehlo.maximum`'s NaN behaviour is implementation-defined
#     and XLA:CPU may return the non-NaN operand. Only a NaN-carrying state can
#     tell them apart, and a probe that produced one would never have reached a
#     manifest (the generator refuses a non-finite anchor).
#   * `^`. Julia's `x^y` for a Float64 `y` is `pow` with Julia's own special
#     cases and its own last-bit rounding; `stablehlo.power` is XLA's. The two
#     agree to within an ulp or two on ordinary arguments, which is inside
#     `transcendental` (rtol 1e-12), not inside `algebraic`. A literal INTEGER
#     exponent is the common case and both lower it by repeated multiplication.
const _DE_OPS = Dict{Symbol, Function}()

let T = _DE_OPS
    for (op, f) in ((:+, _hlo.add), (:*, _hlo.multiply), (:max, _hlo.maximum), (:min, _hlo.minimum))
        T[op] = (ctx, _, c) -> _de_chain(ctx, f, c)
    end
    T[:-] = (ctx, _, c) -> length(c) == 1 ? _de_un(ctx, _hlo.negate, c[1]) :
        _de_bin(ctx, _hlo.subtract, c[1], c[2])
    T[:neg] = (ctx, _, c) -> _de_un(ctx, _hlo.negate, c[1])
    T[:/] = (ctx, op, c) -> _de_bin(ctx, _hlo.divide, c[1], c[2])
    for op in (:^, :pow)
        T[op] = (ctx, op, c) -> _de_bin(ctx, _hlo.power, c[1], c[2])
    end
    T[:atan2] = (ctx, op, c) -> _de_bin(ctx, _hlo.atan2, c[1], c[2])
    T[:log10] = (ctx, op, c) -> _de_log10(ctx, c[1])
    for tbl in (_DE_UNARY, _DE_UNARY_CHLO), (op, f) in tbl
        T[op] = (ctx, op, c) -> _de_un(ctx, f, c[1])
    end
    # The registry spells the two-argument arctangent both ways.
    T[:atan] = (ctx, _, c) -> length(c) == 2 ? _de_bin(ctx, _hlo.atan2, c[1], c[2]) :
        _de_un(ctx, _chlo.atan, c[1])
    for (op, dir) in _DE_COMPARE
        T[op] = (ctx, op, c) -> _de_cmp(ctx, dir, c[1], c[2])
    end
    T[:ifelse] = function (ctx, op, c)
        pred, L = _de_nonzero(ctx, c[1])
        L2 = max(L, c[2].len, c[3].len)
        if L2 != L
            pred, L = _de_nonzero(ctx, _de_bcast(ctx, c[1], L2))
        end
        return _de_select(ctx, pred, L, c[2], c[3])
    end
    T[:not] = (ctx, _, c) -> _de_cmp(ctx, "EQ", c[1], _de_const(ctx, 0.0))
    # Eager folds of 0/1 indicators, the vectorized ladders' semantics.
    for (op, f) in ((:and, _hlo.multiply), (:or, _hlo.maximum))
        T[op] = function (ctx, _, c)
            r = _de_cmp(ctx, "NE", c[1], _de_const(ctx, 0.0))
            for i in 2:length(c)
                r = _de_bin(ctx, f, r, _de_cmp(ctx, "NE", c[i], _de_const(ctx, 0.0)))
            end
            return r
        end
    end
    for r in _E._SHAPED_OPS
        r.spec.shape === :constant || continue
        v = r.spec.value::Float64
        T[r.sym] = (ctx, _, c) -> _de_const(ctx, v)
    end
    T[:Pre] = (ctx, _, c) -> c[1]
end

Set(keys(_DE_OPS)) == _E._SHAPED_OP_SYMS || error(
    "the direct emitter's operator table and the operator registry " *
        "disagree: the emitter lacks $(sort!(collect(setdiff(_E._SHAPED_OP_SYMS, keys(_DE_OPS))))) " *
        "and has no registry row for $(sort!(collect(setdiff(keys(_DE_OPS), _E._SHAPED_OP_SYMS))))"
)

_de_op(ctx::_DECtx, nd::_E._Node, c::Vector{_DEVal})::_DEVal = _de_op(ctx, nd.op, c)

function _de_op(ctx::_DECtx, op::Symbol, c::Vector{_DEVal})::_DEVal
    f = get(_DE_OPS, op, nothing)
    if f !== nothing
        ar = _E._OP_SYM_INDEX[op].arity::UnitRange{Int}
        length(c) in ar || return _de_refuse(
            ctx, "`$op` with $(length(c)) arguments",
            "`$op` takes $(_E._arity_words(ar)) (esm-spec §4.2)."
        )
        return f(ctx, op, c)::_DEVal
    end
    # Not `unevaluable_operator` (esm-spec §9.6.6): `_compile_op` refuses an op
    # outside the evaluable core while the evaluator is BUILT, and the load-time
    # check above keeps this table equal to what it admits. What reaches here is
    # an IR invariant break (an operator the build should have refused).
    return _de_refuse(
        ctx, "the operator `$op`",
        "it is not in the direct emitter's operator table (`_DE_OPS`, " *
            "ext/reactant_direct/ops.jl), which matches the operators the " *
            "tree walk admits."
    )
end

# The host const-fold evaluates an operator through `_scalar_op` exactly when
# the emitter has an arm for it.
_de_foldable_op(op::Symbol) = haskey(_DE_OPS, op)

# ---- host const-fold ---------------------------------------------------------
#
# A subtree whose leaves are all host data — literals, enclosing loop counters,
# frozen const-gather arrays, and (when `p` is a host NamedTuple) parameters —
# is EVALUATED HERE and emitted as one interned constant instead of as a
# subgraph. This is what keeps a contraction loop's emission from being O(range)
# in EMITTED OPS: a `Σ_k` whose body is index arithmetic over frozen data folds
# to `range` host multiply-adds and, after interning, a handful of constants.
#
# It is also strictly MORE faithful than emitting the ops would be: the value is
# computed in Float64 by `_scalar_op`, which the same generator as `_eval_node_op`
# builds (`_op_ladder`), so a folded subtree agrees with the interpreter bit for
# bit, where `stablehlo.power` and friends would not.
#
# `_de_static` is memoized per node (structural, so a loop body asked once per
# `k` pays the walk once); `_de_hostval` is re-evaluated per `k`, because a
# `_NK_LOOPVAR` leaf reads the live counter.

function _de_static(ctx::_DECtx, nd::_E._Node)::Bool
    hit = get(ctx.static, nd, nothing)
    hit === nothing || return hit
    r = _de_static_uncached(ctx, nd)
    ctx.static[nd] = r
    return r
end

function _de_static_uncached(ctx::_DECtx, nd::_E._Node)::Bool
    k = nd.kind
    if k === _E._NK_LITERAL || k === _E._NK_LOOPVAR
        return true
    elseif k === _E._NK_PARAM
        # A parameter is host data only when `p` is a host NamedTuple holding a
        # plain `Real` there; a traced parameter is a program INPUT and must stay
        # one (that is what makes a parameter override recompile-free).
        p = ctx.p
        p isa NamedTuple || return false
        hasproperty(p, nd.sym) || return false
        return getfield(p, nd.sym) isa Real
    elseif k === _E._NK_CONST_GATHER
        return all(ch -> _de_static(ctx, ch), nd.children)
    elseif k === _E._NK_CONTRACTION
        return all(ch -> _de_static(ctx, ch), nd.children)
    elseif k === _E._NK_CONTRACTION_LOOP
        return _de_static(ctx, nd.children[1])
    elseif k === _E._NK_OP
        _de_foldable_op(nd.op) || return false
        return all(ch -> _de_static(ctx, ch), nd.children)
    end
    return false
end

function _de_hostval(ctx::_DECtx, nd::_E._Node)::Float64
    k = nd.kind
    if k === _E._NK_LITERAL
        return nd.literal
    elseif k === _E._NK_LOOPVAR
        return Float64(_de_counter(ctx, nd.payload::Base.RefValue{Int}))
    elseif k === _E._NK_PARAM
        return Float64(getfield(ctx.p, nd.sym)::Real)
    elseif k === _E._NK_CONST_GATHER
        cg = nd.payload::_E._ConstGatherArray
        off = _E._const_gather_offset(
            cg, length(nd.children), d -> _de_index_int(ctx, nd.children[d])
        )
        return Float64(cg.flat[off])
    elseif k === _E._NK_CONTRACTION
        terms = Float64[_de_hostval(ctx, ch) for ch in nd.children]
        return _de_host_fold(ctx, nd.op, nd.literal, terms)
    elseif k === _E._NK_CONTRACTION_LOOP
        spec = nd.payload::_E._ContractLoop
        body = nd.children[1]
        terms = Float64[]
        for kk in spec.lo:spec.step:spec.hi
            _de_set_counter!(ctx, spec.ref, kk)
            push!(terms, _de_hostval(ctx, body))
        end
        return _de_host_fold(ctx, nd.op, nd.literal, terms)
    end
    # `_NK_OP`: the host ladder, generated as the interpreter's (`_op_ladder`),
    # so a folded subtree is bit-identical to what `f!` computes for it.
    c = Any[_de_hostval(ctx, ch) for ch in nd.children]
    return _de_host_op(ctx, nd.op, c)
end

# The host twins of `_de_fold_terms` and `_de_chain`. Under `tree_fold` they
# group as `_de_balanced_fold` does, so a subtree folded on the host and the
# same subtree emitted (where another target cannot fold it) round alike.
function _de_host_fold(ctx::_DECtx, op::Symbol, zbar::Float64, terms::Vector{Float64})::Float64
    f = _de_semiring_jl(ctx, op)
    ctx.tree_fold && return _de_host_balanced(f, [zbar; terms], 1, length(terms) + 1)
    return foldl(f, terms; init = zbar)
end

function _de_host_op(ctx::_DECtx, op::Symbol, c::Vector{Any})::Float64
    if ctx.tree_fold && length(c) > 2 && op in (:+, :*, :max, :min)
        return _de_host_balanced((a, b) -> _E._scalar_op(op, Any[a, b]), c, 1, length(c))
    end
    return _E._scalar_op(op, c)
end

function _de_host_balanced(f::F, xs, lo, hi) where {F}
    lo == hi && return xs[lo]
    mid = (lo + hi) ÷ 2
    return f(_de_host_balanced(f, xs, lo, mid), _de_host_balanced(f, xs, mid + 1, hi))
end

const _DE_FOLD_KINDS = (_E._NK_OP, _E._NK_CONTRACTION, _E._NK_CONTRACTION_LOOP)

# Fold if we can; `nothing` if the subtree is not host data.
function _de_try_fold(ctx::_DECtx, nd::_E._Node)::Union{Nothing, _DEVal}
    nd.kind === _E._NK_LITERAL && return nothing   # already one constant
    # A Float32 fragment evaluates in Float32, which a Float64 host fold does not.
    (ctx.precision !== Float64 && nd.kind in _DE_FOLD_KINDS) && return nothing
    _de_static(ctx, nd) || return nothing
    _de_tally!(ctx, :const_folded)
    return _de_const(ctx, _de_hostval(ctx, nd))
end

# Host integer evaluation of a gather subscript (loop counters + literals),
# reusing the emitter's own resolver — no state can appear in a subscript.
_de_index_int(ctx::_DECtx, nd::_E._Node) = _E._index_int(nd, r -> _de_counter(ctx, r))
