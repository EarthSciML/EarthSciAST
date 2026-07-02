# ESM Format Compliance Validation Matrix

> **Reference Taxonomy**: This document catalogs testable requirements extracted from the
> ESM specifications. It is a static reference taxonomy, not a live verification report.
> For current test results, see CI artifacts.
>
> **Last manual audit**: May 2026

**Version**: 0.2.0
**Generated**: 2026-05-05
**Sources**: esm-spec.md, esm-libraries-spec.md

## Overview

This document provides a systematic extraction of all testable requirements from both the ESM Format Specification and ESM Libraries Specification. Each requirement is assigned a structured ID and categorized for mapping to specific test fixtures.

## Requirement ID Structure

Requirements use the format: `{CATEGORY}-{SECTION}-{SUBSECTION}-{NUMBER}`

Where:
- **CATEGORY**: SCHEMA, STRUCT, BEHAV, FORMAT, ALGO, VALID, DISPLAY
- **SECTION**: Two-digit section number from specs
- **SUBSECTION**: Single letter subsection identifier
- **NUMBER**: Three-digit requirement number

## Categories

- **SCHEMA**: JSON Schema validation requirements
- **STRUCT**: Structural consistency and integrity requirements
- **BEHAV**: Behavioral requirements (MUST/SHALL requirements)
- **FORMAT**: Field requirements and value constraints
- **ALGO**: Algorithmic specifications (ODE derivation, stoichiometric matrices)
- **VALID**: Validation API and error handling requirements
- **DISPLAY**: Pretty-printing and display format requirements

---

## 1. SCHEMA VALIDATION REQUIREMENTS

### SCHEMA-03-A: JSON Schema Compliance
| ID | Requirement | Spec Reference | Testable | Test Category |
|---|---|---|---|---|
| SCHEMA-03-A-001 | Library MUST validate ESM file against JSON Schema | esm-libraries-spec.md:153 | Yes | schema |
| SCHEMA-03-A-002 | Library MUST throw error on malformed JSON | esm-libraries-spec.md:63 | Yes | schema |
| SCHEMA-03-A-003 | Library MUST throw validation error on schema failures | esm-libraries-spec.md:64 | Yes | schema |
| SCHEMA-03-A-004 | Library MUST NOT silently accept invalid files | esm-libraries-spec.md:64 | Yes | schema |
| SCHEMA-03-A-005 | Library MUST use specified JSON Schema libraries | esm-libraries-spec.md:155-162 | Yes | schema |

---

## 2. STRUCTURAL VALIDATION REQUIREMENTS

### STRUCT-03-B: Equation-Unknown Balance
| ID | Requirement | Spec Reference | Testable | Test Category |
|---|---|---|---|---|
| STRUCT-03-B-001 | Count state variables (type "state") equals n_states | esm-libraries-spec.md:173 | Yes | structural |
| STRUCT-03-B-002 | Count equations with D(var,t) LHS equals n_odes | esm-libraries-spec.md:174 | Yes | structural |
| STRUCT-03-B-003 | MUST verify n_odes == n_states for each model | esm-libraries-spec.md:175 | Yes | structural |
| STRUCT-03-B-004 | MUST report variables lacking equations | esm-libraries-spec.md:175 | Yes | structural |
| STRUCT-03-B-005 | MUST report equations lacking state variables | esm-libraries-spec.md:175 | Yes | structural |

### STRUCT-03-C: Reference Integrity
| ID | Requirement | Spec Reference | Testable | Test Category |
|---|---|---|---|---|
| STRUCT-03-C-001 | Every variable reference MUST exist in model variables | esm-libraries-spec.md:185 | Yes | structural |
| STRUCT-03-C-002 | Every scoped reference MUST resolve via hierarchy | esm-libraries-spec.md:186 | Yes | structural |
| STRUCT-03-C-003 | Every discrete_parameters entry MUST match declared parameter | esm-libraries-spec.md:187 | Yes | structural |
| STRUCT-03-C-004 | Every coupling from/to MUST reference existing system | esm-libraries-spec.md:188 | Yes | structural |
| STRUCT-03-C-005 | Every operator_apply MUST reference existing operator | esm-libraries-spec.md:189 | Yes | structural |

### STRUCT-03-D: Event Consistency
| ID | Requirement | Spec Reference | Testable | Test Category |
|---|---|---|---|---|
| STRUCT-03-D-001 | Continuous event conditions MUST be expressions not booleans | esm-libraries-spec.md:193 | Yes | structural |
| STRUCT-03-D-002 | Discrete event conditions MUST produce boolean values | esm-libraries-spec.md:194 | Yes | structural |
| STRUCT-03-D-003 | Event affect variables MUST be declared | esm-libraries-spec.md:195 | Yes | structural |
| STRUCT-03-D-004 | Functional affect read_vars MUST reference declared variables | esm-libraries-spec.md:196 | Yes | structural |

### STRUCT-03-E: Reaction Consistency
| ID | Requirement | Spec Reference | Testable | Test Category |
|---|---|---|---|---|
| STRUCT-03-E-001 | Every species in substrates/products MUST be in species | esm-libraries-spec.md:200 | Yes | structural |
| STRUCT-03-E-002 | Stoichiometries MUST be positive integers | esm-libraries-spec.md:201 | Yes | structural |
| STRUCT-03-E-003 | No reaction MUST have both substrates and products null | esm-libraries-spec.md:202 | Yes | structural |
| STRUCT-03-E-004 | Rate expressions MUST only reference declared parameters/species | esm-libraries-spec.md:203 | Yes | structural |

---

## 3. BEHAVIORAL REQUIREMENTS

### BEHAV-02-A: Top-Level Structure
| ID | Requirement | Spec Reference | Testable | Test Category |
|---|---|---|---|---|
| BEHAV-02-A-001 | ESM MUST be language-agnostic | esm-spec.md:13 | Yes | behavioral |
| BEHAV-02-A-002 | Every model MUST be fully self-describing | esm-spec.md:13 | Yes | behavioral |
| BEHAV-02-A-003 | Conforming parser MUST reconstruct complete system from ESM alone | esm-spec.md:13 | Yes | behavioral |
| BEHAV-02-A-004 | At least one of models or reaction_systems MUST be present | esm-spec.md:51 | Yes | behavioral |

### BEHAV-04-A: Scoped References
| ID | Requirement | Spec Reference | Testable | Test Category |
|---|---|---|---|---|
| BEHAV-04-A-001 | Scoped references MUST follow dot notation hierarchy | esm-spec.md:156 | Yes | behavioral |
| BEHAV-04-A-002 | Final segment MUST be variable name | esm-spec.md:156 | Yes | behavioral |
| BEHAV-04-A-003 | Preceding segments MUST form valid system path | esm-spec.md:156 | Yes | behavioral |
| BEHAV-04-A-004 | Coupling entries MUST use fully qualified references | esm-spec.md:158 | Yes | behavioral |

