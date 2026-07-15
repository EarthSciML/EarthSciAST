# ========================================================================
# tree_walk/oop.jl — part of the tree-walk evaluator.
# Included by src/tree_walk.jl; see that file for the full layout and
# include order. Section 4d: the OUT-OF-PLACE RHS emitter — a second
# emitter over the SAME compiled IR (`_Node` + `_VecNode`/`_VecKernel`)
# that `_make_rhs` lowers to `f!(du, u, p, t)`.
# ========================================================================

# ============================================================
# 4d. Out-of-place RHS: `f(u, p, t) -> du`
# ============================================================
#
# WHY A SECOND EMITTER — and what it is NOT for.
# ----------------------------------------------
# It is NOT the AD path. `f!` (vectorize.jl) is eltype-generic in its own right: it
# is zero-alloc AND bit-identical at Float64, and it differentiates under ForwardDiff
# over the state or the parameters. Differentiate with `f!`. Solve with `f!`. If you
# are reaching for this file to get a derivative on the CPU, you are in the wrong file.
#
# THIS EMITTER EXISTS TO BE TRACED — by XLA/Reactant today (ext/EarthSciASTReactantExt.jl),
# by any device backend tomorrow. What makes it traceable is not the out-of-place
# SIGNATURE, which is incidental, but two properties `f!` cannot have without ceasing
# to be `f!`:
#
#   1. NO CAPTURED HOST BUFFERS. `f!` writes into a preallocated `Vector{Float64}` per
#      `_VecNode` (`n.buf`), created at build time. A traced value cannot be written
#      into concrete host memory. Nor does `f!`'s eltype-generic alt-buffer rescue it:
#      under tracing the value type is `TracedRNumber{Float64}`, so the lazy buffer
#      would be a HOST `Vector{TracedRNumber}` — a Julia array of traced scalars, which
#      is not a traced array. (And XLA assigns its own buffers anyway, so ours would be
#      redundant even if they worked.)
#   2. NO PER-LANE SCALAR LOOPS. `f!` still walks lanes one at a time in several arms —
#      the gather (`b[j] = u[s[j]]`), the pgather, the `du` scatter, the interp kernels.
#      XLA REJECTS scalar indexing of a traced array outright. Every one of those is a
#      whole-array op here (`u[slots]`, `du[out] = res`). That de-scalarization is the
#      real content of this file.
#
# Fix both in `f!` and you would have rewritten this walker. They converge; that is why
# there are two, and why neither subsumes the other.
#
# Its second, quieter job: it is an INDEPENDENT implementation of the same IR, so it is
# the oracle the in-place tests use to prove `f!` still computes the same Float64 answers
# (tree_walk_iip_generic_test.jl). Two emitters that must agree bit-for-bit keep each
# other honest.
#
# `build_evaluator(model; form = :oop)` returns `f(u, p, t) -> du` in the `f!` slot of
# the usual `(f, u0, p, tspan, var_map)` tuple; SciML dispatches `ODEProblem` on RHS
# arity, so it drops straight in.
#
# The value type is derived from `u`, `p` AND `t` together — see `_oop_value_type` —
# never from `eltype(u)` alone, which would throw `Float64(::Dual)` the moment anyone
# differentiated with respect to a PARAMETER (there `u` stays `Float64` and only the
# parameter values go `Dual`).
#
# ENZYME NEEDS ONE FLAG, and it is worth knowing why before trying to remove it:
#
#     Enzyme.API.strictAliasing!(false)     # once, before any autodiff call
#
# Reverse mode then produces gradients matching ForwardDiff to ~1e-16. Without it,
# Enzyme's type analysis rejects the RHS — not because of anything this file does,
# but because the walk LOADS FIELDS FROM `_VecNode`, and that struct is heterogeneous
# by design: one `payload::Any` slot serving ten node kinds, `fnargs::Vector{Any}` for
# the boxed closed-function path, and `altbuf::RefValue{Any}` for `f!`'s lazy per-eltype
# scratch. Enzyme cannot type-analyze loads out of such an object and bails on the whole
# method — including, note, loads of the CONCRETE fields (`vals`, `slots`), so simply
# routing around the `Any` payload does NOT help. I tried that; it does not work. Nothing
# short of a payload-free IR will.
#
# Which is the real fix, and it is a separate piece of work: lower the compiled IR ONCE
# at build time into a concretely-typed tree with no `Any` anywhere. That same lowering
# is what an XLA/Reactant backend wants regardless, so the two motivations converge.
# ForwardDiff, which analyzes types the way Julia does, is unaffected and needs nothing.
#
# THE ONE LADDER. `_oop_op` evaluates an op over ALREADY-EVALUATED children using
# broadcast (`.+`, `sin.`, …) throughout. Broadcasting two scalars yields a scalar,
# so the SAME ladder serves the scalar walker (`_Node`, children all `T`) and the
# array walker (`_VecNode`, children a mix of `T` and `Vector{T}`) — no third arm
# set to drift out of sync with `_eval_node_op` and `_eval_vec_op`. The op-coverage
# test asserts this ladder accepts every op those two accept.
#
# PERFORMANCE SHAPE (measured, 1-D reaction–diffusion, Float64). This form costs about
# 2.7–4× the in-place `f!` and allocates ~12 MB per call at N = 100k. That cost is not
# the tree walk — which is O(#nodes), not O(#cells), so its dynamic dispatch amortizes
# away over the cell axis — it is the DEFINING cost of being out of place: one fresh
# temporary per AST node instead of `f!`'s preallocated `buf`s, and the GC pressure that
# comes with it. It is not a bug to be optimized away; it is what you trade the buffers
# for. (An affine-slice fast path for the gathers was tried and measured worthless, so
# it is not here.)
#
# So do NOT reach for this form to go faster, and do not reach for it to differentiate
# on the CPU either — `f!` does both better. Reach for it when the target is a tracer or
# a device, where the buffers this form lacks are exactly the thing standing in the way.

