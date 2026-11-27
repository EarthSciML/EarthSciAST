# Discrete-cadence loader refresh: the consumer surface for provider-fed
# forcing buffers.
#
# This file owns two seams whose implementations live outside EarthSciAST:
#
#   1. the Provider protocol (`provider_refresh_times`, `provider_is_const`,
#      `provider_sample` and the selection, gate and extent generics), which the
#      EarthSciIO extension or a test mock implements;
#   2. `RefreshBuffers`, the live forcing buffers: the same dense
#      `Array{Float64}` objects passed as `esm_problem`'s `param_arrays`, written
#      in place at each cadence boundary (`_write_forcing!`).
#
# `build_refresh_callback` returns the callback and its tstops; its method lives in
# ext/EarthSciASTCallbacksExt.jl so the core pulls in no solver stack.

"""
    RefreshError(msg, code = "")

Thrown by the data-refresh surface: an unimplemented Provider
protocol method, a buffer that is not a dense `Array{Float64}`, a
shape/length mismatch at refresh time, or a call to
[`build_refresh_callback`](@ref) before the `DiffEqCallbacks` / `SciMLBase`
extension is loaded. Fields: `code` (an [`ERROR_CODES`](@ref) value, or `""`)
and `msg`.
"""
struct RefreshError <: EarthSciASTError
    code::String
    msg::String
    RefreshError(msg::AbstractString, code::AbstractString = "") = new(String(code), String(msg))
end

# --------------------------------------------------------------------------- #
# Provider protocol (consumer-side; concrete impls live in the data binding)
# --------------------------------------------------------------------------- #
#
# A provider supplies a loader's native-grid arrays on the solver time axis.
# Its refresh times are `Float64` seconds on the integrator's `t` axis, so they
# are the tstops directly.

"""
    provider_refresh_times(provider) -> AbstractVector{Float64}

The cadence anchors at which `provider`'s data changes, in solver time
(seconds on the integrator's `t` axis). Empty for a time-invariant
(CONST) provider — such a provider is materialized once and contributes no
tstops. Concrete impls live in the data binding (EarthSciIO) or a test mock.
"""
function provider_refresh_times end
provider_refresh_times(p) = throw(
    RefreshError(
        "provider_refresh_times not implemented for $(typeof(p)); the data binding " *
            "(EarthSciIO) or a mock must add a method",
        ERROR_CODES.PROVIDER_METHOD_MISSING
    )
)

"""
    provider_is_const(provider) -> Bool

True if `provider`'s data is time-invariant (no cadence). CONST providers are
materialized once into `const_arrays` at `_build_evaluator` time and are absent
from the refresh callback. Defaults to "no refresh times"; a concrete impl may
override (e.g. EarthSciIO's `is_const`).
"""
function provider_is_const end
provider_is_const(p) = isempty(provider_refresh_times(p))

"""
    provider_supports_selection(provider) -> Bool

True if `provider` can honour a per-call `selection` (projection pushdown) in
[`provider_sample`](@ref) — i.e. it reads only the requested slice of the
native array rather than the whole thing. Defaults to `false`; the EarthSciIO
extension bridges it to `EarthSciIO.supports_selection`. A `selection` may be
handed only to a provider for which this is `true`.
"""
function provider_supports_selection end
provider_supports_selection(::Any) = false

