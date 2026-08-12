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

# ---- Read interning, TRACE ONLY (ess-oop-intern) -----------------------------
#
# The SAME window of the SAME container is read many times inside one RHS
# evaluation: a materialized array observed lives in the flat extended state
# tensor `ue`, and every acc-kernel descriptor that reads it emits its own read.
# Measured on ReSEACT at 7x7x16, one chemistry RHS emitted 478 `stablehlo.slice`
# ops over just 123 DISTINCT windows (~3.9x), and the whole module 8,093 slices
# of which 4,928 (60.9%) were exact `(operand, window)` duplicates. XLA then
# rediscovers that they are duplicates with `CSE<stablehlo::SliceOp>`, a PAIRWISE
# (quadratic) pattern that a `perf` profile of a stuck CONUS compile put at ~50%
# of all CPU. Emitting the read once removes the duplicate before it exists.
#
# WHY THIS IS A THIRD ARGUMENT AND NOT A GLOBAL. The memo has to die with the
# trace that created it: an SSA value from a finished module is not usable in the
# next one. So it is carried by `_OopForcing`, which `_make_rhs_oop`'s closure
# constructs FRESH on every call and threads to every read site — the memo's
# lifetime is then exactly one RHS invocation, by construction. Nothing to tear
# down, nothing to leak on an exception, nothing shared between threads, and no
# way for one trace's values to reach another. It is also the largest scope that
# is SOUND: a trace of a `@trace for` body puts the RHS's ops in a nested REGION,
# and a value defined in one region does not dominate a use in the next, so a
# memo living longer than one invocation could emit IR that does not verify.
#
# WHY IT IS TRACE-ONLY. On host the containers are MUTATED IN PLACE — `_oop_store`
# and `_oop_scatter` write and return the same array — so a read cache keyed on
# container identity would hand back pre-write data. Under a trace the writes are
# FUNCTIONAL: `setindex!` on a `TracedRArray` rebinds the object's MLIR value, so
# "which SSA value is this container right now" is a complete description of its
# CONTENTS, and that is what the extension keys on. Host therefore builds NO memo
# (`_oop_new_memo` returns `nothing`) and `_oop_gather(u, slots, ::Nothing)` is
# the two-argument gather verbatim — the host path is byte-identical.
#
# `ESS_OOP_INTERN=0` declines the memo (the extension's `_oop_new_memo` then also
# returns `nothing`), so a traced build can be compared with the feature off.
@inline _oop_gather(u, slots::Vector{Int}, ::Nothing) = _oop_gather(u, slots)
@inline _oop_gather(u, slots::Vector{Int}, memo) = _oop_gather(u, slots)

# The memo constructor seam. `nothing` on host and under every non-tracing
# element type (`Dual`, `Float32`, …); the Reactant extension adds the one method
# that returns a real memo, for a `TracedRArray` state.
@inline _oop_new_memo(u) = nothing

# Engagement witness. Trace-time only — the host path never reaches it — and a
# COUNTER, not a cache: nothing is ever read back out of it by the walker, so it
# carries no correctness weight. It exists so a test can assert that interning
# actually fired rather than silently regressing to a no-op, and so a probe can
# report the hit rate on a real model.
const _OOP_INTERN_TALLY = Int[0, 0]      # [hits, misses]

@inline function _oop_intern_tally!(hit::Bool)
    @inbounds _OOP_INTERN_TALLY[hit ? 1 : 2] += 1
    return nothing
end

"""
    oop_intern_stats() -> (; hits, misses)

Cumulative `(tensor, window)` read-interning counters for the out-of-place
emitter's TRACED path (ess-oop-intern): `hits` is the number of reads served
from a memo instead of emitting an op, `misses` the number that emitted one.
Both are zero on host — interning is trace-only — and zero when
`ESS_OOP_INTERN=0`. Reset with [`oop_intern_stats_reset!`](@ref).
"""
oop_intern_stats() = (hits = @inbounds(_OOP_INTERN_TALLY[1]),
                      misses = @inbounds(_OOP_INTERN_TALLY[2]))

"""
    oop_intern_stats_reset!()

Zero the [`oop_intern_stats`](@ref) counters.
"""
function oop_intern_stats_reset!()
    @inbounds _OOP_INTERN_TALLY[1] = 0
    @inbounds _OOP_INTERN_TALLY[2] = 0
    return nothing
end

# One SCALAR element of a live forcing buffer (an `_NK_PARAM_GATHER` node or an
# invariant `_AK_ARR_FIXED` descriptor). A seam for the same reason
# `_oop_read_state` is: on host it is the indexed load it reads as; a tracing
# backend must replace it, because scalar indexing of a traced array is rejected
# outright. Bounded exactly like `_oop_read_state` — O(#scalar forcing reads),
# never O(#cells); a forcing LANE goes through `_oop_gather`, which is a
# whole-array op and needs no method.
@inline _oop_read_forcing(buf, i::Int) = @inbounds buf[i]

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

# Seed the extended vector's STATE prefix from `u`, for the materialized-observed
# prelude. A third member of the family above, and a seam for the same reason: on
# host this is one `copyto!`, but a tracing backend needs it as ONE slice
# operation rather than `n` scalar stores — the per-element form would put the
# state size into the XLA program, which is the property the compiled IR exists
# to avoid. Returns `ue` so a backend can implement it functionally.
@inline function _oop_prefix_copy(ue, u, n::Int)
    @inbounds copyto!(ue, 1, u, 1, n)
    return ue
end

# A fill body carries no CSE prelude (`_materialized_fill_equation` compiles
# straight through `_compile`), but `_oop_eval` still takes a cache. One empty
# vector per value type, allocated once at call time rather than per level.
@inline _EMPTY_OOP_CACHE(::Type{T}) where {T} = Vector{T}(undef, 0)

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

# ---- interp knot addressing: the seams a TRACER replaces --------------------
#
# The three primitive shapes the lane forms below are built from, factored out
# as SEAMS for exactly the reason `_oop_read_state` is one: the branch-free
# select-ladder lowering is RIGHT for host / ForwardDiff — a handful of fused
# broadcasts over a 2–3 knot table, no branch, no allocation per knot — and
# catastrophically WRONG for a tracer on a big table, where every ladder step is
# a separate traced op and the emitted program is O(table) PER CALL SITE.
#
# Measured, one `interp.bilinear` on a 61×23 table over 392 lanes: the ladder
# traces to 76,593 stablehlo ops (5,524 `select` + 2,806 `compare` + 1,319 `and`
# and their broadcast/constant scaffolding), in 74 s. The ReSEACT Fast-JX
# component has 18 such calls; across the traced operator-split window's ~120
# RHS call sites that reached 21.4M ops and the XLA compile was OOM-killed at
# 30 GB. >90% of that program was ladder scaffolding; real arithmetic was <1%.
#
# A tracer has a constant-time primitive for precisely this — `stablehlo.gather`
# on a constant table, and a `reduce` for the count — so a backend replaces the
# three ladders HERE rather than forking the three lane evaluators. What a
# backend method must honour, bit-for-bit:
#
#   `_oop_knot_count(knots, q, cmp)`   Σ_k [cmp(knots[k], q)] as a Float64 lane
#         value. The terms are 0.0/1.0 and n ≪ 2^53, so the sum is EXACT in any
#         association order: a `reduce` is bit-identical to the ladder's
#         left-to-right `.+` chain, for every query including NaN (which fails
#         every compare and contributes 0.0 in both).
#   `_oop_knot_pair(v, i)`             `(v[i], v[i+1])` elementwise, `i` an
#         exactly-integral Float64 lane index in `[1, length(v)-1]`. SELECTION,
#         never a blend — the table entry comes through bit-exact (no `0·Inf`,
#         no signed-zero surprise), which a gather also gives by construction.
#   `_oop_knot_pair2(a, b, i)`         the same, for two same-length tables at
#         one index, sharing the ladder's compares (the linear evaluator's
#         axis+table pair; kept fused so the host op count is UNCHANGED).
#   `_oop_bilinear_corners(tbl, i, j, Nx, Ny)`  the four `tbl[i+a][j+b]`,
#         `a,b ∈ {0,1}`, same selection contract, `i ∈ [1,Nx-1]`, `j ∈ [1,Ny-1]`.
#
# `knots`/`v`/`a`/`b` is a `Vector{Float64}` (one table shared by every lane) or
# a `Vector{Vector{Float64}}` of lane COLUMNS (`_Interp*LaneSpec`, one table per
# lane, `col[k][l]`); `tbl` is `Vector{Vector{Float64}}` (scalar spec,
# `tbl[k][l]`) or a `Matrix{Vector{Float64}}` of lane columns (`tbl[k,l][lane]`).
# Both are build-time host constants either way, so a backend can materialize
# them as constant tensors. `_oop_knot_at` is the one place that difference is
# read, so a backend's methods need not repeat it.
@inline _oop_knot_at(v::AbstractVector{Float64}, k::Int) = @inbounds v[k]
@inline _oop_knot_at(v::AbstractVector{Vector{Float64}}, k::Int) = @inbounds v[k]
@inline _oop_tbl_at(t::Vector{Vector{Float64}}, k::Int, l::Int) = @inbounds t[k][l]
@inline _oop_tbl_at(t::Matrix{Vector{Float64}}, k::Int, l::Int) = @inbounds t[k, l]

@inline function _oop_knot_count(knots, q, cmp::F) where {F}
    n = length(knots)
    cnt = ifelse.(cmp.(_oop_knot_at(knots, 1), q), 1.0, 0.0)
    for k in 2:n
        cnt = cnt .+ ifelse.(cmp.(_oop_knot_at(knots, k), q), 1.0, 0.0)
    end
    return cnt
end

@inline function _oop_knot_pair(v, i)
    n = length(v)
    lo = _oop_knot_at(v, 1) .+ zero.(i)
    hi = _oop_knot_at(v, 2) .+ zero.(i)
    for k in 2:(n - 1)
        sel = i .== Float64(k)
        lo = ifelse.(sel, _oop_knot_at(v, k),     lo)
        hi = ifelse.(sel, _oop_knot_at(v, k + 1), hi)
    end
    return lo, hi
end

@inline function _oop_knot_pair2(a, b, i)
    n = length(a)
    alo = _oop_knot_at(a, 1) .+ zero.(i); ahi = _oop_knot_at(a, 2) .+ zero.(i)
    blo = _oop_knot_at(b, 1) .+ zero.(i); bhi = _oop_knot_at(b, 2) .+ zero.(i)
    for k in 2:(n - 1)
        sel = i .== Float64(k)
        alo = ifelse.(sel, _oop_knot_at(a, k),     alo)
        ahi = ifelse.(sel, _oop_knot_at(a, k + 1), ahi)
        blo = ifelse.(sel, _oop_knot_at(b, k),     blo)
        bhi = ifelse.(sel, _oop_knot_at(b, k + 1), bhi)
    end
    return alo, ahi, blo, bhi
end

