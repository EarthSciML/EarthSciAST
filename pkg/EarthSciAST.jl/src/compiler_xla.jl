# ============================================================
# compiler=:xla — the direct StableHLO emitter on the solve path
# (API_SPEC §5.8, esm-libraries-spec §2.5.2/§2.5.10)
# ============================================================
#
# `:xla` is a SPECIALTY compiler, and it is special in the second of §5.8's two
# ways: it needs a HEAVY EXTERNAL DEPENDENCY to exist at all. `interpreter` is
# the deliberately simple oracle the other compilers are checked against;
# `native` is the universally fast option with no heavy external dependency,
# which is why it is the default; `sympy` and `mtk` are specialty compilers that
# work only for some documents; `:xla` is the one that needs Reactant, and with
# it an XLA runtime, in the session.
#
# WHAT IS IN THIS FILE AND WHAT IS NOT. Everything here is Reactant-FREE: the
# availability answer, the device choice, the refusal vocabulary and the report
# row. The compile itself — `direct_rhs`, `Reactant.@compile`, the device
# arrays — is in ext/reactant_direct/problem.jl, behind the
# `_xla_compile_rhs` seam declared below, because `Reactant.@compile` is a macro
# that cannot be spelled in a package that does not depend on Reactant.
#
# HOW THE COMPILED PROGRAM SITS IN THE PROBLEM. `esm_problem(…; compiler = :xla)`
# builds the document `form = :oop` — the compiled tree-walk intermediate
# representation, which is what the direct emitter lowers — and then wraps the
# XLA executable in an IN-PLACE `f!(du, u, p, t)`. The Problem's public surface
# is therefore unchanged: `prob.f!` is still the in-place right-hand side
# `ODEFunction` reads as in-place, `u0`/`p`/`tspan`/`var_map`/`observed_field`
# are the same objects a `:native` build produces, and `solve(prob, alg; …)`
# needs no knowledge that the derivative came off an accelerator. This is the
# wiring the `compiled_rhs` adapter already proved (one compile per BUILD, never
# per call: `u`, `p` and `t` are program INPUTS), lifted onto the Problem.
#
# HOST ARRAYS IN, HOST ARRAYS OUT. The integrator owns `u` and `du` as ordinary
# `Vector{Float64}`s, so each call copies `u` into the program's device input
# and copies the result back into `du`. Keeping the state resident on the device
# across steps would mean owning the time loop, which is a different feature
# (an integrator, not a right-hand side) and is not what §5.8's `compiler`
# keyword promises.

"""
    _xla_extension() -> Module

The loaded Reactant extension, or `compiler_unavailable` naming what to load.

This is the AVAILABILITY answer for `:xla`, and it is deliberately separate from
the vocabulary answer: `:xla` is IN the closed vocabulary, so a session without
Reactant must hear `compiler_unavailable` ("in it, but this binding, build or
process cannot provide it"), never `compiler_unknown`. `_compiler_plan` calls
this on its `:xla` arm, before any document is loaded, so the caller hears it
without waiting through a load and a flatten.
"""
function _xla_extension()
    ext = Base.get_extension(@__MODULE__, :EarthSciASTReactantExt)
    ext === nothing && throw(SimulateError(
        "compiler=:xla needs Reactant loaded: it is the specialty compiler " *
        "that exists only with a heavy external dependency (Reactant bundles " *
        "the XLA runtime the emitted StableHLO is compiled and run on). Add " *
        "`using Reactant` to this session and build again, or build with " *
        "compiler=:native, the universally fast option that needs no external " *
        "dependency",
        ERROR_CODES.COMPILER_UNAVAILABLE))
    return ext
end

"""
    XLA_DEVICE_ENV

The environment variable naming WHERE an `:xla` build compiles and runs:
`"cpu"` (the default, always available) or `"gpu"`.

This is not an evaluation strategy and does not belong to the `compiler`
keyword: the same StableHLO module compiles on either platform, and §2.5.10's
rule is that no environment variable selects an EVALUATOR. Which machine the
evaluator runs on is the ordinary deployment question, spelled the same way the
`compiled_rhs` conformance adapter already spells it, and the answer is recorded
on the build's [`CompilerReport`](@ref) so a Problem still says where it ran.

The two ways this can go wrong get two different answers, because they mean two
different things:

* a value other than the two spellings is a CONFIGURATION error, an
  `ArgumentError`. A typo is not "this binding has no such compiler", and
  reporting it as `compiler_unavailable` would let a conformance run read it as
  an optional binding to skip and pass without running anything.
* `"gpu"` in a process with no GPU client is `compiler_unavailable`: the
  request is well formed, and this process cannot provide it.

Both are answered by `_compiler_plan(:xla)`, before any document is loaded.
"""
const XLA_DEVICE_ENV = "EARTHSCI_JULIA_XLA_DEVICE"

