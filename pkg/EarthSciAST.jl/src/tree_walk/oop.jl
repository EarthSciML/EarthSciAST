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
# parameter values, and time — see `_rhs_value_type` (compile.jl), whose
# rationale (deriving `T` from all three, not just `eltype(u)`, is load-bearing
# under ForwardDiff-over-parameters) applies verbatim here. The two emitters
# MUST agree on the value type, so this is the same function under the
# emitter-local name (it was an identical hand-copy until the promised dedupe).
const _oop_value_type = _rhs_value_type

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
# to the registry reaches every ladder (scalar / vectorized / oop / access-kernel)
# at once. `nothing` ⇒ not a mechanical unary op ⇒ the caller's ladder falls
# through. The comparison / binary / min-max probes below follow the same
# protocol from their own registry tables.
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

# The comparison arms (`<` … `!=` → 1/0 in the value type), GENERATED from
# `_COMPARISON_ELEMENTWISE_OPS` the same way. A comparison is piecewise
# constant, so `one(T)`/`zero(T)` carry the correct (zero) derivative under AD.
# `$(fnsym).(a, b)` is broadcast sugar for the hand-written infix `a .< b`, so
# the fused blend is unchanged.
let arms = :(return nothing)
    for row in reverse(_COMPARISON_ELEMENTWISE_OPS)
        arms = Core.Expr(:if, :(op === $(QuoteNode(row.sym))),
                         quote
                             _expect_arity_n(op, c, 2)
                             return ifelse.($(row.fnsym).(c[1], c[2]), one(T), zero(T))
                         end,
                         arms)
    end
    @eval @inline function _oop_comparison(op::Symbol, c::AbstractVector,
                                           ::Type{T}) where {T}
        $arms
    end
end

# The fixed-2-ary elementwise arms (`/`, `^`, `pow`, `atan2`), GENERATED from
# `_BINARY_ELEMENTWISE_OPS`. NB the `^` arm here is only the FALLBACK for a
# malformed arity: a well-formed 2-ary `^`/`pow` is intercepted upstream by
# `_oop_pow` / `_oop_eval_vec`'s literal-exponent arm and never reaches the
# shared ladder (see `_oop_pow` for why).
let arms = :(return nothing)
    for row in reverse(_BINARY_ELEMENTWISE_OPS)
        arms = Core.Expr(:if, :(op === $(QuoteNode(row.sym))),
                         quote
                             _expect_arity_n(op, c, 2)
                             return $(row.fnsym).(c[1], c[2])
                         end,
                         arms)
    end
    @eval @inline function _oop_binary_elementwise(op::Symbol, c::AbstractVector)
        $arms
    end
end

# The n-ary `min`/`max` folds (arity ≥ 2), GENERATED from `_NARY_MINMAX_OPS` —
# same guard and fold order as the in-place ladders.
let arms = :(return nothing)
    for row in reverse(_NARY_MINMAX_OPS)
        arms = Core.Expr(:if, :(op === $(QuoteNode(row.sym))),
                         quote
                             length(c) < 2 && throw(TreeWalkError("E_TREEWALK_ARITY",
                                 $(row.name * " needs ≥2 args")))
                             r = $(row.fnsym).(c[1], c[2])
                             for i in 3:length(c)
                                 r = $(row.fnsym).(r, c[i])
                             end
                             return r
                         end,
                         arms)
    end
    @eval @inline function _oop_minmax(op::Symbol, c::AbstractVector)
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
    # Fixed-2-ary elementwise (`/`, `^`, `pow`, `atan2`) — GENERATED from the
    # registry (`_oop_binary_elementwise` above). The probe sits where `/` sat.
    elseif (bin = _oop_binary_elementwise(op, c)) !== nothing
        return bin

    # Comparisons → 1/0 in the value type — GENERATED from the registry
    # (`_oop_comparison` above, where the piecewise-constant AD note lives).
    elseif (cmp = _oop_comparison(op, c, T)) !== nothing
        return cmp

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
    # n-ary min/max (arity ≥ 2) — GENERATED from the registry (`_oop_minmax`
    # above). (`atan2` is handled by the binary probe near the ladder top.)
    elseif (mm = _oop_minmax(op, c)) !== nothing
        return mm

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

# ---- interp.* over whole LANES: locate → gather → blend ----------------------
#
# The de-scalarized interp forms the affine access-kernel path evaluates (and the
# forms an XLA/Reactant trace needs): NO branch on the query, NO opaque scalar
# core inside a broadcast — every step is elementwise arithmetic + `ifelse`
# selection, so a traced query lane vector flows through as whole-array ops and
# the emitted program's size is O(table), independent of the grid.
#
# BIT-IDENTICAL to the scalar cores, by mirroring their decision trees with
# `ifelse` selects instead of branches:
#   * locate: `i = clamp(Σ_k [axis[k] ≤ x], 1, n-1)` — for a validated strictly-
#     increasing axis this is exactly the scan's "largest k with axis[k] ≤ x".
#   * gather: chained `ifelse(i == k, table[k], …)` SELECTS (never blends) the
#     cell's endpoints, so table entries come through exactly (no `0·Inf`, no
#     signed-zero surprises).
#   * blend: the cores' pinned form `tᵢ + w·(tᵢ₊₁ − tᵢ)` verbatim.
#   * clamps: the same outer `x ≤ axis[1]` / `x ≥ axis[n]` selects the cores
#     early-return on. A NaN query fails both compares, takes the blend arm, and
#     `w = (NaN − aᵢ)/…` propagates NaN — the cores' documented NaN semantics.
# The oop test file pins these against the scalar cores over dense query sweeps
# (in-range, knots, both clamps, NaN).
#
# `q` may be a lane vector OR a scalar (an invariant query) — broadcast serves
# both, exactly like the rest of this emitter.
function _oop_interp_linear_lanes(h::_InterpLinearSpec, q, ::Type{T}) where {T}
    axis = h.axis; table = h.table
    n = length(axis)
    cnt = ifelse.(axis[1] .<= q, 1.0, 0.0)
    for k in 2:n
        cnt = cnt .+ ifelse.(axis[k] .<= q, 1.0, 0.0)
    end
    i = min.(max.(cnt, 1.0), Float64(n - 1))
    ai  = axis[1] .+ zero.(i);  ai1 = axis[2] .+ zero.(i)
    ti  = table[1] .+ zero.(i); ti1 = table[2] .+ zero.(i)
    for k in 2:(n - 1)
        sel = i .== Float64(k)
        ai  = ifelse.(sel, axis[k],      ai)
        ai1 = ifelse.(sel, axis[k + 1],  ai1)
        ti  = ifelse.(sel, table[k],     ti)
        ti1 = ifelse.(sel, table[k + 1], ti1)
    end
    w = (q .- ai) ./ (ai1 .- ai)
    blend = ti .+ w .* (ti1 .- ti)
    return ifelse.(q .<= axis[1], table[1],
                   ifelse.(q .>= axis[n], table[n], blend))
