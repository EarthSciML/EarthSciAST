---
title: "domain_extent_mismatch_error"
description: "Stable error · Flatten"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** error · **Topic:** [Flatten](/generated/api/topics/flatten)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `DomainExtentMismatchError` | not exported | `DomainExtentMismatchError` | not exported | not exported |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct DomainExtentMismatchError <: EarthSciASTError
DomainExtentMismatchError(variable::String)
DomainExtentMismatchError(variable)
```

```julia
DomainExtentMismatchError
```

Defined for cross-language error-name parity with the Rust `FlattenError`
taxonomy and the Python `flatten()` exception set. Would be raised when an
`identity` mapping bridges two domains whose spatial extents on a shared
independent variable disagree. The Julia flatten pipeline does not currently
perform this check, so this type is reserved and never raised by the current
implementation — it exists so consumers can catch it by name.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/flatten_errors.jl#L216)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">TypeScript does not export this error.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class DomainExtentMismatchError(FlattenError)
```

Two domains coupled via `identity` have incompatible spatial extents.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/flatten.py#L219)

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
