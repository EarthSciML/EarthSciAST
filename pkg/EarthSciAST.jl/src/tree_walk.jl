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
# ─────────────────────────────────────────────────────────────────────────────

include("tree_walk/errors.jl")           # §1   TreeWalkError + E_TREEWALK_* codes
include("tree_walk/geometry_setup.jl")   # §2   build-time geometry materialization
include("tree_walk/build_helpers.jl")    #      sentinels, boundary policy, folds
include("tree_walk/scan.jl")             #      prefix-scan detection + `_ScanFold`
include("tree_walk/build.jl")            # §2b  build pipeline, `build_evaluator`
include("tree_walk/compile.jl")          # §3-4 `_Node` IR, scalar CSE, scalar walker
include("tree_walk/geometry_compile.jl") # §2c  geometry body compiler (needs `_Node`)
include("tree_walk/access_kernel.jl")    # §4b  unified array-kernel IR (`_AccKernel`)
include("tree_walk/oop.jl")              # §4d  out-of-place emitter over the same IR
include("tree_walk/acc_merge.jl")        # §4e  per-cell merge + `_make_rhs`
include("tree_walk/oop_merge.jl")        #      `:oop` kernel-CLASS merge
include("tree_walk/xcse.jl")             #      cross-kernel / kernel↔prelude fn-CSE
include("tree_walk/codegen_kernel.jl")   # §4f  Julia-codegen tier for access kernels
include("tree_walk/const_tier.jl")       # §4g  cadence partition of the scalar prelude
include("tree_walk/stencil.jl")          # §4c  symbolic stencilizer (spines + recipes)
include("tree_walk/stencil_affine.jl")   #      affine box processor (the default build)
include("tree_walk/helpers.jl")          # §5   misc + array-variable helpers
include("tree_walk/semiring.jl")         # §5c  semiring registry + join-gate resolution
include("tree_walk/resolve.jl")          # §5d  index resolution, `_PGatherArray`
