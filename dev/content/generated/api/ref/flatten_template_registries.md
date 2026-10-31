---
title: "flatten_template_registries"
description: "Stable function · Flatten"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Flatten](/generated/api/topics/flatten)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | `flattenTemplateRegistries` | `flatten_template_registries` | not exported | not exported |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

<p class="api-absent">Julia does not export this function.</p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function flattenTemplateRegistries(loaded: object): FlattenedTemplateRegistries
```

The flatten-time template-registry merge (esm-spec §9.6.4 rule 7, §10.7;
esm-libraries-spec §4.7.5 step 4). Given an Option-B loaded multi-component
document `loaded`, merge every component's match-less `expression_templates`
registry into a single document-scoped merged registry:

 - **Deep-equal dedup at first occurrence** — two components importing one
   stencil produce identical folded bodies, kept once under the bare name.
 - **Non-deep-equal same-name collision** — both entries are renamed
   deterministically to `<ComponentPath>.<name>` and their
   `apply_expression_template` references are rewritten in lockstep.
 - **Collisions propagate along the reference DAG** — a declaration that
   references a colliding name collides too (see
   `registryCollisionNames`), so a byte-identical wrapper over a
   per-component leaf is renamed per owner rather than deduped into one body
   whose nested reference no longer resolves.

Returns the rewritten document `root` (component reference sites updated) and
the merged registry (the FlattenedSystem's first-class registry field).
`match` rules are not merged (only match-less templates are referenceable).
Mirrors the Julia reference `flatten_template_registries`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-ts/src/lower-expression-templates.ts#L2355)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
flatten_template_registries(loaded: Any) -> tuple[dict, dict]
```

The flatten-time template-registry merge (esm-spec §9.6.4 rule 7, §10.7;
esm-libraries-spec §4.7.5 step 4). Given an Option-B loaded multi-component
document `loaded`, merge every component's `expression_templates`
registry into a single document-scoped merged registry:

- **Deep-equal dedup at first occurrence** — two components importing one
  stencil produce identical folded bodies, kept once under the bare name.
- **Non-deep-equal same-name collision** — both entries are renamed
  deterministically to `<ComponentPath>.<name>` and their
  `apply_expression_template` references are rewritten in lockstep (total,
  deterministic; no new diagnostic).
- **Collisions propagate along the reference DAG** — a declaration that
  references a colliding name collides too (see
  `_registry_collision_names`), so a byte-identical wrapper over a
  per-component leaf is renamed per owner rather than deduped into one body
  whose nested reference no longer resolves.

Returns the rewritten document `root` (component reference sites updated)
and the merged registry as a dict (the FlattenedSystem's first-class
registry field). `match` rules are not merged (only match-less templates
are referenceable, §9.6.2).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/lower_expression_templates.py#L1704)

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
