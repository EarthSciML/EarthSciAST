# Streaming output sinks: the output mirror of the data-loader input seam in
# data_refresh.jl. A `PresetTimeCallback` snapshots the integrator state (and any
# caller-named observed fields) at each output boundary and hands it to each
# sink, so the trajectory need not be kept in memory (`save_everystep=false`).
#
# This file owns the contract: the Sink protocol generics and the host-gather
# `state_snapshot`. Concrete sinks live outside EarthSciAST (the Zarr sink is the
# EarthSciIO extension's `build_zarr_sink`). `build_output_callback`'s method
# lives in ext/EarthSciASTCallbacksExt.jl so the core pulls in no solver stack;
# `esm_problem(…; sinks)` composes it, or a caller attaches it to its own solve.

"""
    OutputError(msg)
    OutputError(msg, code)

Thrown by the streaming-output surface: an unimplemented Sink protocol method, a
malformed snapshot, an output request that designates no single variable, or a
call to [`build_output_callback`](@ref) before the `DiffEqCallbacks` /
`SciMLBase` extension is loaded. The output-side mirror of
[`RefreshError`](@ref).

`code` is the registered diagnostic code (an [`ERROR_CODES`](@ref) value) for
the failures that carry one, and `""` otherwise.
"""
struct OutputError <: EarthSciASTError
    code::String
    msg::String
    OutputError(msg::AbstractString, code::AbstractString = "") = new(String(code), String(msg))
end

# --------------------------------------------------------------------------- #
# AbstractSink — an optional supertype for concrete sinks. Sinks need NOT subtype
# it (the protocol dispatches structurally on the generics below, exactly like the
# Provider protocol accepts any object); it exists so `esm_problem`'s `sinks` kwarg
# has a meaningful element type and so a concrete binding may opt in.
# --------------------------------------------------------------------------- #

"""
    AbstractSink

Optional supertype for a streaming output sink. A sink is any object implementing
the Sink protocol ([`sink_output_times`](@ref) / [`sink_open!`](@ref) /
[`sink_write!`](@ref) / [`sink_flush!`](@ref) / [`sink_close!`](@ref)); it need
not subtype `AbstractSink` (the protocol dispatches structurally, mirroring how
the Provider protocol accepts any object). It exists as the declared element type
of [`esm_problem`](@ref)'s `sinks` keyword and as an opt-in for concrete bindings.
"""
abstract type AbstractSink end

# --------------------------------------------------------------------------- #
# StateSnapshot — the fixed-shape payload the callback assembles once per output
# tick and hands to every writing sink (RFC §16.3). It is NOT state-only: the
# callback's `pre_write` hook freshens the caller's observed caches first, and the
# `snapshot` function folds those into `observed` alongside the host-gathered state.
# --------------------------------------------------------------------------- #

"""
    StateSnapshot(t, state, observed)

One output record: the integrator state (and any caller-named observed/derived
fields) at solver time `t`, host-materialized, ready to scatter into a sink's
gridded arrays. Assembled once per output boundary by the output callback's
`affect!` and passed to [`sink_write!`](@ref).

Fields (RFC §16.3):

* `t::Float64` — the solver time (seconds) of this record.
* `state::Vector{Tuple{Array,Tuple{Vararg{UnitRange{Int}}}}}` — the state as
  `(slab, global-range tuple)` pairs. [`state_snapshot`](@ref) gives exactly one
  entry, `(Array(u), (1:length(u),))`, the whole flat state at offset 0; a
  sharded snapshot may give one slab per shard with its global range.
* `observed::Dict{String,Array}` — caller-named observed/derived arrays,
  host-materialized (empty unless a sink's schema names observed outputs; those
  names drive what `pre_write` evaluates — the evaluator already produces them).
"""
struct StateSnapshot
    t::Float64
    state::Vector{Tuple{Array, Tuple{Vararg{UnitRange{Int}}}}}
    observed::Dict{String, Array}
end

# --------------------------------------------------------------------------- #
# Sink protocol (producer-side; concrete impls live in the data binding or a mock)
# --------------------------------------------------------------------------- #
#
# A "sink" is any object that persists a stream of `StateSnapshot`s on the solver
# time axis. EarthSciAST owns the contract (these generics) and calls them; the
# EarthSciIO Zarr sink satisfies it via a binding, or a mock in tests. Each sink
# carries/derives its OWN `OutputSchema` (variable list, dims, coordinates, chunk/
# shard shape, codec profile — RFC §16.2): there is no single shared schema, so
# `build_output_callback` takes no `schema` argument, and `sink_open!` opens a sink
# against its own schema. The sink's `sink_output_times` are on the SAME axis as the
# integrator's `t` (as the provider's refresh times are), so those times ARE the
# tstops — no wall-clock↔seconds mapping.

