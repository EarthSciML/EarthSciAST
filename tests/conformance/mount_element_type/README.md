# `mount_element_type` — a mounted leaf's `domain.element_type` crosses the mount

Shared fixtures pinning esm-spec §4.7 "Working precision crosses a mount" and
CONFORMANCE_SPEC §5.18.2b across all five bindings.

A mounted document's `domain` does not merge into the mounting document, so its
`element_type` used to vanish at the edge: a `"Float32"` leaf mounted by a
document that declares no domain evaluated in binary64, and
`100 * ((100 - 73.5) / 100) / (100 - 73.5)` came out `1` through the mount and
`0.99999994` standalone, with nothing to say so. The mount now writes the leaf's
declared precision onto every variable of the spliced component that declares
none, whenever it differs from the mounting document's **effective** precision —
its own declaration, else the one it inherits from its mounter, else `"Float64"`
at a root. A leaf that declares no precision adopts its mounter's.

## The fixtures

| File | Role |
|---|---|
| `leaf_f32.esm` | A `"Float32"` leaf: the witness ratio `x`, plus a ten-digit key declared `"Float64"` and `key_next = key + 5`. Passes its own inline tests standalone. |
| `leaf_none.esm`, `leaf_f64.esm` | The same ratio in a leaf that declares no precision, and in one that declares `"Float64"`. |
| `toplevel.esm` | The defect's case: no domain, the `"Float32"` leaf at a top-level `models.<k>` `{ref}`, beside a model of its own that uses the SAME variable names. The leaf's variables carry `"Float32"` (its key keeps `"Float64"`); the assembly's stay binary64. |
| `subsystems.esm` | The same leaf at a `subsystems.<k>` `{ref}`. The loader writes the same fields. |
| `root_f32.esm` | A `"Float32"` document mounting all three leaves: nothing is written for the `"Float32"` leaf or the undeclared one; the `"Float64"` leaf's variables carry `"Float64"`. |
| `mid_none.esm`, `nested_f32.esm`, `nested_none.esm` | An intermediate assembly that declares nothing, mounting the `"Float32"` leaf, mounted in turn by a `"Float32"` root (nothing written: every edge agrees) and by an undeclared root (the leaf's edge writes `"Float32"`). |
| `leaf_f32_sub.esm`, `deep.esm` | A `"Float32"` leaf that carries a subsystem of its own (`leaf_none.esm`), mounted under an undeclared root beside a binary64 model: the precision is written at every depth, and building the root's own model is unaffected by it. |
| `mid_f64.esm`, `chain_f32.esm` | A `"Float32"` root mounting a `"Float64"` assembly that mounts the `"Float32"` leaf: the inner edge writes `"Float32"`, and the outer edge's `"Float64"` lands on nothing, because every variable already declares a precision. |
| `mixed_coupling.esm` | A binary64 model reads the mounted binary32 quantity through a `variable_map`. Loads everywhere; evaluation is `mixed_element_type`. |
| `reaction_leaf_f32.esm`, `reaction_mount.esm`, `reaction_toplevel.esm` | A `"Float32"` reaction-system leaf, mounted under a binary64 document at a reaction system's `subsystems.<k>` and at a top-level `reaction_systems.<k>`. Species and reaction parameters have no `element_type`: `element_type_uncarried`. |
| `expected.json` | The contract. |

## What `expected.json` pins

- `loads` — for every variable of every model (subsystems as `Model.Sub.var`),
  the `element_type` it carries after load (or `null`), and the document's own
  `domain.element_type`. Exact: a field equal to the enclosing effective
  precision is NOT written. All five bindings assert it, plus the load → emit →
  load fixed point.
- `load_errors` — `{fixture: {code: [bindings]}}`. The bindings implement
  complementary reaction-system mount forms (Rust, Python, TypeScript and Go
  mount a reaction system under a reaction system's `subsystems.<k>` and refuse
  the top-level form with `mount_form_unsupported`; Julia mounts the top-level
  form and refuses the other at parse), so each fixture names who raises which
  code. A binding listed under no code must still refuse the fixture.
- `values`, `build_errors` — asserted by the bindings in `evaluated_by` (those
  that evaluate per-variable precision; today Rust). Values are compared bit for
  bit: `0.9999999403953552` is the binary32 witness, `2265007015` the key that
  binary32 would turn into `2265007104`. `subsystems.esm` and `deep.esm` pin
  values inside a `subsystems.<k>` component (`Host.Leaf.x`, `Leaf.Inner.x`).

## What each binding asserts

- `pkg/EarthSciAST.jl/test/mount_element_type_test.jl`
- `pkg/earthsci-ast-py/tests/test_mount_element_type.py`
- `pkg/earthsci-ast-rs/tests/mount_element_type.rs` (also `values` and `build_errors`)
- `pkg/earthsci-ast-go/pkg/esm/mount_element_type_test.go`
- `pkg/earthsci-ast-ts/src/mount-element-type.test.ts`
