"""
    EarthSciASTDataOutputExt

The streaming-output callback constructor (streaming-output-sinks RFC §16,
Wave 1), loaded automatically when both `DiffEqCallbacks` and `SciMLBase` are in
the session. It supplies the one method the core `build_output_callback` generic
is missing: the body that builds a `PresetTimeCallback` whose `affect!` snapshots
the integrator state and pushes it to each output sink at its cadence anchors.

Kept out of the base package per `[[library-exposes-rhs-not-solver]]` and the RFC
§16.4 gating: returning a `PresetTimeCallback` needs `DiffEqCallbacks`, and the
callback interoperates with `SciMLBase` — both solver-adjacent, so they stay
`weakdeps`, mirroring the existing `DataRefreshExt` / `MTKExt` / `CatalystExt`
pattern. Without them loaded, the core fallback throws an `OutputError` telling the
user what to load. This module is the OUTPUT mirror of `EarthSciASTDataRefreshExt`.
"""
module EarthSciASTDataOutputExt

using EarthSciAST: OutputError, StateSnapshot,
    sink_output_times, sink_write!
# Explicit import so we can add the extension method to this generic.
import EarthSciAST: build_output_callback
import DiffEqCallbacks: PresetTimeCallback

# Coerce a `snapshot(integrator)` return value into a `StateSnapshot` at time `t`.
# A caller may supply a `snapshot` that already captures its observed caches and
# returns a full `StateSnapshot`; the default `state_snapshot` returns just the
# host-gathered state slabs, which we wrap with an empty observed dict. Both forms
# reach `sink_write!(sink, ::StateSnapshot)` identically.
_as_snapshot(::Any, snap::StateSnapshot) = snap
_as_snapshot(t::Float64, state::AbstractVector) =
    StateSnapshot(t, collect(Tuple{Array,Tuple{Vararg{UnitRange{Int}}}}, state),
                  Dict{String,Array}())

# Zero-positional keyword method (the callback is a pure function of the sink
# registry and the snapshot/pre_write seams; it never reads the model). More
# specific than the core's varargs fallback, so it wins whenever this extension is
# loaded.
function build_output_callback(;
                               sinks,
                               snapshot,
                               pre_write::Function = () -> nothing)
    # Materialize each sink's output times once (stable order = the `sinks`
    # order), so a sink's `sink_output_times` is consulted once here for the tstops
    # union and reused in `affect!` for the per-tick membership test.
    sink_times = [collect(Float64, sink_output_times(sink)) for sink in sinks]

    # tstops = sorted, de-duplicated UNION of every sink's output times — the
    # identical construction `build_refresh_callback` uses, so output composes with
    # input-refresh in one CallbackSet (union the two tstops).
    tstops = Float64[]
    for ts in sink_times
        append!(tstops, ts)
    end
    sort!(tstops)
    unique!(tstops)

    # The affect: at each output anchor, freshen the caller's observed caches
    # (`pre_write`), snapshot the state, then hand the snapshot to every sink whose
    # OWN output times include this exact tick. `pre_write()` runs BEFORE
    # `snapshot(integrator)` so the observed caches are fresh when the snapshot
    # reads them. `tstops` are exact preset times, so membership is exact `in` on
    # each sink's own times — a sink only writes at its own anchors, not at another
    # sink's (the union merely tells the solver where to stop).
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

end # module EarthSciASTDataOutputExt