function _xla_device()
    d = lowercase(strip(get(ENV, XLA_DEVICE_ENV, "cpu")))
    isempty(d) && (d = "cpu")
    d in ("cpu", "gpu") || throw(ArgumentError(
        "$XLA_DEVICE_ENV must be 'cpu' or 'gpu', got '$d'"))
    return d
end

"""
    _xla_client(device) -> XLA client

The XLA client for `device` (`"cpu"` / `"gpu"`), or `compiler_unavailable` when
this process has none. **Declared here, implemented in the Reactant extension**
(ext/reactant_direct/problem.jl), which only [`_xla_extension`](@ref) lets a
caller reach.
"""
function _xla_client end

"""
    _xla_refuse(rule, reason) -> never returns

`compiler_refused_rule` for the `:xla` compiler, in the exact message shape
`_refuse_rule` produces — `compiler=:xla refuses '<rule>': <reason>` — which is
what esm-libraries-spec §2.5.10 fixes and what the compiler-agreement adapter
reads back.

It is spelled here rather than through `_refuse_rule` because these refusals are
raised AFTER the build's plan has gone out of scope (the emission happens on the
build's product, not inside it), and a refusal that read the ambient plan there
would name `:native` for a run the caller asked to be `:xla`.
"""
_xla_refuse(rule::AbstractString, reason::AbstractString) =
    throw(TreeWalkError(ERROR_CODES.COMPILER_REFUSED_RULE,
                        "compiler=:xla refuses '$rule': $reason"))

"""
    _xla_check_form(compiler, form)

`compiler = :xla` builds ONE thing: the out-of-place compiled intermediate
representation (`form = :oop`) that the direct StableHLO emitter lowers.
[`esm_problem`](@ref) then compiles that into the Problem's `f!`. The in-place
evaluator is `native`'s, so a build asked for `compiler = :xla` in the in-place
form would hand back a host closure under a report that says `:xla` — a
fallback in everything but name. It is an `ArgumentError` instead.
"""
function _xla_check_form(compiler::Symbol, form::Symbol)
    compiler === :xla && form !== :oop && throw(ArgumentError(
        "compiler=:xla builds only the out-of-place product (`form = :oop`) the " *
        "direct StableHLO emitter lowers, not the in-place evaluator (form " *
        ":$form), which is compiler=:native's. For a runnable :xla " *
        "right-hand side build `esm_problem(input, tspan; compiler = :xla)`; " *
        "for the in-place evaluator, build with compiler=:native"))
    return nothing
end

# A `DirectEmitError` IS the emitter's hard error — the construct it cannot
# lower and the rule it came from — so it becomes `compiler_refused_rule`
# verbatim rather than an anonymous failure. Nothing here retries, demotes or
# falls back: `:xla` either runs the whole document or names what it refused.
function _xla_refuse_emit(err::DirectEmitError)
    _xla_refuse(err.rule,
        "the direct StableHLO emitter cannot lower $(err.construct): $(err.detail)")
end

"""
    _xla_compile_rhs(f_oop, var_map, u0, p, device) -> callable

Compile an out-of-place build product into an in-place `f!(du, u, p, t)` backed
by an XLA executable on `device`'s client. **Declared here, implemented in the
Reactant extension** (ext/reactant_direct/problem.jl); a session without
Reactant never reaches it, because [`_xla_extension`](@ref) has already raised
`compiler_unavailable`.
"""
function _xla_compile_rhs end

# The refusal for a model that binds LIVE FORCING BUFFERS, named by the buffers.
# The compiled program takes such buffers as a fourth ARGUMENT
# (`direct_rhs_with_buffers`), and keeping them live across a run means syncing
# device copies at each cadence boundary through the refresh callback's
# `post_refresh` hook (`sync_forcing!`). That wiring is not on this entry point
# yet, and the alternative — the three-argument form — would BAKE the buffers in
# as constants and answer every step with the forcing the build happened to
# start with. A silently stale forcing is a wrong number with nothing in the
# result to say so, so it is a named refusal instead.
function _xla_refuse_live_buffers(names)
    ns = sort!(String.(collect(names)))
    _xla_refuse("live forcing buffers (" * join(ns, ", ") * ")",
        "this document binds $(length(ns)) live forcing buffer(s), which a " *
        "compiled program must receive as arguments and have re-synced to the " *
        "device at each cadence boundary; `esm_problem(…; compiler = :xla)` " *
        "does not wire that refresh yet, and the buffer-free form would bake " *
        "the build-time forcing in as a constant and run the whole simulation " *
        "against it. Build with compiler=:native, or drive the compiled lane " *
        "directly (`direct_rhs_with_buffers` + `sync_forcing!`)")
