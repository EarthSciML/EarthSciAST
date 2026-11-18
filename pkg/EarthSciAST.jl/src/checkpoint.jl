# Checkpoint predicates (streaming-output-sinks RFC §10, §16.7) and the
# predicate-driven checkpoint callback's public surface.

# --------------------------------------------------------------------------- #
# Checkpoint triggers (RFC §10, §16.7). A checkpoint fires on any composition of a
# fixed INTERVAL (checkpoint times → the ordinary sink cadence / a PresetTimeCallback)
# and/or one or more PREDICATES (a DiscreteCallback whose condition ORs them). A
# predicate is a zero-arg `() -> Bool`; EarthSciAST ships an `any_of` combinator plus
# two built-ins — a SLURM remaining-walltime predicate and a cloud spot-preemption
# predicate. The predicates are pure and live here (no solver stack); the
# predicate→`DiscreteCallback` wiring lives in the DiffEqCallbacks extension, and
# the manifest-driven RESTART read lives in the EarthSciIO extension.
# --------------------------------------------------------------------------- #

"""
    any_of(predicates...) -> () -> Bool

OR-compose checkpoint predicates (RFC §10): the returned zero-arg predicate fires
when ANY of `predicates` fires. Each argument is itself a `() -> Bool`. With no
arguments the result never fires (`false`, the identity for OR) — a predicate-free
checkpoint configuration contributes no just-in-time trigger. Predicates compose
freely with a fixed interval; a user on PBS / Kubernetes / a bespoke scheduler
passes their own `() -> Bool` with no library change.
"""
any_of(predicates...) = () -> any(p -> p()::Bool, predicates)

# Default Unix-seconds wall clock, kept a tiny injectable seam so
# `slurm_walltime_predicate` is deterministically testable without touching the
# real clock (pass `clock = () -> fixed`).
_unix_now() = time()

"""
    slurm_walltime_predicate(; margin_seconds = 300, clock = EarthSciAST._unix_now,
                             end_time_env = "SLURM_JOB_END_TIME") -> () -> Bool

Built-in SLURM remaining-walltime checkpoint predicate (RFC §10): fires once the
job is within `margin_seconds` of its scheduled end, so a full-state checkpoint
lands before SLURM kills the job. Reads the job end time (Unix epoch seconds) from
the `end_time_env` environment variable; returns `false` when it is absent or
unparseable — i.e. not running under SLURM ⇒ never fires. `clock` (a `() -> Real`
Unix-seconds source) is injectable for testing.
"""
function slurm_walltime_predicate(;
        margin_seconds::Real = 300,
        clock = _unix_now,
        end_time_env::AbstractString = "SLURM_JOB_END_TIME"
    )
    return function ()
        endt = tryparse(Float64, get(ENV, end_time_env, ""))
        endt === nothing && return false
        return (endt - clock()) <= margin_seconds
    end
end

"""
    spot_preemption_predicate(; poll) -> () -> Bool

Built-in cloud spot / preemptible-instance checkpoint predicate (RFC §10): fires
when the instance metadata service reports a pending termination notice. `poll` is
a `() -> Bool` performing the provider-specific metadata check (AWS
`/latest/meta-data/spot/instance-action`, GCP `preempted`, …) — REQUIRED and
supplied by the caller, so the core carries no HTTP/provider dependency and the
predicate stays testable. Combine with [`any_of`](@ref) and/or an interval.
"""
spot_preemption_predicate(; poll) = () -> poll()::Bool

# --------------------------------------------------------------------------- #
# build_checkpoint_callback — public surface; the DiscreteCallback method lives in
# the DiffEqCallbacks extension (mirror of build_output_callback). Turns a set of
# checkpoint predicates into a just-in-time `DiscreteCallback` that writes the
# full-state checkpoint to `sinks`, calls `sink_flush!` (the durable barrier), and
# optionally `terminate!`s for a clean pre-preemption exit.
# --------------------------------------------------------------------------- #

"""
    build_checkpoint_callback(; sinks, predicates, snapshot = state_snapshot,
                              pre_write = () -> nothing, terminate_on_fire = true)
        -> cb

Build the PREDICATE-driven checkpoint callback (RFC §10, §16.7): a `DiscreteCallback`
whose `condition` is the OR of `predicates` ([`any_of`](@ref)-style zero-arg
`() -> Bool`s, e.g. [`slurm_walltime_predicate`](@ref) /
[`spot_preemption_predicate`](@ref)) and whose `affect!` snapshots the full state,
writes it to every sink in `sinks`, calls [`sink_flush!`](@ref) (the durable commit
barrier), and — when `terminate_on_fire` — `terminate!`s the integrator for a clean
pre-preemption exit. Compose the returned callback in the same `CallbackSet` as the
diagnostic output and input-refresh callbacks. Interval-only checkpointing needs no
predicate callback — a checkpoint-profile sink's `sink_output_times` already ride the
ordinary `PresetTimeCallback` cadence.

Requires `DiffEqCallbacks` + `SciMLBase` (the constructor is a package extension);
calling it without them throws [`OutputError`](@ref).
"""
function build_checkpoint_callback end
build_checkpoint_callback(args...; kwargs...) = throw(
    OutputError(
        "build_checkpoint_callback requires the DiffEqCallbacks + SciMLBase extension; " *
            "add `using DiffEqCallbacks, SciMLBase` so EarthSciASTCallbacksExt is active"
    )
)
