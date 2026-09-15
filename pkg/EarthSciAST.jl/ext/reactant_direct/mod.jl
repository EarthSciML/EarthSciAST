# ========================================================================
# ext/reactant_direct/mod.jl — direct StableHLO emission from the compiled
# tree-walk IR. Included by ext/EarthSciASTReactantExt.jl.
# ========================================================================
#
# WHAT THIS IS. The COMPILED backend for the out-of-place RHS. It does not trace
# the emitter's broadcast Julia code: it walks the SAME compiled IR the `:oop`
# closure captured — the materialized-observed fill levels, the CSE prelude, the
# `rhs_list` scalar spines, the `_AccKernel`s with their `_OopAccPlan`s, the
# template sub-kernels, the CSR reduces and the prefix scan folds — and
# constructs `stablehlo.*` operations directly through
# `Reactant.MLIR.Dialects.stablehlo`, the way `Reactant.Ops` does internally. It
# runs INSIDE `Reactant.@compile`, so the compile pipeline, the PJRT client and
# the argument/result plumbing are Reactant's; what changes is that every op in
# the module comes from an IR node rather than from Julia's broadcast machinery.
#
# VALUE MODEL. Every emitted value is a rank-1 `tensor<Lxf64>`; a scalar is
# `L == 1`. There is NO extended flat state buffer `ue`: a materialized
# observed's fill result is recorded in a SLOT MAP (slot -> (producer value,
# position)), and a later read of those slots becomes slices of the producer
# values plus one concatenate — the reference-preserving form
# src/tree_walk/SSA_SPIKE.md reaches for from the other side. `du` is assembled
# the same way, unwritten slots becoming a zero-constant run.
#
# HARD ERRORS, NOT FALLBACKS. Anything this backend cannot lower raises
# `EarthSciAST.DirectEmitError` naming the node kind / descriptor kind / kernel
# shape and the rule it came from. See api.jl for why.
#
# FILES
#   values.jl   the emitted value, the context, constants, shape plumbing, slot
#               maps, the slices-plus-concatenate read form, forcing buffers
#   ops.jl      the elementwise ladder, the ⊕-folds, the host const-fold
#   interp.jl   closed functions (`:fn`): the six `interp.*` forms
#   emit.jl     the walk — spines, kernels, sub-kernels, reduces, scans, the RHS
#   batch.jl    the LANE-BATCHED scalar surface: the `:oop` build's congruent
#               per-cell entry groups emitted once over their lane axis
#   device.jl   WHERE it runs: the XLA client (cpu/gpu), the cell-axis sharding
#               of the flat state across several devices, and the device-input
#               builders, held BESIDE the callable rather than in it. Included
#               BEFORE api.jl: it declares the `DirectCallable` supertype and
#               the placement table api.jl registers into.
#   api.jl      `direct_rhs` / `direct_rhs_with_buffers` and the call methods

import EarthSciAST
const _E = EarthSciAST
const _MLIR = Reactant.MLIR
const _hlo = Reactant.MLIR.Dialects.stablehlo
const _chlo = Reactant.MLIR.Dialects.chlo

include("values.jl")
include("ops.jl")
include("interp.jl")
include("emit.jl")
include("batch.jl")
include("device.jl")
include("api.jl")
