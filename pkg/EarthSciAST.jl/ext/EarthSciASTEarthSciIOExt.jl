"""
    EarthSciASTEarthSciIOExt

Wires the EarthSciIO Julia `Provider` into EarthSciAST's data-provider seam
([`provider_refresh_times`](@ref) / [`provider_sample`](@ref)), loaded
automatically whenever `EarthSciIO` is in the session alongside
EarthSciAST. Before this extension existed the adapter shipped only as
a doc comment on the seam (`data_refresh.jl`), so every run script had to repeat
it; now `simulate(...; providers = Dict("Loader.var" => provider))` accepts an
EarthSciIO provider with no per-script glue.

DELIBERATELY THIN. EarthSciAST is agnostic to dimension order: the provider sample is
handed straight to the forcing-write / const-array fold, which
linearizes it column-major against the CONSUMER's declared shape and never
inspects the data's named dims or coordinates (`_write_forcing!`,
`_provider_const_field`, the `LinearIndices(pg.dims)` gather). So this adapter
does NOT reproject, transpose, or reorder — it returns the provider's array in
its native file order. Any grid/orientation reconciliation is the model's job
(declare the loader field in the source's native dim order, then regrid/reindex
in a coupling expression), exactly as it would be for any other provider.

Kept a `weakdep` extension (mirroring `MTKExt` / `DataRefreshExt`) so the base
package carries no EarthSciIO dependency; without it loaded, the core seam throws
a `RefreshError` naming what to load.
"""
module EarthSciASTEarthSciIOExt

using EarthSciAST: RefreshError, OutputError, StateSnapshot, VarGridding,
    derive_output_gridding, scatter_grid!
# Explicit imports so we can add the extension methods to these generics.
import EarthSciAST: provider_refresh_times, provider_sample, provider_supports_selection
import EarthSciAST: build_zarr_sink, sink_output_times, sink_open!, sink_write!,
    sink_flush!, sink_close!, sink_observed_names
import EarthSciIO

# The cadence anchors, straight from the provider (empty ⇒ CONST, which makes the
# default `provider_is_const` — `isempty(provider_refresh_times(p))` — report true
# with no extra method).
provider_refresh_times(p::EarthSciIO.Provider) = EarthSciIO.refresh_times(p)

# Capability bridge: whether this provider can push a projection down (true for a
# store-backed zarr provider, false for a whole-file reader). The generic default
# (`provider_supports_selection(::Any) = false`, data_refresh.jl) already covers
# every non-EarthSciIO source.
provider_supports_selection(p::EarthSciIO.Provider) = EarthSciIO.supports_selection(p)

# Translate the provider-NEUTRAL, 1-based, per-axis positional `selection` into
# EarthSciIO's native `Dict("axes" => [...])` with 0-based indices:
#   Colon()                       → "all"                     (whole axis)
#   Integer i                     → Dict("indices" => [i-1])  (single fixed index)
#   AbstractVector v (of Integer) → Dict("indices" => v .- 1) (ordered index list)
# 1-based is validated here (every index ≥ 1) so an accidental 0-based caller gets
# a clear error rather than a silently-shifted, off-by-one slice.
function _neutral_selection_to_native(selection::AbstractVector)
    axes = Any[]
    for (d, ax) in enumerate(selection)
        if ax isa Colon
            push!(axes, "all")
        elseif ax isa Integer
            ax >= 1 || throw(RefreshError(
                "selection axis $d: index must be 1-based (≥ 1), got $ax"))
            push!(axes, Dict("indices" => [Int(ax) - 1]))
        elseif ax isa AbstractVector{<:Integer}
            idx = collect(Int, ax)
            all(>=(1), idx) || throw(RefreshError(
                "selection axis $d: indices must be 1-based (≥ 1), got $idx"))
            push!(axes, Dict("indices" => idx .- 1))
        else
            throw(RefreshError(
                "selection axis $d: unrecognized entry $(ax)::$(typeof(ax)); use " *
                "Colon() (whole axis), an Integer (1-based single index), or an " *
                "AbstractVector{<:Integer} (1-based ordered index list)"))
        end
    end
    return Dict("axes" => axes)
