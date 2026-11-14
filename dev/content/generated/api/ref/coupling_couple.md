---
title: "coupling_couple"
description: "Stable type · Document types"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Document types](/generated/api/topics/document-types)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `CouplingCouple` | not exported | not exported | not exported | `CouplingCouple` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct CouplingCouple <: CouplingEntry
CouplingCouple(systems::Vector{String}, connector::Dict{String, Any}; description, lifting)
```

```julia
CouplingCouple <: CouplingEntry
```

Bi-directional coupling via connector equations.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/ae13cc8f0c7013724cd3011b89390f836e34b5ad/pkg/EarthSciAST.jl/src/types.jl#L1976)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">TypeScript does not export this type.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

<p class="api-absent">Python does not export this type.</p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

<p class="api-absent">Rust does not export this type.</p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type CouplingCouple struct {
	Type        string    `json:"type"` // "couple"
	Systems     [2]string `json:"systems"`
	Connector   Connector `json:"connector"`
	Lifting     *string   `json:"lifting,omitempty"`
	Description *string   `json:"description,omitempty"`
}

func (c CouplingCouple) CouplingType() string
```

CouplingCouple represents bi-directional coupling via connector equations

**Methods**

```go
func (c CouplingCouple) CouplingType() string
```

[Source](https://github.com/EarthSciML/EarthSciAST/blob/ae13cc8f0c7013724cd3011b89390f836e34b5ad/pkg/earthsci-ast-go/pkg/esm/types.go#L916) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CouplingCouple)

</div>

</div>