@inline function _oop_bilinear_corners(tbl, i, j, Nx::Int, Ny::Int)
    z = zero.(i .+ j)
    t_ij    = _oop_tbl_at(tbl, 1, 1) .+ z; t_i1j   = _oop_tbl_at(tbl, 2, 1) .+ z
    t_ijp1  = _oop_tbl_at(tbl, 1, 2) .+ z; t_i1jp1 = _oop_tbl_at(tbl, 2, 2) .+ z
    for k in 1:(Nx - 1), l in 1:(Ny - 1)
        (k == 1 && l == 1) && continue
        sel = (i .== Float64(k)) .& (j .== Float64(l))
        t_ij    = ifelse.(sel, _oop_tbl_at(tbl, k,     l),     t_ij)
        t_i1j   = ifelse.(sel, _oop_tbl_at(tbl, k + 1, l),     t_i1j)
        t_ijp1  = ifelse.(sel, _oop_tbl_at(tbl, k,     l + 1), t_ijp1)
        t_i1jp1 = ifelse.(sel, _oop_tbl_at(tbl, k + 1, l + 1), t_i1jp1)
    end
    return t_ij, t_i1j, t_ijp1, t_i1jp1
end

# ---- interp.* over whole LANES: locate → gather → blend ----------------------
#
# The de-scalarized interp forms the affine access-kernel path evaluates (and the
# forms an XLA/Reactant trace needs): NO branch on the query, NO opaque scalar
# core inside a broadcast — every step is elementwise arithmetic + a knot-
# addressing seam, so a traced query lane vector flows through as whole-array ops
# and the emitted program's size is independent of the GRID. (It is independent
# of the TABLE too, but only on a backend that gives the seams above a gather;
# the default lowering is the O(table) select ladder — see the seam header.)
#
# BIT-IDENTICAL to the scalar cores, by mirroring their decision trees with
# `ifelse` selects instead of branches:
#   * locate: `i = clamp(Σ_k [axis[k] ≤ x], 1, n-1)` — for a validated strictly-
#     increasing axis this is exactly the scan's "largest k with axis[k] ≤ x".
#   * gather: `_oop_knot_pair` / `_oop_bilinear_corners` SELECT (never blend)
#     the cell's endpoints, so table entries come through exactly (no `0·Inf`, no
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
    cnt = _oop_knot_count(axis, q, <=)
    i = min.(max.(cnt, 1.0), Float64(n - 1))
    ai, ai1, ti, ti1 = _oop_knot_pair2(axis, table, i)
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
    r = _oop_knot_count(xs, q, <) .+ 1.0
    return ifelse.(q .!= q, Float64(n + 1), r)
end

function _oop_interp_bilinear_lanes(h::_InterpBilinearSpec, x, y, ::Type{T}) where {T}
    ax = h.axis_x; ay = h.axis_y; table = h.table
    Nx = length(ax); Ny = length(ay)
    # Per-axis clamp of the QUERY (the core's x_q/y_q), then count-locate.
    x_q = ifelse.(x .<= ax[1], ax[1], ifelse.(x .>= ax[Nx], ax[Nx], x))
    y_q = ifelse.(y .<= ay[1], ay[1], ifelse.(y .>= ay[Ny], ay[Ny], y))
    i = min.(max.(_oop_knot_count(ax, x_q, <=), 1.0), Float64(Nx - 1))
    j = min.(max.(_oop_knot_count(ay, y_q, <=), 1.0), Float64(Ny - 1))
    xi, xip1 = _oop_knot_pair(ax, i)
    yj, yjp1 = _oop_knot_pair(ay, j)
    t_ij, t_i1j, t_ijp1, t_i1jp1 = _oop_bilinear_corners(table, i, j, Nx, Ny)
    wx = (x_q .- xi) ./ (xip1 .- xi)
    wy = (y_q .- yj) ./ (yjp1 .- yj)
    row_j   = t_ij   .+ wx .* (t_i1j   .- t_ij)
    row_jp1 = t_ijp1 .+ wx .* (t_i1jp1 .- t_ijp1)
    return row_j .+ wy .* (row_jp1 .- row_j)
end

# ---- interp.* with PER-LANE spec tables (kernel-class merge) -----------------
#
# The lane-tabled twins of the three evaluators above, for a merged kernel
# class whose members carry DIFFERENT same-shape interp tables
# (`_Interp*LaneSpec`, registered_functions.jl). Same locate → gather → blend
# through the SAME seams, with every scalar knot read (`axis[k]` / `table[k]` /
# `xs[k]`) replaced by its length-L lane COLUMN (`col[k][l] == specs[l].…[k]`).
# All the selects are elementwise, so lane `l` computes exactly what the
# scalar-spec evaluator computes on `specs[l]` — bit-identical to the unmerged
# kernels by construction. The columns are host `Vector{Float64}` constants, so
# a Reactant trace embeds them as constant tensors exactly like scalar knots,
# and the emitted program stays independent of the lane count's origin. `q` may
# be a lane vector OR an invariant scalar; the columns force a length-L result
# either way (each lane still owns its own table).
#
# CLAMP/EDGE BOUNDS are the exception to "every knot read is a seam": the outer
# clamp (`ax[1]`/`ax[Nx]`, and the linear form's edge values `table[1]`/
# `table[n]`) is a plain broadcast over the boundary COLUMN, so under a trace
# each such column used to be embedded as a lane-wide constant even when every
# lane held the same bound — the one remaining O(lanes) constant after the
# knot/table gathers went grid-independent (4 per bilinear; ~3.8 MB at 13×7×72
# against the table's former 1.32 GB — see test/reactant_lane_dedup_test.jl).
# `_oop_lane_bound` collapses a boundary column whose lanes are all BITWISE
# equal (`isequal` per element: NaN unifies, `-0.0` stays apart from `0.0` —
# the same key the trace-time lane dedup groups by) to its one scalar, which a
# trace then embeds as a scalar constant. Bit-identical by construction: the
# broadcasts consume one value per lane either way, and it is the same value.
# RESULT LENGTH is unchanged in every case — the length-L knot columns flow
# through `_oop_knot_count`/`_oop_knot_pair`/`_oop_bilinear_corners` on every
# path, so the lane axis is carried by the located/gathered terms even when a
# collapsed bound meets a lane-invariant scalar query (the `Lq` trap the
# Reactant ext's `_rx_knot_matrix` guard documents). A mixed column (lanes
# genuinely differing in their bound) stays a column — exactly today.
# `ESS_LANE_INTERN_DISABLE=1` turns the collapse off with the rest of the
# lane-intern feature, restoring today's lane-wide bounds as the oracle.
function _oop_lane_bound(col::Vector{Float64})
    _lane_intern_disabled() && return col
    @inbounds v1 = col[1]
    @inbounds for k in 2:length(col)
        isequal(col[k], v1) || return col
    end
    return v1
end

function _oop_interp_linear_lanes(h::_InterpLinearLaneSpec, q, ::Type{T}) where {T}
    axis = h.axis_cols; table = h.table_cols
    n = length(axis)
    cnt = _oop_knot_count(axis, q, <=)
    i = min.(max.(cnt, 1.0), Float64(n - 1))
    ai, ai1, ti, ti1 = _oop_knot_pair2(axis, table, i)
    w = (q .- ai) ./ (ai1 .- ai)
    blend = ti .+ w .* (ti1 .- ti)
    return ifelse.(q .<= _oop_lane_bound(axis[1]), _oop_lane_bound(table[1]),
                   ifelse.(q .>= _oop_lane_bound(axis[n]), _oop_lane_bound(table[n]),
                           blend))
end

function _oop_interp_searchsorted_lanes(h::_InterpSearchsortedLaneSpec, q,
                                        ::Type{T}) where {T}
    xs = h.xs_cols
    n = length(xs)
    n == 0 && return one.(q .* 0 .+ 1.0)     # empty table → 1 lane-wide (core's rule)
    r = _oop_knot_count(xs, q, <) .+ 1.0
    return ifelse.(q .!= q, Float64(n + 1), r)
end

function _oop_interp_bilinear_lanes(h::_InterpBilinearLaneSpec, x, y,
                                    ::Type{T}) where {T}
    ax = h.axis_x_cols; ay = h.axis_y_cols; table = h.table_cols
    Nx = length(ax); Ny = length(ay)
    ax1 = _oop_lane_bound(ax[1]); axN = _oop_lane_bound(ax[Nx])
    ay1 = _oop_lane_bound(ay[1]); ayN = _oop_lane_bound(ay[Ny])
    x_q = ifelse.(x .<= ax1, ax1, ifelse.(x .>= axN, axN, x))
    y_q = ifelse.(y .<= ay1, ay1, ifelse.(y .>= ayN, ayN, y))
    i = min.(max.(_oop_knot_count(ax, x_q, <=), 1.0), Float64(Nx - 1))
    j = min.(max.(_oop_knot_count(ay, y_q, <=), 1.0), Float64(Ny - 1))
    xi, xip1 = _oop_knot_pair(ax, i)
    yj, yjp1 = _oop_knot_pair(ay, j)
    t_ij, t_i1j, t_ijp1, t_i1jp1 = _oop_bilinear_corners(table, i, j, Nx, Ny)
    wx = (x_q .- xi) ./ (xip1 .- xi)
    wy = (y_q .- yj) ./ (yjp1 .- yj)
    row_j   = t_ij   .+ wx .* (t_i1j   .- t_ij)
    row_jp1 = t_ijp1 .+ wx .* (t_i1jp1 .- t_ijp1)
    return row_j .+ wy .* (row_jp1 .- row_j)
end

# ---- interp.* over lanes, ON HOST: just call the core per lane ---------------
#
# The six evaluators above are the TRACER's lowering, and they are branch-free
# because a tracer cannot branch on a traced query. Nothing else needs that.
# When the value type is a plain `Real` — `Float64`, or a ForwardDiff `Dual`,
# i.e. every host and AD walk — the query is a host value and the lane loop may
# simply BRANCH, which is what the scalar `_interp_*_core` kernels already do.
# (`Reactant`'s `TracedRNumber <: Number` but NOT `<: Real`, so a trace never
# reaches these methods; they are strictly a host dispatch.)
#
# BIT-IDENTICAL by construction, not by argument: these call the SAME
# `_oop_interp_*` wrappers — hence the same `_interp_*_core` kernels — that the
# scalar `:fn` arm and `f!` call, which is precisely what the branch-free forms
# are documented (and tested) to reproduce. Broadcast serves a lane vector and
# an invariant scalar query alike, exactly as the ladders did; the per-LANE spec
# forms broadcast over `h.specs`, so lane `l` reads its own table.
#
# WHY IT MATTERS. The ladder is O(table) per LANE, and the constant is brutal on
# a big table: a 61x23 `interp.bilinear` over 392 lanes costs 6.0 ms through the
# ladder and 0.018 ms through the cores — 328x, at Float64 and at `Dual` alike
# (measured). A model with 18 such calls per RHS was spending ~0.1 s per
# evaluation inside interp alone; a 60 s chemistry window took 1775 s against
# 25 s for the same model without the bilinear component. That is not a tracing
# problem and never was — it is the tracer's program running on host.
@inline _oop_interp_linear_lanes(h::_InterpLinearSpec, q, ::Type{T}) where {T<:Real} =
    _oop_interp_linear.(Ref(h), q, T)
@inline _oop_interp_searchsorted_lanes(h::_InterpSearchsortedSpec, q,
                                       ::Type{T}) where {T<:Real} =
    _oop_interp_searchsorted.(Ref(h), q, T)
@inline _oop_interp_bilinear_lanes(h::_InterpBilinearSpec, x, y,
                                   ::Type{T}) where {T<:Real} =
    _oop_interp_bilinear.(Ref(h), x, y, T)

