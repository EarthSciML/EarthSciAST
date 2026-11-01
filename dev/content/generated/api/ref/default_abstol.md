---
title: "default_abstol"
description: "Stable constant · Simulation"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** constant · **Topic:** [Simulation](/generated/api/topics/simulation)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | `DEFAULT_ABSTOL` | not exported | `DEFAULT_ABSTOL` | outside profile |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

<p class="api-absent">Julia does not export this constant.</p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
const DEFAULT_ABSTOL: 0.000001
```

Binding default absolute tolerance (API_SPEC §5.8) — the bottom of the
§2.2.2 chain, used when neither the caller nor `solver.abstol` sets one.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/solver.ts#L36)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

<p class="api-absent">Python does not export this constant.</p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub const DEFAULT_ABSTOL: f64 = 1e-6;
```

The canonical default absolute tolerance — Julia's. Rust's was `1e-8`.
See [`DEFAULT_RELTOL`](/generated/api/ref/default_reltol).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-rs/src/simulate/api.rs#L73) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/constant.DEFAULT_ABSTOL.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Not available in Go. Go is outside the simulation capability profile (Julia, Python, Rust): build an RHS and integrate it; TypeScript and Go are deliberately non-simulating.</p>

</div>

</div>