end

"""
    _xla_refuse_before_build(param_arrays)

The `:xla` refusals [`esm_problem`](@ref) can make BEFORE it builds anything. A
caller's `param_arrays` and every discrete data provider's buffer are known
before the build starts, and at continental scale the build is the expensive
part, so a document the compiler will refuse for its live forcing hears so
up front. [`_xla_problem_rhs`](@ref) keeps the same check on the build product
as the backstop for the buffers only the build creates (a
[`DiscreteMaterializer`](@ref) cache).
"""
function _xla_refuse_before_build(param_arrays::AbstractDict)
    isempty(param_arrays) || _xla_refuse_live_buffers(keys(param_arrays))
    return nothing
end

# `Reactant.@compile` runs the emission inside its own machinery, which may hand
# back what the trace threw wrapped in something else (a captured task failure,
# a composite of several). Dig the `DirectEmitError` out of whatever came back,
# so the refusal is named whichever way it arrives; `nothing` when the failure
# was not the emitter's.
function _find_direct_emit_error(e, depth::Int = 0)
    e isa DirectEmitError && return e
    depth > 16 && return nothing
    for f in (:error, :ex, :exception, :task, :captured, :result)
        if hasproperty(e, f)
            inner = getproperty(e, f)
            inner === e && continue
            r = _find_direct_emit_error(inner, depth + 1)
            r === nothing || return r
        end
    end
    if e isa CompositeException || e isa AbstractVector || e isa Tuple
        for x in e
            r = _find_direct_emit_error(x, depth + 1)
            r === nothing || return r
        end
    end
    return nothing
end

"""
    _xla_problem_rhs(f_oop, var_map, u0, p, report) -> callable

The `:xla` right-hand side for [`esm_problem`](@ref): the out-of-place build
product `f_oop` lowered to StableHLO, compiled on the chosen XLA client, and
wrapped in the in-place calling convention the Problem's `f!` slot promises.

Refuses, never falls back:

* a build product that binds LIVE FORCING BUFFERS. `esm_problem` has already
  refused the ones it could see before building
  ([`_xla_refuse_before_build`](@ref)); this catches what only the build creates,
  a [`DiscreteMaterializer`](@ref) cache.
* anything the emitter cannot lower, by [`_xla_refuse_emit`](@ref), however
  `Reactant.@compile` wrapped it.

Availability and the device were both answered by `_compiler_plan(:xla)` before
the document was loaded, so neither is asked again here.
"""
function _xla_problem_rhs(f_oop, var_map, u0, p, report::CompilerReport)
    device = _xla_device()
    bufs = forcing_buffers(f_oop)
    isempty(bufs) || _xla_refuse_live_buffers(keys(bufs))
    w = try
        _xla_compile_rhs(f_oop, var_map, u0, p, device)
    catch err
        de = _find_direct_emit_error(err)
        de === nothing ? rethrow() : _xla_refuse_emit(de)
    end
    _xla_record!(report, device, w.stats)
    return w
end

"""
    _xla_record!(report, device, stats) -> report

Add what the `:xla` build did to the per-rule record `native` already fills.

Two things go in, and they are the two a caller comparing two `:xla` Problems
needs: one RULE ROW for the assembled program — `the right-hand side`, kind
`:rhs_program`, landing on the tier `:xla_direct_cpu` / `:xla_direct_gpu`, which
names both the EMITTER (direct StableHLO emission, not a traced broadcast) and
the DEVICE — and the emitter's own op census `stats` folded into the report's
tally under `xla_`-prefixed keys (kernels, folds, constants, reads).

The per-rule rows the cascade filed while building the out-of-place
intermediate representation are left exactly as they are: under `:xla` those
rows say how each rule was lowered INTO the intermediate representation the
emitter then walked, which is the same question `native` answers and the same
answer.
"""
function _xla_record!(report::CompilerReport, device::AbstractString,
                      stats::AbstractDict{Symbol,Int})
    push!(report.rules,
          CompilerRuleRecord("the right-hand side", :rhs_program,
                             Symbol("xla_direct_", device),
                             Pair{Symbol,Symbol}[]))
    for (k, v) in stats
        report.tally[Symbol("xla_", k)] = v
    end
    return report
