# Record axes — one record, or the pair that brackets the time

A data-fed parameter receives, at a query time, either the record at or before
it or that record and its successor, stacked along the parameter's first axis
(esm-spec §8.5.1). Which one is said by the parameter's **record shape**: its
declared `shape`, or, for a parameter that declares none, the declared `shape`
of each `param_to_var` target it is the `from` of. When the record shape begins
with a **record axis**, an `interval` index set of size 2 carrying
`"records": true`, the parameter receives two records; otherwise one.

The older fields `from.records_per_sample` and `temporal.records_per_sample`
(§8.3) are **deprecated** and removed at esm 3.0.0. They are no longer obeyed:
until removal they load with one `deprecated_records_per_sample` warning per
load and are checked, so a written value must equal the count the record shape
gives. That is a breaking change, made with the esm 2.0.0 break: a document
written before the record axis with `records_per_sample: 2` over a plain
size-2 first axis is now `records_per_sample_invalid`, and is fixed by adding
`"records": true` to that axis.

`manifest.json` drives one consumer per binding (Julia, Python, Rust,
TypeScript, Go). `record_codes` lists the four diagnostics this tier owns.

- **Valid cases** load, validate with none of `record_codes`, and flatten. Each
  listed `loader_fields` entry must report the number of records the parameter
  receives, and `flattened_from_records_per_sample` pins that the flattened
  parameter's `update.from` keeps the deprecated field exactly as written
  (`null` = absent). The `records` flag and the field must survive emit then
  load. `deprecated_fields` is the sorted list of JSON pointers at which the
  deprecated field is written: each binding's deprecated-site function must
  return exactly that list, and loading must warn once when it is non-empty and
  not at all when it is empty. `record_axis` and its `param_to_var`,
  `coupling_import` and `ref` variants use the record axis alone;
  `records_per_sample_deprecated*` keep the deprecated form, agreeing with the
  shape, to cover the warning path; `records_per_sample_deprecated_reaction_system`
  does so for a reaction system's data-fed parameter, whose site is a
  `/reaction_systems/...` pointer (it lists no `loader_fields`).
- **Invalid cases** (`expect: "invalid"`) are schema-valid and must be refused
  by structural validation with exactly one diagnostic from `record_codes`,
  `code` at `pointer`:
  - `record_axis_invalid` at `/index_sets/<name>`: a record axis whose size is
    not 2;
  - `record_axis_misplaced` at the rule's pointer: a data-fed record shape
    naming a record axis anywhere but first, or several record shapes that
    disagree about beginning with one — in a top-level model or a subsystem,
    in a one-rule or array-form `update` (the pointer then ends in the rule's
    index), with the record shape declared or coming from a `param_to_var`
    target (every target is checked);
  - `record_axis_time_invariant_source` at the rule's pointer: a record shape
    beginning with a record axis on a source with no `temporal` block or no
    `temporal.start`;
  - `records_per_sample_invalid` at the rule's pointer: the deprecated field
    on a non-`data` rule, or a written value (own or inherited from the source)
    that disagrees with the record shape — 2 on a shape with no record axis
    first (including a pre-record-axis document whose first axis is a plain
    interval of size 2), or 1 on one with — for a model variable or a
    reaction-system parameter alike.
- **Flatten-invalid cases** (`expect: "flatten_invalid"`) pass structural
  validation and are refused by `flatten` with `code`: the target arrives
  through a `coupling_import`, which expands only at flatten.
- **Refused cases** (`expect: "refused"`) are refused with `code` by validation
  or by `flatten`, whichever first sees the record shape: the target sits in a
  model mounted by `ref`.

The files under `fixtures/components/` (a coupling library and two mounted
components) are referenced by the cases and are not cases themselves.

Every source carries `metadata.esio_format` (§8.1.1), which changes nothing.