"""
    sink_output_times(sink) -> AbstractVector{Float64}

The output-cadence anchors at which `sink` writes a record, in solver time
(seconds on the integrator's `t` axis). May be empty (a predicate-only checkpoint
sink contributes no fixed tstops). The output-side mirror of
[`provider_refresh_times`](@ref). Concrete impls live in the data binding
(EarthSciIO) or a test mock.
"""
function sink_output_times end
sink_output_times(s) = throw(
    OutputError(
        "sink_output_times not implemented for $(typeof(s)); the data binding " *
            "(EarthSciIO) or a mock must add a method"
    )
)

"""
    sink_open!(sink)

Open `sink` for writing against its OWN `OutputSchema` (declare dims / coordinates
/ variables / chunk-shard grid ONCE). Called before the first
[`sink_write!`](@ref). Concrete impls live in the data binding or a test mock.
"""
function sink_open! end
sink_open!(s) = throw(
    OutputError(
        "sink_open! not implemented for $(typeof(s)); the data binding " *
            "(EarthSciIO) or a mock must add a method"
    )
)

"""
    sink_write!(sink, snap::StateSnapshot; selection=nothing)

Persist one time record: scatter the [`StateSnapshot`](@ref)'s state slabs and
observed arrays into `sink`'s gridded arrays. The output-side mirror of
[`provider_sample`](@ref).

`selection` is the write-side mirror of the Provider's read-side projection
pushdown: an optional per-axis sub-slab so a sink is handed only part of an axis
(distributed region writes). The output callback always passes
`selection === nothing`, since [`state_snapshot`](@ref) delivers the whole state;
see [`sink_supports_partial`](@ref). Concrete impls live in the data binding or a test mock.
"""
function sink_write! end
sink_write!(s, ::StateSnapshot; selection = nothing) = throw(
    OutputError(
        "sink_write! not implemented for $(typeof(s)); the data binding " *
            "(EarthSciIO) or a mock must add a method"
    )
)

"""
    sink_flush!(sink)

Durable barrier: make every record written so far durable (the checkpoint-boundary
commit). Concrete impls live in the data binding or a test mock.
"""
function sink_flush! end
sink_flush!(s) = throw(
    OutputError(
        "sink_flush! not implemented for $(typeof(s)); the data binding " *
            "(EarthSciIO) or a mock must add a method"
    )
)

"""
    sink_close!(sink)

Finalize `sink`: flush, write the end-of-run manifest / consolidated metadata, and
release resources. Called once after the last [`sink_write!`](@ref). Concrete impls
live in the data binding or a test mock.
"""
function sink_close! end
sink_close!(s) = throw(
    OutputError(
        "sink_close! not implemented for $(typeof(s)); the data binding " *
            "(EarthSciIO) or a mock must add a method"
    )
)

"""
    sink_supports_partial(sink) -> Bool

True if `sink` can accept a sub-slab (region) write — the write-side mirror of
[`provider_supports_selection`](@ref), used for distributed shard-local output.
Defaults to `false`; nothing in this package issues a partial write. A
concrete binding overrides it.
"""
function sink_supports_partial end
sink_supports_partial(::Any) = false

"""
    sink_observed_names(sink) -> Vector{String}

The names of the observed/derived fields `sink` wants written alongside the state
— exactly the fields the output callback's `pre_write` hook must evaluate at each
output tick (the evaluator already produces them). Defaults to `String[]` (a
state-only sink). A concrete binding overrides it from its schema.
"""
function sink_observed_names end
sink_observed_names(::Any) = String[]

# --------------------------------------------------------------------------- #
# state_snapshot — the one place the output callback touches the solver state.
# --------------------------------------------------------------------------- #

"""
    state_snapshot(integrator) -> Vector{Tuple{Array,Tuple{Vararg{UnitRange{Int}}}}}

Host-gather the integrator's state into the [`StateSnapshot`](@ref) `state` shape:
one `(Array(integrator.u), (1:length(integrator.u),))` pair, the whole flat
state on the host at global offset 0. `Array(u)` gathers a device array to the
host and is a plain copy for a host array.
"""
function state_snapshot(integrator)
    u = integrator.u
    return Tuple{Array, Tuple{Vararg{UnitRange{Int}}}}[
        (Array(u), (1:length(u),)),
    ]
end

# --------------------------------------------------------------------------- #
# build_output_callback — public surface; method lives in the extension
# --------------------------------------------------------------------------- #

