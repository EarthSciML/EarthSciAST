---
title: "emit_document"
description: "Stable function · Document I/O"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Document I/O](/generated/api/topics/document-io)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | `emitDocument` | `emit_document` | not exported | not exported |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

<p class="api-absent">Julia does not export this function.</p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function emitDocument(rawSource: unknown, basePath: string, options?: TemplateResolveOptions): JsonObject
```

Produce the reference-preserving, self-contained emitted document (esm-spec
§9.6.4 rule 5, RFC out-of-line-expression-templates §7.5) from a source
document `rawSource` (a fixture, or an already-emitted document for the
idempotency property; relative import refs resolve against `basePath`). Loads
`rawSource` under Option B, then materializes each component's surviving
reference closure into its `expression_templates` block, drops consumed
imports, and version-stamps `esm: 0.9.0` when any reference/materialized entry
remains (§9.6.4 rule 8). `emitEsmString ∘ emitDocument` is a byte-wise fixed
point under reload. Mirrors the Julia reference `emit_document`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-ts/src/template-imports.ts#L2265)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
emit_document(raw_source: Any, base_path: str) -> dict
```

Produce the reference-preserving, self-contained emitted document
(esm-spec §9.6.4 rule 5, RFC out-of-line-expression-templates §7.5) from a
source document (a fixture, or an already-emitted document for the
idempotency property). Loads `raw_source` under Option B, then for every
component builds its emitted `expression_templates` block — authored
match-less entries first in authored order, then the materialized transitive
closure of its surviving references (match-less), lexicographically sorted —
drops consumed `expression_template_imports`, and version-stamps
`esm: 0.9.0` when any surviving reference or materialized entry remains
(§9.6.4 rule 8). `emit_esm_string ∘ emit_document` is a byte-wise fixed
point under reload.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-py/src/earthsci_ast/lower_expression_templates.py#L1506)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

<p class="api-absent">Rust does not export this function.</p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Go does not export this function.</p>

</div>

</div>
