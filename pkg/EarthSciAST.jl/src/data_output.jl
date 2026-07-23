# Streaming output sinks — the EarthSciAST-Julia producer surface
# (streaming-output-sinks RFC §16, Wave 1). This file is the OUTPUT mirror of the
# pure-I/O data-loader INPUT seam in `data_refresh.jl`.
#
# Where `data_refresh.jl` PULLS native arrays from a data Provider into the live
# forcing buffers at each cadence boundary, this file PUSHES simulation state to a
# Sink at each output boundary: a `PresetTimeCallback` whose `affect!` snapshots
# the integrator state (and any caller-named observed fields) and hands it to each
# sink for persistence. The trajectory never has to be fully resident — the sink
# IS the trajectory store, so the solver is told `save_everystep=false` and peak
# memory stops being `O(n_timepoints × length(u0))`.
#
# Principle `[[library-exposes-rhs-not-solver]]`: EarthSciAST returns the *pieces*
# (`build_output_callback -> (cb, tstops)`); the USER attaches them to their own
# `ODEProblem`/`solve`. EarthSciAST ships no `solve`, no `ODEProblem`, no solver.
# The callback constructor itself lives in a package extension gated on
# `DiffEqCallbacks` + `SciMLBase` (see ext/EarthSciASTDataOutputExt.jl) so the base
# library never pulls a solver-adjacent stack into `[deps]` — identical to the
# `DataRefreshExt` pattern.
#
# This file (core) owns the CONTRACT (the Sink protocol generics + a host-gather
# `state_snapshot` seam); concrete sinks live OUTSIDE EarthSciAST, exactly like the
# Provider protocol's concrete impl is the EarthSciIO `Provider`. Wave 1 ships no
# concrete sink — the EarthSciIO-bound Zarr sink is a later wave; the tests use a
# mock. EarthSciAST never imports EarthSciIO; it calls these generics, which the
# data binding (or a mock) fills in.

"""
    OutputError(msg)

Thrown by the streaming-output surface: an unimplemented Sink protocol method, a
malformed snapshot, or a call to [`build_output_callback`](@ref) before the
`DiffEqCallbacks` / `SciMLBase` extension is loaded. The output-side mirror of
[`RefreshError`](@ref).
"""
struct OutputError <: Exception
    msg::String
end
Base.showerror(io::IO, e::OutputError) = print(io, "OutputError: ", e.msg)

# --------------------------------------------------------------------------- #
# AbstractSink — an optional supertype for concrete sinks. Sinks need NOT subtype
# it (the protocol dispatches structurally on the generics below, exactly like the
# Provider protocol accepts any object); it exists so `simulate`'s `sinks` kwarg
# has a meaningful element type and so a concrete binding may opt in.
# --------------------------------------------------------------------------- #

"""
    AbstractSink

Optional supertype for a streaming output sink. A sink is any object implementing
the Sink protocol ([`sink_output_times`](@ref) / [`sink_open!`](@ref) /
[`sink_write!`](@ref) / [`sink_flush!`](@ref) / [`sink_close!`](@ref)); it need
not subtype `AbstractSink` (the protocol dispatches structurally, mirroring how
the Provider protocol accepts any object). It exists as the declared element type
of [`simulate`](@ref)'s `sinks` keyword and as an opt-in for concrete bindings.
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
  `(slab, global-range tuple)` pairs. In v1 (host-gather) this is exactly ONE
  entry, `(Array(u), (1:length(u),))` — the whole flat state at offset 0. The
  vector-of-slabs shape is what lets the deferred Reactant shard-local
  [`state_snapshot`](@ref) return each rank's addressable shard with its GLOBAL
  range instead of a gathered whole, with no change to the sink or the callback.
* `observed::Dict{String,Array}` — caller-named observed/derived arrays,
  host-materialized (empty unless a sink's schema names observed outputs; those
  names drive what `pre_write` evaluates — the evaluator already produces them).
"""
struct StateSnapshot
    t::Float64
    state::Vector{Tuple{Array,Tuple{Vararg{UnitRange{Int}}}}}
    observed::Dict{String,Array}
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
sink_output_times(s) = throw(OutputError(
    "sink_output_times not implemented for $(typeof(s)); the data binding " *
    "(EarthSciIO) or a mock must add a method"))

