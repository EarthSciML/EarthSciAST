# ========================================================================
# ext/reactant_direct/problem.jl — `esm_problem(…; compiler = :xla)`.
# ========================================================================
#
# The bridge between the direct StableHLO emitter (api.jl) and the Problem
# surface of API_SPEC §5.8. src/compiler_xla.jl holds everything about this
# that can be said without Reactant — the availability answer, the device
# choice, the refusal vocabulary, the report row; here is the part that cannot:
# `direct_rhs`, `Reactant.@compile` and the device inputs.
#
# ONE COMPILE PER BUILD. `u`, `p` and `t` are program INPUTS, so a whole run —
# every step, every stage, every save — is served by the single executable built
# here. Nothing recompiles per call, and `remake(prob; p, u0, tspan)` reuses it
# as it reuses a `:native` closure.
#
# THE CALLING CONVENTION IS THE PROBLEM'S, NOT THE EMITTER'S. The emitted
# program is out-of-place on device arrays (`d(u, p, t) -> du`); the Problem's
# `f!` slot is in-place on host vectors. `XlaProblemRHS` is that adapter, and it
# is where the two host copies live: `u` into the program's state input, the
# result back into `du`.
#
# WHAT IS REUSED BETWEEN CALLS, AND WHY EACH CHOICE.
#
#   the state input   ONE `ConcreteRArray`, written with `copyto!` per call. A
#                     device array passed as an ARGUMENT is a real XLA input, so
#                     writing it between calls is seen by the already-compiled
#                     program — the same property `sync_forcing!` relies on —
#                     and it keeps a per-step allocation off the hot path.
#   the parameters    rebuilt only when the `p` the integrator hands over is not
#                     the one already on the device. A solver passes the same
#                     `p` on every call of a run, so this is once per run, while
#                     `remake(prob; p = …)` — which swaps `p` and nothing else —
#                     is picked up on the next call with no recompile.
#   the time          a fresh `ConcreteRNumber` per call. It is one scalar, and
#                     a `ConcreteRNumber` has no in-place write; the emitter's
#                     own conformance adapter feeds a fresh one per probe for
#                     the same reason.
#
# A SINGLE-TASK CONTRACT. The reused state input makes this wrapper stateful, so
# two RUNS of the same Problem must not be in flight at once — which is already
# the `:native` closure's contract (its prelude scratch is shared the same way).

"""
    XlaProblemRHS

The in-place right-hand side of an `esm_problem(…; compiler = :xla)` Problem: an
XLA executable of the directly emitted StableHLO, called as `f!(du, u, p, t)` on
ordinary host vectors.

Built by `EarthSciAST._xla_compile_rhs`; never constructed by hand. `stats` is
the emitter's op census of the program inside it, shared with the [`DirectRHS`](@ref)
it was compiled from and folded into the build's `compiler_report`.
"""
struct XlaProblemRHS{D,C,U,P} <: Function
    d::D                        # the DirectRHS wrapper that was emitted
    compiled::C                 # the XLA executable
    u_dev::U                    # the program's state input, written per call
    p_host::Base.RefValue{P}    # the `p` currently on the device
    p_dev::Base.RefValue{Any}   # …as device scalars
    device::String              # "cpu" / "gpu" — what the report row records
    stats::Dict{Symbol,Int}     # the emitter's op census (informational)
end

# THE FUNCTION BARRIER IN FRONT OF `@compile`, for the reason spelled out at
# length in scripts/compiled_rhs_adapter.jl: at the call site below, the
# evaluator, the wrapper and the device inputs all come out of calls whose types
# depend on a document read at runtime, so they are `Any` there.
# `Reactant.@compile` expands to a generated function whose generator runs
# GPUCompiler, and inferring that through `Any`s sends Julia's abstract
# interpreter into a recursion that trips the stack-overflow guard and can WEDGE
# the process inside `typeinf` — no error, no progress, on the CPU client as
# readily as on a GPU one. Passing the values through a plain function first
# makes Julia specialize on their runtime types, so inside the barrier every
# argument is concrete and the compile is inferred exactly as it would be from a
# script that spelled the constructors out.
_xla_compile_barrier(d, u_dev, p_dev, t_dev) =
    Reactant.@compile sync = true d(u_dev, p_dev, t_dev)