# ---- Value type -------------------------------------------------------------
#
# The RHS's value type is fixed by the three runtime inputs: the state, the
# parameter values, and time. Literals, const arrays, and captured forcing buffers
# are `Float64` DATA — never differentiated — so they promote into `T` rather than
# constraining it.
#
# Deriving `T` from all three (not just `eltype(u)`) is load-bearing. Under
# ForwardDiff-over-parameters `u` is a plain `Vector{Float64}` and only the `p`
# values are `Dual`; a `du` sized from `eltype(u)` would be `Vector{Float64}` and
# the first store would throw `Float64(::Dual)`.
@inline _oop_promote_vals(::Tuple{}) = Bool   # identity for `promote_type`
@inline _oop_promote_vals(x::Tuple) =
    promote_type(typeof(x[1]), _oop_promote_vals(Base.tail(x)))

@inline _oop_value_type(u, p::NamedTuple, t) =
    promote_type(eltype(u), _oop_promote_vals(values(p)), typeof(t))

# A parameter-free model carries SciMLBase's `nothing` sentinel instead of an empty
# NamedTuple (see `_build_state_layout`); with no parameters there is nothing for it
# to contribute to the value type.
@inline _oop_value_type(u, ::Nothing, t) = promote_type(eltype(u), typeof(t))

# ---- Container seams (GPU / Reactant) ---------------------------------------
#
# The two places the RHS touches the state by index. Kept as named one-liners so a
# device or tracing backend can add a method instead of forking the walker: XLA
# rejects scalar indexing of a traced array, and needs `u[i:i]` (a size-1 slice,
# which broadcasts against full-length lanes) in place of `u[i]`.
@inline _oop_read_state(u, i::Int) = @inbounds u[i]

# A plain indexed gather, deliberately. A stencil's slots are almost always a
# contiguous run (`c[i-1]` over the interior is just the state window shifted by one),
# so it is tempting to detect that and take `u[a:b]` instead — but measured, the
# detector buys NOTHING here: this RHS is bound by allocating one temporary per node,
# not by the gather's addressing mode. (XLA canonicalizes such gathers to slices on its
# own, and an equivalent detector was equally worthless there. Same answer, both worlds.)
@inline _oop_gather(u, slots::Vector{Int}) = @inbounds u[slots]

# ---- Output-container seams (GPU / Reactant) --------------------------------
#
# The three places the RHS BUILDS its output, named for the same reason
# `_oop_read_state` is: a backend must be able to replace them without forking the
# walker. Under Julia they are exactly what they read as, and at Float64 they emit
# the same stores in the same order the inline code did, so nothing changes.
#
# Under tracing they cannot stay inline. `_oop_value_type` resolves to the backend's
# traced SCALAR type (`TracedRNumber{Float64}` for Reactant), and `similar(u, that, n)`
# builds a HOST `Vector{TracedRNumber}` — a Julia array holding traced scalars, which
# is not a traced array and so is not something the trace can return. The output
# container has to come from the backend, not from `T`; hence `_oop_du_zeros` takes
# `u` (whose container type the backend owns) as well as `T`.
#
# And every write RETURNS `du` rather than only mutating it. That costs nothing here
# — the default methods return the same object they were handed — but it is what lets
# a backend implement the writes FUNCTIONALLY on an immutable traced value, which is
# the only form available to it.
@inline _oop_du_zeros(u, ::Type{T}, n::Int) where {T} = fill!(similar(u, T, n), zero(T))

@inline _oop_store(du, i::Int, v) = (@inbounds du[i] = v; du)

# One kernel's whole result lands through ONE call, not one call per cell. Splitting
# it per cell would be the natural-looking thing and is exactly wrong for a tracing
# backend: it turns a single scatter into `length(out)` separate scatter ops, i.e. an
# XLA program whose SIZE grows with the grid — the one property the compiled IR is
# built to avoid. `res` is a scalar when the kernel's whole template hoisted to
# lane-invariant (a single-cell boundary group, say); that branch is the caller's
# `else` arm from before, kept here so the seam owns the entire scatter.
@inline function _oop_scatter(du, out::Vector{Int}, res)
    if res isa AbstractArray
        @inbounds for m in eachindex(out)
            du[out[m]] = res[m]
        end
    else
        @inbounds for m in eachindex(out)
            du[out[m]] = res
        end
    end
    return du
