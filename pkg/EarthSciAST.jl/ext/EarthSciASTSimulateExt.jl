"""
    EarthSciASTSimulateExt

The SciML plumbing for [`ESMProblem`](@ref), loaded automatically when
`SciMLBase` is in the session.

esm-libraries-spec §2.5 gives the simulation surface one noun and one verb, and
§4 of `API_SPEC.md` makes the SciML spellings canonical. This extension is what
makes them literally the SciML ones: it specializes `SciMLBase.__init` and
`SciMLBase.__solve` on an `ESMProblem`, so the standard entry points —
`solve`, `init`, `step!`, `solve!`, `remake`, `EnsembleProblem` — work on it
directly, and a solution is a real `ODESolution` carrying a real
`SciMLBase.ReturnCode` and indexed by variable name through
SymbolicIndexingInterface.

Kept out of the base package per `[[library-exposes-rhs-not-solver]]` and
§2.5.9: CONSTRUCTING an `ESMProblem` must not require the solver, so
`ODEProblem` / `solve` / `ReturnCode` stay behind a `weakdep`, mirroring the
`DataRefreshExt` / `DataOutputExt` / `MTKExt` pattern. Only `solve` / `init` /
`solve!` need this extension.

The algorithm itself (e.g. `Tsit5`) comes from the caller's own solver package
(OrdinaryDiffEq*); `solve(prob, alg)` dispatches into it.
"""
module EarthSciASTSimulateExt

using EarthSciAST: EarthSciAST, ESMProblem, SimulateError, DEFAULT_SIM_RELTOL,
                   DEFAULT_SIM_ABSTOL, callbacks, param_map, sink_open!, sink_close!
import SciMLBase

# SymbolicIndexingInterface reaches us through SciMLBase (which `using`s it), so
# it needs no weakdep/trigger of its own — an extension may only load its own
# declared triggers, and requiring the user to `using SymbolicIndexingInterface`
# to get a working `solve` would be an absurd trigger to hang this on.
const SII = SciMLBase.SymbolicIndexingInterface

# --------------------------------------------------------------------------- #
# The core's callback-composition seam (`_callback_set`), now that `CallbackSet`
# is reachable. A problem with 0 or 1 callbacks never gets here.
# --------------------------------------------------------------------------- #
EarthSciAST._callback_set(cbs::AbstractVector) = SciMLBase.CallbackSet(cbs...)

# The core's internal solve bridge (`run_pde_tests` and friends), routed through
# the ONE public solve path so there is no second mechanism.
EarthSciAST._solve_problem(prob::ESMProblem, alg; kwargs...) =
    SciMLBase.solve(prob, alg; kwargs...)

# --------------------------------------------------------------------------- #
# §2.5.7 — a solution is indexed BY VARIABLE NAME, not by position in the state
# vector: the flattened state ordering is an implementation detail that coupling
# can change. `SymbolCache` is the SymbolicIndexingInterface "system" the
# `ODEFunction` carries, so `sol[Symbol("Chem.A")]`, `variable_symbols(sol)` and
# `getsym` all work on the real `ODESolution` with no wrapper type of ours.
#
# Names are the `var_map` keys verbatim, including the element encoding of an
# array state (`Symbol("M.psi[3,4]")`), so the SII spelling and the `var_map`
# spelling never diverge. Built once per problem and memoized on it.
# --------------------------------------------------------------------------- #
function _symbol_cache(prob::ESMProblem)
    cached = prob.symcache[]
    cached === nothing || return cached
    n = length(prob.u0)
    vars = Symbol[Symbol("u[", i, "]") for i in 1:n]
    for (name, i) in prob.var_map
        1 <= i <= n && (vars[i] = Symbol(name))
    end
    # Parameter SYMBOLS come from the build's own `p` ordering (`param_map`), so
    # `parameter_symbols(prob)` reports the same names `remake(prob; p = …)`
    # accepts. Parameter VALUE access (`getp`) is not wired: the carrier is a
    # `NamedTuple`, which SII has no `parameter_values` method for — read a
    # value through `prob.p` / `param_map(prob.p)` instead.
    pm = prob.p === nothing ? Dict{String,Int}() : param_map(prob.p)
    psyms = Vector{Symbol}(undef, length(pm))
    ok = true
    for (name, i) in pm
        1 <= i <= length(psyms) ? (psyms[i] = Symbol(name)) : (ok = false)
    end
    ok || (psyms = Symbol[Symbol(k) for k in sort!(collect(keys(pm)))])
    iv = Symbol(prob.output_meta.time_dim)
    sc = SII.SymbolCache(vars, psyms, iv)
    prob.symcache[] = sc
    return sc
end

_ode_problem(prob::ESMProblem, tspan) = SciMLBase.ODEProblem(
    SciMLBase.ODEFunction(prob.f!; sys = _symbol_cache(prob)),
    copy(prob.u0), tspan, prob.p)

