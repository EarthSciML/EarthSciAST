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

Anything other than the two spellings is an error rather than a silent default:
a typo that quietly ran on the host would report a CPU run under a GPU label.
"""
const XLA_DEVICE_ENV = "EARTHSCI_JULIA_XLA_DEVICE"

function _xla_device()
    d = lowercase(strip(get(ENV, XLA_DEVICE_ENV, "cpu")))
    isempty(d) && (d = "cpu")
    d in ("cpu", "gpu") || throw(SimulateError(
        "$XLA_DEVICE_ENV must be 'cpu' or 'gpu', got '$d'",
        ERROR_CODES.COMPILER_UNAVAILABLE))
    return d
end

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
by an XLA executable. **Declared here, implemented in the Reactant extension**
(ext/reactant_direct/problem.jl); a session without Reactant never reaches it,
because [`_xla_extension`](@ref) has already raised `compiler_unavailable`.
"""
function _xla_compile_rhs end

"""
    _xla_problem_rhs(f_oop, var_map, u0, p, report) -> callable

The `:xla` right-hand side for [`esm_problem`](@ref): the out-of-place build
product `f_oop` lowered to StableHLO, compiled on the chosen XLA client, and
wrapped in the in-place calling convention the Problem's `f!` slot promises.

Refuses, never falls back:

* a model that binds LIVE FORCING BUFFERS (`param_arrays`, or a
  [`DiscreteMaterializer`](@ref) cache — in practice, a document with a DISCRETE
  data provider). The compiled program takes such buffers as a fourth ARGUMENT
  (`direct_rhs_with_buffers`), and keeping them live across a run means syncing
  device copies at each cadence boundary through the refresh callback's
  `post_refresh` hook ([`sync_forcing!`](@ref)). That wiring is not on this
  entry point yet, and the alternative — the three-argument form — would BAKE
  the buffers in as constants and answer every step with the forcing the build
  happened to start with. A silently stale forcing is a wrong number with
  nothing in the result to say so, so it is a named refusal instead.
* anything the emitter cannot lower, by [`_xla_refuse_emit`](@ref).
"""
function _xla_problem_rhs(f_oop, var_map, u0, p, report::CompilerReport)
    _xla_extension()                       # availability, re-checked at the build
    device = _xla_device()
    bufs = forcing_buffers(f_oop)
    isempty(bufs) || _xla_refuse(
        "live forcing buffers (" * join(String.(collect(keys(bufs))), ", ") * ")",
        "this document binds $(length(bufs)) live forcing buffer(s), which a " *
        "compiled program must receive as arguments and have re-synced to the " *
        "device at each cadence boundary; `esm_problem(…; compiler = :xla)` " *
        "does not wire that refresh yet, and the buffer-free form would bake " *
        "the build-time forcing in as a constant and run the whole simulation " *
        "against it. Build with compiler=:native, or drive the compiled lane " *
        "directly (`direct_rhs_with_buffers` + `sync_forcing!`)")
    w = try
        _xla_compile_rhs(f_oop, var_map, u0, p, device)
    catch err
        err isa DirectEmitError ? _xla_refuse_emit(err) : rethrow()
    end
    _xla_record!(report, device, w)
    return w
end

"""
    _xla_record!(report, device, w) -> report

Add what the `:xla` build did to the per-rule record `native` already fills.

Two things go in, and they are the two a caller comparing two `:xla` Problems
needs: one RULE ROW for the assembled program — `the right-hand side`, kind
`:rhs_program`, landing on the tier `:xla_direct_cpu` / `:xla_direct_gpu`, which
names both the EMITTER (direct StableHLO emission, not a traced broadcast) and
the DEVICE — and the emitter's own op census folded into the report's tally
under `xla_`-prefixed keys (kernels, folds, constants, reads).

The per-rule rows the cascade filed while building the out-of-place
intermediate representation are left exactly as they are: under `:xla` those
rows say how each rule was lowered INTO the intermediate representation the
emitter then walked, which is the same question `native` answers and the same
answer.
"""
function _xla_record!(report::CompilerReport, device::AbstractString, w)
    push!(report.rules,
          CompilerRuleRecord("the right-hand side", :rhs_program,
                             Symbol("xla_direct_", device),
                             Pair{Symbol,Symbol}[]))
    for (k, v) in _xla_stats(w)
        report.tally[Symbol("xla_", k)] = v
    end
    return report
end

# The emitted-op census of a compiled wrapper. Defined for `Any` so the report
# is filled even by a wrapper that does not carry one (nothing gates on it).
_xla_stats(w) = hasproperty(w, :stats) ? getproperty(w, :stats) : Dict{Symbol,Int}()
