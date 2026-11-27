"""
    EarthSciASTCallbacksExt

The solver callback constructors, loaded when both `DiffEqCallbacks` and
`SciMLBase` are in the session: `build_refresh_callback` (loader refresh at
cadence boundaries), `build_output_callback` (output sinks at their anchors) and
`build_checkpoint_callback` (predicate-driven checkpoints). The base package
returns a right-hand side, not a solver, so these stay behind weak dependencies;
without them each core fallback throws a `RefreshError` or `OutputError` saying
what to load.
"""
module EarthSciASTCallbacksExt

using EarthSciAST: ERROR_CODES, RefreshBuffers, RefreshError, OutputError, StateSnapshot,
    provider_is_const, provider_refresh_times, provider_sample, _write_forcing!,
    notify_forcing_refresh!, sink_output_times, sink_write!, sink_flush!, _union_tstops,
    _declare_announced!
import EarthSciAST: build_refresh_callback, _refresh_callback, build_output_callback,
    build_checkpoint_callback
import DiffEqCallbacks: PresetTimeCallback
import SciMLBase
import SciMLBase: DiscreteCallback, terminate!

# SciMLBase 3 renamed `u_modified!` to `derivative_discontinuity!`; SciMLBase 2
# has only `u_modified!`. Bind whichever this SciMLBase provides.
const _derivative_discontinuity! =
    isdefined(SciMLBase, :derivative_discontinuity!) ?
    SciMLBase.derivative_discontinuity! : SciMLBase.u_modified!

# ---------------------------------------------------------------------------
# Loader refresh
# ---------------------------------------------------------------------------

# Group the refreshed (discrete) variables by provider object so a provider
# serving several variables is sampled once per boundary. Const providers never
# refresh (they ride `const_arrays`) and are dropped. Variables are visited in
# sorted order so the grouping, the stop times and the affect are deterministic.
function _group_discrete_providers(providers::AbstractDict, buffers::RefreshBuffers)
    groups = Tuple{Any, Vector{String}}[]   # (provider, [var, ...]) in first-seen order
    slot = Base.IdDict{Any, Int}()           # provider identity => index into `groups`
    entries = sort!(
        Tuple{String, Any}[(String(k), v) for (k, v) in pairs(providers)];
        by = first
    )
    for (var, prov) in entries
        provider_is_const(prov) && continue
        haskey(buffers, var) || throw(
            RefreshError(
                "build_refresh_callback: no buffer for refreshed variable '$var'; add it to " *
                    "`buffers` (the same Array{Float64} passed to `esm_problem`'s `param_arrays`)",
                ERROR_CODES.UNDEFINED_VARIABLE
            )
        )
        i = get(slot, prov, 0)
        if i == 0
            push!(groups, (prov, String[var]))
            slot[prov] = length(groups)
        else
            push!(groups[i][2], var)
        end
    end
    return groups
end

# Zero-positional keyword methods: more specific than the core's varargs
# fallbacks, so they win whenever this extension is loaded. A caller's
# `owner` also declares that the build's forcing writes are announced
# (`_declare_announced!`); the Problem's own callback (`_problem_callbacks`)
# calls `_refresh_callback` directly, which declares nothing.
function build_refresh_callback(;
        providers::AbstractDict,
        buffers::RefreshBuffers,
        owner,
        post_refresh::Function = () -> nothing
    )
    out = _refresh_callback(; providers, buffers, owner, post_refresh)
    owner === nothing || _declare_announced!(owner)
    return out
end

function _refresh_callback(;
        providers::AbstractDict,
        buffers::RefreshBuffers,
        owner,
        post_refresh::Function = () -> nothing
    )
    owner === nothing || applicable(notify_forcing_refresh!, owner) || throw(
        ArgumentError(
            "build_refresh_callback: `owner` must be the Problem or DiscreteMaterializer " *
                "whose build reads `buffers`; got a $(typeof(owner))"
        )
    )
    groups = _group_discrete_providers(providers, buffers)
    tstops = Float64[]
    for (prov, _vars) in groups
        tstops = _union_tstops(tstops, collect(Float64, provider_refresh_times(prov)))
    end

    # At each anchor: sample, write each forcing into its buffer in place,
    # announce the writes to the build that reads them, run `post_refresh`
    # (recomputes the derived discrete-cadence caches from the fresh buffers),
    # then mark a derivative discontinuity. The flag must be
    # `true`: `p` changed, so `f(u, p, t)` changed although `u` did not, and an
    # FSAL integrator would otherwise reuse the last stage's derivative computed
    # from the old forcing. `u` itself is not touched.
    function affect!(integrator)
        t = integrator.t
        for (prov, vars) in groups
            sample = provider_sample(prov, t)
            for var in vars
                _write_forcing!(buffers[var], var, sample)
            end
        end
        owner === nothing || notify_forcing_refresh!(owner)
        post_refresh()
        _derivative_discontinuity!(integrator, true)
        return nothing
    end

    cb = PresetTimeCallback(tstops, affect!)
    return cb, tstops
end

# ---------------------------------------------------------------------------
# Output and checkpoint sinks
# ---------------------------------------------------------------------------

# Coerce a `snapshot(integrator)` return value into a `StateSnapshot` at time
# `t`: a caller's snapshot may already be a full `StateSnapshot`; the default
# `state_snapshot` returns the host-gathered state slabs only.
_as_snapshot(::Any, snap::StateSnapshot) = snap
_as_snapshot(t::Float64, state::AbstractVector) =
    StateSnapshot(
    t, collect(Tuple{Array, Tuple{Vararg{UnitRange{Int}}}}, state),
    Dict{String, Array}()
)

function build_output_callback(;
        sinks,
        snapshot,
        pre_write::Function = () -> nothing
    )
    # Each sink's output times, read once: the union is where the solver stops,
    # and a sink writes only at its own times (exact membership; preset times).
    sink_times = [collect(Float64, sink_output_times(sink)) for sink in sinks]
    tstops = Float64[]
    for ts in sink_times
        tstops = _union_tstops(tstops, ts)
    end

    # `pre_write` runs before `snapshot` so the observed caches it freshens are
    # current when the snapshot reads them.
    function affect!(integrator)
        pre_write()
        snap = _as_snapshot(Float64(integrator.t), snapshot(integrator))
        for (sink, ts) in zip(sinks, sink_times)
            (integrator.t in ts) && sink_write!(sink, snap)
        end
        return nothing
    end

    cb = PresetTimeCallback(tstops, affect!)
    return cb, tstops
end

# A `DiscreteCallback` whose condition, checked at every accepted step, is the OR
# of the caller's zero-argument predicates. When one fires it snapshots the full
# state, writes it to every checkpoint sink, flushes each (the durable commit
# barrier) and, with `terminate_on_fire`, ends the integration. A checkpoint
# sink on an interval cadence needs none of this: it rides the output callback.
function build_checkpoint_callback(;
        sinks,
        predicates,
        snapshot,
        pre_write::Function = () -> nothing,
        terminate_on_fire::Bool = true
    )
    preds = collect(predicates)
    condition(u, t, integrator) = any(p -> p()::Bool, preds)

    function affect!(integrator)
        pre_write()
        snap = _as_snapshot(Float64(integrator.t), snapshot(integrator))
        for sink in sinks
            sink_write!(sink, snap)
            sink_flush!(sink)
        end
        terminate_on_fire && terminate!(integrator)
        return nothing
    end

    return DiscreteCallback(condition, affect!)
end

end # module EarthSciASTCallbacksExt
