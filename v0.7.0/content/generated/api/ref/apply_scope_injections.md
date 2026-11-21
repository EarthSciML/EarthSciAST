---
title: "apply_scope_injections"
description: "Stable function · Load-time lowering and templates"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Load-time lowering and templates](/generated/api/topics/lowering)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | `applyScopeInjections` | not exported | `apply_scope_injections` | not exported |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

<p class="api-absent">Julia does not export this function.</p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function applyScopeInjections(raw: unknown, injected?: readonly unknown[]): JsonObject | null
```

esm-spec §9.7.10 forms A + B: if `raw` needs a scope-directed injection (a
non-empty subsystem-ref edge list `injected`, or a coupling entry carrying
an injection map), return a fresh plain-object tree with the injected
imports folded into the target components' own `expression_template_imports`,
ready for `resolveTemplateMachinery`. Returns `null` when no injection
applies, so the caller keeps its original fast path.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-ts/src/template-imports.ts#L2844)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

<p class="api-absent">Python does not export this function.</p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn apply_scope_injections(root: &mut Value, injected: &[Value]) -> Result<(), ExpressionTemplateError>
```

esm-spec §9.7.10 forms A + B: fold any scope-directed injection — a
subsystem-ref edge's `injected` import list (form A) or a coupling entry's
injection map (form B) — into the target components' own
`expression_template_imports`, in place, so the ordinary import resolver +
§9.6.3 fixpoint lower the target under the consumer-chosen discretization.
Runs BEFORE `resolve_template_machinery`; form B target diagnostics
(`template_inject_target_*`) surface here.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-rs/src/template_imports.rs#L3538) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.apply_scope_injections.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Go does not export this function.</p>

</div>

</div>
