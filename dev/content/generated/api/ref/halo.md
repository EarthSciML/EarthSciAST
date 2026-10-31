---
title: "halo"
description: "Stable function · Other"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Other](/generated/api/topics/other)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `halo` | not exported | `halo` | not exported | not exported |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
halo(op::EarthSciAST.RhsProgram, dec::Decomposition)
```

```julia
halo(op::RhsProgram, dec::Decomposition) -> Dict{Tuple{String,String},Tuple{Int,Int}}
```

The halo report (API_SPEC §5.8): for every state the operator reads and every
cut or face index set on its shape, `(variable, set) => (lo, hi)`, how far the
owned output reaches into that state along that set. Offsets compose through
observeds, each `makearray` region contributes its own reach, and a periodic
wrap counts as reach across the seam.

Raises `range_global_locality` for a contraction, scan or data-dependent
subscript along a cut axis, `range_box_invalid` for a decomposition that does
not fit the program, and `compiler_unavailable` unless the program was built
with `compiler = :native`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/range_restricted.jl#L2468)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">TypeScript does not export this function.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
halo(op: Any, dec: Any) -> Any
```

The halo report of `op` along `dec`. Raises `compiler_unavailable`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/range_restricted.py#L56)

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
