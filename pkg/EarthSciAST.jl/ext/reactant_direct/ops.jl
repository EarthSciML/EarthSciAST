# ========================================================================
# ext/reactant_direct/ops.jl — the elementwise op ladder, the ⊕-fold forms
# (chain and `stablehlo.reduce`), and the host const-fold.
# ========================================================================

# ---- elementwise -------------------------------------------------------------

function _de_bin(ctx::_DECtx, f::F, a::_DEVal, b::_DEVal)::_DEVal where {F}
    L = max(a.len, b.len)
    a = _de_bcast(ctx, a, L); b = _de_bcast(ctx, b, L)
    _de_tally!(ctx, :arith)
    op = f(a.v, b.v; result=_de_ty(L), location=_de_loc())
    return _DEVal(_de_res(op), L)
end

function _de_un(ctx::_DECtx, f::F, a::_DEVal)::_DEVal where {F}
    _de_tally!(ctx, :arith)
    op = f(a.v; result=_de_ty(a.len), location=_de_loc())
    return _DEVal(_de_res(op), a.len)
end

function _de_pred(ctx::_DECtx, dir::String, a::_DEVal, b::_DEVal)
    L = max(a.len, b.len)
    a = _de_bcast(ctx, a, L); b = _de_bcast(ctx, b, L)
    _de_tally!(ctx, :compare)
    op = _hlo.compare(a.v, b.v; result_0=_de_ty_i1(L),
                      comparison_direction=_MLIR.API.stablehloComparisonDirectionAttrGet(
                          _MLIR.IR.current_context(), dir),
                      location=_de_loc())
    return (_de_res(op), L)
end

function _de_select(ctx::_DECtx, pred, L::Int, a::_DEVal, b::_DEVal)::_DEVal
    a = _de_bcast(ctx, a, L); b = _de_bcast(ctx, b, L)
    _de_tally!(ctx, :select)
    op = _hlo.select(pred, a.v, b.v; result=_de_ty(L), location=_de_loc())
    return _DEVal(_de_res(op), L)
end

function _de_cmp(ctx::_DECtx, dir::String, a::_DEVal, b::_DEVal)::_DEVal
    pred, L = _de_pred(ctx, dir, a, b)
    return _de_select(ctx, pred, L, _de_const(ctx, 1.0), _de_const(ctx, 0.0))
end

_de_nonzero(ctx::_DECtx, a::_DEVal) = _de_pred(ctx, "NE", a, _de_const(ctx, 0.0))

