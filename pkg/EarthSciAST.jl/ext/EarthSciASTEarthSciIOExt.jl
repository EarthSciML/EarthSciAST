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
    derive_output_gridding, scatter_grid!, gather_flat!, OutputMeta, DimCoord,
    plan_dimension_coordinates
# Explicit imports so we can add the extension methods to these generics.
import EarthSciAST: provider_refresh_times, provider_sample, provider_supports_selection
import EarthSciAST: build_zarr_sink, sink_output_times, sink_open!, sink_write!,
    sink_flush!, sink_close!, sink_observed_names, zarr_restart_state
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
# Wave 2: state-only, host-gather, positional dim names, one store.
# Wave 3: REAL index-set dim names + CF dimension-coordinate emission (values +
# standard_name/units/axis) from the document's `coordinates` registry, plus
# per-variable CF attrs (units, …) — all carried in via the `OutputMeta` a
# `PreparedModel` derives. Observed fields, auxiliary/source coordinates,
# checkpoint profiles, and object stores are later waves; the protocol is unchanged.
# --------------------------------------------------------------------------- #

mutable struct ZarrSink
    base_url::String                 # file:// URL or path of the output store
    gridding::Vector{VarGridding}    # per-base-variable flat→gridded layout (RFC §7)
    coords::Vector{DimCoord}         # CF dimension coordinates (§8.3; may be empty)
    var_attrs::Dict{String,Dict{String,Any}}  # base var => CF variable attrs (units, …)
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
    build_zarr_sink(var_map::AbstractDict, base_url; output_times, meta=nothing, kwargs...) -> ZarrSink