"""
    provider_gate_spec(provider) -> Union{Nothing,AbstractDict}

The projection-pushdown GATE for a deferred provider, or `nothing` (the default)
for an ordinary provider. A gated provider is not sampled whole by
[`esm_problem`](@ref): its fetch waits until value invention has materialized
the gating derived set's members, which are then passed as a per-axis
`selection` ([`provider_sample`](@ref)) so only the compact slab is read.

The gate is `Dict("axes"=>[…], "applies_to"=>[names…])`, with one `axes` entry
per native array axis:

  * `"all"`                       → the whole axis;
  * `Dict("fixed"=>[i])`          → native 0-based index `i`, DROPPED (length-1);
  * `Dict("range"=>Dict("start"=>a, "stop"=>b, "step"=>s))`
                                  → the half-open 0-based window `[a, b)` by
                                    `s`, axis KEPT (`start`/`step` default 0/1);
  * `Dict("gated_by"=>"<set>")`   → the derived index set's materialised members
                                    (1-based), in the set's canonical order.

This is the loader `select` vocabulary of esm-spec §8.9.2, which
[`desugar_pushdown`](@ref) also generates. Only `gated_by` defers.
`applies_to` names the fetched variables to merge into `const_arrays`.
"""
function provider_gate_spec end
provider_gate_spec(::Any) = nothing

"""
    provider_extent_metaparameter(provider) -> Union{Nothing,String}

The metaparameter this provider's own EXTENT binds (esm-spec §8.9.4), or
`nothing` (the default) for a provider whose size the document already knows.

A source whose record count is known only once it is read (a filtered record
table, say) declares `extent: {"metaparameter": "N_REC"}` on its loader.
[`esm_problem`](@ref) samples such a provider once, before it closes
metaparameters (esm-spec §9.7.6), and the length of the delivered record axis
binds that metaparameter, so an index set declared `size: "N_REC"` is sized by
the data. Every provider naming the same metaparameter must report the same
count, and a caller binding that contradicts it is an error (CONFORMANCE_SPEC
§5.5).
"""
function provider_extent_metaparameter end
provider_extent_metaparameter(::Any) = nothing

"""
    providers_from_document(doc; cache_root, loaders=nothing, url_overrides=Dict(),
                            substitutions=Dict(), window=nothing,
                            records_per_sample=Dict()) -> Dict{String,Any}

Construct the data providers a document declares: one provider per data-fed
parameter, drawn from a `data_sources.<name>` entry carrying a
`metadata.esio_format` ("zarr", "ff10", …). Each source is read by EarthSciIO's
`provider_from_esm` (EarthSciIO spec/esm-sources.md §3): its `url_template` and
`mirrors` are expanded at each file anchor, and a source with a `temporal` block
is time-varying on a calendar cadence (`P1M` is a calendar month). `doc` is a raw
document `Dict`, an `EsmFile`, or a path.

The result is keyed `"<ModelPath>.<param>"`, the consuming parameter's flattened
name (a source declares no variables of its own; a model reads a field by
declaring a parameter whose `update` names the source, esm-spec §8.5). These are
the `providers` keys [`esm_problem`](@ref) takes.

Every provider runs on the model clock (esm-spec §2.2.7). Its time origin, the
UTC instant of model time 0, is the first of: the document's
`domain.temporal.reference_time`, its `domain.temporal.start` (each when a
non-empty string; an unreadable one raises `time_origin_invalid`, as
[`time_origin`](@ref) does), the start of `window`, the POSIX epoch. A sample at
model time `t` reads the instant `origin + t`, and
[`provider_refresh_times`](@ref) reports anchors in model seconds. With no
`window`, the document's `solver.time_span` (as [`resolve_time_span`](@ref)
reads it) supplies one; with neither, a time-varying provider is bounded only by
its own `temporal.end`.

A source declaring a `record_filter` or `codes` is a record table decoded once per
record anchor and shared by its parameters. A declared `select` names the
source's native per-record axes; a time-varying source applies it after slicing
the record and reports `provider_supports_selection == false`.

Keywords:
  * `cache_root` — root of the download cache (one subdirectory per loader).
  * `loaders` — restrict to these loader names (`nothing` = every loader with an
    `esio_format`).
  * `url_overrides` — loader name ⇒ URL template, replacing `url_template` and
    its mirrors. An empty entry is an error.
  * `substitutions` — loader name ⇒ `Dict(placeholder => value)`, binding the
    custom `{name}` placeholders a mount's `url_substitutions` left. An unbound
    placeholder is an error.
  * `window` — the run's `(start, stop)`, each a `DateTime` (UTC) or a finite
    number of Unix seconds, bounding each time-varying provider's refresh times.
    Anything else is an `ArgumentError`.
  * `records_per_sample` — consuming parameter key ⇒ 1 or 2. The count is fixed
    by the parameter's record shape (esm-spec §8.5.1): two when its declared
    `shape` (else that of its `param_to_var` targets) begins with an `interval`
    index set carrying `"records": true`, else one. An entry must equal that
    count. The deprecated `update.from.records_per_sample` /
    `temporal.records_per_sample` must agree with it too, and stand in for it
    only where the raw document cannot show the record shape (a target brought
    by a `coupling_import`). Every value must be the number 1 or 2 (`2.0` is 2;
    `1.5`, `"2"` and `true` are refused). With 2 the provider returns the record
    at or before `t` and the next one, stacked along the first dimension; 2 is
    refused on a time-invariant source and on a record table.

Implemented by the `EarthSciASTEarthSciIOExt` extension: load `EarthSciIO`
alongside EarthSciAST, or the call is a `MethodError`. `esio_format` goes
straight to EarthSciIO, whose format registry decides what is readable.
"""
function providers_from_document end

