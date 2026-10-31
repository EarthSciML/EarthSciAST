---
title: "materialize_value_invention"
description: "Stable function · Load-time lowering and templates"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Load-time lowering and templates](/generated/api/topics/lowering)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | not exported | `materialize_value_invention` | `materialize_value_invention` | not exported |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

<p class="api-absent">Julia does not export this function.</p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">TypeScript does not export this function.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
materialize_value_invention(model_json: Mapping[str, Any], const_arrays: Mapping[str, Any] | None = None, params: Mapping[str, Any] | None = None, const_array_boundaries: Mapping[str, Sequence[str]] | None = None, index_sets: Mapping[str, Any] | None = None, maps_only: bool = False) -> ValueInventionResult
```

Run the build-time value-invention engine over a raw model document.

`const_arrays` supplies the build-time factor arrays (the connectivity /
coordinates the keys are computed from); `params` supplies scalar parameter
overrides. A producer that classifies CONTINUOUS is rejected (§5.7 guard 2).

`maps_only` restricts the pass to the skolem BIN maps and their surfaced
`ValueInventionResult.join_key_buffers` — the arg-witness maps, the
grouped / derived chain, and the index-set producers are all skipped. This is
the build's join-key PRE-PASS (`simulation_array._build_numpy_rhs`),
which needs the broad-phase equi-join columns available BEFORE the full
observed hoist that the join-carrying observeds ride: it is fed only the
binning-coordinate closure, so a full producer materialisation (which may read
a wider const factor) could raise — `maps_only` guarantees the bins are
produced regardless.

`index_sets` is the document-scoped index-set registry (RFC §5.2), which
lives at the top level of the document rather than on each model — mirrors
[`reference_resolution.build_reference_graph`](/generated/api/ref/build_reference_graph). When omitted it falls
back to a model-local `model_json["index_sets"]` key, so a caller need not splice the document registry
onto the model dict before calling.

`const_array_boundaries` optionally declares a per-const-array,
per-dimension out-of-range gather policy: a mapping of array name → an
iterable of per-dimension policy strings, each one of "periodic" | "clamp" |
"error". A const-array gather at an out-of-range 1-based index then resolves
declaratively ("periodic" wraps via 1-based modulo, "clamp" edge-extends);
any array WITHOUT a declared policy (or one with "error") keeps raising a
structured [`ValueInventionError`](/generated/api/ref/value_invention_error), so genuine out-of-bounds bugs in
connectivity / stencil-weight factors stay caught.

A no-op (empty result) for a model with no skolem/distinct/rank node — the
evaluator front-door then behaves byte-identically to before.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/value_invention.py#L1282)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn materialize_value_invention(model_json: &Value, const_arrays: &HashMap<String, ArrayD<f64>>, params: &HashMap<String, f64>, const_array_boundaries: &HashMap<String, Vec<BoundaryKind>>) -> Result<ValueInventionResult, ValueInventionError>
```

Run the build-time value-invention engine over a raw model document.

Value invention mints new entities from data, once at setup: unique edge
IDs from a mesh, dense ranks from a categorical column, bin keys from
coordinates. This evaluates every value-invention aggregate in
`model_json` (a `faq` with `distinct: true`, or whose body or `key` is
`skolem` / `rank`, plus the arg-witness and grouped buffers that depend on
them) and returns what it materialized as a [`ValueInventionResult`](/generated/api/ref/value_invention_result). Pass
that result to [`apply_value_invention`](/generated/api/extension/rust#x-apply_value_invention) to rewrite the model so the array
runtime can compile it.

- `model_json` is the raw model document, not the typed [`Model`](/generated/api/ref/model): the
  typed expression tree does not keep an aggregate's `key` and `distinct`
  fields.
- `const_arrays` supplies the build-time factor arrays (connectivity,
  coordinates) the keys are computed from.
- `params` supplies scalar parameter overrides.
- `const_array_boundaries` optionally gives a per-array, per-dimension
  [`BoundaryKind`](/generated/api/extension/rust#x-boundarykind) for a gather at a 1-based index outside `1..=n`
  (periodic wrap or edge clamp). An array absent from the map, or a
  dimension beyond its listed kinds, errors on an out-of-range index; pass
  an empty map for that everywhere.

A model with no `skolem`, `distinct` or `rank` node returns an empty
result.

**Errors**

Returns a [`ValueInventionError`](/generated/api/ref/value_invention_error) when a producer classifies as
continuous (its entities would change every step, `CONFORMANCE_SPEC.md`
§5.7 guard 2), when a key cannot be evaluated from the build-time data, or
on an out-of-range gather with no boundary policy.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-rs/src/value_invention.rs#L1969) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.materialize_value_invention.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Go does not export this function.</p>

</div>

</div>