end

# ---- The shared op ladder ---------------------------------------------------
#
# The mechanical unary arms (`sin` … `ceil`), GENERATED from the op-registry table
# exactly as `_eval_vec_unary_elementwise` (vectorize.jl) is, so a unary op added
# to the registry reaches all three ladders at once. `nothing` ⇒ not a mechanical
# unary op ⇒ the caller's ladder falls through.
let arms = :(return nothing)
    for row in reverse(_UNARY_ELEMENTWISE_OPS)
        arms = Core.Expr(:if, :(op === $(QuoteNode(row.sym))),
                         quote
                             _expect_arity_n(op, c, 1)
                             return $(row.sym).(c[1])
                         end,
                         arms)
    end
    @eval @inline function _oop_unary_elementwise(op::Symbol, c::AbstractVector)
        $arms
    end
end

# Apply `op` to already-evaluated children. Every arm broadcasts, so `c` may hold
# scalars (the `_Node` walker), arrays (the `_VecNode` walker), or a mix — and the
# fold ORDER matches `_eval_node_op` / `_eval_vec_op` arm for arm, which is what
# keeps a Float64 run of this emitter bit-identical to `f!`.
function _oop_op(op::Symbol, c::AbstractVector, ::Type{T}) where {T}
    if op === :+
        length(c) == 1 && return c[1]
        r = c[1] .+ c[2]
        for i in 3:length(c)
            r = r .+ c[i]
        end
        return r
    elseif op === :*
        length(c) == 1 && return c[1]
        r = c[1] .* c[2]
        for i in 3:length(c)
            r = r .* c[i]
        end
        return r
    elseif op === :-
        length(c) == 1 && return .-c[1]
        length(c) == 2 && return c[1] .- c[2]
        throw(TreeWalkError("E_TREEWALK_ARITY", "- expects 1 or 2 args"))
    elseif op === :neg
        _expect_arity_n(op, c, 1)
        return .-c[1]
    elseif op === :/
        _expect_arity_n(op, c, 2)
        return c[1] ./ c[2]
    elseif op === :^ || op === :pow
        _expect_arity_n(op, c, 2)
        return c[1] .^ c[2]

    # Comparisons → 1/0 in the value type. A comparison is piecewise constant, so
    # `one(T)`/`zero(T)` carry the correct (zero) derivative under AD.
    elseif op === :<
        _expect_arity_n(op, c, 2)
        return ifelse.(c[1] .< c[2], one(T), zero(T))
    elseif op === Symbol("<=")
        _expect_arity_n(op, c, 2)
        return ifelse.(c[1] .<= c[2], one(T), zero(T))
    elseif op === :>
        _expect_arity_n(op, c, 2)
        return ifelse.(c[1] .> c[2], one(T), zero(T))
    elseif op === Symbol(">=")
        _expect_arity_n(op, c, 2)
        return ifelse.(c[1] .>= c[2], one(T), zero(T))
    elseif op === Symbol("==")
        _expect_arity_n(op, c, 2)
        return ifelse.(c[1] .== c[2], one(T), zero(T))
    elseif op === Symbol("!=")
        _expect_arity_n(op, c, 2)
        return ifelse.(c[1] .!= c[2], one(T), zero(T))

    # Logical — folded (not short-circuited), matching `_eval_vec_op`; every child
    # is evaluated either way, so the values agree with the scalar arm too.
    elseif op === :and
        r = one(T)
        for a in eachindex(c)
            r = ifelse.((r .!= 0) .& (c[a] .!= 0), one(T), zero(T))
        end
        return r
    elseif op === :or
        r = zero(T)
        for a in eachindex(c)
            r = ifelse.((r .!= 0) .| (c[a] .!= 0), one(T), zero(T))
        end
        return r
    elseif op === :not
        _expect_arity_n(op, c, 1)
        return ifelse.(c[1] .== 0, one(T), zero(T))
    elseif op === :ifelse
        _expect_arity_n(op, c, 3)
        return ifelse.(c[1] .!= 0, c[2], c[3])

    elseif (unary = _oop_unary_elementwise(op, c)) !== nothing
        return unary
    elseif op === :atan
        length(c) == 1 && return atan.(c[1])
        length(c) == 2 && return atan.(c[1], c[2])
        throw(TreeWalkError("E_TREEWALK_ARITY", "atan expects 1 or 2 args"))
    elseif op === :atan2
        _expect_arity_n(op, c, 2)
        return atan.(c[1], c[2])
    elseif op === :min
        length(c) < 2 && throw(TreeWalkError("E_TREEWALK_ARITY", "min needs ≥2 args"))
        r = min.(c[1], c[2])
        for i in 3:length(c)
            r = min.(r, c[i])
        end
        return r
    elseif op === :max
        length(c) < 2 && throw(TreeWalkError("E_TREEWALK_ARITY", "max needs ≥2 args"))
        r = max.(c[1], c[2])
        for i in 3:length(c)
            r = max.(r, c[i])
        end
        return r

    elseif op === :pi || op === :π
        return T(pi)
    elseif op === :e
        return T(ℯ)
    elseif op === :Pre
        _expect_arity_n(op, c, 1)
        return c[1]
    else
        throw(TreeWalkError("E_TREEWALK_UNSUPPORTED_OP", String(op)))
    end
