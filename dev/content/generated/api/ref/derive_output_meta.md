---
title: "derive_output_meta"
description: "Stable function · Runtime I/O"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Runtime I/O](/generated/api/topics/runtime-io)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `derive_output_meta` | outside profile | not exported | `derive_output_meta` | outside profile |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
derive_output_meta(doc::AbstractDict)
```

```julia
derive_output_meta(doc) -> OutputMeta
```

Distill the flattened run document into [`OutputMeta`](/generated/api/ref/output_meta): the model names, the
`index_sets` axis lengths, each variable's declared `shape` (real dim names) +
retained CF attrs + declared kind, the additive `coordinates` registry (§8.3), and
the record-axis name (`domain.independent_variable`). Returns an empty
`OutputMeta` for a document with no `models` (nothing to name). Reads only the doc
— no build artifacts — so it composes with `derive_output_gridding`.

Variable tables are keyed by BOTH the bare name and its `Model.`-qualified form,
so a namespaced flat state (`Model.u[…]`) resolves its real dim names instead of
silently falling back to positional ones. A bare name claimed by more than one
model is ambiguous and only the qualified key survives.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/EarthSciAST.jl/src/data_output.jl#L589)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">Not available in TypeScript. TypeScript is outside the runtime I/O capability profile (Julia, Python, Rust): data-source providers, refresh cadence, output sinks, checkpoints.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

<p class="api-absent">Python does not export this function.</p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn derive_output_meta(doc: &EsmFile) -> OutputMeta
```

Distill a run document into [`OutputMeta`](/generated/api/ref/output_meta) — the Rust mirror of Julia's
`derive_output_meta`. Reads only the document (no build artifacts), so it
composes with [`derive_output_gridding`](/generated/api/ref/derive_output_gridding).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-rs/src/data_output.rs#L652) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.derive_output_meta.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Not available in Go. Go is outside the runtime I/O capability profile (Julia, Python, Rust): data-source providers, refresh cadence, output sinks, checkpoints.</p>

</div>

</div>
