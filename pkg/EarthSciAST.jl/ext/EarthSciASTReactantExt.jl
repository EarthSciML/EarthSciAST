"""
    EarthSciASTReactantExt

XLA tracing for the OUT-OF-PLACE RHS (`build_evaluator(model; form = :oop)`,
src/tree_walk/oop.jl), loaded automatically when `Reactant` is in the session.

WHAT THIS EXTENSION IS. Six methods on the five container SEAMS the out-of-place
walker already routes every state read and every `du` write through. Not a sixth
evaluator: `@compile`ing `f` runs the SAME tree walk, on the SAME compiled IR, with
`TracedRNumber`/`TracedRArray` in place of `Float64`/`Vector{Float64}` — the walk
executes once, at TRACE time, and what XLA gets is the flat op graph it left behind.
That is the whole reason the emitter is eltype-generic and buffer-free; `f!` cannot
be traced at all, because it captures a concrete `Vector{Float64}` scratch buffer per
`_VecNode` and XLA has nothing to do with a host buffer.

WHY THESE FIVE AND NOTHING ELSE. Everything in between — `_oop_op`'s broadcast ladder,
CSE, the semiring folds, the invariant hoist — is already legal StableHLO: broadcasting
`TracedRArray`s traces to elementwise ops, and `_oop_value_type` resolves to
`TracedRNumber{Float64}` on its own (`promote_type` over Reactant's number type does the
right thing), so `convert(T, literal)`, `zero(T)`, `one(T)` all trace. What is NOT legal
is exactly the container boundary:

  * SCALAR INDEXING of a traced array is REJECTED, not slow — Reactant errors with
    "Scalar indexing is disallowed" rather than silently emitting a per-element read.
    `_oop_read_state` / `_oop_store` are the only two places the walker does it, and
    both do it O(#scalar states) times (never O(#cells) — a lane axis goes through
    `_oop_gather`/`_oop_scatter`, which are whole-array ops and trace as-is). So
    `@allowscalar` here is a narrow, bounded assertion, not a blanket opt-out: it says
    "this index is on the scalar spine of the model", and the program size stays
    independent of the grid, which is the property the compiled IR exists to have.

  * The OUTPUT CONTAINER cannot come from `similar`. Under tracing
    `T === TracedRNumber{Float64}`, and `similar(u, T, n)` is a host `Vector` OF traced
    scalars — a Julia array holding trace handles, not a traced array. It has no MLIR
    value, so the trace has no output and the compile fails (or, worse, silently returns
    a constant). `_oop_du_zeros` takes the container from `Reactant.Ops.fill` instead.

LIVE FORCING BUFFERS ARE TRACED ARGUMENTS, NOT CAPTURES (B2). A live forcing
buffer (`param_arrays`, ess-14f.3; a `DiscreteMaterializer` cache is a `pgather`
entry by construction) is bound BY REFERENCE into `_NK_PARAM_GATHER` node payloads
and forcing acc descriptors. Under tracing a CAPTURED host array is a TRACE-TIME
CONSTANT: XLA bakes in whatever the buffer held at `@compile`, the discrete-cadence
refresh callback (src/data_refresh.jl) then writes the buffer in place, and the
compiled program does not see it — silently STALE forcing, no error, plausible
numbers. That defect was demonstrated, then fixed by moving the BINDING, not the
refresh model: the out-of-place RHS now carries an explicit-buffers form,
`rhs_with_buffers(f)(u, p, t, buffers)`, whose `buffers` container (see
`forcing_buffers` / `forcing_buffer_index`) arrives through the ARGUMENT LIST. An
array passed as an argument is a real XLA input, and `copyto!`-ing new values into
that same `ConcreteRArray` between calls IS seen by the already-compiled program
(measured, and pinned by test/reactant_oop_test.jl) — so the discrete-cadence model
survives compilation verbatim: one aliased buffer per forcing, refreshed in place at
each cadence boundary (`sync_forcing!` mirrors host → device inside the refresh
callback's `post_refresh` hook), no reallocation, no recompile. (Recompiling at each
boundary "works" and is the trap: silent, O(#boundaries) compiles, and a different
program at each one.)

The usage contract, then:

    fo   = build_evaluator(model; form = :oop, param_arrays = forcing)[1]
    dev  = map(ConcreteRArray, forcing_buffers(fo))
    xla  = @compile rhs_with_buffers(fo)(u_r, p_r, t_r, dev)
    # at each cadence boundary, after the host refresh:
    sync_forcing!(dev, forcing_buffers(fo))

`@compile`-ing the 3-ARG wrapper `fo(u, p, t)` over a live-forcing model still
REFUSES (audit J5): the wrapper forwards its captured HOST buffers, which is
exactly the silent-staleness configuration, so the walk throws
`E_TREEWALK_XLA_LIVE_FORCING` during the trace rather than bake them in. A model
with no `param_arrays` compiles through the 3-arg wrapper as before.
"""
module EarthSciASTReactantExt