"""
    provider_is_gated(provider) -> Bool

True iff `provider` carries a projection-pushdown [`provider_gate_spec`](@ref) —
i.e. its materialization must be DEFERRED past value-invention and delivered
pre-sliced to the compact derived axis, rather than pulled whole in the eager
const loop.
"""
provider_is_gated(p) = provider_gate_spec(p) !== nothing

"""
    provider_sample(provider, t::Real; selection=nothing) -> sample

The native-grid data for `provider` at cadence tick `t` (solver seconds). The
return value is an `AbstractDict` keyed by variable name, a bare `AbstractArray`
or a `Real` (a single-variable sample); see [`forcing_from_sample`](@ref).

`selection` is an optional per-axis projection pushdown: one positional entry
per native axis of the gated array(s). `nothing` (the default) samples the whole
array. Otherwise each entry is:

  * `Colon()`                         → the whole axis;
  * an `Integer i` (1-BASED)          → the single fixed index `i`;
  * an `AbstractVector{<:Integer}` (1-BASED) → that ordered list of indices.

The provider reads only the selected data. The gated axis of the returned array
is ordered exactly as the index vector (a permuted list yields permuted rows). A
`selection` may only be given to a provider whose
[`provider_supports_selection`](@ref) is `true`; otherwise the binding errors.
"""
function provider_sample end
provider_sample(p, ::Real; selection = nothing) = throw(
    RefreshError(
        "provider_sample not implemented for $(typeof(p)); the data binding " *
            "(EarthSciIO) or a mock must add a method",
        ERROR_CODES.PROVIDER_METHOD_MISSING
    )
)

# --------------------------------------------------------------------------- #
# Forcing-write seam: a freshly sampled field written into its live buffer in
# place. The buffer aliases the `param_arrays` storage the right-hand side reads,
# so the write mutates it (`copyto!`) and never rebinds it. Regridding is an
# in-model coupling expression, not part of the write.
# --------------------------------------------------------------------------- #

# Pull the field for `var` out of an opaque provider sample: an `AbstractDict`
# keyed by variable name, or a bare `AbstractArray` for a single-variable sample.
_sample_field(sample::AbstractDict, var::AbstractString) = begin
    haskey(sample, var) || throw(
        RefreshError(
            "provider sample has no variable '$var' (present: $(collect(keys(sample))))",
            ERROR_CODES.UNDEFINED_VARIABLE
        )
    )
    sample[var]
end
_sample_field(sample::AbstractArray, ::AbstractString) = sample
_sample_field(sample::Real, ::AbstractString) = sample
_sample_field(sample, var::AbstractString) = throw(
    RefreshError(
        "cannot extract '$var' from a provider sample of type $(typeof(sample)); " *
            "supply an AbstractDict (var => field), a bare AbstractArray or a number",
        ERROR_CODES.INVALID_ARGUMENT
    )
)