end
_neutral_selection_to_native(selection) = throw(RefreshError(
    "selection must be an AbstractVector with one entry per native axis " *
    "(Colon / Integer / integer vector), got $(typeof(selection))"))

# One forcing field at cadence tick `t`, in the source's NATIVE layout (no
# reorder — see the module docstring). `providers` is keyed one entry per consumer
# variable, so a sample carries exactly one data variable; a multi-variable blob
# is a binding error the caller must split (EarthSciAST can't know which field a bare
# array means). Returns the bare `AbstractArray` that `_write_forcing!` /
# `_provider_const_field` expect for a single-variable sample.
#
# `selection===nothing` (default) samples the whole array — byte-identical to the
# pre-pushdown path. A non-nothing `selection` is translated to the native zarr
# `select` and pushed down so only the intersecting chunks are fetched; the gated
# axis is returned in EXACTLY the requested index order (the reader gathers in the
# order of the index vector — see EarthSciIO `_resolve_axis`/`_assemble`).
function provider_sample(p::EarthSciIO.Provider, t::Real; selection = nothing)
    if selection === nothing
        nds = EarthSciIO.refresh(p, Float64(t))          # == materialize(p, t)
    else
        provider_supports_selection(p) || throw(RefreshError(
            "provider does not support selection/pushdown: $(typeof(p)) is not a " *
            "store-backed reader (provider_supports_selection is false). Sample it " *
            "without a `selection`, or bind a pushdown-capable provider (zarr)"))
        native = _neutral_selection_to_native(selection)
        nds = EarthSciIO.refresh(p, Float64(t); select = native)
    end
    vars = EarthSciIO.variable_names(nds)
    length(vars) == 1 || throw(RefreshError(
        "EarthSciIO provider yields $(length(vars)) variables $(vars); bind one " *
        "provider per consumer variable (providers[\"Loader.var\"] => provider) so " *
        "each sample is a single field, or slice the provider upstream"))
    return nds[vars[1]].data
end

# --------------------------------------------------------------------------- #
# ZarrSink — the concrete streaming output sink (RFC §5, §16). Binds the
# EarthSciAST Sink protocol to EarthSciIO's Zarr v3 `ZarrWriter`: it derives a
# gridded `OutputSchema` from the flat state, scatters each `StateSnapshot` slab
# into gridded arrays (column-major, via `scatter_grid!`), and streams them as
# atomically-committed time-shards. The write-side mirror of the read-side
# `Provider` adapter above.
#
# Wave 2: state-only, host-gather, positional dim names, one store. Observed
# fields, the `coordinates`/CF metadata (real axis names), checkpoint profiles,
# and object stores are later waves; the sink protocol does not change for them.
# --------------------------------------------------------------------------- #

mutable struct ZarrSink
    base_url::String                 # file:// URL or path of the output store
    gridding::Vector{VarGridding}    # per-base-variable flat→gridded layout (RFC §7)
    output_times::Vector{Float64}    # solver-second write anchors
    profile::Symbol                  # :diagnostic | :checkpoint (codec params)
    records_per_shard::Int           # time records packed per flushed shard object
    time_dim::String                 # growable time axis name
    writer::Any                      # EarthSciIO.ZarrWriter (set at open)
    handle::Any                      # write handle (set at open)
    manifest::Any                    # EarthSciIO.OutputManifest (set at close)
end

