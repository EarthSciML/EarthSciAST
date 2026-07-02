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