# The per-lane spec twins. `h.specs[l]` is the member kernel's ORIGINAL spec, so
# this is the unmerged kernel's own call on lane `l` — the identity the merge is
# defined by, reached directly instead of through the knot-column ladder.
@inline _oop_interp_linear_lanes(h::_InterpLinearLaneSpec, q, ::Type{T}) where {T<:Real} =
    _oop_interp_linear.(h.specs, q, T)
@inline _oop_interp_searchsorted_lanes(h::_InterpSearchsortedLaneSpec, q,
                                       ::Type{T}) where {T<:Real} =
    _oop_interp_searchsorted.(h.specs, q, T)
@inline _oop_interp_bilinear_lanes(h::_InterpBilinearLaneSpec, x, y,
                                   ::Type{T}) where {T<:Real} =
    _oop_interp_bilinear.(h.specs, x, y, T)

# ---- Live forcing buffers as ARGUMENTS (B2) ----------------------------------
#
# The compiled IR reaches a live forcing buffer (`param_arrays` entries and
# DiscreteMaterializer caches, both registered in the build's `pgather` dict) by
# ALIAS: an `_NK_PARAM_GATHER` payload and the `arr` field of a forcing acc
# descriptor (`_AK_ARR_FIXED` / `_AK_FORCING_BOX` / `_AK_ARR_TBL_BOX`) are the
# same host `Vector{Float64}` the caller bound. On host that aliasing IS the
# live-refresh channel. Under an XLA trace it is the silent-staleness bug: a
# captured host array is a trace-time CONSTANT.
#
# So the out-of-place RHS carries the buffers through its ARGUMENT LIST instead:
# the explicit form is `rhs(u, p, t, buffers)`, where `buffers` is a NamedTuple
# of arrays in a STABLE order (buffer names sorted; see `_make_rhs_oop`). At each
# read site the walker swaps the node's aliased host array for the aligned entry
# of the `buffers` argument via `_oop_forcing_slab` — an identity (`===`) scan
# over `hostkeys`, the host buffers in the container's own order (built once per
# RHS). A LINEAR scan, not an `IdDict`, and that is load-bearing: the scan runs
# per forcing read per call, O(#buffers) with #buffers the handful of forcing
# VARIABLES (never cells) — and an `IdDict` capture is untraceable (its
# `Memory{Any}` hash table throws inside Reactant's closure walk), which would
# break tracing for every model, forcing or not. A backend passes device arrays
# (`ConcreteRArray`s) in `buffers`, and an in-place `copyto!` into those SAME
# arrays between calls is a real input update the compiled program sees
# (measured; see ext/EarthSciASTReactantExt.jl).
#
# The host wrapper (`_OopRHS`) forwards the build's own host buffers, so
# `f(u, p, t)` still reads the exact aliased storage it always did — the
# fallback arm in `_oop_forcing_slab` (an arr absent from `hostkeys`, e.g. a
# hand-built test kernel) reads the host array directly, the pre-B2 behavior.
#
# The third field is the per-call READ MEMO (ess-oop-intern; see the
# `_oop_gather` seam). It rides here because this is the one per-call context
# object the walker already threads to every read site, and because that makes
# the memo's lifetime exactly one RHS invocation with no global state and no
# teardown. `M === Nothing` on host and the field is zero-sized, so a host build
# is unchanged in layout, allocation and code.
struct _OopForcing{B,M}
    bufs::B                             # this CALL's buffer container (host or traced)
    hostkeys::Vector{Vector{Float64}}   # host buffer identities, aligned with `bufs`
    memo::M                             # per-call (tensor, window) read memo, or `nothing`
end
_OopForcing(bufs, hostkeys) = _OopForcing(bufs, hostkeys, nothing)
const _OOP_NO_FORCING = _OopForcing((;), Vector{Float64}[])

@inline function _oop_forcing_slab(fb::_OopForcing, arr::Vector{Float64})
    ks = fb.hostkeys
    @inbounds for j in eachindex(ks)
        ks[j] === arr && return fb.bufs[j]
    end
    return arr
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
function _oop_eval(n::_Node, u, p, t, cache::AbstractVector{T}, fb::_OopForcing)::T where {T}
    k = n.kind
    if k === _NK_LITERAL
        return convert(T, n.literal)
    elseif k === _NK_STATE
        return convert(T, _oop_read_state(u, n.idx))
    elseif k === _NK_PARAM
        return convert(T, _read_param(p, n.sym, n.idx))
    elseif k === _NK_TIME
        return convert(T, t)
    elseif k === _NK_PARAM_GATHER
        # Live forcing buffer (ess-14f.3) — data, so it enters as a constant of
        # the value type (zero derivative), exactly as it should. Read through
        # the `buffers` ARGUMENT (`_oop_forcing_slab` swaps the node's aliased
        # host array for the aligned argument entry), so a tracing backend sees
        # a real input, not a baked-in trace-time constant.
        return convert(T, _oop_read_forcing(
            _oop_forcing_slab(fb, n.payload::Vector{Float64}), n.idx))
    elseif k === _NK_CACHED
        return @inbounds cache[n.idx]
    elseif k === _NK_CONTRACTION
        return _oop_contraction(n, u, p, t, cache, fb)
    elseif k === _NK_LOOPVAR
        # ess-runtime-contraction: enclosing loop counter, an integer constant of T.
        return convert(T, (n.payload::Base.RefValue{Int})[])
    elseif k === _NK_CONTRACTION_LOOP
        return _oop_contraction_loop(n, u, p, t, cache, fb)
    elseif k === _NK_CONST_GATHER
        return _oop_const_gather(n, u, p, t, cache, fb)
    elseif k === _NK_STATE_GATHER
        return _oop_state_gather(n, u, p, t, cache, fb)
    else
        return _oop_eval_op(n, u, p, t, cache, fb)
    end
end

# OOP twin of the `_NK_CONST_GATHER` arm of `_eval_node` (wall2 Phase B): a
# runtime-indexed read of a frozen const/provider array. The scalar walker gained
# this via the compile-once cellwise path; the OOP form had no arm because that
# path never traces — but a runtime contraction loop (ess-runtime-contraction) can
# put a const-gather (a loop-var-subscripted weight) on the traced `:oop` RHS, so
# it needs the same lowering here to stay bit-identical to `f!`.
# Evaluate an INDEX subtree to a concrete `Int`.
#
# WHY THIS IS NOT `_oop_eval`. A gather's subscripts are integer index arithmetic
# over enclosing loop counters and literals — they never read the state. But
# `_oop_eval` returns the VALUE type, so under tracing a loop counter comes back
# as a `TracedRNumber` holding a constant, and everything downstream inherits it:
# `round(Int, ·)` stays traced, and the ghost-bounds test `lo <= sub <= hi` then
# throws "non-boolean (TracedRNumber{Bool}) used in boolean context" — a control
# decision XLA cannot make, on a quantity that was concrete all along.
#
# Reached whenever a runtime contraction loop (ess-runtime-contraction) puts a
# loop-var-dependent subscript on the traced RHS, which a mass-weighted column
# integral does as soon as the reduction is long enough to clear
# `ESS_CONTRACTION_LOOP_MIN`.
#
# Deliberately NARROW: exactly the kinds an index expression can contain. Anything
# else is a genuinely state-dependent subscript, which cannot be resolved at trace
# time at all, and says so rather than silently tracing into the same dead end.
function _oop_index_int(n::_Node, u, p, t, cache::AbstractVector{T},
                        fb::_OopForcing)::Int where {T}
    k = n.kind
    if k === _NK_LOOPVAR
        return (n.payload::Base.RefValue{Int})[]
    elseif k === _NK_LITERAL
        return round(Int, n.literal)
    elseif k === _NK_CONST_GATHER
        cg = n.payload::_ConstGatherArray
        off = 1
        @inbounds for d in eachindex(n.children)
            off += (_oop_index_int(n.children[d], u, p, t, cache, fb) - 1) * cg.strides[d]
        end
        (1 <= off <= cg.len) || throw(BoundsError(cg.flat, off))
        return round(Int, @inbounds cg.flat[off])
    elseif k === _NK_OP
        op = n.op
        c = n.children
        if op === :+
            s = 0
            @inbounds for d in eachindex(c)
                s += _oop_index_int(c[d], u, p, t, cache, fb)
            end
            return s
        elseif op === :-
            length(c) == 1 && return -_oop_index_int(c[1], u, p, t, cache, fb)
            return _oop_index_int(c[1], u, p, t, cache, fb) -
                   _oop_index_int(c[2], u, p, t, cache, fb)
        elseif op === :*
            s = 1
            @inbounds for d in eachindex(c)
                s *= _oop_index_int(c[d], u, p, t, cache, fb)
            end
            return s
        elseif op === :/
            return div(_oop_index_int(c[1], u, p, t, cache, fb),
                       _oop_index_int(c[2], u, p, t, cache, fb))
        end
    end
    throw(TreeWalkError("E_TREEWALK_TRACED_SUBSCRIPT",
        "an out-of-place gather subscript must resolve to a build-time / " *
        "loop-counter integer, but this one is node kind $(k)" *
        (k === _NK_OP ? " (op $(n.op))" : "") *
        ". A subscript computed from the STATE cannot be resolved while tracing " *
        "— XLA would need the value to pick a slot. Run the interpreted " *
        "evaluator (`form = :inplace`), which resolves it per call."))
end

function _oop_const_gather(n::_Node, u, p, t, cache::AbstractVector{T}, fb::_OopForcing)::T where {T}
    cg = n.payload::_ConstGatherArray
    children = n.children
    strides = cg.strides
    off = 1
    @inbounds for d in eachindex(children)
        sub = _oop_index_int(children[d], u, p, t, cache, fb)
        off += (sub - 1) * strides[d]
    end
    (1 <= off <= cg.len) || throw(BoundsError(cg.flat, off))
    return convert(T, @inbounds cg.flat[off])
end

# OOP twin of `_eval_state_gather` (ess-runtime-contraction). Same slot computation
# and ghost convention; reads the state through `_oop_read_state` so a tracing
# backend sees the real input, and returns `T` on both arms.
function _oop_state_gather(n::_Node, u, p, t, cache::AbstractVector{T}, fb::_OopForcing)::T where {T}
    sg = n.payload::_StateGather
    children = n.children
    off = 0
    @inbounds for d in eachindex(children)
        # `_oop_index_int`, not `_oop_eval`: the ghost test below is a CONTROL
        # decision, so `sub` has to be a host `Int`. See `_oop_index_int`.
        sub = _oop_index_int(children[d], u, p, t, cache, fb)
        (sg.lo[d] <= sub <= sg.hi[d]) || return zero(T)   # ghost cell
        off += (sub - sg.lo[d]) * sg.strides[d]
    end
    slot = @inbounds sg.slot_flat[off + 1]
    return convert(T, _oop_read_state(u, slot))
end

