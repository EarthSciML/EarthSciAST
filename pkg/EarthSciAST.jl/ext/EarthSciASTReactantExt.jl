"""
    EarthSciASTReactantExt

The Reactant/XLA backend for EarthSciAST, loaded automatically when `Reactant`
is in the session.

WHAT IT PROVIDES. `direct_rhs` / `direct_rhs_with_buffers`
(ext/reactant_direct/): a StableHLO program built DIRECTLY from the compiled
tree-walk intermediate representation that `build_evaluator(model; form = :oop)`
returns — every operation in the module comes from an IR node rather than from
Julia broadcast tracing. See ext/reactant_direct/mod.jl for the value model and
ext/reactant_direct/api.jl for the contract (hard errors, never a fallback).
Device choice and multi-device sharding live in ext/reactant_direct/device.jl and
are documented in docs/src/compiled-backend-devices.md.

It also specializes the `interp.*` knot-addressing seams
(src/tree_walk/interp_lanes.jl) on Reactant's traced index types, so that the
lane evaluators the emitter reaches through `Reactant.call_with_reactant` lower a
table read as one constant-time `stablehlo.gather` rather than an O(table) select
ladder. That is ext/reactant_interp.jl.

LIVE FORCING BUFFERS ARE PROGRAM INPUTS, NOT CAPTURES. A live forcing buffer
(`param_arrays`, and a `DiscreteMaterializer` cache by construction) is bound BY
REFERENCE into the IR's node payloads and forcing descriptors. A captured host
array is a compile-time CONSTANT: XLA would bake in whatever the buffer held at
`@compile`, the discrete-cadence refresh callback (src/data_refresh.jl) would
then write the buffer in place, and the compiled program would not see it —
silently stale forcing, no error, plausible numbers. So the buffers arrive
through the ARGUMENT LIST instead. An array passed as an argument is a real XLA
input, and `copyto!`-ing new values into that same `ConcreteRArray` between calls
IS seen by the already-compiled program, so the discrete-cadence model survives
compilation verbatim: one aliased buffer per forcing, refreshed in place at each
cadence boundary, no reallocation and no recompile.

    fo   = build_evaluator(model; form = :oop, param_arrays = forcing)[1]
    db   = direct_rhs_with_buffers(fo)
    dev  = map(ConcreteRArray, forcing_buffers(fo))
    xla  = @compile db(u_r, p_r, t_r, dev)
    # at each cadence boundary, after the host refresh:
    sync_forcing!(dev, forcing_buffers(fo))

The 3-argument form `direct_rhs(fo)` REFUSES a model that binds live forcing:
that configuration is exactly the silent-staleness one, so the emission stops
with a `DirectEmitError` rather than baking the buffers in. A model with no
`param_arrays` compiles through the 3-argument form.

UPSTREAM DEFECTS THIS EXTENSION WORKS AROUND are catalogued in
UPSTREAM_ISSUES.md, together with what each one unblocks here and what it does
NOT. Read it before adding a workaround, and before concluding that a cost
centre is upstream's fault — most of the compile cost seen so far has been
emitter shape in THIS repository.
"""
module EarthSciASTReactantExt

using Reactant: Reactant, TracedRArray, TracedRNumber, @allowscalar

# The `interp.*` knot-addressing seams this extension specializes; see
# reactant_interp.jl.
import EarthSciAST: _knot_count, _knot_pair, _knot_pair2, _bilinear_corners

include("reactant_interp.jl")

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