end

function _oop_interp_searchsorted_lanes(h::_InterpSearchsortedSpec, q, ::Type{T}) where {T}
    xs = h.xs
    n = length(xs)
    n == 0 && return one.(q .* 0 .+ 1.0)     # empty table → 1 lane-wide (core's rule)
    # smallest i with xs[i] ≥ x  ==  #(xs .< x) + 1; NaN → n+1 (selected explicitly,
    # since `xs[k] < NaN` is false everywhere and would land on 1).
    cnt = ifelse.(xs[1] .< q, 1.0, 0.0)
    for k in 2:n
        cnt = cnt .+ ifelse.(xs[k] .< q, 1.0, 0.0)
    end
    r = cnt .+ 1.0
    return ifelse.(q .!= q, Float64(n + 1), r)
end

function _oop_interp_bilinear_lanes(h::_InterpBilinearSpec, x, y, ::Type{T}) where {T}
    ax = h.axis_x; ay = h.axis_y; table = h.table
    Nx = length(ax); Ny = length(ay)
    # Per-axis clamp of the QUERY (the core's x_q/y_q), then count-locate.
    x_q = ifelse.(x .<= ax[1], ax[1], ifelse.(x .>= ax[Nx], ax[Nx], x))
    y_q = ifelse.(y .<= ay[1], ay[1], ifelse.(y .>= ay[Ny], ay[Ny], y))
    ci = ifelse.(ax[1] .<= x_q, 1.0, 0.0)
    for k in 2:Nx
        ci = ci .+ ifelse.(ax[k] .<= x_q, 1.0, 0.0)
    end
    i = min.(max.(ci, 1.0), Float64(Nx - 1))
    cj = ifelse.(ay[1] .<= y_q, 1.0, 0.0)
    for k in 2:Ny
        cj = cj .+ ifelse.(ay[k] .<= y_q, 1.0, 0.0)
    end
    j = min.(max.(cj, 1.0), Float64(Ny - 1))
    xi  = ax[1] .+ zero.(i); xip1 = ax[2] .+ zero.(i)
    for k in 2:(Nx - 1)
        sel = i .== Float64(k)
        xi   = ifelse.(sel, ax[k],     xi)
        xip1 = ifelse.(sel, ax[k + 1], xip1)
    end
    yj  = ay[1] .+ zero.(j); yjp1 = ay[2] .+ zero.(j)
    for k in 2:(Ny - 1)
        sel = j .== Float64(k)
        yj   = ifelse.(sel, ay[k],     yj)
        yjp1 = ifelse.(sel, ay[k + 1], yjp1)
    end
    # Corner gathers: doubly-chained selects over the (Nx−1)×(Ny−1) cells.
    t_ij   = table[1][1] .+ zero.(i .+ j); t_i1j  = table[2][1] .+ zero.(i .+ j)
    t_ijp1 = table[1][2] .+ zero.(i .+ j); t_i1jp1 = table[2][2] .+ zero.(i .+ j)
    for k in 1:(Nx - 1), l in 1:(Ny - 1)
        (k == 1 && l == 1) && continue
        sel = (i .== Float64(k)) .& (j .== Float64(l))
        t_ij    = ifelse.(sel, table[k][l],         t_ij)
        t_i1j   = ifelse.(sel, table[k + 1][l],     t_i1j)
        t_ijp1  = ifelse.(sel, table[k][l + 1],     t_ijp1)
        t_i1jp1 = ifelse.(sel, table[k + 1][l + 1], t_i1jp1)
    end
    wx = (x_q .- xi) ./ (xip1 .- xi)
    wy = (y_q .- yj) ./ (yjp1 .- yj)
    row_j   = t_ij   .+ wx .* (t_i1j   .- t_ij)
    row_jp1 = t_ijp1 .+ wx .* (t_i1jp1 .- t_ijp1)
    return row_j .+ wy .* (row_jp1 .- row_j)
end

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
# `_FN_CONST_ARG_SPECS` protocol); `datetime.*` is all-scalar and boxed. The
# boxed call goes through `_eval_closed_fn`, which selects the `Float64`-pinned
# registry or its eltype-generic twin on the compile-time `T` — so a `Dual` walk
# differentiates `datetime.julian_day` (a real function of `t`, which IS a
# differentiation variable for a Rosenbrock ∂f/∂t term) instead of throwing on it.
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
        return convert(T, _eval_closed_fn(pl[1], args, T))
    end
    throw(TreeWalkError("E_TREEWALK_UNKNOWN_CLOSED_FUNCTION",
        "fn payload $(typeof(pl)) is neither a typed interp spec tuple nor (String, Nothing)"))
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
_scalar_has_pgather(n::_Node) =
    n.kind === _NK_PARAM_GATHER || any(_scalar_has_pgather, n.children)

function _has_live_forcing(cse_prelude, rhs_list)
    any(_scalar_has_pgather, cse_prelude) && return true
    any(((_, node),) -> _scalar_has_pgather(node), rhs_list)
end

# The ACCESS-KERNEL half of the J5 guard. An affine kernel reads live forcing
# through two descriptor kinds: `_AK_FORCING_BOX` (a lane-affine gather off the
# aliased `_PGatherArray.flat`) and `_AK_ARR_FIXED` (the lowering of an invariant
# `_NK_PARAM_GATHER` — also the aliased buffer). Both are host arrays a tracer
# would bake in as constants, so a build whose acc kernels carry either must
# refuse `@compile` exactly as the `_VK_PGATHER` path does. Sub-kernel tables
# (`K.subs`, transitive by construction) are scanned too.
_acc_desc_live_forcing(a::_AccDesc) =
    a.kind === _AK_FORCING_BOX || a.kind === _AK_ARR_FIXED ||
    a.kind === _AK_ARR_TBL_BOX
_acc_has_live_forcing(K::_AccKernel) =
    any(_acc_desc_live_forcing, K.acc) ||
    any(S -> any(_acc_desc_live_forcing, S.acc), K.subs)