"""
    build_output_callback(; sinks, snapshot, pre_write = () -> nothing)
        -> (cb, tstops::Vector{Float64})

Build the streaming-output callback and its tstops, the output-side mirror of
[`build_refresh_callback`](@ref). The callback reads only `sinks`, `snapshot`
and `pre_write`, never the model. The caller attaches it to their own problem:

```julia
cb, tstops = build_output_callback(; sinks = [my_sink], snapshot = state_snapshot)
prob = ODEProblem(f!, u0, tspan, p)              # USER's solver call
sol  = solve(prob, Tsit5(); callback = cb, tstops = tstops, save_everystep = false)
```

* `sinks` — a collection of objects implementing the Sink protocol
  ([`sink_output_times`](@ref) / [`sink_write!`](@ref) / …). Each has its OWN
  output cadence; multiple sinks with different cadences are first-class.
* `snapshot` — required: an `integrator -> snapshot` function returning a
  [`StateSnapshot`](@ref) or, like [`state_snapshot`](@ref), just its state
  slabs. A caller writing observed fields supplies one that captures its
  observed caches.
* `pre_write` — a `() -> nothing` hook the `affect!` calls at each output boundary
  BEFORE `snapshot(integrator)`, so the caller-named observed caches are fresh when
  the snapshot reads them. Defaults to a no-op.

`affect!` at each tick: run `pre_write()`, build the snapshot via
`snapshot(integrator)`, then for each sink whose `sink_output_times` contains the
tick, call `sink_write!(sink, snap)`.

`cb` is a `PresetTimeCallback`; `tstops` is the sorted, de-duplicated UNION of
every sink's [`sink_output_times`](@ref), built as [`build_refresh_callback`](@ref)
builds its tstops, so refresh and output compose in one `CallbackSet` (union
the two tstops).
Returns an empty-tstops no-op callback when every sink is predicate-only.

Requires `DiffEqCallbacks` and `SciMLBase` to be loaded (the constructor is a
package extension); calling it without them throws [`OutputError`](@ref).
"""
function build_output_callback end

# Fallback (varargs ⇒ strictly less specific than the extension's
# zero-positional keyword method): fires only when the extension is NOT loaded.
build_output_callback(args...; kwargs...) = throw(
    OutputError(
        "build_output_callback requires the DiffEqCallbacks + SciMLBase extension; " *
            "add `using DiffEqCallbacks, SciMLBase` (or a solver stack that loads them) so " *
            "EarthSciASTCallbacksExt is active"
    )
)

# --------------------------------------------------------------------------- #
# build_zarr_sink — public surface; concrete ZarrSink lives in the EarthSciIO ext
# (mirror of build_output_callback / build_refresh_callback: core owns the generic
# + a throwing fallback, the data binding supplies the method).
# --------------------------------------------------------------------------- #

"""
    build_zarr_sink(source, base_url; output_times, kwargs...) -> sink

Construct a concrete Zarr [streaming sink](@ref sink_output_times) writing to the
store at `base_url` (a `file://` URL or path). `source` is an [`EsmProblem`](@ref)
(or a bare `var_map` dict); `output_times` are the solver-second anchors at which
the sink writes. The returned object implements the Sink protocol and is passed to
[`esm_problem`](@ref)'s `sinks` keyword.

Requires `EarthSciIO` to be loaded (the concrete sink is in the
`EarthSciASTEarthSciIOExt` extension); calling it without EarthSciIO throws
[`OutputError`](@ref).
"""
function build_zarr_sink end
build_zarr_sink(args...; kwargs...) = throw(
    OutputError(
        "build_zarr_sink requires the EarthSciIO extension; add `using EarthSciIO` so " *
            "EarthSciASTEarthSciIOExt (the concrete Zarr sink) is active"
    )
)

"""
    zarr_restart_state(prep, base_url; kwargs...) -> (t0::Float64, u0::Vector{Float64})

Reconstruct a flat restart state from the last committed checkpoint in the Zarr
store at `base_url` (streaming-output-sinks RFC §10, §16.7): read the output
manifest for the last durable `t`, read each variable's gridded slab at that time
index through the `ZarrReader`, and [`gather_flat!`](@ref) it back into a flat `u0`
in the model's `var_map` order. Continue integrating a fresh run from `(t0, t_end)`
seeded with `u0` — a valid continuation consistent to solver tolerance (NOT
bit-identical; the integrator's internal cache is not checkpointed).

Requires `EarthSciIO` to be loaded (the reader/manifest live there); calling it
without EarthSciIO throws [`OutputError`](@ref).
"""
function zarr_restart_state end
zarr_restart_state(args...; kwargs...) = throw(
    OutputError(
        "zarr_restart_state requires the EarthSciIO extension; add `using EarthSciIO` so " *
            "EarthSciASTEarthSciIOExt (the reader + output manifest) is active"
    )
)