"""
    sink_open!(sink)

Open `sink` for writing against its OWN `OutputSchema` (declare dims / coordinates
/ variables / chunk-shard grid ONCE). Called before the first
[`sink_write!`](@ref). Concrete impls live in the data binding or a test mock.
"""
function sink_open! end
sink_open!(s) = throw(OutputError(
    "sink_open! not implemented for $(typeof(s)); the data binding " *
    "(EarthSciIO) or a mock must add a method"))

"""
    sink_write!(sink, snap::StateSnapshot; selection=nothing)

Persist one time record: scatter the [`StateSnapshot`](@ref)'s state slabs and
observed arrays into `sink`'s gridded arrays. The output-side mirror of
[`provider_sample`](@ref).

`selection` is the write-side mirror of the Provider's read-side projection
pushdown: an optional per-axis sub-slab so a sink is handed only part of an axis
(distributed region writes). It is INERT in v1 (host-gather delivers the whole
state as a single offset-0 slab, `selection===nothing`); it becomes live with the
deferred Reactant shard-local [`state_snapshot`](@ref) + [`sink_supports_partial`](@ref).
Concrete impls live in the data binding or a test mock.
"""
function sink_write! end
sink_write!(s, ::StateSnapshot; selection=nothing) = throw(OutputError(
    "sink_write! not implemented for $(typeof(s)); the data binding " *
    "(EarthSciIO) or a mock must add a method"))

"""
    sink_flush!(sink)

Durable barrier: make every record written so far durable (the checkpoint-boundary
commit). Concrete impls live in the data binding or a test mock.
"""
function sink_flush! end
sink_flush!(s) = throw(OutputError(
    "sink_flush! not implemented for $(typeof(s)); the data binding " *
    "(EarthSciIO) or a mock must add a method"))

"""
    sink_close!(sink)

Finalize `sink`: flush, write the end-of-run manifest / consolidated metadata, and
release resources. Called once after the last [`sink_write!`](@ref). Concrete impls
live in the data binding or a test mock.
"""
function sink_close! end
sink_close!(s) = throw(OutputError(
    "sink_close! not implemented for $(typeof(s)); the data binding " *
    "(EarthSciIO) or a mock must add a method"))

"""
    sink_supports_partial(sink) -> Bool

True if `sink` can accept a sub-slab (region) write — the write-side mirror of
[`provider_supports_selection`](@ref), used for distributed shard-local output.
Defaults to `false`; it is INERT in v1 (host-gather is a single whole-state write)
and becomes load-bearing with the deferred Reactant shard-local phase. A concrete
binding overrides it.
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
# state_snapshot — the ONE place the output callback touches the solver state.
# HOST-GATHER v1 impl (RFC §6, §16.4): the whole flat state as a single offset-0
# slab. Kept a small standalone function so the Reactant shard-local impl (return
# each device's addressable shard with its GLOBAL range, no gather) can be added
# later WITHOUT touching any caller — the same "ship behind a stable seam" pattern
# the input side uses for `_write_forcing!` / `sync_forcing!`.
# --------------------------------------------------------------------------- #

"""
    state_snapshot(integrator) -> Vector{Tuple{Array,Tuple{Vararg{UnitRange{Int}}}}}

Host-gather the integrator's state into the [`StateSnapshot`](@ref) `state` shape:
in v1 exactly one `(Array(integrator.u), (1:length(integrator.u),))` pair — the
whole flat state materialized on the host at global offset 0. `Array(u)` triggers
XLA's gather to host under a replicated/single-host Reactant tier and is a plain
copy on the CPU tree-walk path, so this one impl is correct at any scale that fits
one host's write bandwidth.

