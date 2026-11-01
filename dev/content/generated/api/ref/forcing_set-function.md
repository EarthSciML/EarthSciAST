---
title: "forcing_set (function)"
description: "Stable function · Other"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Other](/generated/api/topics/other)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `forcing_set` | not exported | `forcing_set` | not exported | not exported |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
forcing_set(x, bufs)
```

```julia
forcing_set(x, bufs) -> ForcingSet
```

A forcing set for `x` (API_SPEC §5.8): `bufs` holds one buffer per
[`forcing_slots`](/generated/api/extension/julia#x-forcing_slots)`(x)` entry, in slot order, each of `prod(shape)`
elements read in linear (column-major) order. The buffers are held by
reference; the set gets a fresh epoch. A wrong count or length is a
`DimensionMismatch`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/EarthSciAST.jl/src/rhs_program.jl#L180)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">TypeScript does not export this function.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
forcing_set(prog: Any, bufs: Any) -> Any
```

An epoch-stamped forcing set for `prog`. Raises `compiler_unavailable`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-py/src/earthsci_ast/range_restricted.py#L41)

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