end

# ---- interp.* under a generic value type ------------------------------------
#
# The SAME `_interp_*_core` kernels the in-place path calls (registered_functions.jl),
# so a Float64 run is bit-identical by construction. `convert(T, …)` pins the result
# to the value type: the cores' flat-extrapolation clamps return the `Float64` table
# entry, and outside the table the derivative w.r.t. the query genuinely IS zero, so
# widening a clamped `Float64` to a zero-partial `Dual` is the correct lift, not a
# loss. Broadcasting these wrappers is what vectorizes an interp leaf.
@inline _oop_interp_linear(h::_InterpLinearSpec, x, ::Type{T}) where {T} =
    convert(T, _interp_linear_core(h.table, h.axis, x))
@inline _oop_interp_bilinear(h::_InterpBilinearSpec, x, y, ::Type{T}) where {T} =
    convert(T, _interp_bilinear_core(h.table, h.axis_x, h.axis_y, x, y))
@inline _oop_interp_searchsorted(h::_InterpSearchsortedSpec, x, ::Type{T}) where {T} =
    convert(T, _interp_searchsorted_core("interp.searchsorted", x, h.xs))

# ---- Scalar walker (`_Node`) ------------------------------------------------
#
# The generic twin of `_eval_node`. Type-stable in `T`: every leaf converts into the
# value type (so a `Float64` literal beside a `Dual` state does not widen the tree
# to a `Union`), and `_oop_op` returns `T` when all of its children are `T`.
#
# `cache` carries the CSE prelude's per-call values, so `_NK_CACHED` resolves the
# same way it does under `f!` — the OOP form keeps CSE rather than re-walking shared
# subexpressions. `f!` reads the same slots out of a `Vector{Float64}` captured on
# the node; here they come from a `Vector{T}` allocated per call, which is what makes
# CSE survive differentiation at all.
function _oop_eval(n::_Node, u, p, t, cache::AbstractVector{T})::T where {T}
    k = n.kind
    if k === _NK_LITERAL
        return convert(T, n.literal)
    elseif k === _NK_STATE
        return convert(T, _oop_read_state(u, n.idx))
    elseif k === _NK_PARAM
        return convert(T, getfield(p, n.sym))
    elseif k === _NK_TIME
        return convert(T, t)
    elseif k === _NK_PARAM_GATHER
        # Captured live forcing buffer (ess-14f.3) — data, so it enters as a
        # constant of the value type (zero derivative), exactly as it should.
        return convert(T, @inbounds (n.payload::Vector{Float64})[n.idx])
    elseif k === _NK_CACHED
        return @inbounds cache[n.idx]
    elseif k === _NK_CONTRACTION
        return _oop_contraction(n, u, p, t, cache)
    else
        return _oop_eval_op(n, u, p, t, cache)
    end
end

function _oop_eval_op(n::_Node, u, p, t, cache::AbstractVector{T})::T where {T}
    n.op === :fn && return _oop_fn(n, u, p, t, cache)
    if n.op === :^ || n.op === :pow
        return _oop_pow(n.op, n.children, u, p, t, cache)
    end
    # A GUARD MUST GUARD. `ifelse`/`and`/`or` are lazy on the in-place scalar walker
    # (`_eval_node_op`), and this emitter promises a Float64 `:oop` run is bit-
    # identical to `:inplace` — but the generic path below fills EVERY child into `c`
    # before dispatching to `_oop_op`, which would make them eager here and throw
    # `DomainError` on `ifelse(a >= 0, sqrt(a), 0)` at `a = -1`, a model `f!` runs
    # fine. So they short-circuit here, ahead of the child loop, exactly the way `fn`
    # and `^` already return early. (`_oop_op` keeps its folded arms: it is SHARED
    # with `_oop_eval_vec`'s `_VK_OP` arm, where evaluation is over lanes and eager
    # by construction — the same scalar/array divergence `_eval_vec` has.)
    ch = n.children
    if n.op === :ifelse
        _expect_arity_n(n.op, ch, 3)
        return _oop_eval(ch[1], u, p, t, cache) != 0 ?
               _oop_eval(ch[2], u, p, t, cache) :
               _oop_eval(ch[3], u, p, t, cache)
    elseif n.op === :and
        @inbounds for i in eachindex(ch)
            _oop_eval(ch[i], u, p, t, cache) == 0 && return zero(T)
        end
        return one(T)
    elseif n.op === :or
        @inbounds for i in eachindex(ch)
            _oop_eval(ch[i], u, p, t, cache) != 0 && return one(T)
        end
        return zero(T)
    end
    c = Vector{T}(undef, length(ch))
    @inbounds for i in eachindex(ch)
        c[i] = _oop_eval(ch[i], u, p, t, cache)
    end
    return _oop_op(n.op, c, T)
end

