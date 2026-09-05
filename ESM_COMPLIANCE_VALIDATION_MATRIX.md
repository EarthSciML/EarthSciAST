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

### BEHAV-04-G: Evaluable-Core Operator Coverage (esm-spec §4.2)
| ID | Requirement | Spec Reference | Testable | Test Category |
|---|---|---|---|---|
| BEHAV-04-G-001 | `{"op": "true"}` is a nullary boolean LITERAL, not a form op awaiting a lowering pass: an evaluator MUST produce the true value for it (1.0 under the 0/1 convention every comparison and `and`/`or`/`not` already uses), so `aggregate{expr: true}` — the semi-join spelling — COUNTS the admitted tuples | esm-spec.md §4.2 (op table), CONFORMANCE_SPEC.md §5.5.8 | Yes | behavioral |
| BEHAV-04-G-002 | A §4.2 evaluable-core op the evaluator has NO rule for (`skolem`, `rank`, `distinct`, `argmin`, `argmax`, `ic`, `enum`, `table_lookup`, `apply_expression_template`) MUST be refused with a diagnostic naming it — never a panic, never a NaN. The refusal belongs at BUILD, at the funnel every run passes through, not at each evaluator entry point | esm-spec.md §4.2, §9.6.8 | Yes | validation |
| BEHAV-04-G-003 | The one carve-out: `ic` is legal as an equation LHS (§11.4) — initial-condition assembly reads the equation and the evaluator never sees the node — so the gate MUST unwrap an `ic` LHS and check its operand instead of rejecting it | esm-spec.md §11.4, §4.2 | Yes | validation |

> **Binding status (2026-09-01)**: **Rust** was the only binding that could not evaluate
> `true`: `eval_op`'s backstop for an ungated op is `unreachable!` (chosen over the silent
> NaN it replaced), and `hoist_static_observeds` reached the evaluator without calling
> `check_evaluable`, so a document that `esm validate` had just passed exited 101 with a
> panic. **Python** (`numpy_interpreter.py`: `if op == "true": return 1.0`) and **Julia**
> (`tree_walk/geometry_compile.jl`: a 1.0 literal node) already answered, as did Rust's own
> `value_invention::vi_eval` (`Val::Bool(true)`) — so -001 was a Rust-local divergence from
> a rule the peers had already settled, and the fix aligns it. -002 is the class the panic
> text implies: six of the nine ops above reached the same backstop, verified by running
> them against the un-gated build. Fixed by widening `simulate_array/compile.rs` stage (0)
> from `check_no_spatial_ops` to the full `check_evaluable`; the remaining three
> (`skolem`, `argmin`, `argmax`) are refused earlier, in the value-invention stage's own
> vocabulary. Gates: `earthsci-ast-rs/tests/evaluable_core_gate.rs` plus
> `eval.rs::the_true_literal_evaluates_to_one` and
> `the_core_minus_evaluable_gap_is_exactly_nine_ops`, which pins the gap member by member
> so a tenth op arriving without a rule fails a test instead of panicking at an author.
>
> **Cross-binding notes, reported not fixed.** (a) Python and Julia both also evaluate
> `{"op": "false"}` → 0.0, and Rust's `value_invention` does too, but `false` is in NO
> binding's core-op ARITY registry and is absent from the §4.2 op table — so a document
> spelling it is rejected as an unlowered rewrite target by the very bindings that would
> evaluate it. Either the spec table gains `false` beside `true` or the three evaluators
> should drop it; it is a spec question, not a binding bug. (b) Peer bindings should audit
> their own core-set-minus-evaluable gap the way -002 does: the failure mode is a panic or
> a NaN on a schema-valid document, and only an enumerated gap makes it visible.

