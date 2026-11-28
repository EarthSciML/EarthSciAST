# The tree-walk build for discretized `.esm` models (`compiler = :native` and
# `:interpreter`).
#
# Compiles the canonical-form equations of a `Model` into a plain
# `f!(du, u, p, t)`: each equation is lowered once, at build time, to the `_Node`
# IR, which the run-time evaluators and the code-generation tiers execute.
# Bypasses ModelingToolkit entirely; it is meant for discretized PDEs whose
# scalar count exceeds MTK's tearing/codegen ceiling.
#
# Internal entry (callers use `esm_problem`, and the package's tests and
# adapters `EarthSciAST.Internal.build`):
#
#     _build_evaluator(model::Model; kwargs...)
#         → (f!, u0::Vector{Float64}, p::NamedTuple, tspan::Tuple{Float64,Float64},
#            var_map::StateLayout)
#
# The returned tuple plugs straight into `ODEProblem(f!, u0, tspan, p)`.
# `var_map` is the state-name → index lookup so callers can probe the
# solution at specific variables: an `AbstractDict{String,Int}` over the
# element names (`"u[2,3]"`), answered arithmetically from one block per array
# variable (tree_walk/state_layout.jl).
#
# The default `f!` both SOLVES and DIFFERENTIATES: it is zero-alloc at Float64 and
# eltype-generic, so ForwardDiff runs through it over the state or the parameters
# (a stiff solve gets an exact AD Jacobian for free).
#
# `_build_evaluator(model; form = :oop)` returns the COMPILED INTERMEDIATE
# REPRESENTATION in the same slot (tree_walk/oop.jl) rather than a second
# evaluator: the same node spines and access kernels `f!` is lowered from, as
# data, for a compiled backend to emit a program from. `direct_rhs`
# (ext/reactant_direct/) is the one in tree. It does not evaluate on host.
#
# Dict and EsmFile convenience entry points select a model by name (or
# the single model, if the file carries only one).
#
# ─────────────────────────────────────────────────────────────────────────────
# FILE LAYOUT. The evaluator is split along its numbered section seams into
# the files below (under src/tree_walk/), included here in the original
# definition order. Definitions used at include time (structs, consts) must
# stay before their include-time uses — in particular `_Node` (node.jl) and
# `_BuildMemo`/`_MaybeMemo` (compile.jl) precede `_ResolveCtx`
# (resolve_ctx.jl), which every resolve signature names. The build pipeline
# (tree_walk/build_*.jl) is included after the compile layer, so its
# signatures may name compile-layer types; only its records
# (build_records.jl) and the run-time types a kernel dispatches on
# (obs_buffers.jl) come earlier.
# ─────────────────────────────────────────────────────────────────────────────