# ---- Affine access kernels, out of place (ess-affine) -----------------------
#
# TWO FORMS, chosen per kernel at closure build:
#
#   * The VECTORIZED (de-scalarized) form — `_oop_run_acc_vec` below — the
#     default. Every state read is a whole-array `_oop_gather(u, slots)` with
#     slot vectors precomputed on host from the kernel's affine descriptors,
#     every op is the shared broadcast ladder, interp leaves are the
#     locate→gather→blend lane forms, and the kernel's whole result lands
#     through ONE `_oop_scatter`. NOTHING scalar-indexes `u` per cell, so an
#     XLA/Reactant trace of a DEFAULT (affine) build emits a program whose size
#     is independent of the grid — the refusal this replaced
#     (`E_TREEWALK_ACC_XLA_UNSUPPORTED`) is gone.
#
#   * The PER-CELL fallback — `_oop_run_acc_kernel` — the functional twin of
#     `_run_acc_kernel!`: same cell walk, same eltype-generic `_eval_acc` spine,
#     each value landing through the `_oop_store` seam. Correct on host
#     (Float64 / ForwardDiff `Dual`); under a trace its per-cell scalar reads
#     fail LOUDLY in Reactant rather than silently.
#
#     Two classes still take this fallback (gordian total-vectorize closed the
#     ghost-bearing state table — it now vectorizes by gather-then-select):
#       - VARIABLE-VALENCE reductions / unstructured indirect gathers (`_NK_REDUCE`
#         with a per-cell neighbour count, `_AK_STATE_INDIRECT[_COL]`, `_AK_CONST_
#         EDGE`). A whole-array form needs a SEGMENTED gather+reduce (CSR-style)
#         that reproduces `_eval_acc`'s seeded, child-ORDERED ⊕-fold bit for bit;
#         a padded rectangular reduce would reorder the fold. Left as a fallback
#         rather than risk a fold-order divergence across the semiring/aggregate/
#         join corpus.
#       - TEMPLATE SUB-KERNEL calls (`K.subs` non-empty / `_NK_SUBCALL`). Needs the
#         sub-kernel evaluated as its own whole-array op over the parent's lanes
#         and its result array spliced into the parent operand stream (per
#         (variant, region), shared). The in-place tape declines these the same
#         way (`isempty(K.subs)` gate in `_build_acc_plan`); neither path
#         vectorizes them yet.
function _oop_run_acc_kernel(du, u, p, t, K::_AccKernel, ::Type{T}) where {T}
    for S in K.subs                                 # template-body sub-kernels:
        _fill_invariant!(S, u, p, t, T)             # invariant tier once per call
    end
    _fill_invariant!(K, u, p, t, T)                 # once per call, before the loop
    cs = K.cells
    # `_eval_cell` fills the per-cell CSE scratch (an in-place buffer write) then
    # returns the spine value; on the host / ForwardDiff-over-oop path that
    # mutation is fine. (A traced call never lands here for a DEFAULT affine
    # build — those kernels take `_oop_run_acc_vec`; a declined kernel's scalar
    # reads fail loudly inside Reactant.)
    if _is_outs(cs)                                 # indirect out slots (per-cell merge)
        outs = cs.outs
        @inbounds for c in eachindex(outs)
            oln = outs[c]
            du = _oop_store(du, oln, _eval_cell(K, u, p, t, c, oln, (c, 1, 1), T))
        end
        return du
    end
    if _is_contig(cs)                               # contiguous / unstructured
        @inbounds for c in cs.ranges[1]
            du = _oop_store(du, c, _eval_cell(K, u, p, t, c, c, (c, 1, 1), T))
        end
        return du
    end
    st = cs.strides; rg = cs.ranges; b = cs.base; nd = length(st)
    if nd == 1
        s1 = st[1]
        @inbounds for i in rg[1]
            oln = b + i*s1
            du = _oop_store(du, oln, _eval_cell(K, u, p, t, oln, oln, (i, 1, 1), T))
        end
    elseif nd == 2
        s1 = st[1]; s2 = st[2]
        @inbounds for j in rg[2], i in rg[1]
            oln = b + i*s1 + j*s2
            du = _oop_store(du, oln, _eval_cell(K, u, p, t, oln, oln, (i, j, 1), T))
        end
    elseif nd == 3
        s1 = st[1]; s2 = st[2]; s3 = st[3]
        @inbounds for k in rg[3], j in rg[2], i in rg[1]
            oln = b + i*s1 + j*s2 + k*s3
            du = _oop_store(du, oln, _eval_cell(K, u, p, t, oln, oln, (i, j, k), T))
        end
    else
        @inbounds for idxs in Iterators.product(rg...)
            oln = b
            for d in 1:nd; oln += idxs[d]*st[d]; end
            mi = (idxs[1], nd >= 2 ? idxs[2] : 1, nd >= 3 ? idxs[3] : 1)
            du = _oop_store(du, oln, _eval_cell(K, u, p, t, oln, oln, mi, T))
        end
    end
    return du
end

# ---- The vectorized (traceable) acc form ------------------------------------
#
# Per-kernel host-side lane index, built ONCE at closure build: the output slots
# in the EXACT `_run_acc_kernel!` cell order, the loop multi-index per lane, and
# — per access descriptor — either a precomputed state-gather slot vector, a
# frozen const lane vector, or (for a LIVE forcing box) the flat indices to
# re-gather per call. All `Int`/`Float64` host data: under tracing these are the
# constant index sets a gather/scatter op wants, never traced values.
struct _OopAccPlan
    vectorizable::Bool
    out_slots::Vector{Int}
    gathers::Vector{Vector{Int}}      # per descriptor: state gather slots (empty otherwise)
    consts::Vector{Vector{Float64}}   # per descriptor: frozen lane values (empty otherwise)
    forc::Vector{Vector{Int}}         # per descriptor: LIVE forcing flat indices (empty otherwise)
    ghost::Vector{Vector{Bool}}       # per descriptor: ghost-lane mask for a STATE_TBL_BOX with
                                      # a 0 slot (empty ⇒ no ghost); true lanes select 0.0 after
                                      # a gather at a SAFE index (see _build_oop_acc_plan)
    # Template-body sub-kernels (compile-once tier, `_NK_SUBCALL`): the parent's
    # FLAT transitive `K.subs` list and, aligned with it, each sub-kernel's own
    # lane plan built against the PARENT's lane enumeration (a sub is evaluated at
    # the parent's `(c,n,oln,midx)`, so its descriptors index by the parent lanes).
    # Empty for every reference-free kernel. Nested subs are all present here
    # (K.subs is transitive), so a `_NK_SUBCALL` in a sub's spine resolves against
    # this same list. A sub whose spine does not vectorize forces `vectorizable`
    # false on the whole parent.
    subs::Vector{_AccKernel}
    sub_plans::Vector{_OopAccPlan}
    # Variable-valence reduction (`_NK_REDUCE` + `_VarBound`/`_FixedBound`,
    # `_AK_STATE_INDIRECT[_COL]` / `_AK_CONST_EDGE`), CSR-segmented (gordian
    # reduce-vectorize): `red_seg` is the row-pointer vector (length N+1, so cell
    # `c`'s neighbour entries are `red_seg[c]:red_seg[c+1]-1` in the flat E-lane
    # buffers), and `red_plan[1]` is the body's descriptor plan resolved at E-lane
    # (per-entry `(c,n)`) granularity. Empty ⇒ this kernel carries no reduce. The
    # E-lane gather is the ONLY state access; the segment fold runs on the gathered
    # host buffer in child (CSR) order — bit-identical to `_eval_acc`'s seeded fold.
    red_seg::Vector{Int}
    red_plan::Vector{_OopAccPlan}
