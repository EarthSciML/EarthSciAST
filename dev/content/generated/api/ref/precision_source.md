---
title: "precision_source"
description: "Stable function · Other"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Other](/generated/api/topics/other)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `precision_source` | `precisionSource` | `precision_source` | `precision_source` | `PrecisionSource` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
precision_source(document::EsmFile)
precision_source(document::EsmFile, variable::Union{Nothing, ModelVariable})
```

```julia
precision_source(document::EsmFile, [variable])
```

Return the declared element type or `"unspecified"` (esm-spec §11.3.3).
Omit the variable to query the document default, including for reaction
species and parameters.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/EarthSciAST.jl/src/mounts.jl#L586)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function precisionSource(document: EsmFile, variable?: Pick<ModelVariable, 'element_type'>): 'Float32' | 'Float64' | 'unspecified'
```

Return the declared element type or `unspecified`. With no variable, query the document default.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-ts/src/precision.ts#L23)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
precision_source(document: EsmFile, variable: ModelVariable | None = None) -> str
```

Return the declared element type, or `unspecified` for eligible omission.

Pass no variable to query the document default (also used by species and
reaction-system parameters).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-py/src/earthsci_ast/precision.py#L22)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn precision_source(document: &EsmFile, variable: Option<&ModelVariable>) -> Result<PrecisionSource, CompileError>
```

Return the source of a variable's working precision (esm-spec §11.3.3).
Pass `None` for the document default, including reaction species and parameters.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/precision.rs#L220) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/precision/fn.precision_source.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func PrecisionSource(document *ESMFile, variable *ModelVariable) string
```

PrecisionSource returns the declared element type or "unspecified" (§11.3.3). A nil variable queries the document default, including for reaction species and parameters.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-go/pkg/esm/precision.go#L12) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#PrecisionSource)

</div>

</div>
