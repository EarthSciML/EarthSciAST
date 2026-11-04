# A data-fed parameter mapped onto a shaped target

Fixtures for esm-libraries-spec §4.7.3, "The survivor is the source's declaration".

A `param_to_var` edge maps a data-fed parameter `Met.K` (an `update` of
`kind: "data"` with a `from` binding) onto a parameter `Box.F_k` shaped `[rec, x]`.
Flattening removes `Box.F_k` and rewrites every reference to `Met.K`. The surviving
`Met.K` is its own declaration, unchanged:

- it keeps its `update`, so it is in `discrete_parameters`;
- it keeps its `shape`, which must equal the target's `[rec, x]`, because the
  rewritten equations index it as `Met.K[1, i]`;
- it is the parameter its `loader_fields` entry names.

This is the pattern `reseact.esm` uses for every GEOS-FP field
(`GEOSFP.PBLH` -> `Transport3D.F_PBLH[gf_t, gf_lat, gf_lon]`), which therefore needs
`GEOSFP.PBLH` declared with shape `[gf_t, gf_lat, gf_lon]`.

| Fixture | Outcome | What it pins |
|---|---|---|
| `data_fed_source_keeps_declaration` | flattens | The data source key (`met_source`) differs from the owning model's name. `Met.K` survives with its own `update` and shape. |
| `source_named_like_owner` | flattens | The data source is keyed `Met`, the owning model's name. Python, TypeScript and Go took this for a pre-1.0 loaded field and rebuilt `Met.K` with the target's shape and no `update`. Rust refused the document at load, because its coupling-reference check let the data source's variables replace the model's. |
| `state_source_named_like_data_source` | flattens | The source `Met.T` is a state of a model whose name is also a `data_sources` key. Python, TypeScript and Go built a parameter `Met.T` beside the state. It must stay a state only. |
| `scalar_source_onto_shaped_target` | refused (`VariableMapShapeConflictError`) | `Met.K` declares `shape: []`, which is a scalar buffer, not a request for the target's shape. |
| `one_source_two_target_shapes` | refused (`VariableMapShapeConflictError`) | One source feeds targets shaped `[rec, x]` and `[x]`. Each edge is checked against the source's declaration, so the verdict does not depend on coupling order. |

A `from` that names a field of a data source no component declares is
`tests/invalid/variable_map_from_data_source.esm` (`unresolved_scoped_ref`): a data
source is not a coupling endpoint (esm-spec §8).

## How the fixtures are run

There is no separate runner. The three flattening fixtures are cases of the flatten
corpus, `tests/conformance/flatten/cases.json`, under the tier `variable_map_data_fed`
with the id `variable_map_data_fed_<fixture name>`; the two refused ones are entries
of its `refusals` list. Every binding's flatten-corpus test covers both. Regenerate
the corpus with `python3 scripts/generate-flatten-corpus.py`.
