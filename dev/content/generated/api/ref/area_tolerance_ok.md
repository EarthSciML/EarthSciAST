---
title: "area_tolerance_ok"
description: "Stable function · Relational keys and geometry"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Relational keys and geometry](/generated/api/topics/relational)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | not exported | `area_tolerance_ok` | `area_tolerance_ok` | not exported |


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
area_tolerance_ok(area_x: float, area_ref: float, rtol: float, radius: float = 1.0, atol: float | None = None) -> bool
```

Combined rel+abs area-agreement gate with a sliver floor (B.5 / §5.8.2).

`|A_x − A_ref| ≤ atol + rtol·A_ref` with `atol ≈ 1e-15·R²` the sliver
floor: sub-`atol` areas are treated as equal-to-zero, so a "present-but-tiny"
overlap and an "absent" one **both pass**. `rtol` is empirically calibrated
per the loosest binding pair (GeometryOps-vs-S2); Python and Rust share the S2
core and agree far tighter. Pass an explicit `atol` to override the floor.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/geometry.py#L840)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn area_tolerance_ok(area_x: f64, area_ref: f64, rtol: f64, radius: f64) -> bool
```

The combined relative + absolute area-agreement gate with a sliver floor
(B.5 / CONFORMANCE_SPEC.md §5.8.2):

```text
|A_x − A_ref| ≤ atol + rtol·|A_ref|,   atol = 1e-15·radius²
```

Sub-`atol` areas are snapped to zero first, so a "present-but-tiny" overlap and
an "absent" one **both pass** — the snapping / tie-break regime MUST NOT fail
conformance (§5.8.2). `rtol` is empirically calibrated to the **loosest** binding
pair (GeometryOps-vs-S2); Rust and Python share the S2 core and agree far
tighter. This is the Rust analogue of Python `geometry.area_tolerance_ok`, the
primitive that folds the Rust binding into the cross-binding tolerance gate.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-rs/src/geometry.rs#L518) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.area_tolerance_ok.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Go does not export this function.</p>

</div>

</div>
