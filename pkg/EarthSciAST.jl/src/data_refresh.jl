# Discrete-cadence loader refresh — the EarthSciAST-Julia consumer surface
# (ess-14f.4, JL-J1). Plan: mayor-dir esio-consumer-julia-plan-2026-06-26.md §1.
#
# The companion to the JL-J0 engine touch (`param_arrays` / `_NK_PARAM_GATHER`,
# ess-14f.3). J0 made a forcing buffer readable LIVE by the RHS: a dense
# `Array{Float64}` bound through `build_evaluator(...; param_arrays=...)` is
# captured BY REFERENCE, so an in-place `buf .= …` shows through to `f!` with
# zero reallocation. J1 builds the thing that DOES that in-place write at the
# right times: a `PresetTimeCallback` whose `affect!` pulls fresh native arrays
# from a data Provider, regrids them, and writes them into the SAME buffer
# objects — once per cadence boundary, never on the hot per-step path.
#
# Principle `[[library-exposes-rhs-not-solver]]`: EarthSciAST returns the *pieces*
# (`build_refresh_callback -> (cb, tstops)`); the USER attaches them to their own
# `ODEProblem`/`solve`. EarthSciAST ships no `solve`, no `ODEProblem`, no solver. The
# callback constructor itself lives in a package extension gated on
# `DiffEqCallbacks` + `SciMLBase` (see ext/EarthSciASTDataRefreshExt.jl)
# so the base library never pulls a solver-adjacent stack into `[deps]`.
#
# This file (core) owns two decoupled seams; concrete implementations live
# outside EarthSciAST, exactly like the GridAccessor / AbstractGrid traits:
#
#   1. the Provider protocol  — `provider_refresh_times` / `provider_is_const` /
#      `provider_sample`. Satisfied by the EarthSciIO Julia Provider
#      (esio-9nb.5) via a thin adapter, or by a mock in tests. EarthSciAST never
#      imports EarthSciIO; it calls these generics, which the data binding fills in.
#   2. `RefreshBuffers` — the registry of live forcing buffers, the SAME dense
#      `Array{Float64}` objects passed to `build_evaluator`'s `param_arrays`.
#      `affect!` writes the freshly sampled native forcing straight into them
#      (`_write_forcing!`); any native→sim regrid is an in-model coupling
#      expression the RHS evaluates, not a refresh-time transform (the obsolete
#      `RegridApplier` seam was removed in v0.8.0).

"""
    RefreshError(msg)

Thrown by the data-refresh surface: an unimplemented Provider
protocol method, a buffer that is not a dense `Array{Float64}`, a
shape/length mismatch at refresh time, or a call to
[`build_refresh_callback`](@ref) before the `DiffEqCallbacks` / `SciMLBase`
extension is loaded.
"""
struct RefreshError <: Exception
    msg::String
end
Base.showerror(io::IO, e::RefreshError) = print(io, "RefreshError: ", e.msg)

# --------------------------------------------------------------------------- #
# Provider protocol (consumer-side; concrete impls live in the data binding)
# --------------------------------------------------------------------------- #
#
# A "provider" is any object that supplies a loader's native-grid arrays on the
# solver time axis. EarthSciAST owns the contract (these three generics) and calls
# them; the EarthSciIO Julia Provider satisfies it via an adapter, e.g.
#
#     EarthSciAST.provider_refresh_times(p::EarthSciIO.Provider) = EarthSciIO.refresh_times(p)
#     EarthSciAST.provider_sample(p::EarthSciIO.Provider, t)     = EarthSciIO.refresh(p, t)
#
# (`provider_is_const` then comes free from the default below). The provider's
# `refresh_times`/`refresh` already speak `Float64` seconds on the SAME axis as
# the integrator's `t` (esio-9nb.5), so J1 needs no wall-clock↔seconds mapping:
# the times ARE the tstops.