"""
    forcing_from_sample(sample, name::AbstractString; shape = nothing) -> Array{Float64}
    forcing_from_sample(sample, slot::ForcingSlot) -> Vector{Float64}

The buffer of the data-fed parameter `name` built from one
[`provider_sample`](@ref) result: the check and conversion
[`esm_problem`](@ref) applies to the sample of every provider it binds whole
(a const provider, a discrete provider at each refresh, and a provider that
discovers a loader extent; API_SPEC §5.8, "Forcing sets"). A runtime that
builds its own [`ForcingSet`](@ref)s from provider samples calls this to get,
bit for bit, the buffer `esm_problem` builds from the same sample. A GATED
provider is not bound whole: `esm_problem` fetches only the rows its gating set
selects, so its buffer is that slab, not this function of a whole sample.

`sample` is what `provider_sample` returned: an `AbstractDict` keyed by
flattened parameter name, from which the `name` entry is taken, or a bare
`AbstractArray` or `Real` (a single-variable sample, which is the field
itself; a `Real` is a 0-d field). The result is a fresh dense
`Array{Float64}` with the field's dimensions, in the order the provider
delivered them (a source's file order, the record dimension first when two
records are delivered), so its linear order is column-major over those
dimensions: the order a forcing set reads a slot's buffer in.

With `shape` (the parameter's declared shape resolved, as a
[`ForcingSlot`](@ref) carries it: any collection of integers, a `Vector` or a
`Tuple`) the field's size must equal it, axis by axis, and an empty shape takes
a field of one value; any other field is a `DimensionMismatch`. `esm_problem`
applies the same check against each parameter's declared shape, wherever that
shape resolves before the build, so a sample it accepts passes here. The
`ForcingSlot` method checks against `slot.shape` and returns the buffer as a
`Vector{Float64}`, ready for [`forcing_set`](@ref) or
[`replace_forcing`](@ref).

A declared `unit_conversion` (esm-spec §8.5) is NOT applied here: a provider
from [`providers_from_document`](@ref) applies it when it delivers the sample,
so the sample is already in the parameter's declared units, and applying it
again would apply it twice. A sample with no `name` entry is a `RefreshError`.
"""
function forcing_from_sample(sample, name::AbstractString; shape = nothing)
    field = _sample_field(sample, String(name))
    shape === nothing || _check_forcing_shape(field, name, shape)
    return _dense_field(field)
end

# A provider field as a fresh dense `Array{Float64}` of its own dimensions; a
# bare number is a 0-d field.
_dense_field(field::Real) = fill(Float64(field))
_dense_field(field) = Array{Float64}(field)

# Refuse a provider field whose size is not the parameter's declared `shape`,
# axis by axis; an empty `shape` takes a field of one value.
function _check_forcing_shape(field, name::AbstractString, shape)
    dims = Int[Int(d) for d in shape]
    ok = isempty(dims) ? length(field) == 1 :
        ndims(field) == length(dims) &&
        all(size(field, d) == dims[d] for d in eachindex(dims))
    ok || throw(
        DimensionMismatch(
            "forcing '$name': the provider sample has size $(size(field)); the " *
                "parameter's declared shape is $(Tuple(dims))" *
                (isempty(dims) ? ", one value" : "")
        )
    )
    return nothing
end