# A LITERAL EXPONENT STAYS A LITERAL. Everywhere else, widening a `Float64` constant
# into the value type is a harmless no-op (a `Dual` with zero partials computes the
# same value and carries the same zero derivative). `^` is the sole exception, and it
# is not harmless: `x^y` is the only op whose derivative with respect to an OPERAND
# needs a function with a smaller domain than the op itself — ∂(x^y)/∂y = x^y·log(x).
# Hand ForwardDiff a `Dual` exponent and it evaluates that formula even though the
# exponent's partials are zero, so `c^2` at any NEGATIVE c yields `log(c)` = NaN and
# poisons the whole gradient. Keeping the literal a `Float64` selects the power rule
# instead: correct, faster, and defined on the entire domain `^` is defined on.
#
# Both branches return the value type (`T^Float64` and `T^T` alike), so this stays
# type-stable, and at Float64 it is the same `^` call the in-place ladder makes.
@inline function _oop_pow(op::Symbol, ch::Vector{_Node}, u, p, t,
                          cache::AbstractVector{T})::T where {T}
    _expect_arity_n(op, ch, 2)
    base = _oop_eval(ch[1], u, p, t, cache)
    e = ch[2]
    return e.kind === _NK_LITERAL ? base^e.literal :
           base^_oop_eval(e, u, p, t, cache)
end

# Semiring fold, seeded from the 0̄ identity baked on the node — same order as
# `_eval_contraction`, so the sum is bit-identical at Float64.
function _oop_contraction(n::_Node, u, p, t, cache::AbstractVector{T})::T where {T}
    op = n.op
    ch = n.children
    s = convert(T, n.literal)
    if op === :+
        @inbounds for k in eachindex(ch)
            s += _oop_eval(ch[k], u, p, t, cache)
        end
    elseif op === :*
        @inbounds for k in eachindex(ch)
            s *= _oop_eval(ch[k], u, p, t, cache)
        end
    elseif op === :max
        @inbounds for k in eachindex(ch)
            s = max(s, _oop_eval(ch[k], u, p, t, cache))
        end
    else  # :min
        @inbounds for k in eachindex(ch)
            s = min(s, _oop_eval(ch[k], u, p, t, cache))
        end
    end
    return s
end

# Closed functions. `interp.*` carries a build-time-validated typed spec (the
# `_FN_CONST_ARG_SPECS` protocol); `datetime.*` is all-scalar and boxed, and returns
# a `Float64` — correct, since those are functions of wall-clock time, which is not
# a differentiation variable.
function _oop_fn(n::_Node, u, p, t, cache::AbstractVector{T})::T where {T}
    pl = n.payload
    c = n.children
    if pl isa Tuple{String,_InterpLinearSpec}
        return _oop_interp_linear(pl[2], _oop_eval(c[1], u, p, t, cache), T)
    elseif pl isa Tuple{String,_InterpBilinearSpec}
        return _oop_interp_bilinear(pl[2], _oop_eval(c[1], u, p, t, cache),
                                    _oop_eval(c[2], u, p, t, cache), T)
    elseif pl isa Tuple{String,_InterpSearchsortedSpec}
        return _oop_interp_searchsorted(pl[2], _oop_eval(c[1], u, p, t, cache), T)
    elseif pl isa Tuple{String,Nothing}
        args = Any[_oop_eval(ci, u, p, t, cache) for ci in c]
        return convert(T, evaluate_closed_function(pl[1], args))
    end
    throw(TreeWalkError("E_TREEWALK_UNKNOWN_CLOSED_FUNCTION",
        "fn payload $(typeof(pl)) is neither a typed interp spec tuple nor (String, Nothing)"))
end

# ---- Array walker (`_VecNode`) ----------------------------------------------
#
# Returns a length-`len` array for a lane-varying node and a bare scalar for a
# lane-invariant one (LITERAL, PARAM, TIME, a hoisted `_VK_INVARIANT` subtree).
# Broadcast makes the two interchangeable everywhere except the kernel root, which
# `_make_rhs_oop` materializes.
#
# `_VK_INVARIANT` is where the hoisting pass pays off twice: the subtree is walked
# ONCE per call as a scalar, so it is neither recomputed per lane nor materialized
# as a constant-valued N-vector.
#
# `vcache` is the VEC PRELUDE's per-call results (vec_share.jl): the shared LANE
# VECTORS, already computed, indexed by a `_VK_VCACHED` node's `idx`. Where `f!`'s
# refs read a build-time buffer the def wrote in place, this emitter has no such
# buffer to read — it is value-returning by construction — so the closure fills a
# fresh `Vector{Any}` per call and the ref indexes it. Same evaluate-once property,
# expressed the only way an out-of-place walker can express it.
function _oop_eval_vec(n::_VecNode, u, p, t, cache::AbstractVector{T},
                       vcache::Vector{Any}) where {T}
    k = n.kind
    if k === _VK_VCACHED
        return @inbounds vcache[n.idx]
    elseif k === _VK_LITERAL
        return convert(T, n.literal)
    elseif k === _VK_CONSTVEC
        return n.vals                       # per-cell constants: `Float64` data
    elseif k === _VK_STATE
        return convert(T, _oop_read_state(u, n.idx))
    elseif k === _VK_GATHER
        return _oop_gather(u, n.slots)
    elseif k === _VK_PARAM
        return convert(T, getfield(p, n.sym))
    elseif k === _VK_TIME
        return convert(T, t)
    elseif k === _VK_PGATHER
        return @inbounds (n.payload::Vector{Float64})[n.slots]
    elseif k === _VK_INVARIANT
        return _oop_eval(n.payload::_Node, u, p, t, cache)
    elseif k === _VK_REDUCE
        return _oop_vec_reduce(n, u, p, t, cache, vcache)
    elseif k === _VK_FN
        return _oop_vec_fn(n, u, p, t, cache, vcache)
    elseif (n.op === :^ || n.op === :pow) && length(n.children) == 2
        # A literal exponent stays a literal — see `_oop_pow`. `c[i]^2` over a lane
        # vector holding negative cells is the exact case that NaNs otherwise.
        # (`_vk_hoistable` never lifts a `_VK_LITERAL`, so a shared exponent cannot
        # hide behind a `_VK_VCACHED` and defeat this test.)
        ch = n.children
        base = _oop_eval_vec(ch[1], u, p, t, cache, vcache)
        e = ch[2]
        return e.kind === _VK_LITERAL ? base .^ e.literal :
               base .^ _oop_eval_vec(e, u, p, t, cache, vcache)
    else  # _VK_OP
        ch = n.children
        c = Vector{Any}(undef, length(ch))
        for i in eachindex(ch)
            c[i] = _oop_eval_vec(ch[i], u, p, t, cache, vcache)
        end
        return _oop_op(n.op, c, T)
    end