# OOP twin of `_eval_contraction_loop` (ess-runtime-contraction). Same static-range
# iteration, same 0̄-seeded ⊕-fold, so a Float64 `:oop` run stays bit-identical to
# `f!` — the property the in-place tests use `:oop` as an oracle for.
function _oop_contraction_loop(n::_Node, u, p, t, cache::AbstractVector{T}, fb::_OopForcing)::T where {T}
    spec = n.payload::_ContractLoop
    ref = spec.ref
    body = @inbounds n.children[1]
    op = n.op
    s = convert(T, n.literal)
    rng = spec.lo:spec.step:spec.hi
    if op === :+
        @inbounds for k in rng
            ref[] = k
            s += _oop_eval(body, u, p, t, cache, fb)
        end
    elseif op === :*
        @inbounds for k in rng
            ref[] = k
            s *= _oop_eval(body, u, p, t, cache, fb)
        end
    elseif op === :max
        @inbounds for k in rng
            ref[] = k
            s = max(s, _oop_eval(body, u, p, t, cache, fb))
        end
    else  # :min
        @inbounds for k in rng
            ref[] = k
            s = min(s, _oop_eval(body, u, p, t, cache, fb))
        end
    end
    return s
end

function _oop_eval_op(n::_Node, u, p, t, cache::AbstractVector{T}, fb::_OopForcing)::T where {T}
    n.op === :fn && return _oop_fn(n, u, p, t, cache, fb)
    if n.op === :^ || n.op === :pow
        return _oop_pow(n.op, n.children, u, p, t, cache, fb)
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
        return _oop_eval(ch[1], u, p, t, cache, fb) != 0 ?
               _oop_eval(ch[2], u, p, t, cache, fb) :
               _oop_eval(ch[3], u, p, t, cache, fb)
    elseif n.op === :and
        @inbounds for i in eachindex(ch)
            _oop_eval(ch[i], u, p, t, cache, fb) == 0 && return zero(T)
        end
        return one(T)
    elseif n.op === :or
        @inbounds for i in eachindex(ch)
            _oop_eval(ch[i], u, p, t, cache, fb) != 0 && return one(T)
        end
        return zero(T)
    end
    c = Vector{T}(undef, length(ch))
    @inbounds for i in eachindex(ch)
        c[i] = _oop_eval(ch[i], u, p, t, cache, fb)
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
                          cache::AbstractVector{T}, fb::_OopForcing)::T where {T}
    _expect_arity_n(op, ch, 2)
    base = _oop_eval(ch[1], u, p, t, cache, fb)
    e = ch[2]
    return e.kind === _NK_LITERAL ? base^e.literal :
           base^_oop_eval(e, u, p, t, cache, fb)
end

# Semiring fold, seeded from the 0̄ identity baked on the node — same order as
# `_eval_contraction`, so the sum is bit-identical at Float64.
function _oop_contraction(n::_Node, u, p, t, cache::AbstractVector{T}, fb::_OopForcing)::T where {T}
    op = n.op
    ch = n.children
    s = convert(T, n.literal)
    if op === :+
        @inbounds for k in eachindex(ch)
            s += _oop_eval(ch[k], u, p, t, cache, fb)
        end
    elseif op === :*
        @inbounds for k in eachindex(ch)
            s *= _oop_eval(ch[k], u, p, t, cache, fb)
        end
    elseif op === :max
        @inbounds for k in eachindex(ch)
            s = max(s, _oop_eval(ch[k], u, p, t, cache, fb))
        end
    else  # :min
        @inbounds for k in eachindex(ch)
            s = min(s, _oop_eval(ch[k], u, p, t, cache, fb))
        end
    end
    return s
end

# Closed functions. `interp.*` carries a build-time-validated typed spec (the
# `_FN_CONST_ARG_SPECS` protocol); an all-scalar fn carries its typed-core
# rider (`_FnTypedCoreSpec`, ess-dtcore) when the registry declares one —
# `datetime.*` does — and `nothing` (boxed) otherwise. At `T === Float64` the
# typed rider calls the core directly; every OTHER `T` — and every boxed
# payload — goes through `_eval_closed_fn`, which selects the `Float64`-pinned
# registry or its eltype-generic twin on the compile-time `T`: a `Dual` walk
# differentiates `datetime.julian_day` (a real function of `t`, which IS a
# differentiation variable for a Rosenbrock ∂f/∂t term), and a traced walk
# keeps the decomposition inside the program (`evaluate_closed_function_ad`),
# exactly as before typed cores existed.
function _oop_fn(n::_Node, u, p, t, cache::AbstractVector{T}, fb::_OopForcing)::T where {T}
    pl = n.payload
    c = n.children
    if pl isa Tuple{String,_InterpLinearSpec}
        return _oop_interp_linear(pl[2], _oop_eval(c[1], u, p, t, cache, fb), T)
    elseif pl isa Tuple{String,_InterpBilinearSpec}
        return _oop_interp_bilinear(pl[2], _oop_eval(c[1], u, p, t, cache, fb),
                                    _oop_eval(c[2], u, p, t, cache, fb), T)
    elseif pl isa Tuple{String,_InterpSearchsortedSpec}
        return _oop_interp_searchsorted(pl[2], _oop_eval(c[1], u, p, t, cache, fb), T)
    elseif pl isa Tuple{String,_FnTypedCoreSpec}
        if T === Float64      # compile-time fold, as in `_eval_closed_fn`
            return _fn_typed_core_call(pl[2].id, _oop_eval(c[1], u, p, t, cache, fb))
        end
        args = Any[_oop_eval(ci, u, p, t, cache, fb) for ci in c]
        return convert(T, _eval_closed_fn(pl[1], args, T))
    elseif pl isa Tuple{String,Nothing}
        args = Any[_oop_eval(ci, u, p, t, cache, fb) for ci in c]
        return convert(T, _eval_closed_fn(pl[1], args, T))
    end
    throw(TreeWalkError("E_TREEWALK_UNKNOWN_CLOSED_FUNCTION",
        "fn payload $(typeof(pl)) is neither a typed interp spec tuple nor (String, Nothing)"))
end

# ---- Lane-batched scalar entries (ess-oop-batch) -----------------------------
#
# WHY. The per-CELL scalar surface of this emitter — `rhs_list` entries a state
# equation lowers to when it declines the kernel path (a runtime contraction
# loop routes there BY DESIGN, see resolve.jl's `_ARRAY_CELL_DEPTH` note), and
# the per-column `scalars` of a materialized-observed fill level — is walked one
# entry at a time through `_oop_eval`. Correct, and on host cheap; under a TRACE
# it is the one remaining place the emitted program's size scales with the grid:
# every entry re-traces its whole tree, so a contraction loop over L levels
# inside a per-column fill emits O(columns × L) scalar-indexed reads (measured
# on ReSEACT CONUS: ~80 `stablehlo.dynamic_slice` PER GRID CELL, a 410 MB HLO
# module at 7×7×72 — the multi-day-XLA-hang term).
#
# WHAT. Those entries are per-cell INSTANTIATIONS of one expression: same tree,
# same ops, same loop ranges — only the baked-in cell data differ (state slots,
# forcing offsets, gather subscripts, inlined per-cell constants). So at closure
# build the entries are GROUPED by a canonical structural signature
# (`_oop_batch_sig`) that wildcards exactly those lane-varying leaves, each
# group is lowered ONCE to a lane-batched tree (`_OopBatchNode`,
# `_oop_batch_lower`), and the whole group evaluates through `_oop_eval_batch`
# as whole-array ops over its lane axis: a state leaf is ONE `_oop_gather` over
# the per-lane slots, a contraction loop runs its L iterations ONCE with a
# whole-lane accumulate per iteration, and the group's result lands through ONE
# `_oop_scatter`. Emitted-program size: O(tree × L), independent of the lane
# (grid) count.
#
# BIT-IDENTITY. Per lane, every arm performs the same operations in the same
# order the scalar walker performs them (broadcast is elementwise; the loop
# fold accumulates per lane in the same ascending-k order seeded from the same
# 0̄; a ghost state-gather selects the same 0; a pow keeps its literal exponent
# — the signature PINS the exponent, so a group never blends the power rule).
# The one semantic divergence is inherited from every vectorized tier of this
# codebase: `ifelse`/`and`/`or` evaluate EAGERLY over lanes (the `_oop_op`
# folded arms, value-identical to the lazy scalar arms) rather than
# short-circuiting, so a guard that exists to dodge a DomainError does not
# dodge it here — exactly the `_eval_vec` / `_oop_run_acc_vec` contract. Under
# a trace the lazy arms could not run anyway (branching on a traced Bool
# throws), so for the traced consumer this path is strictly more capable.
#
# SAFETY. Grouping is conservative: a signature mismatch, a singleton group, an
# unknown node kind, or any congruence check failing in `_oop_batch_lower`
# leaves the affected entries on the existing one-at-a-time scalar path,
# unchanged. `ESS_OOP_BATCH=0` disables the whole feature (every entry single).
# Entries within one batch surface write DISJOINT slots and never read each
# other (rhs_list writes `du` reading only `ue`/cache; a fill level's scalars
# read only strictly-lower levels — the level scheduler's invariant), so
# evaluating groups after the leftover singles reorders only WRITES to disjoint
# slots, never a read-after-write.
_oop_batch_enabled() = get(ENV, "ESS_OOP_BATCH", "1") != "0"

# One position of a lane-batched tree. `kind` mirrors the `_NK_*` of every
# lane's node at this position; which fields are live depends on it:
#   _NK_LITERAL       shared `literal`, or per-lane `lanes_f`
#   _NK_STATE         shared `idx`, or per-lane `slots` (one whole-array gather)
#   _NK_PARAM/_NK_TIME/_NK_CACHED  shared `sym`/`idx` (lane-invariant scalar)
#   _NK_PARAM_GATHER  `payload` the ONE shared buffer; shared `idx` or `slots`
#   _NK_CONST_GATHER / _NK_STATE_GATHER  `nodes`: each lane's ORIGINAL node,
#                     resolved per lane at eval (subscripts are host integer
#                     arithmetic — `_oop_index_int` — so this is host work; the
#                     state read is still one whole-array gather)
#   _NK_LOOPVAR       `refs`: each lane's counter Ref (values read per lane)
#   _NK_CONTRACTION_LOOP  shared `op`/`literal`/`lo:step:hi`; `refs` all lanes'
#                     counters; `children[1]` the batched body
#   _NK_CONTRACTION   shared `op`/`literal`; batched children
#   _NK_OP            shared `op` (+ `payload` for `:fn`); batched children
struct _OopBatchNode
    kind::UInt8
    op::Symbol
    literal::Float64
    idx::Int
    sym::Symbol
    payload::Any
    lanes_f::Vector{Float64}
    slots::Vector{Int}
    nodes::Vector{_Node}
    refs::Vector{Base.RefValue{Int}}
    lo::Int
    hi::Int
    step::Int
    children::Vector{_OopBatchNode}
end
function _mkbatch(; kind::UInt8, op::Symbol=Symbol(""), literal::Float64=0.0,
                  idx::Int=0, sym::Symbol=Symbol(""), payload=nothing,
                  lanes_f::Vector{Float64}=Float64[], slots::Vector{Int}=Int[],
                  nodes::Vector{_Node}=_Node[],
                  refs::Vector{Base.RefValue{Int}}=Base.RefValue{Int}[],
                  lo::Int=0, hi::Int=0, step::Int=1,
                  children::Vector{_OopBatchNode}=_OopBatchNode[])
    return _OopBatchNode(kind, op, literal, idx, sym, payload, lanes_f, slots,
                         nodes, refs, lo, hi, step, children)
end

