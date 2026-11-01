---
title: "derive_odes"
description: "Stable function · Reactions"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Reactions](/generated/api/topics/reactions)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `derive_odes` | `deriveODEs`, `deriveOdes` | `derive_odes` | `derive_odes` | `DeriveODEs` |


**Note:** spelling differs from the §2 rule: go=DeriveODEs (expected DeriveOdes); typescript=deriveODEs (expected deriveOdes); multiple spellings exported by: typescript


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
derive_odes(rxn_sys::ReactionSystem)
```

```julia
derive_odes(rxn_sys::ReactionSystem) -> Model
```

Generate an ODE model from a reaction system using standard mass action kinetics.

Creates state variables for each species, parameters for rate constants, and equations
with d[species]/dt = net_stoichiometry * rate_law. Handles source reactions (null
substrates), sink reactions (null products), and constraint equations.

**Arguments**
- `rxn_sys::ReactionSystem`: Input reaction system with species, reactions, and parameters

**Returns**
- `Model`: ODE model with variables, equations, and optional events/subsystems

**Algorithm (Libraries Spec Section 7.4)**
1. Create state variables for all species in the reaction system, except
   reservoir species (`constant: true`), which become parameters
2. Create parameter variables for all parameters (rate constants)
3. For each reaction, compute the mass action rate expression
4. For each species, compute the net rate of change from all reactions
5. Create differential equations d[species]/dt = net_rate, except for
   reservoir species, which are held fixed and get none

**Examples**
```julia
# Simple A + B -> C reaction
species = [Species("A"), Species("B"), Species("C")]
reactions = [Reaction(Dict("A"=>1, "B"=>1), Dict("C"=>1), VarExpr("k1"))]
parameters = [Parameter("k1", 0.1)]
rxn_sys = ReactionSystem(species, reactions, parameters=parameters)

model = derive_odes(rxn_sys)
# Returns Model with:
# - State variables: A, B, C
# - Parameter: k1
# - Equations: d[A]/dt = -k1*A*B, d[B]/dt = -k1*A*B, d[C]/dt = k1*A*B
```

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/EarthSciAST.jl/src/reactions.jl#L45)

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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/docs/api/examples/julia/reactions.jl#L7-L23">docs/api/examples/julia/reactions.jl</a></p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

Exported as `deriveODEs` and `deriveOdes`. Both names refer to the same operation.

**`deriveODEs`**

```typescript
function deriveODEs(system: ReactionSystem): Model
```

**Deprecated.** Use `deriveOdes`.

---

**Deprecated.** Spelling alias for [`deriveOdes`](/generated/api/ref/derive_odes), kept for one minor per
API_SPEC.md §10. The canonical name is `derive_odes`, whose TypeScript
transliteration (API_SPEC §2/§2.1) is `deriveOdes`, matching the siblings
`odeStates` / `isOdeState`. Removed at the next major.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/reactions.ts#L319)

**`deriveOdes`**

```typescript
function deriveOdes(system: ReactionSystem): Model
```

Derive ODEs from a reaction system using mass action kinetics

Generates an ODE model from reaction stoichiometry and rate laws. For each reaction
with rate k, substrates {Si} with stoichiometries {ni}, products {Pj} with
stoichiometries {mj}:
- rate law: v = k * prod(Si^ni)
- ODE contribution: dX/dt += net_stoich_X * v

Handles:
- Source reactions (null substrates): rate is the direct production term
- Sink reactions (null products): rate is the direct loss term
- Constraint equations are appended as additional equations

**Parameters**

- `system` — ReactionSystem to derive ODEs from

**Returns**

Model with species as state variables, derived ODEs plus constraints

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/reactions.ts#L35)

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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/docs/api/examples/typescript/reactions.ts#L9-L33">docs/api/examples/typescript/reactions.ts</a></p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
derive_odes(system: ReactionSystem) -> Model
```

Derive ODEs from a reaction system using mass action kinetics.

Thin wrapper around `lower_reactions_to_equations` that bundles the
resulting equations with a `variables` dict (state variables for species,
parameter variables for rate constants) into a [`Model`](/generated/api/ref/model). Handles
source reactions (null substrates) and sink reactions (null products).

**Parameters**

- `system` (`ReactionSystem`) — ReactionSystem containing species, reactions, and parameters

**Returns**

- `Model` `Model` — Mathematical model with ODE equations for each species

**Raises**

- `ValueError` — If system is empty or contains invalid reactions

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-py/src/earthsci_ast/reactions.py#L124)

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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/docs/api/examples/python/reactions.py#L13-L26">docs/api/examples/python/reactions.py</a></p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn derive_odes(system: &ReactionSystem) -> Result<Model, DeriveError>
```

Generate ODE model from a reaction system

Converts a reaction system into an ODE model with species as state variables
and reactions contributing to their derivatives using mass action kinetics.

Mass action kinetics: rate law = k * product(substrates^stoichiometry)
Net stoichiometry = products - substrates
`d[species]/dt = sum(net_stoichiometry * rate_law)`

**Arguments**

* `system` - The reaction system to convert

**Returns**

* `Result<Model, DeriveError>` - ODE model with species as state variables, or error

**Errors**

Returns `DeriveError` for invalid stoichiometry, missing rate laws, or unit conversion issues.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-rs/src/reactions.rs#L244) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.derive_odes.html)

**Example** (`reactions`)

```rust
let doc = load_path(fixture("ozone.esm"))?;
let system = &doc.reaction_systems.as_ref().unwrap()["Ozone"];

// derive_odes turns the reactions into an ordinary model: one
// differential equation per species, with mass-action rate laws.
let model = derive_odes(system)?;
for eq in &model.equations {
    println!("{}", to_ascii(eq));
}
let mut states = ode_states(&model);
states.sort();
assert_eq!(states, ["NO", "NO2", "O3"]);
let no2 = model.equations.iter().find(|eq| to_ascii(&eq.lhs) == "D(NO2)/Dt").unwrap();
assert_eq!(to_ascii(&no2.rhs), "k1 * NO * O3 + -1 * jNO2 * NO2");
assert_eq!(model.equations.len(), 3);
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/docs/api/examples/rust/reactions.rs#L8-L22">docs/api/examples/rust/reactions.rs</a></p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func DeriveODEs(system *ReactionSystem) (*Model, error)
```

DeriveODEs converts a reaction network into a Model whose equations are the species' ODEs under mass-action kinetics (esm-spec §7.4).

Species become UNKNOWNS — the `D(s,t)` equation emitted below is what makes one an ODE state under the §6.3.1 derived classification — except reservoir species (`constant: true`), which are held fixed and get no ODE, so they lower to PARAMETERS carrying their declared `default`. Rate parameters become parameters. Subsystems are derived recursively, as in the Julia reference.

The equations come from the same lowerReactionsToEquations the flatten path uses, so a system's ODEs are identical whether reached through here or through Flatten. That is deliberate and mirrors how Julia and Rust are arranged — both have `derive_odes` call their own shared lowering helper rather than reimplementing mass action beside it. The helper is not itself exported: it takes an explicit species order that only a caller which has already decided the document's ordering (flatten) can supply meaningfully, and exporting that argument would export a decision this entry point is here to make.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-go/pkg/esm/reactions.go#L45) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#DeriveODEs)

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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/docs/api/examples/go/reactions_test.go#L13-L27">docs/api/examples/go/reactions_test.go</a></p>

</div>

</div>
