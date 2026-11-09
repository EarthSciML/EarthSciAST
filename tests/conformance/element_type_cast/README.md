# `element_type_cast` — the one conversion between Float64 and Float32

Shared fixtures pinning the `cast` op (esm-spec §4.2, §11.3.1;
CONFORMANCE_SPEC §5.18.2a) across all five bindings.

esm-spec §11.3.1 told an author to compute a mixed-precision step "into a
variable whose own `element_type` says which precision it lands in", and the
same section refused exactly that equation as `mixed_element_type`. So there
was no way to convert a value between binary64 and binary32 in either
direction (EarthSciAST#536). `{"op": "cast", "element_type": P, "args": [x]}`
is that conversion: the operand is evaluated at its own precision, the value
is rounded once to `P` (round-to-nearest-even narrowing, exact widening, the
identity when they agree), and the node carries `P` to its parent. Mixing
precisions under an operator or an equation still refuses.

## The fixtures

| File | Role |
|---|---|
| `narrow_sum.esm` | A `"Float32"` document that sums binary64 weights in binary64 and narrows the total once (`pop`), beside the same sum accumulated in binary32 (`pop32_sum`). `2^24 + 1 + 1` is 16777218 the first way and 16777216 the second. Then `half = pop / 2` continues in binary32. |
| `float_storage.esm` | A binary64 document that rounds `0.1` through binary32 storage and continues in binary64: `cast(cast(x, Float32), Float64)`. No variable declares an `element_type`. |
| `widen.esm` | A binary32 quantity widened exactly: `0.99999994` stays `0.9999999403953552`, and `1 - x64` is `2^-24` in binary64. |
| `identity_f64.esm` | A cast to the precision the operand already has, in a binary64 document. Every evaluating binding evaluates this one. |
| `mixed_without_cast.esm` | The narrowing equation written without the cast: `mixed_element_type`. |
| `cast_then_mixed.esm` | `cast(x, Float32) + z` with `z` binary64: a cast is a precision leaf and does not adopt its parent's precision, so this is `mixed_element_type`. |
| `expected.json` | The contract. |

The malformed forms are in `tests/invalid/`: `cast_missing_element_type.esm`,
`cast_unknown_element_type.esm`, `cast_arity.esm` and
`element_type_on_non_cast_node.esm`, pinned in
`tests/invalid/expected_errors.json` as schema violations.

## What `expected.json` pins

- `casts` — every fixture's `cast` nodes' `element_type`s, in document order.
  All five bindings assert each fixture loads with exactly these and keeps them
  through load → emit → load.
- `values`, `build_errors` — asserted by the bindings in `evaluated_by` (those
  that evaluate per-variable precision; today Rust), bit for bit.
- `binary64_values`, `binary64_refusals` — asserted by the bindings in
  `binary64_only` (Julia, Python). They evaluate binary64 alone, so a cast to
  `Float64` is the identity and a cast to `Float32` (or a `"Float32"` document)
  is refused with `float32_unsupported`, never evaluated without its rounding.

The fixtures also carry their own inline `tests`, so `esm test` on each of the
four evaluable fixtures checks the same values.

## What each binding asserts

- `pkg/earthsci-ast-rs/tests/element_type_cast.rs`
- `pkg/EarthSciAST.jl/test/element_type_cast_test.jl`
- `pkg/earthsci-ast-py/tests/test_element_type_cast.py`
- `pkg/earthsci-ast-go/pkg/esm/element_type_cast_test.go`
- `pkg/earthsci-ast-ts/src/element-type-cast.test.ts`
