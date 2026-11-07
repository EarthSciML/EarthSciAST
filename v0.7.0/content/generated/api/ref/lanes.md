---
title: "lanes"
description: "Stable function · Other"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Other](/generated/api/topics/other)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `lanes` | not exported | `lanes` | not exported | not exported |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
lanes(op::EarthSciAST.RhsProgram, kind::Symbol, sets; chunk)
```

```julia
lanes(op::RhsProgram, kind::Symbol, sets) -> LaneProgram
```

The operator over a run-time list of cells (`kind = :cells`, `sets` every index
set of the written variables' shape) or columns (`kind = :columns`, `sets` the
horizontal sets) (API_SPEC §5.8, "Lanes"). `sets` orders the rows of a call's
`cells` matrix. For every lane `l ≤ n` and written variable `v`,
`du_L[v, l]` equals the whole-domain evaluation at `cells[:, l]` bitwise.

A read that leaves the cell (or the column) raises `compiler_refused_rule`
naming the rule; lane sets that do not fit the program raise
`range_box_invalid`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/EarthSciAST.jl/src/range_restricted.jl#L3046)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">TypeScript does not export this function.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
lanes(op: Any, kind: str, sets: Any) -> Any
```

`op` over a run-time list of cells or columns. Raises `compiler_unavailable`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-py/src/earthsci_ast/range_restricted.py#L66)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

<p class="api-absent">Rust does not export this function.</p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Go does not export this function.</p>

</div>

</div>
