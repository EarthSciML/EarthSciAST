# A data-fed parameter mapped onto a shaped target

Fixtures for esm-libraries-spec §4.7.3, "The survivor is the source's declaration".

A `param_to_var` edge maps a 0-d data-fed parameter `Met.K` (an `update` of
`kind: "data"`) onto a parameter `Box.F_k` shaped `[rec, x]`. Flattening removes
`Box.F_k` and rewrites every reference to `Met.K`. The surviving `Met.K` must:

- keep its own `update`, so it is in `discrete_parameters`;
- take the target's shape `[rec, x]`, since it declares none of its own;
- be the parameter its `loader_fields` entry names.

This is the pattern `reseact.esm` uses for every GEOS-FP field
(`GEOSFP.PBLH` -> `Transport3D.F_PBLH[gf_t, gf_lat, gf_lon]`).

| Fixture | What it pins |
|---|---|
| `scalar_feed_onto_shaped_target` | The data source key (`met_source`) differs from the owning model's name. Julia, Rust, Python, TypeScript and Go all kept the `update` here but left `Met.K` scalar while the equations index it `Met.K[1, i]`. |
| `source_named_like_owner` | The data source is keyed `Met`, the owning model's name. Python, TypeScript and Go took this for a pre-1.0 loaded field and rebuilt `Met.K` with the target's shape and no `update`, so it left `discrete_parameters` while `loader_fields` still listed it. Rust refused the document at load: its coupling-reference check let the data source's variables replace the model's, so `Met.K` was "not provided by `Met`". |

## How the fixtures are run

There is no separate runner. Each fixture is a case of the flatten corpus,
`tests/conformance/flatten/cases.json`, under the tier `variable_map_data_fed` with
the id `variable_map_data_fed_<fixture name>`, so every binding's flatten-corpus test
covers it. Regenerate the corpus with `python3 scripts/generate-flatten-corpus.py`.
