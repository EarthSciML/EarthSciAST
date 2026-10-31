---
title: "reaction"
description: "Stable type · Document types"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Document types](/generated/api/topics/document-types)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `Reaction` | not exported | `Reaction` | `Reaction` | `Reaction` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct Reaction
Reaction(id::String, substrates::Union{Nothing, Vector{EarthSciAST.StoichiometryEntry}}, products::Union{Nothing, Vector{EarthSciAST.StoichiometryEntry}}, rate::ASTExpr; name, reference)
Reaction(reactants::AbstractDict{String, <:Real}, products::AbstractDict{String, <:Real}, rate::ASTExpr; reversible)
```

```julia
Reaction
```

Chemical reaction with substrates, products, and rate expression.

---

```julia
Reaction(reactants::AbstractDict{String,<:Real}, products::AbstractDict{String,<:Real}, rate::ASTExpr; reversible=false) -> Reaction
```

Convenience constructor that creates a reaction with an
auto-generated, content-derived id: the same reactants, products, and rate
always produce the same id (deterministic across sessions and Julia versions,
unlike `Base.hash`).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/types.jl#L2198)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">TypeScript does not export this type.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class Reaction
Reaction(name: str, id: str | None = None, reactants: dict[str, int | float] = dict(), products: dict[str, int | float] = dict(), rate_constant: float | Expr | None = None, conditions: dict[str, Any] = dict(), reference: Reference | None = None, name_authored: bool = True, substrate_entries: list[tuple[str, int | float]] | None = None, product_entries: list[tuple[str, int | float]] | None = None)
Reaction.substrate_list() -> list[tuple[str, int | float]]
Reaction.product_list() -> list[tuple[str, int | float]]
```

A chemical reaction.

**Members**

- `substrate_list` — The substrate entries in listed order, repeats kept.
- `product_list` — The product entries in listed order, repeats kept.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/esm_types.py#L561)

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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/python/reactions.py#L13-L26">docs/api/examples/python/reactions.py</a></p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub struct Reaction {
    pub id: Option<String>,
    pub name: Option<String>,
    pub substrates: Option<Vec<StoichiometricEntry>>,
    pub products: Option<Vec<StoichiometricEntry>>,
    pub rate: Expr,
    pub reference: Option<Reference>,
}
```

Chemical reaction

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-rs/src/types/components.rs#L132) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.Reaction.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type Reaction struct {
	ID         string             `json:"id"`
	Name       *string            `json:"name,omitempty"`
	Substrates []SubstrateProduct `json:"substrates"`
	Products   []SubstrateProduct `json:"products"`
	Rate       Expression         `json:"rate"`
	Reference  *Reference         `json:"reference,omitempty"`
}

func (r *Reaction) UnmarshalJSON(data []byte) error
```

Reaction represents a chemical reaction

**Methods**

```go
func (r *Reaction) UnmarshalJSON(data []byte) error
```

Custom JSON unmarshaling for Reaction

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/types.go#L521) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#Reaction)

</div>

</div>