"""
    provider_refresh_times(provider) -> AbstractVector{Float64}

The cadence anchors at which `provider`'s data changes, in solver time
(seconds on the integrator's `t` axis). Empty for a time-invariant
(CONST) provider — such a provider is materialized once and contributes no
tstops. Concrete impls live in the data binding (EarthSciIO) or a test mock.
"""
function provider_refresh_times end
provider_refresh_times(p) = throw(RefreshError(
    "provider_refresh_times not implemented for $(typeof(p)); the data binding " *
    "(EarthSciIO) or a mock must add a method"))

"""
    provider_is_const(provider) -> Bool

True if `provider`'s data is time-invariant (no cadence). CONST providers are
materialized once into `const_arrays` at `build_evaluator` time and are absent
from the refresh callback. Defaults to "no refresh times"; a concrete impl may
override (e.g. EarthSciIO's `is_const`).
"""
function provider_is_const end
provider_is_const(p) = isempty(provider_refresh_times(p))

"""
    provider_sample(provider, t::Real) -> sample

The native-grid data for `provider` at cadence tick `t` (solver seconds). The
return value is opaque to EarthSciAST — it is handed straight to the forcing-write seam
(`_write_forcing!`), which extracts a named variable from it.
For the EarthSciIO provider this is `refresh(p, t)` returning a `NativeDataset`;
for a mock it can be any per-variable container (e.g. a `Dict{String,Vector}`).
"""
function provider_sample end
provider_sample(p, ::Real) = throw(RefreshError(
    "provider_sample not implemented for $(typeof(p)); the data binding " *
    "(EarthSciIO) or a mock must add a method"))

# --------------------------------------------------------------------------- #
# Forcing-write seam — pull a freshly sampled field out of a provider sample and
# write it into the live buffer IN PLACE. There is NO native→sim regrid here:
# regridding is an ordinary in-model coupling expression over the native forcing
# (the obsolete `RegridApplier` seam was removed in v0.8.0). The buffer aliases
# the `param_arrays` storage the RHS reads live, so the write MUST mutate in
# place (`copyto!`), never rebind — a fresh allocation would silently detach the
# refresh from `f!`.
# --------------------------------------------------------------------------- #

# Pull the field for `var` out of an opaque provider sample: an `AbstractDict`
# keyed by variable name, or a bare `AbstractArray` for a single-variable sample.
_sample_field(sample::AbstractDict, var::AbstractString) = begin
    haskey(sample, var) || throw(RefreshError(
        "provider sample has no variable '$var' (present: $(collect(keys(sample))))"))
    sample[var]
end
_sample_field(sample::AbstractArray, ::AbstractString) = sample
_sample_field(sample, var::AbstractString) = throw(RefreshError(
    "cannot extract '$var' from a provider sample of type $(typeof(sample)); " *
    "supply an AbstractDict (var => field) or a bare AbstractArray"))

"""
    _write_forcing!(buffer::Array{Float64}, var::AbstractString, sample) -> buffer

Write the freshly sampled `var` field (from a [`provider_sample`](@ref) result)
into `buffer` IN PLACE and return it. The native field lands directly in the
buffer — any regrid onto the sim grid is an in-model coupling expression the RHS
evaluates downstream, not a refresh-time transform. The copy is
column-major-linear, matching the `_VK_PGATHER` linearization (ess-14f.3); it
mutates `buffer` (never rebinds), since the buffer aliases the `param_arrays`
storage the RHS gathers live.
"""
function _write_forcing!(buffer::Array{Float64}, var::AbstractString, sample)
    field = _sample_field(sample, var)
    length(field) == length(buffer) || throw(RefreshError(
        "forcing '$var': provider field has $(length(field)) elements but the buffer " *
        "has $(length(buffer)); the provider must deliver the native forcing on the " *
        "buffer's grid (regridding is an in-model coupling, not a refresh-time transform)"))
    copyto!(buffer, field)
    # The buffer just changed in place under the RHS's live gathers — invalidate the
    # memoized time-cadence prelude slots (B3, tree_walk/const_tier.jl). A refresh
    # callback fires AT its tstop, so the next RHS call may be at a `t` the t-tier
    # stamp already holds; the epoch bump is what makes the refresh visible then.
    _bump_forcing_epoch!()
    return buffer
