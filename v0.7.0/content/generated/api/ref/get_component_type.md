---
title: "get_component_type"
description: "Stable function · Editing"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Editing](/generated/api/topics/editing)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | `getComponentType` | not exported | `get_component_type` | not exported |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

<p class="api-absent">Julia does not export this function.</p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function getComponentType(esmFile: EsmFile, componentId: string): ComponentNode['type'] | null
```

Get the type of a component by its ID

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-ts/src/graph.ts#L487)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

<p class="api-absent">Python does not export this function.</p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn get_component_type(esm_file: &EsmFile, component_id: &str) -> Option<ComponentType>
```

Get the type of a component

A `data_sources` id is NOT a component (esm-libraries-spec §4.8.1) and
resolves to `None`.

**Arguments**

* `esm_file` - The ESM file to check
* `component_id` - The component ID to look for

**Returns**

* `Some(ComponentType)` if the component exists
* `None` if the component doesn't exist

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-rs/src/graph.rs#L381) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.get_component_type.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Go does not export this function.</p>

</div>

</div>
