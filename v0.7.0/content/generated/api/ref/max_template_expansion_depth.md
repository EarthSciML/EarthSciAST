---
title: "max_template_expansion_depth"
description: "Stable constant · Load-time lowering and templates"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** constant · **Topic:** [Load-time lowering and templates](/generated/api/topics/lowering)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | `MAX_TEMPLATE_EXPANSION_DEPTH` | `MAX_TEMPLATE_EXPANSION_DEPTH` | not exported | `MaxTemplateExpansionDepth` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

<p class="api-absent">Julia does not export this constant.</p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
const MAX_TEMPLATE_EXPANSION_DEPTH: 32
```

Maximum template-body reference-chain depth (counted in TEMPLATES along the
longest chain, so a 33-template chain is rejected while a 32-template chain
is accepted) before a file is rejected with
`template_body_expansion_too_deep` (esm-spec §9.7.3). Pinned identically
across all bindings.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-ts/src/lower-expression-templates.ts#L571)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
MAX_TEMPLATE_EXPANSION_DEPTH = 32
```

Maximum template-body reference-chain depth (counted in TEMPLATES along the
longest chain, so a 33-template chain is rejected and a 32-template chain is
accepted) before a file is rejected with `template_body_expansion_too_deep`
(esm-spec §9.7.3). Pinned identically across all bindings.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-py/src/earthsci_ast/template_imports.py#L87)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

<p class="api-absent">Rust does not export this constant.</p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
const MaxTemplateExpansionDepth = 32
```

MaxTemplateExpansionDepth is the maximum template-body reference-chain depth (counted in TEMPLATES along the longest chain, so a 33-template chain is rejected and a 32-template chain is accepted) before a file is rejected with `template_body_expansion_too_deep` (esm-spec §9.7.3). Pinned identically across all bindings.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-go/pkg/esm/template_imports.go#L49) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#MaxTemplateExpansionDepth)

</div>

</div>
