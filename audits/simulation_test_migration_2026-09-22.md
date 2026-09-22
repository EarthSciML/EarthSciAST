# Simulation-test migration ledger — phase 6 of "Choosing the Compiler"

Branch `compiler/testmig`, cut from `compiler-selection` at `25efca83a`. This
document is the disposition of **every** file the three phase-0 censuses
classified as *move-to-fixture*:

* `audits/compiler_census_2026-09-21_julia.md` §3A — 52 files
* `audits/compiler_census_2026-09-21_rust.md` §3 (the `fixture` bucket) — 52 files
* `audits/compiler_census_2026-09-21_python.md` §3.1 (bucket 1) — 28 files

Every claim below was measured on this branch; nothing is inferred from the
censuses' prose.

## One correction to the premise, up front

The phase description assumed that a file which is "an adapter over a shared
fixture + golden" is a **duplicate** of something `scripts/test-conformance.sh`
already runs for every binding, and can therefore be deleted. **On this
repository that is not true, and it matters.**

`scripts/test-conformance.sh` drives exactly seven tier families with
per-binding producer stages: `determinism`, `cadence`, `pde_simulation`,
`pde_simulation_pipeline`, `compiled_rhs`, `compiler_agreement`, and (self-test
only) `geometry`. Every OTHER tier under `tests/conformance/` — 50-odd of them,
including `shaped_parameter_broadcast`, `scalar_ic`, `merged_rename_reach`, all
eight `pde_inline_*` categories and the rest — is driven **only by each
binding's own test suite**, through exactly the per-binding adapter files the
censuses bucketed as *move-to-fixture*.

Those adapters are therefore **not duplicates**: each one is the only thing that
runs that shared fixture in that binding. Deleting a Julia adapter would delete
Julia's coverage of that tier outright. They are gated in CI — the
`standard-conformance-testing` job carries
`needs: [julia-tests, typescript-tests, python-tests, rust-tests, go-tests]`, so
all five suites pass before the harness starts — but they are gated **there**,
not in the harness.

So the ledger's first category is **already shared**, not "already covered, so
deletable". A file in it needs no work and must not be removed; the semantics it
gates is already one document and one golden that every executing binding reads.
What it does NOT have is a harness stage naming its compiler, and that is a
separate, larger piece of work than this phase: it would mean an adapter CLI per
tier per binding, times fifty tiers. The one general-purpose mechanism this
phase added — `scripts/run-inline-tests-conformance.py` and its three adapters —
is what makes that possible tier by tier, and the two new tiers are built on it.

## Totals

| Binding | Files | already shared | migrated now | deferred |
|---|---|---|---|---|
| Julia | 52 | 44 | 2 | 6 |
| Rust | 55 | 45 | 2 | 8 |
| Python | 28 | 26 | 1 | 1 |
| **Total** | **135** | **115** | **5** | **15** |

The Rust column carries **three rows beyond the census's 52**:
`cumulative_prefix_scan.rs`, `recurrence_causal_self_reference.rs` and
`simulate.rs`. The Rust census bucketed each of those as binding-internal or
refusal because that is what MOST of the file is, while saying in the same row
that it is "genuinely two-bucket". Their fixture halves are real, `simulate.rs`
holds seven of the analytic trajectory goldens this phase is about, and leaving
them out would have left the largest analytic-trajectory file in the tree
unaccounted for. They are listed here for completeness and counted separately
above.

"migrated now" counts the FILE whose assertions moved, not the assertions: the
five files between them gave up five documents' worth of §4.3.4 value claims and
two private operator tables, and the destination is two new tiers holding eleven
fixtures and 138 assertions.

## What was built