# One batched group: the (disjoint) output slots, lane-aligned, and the lowered
# tree. `_OopScalarBatches` is one whole batch surface (rhs_list, or one fill
# level's scalars): the groups plus the leftover singles in their ORIGINAL
# relative order. `n_batched` is Σ group lanes — the build-observability number
# (and the closure-reflection witness the tests pin).
struct _OopScalarBatch
    slots::Vector{Int}
    root::_OopBatchNode
end
struct _OopScalarBatches
    groups::Vector{_OopScalarBatch}
    rest::Vector{Tuple{Int,_Node}}
    n_batched::Int
end
const _OOP_NO_BATCH = _OopScalarBatches(_OopScalarBatch[], Tuple{Int,_Node}[], 0)

# Canonical structural signature: two entries share one iff `_oop_batch_lower`
# can lane-batch them together. Writes into `io`; returns `false` for a node
# kind the batch walker does not model (the entry then stays single). What is
# PINNED (in the key) vs WILDCARDED (varies per lane):
#   pinned:    tree shape, every op, param syms, cache slot ids, loop ranges +
#              ⊕ + 0̄, fn identity (typed-core id / boxed name / interp spec
#              object), the forcing BUFFER identity, pow's literal exponent
#              (so a Dual walk keeps the power rule — see `_oop_pow`)
#   wildcard:  state slot idx, forcing offset idx, value-position literals,
#              const/state-gather payloads AND their whole subscript subtrees
#              (each lane resolves its own — congruence across lanes is not
#              required there, only that the kind sits at the same position)
function _oop_batch_sig!(io::IO, n::_Node, fixed_lit::Bool)::Bool
    k = n.kind
    if k === _NK_LITERAL
        fixed_lit ? print(io, "L", n.literal) : print(io, "l")
    elseif k === _NK_STATE
        print(io, "s")
    elseif k === _NK_PARAM
        print(io, "p", n.sym)
    elseif k === _NK_TIME
        print(io, "t")
    elseif k === _NK_CACHED
        print(io, "c", n.idx)
    elseif k === _NK_PARAM_GATHER
        print(io, "pg", objectid(n.payload))
    elseif k === _NK_CONST_GATHER
        print(io, "cg")
    elseif k === _NK_STATE_GATHER
        print(io, "sg")
    elseif k === _NK_LOOPVAR
        print(io, "lv")
    elseif k === _NK_CONTRACTION_LOOP
        spec = n.payload::_ContractLoop
        print(io, "cl(", n.op, ",", n.literal, ",", spec.lo, ":", spec.step,
              ":", spec.hi, "){")
        _oop_batch_sig!(io, n.children[1], false) || return false
        print(io, "}")
    elseif k === _NK_CONTRACTION
        print(io, "cn(", n.op, ",", n.literal, "){")
        for c in n.children
            _oop_batch_sig!(io, c, false) || return false
            print(io, ",")
        end
        print(io, "}")
    elseif k === _NK_OP
        op = n.op
        if op === :fn
            pl = n.payload
            if pl isa Tuple{String,_FnTypedCoreSpec}
                print(io, "fn(", pl[1], ",", pl[2].id, ")")
            elseif pl isa Tuple{String,Nothing}
                print(io, "fn0(", pl[1], ")")
            elseif pl isa Tuple{String,_InterpLinearSpec} ||
                   pl isa Tuple{String,_InterpBilinearSpec} ||
                   pl isa Tuple{String,_InterpSearchsortedSpec}
                # Spec OBJECT identity: the build memo shares one compiled node
                # (hence one spec) across cells; content-equal distinct objects
                # merely fragment the group, never miscompile it.
                print(io, "fni", objectid(pl[2]))
            else
                return false
            end
            print(io, "{")
            for c in n.children
                _oop_batch_sig!(io, c, false) || return false
                print(io, ",")
            end
            print(io, "}")
        elseif op === :^ || op === :pow
            length(n.children) == 2 || return false
            print(io, "pw{")
            _oop_batch_sig!(io, n.children[1], false) || return false
            print(io, ",")
            # The exponent's IMMEDIATE literal is pinned; a non-literal exponent
            # recurses normally (its own literals stay wildcards).
            _oop_batch_sig!(io, n.children[2], true) || return false
            print(io, "}")
        else
            print(io, "o(", op, "){")
            for c in n.children
                _oop_batch_sig!(io, c, false) || return false
                print(io, ",")
            end
            print(io, "}")
        end
    else
        return false
    end
    return true
end
function _oop_batch_sig(n::_Node)::Union{Nothing,String}
    io = IOBuffer()
    return _oop_batch_sig!(io, n, false) ? String(take!(io)) : nothing
end

# Lower `L` congruent lane nodes to one batched node. Defensive: every
# congruence the signature promises is RE-CHECKED here (a `nothing` return
# declines the whole group back to the scalar path — a signature collision can
# lose batching, never correctness).
function _oop_batch_lower(nodes::Vector{_Node})::Union{Nothing,_OopBatchNode}
    n1 = @inbounds nodes[1]
    k = n1.kind
    @inbounds for l in 2:length(nodes)
        nodes[l].kind === k || return nothing
    end
    if k === _NK_LITERAL
        all(nd -> isequal(nd.literal, n1.literal), nodes) &&
            return _mkbatch(kind=k, literal=n1.literal)
        return _mkbatch(kind=k, lanes_f=Float64[nd.literal for nd in nodes])
    elseif k === _NK_STATE
        all(nd -> nd.idx == n1.idx, nodes) && return _mkbatch(kind=k, idx=n1.idx)
        return _mkbatch(kind=k, slots=Int[nd.idx for nd in nodes])
    elseif k === _NK_PARAM
        # `idx` rides along with `sym` (the read seam wants both). It is not part
        # of the congruence test because it is a FUNCTION of `sym` — one build's
        # parameter order — so equal syms already imply equal indices.
        all(nd -> nd.sym === n1.sym, nodes) || return nothing
        return _mkbatch(kind=k, sym=n1.sym, idx=n1.idx)
    elseif k === _NK_TIME
        return _mkbatch(kind=k)
    elseif k === _NK_CACHED
        all(nd -> nd.idx == n1.idx && nd.payload === n1.payload, nodes) || return nothing
        return _mkbatch(kind=k, idx=n1.idx, payload=n1.payload)
    elseif k === _NK_PARAM_GATHER
        arr = n1.payload::Vector{Float64}
        all(nd -> nd.payload === arr, nodes) || return nothing
        all(nd -> nd.idx == n1.idx, nodes) &&
            return _mkbatch(kind=k, idx=n1.idx, payload=arr)
        return _mkbatch(kind=k, payload=arr, slots=Int[nd.idx for nd in nodes])
    elseif k === _NK_CONST_GATHER || k === _NK_STATE_GATHER
        return _mkbatch(kind=k, nodes=nodes)
    elseif k === _NK_LOOPVAR
        return _mkbatch(kind=k,
            refs=Base.RefValue{Int}[nd.payload::Base.RefValue{Int} for nd in nodes])
    elseif k === _NK_CONTRACTION_LOOP
        spec = n1.payload::_ContractLoop
        for nd in nodes
            sp = nd.payload::_ContractLoop
            (nd.op === n1.op && isequal(nd.literal, n1.literal) &&
             sp.lo == spec.lo && sp.hi == spec.hi && sp.step == spec.step &&
             length(nd.children) == 1) || return nothing
        end
        body = _oop_batch_lower(_Node[nd.children[1] for nd in nodes])
        body === nothing && return nothing
        return _mkbatch(kind=k, op=n1.op, literal=n1.literal,
            refs=Base.RefValue{Int}[(nd.payload::_ContractLoop).ref for nd in nodes],
            lo=spec.lo, hi=spec.hi, step=spec.step,
            children=_OopBatchNode[body])
    elseif k === _NK_CONTRACTION || k === _NK_OP
        nc = length(n1.children)
        for nd in nodes
            (nd.op === n1.op && length(nd.children) == nc &&
             (k !== _NK_CONTRACTION || isequal(nd.literal, n1.literal))) ||
                return nothing
        end
        if k === _NK_OP && n1.op === :fn
            pl = n1.payload
            ok = if pl isa Tuple{String,_FnTypedCoreSpec}
                all(nd -> (q = nd.payload;
                           q isa Tuple{String,_FnTypedCoreSpec} &&
                           q[1] == pl[1] && q[2].id === pl[2].id), nodes)
            elseif pl isa Tuple{String,Nothing}
                all(nd -> (q = nd.payload;
                           q isa Tuple{String,Nothing} && q[1] == pl[1]), nodes)
            elseif pl isa Tuple{String,_InterpLinearSpec} ||
                   pl isa Tuple{String,_InterpBilinearSpec} ||
                   pl isa Tuple{String,_InterpSearchsortedSpec}
                all(nd -> nd.payload isa Tuple && length(nd.payload) == 2 &&
                          nd.payload[2] === pl[2], nodes)
            else
                false
            end
            ok || return nothing
        end
        children = Vector{_OopBatchNode}(undef, nc)
        for i in 1:nc
            ci = _oop_batch_lower(_Node[nd.children[i] for nd in nodes])
            ci === nothing && return nothing
            children[i] = ci
        end
        return _mkbatch(kind=k, op=n1.op, literal=n1.literal,
                        payload=(k === _NK_OP ? n1.payload : nothing),
                        children=children)
    end
    return nothing
end

# Group one batch surface. Groups (≥2 congruent lanes, lowered successfully)
# come out in first-appearance order with lanes in original entry order; every
# other entry stays in `rest`, original relative order preserved. With the
# feature disabled (`ESS_OOP_BATCH=0`) everything is `rest` — byte-identical to
# the pre-feature closure. `ESS_OOP_PROBE=1` tallies the outcome per entry
# (`:oop_batch_lane` / `:oop_batch_single`) and per group (`:oop_batch_group`).
function _oop_batch_scalars(entries::AbstractVector{Tuple{Int,_Node}})
    (!_oop_batch_enabled() || length(entries) < 2) &&
        return _OopScalarBatches(_OopScalarBatch[],
                                 collect(Tuple{Int,_Node}, entries), 0)
    order = Dict{String,Int}()          # key -> first-appearance group ordinal
    members = Vector{Vector{Int}}()     # ordinal -> entry indices
    for (i, (_, nd)) in enumerate(entries)
        s = _oop_batch_sig(nd)
        s === nothing && continue
        g = get!(order, s) do
            push!(members, Int[])
            length(members)
        end
        push!(members[g], i)
    end
    groups = _OopScalarBatch[]
    single = trues(length(entries))
    n_batched = 0
    probe = get(ENV, "ESS_OOP_PROBE", "") == "1"
    for idxs in members
        length(idxs) >= 2 || continue
        root = _oop_batch_lower(_Node[entries[i][2] for i in idxs])
        root === nothing && continue
        push!(groups, _OopScalarBatch(Int[entries[i][1] for i in idxs], root))
        n_batched += length(idxs)
        for i in idxs
            single[i] = false
        end
        probe && _tally_cascade!(:oop_batch_group)
    end
    rest = Tuple{Int,_Node}[entries[i] for i in eachindex(entries) if single[i]]
    if probe
        for _ in 1:n_batched; _tally_cascade!(:oop_batch_lane); end
        for _ in 1:length(rest); _tally_cascade!(:oop_batch_single); end
    end
    return _OopScalarBatches(groups, rest, n_batched)
