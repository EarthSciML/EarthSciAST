---
title: "conflicting_derivative_error"
description: "Stable error · Flatten"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** error · **Topic:** [Flatten](/generated/api/topics/flatten)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `ConflictingDerivativeError` | `ConflictingDerivativeError` | `ConflictingDerivativeError` | not exported | `ConflictingDerivativeError` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct ConflictingDerivativeError <: EarthSciASTError
ConflictingDerivativeError(species::Vector{String})
ConflictingDerivativeError(species)
```

```julia
ConflictingDerivativeError
```

Raised when a species appears both as the left-hand side of an explicit
differential equation (`D(X, t) = ...`) and as a substrate or product of any
reaction in the same flattened file. Such a system is over-determined: the
reaction contribution to `d[X]/dt` would silently shadow the user's equation.

Fields:
- `species::Vector{String}`: fully-qualified (dot-namespaced) names of every
  offending species.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/EarthSciAST.jl/src/flatten_errors.jl#L10)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
class ConflictingDerivativeError extends FlattenError
new ConflictingDerivativeError(message: string): ConflictingDerivativeError
```

Two systems define non-additive equations for the same dependent variable —
the §4.7.5 over-determination check. Such a system is over-determined: one
contribution to `d[X]/dt` would silently shadow the other.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-ts/src/flatten.ts#L128)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class ConflictingDerivativeError(FlattenError)
```

Two systems define non-additive equations for the same dependent variable.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-py/src/earthsci_ast/flatten.py#L77)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

<p class="api-absent">Rust does not export this error.</p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type ConflictingDerivativeError struct{ Message string }
func (e *ConflictingDerivativeError) Error() string
```

ConflictingDerivativeError reports that two source systems define non-additive equations for the same dependent variable (esm-libraries-spec §4.7.5 step 4's over-determination check). Such a system is over-determined: one contribution to d\[X\]/dt would silently shadow the other.

**Methods**

```go
func (e *ConflictingDerivativeError) Error() string
```

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-go/pkg/esm/flatten.go#L69) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ConflictingDerivativeError)

</div>

</div>
