---
title: "unit_finding_dimensionless_literal"
description: "Stable constant · Other"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** constant · **Topic:** [Other](/generated/api/topics/other)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `UNIT_FINDING_DIMENSIONLESS_LITERAL` | not exported | `UNIT_FINDING_DIMENSIONLESS_LITERAL` | `UNIT_FINDING_DIMENSIONLESS_LITERAL` | `UnitFindingDimensionlessLiteral` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
const UNIT_FINDING_DIMENSIONLESS_LITERAL::String
```

```julia
UNIT_FINDING_DIMENSIONLESS_LITERAL::String
```

The `UnitWarning.code` of a check site that the current neutral-literal rule
passes or skips but that fails once a bare numeric literal is read as
dimensionless at scale 1 (esm-spec §4.8.6). Its value is
`"units_dimensionless_literal_mismatch"`. A WARNING at this stage:
[`validate`](/generated/api/ref/validate) reports it on `unit_warnings` and it never changes
`is_valid`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/EarthSciAST.jl/src/units.jl#L2421)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">TypeScript does not export this constant.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
UNIT_FINDING_DIMENSIONLESS_LITERAL = 'units_dimensionless_literal_mismatch'
```

A check the CURRENT neutral-literal rule skips or passes fails once a bare
numeric literal is read as dimensionless (esm-spec §4.8.6). A WARNING at this
stage: validity is decided by the current rule alone.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-py/src/earthsci_ast/units.py#L1117)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub const UNIT_FINDING_DIMENSIONLESS_LITERAL: &str = crate::diagnostic::codes::UNITS_DIMENSIONLESS_LITERAL_MISMATCH;
```

A check site the CURRENT neutral-literal rule passes or skips fails once a
nonzero bare numeric literal is read as dimensionless at scale 1 (esm-spec
§4.8.6). A WARNING at this stage: validity is decided by the current rule
alone.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-rs/src/units.rs#L493) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/constant.UNIT_FINDING_DIMENSIONLESS_LITERAL.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
const UnitFindingDimensionlessLiteral = "units_dimensionless_literal_mismatch"
```

UnitFindingDimensionlessLiteral — a check site the CURRENT neutral-literal rule passes or skips fails once a nonzero bare numeric literal is read as dimensionless at scale 1 (esm-spec §4.8.6). → WARNING at this stage; it becomes an error at the next major esm version.

Unit-finding codes. A unit finding is either a DEFECT IN THE FILE — which invalidates the document — or a limit of the ANALYSIS, which does not. The classification is decided at the point the finding is raised (never recovered later from the prose) and carried on UnitWarning.Code; ValidateStructuralWithCodes promotes the defect-bearing codes to `unit_inconsistency` structural errors.

The split is the cross-binding policy and mirrors TypeScript's units.ts:

- UnitFindingDimensionalMismatch — a PROVABLE inconsistency: adding metres to kilograms, log() of a dimensional quantity, an equation whose sides have different dimensions. The file is wrong. → HARD ERROR.
- UnitFindingUnparseable — a declared unit string that does not denote a real unit ("not\_a\_unit"). The file is wrong. → HARD ERROR.
- UnitFindingAnalysis — the checker cannot DETERMINE a dimension: a symbolic (non-literal) exponent, an operator with no dimensional rule (fn/table\_lookup), a malformed arity. That is a statement about the checker, not a defect in the file. → WARNING.
- UnitFindingDimensionlessLiteral — the esm-spec §4.8.6 warning stage: a site that fails only when nonzero bare literals are dimensionless. Never promoted. → WARNING.

An unknown VARIABLE is likewise never a mismatch (it propagates as "unknown" and suppresses the check); it is separately a hard `undefined_variable` error, so the units layer does not double-report it.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-go/pkg/esm/units.go#L1605) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#UnitFindingDimensionlessLiteral)

</div>

</div>
