# Tree-walk evaluator for discretized `.esm` models (gt-e8yw).
#
# Compiles the canonical-form equations of a `Model` into a plain
# `f!(du, u, p, t)` by walking the expression AST at every RHS call.
# Bypasses ModelingToolkit entirely, so compile time is independent of
# the system size — the path is intended for discretized PDEs whose
# scalar count exceeds MTK's tearing/codegen ceiling.
#
# Public API:
#
#     build_evaluator(model::Model; kwargs...)
#         → (f!, u0::Vector{Float64}, p::NamedTuple, tspan::Tuple{Float64,Float64},
#            var_map::Dict{String,Int})
#
# The returned tuple plugs straight into `ODEProblem(f!, u0, tspan, p)`.
# `var_map` is the state-name → index lookup so callers can probe the
# solution at specific variables.
#
# The default `f!` both SOLVES and DIFFERENTIATES: it is zero-alloc at Float64 and
# eltype-generic, so ForwardDiff runs through it over the state or the parameters
# (a stiff solve gets an exact AD Jacobian for free).
#
# `build_evaluator(model; form = :oop)` returns an OUT-OF-PLACE `f(u, p, t) → du` in
# the same slot (tree_walk/oop.jl). It is NOT a faster or more differentiable `f!` —
# it is the one that can be TRACED: it captures no host buffers and contains no
# per-lane scalar loops, the two things XLA/Reactant and device backends cannot
# accept. Reach for it for tracing, not for derivatives.
#
# Dict and EsmFile convenience entry points select a model by name (or
# the single model, if the file carries only one).
#
# ─────────────────────────────────────────────────────────────────────────────
# FILE LAYOUT. The evaluator is split along its numbered section seams into
# the files below (under src/tree_walk/), included here in the original
# definition order. Definitions used at include time (structs, consts) must
# stay before their include-time uses — in particular `_Node`/`_BuildMemo`/
# `_MaybeMemo` (compile.jl) precede the `_resolve_indices` signatures
# (resolve.jl). Note that build.jl is included BEFORE compile.jl — its
# function signatures therefore must not annotate compile-layer types
# (they are used at runtime only; see `_compile_arrayop_equation!`).
#
#   errors.jl          §1   TreeWalkError + E_TREEWALK_* codes
#   geometry_setup.jl  §2   build-time geometry kernels (clip / fused area /
#                           ranged clips / binning coordinates); the geometry
#                           BODY COMPILER is §2c (geometry_compile.jl, below)
#   build_helpers.jl        _EMPTY_* sentinels, const-array boundary policy,
#                           whole-array lift, WS4 elementwise fold
#   build.jl           §2b  BuildInspection, build-pipeline stages,
#                           _build_evaluator_impl, build_evaluator entry
#                           points, evaluate_expr
#   compile.jl         §3-4 _Node IR compilation, CSE (ess-r7h), the compiled
#                           scalar walker (zero-alloc hot path), the RHS value
#                           type (_rhs_value_type) both walkers compute in
#   geometry_compile.jl §2c setup-time geometry BODY COMPILER: lowers geometry
#                           bodies once per materialization sweep into the
#                           _Node IR (compile-once, evaluate-per-cell —
#                           retires the former _geo_eval interpreter)
#   access_kernel.jl   §4b  the UNIFIED array-kernel IR (_AccKernel): access
#                           descriptors, the eltype-generic scalar runner, the
#                           per-cell/invariant CSE tiers, and the Float64
#                           lane tape (tiled, zero-alloc, SIMD op loops)
#   oop.jl             §4d  out-of-place emitter over the SAME IR: eltype-generic
#                           f(u,p,t) → du, the AD / device path (`form = :oop`)
#   acc_merge.jl       §4e  the per-cell fallback's whole-array host (grouping
#                           signature + indirect-outs merge) and _make_rhs,
#                           the in-place RHS closure generator
#   const_tier.jl      §4g  partitions the (final) scalar prelude by cadence:
#                           slots that depend only on `p` are refilled only when
#                           `p` moves, not once per stage of every step (4qf)
#   stencil.jl         §4c  symbolic stencilizer (sentinel spines + lane
#                           recipes — the affine box processor's front half)
#   helpers.jl         §5-5b misc + array-variable helpers (_cell_key /
#                           _parse_cell_key, field ICs, _eval_const_int)
#   semiring.jl        §5c  semiring registry + join-gate resolution
#   resolve.jl         §5d  index-set + build-time index resolution,
#                           _PGatherArray, cell discovery, model selection
# ─────────────────────────────────────────────────────────────────────────────

include("tree_walk/errors.jl")
include("tree_walk/geometry_setup.jl")
include("tree_walk/build_helpers.jl")
include("tree_walk/build.jl")
include("tree_walk/compile.jl")
include("tree_walk/geometry_compile.jl")   # §2c: needs _Node (compile.jl)
include("tree_walk/access_kernel.jl")
include("tree_walk/oop.jl")
include("tree_walk/acc_merge.jl")     # per-cell → indirect-outs _AccKernels + _make_rhs
include("tree_walk/xcse.jl")          # §4e: cross-kernel/kernel↔prelude fn-CSE (plan B4)
include("tree_walk/codegen_kernel.jl") # §4f: B1 Julia-codegen tier for access kernels (RGF)
include("tree_walk/const_tier.jl")
include("tree_walk/stencil.jl")
include("tree_walk/stencil_affine.jl")
include("tree_walk/helpers.jl")
include("tree_walk/semiring.jl")
include("tree_walk/resolve.jl")