### BEHAV-06-A: Model Specification
| ID | Requirement | Spec Reference | Testable | Test Category |
|---|---|---|---|---|
| BEHAV-06-A-001 | All models MUST be fully specified | esm-spec.md:450 | Yes | behavioral |
| BEHAV-06-A-002 | Every equation, variable, parameter MUST be present in ESM | esm-spec.md:450 | Yes | behavioral |

### BEHAV-04-B: Remote (URL) References — Optional Capability
| ID | Requirement | Spec Reference | Testable | Test Category |
|---|---|---|---|---|
| BEHAV-04-B-001 | URL/remote reference support is an OPTIONAL binding capability; a binding without it MUST reject a URL ref cleanly with the existing unresolved diagnostics (`template_import_unresolved` / subsystem-ref resolution error), never silently skip or misresolve | esm-spec.md §4.7, §9.7.2 | Yes | behavioral |
| BEHAV-04-B-002 | A binding that supports URL refs MUST resolve a URL-loaded document's own relative refs against its URL base (RFC 3986 joining) and canonicalize URL identity for cycle detection (dot segments removed, relative spellings joined) | esm-spec.md §4.7, §9.7.2 | Yes | behavioral |

### BEHAV-04-D: Subsystem-Mounted `index_sets` Merge (esm-spec §4.7)
| ID | Requirement | Spec Reference | Testable | Test Category |
|---|---|---|---|---|
| BEHAV-04-D-001 | A referenced subsystem file's top-level `index_sets` MUST merge into the importing document's document-scoped registry at resolution time, after the referenced document's metaparameters close and fold (§9.7.6 site 3 bindings, then defaults); names absent from the importer are added, deep-equal redeclaration is idempotent | esm-spec.md §4.7 | Yes | validation |
| BEHAV-04-D-002 | A non-deep-equal collision between a mounted file's index-set declaration and the importing document's registry MUST be rejected at load with `subsystem_index_set_conflict` (the subsystem-edge mirror of `template_import_index_set_conflict`, §9.7.5) | esm-spec.md §4.7, §9.6.6 | Yes | validation |

> **Binding status (2026-07-02)**: Julia implemented (`_merge_subsystem_index_sets!` in `parse.jl`, called from `_resolve_subsystem_ref` for every §4.7 subsystem edge, local and remote; fixtures `tests/valid/subsystem_mesh_lib.esm` + `tests/valid/subsystem_index_set_merge.esm`, `tests/invalid/template_imports/subsystem_index_set_conflict.esm`). **Pending port** — Python / Rust / TypeScript / Go must each: (1) at every subsystem-ref resolution, merge the loaded file's top-level `index_sets` (post-metaparameter-fold) into the importing document's registry; (2) treat deep-equal redeclaration as idempotent (structural equality over kind/size/members/of/offsets/values/from_faq); (3) reject non-equal collisions with the stable `subsystem_index_set_conflict` diagnostic; (4) drive the shared fixtures (schema-only bindings assert schema acceptance per `resolver_only`). Note: the Julia raw-level top-level-model `{ref}` inline path (`_inline_toplevel_model_refs!`) is a distinct mechanism and does not yet merge `index_sets`; it merges only `function_tables`/`data_loaders`/`enums`.
>
> **Go port (2026-07-03)**: implemented (`mergeSubsystemIndexSets` + `indexSetDeepEqual` in `subsystem_ref.go`; the importing document's `file.IndexSets` registry is threaded through `resolveSubsystemRefs`/`resolveSubsystemMap` and each mounted file's folded top-level `index_sets` merge in, transitively through nested mounts). `subsystem_index_set_merge.esm` loads with `vertices` merged in (size 4) and `cells` deep-equal-idempotent; `subsystem_index_set_conflict.esm` is rejected with `subsystem_index_set_conflict` (`go test ./...`).
> **TypeScript = implemented (2026-07-03)**: `mergeSubsystemIndexSets` in `packages/earthsci-toolkit/src/ref-loading.ts`, called from `resolveModelRefs` at every model subsystem-ref resolution with the importing document's `file.index_sets` threaded as the registry; deep-equal via `deepEqual` (numeric-literal-aware), non-equal collision → `subsystem_index_set_conflict`, absent name added. Matches the Julia reference (registry threaded only through the model walk, not reaction systems). The `subsystem_index_set_conflict.esm` fixture is rejected with the exact code (`src/template-imports.test.ts` invalid loop, via `resolveSubsystemRefs`).
> **Rust (2026-07-03)**: implemented (`earthsci-toolkit-rs/src/ref_loading.rs` —
> `merge_subsystem_index_sets` threaded through the model-subsystem walk via an
> `Option<&mut Map>` registry seeded from the importing document's own `index_sets`,
> written back post-merge; reaction-system subsystem refs thread `None`, matching the Julia
> scope; deep-equal via order-independent serde_json `Map` equality). Fixtures
> `subsystem_index_set_merge.esm` (+ `subsystem_mesh_lib.esm`) and
> `subsystem_index_set_conflict.esm` drive it (`template_imports_conformance`).

### BEHAV-04-C: `makearray` Region Bounds — Empty vs Inverted (esm-spec §4.3.2)
| ID | Requirement | Spec Reference | Testable | Test Category |
|---|---|---|---|---|
| BEHAV-04-C-001 | A `makearray` region bound pair `[start, start − 1]` is the canonical EMPTY bound: the region contributes no elements and its `values` entry is never consulted; the document MUST load cleanly (the §9.6.8 minimum-admissible-extent case, e.g. `[2, N−1]` folded at `N = 2`) | esm-spec.md §4.3.2, §9.6.8 | Yes | validation |
| BEHAV-04-C-002 | A `makearray` region bound pair with `stop < start − 1` on the expanded, metaparameter-folded form MUST be rejected at load with `makearray_region_inverted` (e.g. `[2, N−1]` folded at `N = 1`) | esm-spec.md §4.3.2, §9.6.6, §9.6.4 | Yes | validation |

> **Binding status (2026-07-02)**: Julia implemented (`_validate_makearray_regions`, both §9.6.4 validator sites in `lower_expression_templates.jl`; fixtures `tests/valid/makearray_empty_region_min_extent.esm`, `tests/invalid/template_imports/makearray_region_inverted.esm`). **Pending port** — Python / Rust / TypeScript / Go must each: (1) walk the expanded, folded tree's `makearray.regions`, skipping `expression_templates` blocks and non-integer (unfolded) bound entries; (2) accept `stop == start − 1` as empty; (3) reject `stop < start − 1` with the stable `makearray_region_inverted` diagnostic; (4) drive the two shared fixtures (schema-only bindings TS/Go assert schema acceptance per the `resolver_only` flag in `expected_errors.json`).
>
> **Go port (2026-07-03)**: implemented (`validateMakearrayRegions` + `asInt64Strict` in `lower_expression_templates.go`, run at both §9.6.4 validator sites — the no-machinery fast path and the post-fixpoint return). `makearray_empty_region_min_extent.esm` loads at default N=2 (empty bound `[2,1]`) and is rejected at N=1 (inverted `[2,0]`) with `makearray_region_inverted`; the shared invalid fixture is rejected (`go test ./...`).
> **TypeScript = implemented (2026-07-03)**: `validateMakearrayRegions` in `packages/earthsci-toolkit/src/lower_expression_templates.ts`, run on the expanded/folded form at both `lowerExpressionTemplates` validator sites (fast path + full path), skipping `expression_templates` and non-integer bounds. `makearray_empty_region_min_extent.esm` loads clean at default `N = 2` (interior folds to `[2, 1]`); the same file rebound `N = 1` (loader API) and `makearray_region_inverted.esm` are rejected with `makearray_region_inverted`. Tests in `src/expression-templates.test.ts` + the `src/template-imports.test.ts` invalid-fixture loop.
> **Rust (2026-07-03)**: implemented (`earthsci-toolkit-rs/src/lower_expression_templates.rs`
> — `validate_makearray_regions`, called at the end of `lower_expression_templates` after
> `validate_geometry_manifolds`; skips `expression_templates` and non-integer bounds, accepts
> `stop == start − 1`, rejects `stop < start − 1` with `makearray_region_inverted`). Fixtures
> `makearray_empty_region_min_extent.esm` (default N=2 loads; loader-API N=1 rejects) and
> `makearray_region_inverted.esm` (`template_imports_conformance`).

