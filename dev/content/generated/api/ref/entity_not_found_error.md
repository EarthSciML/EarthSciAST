---
title: "entity_not_found_error"
description: "Stable error · Editing"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** error · **Topic:** [Editing](/generated/api/topics/editing)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | `EntityNotFoundError` | not exported | not exported | `EntityNotFoundError` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

<p class="api-absent">Julia does not export this error.</p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
class EntityNotFoundError extends EsmDiagnosticError
new EntityNotFoundError(entityType: string, entityName: string): EntityNotFoundError
```

Error thrown when attempting an operation on a non-existent entity

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-ts/src/edit.ts#L47)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

<p class="api-absent">Python does not export this error.</p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

<p class="api-absent">Rust does not export this error.</p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type EntityNotFoundError struct {
	EditError
	EntityType string
	EntityName string
}
```

EntityNotFoundError reports an operation on a non-existent entity. Mirrors TypeScript's `EntityNotFoundError`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/edit.go#L86) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#EntityNotFoundError)

</div>

</div>