include("tree_walk/errors.jl")           # §1   TreeWalkError + E_TREEWALK_* codes
include("tree_walk/op_ladder.jl")        #      the operator ladder generator (op registry shapes)
include("tree_walk/cadence_stamp.jl")    #      parameter stamps + the per-build forcing epoch
include("tree_walk/state_layout.jl")     #      the flat state layout (`StateLayout`)
include("tree_walk/node.jl")             # §3   the `_Node` IR and its payload types
include("tree_walk/dag.jl")              #      unique-node walks over a shared DAG
include("tree_walk/setup_select.jl")     # §2   which array observeds are setup arrays
include("tree_walk/setup_sweep.jl")      #      the compiled setup sweep of a build-once faq
include("tree_walk/setup_materialize.jl") #     materializing the setup arrays
include("tree_walk/setup_frontdoor.jl")  #      binning coordinates, overlap envelope factors
include("tree_walk/build_helpers.jl")    #      sentinels, claimed-slot set, small utilities
include("tree_walk/bounded_const_array.jl") #    const-array boundary policy
include("tree_walk/unlowered_gate.jl")   #      §9.6.3 c.6 pre-build rewrite-target walk
include("tree_walk/scan.jl")             #      prefix-scan detection + `_ScanFold`
include("tree_walk/build_ic_system.jl")   #      the initialization system (esm-spec §11.4.3)
include("tree_walk/build_records.jl")    #      the records a build hands back
include("tree_walk/hoist.jl")            #      nested reductions lifted to internal observeds
include("tree_walk/compile.jl")          # §3   expression → `_Node`
include("tree_walk/call.jl")             #      template references compiled as calls
include("tree_walk/resolve_ctx.jl")      #      the index-resolution context, `_PGatherArray`
include("tree_walk/prelude_cache.jl")    #      the scalar prelude cache and its stamps
include("tree_walk/rhs_seams.jl")        #      value type, parameter read, Float32 guard
include("tree_walk/scalar_cse.jl")       # §3b  scalar common-subexpression elimination
include("tree_walk/scalar_walk.jl")      # §4   the compiled scalar walker
include("tree_walk/geometry_compile.jl") # §2c  geometry body compiler (needs `_Node`)
include("tree_walk/access_kernel.jl")    # §4b  unified array-kernel IR (`_AccKernel`)
include("tree_walk/threading.jl")        #      thread verdicts, partition, chunk dispatch
include("tree_walk/scalar_ops.jl")       #      op ladder, subscript resolver, forcing args
include("tree_walk/knot_count.jl")       #      the comparison count over a whole lane
include("tree_walk/oop.jl")              # §4d  the out-of-place build product
include("tree_walk/acc_merge.jl")        # §4e  per-cell merge into access kernels
include("tree_walk/oop_merge.jl")        #      kernel-CLASS merge, for both forms
include("tree_walk/xcse.jl")             #      cross-kernel / kernel↔prelude CSE
include("tree_walk/obs_buffers.jl")      #      run-time observed slot space + discrete refill
include("tree_walk/codegen_kernel.jl")   # §4f  Julia-codegen tier for access kernels
include("tree_walk/scan_fused.jl")       #      a prefix scan's term and fold in one pass
include("tree_walk/array_contraction.jl") # §4f  …and for the whole-array contraction nest
include("tree_walk/scatter.jl")          #      one-pass scatter for an equality filter
include("tree_walk/recurrence_sweep.jl") #      the ordered sweep of a causal self-reference
include("tree_walk/recurrence_group.jl") #      a recurrence group as its stacked single recurrence
include("tree_walk/scalar_codegen.jl")   #      …and for the scalar equations and the prelude
include("tree_walk/rhs_assembly.jl")     #      the in-place right-hand side and its stages
include("tree_walk/const_tier.jl")       # §4g  cadence partition of the scalar prelude
include("tree_walk/stencil.jl")          # §4c  symbolic stencilizer (spines + recipes)
include("tree_walk/stencil_affine.jl")   #      affine box processor (the default build)
include("tree_walk/observed_program.jl") #      the compiled output-time observed route
include("tree_walk/field_ic.jl")         # §5   a field `ic` per cell
include("tree_walk/cellwise.jl")         #      cell-wise evaluation, compile-once cell evaluators
include("tree_walk/ranges.jl")           #      integer range expansion
include("tree_walk/memory.jl")           #      zero-filled buffers
include("tree_walk/const_int.jl")        #      the integer subscript evaluator
include("tree_walk/semiring.jl")         # §5c  semiring registry and reducers
include("tree_walk/join_gates.jl")       #      join clauses resolved to gates
include("tree_walk/join_key_columns.jl") #      the key columns a join compares
include("tree_walk/index_sets.jl")       # §5d  `ranges` naming an index set
include("tree_walk/aggregate_expand.jl") #      the unroll of an aggregate's contracted indices
include("tree_walk/gather_resolve.jl")   #      const, inline-const and state gathers; guards
include("tree_walk/shape_ops.jl")        #      shape ops and broadcasting as index maps
include("tree_walk/resolve_loops.jl")    #      reductions kept as run-time loops
include("tree_walk/resolve_producers.jl") #     `index(faq, …)` and `index(makearray, …)`
include("tree_walk/resolve.jl")          #      `_resolve_indices` and its dispatch
include("tree_walk/lhs_cells.jl")        #      array variables, LHS cells, model selection
include("tree_walk/setup_fill.jl")       # §5e  construction-time fills through the cascade
include("tree_walk/range_hooks.jl")      #      the seams of a range-restricted build
include("tree_walk/build_equation_prep.jl")   #      broadcast lowering, observed LHS, lifts, folds
include("tree_walk/build_refusals.jl")        #      refusals at the build entry
include("tree_walk/build_classify.jl")        # §2b  pre-lowering + variable classification
include("tree_walk/build_caller_data.jl")     #      caller data, keys, parameter scope
include("tree_walk/build_initial_state.jl")   #      `ic` equations and u0
include("tree_walk/build_discrete_cache.jl")  #      discrete-cadence caches
include("tree_walk/build_observed_fills.jl")  #      materialized array-observed fills
include("tree_walk/build_array_equation.jl")  #      derivative compile + array-equation cascade
include("tree_walk/build_pipeline.jl")        # §2c  the build phases, `_build_evaluator_impl`
include("tree_walk/build_options.jl")         #      `BuildOptions`: what one document build is asked for
include("tree_walk/build_front_doors.jl")     #      `_build_evaluator` entry points, `evaluate_expr`
include("tree_walk/ir_contract.jl")      #      what a back end may rely on in `_CompiledIR`
