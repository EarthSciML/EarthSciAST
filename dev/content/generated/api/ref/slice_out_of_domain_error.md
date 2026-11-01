---
title: "slice_out_of_domain_error"
description: "Stable error · Flatten"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** error · **Topic:** [Flatten](/generated/api/topics/flatten)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `SliceOutOfDomainError` | not exported | `SliceOutOfDomainError` | not exported | not exported |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct SliceOutOfDomainError <: EarthSciASTError
SliceOutOfDomainError(coordinate::String, value::String)
SliceOutOfDomainError(coordinate, value)
```

```julia
SliceOutOfDomainError
```

Defined for cross-language error-name parity; only raised if `slice` is ever
implemented at a higher tier in the Julia flatten pipeline. Would be raised
when a `slice` mapping's fixed coordinate lies outside the source variable's
declared domain extent.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/EarthSciAST.jl/src/flatten_errors.jl#L235)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">TypeScript does not export this error.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class SliceOutOfDomainError(FlattenError)
```

A `slice` mapping reaches outside the source variable's domain.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-py/src/earthsci_ast/flatten.py#L223)

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