end
const _OOP_ACC_FALLBACK =
    _OopAccPlan(false, Int[], Vector{Int}[], Vector{Float64}[], Vector{Int}[], Vector{Bool}[],
                _AccKernel[], _OopAccPlan[], Int[], _OopAccPlan[])

# Identity lookup of a sub-kernel in the parent plan's flat transitive list.
@inline function _oop_sub_index(subs::Vector{_AccKernel}, S::_AccKernel)
    @inbounds for j in eachindex(subs)
        subs[j] === S && return j
    end
    throw(TreeWalkError("E_TREEWALK_ACC_SUBCALL_UNKNOWN",
        "vectorized oop: a _NK_SUBCALL references a sub-kernel absent from the " *
        "parent's transitive K.subs list — a `_collect_subkernels` invariant break."))
end

# Lane enumeration mirroring `_run_acc_kernel!` / `_run_box_kernel!` order.
function _oop_acc_lanes(cs::_CellSet)
    if _is_outs(cs)
        # Indirect out slots: the cell ORDINAL rides m1 (the box-addressed
        # per-cell tables index by it, s1=1/off=1), `out` is the slot list.
        L = length(cs.outs)
        return copy(cs.outs), collect(1:L), fill(1, L), fill(1, L)
    end
    if _is_contig(cs)
        rng = cs.ranges[1]
        out = collect(Int, rng)
        return out, copy(out), fill(1, length(out)), fill(1, length(out))
    end
    st = cs.strides; rg = cs.ranges; b = cs.base; nd = length(st)
    L = prod(length, rg)
    out = Vector{Int}(undef, L); m1 = Vector{Int}(undef, L)
    m2 = fill(1, L); m3 = fill(1, L)
    q = 0
    @inbounds for idxs in Iterators.product(rg...)
        q += 1
        oln = b
        for d in 1:nd; oln += idxs[d]*st[d]; end
        out[q] = oln
        m1[q] = idxs[1]
        nd >= 2 && (m2[q] = idxs[2])
        nd >= 3 && (m3[q] = idxs[3])
    end
    return out, m1, m2, m3
end

# The descriptor kinds the E-lane (in-reduce) plan builder can resolve per entry
# `(c,n)`. The n-indexed kinds (`_AK_STATE_INDIRECT[_COL]`, `_AK_CONST_EDGE`) are
# ONLY meaningful inside a reduce; the affine/cell/invariant kinds broadcast a
# cell value across the cell's segment. Box/forcing/tbl kinds are left to the
# per-cell fallback (they need a per-entry `midx` the CSR layout does not carry).
@inline _oop_reduce_desc_ok(ak::UInt8) =
    ak === _AK_STATE_AFFINE || ak === _AK_STATE_INDIRECT ||
    ak === _AK_STATE_INDIRECT_COL || ak === _AK_CONST_EDGE ||
    ak === _AK_CONST_CELL || ak === _AK_CONST_AFFINE ||
    ak === _AK_SCALAR || ak === _AK_STATE_FIXED || ak === _AK_ARR_FIXED ||
    ak === _AK_LOOP_IDX

# Can the whole spine (plus CSE recipes) evaluate as lane vectors? A `_NK_CACHED`
# must resolve to THIS kernel's scratch tiers. (Ghost-bearing STATE_TBL_BOX no
# longer declines — gordian total-vectorize closed it via gather-then-select; the
# sub-kernel class no longer declines — gordian subcall-vectorize evaluates each
# template body as its own whole-array op over the parent lanes; a variable-valence
# reduction no longer declines — gordian reduce-vectorize evaluates the body over a
# flat CSR gather and folds each segment in child order, see `_oop_run_acc_vec`.)
# `in_reduce` permits the n-indexed descriptors that only make sense inside a fold.
_oop_acc_vecable(n::_Node, K::_AccKernel) = _oop_acc_vecable(n, K, false)
function _oop_acc_vecable(n::_Node, K::_AccKernel, in_reduce::Bool)
    k = n.kind
    if k === _NK_REDUCE
        # A reduce vectorizes as a CSR segment fold iff its OUTPUT set is
        # contiguous (so cell ordinal == out slot == lane, the only layout a
        # variable-valence unstructured reduction ever has) and its body's
        # descriptors are all E-lane resolvable. Nested reduces are not modelled.
        in_reduce && return false
        _is_contig(K.cells) || return false
        return _oop_acc_vecable(n.children[1], K, true)
    end
    if k === _NK_SUBCALL
        # A template-body sub-kernel vectorizes iff its OWN spine + CSE recipes do
        # (checked against the SUB's descriptor table — a sub's `_NK_CACHED`
        # resolves to the sub's scratch, not the parent's). Nested subcalls recurse
        # the same way. `K.subs` being transitive means every reachable sub is also
        # planned at the parent, so this check and the plan build agree.
        S = n.payload::_AccKernel
        return _oop_acc_vecable(S.spine, S) &&
               all(r -> _oop_acc_vecable(r, S), S.cse.recipes) &&
               all(r -> _oop_acc_vecable(r, S), S.cse.inv_recipes)
    end
    if k === _NK_ACCESS
        a = K.acc[n.idx]
        ak = a.kind
        if ak === _AK_CONST_EDGE || ak === _AK_STATE_INDIRECT ||
           ak === _AK_STATE_INDIRECT_COL
            # n-indexed: only resolvable inside a CSR segment fold.
            return in_reduce && _oop_reduce_desc_ok(ak)
        end
        # Inside a reduce, restrict to the E-lane-resolvable kinds (box/forcing/tbl
        # need a per-entry midx the CSR layout omits — keep the per-cell fallback).
        in_reduce && !_oop_reduce_desc_ok(ak) && return false
        # An unstructured slot-table gather vectorizes as a plain precomputed
        # gather (gather-of-gather resolved host-side). A ghost slot (0) in the
        # table also vectorizes (gordian total-vectorize): gather at a SAFE index
        # and select 0.0 on the ghost lanes against a host-precomputed mask (see
        # `_build_oop_acc_plan`) — no per-cell fallback, still whole-array only.
        # CONST_CELL addresses by `oln`, which equals the ordinal only for a
        # contiguous set — an indirect-outs kernel would freeze wrong lanes.
        # (The builder never emits it there; this guards hand-built kernels.)
        ak === _AK_CONST_CELL && _is_outs(K.cells) && return false
    elseif k === _NK_CACHED
        (n.payload === K.cse.scratch || n.payload === K.cse.inv_scratch) || return false
    end
    return all(c -> _oop_acc_vecable(c, K, in_reduce), n.children)
