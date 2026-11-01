---
title: "emit_esm_string"
description: "Stable function · Document I/O"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Document I/O](/generated/api/topics/document-io)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | `emitEsmString` | `emit_esm_string` | not exported | not exported |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

<p class="api-absent">Julia does not export this function.</p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function emitEsmString(doc: unknown): string
```

Canonical byte serialization of an emitted document (esm-spec §9.6.4 rule 5):
2-space indent, object keys sorted lexicographically (UTF-8 byte order)
EXCEPT the entries of an `expression_templates` object, which preserve their
authored-first / materialized-sorted order. The cross-binding byte-identity
surface for the Option-B emitted form and the target of the `emitted.esm`
goldens. Mirrors the Julia reference `emit_esm_string`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/lower-expression-templates.ts#L2231)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
emit_esm_string(doc: Any) -> str
```

Canonical byte serialization of an emitted document (esm-spec §9.6.4
rule 5): 2-space indent, object keys sorted lexicographically EXCEPT the
entries of an `expression_templates` object, which preserve their
authored-first / materialized-sorted order. The cross-binding byte-identity
surface for the Option-B emitted form and the target of the `emitted.esm`
goldens.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-py/src/earthsci_ast/serialize.py#L1370)

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