"""
    build_zarr_sink(prep::PreparedModel, base_url; output_times, kwargs...) -> ZarrSink
    build_zarr_sink(var_map::AbstractDict, base_url; output_times, kwargs...) -> ZarrSink

Construct a [`ZarrSink`](@ref) streaming the flat state to the Zarr v3 store at
`base_url`. The gridded layout is derived from the model's `var_map`
([`derive_output_gridding`](@ref), RFC §7). Keyword `output_times` are the
solver-second anchors; `profile` (`:diagnostic`/`:checkpoint`) selects codec
params; `records_per_shard` sets how many time records pack into one shard object;
`time_dim` names the growable axis.
"""
function build_zarr_sink(var_map::AbstractDict, base_url::AbstractString;
                         output_times, profile::Symbol = :diagnostic,
                         records_per_shard::Integer = 8,
                         time_dim::AbstractString = "time")
    g = derive_output_gridding(var_map)
    return ZarrSink(String(base_url), g, collect(Float64, output_times), profile,
                    Int(records_per_shard), String(time_dim), nothing, nothing, nothing)
end

build_zarr_sink(prep, base_url::AbstractString; kwargs...) =
    build_zarr_sink(prep.var_map, base_url; kwargs...)

sink_output_times(s::ZarrSink) = s.output_times
sink_observed_names(::ZarrSink) = String[]      # Wave 2: state only

function sink_open!(s::ZarrSink)
    # Collect distinct spatial dims (name => length) in first-seen order, then the
    # growable time axis (length 0 placeholder — it grows one shard per flush).
    dims = Pair{String,Int}[]
    seen = Set{String}()
    for g in s.gridding, d in eachindex(g.dimnames)
        nm = g.dimnames[d]
        if !(nm in seen)
            push!(dims, nm => g.shape[d]); push!(seen, nm)
        end
    end
    push!(dims, s.time_dim => 0)

    vars = Pair{String,EarthSciIO.OutputVar}[]
    for g in s.gridding
        odims = String[g.dimnames...]; push!(odims, s.time_dim)   # time last
        push!(vars, g.base => EarthSciIO.OutputVar(odims, Float64))
    end

    # Default chunk/shard: whole spatial extent per chunk (one map per read); time
    # inner-chunk = 1 record, shard packs `records_per_shard` records per object.
    chunk = Dict{String,Int}(); shard = Dict{String,Int}()
    for (nm, len) in dims
        if nm == s.time_dim
            chunk[nm] = 1
            shard[nm] = max(1, s.records_per_shard)
        else
            chunk[nm] = len
            shard[nm] = len
        end
    end

    schema = EarthSciIO.OutputSchema(; dims = dims, time_dim = s.time_dim, vars = vars,
                                     chunk_shape = chunk, shard_shape = shard,
                                     profile = s.profile)
    # The registry is the discovery seam (WRITER_REGISTRY["zarr"] is :active); the
    # binding knows it wants zarr, so it constructs the writer directly.
    s.writer = EarthSciIO.ZarrWriter()
    s.handle = EarthSciIO.write_open!(s.writer, nothing, s.base_url, schema)
    return s
end

function sink_write!(s::ZarrSink, snap::StateSnapshot; selection = nothing)
    selection === nothing || throw(OutputError(
        "ZarrSink: `selection`/partial writes are inert in v1 (host-gather delivers " *
        "the whole state as a single offset-0 slab)"))
    s.handle === nothing && throw(OutputError(
        "ZarrSink.sink_write! before sink_open!; open the sink first"))
    isempty(snap.state) && throw(OutputError("ZarrSink: empty StateSnapshot.state"))
    u = snap.state[1][1]::AbstractArray            # v1: the whole flat state, offset 0
    arrays = Dict{String,Any}()
    for g in s.gridding
        grid = Array{Float64}(undef, Tuple(g.shape)...)
        scatter_grid!(grid, g, u)
        arrays[g.base] = grid
    end
    EarthSciIO.write_record!(s.writer, s.handle, snap.t, arrays)
    return nothing
end

# The writer commits a durable shard object at each shard boundary already; an
# explicit flush is a no-op in Wave 2 (it becomes the checkpoint durable barrier
# in the checkpoint/restart wave).
sink_flush!(::ZarrSink) = nothing

function sink_close!(s::ZarrSink)
    s.handle === nothing && return nothing
    s.manifest = EarthSciIO.write_close!(s.writer, s.handle)
    return s.manifest
end

end # module