const _DE_UNARY = Dict{Symbol,Any}(
    :cos => _hlo.cosine, :sin => _hlo.sine, :exp => _hlo.exponential, :log => _hlo.log,
    :sqrt => _hlo.sqrt, :abs => _hlo.abs, :tanh => _hlo.tanh, :tan => _hlo.tan,
    :expm1 => _hlo.exponential_minus_one, :log1p => _hlo.log_plus_one,
    :floor => _hlo.floor, :ceil => _hlo.ceil, :sign => _hlo.sign, :cbrt => _hlo.cbrt,
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
    return _de_bin(ctx, _hlo.divide, _de_un(ctx, _hlo.log, a),
                   _de_const(ctx, log(10.0)))
end

# The transcendentals StableHLO itself does not carry. CHLO is the
# decomposition dialect the StableHLO pipeline already expands for `Ops.asin`
# and friends, so these lower to the same programs Reactant's own builders
# reach — not to a hand-rolled series here.
const _DE_UNARY_CHLO = Dict{Symbol,Any}(
    :asin => _chlo.asin, :acos => _chlo.acos, :atan => _chlo.atan,
    :asinh => _chlo.asinh, :acosh => _chlo.acosh, :atanh => _chlo.atanh,
    :sinh => _chlo.sinh, :cosh => _chlo.cosh, :erf => _chlo.erf,
)
const _DE_COMPARE = Dict{Symbol,String}(
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
# association order. The cut is `ESM_DIRECT_EMIT_REDUCE_MIN` (default 32): below
# it the chain, at or above it one reduce, so short folds — every scalar
# contraction in a small model — stay bit-identical.

function _de_semiring_fn(op::Symbol)
    op === :+ && return _hlo.add
    op === :* && return _hlo.multiply
    op === :max && return _hlo.maximum
    op === :min && return _hlo.minimum
    _de_refuse("the semiring operator `$op`",
        "only `+`, `*`, `max` and `min` have a StableHLO reduction form here.")
end

_de_semiring_jl(op::Symbol) =
    op === :+ ? (+) : op === :* ? (*) : op === :max ? max :
    op === :min ? min : _de_semiring_fn(op)

# One `stablehlo.reduce` over `terms`, seeded from `zbar`. The terms are
# concatenated into a `tensor<(L*n)xf64>`, reshaped to `(L, n)` — column `j` is
# term `j`, which is exactly what the concatenation laid down in column-major —
# and reduced along the term axis.
function _de_reduce_terms(ctx::_DECtx, op::Symbol, zbar::Float64,
                          terms::Vector{_DEVal}, L::Int)::_DEVal
    n = length(terms)
    flat = _de_concat(ctx, _DEVal[_de_bcast(ctx, x, L) for x in terms])
    x2 = Reactant.Ops.reshape(_de_traced(flat), L, n)
    init = Reactant.promote_to(TracedRNumber{Float64}, zbar)
    r = Reactant.Ops.reduce(x2, init, Int[2], _de_semiring_jl(op))
    _de_tally!(ctx, :reduce)
    return _de_untraced(r)
end

# The SEEDLESS left fold an n-ary operator node takes: `((c1 ⊕ c2) ⊕ c3)…`,
# the interpreter's association order (`_eval_node_op`), and never a reduce — an
# operator node has no 0̄ to seed a monoid with, and seeding `+` with `0.0`
# would turn a sum of `-0.0`s into `0.0`.
function _de_chain(ctx::_DECtx, f::F, c::Vector{_DEVal})::_DEVal where {F}
    r = c[1]
    for i in 2:length(c)
        r = _de_bin(ctx, f, r, c[i])
    end
    return r
end

# The SEEDED ⊕-fold a semiring contraction takes, seeded from the node's own 0̄.
function _de_fold_terms(ctx::_DECtx, op::Symbol, zbar::Float64,
                        terms::Vector{_DEVal})::_DEVal
    isempty(terms) && return _de_const(ctx, zbar)
    L = maximum(x.len for x in terms)
    if length(terms) >= ctx.reduce_min
        return _de_reduce_terms(ctx, op, zbar, terms, L)
    end
    f = _de_semiring_fn(op)
    s = _de_const(ctx, zbar)
    for x in terms
        s = _de_bin(ctx, f, s, x)
    end
    return s
end

# ---- the op ladder -----------------------------------------------------------
#
# Left-folds n-ary `+`/`*` in the interpreter's association order
# (`_eval_node_op`), so every intermediate has broadcast's shape and the same
# grouping.
#
# TWO PLACES THIS IS NOT BIT-IDENTICAL TO THE INTERPRETER, both accepted inside
# the `compiled_rhs` tolerance classes and both recorded here rather than in a
# commit message:
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
_de_op(ctx::_DECtx, nd::_E._Node, c::Vector{_DEVal})::_DEVal = _de_op(ctx, nd.op, c)

function _de_op(ctx::_DECtx, op::Symbol, c::Vector{_DEVal})::_DEVal
    n = length(c)
    if op === :+
        return _de_chain(ctx, _hlo.add, c)
    elseif op === :*
        return _de_chain(ctx, _hlo.multiply, c)
    elseif op === :-
        n == 1 && return _de_un(ctx, _hlo.negate, c[1])
        n == 2 && return _de_bin(ctx, _hlo.subtract, c[1], c[2])
        _de_refuse("`-` with $n arguments", "the IR's `-` is unary or binary.")
    elseif op === :neg
        return _de_un(ctx, _hlo.negate, c[1])
    elseif op === :/
        n == 2 || _de_refuse("`/` with $n arguments", "division is binary.")
        return _de_bin(ctx, _hlo.divide, c[1], c[2])
    elseif op === :^ || op === :pow
        n == 2 || _de_refuse("`^` with $n arguments", "exponentiation is binary.")
        return _de_bin(ctx, _hlo.power, c[1], c[2])
    elseif op === :max
        return _de_chain(ctx, _hlo.maximum, c)
    elseif op === :min
        return _de_chain(ctx, _hlo.minimum, c)
    elseif op === :atan2
        n == 2 || _de_refuse("`atan2` with $n arguments", "`atan2` is binary.")
        return _de_bin(ctx, _hlo.atan2, c[1], c[2])
    elseif op === :atan && n == 2
        # The registry spells the two-argument form both ways.
        return _de_bin(ctx, _hlo.atan2, c[1], c[2])
    elseif op === :log10
        n == 1 || _de_refuse("unary `log10` with $n arguments",
                             "`log10` takes exactly one argument.")
        return _de_log10(ctx, c[1])
    elseif haskey(_DE_UNARY, op)
        n == 1 || _de_refuse("unary `$op` with $n arguments",
                             "`$op` takes exactly one argument.")
        return _de_un(ctx, _DE_UNARY[op], c[1])
    elseif haskey(_DE_UNARY_CHLO, op)
        n == 1 || _de_refuse("unary `$op` with $n arguments",
                             "`$op` takes exactly one argument.")
        return _de_un(ctx, _DE_UNARY_CHLO[op], c[1])
    elseif haskey(_DE_COMPARE, op)
        n == 2 || _de_refuse("comparison `$op` with $n arguments",
                             "a comparison is binary.")
        return _de_cmp(ctx, _DE_COMPARE[op], c[1], c[2])
    elseif op === :ifelse
        n == 3 || _de_refuse("`ifelse` with $n arguments", "`ifelse` takes three.")
        pred, L = _de_nonzero(ctx, c[1])
        L2 = max(L, c[2].len, c[3].len)
        if L2 != L
            pred, L = _de_nonzero(ctx, _de_bcast(ctx, c[1], L2))
        end
        return _de_select(ctx, pred, L, c[2], c[3])
    elseif op === :not
        return _de_cmp(ctx, "EQ", c[1], _de_const(ctx, 0.0))
    elseif op === :and
        # eager fold of 0/1 indicators — the vectorized ladders' semantics
        r = _de_cmp(ctx, "NE", c[1], _de_const(ctx, 0.0))
        for i in 2:n
            r = _de_bin(ctx, _hlo.multiply, r, _de_cmp(ctx, "NE", c[i], _de_const(ctx, 0.0)))
        end
        return r
    elseif op === :or
        r = _de_cmp(ctx, "NE", c[1], _de_const(ctx, 0.0))
        for i in 2:n
            r = _de_bin(ctx, _hlo.maximum, r, _de_cmp(ctx, "NE", c[i], _de_const(ctx, 0.0)))
        end
        return r
    elseif op === :pi || op === :π
        return _de_const(ctx, Float64(pi))
    elseif op === :e
        return _de_const(ctx, Float64(ℯ))
    elseif op === :Pre
        return c[1]
    end
    _de_refuse("the operator `$op`",
        "it is not in the direct-emission op ladder. Add it to `_de_op` " *
        "(ext/reactant_direct/ops.jl) with the StableHLO op that matches the " *
        "interpreter's arm for it (`_eval_node_op`), or lower it away before " *
        "the backend.")
end

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
# computed in Float64 by `_scalar_op`, whose arm order is pinned against
# `_eval_node_op` by test/scalar_ops_test.jl, so a folded subtree agrees with the
# interpreter bit for bit, where `stablehlo.power` and friends would not.
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
        # `:fn` is deliberately excluded: a closed function's host core is not
        # this file's contract to reproduce, and the interp lowering below is
        # already O(1).
        nd.op === :fn && return false
        (haskey(_DE_UNARY, nd.op) || haskey(_DE_COMPARE, nd.op) ||
         haskey(_DE_UNARY_CHLO, nd.op) ||
         nd.op in (:+, :*, :-, :neg, :/, :^, :pow, :max, :min, :ifelse, :not,
                   :and, :or, :pi, :π, :e, :Pre, :atan, :atan2, :log10)) || return false
        return all(ch -> _de_static(ctx, ch), nd.children)
    end
    return false
end

function _de_hostval(ctx::_DECtx, nd::_E._Node)::Float64
    k = nd.kind
    if k === _E._NK_LITERAL
        return nd.literal
    elseif k === _E._NK_LOOPVAR
        return Float64((nd.payload::Base.RefValue{Int})[])
    elseif k === _E._NK_PARAM
        return Float64(getfield(ctx.p, nd.sym)::Real)
    elseif k === _E._NK_CONST_GATHER
        cg = nd.payload::_E._ConstGatherArray
        off = 1
        for d in eachindex(nd.children)
            off += (_de_index_int(nd.children[d]) - 1) * cg.strides[d]
        end
        (1 <= off <= cg.len) ||
            _de_refuse("a const gather out of range",
                "the folded offset $off is outside the frozen array " *
                "(length $(cg.len)).")
        return Float64(cg.flat[off])
    elseif k === _E._NK_CONTRACTION
        s = nd.literal
        f = _de_semiring_jl(nd.op)
        for ch in nd.children
            s = f(s, _de_hostval(ctx, ch))
        end
        return s
    elseif k === _E._NK_CONTRACTION_LOOP
        spec = nd.payload::_E._ContractLoop
        s = nd.literal
        f = _de_semiring_jl(nd.op)
        body = nd.children[1]
        for kk in spec.lo:spec.step:spec.hi
            spec.ref[] = kk
            s = f(s, _de_hostval(ctx, body))
        end
        return s
    end
    # `_NK_OP`: the shared ladder, at Float64. Its arms are pinned against the
    # interpreter's (`_eval_node_op`) by test/scalar_ops_test.jl, so a folded
    # subtree is bit-identical to what `f!` computes for it.
    c = Any[_de_hostval(ctx, ch) for ch in nd.children]
    return Float64(_E._scalar_op(nd.op, c, Float64))
end

# Fold if we can; `nothing` if the subtree is not host data.
function _de_try_fold(ctx::_DECtx, nd::_E._Node)::Union{Nothing,_DEVal}
    nd.kind === _E._NK_LITERAL && return nothing   # already one constant
    _de_static(ctx, nd) || return nothing
    _de_tally!(ctx, :const_folded)
    return _de_const(ctx, _de_hostval(ctx, nd))
end

# Host integer evaluation of a gather subscript (loop counters + literals),
# reusing the emitter's own resolver — no state can appear in a subscript.
_de_index_int(nd::_E._Node) = _E._index_int(nd)
