---
title: "dimension_promotion_error"
description: "Stable error · Flatten"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** error · **Topic:** [Flatten](/generated/api/topics/flatten)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `DimensionPromotionError` | `DimensionPromotionError` | `DimensionPromotionError` | not exported | `DimensionPromotionError` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct DimensionPromotionError <: EarthSciASTError
DimensionPromotionError(details::String)
DimensionPromotionError(details)
```

```julia
DimensionPromotionError
```

Raised during flatten when a variable or equation cannot be promoted from
its source domain to the target domain given the available `Interface` rules
(§4.7.6).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/EarthSciAST.jl/src/flatten_errors.jl#L149)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
class DimensionPromotionError extends FlattenError
new DimensionPromotionError(message: string): DimensionPromotionError
```

A variable or equation cannot be promoted onto the target grid — raised by the
§10.5 pointwise spatial lift when a species' operator makearrays yield no
full-rank interior-stencil gather.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/flatten.ts#L233)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class DimensionPromotionError(FlattenError)
```

A variable or equation cannot be promoted given the available Interfaces.

Raised when dimension promotion is ambiguous, when required dimension
metadata is missing, or when the promotion request would otherwise fail
independent of mapping-tier support — see spec §4.7.6.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-py/src/earthsci_ast/flatten.py#L182)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

<p class="api-absent">Rust does not export this error.</p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type DimensionPromotionError struct{ Message string }
func (e *DimensionPromotionError) Error() string
```

DimensionPromotionError reports that a variable or equation cannot be promoted onto the target grid (esm-libraries-spec §4.7.6): here, that the pointwise spatial lift (esm-spec §10.5) could not read the spatial loop variables off a species' operator makearray.

**Methods**

```go
func (e *DimensionPromotionError) Error() string
```

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-go/pkg/esm/flatten.go#L227) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#DimensionPromotionError)

</div>

</div>
