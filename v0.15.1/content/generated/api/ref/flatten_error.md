---
title: "flatten_error"
description: "Stable error · Flatten"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** error · **Topic:** [Flatten](/generated/api/topics/flatten)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `FlattenError` | `FlattenError` | `FlattenError` | `FlattenError` | not exported |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
abstract type FlattenError <: EarthSciASTError
```

```julia
FlattenError <: EarthSciASTError
```

Supertype of the errors `flatten` raises about the document it flattens, as in
Python, TypeScript and Rust. Each subtype leads with `code::String`, the
diagnostic code a caller branches on (for a type whose message begins with a
code, `"<code>: …"`, that code). Its message is composed from its fields by
`_flatten_message`, and it prints through the package's one `showerror`. Each
keeps its positional constructor without the code, which it fills in.

A refusal the other bindings do not name with a type of its own is a
`FlattenRefusal` (unexported): catch it as `FlattenError` and read its code
with [`error_code`](/generated/api/extension/julia#x-error_code).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/EarthSciAST.jl/src/flatten_errors.jl#L5)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
class FlattenError extends EsmDiagnosticError
new FlattenError(message: string, code?: string, details?: Record<string, unknown>): FlattenError
```

Base class for every error [`flatten`](/generated/api/ref/flatten) raises. Mirrors Rust's
`FlattenError` and Python's `FlattenError` for cross-language error-name
parity.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/earthsci-ast-ts/src/flatten.ts#L123)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class FlattenError(EarthSciAstError)
```

Base class for errors raised during flatten().

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/earthsci-ast-py/src/earthsci_ast/flatten.py#L78)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub enum FlattenError {
    ConflictingDerivative { species: Vec<String>, message: String },
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
    VariableMapShapeConflict { from: String, to: String, source_shape: Vec<String>, target_shape: Vec<String>, took_shape: bool },
    Reaction(DeriveError),
    CouplingImport(DiagnosticError),
    MalformedConnectorEquation { systems: String, side: String },
    CoupleMultiplicativeNoTendency { target: String },
    OperatorComposeNoMerge { a: String, b: String, authored: usize, unmatched: String },
    OperatorComposeRequireMatchUnmatched { a: String, b: String, merged: usize, authored: usize, unmatched: String },
    OperatorComposeAmbiguousBareName { a: String, b: String, b_dep: String, target: String },
    RecordsPerSample(DiagnosticError),
    Empty,
}

impl FlattenError { pub fn code(&self) -> Option<&'static str> }
```

Errors raised by [`flatten`](/generated/api/ref/flatten) and [`flatten_model`](/generated/api/extension/rust#x-flatten_model) during spec-compliant
coupled-system flattening.

Variant names are deliberately cross-language-compatible so Julia, Python,
and Rust agents can report the same failure using the same error name.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/earthsci-ast-rs/src/flatten.rs#L68) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/enum.FlattenError.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Go does not export this error.</p>

</div>

</div>
