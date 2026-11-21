# ========================================================================
# ext/reactant_direct/mod.jl — direct StableHLO emission from the compiled
# tree-walk IR. Included by ext/EarthSciASTReactantExt.jl.
# ========================================================================
#
# The compiled backend for the out-of-place right-hand side. It walks the same
# compiled IR the `:oop` closure captured (materialized-observed fill levels, the
# CSE prelude, the `rhs_list` scalar spines, the `_AccKernel`s with their
# `_OopAccPlan`s, CSR reduces and prefix-scan folds) and
# builds `stablehlo.*` operations directly through
# `Reactant.MLIR.Dialects.stablehlo`, inside `Reactant.@compile`.
#
# VALUE MODEL. Every emitted value is a rank-1 `tensor<Lxf64>`; a scalar is
# `L == 1`. There is no extended flat state buffer: a materialized observed's
# fill result is recorded in a slot map (slot -> (producer value, position)), and
# a later read of those slots becomes slices of the producer values plus one
# concatenate. `du` is assembled the same way, unwritten slots becoming a
# zero-constant run.
#
# Anything this backend cannot lower raises `EarthSciAST.DirectEmitError` naming
# the node, descriptor or kernel shape; there is no fallback.
#
# FILES
#   options.jl  `DirectEmitOptions`, the tuning switches, read from ENV once
#   values.jl   the emitted value, the context, constants, shape plumbing, slot
#               maps, the slices-plus-concatenate read form, forcing buffers
#   ops.jl      the elementwise ladder, the ⊕-folds, the host const-fold
#   closed.jl   the standard-library shapes: a const-array read at a computed
#               subscript, and the comparison count
#   emit.jl     the walk — spines, kernels, reduces, scans, the RHS
#   batch.jl    the LANE-BATCHED scalar surface: the `:oop` build's congruent
#               per-cell entry groups emitted once over their lane axis
#   device.jl   the XLA client (cpu/gpu), cell-axis sharding of the flat state
#               across devices, and the device-input builders. Included before
#               api.jl: it declares the `DirectCallable` supertype and the
#               placement table api.jl registers into.
#   api.jl      `direct_rhs` / `direct_rhs_with_buffers` and the call methods
#   problem.jl  `esm_problem(…; compiler = :xla)`: the emitted program compiled
#               once per build behind the Problem's in-place `f!`. Included
#               last: it is the only file here that uses the Problem surface.

import EarthSciAST
# The entry points are declared in src/compiler_xla.jl; the methods are here.
import EarthSciAST: direct_rhs, direct_rhs_with_buffers, direct_state,
    direct_params, direct_time, direct_buffers, direct_client, direct_devices,
    direct_shard, direct_devicecount, direct_platform
const _E = EarthSciAST
const _MLIR = Reactant.MLIR
const _hlo = Reactant.MLIR.Dialects.stablehlo
const _chlo = Reactant.MLIR.Dialects.chlo

include("options.jl")
include("values.jl")
include("ops.jl")
include("closed.jl")
include("emit.jl")
include("batch.jl")
include("device.jl")
include("api.jl")
include("problem.jl")
