---
title: "product_matrix"
description: "Stable function · Reactions"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Reactions](/generated/api/topics/reactions)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | `productMatrix` | `product_matrix` | not exported | not exported |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

<p class="api-absent">Julia does not export this function.</p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function productMatrix(system: ReactionSystem): number[][]
```

Compute product stoichiometric matrix from a reaction system

Returns the product stoichiometric matrix (species × reactions) where:
- Rows are species (in declaration order)
- Columns are reactions (in array order)
- Entry [i][j] = product stoichiometry for species i in reaction j
- Null products contribute 0

**Parameters**

- `system` — ReactionSystem to compute matrix from

**Returns**

Product stoichiometric matrix

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-ts/src/reactions.ts#L291)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
product_matrix(system: ReactionSystem) -> np.ndarray
```

Compute the product stoichiometric matrix.

The product matrix gives only the product stoichiometric coefficients.
All entries are non-negative, with P[i,j] giving the coefficient of
species i as a product in reaction j.

**Parameters**

- `system` (`ReactionSystem`) — ReactionSystem containing species and reactions

**Returns**

- `np.ndarray` — np.ndarray: Product matrix with shape (n_species, n_reactions)
         where P[i,j] = product coefficient of species i in reaction j

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/reactions.py#L282)

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

<p class="api-absent">Rust does not export this function.</p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Go does not export this function.</p>

</div>

</div>