_xla_run_barrier(compiled, u_dev, p_dev, t_dev) =
    Array(compiled(u_dev, p_dev, t_dev))

function _E._xla_compile_rhs(f::_E._OopRHS, var_map, u0::AbstractVector,
                             p, device::AbstractString)
    cl = direct_client(device)
    d = direct_rhs(f; var_map = var_map, client = cl)
    u_dev = direct_state(d, Array{Float64,1}(u0))
    p_dev = direct_params(d, _xla_params(p))
    t_dev = direct_time(d, 0.0)
    compiled = _xla_compile_barrier(d, u_dev, p_dev, t_dev)
    return XlaProblemRHS(d, compiled, u_dev, Ref{Any}(p), Ref{Any}(p_dev),
                         String(device), d.stats)
end

# The parameter carrier the device builders accept. A parameter-free model
# carries SciMLBase's `nothing` sentinel, which passes straight through; a
# NamedTuple of scalars is the ordinary case. Anything else — a
# `ComponentVector`, a dual-number carrier from an outer differentiation — is
# refused BY NAME rather than converted, because the compiled program's
# parameter inputs are Float64 device scalars and silently narrowing an
# author's carrier into them is the class of wrong answer nothing in the result
# would reveal.
_xla_params(::Nothing) = nothing
_xla_params(p::NamedTuple) = p
_xla_params(p) = _E._xla_refuse("the parameter carrier",
    "compiler=:xla feeds parameters to the compiled program as Float64 device " *
    "scalars, and this build's `p` is a $(typeof(p)), which it will not " *
    "convert behind the author's back. Build with compiler=:native to run " *
    "this parameter carrier, or pass the scalars as the NamedTuple the build " *
    "produces")

function (w::XlaProblemRHS)(du::AbstractVector{Float64}, u::AbstractVector{Float64},
                            p, t)
    copyto!(w.u_dev, u)
    if !(p === w.p_host[])
        w.p_host[] = p
        w.p_dev[] = direct_params(w.d, _xla_params(p))
    end
    out = _xla_run_barrier(w.compiled, w.u_dev, w.p_dev[],
                           direct_time(w.d, Float64(t)))
    copyto!(du, out)
    return nothing
end

# PRECISION AND HOST DIFFERENTIATION. The emitted program is Float64 throughout
# (see api.jl), so a call carrying any other element type is refused by name
# rather than widened or narrowed. In practice this is what a caller hears when
# a stiff algorithm forward-differentiates the right-hand side to build its
# Jacobian: a compiled device program is not a Julia function a `Dual` can be
# pushed through, and the honest answer is to say so and name the two ways out.
(w::XlaProblemRHS)(du, u, p, t) = _xla_wrong_eltype(eltype(du), eltype(u))

_xla_wrong_eltype(::Type{TD}, ::Type{TU}) where {TD,TU} =
    _E._xla_refuse("the right-hand side",
        "the compiled StableHLO program is Float64 throughout, and this call " *
        "carries du::$TD / u::$TU. A compiled device program cannot be " *
        "differentiated on the host, so an algorithm that builds its Jacobian " *
        "by forward-differentiating the right-hand side needs a " *
        "finite-difference Jacobian instead (`autodiff = AutoFiniteDiff()`); a " *
        "document that changes precision needs compiler=:native")

function Base.show(io::IO, w::XlaProblemRHS)
    print(io, "XlaProblemRHS(", length(w.u_dev), " state elements, direct ",
          "StableHLO on ", direct_platform(w.d), ")")
end