end

# Axis fold, seeded from 0̄ as a SCALAR: the first `.+` broadcasts it up to the lane
# vector. Same fold order as `_eval_vec_reduce`'s `fill!(b, 0̄)` + `@. b += ck`.
function _oop_vec_reduce(n::_VecNode, u, p, t, cache::AbstractVector{T},
                         vcache::Vector{Any}) where {T}
    op = n.op
    c = n.children
    r = convert(T, n.literal)
    if op === :+
        for k in eachindex(c)
            r = r .+ _oop_eval_vec(c[k], u, p, t, cache, vcache)
        end
    elseif op === :*
        for k in eachindex(c)
            r = r .* _oop_eval_vec(c[k], u, p, t, cache, vcache)
        end
    elseif op === :max
        for k in eachindex(c)
            r = max.(r, _oop_eval_vec(c[k], u, p, t, cache, vcache))
        end
    else  # :min
        for k in eachindex(c)
            r = min.(r, _oop_eval_vec(c[k], u, p, t, cache, vcache))
        end
    end
    return r
end

# An interp leaf vectorizes by BROADCASTING the same scalar core the in-place
# kernels call per lane — identical arithmetic, so identical bits, and it inherits
# the generic query type for free. (An XLA backend will want this re-expressed as
# locate → gather → blend, since a broadcast over an opaque core does not trace;
# that is a backend concern, not a numerics one.)
function _oop_vec_fn(n::_VecNode, u, p, t, cache::AbstractVector{T},
                     vcache::Vector{Any}) where {T}
    h = n.payload
    c = n.children
    if h isa _InterpLinearSpec
        return _oop_interp_linear.(Ref(h), _oop_eval_vec(c[1], u, p, t, cache, vcache), T)
    elseif h isa _InterpBilinearSpec
        return _oop_interp_bilinear.(Ref(h), _oop_eval_vec(c[1], u, p, t, cache, vcache),
                                     _oop_eval_vec(c[2], u, p, t, cache, vcache), T)
    elseif h isa _InterpSearchsortedSpec
        return _oop_interp_searchsorted.(Ref(h),
                                         _oop_eval_vec(c[1], u, p, t, cache, vcache), T)
    end
    # All-scalar closed functions (`datetime.*`): boxed, one call per lane.
    fname, spec = n.payload::Tuple{String,Any}
    spec === nothing ||
        throw(TreeWalkError("E_TREEWALK_UNSUPPORTED_VEC_OP", string("fn:", fname)))
    cv = Any[_oop_eval_vec(ci, u, p, t, cache, vcache) for ci in c]
    return broadcast((as...) -> convert(T, evaluate_closed_function(fname, Any[as...])),
                     cv...)
end