end

# Build observability (parallels `_CASCADE_TALLY`): why did an acc kernel decline
# the vectorized oop plan? Returns `:ok`, or the first blocking reason — a
# `_NK_REDUCE` / `_AK_STATE_INDIRECT[_COL]` / `_AK_CONST_EDGE` (the last remaining
# per-cell oop fallback class, a latent IR capability with no production builder).
# Sub-kernels (`_NK_SUBCALL`) are NOT a decline reason — they now vectorize
# (gordian subcall-vectorize) — so the walk recurses into each. Read corpus-wide
# via the `ESS_OOP_PROBE=1` hook in `_make_rhs` (records `:oop_vec` / `:oopdecl_*`
# into the cascade tally).
function _oop_decline_reason(K::_AccKernel)
    r = _oop_decline_walk(K.spine, K)
    r === :ok || return r
    for rec in K.cse.recipes
        rr = _oop_decline_walk(rec, K); rr === :ok || return rr
    end
    for rec in K.cse.inv_recipes
        rr = _oop_decline_walk(rec, K); rr === :ok || return rr
    end
    return :ok
end
function _oop_decline_walk(n::_Node, K::_AccKernel)
    k = n.kind
    if k === _NK_REDUCE
        _is_contig(K.cells) || return :reduce_noncontig
        return _oop_decline_walk(n.children[1], K)   # report the real blocker in the body
    end
    if k === _NK_SUBCALL
        S = n.payload::_AccKernel
        r = _oop_decline_walk(S.spine, S); r === :ok || return r
        for rec in S.cse.recipes
            rr = _oop_decline_walk(rec, S); rr === :ok || return rr
        end
        for rec in S.cse.inv_recipes
            rr = _oop_decline_walk(rec, S); rr === :ok || return rr
        end
        return :ok
    end
    if k === _NK_ACCESS
        ak = K.acc[n.idx].kind
        ak === _AK_CONST_EDGE && return :const_edge
        ak === _AK_STATE_INDIRECT && return :state_indirect
        ak === _AK_STATE_INDIRECT_COL && return :state_indirect_col
        (ak === _AK_CONST_CELL && _is_outs(K.cells)) && return :const_cell_outs
    elseif k === _NK_CACHED
        (n.payload === K.cse.scratch || n.payload === K.cse.inv_scratch) || return :cached
    end
    for c in n.children
        r = _oop_decline_walk(c, K); r === :ok || return r
    end
    return :ok
end

# Resolve one descriptor table's per-lane host data against a GIVEN lane
# enumeration (`out`/`m1`/`m2`/`m3`). Split out of `_build_oop_acc_plan` so a
# template-body sub-kernel — evaluated at the PARENT's lanes — resolves its own
# descriptors against those same parent lanes (its `_contig_cells(0)` carries no
# lanes of its own). Returns the four aligned per-descriptor vectors.
function _build_oop_desc_vectors(acc::Vector{_AccDesc},
                                 out::Vector{Int}, m1::Vector{Int},
                                 m2::Vector{Int}, m3::Vector{Int})
    L = length(out)
    nacc = length(acc)
    gathers = [Int[] for _ in 1:nacc]
    consts  = [Float64[] for _ in 1:nacc]
    forc    = [Int[] for _ in 1:nacc]
    ghost   = [Bool[] for _ in 1:nacc]
    for (i, a) in enumerate(acc)
        k = a.kind
        if k === _AK_STATE_AFFINE
            gathers[i] = out .+ a.delta
        elseif k === _AK_STATE_TBL_BOX
            # Gather-of-gather resolved on host: the per-lane state slot is the
            # box-addressed table entry. A ghost slot (0) — which the in-place
            # tape reads as 0.0 — is gathered at a SAFE index (1, always valid)
            # and masked: the eval selects 0.0 on those lanes, so the trace still
            # sees ONE whole-array gather plus a select against a constant mask.
            raw = Int[@inbounds a.conn[a.off + (m1[l]-1)*a.s1 +
                      (m2[l]-1)*a.s2 + (m3[l]-1)*a.s3] for l in 1:L]
            if any(==(0), raw)
                ghost[i]   = Bool[s == 0 for s in raw]
                gathers[i] = Int[s == 0 ? 1 : s for s in raw]
            else
                gathers[i] = raw
            end
        elseif k === _AK_CONST_AFFINE
            gathers_i = out .+ a.delta
            consts[i] = a.arr[gathers_i]
        elseif k === _AK_CONST_BOX
            consts[i] = Float64[@inbounds a.arr[a.off + (m1[l]-1)*a.s1 +
                                (m2[l]-1)*a.s2 + (m3[l]-1)*a.s3] for l in 1:L]
        elseif k === _AK_FORCING_BOX
            forc[i] = Int[a.off + (m1[l]-1)*a.s1 + (m2[l]-1)*a.s2 + (m3[l]-1)*a.s3
                          for l in 1:L]
        elseif k === _AK_ARR_TBL_BOX
            # LIVE forcing through a per-cell index table: freeze the INDICES
            # (host data), re-gather the aliased buffer per call.
            forc[i] = Int[@inbounds a.conn[a.off + (m1[l]-1)*a.s1 +
                          (m2[l]-1)*a.s2 + (m3[l]-1)*a.s3] for l in 1:L]
        elseif k === _AK_LOOP_IDX
            mi = a.dim === 1 ? m1 : a.dim === 2 ? m2 : m3
            consts[i] = Float64.(mi)
        elseif k === _AK_CONST_CELL
            consts[i] = a.arr[out]        # cell ordinal == oln (see _run_box_kernel!)
        end
        # SCALAR / STATE_FIXED / ARR_FIXED: read directly by the walker.
    end
    return gathers, consts, forc, ghost
end