end

# --------------------------------------------------------------------------- #
# RefreshBuffers — the live forcing buffers (the SAME objects as param_arrays)
# --------------------------------------------------------------------------- #

"""
    RefreshBuffers(buffers::AbstractDict)
    RefreshBuffers(pairs::Pair...)

Registry mapping a forcing variable name to its live buffer — the dense
`Array{Float64}` bound BY REFERENCE through
`build_evaluator(model; param_arrays = …)` (ess-14f.3). The refresh callback's
`affect!` writes the freshly sampled forcing into these exact objects in place, so the RHS
(which gathers the same aliased storage via `_NK_PARAM_GATHER`) sees the update
on its next evaluation.

Each value MUST be a dense `Array{Float64}`, matching the `param_arrays`
invariant — pass the SAME dictionary you gave `param_arrays` (or its values) so
the buffers are shared, not copied:

```julia
forcing = Dict("wind" => zeros(nx, ny))
f!, u0, p, tspan, _ = build_evaluator(model; param_arrays = forcing, …)
buffers = RefreshBuffers(forcing)   # same array objects — aliased, not copied
```
"""
struct RefreshBuffers
    buffers::Dict{String,Array{Float64}}
end

function RefreshBuffers(d::AbstractDict)
    out = Dict{String,Array{Float64}}()
    for (k, v) in d
        k_str = String(k)
        v isa Array{Float64} || throw(RefreshError(
            "RefreshBuffers['$k_str'] must be a dense Array{Float64} (the SAME object " *
            "bound to build_evaluator's param_arrays, captured by reference for live " *
            "refresh), got $(typeof(v))"))
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
    build_refresh_callback(; providers, buffers,
                           post_refresh = () -> nothing)
        -> (cb, tstops::Vector{Float64})

Build the discrete-cadence loader-refresh callback and its tstops, WITHOUT
embedding a solver (`[[library-exposes-rhs-not-solver]]`). The callback is a
pure function of the `providers` and `buffers` registries — it never reads the
model (the forcing names and cadences live entirely in those two arguments).
The caller attaches both to their own problem:

```julia
forcing = Dict("wind" => zeros(nx, ny))
f!, u0, p, tspan, _ = build_evaluator(model; param_arrays = forcing, …)
cb, tstops = build_refresh_callback(;
    providers = Dict("wind" => wind_provider),   # var name => data Provider
    buffers   = RefreshBuffers(forcing))         # same array objects as param_arrays
prob = ODEProblem(f!, u0, tspan, p)              # USER's solver call
sol  = solve(prob, Tsit5(); callback = cb, tstops = tstops)
```

`providers` maps each forcing variable to a data provider (the
[`provider_refresh_times`](@ref) / [`provider_is_const`](@ref) /
[`provider_sample`](@ref) protocol). Several variables may share one provider
object; it is then sampled once per cadence boundary. The provider delivers the
native forcing on the buffer's grid; any native→sim regrid is an ordinary
in-model coupling expression the RHS evaluates (the obsolete `RegridApplier`
seam was removed in v0.8.0), not a refresh-time transform.

* **DISCRETE** providers (non-empty `provider_refresh_times`) are refreshed at
  each anchor: `affect!` samples and writes the buffer in place, then
  calls `u_modified!(integrator, true)`. The forcing lives in `p`, so changing it
  changes `f(u, p, t)` even though `u` is untouched; `true` forces an FSAL
  integrator (Tsit5, …) to recompute its cached derivative from the refreshed
  buffer instead of reusing the stale pre-refresh one for a stage. It does NOT
  reset `u` or the trajectory — only the derivative cache. Dependent/observed
  variables need no separate refresh — they are RHS expressions over the buffers,
  so they recompute automatically on the next step.