# ---- The closure ------------------------------------------------------------
#
# Mirrors `_make_rhs` phase for phase (CSE prelude → scalar equations → array
# kernels) so the two emitters cannot diverge in evaluation ORDER, only in storage.
# States with no `D(...)` equation keep `du = 0`, as under `f!`.
#
# Every touch of the output goes through the `_oop_du_zeros` / `_oop_store` /
# `_oop_scatter` seams above, and the closure REBINDS `du` from each — so a backend
# whose output is immutable (a traced value) is expressible here without a second
# closure. At Float64 the seams are the inline code they replaced.
#
# NO CONST-CADENCE TIER HERE, AND THAT IS NOT AN OVERSIGHT (4qf). `f!` skips its
# const prelude slots when `p` has not moved because it refills a buffer it OWNS
# across calls — the values from the previous call are still sitting in it. This
# emitter's cache is a `Vector{T}` allocated FRESH on every call, and it must be: a
# captured host buffer is precisely what makes `f!` untraceable (see property 1 at the
# top of this file), and under tracing `T` is the backend's traced scalar type, so a
# cross-call buffer would be carrying traced values from one trace into the next. There
# is nothing valid to skip TO. So every slot is refilled, in ascending slot order —
# which is the const tier's two loops with the skip permanently disabled, hence
# numerically identical to `f!` (the tests pin `:inplace` ≡ `:oop`) and never stale.
# The build still REPORTS `n_const_slots` / `n_dynamic_slots` for an `:oop` build; the
# classification is a property of the prelude, not of the emitter.
# ---------------------------------------------------------------------------
# J5 — REFUSE TO BE XLA-COMPILED WHILE A LIVE FORCING BUFFER IS BOUND.
#
# A `_VK_PGATHER`/`_NK_PARAM_GATHER` payload is an ALIASED HOST `Vector{Float64}`
# — the same object the caller passed through `param_arrays`, so that a
# discrete-cadence refresh callback's in-place `buffer .= …` is seen by the RHS
# with zero reallocation. That aliasing is the whole point of the channel, and it
# is exactly what an XLA tracer cannot honour: to the tracer the host vector is a
# CONSTANT, so `@compile` bakes the buffer's compile-time contents into the
# program and the refresh is never seen again.
#
# The failure mode is the dangerous one — not an exception, not a NaN, but THE
# SAME NUMBERS FOREVER, off by the full magnitude of every forcing update. A
# silently wrong answer is worse than no answer, so this refuses.
#
# The refusal fires during the TRACE (i.e. inside `@compile`), not at build time,
# because build time cannot distinguish the two consumers: the interpreted
# out-of-place closure over a `param_arrays` model is perfectly correct and DOES
# track the refresh — `reactant_oop_test.jl` asserts exactly that — so refusing at
# `build_evaluator` would reject a working configuration.
#
# `_is_traced` deliberately does not depend on Reactant: it asks whether the
# argument's type comes from the Reactant module at all. ForwardDiff `Dual`s and
# Enzyme's shadows are NOT Reactant types, so AD is untouched.
# ---------------------------------------------------------------------------
_reactant_rooted(x) = nameof(Base.moduleroot(parentmodule(typeof(x)))) === :Reactant
_is_traced(u, p, t) = _reactant_rooted(u) || _reactant_rooted(t)

# Does this compiled IR read a live forcing buffer anywhere? A `_VK_INVARIANT`
# carries a scalar `_Node` in its payload, so the scalar side is walked too — a
# forcing read hoisted into the scalar prelude is still a forcing read.
_vec_has_pgather(n::_VecNode) =
    n.kind === _VK_PGATHER ||
    (n.kind === _VK_INVARIANT && n.payload isa _Node && _scalar_has_pgather(n.payload)) ||
    any(_vec_has_pgather, n.children)

_scalar_has_pgather(n::_Node) =
    n.kind === _NK_PARAM_GATHER || any(_scalar_has_pgather, n.children)

function _has_live_forcing(cse_prelude, rhs_list, vec_prelude, vec_kernels)
    any(_scalar_has_pgather, cse_prelude) && return true
    any(((_, node),) -> _scalar_has_pgather(node), rhs_list) && return true
    any(_vec_has_pgather, vec_prelude) && return true
    any(vk -> _vec_has_pgather(vk.template), vec_kernels)
end

# ---- Affine access kernels, out of place (ess-affine) -----------------------
#
# The functional twin of `_run_acc_kernel!` (access_kernel.jl): the SAME cell walk
# and the SAME `_eval_acc` spine evaluation — which is eltype-generic, so this
# inherits AD and a bit-identical Float64 run for free — but each cell's value
# lands through the `_oop_store` seam, which RETURNS `du`, so an immutable/rebound
# output is expressible exactly as the rest of this emitter is. The box index math
# mirrors `_run_box_kernel!` (rank ≤ 3 unrolled, `oln = base + Σ i_d·stride_d`).
#
# NOT de-scalarized for tracing. `_eval_acc` reads `u[oln+Δ]` directly (through the
# descriptor `_fetch`, not the `_oop_read_state` seam) — one scalar index per gather
# per cell, the per-lane scalar access XLA rejects (property 2 in this file's
# header). Rewriting the affine gathers/scatters into whole-box array ops is the
# same body of work `_make_rhs`'s de-scalarization was, and is deferred; `f` above
# REFUSES a traced call while acc kernels are present rather than emit a program
# that scalar-indexes a traced value. On host (Float64 / ForwardDiff `Dual`) it is
# correct and matches both the in-place affine path and the per-cell reference.
function _oop_run_acc_kernel(du, u, p, t, K::_AccKernel, ::Type{T}) where {T}
    cs = K.cells
    if _is_contig(cs)                               # contiguous / unstructured
        @inbounds for c in cs.ranges[1]
            du = _oop_store(du, c, _eval_acc(K.spine, u, p, t, c, 0, c, (c, 1, 1), K, T))
        end
        return du
    end
    st = cs.strides; rg = cs.ranges; b = cs.base; nd = length(st)
    if nd == 1
        s1 = st[1]
        @inbounds for i in rg[1]
            oln = b + i*s1
            du = _oop_store(du, oln, _eval_acc(K.spine, u, p, t, oln, 0, oln, (i, 1, 1), K, T))
        end
    elseif nd == 2
        s1 = st[1]; s2 = st[2]
        @inbounds for j in rg[2], i in rg[1]
            oln = b + i*s1 + j*s2
            du = _oop_store(du, oln, _eval_acc(K.spine, u, p, t, oln, 0, oln, (i, j, 1), K, T))
        end
    elseif nd == 3
        s1 = st[1]; s2 = st[2]; s3 = st[3]
        @inbounds for k in rg[3], j in rg[2], i in rg[1]
            oln = b + i*s1 + j*s2 + k*s3
            du = _oop_store(du, oln, _eval_acc(K.spine, u, p, t, oln, 0, oln, (i, j, k), K, T))
        end
    else
        @inbounds for idxs in Iterators.product(rg...)
            oln = b
            for d in 1:nd; oln += idxs[d]*st[d]; end
            mi = (idxs[1], nd >= 2 ? idxs[2] : 1, nd >= 3 ? idxs[3] : 1)
            du = _oop_store(du, oln, _eval_acc(K.spine, u, p, t, oln, 0, oln, mi, K, T))
        end
    end
    return du