| Thing | Path |
|---|---|
| the runner | `scripts/run-inline-tests-conformance.py` |
| Julia adapter | `pkg/EarthSciAST.jl/scripts/inline_tests_adapter.jl` |
| Rust adapter | `pkg/earthsci-ast-rs/src/inline_tests_adapter.rs` + `src/bin/earthsci-inline-tests-adapter-rust.rs` |
| Python adapter | `pkg/earthsci-ast-py/src/earthsci_ast/cli/inline_tests_adapter.py` |
| normative text | `CONFORMANCE_SPEC.md` §5.45 |
| harness stages | `scripts/test-conformance.sh`: `inline-test self-test`, then `inline-test {interpreter,native} producer ({julia,rust,python})` — 7 stages, each naming `--compiler` explicitly |
| tier 1 | `tests/conformance/broadcast_alignment/` — 7 fixtures (4 referenced from `tests/valid/array_broadcast/`, 3 authored), 48 assertions |
| tier 2 | `tests/conformance/scalar_operator_semantics/` — 4 fixtures, 90 assertions: 84 operator rows in one algebraic document, plus three split-out single-operator documents (`pow`, `true`, `false`) |

## Named refusals, for issue filing

Every one was MEASURED on this branch on 2026-09-22 and is recorded in the
fixture's `named_exclusions` ledger, so each run reports it by name.

| Binding | Compilers | Fixture | Code | What it means |
|---|---|---|---|---|
| rust | `native` | `broadcast_alignment/broadcast_node_mixed_rank` | `compiler_refused_rule` | Rust's strict `native` has no wholesale lowering for the array-level `broadcast` node: *"compiler 'native' cannot run the continuous-cadence state derivative 'D(dp[1,1,1])': wholesale: unsupported op `broadcast`"*. `interpreter` runs it. Rust's own `tests/array_level_broadcast.rs` already forced `Compiler::Interpreter` on these documents; this is the first place the refusal is NAMED rather than worked around. |
| rust | `native` | `broadcast_alignment/unary_broadcast_fn` | `compiler_refused_rule` | The same rule, on the one-operand `broadcast` spelling. |
| rust | `interpreter`, `native` | `scalar_operator_semantics/pow_alias` | `unlowered_operator` | Rust classes `pow` as a REWRITE TARGET, not an evaluable-core operator: *"rewrite-target operator 'pow' reached evaluation without being lowered to a stencil by a rewrite rule"*. Julia and Python both evaluate it, and to the same number `^` gives. Not a `native` strictness question — the refusal is identical under `interpreter`. |
| rust | `interpreter`, `native` | `scalar_operator_semantics/boolean_literal_false` | `unlowered_operator` | Rust classes the `false` literal op as a rewrite target and refuses it before evaluation. |
| julia | `interpreter`, `native` | `scalar_operator_semantics/boolean_literal_false` | `unevaluable_operator` | Julia's tree-walk evaluator carries an evaluation rule for `true` and **none** for `false`: *"operator 'false' is an evaluable-core op with no evaluation rule in the tree-walk evaluator"*. Python is the only binding that answers this operator today. |
| rust | `native` | `scalar_operator_semantics/boolean_literal_true` | `compiler_refused_rule` | Rust's strict `native` has no wholesale lowering for the `true` leaf: *"compiler 'native' cannot run the const-cadence observed 'literal_true': wholesale: unsupported op `true`"*. Its `interpreter` runs it. |

**Two kinds of gap, and the ledger keeps them apart.** `pow` and `false` are
refused by Rust under `interpreter` too, and `false` is refused by Julia under
both — those are disagreements about what the evaluable-core VOCABULARY IS, and
`esm-libraries-spec.md` §2.5.10 says both operators are in it. `true` and the
two `broadcast` fixtures are refused only under `native`, so those are ordinary
`native` coverage gaps of exactly the kind phase 6 exists to make visible.

Each contested operator is split into a fixture of its own precisely so that an
exclusion costs the 84 operators in the sibling fixture nothing. Nothing was
weakened to make a binding pass: every assertion is at the tolerance it was
authored with, and the scalar tier's default band is EXACT.

## Per-file disposition

### Julia (52 files, under `pkg/EarthSciAST.jl/`)

already shared 44 · migrated now 2 · deferred 6

