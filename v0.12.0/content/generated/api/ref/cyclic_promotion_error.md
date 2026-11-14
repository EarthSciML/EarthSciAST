---
title: "cyclic_promotion_error"
description: "Stable error · Flatten"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** error · **Topic:** [Flatten](/generated/api/topics/flatten)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `CyclicPromotionError` | not exported | `CyclicPromotionError` | not exported | not exported |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct CyclicPromotionError <: EarthSciASTError
CyclicPromotionError(variables::Vector{String})
CyclicPromotionError(variables)
```

```julia
CyclicPromotionError
```

Defined for cross-language error-name parity. Not raised by Core-tier Julia
because no promotion graph is built — reserved for a future tier upgrade that
does promotion-graph analysis. Would signal that the declared `Interface`
rules form a cycle (A promotes to B, B promotes back to A on a different
axis).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/00808ba516066c29654f9613e987190c0347e352/pkg/EarthSciAST.jl/src/flatten_errors.jl#L318)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">TypeScript does not export this error.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class CyclicPromotionError(FlattenError)
```

Promotion rules form a cycle (A→B→…→A).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/00808ba516066c29654f9613e987190c0347e352/pkg/earthsci-ast-py/src/earthsci_ast/flatten.py#L281)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

<p class="api-absent">Rust does not export this error.</p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Go does not export this error.</p>

</div>

</div>
