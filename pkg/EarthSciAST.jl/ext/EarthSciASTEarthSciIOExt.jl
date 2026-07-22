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

using EarthSciAST: RefreshError
# Explicit imports so we can add the extension methods to these generics.
import EarthSciAST: provider_refresh_times, provider_sample, provider_supports_selection
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

end # module
