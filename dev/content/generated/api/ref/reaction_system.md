---
title: "reaction_system"
description: "Stable type · Document types"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Document types](/generated/api/topics/document-types)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `ReactionSystem` | not exported | `ReactionSystem` | `ReactionSystem` | `ReactionSystem` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct ReactionSystem
ReactionSystem(species::Vector{Species}, reactions::Vector{Reaction}; parameters, subsystems, constraint_equations, discrete_events, continuous_events, tolerance, tests, analyses, reference)
```

```julia
ReactionSystem
```

Collection of chemical reactions with associated species, supporting hierarchical composition.

Carries every property esm-schema.json's `ReactionSystem` defines, including
`subsystems` (a reaction-system hierarchy), `constraint_equations` (additional
algebraic/ODE constraints), `continuous_events` / `discrete_events` and
`analyses`, all of which load and serialize. `analyses` is kept VERBATIM for the reason [`Model`](/generated/api/ref/model)'s is.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/types.jl#L2220)

**Example** (`reactions`)

```julia
doc = load_path(joinpath(FIXTURES, "ozone.esm"))
rs = doc.reaction_systems["Ozone"]
@assert rs isa ReactionSystem
@assert length(rs.reactions) == 2

odes = derive_odes(rs)  # a Model with one D(species)/dt per species
for eq in odes.equations
    println(to_ascii(eq))
end
@assert [to_ascii(eq) for eq in odes.equations] == [
    "D(O3)/Dt = -1 * k1 * NO * O3 + jNO2 * NO2",
    "D(NO)/Dt = -1 * k1 * NO * O3 + jNO2 * NO2",
    "D(NO2)/Dt = k1 * NO * O3 + -1 * jNO2 * NO2",
]

# Rows are species (O3, NO, NO2), columns are reactions (R1, R2).
@assert stoichiometric_matrix(rs) == [-1.0 1.0; -1.0 1.0; 1.0 -1.0]
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/julia/reactions.jl#L7-L23">docs/api/examples/julia/reactions.jl</a></p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">TypeScript does not export this type.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class ReactionSystem
ReactionSystem(name: str, species: list[Species] = list(), parameters: list[Parameter] = list(), reactions: list[Reaction] = list(), constraint_equations: list[Equation] = list(), subsystems: dict[str, ReactionSystem] = dict(), tolerance: Tolerance | None = None, tests: list[Test] = list(), analyses: list[Analysis] = list(), continuous_events: list[ContinuousEvent] = list(), discrete_events: list[DiscreteEvent] = list(), reference: Reference | None = None)
```

A system of chemical reactions.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/esm_types.py#L624)

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
pub struct ReactionSystem {
    pub reference: Option<Reference>,
    pub species: IndexMap<String, Species>,
    pub parameters: IndexMap<String, Parameter>,
    pub reactions: Vec<Reaction>,
    pub constraint_equations: Option<Vec<Equation>>,
    pub discrete_events: Option<Vec<DiscreteEvent>>,
    pub continuous_events: Option<Vec<ContinuousEvent>>,
    pub subsystems: Option<IndexMap<String, Value>>,
    pub tolerance: Option<Tolerance>,
    pub tests: Option<Vec<ModelTest>>,
    pub analyses: Option<Vec<ModelAnalysis>>,
}
```

Reaction network component

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-rs/src/types/components.rs#L8) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.ReactionSystem.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type ReactionSystem struct {
	Reference           *Reference           `json:"reference,omitempty"`
	Species             map[string]Species   `json:"species"`
	Parameters          map[string]Parameter `json:"parameters"`
	Reactions           []Reaction           `json:"reactions"`
	ConstraintEquations []Equation           `json:"constraint_equations,omitempty"`
	DiscreteEvents      []DiscreteEvent      `json:"discrete_events,omitempty"`
	ContinuousEvents    []ContinuousEvent    `json:"continuous_events,omitempty"`
	Subsystems          map[string]any       `json:"subsystems,omitempty"`
	// Tolerance is the component-level default numerical tolerance for inline
	// tests (esm-spec §6.6).
	Tolerance *Tolerance `json:"tolerance,omitempty"`
	// Tests are inline validation tests for this reaction system (esm-spec §6.6).
	Tests []Test `json:"tests,omitempty"`
	// Analyses are inline illustrative runs + plot specs (esm-spec §6.7).
	Analyses []Analysis `json:"analyses,omitempty"`
	// contains filtered or unexported fields
}
```

ReactionSystem represents a chemical reaction network

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/types.go#L531) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ReactionSystem)

</div>

</div>
