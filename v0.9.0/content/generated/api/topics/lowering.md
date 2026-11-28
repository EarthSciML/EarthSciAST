---
title: "Load-time lowering and templates"
description: "The passes a loader runs before a document is usable: enum lowering, subsystem references, expression templates and coupling imports."
type: "api"
---


| Operation | Kind | Bindings | Summary |
|---|---|---|---|
| [`apply_scope_injections`](/generated/api/ref/apply_scope_injections) | function | TypeScript, Rust | esm-spec §9.7.10 forms A + B: if `raw` needs a scope-directed injection (a non-empty subsystem-ref edge list `injected`, or a coupling entry carrying an injection map), return a… |
| [`desugar_pushdown`](/generated/api/ref/desugar_pushdown) | function | Python, Rust | Recognise the projection-pushdown pattern in `esm`'s named model and, when it matches, return a NEW document with the four constructs desugared in (a `kind:"derived"` index set,… |
| [`ephemeral_injected_file`](/generated/api/ref/ephemeral_injected_file) | function | TypeScript, Rust | esm-spec §9.7.10 form C: build a throwaway `EsmFile` in which component `mname` has the run's `imports` (raw §9.7.2 entries) appended to its own `expression_template_imports`, so… |
| [`expand_coupling_imports`](/generated/api/ref/expand_coupling_imports) | function | Julia, TypeScript, Python, Rust | Expand every `CouplingImport` entry in `file.coupling` into concrete edges, splicing them in the position of the import entry (esm-spec §10.10.3). |
| [`expand_document`](/generated/api/ref/expand_document) | function | TypeScript, Python | Fully expand every surviving `apply_expression_template` reference in a document `loaded` by `lowerExpressionTemplates` (Option B), producing the Option-A image: every reference… |
| [`is_coupling_library_doc`](/generated/api/ref/is_coupling_library_doc) | function | TypeScript, Python, Rust | True when `raw` has the coupling-library-file FORM (top-level `coupling_roles`, esm-spec §10.9). |
| [`is_template_library_doc`](/generated/api/ref/is_template_library_doc) | function | TypeScript, Rust | True when `raw` has the template-library-file FORM (top-level `expression_templates`, esm-spec §9.7.1). |
| [`lower_enums`](/generated/api/ref/lower_enums) | function | Julia, TypeScript, Python, Rust, Go | The PURE form: return a DEEP COPY of `file` with every `enum` op replaced by the `const` integer the file's `enums` block assigns it, leaving `file` untouched. |
| [`lower_enums_mut`](/generated/api/ref/lower_enums_mut) | function | Python, Rust, Go | In-place twin of `lower_enums`: lower every `enum` op in `file` itself, and return it (API_SPEC.md §8 item 15). |
| [`lower_expression_templates`](/generated/api/ref/lower_expression_templates) | function | Julia, TypeScript, Python, Go | Run the §9.6.3 rewrite fixpoint over `raw_data` against each component-local `expression_templates` block (esm-spec §9.6.4, Option B): auto `match` rules fire, EAGER… |
| [`materialize_value_invention`](/generated/api/ref/materialize_value_invention) | function | Python, Rust | Run the build-time value-invention engine over a raw model document. |
| [`resolve_subsystem_refs`](/generated/api/ref/resolve_subsystem_refs) | function | Julia, TypeScript, Python, Rust, Go | Resolve all subsystem references in-place. |
| [`resolve_template_machinery`](/generated/api/ref/resolve_template_machinery) | function | Julia, TypeScript, Python, Rust | Resolve every esm-spec §9.7 construct of the ROOT document `raw_data` (relative import refs resolve against `base_path`): imports recursively with per-edge instantiation,… |
| [`value_invention_result`](/generated/api/ref/value_invention_result) | type | Python, Rust | Result of `materialize_value_invention`. |
| [`circular_reference_error`](/generated/api/ref/circular_reference_error) | error | TypeScript, Python | Error thrown when a circular reference is detected during subsystem resolution. |
| [`enum_lowering_error`](/generated/api/ref/enum_lowering_error) | error | Julia, TypeScript, Python, Rust, Go | Raised when enum lowering (esm-spec §9.3) fails, carrying the stable diagnostic `code` as a structured field rather than interpolated into the message — the same shape as… |
| [`expression_template_error`](/generated/api/ref/expression_template_error) | error | Julia, TypeScript, Python, Go | Exception raised when a load-time lowering pass fails: expression-template expansion (esm-spec §9.6), template-library imports (§9.7), coupling-library imports (§10.9–§10.11),… |
| [`subsystem_ref_error`](/generated/api/ref/subsystem_ref_error) | error | Julia, Python | Exception thrown when subsystem reference resolution fails. |
| [`value_invention_error`](/generated/api/ref/value_invention_error) | error | Python, Rust | A value-invention build-time materialisation error. |
| [`max_template_expansion_depth`](/generated/api/ref/max_template_expansion_depth) | constant | TypeScript, Python, Go | Maximum template-body reference-chain depth (counted in TEMPLATES along the longest chain, so a 33-template chain is rejected while a 32-template chain is accepted) before a file… |

[All topics](/generated/api)