end

# The lane-batched fn arm: children already evaluated (lane vectors and/or
# invariant scalars). Interp goes through the SAME lane evaluators the
# vectorized acc path uses (host: the scalar cores per lane, bit-identical by
# construction; trace: the branch-free forms / the ext's gather seams). A
# typed-core fn at Float64 is one typed broadcast; every other case is the
# boxed per-lane broadcast — host-correct, loud under a trace, exactly the
# `_oop_acck_fn` contract.
function _oop_batch_fn(pl, cv::Vector{Any}, ::Type{T}) where {T}
    if pl isa Tuple{String,_InterpLinearSpec}
        return _oop_interp_linear_lanes(pl[2], cv[1], T)
    elseif pl isa Tuple{String,_InterpBilinearSpec}
        return _oop_interp_bilinear_lanes(pl[2], cv[1], cv[2], T)
    elseif pl isa Tuple{String,_InterpSearchsortedSpec}
        return _oop_interp_searchsorted_lanes(pl[2], cv[1], T)
    elseif pl isa Tuple{String,_FnTypedCoreSpec}
        T === Float64 && return _fn_typed_core_call.(pl[2].id, cv[1])
        fname = pl[1]
        return broadcast((as...) -> convert(T, _eval_closed_fn(fname, Any[as...], T)),
                         cv...)
    elseif pl isa Tuple{String,Nothing}
        fname = pl[1]
        return broadcast((as...) -> convert(T, _eval_closed_fn(fname, Any[as...], T)),
                         cv...)
    end
    throw(TreeWalkError("E_TREEWALK_UNKNOWN_CLOSED_FUNCTION",
        "fn payload $(typeof(pl)) is neither a typed interp spec tuple nor (String, Nothing)"))
end

# Evaluate a batched tree over its whole lane axis. Returns a length-L lane
# vector, or a bare scalar where the subtree is lane-invariant — broadcast makes
# them interchangeable, exactly as in `_oop_eval_acck`. Per lane this computes
# what `_oop_eval` computes on that lane's original node (see the bit-identity
# note at the section header).
function _oop_eval_batch(b::_OopBatchNode, u, p, t, cache::AbstractVector{T},
                         fb::_OopForcing) where {T}
    k = b.kind
    if k === _NK_LITERAL
        return isempty(b.lanes_f) ? convert(T, b.literal) : b.lanes_f
    elseif k === _NK_STATE
        return isempty(b.slots) ? convert(T, _oop_read_state(u, b.idx)) :
               _oop_gather(u, b.slots, fb.memo)
    elseif k === _NK_PARAM
        return convert(T, _read_param(p, b.sym, b.idx))
    elseif k === _NK_TIME
        return convert(T, t)
    elseif k === _NK_CACHED
        return @inbounds cache[b.idx]
    elseif k === _NK_PARAM_GATHER
        buf = _oop_forcing_slab(fb, b.payload::Vector{Float64})
        return isempty(b.slots) ? convert(T, _oop_read_forcing(buf, b.idx)) :
               _oop_gather(buf, b.slots, fb.memo)
    elseif k === _NK_LOOPVAR
        # Per LANE: positionally-matched loop counters normally all hold the
        # same k (the batched loop below writes every lane's ref), but two
        # congruent trees may bind DIFFERENT enclosing loops at this position
        # (Σ_k Σ_l f(k) grouped with Σ_k Σ_l f(l)), so read each lane's own.
        refs = b.refs
        v1 = @inbounds refs[1][]
        same = true
        @inbounds for l in 2:length(refs)
            same &= (refs[l][] == v1)
        end
        return same ? convert(T, v1) : Float64[Float64(r[]) for r in refs]
    elseif k === _NK_CONST_GATHER
        # Host-resolved per lane (subscripts are loop-counter integer
        # arithmetic; `_oop_index_int` guarantees a host Int — the same
        # resolution `_oop_const_gather` performs per entry), collapsed to one
        # scalar when every lane reads the same value.
        nds = b.nodes
        L = length(nds)
        vals = Vector{Float64}(undef, L)
        @inbounds for l in 1:L
            nd = nds[l]
            cg = nd.payload::_ConstGatherArray
            off = 1
            for d in eachindex(nd.children)
                off += (_oop_index_int(nd.children[d], u, p, t, cache, fb) - 1) *
                       cg.strides[d]
            end
            (1 <= off <= cg.len) || throw(BoundsError(cg.flat, off))
            vals[l] = cg.flat[off]
        end
        allsame = true
        @inbounds for l in 2:L
            allsame &= isequal(vals[l], vals[1])
        end
        return allsame ? convert(T, @inbounds vals[1]) : vals
    elseif k === _NK_STATE_GATHER
        # Per-lane slot resolution on host (`_oop_index_int`, the CONTROL-side
        # ghost test `_oop_state_gather` performs), then ONE whole-array gather;
        # ghost lanes gather a SAFE slot and select 0 — the in-place runners'
        # `s == 0 ? 0.0 : u[s]`, bit-identical (the `_AK_STATE_TBL_BOX` pattern).
        nds = b.nodes
        L = length(nds)
        slots = Vector{Int}(undef, L)
        mask = Vector{Bool}(undef, L)
        anyghost = false
        @inbounds for l in 1:L
            nd = nds[l]
            sg = nd.payload::_StateGather
            off = 0
            g = false
            for d in eachindex(nd.children)
                sub = _oop_index_int(nd.children[d], u, p, t, cache, fb)
                if !(sg.lo[d] <= sub <= sg.hi[d])
                    g = true
                    break
                end
                off += (sub - sg.lo[d]) * sg.strides[d]
            end
            mask[l] = g
            slots[l] = g ? 1 : sg.slot_flat[off + 1]
            anyghost |= g
        end
        gth = _oop_gather(u, slots, fb.memo)
        return anyghost ? ifelse.(mask, zero(T), gth) : gth
    elseif k === _NK_CONTRACTION_LOOP
        # The whole group's reduction in ONE loop of L_iter whole-lane steps:
        # per iteration, write every lane's counter, evaluate the body once over
        # lanes, accumulate elementwise. Per lane this is the scalar loop's
        # ascending-k fold seeded from the same 0̄ — bit-identical.
        body = @inbounds b.children[1]
        op = b.op
        refs = b.refs
        s::Any = convert(T, b.literal)
        if op === :+
            for kk in b.lo:b.step:b.hi
                @inbounds for r in refs; r[] = kk; end
                s = s .+ _oop_eval_batch(body, u, p, t, cache, fb)
            end
        elseif op === :*
            for kk in b.lo:b.step:b.hi
                @inbounds for r in refs; r[] = kk; end
                s = s .* _oop_eval_batch(body, u, p, t, cache, fb)
            end
        elseif op === :max
            for kk in b.lo:b.step:b.hi
                @inbounds for r in refs; r[] = kk; end
                s = max.(s, _oop_eval_batch(body, u, p, t, cache, fb))
            end
        else  # :min
            for kk in b.lo:b.step:b.hi
                @inbounds for r in refs; r[] = kk; end
                s = min.(s, _oop_eval_batch(body, u, p, t, cache, fb))
            end
        end
        return s
    elseif k === _NK_CONTRACTION
        # Fixed-width ⊕-fold, child order, seeded from 0̄ — `_oop_contraction`
        # per lane.
        ch = b.children
        res::Any = convert(T, b.literal)
        if b.op === :+
            for i in eachindex(ch)
                res = res .+ _oop_eval_batch(ch[i], u, p, t, cache, fb)
            end
        elseif b.op === :*
            for i in eachindex(ch)
                res = res .* _oop_eval_batch(ch[i], u, p, t, cache, fb)
            end
        elseif b.op === :max
            for i in eachindex(ch)
                res = max.(res, _oop_eval_batch(ch[i], u, p, t, cache, fb))
            end
        else  # :min
            for i in eachindex(ch)
                res = min.(res, _oop_eval_batch(ch[i], u, p, t, cache, fb))
            end
        end
        return res
    else  # _NK_OP
        op = b.op
        ch = b.children
        if op === :fn
            cv = Any[_oop_eval_batch(c, u, p, t, cache, fb) for c in ch]
            return _oop_batch_fn(b.payload, cv, T)
        elseif (op === :^ || op === :pow) && length(ch) == 2
            # A literal exponent stays a literal (see `_oop_pow`); the signature
            # pinned it, so a literal exponent is always the SHARED-literal form.
            base = _oop_eval_batch(ch[1], u, p, t, cache, fb)
            e = @inbounds ch[2]
            (e.kind === _NK_LITERAL && isempty(e.lanes_f)) && return base .^ e.literal
            return base .^ _oop_eval_batch(e, u, p, t, cache, fb)
        end
        c = Vector{Any}(undef, length(ch))
        for i in eachindex(ch)
            c[i] = _oop_eval_batch(ch[i], u, p, t, cache, fb)
        end
        return _oop_op(op, c, T)
    end
end

# Run one batch surface: leftover singles first (original order), then each
# group as one whole-lane evaluation landing through ONE scatter. Slots within
# the surface are disjoint and the entries never read each other (section
# header), so the values are the per-entry scalar walk's, bit for bit.
function _oop_run_scalar_batches(du, sb::_OopScalarBatches, ue, p, t,
                                 cache::AbstractVector{T}, fb::_OopForcing) where {T}
    rl = sb.rest
    @inbounds for i in eachindex(rl)
        slot, node = rl[i]
        du = _oop_store(du, slot, _oop_eval(node, ue, p, t, cache, fb))
    end
    gs = sb.groups
    for i in eachindex(gs)
        g = gs[i]
        du = _oop_scatter(du, g.slots, _oop_eval_batch(g.root, ue, p, t, cache, fb))
    end
    return du
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
# The same reasoning covers the B3 TIME tier: with a per-call cache there is nothing
# valid to skip to, so `:oop` refills time slots every call too — and is therefore
# also the natural untiered oracle for the t-tier differential tests. The build still
# REPORTS `n_const_slots` / `n_time_slots` / `n_dynamic_slots` for an `:oop` build;
# the classification is a property of the prelude, not of the emitter.
# ---------------------------------------------------------------------------
# J5 — REFUSE TO BE XLA-COMPILED WHILE A LIVE FORCING BUFFER IS A CAPTURE.
#
# A `_NK_PARAM_GATHER` payload is an ALIASED HOST `Vector{Float64}` — the same
# object the caller passed through `param_arrays`, so that a discrete-cadence
# refresh callback's in-place `buffer .= …` is seen by the RHS with zero
# reallocation. That aliasing is the whole point of the channel, and it is
# exactly what an XLA tracer cannot honour: to the tracer a captured host vector
# is a CONSTANT, so `@compile` bakes the buffer's compile-time contents into the
# program and the refresh is never seen again.
#
# The failure mode is the dangerous one — not an exception, not a NaN, but THE
# SAME NUMBERS FOREVER, off by the full magnitude of every forcing update. A
# silently wrong answer is worse than no answer, so this refuses.
#
# The SUPPORTED tracing route (B2) is the explicit-buffers form: `rhs_with_buffers`
# hands out `rhs(u, p, t, buffers)`, and a trace that passes TRACED buffers (the
# `buffers` argument arrives Reactant-rooted) is legal — every forcing read then
# lands on a real XLA input, and `copyto!` into those same device arrays at each
# cadence boundary IS seen by the compiled program. The refusal therefore fires
# only when a trace reaches the walk while the buffers are still HOST arrays —
# i.e. the 3-arg wrapper (which forwards its captured host buffers) or an
# explicit call that passed host buffers under tracing.
#
# The refusal fires during the TRACE (i.e. inside `@compile`), not at build time,
# because build time cannot distinguish the consumers: the interpreted
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

