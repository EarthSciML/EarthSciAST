# `scoped_assertion_variable` — an assertion may name a scoped reference

Shared fixtures pinning that an inline-test assertion's `variable` accepts a
scoped reference, across the three bindings that run inline tests (Julia,
Python, Rust; see `API_SPEC.md`). Reported as issue #263.

## The rule

`esm-schema.json` documents `Assertion.variable` as "the local name (e.g.
`"O3"`) or a scoped reference relative to this component (e.g.
`"subsystem.X"`)". A runner resolves it by the rule the equation binder already
applies to the same string in the same component (esm-spec §4.6, flatten
namespacing):

- a dotted name whose **head is a subsystem key of the asserting component** is
  relative to it — `Leaf.u` asserted in `Host`, which mounts `Leaf`, is
  `Host.Leaf.u`;
- any other dotted name is **document-absolute** — `Leaf.u` asserted in `Host`
  beside a top-level `Leaf` is `Leaf.u`.

Every lookup the assertion makes — the trajectory row, an array state's cells,
an observed's field, the declared shape a `coords` map is checked against — is
then made against the component that owns the name, not the asserting one.

## The fixtures

| File | Role |
|---|---|
| `fixtures/leaf.esm` | `Leaf`: a decaying scalar state `u`, a scalar observed `v = 2u`, and an array observed `key = [7, 9, 4]` over `leaf_axis`. Passes its own test standalone. |
| `fixtures/top_level_mount.esm` | `Host` beside a top-level `models` `{ref}` of the leaf. Asserts `w = 3·Leaf.u` (the control: the scoped name as an operand), then `Leaf.u`, `Leaf.v`, `Leaf.key` at a `coords` cell, and `Leaf.key` reduced by `max`. |
| `fixtures/nested_mount.esm` | The same `Host` and assertions, with the leaf as `Host`'s own `subsystems` mount. |
| `fixtures/shadowed_mount.esm` | Both readings exist: a top-level `Leaf` (the leaf document) and an inline subsystem `Leaf` of `Host` whose `u` is held at 2 and whose `key` is `[1, 2, 3]`. Every expectation is the subsystem's value, as `w = 3·Leaf.u` is. |

Before the fix the `coords` and `reduce` assertions errored with
`variable 'Leaf.key' is not declared in model 'Host'` in both mount forms, and in
`shadowed_mount.esm` the pointwise `Leaf.u` silently read the top-level leaf
(`exp(−1)`) instead of the subsystem (`2`).

`nested_mount.esm` also gates a Rust routing gap the scoped name exposed: `Host`
declares no derivative and no shaped variable of its own — both live in the
mounted leaf — and Rust chose the simulation backend from top-level models
only, so the document went to the scalar backend, which cannot hold an array
`const`, and failed to build whatever its tests asserted. Rust now asks the
backend questions of the whole mount tree (`simulate_array::model_tree_any`).

## What each binding asserts

Driven by per-binding test files rather than by a harness manifest, in the
manner of `tests/conformance/mounted_component_tests/`:

- `pkg/EarthSciAST.jl/test/scoped_assertion_variable_test.jl`
- `pkg/earthsci-ast-py/tests/test_scoped_assertion_variable.py`
- `pkg/earthsci-ast-rs/tests/scoped_assertion_variable.rs`

Each runs the four fixtures through the library inline-test runner and checks
that every assertion passes with the expected actual value. Go and TypeScript do
not run inline tests and do not resolve `Assertion.variable` at validation, so
there is nothing for them to pin.
