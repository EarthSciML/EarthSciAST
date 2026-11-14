# The pointwise lift: which states, and onto which index sets

Fixtures for which states the pointwise lift (esm-spec §10.5) lifts (esm-libraries-spec
§4.7.5, "Pointwise lift: which states are lifted") and the index sets it gives them
("Pointwise lift: index sets").

A scalar state is lifted when its merged equation carries an operator `makearray`, or when
its merged right-hand side is an array under the §4.3.4 shape rules. A lifted state takes
its whole top-level component with it, and the search repeats across components until
nothing changes. Under an operator, each dimension of the grid lives on one index set, chosen by
the first rule that applies: the index set an operand gathered at the lift's loops is
declared on; else the only index set the document declares with the dimension's size;
else a synthetic `_liftdim<d>_<extent>` interval, which the flattened `index_sets` gains.
On the other routes the index sets are those the array operands declare. Every binding
then records the choice in the same three places:

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
| `lift_skips_shaped_state.esm` | `[4]` | `Chem.m` already declares `shape: ["cell"]`; the operator's `D(_var)` reaches it as well as the scalar `Chem.c`. Only `Chem.c` is lifted: `Chem.m` keeps its shape, gets no `lifted_shapes` entry, and its equation is not wrapped in a lifted `faq`. | `shape: ["cell"]` |
| `lift_synthetic_index_sets.esm` | `[3, 5]` | Two index sets of size 3 (`a`, `b`) and no shaped operand; no index set of size 5. | `shape: ["_liftdim1_3", "_liftdim2_5"]`, and `index_sets` gains both |

### The routes besides the operator `makearray`

| Fixture | Route | Lifted |
|---|---|---|
| `lift_variable_map_rate.esm` | A pointwise `variable_map` feeds the `[lev]` `Column.T` into `Rates.T`, so the rate `Rates.k1` is an array. | `Mech.A`, `Mech.B` on `[lev]`; `Tend.dA_dt = D(Mech.A)` resolves to `Mech.A`'s lifted right-hand side |
| `lift_operator_elementwise.esm` | `operator_compose` with an operator written elementwise, `D(_var) = -km * _var` with `km` on `[lev]`; `lifting` omitted, which is pointwise. | `Mech.A`, `Mech.B` on `[lev]`, loops `_p0` |
| `lift_partial_translate.esm` | A partial `translate` merges `Mech.A` into the `[lev]` `Col.A`; `Mech.B` reads it. | `Mech.B` on `[lev]` |
| `lift_untouched_species.esm` | The whole component lifts: `Mech.C` is in no reaction and `Box.y` reads no array. | every state of `Mech` and `Box` |
| `lift_fixpoint.esm` | `Uptake.u` reads `Mech.A`; `Store.s` reads `Uptake.u`. Each is declared before what it reads. | `Mech`, then `Uptake`, then `Store` |
| `lift_mean_not_triggered.esm` | A `variable_map` with `lifting: "mean"`. It does not trigger the lift. No binding implements the mean itself, so the tendency still reads the raw array; the fixture pins only that `Land.w` stays scalar. | nothing |

Three fixtures are corpus **refusals** (the corpus's `refusals` array):

- `lift_two_grids.esm` (`DimensionPromotionError`): `Box.x` reads a `[lev]` field and
  `Box.y` a `[lat]` one, so the component `Box` would land on two grids.

- `lift_synthetic_name_clash.esm` (`DimensionPromotionError`) needs the synthetic index set
  `_liftdim1_3`, but the document declares an index set of that name with size 4, so flatten
  refuses it rather than shadow the declared set.
- `lift_placeholder_ic_conflict.esm` (`ConflictingDerivativeError`) declares `ic(c)` on `Chem`
  while the operator's `ic(_var)` also expands onto `Chem.c`, leaving it two initial
  conditions; flatten refuses rather than let one win.
