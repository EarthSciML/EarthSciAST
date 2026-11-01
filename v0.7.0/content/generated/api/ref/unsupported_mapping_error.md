---
title: "unsupported_mapping_error"
description: "Stable error · Flatten"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** error · **Topic:** [Flatten](/generated/api/topics/flatten)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `UnsupportedMappingError` | not exported | `UnsupportedMappingError` | not exported | not exported |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct UnsupportedMappingError <: EarthSciASTError
UnsupportedMappingError(mapping_type::String)
UnsupportedMappingError(mapping_type)
```

```julia
UnsupportedMappingError
```

Raised when an `Interface` requests a `dimension_mapping` type or regridding
strategy that is not supported by the current library tier (§4.7.6). The
`mapping_type` field carries the offending type or strategy name (e.g.
`"slice"`, `"project"`, `"regrid"`, or a specific regridding method like
`"cubic_spline"`). Matches the Rust `FlattenError::UnsupportedMapping` variant
and the Python `UnsupportedMappingError` exception for cross-language
error-name parity.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/EarthSciAST.jl/src/flatten_errors.jl#L178)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">TypeScript does not export this error.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class UnsupportedMappingError(FlattenError)
```

A dimension-promotion mapping is not supported by this implementation tier.

Core-tier libraries (the Python tier) only implement `broadcast` and
`identity` mappings; `slice`, `project`, and `regrid` raise this
error, as do spatial operators (`grad`, `div`, `laplacian`) when
encountered during a Core-tier flatten — see spec §4.7.6.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-py/src/earthsci_ast/flatten.py#L200)

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
