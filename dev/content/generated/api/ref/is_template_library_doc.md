---
title: "is_template_library_doc"
description: "Stable function · Load-time lowering and templates"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Load-time lowering and templates](/generated/api/topics/lowering)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | `isTemplateLibraryDoc` | not exported | `is_template_library_doc` | not exported |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

<p class="api-absent">Julia does not export this function.</p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function isTemplateLibraryDoc(raw: unknown): boolean
```

True when `raw` has the template-library-file FORM (top-level
`expression_templates`, esm-spec §9.7.1). Purity (no models / reaction
systems / loaders / coupling / domain) is checked separately at import
edges.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-ts/src/template-imports.ts#L186)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

<p class="api-absent">Python does not export this function.</p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn is_template_library_doc(raw: &Value) -> bool
```

True when `raw` has the template-library-file FORM (top-level
`expression_templates`, esm-spec §9.7.1). Purity (no models / reaction
systems / loaders / coupling / domain) is checked separately at import
edges.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-rs/src/template_imports.rs#L309) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.is_template_library_doc.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Go does not export this function.</p>

</div>

</div>