### BEHAV-08-A: Geometry-Op Operand Rings — Padding and Degenerate Vertices (esm-spec §8.6.1)
| ID | Requirement | Spec Reference | Testable | Test Category |
|---|---|---|---|---|
| BEHAV-08-A-001 | `intersect_polygon` / `polygon_intersection_area` operand rings MUST accept a closing duplicate final vertex and CONSECUTIVE duplicate vertices (rectangular-storage padding, e.g. an MPAS pentagon in a hexagon-shaped `[cells, NVERT, 2]` slot) and evaluate them as the deduplicated ring (point-equality tolerance atol 1e-8 / rtol 1e-5), equal to the same op over the already-distinct ring | esm-spec.md §8.6.1 | Yes | mathematical |
| BEHAV-08-A-002 | Deduplication MUST happen in the binding kernel's operand coercion BEFORE the backend clip (S2 rejects zero-length edges as degenerate; Sutherland–Hodgman treats them as no-ops — the op contract must not depend on the backend), and `intersect_polygon` MUST return its overlap ring as distinct vertices with implicit closure on every manifold | esm-spec.md §8.6.1, CONFORMANCE_SPEC §5.8.4 | Yes | mathematical |
| BEHAV-08-A-003 | A ring with fewer than 3 DISTINCT vertices after deduplication is a degenerate operand and MUST be rejected (the ≥3-distinct-vertices operand error) | esm-spec.md §8.6.1 | Yes | validation |

