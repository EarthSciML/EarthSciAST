---
title: "species"
description: "Stable type · Document types"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Document types](/generated/api/topics/document-types)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `Species` | not exported | `Species` | `Species` | `Species` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct Species
Species(name::String; units, default, description, default_units, constant)
```

```julia
Species
```

Chemical species definition with name and optional properties.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/EarthSciAST.jl/src/types.jl#L1769)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">TypeScript does not export this type.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class Species
Species(name: str, units: str | None = None, default: float | None = None, default_units: str | None = None, description: str | None = None, formula: str | None = None, constant: bool | None = None)
```

A chemical species in a reaction system.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-py/src/earthsci_ast/esm_types.py#L520)

**Example** (`reactions`)

```python
doc = earthsci_ast.load_path(FIXTURES / "ozone.esm")
system = doc.reaction_systems["Ozone"]
assert [s.name for s in system.species] == ["O3", "NO", "NO2"]
assert [r.id for r in system.reactions] == ["R1", "R2"]

odes = earthsci_ast.derive_odes(system)
for eq in odes.equations:
    print(earthsci_ast.to_ascii(eq))

# One equation per species, in declaration order; rate constants become parameters.
assert earthsci_ast.ode_states(odes) == ["NO", "NO2", "O3"]
assert [eq.lhs.args[0] for eq in odes.equations] == ["O3", "NO", "NO2"]
assert odes.variables["k1"].type == "parameter"
assert earthsci_ast.to_ascii(odes.equations[2]) == "D(NO2)/Dt = k1 * NO * O3 + -1 * jNO2 * NO2"
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/docs/api/examples/python/reactions.py#L13-L26">docs/api/examples/python/reactions.py</a></p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub struct Species {
    pub units: Option<String>,
    pub default: Option<f64>,
    pub default_units: Option<String>,
    pub description: Option<String>,
    pub constant: Option<bool>,
}
```

Chemical species in a reaction system. Keyed by name in the parent map.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-rs/src/types/components.rs#L60) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.Species.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type Species struct {
	Units   *string `json:"units,omitempty"`
	Default any     `json:"default,omitempty"`
	// DefaultUnits declares the units the scalar `default` is expressed in when
	// they differ from `units` — the Species twin of ModelVariable.DefaultUnits.
	// `omitempty`: an optional key, absent from most species.
	DefaultUnits *string `json:"default_units,omitempty"`
	Description  *string `json:"description,omitempty"`
	// Constant marks reservoir species (held fixed, no ODE).
	// Maps to Catalyst's isconstantspecies=true.
	Constant *bool `json:"constant,omitempty"`
}

func (s *Species) UnmarshalJSON(data []byte) error
```

Species represents a chemical species

**Methods**

```go
func (s *Species) UnmarshalJSON(data []byte) error
```

Custom JSON unmarshaling for Species. Decodes `default` through UnmarshalExpression so an integer-valued default keeps its int wire shape (RFC §5.4.1); a plain decode would coerce it to float64 and re-emit "1.0".

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-go/pkg/esm/types.go#L418) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#Species)

</div>

</div>
