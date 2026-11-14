---
title: "domain_unit_mismatch_error"
description: "Stable error · Flatten"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** error · **Topic:** [Flatten](/generated/api/topics/flatten)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `DomainUnitMismatchError` | `DomainUnitMismatchError` | `DomainUnitMismatchError` | not exported | not exported |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct DomainUnitMismatchError <: EarthSciASTError
DomainUnitMismatchError(variable::String, source_units::String, target_units::String)
DomainUnitMismatchError(variable, source_units, target_units)
```

```julia
DomainUnitMismatchError
```

Raised when coupling across an `Interface` requires a unit conversion that
was not declared by the user (§4.7.6).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/ae13cc8f0c7013724cd3011b89390f836e34b5ad/pkg/EarthSciAST.jl/src/flatten_errors.jl#L263)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
class DomainUnitMismatchError extends FlattenError
new DomainUnitMismatchError(message: string): DomainUnitMismatchError
```

An `identity`-transform `variable_map` bridges two variables whose declared,
non-empty units differ (esm-libraries-spec §4.7.6). `conversion_factor` and
`param_to_var` are exempt: the first declares the conversion explicitly, the
second does not imply unit equivalence at the mapping site.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/ae13cc8f0c7013724cd3011b89390f836e34b5ad/pkg/earthsci-ast-ts/src/flatten.ts#L233)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class DomainUnitMismatchError(FlattenError)
```

An Interface coupling requires a unit conversion that was not declared.

Raised by the flatten preflight when a `variable_map` coupling with an
`identity` transform binds two variables whose declared, non-empty units
differ (§4.7.6). Mirrors Julia's `DomainUnitMismatchError`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/ae13cc8f0c7013724cd3011b89390f836e34b5ad/pkg/earthsci-ast-py/src/earthsci_ast/flatten.py#L264)

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
