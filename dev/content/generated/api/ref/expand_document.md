---
title: "expand_document"
description: "Stable function · Load-time lowering and templates"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Load-time lowering and templates](/generated/api/topics/lowering)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | `expandDocument` | `expand_document` | not exported | not exported |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

<p class="api-absent">Julia does not export this function.</p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function expandDocument<T extends object>(loaded: T): T
```

Fully expand every surviving `apply_expression_template` reference in a
document `loaded` by [`lowerExpressionTemplates`](/generated/api/ref/lower_expression_templates) (Option B), producing
the Option-A image: every reference replaced by its expansion (pure
substitution to the acyclic fixpoint, §9.6.4 rule 2) and every per-component
`expression_templates` block stripped. Deterministic — the §9.7.3 DAG is
acyclic and substitution confluent, so `expandDocument(load(f))` is
structurally equal to the pre-0.9.0 expanded form (the `expanded*.esm`
conformance oracle). Non-destructive: `loaded` is deep-cloned first. Mirrors
the Julia reference `expand_document` / `Expand`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/lower-expression-templates.ts#L1985)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
expand_document(loaded: Any) -> Any
```

Fully expand every surviving `apply_expression_template` reference in a
document `loaded` by [`lower_expression_templates`](/generated/api/ref/lower_expression_templates) (Option B),
producing the Option-A image: every reference replaced by its expansion
(pure substitution to the acyclic fixpoint, §9.6.4 rule 2) and every
per-component `expression_templates` block stripped. Deterministic — the
DAG is acyclic and substitution confluent, so the result is structurally
equal to the `expanded*.esm` conformance oracle (§9.6.7). Non-destructive: `loaded` is deep copied
first.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-py/src/earthsci_ast/lower_expression_templates.py#L1381)

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
