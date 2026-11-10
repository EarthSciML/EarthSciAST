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
| `field_ic_application` | `fixtures/field_ic_application.esm` | A field initial condition `ic(c) = linear(…, x = rho)` is lifted over `c`'s index sets like an equation. |
| `declared_scalar_application` | `fixtures/declared_scalar_application.esm` | `y` declares `shape: []`, a scalar, so its equation is never lifted. The build refuses it. |
| `refused_lift` | `fixtures/refused_lift.esm` | `y` applies `linear` over arrays on unrelated index sets, which the lift refuses. Flatten then leaves every equation as written, `z`'s too, though `z` alone could be lifted. The build refuses it. |

## The golden form

One line of JSON, followed by a newline:

```
{"equations":[{"lhs":…,"rhs":…},…],"field_ics":[{"rhs":…,"target":"<name>"},…],"shapes":{"<name>":[…]|null,…}}
```

- `equations` holds the flattened equations in order. Each `lhs` and `rhs` is the
  binding's wire serialization of the expression, with every surviving template
  reference expanded. The Julia binding keeps references through flatten, so its
  test calls `expand_flattened_refs` first, as the planner does.
- `field_ics` holds the field initial conditions in order, each its target
  state and its right-hand side, serialized the same way.
- `shapes` maps every state, parameter and observed to its declared `shape`
  (`null` when it declares none).
- The text is canonical: object keys sorted by code point, no whitespace,
  integers as written, and floats through `format_canonical_float`.

Both bindings write these bytes exactly. The tests are:

- Rust: `pkg/earthsci-ast-rs/tests/flatten_wire_conformance.rs`
- Julia: `pkg/EarthSciAST.jl/test/flatten_wire_conformance_test.jl`

Each test also writes the flattened system out as a document (one model per
component, each field initial condition as an `ic(x)` equation), reads it back,
and builds it under both compilers. The read-back system must give the
original's initial state and right-hand side bit for bit, or be refused where
the original is. `builds` in `cases.json` is the reference evaluator's verdict
(`interpreter`); a strict compiler may refuse more. The Rust `native` compiler
refuses `field_ic_application`'s initial condition, whose per-cell `faq` its
setup overlay does not take, and refuses the read-back system the same way.

The goldens are written by either binding and checked equal to the other's
bytes. The Python, TypeScript and Go bindings do not run these cases yet.