### BEHAV-04-G: Causal Self-Reference (Recurrence) Along One Index Axis (esm-spec §4.3.1.1)
| ID | Requirement | Spec Reference | Testable | Test Category |
|---|---|---|---|---|
| BEHAV-04-G-001 | An equation defining an array-shaped unknown `V` whose RHS `aggregate` body reads `index(V, …)` at a strictly earlier position along ONE of that aggregate's output axes is a RECURRENCE DEFINITION of `V`, and MUST be materialized cell by cell with that axis as the outermost loop, ascending, each cell published before the axis advances. No `scan` / `fold` / `recur` operator exists and a binding MUST NOT add one | esm-spec.md §4.3.1.1; CONFORMANCE_SPEC.md §5.19 | Yes | behavioral |
| BEHAV-04-G-002 | The recurrence axis, its direction and the maximum lag are all DERIVED from the read, never declared. An index argument at the recurrence axis MUST be affine in that axis's frame symbol with coefficient 1; the lag is `k_d − <argument>`; a lag provably `≤ 0` for every value MUST be rejected, a lag provably `≥ 1` is admitted, and a lag STRADDLING zero is admitted because a self-read of an unpublished cell cannot return a value | esm-spec.md §4.3.1.1 | Yes | validation |
| BEHAV-04-G-003 | A recurrence definition MUST NOT be evaluated through any whole-array, vectorized, fused, tiled, kernel-merged or otherwise reordered path. Its cells are not independent, so a reordering computes something else and a reassociation of the body is a different number | CONFORMANCE_SPEC.md §5.19.2 | Yes | behavioral |
| BEHAV-04-G-004 | A self-read of a position outside the recurrence axis, or of a cell the sweep has not published, MUST be a fail-closed fault (`E_TREEWALK_RECUR_UNAVAILABLE`) and MUST NOT resolve to a number. The §5.5.5 zero ghost is never applied to a causal self-read, and a NaN sentinel is not sufficient on its own because a `max(x, 0)` in the body launders one | esm-spec.md §4.3.1.1; CONFORMANCE_SPEC.md §5.19.4 | Yes | behavioral |
| BEHAV-04-G-005 | The carried value is a cell of the variable being defined, so it takes that variable's `element_type` and MUST be rounded to it at EVERY cell, not only when the finished array is read back | esm-spec.md §4.3.1.1, §11.3.1; CONFORMANCE_SPEC.md §5.19.3a | Yes | behavioral |
| BEHAV-04-G-006 | A self-read that is not a well-founded causal read MUST be rejected with `recurrence_not_wellfounded`, and one the runtime cannot restrict to a single cell (a `makearray` region value, a `reshape`/`transpose`/`concat`/`broadcast` operand, or an RHS that is not an `aggregate` over the variable's frame) with `recurrence_unsupported_form`. Both apply in EVERY binding, executing or not | esm-spec.md §4.3.1.1; CONFORMANCE_SPEC.md §5.19.5 | Yes | validation |
| BEHAV-04-G-007 | The self-edge `V → V` MUST be dropped from the observed dependency graph, so a well-founded recurrence is not reported as a cycle; a cycle through two DISTINCT variables MUST keep whatever handling it had, and MUST NOT be diagnosed as a recurrence | CONFORMANCE_SPEC.md §5.19.5 | Yes | validation |
| BEHAV-04-G-009 | A binding MUST evaluate a recurrence identically on EVERY route it has for materializing an observed — a per-step route and a build-time/pipeline route are both routes — and its test tier MUST exercise each. The sweep MUST be ONE implementation both routes call, and a fixture MUST be re-checked per route against the same pinned value rather than merely re-run. Rust shipped this construct on its per-step route only: correct under `esm test`, silently dead under `esm simulate` and for any ingesting document, because `max(NaN, 0.0)` returns `0.0` and the motivating body is a clamp | CONFORMANCE_SPEC.md §5.19.3b | Yes | behavioral |
| BEHAV-04-G-008 | A conformance fixture in this category MUST pin the arithmetic ORDER, not an answer within a tolerance: a catastrophic-cancellation ladder that separates the left fold from every reassociation, a lag greater than 1, and a symbol-valued lag — the last so a binding implementing only `acc[i] = f(acc[i−1], …)` fails rather than passing on the subset it covers | CONFORMANCE_SPEC.md §5.19.3 | Yes | behavioral |

> **Binding status (2026-09-02)**: see `tests/conformance/recurrence/manifest.json` for the
> per-binding execution and skip status. `recurrence_not_wellfounded` and
> `recurrence_unsupported_form` are NEW cross-binding diagnostic codes; -003 through -005 are
> requirements on an EXECUTING binding only, while -002, -006 and -007 bind all five.

### BEHAV-04-H: Name Resolution in Expressions (CONFORMANCE_SPEC §5.23)
| ID | Requirement | Spec Reference | Testable | Test Category |
|---|---|---|---|---|
| BEHAV-04-H-001 | An expression MUST NOT be evaluated against a name bound in NONE of the resolution scopes available where it is evaluated. The binding MUST surface a named fault and MUST NOT substitute a value. A NaN sentinel is NOT sufficient: IEEE-754 `max`/`min` return the non-NaN operand, so `max(known, undeclaredFloor)` evaluates as `max(known)` — the operand DISAPPEARS and every downstream digit stays finite and plausible | CONFORMANCE_SPEC.md §5.23 | Yes | behavioral |
| BEHAV-04-H-002 | The check MUST be ONE shared implementation that EVERY route to a value invokes — a per-step route and a build-time/pipeline route are both routes — and a route that misses it MUST still fail closed at the resolver. A fixture MUST be driven on each route and the SAME verdict asserted, naming the same operand; "each route did something" is the state that persisted while the defect existed | CONFORMANCE_SPEC.md §5.23.1 | Yes | behavioral |

> **Binding status (2026-09-04)**: surveyed, not assumed — see the table in
> CONFORMANCE_SPEC §5.23.3. Julia (`E_TREEWALK_UNBOUND_VARIABLE`), Python (`Unresolved
> symbol`, plus a structural rejection at load) and TypeScript (`unbound_variable`) already
> raised; Go has no runner by design and its validator reports `Unknown variable '…'`. Rust
> was the only binding that resolved an unbound name to a NaN sentinel, and is FIXED
> (`E_TREEWALK_UNBOUND_NAME`, with the build pipeline now calling the same free-variable gate
> the compile path calls). Nothing in this family is left deferred.

### BEHAV-04-F: Aggregate Binders vs Globally-Scoped Names (esm-spec §4.3.1 / §11.3)
| ID | Requirement | Spec Reference | Testable | Test Category |
|---|---|---|---|---|
| BEHAV-04-F-001 | An `aggregate` binder — a `ranges` key or an `output_idx` entry — spelled with the document's INDEPENDENT VARIABLE (`domain.independent_variable`, default `"t"`) or with the §6.4 `_var` placeholder MUST be rejected at load with `reserved_index_symbol`. Both names are implicitly declared in every model's expression scope (§4.9.1) and are resolved by name AHEAD of the loop bindings, so such a binder declares a loop its own body can never address | esm-spec.md §4.3.1, §11.3, §4.9.1; CONFORMANCE_SPEC.md §5.5.8 | Yes | validation |
| BEHAV-04-F-002 | The rule follows `domain.independent_variable`: a document that renames it moves the rejection onto the new name and frees `t` as an ordinary symbol | esm-spec.md §11.3 | Yes | validation |
| BEHAV-04-F-003 | An `integral`'s `var` is NOT covered: `∫f dt` binds the independent variable because it is integrating over it, which is the authored §4.2 form and not a shadow | esm-spec.md §4.2 | Yes | validation |
| BEHAV-04-F-004 | The check MUST run on the fully lowered document (after §9.7 import resolution, the §9.6.3 fixpoint and template expansion), so a binder introduced by a template BODY is caught alongside an authored one | esm-spec.md §9.6.4, §9.7.6 | Yes | validation |

> **Binding status (2026-09-01)**: **Rust only**; `reserved_index_symbol` is a NEW
> cross-binding diagnostic code and Julia, Python, TypeScript and Go all need the mirror
> before the vocabularies agree again (Rust: `diagnostic.rs` registry +
> `parse::reject_reserved_index_symbols`; the value is pinned by
> `the_diagnostic_vocabulary_is_pinned`).
>
> **Julia measured against this row (2026-09-01): the rule is MISSING, and the
> symptom is DIFFERENT.** Julia's precedence is the opposite of Rust's — the dense
> aggregate expansion substitutes the loop binding into the body first
> (`_foreach_aggregate_product` -> `_sub_preserving`), so the binder is not dead
> and the JOIN is unaffected: on the same shape, ranges symbol `k`, `t` and
> `_var` all give 5.0 with 5 driven visits over data columns, and `k` and `t`
> both give 2.0 with 2 visits over index-set member columns. There is therefore
> no `0`-instead-of-2 in Julia. The cost lands on the other side of the same
> collision: the binder SHADOWS the independent variable inside the node, so with
> a body of `1.0 * t` at t = 7, symbol `k` gives 35.0 (5 terms x 7, correct) and
> symbol `t` gives 10.0 — the sum of the loop positions. `validate` reports valid
> in every one of those cases. So the document is accepted by both bindings and
> computes different answers, which is what this row exists to stop; Julia still
> needs the load-time rejection, and adopting it costs Julia nothing it currently
> relies on.
>
> **Why a rejection and not a shadowing rule.** Making the binder win means inverting the
> name-first precedence at nine sites in Rust alone (`simulate_array/eval.rs`
> `lookup_variable` / `lookup_array_ref`, `vectorized.rs::eval_vec_variable`, two
> `tape/lower.rs` sites, `units.rs`, `simulate/resolve.rs`, and the scoping walkers
> `flatten.rs::namespace_expr_scoped` / `scope_template_body`, each spelled
> `if name == "t" || name == VAR_PLACEHOLDER || bound.contains(name)`) and in every peer
> binding — and it would still leave the node unable to mention the independent variable
> at all, since an `aggregate` body reading `t` for a forcing term is ordinary and would
> silently become an index. Rejecting costs an author nothing: an index symbol is a free
> choice (§4.3.1). A scan of the whole shared corpus finds no document that binds either
> name, so no conforming fixture is affected (pinned by
> `the_shared_corpus_carries_no_reserved_binder`).
>
> **What it was before.** SILENT. Two aggregates over the same data differing only in the
> first loop symbol's name gave 2 for `k` and **0** for `t` — no error, no warning, and
> `esm validate` passing. With `const` key columns the same collision surfaced instead as
> `E_TREEWALK_CONSTARRAY_OOB: const array 'left_key' index 0 out of range 1..3`, a
> diagnostic about the wrong thing, because the lowered `code_lookup` addressed the
> constant key table with the simulation TIME. §5.5.8 already requires an unresolvable
> `join.on` key column to be a build error rather than a no-op; this is that rule one step
> earlier, at the binder. Reported by the downstream EPA MOVES port (finding F4), where a
> time-key loop symbol spelled `t` made a daytime hour count come out 0 with everything
> else passing. Gates: `earthsci-ast-rs/tests/reserved_index_symbol.rs` and the three
> fixtures under `tests/fixtures/reserved_index_symbol/` (the data-column half, the
> `const`-array half, and the `k`-spelled control that still answers 2).

### BEHAV-04-E: Subsystem-Mounted Data-Loader Consumption (RFC pure-io-data-loaders §4.3)
| ID | Requirement | Spec Reference | Testable | Test Category |
|---|---|---|---|---|
| BEHAV-04-E-001 | A pure-I/O data loader MOUNTED as a model subsystem (`models.X.subsystems.raw = <DataLoader>`) MUST have each of its variables lowered by flatten to a const-array-backed **observed** `<owner>.<subkey>.<var>` with NO defining equation; the owning model's own equations consume it by dot-notation (`raw.field`), and simulate MUST bind its value through the provider/const-array seam so BOTH a bare-scalar reference and a gather `index(raw.field, …)` resolve to the loaded value | RFC pure-io-data-loaders §4.3; CONFORMANCE_SPEC.md §5.11 | Yes | behavioral |

> **Binding status (2026-07-06)**: Python + Julia + Rust **implemented** and gated by the shared offline fixture `tests/conformance/subsystem_loader/` (analytic golden). Julia: flatten `_collect_model!` lowers each DataLoader-subsystem variable to an observed and the bare-scalar reference resolves through `_resolve_indices(::VarExpr)` against the CONST provider's `const_arrays` (runner `subsystem_loader_conformance_test.jl`). Python: `flatten.py` already lowers the observed + `LoaderField`; the 2-part `raw.field` structural check (`structural_checks.py`) and the numpy interpreter's bare 1-element loader-field scalarization (`numpy_interpreter.py`) were the two fixes (runner `test_subsystem_loader_conformance.py`). Rust: `flatten.rs` (`lower_loader_subsystems`) lowers each DataLoader-subsystem variable to an expression-less observed `Box.raw.<var>` and namespaces the owner's bare `raw.<var>` references to `Box.raw.<var>`; `structural.rs` (`loader_subsystem_scoped_refs`) resolves the 2-part ref so `validate` accepts it; both then bind at the RHS through the existing data-Provider forcing seam (`ArrayCompiled::forcing_handle`) — a bare-scalar field seeded as a 0-D array, a gathered field as a 1-D array (runner `subsystem_loader_conformance.rs`). Go / TypeScript out of scope (no array simulator).

### BEHAV-04-D: Subsystem-Mounted `index_sets` Merge (esm-spec §4.7)
| ID | Requirement | Spec Reference | Testable | Test Category |
|---|---|---|---|---|
| BEHAV-04-D-001 | A referenced subsystem file's top-level `index_sets` MUST merge into the importing document's document-scoped registry at resolution time, after the referenced document's metaparameters close and fold (§9.7.6 site 3 bindings, then defaults); names absent from the importer are added, deep-equal redeclaration is idempotent | esm-spec.md §4.7 | Yes | validation |
| BEHAV-04-D-002 | A non-deep-equal collision between a mounted file's index-set declaration and the importing document's registry MUST be rejected at load with `subsystem_index_set_conflict` (the subsystem-edge mirror of `template_import_index_set_conflict`, §9.7.5) | esm-spec.md §4.7, §9.6.6 | Yes | validation |

> **Binding status (2026-07-02)**: Julia implemented (`_merge_subsystem_index_sets!` in `parse.jl`, called from `_resolve_subsystem_ref` for every §4.7 subsystem edge, local and remote; fixtures `tests/valid/subsystem_mesh_lib.esm` + `tests/valid/subsystem_index_set_merge.esm`, `tests/invalid/template_imports/subsystem_index_set_conflict.esm`). **Pending port** — Python / Rust / TypeScript / Go must each: (1) at every subsystem-ref resolution, merge the loaded file's top-level `index_sets` (post-metaparameter-fold) into the importing document's registry; (2) treat deep-equal redeclaration as idempotent (structural equality over kind/size/members/of/offsets/values/from_faq); (3) reject non-equal collisions with the stable `subsystem_index_set_conflict` diagnostic; (4) drive the shared fixtures (schema-only bindings assert schema acceptance per `resolver_only`). Note: the Julia raw-level top-level-model `{ref}` inline path (`_inline_toplevel_model_refs!`) is a distinct mechanism and does not yet merge `index_sets`; it merges only `function_tables`/`data_loaders`/`enums`.
>
> **Go port (2026-07-03)**: implemented (`mergeSubsystemIndexSets` + `indexSetDeepEqual` in `subsystem_ref.go`; the importing document's `file.IndexSets` registry is threaded through `resolveSubsystemRefs`/`resolveSubsystemMap` and each mounted file's folded top-level `index_sets` merge in, transitively through nested mounts). `subsystem_index_set_merge.esm` loads with `vertices` merged in (size 4) and `cells` deep-equal-idempotent; `subsystem_index_set_conflict.esm` is rejected with `subsystem_index_set_conflict` (`go test ./...`).
> **TypeScript = implemented (2026-07-03)**: `mergeSubsystemIndexSets` in `pkg/earthsci-ast-ts/src/ref-loading.ts`, called from `resolveModelRefs` at every model subsystem-ref resolution with the importing document's `file.index_sets` threaded as the registry; deep-equal via `deepEqual` (numeric-literal-aware), non-equal collision → `subsystem_index_set_conflict`, absent name added. Matches the Julia reference (registry threaded only through the model walk, not reaction systems). The `subsystem_index_set_conflict.esm` fixture is rejected with the exact code (`src/template-imports.test.ts` invalid loop, via `resolveSubsystemRefs`).
> **Rust (2026-07-03)**: implemented (`earthsci-ast-rs/src/ref_loading.rs` —
> `merge_subsystem_index_sets` threaded through the model-subsystem walk via an
> `Option<&mut Map>` registry seeded from the importing document's own `index_sets`,
> written back post-merge; reaction-system subsystem refs thread `None`, matching the Julia
> scope; deep-equal via order-independent serde_json `Map` equality). Fixtures
> `subsystem_index_set_merge.esm` (+ `subsystem_mesh_lib.esm`) and
> `subsystem_index_set_conflict.esm` drive it (`template_imports_conformance`).
> **Python (2026-07-03)**: implemented (`earthsci_ast/parse.py` `_merge_subsystem_index_sets` + `_index_set_deep_equal`, threaded through model subsystem resolution via `EsmFile.index_sets`; reaction-system subsystems do not merge, matching the Julia reference). Fixtures: `subsystem_index_set_merge.esm` brings `vertices` in and keeps deep-equal `cells`; `subsystem_index_set_conflict.esm` raises `subsystem_index_set_conflict`.

### BEHAV-04-C: `makearray` Region Bounds — Empty vs Inverted (esm-spec §4.3.2)
| ID | Requirement | Spec Reference | Testable | Test Category |
|---|---|---|---|---|
| BEHAV-04-C-001 | A `makearray` region bound pair `[start, start − 1]` is the canonical EMPTY bound: the region contributes no elements and its `values` entry is never consulted; the document MUST load cleanly (the §9.6.8 minimum-admissible-extent case, e.g. `[2, N−1]` folded at `N = 2`) | esm-spec.md §4.3.2, §9.6.8 | Yes | validation |
| BEHAV-04-C-002 | A `makearray` region bound pair with `stop < start − 1` on the expanded, metaparameter-folded form MUST be rejected at load with `makearray_region_inverted` (e.g. `[2, N−1]` folded at `N = 1`) | esm-spec.md §4.3.2, §9.6.6, §9.6.4 | Yes | validation |

> **Binding status (2026-07-02)**: Julia implemented (`_validate_makearray_regions`, both §9.6.4 validator sites in `lower_expression_templates.jl`; fixtures `tests/valid/makearray_empty_region_min_extent.esm`, `tests/invalid/template_imports/makearray_region_inverted.esm`). **Pending port** — Python / Rust / TypeScript / Go must each: (1) walk the expanded, folded tree's `makearray.regions`, skipping `expression_templates` blocks and non-integer (unfolded) bound entries; (2) accept `stop == start − 1` as empty; (3) reject `stop < start − 1` with the stable `makearray_region_inverted` diagnostic; (4) drive the two shared fixtures (schema-only bindings TS/Go assert schema acceptance per the `resolver_only` flag in `expected_errors.json`).
>
> **Go port (2026-07-03)**: implemented (`validateMakearrayRegions` + `asInt64Strict` in `lower_expression_templates.go`, run at both §9.6.4 validator sites — the no-machinery fast path and the post-fixpoint return). `makearray_empty_region_min_extent.esm` loads at default N=2 (empty bound `[2,1]`) and is rejected at N=1 (inverted `[2,0]`) with `makearray_region_inverted`; the shared invalid fixture is rejected (`go test ./...`).
> **TypeScript = implemented (2026-07-03)**: `validateMakearrayRegions` in `pkg/earthsci-ast-ts/src/lower_expression_templates.ts`, run on the expanded/folded form at both `lowerExpressionTemplates` validator sites (fast path + full path), skipping `expression_templates` and non-integer bounds. `makearray_empty_region_min_extent.esm` loads clean at default `N = 2` (interior folds to `[2, 1]`); the same file rebound `N = 1` (loader API) and `makearray_region_inverted.esm` are rejected with `makearray_region_inverted`. Tests in `src/expression-templates.test.ts` + the `src/template-imports.test.ts` invalid-fixture loop.
> **Rust (2026-07-03)**: implemented (`earthsci-ast-rs/src/lower_expression_templates.rs`
> — `validate_makearray_regions`, called at the end of `lower_expression_templates` after
> `validate_geometry_manifolds`; skips `expression_templates` and non-integer bounds, accepts
> `stop == start − 1`, rejects `stop < start − 1` with `makearray_region_inverted`). Fixtures
> `makearray_empty_region_min_extent.esm` (default N=2 loads; loader-API N=1 rejects) and
> `makearray_region_inverted.esm` (`template_imports_conformance`).
> **Python (2026-07-03)**: implemented (`earthsci_ast/lower_expression_templates.py` `_validate_makearray_regions`, run at both §9.6.4 validator sites — fast path and full path — skipping `expression_templates` and non-integer bounds). Fixtures: `makearray_empty_region_min_extent.esm` loads at `N=2` (folds `[2,1]`) and rejects at `N=1` (folds `[2,0]`); `makearray_region_inverted.esm` raises `makearray_region_inverted`.

### BEHAV-08-A: Geometry-Op Operand Rings — Padding and Degenerate Vertices (esm-spec §8.6.1)
| ID | Requirement | Spec Reference | Testable | Test Category |
|---|---|---|---|---|
| BEHAV-08-A-001 | `intersect_polygon` / `polygon_intersection_area` operand rings MUST accept a closing duplicate final vertex and CONSECUTIVE duplicate vertices (rectangular-storage padding, e.g. an MPAS pentagon in a hexagon-shaped `[cells, NVERT, 2]` slot) and evaluate them as the deduplicated ring (point-equality tolerance atol 1e-8 / rtol 1e-5), equal to the same op over the already-distinct ring | esm-spec.md §8.6.1 | Yes | mathematical |
| BEHAV-08-A-002 | Deduplication MUST happen in the binding kernel's operand coercion BEFORE the backend clip (S2 rejects zero-length edges as degenerate; Sutherland–Hodgman treats them as no-ops — the op contract must not depend on the backend), and `intersect_polygon` MUST return its overlap ring as distinct vertices with implicit closure on every manifold | esm-spec.md §8.6.1, CONFORMANCE_SPEC §5.8.4 | Yes | mathematical |
| BEHAV-08-A-003 | A ring with fewer than 3 DISTINCT vertices after deduplication is a degenerate operand and MUST be rejected (the ≥3-distinct-vertices operand error) | esm-spec.md §8.6.1 | Yes | validation |

> **Binding status (2026-07-02)**: Julia implemented (`_as_ring` in `geometry.jl` now runs `_dedup_consecutive` on every operand before the planar/GeometryOps clip; empirically the planar and GeometryOps paths already tolerated padding with exactly-equal areas, but the spherical clip's OUTPUT retained the duplicates — dedup-at-coercion restores the distinct-vertex output contract; fixture `tests/valid/geometry/polygon_intersection_area_padded_ring.esm`, unit tests in `geometry_polygon_intersection_area_test.jl` incl. pentagon padded to 6/7 slots, planar + spherical). **Pending port** — **Python** (`geometry.py::_as_ring`): apply `_dedup_consecutive` (already defined for clip output) to operands before the clip — empirically REQUIRED for the spherely/S2 path, which rejects degenerate edges. **Rust** (`geometry.rs::intersect_polygon`): dedupe operands (allclose tolerance, wrap pair included) before `SphericalPolygon::from_lon_lat` — empirically the S2 path FAILS today on padded rings ("Edge N is degenerate (duplicate vertex)"), and the planar path passes padding through to its output ring; also dedupe the planar output. **TypeScript / Go**: schema-only, no geometry kernel — no action.
>
> **Rust (2026-07-03)**: DONE (`earthsci-ast-rs/src/geometry.rs` — `dedup_consecutive`
> + `as_ring` applied to both operands at the top of `intersect_polygon`, `dedup_consecutive`
> on the planar clip output, and dedup before `SphericalPolygon::from_lon_lat` in
> `spherical_area`; `<3` distinct after dedup rejects). Confirmed: the padded MPAS-style ring
> now clips in S2 (unit test `spherical_clip_accepts_padded_rings` — previously failed with
> the degenerate-edge error). Fixture `polygon_intersection_area_padded_ring.esm` simulates to
> area 1.0 via the `pde_conformance` example.
> **Python (2026-07-03)**: implemented (`earthsci_ast/geometry.py` `_as_ring` now runs `_dedup_consecutive` — interior consecutive duplicates + closing wrap pair — on every operand before the clip; `<3` distinct vertices rejected). Verified on the PLANAR path: `polygon_intersection_area_padded_ring.esm` (5-/6-vertex padded squares) deduplicates to 4-vertex squares, overlap area = 1.0; unit tests cover dedup + degenerate reject. The SPHERICAL/S2 (`spherely`) path is spherely-gated in this venv (no cp314 macOS-arm wheel) and could not be exercised; the dedup runs identically before either backend.

### BEHAV-06-B: Inline-Test Assertion Semantics (pinned §6.6.3/§6.6.5 conventions)
| ID | Requirement | Spec Reference | Testable | Test Category |
|---|---|---|---|---|
| BEHAV-06-B-001 | PDE assertions MUST select a scalar via `coords` or `reduce`; pointwise assertions are 0-D-only (validators reject the cross cases) | esm-spec.md §6.6.5 | Yes | simulation |
| BEHAV-06-B-002 | `coords` values are 1-based fractional INDEX-space positions along the named interval index sets; sampling picks the nearest grid index with exact half-way ties rounding down (`idx = ceil(c − 1/2)`); resolved index in `1..size` | esm-spec.md §6.6.3, §6.6.5 convention 1 | Yes | simulation |
| BEHAV-06-B-003 | `coords` may pin a strict subset of dimensions only when every remaining dimension resolves to a single sample | esm-spec.md §6.6.5 convention 1 | Yes | simulation |
| BEHAV-06-B-004 | `integral` reduce is the uniform-cell Riemann sum under unit total domain measure per axis (= `mean` over interval sets); the measure convention under which relative-L2 is measure-free | esm-spec.md §6.6.5 convention 2 | Yes | simulation |
| BEHAV-06-B-005 | `from_file` reference `path` resolves relative to the `.esm` file's directory; v1 `format` is `json` — a row-major nested array shape-validated against the field | esm-spec.md §6.6.5 convention 3 | Yes | simulation |
| BEHAV-06-B-006 | A `coords`/`reduce` assertion on a rank≥2 (multidimensional) array OBSERVED MUST materialize the field over the full Cartesian product of its interval index sets in row-major (lexicographic) cell order paired with the value layout, so all bindings agree. Julia: FIXED (`vec()` around the `CartesianIndices` cell sweep — a rank≥2 comprehension yields a Matrix that `sort!` rejected without `dims=`); Python (`np.ndindex`) and Rust (row-major `IxDyn` enumeration) were already rank-agnostic. Gate: `tests/conformance/pde_inline_observed_rank2/` (Julia/Python/Rust agree on the golden actuals) | esm-spec.md §6.6.5 convention 1 | Yes | simulation |
| BEHAV-06-B-007 | An assertion whose ACTUAL value is not finite MUST FAIL unless `expected` is the same infinity: the pass predicate is `actual == expected OR (both finite AND within tolerance)`, and finiteness is judged BEFORE tolerance. Applying the tolerance bound alone makes `\|±Inf − expected\| ≤ max(atol, rtol·max(Inf, \|expected\|))` vacuously true, so the assertion passes for EVERY expected value and an overflow / `x/0` / `log(0)` reports green. Julia: already conforming (`isapprox` carries the clause). Rust (`check_assertion`) and Python (`_check_assertion`): FIXED — both re-implemented "Julia isapprox semantics" without it. Gate: `tests/conformance/assertion_nonfinite/` (Julia/Python/Rust agree on the VERDICTS; ±Inf and NaN are not JSON-representable) | esm-spec.md §6.6.3, CONFORMANCE_SPEC §5.20 | Yes | simulation |
| BEHAV-06-B-008 | A POINTWISE assertion on a 0-D OBSERVED MUST be answerable wherever that observed's value exists — in a component with no array variable at all (no state vector to be found in), in a component that integrates (the observed is read along the trajectory, not held at t=0), and in a component with nothing to integrate whose value is a build-materialized field (a document that ingests `data_sources`). A variable the build bound NOTHING for MUST be an ERROR naming it, never a plausible zero. Rust: FIXED — the runner requests the pointwise-asserted observeds (`output_observed`) and falls back to the build's state-free scalar fields. Julia's MTK runner reads observeds natively; the Julia and Python tree-walk `run_pde_tests` still resolve a pointwise assertion against state rows only | esm-spec.md §6.6.3, §6.3.1 | Yes | simulation |
| BEHAV-06-B-009 | A `coords` / `reduce` assertion MUST be answerable on a STATE-DEPENDENT array OBSERVED, not only on a state or a state-free one. Such a field is in NO build-time product (only state-free observeds are materialized at build) and is not a scalar output row either, so a binding must evaluate the observed's own expression AT THE SAMPLED STATE — §5.23's "a reference denotes its expansion", already applied to scalar observeds. All three executing bindings refused it with "array state '<v>' has no cells in var_map". Rust: FIXED — the runner REQUESTS the asserted array observed (`SolveOptions::output_observed`), which the array runtime already emits as one row per cell. Python: FIXED — `observed_at_state` replays the observed driver on the trajectory sample. Julia: FIXED — `_state_scope` puts the solved state and `t` into the `evaluate_cellwise` scopes. Gate: `tests/conformance/pde_inline_observed_state_dependent/` (Julia/Python/Rust agree on the golden actuals; the same fixture's state-free `rate` keeps the build-materialized path pinned) | esm-spec.md §6.6.5, §5.23 | Yes | simulation |
| BEHAV-06-B-010 | An array field read for an assertion MUST be the ASSERTED COMPONENT's, never a union across sibling components that reuse the bare name: the model-qualified element stem wins, with the bare-suffix match reached only when no qualified element exists (the array analog of the pointwise `scalar_slot` rule). A single-pass union splices every model's cells into one field — four components each declaring `w[x]` yield four cells at index `[1]`, so a `coords` sample silently reads whichever component sorts first, a `reduce` collapses over all of them, and a per-cell `reference` indexes past the end. Julia and Rust: already two-pass. Python (`state_cells`): FIXED | esm-spec.md §6.6, §6.6.5 | Yes | simulation |

### BEHAV-10-A: `join` Names Under Flattening (CONFORMANCE_SPEC §5.5.6)
| ID | Requirement | Spec Reference | Testable | Test Category |
|---|---|---|---|---|
| BEHAV-10-A-001 | Flattening MUST dot-namespace the plain-string references a `join` clause carries — an `on` key column and an `overlap` clause's `src_env`/`tgt_env` envelope factors — because they resolve against the VARIABLE REGISTRY, which after flattening is the namespaced one. They are references encoded as strings, not structural metadata like `output_idx` / `ranges` keys / `int_var` | CONFORMANCE_SPEC.md §5.5.6, esm-spec.md §10.7 | Yes | behavioral |
| BEHAV-10-A-002 | The rewrite MUST be gated on the component's DECLARED LOCAL names (own variables + subsystem keys): a name that is not a declared local — a loop symbol bound by the enclosing `ranges`, a document-scoped index set named by an `on` key column, an already-qualified cross-component reference — MUST be left unchanged | CONFORMANCE_SPEC.md §5.5.6, §5.3 | Yes | behavioral |
| BEHAV-10-A-003 | Within one node the `join` names and the same factors carried in `args` MUST agree after flattening — a node MUST NOT spell one factor two ways | CONFORMANCE_SPEC.md §5.5.6 | Yes | behavioral |
| BEHAV-10-A-004 | A `variable_map` whose transform REMOVES the target parameter (`param_to_var`, `conversion_factor`, absent) MUST rename `to` → `from` inside every `join` clause as well; the expression-substitution walk does not reach these names, and a join left naming the removed parameter fails materialisation with `join references unknown variable` | CONFORMANCE_SPEC.md §5.5.6, esm-spec.md §10.4 | Yes | behavioral |
| BEHAV-10-A-005 | A flattened overlap-gated `distinct` producer MUST materialise the SAME support set as the unflattened one — the set is integer-valued and compared byte-identically (§5.5.1), so namespacing is required to be result-neutral | CONFORMANCE_SPEC.md §5.5.6, §5.5.1 | Yes | behavioral |
| BEHAV-10-A-006 | The NODE-LOCAL BINDER test MUST precede the declared-local test: a join name that is an `output_idx` entry or a `ranges` key of the node carrying the clause MUST be left unchanged **even when a local variable of the same name is declared**. esm-spec §4.3.1 permits that shadowing, and an `on` column resolves against the node's own ranges, so prefixing a shadowed symbol makes it resolve to nothing. The binder set is the clause-bearing node's own symbols, not an enclosing node's | CONFORMANCE_SPEC.md §5.5.6, esm-spec.md §4.3.1 | Yes | behavioral |
| BEHAV-10-A-007 | A §4.7 subsystem MOUNT is a namespacing event and MUST carry the same plain-string references: after renaming a mounted variable to `<key>.<name>`, every `join.on` key column, `overlap` envelope factor and resolved `on_gate` COLUMN naming it MUST follow. The rule is per NAME (a name the clause-bearing node binds stays bare while its siblings are rewritten), and a clause's SYMBOLS (`sym_src`/`sym_tgt`, the gate's two gated symbols) are binders and MUST NOT be renamed. Applies to the ARRAY-runtime mount as much as to the scalar flatten | CONFORMANCE_SPEC.md §5.5.6, esm-spec.md §4.6, §4.7 | Yes | behavioral |

> **Binding status (2026-08-12)**: **Julia** was already correct and is the reference
> (`namespacing.jl::_namespace_join` for -001/-002/-003,
> `coupling_apply.jl::_rename_join_names` for -004). **Rust** and **Python** both left
> `join` bare while namespacing everything around it, so the same document flattened by
> the three bindings produced join clauses that disagreed; Rust's own materializer then
> died on the flattened form with `join references unknown variable "X"`. Fixed in
> `earthsci-ast-rs/src/flatten.rs` (`namespace_join_names`, `rename_join_names`) and
> `earthsci-ast-py/src/earthsci_ast/flatten.py` (`_namespace_join`, `_rename_join_names`)
> — Python's flattener had documented the omission as unavoidable ("no index-set registry
> to tell the two apart"); the declared-local gate of -002 removes the need for one.
> **Go** flattens equations to STRINGS, so `join` survives only on its event trees;
> `flatten.go::namespaceJoinNames` covers that surface (Go has no join resolver, so -004
> and -005 do not apply). **TypeScript**'s flattener is string-emitting and discards
> `join` entirely — no action. Gates: `earthsci-ast-rs/tests/join_namespacing.rs`,
> `earthsci-ast-py/tests/test_join_namespacing.py` and
> `EarthSciAST.jl/test/join_namespacing_test.jl` all flatten the shared
> `overlap_gate_point_in_rect.esm` fixture and materialise the same `[1,2,4,9]` L1
> golden from the FLATTENED form, and all three pin the same `join.on` gate cases
> against the committed `tests/valid/aggregate/join_filter.esm`;
> `earthsci-ast-go/pkg/esm/join_namespacing_test.go` pins -001/-002/-003 on Go's
> event-tree surface. The Rust/Python cases fail on `origin/main` (4 of 5 each) and
> the Julia ones pass unchanged, which is the divergence stated as a test.
>
> **-006 (2026-08-17)**: the declared-local gate of -002, applied alone, mis-fires on a
> component that declares a variable named like one of its own loop symbols — a spelling
> esm-spec §4.3.1 explicitly permits. Verified: flattening `join_filter.esm` with an added
> `src` parameter rewrote `join.on [["src","sourceType"], …]` to
> `[["EmissionsAggregate.src","sourceType"], …]`, and
> `numpy_interpreter._join_sym_for_key("EmissionsAggregate.src")` then raises "neither a
> declared range symbol nor an index set bound by a range of this aggregate". Fixed in ALL
> FOUR bindings by testing the node's own binders (`output_idx` entries + `ranges` keys)
> before the declared-local gate — `namespace_join_names` (Rust), `_namespace_join`
> (Python, Julia), `namespaceJoinNames` (Go). Two cases per binding (a shadowed `ranges`
> key, a shadowed `output_idx` entry with a literal singleton dimension beside it); all
> four pairs fail with the binder test removed.
>
> **-007 (2026-09-01)**: the mount is the THIRD namespacing event in this crate and had
> none of -001..-006. `simulate_array/compile.rs::mount_subsystems` renames references
> through `rename_free_symbol`, an `Expr::Variable` walker over `map_children`, so a
> mounted leaf's variables became `Leaf.left_key` while its `join.on` went on naming the
> bare `left_key` — and the build died with "join key column 'left_key' does not resolve
> to a loop index of this aggregate". Every relational leaf joins on data columns
> (§5.5.8 names MOVES as the motivating case), so under this NO calculator could be
> mounted as a nested subsystem at all; the downstream EPA MOVES port worked around it by
> mounting leaves as top-level `models` `{ref}` instead. Fixed in Rust only
> (`rename_free_symbol` now finishes the node through a new `rename_join_names`, the
> array twin of `flatten.rs`'s); the existing per-node binder test in that walker gives
> the -006 shadowing rule for free, because the mount calls it once per sibling NAME.
> Gates: `earthsci-ast-rs/tests/subsystem_mount_join_names.rs` (end to end through
> `load_path` + the inline-test runner) and three unit cases in `compile.rs`
> (`mounting_carries_a_leafs_join_on_key_columns`,
> `mounting_leaves_a_shadowed_loop_symbol_alone`,
> `mounting_carries_overlap_envelope_factors`) — all four fail with the join rewrite
> removed. **Not ported**: Julia, Python, Go and TypeScript each need the audit on their
> own mount path (whichever renames a mounted subsystem's variables), and until then this
> row is Rust-only.
>
> **Adjacent, found by the -007 audit and NOT fixed** — `flatten.rs::retarget_merged_names`
> (the `operator_compose` renaming match, `B.x` → `A.y`) is also a pure variable RENAME
> driven through `crate::substitute`, which walks `Expr` children only, and unlike its
> `variable_map` sibling twenty lines below it has no `rename_join_names` companion. A
> `join` naming the folded-away spelling would keep naming it. No fixture exercises an
> `operator_compose` renaming match over a joined aggregate, so this is reported rather
> than fixed. Separately, `dae.rs`'s tearing substitution replaces a variable with an
> EXPRESSION; a `join.on` key column can only be a NAME, so an eliminated variable that is
> also a key column cannot be rewritten at all — a structural limit worth a diagnostic
> rather than a rename.
>
> **Adjacent, NOT fixed here** — Julia's `namespace_expr` tracks no bound-symbol scope at
> all, so on the same shadowed document it rewrites the loop symbol inside the node's
> `expr` as well (`index(base_rate, src)` → `index(base_rate, EmissionsAggregate.src)`),
> where Rust (`child_bound`) and Python (`local_leave`) leave it alone. That is a SECOND
> cross-binding divergence, pre-existing and independent of `join`; closing it means
> threading a scope through Julia's identity-memoized recursion, whose memo is documented
> as sound only because "prefix and local_names are traversal-constant". Left as its own
> change.

### BEHAV-10-B: Value-Equality (`join.on`) Gate (CONFORMANCE_SPEC §5.5.8)
| ID | Requirement | Spec Reference | Testable | Test Category |
|---|---|---|---|---|
| BEHAV-10-B-001 | An `on` key column MUST resolve in the §5.5.6 precedence order: first a LOOP SYMBOL of the clause-bearing node or the INDEX SET one of its ranges draws `{from}` (key values = declared members / interval IDs), otherwise a DATA COLUMN — any declared 1-D variable whose single shape index set names one of that node's ranges. A binding that admits only the first, or admits the second only for a value-invention bin buffer, is non-conformant | CONFORMANCE_SPEC.md §5.5.8 | Yes | behavioral |
| BEHAV-10-B-002 | A multi-pair `on` clause over the same two loop symbols is ONE composite key: a combination is admitted iff EVERY listed pair agrees (tuple equality on the §5.5.1 rule-4 skolem tuple). Pairs over different symbol pairs are separate gates | CONFORMANCE_SPEC.md §5.5.8, §5.5.1 | Yes | behavioral |
| BEHAV-10-B-003 | The match set MUST be built ONCE per node, hashing to bucket ONLY, and emitted ordered by the canonical key then by left then right position — so duplicate / reversed / permuted inputs give a byte-identical pair list | CONFORMANCE_SPEC.md §5.5.8, §5.5 rule 5 | Yes | determinism |
| BEHAV-10-B-004 | The gate MUST DRIVE enumeration under the same three binding cases as §5.5.6 (both contracted ⇒ pairs; one bound ⇒ partner list; both bound ⇒ membership test), so the contraction costs `O(\|matches\|·∏ungated)` and not `O(∏ranges)`. An output position with no candidate pair takes the semiring identity `0̄` | CONFORMANCE_SPEC.md §5.5.8, §5.5.6 | Yes | performance |
| BEHAV-10-B-004a | SHOULD: both gated symbols contracted ALONGSIDE other contracted axes (a rollup that also reduces over an unrelated axis) is driven by letting the LATER gated axis enumerate only the partners of the earlier one's current binding — still an order-preserving subsequence, and it removes the whole `N_later` factor | CONFORMANCE_SPEC.md §5.5.8 | Yes | performance |
| BEHAV-10-B-005 | Driving MUST be a pure optimisation of the enumeration EXTENT: the driven and undriven results MUST be identical (bit-identical for a floating ⊕, since the driven walk is an order-preserving subsequence of the filtered full product) | CONFORMANCE_SPEC.md §5.5.8 | Yes | behavioral |
| BEHAV-10-B-006 | Because an `on` gate is EXACT rather than a conservative broad phase, a binding MUST keep every evaluation path that does not consult the gate — a vectorised/whole-array overlay, a compiled tape, a build-time observed evaluator — applying the equality. Resolving the clause into a gate ALONE, and leaving such a path evaluating an ungated product, is silently wrong rather than merely slow | CONFORMANCE_SPEC.md §5.5.8 | Yes | behavioral |
| BEHAV-10-B-007 | A relation MUST be joinable to ITSELF: two of the node's ranges drawing ONE index set. A key column's axis then names several candidate range symbols, and the SIDE ASSIGNMENT is normative — with exactly two candidates the LEFT key is read at the earlier in canonical range order (`output_idx` order, then the contracted symbols ascending) and the RIGHT at the later; with three or more the document MUST be rejected, naming the candidates | CONFORMANCE_SPEC.md §5.5.8 | Yes | behavioral |
| BEHAV-10-B-008 | A `join` clause MAY carry `syms`, a 2-element `[left, right]` array of range symbols overriding the default for every pair in the clause. Both MUST name ranges of the node; a key whose axis the named symbol does not draw is a build error. `syms` names BINDERS, so a binding MUST carry it unchanged through §5.5.6 namespacing and `variable_map` renaming, and MUST NOT rewrite it as a variable reference | CONFORMANCE_SPEC.md §5.5.8 | Yes | behavioral |
| BEHAV-10-B-010 | The two self-join refusals are STRUCTURAL and stated about the DOCUMENT: both are decidable from the single file, so `validate()` MUST report them under `join_side_ambiguous` (no range symbol determined for an `on` key) and `join_syms_unknown_symbol` (a `syms` entry the node does not bind), at the containing equation field. A binding that defers either to its evaluator reports it under a different code, at a different phase, or not at all for a document that is never simulated | CONFORMANCE_SPEC.md §5.5.8 | Yes | behavioral |
| BEHAV-10-B-009 | The default assignment applies to a DATA COLUMN's axis only. A key NAMING an index set that several range symbols draw MUST stay a build error advising the range symbol (or `syms`) — adding the self-join capability must not remove that diagnostic, or `on: [["county", "i"]]` with two ranges over `county` becomes a tautological pair and an ungated product | CONFORMANCE_SPEC.md §5.5.8 | Yes | behavioral |

> **Superseded in part by BEHAV-11 (CONFORMANCE_SPEC §5.24).** -004's "the gate
> MUST DRIVE" is unchanged, but WHICH gate drives when a node carries several,
> and whether their partner sets are intersected, is BEHAV-11's subject.
>
> **Binding status (2026-08-31)**: **Rust** implements all six plus the -004a SHOULD.
> `join.rs::resolve_aggregate_joins` resolves each pair to `(loop symbol, KeyColumn)` —
> `Const` (index-set members / interval IDs) or `Column` (a declared 1-D variable) —
> emits the equality into `filter` for -006 and attaches a `JoinClause::on_gate` for
> -004; `relational.rs::equijoin` is the single canonical-key-ordered match kernel for
> -003; `simulate_array/eval.rs::resolve_join_gate` builds the pair index once per node
> and hands it to the SAME `broad_phase::overlap_drive_plan` /
> `reduce_contraction_gated` the overlap gate uses, so -004's three cases are shared
> code rather than a parallel implementation. Gates:
> `earthsci-ast-rs/tests/join_on_equality_gate.rs` (differential vs the hand-written
> filter AND vs the same document with the driver killed, plus two scaling tests) and
> the shared fixture `tests/valid/aggregate/join_on_data_columns.esm`, whose inline
> `count(1) = 5` reads the join's cardinality directly (a binding that drops the clause
> computes the full product's 12).
>
> **-007 / -008 / -009 (self-join) status (2026-09-02): Rust, Julia and Python all
> three.** The resolution is the same in each: a node's canonical range order orders an
> ambiguous axis's candidates, the left/right default applies at the DATA-COLUMN step
> only, and a clause's `syms` overrides it (Rust `join.rs::Pick` / `Via`; Julia
> `_join_sym_for_key(…, pick, order, via)`; Python the same signature). TypeScript and
> Go carry `syms` through unchanged with no code change — a join clause is an open bag
> in both (`{[k: string]: unknown}` / `[]any`) — and validate it from the synced
> schema. The -010 rejections are pinned ONCE for all five, as
> `tests/invalid/aggregate/build_time/self_join_three_ranges_ambiguous.esm`,
> `…_index_set_key_ambiguous.esm` and `…_syms_unknown_symbol.esm` with their
> `(code, path)` in `tests/invalid/expected_errors.json` — the file
> `scripts/compare-conformance-outputs.py` reads for check B (every
> `tests/invalid/**` rejected, per binding, no exceptions) and check C (each
> rejection carries the pinned findings). Verified identical in all five: same
> code, same JSON pointer, for each of the three.
> Gates: the shared fixture `tests/valid/aggregate/join_on_self_join.esm`
> (`priorSum = 1111`, NOT the transposed 11110 nor the ungated 55555; `pairCount = 4`,
> NOT 25), plus `earthsci-ast-rs/tests/join_on_self_join.rs`,
> `EarthSciAST.jl/test/join_on_self_join_test.jl` and
> `earthsci-ast-py/tests/test_numpy_interpreter_self_join.py`, each asserting the
> transposed answer as what the default must NOT produce and each pinning driven work
> at the match count rather than at N². Rationale:
> `docs/content/rfcs/self-join-two-ranges-over-one-index-set.md`.
>
> **Python: -001 DONE (2026-08-31), -004 MISSING.** `_resolve_join_key_column` gained
> the data-column branch below — resolved through `ctx.var_index_sets` and read with
> `_overlap_env_array`, with binders tested first — so the shared fixture passes. The
> driver (-004) is still absent.
>
> **Julia: -001, -002, -003, -004, -005 and -006 DONE (2026-08-31). -004a NOT
> implemented.** The two halves the handoff described — a polymorphic `on` key
> resolver and the §5.5.6 driver — were both already in the tree and are now
> connected.
>
> * **-001.** `tree_walk/semiring.jl::_join_key_sym_pos_vals` gained the
>   data-column branch: the key resolves through the variable's declared 1-D
>   shape (`var_shapes`) and its build-time data comes from, in order, a
>   value-invention map buffer, the const arrays (host-supplied,
>   front-door-derived, or a `const`-op array observed), or a document-LITERAL
>   array observed materialised through the same `_resolve_index_of_makearray`
>   the body's own `index(col, l)` uses. Anything else is a named build error,
>   never a silently ungated product. BINDERS ARE NOW TESTED FIRST, as Python
>   does: the value-invention buffer branch used to run before them and is now
>   the special case of a data column it always was. A float-STORED column is
>   admitted only where every value is exactly integral; Julia follows Python
>   (reject the document) rather than Rust (decline the gate), because it lowers
>   no equality predicate to fall back on.
> * **-004.** `_on_gate_match_pairs` builds the admissible pair set once per node
>   and wraps it in the same `_OverlapIndex` an overlap gate carries, so
>   `broad_phase.jl::_overlap_drive_plan` and
>   `tree_walk/resolve.jl::_foreach_aggregate_term_gated` drive an `on` gate
>   through the identical code path and the identical three binding cases. No
>   parallel driver. `_overlap_driver` is renamed `_drivable_gate` — it never
>   inspected which kind of gate produced the index, and now genuinely serves
>   both.
> * **-002.** Pairs of one clause over the same two loop symbols are grouped
>   before indexing: the composite key is the tuple of per-pair bucket codes and
>   it is the COMPOSITE match set that drives, not the first pair's (a superset).
>   The first gate of each group carries the index; the rest stay pure code
>   tests, so admission is unchanged.
> * **-003.** The match set comes from `Relational.equijoin`, the one canonical
>   rule-5 primitive — hashing buckets only, output sorted by canonical key then
>   left then right, never `Dict` iteration order (Julia's `Dict` is not
>   insertion-ordered, so a naive port would have leaked it). `_OverlapIndex`
>   derives the position-ascending DRIVE order from that list.
> * **-005.** `_join_admits` still tests the CODES whenever a gate has them,
>   index or no index, so every driven leaf is re-checked against the same
>   predicate the undriven product applies.
> * **-006** holds as it always did, structurally: Julia's whole-array,
>   stencil, setup-geometry and PDE-inline fast paths each decline a node
>   carrying `join`/`join_gates`/`filter` rather than evaluating an ungated
>   product, so there is no non-consulting path to keep in step.
> * **-004a (SHOULD) NOT implemented.** With both gated symbols contracted
>   ALONGSIDE other contracted axes, `_foreach_aggregate_term_gated` still falls
>   back to the full product: its `:pairs` shape binds the whole tuple and is
>   taken only when the two gated symbols are the only contracted axes. Driving
>   the later gated axis in place means replacing the `Iterators.product` unroll
>   with a nested walk carrying a per-level restriction, in the engine's hottest
>   loop, and §5.5.8 makes this a SHOULD precisely because falling back is
>   correct and only slower. The value-invention producer
>   (`_vi_enumerate_join`) already drives this shape, because it recurses the
>   remaining ranges rather than producting them.
>
> Gates: `pkg/EarthSciAST.jl/test/join_on_equality_gate_test.jl`, which pins the
> driver from both sides (the index-set product grows 200x to 1e8 with the match
> count fixed and the visit count must not move; the product is held at 1e7 while
> the matches grow to 10 000 and the visit count must track them) and against
> BOTH differential arms — the same document with the driver killed
> (`ESS_JOIN_ON_GATE_DISABLE=1`), and `_foreach_aggregate_term` run driven and
> undriven with the emitted term SEQUENCES compared element for element. A visit
> count of 0 means the gate declined, so a silent fallback fails too. Measured
> (build + one RHS call, on a loaded machine): 5e5 candidate pairs, gate OFF
> 0.47s / ON 0.009s; 1e7, OFF 10.7s / ON 0.021s; 1e8, ON 0.26s. The driven arm
> tracks MATCHES — 500 / 1000 / 10 000 at a fixed 1e7 product cost 0.009 /
> 0.028 / 0.080s — while the undriven arm tracks the product.
>
> **Julia had NO analogue of Rust's `prepare.rs` hole** (a build-time observed
> evaluator carrying an `overlap` resolution hook and no `on` one). Julia's
> tree-walk build resolves `join` uniformly for every ODE and initialization
> equation, observed-defining ones included, and its geometry-setup and
> value-invention resolvers each handle both clause kinds. One ADJACENT gap
> survives, pre-existing and already documented in-tree: `_expr_has_join`, the
> predicate that decides whether the resolution pre-pass runs at all, walks
> `args`/`expr_body`/`values`/`filter` but not `lower`/`upper`/`key`/
> `table_axes`/range bounds — so a document whose ONLY `join` sits in such a
> field would skip the pre-pass and reach the evaluator ungated, even though
> `_resolve_join_in_expr` does recurse those fields once the pre-pass runs. The
> in-tree comment marks the subset as behaviour-pinned and "flagged for Wave 3";
> no document exercising it could be constructed here (the `integral` op's
> evaluator ignores its bound fields), so it is recorded rather than widened.
>
> **The two Rust-side join defects, checked against Julia (2026-09-01).** Both
> were reported downstream and fixed in Rust; neither reproduces in Julia, but
> one leaves a REAL cross-binding divergence that Julia has not closed.
>
> * **F1 — a nested subsystem mount dropping a leaf's `join.on` key columns:
>   NOT PRESENT in Julia.** Rust's `mount_subsystems` rewrote references through
>   an `Expr::Variable` walker, and a key column is a plain STRING on the
>   aggregate node, so the array path renamed everything about the leaf EXCEPT
>   its join and the build then failed. Julia has one namespacing path, not a
>   separate array one, and `namespacing.jl::_namespace_join` is on it.
>   Verified on Rust's own fixtures (`subsystem_join/join_leaf.esm`,
>   `host_mounts_join_leaf.esm`): flattened standalone the variables are
>   `JoinLeaf.left_key` / `JoinLeaf.right_key` and the clause reads
>   `("JoinLeaf.left_key", "JoinLeaf.right_key")`; flattened under the mount they
>   are `Host.Leaf.*` and the clause reads `("Host.Leaf.left_key",
>   "Host.Leaf.right_key")` — in lockstep, both times. End to end the leaf's join
>   gives 2.0 with 2 driven visits standalone AND mounted, where pre-fix Rust
>   failed the mounted build outright.
> * **F4 — an aggregate binder that shadows `t`: the SYMPTOM is absent in Julia,
>   the DIVERGENCE is not.** Rust resolved `t` by name BEFORE the loop bindings,
>   so a binder spelled `t` was dead and the join matched nothing (0, silently);
>   Rust now rejects such a binder at load with `reserved_index_symbol`. Julia
>   has the OPPOSITE precedence: the loop binding is substituted into the body
>   first, so the join is unaffected — measured on the same shape, ranges symbol
>   `k`, `t` and `_var` all give 5.0 with 5 driven visits (data columns), and `k`
>   and `t` both give 2.0 with 2 visits (index-set member columns). But the
>   binder then SHADOWS the independent variable inside the node: with body
>   `1.0 * t` at t = 7, symbol `k` gives 35.0 (5 terms x 7, correct) while symbol
>   `t` gives 10.0 — the sum of the loop positions. `validate` reports valid in
>   every one of these cases. So the same document is accepted by both bindings
>   and computes DIFFERENT answers, which is the thing §5.5.1 rule 1 exists to
>   prevent. Julia needs the mirror rejection, and the `reserved_index_symbol`
>   code value is a cross-binding contract; NOT done here — it is a parse/load
>   rule, not a `join.on` gate rule, and the Rust commit records it as owed by
>   Julia, Python, TypeScript and Go alike.
>
> Julia has adopted `tests/valid/aggregate/join_on_data_columns.esm` into
> `test/aggregate_conformance_test.jl`; Python's `test_aggregate_conformance.py`
> auto-collects it already (it globs every aggregate fixture carrying an inline
> `tests` block).
> **Go** and **TypeScript** validate the join schema and do not evaluate, so no rows
> apply to them.

### BEHAV-12: Inline-Test Build Reuse and Test Selection (CONFORMANCE_SPEC §5.25)
| ID | Requirement | Spec Reference | Testable | Test Category |
|---|---|---|---|---|
| BEHAV-12-001 | A binding MAY reuse a constructed problem for a later test of the SAME component of the SAME document, and MUST NOT reuse it unless every input its own build reads is unchanged. For the construction contract this spec pins, that key is `expression_template_imports`, `time_span`, `parameter_overrides` and `initial_conditions`; a build that reads more MUST key on more | CONFORMANCE_SPEC.md §5.25.1 | Yes | behavioral |
| BEHAV-12-002 | The key MUST be compared EXACTLY. A key missing a field does not error — the later test is answered with the earlier test's model, a plausible number from a configuration the author did not write (the §5.14 / §5.23 failure class) | CONFORMANCE_SPEC.md §5.25.1 | Yes | behavioral |
| BEHAV-12-003 | A test's `assertions` reach the RUN (sampled times, requested observeds) and not the build, so a binding that reuses a build MUST still perform the run per test — or carry the assertion list in the key. `id`, `description` and `tolerance` reach neither | CONFORMANCE_SPEC.md §5.25.1 | Yes | behavioral |
| BEHAV-12-004 | Artifacts a run MUTATES — the build-observability record (filled by a run, DRAINED by its reader), a refreshable forcing channel, a provider executor — MUST be restored to their post-construction state before each reuse, so the n-th test of a shared build observes what a freshly built problem would | CONFORMANCE_SPEC.md §5.25.2 | Yes | behavioral |
| BEHAV-12-005 | Permuting a component's `tests` array MUST NOT change any assertion's actual, nor which assertions are reported. A single-slot (consecutive-only) cache is permitted — its BUILD COUNT is order-dependent, which is a cost, not a result | CONFORMANCE_SPEC.md §5.25.3, §5.5 rule 5, §5.7 rule 5 | Yes | determinism |
| BEHAV-12-006 | A runner's test filter MUST report exactly the rows the same predicate applied to the unfiltered result set would report — same rows, same order, same fields, including the whole-test ERROR rows a test that could not be built contributes | CONFORMANCE_SPEC.md §5.25.4 | Yes | behavioral |
| BEHAV-12-007 | SHOULD: the filter is applied BEFORE anything is built or run, so narrowing to one test costs one test. Applied to an already-computed result vector it is useless — on `nr-logging-county` the pre-fix filtered run took 309.3 s / 326.2 s against 301.9 s / 306.6 s unfiltered (slower, within the spread), because all 29 builds had already run; selecting first, `esm test ./runs --filter <one of fifteen>` went 153.2 s / 156.9 s → 0.98 s / 0.97 s for the same rows | CONFORMANCE_SPEC.md §5.25.4 | Yes | performance |

> **Binding status (2026-09-04)**: **Rust** implements all seven.
> `pde_inline_tests.rs::BuildKey` is the four-field key (floats keyed by BIT PATTERN, so
> two spellings of one value miss and rebuild rather than merging), compared exactly by a
> ONE-SLOT memo in `run_model_tests`; -003 holds because only the build is memoised and
> `solve` still runs per test; -004 is `EsmProblem::reset_inspection`, called before every
> reuse (construction leaves the record empty, `solve` overwrites it on the array backend
> only, and `take_inspection` drains it, so without the reset the second test of a
> STATE-FREE document would read an emptied record); -006/-007 are
> `run_pde_tests_filtered`, which the CLI's `--filter` now calls instead of filtering the
> returned `Vec`. Gate: `earthsci-ast-rs/tests/inline_test_build_memo.rs` — the
> `build_providers` factory is called once per build, so a counting factory reports the
> build count directly, and every case is ALSO built so that a missing key field gives a
> wrong number rather than merely a fast one. Sabotage-verified: dropping each of the
> four fields from `BuildKey::of` in turn turns the suite red (1, 1, 4 and 1 tests
> respectively), and restoring it green.
>
> Measured on moves.esm at EarthSciAST a1dc9bb30, `/usr/bin/time`, base and new
> interleaved, output diffed byte-for-byte at every point (`--verbose`, so every
> assertion row is compared, not only the summary):
>
> | `esm test …` | tests → builds | base | new |
> |---|---|---:|---:|
> | `fixtures/nr-logging-county.esm` | 29 → 1 | 301.9 s / 306.6 s | 11.0 s / 16.2 s |
> | `fixtures/process-evap-fvv.esm` | 14 → 1 | 68.2 s | 5.0 s |
> | `fixtures/process-evap-leaks.esm` | 10 → 1 | 47.8 s | 4.9 s |
> | `./runs` | 15 → 5 | 169.3 s | 150.2 s (solve-bound, not build-bound) |
> | `./components` | 130 → 34 | 8.1 s | 8.0 s (builds already cheap) |
> | `moves.esm/run-tests.sh`, whole suite | — | 630.7 s / 663.0 s | 232.4 s / 239.9 s |
>
> **Julia**, **Python** build per test, so §5.25.1–§5.25.3 impose nothing on them until
> they memoise; neither exposes a test filter, so -006/-007 are Rust-only today.
> **TypeScript**, **Go** have no inline-test runner and no rows apply.

### BEHAV-13: `enums` Member Value Domain (CONFORMANCE_SPEC §5.26)
| ID | Requirement | Spec Reference | Testable | Test Category |
|---|---|---|---|---|
| BEHAV-13-001 | An `enums` member's value is ANY integer — negative, zero or positive. A binding MUST accept a zero-valued and a negative-valued member; the old `EnumDeclaration.additionalProperties` bound `{"type":"integer","minimum":1}` made a zero-valued identifier unnameable in every binding at once | esm-spec.md §9.3; CONFORMANCE_SPEC.md §5.26 | Yes | validation |
| BEHAV-13-002 | A member MUST resolve to EXACTLY its declared integer: the load-time lowering produces `{"op":"const","value":<n>}` with `n` unchanged in value and sign. A binding MUST NOT clamp a `0` up, read it as absent, or take it for a default — schema acceptance alone is not conformance | esm-spec.md §9.3, §4.5; CONFORMANCE_SPEC.md §5.26.3 | Yes | behavioral |
| BEHAV-13-003 | The resolved value MUST carry through ARITHMETIC as an ordinary number, keeping its magnitude and sign. The shared fixture `tests/valid/enums_zero_and_negative.esm` pins `Braking + 10*Idling + Unassociated = 0 + 10 − 1 = 9`, which a binding that clamped or dropped a sign cannot produce. Whether a COMPARISON of a member is exact is §5.24's rule, not this one's: a member is a numeric literal and adopts its context precision, so in a `Float32` document two members 5 apart compare equal (measured, §5.26.4) | esm-spec.md §9.3; CONFORMANCE_SPEC.md §5.26.3, §5.26.4, §5.24 | Yes | behavioral |
| BEHAV-13-004 | An enum member is a CODE, not a 1-based position. A binding MUST NOT reintroduce a positivity bound on the grounds that the §4.5 example indexes a `const` table with one: `index`-op coordinates and `makearray` regions are separate 1-based constructs with their own bounds validation (`E_TREEWALK_CONSTARRAY_OOB`, §5.5.5) | esm-spec.md §9.3, §4.3.3, §4.5; CONFORMANCE_SPEC.md §5.26.1 | Yes | behavioral |
| BEHAV-13-005 | Values MUST remain unique within one enum, and `0` is a value like any other — two symbols MAY NOT both map to `0`. Not expressible in JSON Schema, so it lives in each loader | esm-spec.md §9.3; CONFORMANCE_SPEC.md §5.26.5 | Yes | validation |

> **Binding status (2026-09-05), measured on `tests/valid/enums_zero_and_negative.esm`:**
> **-001 / -002 / -003 / -004 pass in all five bindings.** Rust
> (`tests/lower_enums_integration.rs`, plus `esm test` on the fixture: 3/3
> assertions), Python
> (`tests/test_closed_functions.py::test_zero_and_negative_enum_members_load_and_resolve_to_themselves`),
> Julia (`test/closed_functions_test.jl`, "zero and negative enum members"),
> TypeScript (`src/enums-zero-negative.test.ts`) and Go
> (`pkg/esm/lower_enums_test.go::TestZeroAndNegativeEnumMembers`) each load the
> document, assert the lowered `const 0` / `const −1`, and evaluate the
> arithmetic row to 9.
>
> **-005 is DEFERRED in three bindings.** Python (`parse.py`) and Julia
> (`coerce_enums`) reject a duplicate value, and reject a duplicate `0` exactly
> as they reject a duplicate positive — neither uses `0` as a sentinel. **Rust**
> (`lower_enums.rs::parse_enums_block`), **TypeScript** (`lower-enums.ts`) and
> **Go** (`lower_enums.go`) accept a duplicate value silently. That gap is NOT
> introduced by the widened domain — measured, they accept a duplicate positive
> value too — and predates it; it is recorded here rather than left unstated.

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

### BEHAV-11: Conjunctive, Selectivity-Ordered Join Gating (CONFORMANCE_SPEC §5.24)

BEHAV-10-B pins the value-equality gate. This section pins what a node does when
it carries SEVERAL of them, which §5.5.8 used to leave as "the first in document
order drives". Everything here is about COST except -003 and -005, which are
about the result and are the reason the cost rule is allowed to exist at all.

| ID | Requirement | Spec Reference | Testable | Test Category |
|---|---|---|---|---|
| BEHAV-11-001 | When several gates on one node could drive, a binding SHOULD choose by an estimate of selectivity rather than by clause position. The RECOMMENDED estimate is the admitted fraction `\|matches\| / (\|L\| · \|R\|)`, every input of which the gate's own construction already produced | CONFORMANCE_SPEC.md §5.24.1 | Yes | performance |
| BEHAV-11-002 | The estimate MUST be compared as an exact rational (`a₁·s₂` vs `a₂·s₁` in integers), never by a floating-point division: two bindings must order two nearly-equal estimates the same way | CONFORMANCE_SPEC.md §5.24.1 | Yes | determinism |
| BEHAV-11-003 | Ties MUST break on the gate's index in the node's resolved `join` list, so the chosen order is a pure function of the DOCUMENT and the data — not of hash iteration, allocator or locale | CONFORMANCE_SPEC.md §5.24.1, §5.7 rule 5 | Yes | determinism |
| BEHAV-11-004 | A binding SHOULD drive the CONJUNCTION: a contracted axis put opposite an already-bound output index by several gates enumerates the INTERSECTION of their partner lists, not one of them. The lists are ascending and duplicate-free (§5.5.8's canonical match order), so the intersection is a linear merge and an order-preserving subsequence of the axis's range | CONFORMANCE_SPEC.md §5.24.2 | Yes | performance |
| BEHAV-11-005 | The emitted values MUST NOT depend on which gate drives or on whether the conjunction is intersected — bit-identically, for a floating `⊕`. This is a MUST that does not hold for free: it requires every clause to be lowered into `filter` (§5.5.8) AND that lowered comparison to be evaluated exactly (BEHAV-11-007) | CONFORMANCE_SPEC.md §5.24.1, §5.5.8 | Yes | behavioral |
| BEHAV-11-006 | An EMPTY intersection admits no leaf and the output position takes the semiring identity `0̄` (§5.5.6 identity fill) — not a hole, not `NaN`. Many-to-many is unaffected: the intersection is over POSITIONS, so all `m·n` terms of a duplicated key still appear | CONFORMANCE_SPEC.md §5.24.2, RFC semiring-faq-unified-ir §5.3 | Yes | behavioral |
| BEHAV-11-007 | The `filter` predicate an `on` clause lowers to MUST be evaluated on the key values AS STORED, in the binding's widest precision, and MUST NOT be narrowed to the document's `domain.element_type`. A join key is an exact-equality value and `==` returns an exact flag, so there is nothing to round — and a binary32 `==` calls two NONROAD SCCs five apart equal, which makes BEHAV-11-005 false | CONFORMANCE_SPEC.md §5.5.8, §5.18 | Yes | behavioral |
| BEHAV-11-008 | A both-contracted gate cannot be intersected (neither side is bound); one MAY drive the partner-restricted walk and MUST intersect its partner list with what the bound gates already admitted for that axis | CONFORMANCE_SPEC.md §5.24.2, §5.5.8 | Yes | performance |

> **Binding status (2026-09-04): Rust implements all eight.**
> `simulate_array/eval.rs::resolve_join_gates` resolves every drivable clause and
> sorts by `JoinGate::selectivity_cmp` (`i128` rational, `clause_ix` tiebreak) for
> -001/-002/-003; `reduce_contraction_gated` intersects per contracted axis for
> -004/-006 and composes that with the partner-restricted walk for -008;
> `join.rs::equality_predicate` wraps the comparison in
> `precision_infer::mark_exact_key_comparison` for -007. -005 is asserted three
> ways in `tests/join_on_conjunctive_gate.rs` — every permutation of a node's
> clauses against a plain-Rust oracle, against the hand-written `filter` the
> clauses lower to, and against the same document with the driver killed — and
> once more end-to-end, as a byte-diff of the 144-row `nr-logging-county`
> fixture against the pre-change binary.
>
> **-007 is a fix, not a capability.** It bites only where a document declares a
> working precision narrower than its key magnitudes need — the normal state of a
> MOVES port, whose quantities are binary32 and whose SCC and polProcessID keys
> are nine- and ten-digit integers.
>
> **The other four bindings were checked (2026-09-05) and none has it**, which is
> a stronger result than "not yet audited" and a different one from what this
> note previously guessed. It said Julia, Python and TypeScript each lower an
> `on` pair to an equality predicate the same way. **They do not**, and that is
> why they are immune:
>
> | binding | verdict | basis |
> |---|---|---|
> | Julia | structurally immune | never builds a comparison expression from a join. Each pair is a `_JoinGate` of `Dict{Int,Int}` bucket codes (`types.jl:155`), encoded by `_encode_join_keys` (`tree_walk/semiring.jl:349`) and tested by integer `==` in `_join_admits` (`semiring.jl:649`). `broad_phase.jl:287` states the resulting invariant outright. Measured: 4, in both clause orders. |
> | Python | structurally immune | same shape — `_resolve_join` (`numpy_interpreter.py:3046`) builds int-code gates, compared by `int` `!=` in `_join_admits` (`:3262`) and by int64 arrays in `_join_admits_mask` (`:2052`). Measured: 4, in both clause orders. |
> | Go, TypeScript | cannot exhibit it | no numeric evaluation at all (§5.5.8's binding table, this file's Go/TS rows). No join is evaluated, so no comparison is lowered. |
>
> Rust was alone in lowering the comparison, which is why it was alone in getting
> it wrong. **A binding with no lowered predicate has no -007 to fail** — but it
> also has no `filter` to fall back on, so for it -005 rests entirely on
> `_join_admits` re-testing every gate, which is what `semiring.jl:263` records.
>
> The control that makes those two nulls mean something is a `Float32` document
> with integer keys straddling a binary32 collision (`2265007010` / `2265007015`;
> binary32 spacing at that magnitude is 256) and two clauses over the same symbol
> pair. Exact-key semantics admit 4 combinations; a binary32 key comparison
> admits 8. On the pre-fix Rust binary it gives **4 in one clause order and 8 in
> the other**; on Rust after -007, 4 in both. So the probe reproduces the defect
> it is being used to rule out.
>
> **Separately, and NOT -007:** with the key columns left at the document's
> `Float32` default rather than overridden to `Float64`, Rust answers **8** in
> every clause order, before and after the fix, while Julia and Python answer
> **4**. Rust's 8 is §5.18/F18 — the key column was narrowed at INGEST, before any
> comparison, and `2265007104` is exactly integral so no integrality guard fires.
> Julia's and Python's 4 is the opposite gap: neither honours
> `domain.element_type` outside the recurrence sweep at all (`element_type` is
> read nowhere in Julia's evaluator; Python reads `ctx.element_types` only at
> `simulation_array.py:686`), so they are right here by not implementing the
> declaration — and wrong wherever binary32 rounding is what the reference
> actually does, which §5.18.1 opens by measuring. Three executing bindings, two
> answers, no diagnostic on any of them. §5.18.2 already requires the refusal
> that would surface it, and **PREC-11-A's binding status below already records
> the gap** — this measurement is a witness for that row, not a new finding. What
> it adds is that the divergence is reachable through a JOIN KEY and not only
> through arithmetic, so it changes an answer's row membership rather than its
> last ulp.
>
> **-001/-002/-004 are SHOULDs.** A binding that declines is slower, not wrong:
> the lowered `filter` still decides every leaf. Julia's tree-walk and Python's
> NumPy interpreter both currently drive one gate, so both are conforming and
> both leave the same 500×–2,000× on the table that Rust did; TypeScript and Go
> have no evaluator and are unaffected.

### BEHAV-08-B: Data-Source Location Resolution (esm-spec §8.2.1)

Unlike BEHAV-04-B (remote refs) and §4.7's `${VAR}` expansion in a `ref`, this is
**not** an optional capability with a per-binding matrix. §8.2.1 decides where a
document's data comes from, so a binding that resolved differently — or not at
all — would make the same checked-in document mean two different things. That is
the non-portability the rule exists to remove, so there is no coherent reduced
capability and no binding is exempt.

| ID | Requirement | Spec Reference | Testable | Test Category |
|---|---|---|---|---|
| BEHAV-08-B-001 | All five bindings implement §8.2.1 resolution identically, pinned by the shared `tests/conformance/data_source_url/manifest.json` (CONFORMANCE_SPEC §5.22); `bindings_required` is all five | esm-spec.md §8.2.1 | Yes | behavioral |
| BEHAV-08-B-002 | The conformance pin compares the RESOLVED PATH, not merely that a read succeeded — a rule that resolves to a different file and reads it successfully is a silent-wrong-value defect no error-only assertion can catch | CONFORMANCE_SPEC §5.22.2 | Yes | behavioral |
| BEHAV-08-B-003 | Resolution is idempotent (its output is scheme-led), so `parse → emit → parse` is stable; the resolved form is what `emit` carries, which is what makes the rule observable in a validate-only binding (Go, TypeScript have no ingest) | esm-spec.md §8.2.1 | Yes | behavioral |

**Status: all five bindings conform.** Julia
`pkg/EarthSciAST.jl/test/data_source_url_conformance_test.jl`, TypeScript
`pkg/earthsci-ast-ts/src/data-source-urls.test.ts`, Python
`pkg/earthsci-ast-py/tests/test_data_source_url_conformance.py`, Rust
`pkg/earthsci-ast-rs/tests/data_source_url_conformance.rs`, Go
`pkg/earthsci-ast-go/pkg/esm/data_source_url_conformance_test.go`.

### FORMAT-08-A: Data Loader Fields
| ID | Requirement | Spec Reference | Testable | Test Category |
|---|---|---|---|---|
| FORMAT-08-A-001 | kind field MUST be present (`grid`, `points`, or `static`) | esm-spec.md §8.1 | Yes | format |
| FORMAT-08-A-002 | source field MUST be present with url_template | esm-spec.md §8.2 | Yes | format |
| FORMAT-08-A-002a | `source.url_template` and every `source.mirrors` entry MUST be resolved at load: scheme-led used unchanged, `{`-led used unchanged, absolute path dot-segment-removed then `file://`-prefixed, RELATIVE path joined onto the directory of the file that declared it (§4.7's base) then dot-segment-removed and `file://`-prefixed. Dot-segment removal is LEXICAL (RFC 3986 §5.2.4), never `realpath`. REQUIRED of every binding — not optional, because it decides which bytes a document reads | esm-spec.md §8.2.1 | Yes | behavioral |
| FORMAT-08-A-002b | Environment variables MUST NOT be expanded in a `url_template` or mirror; a template containing `${` MUST be REFUSED at load with `data_source_url_unresolved`, whose message MUST name both the document site and the offending template. A resolved path containing `?` or `#` MUST be refused the same way. It MUST NOT be skipped, and MUST NOT be allowed to deliver an empty read or a consuming parameter's `default` | esm-spec.md §8.2.1 | Yes | behavioral |
| FORMAT-08-A-003 | variables field MUST be present and non-empty | esm-spec.md §8.5 | Yes | format |
| FORMAT-08-A-004 | each variable MUST have file_variable and units | esm-spec.md §8.5 | Yes | format |
| FORMAT-08-A-005 | if spatial is present, crs and grid_type MUST be present | esm-spec.md §8.4 | Yes | format |
| FORMAT-08-A-006 | a `reader_options` key the bound reader does not recognise MUST be an error, never ignored | esm-spec.md §8.9.1 | Yes | behavioral |
| FORMAT-08-A-007 | a text column with no `codes` map MUST be rejected at the loader boundary (a forcing is numeric) | esm-spec.md §8.9.1 | Yes | behavioral |
| FORMAT-08-A-008 | `record_filter` / `codes.unmapped:"drop"` MUST drop the RECORD from every variable of the loader (columns stay aligned) | esm-spec.md §8.9.3 | Yes | behavioral |
| FORMAT-08-A-009 | `select` is over the DELIVERED axis (it follows `record_filter`), and pushing it to the reader vs applying it after MUST agree | esm-spec.md §8.9.2 | Yes | behavioral |
| FORMAT-08-A-010 | `extent.metaparameter` MUST be closed from the loader's delivered record count before metaparameters are closed; disagreeing variables, and a contradicting caller binding, MUST error | esm-spec.md §8.9.4 | Yes | behavioral |
| FORMAT-08-A-011 | a variable's `unit_conversion` MUST be applied when producing values in the declared `units` — both spellings (a numeric factor and an Expression AST evaluated per element with the raw value bound to its single free variable); a variable declaring none MUST deliver the raw column unchanged | esm-spec.md §8.5 | Yes | behavioral |

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
| VALID-03-B-008 | MUST use event_affects_parameter code | esm-libraries-spec.md:283 | Yes | validation |
| VALID-03-B-009 | MUST use null_reaction code | esm-libraries-spec.md:284 | Yes | validation |
| VALID-03-B-010 | MUST use data_source_undefined code | esm-libraries-spec.md:285 | Yes | validation |
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
> **Go port (2026-07-03)**: implemented in `pkg/earthsci-ast-go/pkg/esm/template_imports.go`
> (`applyEdgeRenames` + `renameWalk`/`renameDecl`/`nameMap`/`collectBoundSyms`/`collectRefNames`,
> called from `resolveImportEntry` after `only` filtering, before the §9.7.4/§9.7.5 merge).
> Goldens `import_rename_two_instances`, `import_rebind_keyed_factors`, `import_rename_diamond`
> byte-identical; `rename_unknown_name` / `rebind_unknown_free_name` / `rename_collision` /
> `rename_invalid_identifier` raise the mapped diagnostics (`go test ./...`).
> **TypeScript = implemented (2026-07-03)**: `applyEdgeRenames` + `renameWalk` /
> `renameDecl` / `nameMap` / `collectBoundSyms` / `collectRefNames` in
> `pkg/earthsci-ast-ts/src/template_imports.ts`, called from
> `resolveImportEntry` after `bindings`/`only` and before the merge; `where` added
> to `META_SUBST_SKIP_KEYS`. Byte-identity (via `toEqual`) confirmed against the
> Julia goldens for `import_rename_two_instances`, `import_rebind_keyed_factors`,
> `import_rename_diamond`; the four invalid fixtures raise the exact codes
> (`rename_unknown_name`, `rebind_unknown_free_name`, `rename_collision`,
> `rename_invalid_identifier`). Tests in `src/template-imports.test.ts`.
> **Rust (2026-07-03)**: implemented (`earthsci-ast-rs/src/template_imports.rs` —
> `apply_edge_renames` + `name_map`/`rename_walk`/`rename_decl`/`collect_bound_syms`/
> `collect_ref_names`, `is_valid_dotted_name`, `RENAME_AXIS_KEYS`/`RENAME_EXTRA_PROTECTED_KEYS`,
> `where` added to `META_SUBST_SKIP_KEYS`; called from `resolve_import_entry` after
> `only` filtering). Byte-identical goldens for `import_rename_two_instances`,
> `import_rebind_keyed_factors`, `import_rename_diamond` (EXPR-09-F-008), verified via
> the `canonical_expand` example and the `template_imports_conformance` suite. AST byte
> identity for full-precision float literals also required the serde_json `float_roundtrip`
> feature (default fast path was 1 ulp off on some 16-17-digit literals).
> **Python (2026-07-03)**: implemented (`earthsci_ast/template_imports.py`
> `_apply_edge_renames`, called per import edge after `bindings`/`only`, before merge).
> Goldens byte-identical: `import_rename_two_instances`, `import_rebind_keyed_factors`,
> `import_rename_diamond`. Invalid fixtures raise the mapped diagnostics
> `rename_invalid_identifier`).
>
> **`where.*.shape` rewrite (2026-07-03, EXPR-09-F-003)**: an import-edge
> `prefix`/`rename` MUST carry a `where`-constrained rule's `where.*.shape`
> index-set names through the edge's index-set map in lockstep with the rule's
> declaration and body references (constraint KEYS — param names — stay
> unchanged; unmapped shape names stay as spelled). Previously the rename walk
> reused the metaparameter `_META_SUBST_SKIP_KEYS` (which protects `where`) and
> copied `where` verbatim, so an imported `where`-rule renamed under `prefix`
> failed rule registration with `template_constraint_unknown_index_set`
> (body/registry used `<prefix>.x` while `where` still said `x`). Fixed in the
> RENAME walk only (META-SUBST still skips `where`) via a positional `where`
> branch (`_rename_where` / `rename_where` / `renameWhere`) in **all five
> bindings** (`template_imports.jl`, `template_imports.py`, `template_imports.rs`,
> `template_imports.ts`, `template_imports.go`). Guarded by the combined fixture
> `import_where_rename_two_instances` (a `where`-rule library imported twice
> under prefix `meshA`/`meshB`; each renamed rule instance fires only on its own
> field — five-way byte-identical expanded AST) and the negative fixture
> `import_where_rename_unknown_index_set` (a `where` shape naming a set the
> library never declares survives the rename as spelled and is rejected at
> registration with `template_constraint_unknown_index_set`).

| ID | Requirement | Spec Reference | Testable | Test Category |
|---|---|---|---|---|
| EXPR-09-F-001 | Edge pipeline order MUST be: target's own-scope resolution → `bindings` → `only` → `prefix`/`rename`/`rebind` → merge; `only`/`bindings`/`rename`/`rebind` speak the target's export vocabulary (pre this edge's rename) | esm-spec.md §9.7.7 | Yes | expression |
| EXPR-09-F-002 | `prefix` MUST rename every surviving exported name without an explicit `rename` entry to `<prefix>.<name>`; `rename` entries override; prefixes nest through re-export chains (deeper edges and the loader API bind the renamed, dotted names) | esm-spec.md §9.7.7 | Yes | expression |
| EXPR-09-F-003 | Renames MUST apply transitively through the pinned occurrence sites: index-set registry keys / registry `of` / `{"from"}` refs / `wrt`-`dim` scalar fields / `where.*.shape` match-scoping index-set names in `body` AND `match` (param-shadowed); metaparameter keys / expression-position bare strings / structural-site names; template keys / `apply_expression_template.name` | esm-spec.md §9.7.7 | Yes | expression |
| EXPR-09-F-004 | `rebind` MUST rewrite free variable names in bodies/matches (incl. `aggregate` `args` and `index` gathers) and ragged `offsets`/`values`; dotted targets are §4.6 scoped references | esm-spec.md §9.7.7 | Yes | expression |
| EXPR-09-F-005 | Renaming a name the target does not export at the edge is `template_import_rename_unknown_name`; rebinding a non-occurring or declared name is `template_import_rebind_unknown_name`; rebinding a bound index symbol is `template_import_rename_invalid` | esm-spec.md §9.7.7 | Yes | validation |
| EXPR-09-F-006 | Post-rename names MUST be unique per namespace and new bare names fresh (no capture of free names, bound symbols, or params): `template_import_rename_collision`; `prefix`/targets MUST be dotted identifiers: `template_import_rename_invalid` | esm-spec.md §9.7.7 | Yes | validation |
| EXPR-09-F-007 | Same file under different renames = distinct registrations (no deep-equal dedup across renames); identical `ref` + instantiation + renames = dedupe at first occurrence; renamed `match`-rule instances register at their edges' §9.7.4 positions and identical patterns tie-break by that order | esm-spec.md §9.7.4, §9.7.7 | Yes | expression |
| EXPR-09-F-008 | All five bindings MUST produce byte-identical post-lowering canonical ASTs for `import_rename_two_instances`, `import_where_rename_two_instances`, `import_rebind_keyed_factors`, `import_rename_diamond` | esm-spec.md §9.6.7 | `tests/conformance/expression_templates/import_rename_*`, `import_where_rename_*`, `import_rebind_*` | expression |

### EXPR-09-G: Match-Pattern Scoping Constraints (`where`, esm-spec §9.6.1; RFC match-pattern-scoping-constraints)

> Binding status: Julia reference implementation landed (2026-07); Python / Rust /
> TypeScript / Go ports pending (wave 2 — RFC §10 porting checklist).
>
> **Go port (2026-07-03)**: implemented in `pkg/earthsci-ast-go/pkg/esm/lower_expression_templates.go`
> (`componentShapeEnv` / `whereSatisfied` / `registeredWhere`, threaded through `matchRule.whereC`
> and `rewritePass`/`rewriteToFixpoint`; `where` structural checks in `validateTemplates`; `where`
> added to `metaSubstSkipKeys`). Goldens `constrained_match_scope`, `two_div_two_meshes`,
> `per_variable_scheme_literal_args` byte-identical (models.m.variables); `constraint_unknown_index_set`
> raises `template_constraint_unknown_index_set` (`go test ./...`).
> **TypeScript = implemented (2026-07-03)**: `where` structural validation in
> `validateTemplates`, plus `componentShapeEnv` / `whereSatisfied` /
> `registeredWhere` and the `whereConstraint`/`shapeEnv` threading through the
> §9.6.3 engine (`onePass` / `rewriteToFixpoint`) in
> `pkg/earthsci-ast-ts/src/lower_expression_templates.ts`; `where` added to
> `META_SUBST_SKIP_KEYS` (G-008). Byte-identity confirmed for
> `constrained_match_scope`, `two_div_two_meshes`, `per_variable_scheme_literal_args`;
> `constraint_unknown_index_set` rejected at load with
> `template_constraint_unknown_index_set`. The two non-fixture pins
> (filter-before-priority, compound-arg-conservative) are unit-tested. Tests in
> `src/expression-templates.test.ts`.
> **Rust (2026-07-03)**: implemented (`earthsci-ast-rs/src/lower_expression_templates.rs`
> — `where` structural validation in `validate_templates`, `component_shape_env`,
> `registered_where` (`template_constraint_unknown_index_set` against the document
> `index_sets` registry), `where_satisfied` checked as match eligibility in `rewrite_pass`,
> `MatchRule.where_c`). Goldens `constrained_match_scope`, `two_div_two_meshes`,
> `per_variable_scheme_literal_args` match and `constraint_unknown_index_set` rejects at load
> (EXPR-09-G-009), via the `expression_templates_conformance` suite.
> **Python (2026-07-03)**: implemented (`earthsci_ast/lower_expression_templates.py`
> `_component_shape_env` / `_where_satisfied` / `_registered_where`; constraint filtering
> in `_rewrite_pass` before priority selection; `where` added to `_META_SUBST_SKIP_KEYS`).
> Goldens match (models/index_sets): `constrained_match_scope`,
> `per_variable_scheme_literal_args`, `two_div_two_meshes`. Error fixture
> `constraint_unknown_index_set` raises `template_constraint_unknown_index_set`;
> filter-before-priority and compound-arg-conservative pins covered as unit tests.

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

### SERIAL-05-A: Canonical Number Formatting (CONFORMANCE_SPEC §5.5.3.1)
| ID | Requirement | Spec Reference | Testable | Test Category |
|---|---|---|---|---|
| SERIAL-05-A-001 | Integral, `Int64`-representable numbers serialize as integer literals regardless of source spelling (`0.0` → `0`) — rule 1, applied uniformly at the AST-literal boundary | CONFORMANCE_SPEC.md §5.5.3.1 rule 1 | Yes | serialization |
| SERIAL-05-A-002 | Non-integral finite floats use shortest round-trip formatting (Julia-style positional/scientific split) | CONFORMANCE_SPEC.md §5.5.3.1 rule 2 | Yes | serialization |
| SERIAL-05-A-003 | Arithmetic-op operand literal types are by value, not reader-inferred storage: an **integer operand of `+ - * / ^ neg` stays an integer literal inside AND outside an `aggregate` `expr` body**. A binding whose JSON reader widens a bare integer token to float (Julia `JSON3` structural inference) MUST re-apply rule 1 when building the AST | CONFORMANCE_SPEC.md §5.5.3.1 rule 3 | Yes | serialization |
| SERIAL-05-A-004 | An integer ratio `{op:"/",args:[1,N]}` has one canonical byte form all five bindings produce identically; `/` is true (float-returning) division at evaluation (`1/8` = `0.125`), so integer operands are value-preserving | CONFORMANCE_SPEC.md §5.5.3.1 rule 3 | Yes | serialization |

**Conformance fixture:** `tests/valid/aggregate/coordinate_int_ratio_spacing.esm` (registered in `tests/conformance/round_trip/manifest.json`, tag `ess-aggregate-intdiv`) authors cell-centre spacing `(i − 1/2)·(1/N)` with the exact integer ratio `{op:"/",args:[1,8]}` / `[1,16]` INSIDE an `aggregate` `expr` body; all five bindings (julia/python/rust/ts/go) MUST round-trip it byte-identically, and the inline `tests` block pins the values (`coordA[1]=0.0625`, i.e. `0.5·(1/8)`; `coordB[1]=0.03125`). Julia regression guard: `parse_test.jl` "Integer ratio inside aggregate stays integer (§5.5.3.1)" loads a `cos(pi·…)`-nested document that provokes the JSON3 widening and asserts the ratio re-serializes as `1/8`, not `1.0/8.0`.

---

## 9b. WORKING-PRECISION REQUIREMENTS

### PREC-11-A: `domain.element_type` is the evaluation precision (esm-spec §11.3.1, CONFORMANCE_SPEC §5.18)

| ID | Requirement | Spec Reference | Testable | Test Category |
|---|---|---|---|---|
| PREC-11-A-001 | `element_type: "Float32"` MUST make the evaluator compute in IEEE binary32, rounding **once per operation** — not store-as-f32/compute-in-f64 | CONFORMANCE_SPEC §5.18.1 | Yes | simulation |
| PREC-11-A-002 | A reduction's ⊕ MUST round per accumulation step; an N-term sum rounds N times | CONFORMANCE_SPEC §5.18.1 | Yes | simulation |
| PREC-11-A-003 | Literals (including a `const` op's raw JSON value), parameter values, initial conditions and host-supplied arrays MUST round on ingress | CONFORMANCE_SPEC §5.18.1 | Yes | simulation |
| PREC-11-A-004 | Build-time constant folding MUST round identically to run-time evaluation | CONFORMANCE_SPEC §5.18.1 | Yes | simulation |
| PREC-11-A-005 | Index expressions keep integer semantics; a declared index-set extent above `2^24` MUST be rejected under Float32 rather than let a subscript round | CONFORMANCE_SPEC §5.18.1 | Yes | simulation |
| PREC-11-A-006 | `element_type: "Float64"` (and an absent field) MUST be bit-unchanged from a runtime with no precision support at all | CONFORMANCE_SPEC §5.18.1 | Yes | simulation |
| PREC-11-A-007 | An `element_type` that is neither `"Float64"` nor `"Float32"` MUST error (`unsupported_element_type`), never evaluate in binary64 | CONFORMANCE_SPEC §5.18.2 | Yes | validation |
| PREC-11-A-008 | Under Float32, a construct whose numerics are binary64-only (`intersect_polygon`, `polygon_intersection_area`, `interp.linear`, `interp.bilinear`, `datetime.julian_day`) MUST error naming it (`float32_unsupported`) | CONFORMANCE_SPEC §5.18.2 | Yes | validation |
| PREC-11-A-009 | Under Float32, TIME INTEGRATION MUST error naming it (the solver is binary64); algebraic / observed / relational evaluation is unaffected | CONFORMANCE_SPEC §5.18.2 | Yes | validation |
| PREC-11-A-010 | Conformance assertions on precision MUST be exact (bit) comparisons, not tolerances — a tolerance cannot see the one-ulp difference the contract is about | CONFORMANCE_SPEC §5.18.4 | Yes | simulation |
| PREC-11-A-011 | `ModelVariable.element_type` MUST override `domain.element_type` for that variable AND for the arithmetic over it; absent, it is the document's | CONFORMANCE_SPEC §5.18.2a | Yes | simulation |
| PREC-11-A-012 | Precision MUST propagate statically from an expression's leaves: a numeric literal adopts its context, a variable carries its declaration, an operator evaluates at its operands' | CONFORMANCE_SPEC §5.18.2a | Yes | simulation |
| PREC-11-A-013 | A comparison / logical operator's operands MUST agree with each other and be evaluated at THEIR precision; the 0/1 flag it returns is exact, so the operator is context-adopting to its parent | CONFORMANCE_SPEC §5.18.2a | Yes | simulation |
| PREC-11-A-014 | An operator mixing two declared element types, or an equation whose right-hand side disagrees with its left-hand side, MUST error naming both variables (`mixed_element_type`) — never a widest-operand resolution | CONFORMANCE_SPEC §5.18.2a | Yes | validation |
| PREC-11-A-015 | An exempt variable MUST stay exempt through ARITHMETIC, not only through ingress: `floor(scc/1000)*1000` is `2260007000` in binary64 and `2260006912` in binary32 | CONFORMANCE_SPEC §5.18.2a | Yes | simulation |
| PREC-11-A-016 | A compiled artifact MUST carry the per-variable table and re-arm it at every run entry, not only at build | CONFORMANCE_SPEC §5.18.2a | Yes | simulation |
| PREC-11-A-017 | A document in which no variable declares an `element_type` MUST be bit-unchanged, on the same code path, from PREC-11-A-001…010 alone | CONFORMANCE_SPEC §5.18.2a | Yes | simulation |

**Binding status.** Rust implements PREC-11-A-001…017
(`pkg/earthsci-ast-rs/src/precision.rs`, gated by
`pkg/earthsci-ast-rs/tests/precision_element_type.rs` and the witness fixtures in
`pkg/earthsci-ast-rs/tests/fixtures/precision/`; the per-variable half in
`pkg/earthsci-ast-rs/src/precision_infer.rs`). **Julia, Python, Go and
TypeScript parse and round-trip `domain.element_type` but do not honour it**: a
`"Float32"` document evaluates in binary64 there, which is the divergence this
row exists to record. To match PREC-11-A-001…010, each needs (a) an
active-precision mode threaded to wherever it evaluates expressions, (b)
per-operation rounding at every such site — including any monomorphized /
vectorized fast path, which in Rust was four of the five arithmetic definitions
and the one the witness actually executed (CONFORMANCE_SPEC §5.18.3) — (c)
ingress rounding, and (d) the three refusals of §5.18.2. Python can lean on
`numpy.float32` for (b) provided it narrows at every operation rather than only
at storage; Julia's `Float32` and Go's `float32` give (b) natively once the
values are typed; TypeScript has only `Math.fround`, which gives correctly-rounded
`+ - * / sqrt` on already-rounded operands but not binary32 elementary functions.

For PREC-11-A-011…017 on top of that, each of the four needs, in order:

1. **The field on the variable type.** `element_type` alongside `type` on
   `ModelVariable` — a separate field, never an overload of `type`, which is the
   semantic role (`unknown` / `parameter`). The JSON Schema already carries it,
   so a binding that models variables loosely (Python's dict, TypeScript's
   generated interface) gets parsing and round-trip for free and needs only the
   two steps below.
2. **The inference pass**, run after template expansion and `$ref` resolution
   and before anything lowers or evaluates an equation: one bottom-up walk per
   equation returning "this subtree's precision, or none (context-adopting)",
   raising `mixed_element_type` on a clash, and marking each subtree whose
   precision differs from its equation's. Rust's is ~150 lines
   (`precision_infer.rs`) and is the whole of PREC-11-A-012…014.
3. **Two arming points, not one.** The equation's precision on the RULE it
   compiles to (Rust: `precision::of_variable(rule.var)` at each site that
   evaluates one equation — the build-time observed materialization, the array
   runtime's observed pass, value invention, the scalar interpreter), and the
   marked subtrees by a guard around that subtree's evaluation. A binding whose
   evaluator fuses instructions across rules (Rust's tape) cannot carry a
   per-rule precision and must fall back to a per-rule path for such documents.
4. **The table on the compiled artifact** (PREC-11-A-016), re-armed at each run
   entry beside the document precision that is already recorded there.

Julia and Python, whose evaluators are per-node interpreters, need (3) at one
site each. Go and TypeScript are the same shape. None of the four needs a typed
integer path: binary64's 53-bit mantissa is exact for every integer below
9.0 × 10¹⁵, which covers every key these documents carry.

**Conformance fixtures:** `pkg/earthsci-ast-rs/tests/fixtures/precision/f32_per_op_rounding.esm`
and its Float64 twin `f64_per_op_rounding.esm` — the same expression,
`100 * ((100 - 73.5) / 100) / (100 - 73.5)`, over runtime parameters, asserted at
zero tolerance to `0.9999999403953552` and `1.0` respectively. For the
per-variable rows, `f32_per_variable_element_type.esm` (four assertions at zero
tolerance: the binary32 quantity, a binary64 key through ingress, the same key
through `floor(scc/1000)*1000`, and two codes ten apart that binary32 would make
equal) and `f32_mixed_element_types.esm`, which must not build.

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
| Serialization | 10 | 10 | serialization |
| Versioning | 4 | 4 | versioning |
| **TOTAL** | **138** | **138** | **10 categories** |

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