This is the mirror of what the INPUT side already does when it materializes host
forcing buffers. The multi-slab (shard-local) return — each device's local shard
with its global range, no global gather — is the deferred Reactant drop-in; adding
it changes only this function, not the sink or the callback.
"""
function state_snapshot(integrator)
    u = integrator.u
    return Tuple{Array,Tuple{Vararg{UnitRange{Int}}}}[
        (Array(u), (1:length(u),))]
end

# --------------------------------------------------------------------------- #
# build_output_callback — public surface; method lives in the extension
# --------------------------------------------------------------------------- #

"""
    build_output_callback(; sinks, snapshot = state_snapshot,
                          pre_write = () -> nothing)
        -> (cb, tstops::Vector{Float64})

Build the streaming-output callback and its tstops, WITHOUT embedding a solver
(`[[library-exposes-rhs-not-solver]]`) — the output-side mirror of
[`build_refresh_callback`](@ref). The callback is a pure function of the `sinks`
and the `snapshot`/`pre_write` seams; it never reads the model. The caller attaches
it to their own problem:

```julia
cb, tstops = build_output_callback(; sinks = [my_sink])
prob = ODEProblem(f!, u0, tspan, p)              # USER's solver call
sol  = solve(prob, Tsit5(); callback = cb, tstops = tstops, save_everystep = false)
```

* `sinks` — a collection of objects implementing the Sink protocol
  ([`sink_output_times`](@ref) / [`sink_write!`](@ref) / …). Each has its OWN
  output cadence; multiple sinks with different cadences are first-class.
* `snapshot` — an `integrator -> StateSnapshot` function. Defaults to
  [`state_snapshot`](@ref) wrapped to also fold in the observed caches; a caller
  supplies one that captures its observed caches when writing observed fields.
* `pre_write` — a `() -> nothing` hook the `affect!` calls at each output boundary
  BEFORE `snapshot(integrator)`, so the caller-named observed caches are fresh when
  the snapshot reads them. Defaults to a no-op.

`affect!` at each tick: run `pre_write()`, build the snapshot via
`snapshot(integrator)`, then for each sink whose `sink_output_times` contains the
tick, call `sink_write!(sink, snap)`.

`cb` is a `PresetTimeCallback`; `tstops` is the sorted, de-duplicated UNION of
every sink's [`sink_output_times`](@ref) — the identical construction
[`build_refresh_callback`](@ref) uses for provider refresh times, so **input
refresh and output write compose in one `CallbackSet`** (union the two tstops).
Returns an empty-tstops no-op callback when every sink is predicate-only.

Requires `DiffEqCallbacks` and `SciMLBase` to be loaded (the constructor is a
package extension); calling it without them throws [`OutputError`](@ref).
"""
function build_output_callback end

# Fallback (varargs ⇒ strictly less specific than the extension's
# zero-positional keyword method): fires only when the extension is NOT loaded.
build_output_callback(args...; kwargs...) = throw(OutputError(
    "build_output_callback requires the DiffEqCallbacks + SciMLBase extension; " *
    "add `using DiffEqCallbacks, SciMLBase` (or a solver stack that loads them) so " *
    "EarthSciASTDataOutputExt is active"))

# --------------------------------------------------------------------------- #
# Flat→gridded inversion (RFC §7). The shared, language-neutral piece: invert the
# column-major `name[i,j]` cell-key scheme (`_parse_cell_key`) so a flat `u` slab
# scatters into per-variable gridded arrays. Pure EarthSciAST (no EarthSciIO), so
# the same derivation feeds any Writer backend and can be specified once in the
# shared conformance spec.
#
# Wave 2 note: dimension NAMES here are POSITIONAL (`<base>_d0`, …). Binding an
# axis to its real `index_sets` name + the `coordinates` registry (CF metadata) is
# the next wave (needs the run document, which `PreparedModel` does not carry); the
# SCATTER (shape + placement) is already final and correct.
# --------------------------------------------------------------------------- #

"""
    VarGridding

