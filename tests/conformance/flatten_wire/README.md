# The flattened system on the wire

Byte-for-byte goldens for the flattened system a binding writes out. A consumer
that splits a flattened system into derived documents writes its equations as
they serialize and reads them back. The EarthSciIntegrator planner is one such
consumer. Two rules make what it reads back mean what the flattened system
meant:

- **An elementwise template application is written as its per-cell `faq`**
  (esm-spec §9.6.11, "A flattened system keeps its applications' meaning on the
  wire"). What makes an expansion an application is load provenance, and it
  never reaches the wire. Left as the bare expansion, the written-out document
  reads the array by bare name inside the template's bracket count, which is
  `faq_bare_array_operand` (§4.3.1).
- **The pointwise lift reads every array operand at the cell**, including a
  variable declared without a `shape` whose definition is elementwise over
  arrays (esm-libraries-spec §4.7.5, "Pointwise lift: operands read per cell").

## The cases

`cases.json` lists them. Each case is a fixture and its golden.

| Case | Fixture | What it pins |
|---|---|---|
| `template_array_args_coupled` | `../template_array_args/coupled/template.esm` | `linear` and `bilinear` applied to scalar-declared parameters that `variable_map` feeds `[x, y, z]` arrays. Each lifted equation is a `faq` over `{"from": …}` with loops `_p0, _p1, _p2`, and every coupled array is gathered at the loops of its index sets. No declaration changes: `Phys.Dz`, `Phys.J` and `Phys.k_loss` stay unshaped. |
| `lift_inferred_operand` | `fixtures/lift_inferred_operand.esm` | `Grid.kk = 0.1 * rho` declares no shape and is fed to a pointwise-lifted mechanism. The lift reads `index(Grid.kk, i)`. |

## The golden form

One line of JSON, followed by a newline:

```
{"equations":[{"lhs":…,"rhs":…},…],"shapes":{"<name>":[…]|null,…}}
```

- `equations` holds the flattened equations in order. Each `lhs` and `rhs` is the
  binding's wire serialization of the expression, with every surviving template
  reference expanded. The Julia binding keeps references through flatten, so its
  test calls `expand_flattened_refs` first, as the planner does.
- `shapes` maps every state, parameter and observed to its declared `shape`
  (`null` when it declares none).
- The text is canonical: object keys sorted by code point, no whitespace,
  integers as written, and floats through `format_canonical_float`.

Both bindings write these bytes exactly. The tests are:

- Rust: `pkg/earthsci-ast-rs/tests/flatten_wire_conformance.rs`
- Julia: `pkg/EarthSciAST.jl/test/flatten_wire_conformance_test.jl`

Each test also reads the written-out system back and builds it under both
compilers.

The goldens were written by the Rust binding and checked equal to the Julia
binding's bytes. The Python, TypeScript and Go bindings do not run these cases yet.
