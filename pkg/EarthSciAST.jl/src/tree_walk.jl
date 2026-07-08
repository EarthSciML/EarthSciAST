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
# Dict and EsmFile convenience entry points select a model by name (or
# the single model, if the file carries only one).
#
# ─────────────────────────────────────────────────────────────────────────────
# FILE LAYOUT. The evaluator is split along its numbered section seams into
# the files below (under src/tree_walk/), included here in the original
# definition order. Definitions used at include time (structs, consts) must
# stay before their include-time uses — in particular `_Node`/`_BuildMemo`/
# `_MaybeMemo` (compile.jl) precede the `_resolve_indices` signatures
# (resolve.jl), and `_VecNode`/`_VecKernel` (vectorize.jl) precede the stencil
# compiler (stencil.jl). Note that build.jl is included BEFORE compile.jl —
# its function signatures therefore must not annotate compile/vectorize types
# (they are used at runtime only; see `_compile_arrayop_equation!`).
#
#   errors.jl          §1   TreeWalkError + E_TREEWALK_* codes
#   geometry_setup.jl  §2   build-time geometry kernels (clip / fused area /
#                           ranged clips / _geo_eval / binning coordinates)
#   build_helpers.jl        _EMPTY_* sentinels, const-array boundary policy,
#                           whole-array lift, WS4 elementwise fold
#   build.jl           §2b  BuildInspection, build-pipeline stages,
#                           _build_evaluator_impl, build_evaluator entry
#                           points, evaluate_expr
#   compile.jl         §3-4 _Node IR compilation, CSE (ess-r7h), the compiled
#                           scalar walker (zero-alloc hot path)
#   vectorize.jl       §4b  vectorized array kernels (ess-dhq): merge +
#                           in-place runtime eval + _make_rhs (zero-alloc)
#   stencil.jl         §4c  symbolic stencil compiler (ess-perf)
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
include("tree_walk/vectorize.jl")
include("tree_walk/stencil.jl")
include("tree_walk/helpers.jl")
include("tree_walk/semiring.jl")
include("tree_walk/resolve.jl")
