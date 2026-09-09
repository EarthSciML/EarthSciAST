# Function Tables Conformance Fixtures (esm-spec §9.5)

These fixtures exercise the `function_tables` top-level block and the
`table_lookup` AST op landed in v0.4.0 (RFC `docs/content/rfcs/sampled-tables.md`,
bead esm-jcj / esm-hid).

## Fixtures

### `linear/fixture.esm`

A single-output 1-axis linear function table — the canonical 1-D blend.
The single equation lowers to `interp.linear(table=data, axis=axis_values, x=lambda)`
and MUST be bit-equivalent to a hand-written inline-const `interp.linear` invocation
on the same arrays at the same query point (esm-spec §9.2 tolerance contract).

### `bilinear/fixture.esm`

A multi-output 2-axis bilinear function table with named outputs
(`["NO2", "O3", "HCHO"]`). Two `table_lookup` equations: one selects by output name
(`"NO2"`), the other by integer index (`1` → `"O3"`). Both lower to
`interp.bilinear` invocations and must agree numerically with the equivalent
hand-written inline-const form.

### `roundtrip/fixture.esm`

A mixed file carrying both a `function_tables`-driven `table_lookup` and a
hand-written inline-const `interp.linear` invocation referencing identical
data. **Round-trip MUST preserve the authored form of each equation**:
loaders MUST NOT auto-promote the inline-const lookup into a `table_lookup`,
and MUST NOT demote the `table_lookup` into an inline-const lookup. This
property is pinned by esm-spec §9.5.4 ("Round-tripping").

### `inline_test/fixture.esm`

The lowering exercised **end to end**, through each binding's own inline-test
runner (§6.6, the `esm test` path) rather than through a hand-written lowering
harness. One model, three assertions: observed `y` is a `table_lookup` (25),
observed `z` is the same lookup spelled in the lowered
`fn interp.linear(const data, const axis, x)` form (25), and observed `w` is a
`table_lookup` whose input sits above the last knot, so the default
`out_of_bounds: "clamp"` holds the last table value (40).

This is the fixture that catches issue #188. Every binding had a §9.5.3
lowering *in its test harness* and none had one on the evaluation path, so
`y` and `w` failed while `z` passed — the classic shape of a transformation
that is verified but never applied. `linear/` and `bilinear/` cannot detect
that, because their harnesses do the lowering themselves.

### `out_of_bounds_error/fixture.esm`

A table declaring `out_of_bounds: "error"`, the §9.5.1 mode that is
"conformant when implemented" and that no binding implements as of v1.0.0.
The document **loads** — it is schema-valid and §9.5.5 lists no load-time
diagnostic for it — and it **round-trips**. What it must not do is evaluate as
though it said `"clamp"`: every binding refuses the lookup with
`table_out_of_bounds_unsupported` at the point it would otherwise lower or
dispatch the node (esm-spec §9.5.3a). Answering in the mode the binding
happens to have, rather than the one the author declared, is a wrong number
with nothing in the result to say so.

## Per-binding contract

All five language bindings (Julia, Python, TypeScript, Rust, Go) MUST:

1. Load each fixture without error (`out_of_bounds_error/` included — its
   refusal is an evaluation-path refusal, not a loader one).
2. Materialize the `table_lookup` to a structurally-equivalent
   `interp.linear` / `interp.bilinear` form whose numerical evaluation agrees
   bit-exactly with the hand-written inline-const equivalent (`abs: 0,
   rel: 0` non-FMA, `abs: 0, rel: 4e-16` mixed-FMA cross-binding —
   esm-spec §9.2 tolerance contract).
3. Apply that materialization **on the path that evaluates a document**, not
   only inside the binding's own test harness — pinned by `inline_test/`.
4. Refuse `out_of_bounds: "error"` by name — pinned by `out_of_bounds_error/`.
5. Round-trip the loaded file: `parse → serialize → parse → serialize`
   yields bit-identical bytes (modulo whitespace), preserving the authored
   `function_tables` block and `table_lookup` nodes.