# Are the buffers this call carries real trace INPUTS? True iff every entry of
# the `buffers` argument is Reactant-rooted (a `TracedRArray` during a trace).
# `all` over an empty container is `true`, but the guard only consults this when
# `live_forcing` holds, and live forcing implies a non-empty buffers container.
_forcing_traced(bufs) = all(_reactant_rooted, values(bufs))

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
#         (variant, region), shared). The in-place codegen emitter declines
#         these the same way (sub-kernel spines carry foreign scratch); this
#         path does not vectorize them either.
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
            # runners read as 0.0 — is gathered at a SAFE index (1, always valid)
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
                        sub::_OopSubRT, fb::_OopForcing, ::Type{T}) where {T}
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
            return _oop_gather(u, plan.gathers[nd.idx], fb.memo)
        elseif ak === _AK_STATE_TBL_BOX
            g = _oop_gather(u, plan.gathers[nd.idx], fb.memo)
            m = plan.ghost[nd.idx]
            # ghost lanes (table slot 0) select 0.0 — the in-place runners'
            # `s == 0 ? 0.0 : u[s]`, bit-identical; the gather used a safe index.
            return isempty(m) ? g : ifelse.(m, zero(T), g)
        elseif ak === _AK_STATE_FIXED
            return convert(T, _oop_read_state(u, a.idx))
        elseif ak === _AK_SCALAR
            return convert(T, a.v)
        elseif ak === _AK_ARR_FIXED
            # LIVE forcing (invariant slot): re-read per call — data, zero
            # derivative. Through the `buffers` argument (see `_OopForcing`), so
            # a trace reads a real input; the seam makes the scalar read legal.
            return convert(T, _oop_read_forcing(_oop_forcing_slab(fb, a.arr), a.idx))
        elseif ak === _AK_FORCING_BOX || ak === _AK_ARR_TBL_BOX
            # LIVE forcing lanes: re-gathered per call from the `buffers`
            # argument — one whole-array gather at host-frozen indices, which
            # traces as-is (the indices are constants; the buffer is an input).
            return _oop_gather(_oop_forcing_slab(fb, a.arr), plan.forc[nd.idx], fb.memo)
        else
            # CONST_AFFINE / CONST_BOX / LOOP_IDX / CONST_CELL: frozen lane data.
            return plan.consts[nd.idx]
        end
    elseif k === _NK_LITERAL
        return convert(T, nd.literal)
    elseif k === _NK_PARAM
        return convert(T, _read_param(p, nd.sym, nd.idx))
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
            cv[i] = _oop_eval_acck(rs[i], u, p, t, S, Sp, iv, cv, sub, fb, T)
        end
        return _oop_eval_acck(S.spine, u, p, t, S, Sp, iv, cv, sub, fb, T)
    elseif k === _NK_REDUCE
        # Variable-valence sum reduction, CSR-segmented (gordian reduce-vectorize):
        # evaluate the body ONCE over the flat E-lane buffer (its only state access
        # is the whole-array gather in the E-plan), then fold each cell's segment
        # SEQUENTIALLY in child (CSR) order, seeded from `zerobar` — bit-identical
        # to `_eval_acc`'s `s = zerobar; for m in 1:cnt; s += body(c,m)`.
        Ep = @inbounds plan.red_plan[1]
        bodyE = _oop_eval_acck(nd.children[1], u, p, t, K, Ep, invvals, cellvals, sub, fb, T)
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
                res = res .+ _oop_eval_acck(ch[i], u, p, t, K, plan, invvals, cellvals, sub, fb, T)
            end
        elseif op === :*
            for i in eachindex(ch)
                res = res .* _oop_eval_acck(ch[i], u, p, t, K, plan, invvals, cellvals, sub, fb, T)
            end
        elseif op === :max
            for i in eachindex(ch)
                res = max.(res, _oop_eval_acck(ch[i], u, p, t, K, plan,
                                               invvals, cellvals, sub, fb, T))
            end
        else  # :min
            for i in eachindex(ch)
                res = min.(res, _oop_eval_acck(ch[i], u, p, t, K, plan,
                                               invvals, cellvals, sub, fb, T))
            end
        end
        return res
    else # _NK_OP
        op = nd.op
        ch = nd.children
        if op === :fn
            return _oop_acck_fn(nd, u, p, t, K, plan, invvals, cellvals, sub, fb, T)
        elseif (op === :^ || op === :pow) && length(ch) == 2
            # A literal exponent stays a literal — see `_oop_pow`.
            base = _oop_eval_acck(ch[1], u, p, t, K, plan, invvals, cellvals, sub, fb, T)
            e = ch[2]
            return e.kind === _NK_LITERAL ? base .^ e.literal :
                   base .^ _oop_eval_acck(e, u, p, t, K, plan, invvals, cellvals, sub, fb, T)
        end
        c = Vector{Any}(undef, length(ch))
        for i in eachindex(ch)
            c[i] = _oop_eval_acck(ch[i], u, p, t, K, plan, invvals, cellvals, sub, fb, T)
        end
        return _oop_op(op, c, T)
    end
end

function _oop_acck_fn(nd::_Node, u, p, t, K::_AccKernel, plan::_OopAccPlan,
                      invvals::Vector{Any}, cellvals::Vector{Any},
                      sub::_OopSubRT, fb::_OopForcing, ::Type{T}) where {T}
    pl = nd.payload
    ch = nd.children
    ev(x) = _oop_eval_acck(x, u, p, t, K, plan, invvals, cellvals, sub, fb, T)
    if pl isa Tuple{String,_InterpLinearSpec}
        return _oop_interp_linear_lanes(pl[2], ev(ch[1]), T)
    elseif pl isa Tuple{String,_InterpBilinearSpec}
        return _oop_interp_bilinear_lanes(pl[2], ev(ch[1]), ev(ch[2]), T)
    elseif pl isa Tuple{String,_InterpSearchsortedSpec}
        return _oop_interp_searchsorted_lanes(pl[2], ev(ch[1]), T)
    elseif pl isa Tuple{String,_InterpLinearLaneSpec}
        # Per-lane spec tables (kernel-class merge): the lane-column twins of
        # the arms above — lane l reads its member's own knots.
        return _oop_interp_linear_lanes(pl[2], ev(ch[1]), T)
    elseif pl isa Tuple{String,_InterpBilinearLaneSpec}
        return _oop_interp_bilinear_lanes(pl[2], ev(ch[1]), ev(ch[2]), T)
    elseif pl isa Tuple{String,_InterpSearchsortedLaneSpec}
        return _oop_interp_searchsorted_lanes(pl[2], ev(ch[1]), T)
    elseif pl isa Tuple{String,_FnTypedCoreSpec}
        # Registry-declared typed scalar core (ess-dtcore). At `T === Float64`
        # ONE typed broadcast over the lane vector — same `_fn_typed_core_call`
        # as every other tier's Float64 path, no per-lane `Any[]` box, no
        # opaque per-lane call. Every other `T` (a `Dual` walk, a traced walk)
        # keeps the boxed per-lane route below verbatim — including its
        # loud-failure property under a trace (the calendar decomposition then
        # stays inside the program via `evaluate_closed_function_ad`).
        if T === Float64
            return _fn_typed_core_call.(pl[2].id, ev(ch[1]))
        end
        fname = pl[1]
        cv = Any[ev(ci) for ci in ch]
        return broadcast((as...) -> convert(T, _eval_closed_fn(fname, Any[as...], T)),
                         cv...)
    elseif pl isa Tuple{String,Nothing}
        # All-scalar closed functions WITHOUT a typed-core row (none in the
        # v0.3.0 set): boxed, one call per lane — host-correct; a trace fails
        # loudly inside the opaque callee.
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
                          ::Type{T}, fb::_OopForcing=_OOP_NO_FORCING) where {T}
    sub = _oop_build_subrt(plan)
    for j in eachindex(sub.subs)
        S = @inbounds sub.subs[j]
        Sp = @inbounds sub.plans[j]
        iv = @inbounds sub.invvals[j]; cv = @inbounds sub.cellvals[j]
        ir = S.cse.inv_recipes
        @inbounds for i in eachindex(ir)
            iv[i] = _oop_eval_acck(ir[i], u, p, t, S, Sp, iv, cv, sub, fb, T)
        end
    end
    cse = K.cse
    invvals = Vector{Any}(undef, length(cse.inv_recipes))
    cellvals = Vector{Any}(undef, length(cse.recipes))
    for i in eachindex(cse.inv_recipes)
        invvals[i] = _oop_eval_acck(cse.inv_recipes[i], u, p, t, K, plan,
                                    invvals, cellvals, sub, fb, T)
    end
    for i in eachindex(cse.recipes)
        cellvals[i] = _oop_eval_acck(cse.recipes[i], u, p, t, K, plan,
                                     invvals, cellvals, sub, fb, T)
    end
    res = _oop_eval_acck(K.spine, u, p, t, K, plan, invvals, cellvals, sub, fb, T)
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

# ---- The RHS wrapper: buffers as arguments, arity preserved (B2) -------------
#
# `build_evaluator(model; form = :oop)` returns one of these in the `f!` slot.
# It IS the backward-compatible 3-arg RHS — `f(u, p, t) -> du`, exactly the arity
# SciML dispatches `ODEProblem` on, forwarding the build's own HOST buffers — and
# it also CARRIES the explicit-buffers form a tracing backend compiles.
#
# Deliberately NO 4-arg call method on the wrapper itself: SciMLBase infers
# in-place-ness from a 4-argument method (`f!(du, u, p, t)`), so adding one would
# make `ODEProblem(f, …)` misread this out-of-place RHS as in-place. The explicit
# form is handed out by `rhs_with_buffers` instead.
struct _OopRHS{F,B} <: Function
    rhs::F                          # rhs(u, p, t, buffers) -> du  (explicit form)
    buffers::B                      # NamedTuple: name => aliased HOST buffer, stable order
    buffer_index::Dict{String,Int}  # buffer name -> position in `buffers`
end
(f::_OopRHS)(u, p, t) = f.rhs(u, p, t, f.buffers)

"""
    rhs_with_buffers(f) -> rhs

The explicit-buffers form of an out-of-place RHS built by
`build_evaluator(model; form = :oop)`: a function `rhs(u, p, t, buffers) -> du`
whose LIVE FORCING BUFFERS (`param_arrays` entries and [`DiscreteMaterializer`](@ref)
caches) arrive through the ARGUMENT LIST instead of being read off the compiled
IR's captured host arrays. `buffers` must be a container aligned with
[`forcing_buffers`](@ref)`(f)` — same length, same (stable, name-sorted) order;
pass `forcing_buffers(f)` itself for host evaluation (that is exactly what
calling `f(u, p, t)` does), or an aligned NamedTuple of device arrays
(`Reactant.ConcreteRArray`s) when compiling with `@compile`. In the compiled
program each buffer is a real XLA input, so an in-place `copyto!` into those
same device arrays between calls — see [`sync_forcing!`](@ref) — IS observed on
the next call: the discrete-cadence refresh model survives compilation with no
retrace.
"""
rhs_with_buffers(f::_OopRHS) = f.rhs