Construct a [`ZarrSink`](@ref) streaming the flat state to the Zarr v3 store at
`base_url`. The gridded layout is derived from the model's `var_map`
([`derive_output_gridding`](@ref), RFC §7). Given a `PreparedModel` (or an
[`OutputMeta`](@ref) via the `meta` keyword), axes are named by their REAL
index-set names and the document's `coordinates` registry is emitted as CF
dimension coordinates (RFC §8); with a bare `var_map` and no `meta`, axes keep
positional names and no coordinates are written. Keyword `output_times` are the
solver-second anchors; `profile` (`:diagnostic`/`:checkpoint`) selects codec
params; `records_per_shard` sets how many time records pack into one shard object;
`time_dim` names the growable axis.
"""
function build_zarr_sink(var_map::AbstractDict, base_url::AbstractString;
                         output_times, profile::Symbol = :diagnostic,
                         records_per_shard::Integer = 8,
                         time_dim::AbstractString = "time",
                         meta::Union{Nothing,OutputMeta} = nothing,
                         variables::Union{Nothing,AbstractVector} = nothing)
    g = meta === nothing ? derive_output_gridding(var_map) :
        derive_output_gridding(var_map, meta)
    # Optional per-grid restriction (RFC §9): keep only the named base variables, so
    # one sink writes exactly one grid's variables to its own store.
    if variables !== nothing
        want = Set(String(v) for v in variables)
        available = String[x.base for x in g]
        g = VarGridding[x for x in g if x.base in want]
        isempty(g) && throw(OutputError(
            "build_zarr_sink: `variables` $(collect(want)) selected no variables from " *
            "$(available)"))
    end
    coords = meta === nothing ? DimCoord[] : plan_dimension_coordinates(g, meta)
    vattrs = meta === nothing ? Dict{String,Dict{String,Any}}() : meta.var_attrs
    return ZarrSink(String(base_url), g, coords, vattrs, collect(Float64, output_times),
                    profile, Int(records_per_shard), String(time_dim), nothing, nothing, nothing)
end

build_zarr_sink(prep, base_url::AbstractString; kwargs...) =
    build_zarr_sink(prep.var_map, base_url; meta = prep.output_meta, kwargs...)

sink_output_times(s::ZarrSink) = s.output_times
sink_observed_names(::ZarrSink) = String[]      # Wave 2/3: state only

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

    # Per-variable CF attrs (units, standard_name, description) from the doc.
    vars = Pair{String,EarthSciIO.OutputVar}[]
    for g in s.gridding
        odims = String[g.dimnames...]; push!(odims, s.time_dim)   # time last
        attrs = Dict{String,Any}(get(s.var_attrs, g.base, Dict{String,Any}()))
        push!(vars, g.base => EarthSciIO.OutputVar(odims, Float64; attrs = attrs))
    end

    # CF dimension coordinates (§8.3): name == dim, 1-D values + standard_name/units/axis.
    coords = Pair{String,Tuple{Vector,Dict{String,Any}}}[]
    for c in s.coords
        push!(coords, c.name => (c.values, c.attrs))
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
                                     coords = coords,
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

# The checkpoint durable barrier (RFC §10, §16.7): force any buffered records out
# as a durable partial shard + refresh the output manifest, so a restart reading the
# manifest sees everything written so far as committed. A no-op before open or with
# an empty buffer (already durable, e.g. records_per_shard = 1).
function sink_flush!(s::ZarrSink)
    s.handle === nothing && return nothing
    EarthSciIO.write_flush!(s.writer, s.handle)
    return nothing
end

function sink_close!(s::ZarrSink)
    s.handle === nothing && return nothing
    s.manifest = EarthSciIO.write_close!(s.writer, s.handle)
    return s.manifest
end

# --------------------------------------------------------------------------- #
# zarr_restart_state — the manifest-driven restart read (RFC §10, §16.7). The
# inverse direction of the sink: read the last committed checkpoint slab back into
# a flat `u0`. Uses the SAME `derive_output_gridding(var_map, meta)` the sink wrote
# with, so the flat↔gridded scatter/gather are exact inverses.
# --------------------------------------------------------------------------- #

function zarr_restart_state(prep, base_url::AbstractString; cache_dir = nothing)
    meta = prep.output_meta
    gridding = derive_output_gridding(prep.var_map, meta)
    base = EarthSciIO._output_base(String(base_url))

    man = EarthSciIO.read_output_manifest(joinpath(base, "output_manifest.json"))
    man === nothing && throw(OutputError(
        "no output manifest under $base; nothing to restart from (was the store " *
        "opened by a ZarrSink and at least one shard committed?)"))
    man.last_t === nothing && throw(OutputError(
        "output manifest at $base has no committed record (last_t is null); a shard " *
        "must commit — via a full shard, sink_flush!, or sink_close! — before restart"))
    nrec = man.n_records
    nrec >= 1 || throw(OutputError("output manifest reports 0 committed records"))

    cd = cache_dir === nothing ? joinpath(base, "_restart_cache") : String(cache_dir)
    cache = EarthSciIO.Cache(EarthSciIO.LocalStore(cd); offline = false)
    varnames = String[g.base for g in gridding]
    nds = EarthSciIO.read_store(EarthSciIO.ZarrReader(), cache, base_url;
                                variables = varnames)

    u0 = zeros(Float64, length(prep.var_map))
    for g in gridding
        v = nds.variables[g.base]
        tdim = findfirst(==("time"), v.dims)
        tdim === nothing && throw(OutputError(
            "restart: variable '$(g.base)' has no 'time' axis (dims $(v.dims))"))
        # last COMMITTED time index (1-based); the array may be longer only if a
        # crash left an uncommitted shape bump, so clamp to the manifest count.
        ti = min(nrec, size(v.data, tdim))
        slab = v.data[ntuple(d -> d == tdim ? ti : Colon(), ndims(v.data))...]
        # reorder the sliced spatial slab into the gridding's dim order if the reader
        # returned the axes in a different order (robust to dim reordering).
        spatial = String[d for d in v.dims if d != "time"]
        if spatial != g.dimnames
            perm = Int[findfirst(==(dn), spatial) for dn in g.dimnames]
            any(isnothing, perm) && throw(OutputError(
                "restart: variable '$(g.base)' on-disk dims $(spatial) do not match " *
                "the model gridding dims $(g.dimnames)"))
            slab = permutedims(slab, perm)
        end
        gather_flat!(u0, g, slab)
    end
    return (Float64(man.last_t), u0)
end

end # module
