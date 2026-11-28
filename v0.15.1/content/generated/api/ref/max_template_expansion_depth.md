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
const MAX_TEMPLATE_EXPANSION_DEPTH: 64
```

Maximum template-body reference-chain depth (counted in TEMPLATES along the
longest chain, so a 65-template chain is rejected while a 64-template chain
is accepted) before a file is rejected with
`operator_body_expansion_too_deep` (esm-spec §9.7.3). Pinned identically
across all bindings. It equals `MAX_REWRITE_PASSES`: a rewrite of depth `d`
writes a body-reference chain `d` templates deep, so every document the
rewriter accepts also reloads once emitted with its references.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/earthsci-ast-ts/src/lower-expression-templates.ts#L514)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
MAX_TEMPLATE_EXPANSION_DEPTH = 64
```

Maximum template-body reference-chain depth (counted in TEMPLATES along the
longest chain, so a 65-template chain is rejected and a 64-template chain is
accepted) before a file is rejected with `template_body_expansion_too_deep`
(esm-spec §9.7.3). Pinned identically across all bindings. It equals
`MAX_REWRITE_PASSES`: a rewrite of depth `d` writes a body-reference chain
`d` templates deep, so every document the rewriter accepts also reloads
once emitted with its references.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/earthsci-ast-py/src/earthsci_ast/template_imports.py#L93)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

<p class="api-absent">Rust does not export this constant.</p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
const MaxTemplateExpansionDepth = 64
```

MaxTemplateExpansionDepth is the maximum template-body reference-chain depth (counted in TEMPLATES along the longest chain, so a 65-template chain is rejected and a 64-template chain is accepted) before a file is rejected with `operator_body_expansion_too_deep` (esm-spec §9.7.3). Pinned identically across all bindings. It equals MaxRewritePasses: a rewrite of depth d writes a body-reference chain d templates deep, so every document the rewriter accepts also reloads once emitted with its references.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/86bed77c797f79bad4895e685007ce09e6451cf7/pkg/earthsci-ast-go/pkg/esm/template_imports.go#L51) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#MaxTemplateExpansionDepth)

</div>

</div>