# CSR row pointers + per-entry (cell, neighbour) tables for a variable-valence
# reduction. Cell `c`'s neighbour entries occupy the flat range
# `seg_off[c]:seg_off[c+1]-1`, in ascending `n` (= child) order — so a per-segment
# fold over the flat E-lane body buffer reproduces `_eval_acc`'s seeded child-order
# sum exactly. `N` is the cell count (== lane count for a contiguous set).
function _oop_reduce_segments(K::_AccKernel, N::Int)
    seg_off = Vector{Int}(undef, N + 1)
    seg_off[1] = 1
    @inbounds for c in 1:N
        seg_off[c+1] = seg_off[c] + _nbrcount(K.bound, c)
    end
    E = seg_off[N+1] - 1
    seg_cell = Vector{Int}(undef, E)
    seg_n    = Vector{Int}(undef, E)
    @inbounds for c in 1:N
        base = seg_off[c] - 1
        for n in 1:_nbrcount(K.bound, c)
            seg_cell[base+n] = c
            seg_n[base+n]    = n
        end
    end
    return seg_off, seg_cell, seg_n
end

# The E-lane (in-reduce) descriptor plan: one value per flat entry `e = (c, n)`.
# The n-indexed kinds resolve per entry; cell/affine/invariant kinds broadcast a
# cell value across the cell's whole segment (matching `_fetch`, which is n-blind
# for them). `out[c]` is cell `c`'s output slot (== c for the contiguous set a
# reduce always has). Only the state kinds produce a `gathers` vector (the sole
# state access, whole-array); everything else is frozen `consts`.
function _build_oop_reduce_desc_vectors(acc::Vector{_AccDesc}, seg_cell::Vector{Int},
                                        seg_n::Vector{Int}, out::Vector{Int})
    E = length(seg_cell)
    nacc = length(acc)
    gathers = [Int[] for _ in 1:nacc]
    consts  = [Float64[] for _ in 1:nacc]
    for (i, a) in enumerate(acc)
        k = a.kind
        if k === _AK_STATE_AFFINE
            gathers[i] = Int[@inbounds out[seg_cell[e]] + a.delta for e in 1:E]
        elseif k === _AK_STATE_INDIRECT
            gathers[i] = Int[@inbounds a.conn[(seg_cell[e]-1)*a.width + seg_n[e]] for e in 1:E]
        elseif k === _AK_STATE_INDIRECT_COL
            gathers[i] = Int[@inbounds a.conn[(seg_cell[e]-1)*a.width + a.col] for e in 1:E]
        elseif k === _AK_CONST_EDGE
            consts[i] = Float64[@inbounds a.arr[(seg_cell[e]-1)*a.width + seg_n[e]] for e in 1:E]
        elseif k === _AK_CONST_CELL
            consts[i] = Float64[@inbounds a.arr[seg_cell[e]] for e in 1:E]   # c == oln (contiguous)
        elseif k === _AK_CONST_AFFINE
            consts[i] = Float64[@inbounds a.arr[out[seg_cell[e]] + a.delta] for e in 1:E]
        elseif k === _AK_LOOP_IDX
            # contiguous reduce: midx == (c, 1, 1); dim 1 → c, higher dims → 1.
            consts[i] = a.dim === 1 ? Float64[Float64(seg_cell[e]) for e in 1:E] : fill(1.0, E)
        end
        # SCALAR / STATE_FIXED / ARR_FIXED: read directly by the walker (scalars,
        # broadcast over the segment). Box/forcing/tbl kinds were declined upstream.
    end
    return gathers, consts
end

# Fold each cell's flat segment of the body buffer, seeded from `zerobar`, in
# ascending (child) order — the byte-for-byte `_NK_REDUCE` sum. `bodyE` is a
# length-E vector (a body with a per-neighbour descriptor) or a bare scalar (a
# body that hoisted lane-invariant); both fold identically.
function _oop_reduce_fold(bodyE, seg::Vector{Int}, zerobar::Float64, ::Type{T}) where {T}
    N = length(seg) - 1
    res = Vector{T}(undef, N)
    z = convert(T, zerobar)
    if bodyE isa AbstractArray
        @inbounds for c in 1:N
            s = z
            for e in seg[c]:(seg[c+1]-1)
                s += bodyE[e]
            end
            res[c] = s
        end
    else
        @inbounds for c in 1:N
            s = z
            for _ in seg[c]:(seg[c+1]-1)
                s += bodyE
            end
            res[c] = s
        end
    end
    return res
end

function _build_oop_acc_plan(K::_AccKernel)
    ok = _oop_acc_vecable(K.spine, K) &&
         all(r -> _oop_acc_vecable(r, K), K.cse.recipes) &&
         all(r -> _oop_acc_vecable(r, K), K.cse.inv_recipes)
    ok || return _OOP_ACC_FALLBACK
    out, m1, m2, m3 = _oop_acc_lanes(K.cells)
    gathers, consts, forc, ghost = _build_oop_desc_vectors(K.acc, out, m1, m2, m3)
    # Template-body sub-kernels (`K.subs`, transitive/nested-first): each is
    # evaluated at the parent's `(c,n,oln,midx)`, so resolve its descriptor tables
    # against the PARENT's lane enumeration. `_oop_acc_vecable` already accepted
    # every `_NK_SUBCALL` above (recursing into each sub), so the subs vectorize by
    # construction; build their aligned lane plans here so the walker can splice
    # each variant's whole-array result into the parent operand stream.
    subs = K.subs
    sub_plans = _OopAccPlan[]
    if !isempty(subs)
        sub_plans = Vector{_OopAccPlan}(undef, length(subs))
        for j in eachindex(subs)
            S = subs[j]
            sg, sc, sf, sgh = _build_oop_desc_vectors(S.acc, out, m1, m2, m3)
            # A sub carries no cells of its own; `out_slots` is unused for a sub
            # (only the top-level plan scatters), so reuse the parent lane slots.
            sub_plans[j] = _OopAccPlan(true, out, sg, sc, sf, sgh,
                                       _AccKernel[], _OopAccPlan[], Int[], _OopAccPlan[])
        end
    end
    # Variable-valence reduction: build the CSR segments + the E-lane body plan.
    # `_build_acc_cse` never CSE's a reduce spine, so the reduce sits directly on
    # `K.spine` (no recipes carry one) and there is exactly one to model.
    red_seg = Int[]
    red_plan = _OopAccPlan[]
    if _acc_has_reduce(K.spine)
        N = length(out)
        seg_off, seg_cell, seg_n = _oop_reduce_segments(K, N)
        eg, ec = _build_oop_reduce_desc_vectors(K.acc, seg_cell, seg_n, out)
        nacc = length(K.acc)
        red_seg = seg_off
        red_plan = _OopAccPlan[_OopAccPlan(true, Int[], eg, ec,
                        [Int[] for _ in 1:nacc], [Bool[] for _ in 1:nacc],
                        _AccKernel[], _OopAccPlan[], Int[], _OopAccPlan[])]
    end
    return _OopAccPlan(true, out, gathers, consts, forc, ghost, subs, sub_plans,
                       red_seg, red_plan)