| File | Disposition | Detail |
|---|---|---|
| `test/array_ops_test.jl` | **already shared** | The four value testsets (1, 2, 6, 8) are the analytic arms of `tests/fixtures/faq/01`, `02`, `06`, `08`, which every binding already runs through `simulate_faq`. What is left in the file is MTK-path structure (`length(unknowns(simp))`), serialization round trips, `infer_array_shapes`, and an MTK-vs-tree-walk bit-identity — none of which a document can state. The `Cancel` accumulation-order case (§5.45 candidate) is deferred; see below. |
| `test/broadcast_alignment_test.jl` | **migrated now** | Its §4.3.4 VALUE testsets are now `tests/conformance/broadcast_alignment/`, run by `scripts/test-conformance.sh` for julia, rust and python under both `interpreter` and `native`. The file keeps its `validate()` diagnostics (`array_shape_mismatch`, the `broadcast` `fn` contract), its two-build oracle differentials, the internal predicates and the MTK exporter's `fn` vocabulary. |
| `test/build_once_spatial_field_conformance_test.jl` | **already shared** | Adapter over `tests/conformance/build_once_spatial_field/` (§5.12); rust and python have their own adapters over the same fixture and golden. |
| `test/conformance_assertion_nonfinite_test.jl` | **already shared** | Adapter over `tests/conformance/assertion_nonfinite/` (§5.20). |
| `test/conformance_assertion_tolerance_test.jl` | **already shared** | Adapter over `tests/conformance/assertion_tolerance/` (§5.37). |
| `test/conformance_elementwise_observed_gather_test.jl` | **already shared** | Adapter over `tests/conformance/elementwise_observed_gather/` (§5.29). |
| `test/conformance_pde_inline_array_overrides_test.jl` | **already shared** | Adapter over `tests/conformance/pde_inline_array_overrides/` (§5.28). |
| `test/conformance_pde_inline_dead_observed_test.jl` | **already shared** | Adapter over `tests/conformance/pde_inline_dead_observed/`. |
| `test/conformance_pde_inline_ic_param_override_test.jl` | **already shared** | Adapter over `tests/conformance/pde_inline_ic_param_override/` (§5.14). |
| `test/conformance_pde_inline_observed_indexed_lhs_test.jl` | **already shared** | Adapter over `tests/conformance/pde_inline_observed_indexed_lhs/` (§5.36). |
| `test/conformance_pde_inline_observed_param_rank2_test.jl` | **already shared** | Adapter over `tests/conformance/pde_inline_observed_param_rank2/`. |
| `test/conformance_pde_inline_observed_rank2_test.jl` | **already shared** | Adapter over `tests/conformance/pde_inline_observed_rank2/`. |
| `test/conformance_pde_inline_observed_state_dependent_test.jl` | **already shared** | Adapter over `tests/conformance/pde_inline_observed_state_dependent/`. |
| `test/conformance_pde_inline_reference_dimension_names_test.jl` | **already shared** | Adapter over `tests/conformance/pde_inline_reference_dimension_names/` (§5.30). |
| `test/conformance_scalar_ic_test.jl` | **already shared** | Adapter over `tests/conformance/scalar_ic/` (§5.16). |
| `test/conformance_shaped_observed_scalar_broadcast_test.jl` | **already shared** | Adapter over `tests/conformance/shaped_observed_scalar_broadcast/` (§5.41). |
| `test/conformance_shaped_parameter_broadcast_test.jl` | **already shared** | Adapter over `tests/conformance/shaped_parameter_broadcast/` (§5.32). This file is the template the two new tiers' contract was built from. |
| `test/conformance_static_evaluation_assertions_test.jl` | **already shared** | Adapter over `tests/conformance/static_evaluation_assertions/` (§5.43). |
| `test/container_in_document_test.jl` | **already shared** | Drives the shared `tests/conformance/merged_rename_reach/` manifest. |
| `test/discrete_materialize_conformance_test.jl` | **already shared** | Adapter over `tests/conformance/discrete_materialize/` (§5.13). |
| `test/faq_conformance_test.jl` | **already shared** | Drives the shared `tests/valid/faq/*.esm` documents, which already carry inline `tests` blocks; rust (`faq_conformance.rs`) and python (`test_faq_conformance.py`) drive the same files. |
| `test/function_tables_lowering_path_test.jl` | **already shared** | Drives the shared `tests/conformance/function_tables/<case>/fixture.esm` documents and their inline `tests` blocks. |
| `test/geometry_assembly_conformance_test.jl` | **already shared** | Drives shared `tests/valid/geometry/` documents with exact rational expectations (§5.8). |
| `test/geometry_conformance_test.jl` | **already shared** | Drives shared `tests/valid/geometry/` documents under the §5.8.2 tolerance gate; python mirrors it. |
| `test/geometry_overlap_join_conformance_test.jl` | **already shared** | Drives a shared `tests/valid/geometry/` document end to end. |
| `test/geometry_polygon_intersection_area_test.jl` | **already shared** | Drives shared `tests/valid/geometry/polygon_intersection_area_*.esm`. |
| `test/geometry_ranged_clip_test.jl` | **deferred** | The document is built inline in Julia, and the assertion is a declarative 2x2 / 3x3 OVERLAP MATRIX rather than a value at a time. Moving it needs either a document spelling for the matrix or a new tier whose comparison is a matrix; neither exists. No other binding has a twin to converge with. |
| `test/inline_tests_test.jl` | **already shared** | Drives the shared `coords` / `integral` / `from_file` fixtures; the census notes it is already pinned 1:1 with the Python and Rust suites. |
| `test/inverse_trig_conformance_test.jl` | **already shared** | Drives the shared inverse-trig / hyperbolic fixture that rust and python also run. `scalar_operator_semantics` deliberately does NOT duplicate those leaves. |
| `test/loaded_ic_bc_simulation_test.jl` | **already shared** | Drives the committed `pde_simulation_pipeline` document; the harness runs that tier for julia, rust and python. |
| `test/loader_ingest_and_select_test.jl` | **already shared** | Drives the shared `tests/valid/data_sources_ingest_and_select.esm` and pins the same numbers as the Rust mirror. |
| `test/merged_rename_reach_conformance_test.jl` | **already shared** | Adapter over `tests/conformance/merged_rename_reach/` (§5.35). |
| `test/mounted_component_tests_test.jl` | **already shared** | Adapter over `tests/conformance/mounted_component_tests/` (§6.6 mount edge). |
| `test/out_of_line_templates_test.jl` | **already shared** | Drives the shared `tests/conformance/expression_templates/` families. |
| `test/overlap_gate_conformance_test.jl` | **deferred** | Both documents are built inline, and the load-bearing assertions are the CANDIDATE SET the gate enumerated as well as the fluxes. The candidate set is a build-time artifact no document can state; splitting the flux half out would leave the tier gating the easy half only. |
| `test/pushdown_cell_geometry_test.jl` | **deferred** | §5.5.7 cell-axis renumbering, paired with a Python mirror (`test_pushdown_cell_geometry.py`) and a Rust one (`pushdown_cell_geometry.rs`). A strong migration candidate for a third inline-test tier, but the Julia and Python halves also assert the REWRITE RECORD through `BuildInspection`, so the tier needs a design decision about whether the numeric half alone is worth its own fixture. Not started. |
| `test/reaction_system_ref_test.jl` | **deferred** | Uses package-local fixtures under `test/fixtures/reaction_ref/` plus the read-only `EarthSciModels` checkout, and its claim is that a mounted-by-reference reaction system flattens and simulates IDENTICALLY to the inlined document — a two-document comparison, not a value a single document states. |
| `test/refresh_conformance_test.jl` | **already shared** | Adapter over `tests/conformance/refresh/` (§5.10). |
| `test/rhs_time_derivative_resolution_test.jl` | **already shared** | Adapter over `tests/conformance/rhs_time_derivative/` (§5.42). |
| `test/scoped_assertion_variable_test.jl` | **already shared** | Drives the shared `tests/conformance/scoped_assertion_variable/` fixtures. |
| `test/simulate_e2e_test.jl` | **deferred** | Decay, the reversible reaction, autocatalysis and Robertson, each against an analytic or published reference. Every trajectory arm is expressible as an inline `tests` block, and the Rust (`simulate.rs`) and Python (`test_simulation.py`) twins assert the same physics at different operands — so the fixture should be the UNION, the way `scalar_operator_semantics` is. What blocks it today is that three of the four also assert a trajectory-wide INVARIANT (`A + B` conserved at every sample) and two assert an INEQUALITY, neither of which §6.6 can state without adding a `total` observed to the document; and Robertson needs a stiff integrator, i.e. a §2.2 `solver` block, whose cross-binding behaviour at t = 4e10 is unmeasured. A third tier, `analytic_trajectories`, is the right home and is NOT started. |
| `test/subsystem_loader_conformance_test.jl` | **already shared** | Adapter over `tests/conformance/subsystem_loader/` (§5.11). |
| `test/template_imports_test.jl` | **already shared** | Drives the shared expression-template and invalid-template-import fixtures. |
| `test/tests_blocks_execution_test.jl` | **already shared** | Walks the shared `tests/simulation/*.esm` documents; rust (`tests_blocks_execution.rs`) and python (`test_simulation_fixtures_blocks.py`) walk the same set. |
| `test/tree_walk_const_array_boundary_test.jl` | **deferred** | The clamp / periodic boundary POLICY is an evaluator keyword argument (`const_array_boundaries`) with NO document spelling anywhere in `esm-schema.json` or `esm-spec.md` — CONFORMANCE_SPEC §5.5.5 says so explicitly. A fixture cannot carry it, so the numerics cannot move without a format change. The half that IS document-expressible, 'an out-of-range gather with no declared policy fails closed', is already `tests/conformance/const_array_gather_bounds/`. |
| `test/tree_walk_faq_test.jl` | **already shared** | Drives the shared `tests/fixtures/faq/` documents and their inline `tests` blocks. |
| `test/tree_walk_join_test.jl` | **already shared** | Drives the shared `tests/valid/faq/join_filter.esm`. |
| `test/tree_walk_semiring_test.jl` | **already shared** | Drives the shared `tests/valid/faq/faq_semiring_indexset.esm`. |
| `test/tree_walk_test.jl` | **migrated now** | Its five scalar-operator testsets (arithmetic, integer-vs-float literals, comparisons and logic, `ifelse`/`sign`/`min`/`max`, elementary functions) are now `tests/conformance/scalar_operator_semantics/`, at EXACT tolerance and over the union of the Julia and Rust operand values. The file keeps the closed-function registry, the unsupported-op diagnostics, observed inlining and cycle detection, the decay and 1-D heat solves, and the MTK parity sampling. |
| `test/value_invention_materialize_conformance_test.jl` | **already shared** | Adapter over `tests/conformance/value_invention_materialize/`. |
| `test/wildfire_simulation_test.jl` | **already shared** | Drives the shared `tests/valid/wildfire_atmosphere_ocean.esm`; rust and python drive the same document. |
| `test/wrt_default_omitted_test.jl` | **already shared** | Drives the shared `tests/conformance/classification/fixtures/wrt_default_omitted.esm` plus the shared faq and simulation documents (§5.42). |

