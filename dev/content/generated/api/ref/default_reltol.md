---
title: "default_reltol"
description: "Stable constant · Simulation"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** constant · **Topic:** [Simulation](/generated/api/topics/simulation)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | `DEFAULT_RELTOL` | not exported | `DEFAULT_RELTOL` | outside profile |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

<p class="api-absent">Julia does not export this constant.</p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
const DEFAULT_RELTOL: 0.0001
```

Binding default relative tolerance (API_SPEC §5.8) — the bottom of the
§2.2.2 chain, used when neither the caller nor `solver.reltol` sets one.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-ts/src/solver.ts#L31)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

<p class="api-absent">Python does not export this constant.</p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub const DEFAULT_RELTOL: f64 = 1e-4;
```

The canonical default relative tolerance.

All three simulation-capable bindings defaulted differently — Rust `1e-6`,
Python scipy's `1e-3`, Julia `1e-4` — so the same document solved with
default options did not produce comparable trajectories. The ruling is to
adopt **Julia's** pair, which is what this is; Rust's own default was two
orders TIGHTER, so aligning loosens it.

These are the defaults for a *production* run, not for a conformance
assertion. A test that pins a trajectory to a numerical threshold should
pass an explicit `reltol`/`abstol` rather than lean on these — that is what
the knobs are for, and it is what the in-tree fixtures do.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-rs/src/simulate/api.rs#L69) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/constant.DEFAULT_RELTOL.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Not available in Go. Go is outside the simulation capability profile (Julia, Python, Rust): build an RHS and integrate it; TypeScript and Go are deliberately non-simulating.</p>

</div>

</div>