end

# Per-call runtime context for template-body sub-kernels (`_NK_SUBCALL`). Holds
# the parent plan's flat transitive sub list + aligned build-time lane plans (for
# identity lookup), and per-sub CSE tier buffers allocated ONCE per call: the
# invariant tier filled by the runner prologue, the per-cell tier refilled at each
# subcall site (matching the scalar `_NK_SUBCALL`, which re-fills per cell). Empty
# for every reference-free kernel (`_OOP_NO_SUB`, shared and never mutated).
struct _OopSubRT
    subs::Vector{_AccKernel}
    plans::Vector{_OopAccPlan}
    invvals::Vector{Vector{Any}}
    cellvals::Vector{Vector{Any}}
end
const _OOP_NO_SUB = _OopSubRT(_AccKernel[], _OopAccPlan[], Vector{Any}[], Vector{Any}[])

# The lane walker: value-returning, whole-array, routed through the same seams
# as the `_VecNode` walker — a lane-varying node yields a length-L vector, a
# lane-invariant one a bare scalar, and broadcast makes them interchangeable.
# `cellvals`/`invvals` are this call's CSE tier results (the out-of-place
# expression of the scratch buffers) for kernel `K`, filled in slot order by the
# caller; `sub` is the parent-scoped sub-kernel runtime (constant across the whole
# walk — a `_NK_SUBCALL` looks its sub up there, never in the descending `K`/`plan`).
function _oop_eval_acck(nd::_Node, u, p, t, K::_AccKernel, plan::_OopAccPlan,
                        invvals::Vector{Any}, cellvals::Vector{Any},
                        sub::_OopSubRT, ::Type{T}) where {T}
    k = nd.kind
    if k === _NK_ACCESS
        a = K.acc[nd.idx]
        ak = a.kind
        if ak === _AK_STATE_AFFINE || ak === _AK_STATE_INDIRECT ||
           ak === _AK_STATE_INDIRECT_COL
            # STATE_AFFINE gathers by `out.+delta`; the two n-indexed kinds only
            # appear inside a CSR reduce, where `plan` is the E-lane plan and
            # `gathers` already holds the per-entry `conn[(c-1)*width+n]` slots.
            # (`_AK_CONST_EDGE` falls through to the frozen-consts arm below.)
            return _oop_gather(u, plan.gathers[nd.idx])
        elseif ak === _AK_STATE_TBL_BOX
            g = _oop_gather(u, plan.gathers[nd.idx])
            m = plan.ghost[nd.idx]
            # ghost lanes (table slot 0) select 0.0 — the in-place tape's
            # `s == 0 ? 0.0 : u[s]`, bit-identical; the gather used a safe index.
            return isempty(m) ? g : ifelse.(m, zero(T), g)
        elseif ak === _AK_STATE_FIXED
            return convert(T, _oop_read_state(u, a.idx))
        elseif ak === _AK_SCALAR
            return convert(T, a.v)
        elseif ak === _AK_ARR_FIXED
            # LIVE forcing (invariant slot): re-read per call — data, zero derivative.
            return convert(T, @inbounds a.arr[a.idx])
        elseif ak === _AK_FORCING_BOX || ak === _AK_ARR_TBL_BOX
            # LIVE forcing lanes: re-gathered from the aliased buffer per call.
            return @inbounds a.arr[plan.forc[nd.idx]]
        else
            # CONST_AFFINE / CONST_BOX / LOOP_IDX / CONST_CELL: frozen lane data.
            return plan.consts[nd.idx]
        end
    elseif k === _NK_LITERAL
        return convert(T, nd.literal)
    elseif k === _NK_PARAM
        return convert(T, getfield(p, nd.sym))
    elseif k === _NK_TIME
        return convert(T, t)
    elseif k === _NK_CACHED
        return nd.payload === K.cse.scratch ? (@inbounds cellvals[nd.idx]) :
                                              (@inbounds invvals[nd.idx])
    elseif k === _NK_SUBCALL
        # Template-body sub-kernel: evaluate its spine as its OWN whole-array op
        # over the PARENT's lanes (its descriptors were resolved against them in
        # `_build_oop_acc_plan`), splicing the lane-aligned result in here. The
        # invariant tier was filled once this call by the runner prologue; refill
        # the per-cell tier now — the same per-subcall fill the scalar path does.
        S = nd.payload::_AccKernel
        j = _oop_sub_index(sub.subs, S)
        Sp = @inbounds sub.plans[j]
        iv = @inbounds sub.invvals[j]
        cv = @inbounds sub.cellvals[j]
        rs = S.cse.recipes
        @inbounds for i in eachindex(rs)
            cv[i] = _oop_eval_acck(rs[i], u, p, t, S, Sp, iv, cv, sub, T)
        end
        return _oop_eval_acck(S.spine, u, p, t, S, Sp, iv, cv, sub, T)
    elseif k === _NK_REDUCE
        # Variable-valence sum reduction, CSR-segmented (gordian reduce-vectorize):
        # evaluate the body ONCE over the flat E-lane buffer (its only state access
        # is the whole-array gather in the E-plan), then fold each cell's segment
        # SEQUENTIALLY in child (CSR) order, seeded from `zerobar` — bit-identical
        # to `_eval_acc`'s `s = zerobar; for m in 1:cnt; s += body(c,m)`.
        Ep = @inbounds plan.red_plan[1]
        bodyE = _oop_eval_acck(nd.children[1], u, p, t, K, Ep, invvals, cellvals, sub, T)
        return _oop_reduce_fold(bodyE, plan.red_seg, K.zerobar, T)
    elseif k === _NK_CONTRACTION
        # Fixed-width ⊕-fold over lane vectors, seeded from the 0̄ identity —
        # ((0̄ ⊕ c1) ⊕ c2)… in child order, broadcast per lane: the same fold
        # `_eval_acc_contraction` runs per cell.
        op = nd.op
        ch = nd.children
        res::Any = nd.literal     # scalar seed; the first broadcast promotes it
        if op === :+
            for i in eachindex(ch)
                res = res .+ _oop_eval_acck(ch[i], u, p, t, K, plan, invvals, cellvals, sub, T)
            end
        elseif op === :*
            for i in eachindex(ch)
                res = res .* _oop_eval_acck(ch[i], u, p, t, K, plan, invvals, cellvals, sub, T)
            end
        elseif op === :max
            for i in eachindex(ch)
                res = max.(res, _oop_eval_acck(ch[i], u, p, t, K, plan, invvals, cellvals, sub, T))
            end
        else  # :min
            for i in eachindex(ch)
                res = min.(res, _oop_eval_acck(ch[i], u, p, t, K, plan, invvals, cellvals, sub, T))
            end
        end
        return res
    else # _NK_OP
        op = nd.op
        ch = nd.children
        if op === :fn
            return _oop_acck_fn(nd, u, p, t, K, plan, invvals, cellvals, sub, T)
        elseif (op === :^ || op === :pow) && length(ch) == 2
            # A literal exponent stays a literal — see `_oop_pow`.
            base = _oop_eval_acck(ch[1], u, p, t, K, plan, invvals, cellvals, sub, T)
            e = ch[2]
            return e.kind === _NK_LITERAL ? base .^ e.literal :
                   base .^ _oop_eval_acck(e, u, p, t, K, plan, invvals, cellvals, sub, T)
        end
        c = Vector{Any}(undef, length(ch))
        for i in eachindex(ch)
            c[i] = _oop_eval_acck(ch[i], u, p, t, K, plan, invvals, cellvals, sub, T)
        end
        return _oop_op(op, c, T)
    end
