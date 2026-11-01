---
title: "substrate_matrix"
description: "Stable function · Reactions"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Reactions](/generated/api/topics/reactions)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | `substrateMatrix` | `substrate_matrix` | not exported | not exported |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

<p class="api-absent">Julia does not export this function.</p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function substrateMatrix(system: ReactionSystem): number[][]
```

Compute substrate stoichiometric matrix from a reaction system

Returns the substrate stoichiometric matrix (species × reactions) where:
- Rows are species (in declaration order)
- Columns are reactions (in array order)
- Entry [i][j] = substrate stoichiometry for species i in reaction j
- Null substrates contribute 0

**Parameters**

- `system` — ReactionSystem to compute matrix from

**Returns**

Substrate stoichiometric matrix

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/reactions.ts#L257)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
substrate_matrix(system: ReactionSystem) -> np.ndarray
```

Compute the substrate (reactant) stoichiometric matrix.

The substrate matrix gives only the reactant stoichiometric coefficients.
All entries are non-negative, with S[i,j] giving the coefficient of
species i as a reactant in reaction j.

**Parameters**

- `system` (`ReactionSystem`) — ReactionSystem containing species and reactions

**Returns**

- `np.ndarray` — np.ndarray: Substrate matrix with shape (n_species, n_reactions)
         where S[i,j] = reactant coefficient of species i in reaction j

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-py/src/earthsci_ast/reactions.py#L264)

**Example** (`stoichiometric_matrix`)

```python
# Rows are species (O3, NO, NO2) and columns are reactions (R1, R2).
net = earthsci_ast.stoichiometric_matrix(system)
assert np.array_equal(net, [[-1, 1], [-1, 1], [1, -1]])

consumed = earthsci_ast.substrate_matrix(system)
produced = earthsci_ast.product_matrix(system)
assert np.array_equal(produced - consumed, net)
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/docs/api/examples/python/reactions.py#L31-L37">docs/api/examples/python/reactions.py</a></p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

<p class="api-absent">Rust does not export this function.</p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Go does not export this function.</p>

</div>

</div>
