"""
    EarthSciASTReactantExt

The Reactant/XLA backend for EarthSciAST, loaded automatically when `Reactant`
is in the session.

It provides `direct_rhs` / `direct_rhs_with_buffers` (ext/reactant_direct/): a
StableHLO program built directly from the compiled tree-walk intermediate
representation that `EarthSciAST.Internal.build(model; form = :oop)` returns, every
operation coming from an IR node. Anything the emitter cannot lower is a hard
error, never a fallback (ext/reactant_direct/api.jl). Device choice and sharding
are in ext/reactant_direct/device.jl and docs/src/compiled-backend-devices.md.
ext/reactant_knot_count.jl specializes `_knot_count` (src/tree_walk/knot_count.jl)
on Reactant's traced query types.

Live forcing buffers (`param_arrays`, and `DiscreteMaterializer` caches) are
program inputs, not captures: a captured host array would be a compile-time
constant and an in-place refresh would never reach the compiled program. They
are passed through the argument list, and `copyto!` into the same
`ConcreteRArray` between calls is seen by the compiled program:

    fo   = EarthSciAST.Internal.build(model; form = :oop, param_arrays = forcing)[1]
    db   = direct_rhs_with_buffers(fo)
    dev  = map(ConcreteRArray, forcing_buffers(fo))
    xla  = @compile db(u_r, p_r, t_r, dev)
    # at each cadence boundary, after the host refresh:
    sync_forcing!(dev, forcing_buffers(fo))

The 3-argument form `direct_rhs(fo)` refuses a model that binds live forcing with
a `DirectEmitError`.

Upstream defects this extension works around are listed in UPSTREAM_ISSUES.md.
"""
module EarthSciASTReactantExt

using Reactant: Reactant, TracedRArray, TracedRNumber, @allowscalar

# The comparison count this extension specializes; see reactant_knot_count.jl.
import EarthSciAST: _knot_count

include("reactant_knot_count.jl")

# ---- the COMPILED backend: StableHLO built directly from the compiled IR ----
#
# Public entry points `direct_rhs` / `direct_rhs_with_buffers`; see
# reactant_direct/mod.jl for what it is and reactant_direct/api.jl for the
# contract (hard errors, no fallback, numerical rather than bitwise agreement).
include("reactant_direct/mod.jl")

# The compiled backend asks Reactant not to rewrite one host-side helper; the
# request has to be re-made at load time as well as at precompile time (see
# reactant_direct/device.jl).
__init__() = _de_skip_rewrite!()

end # module