end

# ------------------------------------------------------------------------------
# The Jacobian an `:xla` Problem hands its solver
# ------------------------------------------------------------------------------
#
# A stiff algorithm builds its Jacobian by forward-differentiating the
# right-hand side unless the `ODEFunction` carries one, and a compiled device
# program is not a Julia function a `Dual` can be pushed through: the wrapper
# refuses a non-Float64 call by name (ext/reactant_direct/problem.jl). So an
# `:xla` Problem carries its own `jac` and `tgrad`, finite-differenced through
# the compiled program on Float64 host vectors, and EVERY caller of `solve` —
# `run_inline_tests`' own stiff pick, a conformance adapter, a user naming
# `Rosenbrock23()` with its defaults — gets a Jacobian it can build, rather than
# each of them having to know to ask for `AutoFiniteDiff()`. The algorithm, its
# order and its tolerances are untouched; only where the derivative of the
# right-hand side comes from changes.
#
# One-sided differences with the step `FiniteDiff` uses for them,
# `√eps · max(1, |x|)`. `f(u)` is evaluated ONCE per Jacobian and reused for
# every column, so an n-state Jacobian costs n + 1 calls of the compiled
# program, not 2n.

const _XLA_FD_REL = sqrt(eps(Float64))

"""
    _XlaFdJacobian(f!, n)

The in-place `jac(J, u, p, t)` of an `:xla` Problem: a forward-difference
Jacobian of `f!` on Float64 host vectors. Built once per `ODEProblem`, with its
own scratch, so it carries the same single-task contract as the `f!` it wraps.
"""
struct _XlaFdJacobian{F}
    f!::F
    u::Vector{Float64}          # the perturbed state
    f0::Vector{Float64}         # f(u), once per Jacobian
    f1::Vector{Float64}         # f(u + h eⱼ)
end
_XlaFdJacobian(f!, n::Integer) =
    _XlaFdJacobian(f!, Vector{Float64}(undef, n), Vector{Float64}(undef, n),
                   Vector{Float64}(undef, n))

function (J::_XlaFdJacobian)(Jm::AbstractMatrix, u::AbstractVector, p, t)
    n = length(u)
    copyto!(J.u, u)
    J.f!(J.f0, J.u, p, t)
    @inbounds for j in 1:n
        uj = J.u[j]
        h = _XLA_FD_REL * max(1.0, abs(uj))
        J.u[j] = uj + h
        h = J.u[j] - uj                     # the step the float grid really took
        J.f!(J.f1, J.u, p, t)
        J.u[j] = uj
        for i in 1:n
            Jm[i, j] = (J.f1[i] - J.f0[i]) / h
        end
    end
    return nothing
end

"""
    _XlaFdTgrad(f!, n)

The in-place `tgrad(dT, u, p, t)` of an `:xla` Problem — ∂f/∂t by a forward
difference in `t` — which a Rosenbrock method needs beside the Jacobian and
would otherwise take by forward-differentiating the right-hand side in `t`.
"""
struct _XlaFdTgrad{F}
    f!::F
    f0::Vector{Float64}
    f1::Vector{Float64}
end
_XlaFdTgrad(f!, n::Integer) =
    _XlaFdTgrad(f!, Vector{Float64}(undef, n), Vector{Float64}(undef, n))

function (T::_XlaFdTgrad)(dT::AbstractVector, u::AbstractVector, p, t)
    t0 = Float64(t)
    h = _XLA_FD_REL * max(1.0, abs(t0))
    t1 = t0 + h
    h = t1 - t0
    T.f!(T.f0, u, p, t0)
    T.f!(T.f1, u, p, t1)
    @inbounds for i in eachindex(dT)
        dT[i] = (T.f1[i] - T.f0[i]) / h
    end
    return nothing
end

"""
    _ode_derivatives(prob) -> NamedTuple

The derivative keywords a Problem's `ODEFunction` is built with: `(jac, tgrad)`
for an `:xla` Problem, whose right-hand side cannot be forward-differentiated,
and nothing for every other compiler, whose `f!` is an ordinary eltype-generic
Julia function a solver differentiates itself.
"""
function _ode_derivatives(prob)
    compiler(prob) === :xla || return NamedTuple()
    n = length(prob.u0)
    return (jac = _XlaFdJacobian(prob.f!, n), tgrad = _XlaFdTgrad(prob.f!, n))
end
