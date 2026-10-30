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
"conformant when implemented". The document **loads** — it is schema-valid and
§9.5.5 lists no load-time diagnostic for it — and it **round-trips**. What it
must not do is evaluate as though it said `"clamp"`. A binding that does not
implement the mode refuses the lookup with `table_out_of_bounds_unsupported`
at the point it would otherwise lower or dispatch the node (esm-spec §9.5.3a).
A binding that does implement it (Rust, Julia) answers the fixture's in-range
query (`p = 2.5`) with exactly the clamp lowering's 25.0, and raises
`table_lookup_out_of_bounds` at evaluation time for a query strictly outside
the axis `[1, 4]` (a query on an end knot is in range, and a NaN query is
not out of bounds: it passes through and yields NaN, per esm-spec §9.5.3a) —
under every compiler it offers, or refuses the compiler by
name (Rust's and Julia's `xla`, which have no channel to raise a run-time
error, and Julia's `mtk`). Answering
in the mode the binding happens to have, rather than the one the author
declared, is a wrong number with nothing in the result to say so.

### `nearest/fixture.esm`

`interpolation: "nearest"` (esm-spec §9.5.3) through each binding's inline-test
runner. The lookup returns the table value at the knot NEAREST the query; a tie
between two knots goes to the LOWER knot; and with the default
`out_of_bounds: "clamp"` a query below the first knot or above the last returns
the end value. The axis `[1, 2, 4, 8]` is non-uniform and every midpoint used
(1.5, 3, 6) is exactly representable, so each tie is a true tie in binary64.
Eleven queries cover both clamps, every knot class, the three ties, and a point
either side of a midpoint. `n_tie_2_4_hand` spells the §9.5.3 lowering out by
hand (`interp.searchsorted`, `min`, `max`, `index`, `-`, `<`, `==`, `ifelse`),
so a binding whose lowering is not the spec's composition disagrees with it.

The fixture replaces the pre-2026-10-26 lowering,
`index(data, interp.searchsorted(x, axis))`, which returned the first knot
`>= x` rather than the nearest one, and read one past the end of `data` for a
query above the last knot (`E_TREEWALK_CONSTARRAY_OOB`) — so `q_above` fails a
binding that still lowers that way, and with it every assertion in the model.

### `lookup_defaults/fixture.esm`

The §9.5.2 and §9.5.3 defaults through each binding's inline-test runner. An
omitted `table_lookup.output` means `0` whether or not the table declares
`outputs`; on a multi-output table the lowering reads the slice `data[output]`,
and on a single-output table (no `outputs`) it reads the WHOLE `data`, never
`data[0]`. Each omitted-`output` read is asserted beside the same read written
out and beside a read of a different output, on a 1-axis linear and a 2-axis
bilinear multi-output table, and on a single-output table. (`args` is always
written: the schema requires it on every expression node, so an absent `args`
can only reach a binding through a node built in memory, and is covered by each
binding's unit tests.)

### `load_errors/cases.json`

The §9.5.5 load-time table checks and the order they report in (esm-spec
§9.5.5, "Order of the table checks"). A ledger rather than `.esm` documents:
each case is one table (id `T`) and one `table_lookup` on it, and a harness
builds the table in memory — several cases need a NaN, which JSON cannot carry
(the ledger writes it as the string `"NaN"`, as `tests/closed_functions/` does),
and the one-value and empty axes are rejected by the schema (`minItems: 2`)
before any binding would see them. The harness lowers the lookup through the
binding's own §9.5.3 lowering and asserts `expected_error_code` (`null`: the
lookup lowers). The two-rule cases break two rules ADJACENT in the pinned
order, so every adjacent pair is pinned, and two pairs are pinned across axes
(a decreasing first axis with a NaN in the second is `table_axis_nan`; a
one-value first axis with a decreasing second is `table_axis_non_monotonic`),
because each step covers every axis before the next begins.

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
4. Refuse `out_of_bounds: "error"` by name, or implement it — pinned by
   `out_of_bounds_error/`.
5. Report every `load_errors/` case with its `expected_error_code`.
6. Round-trip the loaded file: `parse → serialize → parse → serialize`
   yields bit-identical bytes (modulo whitespace), preserving the authored
   `function_tables` block and `table_lookup` nodes.