end

function _make_rhs_oop(rhs_list::AbstractVector{Tuple{Int,_Node}},
                       cse_prelude::AbstractVector{_Node},
                       vec_prelude::AbstractVector{_VecNode},
                       vec_kernels::AbstractVector{_VecKernel},
                       acc_kernels::AbstractVector{_AccKernel},
                       n_states::Int)
    has_acc = !isempty(acc_kernels)
    n_cse = length(cse_prelude)
    n_vec = length(vec_prelude)
    live_forcing = _has_live_forcing(cse_prelude, rhs_list, vec_prelude, vec_kernels)
    function f(u, p, t)
        if has_acc && _is_traced(u, p, t)
            throw(TreeWalkError("E_TREEWALK_ACC_XLA_UNSUPPORTED",
                "This model built affine access kernels (ess-affine), which are not " *
                "yet de-scalarized for tracing: `_eval_acc` reads `u[oln+Δ]` one " *
                "scalar index per gather per cell, and an XLA/Reactant tracer rejects " *
                "scalar indexing of a traced array. Rewriting the affine gathers/" *
                "scatters into whole-box array ops (the same de-scalarization the vec " *
                "kernels already have) is deferred. Run the interpreted evaluator " *
                "(host Float64 or ForwardDiff `Dual`), where the affine path is correct " *
                "and bit-identical to the per-cell reference."))
        end
        if live_forcing && _is_traced(u, p, t)
            throw(TreeWalkError("E_TREEWALK_XLA_LIVE_FORCING",
                "This model binds a live forcing buffer through `param_arrays`, and " *
                "an XLA/Reactant tracer cannot honour it: the buffer is an aliased " *
                "host array, which the tracer captures as a CONSTANT. `@compile` would " *
                "bake in its compile-time contents and then silently ignore every " *
                "in-place refresh a data-refresh callback performs — the same numbers " *
                "forever, with no exception and no NaN. Either drop `param_arrays` and " *
                "pass the forcing data as `const_arrays` (frozen, inlined — correct if " *
                "the data never changes), or run the interpreted evaluator, which does " *
                "track the refresh."))
        end
        T = _oop_value_type(u, p, t)
        cache = Vector{T}(undef, n_cse)
        @inbounds for s in 1:n_cse
            cache[s] = _oop_eval(cse_prelude[s], u, p, t, cache)
        end

        du = _oop_du_zeros(u, T, n_states)
        @inbounds for k in eachindex(rhs_list)
            slot, node = rhs_list[k]
            du = _oop_store(du, slot, _oop_eval(node, u, p, t, cache))
        end

        # The shared LANE VECTORS (vec_share.jl), in topological slot order — the same
        # phase, in the same place, that `f!` runs. `Vector{Any}` because a def's value is
        # a `Vector{T}` or (for a `_VK_CONSTVEC`/`_VK_PGATHER` def) a `Vector{Float64}`;
        # this emitter allocates per call anyway, so the box costs nothing it was not
        # already paying, and every subsequent read of the def is one index instead of a
        # re-walk of its whole subtree.
        vcache = Vector{Any}(undef, n_vec)
        @inbounds for s in 1:n_vec
            vcache[s] = _oop_eval_vec(vec_prelude[s], u, p, t, cache, vcache)
        end

        for vk in vec_kernels
            res = _oop_eval_vec(vk.template, u, p, t, cache, vcache)
            du = _oop_scatter(du, vk.out_slots, res)
        end

        # Affine access kernels (ess-affine), out of place. Each rebinds `du`
        # through the `_oop_store` seam — see `_oop_run_acc_kernel`. On host these
        # are the same values `f!`'s in-place `_run_acc_kernel!` writes, in the same
        # slots, so a Float64 `:oop` run stays bit-identical to `:inplace`.
        for K in acc_kernels
            du = _oop_run_acc_kernel(du, u, p, t, K, T)
        end
        return du
    end
    return f
end
