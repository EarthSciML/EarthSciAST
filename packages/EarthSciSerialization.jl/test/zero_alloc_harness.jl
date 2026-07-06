# Reusable zero-allocation harness for the tree-walk PDE RHS (ess-9cc).
#
# `build_evaluator` returns an in-place `f!(du, u, p, t)` that an ODE integrator
# calls every Runge–Kutta stage. For the runner to scale to large grids it must
# allocate NOTHING per call in steady state (after the first, compiling call) —
# otherwise every stage triggers GC pressure proportional to the grid size N.
#
# These helpers measure that property and are written to be reused by any future
# evaluator / vectorization work: pass any built `f!` (or a `Model` to build one)
# and assert the returned byte count is 0. They depend only on the built-in
# `@allocated`, so they add no test dependencies.
#
# Include guard (mirrors testutils.jl): normally pulled in once via
# `include("testutils.jl")`, but a direct include stays harmless.
if !isdefined(Main, :ESM_ZERO_ALLOC_HARNESS_LOADED)

const ESM_ZERO_ALLOC_HARNESS_LOADED = true

using EarthSciSerialization

"""
    rhs_alloc_bytes(f!, du, u0, p, t; warmup=3, samples=5) -> Int

Bytes allocated by a single steady-state `f!(du, u, p, t)` call. `f!` is invoked
`warmup` times first so every method/specialization is compiled and any one-shot
setup is paid, then the MINIMUM `@allocated` over `samples` measured calls is
returned. A genuinely non-allocating `f!` yields 0 on every sample; taking the
min discards incidental GC-safepoint accounting noise without ever masking a
real per-call allocation (a real allocation appears on every sample).
"""
function rhs_alloc_bytes(f!, du, u0, p, t; warmup::Int=3, samples::Int=5)
    for _ in 1:warmup
        f!(du, u0, p, t)
    end
    best = typemax(Int)
    for _ in 1:samples
        best = min(best, @allocated f!(du, u0, p, t))
    end
    return best
end

"""
    built_rhs_alloc_bytes(model; t=0.0, kwargs...) -> Int

Build `model`'s evaluator with `build_evaluator(model; kwargs...)` and return the
steady-state per-call allocation of its RHS (see [`rhs_alloc_bytes`](@ref)). The
state is the model's own initial condition; `kwargs` are forwarded verbatim
(`initial_conditions`, `const_arrays`, …).
"""
function built_rhs_alloc_bytes(model; t=0.0, kwargs...)
    f!, u0, p, _tspan, _vmap = build_evaluator(model; kwargs...)
    du = similar(u0)
    return rhs_alloc_bytes(f!, du, u0, p, t)
end

end # ESM_ZERO_ALLOC_HARNESS_LOADED guard
