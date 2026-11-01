---
title: "Flatten"
description: "Turning a coupled document into a single system of variables and equations, and the errors coupling can raise."
type: "api"
---


| Operation | Kind | Bindings | Summary |
|---|---|---|---|
| [`flatten`](/generated/api/ref/flatten) | function | Julia, TypeScript, Python, Rust, Go | Flatten the coupled systems in `file` into a single symbolic representation per spec §4.7.5 (+ §4.7.6 for hybrid dimension-promoted cases). |
| [`flatten_template_registries`](/generated/api/ref/flatten_template_registries) | function | TypeScript, Python | The flatten-time template-registry merge (esm-spec §9.6.4 rule 7, §10.7; esm-libraries-spec §4.7.5 step 4). |
| [`flatten_with_options`](/generated/api/ref/flatten_with_options) | function | Rust, Go | Flatten with explicit `CouplingImportOptions` controlling how `coupling_import` `ref`s resolve (esm-spec §10.10.3). |
| [`flatten_metadata`](/generated/api/ref/flatten_metadata) | type | Julia, TypeScript, Python, Rust, Go | Provenance metadata for a flattened system. |
| [`flattened_equation`](/generated/api/ref/flattened_equation) | type | TypeScript, Python, Go | A single equation of the flattened system, with dot-namespaced Expression TREES. |
| [`flattened_system`](/generated/api/ref/flattened_system) | type | Julia, TypeScript, Python, Rust, Go | A coupled ESM file flattened into a single symbolic representation. |
| [`flattened_variable`](/generated/api/ref/flattened_variable) | type | TypeScript, Python, Go | One variable of the flattened system, carrying the COMPLETE declared metadata step 4 requires ("Full metadata, not names"): a consumer must be able to build a solver problem from… |
| [`conflicting_derivative_error`](/generated/api/ref/conflicting_derivative_error) | error | Julia, TypeScript, Python, Go | Raised when a species appears both as the left-hand side of an explicit differential equation (`D(X, t) = ...`) and as a substrate or product of any reaction in the same… |
| [`couple_multiplicative_no_tendency_error`](/generated/api/ref/couple_multiplicative_no_tendency_error) | error | TypeScript, Python, Go | A `couple` connector equation with `transform: "multiplicative"` targets something with no tendency to multiply. |
| [`cyclic_promotion_error`](/generated/api/ref/cyclic_promotion_error) | error | Julia, Python | Defined for cross-language error-name parity. |
| [`dimension_promotion_error`](/generated/api/ref/dimension_promotion_error) | error | Julia, TypeScript, Python, Go | Raised during flatten when a variable or equation cannot be promoted from its source domain to the target domain given the available `Interface` rules (§4.7.6). |
| [`domain_extent_mismatch_error`](/generated/api/ref/domain_extent_mismatch_error) | error | Julia, Python | Defined for cross-language error-name parity with the Rust `FlattenError` taxonomy and the Python `flatten()` exception set. |
| [`domain_unit_mismatch_error`](/generated/api/ref/domain_unit_mismatch_error) | error | Julia, TypeScript, Python | Raised when coupling across an `Interface` requires a unit conversion that was not declared by the user (§4.7.6). |
| [`flatten_error`](/generated/api/ref/flatten_error) | error | TypeScript, Python, Rust | Base class for every error `flatten` raises. |
| [`operator_compose_ambiguous_bare_name_error`](/generated/api/ref/operator_compose_ambiguous_bare_name_error) | error | Julia, TypeScript, Python, Go | Raised when the bare-name fallback would unify two STATE variables and the document has not said which spelling survives (esm-libraries-spec §4.7.1 step 3). |
| [`operator_compose_no_merge_error`](/generated/api/ref/operator_compose_no_merge_error) | error | Julia, TypeScript, Python, Go | Raised when an `operator_compose` entry merges NOTHING (esm-libraries-spec §4.7.1 step 5). |
| [`operator_compose_require_match_error`](/generated/api/ref/operator_compose_require_match_error) | error | Julia, TypeScript, Python, Go | Raised when an `operator_compose` entry declares `require_match: true` and one of `systems[2]`'s equations found no equation of `systems[1]` to land on (esm-libraries-spec §4.7.1… |
| [`slice_out_of_domain_error`](/generated/api/ref/slice_out_of_domain_error) | error | Julia, Python | Defined for cross-language error-name parity; only raised if `slice` is ever implemented at a higher tier in the Julia flatten pipeline. |
| [`unmapped_domain_error`](/generated/api/ref/unmapped_domain_error) | error | Julia, Python | Raised when two systems on different domains are coupled without an `Interface` that defines their dimension mapping (§4.7.6). |
| [`unsupported_mapping_error`](/generated/api/ref/unsupported_mapping_error) | error | Julia, Python | Raised when an `Interface` requests a `dimension_mapping` type or regridding strategy that is not supported by the current library tier (§4.7.6). |

[All topics](/generated/api)