The gridded layout of one output base-variable, derived from a flat `var_map`
(RFC §7). Scatter a flat state vector `u` into this variable's gridded array with
`grid[cart[k]] = u[flat_indices[k]]` — placement is by explicit `CartesianIndex`,
so it is correct regardless of enumeration order.

* `base::String` — the variable's base name (the cell key minus its `[…]`).
* `shape::Vector{Int}` — the gridded spatial shape (a scalar variable gets the
  singleton shape `[1]`, so it always has at least one spatial axis to name).
* `dimnames::Vector{String}` — one positional dim name per axis of `shape`
  (Wave 2: `"<base>_d0"`, …; real `index_sets` names are a later wave).
* `flat_indices::Vector{Int}` — the flat `u` indices of this variable's cells.
* `cart::Vector{CartesianIndex}` — the 1-based grid position of each
  `flat_indices` entry (same order).
"""
struct VarGridding
    base::String
    shape::Vector{Int}
    dimnames::Vector{String}
    flat_indices::Vector{Int}
    cart::Vector{CartesianIndex}
end

"""
    derive_output_gridding(var_map) -> Vector{VarGridding}

Invert the flat `var_map` (state-element name → flat index) into one
[`VarGridding`](@ref) per output base-variable (RFC §7). Groups the cell keys by
base name via [`_parse_cell_key`](@ref) (a key with no `[…]` suffix is a scalar
variable), derives each axis length as the max cell index along that axis, and
records the flat-index → `CartesianIndex` scatter map. Base-variable order is the
first-seen order in `var_map`'s iteration, made deterministic by sorting on the
base name so the derived schema is reproducible.
"""
function derive_output_gridding(var_map::AbstractDict)
    groups = Dict{String,Vector{Tuple{Int,Vector{Int}}}}()  # base => [(flat_idx, indices)]
    for (key, idx) in var_map
        parsed = _parse_cell_key(String(key))
        base, inds = parsed === nothing ? (String(key), Int[]) : parsed
        push!(get!(groups, base, Tuple{Int,Vector{Int}}[]), (Int(idx), inds))
    end
    out = VarGridding[]
    for base in sort!(collect(keys(groups)))
        entries = groups[base]
        ndim = maximum(length(e[2]) for e in entries)
        if ndim == 0
            length(entries) == 1 || throw(OutputError(
                "scalar variable '$base' maps to $(length(entries)) flat indices; a " *
                "scalar cell key must be unique"))
            fi = entries[1][1]
            push!(out, VarGridding(base, [1], ["$(base)_d0"], [fi], [CartesianIndex(1)]))
        else
            shape = zeros(Int, ndim)
            for (_, inds) in entries
                length(inds) == ndim || throw(OutputError(
                    "variable '$base' has cells of differing dimensionality " *
                    "($(length(inds)) vs $ndim); a gridded variable must be rectangular"))
                @inbounds for d in 1:ndim
                    shape[d] = max(shape[d], inds[d])
                end
            end
            flat = Int[e[1] for e in entries]
            cart = CartesianIndex[CartesianIndex(Tuple(e[2])...) for e in entries]
            dimnames = String["$(base)_d$(d-1)" for d in 1:ndim]
            push!(out, VarGridding(base, shape, dimnames, flat, cart))
        end
    end
    return out
end

"""
    scatter_grid!(grid, g::VarGridding, u) -> grid

Scatter the flat state `u` into the pre-allocated gridded `grid` for variable
`g`: `grid[cart[k]] = u[flat_indices[k]]`. `grid` must have size `Tuple(g.shape)`.
"""
function scatter_grid!(grid::AbstractArray, g::VarGridding, u::AbstractVector)
    @inbounds for k in eachindex(g.flat_indices)
        grid[g.cart[k]] = u[g.flat_indices[k]]
    end
    return grid
end

"""
    gather_flat!(u, g::VarGridding, grid) -> u