"""
    _write_forcing!(buffer::Array{Float64}, var::AbstractString, sample) -> buffer

Write the freshly sampled `var` field (from a [`provider_sample`](@ref) result)
into `buffer` in place (column-major linear copy) and return it. `buffer` aliases
the `param_arrays` storage the right-hand side reads, so it is never rebound.
"""
function _write_forcing!(buffer::Array{Float64}, var::AbstractString, sample)
    field = _sample_field(sample, var)
    # A one-value buffer (a scalar parameter's) takes a field of one value
    # whatever its rank, as `forcing_from_sample` does for an empty shape.
    fits = length(buffer) == 1 ? length(field) == 1 : size(field) == size(buffer)
    fits || throw(
        RefreshError(
            "forcing '$var': the provider field has size $(size(field)) but the buffer " *
                "has size $(size(buffer)); the provider must deliver the native forcing on the " *
                "buffer's grid, in the same dimension order (regridding is an in-model " *
                "coupling, not a refresh-time transform)",
            ERROR_CODES.ARRAY_SHAPE_MISMATCH
        )
    )
    field isa Real ? (buffer[] = Float64(field)) : copyto!(buffer, field)
    return buffer
end

"""
    notify_forcing_refresh!(prob::EsmProblem)
    notify_forcing_refresh!(prob::EsmProblem, name::AbstractString)
    notify_forcing_refresh!(dm::DiscreteMaterializer)

Announce that the contents of a live forcing buffer (a `param_arrays` buffer
bound into the build) were mutated in place. The announcement goes to the
buffer's owner: the Problem whose build reads it, or the
[`DiscreteMaterializer`](@ref) that build filled (the same build's epoch). Three
kinds of build product are derived from such a buffer, and all are brought up
to the new contents by the owner's next in-place `f!` call (or
[`observed_field`](@ref) read):

* the memoized time-cadence prelude values that gather it, which `f!` refills
  on the next call at a `t` it has already been called at (a later `t`
  re-evaluates them anyway),
* the forcing-cadence materialized observeds that read it (they read forcing
  but neither the state nor `t`), which `f!` refills on its next call at ANY
  `t`. Once the build's writers are declared announced (a Problem whose only
  live buffers are its own providers', or the `owner` given to
  [`build_refresh_callback`](@ref)), nothing but this announcement (or a
  change of `p`) refills them; otherwise a later `t` does too, and
* every discrete-cadence cache ([`DiscreteMaterializer`](@ref)) of the build,
  which `f!` refills on its next call at ANY `t`. Nothing but this
  announcement (or a change of `p`) refills them, so a forcing write that is
  not announced leaves `f!` reading derived fields built from the old forcing,
  whatever `t` it is next called at.

With `name`, the buffer must be one of `prob`'s live forcing buffers (a key of
its `param_arrays` as the caller spelled it, or a discrete provider's
variable); an unknown name raises `ArgumentError`. One build has one epoch, so
both forms refill the same values. Builds of other Problems that alias the same
array are not reached: announce the write to each owner.

The problem's own refresh callback announces its writes itself, as does a
[`build_refresh_callback`](@ref) given the problem as `owner`. Code that writes a
forcing buffer directly (a hand-rolled callback doing `buf .= …`) calls this
after every such write. A reader of [`forcing_buffers`](@ref) gets no refill
from `f!`; it calls the [`DiscreteMaterializer`](@ref)'s `refresh!()` after the
announcement.

A spurious call gives no wrong number, but the next `f!` re-runs its
time-cadence slots, its forcing-cadence observeds and its whole discrete-cadence
stack. The refill happens
inside `f!`, so one build's `f!` must still not be called from several threads
at once.
"""
function notify_forcing_refresh! end

notify_forcing_refresh!(dm::DiscreteMaterializer) = _bump_epoch!(dm.epoch)

# Declare that every write to the live buffers of `owner`'s build is announced
# to it (`_ForcingEpoch.announced`, cadence_stamp.jl).
_declare_announced!(dm::DiscreteMaterializer) = (dm.epoch.announced = true; nothing)
_declare_announced!(_) = nothing

# --------------------------------------------------------------------------- #
# RefreshBuffers — the live forcing buffers (the SAME objects as param_arrays)
# --------------------------------------------------------------------------- #

