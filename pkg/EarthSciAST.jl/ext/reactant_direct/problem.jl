# ========================================================================
# ext/reactant_direct/problem.jl — `esm_problem(…; compiler = :xla)`.
# ========================================================================
#
# The bridge between the direct StableHLO emitter (api.jl) and the Problem
# surface of API_SPEC §5.8; the Reactant-free part (availability, device choice,
# refusals, report row) is in src/compiler_xla.jl.
#
# One compile per build: `u`, `p` and `t` are program inputs, so a whole run, and
# `remake(prob; p, u0, tspan)`, reuses the one executable. `XlaProblemRHS` adapts
# the out-of-place device program (`d(u, p, t) -> du`) to the Problem's in-place
# host `f!`. Between calls:
#
#   the state input   one `ConcreteRArray`, written with `copyto!` per call (an
#                     argument array is a real XLA input, so the compiled
#                     program sees the write);
#   the parameters    rebuilt only when the `p` handed over is not the one on the
#                     device, so `remake(prob; p = …)` takes effect on the next
#                     call;
#   the time          a fresh `ConcreteRNumber` per call (it has no in-place
#                     write).
#
# The reused state input makes the wrapper stateful: two runs of one Problem
# must not be in flight at once, the `:native` closure's contract too.

"""
    XlaProblemRHS

The in-place right-hand side of an `esm_problem(…; compiler = :xla)` Problem: an
XLA executable of the directly emitted StableHLO, called as `f!(du, u, p, t)` on
ordinary host vectors.

Built by `EarthSciAST._xla_compile_rhs`; never constructed by hand. `stats` is
the emitter's op census of the program inside it, shared with the [`DirectRHS`](@ref)
it was compiled from and folded into the build's `compiler_report`.
"""
struct XlaProblemRHS{D, C, U, P} <: Function
    d::D                        # the DirectRHS wrapper that was emitted
    compiled::C                 # the XLA executable
    u_dev::U                    # the program's state input, written per call
    p_host::Base.RefValue{P}    # the `p` currently on the device
    p_dev::Base.RefValue{Any}   # …as device scalars
    stats::Dict{Symbol, Int}     # the emitter's op census (informational)
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
# The result goes straight from the device buffer into the integrator's `du`
# when `du` is a plain host vector, with no intermediate host array; any other
# `AbstractVector` takes the one extra copy through `Array`.
_xla_run_barrier!(du::Vector{Float64}, compiled, u_dev, p_dev, t_dev) =
    (copyto!(du, compiled(u_dev, p_dev, t_dev)); nothing)
_xla_run_barrier!(du, compiled, u_dev, p_dev, t_dev) =
    (copyto!(du, Array(compiled(u_dev, p_dev, t_dev))); nothing)

# `direct_client` raises an ordinary error when the platform asked for has no
# client in this process — a GPU requested on a host without one. The request
# was well formed and this process cannot provide it, which is
# `compiler_unavailable` by definition, so that is what the caller hears, and a
# conformance adapter records the binding as unavailable rather than as broken.
function _E._xla_client(device::AbstractString)
    try
        return direct_client(device)
    catch err
        _E._is_resource_error(err) && rethrow()
        throw(
            _E.SimulateError(
                "compiler=:xla was asked to run on '$device' " *
                    "($(_E.XLA_DEVICE_ENV)), and this process has no XLA client for " *
                    "it: $(sprint(showerror, err)). Run where that device is attached, " *
                    "or set $(_E.XLA_DEVICE_ENV)=cpu",
                _E.ERROR_CODES.COMPILER_UNAVAILABLE
            )
        )
    end
end

function _E._xla_compile_rhs(
        f::_E._OopRHS, var_map, u0::AbstractVector,
        p, device::AbstractString
    )
    d = direct_rhs(f; var_map = var_map, client = _E._xla_client(device))
    u_dev = direct_state(d, Array{Float64, 1}(u0))
    p_dev = direct_params(d, _xla_params(p))
    t_dev = direct_time(d, 0.0)
    compiled = _xla_compile_barrier(d, u_dev, p_dev, t_dev)
    return XlaProblemRHS(
        d, compiled, u_dev, Ref{Any}(p), Ref{Any}(p_dev),
        d.stats
    )
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
_xla_params(p) = _E._refuse_rule(
    _E._plan(:xla), "the parameter carrier",
    "compiler=:xla feeds parameters to the compiled program as Float64 device " *
        "scalars, and this build's `p` is a $(typeof(p)), which it will not " *
        "convert behind the author's back. Build with compiler=:native to run " *
        "this parameter carrier, or pass the scalars as the NamedTuple the build " *
        "produces"
)

function (w::XlaProblemRHS)(
        du::AbstractVector{Float64}, u::AbstractVector{Float64},
        p, t
    )
    copyto!(w.u_dev, u)
    if !(p === w.p_host[])
        w.p_host[] = p
        w.p_dev[] = direct_params(w.d, _xla_params(p))
    end
    _xla_run_barrier!(
        du, w.compiled, w.u_dev, w.p_dev[],
        direct_time(w.d, Float64(t))
    )
    return nothing
end

# PRECISION AND HOST DIFFERENTIATION. The emitted program is Float64 throughout
# (see api.jl), so a call carrying any other element type is refused by name
# rather than widened or narrowed. In practice this is what a caller hears when
# a stiff algorithm forward-differentiates the right-hand side to build its
# Jacobian: a compiled device program is not a Julia function a `Dual` can be
# pushed through, and the honest answer is to say so and name the two ways out.
(w::XlaProblemRHS)(du, u, p, t) = _xla_wrong_eltype(eltype(du), eltype(u))

_xla_wrong_eltype(::Type{TD}, ::Type{TU}) where {TD, TU} =
    _E._refuse_rule(
    _E._plan(:xla), "the right-hand side",
    "the compiled StableHLO program is Float64 throughout, and this call " *
        "carries du::$TD / u::$TU. A compiled device program cannot be " *
        "differentiated on the host. `solve` on the Problem already hands the " *
        "solver a finite-difference Jacobian through the compiled program; a " *
        "caller building its own `ODEProblem` from `prob.f!` needs one too " *
        "(`autodiff = AutoFiniteDiff()`), and a document that changes " *
        "precision needs compiler=:native"
)

function Base.show(io::IO, w::XlaProblemRHS)
    return print(
        io, "XlaProblemRHS(", length(w.u_dev), " state elements, direct ",
        "StableHLO on ", direct_platform(w.d), ")"
    )
end