The inverse of [`scatter_grid!`](@ref): read a variable's gridded `grid` back into
the flat state `u`, `u[flat_indices[k]] = grid[cart[k]]`. This is the restart-read
direction (streaming-output-sinks RFC §10, §16.7) — reconstruct a flat `u0` from a
checkpoint store's gridded arrays. `grid` must have size `Tuple(g.shape)`.
"""
function gather_flat!(u::AbstractVector, g::VarGridding, grid::AbstractArray)
    @inbounds for k in eachindex(g.flat_indices)
        u[g.flat_indices[k]] = grid[g.cart[k]]
    end
    return u
end

# --------------------------------------------------------------------------- #
# Output metadata (RFC §7, §8, Wave 3). The flat `var_map` gives SHAPE (§7); the
# run document gives the REAL axis NAMES (a variable's declared `shape` = ordered
# index-set names), the per-axis sizes (`index_sets`), the per-variable CF attrs
# (`units`, …), and the additive `coordinates` registry (§8.3). `OutputMeta`
# distills exactly that slice of the run doc so a sink emits `lon`/`lat` dims (not
# positional `<base>_d0`) and CF dimension-coordinates, WITHOUT the sink or the
# writer importing the document model. Built once by [`derive_output_meta`] in
# `prepare` (the doc is in scope there; `PreparedModel` carries the result).
# --------------------------------------------------------------------------- #

"""
    OutputMeta

The document-derived output metadata carried by a [`PreparedModel`](@ref) so a
streaming sink can name axes and emit CF coordinates (RFC §7–§8). Distilled from
the flattened run document by [`derive_output_meta`](@ref).

* `model_name::String` — the single flattened model's key (namespacing prefix of
  the `var_map`'s base names).
* `index_sets::Dict{String,Int}` — index-set name → axis length (interval `size`;
  categorical member count).
* `var_dims::Dict{String,Vector{String}}` — namespaced base variable name → its
  declared `shape` (ordered index-set / dim names). Absent for scalars.
* `var_attrs::Dict{String,Dict{String,Any}}` — namespaced base variable name → CF
  variable attributes retained from the doc (`units`, `standard_name`,
  `description` when present).
* `coordinates::Dict{String,Any}` — the additive `coordinates` registry (§8.3),
  verbatim: entry name → `{values|source, standard_name, units, axis}`. Empty when
  the document declares none.
"""
struct OutputMeta
    model_name::String
    index_sets::Dict{String,Int}
    var_dims::Dict{String,Vector{String}}
    var_attrs::Dict{String,Dict{String,Any}}
    coordinates::Dict{String,Any}
end

const _EMPTY_OUTPUT_META = OutputMeta("", Dict{String,Int}(),
    Dict{String,Vector{String}}(), Dict{String,Dict{String,Any}}(), Dict{String,Any}())

# Static axis length of an index-set entry: interval `size`; categorical member
# count; 0 (unknown-here) for derived/ragged whose extent needs the build.
function _index_set_axis_len(is::AbstractDict)
    kind = get(is, "kind", nothing)
    if kind == "interval"
        return Int(get(is, "size", 0))
    elseif kind == "categorical"
        m = get(is, "members", nothing)
        return m isa AbstractVector ? length(m) : 0
    else
        sz = get(is, "size", nothing)
        return sz === nothing ? 0 : Int(sz)
    end
end

"""
    derive_output_meta(doc) -> OutputMeta

