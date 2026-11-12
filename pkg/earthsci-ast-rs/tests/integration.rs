//! The integration-test suite, compiled as ONE test binary.
//!
//! Every `tests/*.rs` file used to be its own binary, and each one linked the
//! whole crate with every test feature on: CI spent ~26 minutes building ~200
//! test executables that then ran for ~70 seconds between them. `Cargo.toml`
//! sets `autotests = false`, and this file pulls each test file in as a module
//! with `#[path]`, so the files keep their place in `tests/` (relative
//! `include_str!` paths and `cargo test <filter>` names still work, the latter
//! as `cargo test --test integration <module>::`).
//!
//! The files NOT listed here are the `[[test]]` targets in `Cargo.toml` that
//! must keep a process to themselves: four install a counting
//! `#[global_allocator]` (one per binary), `env_var_refs` mutates the process
//! environment, and `wasm_suite` only builds for wasm32.
//!
//! `every_test_file_is_registered` below fails when a new `tests/*.rs` file is
//! in neither place, since with `autotests = false` it would otherwise never run.

mod common;
mod portable;

#[path = "alias_observed_export_order.rs"]
mod alias_observed_export_order;
#[path = "analysis_features.rs"]
mod analysis_features;
#[path = "api_surface.rs"]
mod api_surface;
#[path = "array_level_broadcast.rs"]
mod array_level_broadcast;
#[path = "array_observed_output.rs"]
mod array_observed_output;
#[path = "arrayed_vars.rs"]
mod arrayed_vars;
#[path = "assertion_nonfinite_conformance.rs"]
mod assertion_nonfinite_conformance;
#[path = "assertion_tolerance_conformance.rs"]
mod assertion_tolerance_conformance;
#[path = "basic_functionality.rs"]
mod basic_functionality;
#[path = "build_once_spatial_field_conformance.rs"]
mod build_once_spatial_field_conformance;
#[path = "build_time_computed_gathers.rs"]
mod build_time_computed_gathers;
#[path = "build_time_tape_route.rs"]
mod build_time_tape_route;
#[path = "cadence_conformance.rs"]
mod cadence_conformance;
#[path = "classification_conformance.rs"]
mod classification_conformance;
#[path = "cli_data_source_ingest.rs"]
mod cli_data_source_ingest;
#[path = "cli_static_evaluation_output.rs"]
mod cli_static_evaluation_output;
#[path = "cli_test_command.rs"]
mod cli_test_command;
#[path = "cli_units_command.rs"]
mod cli_units_command;
#[path = "compiled_rhs_adapter.rs"]
mod compiled_rhs_adapter;
#[path = "compiler_gate_routes.rs"]
mod compiler_gate_routes;
#[path = "compiler_selection.rs"]
mod compiler_selection;
#[path = "conformance_round_trip.rs"]
mod conformance_round_trip;
#[path = "const_array_gather_bounds_conformance.rs"]
mod const_array_gather_bounds_conformance;
#[path = "const_array_gather_oob.rs"]
mod const_array_gather_oob;
#[path = "coupled_array_seam.rs"]
mod coupled_array_seam;
#[path = "coupled_const_array_fold.rs"]
mod coupled_const_array_fold;
#[path = "coupling_imports.rs"]
mod coupling_imports;
#[path = "cse_equivalence.rs"]
mod cse_equivalence;
#[path = "cumulative_prefix_scan.rs"]
mod cumulative_prefix_scan;
#[path = "dae_contract.rs"]
mod dae_contract;
#[path = "data_fed_retention.rs"]
mod data_fed_retention;
#[path = "data_output_derivation.rs"]
mod data_output_derivation;
#[path = "data_output_zarr_roundtrip.rs"]
mod data_output_zarr_roundtrip;
#[path = "data_source_extent_scope.rs"]
mod data_source_extent_scope;
#[path = "data_source_unbound_conformance.rs"]
mod data_source_unbound_conformance;
#[path = "data_source_url_conformance.rs"]
mod data_source_url_conformance;
#[path = "discrete_materialize_conformance.rs"]
mod discrete_materialize_conformance;
#[path = "display_conformance.rs"]
mod display_conformance;
#[path = "doubly_defined_state_conformance.rs"]
mod doubly_defined_state_conformance;
#[path = "earthscidata_loader_coverage.rs"]
mod earthscidata_loader_coverage;
#[path = "elementwise_observed_gather_conformance.rs"]
mod elementwise_observed_gather_conformance;
#[path = "esio_document_cadence.rs"]
mod esio_document_cadence;
#[path = "esio_provider_bridge.rs"]
mod esio_provider_bridge;
#[path = "esm_problem_front_door.rs"]
mod esm_problem_front_door;
#[path = "evaluable_core_gate.rs"]
mod evaluable_core_gate;
#[path = "evaluate_leaf_ops.rs"]
mod evaluate_leaf_ops;
#[path = "expression_operations.rs"]
mod expression_operations;
#[path = "expression_parse_conformance.rs"]
mod expression_parse_conformance;
#[path = "expression_templates_conformance.rs"]
mod expression_templates_conformance;
#[path = "faq_bare_array_operand.rs"]
mod faq_bare_array_operand;
#[path = "faq_conformance.rs"]
mod faq_conformance;
#[path = "faq_equality_scatter_conformance.rs"]
mod faq_equality_scatter_conformance;
#[path = "faq_simulate.rs"]
mod faq_simulate;
#[path = "field_ic_unlowered_operator.rs"]
mod field_ic_unlowered_operator;
#[path = "flatten.rs"]
mod flatten;
#[path = "flatten_conformance.rs"]
mod flatten_conformance;
#[path = "flatten_wire_conformance.rs"]
mod flatten_wire_conformance;
#[path = "forcing_from_sample.rs"]
mod forcing_from_sample;
#[path = "forcing_native_agreement.rs"]
mod forcing_native_agreement;
#[path = "from_faq_document_scope.rs"]
mod from_faq_document_scope;
#[path = "geometry_templates.rs"]
mod geometry_templates;
#[path = "graph_conformance.rs"]
mod graph_conformance;
#[path = "graph_structure.rs"]
mod graph_structure;
#[path = "ic_at_start_conformance.rs"]
mod ic_at_start_conformance;
#[path = "ifelse_shape_at_build.rs"]
mod ifelse_shape_at_build;
#[path = "index_set_member_factor.rs"]
mod index_set_member_factor;
#[path = "index_sets_document_scope.rs"]
mod index_sets_document_scope;
#[path = "initial_state_conformance.rs"]
mod initial_state_conformance;
#[path = "inline_test_build_memo.rs"]
mod inline_test_build_memo;
#[path = "inline_test_reference_mount_name.rs"]
mod inline_test_reference_mount_name;
#[path = "interpreter_compiler_no_tape.rs"]
mod interpreter_compiler_no_tape;
#[path = "inverse_trig_conformance.rs"]
mod inverse_trig_conformance;
#[path = "join_contracted_gate_propagation.rs"]
mod join_contracted_gate_propagation;
#[path = "join_gate_cache_budget.rs"]
mod join_gate_cache_budget;
#[path = "join_namespacing.rs"]
mod join_namespacing;
#[path = "join_on_conjunctive_gate.rs"]
mod join_on_conjunctive_gate;
#[path = "join_on_equality_gate.rs"]
mod join_on_equality_gate;
#[path = "join_on_equality_gate_bench.rs"]
mod join_on_equality_gate_bench;
#[path = "join_on_self_join.rs"]
mod join_on_self_join;
#[path = "loaded_ic_bc_simulation.rs"]
mod loaded_ic_bc_simulation;
#[path = "loader_ingest_and_select.rs"]
mod loader_ingest_and_select;
#[path = "loader_unit_conversion_conformance.rs"]
mod loader_unit_conversion_conformance;
#[path = "lower_enums_integration.rs"]
mod lower_enums_integration;
#[path = "m2_join_filter.rs"]
mod m2_join_filter;
#[path = "merged_rename_reach_conformance.rs"]
mod merged_rename_reach_conformance;
#[path = "metaparam_expr_bindings.rs"]
mod metaparam_expr_bindings;
#[path = "migration_conformance.rs"]
mod migration_conformance;
#[path = "missing_data_conformance.rs"]
mod missing_data_conformance;
#[path = "mount_element_type.rs"]
mod mount_element_type;
#[path = "mount_enums.rs"]
mod mount_enums;
#[path = "mount_index_set_rename.rs"]
mod mount_index_set_rename;
#[path = "mounted_component_tests.rs"]
mod mounted_component_tests;
#[path = "multi_model_ingest.rs"]
mod multi_model_ingest;
#[path = "native_interpreter_stencil_agreement.rs"]
mod native_interpreter_stencil_agreement;
#[path = "native_lazy_shapes.rs"]
mod native_lazy_shapes;
#[path = "native_model_shapes_conformance.rs"]
mod native_model_shapes_conformance;
#[path = "nonadvancing_run_skips_the_solver.rs"]
mod nonadvancing_run_skips_the_solver;
#[path = "observed_cadence_tier.rs"]
mod observed_cadence_tier;
#[path = "observed_cone.rs"]
mod observed_cone;
#[path = "observed_cycle.rs"]
mod observed_cycle;
#[path = "observed_field_static.rs"]
mod observed_field_static;
#[path = "observed_trajectory.rs"]
mod observed_trajectory;
#[path = "operator_compose_merge_conformance.rs"]
mod operator_compose_merge_conformance;
#[path = "operator_validation.rs"]
mod operator_validation;
#[path = "out_of_line_templates_conformance.rs"]
mod out_of_line_templates_conformance;
#[path = "output_derivation_conformance.rs"]
mod output_derivation_conformance;
#[path = "overlap_gate_conformance.rs"]
mod overlap_gate_conformance;
#[path = "overlap_gate_dense_scaling.rs"]
mod overlap_gate_dense_scaling;
#[path = "overlap_gate_live_forcing.rs"]
mod overlap_gate_live_forcing;
#[path = "override_key_diagnostics_conformance.rs"]
mod override_key_diagnostics_conformance;
#[path = "pde_const_hoist.rs"]
mod pde_const_hoist;
#[path = "pde_inline_array_overrides_conformance.rs"]
mod pde_inline_array_overrides_conformance;
#[path = "pde_inline_dead_observed_conformance.rs"]
mod pde_inline_dead_observed_conformance;
#[path = "pde_inline_ic_param_override_conformance.rs"]
mod pde_inline_ic_param_override_conformance;
#[path = "pde_inline_observed_indexed_lhs_conformance.rs"]
mod pde_inline_observed_indexed_lhs_conformance;
#[path = "pde_inline_observed_state_dependent_conformance.rs"]
mod pde_inline_observed_state_dependent_conformance;
#[path = "pde_inline_reference_dimension_names_conformance.rs"]
mod pde_inline_reference_dimension_names_conformance;
#[path = "pde_vectorized_eval.rs"]
mod pde_vectorized_eval;
#[path = "performance.rs"]
mod performance;
#[path = "pipeline_flatten_rewrites.rs"]
mod pipeline_flatten_rewrites;
#[path = "portable_native_interpreter.rs"]
mod portable_native_interpreter;
#[path = "ppm_template_chain.rs"]
mod ppm_template_chain;
#[path = "precision_element_type.rs"]
mod precision_element_type;
#[path = "prepare_progress.rs"]
mod prepare_progress;
#[path = "prepare_pushdown_l1.rs"]
mod prepare_pushdown_l1;
#[path = "pretty_print.rs"]
mod pretty_print;
#[path = "problem_surface.rs"]
mod problem_surface;
#[path = "property_expression.rs"]
mod property_expression;
#[path = "provider_forcing_conformance.rs"]
mod provider_forcing_conformance;
#[path = "public_rhs_program_conformance.rs"]
mod public_rhs_program_conformance;
#[path = "pushdown_cell_geometry.rs"]
mod pushdown_cell_geometry;
#[path = "pushdown_conformance.rs"]
mod pushdown_conformance;
#[path = "pushdown_template_ref.rs"]
mod pushdown_template_ref;
#[path = "range_restricted_rhs_conformance.rs"]
mod range_restricted_rhs_conformance;
#[path = "reaction_lowering_form.rs"]
mod reaction_lowering_form;
#[path = "reaction_species_order.rs"]
mod reaction_species_order;
#[path = "reaction_system_inline_tests.rs"]
mod reaction_system_inline_tests;
#[path = "records_per_sample_conformance.rs"]
mod records_per_sample_conformance;
#[path = "recurrence_causal_self_reference.rs"]
mod recurrence_causal_self_reference;
#[path = "recurrence_native_agreement.rs"]
mod recurrence_native_agreement;
#[path = "refresh_conformance.rs"]
mod refresh_conformance;
#[path = "relational_rewrites.rs"]
mod relational_rewrites;
#[path = "relational_templates.rs"]
mod relational_templates;
#[path = "removed_spellings.rs"]
mod removed_spellings;
#[path = "reserved_index_symbol.rs"]
mod reserved_index_symbol;
#[path = "reservoir_constant_species.rs"]
mod reservoir_constant_species;
#[path = "rhs_auto_routing.rs"]
mod rhs_auto_routing;
#[path = "rhs_time_derivative.rs"]
mod rhs_time_derivative;
#[path = "rhs_time_derivative_conformance.rs"]
mod rhs_time_derivative_conformance;
#[path = "round_trip.rs"]
mod round_trip;
#[path = "saveat_past_the_span.rs"]
mod saveat_past_the_span;
#[path = "scalar_ic_conformance.rs"]
mod scalar_ic_conformance;
#[path = "scalar_operand_in_faq.rs"]
mod scalar_operand_in_faq;
#[path = "scalar_param_array_default.rs"]
mod scalar_param_array_default;
#[path = "schema_validation.rs"]
mod schema_validation;
#[path = "scope_injection_conformance.rs"]
mod scope_injection_conformance;
#[path = "scoped_assertion_variable.rs"]
mod scoped_assertion_variable;
#[path = "segmented_refresh_solve.rs"]
mod segmented_refresh_solve;
#[path = "shaped_observed_scalar_broadcast_conformance.rs"]
mod shaped_observed_scalar_broadcast_conformance;
#[path = "shaped_parameter_broadcast_conformance.rs"]
mod shaped_parameter_broadcast_conformance;
#[path = "shaped_parameter_const_arrays_conformance.rs"]
mod shaped_parameter_const_arrays_conformance;
#[path = "simulate.rs"]
mod simulate;
#[path = "simulate_progress.rs"]
mod simulate_progress;
#[path = "solver_block.rs"]
mod solver_block;
#[path = "solver_external_conformance.rs"]
mod solver_external_conformance;
#[path = "solver_time_span_conformance.rs"]
mod solver_time_span_conformance;
#[path = "static_evaluation_assertions_conformance.rs"]
mod static_evaluation_assertions_conformance;
#[path = "stdlib_refs_conformance.rs"]
mod stdlib_refs_conformance;
#[path = "stoichiometric_matrix.rs"]
mod stoichiometric_matrix;
#[path = "strip_and_expose_conformance.rs"]
mod strip_and_expose_conformance;
#[path = "structural_validation.rs"]
mod structural_validation;
#[path = "structural_validation_programmatic.rs"]
mod structural_validation_programmatic;
#[path = "substitution.rs"]
mod substitution;
#[path = "subsystem_loader_conformance.rs"]
mod subsystem_loader_conformance;
#[path = "subsystem_mount_build.rs"]
mod subsystem_mount_build;
#[path = "subsystem_mount_join_names.rs"]
mod subsystem_mount_join_names;
#[path = "tape_exec.rs"]
mod tape_exec;
#[path = "tape_fallback_reporting.rs"]
mod tape_fallback_reporting;
#[path = "tape_loop_lowering.rs"]
mod tape_loop_lowering;
#[path = "template_array_args.rs"]
mod template_array_args;
#[path = "template_imports_conformance.rs"]
mod template_imports_conformance;
#[path = "template_scenarios.rs"]
mod template_scenarios;
#[path = "term_provenance.rs"]
mod term_provenance;
#[path = "tests_blocks_execution.rs"]
mod tests_blocks_execution;
#[path = "toplevel_mount_edge_pipeline.rs"]
mod toplevel_mount_edge_pipeline;
#[path = "toplevel_reaction_system_ref.rs"]
mod toplevel_reaction_system_ref;
#[path = "transcendental_scale_conformance.rs"]
mod transcendental_scale_conformance;
#[path = "undeclared_operand_gate.rs"]
mod undeclared_operand_gate;
#[path = "unit_registry_conformance.rs"]
mod unit_registry_conformance;
#[path = "units.rs"]
mod units;
#[path = "units_across_mounts.rs"]
mod units_across_mounts;
#[path = "units_dimensionless_literal.rs"]
mod units_dimensionless_literal;
#[path = "units_fixtures.rs"]
mod units_fixtures;
#[path = "units_inline_tests.rs"]
mod units_inline_tests;
#[path = "unsupported_construct_conformance.rs"]
mod unsupported_construct_conformance;
#[path = "url_substitutions_conformance.rs"]
mod url_substitutions_conformance;
#[path = "value_invention_arrays_and_extents.rs"]
mod value_invention_arrays_and_extents;
#[path = "value_invention_caller_data.rs"]
mod value_invention_caller_data;
#[path = "value_invention_materialize_conformance.rs"]
mod value_invention_materialize_conformance;
#[path = "variable_map_expression_transform.rs"]
mod variable_map_expression_transform;
#[path = "vec_coverage_frontier.rs"]
mod vec_coverage_frontier;
#[path = "wildfire_simulation.rs"]
mod wildfire_simulation;
#[path = "wrt_default_omitted.rs"]
mod wrt_default_omitted;
#[path = "xla_compiled_rhs.rs"]
mod xla_compiled_rhs;

/// With `autotests = false`, a test file that is neither a module above nor a
/// `[[test]]` target in `Cargo.toml` silently never compiles or runs.
#[test]
fn every_test_file_is_registered() {
    let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
    let this = std::fs::read_to_string(dir.join("tests/integration.rs")).unwrap();
    let manifest = std::fs::read_to_string(dir.join("Cargo.toml")).unwrap();
    let mut missing = Vec::new();
    for entry in std::fs::read_dir(dir.join("tests")).unwrap() {
        let path = entry.unwrap().path();
        if path.extension().is_none_or(|e| e != "rs") {
            continue;
        }
        let file = path.file_name().unwrap().to_str().unwrap().to_owned();
        if file == "integration.rs" {
            continue;
        }
        let as_module = format!("#[path = \"{file}\"]");
        let as_target = format!("path = \"tests/{file}\"");
        if !this.contains(&as_module) && !manifest.contains(&as_target) {
            missing.push(file);
        }
    }
    assert!(
        missing.is_empty(),
        "tests/ files that never run: {missing:?} -- add each to tests/integration.rs \
         (or, if it needs its own process, a [[test]] target in Cargo.toml)"
    );
}
