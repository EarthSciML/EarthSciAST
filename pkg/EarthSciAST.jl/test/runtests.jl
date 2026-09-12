using Test
using EarthSciAST
using JSON3

include("testutils.jl")  # shared prelude: repo root, AST builders, _normj, _require_fixture

# ---- Test sharding (ESM_TEST_SHARDS / ESM_TEST_SHARD) ----
#
# CI runs this suite as two parallel jobs, each taking half the files, because
# the julia matrix was the whole workflow's long pole in every run measured and
# this list is ~45 minutes of it. Locally nothing changes: the defaults below
# are one shard, which runs everything.
#
# The split is by POSITION in the list, round-robin — unit n belongs to shard
# `mod1(n, ESM_TEST_SHARDS)`. Two properties matter and both come from that
# rule rather than from a hand-kept list that could drift out of step with the
# includes:
#
#   * EVERY shard walks the WHOLE list and registers every unit in
#     `SHARD_UNITS`; it only skips the bodies it does not own. So the registry
#     is identical in every shard, and a new `shard_include` line is picked up
#     by the assignment automatically.
#   * The assignment is total and single-valued, so the shards partition the
#     list exactly: nothing is dropped and nothing runs twice. That is the
#     entire rigor argument for sharding, so it is not left as a claim —
#     shard_partition_test.jl at the bottom of this file asserts it
#     mechanically, in every shard, on every run.
#
# Balance is good enough at two shards: on the measured 1.12 timings the split
# is 24.4 min / 20.9 min against an ideal 22.6 min.
const TEST_SHARDS = parse(Int, get(ENV, "ESM_TEST_SHARDS", "1"))
const TEST_SHARD = parse(Int, get(ENV, "ESM_TEST_SHARD", "1"))
TEST_SHARDS >= 1 || error("ESM_TEST_SHARDS must be >= 1, got $TEST_SHARDS")
1 <= TEST_SHARD <= TEST_SHARDS ||
    error("ESM_TEST_SHARD must be in 1:$TEST_SHARDS, got $TEST_SHARD")

"Every shardable unit, in list order. Registered by every shard alike."
const SHARD_UNITS = String[]

"The units THIS shard actually ran, in order."
const SHARD_EXECUTED = String[]

"Which shard owns the `n`-th unit. Total and single-valued by construction."
shard_owner(n::Integer, nshards::Integer=TEST_SHARDS) = mod1(Int(n), Int(nshards))

"Register `name` as a shardable unit; return whether this shard owns it."
function shard_claim(name::AbstractString)
    push!(SHARD_UNITS, String(name))
    owned = shard_owner(length(SHARD_UNITS)) == TEST_SHARD
    owned && push!(SHARD_EXECUTED, String(name))
    return owned
end

"Register `path` as a unit, and include it only in the shard that owns it."
function shard_include(path::AbstractString)
    shard_claim(path) && include(joinpath(@__DIR__, path))
    return nothing
end