Distill the flattened run document into [`OutputMeta`](@ref): the single model's
name, the `index_sets` axis lengths, each variable's declared `shape` (real dim
names) + retained CF attrs, and the additive `coordinates` registry (§8.3).
Returns an empty `OutputMeta` for a document with no `models` (nothing to name).
Reads only the doc — no build artifacts — so it composes with `derive_output_gridding`.
"""
function derive_output_meta(doc::AbstractDict)
    models = get(doc, "models", nothing)
    (models isa AbstractDict && !isempty(models)) || return _EMPTY_OUTPUT_META
    sname = String(first(keys(models)))
    model = models[sname]

    idx = Dict{String,Int}()
    isets = get(doc, "index_sets", nothing)
    if isets isa AbstractDict
        for (nm, is) in isets
            is isa AbstractDict && (idx[String(nm)] = _index_set_axis_len(is))
        end
    end

    vdims = Dict{String,Vector{String}}()
    vattrs = Dict{String,Dict{String,Any}}()
    vars = model isa AbstractDict ? get(model, "variables", nothing) : nothing
    if vars isa AbstractDict
        for (vn, v) in vars
            v isa AbstractDict || continue
            base = String(vn)
            shp = get(v, "shape", nothing)
            shp isa AbstractVector && (vdims[base] = String[String(s) for s in shp])
            a = Dict{String,Any}()
            for k in ("units", "standard_name", "description")
                haskey(v, k) && v[k] !== nothing && (a[k] = v[k])
            end
            isempty(a) || (vattrs[base] = a)
        end
    end

    coords = get(doc, "coordinates", nothing)
    cdict = coords isa AbstractDict ?
        Dict{String,Any}(String(k) => v for (k, v) in coords) : Dict{String,Any}()

    return OutputMeta(sname, idx, vdims, vattrs, cdict)
end

"""
    derive_output_gridding(var_map, meta::OutputMeta) -> Vector{VarGridding}

Doc-aware [`derive_output_gridding`](@ref): first invert the flat `var_map`
(shape + scatter map, the language-neutral core), then rename each variable's axes
from positional `<base>_d0` to its REAL declared dim names via `meta.var_dims`
(RFC §7 → §8). A variable with no declared `shape` in `meta` (a scalar, or a
`var_map` built without a document) keeps its positional names. Validates that the
declared dim count and each `index_sets` length agree with the shape recovered
from the flat state — a mismatch means the document and the built state disagree,
which must fail loudly rather than mislabel an axis.
"""
function derive_output_gridding(var_map::AbstractDict, meta::OutputMeta)
    return VarGridding[_name_gridding(g, meta) for g in derive_output_gridding(var_map)]
end

function _name_gridding(g::VarGridding, meta::OutputMeta)
    dims = get(meta.var_dims, g.base, nothing)
    dims === nothing && return g                      # scalar / undeclared → positional
    length(dims) == length(g.shape) || throw(OutputError(
        "output metadata for '$(g.base)' declares $(length(dims)) dim(s) $(dims), but the " *
        "flat state grids it to $(length(g.shape)) axis/axes $(g.shape)"))
    for d in eachindex(dims)
        sz = get(meta.index_sets, dims[d], nothing)
        (sz === nothing || sz == 0 || sz == g.shape[d]) || throw(OutputError(
            "output metadata: '$(g.base)' axis $d is index set '$(dims[d])' of size $sz, " *
            "but the flat state grids that axis to length $(g.shape[d])"))
    end
    return VarGridding(g.base, g.shape, copy(dims), g.flat_indices, g.cart)
end

"""
    DimCoord(name, values, attrs)

A CF **dimension coordinate** (§8.3): a 1-D coordinate variable named exactly like
its dimension, its monotonic `values`, and its CF `attrs` (`standard_name` /
`units` / `axis`). Emitted once at [`sink_open!`](@ref). Auxiliary (unstructured /
curvilinear) coordinates — whose registry key differs from the dim name and whose
values come from a `source` array — are a later drop-in on the same registry; v1
emits inline-`values` dimension coordinates.
"""
struct DimCoord
    name::String
    values::Vector{Float64}
    attrs::Dict{String,Any}
end

"""
    plan_dimension_coordinates(gridding, meta::OutputMeta) -> Vector{DimCoord}