"""
    forcing_buffers(f) -> NamedTuple

The live forcing buffers of an out-of-place RHS from
`build_evaluator(model; form = :oop)`, as a NamedTuple in a STABLE order (buffer
names sorted): every `param_arrays` entry and every [`DiscreteMaterializer`](@ref)
cache, each value the aliased flat host view of the exact array the build bound
— NOT a copy, so a discrete-cadence refresh writing the original array is
visible through this container. Position of a name is
[`forcing_buffer_index`](@ref)`(f)[name]`. Empty for a model with no live
forcing.
"""
forcing_buffers(f::_OopRHS) = f.buffers

"""
    forcing_buffer_index(f) -> Dict{String,Int}

Name → position map for [`forcing_buffers`](@ref)`(f)`: `forcing_buffer_index(f)[name]`
is the index of buffer `name` in the buffers container (and in any aligned
container passed to [`rhs_with_buffers`](@ref)`(f)`). Treat as read-only.
"""
forcing_buffer_index(f::_OopRHS) = f.buffer_index

# Fill ONE materialized-observed level out of place, mirroring
# `_fill_obs_levels!` (build.jl) statement for statement — scalar entries, then
# the level's access kernels, then its prefix reductions — but threading the
# extended vector functionally, because a tracing backend's `_oop_store` returns
# a new value rather than mutating.
#
# Output AND state are both `ue`: a fill reads the state and every STRICTLY
# LOWER level, which are already valid in `ue`, exactly as the in-place wrapper
# arranges. `_oop_eval` wants a CSE cache; a fill body is compiled without one
# (`_materialized_fill_equation` goes straight through `_compile`), so it gets an
# empty view of the caller's — allocating a fresh empty vector per level per call
# would defeat the point of the seam.
#
# The level's `scalars` run through the lane-batched surface (`sb`, built once
# at closure build by `_make_rhs_oop` — see the ess-oop-batch section): the
# per-column fills a level fragments into are exactly the congruent-instance
# shape batching exists for, and under a trace they were the last O(grid)
# scalar surface. Singles first, then groups; disjoint slots + the
# strictly-lower-level read invariant make that reorder value-exact.
@inline function _oop_fill_level(ue, lvl, sb::_OopScalarBatches, p, t, ::Type{T},
                                 fb, empty_cache) where {T}
    scalars, kernels, plans, scans = lvl
    ue = _oop_run_scalar_batches(ue, sb, ue, p, t, empty_cache, fb)
    for j in eachindex(kernels)
        plan = plans[j]
        ue = plan.vectorizable ?
             _oop_run_acc_vec(ue, ue, p, t, kernels[j], plan, T, fb) :
             _oop_run_acc_kernel(ue, ue, p, t, kernels[j], T)
    end
    isempty(scans) || (ue = _apply_scan_folds_oop(ue, scans))
    return ue
end

# Walk the levels as a TUPLE by tail recursion, for the reason `_fill_obs_levels!`
# does: a `Vector` of heterogeneously-parameterized levels boxes each one and
# costs an allocation per level per call.
@inline _oop_fill_levels(ue, ::Tuple{}, sbs::Tuple, p, t, ::Type{T}, fb, ec) where {T} = ue
@inline function _oop_fill_levels(ue, levels::Tuple, sbs::Tuple, p, t, ::Type{T},
                                  fb, ec) where {T}
    ue = _oop_fill_level(ue, levels[1], sbs[1], p, t, T, fb, ec)
    return _oop_fill_levels(ue, Base.tail(levels), Base.tail(sbs), p, t, T, fb, ec)
end

function _make_rhs_oop(rhs_list::AbstractVector{Tuple{Int,_Node}},
                       cse_prelude::AbstractVector{_Node},
                       acc_kernels::AbstractVector{_AccKernel},
                       n_states::Int,
                       pgather::AbstractDict=_EMPTY_PGATHER,
                       scan_folds::AbstractVector{_ScanFold}=_ScanFold[],
                       mat_levels::Tuple=(),
                       n_total::Int=n_states)
    n_cse = length(cse_prelude)
    # J5 covers BOTH IR families: the `_NK_PARAM_GATHER` scalar scan and the
    # acc-descriptor scan (`_AK_FORCING_BOX`/`_AK_ARR_FIXED`/`_AK_ARR_TBL_BOX`)
    # — an affine build over live forcing must refuse a host-buffer trace all
    # the same.
    live_forcing = _has_live_forcing(cse_prelude, rhs_list) ||
                   any(_acc_has_live_forcing, acc_kernels)
    # Vectorized lane plans for the acc kernels (host index data, built once).
    # The kernel-CLASS merge (oop_merge.jl) no longer runs here: it is hoisted
    # into `_build_evaluator_impl` phase 4 (`_merge_acc_kernel_classes`), before
    # the xcse gate, so BOTH emitters receive already-merged kernels and this
    # plan build is over the merged (fewer) list. `acc_kernels` (parameter,
    # never reassigned) and `acc_plans` (bound exactly once) are captured
    # UNBOXED by the `rhs` closure below, with the stable field names
    # :acc_kernels / :acc_plans that external tooling reflects on.
    acc_plans = _OopAccPlan[_build_oop_acc_plan(K) for K in acc_kernels]
    # The buffers container (B2): every live forcing buffer this build registered
    # — raw `param_arrays` entries AND DiscreteMaterializer caches, both of which
    # live in `pgather` by the time this runs — in a STABLE order (names sorted),
    # as a NamedTuple of the aliased flat host views. `host_keys` carries the same
    # arrays positionally: the walkers identity-match a node payload / acc
    # descriptor against it to swap the captured array for the argument entry.
    # Lane-batched scalar surfaces (ess-oop-batch), grouped ONCE at closure
    # build: the rhs_list per-cell entries and each fill level's per-column
    # scalars. `rhs_list`/`mat_levels` stay captured under their stable field
    # names (external tooling reflects on them); `rhs_batches`/`mat_batches`
    # are ADDITIVE fields — the closure-reflection witness for the feature (a
    # group count of zero means everything runs the scalar path, exactly as
    # before this feature existed).
    rhs_batches = _oop_batch_scalars(rhs_list)
    mat_batches = map(lvl -> _oop_batch_scalars(lvl[1]::Vector{Tuple{Int,_Node}}),
                      mat_levels)
    buf_names = sort!(String[String(k) for k in keys(pgather)])
    host_bufs = NamedTuple{Tuple(Symbol(n) for n in buf_names)}(
        Tuple((pgather[n]::_PGatherArray).flat for n in buf_names))
    buffer_index = Dict{String,Int}(n => i for (i, n) in enumerate(buf_names))
    host_keys = Vector{Float64}[(pgather[n]::_PGatherArray).flat for n in buf_names]
    function rhs(u, p, t, buffers)
        _reject_float32_state(u)   # loud, statically-folded (see compile.jl)
        if live_forcing && _is_traced(u, p, t) && !_forcing_traced(buffers)
            throw(TreeWalkError("E_TREEWALK_XLA_LIVE_FORCING",
                "This model binds a live forcing buffer through `param_arrays`, and " *
                "an XLA/Reactant tracer cannot honour a HOST buffer: the tracer " *
                "captures it as a CONSTANT. `@compile` would bake in its compile-time " *
                "contents and then silently ignore every in-place refresh a " *
                "data-refresh callback performs — the same numbers forever, with no " *
                "exception and no NaN. Either compile the explicit-buffers form " *
                "(`rhs_with_buffers(f)`) passing the forcing buffers as traced " *
                "arguments (`ConcreteRArray`s; refresh them with `copyto!` / " *
                "`sync_forcing!` at each cadence boundary), or drop `param_arrays` and " *
                "pass the forcing data as `const_arrays` (frozen, inlined — correct if " *
                "the data never changes), or run the interpreted evaluator, which does " *
                "track the refresh."))
        end
        # `_oop_new_memo(u)` is `nothing` for every host element type — the field
        # is then zero-sized and every `_oop_gather` third argument folds away.
        # Under a Reactant trace the extension returns a fresh per-CALL
        # `(SSA value, window)` read memo; it is built here and dropped when this
        # call returns, which is why nothing has to be torn down. See the
        # interning note at the `_oop_gather` seam for why ONE INVOCATION is both
        # the correct scope and the largest sound one.
        fb = _OopForcing(buffers, host_keys, _oop_new_memo(u))
        T = _oop_value_type(u, p, t)

        # Factored array observeds, filled per call into the block above the ODE
        # state — the out-of-place twin of `_make_rhs_with_obs_buffers`. `ue` is
        # `u` widened to `n_total`, so a reader's `index(<observed>, i…)` resolves
        # through the ordinary array-gather path onto the observed's slots. With
        # nothing materialized this is `ue === u` and the whole prelude folds away,
        # leaving the closure byte-identical to the pre-change one.
        #
        # The CSE cache is built from `ue`, NOT `u`: with observeds materialized
        # the state prelude may reference their slots, and the in-place wrapper
        # gets this for free by evaluating its whole state RHS against `ue`.
        ue = u
        if !isempty(mat_levels)
            ue = _oop_prefix_copy(_oop_du_zeros(u, T, n_total), u, n_states)
            ue = _oop_fill_levels(ue, mat_levels, mat_batches, p, t, T, fb,
                                  _EMPTY_OOP_CACHE(T))
        end

        cache = Vector{T}(undef, n_cse)
        @inbounds for s in 1:n_cse
            cache[s] = _oop_eval(cse_prelude[s], ue, p, t, cache, fb)
        end

        # Scalar state equations, through the lane-batched surface (ess-oop-
        # batch): the leftover singles are the pre-feature per-entry walk; each
        # group is one whole-lane evaluation + one scatter into disjoint slots.
        # (The `isempty(rhs_list)` guard is also what keeps `rhs_list` a
        # captured field of this closure — part of its stable reflection
        # surface — now that the entries themselves live in `rhs_batches`.)
        du = _oop_du_zeros(u, T, n_states)
        if !isempty(rhs_list)
            du = _oop_run_scalar_batches(du, rhs_batches, ue, p, t, cache, fb)
        end

        # Access kernels (the unified array IR), out of place. The vectorized form
        # (whole-array gathers/ops, one scatter — the TRACEABLE form) where the
        # plan permits; the per-cell `_oop_store` walk otherwise. On host both
        # produce the values `f!`'s in-place runners write, in the same slots, so
        # a Float64 `:oop` run stays bit-identical to `:inplace`.
        for j in eachindex(acc_kernels)
            plan = acc_plans[j]
            du = plan.vectorizable ?
                 _oop_run_acc_vec(du, ue, p, t, acc_kernels[j], plan, T, fb) :
                 _oop_run_acc_kernel(du, ue, p, t, acc_kernels[j], T)
        end

        # Cumulative (prefix) reductions (ess-scan, scan.jl): fold the per-cell
        # terms the kernels above just stored, along each scanned axis.
        isempty(scan_folds) || (du = _apply_scan_folds_oop(du, scan_folds))
        return du
    end
    return _OopRHS(rhs, host_bufs, buffer_index)
end