using Reactant: Reactant, TracedRArray, TracedRNumber, @allowscalar

import EarthSciAST: _oop_read_state, _oop_gather, _oop_du_zeros, _oop_store,
    _oop_scatter, _oop_read_forcing

# ---- State reads -------------------------------------------------------------
#
# The scalar read. `u[i]` on a `TracedRArray` throws; under `@allowscalar` it traces
# to a slice + reshape and yields a `TracedRNumber`, which is what the walker's
# `convert(T, …)` wants. Returning a size-1 SLICE (`u[i:i]`) instead would broadcast
# correctly but is a `TracedRArray`, and `convert(TracedRNumber, ::TracedRArray)` is not
# a thing — so the scalar spine, not the lane axis, is where this method belongs.
@inline _oop_read_state(u::TracedRArray{T,1}, i::Int) where {T} = @allowscalar u[i]

# `_oop_gather` needs no method: `u[slots]` on a `TracedRArray` with a host
# `Vector{Int}` already traces to a whole-array gather (XLA then canonicalizes a
# contiguous run to a slice on its own). It is here as an explicit note so that the
# absence of a method reads as a decision rather than an oversight. The same
# applies to a forcing LANE read (`_AK_FORCING_BOX` / `_AK_ARR_TBL_BOX`): the
# walker routes it through `_oop_gather` over the traced buffers ARGUMENT.

# The scalar read of a live forcing buffer passed as a traced argument
# (`_NK_PARAM_GATHER` / `_AK_ARR_FIXED`). Same bounded-scalar-indexing argument
# as `_oop_read_state`: O(#scalar forcing reads), never O(#cells) — a forcing
# lane axis goes through `_oop_gather`, a whole-array op.
@inline _oop_read_forcing(buf::TracedRArray{T,1}, i::Int) where {T} =
    @allowscalar buf[i]

# ---- Output container --------------------------------------------------------
#
# `Ops.fill` builds a genuine `TracedRArray` of the state length. `T0` (the UNWRAPPED
# element type) is recovered from `u`, so a Float32 trace produces a Float32 `du`
# rather than silently widening.
@inline _oop_du_zeros(u::TracedRArray{T0,1}, ::Type{TracedRNumber{T0}},
                      n::Int) where {T0} = Reactant.Ops.fill(zero(T0), (n,))

# One scalar equation's `du` slot. Same bounded-scalar-indexing argument as
# `_oop_read_state`; mutation of a `TracedRArray` is tracked by the trace, so the
# returned `du` is the same object and the seam's rebinding contract is trivially met.
@inline function _oop_store(du::TracedRArray{T,1}, i::Int, v) where {T}
    @allowscalar du[i] = v
    return du
end

# One array kernel's whole result, in ONE traced scatter. The default seam loops
# cell-by-cell; doing that here would emit `length(out)` scatter ops and make the
# XLA program's SIZE grow with the grid — the exact property the vectorized IR is
# built to avoid.
#
# The scalar `res` arm is NOT a corner case: a single-cell kernel group — which is
# what every ghost-boundary cell of a stencil becomes — has all of its lanes merge
# equal, so its whole template hoists to `_VK_INVARIANT` and the kernel evaluates to
# ONE `TracedRNumber`. A 1-D stencil therefore hits this arm on both ends of the grid.
#
# `fill(res, n)` (a host `Vector` of `n` copies of the one trace handle, which
# Reactant materializes as a traced array) rather than the obvious `du[out] .= res`:
# broadcasting a traced SCALAR into a `view` of a traced array routes through
# `_setindex_scalar_cartesian!` and throws the scalar-indexing error, and it does so
# only when `length(out) == 1` — i.e. exactly on the boundary kernels, and never on
# the interior one that a quick test would look at. Placing the value carries no
# arithmetic, so it cannot perturb the result the way a `res .+ zeros(n)` would.
@inline function _oop_scatter(du::TracedRArray{T,1}, out::Vector{Int}, res) where {T}
    du[out] = res isa AbstractArray ? res : fill(res, length(out))
    return du
end

end # module
