---
title: "format_canonical_float"
description: "Stable function · Document I/O"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Document I/O](/generated/api/topics/document-io)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `format_canonical_float` | `formatCanonicalFloat` | not exported | `format_canonical_float` | not exported |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
format_canonical_float(f::Float64)
```

```julia
format_canonical_float(f::Float64) -> String
```

Format a finite `Float64` per RFC §5.4.6.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/canonicalize.jl#L471)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function formatCanonicalFloat(f: number): string
```

Format a finite `number` as a byte-CANONICAL float token per RFC §5.4.6.
Only handles float-typed values: integer-typed `NumericLiteral` nodes are
emitted as bare JSON integers by [`canonicalJson`](/generated/api/ref/canonical_json) directly.

NAMING: distinct from `formatFloatToken` in `./numeric-literal` (the
document-serialization emitter used by `toJson()` / `losslessJsonStringify`).
This canonical version additionally NORMALIZES exponent notation — it strips
the leading `+` (RFC §5.4.6: "no leading + on the exponent") so `1e25` emits
as `1e25`, not `1e+25`, and forces the §5.4.6 exponent thresholds. Use this
one for canonical output, `formatFloatToken` for wire round-trip.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-ts/src/canonicalize.ts#L449)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

<p class="api-absent">Python does not export this function.</p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn format_canonical_float(f: f64) -> String
```

Format a finite f64 per RFC §5.4.6.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-rs/src/canonicalize.rs#L638) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.format_canonical_float.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Go does not export this function.</p>

</div>

</div>
