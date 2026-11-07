---
title: "brownian_parameters"
description: "Stable function · Variable classification"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Variable classification](/generated/api/topics/classification)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `brownian_parameters` | `brownianParameters` | `brownian_parameters` | `brownian_parameters` | `BrownianParameters` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
brownian_parameters(model::Model)
```

```julia
brownian_parameters(model::Model) -> Vector{String}
```

Parameters whose `update.kind` is `"wiener"` — the SDE noise sources
(esm-spec §6.3.1). Sorted lexicographically. Their presence is what makes
[`system_kind`](/generated/api/ref/system_kind-function) `"sde"`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/EarthSciAST.jl/src/classification.jl#L297)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function brownianParameters(model: Model): string[]
```

Parameters whose `update.kind` is `wiener` — the SDE noise sources.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-ts/src/classification.ts#L305)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
brownian_parameters(model: Any) -> list[str]
```

Parameters whose `update.kind` is `"wiener"` — the SDE noise sources
(esm-spec §6.3.1), sorted.

With an update ARRAY a parameter is Brownian iff ANY rule is `wiener`. The
schema forbids `wiener` inside an array (a driving noise process is the
parameter's whole value), so in practice an array means discrete; the test is
written over all the rules anyway rather than assuming the schema held.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-py/src/earthsci_ast/classification.py#L459)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn brownian_parameters(model: &Model) -> Vec<String>
```

Parameters whose `update.kind` is `wiener` — the SDE noise sources.

Names are sorted lexicographically, not in declaration order (API_SPEC.md §5.3).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-rs/src/classification.rs#L372) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.brownian_parameters.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func BrownianParameters(model *Model) []string
```

BrownianParameters returns the parameters whose update is `wiener` — the SDE noise sources, resampled every step with √dt increment scaling. Sorted lexicographically.

With an update ARRAY a parameter is Brownian iff ANY rule is `wiener`; the schema forbids `wiener` inside an array, so in practice an array always means discrete. Checking every rule rather than the first keeps the classification correct on a document that slipped past a lenient schema check.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-go/pkg/esm/classify.go#L132) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#BrownianParameters)

</div>

</div>
