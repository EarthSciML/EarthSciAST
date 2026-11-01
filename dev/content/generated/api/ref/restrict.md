---
title: "restrict"
description: "Stable function · Other"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Other](/generated/api/topics/other)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `restrict` | not exported | `restrict` | not exported | not exported |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
restrict(op::EarthSciAST.RhsProgram, dec::Decomposition; owned, storage)
```

```julia
restrict(op::RhsProgram, dec::Decomposition; owned, storage) -> TileProgram
```

The operator restricted to one tile (API_SPEC §5.8, "Tile semantics"): `owned`
and `storage` give one inclusive range per cut axis (`"lon" => 17:32`), in
global coordinates, unwrapped on a periodic axis. The tile writes only its owned
rows and reads only its storage: an in-domain read outside storage with no
periodic image in it raises `range_halo_insufficient`; a 0-d state write or a
contraction, scan or data-dependent gather along a cut axis raises
`range_global_locality`; a box that does not fit raises `range_box_invalid`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/EarthSciAST.jl/src/range_restricted.jl#L2512)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">TypeScript does not export this function.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
restrict(op: Any, dec: Any, *, owned: Any, storage: Any) -> Any
```

`op` restricted to one tile. Raises `compiler_unavailable`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-py/src/earthsci_ast/range_restricted.py#L61)

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
