# Canonical-form conformance fixtures (RFC §5.4)

Each fixture is a JSON document with:

- `id` — short identifier.
- `description` — human-readable note about what this fixture exercises.
- `input` — an ESM expression in the wire form (number | string |
  ExpressionNode). Integer literals appear as JSON integers; float literals
  contain `.` or `e`/`E`.
- `expected` — the byte-exact canonical JSON string each binding must produce
  from `canonical_json(input)`. Present on positive fixtures; mutually
  exclusive with `expect_error`.
- `expect_error` — OPTIONAL. When present (and used *instead of* `expected`),
  the fixture is a fail-closed case: `canonical_json(input)` must RAISE with
  this error code rather than produce output. The only value currently used is
  `"E_CANONICAL_UNSUPPORTED_FIELD"`.
- `tags` — categorization (`integer`, `float`, `subnormal`, `flatten`,
  `zero_elim`, `ordering`, `nonleaf`, `signed_zero`, `fail_closed`,
  `supported`, ...).

Bindings load each fixture, parse `input` per their wire form, and branch on
which output field the fixture carries:

- If the fixture has `expected`, run `canonicalize(input)` (or
  `canonical_json(input)` directly) and assert the output matches `expected`
  byte-for-byte.
- If the fixture has `expect_error`, assert that `canonical_json(input)` raises
  the error whose code equals `expect_error`.

## Fail-closed canonicalization

`canonical_json` emits ONLY the fields `{op, args, wrt, dim, fn, name, value}`
(it also tolerates `{arg, bindings}`). Any node carrying any *other* set field
— e.g. `int_var`, `lower`, `upper`, `expr`, `output_idx`, `ranges`, `reduce`,
`semiring`, `join`, `filter`, `regions`, `values`, `shape`, `perm`, `axis`,
`table`, `axes`, `output`, `id`, `manifold`, `distinct`, `key`,
`expect_cadence` — must cause `canonical_json` to raise
`E_CANONICAL_UNSUPPORTED_FIELD`. The `*_unsupported` fixtures exercise this;
`bc_fn_supported` is the positive control proving an emissible sidecar field
(`fn`) still round-trips.

## TypeScript exception

The TypeScript binding cannot distinguish integer from float literals until
gt-ca2u (rep refactor) lands. Fixtures whose `expected` contains a
JSON-integer token (no `.`, no `e`) are skipped for TypeScript and tracked
under gt-z8k0's TS follow-up bead.
