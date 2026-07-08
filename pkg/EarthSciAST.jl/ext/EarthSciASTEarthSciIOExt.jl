"""
    EarthSciASTEarthSciIOExt

Wires the EarthSciIO Julia `Provider` into ESS's data-provider seam
([`provider_refresh_times`](@ref) / [`provider_sample`](@ref)), loaded
automatically whenever `EarthSciIO` is in the session alongside
EarthSciAST. Before this extension existed the adapter shipped only as
a doc comment on the seam (`data_refresh.jl`), so every run script had to repeat
it; now `simulate(...; providers = Dict("Loader.var" => provider))` accepts an
EarthSciIO provider with no per-script glue.

DELIBERATELY THIN. ESS is agnostic to dimension order: the provider sample is
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

import EarthSciAST as ESS
using EarthSciAST: RefreshError
import EarthSciIO

# The cadence anchors, straight from the provider (empty ⇒ CONST, which makes the
# default `provider_is_const` — `isempty(provider_refresh_times(p))` — report true
# with no extra method).
ESS.provider_refresh_times(p::EarthSciIO.Provider) = EarthSciIO.refresh_times(p)

# One forcing field at cadence tick `t`, in the source's NATIVE layout (no
# reorder — see the module docstring). `providers` is keyed one entry per consumer
# variable, so a sample carries exactly one data variable; a multi-variable blob
# is a binding error the caller must split (ESS can't know which field a bare
# array means). Returns the bare `AbstractArray` that `_write_forcing!` /
# `_provider_const_field` expect for a single-variable sample.
function ESS.provider_sample(p::EarthSciIO.Provider, t::Real)
    nds = EarthSciIO.refresh(p, Float64(t))          # == materialize(p, t)
    vars = EarthSciIO.variable_names(nds)
    length(vars) == 1 || throw(RefreshError(
        "EarthSciIO provider yields $(length(vars)) variables $(vars); bind one " *
        "provider per consumer variable (providers[\"Loader.var\"] => provider) so " *
        "each sample is a single field, or slice the provider upstream"))
    return nds[vars[1]].data
end

end # module
