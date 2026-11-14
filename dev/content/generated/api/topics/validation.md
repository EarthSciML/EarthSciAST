---
title: "Validation"
description: "Checking a document against the schema and the structural rules of the specification, and reading the errors that result."
type: "api"
---


| Operation | Kind | Bindings | Summary |
|---|---|---|---|
| [`validate`](/generated/api/ref/validate) | function | Julia, TypeScript, Python, Rust, Go | Complete validation combining schema, structural, and unit validation. |
| [`validate_path`](/generated/api/ref/validate_path) | function | Julia, Python | Validate the document at `path`, INCLUDING the failures that happen while loading it. |
| [`validate_schema`](/generated/api/ref/validate_schema) | function | Julia, TypeScript | Validate `data` (a native JSON tree of `Dict`/`Vector`/scalars) against the ESM schema. |
| [`validate_structural`](/generated/api/ref/validate_structural) | function | Julia, Go | Validate structural consistency of ESM file according to spec Section 3.2. |
| [`validate_text`](/generated/api/ref/validate_text) | function | Julia, TypeScript, Python, Rust, Go | Validate an ESM document held as JSON **text**, INCLUDING the failures that happen while loading it. |
| [`schema_error`](/generated/api/ref/schema_error-type) | type | Julia, TypeScript | Represents a validation error with detailed information. |
| [`validation_error`](/generated/api/ref/validation_error) | type | TypeScript, Python | Validation error with structured details |
| [`validation_result`](/generated/api/ref/validation_result) | type | Julia, TypeScript, Python, Rust, Go | Combined validation result containing schema errors, structural errors, unit warnings, and overall validation status. |
| [`schema_error`](/generated/api/ref/schema_error-error) | error | Rust, Go | A schema validation error |
| [`schema_validation_error`](/generated/api/ref/schema_validation_error) | error | Julia, TypeScript, Python | Exception thrown when schema validation fails. |
| [`structural_error`](/generated/api/ref/structural_error) | error | Rust, Go | A structural validation error |

[All topics](/generated/api)