# `verbose = true` prints the per-testset table — name, counts, and TIME — for
# every testset one level down, on every run. Without it a fully passing
# `DefaultTestSet` collapses to a single summary line and the only way to learn
# where the ~30-45 minutes go is to find a run that happened to FAIL, because a
# failure is what makes Julia print the tree. That is how the timings behind
# the sharding below had to be obtained. One word, no runtime cost, and the
# suite reports its own cost from then on.
@testset verbose = true "EarthSciAST.jl Tests" begin

    # ---- Public API surface (api-surface.json at the repo root; API_SPEC.md) ----
    # First, deliberately: if the export block and the manifest have diverged,
    # that is the failure you want to read before 200 other tests scroll past.
    shard_include("api_surface_test.jl")

    # ---- Exception hierarchy + diagnostic-code registry (src/errors.jl,
    #      src/error_codes.jl) ----
    # Also early: these guard the two package-wide invariants a new file can
    # break without any local test noticing — an exception outside the
    # `EarthSciASTError` root, or a diagnostic code spelled as an inline literal.
    shard_include("error_hierarchy_test.jl")

    # ---- Core types, parse, validate, display (src/types.jl, parse.jl,
    #      validate.jl, display.jl, graph.jl) ----
    shard_include("types_test.jl")
    shard_include("solver_block_test.jl")
    shard_include("classification_test.jl")
    shard_include("parse_test.jl")
    # Version-marker migration (src/migration.jl, esm-libraries-spec §8.3) —
    # the Julia mirror of pkg/earthsci-ast-ts/src/migration.test.ts, pinned
    # against tests/version_compatibility/compatibility_matrix.json.
    shard_include("migration_test.jl")
    # The two public version constants (SCHEMA_VERSION / LIBRARY_VERSION) and
    # the schema-$id pin that keeps the first from hand-drifting.
    shard_include("version_constants_test.jl")
    shard_include("validate_test.jl")
    shard_include("structural_validation_test.jl")
    # Causal self-reference well-foundedness (esm-spec §4.3.1.1). A VALIDATION
    # category (CONFORMANCE_SPEC §5.19.5), so it sits with the other structural
    # checks rather than with the tree-walk tests.
    shard_include("recurrence_validation_test.jl")
    # Observed dependency cycles (esm-spec §4.9.6, issue #181). Sits beside the
    # recurrence pass because the two share the CANDIDACY gate that decides
    # which of them owns a self-edge (CONFORMANCE_SPEC §5.19.5).
    shard_include("observed_cycle_validation_test.jl")
    shard_include("expression_test.jl")
    shard_include("reactions_test.jl")
    shard_include("reaction_species_order_test.jl")  # species ORDER = declaration order (API_SPEC §5.10)
    shard_include("display_test.jl")
    shard_include("display_conformance_test.jl")
    shard_include("expression_parse_conformance_test.jl")  # infix-text parser ≡ TS oracle
    shard_include("units_test.jl")
    shard_include("graph_test.jl")
    shard_include("graph_conformance_test.jl")  # component/expression graphs ≡ TS oracle

    # ---- Serialization round-trips (src/serialize.jl + conformance adapter) ----
    shard_include("round_trip_regression_test.jl")
    # `save(load(F))` against **F itself** over the corpus. A different question
    # from the conformance test below, which compares emit pass 2 against pass
    # 3: a field lost on the FIRST load is invisible to a fixed-point check,
    # because passes 2 and 3 agree perfectly about not having it.
    shard_include("corpus_fidelity_test.jl")
    shard_include("conformance_round_trip_test.jl")
    shard_include("conformance_pushdown_test.jl")

    # ---- MTK / Catalyst integration (ext/EarthSciASTMTKExt.jl,
    #      ext/EarthSciASTCatalystExt.jl) ----
    shard_include("real_mtk_integration_test.jl")
    shard_include("mtk_metadata_test.jl")
    shard_include("simulate_e2e_test.jl")
    shard_include("tests_blocks_execution_test.jl")
    shard_include("run_esm_tests_test.jl")
    shard_include("units_fixture_consumption_test.jl")
    shard_include("array_ops_test.jl")
    shard_include("catalyst_extension_test.jl")

    # ---- References, codegen, flatten, editing (reference helpers in
    #      src/types.jl; codegen.jl; flatten.jl and its split passes
    #      (flatten_errors.jl, namespacing.jl, coupling_apply.jl,
    #      pointwise_lift.jl, array_shape_inference.jl, shape_promotion.jl);
    #      edit.jl) ----
    shard_include("reference_resolution_test.jl")
    shard_include("codegen_test.jl")
    shard_include("flatten_test.jl")
    shard_include("flatten_conformance_test.jl")  # FlattenedSystem field set ≡ Python oracle
    # operator_compose merge intent: the §4.7.1 step 5 diagnostic, `require_match`,
    # and step 3's owner-based bare-name rename (issue #195).
    shard_include("operator_compose_merge_conformance_test.jl")
    # How far the merged-away rename REACHES: past the equation ASTs, onto the
    # by-name endpoints of every coupling entry that has not run yet and onto a
    # runner's override keys (issue #230).
    shard_include("merged_rename_reach_conformance_test.jl")
    shard_include("pointwise_lift_axis_names_test.jl")  # §10.5 lift axes by NAME, not by extent
    shard_include("coupling_imports_test.jl")
    shard_include("flattened_to_esm_test.jl")
    shard_include("shape_promotion_test.jl")
    shard_include("shape_promotion_consumer_refs_test.jl")  # promoted-var consumers gathered in-loop
    shard_include("subsystem_ref_test.jl")
    shard_include("mount_index_set_rename_test.jl")  # §4.7 mount-edge index_set_rename
    shard_include("toplevel_mount_edge_pipeline_test.jl")  # §4.7 edge pipeline, top-level {ref}
    shard_include("reaction_system_ref_test.jl")
    shard_include("editing_test.jl")
    shard_include("data_loader_fixtures_test.jl")
    shard_include("arrayed_vars_test.jl")
    shard_include("canonicalize_test.jl")
    shard_include("relational_test.jl")

    # ---- End-to-end simulation runs + MTK export ----
    shard_include("simulate_run_test.jl")
    shard_include("esm_problem_test.jl")
    shard_include("loaded_ic_bc_simulation_test.jl")
    shard_include("subsystem_loader_conformance_test.jl")
    shard_include("build_once_spatial_field_conformance_test.jl")
    shard_include("wildfire_simulation_test.jl")
    shard_include("mtk_export_test.jl")

    # ---- Tree-walk evaluator (src/tree_walk.jl) + discrete-cadence data refresh ----
    shard_include("tree_walk_test.jl")
    shard_include("dag_walk_memo_test.jl")               # ESS-1p5 exponential-path DAG walk regression
    shard_include("intern_oracle_test.jl")               # A1 hash-consing ≡ ESS_INTERN_DISABLE=1 (differential)
    shard_include("xeq_variant_oracle_test.jl")          # A3 cross-eq variant memo ≡ ESS_XEQ_VARIANT_DISABLE=1 (differential)
    shard_include("expand_memo_oracle_test.jl")          # A4 template-expansion memo ≡ ESS_EXPAND_MEMO_DISABLE=1 (differential)
    shard_include("tree_walk_faq_test.jl")
    shard_include("broadcast_alignment_test.jl")           # §4.3.4 broadcast lowering + name-based operand alignment
    shard_include("tree_walk_inline_const_index_test.jl")  # inline `const` array as index() target (fix/index-inline-const-array)
    shard_include("tree_walk_elementwise_obs_gather_test.jl")  # #175 elementwise array observed reached only via an aggregate gather
    shard_include("tree_walk_indexed_observed_lhs_test.jl")    # #232 array observed defined by the INDEXED LHS spelling (§6.3.1)
    shard_include("tree_walk_vectorized_test.jl")
    shard_include("access_kernel_foundation_test.jl")     # ess-affine IR foundation
    shard_include("stencil_affine_lowering_test.jl")       # ess-affine _lower_to_access
    shard_include("stencil_affine_diff_test.jl")           # ess-affine ≡ per-cell (differential)
    shard_include("stencil_affine_ad_test.jl")             # ess-affine AD Jacobian + out-of-place
    shard_include("stencil_affine_fn_test.jl")             # ess-affine interp :fn ≡ per-cell
    shard_include("stencil_affine_pgather_test.jl")        # ess-affine live-forcing ≡ per-cell
    shard_include("stencil_affine_pgather_tbl_test.jl")    # A2 non-affine forcing table ≡ per-cell (ESS_OBSREF_DISABLE oracle)
    shard_include("stencil_affine_contract_test.jl")       # ess-affine const-bound contraction ≡ per-cell
    shard_include("stencil_affine_const_fold_test.jl")     # ess-affine LANE_CONST fold is index-derived, not value-sampled
    shard_include("stencil_subtree_tbl_test.jl")           # subterm-granular fallback: const-evaluable subtree → per-box table (ESS_SUBTREE_TBL_DISABLE oracle)
    shard_include("scan_prefix_test.jl")                   # ess-scan O(N) prefix reduction ≡ per-cell
    shard_include("stencil_affine_cse_test.jl")            # ess-affine per-cell CSE ≡ per-cell
    shard_include("stencil_affine_invariant_test.jl")      # ess-affine invariant hoist ≡ per-cell
    # Cross-shape state gather (a state array read from a loop of a DIFFERENT
    # shape): the cut signature and the box lowering must both stay O(1) in the
    # grid. Sits next to grid_invariance_test.jl because it pins the same
    # property on the tier that was violating it.
    shard_include("stencil_affine_cross_shape_test.jl")
    shard_include("grid_invariance_test.jl")               # compiled IR size is O(1) in the grid
    shard_include("fn_content_cse_test.jl")                # fn specs keyed by CONTENT in per-kernel CSE
    shard_include("array_obs_materialize_test.jl")         # factored array observeds ≡ ESS_ARRAY_OBS_INLINE=1
    shard_include("codegen_kernel_test.jl")                # B1 codegen tier ≡ pre-codegen (differential)
    shard_include("codegen_lanespec_test.jl")              # B1 tier accepts per-lane interp specs (class merge)
    shard_include("dual_fast_path_test.jl")                # ess-dualfp Dual overflow tier ≡ interpreter (ESS_DUAL_CODEGEN_DISABLE oracle)
    shard_include("f64_overflow_codegen_test.jl")          # ess-f64ofl overflow RGF serves budget-declined Float64 kernels (ESS_F64_OVERFLOW_CODEGEN oracle)
    shard_include("cg_foreign_scratch_test.jl")            # ess-cgfsc codegen emits xcse shared-prelude reads (ESS_CG_FOREIGN_SCRATCH_DISABLE oracle)
    shard_include("codegen_threaded_test.jl")              # codegen threaded cell axis: chunk instances ≡ serial, disjointness, threaded subprocess (ESS_CG_THREADS_DISABLE oracle)
    shard_include("codegen_body_split_test.jl")            # ess-iip-body-split oversized kernel body split across @noinline helpers ≡ un-split (ESS_CODEGEN_BODY_SPLIT_DISABLE oracle)
    shard_include("codegen_subcall_fn_test.jl")            # ess-cg-subcall-fn template sub-kernels emitted ONCE as @noinline fns ≡ per-site inline (ESS_CG_SUBCALL_FN_DISABLE oracle)
    shard_include("stencil_indexed_contraction_test.jl")   # reduced-rank + contracted makearray region values fire affine ≡ per-cell (ESS_STENCIL_DISABLE oracle)
    shard_include("lane_table_intern_test.jl")             # content-equal lane tables `===` at build (ESS_LANE_INTERN_DISABLE oracle)
    shard_include("direct_class_emission_test.jl")         # per-cell scalarizer emits class kernels directly (ESS_DIRECT_CLASS_EMIT_DISABLE oracle)
    shard_include("cross_eq_class_emission_test.jl")       # cross-equation + affine-box classes emitted directly; repair pass zero-merge (ESS_CROSS_EQ_CLASS_EMIT_DISABLE oracle)
    shard_include("tree_walk_oop_test.jl")
    shard_include("oop_merge_test.jl")                     # :oop kernel-CLASS merge ≡ unmerged
    shard_include("tree_walk_oop_ssa_test.jl")             # ess-oop-ssa: producer-value references ≡ flat-buffer gathers (ESS_OOP_SSA)
    shard_include("tree_walk_iip_generic_test.jl")
    shard_include("parameter_gradient_test.jl")            # ∂(RHS)/∂p, both emitters (traced arm opt-in)
    shard_include("parameter_vector_abi_test.jl")          # `p::AbstractVector`/ComponentVector ≡ NamedTuple, bit for bit
    shard_include("parameter_classes_test.jl")             # numeric/structural/const-folded/forcing partition + the narrowed solve-time refusal
    # XLA tracing of the out-of-place RHS (ext/EarthSciASTReactantExt.jl). OPT-IN:
    # Reactant bundles an XLA runtime; it is in the test target so `Pkg.test()`
    # resolves it, but it is only LOADED when ESM_TEST_REACTANT=1 — the default
    # suite must keep running (and passing) without it. See the header of
    # test/reactant_oop_test.jl.
    if get(ENV, "ESM_TEST_REACTANT", "0") == "1"
        shard_include("reactant_oop_test.jl")
        shard_include("reactant_lane_dedup_test.jl")       # merged lane tables ≢ grid size
        shard_include("reactant_locate_test.jl")           # count-locate ≢ a reduction, and bit-exact
        shard_include("reactant_scan_test.jl")             # traced prefix scan ≢ grid size
        shard_include("reactant_oop_intern_test.jl")       # one emitted read per (SSA value, window)
        shard_include("reactant_oop_ssa_test.jl")          # ess-oop-ssa: skipped scatters/redirects visible in the raw module
        shard_include("reactant_oop_gvn_test.jl")          # one emitted OP per (opcode, operand values)
    else
        @info "skipping reactant_oop_test.jl (set ESM_TEST_REACTANT=1, with Reactant " *
              "in the environment, to run the XLA tracing tests)"
    end
    shard_include("tree_walk_allocation_test.jl")
    shard_include("tree_walk_param_gather_test.jl")
    shard_include("data_refresh_test.jl")
    shard_include("data_refresh_e2e_test.jl")
    shard_include("refresh_conformance_test.jl")
    # Streaming output sinks — the OUTPUT mirror of the data-refresh input seam
    # (streaming-output-sinks RFC §16, Wave 1). Loads DiffEqCallbacks + SciMLBase
    # (the test target), which activates the EarthSciASTDataOutputExt extension.
    shard_include("data_output_test.jl")
    # Phase 1b projection pushdown across the EarthSciIO provider seam. Loads
    # EarthSciIO (+ Blosc/JSON/SHA) from the test target (Project.toml
    # [targets].test), which activates the EarthSciASTEarthSciIOExt extension.
    shard_include("provider_selection_test.jl")
    # esm-spec §8.5 `unit_conversion` at the unit level (parse + apply).
    shard_include("unit_conversion_test.jl")
    # The loader-ingest surface of esm-spec §8.9 (reader_options / codes /
    # record_filter / extent / select), over local FF10-zip + Zarr-v2 fixtures.
    # The Rust mirror is pkg/earthsci-ast-rs/tests/loader_ingest_and_select.rs.
    shard_include("loader_ingest_and_select_test.jl")
    # esm-spec §8.2.1: WHERE a data source points -- the shared
    # cross-binding pin in tests/conformance/data_source_url/manifest.json.
    shard_include("data_source_url_conformance_test.jl")
    # esm-spec §8.5 `unit_conversion` on the ESIO provider path — the
    # manifest-driven cross-binding conformance adapter.
    shard_include("loader_unit_conversion_conformance_test.jl")
    shard_include("unit_registry_conformance_test.jl")
    # Streaming output sinks (Wave 2): end-to-end ZarrSink write → ZarrReader
    # read-back round-trip through the EarthSciIO write boundary (RFC §16).
    shard_include("zarr_sink_e2e_test.jl")
    # Streaming output sinks (Wave 3): the `coordinates` registry → CF
    # dimension-coordinate emission (real dim names + values + standard_name/units/axis).
    shard_include("streaming_coords_test.jl")
    # Streaming output sinks (Wave 3): predicate-driven checkpoint (DiscreteCallback
    # + SLURM/spot/any_of builtins) + manifest-driven `zarr_restart_state`.
    shard_include("streaming_checkpoint_test.jl")
    # Streaming output sinks (Wave 3): multi-grid — partition variables by
    # spatial-dim signature (`group_gridding_by_grid`) → one sink per grid/store.
    shard_include("streaming_multigrid_test.jl")
    # Streaming output sinks (regression): `sink_flush!` interleaved with ordinary
    # records must not move, drop, or duplicate a record — no fill-valued phantom
    # slots at shard tails, no records written past the declared `shape[time]`.
    shard_include("streaming_flush_gap_test.jl")
    # Streaming output sinks: the CROSS-LANGUAGE derivation gate
    # (`tests/conformance/output_derivation/`, RFC §16.12). Julia and Rust each
    # derive the same plan from the same .esm fixtures + flat slot names and
    # assert the same committed golden, so golden agreement IS cross-language
    # agreement. Needs no solver and no EarthSciIO — it is pure derivation.
    shard_include("output_derivation_conformance_test.jl")
    shard_include("discrete_materialize_test.jl")
    shard_include("discrete_materialize_conformance_test.jl")
    shard_include("tree_walk_cse_test.jl")
    shard_include("tree_walk_observed_slots_test.jl")
    shard_include("contraction_loop_test.jl")             # runtime contraction loop (ess-runtime-contraction)
    shard_include("contraction_tier_order_test.jl")       # loop-vs-affine tier ORDER (ess-runtime-contraction × ess-affine)
    shard_include("oop_scalar_batch_test.jl")             # :oop lane-batched scalar entries (ess-oop-batch)
    shard_include("tree_walk_tcadence_test.jl")           # B3 time-cadence tier (t-memoized slots)
    shard_include("tree_walk_xcse_test.jl")
    shard_include("tree_walk_const_array_boundary_test.jl")
    shard_include("tree_walk_semiring_test.jl")
    shard_include("tree_walk_join_test.jl")
    shard_include("tree_walk_binning_alias_test.jl")
    shard_include("op_registry_test.jl")
    shard_include("tree_walk_op_table_test.jl")
    shard_include("op_capability_audit_test.jl")          # cross-tier op/fn-payload capability drift
    shard_include("tree_walk_audit_fixes_test.jl")

    # ---- Analysis passes (src/reference_graph.jl, src/cadence.jl,
    #      value invention) ----
    shard_include("reference_graph_test.jl")
    shard_include("cadence_test.jl")
    shard_include("value_invention_frontdoor_test.jl")

    # ---- Cross-binding conformance harness adapters (tests/conformance/*) ----
    shard_include("faq_conformance_test.jl")
    shard_include("deprecated_op_alias_test.jl")
    shard_include("expression_ic_conformance_test.jl")
    shard_include("inverse_trig_conformance_test.jl")
    shard_include("geometry_conformance_test.jl")
    shard_include("geometry_polygon_intersection_area_test.jl")
    shard_include("geometry_assembly_conformance_test.jl")
    shard_include("geometry_overlap_join_conformance_test.jl")
    shard_include("geometry_ranged_clip_test.jl")
    shard_include("setup_map_compile_once_test.jl")  # promoted-physics MAP: compile-once == per-cell, bitwise
    shard_include("geom_sweep_specialize_test.jl")   # geometry sweep: rank-specialized == rank-abstract, bitwise
    shard_include("geom_overlap_drive_test.jl")     # setup overlap broad phase: candidate-DRIVEN, and what it changes
    shard_include("broad_phase_conformance_test.jl")   # projection-pushdown Phase 3a
    shard_include("overlap_gate_conformance_test.jl")   # projection-pushdown Phase 2a
    shard_include("join_namespacing_test.jl")           # §5.5.6 join names under flattening
    shard_include("join_on_equality_gate_test.jl")      # §5.5.8 value-equality gate: data columns + DRIVING
    shard_include("join_on_self_join_test.jl")          # §5.5.8 a relation joined to ITSELF: two ranges, one index set
    shard_include("vi_overlap_scaling_test.jl")         # projection-pushdown Wall #1 (candidate-driven)
    shard_include("pushdown_edge_test.jl")              # projection-pushdown Phase 2b (L1 milestone)
    shard_include("auto_pushdown_rewrite_test.jl")      # projection-pushdown Phase 4 (auto desugar)
    shard_include("pushdown_template_ref_test.jl")      # the desugar THROUGH surviving template refs (§9.6.4 Option B)
    shard_include("phase5_clean_auto_test.jl")          # projection-pushdown Phase 5 (LCC@build + fully-automatic)
    shard_include("prepare_pushdown_record_gate_test.jl") # Phase 1 consolidation (public prepare + record-derived gating)
    shard_include("prepare_pushdown_single_member_test.jl") # n=1 support-set pin (cross-language scalarisation footgun)
    shard_include("pushdown_cell_geometry_test.jl")     # rank-preserving cell-axis gathers (polygon allocation)
    shard_include("observed_materialization_test.jl")   # build-time producer materialization (line allocation)
    shard_include("gated_sibling_loaders_test.jl")      # hook 2: sibling loaders sharing a variable name
    shard_include("build_inspection_test.jl")
    shard_include("observed_field_static_test.jl")  # §5.8 name resolution on a state-free document
    shard_include("inline_tests_test.jl")
    shard_include("pde_inline_scalar_slot_collision_test.jl")
    shard_include("pde_inline_dead_observed_test.jl")  # #176: an observed no live equation consumes
    shard_include("mounted_component_tests_test.jl")   # #198: a mount does not carry the leaf's tests
    shard_include("conformance_pde_inline_observed_rank2_test.jl")
    shard_include("conformance_pde_inline_dead_observed_test.jl")
    shard_include("conformance_elementwise_observed_gather_test.jl")
    shard_include("conformance_pde_inline_observed_param_rank2_test.jl")
    shard_include("conformance_pde_inline_observed_state_dependent_test.jl")  # §6.6.5 state-dependent array observed
    shard_include("conformance_pde_inline_observed_indexed_lhs_test.jl")      # §6.3.1 INDEXED-LHS array observed (#232)
    shard_include("conformance_pde_inline_ic_param_override_test.jl")
    shard_include("conformance_pde_inline_array_overrides_test.jl")
    shard_include("conformance_assertion_nonfinite_test.jl")  # §6.6.3 non-finite actuals
    shard_include("assertion_tolerance_symmetry_test.jl")     # §6.6.3 symmetric relative bound
    shard_include("conformance_assertion_tolerance_test.jl")  # §6.6.3 pass predicate (data-only)
    shard_include("conformance_tolerance_resolution_test.jl")  # §6.6.4 per-field tolerance merge
    shard_include("conformance_scalar_ic_test.jl")
    shard_include("conformance_shaped_parameter_broadcast_test.jl")  # §6.3 scalar-on-a-shaped-parameter broadcast
    shard_include("conformance_override_key_diagnostics_test.jl")
    shard_include("conformance_pde_inline_reference_dimension_names_test.jl")  # §6.6.5 reference dimension names
    shard_include("rhs_time_derivative_resolution_test.jl")   # §4.2 right-hand-side D: Julia resolves; its exclusion
    shard_include("closed_functions_test.jl")
    shard_include("closed_functions_autodiff_test.jl")
    shard_include("datetime_arithmetic_test.jl")
    shard_include("datetime_typed_core_test.jl")     # registry-declared typed cores (ess-dtcore)
    shard_include("closed_functions_mtk_test.jl")
    shard_include("function_tables_test.jl")
    shard_include("function_tables_lowering_test.jl")
    # …and the same lowering on the path that EVALUATES a document (#188):
    # the harness above does the lowering itself, so it cannot see whether the
    # build front doors do.
    shard_include("function_tables_lowering_path_test.jl")

    # ---- Expression templates & scoped imports
    #      (src/lower_expression_templates.jl, template_imports.jl) ----
    shard_include("expression_templates_test.jl")
    shard_include("template_imports_test.jl")
    shard_include("scope_injection_test.jl")
    shard_include("out_of_line_templates_test.jl")
    shard_include("compile_once_templates_test.jl")
    shard_include("expanded_model_seam_test.jl")

    # ---- Shared fixture sweeps (tests/valid, tests/invalid, tests/display) ----
    # Smoke coverage across the shared fixture tree. Deeper checks live in the
    # dedicated files: manifest-driven round-trip idempotence in
    # conformance_round_trip_test.jl, expected-error assertions for specific
    # invalid fixtures in validate_test.jl / structural_validation_test.jl,
    # and rendering assertions in display_test.jl. (The former inline
    # "Round-trip Tests" subset was deleted as redundant with
    # conformance_round_trip_test.jl, which round-trips a superset of those
    # fixtures with a stronger save→load→save idempotence check.)
    # Not a file, so it takes its shard slot explicitly — otherwise it would
    # run in every shard and the partition below would be a lie.
    if shard_claim("(inline) Fixture sweeps")
    @testset "Fixture sweeps" begin

        @testset "Valid fixtures load" begin
            valid_dir = joinpath(TESTUTILS_REPO_ROOT, "tests", "valid")
            @test isdir(valid_dir)
            for filename in filter(f -> endswith(f, ".esm"), readdir(valid_dir))
                @testset "load: $filename" begin
                    esm_data = EarthSciAST.load_path(joinpath(valid_dir, filename))
                    @test esm_data isa EarthSciAST.EsmFile
                    @test !isnothing(esm_data.esm)
                    @test !isnothing(esm_data.metadata)
                end
            end
        end

        @testset "Invalid fixtures rejected" begin
            invalid_dir = joinpath(TESTUTILS_REPO_ROOT, "tests", "invalid")
            @test isdir(invalid_dir)
            for filename in filter(f -> endswith(f, ".esm"), readdir(invalid_dir))
                filepath = joinpath(invalid_dir, filename)
                @testset "reject: $filename" begin
                    # A fixture counts as rejected when load throws a documented
                    # rejection error or validate() reports errors. Any OTHER
                    # exception propagates with its full stack trace.
                    rejected = try
                        result = EarthSciAST.validate(
                            EarthSciAST.load_path(filepath))
                        !result.is_valid
                    catch e
                        # `ExpressionTemplateError` is the carrier for the
                        # LOWERING-pass diagnostics -- esm-spec §9.6/§9.7
                        # template + metaparameter codes, §10.9-§10.11 coupling
                        # codes, and §8.2.1 `data_source_url_unresolved`. It
                        # belongs on this list for the same reason the other
                        # three do; it was absent only because this sweep is
                        # NON-RECURSIVE (`readdir`, not `walkdir`), so the
                        # §9.7 fixtures that raise it live one directory down
                        # in tests/invalid/template_imports/ and never reached
                        # here. tests/invalid/data_source_url_env_var.esm is
                        # the first top-level fixture that raises it.
                        (e isa EarthSciAST.ParseError ||
                         e isa EarthSciAST.SchemaValidationError ||
                         e isa EarthSciAST.SubsystemRefError ||
                         e isa EarthSciAST.ExpressionTemplateError) || rethrow()
                        true
                    end
                    if rejected
                        @test rejected
                    else
                        # Known gap: some shared invalid fixtures (several
                        # units_* dimensional checks, undefined-variable rate
                        # references, ...) are rejected by other language
                        # bindings but pass Julia's load+validate. Kept broken
                        # (not skipped) so a src-side fix flips them visibly.
                        @test_broken rejected
                    end
                end
            end
        end

        @testset "Display fixtures parse" begin
            display_dir = joinpath(TESTUTILS_REPO_ROOT, "tests", "display")
            @test isdir(display_dir)
            for filename in filter(f -> endswith(f, ".json"), readdir(display_dir))
                @testset "display: $filename" begin
                    display_data = JSON3.read(read(joinpath(display_dir, filename), String))
                    # Fixture shape varies: flat arrays of cases, or objects
                    # keyed by "chemical_formulas" / "test_cases"; a few (e.g.
                    # model_summary.json) carry no case list at all.
                    cases = if display_data isa JSON3.Array
                        display_data
                    elseif display_data isa JSON3.Object && haskey(display_data, :chemical_formulas)
                        display_data[:chemical_formulas]
                    elseif display_data isa JSON3.Object && haskey(display_data, :test_cases)
                        display_data[:test_cases]
                    else
                        nothing
                    end
                    if cases === nothing
                        @test !isempty(display_data)
                    else
                        @test !isempty(cases)
                        # Every expression-shaped "input" must parse. Inputs may
                        # also be plain strings (chemical formulas), and nested
                        # {description, tests: [...]} groups keep their shape.
                        for case in cases
                            if case isa JSON3.Object && haskey(case, :input) &&
                               case[:input] isa JSON3.Object
                                expr = EarthSciAST.expression_from_json(case[:input])
                                @test expr isa EarthSciAST.ASTExpr
                            elseif case isa JSON3.Object && haskey(case, :tests)
                                @test case[:tests] isa JSON3.Array
                            end
                        end
                    end
                end
            end
        end

        # Substitution fixture tests live in expression_test.jl, where they
        # assert each case's expected output (not just that substitute runs).
    end
    end  # shard_claim("(inline) Fixture sweeps")

    # LAST, deliberately: every `shard_include`/`shard_claim` call above has
    # registered itself by now, so this is the point at which the registry is
    # complete and the partition can be checked. Included unconditionally — it
    # must run in EVERY shard, because a partition proven only in shard 1 says
    # nothing about shard 2.
    include(joinpath(@__DIR__, "shard_partition_test.jl"))
end
