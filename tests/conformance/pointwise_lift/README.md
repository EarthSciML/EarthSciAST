# The index sets of a pointwise-lifted state

Fixtures for the index sets the pointwise lift (esm-spec §10.5) gives a lifted state
(esm-libraries-spec §4.7.5, "Pointwise lift: index sets").

The lift makes a scalar state an array over the grid of the operator `makearray` its
merged equation carries. Each dimension of that grid lives on one index set, chosen by
the first rule that applies: the index set an operand gathered at the lift's loops is
declared on; else the only index set the document declares with the dimension's size;
else a synthetic `_liftdim<d>_<extent>` interval, which the flattened `index_sets` gains.
Every binding then records the choice in the same three places:

- the lifted state's `shape` in `state_variables` names the index sets;
- `lifted_shapes` records their sizes;
- both lifted `faq` nodes range each loop as `{"from": <index set>}`, which `to_ascii`
  prints as `i in <index set>`.

## How the fixtures are run

There is no separate runner. Each fixture is a case of the flatten corpus,
`tests/conformance/flatten/cases.json`, under the tier `pointwise_lift`, so every
binding's flatten-corpus test checks it: the state's `shape`, `lifted_shapes`,
`index_sets` (in order, synthetic sets included) and the rendered equations. The Python
oracle generates the corpus (`scripts/generate-flatten-corpus.py`).

The other corpus cases with a lift (`advection_reaction_loaded_ic_bc`,
`term_provenance_pointwise_lift`) are checked the same way.

## The fixtures

| Fixture | Grid | Rule it pins | Lifted `Chem.c` |
|---|---|---|---|
| `lift_onto_undeclared_grid.esm` | `[4]` | No variable declares the grid's shape; `cell` is the only index set of size 4. | `shape: ["cell"]` |
| `lift_same_size_index_sets.esm` | `[3, 3]` | `y` and `x` both have size 3, and `y` is declared first. `Wind.u` is declared on `[x, y]` and gathered as `index(u, i, j)`, which names each dimension. | `shape: ["x", "y"]` |
| `lift_placeholder_ic.esm` | `[4]` | The operator writes a field initial condition on its placeholder, `ic(_var) ~ Dep.c0 * 2`. It expands once per state of `Chem`, so `field_ics` holds `Chem.c` and `Chem.n`, never `_var`. | `shape: ["cell"]` for both states |
| `lift_synthetic_index_sets.esm` | `[3, 5]` | Two index sets of size 3 (`a`, `b`) and no shaped operand; no index set of size 5. | `shape: ["_liftdim1_3", "_liftdim2_5"]`, and `index_sets` gains both |

One fixture is a corpus **refusal** (the corpus's `refusals` array, error
`DimensionPromotionError`): `lift_synthetic_name_clash.esm` needs the synthetic index set
`_liftdim1_3`, but the document declares an index set of that name with size 4, so flatten
refuses it rather than shadow the declared set.
