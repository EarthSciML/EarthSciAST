---
title: "stoichiometric_matrix"
description: "Stable function · Reactions"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Reactions](/generated/api/topics/reactions)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `stoichiometric_matrix` | `stoichiometricMatrix` | `stoichiometric_matrix` | `stoichiometric_matrix` | `StoichiometricMatrix` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
stoichiometric_matrix(rxn_sys::ReactionSystem)
```

```julia
stoichiometric_matrix(rxn_sys::ReactionSystem) -> Matrix{Float64}
```

Compute the net stoichiometric matrix (species × reactions).

The stoichiometric matrix S has dimensions (n_species × n_reactions) where:
- S[i,j] = net stoichiometry of species i in reaction j
- Net stoichiometry = products - reactants
- Positive values indicate production, negative values indicate consumption

Values are `Float64` because v0.2.x allows fractional stoichiometries
(e.g. `ISOP+O3 → 0.87 CH2O`). Integer-only systems produce a matrix whose
entries happen to be exact integers stored as `Float64`.

**Arguments**
- `rxn_sys::ReactionSystem`: Input reaction system

**Returns**
- `Matrix{Float64}`: Stoichiometric matrix with dimensions (n_species, n_reactions)

**Examples**
```julia
# For reaction A + B -> 2C:
# S = [-1  # A consumed
#      -1  # B consumed
#       2] # C produced (2 molecules)
```

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/reactions.jl#L132)

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

```typescript
function stoichiometricMatrix(system: ReactionSystem): { matrix: number[][]; species: string[]; reactions: string[] }
```

Compute stoichiometric matrix from a reaction system

Returns the net stoichiometric matrix (species × reactions) where:
- Rows are species (in declaration order)
- Columns are reactions (in array order)
- Entry [i][j] = (stoichiometry as product) - (stoichiometry as substrate) for species i in reaction j
- Null substrates contribute 0 to substrate stoichiometry
- Null products contribute 0 to product stoichiometry

**Parameters**

- `system` — ReactionSystem to compute matrix from

**Returns**

Object containing matrix, species list, and reactions list

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-ts/src/reactions.ts#L202)

**Example** (`reactions`)

```typescript
const doc = loadPath(fixture('ozone.esm'))
const system = doc.reaction_systems!.Ozone
assert.ok(!('ref' in system)) // narrows away an unresolved `{ ref }` mount

// Mass-action kinetics: one ODE per species.
const odes = deriveOdes(system)
assert.deepEqual(odeStates(odes).sort(), ['NO', 'NO2', 'O3'])
assert.deepEqual(
  odes.equations.map((eq) => toAscii(eq)),
  [
    'D(O3)/Dt = -1 * k1 * NO * O3 + jNO2 * NO2',
    'D(NO)/Dt = -1 * k1 * NO * O3 + jNO2 * NO2',
    'D(NO2)/Dt = k1 * NO * O3 + -1 * jNO2 * NO2',
  ],
)

// Net stoichiometry: rows are species, columns are reactions.
const { matrix, species, reactions } = stoichiometricMatrix(system)
assert.deepEqual(species, ['O3', 'NO', 'NO2'])
assert.deepEqual(reactions, ['R1', 'R2'])
assert.deepEqual(matrix, [
  [-1, 1],
  [-1, 1],
  [1, -1],
])
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/typescript/reactions.ts#L9-L33">docs/api/examples/typescript/reactions.ts</a></p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
stoichiometric_matrix(system: ReactionSystem) -> np.ndarray
```

Compute the net stoichiometric matrix for a reaction system.

The stoichiometric matrix S is defined such that S[i,j] gives the net
stoichiometric coefficient of species i in reaction j. Negative values
indicate reactants (consumed), positive values indicate products (formed).

**Parameters**

- `system` (`ReactionSystem`) — ReactionSystem containing species and reactions

**Returns**

- `np.ndarray` — np.ndarray: Stoichiometric matrix with shape (n_species, n_reactions)
         where S[i,j] = net stoichiometric coefficient of species i in reaction j

**Raises**

- `ValueError` — If system is empty

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/reactions.py#L240)

**Example** (`stoichiometric_matrix`)

```python
# Rows are species (O3, NO, NO2) and columns are reactions (R1, R2).
net = earthsci_ast.stoichiometric_matrix(system)
assert np.array_equal(net, [[-1, 1], [-1, 1], [1, -1]])

consumed = earthsci_ast.substrate_matrix(system)
produced = earthsci_ast.product_matrix(system)
assert np.array_equal(produced - consumed, net)
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/python/reactions.py#L31-L37">docs/api/examples/python/reactions.py</a></p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn stoichiometric_matrix(system: &ReactionSystem) -> Vec<Vec<f64>>
```

Generate stoichiometric matrix from a reaction system

Creates a matrix where rows represent species and columns represent reactions.
`matrix[i][j]` is the stoichiometric coefficient of species `i` in reaction `j`.
Negative values indicate reactants, positive values indicate products.

**Arguments**

* `system` - The reaction system to analyze

**Returns**

* `Vec<Vec<f64>>` - Matrix with species as rows and reactions as columns

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-rs/src/reactions.rs#L385) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.stoichiometric_matrix.html)

**Example** (`stoichiometric_matrix`)

```rust
// Rows are species in declaration order (O3, NO, NO2), columns reactions
// (R1: NO + O3 -> NO2, R2: NO2 -> NO + O3).
let s = stoichiometric_matrix(system);
assert_eq!(s, [[-1.0, 1.0], [-1.0, 1.0], [1.0, -1.0]]);
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/rust/reactions.rs#L26-L29">docs/api/examples/rust/reactions.rs</a></p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func StoichiometricMatrix(system *ReactionSystem) [][]float64
```

StoichiometricMatrix returns the NET stoichiometric matrix of a reaction network: rows are species in declaration order (see the file header), columns are reactions in declaration order, and entry \[i\]\[j\] is `products − substrates` for species i in reaction j. Negative means consumed, positive means produced.

Values are float64 because esm permits fractional coefficients (`ISOP + O3 → 0.87 CH2O`); an integer-only network yields exact integers stored as float64.

A species appearing more than once on the same side of one reaction has its coefficients SUMMED, which is why the entry accumulates rather than assigns. (That is a warning-level defect — `duplicate_reaction_species` — not an error, so the matrix must still have an answer for it.)

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/reactions.go#L135) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#StoichiometricMatrix)

**Example** (`reactions`)

```go
doc, err := esm.LoadPath(fixture("ozone.esm"))
if err != nil {
	log.Fatal(err)
}
system := doc.ReactionSystems["Ozone"]
odes, err := esm.DeriveODEs(&system)
if err != nil {
	log.Fatal(err)
}
for _, eq := range odes.Equations {
	fmt.Println(esm.ToASCII(eq.LHS), "=", esm.ToASCII(eq.RHS))
}

// One row per species, one column per reaction.
fmt.Println(esm.StoichiometricMatrix(&system))
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/go/reactions_test.go#L13-L27">docs/api/examples/go/reactions_test.go</a></p>

</div>

</div>