"""
    RefreshBuffers(buffers::AbstractDict)
    RefreshBuffers(pairs::Pair...)

Registry mapping a forcing variable name to its live buffer: the dense
`Array{Float64}` bound by reference through
`esm_problem(input, tspan; param_arrays = …)`. The refresh callback writes the
sampled forcing into these objects in place, so the right-hand side sees it on
its next evaluation. Each value must be a dense `Array{Float64}`
(`RefreshError` otherwise); pass the same dictionary you gave `param_arrays` so
the buffers are shared, not copied:

```julia
forcing = Dict("wind" => zeros(nx, ny))
prob = esm_problem(doc, tspan; param_arrays = forcing, …)
buffers = RefreshBuffers(forcing)   # same array objects — aliased, not copied
```
"""
struct RefreshBuffers
    buffers::Dict{String, Array{Float64}}
end

function RefreshBuffers(d::AbstractDict)
    out = Dict{String, Array{Float64}}()
    for (k, v) in d
        k_str = String(k)
        v isa Array{Float64} || throw(
            RefreshError(
                "RefreshBuffers['$k_str'] must be a dense Array{Float64} (the SAME object " *
                    "bound to `esm_problem`'s `param_arrays`, captured by reference for live " *
                    "refresh), got $(typeof(v))",
                ERROR_CODES.INVALID_ARGUMENT
            )
        )
        out[k_str] = v
    end
    return RefreshBuffers(out)
end

RefreshBuffers(pairs::Pair...) = RefreshBuffers(Dict(pairs...))

Base.getindex(b::RefreshBuffers, k) = b.buffers[String(k)]
Base.haskey(b::RefreshBuffers, k) = haskey(b.buffers, String(k))
Base.keys(b::RefreshBuffers) = keys(b.buffers)
Base.length(b::RefreshBuffers) = length(b.buffers)

# --------------------------------------------------------------------------- #
# build_refresh_callback — public surface; method lives in the extension
# --------------------------------------------------------------------------- #

"""
    build_refresh_callback(; providers, buffers, owner,
                           post_refresh = () -> nothing)
        -> (cb, tstops::Vector{Float64})

Build the discrete-cadence loader-refresh callback and its tstops. The callback
reads only the `providers` and `buffers` registries, never the model.
`esm_problem(…; providers)` composes it for a document's own discrete providers;
a caller who binds forcing buffers through `param_arrays` attaches it to the run:

```julia
forcing = Dict("wind" => zeros(nx, ny))
prob = esm_problem(doc, tspan; param_arrays = forcing, …)
cb, tstops = build_refresh_callback(;
    providers = Dict("wind" => wind_provider),   # var name => data Provider
    buffers   = RefreshBuffers(forcing),         # same array objects as param_arrays
    owner     = prob)                            # the build that reads them
sol = solve(prob, Tsit5(); callback = cb, tstops = tstops)
```

`providers` maps each forcing variable to a data provider (the
[`provider_refresh_times`](@ref) / [`provider_is_const`](@ref) /
[`provider_sample`](@ref) protocol). Several variables may share one provider
object; it is then sampled once per cadence boundary. The provider delivers the
forcing on the buffer's grid.

* Discrete providers (non-empty `provider_refresh_times`) are refreshed at each
  anchor: `affect!` samples and writes the buffer in place, then calls
  `u_modified!(integrator, true)` so an FSAL integrator recomputes its cached
  derivative from the new forcing (`u` itself is untouched).
* Const providers ([`provider_is_const`](@ref)) contribute no tstops and are
  absent from the callback.

`owner` is the build that reads `buffers` (the Problem, or the
[`DiscreteMaterializer`](@ref) its build filled); `affect!` announces each
boundary's writes to it with [`notify_forcing_refresh!`](@ref) so its memoized
values refill. Giving `owner` also declares that every write to that build's
live buffers is announced: from then on a materialized observed that reads
forcing but neither the state nor `t` is refilled only on an announcement or a
new `p`, not at every new `t`, so any other writer of those buffers must
announce too. With `owner = nothing` nothing is announced or declared: a value
memoized from the old forcing stays until `t` moves (time-cadence values and,
in a build no writer was declared for, forcing-only observeds) or for good
(discrete caches).

`post_refresh` is a `() -> nothing` hook `affect!` calls at each boundary after
the buffers are refreshed and announced and before `u_modified!`.
[`esm_problem`](@ref) wires it to the [`DiscreteMaterializer`](@ref)'s
`materialize!`, so a state-free derived field is recomputed once per boundary.
Defaults to a no-op.

`cb` is a `PresetTimeCallback`; `tstops` is the sorted, de-duplicated union of
the DISCRETE providers' refresh times. Returns an empty-tstops no-op callback
when every provider is CONST.

Requires `DiffEqCallbacks` and `SciMLBase` to be loaded (the constructor is a
package extension); calling it without them throws [`RefreshError`](@ref).
"""
function build_refresh_callback end

