---
title: "component_exists"
description: "Stable function · Editing"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Editing](/generated/api/topics/editing)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | `componentExists` | `component_exists` | `component_exists` | not exported |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

<p class="api-absent">Julia does not export this function.</p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function componentExists(esmFile: EsmFile, componentId: string): boolean
```

Utility to check if a component exists in the ESM file

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-ts/src/graph.ts#L480)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
component_exists(file: EsmFile, component_id: str) -> bool
```

True when `component_id` names a model or reaction system of `file`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-py/src/earthsci_ast/graph.py#L399)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn component_exists(esm_file: &EsmFile, component_id: &str) -> bool
```

Check if a component exists in the ESM file

**Arguments**

* `esm_file` - The ESM file to check
* `component_id` - The component ID to look for

**Returns**

* `true` if the component exists, `false` otherwise

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-rs/src/graph.rs#L363) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.component_exists.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Go does not export this function.</p>

</div>

</div>
