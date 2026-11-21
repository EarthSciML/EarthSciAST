---
title: "discrete_parameters"
description: "Stable function · Variable classification"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Variable classification](/generated/api/topics/classification)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `discrete_parameters` | `discreteParameters` | `discrete_parameters` | `discrete_parameters` | `DiscreteParameters` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
discrete_parameters(model::Model)
```

```julia
discrete_parameters(model::Model) -> Vector{String}
```

Parameters carrying any update OTHER than `wiener` — piecewise-constant between
refreshes (esm-spec §6.3.1). Sorted lexicographically. These are the sole seed
of the DISCRETE cadence class (CONFORMANCE_SPEC §5.7.2).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/EarthSciAST.jl/src/classification.jl#L312)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function discreteParameters(model: Model): string[]
```

Parameters carrying any OTHER update — piecewise-constant between refreshes.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-ts/src/classification.ts#L310)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
discrete_parameters(model: Any) -> list[str]
```

Parameters carrying any update OTHER than `wiener` — piecewise-constant
between refreshes (esm-spec §6.3.1), sorted.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-py/src/earthsci_ast/classification.py#L479)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn discrete_parameters(model: &Model) -> Vec<String>
```

Parameters carrying any OTHER update — piecewise-constant between
refreshes.

Names are sorted lexicographically, not in declaration order (API_SPEC.md §5.3).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-rs/src/classification.rs#L380) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.discrete_parameters.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func DiscreteParameters(model *Model) []string
```

DiscreteParameters returns the parameters carrying any update OTHER than `wiener` — piecewise-constant between refreshes. Sorted lexicographically.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-go/pkg/esm/classify.go#L138) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#DiscreteParameters)

</div>

</div>
