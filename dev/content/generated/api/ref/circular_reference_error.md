---
title: "circular_reference_error"
description: "Stable error · Load-time lowering and templates"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** error · **Topic:** [Load-time lowering and templates](/generated/api/topics/lowering)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | `CircularReferenceError` | `CircularReferenceError` | not exported | not exported |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

<p class="api-absent">Julia does not export this error.</p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
class CircularReferenceError extends EsmDiagnosticError
new CircularReferenceError(chain: string[]): CircularReferenceError
readonly CircularReferenceError.prototype.chain: string[]
```

Error thrown when a circular reference is detected during subsystem resolution.

**Members**

- `chain` — The chain of references that form the cycle

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-ts/src/ref-loading.ts#L59)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class CircularReferenceError(EarthSciAstError)
```

Exception raised when circular subsystem references are detected.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/parse.py#L123)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

<p class="api-absent">Rust does not export this error.</p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Go does not export this error.</p>

</div>

</div>