# --------------------------------------------------------------------------- #
# Per-run keyword resolution.
#
# §2.5.4, the one genuinely ambiguous point in the design, settled deliberately:
# a `callback` argument to `solve` REPLACES the problem's callback set entirely.
# It does not append, merge, or wrap. `callback = nothing` is a MEANINGFUL
# replacement (drop the problem's callbacks for this run), which is why the test
# is `haskey`, not `!== nothing`.
#
# `tstops` is not a callback and does not follow that rule: the problem's
# refresh/output anchors are solver stops the callbacks NEED, so a caller's
# `tstops` unions with them rather than replacing them.
# --------------------------------------------------------------------------- #
function _run_kwargs(prob::ESMProblem; kwargs...)
    kw = Dict{Symbol,Any}(kwargs)
    haskey(kw, :reltol) || (kw[:reltol] = DEFAULT_SIM_RELTOL)
    haskey(kw, :abstol) || (kw[:abstol] = DEFAULT_SIM_ABSTOL)
    if haskey(kw, :callback)
        kw[:callback] === nothing && delete!(kw, :callback)
    else
        cb = callbacks(prob)
        cb === nothing || (kw[:callback] = cb)
    end
    ts = collect(Float64, prob.tstops)
    haskey(kw, :tstops) && (ts = EarthSciAST._union_tstops(
        ts, collect(Float64, kw[:tstops])))
    isempty(ts) ? delete!(kw, :tstops) : (kw[:tstops] = ts)
    haskey(kw, :saveat) && kw[:saveat] === nothing && delete!(kw, :saveat)
    # Streaming-output mode (streaming-output-sinks RFC §16.5): the sink owns
    # persistence, so stop the solver accumulating the dense RAM trajectory —
    # keep only the start/end points. A caller who asks for `save_everystep`
    # explicitly wins.
    if !prob.save_everystep && !haskey(kw, :save_everystep)
        kw[:save_everystep] = false
        kw[:save_start] = true
        kw[:save_end] = true
    end
    return kw
end

_need_alg(alg) = alg === nothing && throw(SimulateError(
    "solving an ESMProblem needs an ODE algorithm: pass `alg = Tsit5()` " *
    "(and `using OrdinaryDiffEqTsit5`)"))

# --------------------------------------------------------------------------- #
# `init` / `__init` — §2.5.6. `step!` and `solve!` then come free: what we hand
# back IS the solver package's own integrator.
#
# NOTE the sink lifecycle: `__solve` opens and closes the problem's sinks around
# the run. A caller who drives `init` / `step!` themselves owns that lifecycle
# and must call `sink_open!` / `sink_close!` around their loop.
# --------------------------------------------------------------------------- #
function SciMLBase.__init(prob::ESMProblem, alg = nothing, args...; kwargs...)
    _need_alg(alg)
    EarthSciAST._prepare_run!(prob, prob.tspan[1])
    return SciMLBase.init(_ode_problem(prob, prob.tspan), alg, args...;
                          _run_kwargs(prob; kwargs...)...)
end

function SciMLBase.__solve(prob::ESMProblem, alg = nothing, args...; kwargs...)
    _need_alg(alg)
    # Sink lifecycle: open each sink (declares its store dims/coords/chunk-shard
    # grid ONCE) BEFORE the run — the output callback's own `initialize` may
    # write at t0 during `init` — and close each (flush + end-of-run manifest)
    # AFTER, in a `finally` so a solver error still finalizes a partially-written
    # store into a readable, restartable state.
    ls = prob.lifecycle_sinks
    isempty(ls) || foreach(sink_open!, ls)
    try
        integrator = SciMLBase.__init(prob, alg, args...; kwargs...)
        return SciMLBase.solve!(integrator)
    finally
        isempty(ls) || foreach(sink_close!, ls)
    end
end

# `ESMProblem` is deliberately NOT a subtype of `SciMLBase.AbstractDEProblem`:
# the type is defined in the core package, which has no SciMLBase dependency
# (§2.5.9). SciMLBase's generic `solve`/`init` therefore do not cover it, so
# these two thin methods route the standard entry points into the `__solve` /
# `__init` specializations above — the same two-layer shape SciMLBase uses
# internally. `alg` may be positional (the SciML spelling) or a keyword.
function SciMLBase.solve(prob::ESMProblem, args...; alg = nothing, kwargs...)
    a, rest = _split_alg(alg, args)
    return SciMLBase.__solve(prob, a, rest...; kwargs...)
end

function SciMLBase.init(prob::ESMProblem, args...; alg = nothing, kwargs...)
    a, rest = _split_alg(alg, args)
    return SciMLBase.__init(prob, a, rest...; kwargs...)
end

_split_alg(alg, args) = isempty(args) ? (alg, ()) :
    (alg === nothing ? (first(args), Base.tail(args)) :
     throw(SimulateError("`alg` was passed both positionally and by keyword")))

# --------------------------------------------------------------------------- #
# `remake` — §2.5.5. The logic lives in the core (it needs no solver); this is
# the canonical SciML spelling forwarding to it, so `remake(prob; p = …)` works
# in a session that has `using OrdinaryDiffEq` WITHOUT EarthSciAST exporting a
# competing `remake` of its own.
# --------------------------------------------------------------------------- #
SciMLBase.remake(prob::ESMProblem; kwargs...) = EarthSciAST.remake(prob; kwargs...)

# --------------------------------------------------------------------------- #
# `EnsembleProblem` — §2.5.8: a Problem plus a per-trajectory rewrite, solved as
# a family. The canonical form for parameter sweeps, Monte Carlo over declared
# distributions, and perturbed initial conditions.
#
#     ens = EnsembleProblem(prob, (p, i, repeat) -> remake(p; p = Dict("k" => ks[i])))
#     sols = solve(ens, Tsit5(), EnsembleSerial(); trajectories = length(ks))
#
# `safetycopy = false` because `remake` already returns a fresh problem sharing
# only what a substitution cannot invalidate; deep-copying an `ESMProblem` would
# clone the compiled RHS and BREAK the aliasing between the live forcing buffers
# and the closure that reads them.
# --------------------------------------------------------------------------- #
SciMLBase.EnsembleProblem(prob::ESMProblem, rewrite; safetycopy::Bool = false,
                          kwargs...) =
    SciMLBase.EnsembleProblem(prob; prob_func = rewrite, safetycopy = safetycopy,
                              kwargs...)

end # module EarthSciASTSimulateExt
