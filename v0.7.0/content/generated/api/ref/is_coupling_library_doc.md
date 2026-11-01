---
title: "is_coupling_library_doc"
description: "Stable function · Load-time lowering and templates"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Load-time lowering and templates](/generated/api/topics/lowering)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | `isCouplingLibraryDoc` | `is_coupling_library_doc` | `is_coupling_library_doc` | not exported |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

<p class="api-absent">Julia does not export this function.</p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function isCouplingLibraryDoc(raw: unknown): boolean
```

True when `raw` has the coupling-library-file FORM (top-level
`coupling_roles`, esm-spec §10.9). Presence of that key is the sole positive
identifier of the file kind; purity is checked separately at the import edge.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-ts/src/coupling-imports.ts#L63)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
is_coupling_library_doc(raw: Any) -> bool
```

True when `raw` has the coupling-library-file FORM (top-level
`coupling_roles`, esm-spec §10.9). Presence of that key is the sole
positive identifier of the file kind; purity is checked separately at the
import edge.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-py/src/earthsci_ast/coupling_imports.py#L70)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn is_coupling_library_doc(raw: &Value) -> bool
```

True when `raw` has the coupling-library-file FORM (top-level
`coupling_roles`, esm-spec §10.9). Presence of that key is the sole positive
identifier of the file kind; purity is checked separately at the import edge.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-rs/src/coupling_imports.rs#L70) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.is_coupling_library_doc.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Go does not export this function.</p>

</div>

</div>
