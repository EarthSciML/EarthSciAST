# `records_per_sample` — one record, or the pair that brackets the time

A data-fed parameter's `update.from.records_per_sample` (esm-spec §8.5.1) says
whether the parameter receives the record at or before the query time (`1`) or
that record and its successor, stacked along the parameter's first dimension
(`2`), for the model to blend in time. The source's
`temporal.records_per_sample` (§8.3) is the default; absent both, it is `1`.

`manifest.json` drives one consumer per binding (Julia, Python, Rust,
TypeScript, Go):

- **Valid cases** load, validate with no `records_per_sample_invalid`, and
  flatten. Each listed `loader_fields` entry must report the EFFECTIVE value,
  and `flattened_from_records_per_sample` pins that the flattened parameter's
  `update.from` keeps the field exactly as written (`null` = absent). The field
  must also survive emit then load.
- **Invalid cases** (`expect: "invalid"`) are schema-valid and must be refused
  by structural validation with exactly one `records_per_sample_invalid` at
  `pointer`: a non-`data` rule carrying the field, a pair from a source with no
  `temporal`, and a pair whose record shape's first dimension is not an index
  set of two members, whether the 2 is written on `from` or inherited from the
  source, whether the parameter sits in a top-level model or a subsystem,
  whether `update` is one rule or an array (the pointer then ends in the rule's
  index), and whether the record shape is declared or comes from a
  `param_to_var` target (every target is checked, not just the first).
- **Flatten-invalid cases** (`expect: "flatten_invalid"`) pass structural
  validation and are refused by `flatten` with the same code: the target
  arrives through a `coupling_import`, which expands only at flatten.
- **Refused cases** (`expect: "refused"`) are refused with the code by
  validation or by `flatten`, whichever first sees the record shape: the target
  sits in a model mounted by `ref`.

The files under `fixtures/components/` (a coupling library and two mounted
components) are referenced by the cases and are not cases themselves.

Every source carries `metadata.esio_format` (§8.1.1), which changes nothing.
