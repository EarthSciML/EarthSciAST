---
title: "sampled_parameters"
description: "Stable function · Variable classification"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Variable classification](/generated/api/topics/classification)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `sampled_parameters` | `sampledParameters` | `sampled_parameters` | `sampled_parameters` | `SampledParameters` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
sampled_parameters(model::Model)
```

```julia
sampled_parameters(model::Model) -> Vector{String}
```

Parameters with a `distribution` and no `update` — drawn ONCE at setup
(uncertainty quantification, ensembles). Sorted lexicographically.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/EarthSciAST.jl/src/classification.jl#L328)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function sampledParameters(model: Model): string[]
```

Parameters with a `distribution` and no `update` — drawn once at setup.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-ts/src/classification.ts#L315)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
sampled_parameters(model: Any) -> list[str]
```

Parameters with a `distribution` and no `update` — drawn once at
setup (esm-spec §6.3.1), sorted.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-py/src/earthsci_ast/classification.py#L485)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn sampled_parameters(model: &Model) -> Vec<String>
```

Parameters with a `distribution` and no update — drawn once at setup.

Names are sorted lexicographically, not in declaration order (API_SPEC.md §5.3).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-rs/src/classification.rs#L387) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.sampled_parameters.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func SampledParameters(model *Model) []string
```

SampledParameters returns the parameters carrying a distribution and NO update — drawn once at setup (uncertainty quantification, ensembles). Sorted lexicographically.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-go/pkg/esm/classify.go#L147) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#SampledParameters)

</div>

</div>