end

function _oop_acck_fn(nd::_Node, u, p, t, K::_AccKernel, plan::_OopAccPlan,
                      invvals::Vector{Any}, cellvals::Vector{Any},
                      sub::_OopSubRT, ::Type{T}) where {T}
    pl = nd.payload
    ch = nd.children
    ev(x) = _oop_eval_acck(x, u, p, t, K, plan, invvals, cellvals, sub, T)
    if pl isa Tuple{String,_InterpLinearSpec}
        return _oop_interp_linear_lanes(pl[2], ev(ch[1]), T)
    elseif pl isa Tuple{String,_InterpBilinearSpec}
        return _oop_interp_bilinear_lanes(pl[2], ev(ch[1]), ev(ch[2]), T)
    elseif pl isa Tuple{String,_InterpSearchsortedSpec}
        return _oop_interp_searchsorted_lanes(pl[2], ev(ch[1]), T)
    elseif pl isa Tuple{String,Nothing}
        # All-scalar closed functions (`datetime.*`): boxed, one call per lane —
        # host-correct; a trace fails loudly inside the opaque callee.
        fname = pl[1]
        cv = Any[ev(ci) for ci in ch]
        return broadcast((as...) -> convert(T, _eval_closed_fn(fname, Any[as...], T)),
                         cv...)
    end
    throw(TreeWalkError("E_TREEWALK_UNKNOWN_CLOSED_FUNCTION",
        "fn payload $(typeof(pl)) is neither a typed interp spec tuple nor (String, Nothing)"))
end

# Run one vectorized acc kernel: sub-kernel invariant tiers first (once per call,
# in nested-first `K.subs` order — the prologue the in-place runner also runs),
# then K's own CSE tiers in slot order (invariant scalars first), the spine over
# whole lanes, and ONE scatter.
function _oop_run_acc_vec(du, u, p, t, K::_AccKernel, plan::_OopAccPlan,
                          ::Type{T}) where {T}
    sub = _oop_build_subrt(plan)
    for j in eachindex(sub.subs)
        S = @inbounds sub.subs[j]
        Sp = @inbounds sub.plans[j]
        iv = @inbounds sub.invvals[j]; cv = @inbounds sub.cellvals[j]
        ir = S.cse.inv_recipes
        @inbounds for i in eachindex(ir)
            iv[i] = _oop_eval_acck(ir[i], u, p, t, S, Sp, iv, cv, sub, T)
        end
    end
    cse = K.cse
    invvals = Vector{Any}(undef, length(cse.inv_recipes))
    cellvals = Vector{Any}(undef, length(cse.recipes))
    for i in eachindex(cse.inv_recipes)
        invvals[i] = _oop_eval_acck(cse.inv_recipes[i], u, p, t, K, plan,
                                    invvals, cellvals, sub, T)
    end
    for i in eachindex(cse.recipes)
        cellvals[i] = _oop_eval_acck(cse.recipes[i], u, p, t, K, plan,
                                     invvals, cellvals, sub, T)
    end
    res = _oop_eval_acck(K.spine, u, p, t, K, plan, invvals, cellvals, sub, T)
    return _oop_scatter(du, plan.out_slots, res)
end

# Allocate the per-call sub-kernel runtime (empty ⇒ the shared no-op singleton).
function _oop_build_subrt(plan::_OopAccPlan)
    subs = plan.subs
    isempty(subs) && return _OOP_NO_SUB
    invvals  = Vector{Vector{Any}}(undef, length(subs))
    cellvals = Vector{Vector{Any}}(undef, length(subs))
    @inbounds for j in eachindex(subs)
        S = subs[j]
        invvals[j]  = Vector{Any}(undef, length(S.cse.inv_recipes))
        cellvals[j] = Vector{Any}(undef, length(S.cse.recipes))
    end
    return _OopSubRT(subs, plan.sub_plans, invvals, cellvals)
end

function _make_rhs_oop(rhs_list::AbstractVector{Tuple{Int,_Node}},
                       cse_prelude::AbstractVector{_Node},
                       acc_kernels::AbstractVector{_AccKernel},
                       n_states::Int)
    n_cse = length(cse_prelude)
    # J5 covers BOTH IR families: the `_NK_PARAM_GATHER` scalar scan and the
    # acc-descriptor scan (`_AK_FORCING_BOX`/`_AK_ARR_FIXED`/`_AK_ARR_TBL_BOX`)
    # — an affine build over live forcing must refuse a trace all the same.
    live_forcing = _has_live_forcing(cse_prelude, rhs_list) ||
                   any(_acc_has_live_forcing, acc_kernels)
    # Vectorized lane plans for the acc kernels (host index data, built once).
    acc_plans = _OopAccPlan[_build_oop_acc_plan(K) for K in acc_kernels]
    function f(u, p, t)
        _reject_float32_state(u)   # loud, statically-folded (see compile.jl)
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

        # Access kernels (the unified array IR), out of place. The vectorized form
        # (whole-array gathers/ops, one scatter — the TRACEABLE form) where the
        # plan permits; the per-cell `_oop_store` walk otherwise. On host both
        # produce the values `f!`'s in-place runners write, in the same slots, so
        # a Float64 `:oop` run stays bit-identical to `:inplace`.
        for j in eachindex(acc_kernels)
            plan = acc_plans[j]
            du = plan.vectorizable ?
                 _oop_run_acc_vec(du, u, p, t, acc_kernels[j], plan, T) :
                 _oop_run_acc_kernel(du, u, p, t, acc_kernels[j], T)
        end
        return du
    end
    return f
end
