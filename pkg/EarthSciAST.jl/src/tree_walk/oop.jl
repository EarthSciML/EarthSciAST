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
# WHY A SECOND EMITTER (and not a replacement).
# ---------------------------------------------
# `_make_rhs`'s `f!` is the production Float64 path: type-stable, zero-alloc, one
# preallocated `Float64` buffer per `_VecNode` (`n.buf`). Those buffers are what
# make it fast AND what make it Float64-only — a `Vector{Float64}` cannot hold a
# `ForwardDiff.Dual`, so `f!` cannot be differentiated. Widening the buffers to a
# type parameter would mean allocating them per call, i.e. giving up exactly the
# property they exist for.
#
# So the two forms are siblings, not competitors, and they share the compiled IR:
#   * `f!(du, u, p, t)` — zero-alloc, Float64. The default; use it to SOLVE.
#   * `f(u, p, t) -> du` — allocating, eltype-generic. Use it to DIFFERENTIATE.
#
# `build_evaluator(model; form = :oop)` returns the latter in the `f!` slot of the
# usual `(f, u0, p, tspan, var_map)` tuple; SciML dispatches `ODEProblem` on RHS
# arity, so it drops straight in.
#
# WHAT GENERICITY BUYS (the point of the exercise): ForwardDiff over the state
# (Jacobians for stiff/implicit solvers), ForwardDiff over the parameters
# (sensitivities), and Enzyme reverse mode all work on `f`. The value type is
# derived from `u`, `p` AND `t` together — see `_oop_value_type` — which is what
# makes parameter differentiation work: there `u` stays `Float64` while the
# parameter values go `Dual`, so an output buffer sized from `eltype(u)` alone
# would throw on the first store.
#
# ENZYME NEEDS ONE FLAG, and it is worth knowing why before trying to remove it:
#
#     Enzyme.API.strictAliasing!(false)     # once, before any autodiff call
#
# Reverse mode then produces gradients matching ForwardDiff to ~1e-16. Without it,
# Enzyme's type analysis rejects the RHS — not because of anything this file does,
# but because the walk LOADS FIELDS FROM `_VecNode`, and that struct is heterogeneous
# by design: one `payload::Any` slot serving ten node kinds, plus `fnargs::Vector{Any}`
# for the boxed closed-function path. Enzyme cannot type-analyze loads out of such an
# object and bails on the whole method — including, note, loads of the CONCRETE fields
# (`vals`, `slots`), so simply routing around the `Any` payload does NOT help. I tried
# that; it does not work. Nothing short of a payload-free IR will.
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
# Which is exactly why both emitters exist. Integrate with `f!`; differentiate with `f`.
# Under AD the comparison is anyway academic: `Dual` arithmetic dominates, and a chunked
# ForwardDiff Jacobian pays the primal cost once per chunk, not once per column.

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
    ch = n.children
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
function _oop_eval_vec(n::_VecNode, u, p, t, cache::AbstractVector{T}) where {T}
    k = n.kind
    if k === _VK_LITERAL
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
        return _oop_vec_reduce(n, u, p, t, cache)
    elseif k === _VK_FN
        return _oop_vec_fn(n, u, p, t, cache)
    elseif (n.op === :^ || n.op === :pow) && length(n.children) == 2
        # A literal exponent stays a literal — see `_oop_pow`. `c[i]^2` over a lane
        # vector holding negative cells is the exact case that NaNs otherwise.
        ch = n.children
        base = _oop_eval_vec(ch[1], u, p, t, cache)
        e = ch[2]
        return e.kind === _VK_LITERAL ? base .^ e.literal :
               base .^ _oop_eval_vec(e, u, p, t, cache)
    else  # _VK_OP
        ch = n.children
        c = Vector{Any}(undef, length(ch))
        for i in eachindex(ch)
            c[i] = _oop_eval_vec(ch[i], u, p, t, cache)
        end
        return _oop_op(n.op, c, T)
    end
end

# Axis fold, seeded from 0̄ as a SCALAR: the first `.+` broadcasts it up to the lane
# vector. Same fold order as `_eval_vec_reduce`'s `fill!(b, 0̄)` + `@. b += ck`.
function _oop_vec_reduce(n::_VecNode, u, p, t, cache::AbstractVector{T}) where {T}
    op = n.op
    c = n.children
    r = convert(T, n.literal)
    if op === :+
        for k in eachindex(c)
            r = r .+ _oop_eval_vec(c[k], u, p, t, cache)
        end
    elseif op === :*
        for k in eachindex(c)
            r = r .* _oop_eval_vec(c[k], u, p, t, cache)
        end
    elseif op === :max
        for k in eachindex(c)
            r = max.(r, _oop_eval_vec(c[k], u, p, t, cache))
        end
    else  # :min
        for k in eachindex(c)
            r = min.(r, _oop_eval_vec(c[k], u, p, t, cache))
        end
    end
    return r
end

# An interp leaf vectorizes by BROADCASTING the same scalar core the in-place
# kernels call per lane — identical arithmetic, so identical bits, and it inherits
# the generic query type for free. (An XLA backend will want this re-expressed as
# locate → gather → blend, since a broadcast over an opaque core does not trace;
# that is a backend concern, not a numerics one.)
function _oop_vec_fn(n::_VecNode, u, p, t, cache::AbstractVector{T}) where {T}
    h = n.payload
    c = n.children
    if h isa _InterpLinearSpec
        return _oop_interp_linear.(Ref(h), _oop_eval_vec(c[1], u, p, t, cache), T)
    elseif h isa _InterpBilinearSpec
        return _oop_interp_bilinear.(Ref(h), _oop_eval_vec(c[1], u, p, t, cache),
                                     _oop_eval_vec(c[2], u, p, t, cache), T)
    elseif h isa _InterpSearchsortedSpec
        return _oop_interp_searchsorted.(Ref(h), _oop_eval_vec(c[1], u, p, t, cache), T)
    end
    # All-scalar closed functions (`datetime.*`): boxed, one call per lane.
    fname, spec = n.payload::Tuple{String,Any}
    spec === nothing ||
        throw(TreeWalkError("E_TREEWALK_UNSUPPORTED_VEC_OP", string("fn:", fname)))
    cv = Any[_oop_eval_vec(ci, u, p, t, cache) for ci in c]
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
function _make_rhs_oop(rhs_list::AbstractVector{Tuple{Int,_Node}},
                       cse_prelude::AbstractVector{_Node},
                       vec_kernels::AbstractVector{_VecKernel},
                       n_states::Int)
    n_cse = length(cse_prelude)
    function f(u, p, t)
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
        for vk in vec_kernels
            res = _oop_eval_vec(vk.template, u, p, t, cache)
            du = _oop_scatter(du, vk.out_slots, res)
        end
        return du
    end
    return f
end
