---
title: "variable_kind"
description: "Stable type · Variable classification"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Variable classification](/generated/api/topics/classification)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | `VariableKind` | not exported | `VariableKind` | not exported |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

<p class="api-absent">Julia does not export this type.</p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
type VariableKind = VariableNode['kind'];
```

The kind of a variable node. Derived from graph.ts's [`VariableNode`](/generated/api/ref/variable_node) so
the union lives in exactly one place (analysis and the parent graph module
must agree on the vocabulary of variable kinds).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-ts/src/analysis/types.ts#L16)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

<p class="api-absent">Python does not export this type.</p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub enum VariableKind {
    State,
    Algebraic,
    Parameter,
    Observed,
    Brownian,
    Discrete,
    Species,
}
```

Type/kind of variable, as the graph renders it.

These are the esm-spec §6.3.1 DERIVED categories, not declared types — esm
1.0.0 declares only `unknown` and `parameter`. The mapping is fixed by
`variable_kind`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-rs/src/graph.rs#L427) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/enum.VariableKind.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Go does not export this type.</p>

</div>

</div>