# The callback without `build_refresh_callback`'s declaration that the
# owner's writes are announced: the Problem's own callback, whose caller may
# still write its `param_arrays` unannounced. Its method lives in the
# extension too.
function _refresh_callback end

# Fallbacks (varargs ⇒ strictly less specific than the extension's
# zero-positional keyword methods): fire only when the extension is NOT loaded.
_refresh_callback(args...; kwargs...) = build_refresh_callback(args...; kwargs...)
build_refresh_callback(args...; kwargs...) = throw(
    RefreshError(
        "build_refresh_callback requires the DiffEqCallbacks + SciMLBase extension; " *
            "add `using DiffEqCallbacks, SciMLBase` (or a solver stack that loads them) so " *
            "EarthSciASTCallbacksExt is active",
        ERROR_CODES.EXTENSION_UNAVAILABLE
    )
)

# --------------------------------------------------------------------------- #
# sync_forcing! — mirror refreshed host buffers into a compiled right-hand
# side's argument arrays
# --------------------------------------------------------------------------- #

"""
    sync_forcing!(dest::NamedTuple, src::NamedTuple) -> dest

Copy every live forcing buffer in `src` into the same-named array of `dest`, in
place (`copyto!`; `dest`'s arrays are never rebound). When a right-hand side
was compiled through `direct_rhs_with_buffers` (Reactant extension) with device
arrays as its buffers argument, a `copyto!` into those arrays is seen by the
compiled program, so mirroring the refreshed host buffers into them at each
cadence boundary keeps the compiled forcing live without a retrace.

Wire it through [`build_refresh_callback`](@ref)'s `post_refresh` hook (after
`materialize!`, when that is chained first):

```julia
prob = esm_problem(doc, tspan; param_arrays = forcing)
host = forcing_buffers(prob)                # aliased host buffers, stable order
dev  = map(Reactant.ConcreteRArray, host)   # the compiled program's inputs
cb, tstops = build_refresh_callback(;
    providers, buffers = RefreshBuffers(forcing), owner = prob,
    post_refresh = () -> sync_forcing!(dev, host))
```

A forcing write made outside that callback and announced with
[`notify_forcing_refresh!`](@ref) reaches the discrete caches only when something
refills them, so call the [`DiscreteMaterializer`](@ref)'s `refresh!()` before
`sync_forcing!` copies them.

`src` is normally [`forcing_buffers`](@ref)`(prob)`; every key of `src` must be
in `dest` (else [`RefreshError`](@ref)) and lengths must agree (`copyto!`
enforces it). `esm_problem(…; compiler = :xla)` does not do this wiring: it
refuses a document that binds live forcing.
"""
function sync_forcing!(dest::NamedTuple, src::NamedTuple)
    for k in keys(src)
        haskey(dest, k) || throw(
            RefreshError(
                "sync_forcing!: destination has no buffer '$k' (present: " *
                    "$(collect(keys(dest)))); dest must be aligned with forcing_buffers(f)",
                ERROR_CODES.UNDEFINED_VARIABLE
            )
        )
        copyto!(getfield(dest, k), getfield(src, k))
    end
    return dest
end