Resolve the `coordinates` registry (§8.3) into the CF **dimension coordinates**
for a set of [`VarGridding`](@ref)s: for each distinct spatial dim, if the registry
has an entry KEYED BY THAT DIM NAME carrying inline `values`, emit a [`DimCoord`](@ref)
(validating its length against the dim's grid length) with the entry's
`standard_name`/`units`/`axis` attrs. Registry entries whose key is not a dim name
(auxiliary coordinates) and `source`-backed entries are skipped in v1 (the
dimension-coordinate path handles inline values); they are the documented next
drop-in. Dims with no registry entry emit no coordinate (bare integer axis, as before).
"""
function plan_dimension_coordinates(gridding::AbstractVector{VarGridding}, meta::OutputMeta)
    dimlen = Dict{String,Int}()
    order = String[]
    for g in gridding, d in eachindex(g.dimnames)
        nm = g.dimnames[d]
        haskey(dimlen, nm) || push!(order, nm)
        dimlen[nm] = g.shape[d]
    end
    coords = DimCoord[]
    for nm in order
        entry = get(meta.coordinates, nm, nothing)
        entry isa AbstractDict || continue
        vals = get(entry, "values", nothing)
        vals isa AbstractVector || continue           # source/aux: not the inline-dim path
        v = Float64[Float64(x) for x in vals]
        length(v) == dimlen[nm] || throw(OutputError(
            "coordinate '$nm' supplies $(length(v)) value(s) but dimension '$nm' has " *
            "length $(dimlen[nm])"))
        attrs = Dict{String,Any}()
        for k in ("standard_name", "units", "axis")
            haskey(entry, k) && entry[k] !== nothing && (attrs[k] = entry[k])
        end
        push!(coords, DimCoord(nm, v, attrs))
    end
    return coords
end

# --------------------------------------------------------------------------- #
# build_zarr_sink — public surface; concrete ZarrSink lives in the EarthSciIO ext
# (mirror of build_output_callback / build_refresh_callback: core owns the generic
# + a throwing fallback, the data binding supplies the method).
# --------------------------------------------------------------------------- #

"""
    build_zarr_sink(source, base_url; output_times, kwargs...) -> sink

Construct a concrete Zarr [streaming sink](@ref sink_output_times) writing to the
store at `base_url` (a `file://` URL or path). `source` is a [`PreparedModel`](@ref)
(or a bare `var_map` dict); `output_times` are the solver-second anchors at which
the sink writes. The returned object implements the Sink protocol and is passed to
[`simulate`](@ref)'s `sinks` keyword.

Requires `EarthSciIO` to be loaded (the concrete sink is in the
`EarthSciASTEarthSciIOExt` extension); calling it without EarthSciIO throws
[`OutputError`](@ref).
"""
function build_zarr_sink end
build_zarr_sink(args...; kwargs...) = throw(OutputError(
    "build_zarr_sink requires the EarthSciIO extension; add `using EarthSciIO` so " *
    "EarthSciASTEarthSciIOExt (the concrete Zarr sink) is active"))

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
zarr_restart_state(args...; kwargs...) = throw(OutputError(
    "zarr_restart_state requires the EarthSciIO extension; add `using EarthSciIO` so " *
    "EarthSciASTEarthSciIOExt (the reader + output manifest) is active"))

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
function slurm_walltime_predicate(; margin_seconds::Real = 300,
                                  clock = _unix_now,
                                  end_time_env::AbstractString = "SLURM_JOB_END_TIME")
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
build_checkpoint_callback(args...; kwargs...) = throw(OutputError(
    "build_checkpoint_callback requires the DiffEqCallbacks + SciMLBase extension; " *
    "add `using DiffEqCallbacks, SciMLBase` so EarthSciASTDataOutputExt is active"))