### Rust (55 files, under `pkg/earthsci-ast-rs/tests/`)

already shared 45 · migrated now 2 · deferred 8

| File | Disposition | Detail |
|---|---|---|
| `array_level_broadcast.rs` | **migrated now** | Its §4.3.4 value claims are now `tests/conformance/broadcast_alignment/`, which REFERENCES the same four `tests/valid/array_broadcast/*.esm` documents this file drives and adds three more. The file keeps its structural guard, its bare-vs-`broadcast` and bare-vs-`faq` bit-identity arms, and the `array_shape_mismatch` refusals. |
| `arrayed_vars.rs` | **already shared** | Shape / location round trips through `esm_problem` over shared documents; never solves. |
| `assertion_nonfinite_conformance.rs` | **already shared** | Adapter over `tests/conformance/assertion_nonfinite/`. |
| `build_once_spatial_field_conformance.rs` | **already shared** | Adapter over `tests/conformance/build_once_spatial_field/` (§5.12). |
| `coupled_const_array_fold.rs` | **already shared** | Two spellings of one shared table must give the same number (issue #207); the claim is a two-document identity, and the documents are shared. |
| `coupling_imports.rs` | **already shared** | Import-to-edge expansion ported from the TypeScript reference over the shared coupling corpus. |
| `cumulative_prefix_scan.rs` | **already shared** | The value arms drive `tests/fixtures/faq/25_cumulative_prefix_reduction.esm`, whose inline `tests` block every binding runs; the rest is linear-work and timing, which is binding-internal. |
| `discrete_materialize_conformance.rs` | **already shared** | Adapter over `tests/conformance/discrete_materialize/` (§5.13). |
| `elementwise_observed_gather_conformance.rs` | **already shared** | Adapter over `tests/conformance/elementwise_observed_gather/`. |
| `faq_conformance.rs` | **already shared** | Drives the shared `tests/valid/faq/` worked examples. |
| `faq_simulate.rs` | **already shared** | Semiring / index-set values over the shared faq documents. |
| `function_tables_inline_tests.rs` | **already shared** | Drives the shared `tests/conformance/function_tables/` documents. |
| `geometry_simulate_conformance.rs` | **already shared** | Drives the shared `tests/valid/geometry/` documents (§5.8). |
| `inline_test_reference_mount_name.rs` | **already shared** | Drives a shared mount-relative `reference` document (issue #408). |
| `interpret.rs` | **migrated now** | Its operator-by-operator numeric rows are now `tests/conformance/scalar_operator_semantics/`, at EXACT tolerance and at the SAME operands this file used — that is why the fixture carries `+(2,3)`, `+(1,2,3,4)`, `-(10,3)`, `-(5)`, `^(2,10)`, `abs(-3.5)`, `sign(-7)`, `sign(2)`, `floor(2.7)`, `ceil(2.2)`, `min(2,3)`, `max(2,3)`, `ifelse(1,42,99)`, `ifelse(0,42,99)`, the six relational rows and the six logical rows alongside the Julia ones. The file keeps `exp(1)`/`log(e)`/`log10(1000)`/`sqrt(2)`, the trigonometric and hyperbolic rows (the `inverse_trig` tier's subject), `Pre`, the slot-addressed evaluation test and the two construction-time refusals. |
| `inverse_trig_conformance.rs` | **already shared** | Adapter over the shared inverse-trig fixture. |
| `join_on_conjunctive_gate.rs` | **deferred** | §5.24 conjunctive-gate VALUES over inline documents, alongside gate visit counters. The values would move cleanly; the counters are the point of the file and cannot. Needs a tier design that splits them. Not started. |
| `join_on_equality_gate.rs` | **deferred** | Same shape as above for §5.5.8, and the Julia twin (`join_on_equality_gate_test.jl`) is bucketed `stays` because its oracle is a second Julia build. Not started. |
| `join_on_self_join.rs` | **deferred** | Self-join semantics over inline documents; same split as the two gate files. |
| `loaded_ic_bc_simulation.rs` | **already shared** | Drives the shared `pde_simulation_pipeline` document. |
| `loader_ingest_and_select.rs` | **already shared** | §8.9 loader-ingest values off the shared FF10 / Zarr fixtures; the Julia mirror pins the same numbers. |
| `m2_join_filter.rs` | **already shared** | Drives the shared `tests/valid/faq/join_filter.esm` family. |
| `merged_rename_reach_conformance.rs` | **already shared** | Adapter over `tests/conformance/merged_rename_reach/` (§5.35). |
| `mounted_component_tests.rs` | **already shared** | Adapter over `tests/conformance/mounted_component_tests/`. |
| `pde_inline_array_overrides_conformance.rs` | **already shared** | Adapter over `tests/conformance/pde_inline_array_overrides/`. |
| `pde_inline_dead_observed_conformance.rs` | **already shared** | Adapter over `tests/conformance/pde_inline_dead_observed/`. |
| `pde_inline_ic_param_override_conformance.rs` | **already shared** | Adapter over `tests/conformance/pde_inline_ic_param_override/`. |
| `pde_inline_observed_indexed_lhs_conformance.rs` | **already shared** | Adapter over `tests/conformance/pde_inline_observed_indexed_lhs/`. |
| `pde_inline_observed_state_dependent_conformance.rs` | **already shared** | Adapter over `tests/conformance/pde_inline_observed_state_dependent/`. |
| `pde_inline_reference_dimension_names_conformance.rs` | **already shared** | Adapter over `tests/conformance/pde_inline_reference_dimension_names/`. |
| `ppm_template_chain.rs` | **already shared** | Drives the shared PPM template chain. |
| `precision_element_type.rs` | **already shared** | §11.3 Float32 rounding over shared documents (§5.18). |
| `prepare_pushdown_l1.rs` | **deferred** | Rust port of the Julia pushdown test against a frozen fixture and a step-0 oracle; same family as `pushdown_cell_geometry` and deferred with it. |
| `pushdown_cell_geometry.rs` | **deferred** | One of the Julia/Python/Rust §5.5.7 triple. Deferred with its Julia twin: the numeric half would move, the rewrite-record half would not. |
| `reaction_system_inline_tests.rs` | **already shared** | §7.2 `reaction_systems[].tests` over shared documents. |
| `recurrence_causal_self_reference.rs` | **already shared** | The evaluation half drives the shared `tests/conformance/recurrence/` corpus (§5.19); the other half is the rejection ledger. |
| `refresh_conformance.rs` | **already shared** | Adapter over `tests/conformance/refresh/` (§5.10). |
| `reservoir_constant_species.rs` | **already shared** | Drives the shared §7.4 reservoir fixture. |
| `rhs_time_derivative.rs` | **already shared** | The shared §4.2 documents; `rhs_time_derivative_conformance.rs` drives the manifest. |
| `rhs_time_derivative_conformance.rs` | **already shared** | Adapter over `tests/conformance/rhs_time_derivative/`. |
| `scalar_ic_conformance.rs` | **already shared** | Adapter over `tests/conformance/scalar_ic/` (§5.16). |
| `scalar_operand_in_faq.rs` | **deferred** | A 0-D declaration read as a number inside a `faq`, over an inline document. Small and clean, and a good candidate for a later inline-test fixture; no other binding has a twin, so it buys agreement rather than convergence. Not started. |
| `scoped_assertion_variable.rs` | **already shared** | Drives the shared `tests/conformance/scoped_assertion_variable/` fixtures. |
| `shaped_observed_scalar_broadcast_conformance.rs` | **already shared** | Adapter over `tests/conformance/shaped_observed_scalar_broadcast/` (§5.41). |
| `shaped_parameter_broadcast_conformance.rs` | **already shared** | Adapter over `tests/conformance/shaped_parameter_broadcast/` (§5.32). |
| `simulate.rs` | **deferred** | The seven analytic / literature trajectory goldens — decay, the reversible reaction, autocatalysis, Robertson, the two `tests/simulation/*.esm` round trips and the parameter sweep. Deferred WITH `simulate_e2e_test.jl`, which asserts the same four physics at different constants; the union belongs in one `analytic_trajectories` tier, and the blockers are the same (trajectory-wide invariants, inequalities, and a stiff `solver` block whose cross-binding behaviour is unmeasured). Not started. |
| `static_evaluation_assertions_conformance.rs` | **already shared** | Adapter over `tests/conformance/static_evaluation_assertions/` (§5.43). |
| `subsystem_loader_conformance.rs` | **already shared** | Adapter over `tests/conformance/subsystem_loader/` (§5.11). |
| `subsystem_mount_join_names.rs` | **already shared** | Drives a shared mounted-leaf document. |
| `tests_blocks_execution.rs` | **already shared** | Walks the shared `tests/simulation/*.esm` documents. |
| `transcendental_scale_conformance.rs` | **already shared** | §4.8.3 degree/radian scale over shared fixtures. `scalar_operator_semantics` deliberately does not duplicate it. |
| `value_invention_materialize_conformance.rs` | **already shared** | Adapter over `tests/conformance/value_invention_materialize/`. |
| `value_invention_simulate.rs` | **deferred** | Two relational-output models simulate end to end from inline documents. No twin in another binding; a candidate for a later fixture. |
| `wildfire_simulation.rs` | **already shared** | Drives the shared `tests/valid/wildfire_atmosphere_ocean.esm`. |
| `wrt_default_omitted.rs` | **already shared** | Drives the shared `wrt_default_omitted` fixture (issue #407, §5.42). |

### Python (28 files, under `pkg/earthsci-ast-py/tests/`)

already shared 26 · migrated now 1 · deferred 1

| File | Disposition | Detail |
|---|---|---|
| `test_assertion_nonfinite_conformance.py` | **already shared** | Adapter over `tests/conformance/assertion_nonfinite/`. |
| `test_broadcast_and_index_alignment.py` | **migrated now** | Its §4.3.4 end-to-end value claims are now `tests/conformance/broadcast_alignment/` — `test_observed_expression_is_aligned_too` became the `observed_expression_aligned` fixture and `test_broadcast_end_to_end_matches_the_bare_operator` became `unary_broadcast_fn`. The file keeps its `validate()` ledger (the `invalid_broadcast_fn` reasons, the `array_shape_mismatch` record shape, the power-alias and elementwise-op questions it records as live cross-binding divergences) and its `eval_expr` / `align_expression` unit tests. |
| `test_build_once_spatial_field_conformance.py` | **already shared** | Adapter over `tests/conformance/build_once_spatial_field/`. |
| `test_discrete_materialize_conformance.py` | **already shared** | Adapter over `tests/conformance/discrete_materialize/`. |
| `test_elementwise_observed_gather_conformance.py` | **already shared** | Adapter over `tests/conformance/elementwise_observed_gather/`. |
| `test_faq_conformance.py` | **already shared** | Drives the shared `tests/valid/faq/*.esm`. |
| `test_faq_simulation.py` | **already shared** | Purely fixture-driven over shared documents with inline `tests` blocks — the census calls it the cleanest bucket-1 file in the tree, and it is already exactly the shape this phase is moving things INTO. |
| `test_loaded_ic_bc_simulation.py` | **already shared** | Drives the shared `pde_simulation_pipeline` document. |
| `test_merged_rename_reach_conformance.py` | **already shared** | Adapter over `tests/conformance/merged_rename_reach/`. |
| `test_mounted_component_tests.py` | **already shared** | Adapter over `tests/conformance/mounted_component_tests/`. |
| `test_pde_inline_array_overrides_conformance.py` | **already shared** | Adapter over `tests/conformance/pde_inline_array_overrides/`. |
| `test_pde_inline_dead_observed_conformance.py` | **already shared** | Adapter over `tests/conformance/pde_inline_dead_observed/`. |
| `test_pde_inline_ic_param_override_conformance.py` | **already shared** | Adapter over `tests/conformance/pde_inline_ic_param_override/`. |
| `test_pde_inline_observed_indexed_lhs_conformance.py` | **already shared** | Adapter over `tests/conformance/pde_inline_observed_indexed_lhs/`. |
| `test_pde_inline_observed_state_dependent_conformance.py` | **already shared** | Adapter over `tests/conformance/pde_inline_observed_state_dependent/`. |
| `test_pde_inline_reference_dimension_names_conformance.py` | **already shared** | Adapter over `tests/conformance/pde_inline_reference_dimension_names/`. |
| `test_pde_simulation_conformance.py` | **already shared** | Adapter over `tests/conformance/pde_simulation/` (§5.9), which the harness ALREADY runs as a producer stage for julia, rust and python. |
| `test_refresh_conformance.py` | **already shared** | Adapter over `tests/conformance/refresh/`. |
| `test_rhs_time_derivative_conformance.py` | **already shared** | Adapter over `tests/conformance/rhs_time_derivative/`. |
| `test_scalar_ic_conformance.py` | **already shared** | Adapter over `tests/conformance/scalar_ic/`. |
| `test_scoped_assertion_variable.py` | **already shared** | Drives the shared `scoped_assertion_variable` fixtures. |
| `test_shaped_observed_scalar_broadcast_conformance.py` | **already shared** | Adapter over `tests/conformance/shaped_observed_scalar_broadcast/`. |
| `test_shaped_parameter_broadcast_conformance.py` | **already shared** | Adapter over `tests/conformance/shaped_parameter_broadcast/`. |
| `test_simulate_algebraic.py` | **deferred** | Inline documents plus expected trajectories for ALGEBRAIC elimination. No twin in Julia or Rust, so it buys agreement rather than convergence; a natural second wave for the inline-test family once `analytic_trajectories` exists. Not started. |
| `test_simulation_fixtures_blocks.py` | **already shared** | Walks the shared `tests/simulation/*.esm` documents. |
| `test_static_evaluation_assertions_conformance.py` | **already shared** | Adapter over `tests/conformance/static_evaluation_assertions/` (§5.43). |
| `test_subsystem_loader_conformance.py` | **already shared** | Adapter over `tests/conformance/subsystem_loader/`. |
| `test_wildfire_simulation.py` | **already shared** | Drives the shared `tests/valid/wildfire_atmosphere_ocean.esm`. |