* **CONST** providers ([`provider_is_const`](@ref)) are materialized once into
  `const_arrays` at `build_evaluator` time; they contribute no tstops and are
  absent from the callback.

`post_refresh` is a `() -> nothing` hook the `affect!` calls at each boundary
AFTER the raw forcing buffers are refreshed and BEFORE `u_modified!` — the
discrete-cadence materialization seam (the middle phase of the `const ⊏ discrete
⊏ continuous` cadence partition). [`simulate`](@ref) wires it to the
[`DiscreteMaterializer`](@ref)'s `materialize!` so a state-free derived field (a
regrid→physics stack over the forcing) is recomputed once per boundary into its
cache buffer instead of on every continuous step. Defaults to a no-op.

`cb` is a `PresetTimeCallback`; `tstops` is the sorted, de-duplicated union of
the DISCRETE providers' refresh times. Returns an empty-tstops no-op callback
when every provider is CONST.

Requires `DiffEqCallbacks` and `SciMLBase` to be loaded (the constructor is a
package extension); calling it without them throws [`RefreshError`](@ref).
"""
function build_refresh_callback end

# Fallback (varargs ⇒ strictly less specific than the extension's
# zero-positional keyword method): fires only when the extension is NOT loaded.
build_refresh_callback(args...; kwargs...) = throw(RefreshError(
    "build_refresh_callback requires the DiffEqCallbacks + SciMLBase extension; " *
    "add `using DiffEqCallbacks, SciMLBase` (or a solver stack that loads them) so " *
    "EarthSciASTDataRefreshExt is active"))

# --------------------------------------------------------------------------- #
# sync_forcing! — mirror refreshed host buffers into a compiled RHS's argument
# arrays (the B2 hook for the XLA/Reactant tier)
# --------------------------------------------------------------------------- #

"""
    sync_forcing!(dest::NamedTuple, src::NamedTuple) -> dest

Copy every live forcing buffer in `src` into the same-named array of `dest`, in
place (`copyto!` element copy — `dest`'s arrays are never rebound). The refresh
hook for a compiled out-of-place RHS: when the RHS was `@compile`d through
[`rhs_with_buffers`](@ref) with device arrays (`Reactant.ConcreteRArray`s) as
its buffers argument, those arrays are real XLA inputs, and a `copyto!` into
them between calls IS seen by the already-compiled program — so mirroring the
freshly refreshed host buffers into them at each cadence boundary keeps the
compiled forcing live, with no retrace and no reallocation.

Wire it through [`build_refresh_callback`](@ref)'s `post_refresh` hook, which
runs at each cadence boundary AFTER the host buffers are refreshed (and after
the [`DiscreteMaterializer`](@ref) caches are refilled, when `post_refresh`
chains `materialize!` first):

```julia
fo = build_evaluator(model; form = :oop, param_arrays = forcing)[1]
host = forcing_buffers(fo)                        # aliased host buffers, stable order
dev  = map(Reactant.ConcreteRArray, host)         # the compiled program's inputs
rhs  = @compile rhs_with_buffers(fo)(u_r, p_r, t_r, dev)
cb, tstops = build_refresh_callback(;
    providers, buffers = RefreshBuffers(forcing),
    post_refresh = () -> sync_forcing!(dev, host))
```

`src` is normally [`forcing_buffers`](@ref)`(fo)`; any NamedTuple pair works as
long as every key of `src` is present in `dest` and shapes/lengths agree
(`copyto!` enforces length). Missing keys throw [`RefreshError`](@ref).
"""
function sync_forcing!(dest::NamedTuple, src::NamedTuple)
    for k in keys(src)
        haskey(dest, k) || throw(RefreshError(
            "sync_forcing!: destination has no buffer '$k' (present: " *
            "$(collect(keys(dest)))); dest must be aligned with forcing_buffers(f)"))
        copyto!(getfield(dest, k), getfield(src, k))
    end
    return dest
end
