---
title: "domain"
description: "Stable type · Document types"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Document types](/generated/api/topics/document-types)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `Domain` | not exported | `Domain` | `Domain` | `Domain` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct Domain
Domain(; independent_variable, temporal, element_type, array_type)
```

```julia
Domain
```

Spatial and temporal domain specification.

Carries every field esm-schema.json's `Domain` defines — the schema sets
`additionalProperties: false`, so this list is closed — because a flattened
system is required to reproduce "the file's `domain` section, unchanged"
(esm-libraries-spec §4.7.5 step 4). A field this type does not hold is a field
`load` silently drops.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/types.jl#L2121)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">TypeScript does not export this type.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class Domain
Domain(name: str | None = None, independent_variable: str | None = None, temporal: TemporalDomain | None = None, element_type: str | None = None, array_type: str | None = None, dimensions: dict[str, Any] | None = None, coordinates: dict[str, list[float]] = dict(), boundaries: dict[str, Any] = dict())
```

Comprehensive computational domain specification.

A domain carries no boundary-condition data: BCs are not a declared concept
in the format (they are baked into discretization rewrite rules, §9.6.8).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/esm_types.py#L1216)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub struct Domain {
    pub independent_variable: Option<String>,
    pub temporal: Option<Value>,
    pub element_type: Option<String>,
    pub array_type: Option<String>,
}
```

Spatial/temporal domain specification

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-rs/src/types/components.rs#L642) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.Domain.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type Domain struct {
	IndependentVariable *string         `json:"independent_variable,omitempty"`
	Temporal            *TemporalDomain `json:"temporal,omitempty"`
	ElementType         *string         `json:"element_type,omitempty"`
	ArrayType           *string         `json:"array_type,omitempty"`
}
```

Domain represents the spatiotemporal domain.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/types.go#L1028) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#Domain)

</div>

</div>
