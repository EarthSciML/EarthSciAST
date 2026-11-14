---
title: "Units"
description: "Parsing unit strings, converting between units and checking the dimensional consistency of equations."
type: "api"
---


| Operation | Kind | Bindings | Summary |
|---|---|---|---|
| [`apply_unit_conversion`](/generated/api/ref/apply_unit_conversion) | function | Julia, Python | Non-mutating `apply_unit_conversion!`: returns a converted copy, or `values` itself when there is nothing to apply. |
| [`build_unit_env`](/generated/api/ref/build_unit_env) | function | Rust, Go | Build a `HashMap<String, Unit>` environment from model variable metadata, together with a list of warnings for any variables whose declared unit string could not be parsed. |
| [`convert_units`](/generated/api/ref/convert_units) | function | TypeScript, Python, Rust | Convert a numeric value from one unit string to another. |
| [`parse_unit`](/generated/api/ref/parse_unit) | function | TypeScript, Rust, Go | Parse a unit string into canonical SI dimensions plus scale factor. |
| [`parse_unit_conversion`](/generated/api/ref/parse_unit_conversion) | function | Julia, Python | Parse a loader variable's RAW `unit_conversion` (`number \| Expression`). |
| [`validate_equation_dimensions`](/generated/api/ref/validate_equation_dimensions) | function | Julia, Rust, Go | Validate that an equation is dimensionally consistent. |
| [`validate_units`](/generated/api/ref/validate_units) | function | TypeScript, Python | Validate dimensional consistency of equations in an ESM file. |
| [`exact_scale`](/generated/api/ref/exact_scale) | type | Rust, Go | The EXACT scale of a unit relative to SI (esm-spec §4.8.1 "Scales are EXACT"). |
| [`unit`](/generated/api/ref/unit) | type | Rust, Go | Represents a physical unit with dimensions |
| [`unit_finding`](/generated/api/ref/unit_finding) | type | Julia, Python, Rust | A units finding: `subpath` RELATIVE to the owning model's JSON pointer (e.g. `"equations/0"`, `"variables/invalid_sum"`), a human-readable `message`, and the esm-spec §4.8.4… |
| [`unit_warning`](/generated/api/ref/unit_warning) | type | Julia, TypeScript, Python, Rust, Go | A single dimensional-analysis finding, in the STRUCTURED form the Python, TypeScript and Go bindings have always used and Julia did not: this field was a bare `Vector{String}`,… |
| [`unit_conversion_error`](/generated/api/ref/unit_conversion_error) | error | Julia, TypeScript, Python | A `unit_conversion` that cannot be parsed or applied. |
| [`unit_finding_analysis`](/generated/api/ref/unit_finding_analysis) | constant | Python, Rust, Go | The checker could not DETERMINE a dimension -- a symbolic exponent, an operator with no dimensional rule, an unknown variable, a missing pint. |
| [`unit_finding_dimensional_mismatch`](/generated/api/ref/unit_finding_dimensional_mismatch) | constant | Python, Rust, Go | A PROVABLE inconsistency: metres added to kilograms, an equation whose sides cannot agree. |
| [`unit_finding_unparseable`](/generated/api/ref/unit_finding_unparseable) | constant | Python, Rust, Go | A declared unit string that denotes no real unit. |

[All topics](/generated/api)