> **Binding status (2026-07-02)**: Julia implemented (`_as_ring` in `geometry.jl` now runs `_dedup_consecutive` on every operand before the planar/GeometryOps clip; empirically the planar and GeometryOps paths already tolerated padding with exactly-equal areas, but the spherical clip's OUTPUT retained the duplicates — dedup-at-coercion restores the distinct-vertex output contract; fixture `tests/valid/geometry/polygon_intersection_area_padded_ring.esm`, unit tests in `geometry_polygon_intersection_area_test.jl` incl. pentagon padded to 6/7 slots, planar + spherical). **Pending port** — **Python** (`geometry.py::_as_ring`): apply `_dedup_consecutive` (already defined for clip output) to operands before the clip — empirically REQUIRED for the spherely/S2 path, which rejects degenerate edges. **Rust** (`geometry.rs::intersect_polygon`): dedupe operands (allclose tolerance, wrap pair included) before `SphericalPolygon::from_lon_lat` — empirically the S2 path FAILS today on padded rings ("Edge N is degenerate (duplicate vertex)"), and the planar path passes padding through to its output ring; also dedupe the planar output. **TypeScript / Go**: schema-only, no geometry kernel — no action.
>
> **Rust (2026-07-03)**: DONE (`earthsci-toolkit-rs/src/geometry.rs` — `dedup_consecutive`
> + `as_ring` applied to both operands at the top of `intersect_polygon`, `dedup_consecutive`
> on the planar clip output, and dedup before `SphericalPolygon::from_lon_lat` in
> `spherical_area`; `<3` distinct after dedup rejects). Confirmed: the padded MPAS-style ring
> now clips in S2 (unit test `spherical_clip_accepts_padded_rings` — previously failed with
> the degenerate-edge error). Fixture `polygon_intersection_area_padded_ring.esm` simulates to
> area 1.0 via the `pde_conformance` example.

### BEHAV-06-B: Inline-Test Assertion Semantics (pinned §6.6.3/§6.6.5 conventions)
| ID | Requirement | Spec Reference | Testable | Test Category |
|---|---|---|---|---|
| BEHAV-06-B-001 | PDE assertions MUST select a scalar via `coords` or `reduce`; pointwise assertions are 0-D-only (validators reject the cross cases) | esm-spec.md §6.6.5 | Yes | simulation |
| BEHAV-06-B-002 | `coords` values are 1-based fractional INDEX-space positions along the named interval index sets; sampling picks the nearest grid index with exact half-way ties rounding down (`idx = ceil(c − 1/2)`); resolved index in `1..size` | esm-spec.md §6.6.3, §6.6.5 convention 1 | Yes | simulation |
| BEHAV-06-B-003 | `coords` may pin a strict subset of dimensions only when every remaining dimension resolves to a single sample | esm-spec.md §6.6.5 convention 1 | Yes | simulation |
| BEHAV-06-B-004 | `integral` reduce is the uniform-cell Riemann sum under unit total domain measure per axis (= `mean` over interval sets); the measure convention under which relative-L2 is measure-free | esm-spec.md §6.6.5 convention 2 | Yes | simulation |
| BEHAV-06-B-005 | `from_file` reference `path` resolves relative to the `.esm` file's directory; v1 `format` is `json` — a row-major nested array shape-validated against the field | esm-spec.md §6.6.5 convention 3 | Yes | simulation |
| BEHAV-06-B-006 | A `coords`/`reduce` assertion on a rank≥2 (multidimensional) array OBSERVED MUST materialize the field over the full Cartesian product of its interval index sets in row-major (lexicographic) cell order paired with the value layout, so all bindings agree. Julia: FIXED (`vec()` around the `CartesianIndices` cell sweep — a rank≥2 comprehension yields a Matrix that `sort!` rejected without `dims=`); Python (`np.ndindex`) and Rust (row-major `IxDyn` enumeration) were already rank-agnostic. Gate: `tests/conformance/pde_inline_observed_rank2/` (Julia/Python/Rust agree on the golden actuals) | esm-spec.md §6.6.5 convention 1 | Yes | simulation |

---

## 4. FORMAT REQUIREMENTS

### FORMAT-02-A: Required Fields - Top Level
| ID | Requirement | Spec Reference | Testable | Test Category |
|---|---|---|---|---|
| FORMAT-02-A-001 | esm field MUST be present | esm-spec.md:41 | Yes | format |
| FORMAT-02-A-002 | esm field MUST be semver format string | esm-spec.md:41 | Yes | format |
| FORMAT-02-A-003 | metadata field MUST be present | esm-spec.md:42 | Yes | format |

### FORMAT-05-A: Continuous Events
| ID | Requirement | Spec Reference | Testable | Test Category |
|---|---|---|---|---|
| FORMAT-05-A-001 | conditions field MUST be present | esm-spec.md:243 | Yes | format |
| FORMAT-05-A-002 | conditions MUST be array of expressions | esm-spec.md:243 | Yes | format |
| FORMAT-05-A-003 | affects field MUST be present | esm-spec.md:244 | Yes | format |
| FORMAT-05-A-004 | affects MUST be array of {lhs,rhs} objects | esm-spec.md:244 | Yes | format |

### FORMAT-05-B: Discrete Events
| ID | Requirement | Spec Reference | Testable | Test Category |
|---|---|---|---|---|
| FORMAT-05-B-001 | trigger field MUST be present | esm-spec.md:357 | Yes | format |
| FORMAT-05-B-002 | affects MUST be present unless functional_affect provided | esm-spec.md:358 | Yes | format |

### FORMAT-05-C: Functional Affects
| ID | Requirement | Spec Reference | Testable | Test Category |
|---|---|---|---|---|
| FORMAT-05-C-001 | handler_id field MUST be present | esm-spec.md:412 | Yes | format |
| FORMAT-05-C-002 | read_vars field MUST be present | esm-spec.md:413 | Yes | format |
| FORMAT-05-C-003 | read_params field MUST be present | esm-spec.md:414 | Yes | format |

### FORMAT-06-A: Model Fields
| ID | Requirement | Spec Reference | Testable | Test Category |
|---|---|---|---|---|
| FORMAT-06-A-001 | variables field MUST be present | esm-spec.md:563 | Yes | format |
| FORMAT-06-A-002 | equations field MUST be present | esm-spec.md:564 | Yes | format |

### FORMAT-07-A: Reaction System Fields
| ID | Requirement | Spec Reference | Testable | Test Category |
|---|---|---|---|---|
| FORMAT-07-A-001 | species field MUST be present | esm-spec.md:862 | Yes | format |
| FORMAT-07-A-002 | parameters field MUST be present | esm-spec.md:863 | Yes | format |
| FORMAT-07-A-003 | reactions field MUST be present | esm-spec.md:864 | Yes | format |

### FORMAT-07-B: Reaction Fields
| ID | Requirement | Spec Reference | Testable | Test Category |
|---|---|---|---|---|
| FORMAT-07-B-001 | id field MUST be present | esm-spec.md:874 | Yes | format |
| FORMAT-07-B-002 | substrates field MUST be present | esm-spec.md:876 | Yes | format |
| FORMAT-07-B-003 | products field MUST be present | esm-spec.md:877 | Yes | format |
| FORMAT-07-B-004 | rate field MUST be present | esm-spec.md:878 | Yes | format |

### FORMAT-08-A: Data Loader Fields
| ID | Requirement | Spec Reference | Testable | Test Category |
|---|---|---|---|---|
| FORMAT-08-A-001 | kind field MUST be present (`grid`, `points`, or `static`) | esm-spec.md §8.1 | Yes | format |
| FORMAT-08-A-002 | source field MUST be present with url_template | esm-spec.md §8.2 | Yes | format |
| FORMAT-08-A-003 | variables field MUST be present and non-empty | esm-spec.md §8.5 | Yes | format |
| FORMAT-08-A-004 | each variable MUST have file_variable and units | esm-spec.md §8.5 | Yes | format |
| FORMAT-08-A-005 | if spatial is present, crs and grid_type MUST be present | esm-spec.md §8.4 | Yes | format |

### FORMAT-09-A: Operator Fields
| ID | Requirement | Spec Reference | Testable | Test Category |
|---|---|---|---|---|
| FORMAT-09-A-001 | operator_id field MUST be present | esm-spec.md:1009 | Yes | format |
| FORMAT-09-A-002 | needed_vars field MUST be present | esm-spec.md:1012 | Yes | format |

---

## 5. ALGORITHMIC REQUIREMENTS

### ALGO-07-A: ODE Generation from Reactions
| ID | Requirement | Spec Reference | Testable | Test Category |
|---|---|---|---|---|
| ALGO-07-A-001 | Generate ODEs using standard mass action kinetics | esm-spec.md:883-897 | Yes | algorithmic |
| ALGO-07-A-002 | Rate law MUST be v = k · ∏ᵢ Sᵢ^nᵢ | esm-spec.md:887 | Yes | algorithmic |
| ALGO-07-A-003 | ODE contribution MUST be dX/dt += net_stoich_X · v | esm-spec.md:892 | Yes | algorithmic |
| ALGO-07-A-004 | net_stoich_X = (product stoich) - (substrate stoich) | esm-spec.md:895 | Yes | algorithmic |

### ALGO-04-A: derive_odes Function
| ID | Requirement | Spec Reference | Testable | Test Category |
|---|---|---|---|---|
| ALGO-04-A-001 | MUST provide derive_odes(reaction_system) → Model | esm-libraries-spec.md:330 | Yes | algorithmic |
| ALGO-04-A-002 | MUST generate ODE model from stoichiometry and rate laws | esm-libraries-spec.md:330 | Yes | algorithmic |

### ALGO-04-B: Stoichiometric Matrix
| ID | Requirement | Spec Reference | Testable | Test Category |
|---|---|---|---|---|
| ALGO-04-B-001 | MUST provide stoichiometric_matrix(reaction_system) → Matrix | esm-libraries-spec.md:331 | Yes | algorithmic |
| ALGO-04-B-002 | MUST compute net stoichiometric matrix | esm-libraries-spec.md:331 | Yes | algorithmic |

---

## 6. VALIDATION API REQUIREMENTS

### VALID-03-A: Validation Function
| ID | Requirement | Spec Reference | Testable | Test Category |
|---|---|---|---|---|
| VALID-03-A-001 | MUST expose validate(file: EsmFile) → ValidationResult | esm-libraries-spec.md:241 | Yes | validation |
| VALID-03-A-002 | ValidationResult MUST contain schema_errors | esm-libraries-spec.md:246 | Yes | validation |
| VALID-03-A-003 | ValidationResult MUST contain structural_errors | esm-libraries-spec.md:247 | Yes | validation |
| VALID-03-A-004 | ValidationResult MUST contain unit_warnings | esm-libraries-spec.md:248 | Yes | validation |
| VALID-03-A-005 | ValidationResult MUST contain is_valid boolean | esm-libraries-spec.md:249 | Yes | validation |

### VALID-03-B: Error Codes
| ID | Requirement | Spec Reference | Testable | Test Category |
|---|---|---|---|---|
| VALID-03-B-001 | MUST use equation_count_mismatch code | esm-libraries-spec.md:276 | Yes | validation |
| VALID-03-B-002 | MUST use undefined_variable code | esm-libraries-spec.md:277 | Yes | validation |
| VALID-03-B-003 | MUST use undefined_species code | esm-libraries-spec.md:278 | Yes | validation |
| VALID-03-B-004 | MUST use undefined_parameter code | esm-libraries-spec.md:279 | Yes | validation |
| VALID-03-B-005 | MUST use undefined_system code | esm-libraries-spec.md:280 | Yes | validation |
| VALID-03-B-006 | MUST use undefined_operator code | esm-libraries-spec.md:281 | Yes | validation |
| VALID-03-B-007 | MUST use unresolved_scoped_ref code | esm-libraries-spec.md:282 | Yes | validation |
| VALID-03-B-008 | MUST use invalid_discrete_param code | esm-libraries-spec.md:283 | Yes | validation |
| VALID-03-B-009 | MUST use null_reaction code | esm-libraries-spec.md:284 | Yes | validation |
| VALID-03-B-010 | MUST use missing_observed_expr code | esm-libraries-spec.md:285 | Yes | validation |
| VALID-03-B-011 | MUST use event_var_undeclared code | esm-libraries-spec.md:286 | Yes | validation |

---

## 7. DISPLAY FORMAT REQUIREMENTS

### DISPLAY-06-A: Unicode Display
| ID | Requirement | Spec Reference | Testable | Test Category |
|---|---|---|---|---|
| DISPLAY-06-A-001 | MUST use element-aware tokenizer for chemical subscripts | esm-libraries-spec.md:1453 | Yes | display |
| DISPLAY-06-A-002 | MUST recognize 118 chemical element symbols | esm-libraries-spec.md:1458 | Yes | display |
| DISPLAY-06-A-003 | MUST convert trailing digits to Unicode subscripts | esm-libraries-spec.md:1459 | Yes | display |
| DISPLAY-06-A-004 | O3 MUST render as O₃ | esm-libraries-spec.md:1465 | Yes | display |
| DISPLAY-06-A-005 | NO2 MUST render as NO₂ | esm-libraries-spec.md:1466 | Yes | display |
| DISPLAY-06-A-006 | CH2O MUST render as CH₂O | esm-libraries-spec.md:1467 | Yes | display |

### DISPLAY-06-B: Number Formatting
| ID | Requirement | Spec Reference | Testable | Test Category |
|---|---|---|---|---|
| DISPLAY-06-B-001 | Integers MUST use plain format | esm-libraries-spec.md:1479 | Yes | display |
| DISPLAY-06-B-002 | 1-4 sig digits MUST use decimal notation | esm-libraries-spec.md:1481 | Yes | display |
| DISPLAY-06-B-003 | |value| < 0.01 or ≥ 10000 MUST use scientific notation | esm-libraries-spec.md:1482 | Yes | display |
| DISPLAY-06-B-004 | Scientific notation MUST use Unicode superscripts | esm-libraries-spec.md:1482 | Yes | display |

### DISPLAY-06-C: Operator Display
| ID | Requirement | Spec Reference | Testable | Test Category |
|---|---|---|---|---|
| DISPLAY-06-C-001 | D(x,t) MUST render as ∂x/∂t | esm-libraries-spec.md:1491 | Yes | display |
| DISPLAY-06-C-002 | grad(x,y) MUST render as ∂x/∂y | esm-libraries-spec.md:1492 | Yes | display |
| DISPLAY-06-C-003 | a * b MUST render as a·b | esm-libraries-spec.md:1493 | Yes | display |
| DISPLAY-06-C-004 | -a (unary) MUST render as −a with minus sign | esm-libraries-spec.md:1494 | Yes | display |

### DISPLAY-06-D: LaTeX Display
| ID | Requirement | Spec Reference | Testable | Test Category |
|---|---|---|---|---|
| DISPLAY-06-D-001 | MUST use standard LaTeX math conventions | esm-libraries-spec.md:1508 | Yes | display |
| DISPLAY-06-D-002 | Fractions MUST use \frac{}{} | esm-libraries-spec.md:1510 | Yes | display |
| DISPLAY-06-D-003 | Derivatives MUST use \frac{\partial}{\partial t} | esm-libraries-spec.md:1510 | Yes | display |
| DISPLAY-06-D-004 | Species names MUST use \mathrm{} | esm-libraries-spec.md:1511 | Yes | display |

---

## 8. EXPRESSION ENGINE REQUIREMENTS

### EXPR-02-A: Construction
| ID | Requirement | Spec Reference | Testable | Test Category |
|---|---|---|---|---|
| EXPR-02-A-001 | MUST support programmatic expression building | esm-libraries-spec.md:99 | Yes | expression |
| EXPR-02-A-002 | MUST parse from ESM JSON Expression type | esm-libraries-spec.md:100 | Yes | expression |

### EXPR-02-B: Substitution
| ID | Requirement | Spec Reference | Testable | Test Category |
|---|---|---|---|---|
| EXPR-02-B-001 | MUST support variable → constant substitution | esm-libraries-spec.md:128 | Yes | expression |
| EXPR-02-B-002 | MUST support variable → expression substitution | esm-libraries-spec.md:129 | Yes | expression |
| EXPR-02-B-003 | MUST support placeholder → variable substitution | esm-libraries-spec.md:130 | Yes | expression |
| EXPR-02-B-004 | Substitution MUST be recursive | esm-libraries-spec.md:133 | Yes | expression |
| EXPR-02-B-005 | MUST handle hierarchical scoped references | esm-libraries-spec.md:133 | Yes | expression |

### EXPR-02-C: Structural Operations
| ID | Requirement | Spec Reference | Testable | Test Category |
|---|---|---|---|---|
| EXPR-02-C-001 | MUST provide free_variables(expr) → Set<string> | esm-libraries-spec.md:137 | Yes | expression |
| EXPR-02-C-002 | MUST provide contains(expr, var) → bool | esm-libraries-spec.md:139 | Yes | expression |
| EXPR-02-C-003 | MUST provide evaluate(expr, bindings) → number | esm-libraries-spec.md:141 | Yes | expression |
| EXPR-02-C-004 | evaluate MUST error on unbound variables | esm-libraries-spec.md:141 | Yes | expression |
| EXPR-02-C-005 | simplify MUST fold constant arithmetic | esm-libraries-spec.md:140 | Yes | expression |

### EXPR-09-A: `expression_templates` Block (v0.4.0, esm-spec §9.6)
| ID | Requirement | Spec Reference | Testable | Test Category |
|---|---|---|---|---|
| EXPR-09-A-001 | `expression_templates` MUST be declared inside a single model or reaction_system, or at top level of a template-library file (§9.7.1) | esm-spec.md §9.6.1, §9.7.1 | Yes | expression |
| EXPR-09-A-002 | Each entry MUST declare a `params` array (possibly empty; no duplicates; entries non-empty strings) | esm-spec.md §9.6.1 | Yes | expression |
| EXPR-09-A-003 | Each entry MUST declare a fixed Expression AST `body` | esm-spec.md §9.6.1 | Yes | expression |
| EXPR-09-A-004 | Template-body `apply_expression_template` references MUST form an acyclic DAG over match-less in-scope templates, inlined at registration time (depth ≤ 32) | esm-spec.md §9.6.3, §9.7.3 | Yes | expression |

### EXPR-09-B: `apply_expression_template` Op
| ID | Requirement | Spec Reference | Testable | Test Category |
|---|---|---|---|---|
| EXPR-09-B-001 | `apply_expression_template` `name` MUST reference a match-less template declared in or imported into the same component | esm-spec.md §9.6.2, §9.7.2 | Yes | expression |
| EXPR-09-B-002 | `bindings` MUST exactly match the template's `params` (no missing or extra keys) | esm-spec.md §9.6.2 | Yes | expression |
| EXPR-09-B-003 | Loaders MUST expand `apply_expression_template` to a fully-substituted AST at load time | esm-spec.md §9.6.4 | Yes | expression |
| EXPR-09-B-004 | After expansion the AST MUST be structurally identical to inline-authored equivalent | esm-spec.md §9.6.4 | Yes | expression |
| EXPR-09-B-005 | Round-trip `parse → emit` MUST emit the expanded form (Option A always-expanded) | esm-spec.md §9.6.4 | Yes | expression |

### EXPR-09-C: Diagnostics
| ID | Requirement | Spec Reference | Testable | Test Category |
|---|---|---|---|---|
| EXPR-09-C-001 | `apply_expression_template_version_too_old` when `esm` < 0.4.0 uses either construct | esm-spec.md §9.6.5 | Yes | validation |
| EXPR-09-C-002 | `apply_expression_template_unknown_template` for unresolved `name` | esm-spec.md §9.6.6 | Yes | validation |
| EXPR-09-C-003 | `apply_expression_template_bindings_mismatch` for missing/extra binding keys | esm-spec.md §9.6.6 | Yes | validation |
| EXPR-09-C-004 | `apply_expression_template_recursive_body` on a cyclic (self or mutual) template-body reference | esm-spec.md §9.6.6, §9.7.3 | Yes | validation |
| EXPR-09-C-005 | `apply_expression_template_invalid_declaration` for malformed `params`/`body` | esm-spec.md §9.6.6 | Yes | validation |

### EXPR-09-D: Conformance Fixtures
| ID | Requirement | Spec Reference | Test Fixture | Test Category |
|---|---|---|---|---|
| EXPR-09-D-001 | Load + re-serialize of arrhenius template yields canonical expanded AST | esm-spec.md §9.6.7 | `tests/conformance/expression_templates/arrhenius_smoke/fixture.esm` → `expanded.esm` | expression |
| EXPR-09-D-002 | All five bindings MUST agree byte-for-byte after canonical serialization | esm-spec.md §9.6.7 | `tests/conformance/expression_templates/arrhenius_smoke/` | expression |

### EXPR-09-E: Template Libraries, Imports, and Metaparameters (esm-spec §9.7)
| ID | Requirement | Spec Reference | Testable | Test Category |
|---|---|---|---|---|
| EXPR-09-E-001 | A template-library file (top-level `expression_templates`, no models/reaction_systems/data_loaders/coupling/domain) MUST load as a valid ESM document | esm-spec.md §9.7.1 | Yes | validation |
| EXPR-09-E-002 | `expression_template_imports` MUST resolve at load, before validation, with §4.7 reference formats and canonical-path cycle detection (`template_import_cycle`) | esm-spec.md §9.7.2 | Yes | validation |
| EXPR-09-E-003 | Importing a non-library file is `template_import_not_library`; a subsystem `ref` targeting a library file is `subsystem_ref_is_template_library` | esm-spec.md §9.7.1 | Yes | validation |
| EXPR-09-E-004 | Effective declaration order MUST be depth-first post-order over the import DAG; deep-equal diamond duplicates dedup; non-equal same-name collisions are `template_import_name_conflict` | esm-spec.md §9.7.4 | Yes | expression |
| EXPR-09-E-005 | Imported top-level `index_sets` MUST merge into the importing document's registry (deep-equal idempotent; else `template_import_index_set_conflict`) | esm-spec.md §9.7.5 | Yes | validation |
| EXPR-09-E-006 | `only` MUST filter importer-visible templates; unknown names are `template_import_unknown_name` | esm-spec.md §9.7.2 | Yes | validation |
| EXPR-09-E-007 | Metaparameter expressions in `index_sets.size`, dense `ranges`, and `regions` MUST fold to concrete integers at load (exact arithmetic; inexact `/` or 64-bit overflow is `metaparameter_type_error`) | esm-spec.md §9.7.6 | Yes | expression |
| EXPR-09-E-008 | Metaparameter names in expression positions MUST substitute as integer literals with no further folding | esm-spec.md §9.7.6 | Yes | expression |
| EXPR-09-E-009 | Binding precedence MUST be: import/subsystem edge → re-export upward → loader API (root) → defaults; still-open is `metaparameter_unbound` | esm-spec.md §9.7.6 | Yes | validation |
| EXPR-09-E-010 | `load()` MUST accept root-document metaparameter bindings (name → integer) | esm-libraries-spec.md §2.1c | Yes | api |
| EXPR-09-E-011 | Files declaring `esm` < 0.8.0 carrying any §9.7 construct MUST be rejected with `template_import_version_too_old` | esm-spec.md §9.6.5 | Yes | validation |
| EXPR-09-E-012 | Round-trip MUST emit the expanded, folded form; no §9.7 construct survives `parse → emit` | esm-spec.md §9.7.6 | Yes | serialization |
| EXPR-09-E-013 | All five bindings MUST produce byte-identical post-lowering canonical ASTs for `import_smoke`, `import_diamond`, `import_order_determinism`, `metaparameter_resolutions` | esm-spec.md §9.6.7 | `tests/conformance/expression_templates/import_*` | expression |

### EXPR-09-F: Import Renaming, Namespacing, and Free-Name Rebinding (esm-spec §9.7.7)

> **Binding status**: Julia (reference) = implemented; Python / Rust / Go =
> pending port (wave 2 of RFC `docs/content/rfcs/template-import-renaming.md` §10).
>
> **Go port (2026-07-03)**: implemented in `packages/esm-format-go/pkg/esm/template_imports.go`
> (`applyEdgeRenames` + `renameWalk`/`renameDecl`/`nameMap`/`collectBoundSyms`/`collectRefNames`,
> called from `resolveImportEntry` after `only` filtering, before the §9.7.4/§9.7.5 merge).
> Goldens `import_rename_two_instances`, `import_rebind_keyed_factors`, `import_rename_diamond`
> byte-identical; `rename_unknown_name` / `rebind_unknown_free_name` / `rename_collision` /
> `rename_invalid_identifier` raise the mapped diagnostics (`go test ./...`).
> **TypeScript = implemented (2026-07-03)**: `applyEdgeRenames` + `renameWalk` /
> `renameDecl` / `nameMap` / `collectBoundSyms` / `collectRefNames` in
> `packages/earthsci-toolkit/src/template_imports.ts`, called from
> `resolveImportEntry` after `bindings`/`only` and before the merge; `where` added
> to `META_SUBST_SKIP_KEYS`. Byte-identity (via `toEqual`) confirmed against the
> Julia goldens for `import_rename_two_instances`, `import_rebind_keyed_factors`,
> `import_rename_diamond`; the four invalid fixtures raise the exact codes
> (`rename_unknown_name`, `rebind_unknown_free_name`, `rename_collision`,
> `rename_invalid_identifier`). Tests in `src/template-imports.test.ts`.
> **Rust (2026-07-03)**: implemented (`earthsci-toolkit-rs/src/template_imports.rs` —
> `apply_edge_renames` + `name_map`/`rename_walk`/`rename_decl`/`collect_bound_syms`/
> `collect_ref_names`, `is_valid_dotted_name`, `RENAME_AXIS_KEYS`/`RENAME_EXTRA_PROTECTED_KEYS`,
> `where` added to `META_SUBST_SKIP_KEYS`; called from `resolve_import_entry` after
> `only` filtering). Byte-identical goldens for `import_rename_two_instances`,
> `import_rebind_keyed_factors`, `import_rename_diamond` (EXPR-09-F-008), verified via
> the `canonical_expand` example and the `template_imports_conformance` suite. AST byte
> identity for full-precision float literals also required the serde_json `float_roundtrip`
> feature (default fast path was 1 ulp off on some 16-17-digit literals).

| ID | Requirement | Spec Reference | Testable | Test Category |
|---|---|---|---|---|
| EXPR-09-F-001 | Edge pipeline order MUST be: target's own-scope resolution → `bindings` → `only` → `prefix`/`rename`/`rebind` → merge; `only`/`bindings`/`rename`/`rebind` speak the target's export vocabulary (pre this edge's rename) | esm-spec.md §9.7.7 | Yes | expression |
| EXPR-09-F-002 | `prefix` MUST rename every surviving exported name without an explicit `rename` entry to `<prefix>.<name>`; `rename` entries override; prefixes nest through re-export chains (deeper edges and the loader API bind the renamed, dotted names) | esm-spec.md §9.7.7 | Yes | expression |
| EXPR-09-F-003 | Renames MUST apply transitively through the pinned occurrence sites: index-set registry keys / registry `of` / `{"from"}` refs / `wrt`-`dim` scalar fields in `body` AND `match` (param-shadowed); metaparameter keys / expression-position bare strings / structural-site names; template keys / `apply_expression_template.name` | esm-spec.md §9.7.7 | Yes | expression |
| EXPR-09-F-004 | `rebind` MUST rewrite free variable names in bodies/matches (incl. `aggregate` `args` and `index` gathers) and ragged `offsets`/`values`; dotted targets are §4.6 scoped references | esm-spec.md §9.7.7 | Yes | expression |
| EXPR-09-F-005 | Renaming a name the target does not export at the edge is `template_import_rename_unknown_name`; rebinding a non-occurring or declared name is `template_import_rebind_unknown_name`; rebinding a bound index symbol is `template_import_rename_invalid` | esm-spec.md §9.7.7 | Yes | validation |
| EXPR-09-F-006 | Post-rename names MUST be unique per namespace and new bare names fresh (no capture of free names, bound symbols, or params): `template_import_rename_collision`; `prefix`/targets MUST be dotted identifiers: `template_import_rename_invalid` | esm-spec.md §9.7.7 | Yes | validation |
| EXPR-09-F-007 | Same file under different renames = distinct registrations (no deep-equal dedup across renames); identical `ref` + instantiation + renames = dedupe at first occurrence; renamed `match`-rule instances register at their edges' §9.7.4 positions and identical patterns tie-break by that order | esm-spec.md §9.7.4, §9.7.7 | Yes | expression |
| EXPR-09-F-008 | All five bindings MUST produce byte-identical post-lowering canonical ASTs for `import_rename_two_instances`, `import_rebind_keyed_factors`, `import_rename_diamond` | esm-spec.md §9.6.7 | `tests/conformance/expression_templates/import_rename_*`, `import_rebind_*` | expression |

### EXPR-09-G: Match-Pattern Scoping Constraints (`where`, esm-spec §9.6.1; RFC match-pattern-scoping-constraints)

> Binding status: Julia reference implementation landed (2026-07); Python / Rust /
> TypeScript / Go ports pending (wave 2 — RFC §10 porting checklist).
>
> **Go port (2026-07-03)**: implemented in `packages/esm-format-go/pkg/esm/lower_expression_templates.go`
> (`componentShapeEnv` / `whereSatisfied` / `registeredWhere`, threaded through `matchRule.whereC`
> and `rewritePass`/`rewriteToFixpoint`; `where` structural checks in `validateTemplates`; `where`
> added to `metaSubstSkipKeys`). Goldens `constrained_match_scope`, `two_div_two_meshes`,
> `per_variable_scheme_literal_args` byte-identical (models.m.variables); `constraint_unknown_index_set`
> raises `template_constraint_unknown_index_set` (`go test ./...`).
> **TypeScript = implemented (2026-07-03)**: `where` structural validation in
> `validateTemplates`, plus `componentShapeEnv` / `whereSatisfied` /
> `registeredWhere` and the `whereConstraint`/`shapeEnv` threading through the
> §9.6.3 engine (`onePass` / `rewriteToFixpoint`) in
> `packages/earthsci-toolkit/src/lower_expression_templates.ts`; `where` added to
> `META_SUBST_SKIP_KEYS` (G-008). Byte-identity confirmed for
> `constrained_match_scope`, `two_div_two_meshes`, `per_variable_scheme_literal_args`;
> `constraint_unknown_index_set` rejected at load with
> `template_constraint_unknown_index_set`. The two non-fixture pins
> (filter-before-priority, compound-arg-conservative) are unit-tested. Tests in
> `src/expression-templates.test.ts`.
> **Rust (2026-07-03)**: implemented (`earthsci-toolkit-rs/src/lower_expression_templates.rs`
> — `where` structural validation in `validate_templates`, `component_shape_env`,
> `registered_where` (`template_constraint_unknown_index_set` against the document
> `index_sets` registry), `where_satisfied` checked as match eligibility in `rewrite_pass`,
> `MatchRule.where_c`). Goldens `constrained_match_scope`, `two_div_two_meshes`,
> `per_variable_scheme_literal_args` match and `constraint_unknown_index_set` rejects at load
> (EXPR-09-G-009), via the `expression_templates_conformance` suite.

| ID | Requirement | Spec Reference | Testable | Test Category |
|---|---|---|---|---|
| EXPR-09-G-001 | A `match` rule MAY declare `where` constraints on captured params; `where` without `match`, a non-param key, an unknown constraint kind (v1: exactly `shape`), or an empty/non-string `shape` list is `apply_expression_template_invalid_declaration` | esm-spec.md §9.6.1, §9.6.6 | Yes | validation |
| EXPR-09-G-002 | A `shape` constraint is satisfied iff the bound sub-AST is a bare variable reference declared in the enclosing component with exactly that `shape` (same index-set names, same order); compound sub-ASTs, literals, scoped references, undeclared names, and scalars fail | esm-spec.md §9.6.1 | Yes | expression |
| EXPR-09-G-003 | Constraint evaluation MUST be fully static (declared shapes at lowering time, never runtime values); fixpoints remain byte-identical across bindings | esm-spec.md §9.6.1, §9.6.3 | Yes | expression |
| EXPR-09-G-004 | Constraints filter as part of match ELIGIBILITY, before the priority/declaration-order selection: a constraint-excluded rule never shadows a lower-priority rule that fires | esm-spec.md §9.6.3 | Yes | expression |
| EXPR-09-G-005 | Constraint index-set names MUST resolve against the consuming document's merged `index_sets` registry at rule registration; unknown names are `template_constraint_unknown_index_set` | esm-spec.md §9.6.1, §9.6.6 | Yes | validation |
| EXPR-09-G-006 | A constrained rule that never fires is NOT an error; a rewrite-target left un-lowered by constraint exclusion is caught by the ordinary `unlowered_operator` gate | esm-spec.md §9.6.1, §9.6.8 | Yes | expression |
| EXPR-09-G-007 | A non-parameter string in a `match` `args` position is a literal matching only that exact bare variable reference (the sanctioned per-variable selector) | esm-spec.md §9.6.1, §9.6.8 | Yes | expression |
| EXPR-09-G-008 | Metaparameter substitution MUST NOT rewrite `where` contents (structural field) | esm-spec.md §9.6.1, §9.7.6 | Yes | expression |
| EXPR-09-G-009 | Bindings MUST agree on the goldens for `constrained_match_scope`, `two_div_two_meshes`, `per_variable_scheme_literal_args` and reject `constraint_unknown_index_set` at load | esm-spec.md §9.6.7 | `tests/conformance/expression_templates/constrained_match_scope/` etc. | expression |

---

## 9. ROUND-TRIP AND SERIALIZATION

### SERIAL-07-A: Round-Trip Requirements
| ID | Requirement | Spec Reference | Testable | Test Category |
|---|---|---|---|---|
| SERIAL-07-A-001 | load(save(load(file))) MUST equal load(file) | esm-libraries-spec.md:1604 | Yes | serialization |
| SERIAL-07-A-002 | JSON key ordering differences are acceptable | esm-libraries-spec.md:1604 | Yes | serialization |
| SERIAL-07-A-003 | Parsed data model MUST be identical after round-trip | esm-libraries-spec.md:1604 | Yes | serialization |

### SERIAL-02-A: Serialization Requirements
| ID | Requirement | Spec Reference | Testable | Test Category |
|---|---|---|---|---|
| SERIAL-02-A-001 | MUST convert expression tree to ESM JSON | esm-libraries-spec.md:144 | Yes | serialization |
| SERIAL-02-A-002 | Output MUST validate against schema | esm-libraries-spec.md:145 | Yes | serialization |
| SERIAL-02-A-003 | MUST round-trip identically | esm-libraries-spec.md:145 | Yes | serialization |

---

## 10. VERSIONING REQUIREMENTS

### VERSION-08-A: Schema Version Handling
| ID | Requirement | Spec Reference | Testable | Test Category |
|---|---|---|---|---|
| VERSION-08-A-001 | MUST reject unsupported major versions | esm-libraries-spec.md:1617 | Yes | versioning |
| VERSION-08-A-002 | MUST accept backward compatible minor versions | esm-libraries-spec.md:1618 | Yes | versioning |
| VERSION-08-A-003 | MUST warn on higher minor versions | esm-libraries-spec.md:1620 | Yes | versioning |
| VERSION-08-A-004 | MUST skip schema validation for newer minor versions | esm-libraries-spec.md:1620 | Yes | versioning |

---

## Summary Statistics

| Category | Total Requirements | Testable Requirements | Test Categories |
|---|---|---|---|
| Schema | 5 | 5 | schema |
| Structural | 20 | 20 | structural |
| Behavioral | 10 | 10 | behavioral |
| Format | 20 | 20 | format |
| Algorithmic | 6 | 6 | algorithmic |
| Validation | 21 | 21 | validation |
| Display | 17 | 17 | display |
| Expression | 25 | 25 | expression |
| Serialization | 6 | 6 | serialization |
| Versioning | 4 | 4 | versioning |
| **TOTAL** | **134** | **134** | **10 categories** |

## Test Fixture Mapping

Each requirement can be mapped to specific test fixtures:

### Priority 1 (Phase 1 Foundation)
- **schema**: Tests in `tests/invalid/` for schema validation
- **format**: Tests for required field presence
- **behavioral**: Tests for self-describing models
- **serialization**: Round-trip tests with `tests/valid/`

### Priority 2 (Phase 2 Analysis)
- **structural**: Tests in `tests/invalid/` for reference integrity
- **validation**: Error code validation tests
- **algorithmic**: ODE derivation and stoichiometric matrix tests
- **expression**: Expression manipulation tests, plus v0.4.0 expression-template
  conformance under `tests/conformance/expression_templates/` (e.g.
  `arrhenius_smoke/fixture.esm` ↔ `arrhenius_smoke/expanded.esm` for
  load-time expansion of `apply_expression_template`)

### Priority 3 (Phase 3+ Advanced)
- **display**: Pretty-printing format tests in `tests/display/`
- **versioning**: Version compatibility tests

### v0.4.0 Conformance Fixture Inventory

The cross-language `tests/conformance/` tree drives byte-equal cross-binding
agreement for v0.4.0 features:

| Directory | Feature | Notes |
|---|---|---|
| `tests/conformance/canonical/` | Canonical AST equality | Drives `parse → canonical-AST` agreement across bindings |
| `tests/conformance/geometry/` | Conservative-regridding geometry (`intersect_polygon` + `polygon_area` aggregate) | CONFORMANCE_SPEC §5.8 |
| `tests/conformance/expression_templates/` | `expression_templates` + `apply_expression_template` (esm-spec §9.6) | Indexed by EXPR-09-D above |
| `tests/conformance/function_tables/` | `function_tables` + `table_lookup` (esm-spec §9.5) | `linear/`, `bilinear/`, `roundtrip/` |
| `tests/conformance/determinism/` | Build-time relational engine determinism (distinct/skolem/rank/join) | CONFORMANCE_SPEC §5.5 |
| `tests/conformance/migration/` | Schema-version migration | Pairs with VERSION-08-A above |
| `tests/conformance/round_trip/` | Round-trip equality (esm-spec §9.6.4 Option A) | Pairs with SERIAL-07-A above |
| `tests/conformance/simulate_cycles/` | End-to-end simulation cycles via official ESS runners | Per CLAUDE.md "Simulation Pathway" rule |

## Usage

This matrix should be used to:

1. **Create test fixtures**: Each requirement maps to specific test cases
2. **Validate library implementations**: Ensure all requirements are covered
3. **Track compliance**: Use requirement IDs to track implementation status
4. **Generate conformance tests**: Automate test generation from requirements
5. **Cross-language validation**: Ensure consistent behavior across implementations

## Notes

- All 118 requirements are testable through automated test suites
- Requirements are extracted directly from canonical specification documents
- Each requirement includes precise spec reference for traceability
- Test categories align with the proposed conformance test suite structure
- Priority levels guide implementation phases across all target languages