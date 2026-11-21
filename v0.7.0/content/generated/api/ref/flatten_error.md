---
title: "flatten_error"
description: "Stable error · Flatten"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** error · **Topic:** [Flatten](/generated/api/topics/flatten)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | `FlattenError` | `FlattenError` | `FlattenError` | not exported |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

<p class="api-absent">Julia does not export this error.</p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
class FlattenError extends EsmDiagnosticError
new FlattenError(message: string, code?: string): FlattenError
```

Base class for every error [`flatten`](/generated/api/ref/flatten) raises. Mirrors Rust's
`FlattenError` and Python's `FlattenError` for cross-language error-name
parity.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-ts/src/flatten.ts#L116)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class FlattenError(EarthSciAstError)
```

Base class for errors raised during flatten().

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-py/src/earthsci_ast/flatten.py#L73)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub enum FlattenError {
    ConflictingDerivative { species: Vec<String> },
    DimensionPromotion { message: String },
    UnmappedDomain { systems: Vec<String>, candidate_targets: Vec<String> },
    UnsupportedMapping { mapping_type: String, reason: String },
    UnloweredOperator { op: String },
    DomainUnitMismatch { variable: String, source_units: String, target_units: String },
    DomainExtentMismatch { variable: String },
    SliceOutOfDomain { coordinate: String, value: String },
    CyclicPromotion { variables: Vec<String> },
    VariableMapFactorWithExpression { from: String, to: String },
    VariableMapExpressionMissingFrom { from: String, to: String },
    VariableMapUnresolvedEndpoint { from: String, to: String, side: String, endpoint: String },
    Reaction(DeriveError),
    CouplingImport(DiagnosticError),
    MalformedConnectorEquation { systems: String, side: String },
    CoupleMultiplicativeNoTendency { target: String },
    ContributionsOutOfStep { field: &'static str, entries: usize, equations: usize },
    OperatorComposeNoMerge { a: String, b: String, authored: usize, unmatched: String },
    OperatorComposeRequireMatchUnmatched { a: String, b: String, merged: usize, authored: usize, unmatched: String },
    OperatorComposeAmbiguousBareName { a: String, b: String, b_dep: String, target: String },
    MalformedLoaderSubsystem { system: String, subsystem: String, reason: String },
    ExpressionTemplate(DiagnosticError),
    Empty,
}
```

Errors raised by [`flatten`](/generated/api/ref/flatten) and [`flatten_model`](/generated/api/extension/rust#x-flatten_model) during spec-compliant
coupled-system flattening.

Variant names are deliberately cross-language-compatible so Julia, Python,
and Rust agents can report the same failure using the same error name.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-rs/src/flatten.rs#L66) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/enum.FlattenError.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Go does not export this error.</p>

</div>

</div>
